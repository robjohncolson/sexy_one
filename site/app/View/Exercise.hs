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
  , DevView (..)
  , viewExerciseIndex
  , viewDeck
  , viewExerciseRunner
  , formatElapsed
  ) where

import           Data.List              (find)
import qualified Data.IntMap.Strict     as IntMap
import qualified Data.Text              as T
import           Data.Text              (Text)
import           Data.Maybe             (listToMaybe)

import           Miso
import           Miso.Html.Element      as H
import           Miso.Html.Event        as E
import           Miso.Html.Property     as P

import           Device.Midi            (DeviceStatus (..), HubSnapshot (..))
import           I18n
import           SXC1.Exercise.Engine   (ConfirmSource (..), ExerciseState (..), Outcome (..), Response (..), ReviewGrade (..))
import           SXC1.Exercise.Types
import           SXC1.Progress.Types    (ProgressState)
import           SXC1.Route             (Route (..), parseDigits, renderRoute)

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
  , exOnCheck      :: Int -> Bool -> action
  , exOnRate       :: Int -> ReviewGrade -> action
  , exOnConfirm    :: Int -> action
  , exOnSkip       :: Int -> action
  , exOnFindInput  :: Int -> MisoString -> action
  , exOnFindSubmit :: Int -> action
  , exOnShowHint   :: Int -> action
  , exOnNext       :: action
  , exOnRestart    :: action
    -- M4 (task "device-app"): the device panel's controls.
  , exOnDevEnable  :: action
  , exOnDevChannel :: Int -> action
  }

--------------------------------------------------------------------------
-- M4: everything the runner renders the device panel and the per-step
-- verify lines from -- a pure snapshot assembled by Main (see
-- Main.devViewFor); this module decides nothing about MIDI itself.
--------------------------------------------------------------------------

data DevView = DevView
  { dvwSupported :: !Bool            -- ^ boot-time Web MIDI feature-detect result
  , dvwSnap      :: !HubSnapshot     -- ^ the hub mirror (status\/channel\/ports\/last message)
  , dvwWatching  :: Maybe Text       -- ^ the armed watch's promptId text, if any
  }

--------------------------------------------------------------------------
-- Small pure helpers shared by all three screens.
--------------------------------------------------------------------------

unDeckId :: DeckId -> Text
unDeckId (DeckId t) = t

unExId :: ExId -> Text
unExId (ExId t) = t

unPromptId' :: PromptId -> Text
unPromptId' (PromptId t) = t

tshow :: Int -> Text
tshow = T.pack . show

findDeckBySlug :: [Deck] -> Text -> Maybe Deck
findDeckBySlug decks slug = find ((== slug) . unDeckId . dkId) decks

findExerciseBySlug :: Deck -> Text -> Maybe Exercise
findExerciseBySlug d slug = find ((== slug) . unExId . exId) (dkExercises d)

-- | The next card in the authored course order, crossing deck boundaries
-- transparently. The learner should not have to return to a deck index
-- after every completed exercise.
nextExerciseAfter :: [Deck] -> ExId -> Maybe (Deck, Exercise)
nextExerciseAfter decks current = case dropWhile ((/= current) . exId . snd) ordered of
  _current : next : _ -> Just next
  _                   -> Nothing
  where ordered = [ (d, ex) | d <- decks, ex <- dkExercises d ]

