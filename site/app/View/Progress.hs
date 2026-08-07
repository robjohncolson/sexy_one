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
  , progressHomeView
  , jaFirstHeaderEls
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

import           SXC1.Exercise.Types    (Deck (..), DeckId (..), ExId (..), Exercise (..),
                                         PromptId (..), promptIdFor)
import           SXC1.Progress.Codec    (DecodeResult (..))
import           SXC1.Progress.Scheduler (reviewQueue)
import           SXC1.Progress.Types    (DayNum (..), ProgressState (..), Rec (..))
import           SXC1.Route             (Route (RDeck, RExercise, RExercises, RHome, RManual, RPage),
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
  }

data ProgData = ProgData
  { pdDecks      :: [Deck]
  , pdProgress   :: !ProgressState
  , pdToday      :: !DayNum
  , pdLoad       :: DecodeResult
  , pdJaFirst    :: !Bool
  , pdExportBlob :: Maybe Text
  , pdImportMsg  :: Maybe Text
  , pdRawCorrupt :: Maybe Text  -- ^ the undecoded blob, for the corrupt banner's own export
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

-- | The prompt with the latest 'rcLastSeen' day -- the best "most recent
-- event" proxy available from PERSISTED state: 'Rec' only carries day
-- granularity (see "SXC1.Progress.Types"), not a raw timestamp, and the
-- in-memory 'mEventLog' Main.hs keeps for the live event feed is never
-- persisted (it is empty again on every fresh page load, exactly when
-- "continue where you left off" matters most). A tie (same day) keeps
-- whichever 'Map.toList' happens to visit first -- a total, deterministic
-- order over 'Text' keys, just not a promise about WHICH same-day item
-- wins, which nothing here depends on.
mostRecentPromptId :: ProgressState -> Maybe Text
mostRecentPromptId st = case Map.toList (psRecs st) of
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

deckMetaEls :: ProgressState -> [Deck] -> Deck -> [View model action]
deckMetaEls prog decks d =
  [ H.span_ [ P.class_ (ms ("tier-badge tier-" <> dkTier d)) ] [ text (ms (dkTier d)) ]
  , H.span_ [ P.class_ "deck-progress" ]
      [ text (ms (T.pack (show done) <> "/" <> T.pack (show total) <> " done")) ]
  ]
  ++ requiresEls
  where
    (done, total) = deckDoneCount prog d
    requiresEls
      | null (dkRequires d) = []
      | otherwise =
          [ H.span_ [ P.class_ "deck-requires" ]
              [ text (ms ("Requires: " <> T.intercalate ", " (map (requireLabel decks) (dkRequires d)))) ]
          ]

requireLabel :: [Deck] -> Text -> Text
requireLabel decks slug = maybe slug dkTitle (find ((== slug) . unDeckId . dkId) decks)

--------------------------------------------------------------------------
-- Nav badge (every route) + the manual-reader-header JA-first switch.
--------------------------------------------------------------------------

-- | The visible text ("Review N") IS the accessible name -- no separate
-- @aria-label@, which would otherwise have to repeat it verbatim (WCAG
-- 2.5.3 Label in Name) rather than duplicate it awkwardly.
reviewBadgeEl :: Int -> View model action
reviewBadgeEl due = H.a_
  [ P.id_ "sxc1-review-badge", P.class_ "nav-badge"
  , P.href_ (ms (renderRoute RHome))
  ]
  [ text (ms ("Review " <> T.pack (show due))) ]

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
          [ text (if pdJaFirst pd then "Japanese first: on" else "Japanese first: off") ]
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

progressHomeView :: ProgHandlers action -> ProgData -> [View model action]
progressHomeView ph pd =
  corruptBannerEls (pdLoad pd) (pdRawCorrupt pd)
  ++ precedenceOrdered
  ++ streakEls
  ++ retiredEls
  ++ exportImportEls ph pd
  where
    dueItems = liveReviewQueue pd
    precedenceOrdered
      | null dueItems = continueEls pd ++ reviewQueueEls pd dueItems
      | otherwise      = reviewQueueEls pd dueItems ++ continueEls pd

    streakLen = psStreakLen (pdProgress pd)
    streakEls =
      [ H.p_ [ P.id_ "sxc1-streak" ]
          [ text (ms ("Study streak: " <> T.pack (show streakLen)
                        <> (if streakLen == 1 then " day" else " days"))) ]
      ]

    retiredEls
      | retiredCountLive pd > 0 =
          [ H.p_ [ P.id_ "sxc1-retired-note" ]
              [ text (ms ("Note: " <> T.pack (show (retiredCountLive pd))
                            <> " saved item(s) refer to exercises that have since been revised, "
                            <> "and are excluded from review.")) ]
          ]
      | otherwise = []

reviewQueueEls :: ProgData -> [(Text, Rec)] -> [View model action]
reviewQueueEls pd items = [ H.section_ [ P.id_ "sxc1-review-queue" ] queueBody ]
  where
    queueBody
      | null items = H.p_ [] [ "Nothing is due for review right now." ] : nextUpEls pd
      | otherwise  = [ H.ol_ [ P.class_ "queue-list" ] (map (queueItemEl pd) items) ]

nextUpEls :: ProgData -> [View model action]
nextUpEls pd = maybe [] (\d -> [ deckPointerEl "Start the next deck: " d ]) (nextUnstartedDeck pd)

queueItemEl :: ProgData -> (Text, Rec) -> View model action
queueItemEl pd (pid, rec) = case exerciseForPromptId (pdDecks pd) pid of
  Nothing      -> H.li_ [ P.class_ "queue-item" ] []
  Just (d, ex) -> H.li_ [ P.class_ "queue-item" ]
    [ H.a_ [ P.href_ (exerciseHref d ex) ]
        [ H.span_ [ P.class_ "queue-deck" ] [ text (ms (dkTitle d)) ]
        , H.span_ [ P.class_ "queue-ex" ] [ text (ms (exTitle ex)) ]
        , H.span_ [ P.class_ "queue-due" ] [ text (ms (dueLabel (pdToday pd) rec)) ]
        ]
    ]

dueLabel :: DayNum -> Rec -> Text
dueLabel today rec
  | overdue <= 0 = "due today"
  | otherwise    = T.pack (show overdue) <> " day(s) overdue"
  where overdue = unDayNum today - unDayNum (rcDue rec)

continueEls :: ProgData -> [View model action]
continueEls pd = [ H.section_ [ P.id_ "sxc1-continue" ] continueBody ]
  where
    continueBody = case mostRecentPromptId (pdProgress pd) >>= exerciseForPromptId (pdDecks pd) of
      Just (d, ex) ->
        [ H.a_ [ P.href_ (exerciseHref d ex) ]
            [ text (ms ("Continue: " <> dkTitle d <> " \8212 " <> exTitle ex)) ]
        ]
      Nothing -> case nextUnstartedDeck pd of
        Just d  -> [ deckPointerEl "Get started: " d ]
        Nothing -> [ H.a_ [ P.href_ (ms (renderRoute RExercises)) ] [ "Browse the training decks" ] ]

corruptBannerEls :: DecodeResult -> Maybe Text -> [View model action]
corruptBannerEls (DecodeCorrupt reason) mRaw =
  [ H.section_ [ P.id_ "sxc1-corrupt-banner", P.class_ "progress-banner" ]
      ( H.p_ []
          [ text (ms ("Your saved progress could not be read (" <> reason
                        <> "). It has NOT been deleted.")) ]
      : H.p_ [] [ "Copy the raw text below to keep it safe, or use Export/Wipe further down." ]
      : rawEls
      )
  ]
  where
    rawEls = case mRaw of
      Just raw -> [ H.textarea_ [ P.id_ "sxc1-corrupt-raw", P.readonly_ True, P.value_ (ms raw) ] ]
      Nothing  -> [ H.p_ [] [ "(No raw data could be read either.)" ] ]
corruptBannerEls _ _ = []

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
      ( [ H.h2_ [] [ "Your saved progress" ]
        , H.button_ [ P.id_ "btn-progress-export", P.type_ "button", E.onClick (phExport ph) ] [ "Export" ]
        , H.textarea_ [ P.id_ "sxc1-export-blob", P.readonly_ True, P.value_ (ms (fromMaybe "" (pdExportBlob pd))) ]
        , H.form_ [ P.id_ "sxc1-import-form", onImportSubmit (phImport ph) ]
            ( H.label_ [ P.for_ "sxc1-import-input" ] [ "Paste an exported blob to import:" ]
            : H.textarea_ [ P.id_ "sxc1-import-input", P.name_ "sxc1-import-input" ]
            : H.p_ [ P.id_ "sxc1-import-preview" ]
                [ "Paste text above to see how many records it contains." ]
            : H.button_ [ P.id_ "btn-progress-import", P.type_ "submit" ] [ "Import" ]
            : importMsgEls
            )
        , H.button_ [ P.id_ "btn-progress-wipe", P.type_ "button" ] [ "Wipe all progress" ]
        , H.button_
            [ P.id_ "btn-progress-wipe-confirm", P.type_ "button", P.hidden_ True, E.onClick (phWipe ph) ]
            [ "Yes, permanently wipe my progress" ]
        ]
      )
  ]
  where
    importMsgEls = case pdImportMsg pd of
      Just msg -> [ H.p_ [ P.id_ "sxc1-import-error" ] [ text (ms ("Import could not be read: " <> msg)) ] ]
      Nothing  -> []
