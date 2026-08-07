{-# LANGUAGE OverloadedStrings #-}

-- | Integer SM-2: a pure fold of 'ProgressEvent' history into a
-- 'ProgressState'. See "SXC1.Progress.Types" for the module-wide purity
-- discipline (no IO, no @Miso@, no clock reads) -- this module inherits
-- it exactly, and additionally binds NO FLOATING POINT ANYWHERE. That is
-- not a style preference: 'Int' is 32-bit on wasm32 (M1's NEW8), this
-- scheduler is replayed from a stored event log
-- (@exe:progress-check --replay@) as well as run live in the browser,
-- and a stored spaced-repetition schedule must decode to BIT-IDENTICAL
-- records forever on any target -- a 'Double' anywhere in that replay
-- path (even a seemingly-harmless @fromIntegral x / 100@) risks a
-- platform-dependent rounding difference an 'Int' computation cannot
-- have. The ease factor is therefore carried in MILLI-UNITS as a plain
-- 'Int' (2500 means ease factor 2.5); every SM-2 update is a literal
-- (see 'easeDelta') or an 'Int' multiply-then-'div'.
--
-- ONE OUTCOME-INSPECTION EXCEPTION, DOCUMENTED HONESTLY: 'applyEvent'
-- checks @peOutcome ev == 'Completed'@ to decide whether a PROMPTLESS
-- event is an exercise-completion marker (bump 'psDone') rather than a
-- no-op. This is a structural ROUTING check, not a grading
-- interpretation -- it never influences a 'Grade' or a schedule, and
-- "SXC1.Progress.Types".'SXC1.Progress.Types.gradeOfOutcome' remains the
-- only place the four-way 'Grade' mapping itself is computed. In
-- practice "SXC1.Exercise.Engine"'s real event producer (@mkEvent@'s
-- call sites) only ever pairs @peOutcome = Completed@ with
-- @pePrompt = Nothing@, so this check and the @pePrompt@ shape agree by
-- construction; the equality check is kept explicit anyway, rather than
-- dispatching on @pePrompt@'s @Just@\/@Nothing@ shape alone, because the
-- alternative reading of a promptless NON-Completed event silently
-- bumping 'psDone' would be the more dangerous bug to write by accident.
module SXC1.Progress.Scheduler
  ( easeDelta
  , easeMin
  , easeMax
  , easeDefault
  , nextIntervalDays
  , applyEvent
  , applyEvents
  , bumpStreak
  , reviewQueue
  , dueCount
  , retention
  ) where

import           Data.List             (sortBy)
import qualified Data.Map.Strict       as Map
import           Data.Ord              (comparing)
import           Data.Text             (Text)

import           SXC1.Exercise.Engine  (Outcome (..), ProgressEvent (..))
import           SXC1.Exercise.Types   (ExId (..), PromptId (..))
import           SXC1.Progress.Types

--------------------------------------------------------------------------
-- Ease factor: milli-units, bounded, defaulted.
--------------------------------------------------------------------------

easeMin, easeMax, easeDefault :: Int
easeMin     = 1300
easeMax     = 3000
easeDefault = 2500

clampEase :: Int -> Int
clampEase x = max easeMin (min easeMax x)

-- | The exact SM-2 ease deltas for @q = 2,3,4,5@ (the four grades),
-- evaluating @EF' = EF + (0.1 - (5-q)*(0.08 + (5-q)*0.02))@ ahead of
-- time and taking the results as literals -- see the module Haddock:
-- this project does not compute this formula at runtime, ever.
easeDelta :: Grade -> Int
easeDelta GAgain = -320
easeDelta GHard  = -140
easeDelta GGood  = 0
easeDelta GEasy  = 100

clamp1_180 :: Int -> Int
clamp1_180 x = max 1 (min 180 x)

-- | The next interval, in whole days, for a prompt currently at 'Rec'
-- being graded 'Grade'. The 180-day cap ('clamp1_180') is deliberate --
-- see the manifest: this is a device-training course, and an uncapped
-- SM-2 curve schedules items past the point where the learner still
-- owns the hardware.
nextIntervalDays :: Rec -> Grade -> Int
nextIntervalDays rc grade = case grade of
  GAgain -> 0
  GHard
    | rcReps rc == 0 -> 1
    | otherwise       -> clamp1_180 (rcInterval rc * 12 `div` 10)
  GGood
    | rcReps rc == 0 -> 1
    | rcReps rc == 1 -> 3
    | otherwise       -> clamp1_180 (rcInterval rc * rcEase rc `div` 1000)
  GEasy
    | rcReps rc == 0 -> 2
    | rcReps rc == 1 -> 5
    | otherwise       -> clamp1_180 (rcInterval rc * rcEase rc * 13 `div` 10000)

freshRec :: Rec
freshRec = Rec
  { rcReps = 0, rcLapses = 0, rcEase = easeDefault, rcInterval = 0
  , rcDue = DayNum 0, rcLastSeen = DayNum 0, rcSeen = 0
  }

-- | If 'psFirstDay' has never been set (the @DayNum 0@ sentinel
-- 'SXC1.Progress.Types.emptyProgress' starts with), set it to @day@ --
-- the day of whichever event reaches this first, graded prompt or bare
-- exercise completion alike. Never changes it again once set.
touchFirstDay :: DayNum -> ProgressState -> ProgressState
touchFirstDay day st
  | psFirstDay st == DayNum 0 = st { psFirstDay = day }
  | otherwise                 = st

-- | Fold one 'ProgressEvent' into a 'ProgressState'. TAKES NO CLOCK
-- ARGUMENT AT ALL -- the day comes from the event's own 'peAt' via
-- 'dayOf' (see the module Haddock on why: pure replay from a stored log
-- must be exactly reproducible). A promptless, non-'Completed' event
-- (which the real engine never produces -- see the module Haddock) is a
-- total no-op past 'touchFirstDay'.
applyEvent :: ProgressEvent -> ProgressState -> ProgressState
applyEvent ev st0 = case pePrompt ev of
  Just (PromptId pidTxt) ->
    let existing  = Map.findWithDefault freshRec pidTxt (psRecs st1)
        grade     = gradeOfOutcome (peOutcome ev) (peAttempt ev) (peRevealed ev) (peHints ev)
        interval' = nextIntervalDays existing grade
        ease'     = clampEase (rcEase existing + easeDelta grade)
        reps'     = if grade == GAgain then 0 else rcReps existing + 1
        lapses'   = rcLapses existing + (if grade == GAgain && rcReps existing > 0 then 1 else 0)
        due'      = DayNum (unDayNum today + interval')
        newRec = Rec
          { rcReps = reps', rcLapses = lapses', rcEase = ease', rcInterval = interval'
          , rcDue = due', rcLastSeen = today, rcSeen = rcSeen existing + 1
          }
        (streakDay', streakLen') = bumpStreak today (psStreakDay st1) (psStreakLen st1)
    in st1
         { psRecs      = Map.insert pidTxt newRec (psRecs st1)
         , psStreakDay = streakDay'
         , psStreakLen = streakLen'
         }
  Nothing
    | peOutcome ev == Completed ->
        let ExId eidTxt = peExercise ev
        in st1 { psDone = Map.insert eidTxt (Map.findWithDefault 0 eidTxt (psDone st1) + 1) (psDone st1) }
    | otherwise -> st1
  where
    today = dayOf (peAt ev)
    st1   = touchFirstDay today st0

