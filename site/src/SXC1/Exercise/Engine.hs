{-# LANGUAGE OverloadedStrings #-}

-- | The pure exercise engine: ONE state machine for all three exercise
-- types (quiz, drill, lookup), all four 'PromptBody' shapes. 'step' is
-- PURE and TOTAL -- both clock arguments an action carries (monotonic
-- ms, then wall-clock epoch ms) are supplied by the CALLER, so the
-- engine itself has no ambient time and is fully deterministic under
-- test.
--
-- THE M3 FORWARD HOOK: 'ProgressEvent' and 'ProgressSink' are shapes
-- only. M2 persists nothing -- no 'Miso.Storage' import, no storage
-- schema, no scheduling algorithm. M3 must be able to bind localStorage
-- and a spaced-repetition scheduler here WITHOUT changing the engine,
-- the content format or the views.
module SXC1.Exercise.Engine
  ( Response (..)
  , SelfGrade (..)
  , ConfirmSource (..)
  , Outcome (..)
  , ExerciseState (..)
  , ExerciseAction (..)
  , ProgressEvent (..)
  , ProgressSink (..)
  , initialState
  , step
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

-- | Who confirmed a drill step -- the learner, by button, or (M4) the
-- device itself via a WebMIDI @verify:@ hook.
data ConfirmSource = ByLearner | ByDevice
  deriving (Eq, Show)

data Outcome = Correct | Incorrect | Skipped | Completed
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
  , esStartedAt :: !Integer  -- ^ wall-clock epoch ms this attempt began
  , esPromptAt  :: !Integer  -- ^ monotonic ms the CURRENT prompt was (re)shown
  , esDone      :: !Bool
  } deriving (Eq, Show)

-- | Every action carries its own clock reading(s) -- monotonic ms first,
-- then wall-clock epoch ms, matching 'ProgressEvent''s
-- @(peElapsed, peAt)@ pair -- wherever an outcome or timestamp could be
-- produced. 'Toggle', 'Reveal', 'EnterPage' and 'ShowHint' are pure UI
-- state changes that never grade a prompt or emit an event, so they
-- carry no clock. 'Begin' and 'Restart' start (or reset) a fresh
-- attempt and take one clock reading, used to seed both
-- 'esStartedAt' and the first prompt's 'esPromptAt' baseline.
data ExerciseAction
  = Begin Integer
  | Toggle Int Text
  | Submit Int Integer Integer
  | Reveal Int
  | SelfGrade_ Int SelfGrade Integer Integer
  | ConfirmStep Int ConfirmSource Integer Integer
  | EnterPage Int Int
  | SubmitPage Int Integer Integer
  | ShowHint Int
  | Advance Integer
  | Restart Integer
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

initialState :: ExId -> Integer -> ExerciseState
initialState exid t = ExerciseState
  { esExercise  = exid
  , esCursor    = 0
  , esResponses = IntMap.empty
  , esAttempts  = IntMap.empty
  , esHints     = IntMap.empty
  , esRevealed  = IntSet.empty
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

mkEvent :: Exercise -> Maybe PromptId -> Outcome -> Int -> Bool -> Int -> Int -> Integer -> ProgressEvent
mkEvent ex mPid outcome attempt revealed hints elapsedMs wallMs = ProgressEvent
  { peDeck     = exDeck ex
  , peExercise = exId ex
  , pePrompt   = mPid
  , peKind     = exKind ex
  , peOutcome  = outcome
  , peAttempt  = attempt
  , peRevealed = revealed
  , peHints    = hints
  , peElapsed  = elapsedMs
  , peAt       = wallMs
  }

-- | Grade prompt @i@ against @grader@ (which inspects that prompt's
-- 'PromptBody' and returns @Nothing@ if the action doesn't apply to that
-- shape -- e.g. 'Submit' against a 'Confirm' prompt), record the
-- response, increment 'esAttempts', and emit exactly one
-- 'ProgressEvent'. Out-of-range prompt indices and shape mismatches are
-- both silent no-ops -- 'step' is TOTAL, never throws.
gradeStep
  :: Exercise -> ExerciseState -> Int -> Integer -> Integer
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
          elapsedMs = clampToInt (monoMs - esPromptAt st)
          outcome   = if correct then Correct else Incorrect
          st' = st
            { esResponses = IntMap.insert i resp (esResponses st)
            , esAttempts  = attempts'
            , esPromptAt  = monoMs
            }
          event = mkEvent ex (Just (prId prompt)) outcome attemptN revealed hints elapsedMs wallMs
      in (st', [event])

step :: Exercise -> ExerciseAction -> ExerciseState -> (ExerciseState, [ProgressEvent])
step ex action st = case action of
  Begin t   -> (initialState (exId ex) t, [])
  Restart t -> (initialState (exId ex) t, [])

  Toggle i optIdent ->
    let cur = case IntMap.lookup i (esResponses st) of
                Just (RChosen sel) -> sel
                _                  -> []
        sel' = if optIdent `elem` cur then filter (/= optIdent) cur else cur ++ [optIdent]
    in (st { esResponses = IntMap.insert i (RChosen sel') (esResponses st) }, [])

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

  Advance wallMs ->
    let i = esCursor st
        n = length (exPrompts ex)
        curResp = IntMap.findWithDefault RUnanswered i (esResponses st)
        skipEvent
          | i >= 0 && i < n && isUnanswered curResp =
              [ mkEvent ex (fmap prId (safeIndex (exPrompts ex) i)) Skipped 0 False
                  (IntMap.findWithDefault 0 i (esHints st)) 0 wallMs ]
          | otherwise = []
        nextCursor = i + 1
    in if nextCursor >= n
         then ( st { esCursor = nextCursor, esDone = True }
              , skipEvent ++ [ mkEvent ex Nothing Completed 0 False 0 0 wallMs ] )
         else (st { esCursor = nextCursor }, skipEvent)
