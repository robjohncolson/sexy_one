{-# LANGUAGE OverloadedStrings #-}

-- | The three exercise screens ("#/x", "#/x/\<deck\>", "#/x/\<deck\>/\<ex\>"),
-- per the DOM\/CSS contract in briefs\/M2-manifest.json (task
-- "exercise-ui"). All prose renders through M1's "View.Blocks" -- no
-- exercise text and no chapter title is ever constructed here; every
-- string comes from a parsed 'Deck'\/'Exercise' or is plain UI chrome
-- (button labels), exactly the discipline "View.Pages" already follows
-- for the manual reader.
--
-- Kept POLYMORPHIC over @action@, matching "View.Pages"'s existing
-- style (it already threads one bare @action@ value for the JA
-- toggle): the runner needs many action-producing callbacks (toggle an
-- option, submit, confirm a step, ...), bundled here as 'ExHandlers' so
-- this module never needs to know Main's concrete 'Action' type (which
-- would create a module cycle: Main -> View.Pages -> View.Exercise).
module View.Exercise
  ( ExHandlers (..)
  , viewExerciseIndex
  , viewDeck
  , viewExerciseRunner
  , formatElapsed
  ) where

import           Data.List              (find)
import qualified Data.IntMap.Strict     as IntMap
import qualified Data.IntSet            as IntSet
import qualified Data.Text              as T
import           Data.Text              (Text)

import           Miso
import           Miso.Html.Element      as H
import           Miso.Html.Event        as E
import           Miso.Html.Property     as P

import           SXC1.Exercise.Engine   (ExerciseState (..), Outcome (..), Response (..))
import           SXC1.Exercise.Types
import           SXC1.Progress.Types    (ProgressState)
import           SXC1.Route             (Route (..), renderRoute)

import qualified View.Blocks            as Blocks
import qualified View.Progress          as Progress

--------------------------------------------------------------------------
-- Action bundle for the runner. Every field takes whatever the DOM
-- event itself carries (a prompt index, an option id, raw input text)
-- and returns an @action@ -- Main.hs closes over the current 'ExId' and
-- its own 'Action' constructors when building one of these.
--------------------------------------------------------------------------

data ExHandlers action = ExHandlers
  { exOnToggle     :: Int -> Text -> action
  , exOnSubmit     :: Int -> action
  , exOnReveal     :: Int -> action
  , exOnGot        :: Int -> action
  , exOnMissed     :: Int -> action
  , exOnConfirm    :: Int -> action
  , exOnFindInput  :: Int -> MisoString -> action
  , exOnFindSubmit :: Int -> action
  , exOnShowHint   :: Int -> action
  , exOnNext       :: action
  , exOnRestart    :: action
  }

--------------------------------------------------------------------------
-- Small pure helpers shared by all three screens.
--------------------------------------------------------------------------

unDeckId :: DeckId -> Text
unDeckId (DeckId t) = t

unExId :: ExId -> Text
unExId (ExId t) = t

findDeckBySlug :: [Deck] -> Text -> Maybe Deck
findDeckBySlug decks slug = find ((== slug) . unDeckId . dkId) decks

findExerciseBySlug :: Deck -> Text -> Maybe Exercise
findExerciseBySlug d slug = find ((== slug) . unExId . exId) (dkExercises d)

safeIndex :: [a] -> Int -> Maybe a
safeIndex xs i
  | i < 0     = Nothing
  | otherwise = case drop i xs of { (x : _) -> Just x; [] -> Nothing }

-- | First-seen order, deduplicated -- used to group decks by chapter in
-- the order chapters first appear in the corpus (itself
-- content\/exercises\/INDEX order), never a hard-coded chapter list.
uniqueInOrder :: Eq a => [a] -> [a]
uniqueInOrder = reverse . foldl' step []
  where
    step seen x = if x `elem` seen then seen else x : seen

kindClass :: Kind -> Text
kindClass KQuiz   = "quiz"
kindClass KDrill  = "drill"
kindClass KLookup = "lookup"

kindLabel :: Kind -> Text
kindLabel KQuiz   = "Quiz"
kindLabel KDrill  = "Drill"
kindLabel KLookup = "Lookup"

