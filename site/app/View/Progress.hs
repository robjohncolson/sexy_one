{-# LANGUAGE OverloadedStrings #-}

-- | M3 wave 4 ("progress-ui"): review queue, per-deck\/chapter
-- completion, streak, continue-where-you-left-off, export\/import, the
-- corrupt-state banner, the retired-records note, and the JA-first
-- switch's rendering half. Kept POLYMORPHIC over @action@, matching
-- "View.Exercise"'s existing 'View.Exercise.ExHandlers' pattern -- this
-- module never sees Main's concrete @Action@ type, only whatever
-- @action@-producing values "Main.hs" hands it via 'ProgHandlers'.
--
-- SIZE (briefs\/M3-manifest.json, task \"progress-ui\"): this module is
-- the whole ~20 KB gzip budget for the UI. It reuses
-- "SXC1.Progress.Scheduler"\/"SXC1.Progress.Types" -- already linked into
-- @exe:app@ by "Progress.Store" -- rather than re-deriving any of the
-- spaced-repetition arithmetic, and never imports
-- @SXC1.Exercise.(Parse|Report|Lint|Verify)@ (the validating parser wave
-- 1 removed from the browser).
--
-- IMPORT PREVIEW (owner note): the record-count preview under
-- @#sxc1-import-preview@ is computed by plain JavaScript in
-- @site\/static\/index.js@, not here. There is no Miso 'Action' for \"the
-- learner is still typing\/pasting\" (Main's 'ProgressOp' only carries a
-- one-shot commit, @PImport Text@), and this module owns no path that
-- could add one -- so a live, un-committed preview has nowhere to live
-- in the Elm-style Model\/Action loop without inventing state Main.hs's
-- update handlers do not have. Plain JS reacting to the @input@ event on
-- @#sxc1-import-input@ and writing straight into @#sxc1-import-preview@
-- costs nothing against the wasm budget and never touches Haskell state;
-- see that file's own comment for the exact counting rule.
--
-- The IMPORT COMMIT itself (the one moment that must go through
-- Haskell), and the WIPE two-step confirm's actual wipe, both still
-- dispatch a real 'Action' -- see 'onImportSubmit' and 'phWipe' below.
module View.Progress
  ( ProgHandlers (..)
  , ProgData (..)
  , primaryTrainingView
  , progressHomeNotices
  , progressHomeView
  , jaFirstHeaderEls
  , uiLangHeaderEls
  , reviewBadgeEl
  , dueCountLive
  , deckDoneCount
  , chapterDoneCount
  , deckCardAttrs
  , deckMetaEls
  ) where

import           Data.List              (find)
import qualified Data.Map.Strict        as Map
import           Data.Map.Strict        (Map)
import           Data.Maybe             (fromMaybe, listToMaybe)
import qualified Data.Text              as T
import           Data.Text              (Text)

import           Miso
import           Miso.Html.Element      as H
import           Miso.Html.Event        as E
import           Miso.Html.Property     as P
import           Miso.JSON              (withObject, (.:))

import           I18n
import           SXC1.Exercise.Types    (Deck (..), DeckId (..), ExId (..), Exercise (..),
                                         PromptId (..), promptIdFor)
import           SXC1.Progress.Codec    (DecodeResult (..))
import           SXC1.Progress.Scheduler (reviewQueue)
import           SXC1.Progress.Types    (DayNum (..), ProgressState (..), Rec (..))
import           SXC1.Route             (Route (RDeck, RExercise, RExercises, RHome, RManual, RPage, RSession),
                                         renderRoute)

--------------------------------------------------------------------------
-- Action bundle (mirrors "View.Exercise".'View.Exercise.ExHandlers') and
-- the render-time data bundle Main.hs assembles once per frame from its
-- own Model. Neither derives anything -- both are rebuilt fresh on every
-- render, never stored, never compared.
--------------------------------------------------------------------------

data ProgHandlers action = ProgHandlers
  { phExport  :: action         -- ^ #btn-progress-export
  , phImport  :: Text -> action -- ^ the import FORM's submit -- see 'onImportSubmit'
  , phWipe    :: action         -- ^ #btn-progress-wipe-confirm
  , phJaFirst :: action         -- ^ #btn-ja-first -- ALREADY the negated next state; this
                                 --   module only ever renders the CURRENT one ('pdJaFirst')
  , phUiLang  :: action         -- ^ M6 W2: #btn-ui-lang -- flip the UI language (Main owns
                                 --   the persist-then-reload semantics)
  }

