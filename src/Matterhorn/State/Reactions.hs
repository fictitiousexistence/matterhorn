module Matterhorn.State.Reactions
  ( asyncFetchReactionsForPost
  , addReactions
  , removeReaction
  , updateReaction
  , toggleReaction
  )
where

import           Prelude ()
import           Matterhorn.Prelude

import qualified Data.Map.Strict as Map
import           Lens.Micro.Platform
import qualified Data.Set as S

import           Network.Mattermost.Endpoints
import           Network.Mattermost.Lenses
import           Network.Mattermost.Types

import           Matterhorn.State.Async
import           Matterhorn.State.Common
import           Matterhorn.Types


-- | Queue up a fetch for the reactions of the specified post in the
-- specified channel.
asyncFetchReactionsForPost :: ChannelId -> Post -> MH ()
asyncFetchReactionsForPost cId p
  | not (p^.postHasReactionsL) = return ()
  | otherwise = doAsyncChannelMM Normal cId
        (\s _ -> fmap toList (mmGetReactionsForPost (p^.postIdL) s))
        (\_ rs -> Just $ Work "asyncFetchReactionsForPost" $ addReactions cId rs)

-- | Add the specified reactions returned by the server to the relevant
-- posts in the specified channel. This should only be called in
-- response to a server API request or event. If you want to add
-- reactions to a post, start by calling @mmPostReaction@. We also
-- invalidate the cache for any rendered message corresponding to the
-- incoming reactions.
addReactions :: ChannelId -> [Reaction] -> MH ()
addReactions cId rs = do
    invalidateChannelRenderingCache cId
    csChannelMessages(cId) %= fmap upd

    -- Also update any open thread for the corresponding channel's team
    withChannel cId $ \chan -> do
        case chan^.ccInfo.cdTeamId of
            Nothing -> return ()
            Just tId -> modifyThreadMessages tId cId (fmap upd)

    let mentions = S.fromList $ UserIdMention <$> reactionUserId <$> rs
    fetchMentionedUsers mentions
    invalidateRenderCache
  where upd msg = msg & mReactions %~ insertAll (msg^.mMessageId)
        insert mId r
          | mId == Just (MessagePostId (r^.reactionPostIdL)) =
              Map.insertWith S.union (r^.reactionEmojiNameL) (S.singleton $ r^.reactionUserIdL)
          | otherwise = id
        insertAll mId msg = foldr (insert mId) msg rs
        invalidateRenderCache = do
            forM_ rs $ \r ->
                invalidateMessageRenderingCacheByPostId $ r^.reactionPostIdL

-- | Remove the specified reaction from its message in the specified
-- channel. This should only be called in response to a server event
-- instructing us to remove the reaction. If you want to trigger such an
-- event, use @updateReaction@. We also invalidate the cache for any
-- rendered message corresponding to the removed reaction.
removeReaction :: Reaction -> ChannelId -> MH ()
removeReaction r cId = do
    invalidateChannelRenderingCache cId
    csChannelMessages(cId) %= fmap upd

    -- Also update any open thread for the corresponding channel's team
    withChannel cId $ \chan -> do
        case chan^.ccInfo.cdTeamId of
            Nothing -> return ()
            Just tId -> modifyThreadMessages tId cId (fmap upd)

    invalidateRenderCache
  where upd m | m^.mMessageId == Just (MessagePostId $ r^.reactionPostIdL) =
                  m & mReactions %~ (removeEmptySets . Map.alter delReaction (r^.reactionEmojiNameL))
              | otherwise = m
        delReaction mUs = S.delete (r^.reactionUserIdL) <$> mUs
        removeEmptySets = Map.filter (not . S.null)
        invalidateRenderCache =
            invalidateMessageRenderingCacheByPostId $ r^.reactionPostIdL

-- | Set or unset a reaction on a post.
updateReaction :: PostId -> Text -> Bool -> MH ()
updateReaction pId text value = do
    session <- getSession
    myId <- gets myUserId
    if value
      then doAsyncWith Preempt $ do
                mmPostReaction pId myId text session
                return Nothing
      else doAsyncWith Preempt $ do
                mmDeleteReaction pId myId text session
                return Nothing

-- | Toggle a reaction on a post.
toggleReaction :: PostId -> Text -> Set UserId -> MH ()
toggleReaction pId text uIds = do
    myId <- gets myUserId
    let current = myId `S.member` uIds
    updateReaction pId text (not current)
