{-# LANGUAGE OverloadedStrings #-}

-- | The pure progress model: the spaced-repetition record shape, the
-- day-granularity clock projection, and the ONE place an 'Outcome' is
-- ever interpreted into a spaced-repetition 'Grade'.
--
-- PURITY (briefs\/M3-manifest.json, task \"progress-core\"): this module,
-- and every other module under "SXC1.Progress", performs NO IO, imports
-- NO @Miso@ module, and reads NO clock (no @GHC.Clock@, no
-- @Data.Time@, no @System.IO@ beyond what @base@ re-exports for pure
-- code). Every millisecond value the progress engine ever sees is an
-- argument someone else read at an IO boundary -- see
-- "SXC1.Exercise.Engine"'s @MonoMs@\/@WallMs@ clock-seam Haddock, which
-- this module inherits: 'dayOf' takes a 'WallMs'-shaped 'Integer'
-- (@peAt@'s epoch milliseconds) as a plain argument, never samples one
-- itself. This is what makes the whole engine exactly replayable from a
-- stored event log (see @exe:progress-check --replay@) and unit-testable
-- without a browser.
--
-- SIZE DISCIPLINE (inherited from "SXC1.Exercise.Types"): 'Rec' and
-- 'ProgressState' derive 'Eq' ONLY -- no derived 'Show' on either (both
-- are linked into the browser app once "SXC1.Progress.Store" -- M3 wave
-- 3 -- binds them). The small enum\/newtype types below ('Grade',
-- 'DayNum', 'SchemaVersion') keep their derived 'Show': same rationale
-- "SXC1.Exercise.Types" gives for 'Kind'\/'VerifySpec' -- cheap on a
-- small closed type, and useful for diagnostics.
module SXC1.Progress.Types
  ( Grade (..)
  , DayNum (..)
  , dayCap
  , addDays
  , Rec (..)
  , SchemaVersion (..)
  , ProgressState (..)
  , emptyProgress
  , dayOf
  , gradeOfOutcome
  ) where

import           Data.Map.Strict    (Map)
import qualified Data.Map.Strict    as Map
import           Data.Text          (Text)

import           SXC1.Exercise.Engine (Outcome (..))

--------------------------------------------------------------------------
-- Grade -- the spaced-repetition input alphabet. 'gradeOfOutcome' below
-- is the ONLY function in the whole SXC1.Progress.* tree allowed to
-- pattern-match an 'Outcome' to decide one of these four values; every
-- other module (in particular "SXC1.Progress.Scheduler") receives a
-- 'Grade' already decided and never re-derives one from an 'Outcome'.
--------------------------------------------------------------------------

data Grade = GAgain | GHard | GGood | GEasy
  deriving (Eq, Show, Enum, Bounded)

-- | A day number: whole days since the Unix epoch, UTC, floor-divided --
-- see 'dayOf'. Deliberately coarser than 'Integer' milliseconds: a
-- learner who studies at 23:59 and again at 00:01 the same UTC day must
-- not be charged a whole spaced-repetition interval for it.
newtype DayNum = DayNum { unDayNum :: Int }
  deriving (Eq, Ord, Show)

-- | One prompt's spaced-repetition schedule. 'rcEase' is carried in
-- MILLI-UNITS (2500 means ease factor 2.5) as a plain 'Int' -- see
-- "SXC1.Progress.Scheduler"'s module Haddock for why this must never
-- become a 'Double'. 'rcSeen' is the total number of times this prompt
-- has ever been graded (never decreases, even across an 'GAgain' lapse
-- that resets 'rcReps' to 0 -- 'rcSeen' is a lifetime counter,
-- 'rcReps' is "reps since the last lapse").
data Rec = Rec
  { rcReps     :: !Int
  , rcLapses   :: !Int
  , rcEase     :: !Int
  , rcInterval :: !Int
  , rcDue      :: !DayNum
  , rcLastSeen :: !DayNum
  , rcSeen     :: !Int
  } deriving Eq

-- | The wire schema version a 'ProgressState' was decoded as (post any
-- migration -- see "SXC1.Progress.Codec".'SXC1.Progress.Codec.migrateWith'
-- -- this always ends up 'SXC1.Progress.Codec.currentSchema' for any
-- successfully decoded state). A plain newtype 'Int', not the migration
-- mechanism itself.
newtype SchemaVersion = SchemaVersion Int
  deriving (Eq, Show)

-- | The whole learner progress model. 'psRecs' is keyed by 'PromptId'
-- TEXT (not the newtype itself -- see "SXC1.Exercise.Types".'SXC1.Exercise.Types.PromptId'
-- -- so this module never needs to import the exercise CONTENT types,
-- only "SXC1.Exercise.Engine"'s already-pure 'Outcome'). 'psDone' counts
-- exercise-level completions (keyed by exercise id text), separate from
-- any one prompt's schedule. 'psStreakDay'\/'psStreakLen' are the daily
-- study-streak counters ("SXC1.Progress.Scheduler".'SXC1.Progress.Scheduler.bumpStreak');
-- 'psFirstDay' is the day of the very first progress event this state
-- has ever folded (any kind -- graded prompt or exercise completion),
-- kept forever once set, for a "member since" style stat.
data ProgressState = ProgressState
  { psVersion   :: !SchemaVersion
  , psRecs      :: !(Map Text Rec)
  , psDone      :: !(Map Text Int)
  , psStreakDay :: !DayNum
  , psStreakLen :: !Int
  , psFirstDay  :: !DayNum
    -- | Schema v2 (M3 gate NEW12): the PromptId of the most recently
    -- graded prompt, empty when none -- what "continue where you left
    -- off" points at. Day-granularity 'rcLastSeen' cannot break
    -- same-day ties (Map order picked an arbitrary prompt); this field
    -- can. v1 blobs migrate with it empty (the UI falls back to the
    -- day heuristic once, then the first graded event fills it).
  , psLastPrompt :: !Text
  } deriving Eq

-- | A learner who has never done anything. NOTE: 'psVersion' is
-- hardcoded to @SchemaVersion 2@ here rather than referencing
-- "SXC1.Progress.Codec".'SXC1.Progress.Codec.currentSchema' -- 'Codec'
-- imports 'Types', so the reverse import would be a cycle. The two
-- literals (this one, and 'SXC1.Progress.Codec.currentSchema') must be
-- kept in lockstep by hand; @exe:progress-check@'s round-trip self-test
-- group (3) is what would go red first if they ever drifted, since
-- @decodeState . encodeState@ always normalises 'psVersion' to
-- 'SXC1.Progress.Codec.currentSchema'.
emptyProgress :: ProgressState
emptyProgress = ProgressState
  { psVersion   = SchemaVersion 2
  , psRecs      = Map.empty
  , psDone      = Map.empty
  , psStreakDay = DayNum 0
  , psStreakLen = 0
  , psFirstDay  = DayNum 0
  , psLastPrompt = ""
  }

msPerDay :: Integer
msPerDay = 86400000

-- | The largest day number this engine will ever compute or store --
-- roughly the year 29379. M3 gate NEW1: the previous clamp was
-- @maxBound :: Int@, and on wasm32 (32-bit 'Int', M1's NEW8) a due-date
-- computed as @maxBound + interval@ WRAPPED NEGATIVE -- 'encodeState'
-- then emitted a negative day the nonnegative-only wire parser skipped
-- on the way back in, silently dropping the record: a state that could
-- not round-trip. 'dayCap' leaves five decimal orders of magnitude of
-- headroom below @maxBound@ (2^31-1 = 2,147,483,647), so
-- @dayCap + 180@ (the scheduler's own interval cap) cannot overflow,
-- and 'addDays' below re-clamps anyway.
dayCap :: Int
dayCap = 9999999

-- | Overflow-safe day arithmetic: the ONLY way schedule code may add to
-- a 'DayNum' (M3 gate NEW1). TOTAL on all of 'Int' (round-3 residual):
-- each operand is clamped into @[0, 'dayCap']@ BEFORE the add -- the sum
-- of two capped operands tops out near 2x10^7, far inside even wasm32's
-- 32-bit 'Int' -- so the contract holds for any caller-supplied values
-- (the 'DayNum' constructor is exported), not just decoded ones.
addDays :: DayNum -> Int -> DayNum
addDays (DayNum d) n =
  DayNum (min dayCap (min dayCap (max 0 d) + min dayCap (max 0 n)))

-- | Wall-clock epoch milliseconds -> whole UTC days since the epoch,
-- floor-divided, clamped into @[1, 'dayCap']@.
--
-- DAY ZERO IS RESERVED (M3 gate NEW4): @DayNum 0@ is the "never set"
-- sentinel ('emptyProgress''s @psFirstDay@\/@psStreakDay@), so no real
-- event may land on it -- a non-positive or epoch-day-zero reading maps
-- to @DayNum 1@. The cost is that an event genuinely stamped during
-- 1970-01-01 counts as 1970-01-02, which is not a reachable input from
-- any clock this app reads; the benefit is that "first day recorded" and
-- "no day ever recorded" can never collide.
dayOf :: Integer -> DayNum
dayOf ms
  | ms <= 0   = DayNum 1
  | otherwise = DayNum (max 1 (clampToCap (ms `div` msPerDay)))
  where
    clampToCap n
      | n > toInteger dayCap = dayCap
      | otherwise            = fromInteger n

-- | THE ONLY PLACE an 'Outcome' is interpreted into a spaced-repetition
-- 'Grade' -- see the module Haddock. Order matters: within 'Correct',
-- the rules are checked top-to-bottom, so a revealed-AND-multi-attempt
-- correct answer reports 'GHard' (the 'revealed' check alone already
-- decides it) rather than falling through to a hints check.
--
--   * 'Incorrect' or 'Skipped'        -> 'GAgain' (start the item over)
--   * 'Completed' (an exercise-level, promptless marker)  -> 'GGood'
--     (present for TOTALITY -- see "SXC1.Progress.Scheduler"'s Haddock
--     on why a promptless 'Completed' event never actually reaches this
--     function in practice today)
--   * 'Correct' and the answer was revealed first -> 'GHard'
--   * 'Correct' but it took a second (or later) attempt -> 'GHard'
--   * 'Correct', first try, but a hint was used -> 'GGood'
--   * 'Correct', first try, no reveal, no hint -> 'GEasy'
gradeOfOutcome :: Outcome -> Int -> Bool -> Int -> Grade
gradeOfOutcome outcome attempt revealed hints = case outcome of
  Incorrect -> GAgain
  Skipped   -> GAgain
  Completed -> GGood
  Correct
    | revealed        -> GHard
    | attempt >= 2     -> GHard
    | hints > 0         -> GGood
    | otherwise          -> GEasy