-- | Cards tagged @visual-source@ carry the first cited manual page directly
-- beside the prompt. This is for questions whose callout number, physical
-- location or screen wording is meaningless without its source diagram.
sourceFigureEls :: Lang -> Deck -> Exercise -> [View model action]
sourceFigureEls lang d ex
  | "visual-source" `notElem` (dkTags d ++ exTags ex) = []
  | otherwise = case listToMaybe (exCites ex ++ dkCites d) of
      Nothing -> []
      Just c  ->
        [ H.figure_
            [ P.id_ "ex-source-figure"
            , P.class_ (ms ("exercise-source-figure figure-" <> citSlug c <> "-" <> tshow (citPage c)))
            ]
            [ H.a_
                [ P.class_ "exercise-source-frame"
                , P.href_ (ms (renderRoute (RPage (citSlug c) (citPage c) False)))
                ]
                [ H.img_
                    [ P.id_ "ex-source-image"
                    , P.src_ (ms ("./pages/" <> citSlug c <> "/page-" <> zeroPad2 (citPage c) <> ".webp"))
                    , P.alt_ (ms (iExerciseFigureAlt lang (exTitle ex)))
                    , textProp "decoding" "async"
                    , textProp "loading" "eager"
                    ]
                ]
            , H.figcaption_ []
                [ H.a_
                    [ P.class_ "exercise-source-caption"
                    , P.href_ (ms (renderRoute (RPage (citSlug c) (citPage c) False)))
                    ]
                    [ text (ms (iExerciseFigureCaption lang (citSlug c) (citPage c))) ]
                ]
            ]
        ]
  where
    zeroPad2 n | n < 10    = "0" <> tshow n
               | otherwise = tshow n

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

kindLabel :: Lang -> Kind -> Text
kindLabel lang k = iKindLabel lang (kindClass k)

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

exerciseNotFound :: Lang -> Text -> View model action
exerciseNotFound lang label = H.section_ [ P.id_ "sxc1-not-found" ]
  [ H.h1_ [] [ text (ms (iExNotFoundTitle lang)) ]
  , H.p_ [] [ text (ms (iNoExerciseMatches lang label)) ]
  , H.a_ [ P.class_ "manual-card", P.href_ (ms (renderRoute RExercises)) ] [ text (ms (iBackToTraining lang)) ]
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
viewExerciseIndex :: Lang -> ProgressState -> [Deck] -> View model action
viewExerciseIndex lang prog decks = H.section_ [ P.id_ "sxc1-exercise-index" ] (sessionLink : weeklyLink : masteryLink : map renderChapter chapters)
  where
    chapterOrder = uniqueInOrder (map dkChapter decks)
    chapters = [ (ch, [ d | d <- decks, dkChapter d == ch ]) | ch <- chapterOrder ]

    -- | Open by default while the course is still small enough that
    -- collapsing costs more taps than it saves (today's 4 decks); once
    -- the corpus grows toward the full 52 this flips to closed
    -- automatically, no per-task change needed.
    startOpen = length decks <= 8

    sessionLink = H.a_
      [ P.id_ "exercise-session-link", P.class_ "ex-deck-card session-index-card"
      , P.href_ (ms (renderRoute RSession)) ]
      [ H.span_ [ P.class_ "ex-deck-title" ] [ text (ms (iTodaySessionTitle lang)) ]
      , H.span_ [ P.class_ "ex-deck-count" ] [ text (ms (iTodaySessionSub lang)) ]
      ]

    masteryLink = H.a_
      [ P.id_ "exercise-mastery-link", P.class_ "ex-deck-card mastery-index-card"
      , P.href_ (ms (renderRoute RMastery)) ]
      [ H.span_ [ P.class_ "ex-deck-title" ] [ text (ms (iMasteryTitle lang)) ]
      , H.span_ [ P.class_ "ex-deck-count" ] [ text (ms (iMasteryCardSub lang)) ]
      ]

    weeklyLink = H.a_
      [ P.id_ "exercise-weekly-link", P.class_ "ex-deck-card weekly-index-card"
      , P.href_ (ms (renderRoute RWeekly)) ]
      [ H.span_ [ P.class_ "ex-deck-title" ] [ text (ms (iWeeklyTitle lang)) ]
      , H.span_ [ P.class_ "ex-deck-count" ] [ text (ms (iWeeklyCardSub lang)) ]
      ]

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
              [ text (ms (iNExercises lang (length (dkExercises d)))) ]
          : Progress.deckMetaEls lang prog decks d
          )
      ]

--------------------------------------------------------------------------
-- "#/x/<deck>": the ordered exercise list.
--------------------------------------------------------------------------