data ProgData = ProgData
  { pdDecks      :: [Deck]
  , pdProgress   :: !ProgressState
  , pdToday      :: !DayNum
  , pdLoad       :: DecodeResult
  , pdJaFirst    :: !Bool
  , pdLang       :: !Lang       -- ^ M6 W2: the active UI language every string renders through
  , pdExportBlob :: Maybe Text
  , pdImportMsg  :: Maybe Text
  , pdRawCorrupt :: Maybe Text  -- ^ the undecoded blob, for the corrupt banner's own export
  , pdStorageOk  :: !Bool       -- ^ NEW9: False = refused/lost storage; the notice below renders
  }

unDeckId :: DeckId -> Text
unDeckId (DeckId t) = t

unExId :: ExId -> Text
unExId (ExId t) = t

unPromptId :: PromptId -> Text
unPromptId (PromptId t) = t

deckHref :: Deck -> MisoString
deckHref d = ms (renderRoute (RDeck (unDeckId (dkId d))))

exerciseHref :: Deck -> Exercise -> MisoString
exerciseHref d ex = ms (renderRoute (RExercise (unDeckId (dkId d)) (unExId (exId ex))))

-- | A deck-pointing link, tagged as a @.deck-card@ -- the ONE shape
-- shared by "next unstarted deck" (the empty queue's pointer, and a
-- learner with no history at all's "continue" fallback).
deckPointerEl :: Text -> Deck -> View model action
deckPointerEl label d =
  H.a_ (P.href_ (deckHref d) : deckCardAttrs "" d) [ text (ms (label <> dkTitle d)) ]

--------------------------------------------------------------------------
-- Shared corpus/progress lookups.
--------------------------------------------------------------------------

-- | Every 'PromptId' the CURRENT corpus can mint -- mirrors Main.hs's own
-- @allCorpusPromptIds@ (that module cannot be imported here without a
-- cycle, so this is the one necessary re-derivation; both sides compute
-- it from the same 'Deck' list and the same 'promptIdFor', so the two
-- never disagree).
liveIds :: [Deck] -> Map Text ()
liveIds decks = Map.fromList
  [ (unPromptId (promptIdFor (exId e) i), ())
  | d <- decks, e <- dkExercises d, i <- [1 .. length (exPrompts e)] ]

liveReviewQueue :: ProgData -> [(Text, Rec)]
liveReviewQueue pd =
  [ pr | pr@(pid, _) <- reviewQueue (pdToday pd) (pdProgress pd), Map.member pid liveSet ]
  where liveSet = liveIds (pdDecks pd)

dueCountLive :: ProgData -> Int
dueCountLive = length . liveReviewQueue

retiredCountLive :: ProgData -> Int
retiredCountLive pd =
  Map.size (Map.filterWithKey (\k _ -> not (Map.member k liveSet)) (psRecs (pdProgress pd)))
  where liveSet = liveIds (pdDecks pd)

-- | The exercise (and its owning deck) a 'PromptId' text belongs to --
-- @\"\<exercise-id\>#\<n\>\"@, so the exercise id is everything before the
-- last @\'#\'@ (ids never contain one -- @SXC1.Route.isRouteId@'s
-- charset).
exerciseForPromptId :: [Deck] -> Text -> Maybe (Deck, Exercise)
exerciseForPromptId decks pid = listToMaybe
  [ (d, ex) | d <- decks, ex <- dkExercises d, unExId (exId ex) == exIdTxt ]
  where exIdTxt = fst (T.breakOn "#" pid)

-- | Exercises with at least one completion out of a deck's total --
-- @psDone@ is bumped once per completed run (every 'Advance' that empties
-- the cursor -- see "SXC1.Exercise.Engine"), so this is genuine
-- "finished at least once", not merely "attempted".
deckDoneCount :: ProgressState -> Deck -> (Int, Int)
deckDoneCount prog d =
  (length [ () | ex <- exs, Map.member (unExId (exId ex)) (psDone prog) ], length exs)
  where exs = dkExercises d

chapterDoneCount :: ProgressState -> [Deck] -> (Int, Int)
chapterDoneCount prog ds =
  (sum (map fst counts), sum (map snd counts))
  where counts = map (deckDoneCount prog) ds

