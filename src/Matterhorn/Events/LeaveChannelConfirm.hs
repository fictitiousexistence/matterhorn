module Matterhorn.Events.LeaveChannelConfirm
  ( onEventLeaveChannelConfirm
  )
where

import           Prelude ()
import           Matterhorn.Prelude

import qualified Graphics.Vty as Vty

import           Network.Mattermost.Types ( TeamId )

import           Matterhorn.State.Channels
import           Matterhorn.Types


onEventLeaveChannelConfirm :: TeamId -> Vty.Event -> MH ()
onEventLeaveChannelConfirm tId (Vty.EvKey k []) = do
    case k of
        Vty.KChar c | c `elem` ("yY"::String) ->
            leaveCurrentChannel tId
        _ -> return ()
    popMode tId
onEventLeaveChannelConfirm _ _ = return ()