viewDeck :: Lang -> ProgressState -> [Deck] -> Text -> View model action
viewDeck lang prog decks slug = case findDeckBySlug decks slug of
  Nothing -> exerciseNotFound lang slug
  Just d  -> H.section_ [ P.id_ "sxc1-deck" ]
    [ H.h1_ [ P.id_ "ex-deck-title" ] [ text (ms (dkTitle d)) ]
    , H.p_ [ P.id_ "ex-deck-summary" ] (Blocks.renderInlines "" (dkSummary d))
    , H.div_ (Progress.deckCardAttrs "" d) (Progress.deckMetaEls lang prog decks d)
    , H.ol_ [ P.class_ "ex-list" ] (map (renderExLink d) (dkExercises d))
    ]
  where
    renderExLink d ex = H.li_ []
      [ H.a_ [ P.class_ "ex-link"
             , P.href_ (ms (renderRoute (RExercise (unDeckId (dkId d)) (unExId (exId ex)))))
             ]
          [ H.span_ [ P.class_ (ms ("ex-kind kind-" <> kindClass (exKind ex))) ] [ text (ms (kindLabel lang (exKind ex))) ]
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
  :: Lang
  -> ExHandlers action
  -> DevView
  -> [Deck] -> Text -> Text
  -> ExerciseState
  -> Maybe (Outcome, Int)
  -> View model action
viewExerciseRunner lang h dv decks deckSlug exSlug st mResult =
  case findDeckBySlug decks deckSlug of
    Nothing -> exerciseNotFound lang (deckSlug <> "/" <> exSlug)
    Just d -> case findExerciseBySlug d exSlug of
      Nothing -> exerciseNotFound lang (deckSlug <> "/" <> exSlug)
      Just ex -> renderRunner d ex

  where
    renderRunner d ex = H.article_
      [ P.id_ "sxc1-exercise"
      , P.class_ (ms ("exercise kind-" <> kindClass (exKind ex)))
      ]
      -- M5 a11y: @tabindex="-1"@ makes the title a programmatic focus
      -- target -- Main.hs's advance-focus wiring lands here when a
      -- quiz\/lookup prompt advances (see Main.advanceFocusTarget), so
      -- keyboard\/SR focus is never dropped to \<body\> when the button
      -- that had focus (e.g. #btn-ex-next) disappears with the old prompt.
      ( [ H.h1_ [ P.id_ "ex-title", textProp "tabindex" "-1" ] [ text (ms (exTitle ex)) ]
        , H.p_ [ P.id_ "ex-progress" ] [ text (ms progressText) ]
        ]
        ++ sourceFigureEls lang d ex
        ++ [ H.div_ [ P.id_ "ex-stem" ] (Blocks.renderBlocks "" (exIntro ex)) ]
        ++ devicePanelEl ex
        ++ bodyEls ex
        ++ hintsEl ex
        ++ [ H.button_ [ P.id_ "btn-ex-restart", P.class_ "wizard-no", E.onClick (exOnRestart h) ]
               [ text (ms (iRestart lang)) ]
           | showRunnerRestart ex
           ]
        ++ summaryEl
      )
      where
        n = length (exPrompts ex)
        cursor = esCursor st
        displayedCursor = min (cursor + 1) (max n 1)
        progressText = T.pack (show displayedCursor) <> " / " <> T.pack (show n)

        mEvaluation = IntMap.lookup cursor (esEvaluated st)
        renderedResult = case mEvaluation of
          Just outcome -> Just (outcome, 0)
          Nothing      -> mResult
        mAttempted = case renderedResult of { Just _ -> True; Nothing -> False }

        -- Legacy Recall owns one persistent two-button control below. Live
        -- M11 content has zero Recall prompts, but old fixtures remain
        -- readable. Rendering another runner-level Restart would both make
        -- a third choice and force a second button pair after grading.
        showRunnerRestart ex' = not (esDone st) && case safeIndex (exPrompts ex') cursor of
          Just prompt -> case prBody prompt of
            Recall _ -> False
            Choice _ -> False
            _        -> True
          Nothing -> True

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
              Just prompt -> case prBody prompt of
                Recall _ -> kindBodyEl cursor prompt
                Choice _ -> kindBodyEl cursor prompt
                _        -> kindBodyEl cursor prompt ++ sharedFeedbackEls True

        kindBodyEl i prompt = case prBody prompt of
          Choice opts ->
            [ H.fieldset_ [ P.id_ "ex-options", P.class_ (if evaluated then "is-evaluated" else "") ]
                (H.legend_ [] [ text (ms (iCheckAnswer lang)) ] : map (renderOption i opts evaluated) opts)
            ]
            ++ if evaluated
                 then sharedFeedbackEls False ++ gradeActions i evaluation
                 else
                   [ H.div_ [ P.id_ "ex-choice-actions", P.class_ "wizard-actions" ]
                       [ H.button_ ([ P.id_ "btn-ex-submit", P.class_ "wizard-choice wizard-yes"
                                    , E.onClick (exOnCheck h i False)
                                    ] ++ [P.disabled_ | null selected])
                           [ text (ms (iCheckAnswer lang)) ]
                       , H.button_ [ P.id_ "btn-ex-unsure", P.class_ "wizard-choice wizard-no"
                                   , E.onClick (exOnCheck h i True)
                                   ] [ text (ms (iNotSure lang)) ]
                       ]
                   ]
            where
              evaluation = IntMap.lookup i (esEvaluated st)
              evaluated = case evaluation of { Just _ -> True; Nothing -> False }
              selected = case IntMap.lookup i (esResponses st) of { Just (RChosen sel) -> sel; _ -> [] }
          -- A current bundle can never reach this branch: all 128 Answer
          -- cards carry distractors and the bundle fingerprint is checked
          -- before parsing. Keep the constructor total for old checker
          -- fixtures without linking the retired self-grade UI into app.wasm.
          Recall _ -> []
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
                [ H.label_ [ textProp "for" "ex-find-input" ] [ text (ms (iPageNumberLabel lang)) ]
                , H.input_ [ P.id_ "ex-find-input", P.type_ "number", textProp "inputmode" "numeric"
                           , E.onInput (exOnFindInput h i)
                           ]
                , H.button_ [ P.id_ "btn-ex-find-submit", E.onClick (exOnFindSubmit h i) ] [ text (ms (iSubmit lang)) ]
                ]
            ] ++ elapsedEl
          Confirm _ _ -> []  -- drills never reach here; see drillStepsEl

          where
            renderOption idx allOpts evaluated o =
              let selected = case IntMap.lookup idx (esResponses st) of { Just (RChosen sel) -> sel; _ -> [] }
                  isSelected = optId o `elem` selected
                  isMulti = length (filter optCorrect allOpts) > 1
                  stateClass :: Text
                  stateClass
                    | not evaluated = if isSelected then " is-selected" else ""
                    | optCorrect o = " is-correct"
                    | isSelected = " is-wrong"
                    | otherwise = ""
              in H.label_
                [ P.class_ (ms ("ex-option" <> stateClass))
                , textProp "for" (ms ("opt-" <> optId o))
                ]
                [ H.input_
                    ([ P.id_ (ms ("opt-" <> optId o))
                     , P.type_ (if isMulti then "checkbox" else "radio")
                     , P.name_ (ms ("answer-" <> tshow idx))
                     , P.checked_ isSelected
                     , textProp "aria-pressed" (if isSelected then "true" else "false")
                     , E.onClick (exOnToggle h idx (optId o))
                     ] ++ [P.disabled_ | evaluated])
                , H.span_ [] (Blocks.renderInlines "" (optLabel o))
                ]

            gradeActions _ Nothing = []
            gradeActions idx (Just outcome) =
              [ H.div_ [ P.id_ "ex-grade-actions", P.class_ "wizard-actions review-grade-actions" ]
                  (case outcome of
                    Correct ->
                      [ gradeButton ("btn-ex-grade-good" :: Text) ("wizard-no" :: Text) (iGood lang) ReviewGood
                      , gradeButton "btn-ex-grade-easy" "wizard-yes" (iEasy lang) ReviewEasy
                      ]
                    _ ->
                      [ gradeButton "btn-ex-grade-again" "wizard-no" (iAgain lang) ReviewAgain
                      , gradeButton "btn-ex-grade-hard" "wizard-yes" (iHard lang) ReviewHard
                      ])
              ]
              where
                gradeButton ident klass label grade =
                  let identT = ident :: Text
                      klassT = klass :: Text
                      labelT = label :: Text
                  in H.button_
                  [ P.id_ (ms identT), P.class_ (ms ("wizard-choice " <> klassT))
                  , E.onClick (exOnRate h idx grade)
                  ] [ text (ms labelT) ]
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

        sharedFeedbackEls includeNext =
          feedbackEl
            ++ [ H.div_ [ P.id_ "ex-note" ] (Blocks.renderBlocks "" (exNote ex)) | mAttempted, not (null (exNote ex)) ]
            ++ [ H.ul_ [ P.id_ "ex-cites" ] (map renderCite citesForFeedback) | mAttempted, not (null citesForFeedback) ]
            ++ [ H.button_ [ P.id_ "btn-ex-next", P.class_ "wizard-choice wizard-yes"
                           , E.onClick (exOnNext h)
                           ] [ text (ms (iNextButton lang)) ]
               | mAttempted, includeNext
               ]

        feedbackEl = case renderedResult of
          Nothing -> []
          Just (outcome, _) ->
            let isCorrect = outcome == Correct
            in [ H.p_ [ P.id_ "ex-feedback", P.class_ (if isCorrect then "correct" else "incorrect")
                      , textProp "role" "status"
                      ]
                   [ text (ms ((if isCorrect then iCorrectFeedback else iIncorrectFeedback) lang)) ]
               ]

        renderCite c = H.li_ []
          [ H.a_ [ P.class_ "cite", P.href_ (ms (renderRoute (RPage (citSlug c) (citPage c) False))) ]
              [ text (ms (iCitePage lang (citSlug c) (citPage c))) ]
          ]

        drillStepsEl ex' = H.ol_ [ P.id_ "ex-steps" ] (zipWith renderStep [1 ..] (exPrompts ex'))
          where
            -- M5 a11y: each step is a programmatic focus target (see
            -- #ex-title's own comment) -- confirming a step removes the
            -- focused Confirm button, so Main.hs re-lands focus on the
            -- NEXT step's container (manual and DEVICE confirms alike).
            renderStep stepN prompt = H.li_ [ P.class_ "ex-step", P.id_ (ms ("ex-step-" <> T.pack (show stepN))), textProp "tabindex" "-1" ]
              ( H.div_ [ P.class_ "ex-step-instruction" ] (Blocks.renderBlocks "" (prStem prompt))
                : case prBody prompt of
                    Confirm checkInlines mVerify ->
                      [ H.p_ [ P.class_ "ex-step-check", P.id_ (ms ("ex-step-" <> T.pack (show stepN) <> "-check")) ]
                          (Blocks.renderInlines "" checkInlines)
                      ]
                      ++ verifyEl stepN prompt mVerify
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

            -- M4: the live verify line (briefs/M4-plan.md section 3.8),
            -- replacing M2's fixed placeholder sentence. Keeps the
            -- p.ex-verify class and the ex-step-N-verify id, and gains
            -- exactly one state class per render:
            --   .ex-verify-confirmed  this step was confirmed ByDevice
            --   .ex-verify-waiting    armed and listening (the active
            --                         watch names THIS step's promptId
            --                         and access is granted)
            --   .ex-verify-idle       everything else -- including every
            --                         browser with no Web MIDI at all,
            --                         and steps confirmed manually. The
            --                         SENTENCE inside it tells the truth
            --                         about the device (M5 item 11): while
            --                         verification is granted the watch
            --                         arms only the cursor's step, so an
            --                         un-watched hooked step must not
            --                         claim verification is "off".
            -- M5 a11y: @aria-live="polite"@ so a screen reader hears the
            -- waiting -> confirmed sentence change (a DEVICE confirm
            -- happens with no click to anchor the announcement to).
            verifyEl _stepN _prompt Nothing = []
            verifyEl stepN prompt (Just v) =
              [ H.p_ [ P.class_ (ms ("ex-verify " <> stateClass))
                     , P.id_ (ms ("ex-step-" <> T.pack (show stepN) <> "-verify"))
                     , textProp "aria-live" "polite"
                     ]
                  [ text (ms sentence) ]
              ]
              where
                idx0 = stepN - 1
                pidText = unPromptId' (prId prompt)
                confirmedByDevice =
                  IntMap.lookup idx0 (esResponses st) == Just (RConfirmed ByDevice)
                devOn = dvwSupported dv
                  && snapStatus (dvwSnap dv) == DevGranted
                armed = devOn && dvwWatching dv == Just pidText
                (stateClass, sentence)
                  | confirmedByDevice =
                      ( "ex-verify-confirmed" :: Text
                      , iVerifyConfirmed lang (describeSpecFor lang v) )
                  | armed =
                      ( "ex-verify-waiting"
                      , iVerifyWaiting lang (describeSpecFor lang v) (snapChannel (dvwSnap dv)) )
                  -- M5 item 11: verification is ON but this hooked step is
                  -- not the armed one (the watch names the cursor's step,
                  -- or nothing is watched at all -- cursor on an unhooked
                  -- step, or the drill is done). The old text claimed
                  -- verification was off, which was false here.
                  | devOn =
                      ( "ex-verify-idle"
                      , case dvwWatching dv of
                          Just _  -> iVerifyIdleWatching lang
                          Nothing -> iVerifyIdleOn lang )
                  | otherwise =
                      ( "ex-verify-idle"
                      , iVerifyIdleOff lang )

            confirmEl idx0
              | idx0 == esCursor st =
                  [ H.div_ [ P.class_ "wizard-actions drill-step-actions" ]
                      [ H.button_
                          [ P.id_ "btn-ex-skip", P.class_ "wizard-choice wizard-no"
                          , E.onClick (exOnSkip h (length (exPrompts ex) - idx0))
                          ]
                          [ text (ms (iSkipCard lang)) ]
                      , H.button_
                          [ P.class_ "btn-ex-confirm wizard-choice wizard-yes"
                          , P.id_ (ms ("btn-ex-confirm-" <> T.pack (show (idx0 + 1))))
                          , E.onClick (exOnConfirm h idx0)
                          ]
                          [ text (ms (iConfirm lang)) ]
                      ]
                  ]
              | otherwise = []

        hintsEl ex'
          | null (exHints ex') || mAttempted = []
          | otherwise =
              [ H.details_ [ P.id_ "ex-hints-disclosure" ]
                  [ H.summary_ [ P.id_ "btn-ex-hint", E.onClick (exOnShowHint h cursor) ]
                      [ text (ms (iShowHint lang)) ]
                  , H.ul_ [ P.id_ "ex-hints" ]
                      [ H.li_ [ P.class_ "ex-hint" ] (Blocks.renderBlocks "" hb) | hb <- exHints ex' ]
                  ]
              ]

        -- M5 a11y: the summary is the focus target for the FINAL advance
        -- (the whole exercise completing) -- see #ex-title's comment.
        summaryEl
          | esDone st =
              [ H.section_ [ P.id_ "ex-summary", textProp "tabindex" "-1" ]
                  [ H.p_ [] [ text (ms (iExerciseCompleted lang)) ]
                  , H.div_ [ P.class_ "wizard-actions" ]
                      [ case nextExerciseAfter decks (exId ex) of
                      Just (nextDeck, nextEx) ->
                        H.a_ [ P.id_ "btn-ex-next-card", P.class_ "primary-training-action wizard-choice wizard-yes"
                             , P.href_ (ms (renderRoute (RExercise
                                 (unDeckId (dkId nextDeck)) (unExId (exId nextEx)))))
                             ]
                          [ H.strong_ [] [ text (ms (iNextCard lang)) ]
                          , H.span_ [ P.class_ "primary-training-card" ]
                              [ text (ms (dkTitle nextDeck <> " \8212 " <> exTitle nextEx)) ]
                          ]
                      Nothing ->
                        H.a_ [ P.id_ "btn-ex-next-card", P.class_ "primary-training-action wizard-choice wizard-yes"
                             , P.href_ (ms (renderRoute RExercises))
                             ]
                          [ H.strong_ [] [ text (ms (iCourseComplete lang)) ] ]
                      , H.button_ [ P.id_ "btn-ex-restart", P.class_ "wizard-choice wizard-no"
                                  , E.onClick (exOnRestart h)
                                  ]
                          [ H.strong_ [] [ text (ms (iRestart lang)) ] ]
                      ]
                  ]
              ]
          | otherwise = []

        -- M4 (briefs/M4-plan.md section 3.8): the device panel --
        -- rendered ONLY when Web MIDI is available (boot feature detect)
        -- AND the current exercise carries at least one verify: hook
        -- (only drill Confirm steps can, so this is never a quiz or
        -- lookup route). A browser without Web MIDI renders no
        -- #ex-device at all. The manual Confirm button is NEVER removed,
        -- hidden or disabled while device verification is on -- manual
        -- confirmation is the default path in every state.
        devicePanelEl ex'
          | dvwSupported dv && hasVerifyHook ex' =
              [ H.section_ [ P.id_ "ex-device" ]
                  ( deviceActionEl
                    ++
                    [
                    -- M5 a11y: status changes (grant/deny/mismatch/confirm
                    -- teardown) happen without a focus change, so the
                    -- sentence is a polite live region; the bare <select>
                    -- has no <label> element, so aria-label carries its
                    -- accessible name.
                    H.p_ [ P.id_ "device-status", textProp "aria-live" "polite" ] [ text (ms statusSentence) ]
                    , H.select_
                        [ P.id_ "sel-device-channel"
                        , textProp "aria-label" (ms (iChannelAria lang))
                        , E.onChange (\raw -> case parseDigits (fromMisoString raw) of
                            Just cn | cn >= 1 && cn <= 16 -> exOnDevChannel h cn
                            _                             -> exOnDevChannel h chan)
                        ]
                        [ H.option_ [ P.value_ (ms (tshow cn)), P.selected_ (cn == chan) ]
                            [ text (ms (tshow cn)) ]
                        | cn <- [1 .. 16 :: Int]
                        ]
                    , H.p_ [ P.id_ "device-ports" ] [ text (ms portsText) ]
                    ]
                  )
              ]
          | otherwise = []
          where
            snap = dvwSnap dv
            chan = snapChannel snap

            hasVerifyHook e = any
              (\p -> case prBody p of { Confirm _ (Just _) -> True; _ -> False })
              (exPrompts e)

            -- The likeliest real-device failure: the unit transmits on a
            -- channel other than the selected one (translations/midi.md
            -- 1.1: settable 1..16). Name it, and offer the one-click fix.
            mismatch = case (snapStatus snap, snapLastChan snap) of
              (DevGranted, Just c) | c /= chan -> Just c
              _                                -> Nothing

            enableLabel :: Text
            enableLabel = case snapStatus snap of
              DevGranted -> iDevDisable lang
              DevPending -> iDevRequesting lang
              DevDenied  -> iDevRetryAccess lang
              _          -> iDevEnable lang

            statusSentence :: Text
            statusSentence = case snapStatus snap of
              DevOff         -> iDevStatusOff lang
              DevPending     -> iDevStatusPending lang
              DevDenied      -> iDevStatusDenied lang
              DevUnsupported -> iDevStatusUnsupported lang
              DevGranted     -> case mismatch of
                Just c  -> iDevStatusMismatch lang c chan
                Nothing -> iDevStatusOn lang chan

            portsText :: Text
            portsText = case snapStatus snap of
              DevGranted
                | null (snapPorts snap) -> iDevNoInput lang
                | otherwise -> iDevBoundInput lang (T.intercalate ", " (snapPorts snap))
              _ -> iDevNoneBound lang

            -- The device panel and the active drill step share one
            -- decision surface.  A mismatch therefore REPLACES the
            -- enable/disable action with its one-click repair instead of
            -- appending a third button beside the manual Confirm action.
            deviceActionEl = case mismatch of
              Nothing ->
                [ H.button_ [ P.id_ "btn-device-enable", E.onClick (exOnDevEnable h) ]
                    [ text (ms enableLabel) ]
                ]
              Just c  ->
                [ H.button_ [ P.id_ "btn-device-use-channel", E.onClick (exOnDevChannel h c) ]
                    [ text (ms (iUseChannel lang c)) ]
                ]