-- | The first deck (course order) with no completed exercise yet -- the
-- shared "what's next" pointer for both the empty review queue and a
-- learner with no history at all.
nextUnstartedDeck :: ProgData -> Maybe Deck
nextUnstartedDeck pd = find (\d -> fst (deckDoneCount (pdProgress pd) d) == 0) (pdDecks pd)

-- | M3 gate NEW12: schema v2's 'psLastPrompt' IS the last graded prompt
-- -- a true last-activity pointer, persisted, no same-day ambiguity.
-- The day-granularity 'rcLastSeen' scan below survives ONLY as the
-- fallback for a state migrated from a v1 blob whose 'psLastPrompt' is
-- still empty (one page-load's worth of history: the next graded event
-- fills the real pointer). The fallback's same-day tie keeps whichever
-- 'Map.toList' visits first -- deterministic, documented, and no longer
-- the primary path.
mostRecentPromptId :: ProgressState -> Maybe Text
mostRecentPromptId st
  | not (T.null (psLastPrompt st))
  , Map.member (psLastPrompt st) (psRecs st) = Just (psLastPrompt st)
  | otherwise = case Map.toList (psRecs st) of
      []       -> Nothing
      (p0 : ps) -> Just (fst (foldl' newer p0 ps))
  where
    newer a (pid, rc)
      | unDayNum (rcLastSeen rc) > unDayNum (rcLastSeen (snd a)) = (pid, rc)
      | otherwise                                                = a

--------------------------------------------------------------------------
-- Deck cards: tier badge, completion count, requires list. Shared by
-- "View.Exercise" (the index and the deck page) so tier\/requires\/
-- completion is computed and rendered in exactly one place.
--------------------------------------------------------------------------

-- | @baseClass@ is the CALLER's own existing card class (e.g.
-- @\"ex-deck-card\"@, or @\"\"@ on a deck page's own single info block) --
-- folded into ONE @class_@ (never two: a second 'P.class_' in the same
-- attribute list would just overwrite the first, not merge with it)
-- alongside the new, stable @.deck-card@ hook and its @data-tier@.
deckCardAttrs :: Text -> Deck -> [Attribute action]
deckCardAttrs baseClass d =
  [ P.class_ (ms (T.strip (baseClass <> " deck-card")))
  , textProp "data-tier" (ms (dkTier d))
  ]

deckMetaEls :: Lang -> ProgressState -> [Deck] -> Deck -> [View model action]
deckMetaEls lang prog decks d =
  [ H.span_ [ P.class_ (ms ("tier-badge tier-" <> dkTier d)) ] [ text (ms (dkTier d)) ]
  , H.span_ [ P.class_ "deck-progress" ]
      [ text (ms (iDeckDone lang done total)) ]
  ]
  ++ requiresEls
  where
    (done, total) = deckDoneCount prog d
    requiresEls
      | null (dkRequires d) = []
      | otherwise =
          [ H.span_ [ P.class_ "deck-requires" ]
              [ text (ms (iRequiresLabel lang <> T.intercalate ", " (map (requireLabel decks) (dkRequires d)))) ]
          ]

requireLabel :: [Deck] -> Text -> Text
requireLabel decks slug = maybe slug dkTitle (find ((== slug) . unDeckId . dkId) decks)

--------------------------------------------------------------------------
-- Nav badge (every route) + the manual-reader-header JA-first switch.
--------------------------------------------------------------------------

-- | The visible text ("Review N") IS the accessible name -- no separate
-- @aria-label@, which would otherwise have to repeat it verbatim (WCAG
-- 2.5.3 Label in Name) rather than duplicate it awkwardly.
reviewBadgeEl :: Lang -> Int -> View model action
reviewBadgeEl lang due = H.a_
  [ P.id_ "sxc1-review-badge", P.class_ "nav-badge"
  , P.href_ (ms (renderRoute RHome))
  ]
  [ text (ms (iReviewBadge lang due)) ]

-- | M6 W2: @#btn-ui-lang@ -- the header JA\/EN UI-language toggle, on
-- EVERY route (unlike #btn-ja-first, which is a manual-reader-only
-- preference, the UI language governs the whole app). Styled through
-- the same @.nav-toggle@ system as #btn-ja-first. Its label is the
-- language it SWITCHES TO, written in that language, and carries a
-- matching @lang@ attribute for SR pronunciation ('iUiLangButton' \/
-- 'iUiLangButtonLangAttr').
uiLangHeaderEls :: ProgHandlers action -> ProgData -> [View model action]
uiLangHeaderEls ph pd =
  [ H.button_
      [ P.id_ "btn-ui-lang", P.class_ "nav-toggle"
      , textProp "lang" (ms (iUiLangButtonLangAttr (pdLang pd)))
      , E.onClick (phUiLang ph)
      ]
      [ text (ms (iUiLangButton (pdLang pd))) ]
  ]

-- | @#btn-ja-first@: present only on the manual reader's own routes (the
-- TOC and a page), never on Home\/Training -- \"the manual reader
-- header\", per the owner addendum, item 8.
jaFirstHeaderEls :: ProgHandlers action -> ProgData -> Route -> [View model action]
jaFirstHeaderEls ph pd route
  | isManualRoute route =
      [ H.button_
          [ P.id_ "btn-ja-first", P.class_ "nav-toggle"
          , textProp "aria-pressed" (if pdJaFirst pd then "true" else "false")
          , E.onClick (phJaFirst ph)
          ]
          [ text (ms ((if pdJaFirst pd then iJaFirstOn else iJaFirstOff) (pdLang pd))) ]
      ]
  | otherwise = []
  where
    isManualRoute (RManual _)   = True
    isManualRoute (RPage _ _ _) = True
    isManualRoute _             = False

--------------------------------------------------------------------------
-- The home-page progress panel: corrupt banner, continue-or-queue
-- (queue takes precedence when non-empty), streak, retired note,
-- export\/import\/wipe. Returns SIBLING elements for "View.Pages" to
-- splice after its existing manual-list markup, rather than one more
-- wrapper id the manifest never asked for.
--------------------------------------------------------------------------

-- | One dominant home-page action. The coach owns the due/continue/new
-- decision now, so Home stays calm and always opens the same short plan.
primaryTrainingView :: ProgData -> View model action
primaryTrainingView pd = H.section_ [ P.id_ "sxc1-primary-training" ]
  [ H.a_ [ P.id_ "btn-primary-training", P.class_ "primary-training-action wizard-choice wizard-yes"
         , P.href_ (ms (renderRoute RSession))
         ]
      [ H.strong_ [] [ text (ms (iTodaySessionTitle lang)) ]
      , H.span_ [ P.class_ "primary-training-card" ]
          [ text (ms (iTodaySessionSub lang)) ]
      ]
  ]
  where
    lang = pdLang pd

-- | Important persistence/corruption notices stay visible even though the
-- detailed progress controls live behind Home's red alternate-path choice.
progressHomeNotices :: ProgData -> [View model action]
progressHomeNotices pd =
  storageNoteEls (pdLang pd) (pdStorageOk pd)
  ++ corruptBannerEls (pdLang pd) (pdLoad pd) (pdRawCorrupt pd)

progressHomeView :: ProgHandlers action -> ProgData -> [View model action]
progressHomeView ph pd =
  [ H.details_ [ P.id_ "sxc1-study-details", P.class_ "home-disclosure" ]
         ( H.summary_ [] [ text (ms (iReviewProgress (pdLang pd))) ]
         : precedenceOrdered ++ streakEls ++ retiredEls
         )
     , H.details_ [ P.id_ "sxc1-progress-data", P.class_ "home-disclosure" ]
         ( H.summary_ [] [ text (ms (iProgressData (pdLang pd))) ]
         : exportImportEls ph pd
         )
     ]
  where
    dueItems = liveReviewQueue pd
    precedenceOrdered
      | null dueItems = continueEls pd ++ reviewQueueEls pd dueItems
      | otherwise      = reviewQueueEls pd dueItems ++ continueEls pd

    streakLen = psStreakLen (pdProgress pd)
    streakEls =
      [ H.p_ [ P.id_ "sxc1-streak" ]
          [ text (ms (iStudyStreak (pdLang pd) streakLen)) ]
      ]

    retiredEls
      | retiredCountLive pd > 0 =
          [ H.p_ [ P.id_ "sxc1-retired-note" ]
              [ text (ms (iRetiredNote (pdLang pd) (retiredCountLive pd))) ]
          ]
      | otherwise = []

reviewQueueEls :: ProgData -> [(Text, Rec)] -> [View model action]
reviewQueueEls pd items = [ H.section_ [ P.id_ "sxc1-review-queue" ] queueBody ]
  where
    queueBody
      | null items = H.p_ [] [ text (ms (iNothingDue (pdLang pd))) ] : nextUpEls pd
      | otherwise  = [ H.ol_ [ P.class_ "queue-list" ] (map (queueItemEl pd) items) ]

nextUpEls :: ProgData -> [View model action]
nextUpEls pd = maybe [] (\d -> [ deckPointerEl (iStartNextDeck (pdLang pd)) d ]) (nextUnstartedDeck pd)

queueItemEl :: ProgData -> (Text, Rec) -> View model action
queueItemEl pd (pid, rec) = case exerciseForPromptId (pdDecks pd) pid of
  Nothing      -> H.li_ [ P.class_ "queue-item" ] []
  Just (d, ex) -> H.li_ [ P.class_ "queue-item" ]
    [ H.a_ [ P.href_ (exerciseHref d ex) ]
        [ H.span_ [ P.class_ "queue-deck" ] [ text (ms (dkTitle d)) ]
        , H.span_ [ P.class_ "queue-ex" ] [ text (ms (exTitle ex)) ]
        , H.span_ [ P.class_ "queue-due" ] [ text (ms (dueLabel (pdLang pd) (pdToday pd) rec)) ]
        ]
    ]

dueLabel :: Lang -> DayNum -> Rec -> Text
dueLabel lang today rec
  | overdue <= 0 = iDueToday lang
  | otherwise    = iDaysOverdue lang overdue
  where overdue = unDayNum today - unDayNum (rcDue rec)

continueEls :: ProgData -> [View model action]
continueEls pd = [ H.section_ [ P.id_ "sxc1-continue" ] continueBody ]
  where
    continueBody = case mostRecentPromptId (pdProgress pd) >>= exerciseForPromptId (pdDecks pd) of
      Just (d, ex) ->
        [ H.a_ [ P.href_ (exerciseHref d ex) ]
            [ text (ms (iContinueLabel (pdLang pd) <> dkTitle d <> " \8212 " <> exTitle ex)) ]
        ]
      Nothing -> case nextUnstartedDeck pd of
        Just d  -> [ deckPointerEl (iGetStarted (pdLang pd)) d ]
        Nothing -> [ H.a_ [ P.href_ (ms (renderRoute RExercises)) ] [ text (ms (iBrowseDecks (pdLang pd))) ] ]

-- | NEW9: the explicit refused-mode notice. Renders when storage probed
-- unavailable at boot OR a later write failed (quota, revocation): the
-- trainer keeps working fully, but nothing outlives the tab, and the
-- learner deserves to know that rather than discover it tomorrow.
storageNoteEls :: Lang -> Bool -> [View model action]
storageNoteEls _    True  = []
storageNoteEls lang False =
  [ H.div_ [ P.id_ "sxc1-storage-note", P.class_ "progress-banner" ]
      [ H.strong_ [] [ text (ms (iStorageNoteStrong lang)) ]
      , text (ms (iStorageNoteBody lang))
      ]
  ]

corruptBannerEls :: Lang -> DecodeResult -> Maybe Text -> [View model action]
corruptBannerEls lang (DecodeCorrupt reason) mRaw =
  [ H.section_ [ P.id_ "sxc1-corrupt-banner", P.class_ "progress-banner" ]
      ( H.p_ []
          [ text (ms (iCorruptBanner lang reason)) ]
      : H.p_ [] [ text (ms (iCorruptCopyHint lang)) ]
      : rawEls
      )
  ]
  where
    -- M5 a11y: no <label> element exists for this readonly textarea, so
    -- aria-label carries its accessible name (localized -- ruling 3's
    -- a11y parity).
    rawEls = case mRaw of
      Just raw -> [ H.textarea_ [ P.id_ "sxc1-corrupt-raw", P.readonly_ True, textProp "aria-label" (ms (iCorruptRawAria lang)), P.value_ (ms raw) ] ]
      Nothing  -> [ H.p_ [] [ text (ms (iCorruptNoRaw lang)) ] ]
corruptBannerEls _ _ _ = []

--------------------------------------------------------------------------
-- Export / import / wipe. The wipe two-step confirm and the import
-- record-count preview are both plain DOM behaviour in
-- @site\/static\/index.js@ (see the module Haddock); this module renders
-- the structure they operate on and dispatches the two real 'Action's
-- (import commit, wipe confirm) that must go through Haskell.
--------------------------------------------------------------------------

-- | Reads @#sxc1-import-input@'s CURRENT value straight off the DOM at
-- submit time via a custom 'Decoder' -- @event.target@ for a "submit"
-- fired by a submit button IS the owning \<form\>, and a
-- \<form\>'s children with a matching @name@ are reachable as its OWN
-- named properties (a standard, load-bearing HTML feature, not a
-- miso-specific one) -- exactly how "Miso.Event.Decoder".'valueDecoder'
-- itself reads @event.target.value@ for an ordinary input, one path
-- segment shorter. This is the only way to get the pasted text into a
-- real 'Action' without inventing Model state Main.hs's update handlers
-- do not have (see the module Haddock) -- the alternative, dispatching on
-- every keystroke, would silently commit an import the instant a learner
-- finished pasting, before they had a chance to read the preview.
onImportSubmit :: (Text -> action) -> Attribute action
onImportSubmit f = onWithOptions BUBBLE preventDefault "submit" importFormDecoder toAction
  where toAction v _ = f (fromMisoString v)

importFormDecoder :: Decoder MisoString
importFormDecoder = Decoder
  { decodeAt = DecodeTarget ["target", "sxc1-import-input"]
  , decoder  = withObject "form" (.: "value")
  }

exportImportEls :: ProgHandlers action -> ProgData -> [View model action]
exportImportEls ph pd =
  [ H.section_ [ P.id_ "sxc1-progress-tools" ]
      ( [ H.h2_ [] [ text (ms (iYourProgress lang)) ]
        , H.details_ [ P.id_ "sxc1-progress-backup", P.class_ "progress-flow" ]
            [ H.summary_ [] [ text (ms (iExport lang)) ]
            , H.button_ [ P.id_ "btn-progress-export", P.type_ "button", E.onClick (phExport ph) ] [ text (ms (iExport lang)) ]
          -- M5 a11y: like #sxc1-corrupt-raw, no <label> element exists,
          -- so aria-label carries the accessible name (localized).
        , H.textarea_ [ P.id_ "sxc1-export-blob", P.readonly_ True, textProp "aria-label" (ms (iExportAria lang)), P.value_ (ms (fromMaybe "" (pdExportBlob pd))) ]
        -- M9: a deliberately empty DOM-owned shell. The file/share controls
        -- live in index.js so they add no second progress wire format and no
        -- translated string table to app.wasm; the Haskell codec still owns
        -- export generation and import commit.
            , H.div_ [ P.id_ "sxc1-progress-passport" ] []
            ]
        , H.details_ [ P.id_ "sxc1-progress-restore", P.class_ "progress-flow" ]
            [ H.summary_ [] [ text (ms (iImport lang)) ]
            , H.div_ [ P.id_ "sxc1-import-file-shell" ] []
            , H.form_ [ P.id_ "sxc1-import-form", onImportSubmit (phImport ph) ]
            ( H.label_ [ P.for_ "sxc1-import-input" ] [ text (ms (iImportLabel lang)) ]
            : H.textarea_ [ P.id_ "sxc1-import-input", P.name_ "sxc1-import-input" ]
            : H.p_ [ P.id_ "sxc1-import-preview" ]
                [ text (ms (iImportPreviewInit lang)) ]
            : H.button_ [ P.id_ "btn-progress-import", P.type_ "submit" ] [ text (ms (iImport lang)) ]
            : importMsgEls
            )
            ]
        , H.details_ [ P.id_ "sxc1-progress-reset", P.class_ "progress-flow" ]
            [ H.summary_ [] [ text (ms (iWipe lang)) ]
            , H.button_ [ P.id_ "btn-progress-wipe", P.type_ "button" ] [ text (ms (iWipe lang)) ]
        , H.button_
            [ P.id_ "btn-progress-wipe-confirm", P.type_ "button", P.hidden_ True, E.onClick (phWipe ph) ]
            [ text (ms (iWipeConfirm lang)) ]
            ]
        ]
      )
  ]
  where
    lang = pdLang pd
    importMsgEls = case pdImportMsg pd of
      Just msg -> [ H.p_ [ P.id_ "sxc1-import-error" ] [ text (ms (iImportError lang msg)) ] ]
      Nothing  -> []
