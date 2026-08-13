{-# LANGUAGE OverloadedStrings #-}

-- | The pure exercise engine: ONE state machine for all three exercise
-- types (quiz, drill, lookup), all four 'PromptBody' shapes. 'step' is
-- PURE and TOTAL -- both clock arguments an action carries (monotonic
-- ms, then wall-clock epoch ms) are supplied by the CALLER, so the
-- engine itself has no ambient time and is fully deterministic under
-- test.
--
-- THE CLOCK SEAM (M2 gate H1/H6): 'MonoMs' and 'WallMs' are distinct
-- newtypes over the SAME underlying 'Integer' millisecond representation
-- -- deliberately, so the two clock domains can never be silently
-- swapped at a call site. Before this fix, both were bare 'Integer', and
-- Main.hs seeded a fresh attempt's prompt clock from the WALL epoch
-- (~1.79e12) instead of the MONOTONIC clock 'gradeStep' actually
-- subtracts against, so every first-graded prompt (and every prompt
-- immediately after a 'Restart') reported a false near-zero elapsed
-- time. Distinct newtypes make that swap a TYPE ERROR rather than a
-- semantic bug a corrected call site could quietly regress back into --
-- see @site\/app\/Main.hs@'s 'readClocks' and the H1 self-test group in
-- @site\/test\/CheckExercises.hs@.
--
-- THE M3 FORWARD HOOK: 'ProgressEvent' and 'ProgressSink' are shapes
-- only. M2 persists nothing -- no 'Miso.Storage' import, no storage
-- schema, no scheduling algorithm. M3 must be able to bind localStorage
-- and a spaced-repetition scheduler here WITHOUT changing the engine,
-- the content format or the views.
module SXC1.Exercise.Engine
  ( Response (..)
  , SelfGrade (..)
  , ReviewGrade (..)
  , ConfirmSource (..)
  , Outcome (..)
  , MonoMs (..)
  , WallMs (..)
  , ExerciseState (..)
  , ExerciseAction (..)
  , ProgressEvent (..)
  , ProgressSink (..)
  , initialState
  , step
  , stepLive
  ) where

import qualified Data.IntMap.Strict as IntMap
import           Data.IntMap.Strict (IntMap)
import qualified Data.IntSet        as IntSet
import           Data.IntSet        (IntSet)
import qualified Data.Set           as Set
import           Data.Text          (Text)

import           SXC1.Exercise.Types

--------------------------------------------------------------------------
-- Responses and outcomes
--------------------------------------------------------------------------

data Response
  = RUnanswered
  | RChosen [Text]           -- ^ selected option ids, Choice mode
  | RRevealed SelfGrade      -- ^ Recall mode, after self-grading
  | RConfirmed ConfirmSource -- ^ Confirm (drill step)
  | RFound !Int              -- ^ FindPage (lookup)
  deriving (Eq, Show)

data SelfGrade = Got | Missed
  deriving (Eq, Show)

-- | The learner-facing spaced-repetition alphabet. Choice cards are
-- evaluated first, then committed with one of these four ratings. Keeping
-- the enum here lets 'ProgressEvent' carry the explicit decision without
-- making the exercise engine depend on the progress package.
data ReviewGrade = ReviewAgain | ReviewHard | ReviewGood | ReviewEasy
  deriving (Eq, Show, Enum, Bounded)

-- | Who confirmed a drill step -- the learner, by button, or (M4) the
-- device itself via a WebMIDI @verify:@ hook.
data ConfirmSource = ByLearner | ByDevice
  deriving (Eq, Show)

data Outcome = Correct | Incorrect | Skipped | Completed
  deriving (Eq, Show)

--------------------------------------------------------------------------
-- The two clock domains -- see the module Haddock's "THE CLOCK SEAM".
-- Both newtypes over 'Integer' milliseconds, kept DISTINCT on purpose:
-- 'MonoMs' is a monotonic reading (e.g. 'GHC.Clock.getMonotonicTimeNSec'
-- \/ 1e6, never subject to clock adjustment, safe to SUBTRACT for a
-- duration), 'WallMs' is a wall-clock epoch reading (safe to DISPLAY or
-- schedule against a real date, never safe to subtract against a
-- 'MonoMs' reading). Deriving only 'Eq'\/'Show' -- no 'Num', no 'Ord' --
-- is itself part of the safety property: there is no operator that lets
-- one accidentally arithmetic-mix a 'MonoMs' and a 'WallMs' value.
--------------------------------------------------------------------------

newtype MonoMs = MonoMs { unMonoMs :: Integer }
  deriving (Eq, Show)

newtype WallMs = WallMs { unWallMs :: Integer }
  deriving (Eq, Show)

--------------------------------------------------------------------------
-- State and actions
--------------------------------------------------------------------------

data ExerciseState = ExerciseState
  { esExercise  :: !ExId
  , esCursor    :: !Int
  , esResponses :: IntMap Response
  , esAttempts  :: IntMap Int
  , esHints     :: IntMap Int
  , esRevealed  :: IntSet
  , esEvaluated :: IntMap Outcome
  , esRated     :: IntSet
  , esStartedAt :: !MonoMs  -- ^ monotonic ms this attempt began (H1: seeded from the MONOTONIC clock, never the wall one)
  , esPromptAt  :: !MonoMs  -- ^ monotonic ms the CURRENT prompt was (re)shown -- what 'gradeStep' subtracts against
  , esDone      :: !Bool
  } deriving (Eq, Show)

-- | Every action that can grade a prompt or begin\/reset an attempt
-- carries BOTH clock readings -- a 'MonoMs' first, then a 'WallMs',
-- matching 'ProgressEvent''s @(peElapsed, peAt)@ pair -- wherever an
-- outcome or timestamp could be produced. 'Toggle', 'Reveal',
-- 'EnterPage' and 'ShowHint' are pure UI state changes that never grade a
-- prompt or emit an event, so they carry no clock. 'Begin' and 'Restart'
-- start (or reset) a fresh attempt from the monotonic reading (H1: never
-- the wall one -- see the module Haddock); 'Advance' RE-BASELINES
-- 'esPromptAt' to the monotonic reading taken when the NEXT prompt is
-- shown, so a prompt is timed from when the learner actually sees it,
-- not from the previous prompt's submit.
data ExerciseAction
  = Begin MonoMs WallMs
  | Toggle Int Text
  | Submit Int MonoMs WallMs
  | Check Int Bool             -- ^ evaluate Choice; True means "not sure"
  | Rate Int ReviewGrade MonoMs WallMs
  | Reveal Int
  | SelfGrade_ Int SelfGrade MonoMs WallMs
  | ConfirmStep Int ConfirmSource MonoMs WallMs
  | EnterPage Int Int
  | SubmitPage Int MonoMs WallMs
  | ShowHint Int
  | Advance MonoMs WallMs
  | Restart MonoMs WallMs
  deriving (Eq, Show)

--------------------------------------------------------------------------
-- The M3 forward hook
--------------------------------------------------------------------------

data ProgressEvent = ProgressEvent
  { peDeck     :: !DeckId
  , peExercise :: !ExId
  , pePrompt   :: Maybe PromptId
  , peKind     :: !Kind
  , peOutcome  :: !Outcome
  , peAttempt  :: !Int
  , peRevealed :: !Bool
  , peHints    :: !Int
  , peReview   :: Maybe ReviewGrade
  , peElapsed  :: !Int      -- ^ ms on this prompt, monotonic
  , peAt       :: !Integer  -- ^ wall-clock epoch ms; M3 schedules on dates
  } deriving (Eq, Show)

-- | Where M3 will persist events and load them back. Its IO fields are
-- just function fields -- this module performs no IO itself, and no
-- storage schema is designed here.
data ProgressSink = ProgressSink
  { sinkRecord :: ProgressEvent -> IO ()
  , sinkLoad   :: IO [ProgressEvent]
  }

--------------------------------------------------------------------------
-- step
--------------------------------------------------------------------------

initialState :: ExId -> MonoMs -> ExerciseState
initialState exid t = ExerciseState
  { esExercise  = exid
  , esCursor    = 0
  , esResponses = IntMap.empty
  , esAttempts  = IntMap.empty
  , esHints     = IntMap.empty
  , esRevealed  = IntSet.empty
  , esEvaluated = IntMap.empty
  , esRated     = IntSet.empty
  , esStartedAt = t
  , esPromptAt  = t
  , esDone      = False
  }

safeIndex :: [a] -> Int -> Maybe a
safeIndex xs i
  | i < 0     = Nothing
  | otherwise = case drop i xs of { (x : _) -> Just x; [] -> Nothing }

-- | Clamp a (possibly huge or negative, since it comes from subtracting
-- two caller-supplied 'Integer' clock readings) duration into 'Int'
-- range -- 'Int' is 32-bit on wasm32 (M1's NEW8), so this never lets an
-- elapsed-time computation wrap around the way unguarded 'Int' arithmetic
-- did before that fix.
clampToInt :: Integer -> Int
clampToInt n
  | n < 0                                  = 0
  | n > toInteger (maxBound :: Int) = maxBound
  | otherwise                              = fromInteger n

isUnanswered :: Response -> Bool
isUnanswered RUnanswered = True
isUnanswered _            = False

mkEvent :: Exercise -> Maybe PromptId -> Outcome -> Int -> Bool -> Int -> Maybe ReviewGrade -> Int -> Integer -> ProgressEvent
mkEvent ex mPid outcome attempt revealed hints review elapsedMs wallMs = ProgressEvent
  { peDeck     = exDeck ex
  , peExercise = exId ex
  , pePrompt   = mPid
  , peKind     = exKind ex
  , peOutcome  = outcome
  , peAttempt  = attempt
  , peRevealed = revealed
  , peHints    = hints
  , peReview   = review
  , peElapsed  = elapsedMs
  , peAt       = wallMs
  }

-- | Grade prompt @i@ against @grader@ (which inspects that prompt's
-- 'PromptBody' and returns @Nothing@ if the action doesn't apply to that
-- shape -- e.g. 'Submit' against a 'Confirm' prompt), record the
-- response, increment 'esAttempts', and emit exactly one
-- 'ProgressEvent'. Out-of-range prompt indices and shape mismatches are
-- both silent no-ops -- 'step' is TOTAL, never throws. Elapsed time is
-- always @monoMs - esPromptAt st@ -- BOTH monotonic (H1) -- and
-- re-baselines 'esPromptAt' to this same 'MonoMs' reading, so a second
-- grading attempt on the same prompt (a wrong-then-right retry) times
-- itself from the previous attempt, not from when the prompt first
-- appeared.
gradeStep
  :: Exercise -> ExerciseState -> Int -> MonoMs -> WallMs
  -> (Prompt -> Maybe (Bool, Response))
  -> (ExerciseState, [ProgressEvent])
gradeStep ex st i monoMs wallMs grader = case safeIndex (exPrompts ex) i of
  Nothing -> (st, [])
  Just prompt -> case grader prompt of
    Nothing -> (st, [])
    Just (correct, resp) ->
      let attempts' = IntMap.insertWith (+) i 1 (esAttempts st)
          attemptN  = IntMap.findWithDefault 1 i attempts'
          revealed  = IntSet.member i (esRevealed st)
          hints     = IntMap.findWithDefault 0 i (esHints st)
          elapsedMs = clampToInt (unMonoMs monoMs - unMonoMs (esPromptAt st))
          outcome   = if correct then Correct else Incorrect
          st' = st
            { esResponses = IntMap.insert i resp (esResponses st)
            , esAttempts  = attempts'
            , esPromptAt  = monoMs
            }
          event = mkEvent ex (Just (prId prompt)) outcome attemptN revealed hints Nothing elapsedMs (unWallMs wallMs)
      in (st', [event])

-- | Full backwards-compatible interpreter used by the checkers. The live
-- bundle cannot contain bare Recall cards and the app never constructs the
-- retired Submit/Reveal/SelfGrade actions, so those three cases stay outside
-- 'stepLive' and can be removed from the optimized browser link.
step :: Exercise -> ExerciseAction -> ExerciseState -> (ExerciseState, [ProgressEvent])
step ex action st = case action of
  Submit i monoMs wallMs -> gradeStep ex st i monoMs wallMs $ \prompt -> case prBody prompt of
    Choice opts ->
      let selected   = case IntMap.lookup i (esResponses st) of { Just (RChosen sel) -> sel; _ -> [] }
          correctIds = [ optId o | o <- opts, optCorrect o ]
      in Just (Set.fromList selected == Set.fromList correctIds, RChosen selected)
    _ -> Nothing
  Reveal i -> (st { esRevealed = IntSet.insert i (esRevealed st) }, [])
  SelfGrade_ i grade monoMs wallMs -> gradeStep ex st i monoMs wallMs $ \prompt -> case prBody prompt of
    Recall _ -> Just (grade == Got, RRevealed grade)
    _        -> Nothing
  _ -> stepLive ex action st

-- | Shipping interpreter. It remains total over the public action type, but
-- legacy-only constructors are inert and carry no retired grading/UI code.
stepLive :: Exercise -> ExerciseAction -> ExerciseState -> (ExerciseState, [ProgressEvent])
stepLive ex action st = case action of
  -- H1/H6: both clocks are taken, but only the MONOTONIC one seeds the
  -- new attempt's 'esStartedAt'/'esPromptAt' -- see the module Haddock.
  -- The 'WallMs' reading is still required at the call site (so every
  -- fresh-attempt action is symmetric with the graded ones, and so
  -- Main.hs always has a real wall reading on hand if a future M3 event
  -- ever needs one), even though this state shape has no field for it
  -- today.
  Begin mono _wall   -> (initialState (exId ex) mono, [])
  Restart mono _wall -> (initialState (exId ex) mono, [])

  -- Selection semantics (missing from the original manifest -- see
  -- briefs/M2-signoff-fixes.json, task "quiz-selection-semantics", FIX 1):
  -- a prompt with exactly ONE correct option is single-answer, so
  -- selecting a fresh option REPLACES the selection outright (radio
  -- behaviour) -- otherwise a learner who clicks a wrong option, then the
  -- right one, ends up with BOTH selected and is graded wrong while the
  -- correct answer sits there visibly pressed. A prompt with two or more
  -- correct options is genuinely multi-select and keeps the original
  -- additive/toggle behaviour. Either way, re-clicking an already-selected
  -- option still clears just that one -- the grading rule itself (exact-set
  -- equality, in 'Submit' below) is completely unchanged; only what a
  -- click DOES to the selection set was ever unspecified.
  Toggle i optIdent ->
    let cur = case IntMap.lookup i (esResponses st) of
                Just (RChosen sel) -> sel
                _                  -> []
        isSingleAnswer = case safeIndex (exPrompts ex) i of
          Just p -> case prBody p of
            Choice opts -> length (filter optCorrect opts) == 1
            _           -> False
          Nothing -> False
        sel'
          | optIdent `elem` cur = filter (/= optIdent) cur
          | isSingleAnswer      = [optIdent]
          | otherwise           = cur ++ [optIdent]
    in (st { esResponses = IntMap.insert i (RChosen sel') (esResponses st) }, [])

  Submit _ _ _ -> (st, [])

  -- UI choice flow: evaluation and scheduling are deliberately separate.
  -- The learner first gets honest correctness feedback, then chooses the
  -- appropriate Again/Hard or Good/Easy pair. No ProgressEvent is emitted
  -- until that second decision, so the visible rating is the rating saved.
  Check i unsure
    | IntMap.member i (esEvaluated st) -> (st, [])
    | otherwise -> case safeIndex (exPrompts ex) i of
        Just prompt -> case prBody prompt of
          Choice opts ->
            let selected = case IntMap.lookup i (esResponses st) of
                  Just (RChosen xs) -> xs
                  _                 -> []
                correctIds = [ optId o | o <- opts, optCorrect o ]
                correct = not unsure && Set.fromList selected == Set.fromList correctIds
                attempts' = IntMap.insertWith (+) i 1 (esAttempts st)
                response' = if unsure then RChosen [] else RChosen selected
            in ( st { esResponses = IntMap.insert i response' (esResponses st)
                    , esAttempts = attempts'
                    , esEvaluated = IntMap.insert i (if correct then Correct else Incorrect) (esEvaluated st)
                    }
               , [] )
          _ -> (st, [])
        Nothing -> (st, [])

  Rate i review monoMs wallMs
    | IntSet.member i (esRated st) -> (st, [])
    | otherwise -> case (safeIndex (exPrompts ex) i, IntMap.lookup i (esEvaluated st)) of
        (Just prompt, Just outcome) ->
          let attemptN = IntMap.findWithDefault 1 i (esAttempts st)
              revealed = IntSet.member i (esRevealed st)
              hints = IntMap.findWithDefault 0 i (esHints st)
              elapsedMs = clampToInt (unMonoMs monoMs - unMonoMs (esPromptAt st))
              event = mkEvent ex (Just (prId prompt)) outcome attemptN revealed hints
                        (Just review) elapsedMs (unWallMs wallMs)
          in (st { esRated = IntSet.insert i (esRated st), esPromptAt = monoMs }, [event])
        _ -> (st, [])

  Reveal _ -> (st, [])
  SelfGrade_ _ _ _ _ -> (st, [])

  ConfirmStep i src monoMs wallMs -> gradeStep ex st i monoMs wallMs $ \prompt -> case prBody prompt of
    Confirm _ _ -> Just (True, RConfirmed src)
    _           -> Nothing

  EnterPage i n -> (st { esResponses = IntMap.insert i (RFound n) (esResponses st) }, [])

  SubmitPage i monoMs wallMs -> gradeStep ex st i monoMs wallMs $ \prompt -> case prBody prompt of
    FindPage target _ ->
      let entered = case IntMap.lookup i (esResponses st) of { Just (RFound n) -> n; _ -> minBound }
      in Just (entered == citPage target, RFound entered)
    _ -> Nothing

  ShowHint i -> (st { esHints = IntMap.insertWith (+) i 1 (esHints st) }, [])

  -- H1: re-baseline 'esPromptAt' to THIS monotonic reading before moving
  -- the cursor, so prompt n+1 is timed from when it is shown (here), not
  -- from prompt n's last submit -- previously 'Advance' carried only a
  -- wall-clock reading and never touched 'esPromptAt' at all.
  Advance monoMs wallMs ->
    let i = esCursor st
        n = length (exPrompts ex)
        curResp = IntMap.findWithDefault RUnanswered i (esResponses st)
        wallInt = unWallMs wallMs
        skipEvent
          | i >= 0 && i < n && isUnanswered curResp =
              [ mkEvent ex (fmap prId (safeIndex (exPrompts ex) i)) Skipped 0 False
                  (IntMap.findWithDefault 0 i (esHints st)) Nothing 0 wallInt ]
          | otherwise = []
        nextCursor = i + 1
        st' = st { esPromptAt = monoMs }
    in if nextCursor >= n
         then ( st' { esCursor = nextCursor, esDone = True }
              , skipEvent ++ [ mkEvent ex Nothing Completed 0 False 0 Nothing 0 wallInt ] )
         else (st' { esCursor = nextCursor }, skipEvent)
