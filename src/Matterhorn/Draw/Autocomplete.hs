{-# LANGUAGE RankNTypes #-}
module Matterhorn.Draw.Autocomplete
  ( drawAutocompleteLayers
  )
where

import           Prelude ()
import           Matterhorn.Prelude

import           Brick
import           Brick.Widgets.Border
import           Brick.Widgets.List ( renderList, listElementsL, listSelectedFocusedAttr
                                    , listSelectedElement
                                    )
import qualified Data.Text as T
import           Lens.Micro.Platform ( SimpleGetter, Lens' )

import           Network.Mattermost.Types ( User(..), Channel(..), TeamId )

import           Matterhorn.Constants ( normalChannelSigil )
import           Matterhorn.Draw.ChannelList ( channelListWidth )
import           Matterhorn.Draw.Util ( mkChannelName )
import           Matterhorn.Themes
import           Matterhorn.Types
import           Matterhorn.Types.Common ( sanitizeUserText )

drawAutocompleteLayers :: ChatState -> [Widget Name]
drawAutocompleteLayers st =
    catMaybes [ do
                    tId <- st^.csCurrentTeamId
                    cId <- st^.csCurrentChannelId(tId)
                    return $ autocompleteLayer st (channelEditor(cId))
              , do
                    tId <- st^.csCurrentTeamId
                    void $ st^.csTeam(tId).tsThreadInterface
                    let ti :: Lens' ChatState ThreadInterface
                        ti = unsafeThreadInterface(tId)
                        ed :: SimpleGetter ChatState (EditState Name)
                        ed = ti.miEditor
                    return $ autocompleteLayer st ed
              ]

autocompleteLayer :: ChatState -> SimpleGetter ChatState (EditState Name) -> Widget Name
autocompleteLayer st which =
    case st^.which.esAutocomplete of
        Nothing ->
            emptyWidget
        Just ac ->
            fromMaybe emptyWidget $ do
                tId <- st^.csCurrentTeamId
                let mcId = st^.csCurrentChannelId(tId)
                    mCurChan = do
                        cId <- mcId
                        st^?csChannel(cId)
                return $ renderAutocompleteBox st tId mCurChan which ac

userNotInChannelMarker :: T.Text
userNotInChannelMarker = "*"

elementTypeLabel :: AutocompletionType -> Text
elementTypeLabel ACUsers = "Users"
elementTypeLabel ACChannels = "Channels"
elementTypeLabel ACCodeBlockLanguage = "Languages"
elementTypeLabel ACEmoji = "Emoji"
elementTypeLabel ACCommands = "Commands"

renderAutocompleteBox :: ChatState
                      -> TeamId
                      -> Maybe ClientChannel
                      -> SimpleGetter ChatState (EditState Name)
                      -> AutocompleteState Name
                      -> Widget Name
renderAutocompleteBox st tId mCurChan which ac =
    let matchList = _acCompletionList ac
        maxListHeight = 5
        visibleHeight = min maxListHeight numResults
        numResults = length elements
        elements = matchList^.listElementsL
        editorName = getName $ st^.which.esEditor
        isMultiline = st^.which.esEphemeral.eesMultiline
        label = withDefAttr clientMessageAttr $
                txt $ elementTypeLabel (ac^.acType) <> ": " <> (T.pack $ show numResults) <>
                     " match" <> (if numResults == 1 then "" else "es") <>
                     " (Tab/Shift-Tab to select)"

        selElem = snd <$> listSelectedElement matchList
        footer = case mCurChan of
            Nothing ->
                hBorder
            Just curChan ->
                case renderAutocompleteFooterFor st curChan =<< selElem of
                    Just w -> hBorderWithLabel w
                    _ -> hBorder
        curUser = myUsername st
        cfg = st^.csResources.crConfiguration
        showingChanList = configShowChannelList cfg
        maybeLimit = fromMaybe id $ do
            let sub = if showingChanList
                      then channelListWidth st + 1
                      else 0
                threadNarrow = threadShowing && (cfg^.configThreadOrientationL `elem` [ThreadLeft, ThreadRight])
                threadShowing = isJust $ st^.csTeam(tId).tsThreadInterface

            if threadNarrow || sub > 0
               then return $ \w -> Widget Greedy Greedy $ do
                   ctx <- getContext
                   let adjusted = ctx^.availWidthL - sub
                       lim = if threadNarrow
                             then (adjusted - 1) `div` 2
                             else adjusted
                   render $ hLimit lim w
               else Nothing

        -- The top left corner of the editor area is given by the
        -- prompt, or by the editor position if multiline is enabled (in
        -- which case no prompt is drawn).
        editorTop = if isMultiline
                    then editorName
                    else MessageInputPrompt editorName

    in if numResults == 0
       then emptyWidget
       else Widget Greedy Greedy $ do
           let verticalOffset = -1 * (visibleHeight + 2)
           render $ relativeTo editorTop (Location (0, verticalOffset)) $
                    maybeLimit $
                    vBox [ hBorderWithLabel label
                         , vLimit visibleHeight $
                           renderList (renderAutocompleteAlternative curUser) True matchList
                         , footer
                         ]

renderAutocompleteFooterFor :: ChatState -> ClientChannel -> AutocompleteAlternative -> Maybe (Widget Name)
renderAutocompleteFooterFor _ _ (SpecialMention MentionChannel) = Nothing
renderAutocompleteFooterFor _ _ (SpecialMention MentionAll) = Nothing
renderAutocompleteFooterFor st ch (UserCompletion _ False _) =
    Just $ hBox [ txt $ "("
                , withDefAttr clientEmphAttr (txt userNotInChannelMarker)
                , txt ": not a member of "
                , withDefAttr channelNameAttr (txt $ mkChannelName st (ch^.ccInfo))
                , txt ")"
                ]
renderAutocompleteFooterFor _ _ (ChannelCompletion False ch) =
    Just $ hBox [ txt $ "("
                , withDefAttr clientEmphAttr (txt userNotInChannelMarker)
                , txt ": you are not a member of "
                , withDefAttr channelNameAttr (txt $ normalChannelSigil <> preferredChannelName ch)
                , txt ")"
                ]
renderAutocompleteFooterFor _ _ (CommandCompletion src _ _ _) =
    case src of
        Server ->
            Just $ hBox [ txt $ "("
                        , withDefAttr clientEmphAttr (txt serverCommandMarker)
                        , txt ": command provided by the server)"
                        ]
        Client -> Nothing
renderAutocompleteFooterFor _ _ _ =
    Nothing

serverCommandMarker :: Text
serverCommandMarker = "*"

renderAutocompleteAlternative :: Text -> Bool -> AutocompleteAlternative -> Widget Name
renderAutocompleteAlternative _ sel (EmojiCompletion e) =
    padRight Max $ renderEmojiCompletion sel e
renderAutocompleteAlternative _ sel (SpecialMention m) =
    padRight Max $ renderSpecialMention m sel
renderAutocompleteAlternative curUser sel (UserCompletion u inChan _) =
    padRight Max $ renderUserCompletion curUser u inChan sel
renderAutocompleteAlternative _ sel (ChannelCompletion inChan c) =
    padRight Max $ renderChannelCompletion c inChan sel
renderAutocompleteAlternative _ _ (SyntaxCompletion t) =
    padRight Max $ txt t
renderAutocompleteAlternative _ _ (CommandCompletion src n args desc) =
    padRight Max $ renderCommandCompletion src n args desc

renderSpecialMention :: SpecialMention -> Bool -> Widget Name
renderSpecialMention m sel =
    let usernameWidth = 18
        padTo n a = hLimit n $ vLimit 1 (a <+> fill ' ')
        maybeForce = if sel
                     then forceAttr listSelectedFocusedAttr
                     else id
        t = autocompleteAlternativeReplacement $ SpecialMention m
        desc = case m of
            MentionChannel -> "Notifies all users in this channel"
            MentionAll     -> "Mentions all users in this channel"
    in maybeForce $
       hBox [ txt "  "
            , padTo usernameWidth $ withDefAttr clientEmphAttr $ txt t
            , txt desc
            ]

renderEmojiCompletion :: Bool -> T.Text -> Widget Name
renderEmojiCompletion sel e =
    let maybeForce = if sel
                     then forceAttr listSelectedFocusedAttr
                     else id
    in maybeForce $
       padLeft (Pad 2) $
       withDefAttr emojiAttr $
       txt $
       autocompleteAlternativeReplacement $ EmojiCompletion e

renderUserCompletion :: Text -> User -> Bool -> Bool -> Widget Name
renderUserCompletion curUser u inChan selected =
    let usernameWidth = 18
        fullNameWidth = 25
        padTo n a = hLimit n $ vLimit 1 (a <+> fill ' ')
        username = userUsername u
        fullName = (sanitizeUserText $ userFirstName u) <> " " <>
                   (sanitizeUserText $ userLastName u)
        nickname = sanitizeUserText $ userNickname u
        maybeForce = if selected
                     then forceAttr listSelectedFocusedAttr
                     else id
        memberDisplay = if inChan
                        then txt "  "
                        else withDefAttr clientEmphAttr $
                             txt $ userNotInChannelMarker <> " "
    in maybeForce $
       hBox [ memberDisplay
            , padTo usernameWidth $ colorUsername curUser username ("@" <> username)
            , padTo fullNameWidth $ txt fullName
            , txt nickname
            ]

renderChannelCompletion :: Channel -> Bool -> Bool -> Widget Name
renderChannelCompletion c inChan selected =
    let urlNameWidth = 30
        displayNameWidth = 30
        padTo n a = hLimit n $ vLimit 1 (a <+> fill ' ')
        maybeForce = if selected
                     then forceAttr listSelectedFocusedAttr
                     else id
        memberDisplay = if inChan
                        then txt "  "
                        else withDefAttr clientEmphAttr $
                             txt $ userNotInChannelMarker <> " "
    in maybeForce $
       hBox [ memberDisplay
            , padTo urlNameWidth $
              withDefAttr channelNameAttr $
              txt $ normalChannelSigil <> (sanitizeUserText $ channelName c)
            , padTo displayNameWidth $
              withDefAttr channelNameAttr $
              txt $ sanitizeUserText $ channelDisplayName c
            , vLimit 1 $ txt $ sanitizeUserText $ channelPurpose c
            ]

renderCommandCompletion :: CompletionSource -> Text -> Text -> Text -> Widget Name
renderCommandCompletion src name args desc =
    (txt $ " " <> srcTxt <> " ") <+>
    withDefAttr clientMessageAttr
        (txt $ "/" <> name <> if T.null args then "" else " " <> args) <+>
    (txt $ " - " <> desc)
    where
        srcTxt = case src of
            Server -> serverCommandMarker
            Client -> " "