applyEvents :: [ProgressEvent] -> ProgressState -> ProgressState
applyEvents evs st = foldl' (flip applyEvent) st evs

-- | The daily study-streak rule. @bumpStreak today lastDay len@:
--
--   * never bumped before (@len == 0@)             -> @(today, 1)@
--   * @today@ is the same day as @lastDay@          -> unchanged, floor 1
--   * @today@ is exactly the day after @lastDay@     -> @(today, len + 1)@
--   * @today@ is later than @lastDay@ with a gap      -> @(today, 1)@
--   * @today@ is BEFORE @lastDay@ (a backwards clock, or an imported
--     history applied out of order)                    -> UNCHANGED --
--     never advances, never shortens, on a backwards day.
bumpStreak :: DayNum -> DayNum -> Int -> (DayNum, Int)
bumpStreak today lastDay len
  | len == 0                             = (today, 1)
  | unDayNum today == unDayNum lastDay      = (lastDay, max 1 len)
  | unDayNum today == unDayNum lastDay + 1  = (today, len + 1)
  | unDayNum today > unDayNum lastDay + 1   = (today, 1)
  | otherwise {- today < lastDay -}          = (lastDay, len)

-- | Every prompt whose 'rcDue' is on or before @today@, sorted by
-- @(dueDay, promptId)@ -- a TOTAL order over 'Text', so the queue can
-- never depend on 'Map' iteration order changing under a different key
-- set (two records due the same day always come back in prompt-id
-- order, regardless of insertion order).
--
-- HONESTY NOTE (from @exe:progress-check@'s own sabotage sweep): with
-- today's implementation the explicit @pid@ tiebreaker is BEHAVIORALLY
-- redundant -- 'sortBy' is stable and 'Map.toList' already yields keys
-- in ascending order, so removing the tiebreaker produces an identical
-- queue. It is kept anyway as belt-and-suspenders: the contract is the
-- pair-order, not the mechanism, and a future change away from
-- @Map.toList@ (or to an unstable sort) must not silently change the
-- queue. The falsifiability of the group-4 checks is therefore proven
-- with an INVERTED tiebreaker sabotage (which does change behavior),
-- not a removed one (which cannot).
reviewQueue :: DayNum -> ProgressState -> [(Text, Rec)]
reviewQueue today st =
  sortBy (comparing (\(pid, rc) -> (unDayNum (rcDue rc), pid)))
    [ pr | pr@(_, rc) <- Map.toList (psRecs st), unDayNum (rcDue rc) <= unDayNum today ]

dueCount :: DayNum -> ProgressState -> Int
dueCount today st = length (reviewQueue today st)

-- | The integer percentage of known prompts that are NOT currently
-- overdue -- @0@ when there are no known prompts at all (never a
-- division by zero, never a vacuous 100%).
retention :: DayNum -> ProgressState -> Int
retention today st
  | total == 0 = 0
  | otherwise  = ((total - overdue) * 100) `div` total
  where
    total   = Map.size (psRecs st)
    overdue = dueCount today st