-- | Milliseconds -> "M:SS" (matches the DOM contract's
-- @^[0-9]+:[0-9][0-9]$@ for @#ex-elapsed@).
formatElapsed :: Int -> Text
formatElapsed millis =
  T.pack (show m) <> ":" <> pad2 s
  where
    totalSec = max 0 millis `div` 1000
    m = totalSec `div` 60
    s = totalSec `mod` 60
    pad2 n = let t = T.pack (show n) in if T.length t < 2 then "0" <> t else t

exerciseNotFound :: Text -> View model action
exerciseNotFound label = H.section_ [ P.id_ "sxc1-not-found" ]
  [ H.h1_ [] [ "Not found" ]
  , H.p_ [] [ text (ms ("No exercise matches: " <> label)) ]
  , H.a_ [ P.class_ "manual-card", P.href_ (ms (renderRoute RExercises)) ] [ "Back to Training" ]
  ]

--------------------------------------------------------------------------
-- "#/x": the exercise index, grouped by chapter.
--------------------------------------------------------------------------

-- | Groups decks by chapter (course order: 'uniqueInOrder' over
-- 'dkChapter', itself INDEX order -- never a hard-coded chapter list, so
-- this scales unchanged from today's 4 decks to the full 52).
-- Chapters render as \<details\> (native, no JS, keyboard-operable
-- disclosure) rather than a flat wall of decks -- the manifest's mobile
-- guardrail for 52 decks across 6 chapters. 'Progress.deckCardAttrs'
-- folds a stable @.deck-card[data-tier]@ hook onto the SAME element that
-- already carries @.ex-deck-card@ (one @class_@, not two -- see that
-- function's Haddock), so the M2 DOM contract (@.ex-deck-card@) and the
-- M3 one (@.deck-card@) are the same element, not a duplicated list.
viewExerciseIndex :: ProgressState -> [Deck] -> View model action
viewExerciseIndex prog decks = H.section_ [ P.id_ "sxc1-exercise-index" ] (map renderChapter chapters)
  where
    chapterOrder = uniqueInOrder (map dkChapter decks)
    chapters = [ (ch, [ d | d <- decks, dkChapter d == ch ]) | ch <- chapterOrder ]

    -- | Open by default while the course is still small enough that
    -- collapsing costs more taps than it saves (today's 4 decks); once
    -- the corpus grows toward the full 52 this flips to closed
    -- automatically, no per-task change needed.
    startOpen = length decks <= 8

    renderChapter (chTitle, ds) = H.details_ [ P.class_ "ex-chapter", P.open_ startOpen ]
      [ H.summary_ [ P.class_ "ex-chapter-title" ]
          [ text (ms chTitle), chapterProgressEl ds ]
      , H.ul_ [ P.class_ "ex-deck-list" ] (map renderDeckCard ds)
      ]

    chapterProgressEl ds =
      let (done, total) = Progress.chapterDoneCount prog ds
      in H.span_ [ P.class_ "chapter-progress" ]
           [ text (ms (T.pack (show done) <> "/" <> T.pack (show total))) ]

    renderDeckCard d = H.li_ []
      [ H.a_ ( P.href_ (ms (renderRoute (RDeck (unDeckId (dkId d))))) : Progress.deckCardAttrs "ex-deck-card" d )
          ( H.span_ [ P.class_ "ex-deck-title" ] [ text (ms (dkTitle d)) ]
          : H.span_ [ P.class_ "ex-deck-count" ]
              [ text (ms (T.pack (show (length (dkExercises d))) <> " exercises")) ]
          : Progress.deckMetaEls prog decks d
          )
      ]

--------------------------------------------------------------------------
-- "#/x/<deck>": the ordered exercise list.
--------------------------------------------------------------------------

viewDeck :: ProgressState -> [Deck] -> Text -> View model action
viewDeck prog decks slug = case findDeckBySlug decks slug of
  Nothing -> exerciseNotFound slug
  Just d  -> H.section_ [ P.id_ "sxc1-deck" ]
    [ H.h1_ [ P.id_ "ex-deck-title" ] [ text (ms (dkTitle d)) ]
    , H.p_ [ P.id_ "ex-deck-summary" ] (Blocks.renderInlines "" (dkSummary d))
    , H.div_ (Progress.deckCardAttrs "" d) (Progress.deckMetaEls prog decks d)
    , H.ol_ [ P.class_ "ex-list" ] (map (renderExLink d) (dkExercises d))
    ]
  where
    renderExLink d ex = H.li_ []
      [ H.a_ [ P.class_ "ex-link"
             , P.href_ (ms (renderRoute (RExercise (unDeckId (dkId d)) (unExId (exId ex)))))
             ]
          [ H.span_ [ P.class_ (ms ("ex-kind kind-" <> kindClass (exKind ex))) ] [ text (ms (kindLabel (exKind ex))) ]
          , H.span_ [ P.class_ "ex-title" ] [ text (ms (exTitle ex)) ]
          ]
      ]

--------------------------------------------------------------------------
-- "#/x/<deck>/<ex>": the runner.
--------------------------------------------------------------------------

-- | @mResult@ is the CURRENT prompt's last graded outcome (from
-- "SXC1.Exercise.Engine"'s own 'SXC1.Exercise.Engine.ProgressEvent's --
-- see Main.hs), so correctness is never re-derived here; only rendered.
viewExerciseRunner
  :: ExHandlers action
  -> [Deck] -> Text -> Text
  -> ExerciseState
  -> Maybe (Outcome, Int)
  -> View model action
viewExerciseRunner h decks deckSlug exSlug st mResult =
  case findDeckBySlug decks deckSlug of
    Nothing -> exerciseNotFound (deckSlug <> "/" <> exSlug)
    Just d -> case findExerciseBySlug d exSlug of
      Nothing -> exerciseNotFound (deckSlug <> "/" <> exSlug)
      Just ex -> renderRunner ex

  where
    renderRunner ex = H.article_ [ P.id_ "sxc1-exercise", P.class_ (ms ("exercise kind-" <> kindClass (exKind ex))) ]
      ( [ H.h1_ [ P.id_ "ex-title" ] [ text (ms (exTitle ex)) ]
        , H.p_ [ P.id_ "ex-progress" ] [ text (ms progressText) ]
        , H.div_ [ P.id_ "ex-stem" ] (Blocks.renderBlocks "" (exIntro ex))
        ]
        ++ bodyEls ex
        ++ hintsEl ex
        ++ [ H.button_ [ P.id_ "btn-ex-restart", E.onClick (exOnRestart h) ] [ "Restart" ] ]
        ++ summaryEl
      )
      where
        n = length (exPrompts ex)
        cursor = esCursor st
        displayedCursor = min (cursor + 1) (max n 1)
        progressText = T.pack (show displayedCursor) <> " / " <> T.pack (show n)

        mAttempted = case mResult of { Just _ -> True; Nothing -> False }

        -- H8: a drill's step list (with each confirmed step's own
        -- citations -- see 'drillStepsEl') stays visible even once the
        -- WHOLE drill is done, unlike quiz/lookup (which hide their
        -- single prompt once 'esDone'): a completed drill is the one
        -- kind whose in-progress view already doubles as its own log of
        -- what was done, and hiding it at completion is exactly what
        -- made a finished drill's citations unreachable (H8 gate
        -- finding: "still 0 after all three steps are confirmed").
        bodyEls ex'
          | exKind ex' == KDrill = [ drillStepsEl ex' ]
          | esDone st            = []
          | otherwise            = case safeIndex (exPrompts ex') cursor of
              Nothing -> []
              Just prompt -> kindBodyEl cursor prompt ++ sharedFeedbackEls

        kindBodyEl i prompt = case prBody prompt of
          Choice opts ->
            [ H.ul_ [ P.id_ "ex-options" ] (map (renderOption i) opts)
            , H.button_ [ P.id_ "btn-ex-submit", E.onClick (exOnSubmit h i) ] [ "Submit" ]
            ]
          Recall answerBlocks ->
            if IntSet.member i (esRevealed st)
              then [ H.div_ [ P.id_ "ex-answer" ] (Blocks.renderBlocks "" answerBlocks)
                   , H.button_ [ P.id_ "btn-ex-got", E.onClick (exOnGot h i) ] [ "I got it" ]
                   , H.button_ [ P.id_ "btn-ex-missed", E.onClick (exOnMissed h i) ] [ "I missed it" ]
                   ]
              else [ H.button_ [ P.id_ "btn-ex-reveal", E.onClick (exOnReveal h i) ] [ "Reveal answer" ] ]
          -- M6: 'prStem' here is LITERALLY 'exIntro' (both are the same
          -- 'exIntroBlocks' value out of "SXC1.Exercise.Parse" -- a
          -- lookup has exactly one 'Prompt' and no separate task text of
          -- its own), so re-rendering it a second time under
          -- @#ex-find-task@ duplicated @#ex-stem@'s own text verbatim,
          -- AND did so by handing block-level content (which can include
          -- a @\<p\>@ of its own) to an outer @\<p\>@ -- invalid nesting.
          -- Fixed by making @#ex-find-task@ (id kept, per the gate
          -- finding) a plain, non-block wrapper around the genuinely
          -- distinct content this screen actually adds: the page-number
          -- input and its label.
          FindPage _target _limit ->
            [ H.div_ [ P.id_ "ex-find-task" ]
                [ H.label_ [ textProp "for" "ex-find-input" ] [ "Page number:" ]
                , H.input_ [ P.id_ "ex-find-input", P.type_ "number", textProp "inputmode" "numeric"
                           , E.onInput (exOnFindInput h i)
                           ]
                , H.button_ [ P.id_ "btn-ex-find-submit", E.onClick (exOnFindSubmit h i) ] [ "Submit" ]
                ]
            ] ++ elapsedEl
          Confirm _ _ -> []  -- drills never reach here; see drillStepsEl

          where
            selected = case IntMap.lookup i (esResponses st) of { Just (RChosen sel) -> sel; _ -> [] }
            renderOption idx o = H.li_ []
              [ H.button_
                  [ P.id_ (ms ("opt-" <> optId o))
                  , P.class_ "ex-option"
                  , textProp "aria-pressed" (if optId o `elem` selected then "true" else "false")
                  , E.onClick (exOnToggle h idx (optId o))
                  ]
                  (Blocks.renderInlines "" (optLabel o))
              ]
            elapsedEl = case mResult of
              Just (_, elapsedMs) -> [ H.p_ [ P.id_ "ex-elapsed" ] [ text (ms (formatElapsed elapsedMs)) ] ]
              Nothing              -> []

        -- H8: a lookup's own citation is the @find:@ TARGET
        -- ('fpTarget', embedded in its one prompt's 'PromptBody'), never
        -- 'exCites' (which a lookup's optional @cite:@ field -- often
        -- absent -- populates instead), so 'exCites' alone left a
        -- lookup's @#ex-cites@ empty even after a correct answer. Folded
        -- into the SAME list 'exCites' already renders through (keeping
        -- one @#ex-cites@ container, per the gate finding), gated by the
        -- SAME 'mAttempted' every other post-grading element already
        -- uses -- AFTER GRADING ONLY, since the id under @#/m/<slug>/p/<n>@
        -- would otherwise hand the learner the answer before they submit.
        citesForFeedback = exCites ex ++
          [ t | Just p <- [safeIndex (exPrompts ex) cursor], FindPage t _ <- [prBody p] ]

        sharedFeedbackEls =
          feedbackEl
            ++ [ H.div_ [ P.id_ "ex-note" ] (Blocks.renderBlocks "" (exNote ex)) | mAttempted, not (null (exNote ex)) ]
            ++ [ H.ul_ [ P.id_ "ex-cites" ] (map renderCite citesForFeedback) | mAttempted, not (null citesForFeedback) ]
            ++ [ H.button_ [ P.id_ "btn-ex-next", E.onClick (exOnNext h) ] [ "Next" ] | mAttempted ]

        feedbackEl = case mResult of
          Nothing -> []
          Just (outcome, _) ->
            let isCorrect = outcome == Correct
            in [ H.p_ [ P.id_ "ex-feedback", P.class_ (if isCorrect then "correct" else "incorrect")
                      , textProp "role" "status"
                      ]
                   [ text (if isCorrect then "Correct." else "Not quite. Try again.") ]
               ]

        renderCite c = H.li_ []
          [ H.a_ [ P.class_ "cite", P.href_ (ms (renderRoute (RPage (citSlug c) (citPage c) False))) ]
              [ text (ms (citSlug c <> " p. " <> T.pack (show (citPage c)))) ]
          ]

        drillStepsEl ex' = H.ol_ [ P.id_ "ex-steps" ] (zipWith renderStep [1 ..] (exPrompts ex'))
          where
            renderStep stepN prompt = H.li_ [ P.class_ "ex-step", P.id_ (ms ("ex-step-" <> T.pack (show stepN))) ]
              ( H.div_ [ P.class_ "ex-step-instruction" ] (Blocks.renderBlocks "" (prStem prompt))
                : case prBody prompt of
                    Confirm checkInlines mVerify ->
                      [ H.p_ [ P.class_ "ex-step-check", P.id_ (ms ("ex-step-" <> T.pack (show stepN) <> "-check")) ]
                          (Blocks.renderInlines "" checkInlines)
                      ]
                      ++ verifyEl stepN mVerify
                      ++ citesEl stepN (stepN - 1) prompt
                      ++ confirmEl (stepN - 1)
                    _ -> []
              )

            -- H8: a drill's own citations live per-step, in each
            -- 'Prompt''s 'prCites' -- 'sharedFeedbackEls' (the only
            -- citation renderer before this fix) is never reached by a
            -- drill body at all. Rendered AT\/AFTER CONFIRMATION (once
            -- the cursor has moved past this step -- confirming a step
            -- and advancing past it are one undivided action from the
            -- learner's perspective, see Main.hs's 'exOnConfirm'), never
            -- before, and NOT under the shared @#ex-cites@ id (which is
            -- unique per page and already spoken for by the quiz\/lookup
            -- path): a drill can confirm several steps, each with its
            -- own citation, so each gets its own per-step, class-based
            -- list instead. Keeps the same @<a class="cite" ...>@ anchor
            -- contract via 'renderCite'.
            citesEl stepN idx0 prompt
              | idx0 < esCursor st, not (null (prCites prompt)) =
                  [ H.ul_ [ P.class_ "ex-step-cites", P.id_ (ms ("ex-step-" <> T.pack (show stepN) <> "-cites")) ]
                      (map renderCite (prCites prompt))
                  ]
              | otherwise = []

            verifyEl _stepN Nothing = []
            verifyEl stepN (Just _v) =
              [ H.p_ [ P.class_ "ex-verify", P.id_ (ms ("ex-step-" <> T.pack (show stepN) <> "-verify")) ]
                  [ "Automatic device confirmation arrives with WebMIDI support in a future update; "
                  , "confirm manually for now."
                  ]
              ]

            confirmEl idx0
              | idx0 == esCursor st =
                  [ H.button_
                      [ P.class_ "btn-ex-confirm", P.id_ (ms ("btn-ex-confirm-" <> T.pack (show (idx0 + 1))))
                      , E.onClick (exOnConfirm h idx0)
                      ]
                      [ "Confirm" ]
                  ]
              | otherwise = []

        hintsEl ex'
          | null (exHints ex') = []
          | otherwise =
              [ H.button_ [ P.id_ "btn-ex-hint", E.onClick (exOnShowHint h cursor) ] [ "Show a hint" ]
              | shownCount < length (exHints ex')
              ]
              ++ [ H.ul_ [ P.id_ "ex-hints" ]
                     [ H.li_ [ P.class_ "ex-hint" ] (Blocks.renderBlocks "" hb) | hb <- take shownCount (exHints ex') ]
                 | shownCount > 0
                 ]
          where shownCount = IntMap.findWithDefault 0 cursor (esHints st)

        summaryEl
          | esDone st = [ H.section_ [ P.id_ "ex-summary" ] [ H.p_ [] [ "You've completed this exercise." ] ] ]
          | otherwise = []
