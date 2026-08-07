{-# LANGUAGE OverloadedStrings #-}

-- | @exe:progress-check@ -- the self-test binary for the pure progress
-- core ("SXC1.Progress.Types" \/ "SXC1.Progress.Scheduler" \/
-- "SXC1.Progress.Codec"). A wasm32-wasi COMMAND module run on the host
-- via @wasm-run.mjs@, following @site\/test\/CheckExercises.hs@'s shape:
-- numbered assertion groups, an 'assertionLabel', a loop over the whole
-- group range, and -- M1's NEW12, built in from birth -- a run fails if
-- ANY group is EMPTY as well as if any check fails: an empty assertion
-- group printing ok\/FAIL but exiting 0 is a bug class this project has
-- already been bitten by.
--
-- Modes:
--   (none) \/ --self-test   run all assertion groups
--   --replay FILE           read a #sxc1-event-log JSON array from FILE,
--                           fold it through 'applyEvents' from
--                           'emptyProgress', print 'encodeState' of the
--                           result (used at sign-off to compare a real
--                           browser's stored blob against a pure replay)
--
-- GROUP 11 (purity) reads the three module sources from disk and greps
-- them, so it is a real, falsifiable check, not a claim: an @import
-- Miso@ or a clock read appearing in any "SXC1.Progress" module turns
-- the group red. Run from @site\/@ (the same cwd every other checker
-- binary requires).
module Main (main) where

import           Control.Monad          (forM, forM_, unless)
import           Data.IORef             (IORef, modifyIORef', newIORef, readIORef)
import           Data.List              (isSuffixOf)
import           System.Directory       (doesDirectoryExist, listDirectory)
import qualified Data.Map.Strict        as Map
import           Data.Text              (Text)
import qualified Data.Text              as T
import qualified Data.Text.IO           as TIO
import           System.Environment     (getArgs)
import           System.Exit            (exitFailure)
import           System.IO              (hPutStrLn, stderr)

import           SXC1.Content.Stats     (jsonEscape)
import           SXC1.Exercise.Engine   (Outcome (..), ProgressEvent (..))
import           SXC1.Exercise.Types    (DeckId (..), ExId (..), Kind (..), PromptId (..))
import           SXC1.Progress.Codec
import           SXC1.Progress.Scheduler
import           SXC1.Progress.Types

--------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------

data CheckLog = CheckLog { clChecks :: IORef [(Int, String, Bool, String)] }

record :: CheckLog -> Int -> String -> Bool -> String -> IO ()
record cl g name ok detail = do
  modifyIORef' (clChecks cl) (++ [(g, name, ok, detail)])
  putStrLn ((if ok then "ok   - " else "FAIL - ") ++ "[" ++ show g ++ "] " ++ name
            ++ (if ok then "" else " (observed: " ++ take 300 detail ++ ")"))

groupRange :: [Int]
groupRange = [1 .. 12]

assertionLabel :: Int -> String
assertionLabel g = case g of
  1  -> "nextIntervalDays pinned table + ease clamps"
  2  -> "gradeOfOutcome exhaustive mapping"
  3  -> "replay determinism + codec round trip"
  4  -> "reviewQueue total order"
  5  -> "streak rule incl. backwards day"
  6  -> "dayOf projection"
  7  -> "codec robustness"
  8  -> "migration mechanism (migrateWith)"
  9  -> "export/import envelope"
  10 -> "prefs codec + default-OFF safety"
  11 -> "purity guard (source inspection)"
  12 -> "applyEvent full-transition pins"
  _  -> "?"

--------------------------------------------------------------------------
-- Event construction helpers (test-only)
--------------------------------------------------------------------------

mkEv :: Maybe Text -> Outcome -> Int -> Bool -> Int -> Integer -> ProgressEvent
mkEv mPid outcome attempt revealed hints atMs = ProgressEvent
  { peDeck = DeckId "test-deck", peExercise = ExId "q-9-99"
  , pePrompt = PromptId <$> mPid, peKind = KQuiz, peOutcome = outcome
  , peAttempt = attempt, peRevealed = revealed, peHints = hints
  , peElapsed = 1000, peAt = atMs
  }

day :: Int -> Integer
day n = toInteger n * 86400000 + 3600000  -- 01:00 UTC on day n

rec0 :: Int -> Int -> Int -> Rec
rec0 reps intv ease = Rec { rcReps = reps, rcLapses = 0, rcEase = ease
                          , rcInterval = intv, rcDue = DayNum 0
                          , rcLastSeen = DayNum 0, rcSeen = reps }

--------------------------------------------------------------------------
-- Groups
--------------------------------------------------------------------------

group1 :: CheckLog -> IO ()
group1 cl = do
  let cases =
        [ ("fresh GAgain -> 0",  nextIntervalDays (rec0 0 0 2500) GAgain, 0)
        , ("fresh GHard -> 1",   nextIntervalDays (rec0 0 0 2500) GHard,  1)
        , ("fresh GGood -> 1",   nextIntervalDays (rec0 0 0 2500) GGood,  1)
        , ("fresh GEasy -> 2",   nextIntervalDays (rec0 0 0 2500) GEasy,  2)
        , ("reps1 GGood -> 3",   nextIntervalDays (rec0 1 1 2500) GGood,  3)
        , ("reps1 GEasy -> 5",   nextIntervalDays (rec0 1 1 2500) GEasy,  5)
        , ("reps1 GHard -> 1 (1*12/10 floor)", nextIntervalDays (rec0 1 1 2500) GHard, 1)
        , ("reps2 GHard 3d -> 3 (3.6 floor)",  nextIntervalDays (rec0 2 3 2500) GHard, 3)
        , ("reps2 GGood 3d e2500 -> 7",        nextIntervalDays (rec0 2 3 2500) GGood, 7)
        , ("reps2 GEasy 3d e2500 -> 9",        nextIntervalDays (rec0 2 3 2500) GEasy, 9)
        , ("low clamp: 0d GGood -> 1",         nextIntervalDays (rec0 2 0 2500) GGood, 1)
        , ("high clamp: 180d e3000 GGood -> 180", nextIntervalDays (rec0 2 180 3000) GGood, 180)
        , ("high clamp: 90d e3000 GEasy -> 180",  nextIntervalDays (rec0 2 90 3000) GEasy, 180)
        ]
  forM_ cases $ \(nm, got, want) ->
    record cl 1 nm (got == want) ("got " ++ show got ++ " want " ++ show want)
  -- ease clamps, observed through applyEvent (clampEase is internal):
  let stLow = applyEvents [ mkEv (Just "p#1") Incorrect 1 False 0 (day 1)
                          , mkEv (Just "p#1") Incorrect 1 False 0 (day 1)
                          , mkEv (Just "p#1") Incorrect 1 False 0 (day 1)
                          , mkEv (Just "p#1") Incorrect 1 False 0 (day 1)
                          , mkEv (Just "p#1") Incorrect 1 False 0 (day 1)
                          ] emptyProgress
      easeLow = maybe (-1) rcEase (Map.lookup "p#1" (psRecs stLow))
  record cl 1 "ease floors at 1300 after repeated GAgain" (easeLow == 1300) ("ease " ++ show easeLow)
  let evEasy i = mkEv (Just "p#2") Correct 1 False 0 (day i)
      stHigh = applyEvents (map evEasy [1 .. 8]) emptyProgress
      easeHigh = maybe (-1) rcEase (Map.lookup "p#2" (psRecs stHigh))
  record cl 1 "ease caps at 3000 after repeated GEasy" (easeHigh == 3000) ("ease " ++ show easeHigh)
  -- Pin each easeDelta LITERAL through a single applyEvent from a fresh
  -- record (default ease 2500): the clamp checks above are insensitive
  -- to a +-10 drift in a delta (found by this file's own sabotage sweep
  -- -- an unpinned literal is an unguarded literal).
  let oneEase pid outcome att rev hints =
        maybe (-1) rcEase (Map.lookup pid (psRecs (applyEvent (mkEv (Just pid) outcome att rev hints (day 3)) emptyProgress)))
  record cl 1 "one GEasy from fresh: ease 2500 -> 2600" (oneEase "e#1" Correct 1 False 0 == 2600)
    ("ease " ++ show (oneEase "e#1" Correct 1 False 0))
  record cl 1 "one GGood from fresh: ease 2500 -> 2500" (oneEase "e#2" Correct 1 False 1 == 2500)
    ("ease " ++ show (oneEase "e#2" Correct 1 False 1))
  record cl 1 "one GHard from fresh: ease 2500 -> 2360" (oneEase "e#3" Correct 2 False 0 == 2360)
    ("ease " ++ show (oneEase "e#3" Correct 2 False 0))
  record cl 1 "one GAgain from fresh: ease 2500 -> 2180" (oneEase "e#4" Incorrect 1 False 0 == 2180)
    ("ease " ++ show (oneEase "e#4" Incorrect 1 False 0))

group2 :: CheckLog -> IO ()
group2 cl = do
  let cases =
        [ ("Incorrect -> GAgain",              gradeOfOutcome Incorrect 1 False 0, GAgain)
        , ("Skipped -> GAgain",                gradeOfOutcome Skipped 1 False 0,   GAgain)
        , ("Completed -> GGood",               gradeOfOutcome Completed 0 False 0, GGood)
        , ("Correct revealed attempt1 -> GHard", gradeOfOutcome Correct 1 True 0,  GHard)
        , ("Correct revealed attempt2 -> GHard", gradeOfOutcome Correct 2 True 3,  GHard)
        , ("Correct attempt2 clean -> GHard",  gradeOfOutcome Correct 2 False 0,   GHard)
        , ("Correct attempt1 hints -> GGood",  gradeOfOutcome Correct 1 False 2,   GGood)
        , ("Correct first-try clean -> GEasy", gradeOfOutcome Correct 1 False 0,   GEasy)
        ]
  forM_ cases $ \(nm, got, want) ->
    record cl 2 nm (got == want) ("got " ++ show got ++ " want " ++ show want)

fixedHistory :: [ProgressEvent]
fixedHistory =
  [ mkEv (Just "q-1-01#1") Correct   1 False 0 (day 10)
  , mkEv (Just "q-1-01#2") Incorrect 1 False 0 (day 10)
  , mkEv (Just "q-1-02#1") Correct   2 False 1 (day 11)
  , mkEv Nothing           Completed 0 False 0 (day 11)
  , mkEv (Just "q-1-01#2") Correct   2 False 0 (day 12)
  , mkEv (Just "d-2-01#1") Correct   1 True  0 (day 12)
  ]

group3 :: CheckLog -> IO ()
group3 cl = do
  let s1 = applyEvents fixedHistory emptyProgress
      s2 = applyEvents fixedHistory emptyProgress
  record cl 3 "applyEvents is deterministic (two folds equal)" (s1 == s2) "states differ"
  record cl 3 "fixed history yields non-trivial state"
    (Map.size (psRecs s1) == 4 && Map.lookup "q-9-99" (psDone s1) == Just 1)
    ("recs=" ++ show (Map.size (psRecs s1)) ++ " done=" ++ show (Map.toList (psDone s1)))
  case decodeState (encodeState s1) of
    DecodeOk s' -> record cl 3 "decodeState . encodeState round trips" (s' == s1) "round-tripped state differs"
    DecodeEmpty -> record cl 3 "decodeState . encodeState round trips" False "DecodeEmpty"
    DecodeCorrupt r -> record cl 3 "decodeState . encodeState round trips" False ("DecodeCorrupt: " ++ T.unpack r)

group4 :: CheckLog -> IO ()
group4 cl = do
  let ra = rec0 2 3 2500; rb = (rec0 2 3 2500) { rcDue = DayNum 5 }
      mkSt prs = emptyProgress { psRecs = Map.fromList prs }
      stAB = mkSt [("b#1", ra { rcDue = DayNum 5 }), ("a#1", rb)]
      stBA = mkSt [("a#1", rb), ("b#1", ra { rcDue = DayNum 5 })]
      qAB = map fst (reviewQueue (DayNum 9) stAB)
      qBA = map fst (reviewQueue (DayNum 9) stBA)
  record cl 4 "same due day -> prompt-id order" (qAB == ["a#1", "b#1"]) (show qAB)
  record cl 4 "queue invariant under insertion order" (qAB == qBA) (show (qAB, qBA))
  let stMix = mkSt [("z#1", ra { rcDue = DayNum 2 }), ("a#1", rb { rcDue = DayNum 5 })]
      qMix = map fst (reviewQueue (DayNum 9) stMix)
  record cl 4 "earlier due day sorts first regardless of id" (qMix == ["z#1", "a#1"]) (show qMix)
  let stFuture = mkSt [("f#1", ra { rcDue = DayNum 99 })]
  record cl 4 "not-yet-due prompts are excluded" (null (reviewQueue (DayNum 9) stFuture)) "future item leaked into queue"

group5 :: CheckLog -> IO ()
group5 cl = do
  let cases =
        [ ("first ever",   bumpStreak (DayNum 7) (DayNum 0) 0, (DayNum 7, 1))
        , ("same day",     bumpStreak (DayNum 7) (DayNum 7) 3, (DayNum 7, 3))
        , ("next day",     bumpStreak (DayNum 8) (DayNum 7) 3, (DayNum 8, 4))
        , ("gap resets",   bumpStreak (DayNum 12) (DayNum 7) 3, (DayNum 12, 1))
        , ("backwards day unchanged", bumpStreak (DayNum 5) (DayNum 7) 3, (DayNum 7, 3))
        ]
  forM_ cases $ \(nm, got, want) ->
    record cl 5 nm (got == want) ("got " ++ show got ++ " want " ++ show want)

group6 :: CheckLog -> IO ()
group6 cl = do
  -- NEW4: day zero is the RESERVED unset sentinel; no input reaches it.
  record cl 6 "dayOf 0 -> DayNum 1 (day zero reserved as sentinel)" (dayOf 0 == DayNum 1) (show (dayOf 0))
  record cl 6 "dayOf negative -> DayNum 1" (dayOf (-5) == DayNum 1) (show (dayOf (-5)))
  record cl 6 "dayOf 86400000 -> DayNum 1" (dayOf 86400000 == DayNum 1) (show (dayOf 86400000))
  record cl 6 "dayOf 2026-08-07T00:00Z (1785974400000) -> DayNum 20671"
    (dayOf 1785974400000 == DayNum 20671) (show (dayOf 1785974400000))
  record cl 6 "two times on the same UTC day map equal"
    (dayOf (day 20671) == dayOf (toInteger (20671 :: Int) * 86400000 + 82800000)) "same-day times differ"
  -- NEW1: overflow-domain inputs clamp at dayCap and NEVER wrap.
  record cl 6 "dayOf huge epoch clamps to dayCap" (dayOf (10 ^ (18 :: Int)) == DayNum dayCap) (show (dayOf (10 ^ (18 :: Int))))
  record cl 6 "addDays at dayCap stays at dayCap (no wrap)"
    (addDays (DayNum dayCap) 180 == DayNum dayCap) (show (addDays (DayNum dayCap) 180))
  -- NEW1 end-to-end: an event at the far clamp still yields a state the
  -- codec can round-trip -- the exact non-roundtrippable scenario the
  -- gate demonstrated (negative due emitted, then skipped on decode).
  let stFar = applyEvent (mkEv (Just "far#1") Correct 1 False 0 (10 ^ (18 :: Int))) emptyProgress
  case decodeState (encodeState stFar) of
    DecodeOk st' -> record cl 6 "overflow-domain event round-trips through the codec"
      (st' == stFar && maybe False ((>= 0) . unDayNum . rcDue) (Map.lookup "far#1" (psRecs st')))
      "round-tripped state differs or negative due"
    other -> record cl 6 "overflow-domain event round-trips through the codec" False (resultTag other)
  -- NEW4 end-to-end: the first-day contract holds even for an epoch-0
  -- event -- a later event must NOT overwrite psFirstDay.
  let stZero = applyEvents [ mkEv (Just "z#1") Correct 1 False 0 0
                           , mkEv (Just "z#1") Correct 1 False 0 (day 7) ] emptyProgress
  record cl 6 "psFirstDay set by an epoch-0 event survives a later event"
    (psFirstDay stZero == DayNum 1) (show (psFirstDay stZero))

group7 :: CheckLog -> IO ()
group7 cl = do
  let isCorrupt r = case r of { DecodeCorrupt _ -> True; _ -> False }
  record cl 7 "missing header -> DecodeCorrupt"
    (isCorrupt (decodeState "R\tq-1-01#1\t1\t0\t2500\t1\t3\t2\t1\n")) "not corrupt"
  record cl 7 "empty -> DecodeEmpty" (decodeState "" == DecodeEmpty) "not empty"
  record cl 7 "whitespace -> DecodeEmpty" (decodeState "  \n \t \n" == DecodeEmpty) "not empty"
  record cl 7 "version 0 -> DecodeCorrupt"
    (isCorrupt (decodeState "SXC1PROGRESS\t0\nM\t1\t1\t1\n")) "not corrupt"
  record cl 7 "version currentSchema+1 -> DecodeCorrupt"
    (isCorrupt (decodeState ("SXC1PROGRESS\t" <> T.pack (show (currentSchema + 1)) <> "\n"))) "not corrupt"
  let blobUnknownTag = "SXC1PROGRESS\t1\nX\tfuture-thing\t42\nM\t3\t2\t1\nR\tq-1-01#1\t1\t0\t2500\t1\t3\t2\t1\n"
  case decodeState blobUnknownTag of
    DecodeOk st -> do
      record cl 7 "unknown tag skipped, M still decodes" (psStreakLen st == 2) ("streakLen " ++ show (psStreakLen st))
      record cl 7 "unknown tag skipped, R still decodes" (Map.member "q-1-01#1" (psRecs st)) "R record lost"
    other -> record cl 7 "unknown tag skipped (decodes at all)" False (resultTag other)
  let blobTruncR = "SXC1PROGRESS\t1\nR\tq-1-01#1\t1\t0\t2500\nR\tq-1-02#1\t1\t0\t2500\t1\t3\t2\t1\nD\td-1\t2\n"
  case decodeState blobTruncR of
    DecodeOk st -> do
      record cl 7 "truncated R line skipped without losing siblings"
        (not (Map.member "q-1-01#1" (psRecs st)) && Map.member "q-1-02#1" (psRecs st) && Map.lookup "d-1" (psDone st) == Just 2)
        ("recs=" ++ show (Map.keys (psRecs st)))
    other -> record cl 7 "truncated R line (decodes at all)" False (resultTag other)

roundTripEscape :: Text -> Text
roundTripEscape = jsonUnescape . jsonEscape

resultTag :: DecodeResult -> String
resultTag DecodeEmpty       = "DecodeEmpty"
resultTag (DecodeOk _)      = "DecodeOk"
resultTag (DecodeCorrupt r) = "DecodeCorrupt: " ++ T.unpack r

group8 :: CheckLog -> IO ()
group8 cl = do
  let base = emptyProgress { psStreakLen = 7 }
      testSteps n
        | n == 0    = Just (\st -> st { psStreakLen = psStreakLen st + 100 })
        | n == 1    = Just (\st -> st { psStreakLen = psStreakLen st + 1000 })
        | otherwise = Nothing
  case migrateWith testSteps 0 base of
    DecodeOk st -> do
      record cl 8 "migrateWith applies the FULL step chain (0->1->2)" (psStreakLen st == 1107) ("streakLen " ++ show (psStreakLen st))
      record cl 8 "migration normalises psVersion to currentSchema"
        (psVersion st == SchemaVersion currentSchema) "version not normalised"
    other -> record cl 8 "migrateWith applies the step chain" False (resultTag other)
  let noSteps _ = Nothing :: Maybe (ProgressState -> ProgressState)
  case migrateWith noSteps 0 base of
    DecodeCorrupt _ -> record cl 8 "missing hop -> DecodeCorrupt (chain really runs)" True ""
    other           -> record cl 8 "missing hop -> DecodeCorrupt (chain really runs)" False (resultTag other)
  case migrate 0 base of
    DecodeCorrupt _ -> record cl 8 "productionSteps has no v0 step (schema-0 blob is corrupt today)" True ""
    other           -> record cl 8 "productionSteps has no v0 step (schema-0 blob is corrupt today)" False (resultTag other)
  -- The REAL v1->v2 production migration (M3 gate NEW12's schema bump):
  -- a v1 blob (3-field M line, no lastPrompt) decodes as current-schema
  -- state with psLastPrompt defaulted "" -- the mechanism's first
  -- genuine production use.
  let v1blob = "SXC1PROGRESS\t1\nM\t3\t2\t1\nR\tq-1-01#1\t1\t0\t2500\t1\t3\t2\t1\n"
  case decodeState v1blob of
    DecodeOk st -> record cl 8 "a real v1 blob migrates to v2 (lastPrompt defaults empty, records intact)"
      (psVersion st == SchemaVersion currentSchema && psLastPrompt st == "" && Map.member "q-1-01#1" (psRecs st))
      ("version/lastPrompt/recs: " ++ show (psLastPrompt st))
    other -> record cl 8 "a real v1 blob migrates to v2 (lastPrompt defaults empty, records intact)" False (resultTag other)

group9 :: CheckLog -> IO ()
group9 cl = do
  let s1 = applyEvents fixedHistory emptyProgress
      envelope = exportBlob "2026-08-07T12:00:00Z \"quoted\"" s1
  case importBlob envelope of
    DecodeOk s' -> record cl 9 "envelope round trip" (s' == s1) "state differs after envelope round trip"
    other       -> record cl 9 "envelope round trip" False (resultTag other)
  case importBlob (encodeState s1) of
    DecodeOk s' -> record cl 9 "bare wire blob import" (s' == s1) "state differs after bare import"
    other       -> record cl 9 "bare wire blob import" False (resultTag other)
  record cl 9 "envelope payload is escaped (no raw newline/tab inside payload field)"
    (not ("\n" `T.isInfixOf` payloadField envelope) && not ("\t" `T.isInfixOf` payloadField envelope))
    (T.unpack (T.take 120 (payloadField envelope)))
  -- M3 gate NEW7: the previous label claimed quote coverage the payload
  -- never had (wire text is ids+ints; quotes can only enter via the
  -- stamp). Honest split: the stamp path (above) carries the quote, and
  -- the ESCAPER ITSELF is round-tripped here on all five escapes.
  let gnarly = "a\"b\\c\nd\te\rf" :: Text
  record cl 9 "jsonUnescape . jsonEscape is identity on all five escapes (quote, backslash, newline, tab, CR)"
    (roundTripEscape gnarly == gnarly) (T.unpack (roundTripEscape gnarly))
  case importBlob "{\"format\":\"sxc1-progress\"}" of
    DecodeCorrupt _ -> record cl 9 "envelope without payload -> DecodeCorrupt" True ""
    other           -> record cl 9 "envelope without payload -> DecodeCorrupt" False (resultTag other)
  where
    payloadField blob = case T.breakOn "\"payload\":\"" blob of
      (_, rest) -> T.takeWhile (/= '"') (T.drop (T.length ("\"payload\":\"" :: Text)) rest)

group10 :: CheckLog -> IO ()
group10 cl = do
  record cl 10 "decodePrefs \"\" is defaultPrefs (jaFirst OFF)"
    (decodePrefs "" == defaultPrefs && not (prfJaFirst defaultPrefs)) "default is not OFF"
  record cl 10 "prefs round trip (True)"
    (prfJaFirst (decodePrefs (encodePrefs (Prefs True)))) "True did not survive"
  record cl 10 "prefs round trip (False)"
    (not (prfJaFirst (decodePrefs (encodePrefs (Prefs False))))) "False did not survive"
  record cl 10 "short header -> defaults"
    (decodePrefs "SXC1PREFS\n" == defaultPrefs) "short header not defaulted"
  record cl 10 "version above prefsSchema -> defaults"
    (decodePrefs ("SXC1PREFS\t" <> T.pack (show (prefsSchema + 1)) <> "\nP\tjaFirst\t1\n") == defaultPrefs)
    "future version was honoured"
  record cl 10 "unknown P name skipped while jaFirst still decodes"
    (prfJaFirst (decodePrefs "SXC1PREFS\t1\nP\tfontSize\tbig\nP\tjaFirst\t1\n")) "jaFirst lost after unknown name"

group11 :: CheckLog -> IO ()
group11 cl = do
  -- M3 gate NEW3 hardening: the module list is discovered from disk (a
  -- new module cannot dodge by not being listed), the scan is
  -- CASE-INSENSITIVE with comment text stripped per line (not just
  -- comment-prefixed lines), and the needle list covers qualified Miso
  -- imports, more clock APIs, and the float/Double family outright.
  -- Recursive walk (re-gate NEW3 residual: a module hidden in a
  -- subdirectory must not dodge discovery).
  hsFiles <- walkHs "src/SXC1/Progress"
  record cl 11 "purity guard discovers at least the three known modules from disk"
    (length hsFiles >= 3) (show hsFiles)
  forM_ hsFiles $ \f -> do
    src <- readFile f
    let codeOf ln = T.toLower (fst (T.breakOn "--" (T.pack ln)))
        needles = [ "import miso", "import qualified miso"
                  , "getmonotonictimensec", "data.time", "cputime", "getcurrenttime"
                  , "unsafeperformio", "data.ioref", "system.io"
                  , "double", "float", "fromintegral", "realtofrac" ]
        -- Tokenized scan (re-gate NEW3 residual: `touch :: IO ()` has
        -- none of the substrings above -- but its type names the IO
        -- token, which no pure Progress module may do outside comments).
        tokensOf c = T.split (\ch -> not (ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9'))) c
        badToken c = "io" `elem` tokensOf c
        offenders = [ ln | ln <- lines src, let c = codeOf ln
                    , any (`T.isInfixOf` c) needles || badToken c ]
    record cl 11 (f ++ " has no IO/Miso/clock/float reachability on non-comment text (substring + io-token scan)")
      (null offenders) (unlines (take 3 offenders))

-- | M3 gate NEW2: pin EVERY field of the transition, not just ease. One
-- event from fresh, full-Rec equality; then a lapse; then the streak
-- and first-day state fields.
group12 :: CheckLog -> IO ()
group12 cl = do
  let d10 = dayOf (day 10)
      st1 = applyEvent (mkEv (Just "t#1") Correct 1 False 0 (day 10)) emptyProgress
      wantFresh = Rec { rcReps = 1, rcLapses = 0, rcEase = 2600, rcInterval = 2
                      , rcDue = addDays d10 2, rcLastSeen = d10, rcSeen = 1 }
  record cl 12 "one GEasy from fresh: FULL Rec equality (reps/lapses/ease/interval/due/lastSeen/seen)"
    (Map.lookup "t#1" (psRecs st1) == Just wantFresh)
    (maybe "missing" (\r -> "reps=" ++ show (rcReps r) ++ " ease=" ++ show (rcEase r)
       ++ " intv=" ++ show (rcInterval r) ++ " due=" ++ show (unDayNum (rcDue r))
       ++ " last=" ++ show (unDayNum (rcLastSeen r)) ++ " seen=" ++ show (rcSeen r))
       (Map.lookup "t#1" (psRecs st1)))
  let st2 = applyEvent (mkEv (Just "t#1") Incorrect 1 False 0 (day 11)) st1
      wantLapse = Rec { rcReps = 0, rcLapses = 1, rcEase = 2280, rcInterval = 0
                      , rcDue = dayOf (day 11), rcLastSeen = dayOf (day 11), rcSeen = 2 }
  record cl 12 "a lapse after one rep: FULL Rec equality (reps reset, lapses+1, ease 2600-320, due today)"
    (Map.lookup "t#1" (psRecs st2) == Just wantLapse)
    (maybe "missing" (\r -> "reps=" ++ show (rcReps r) ++ " lapses=" ++ show (rcLapses r)
       ++ " ease=" ++ show (rcEase r) ++ " due=" ++ show (unDayNum (rcDue r))) (Map.lookup "t#1" (psRecs st2)))
  record cl 12 "state fields after the two events: streakDay/streakLen/firstDay pinned"
    (psStreakDay st2 == dayOf (day 11) && psStreakLen st2 == 2 && psFirstDay st2 == d10)
    ("streak=" ++ show (unDayNum (psStreakDay st2)) ++ "/" ++ show (psStreakLen st2)
      ++ " first=" ++ show (unDayNum (psFirstDay st2)))
  record cl 12 "psLastPrompt tracks the last graded prompt" (psLastPrompt st2 == "t#1")
    (T.unpack (psLastPrompt st2))
  let st3 = applyEvent (mkEv Nothing Completed 0 False 0 (day 11)) st2
  -- M3 re-gate NEW2 residual: TOTAL isolation -- st3 with psDone rolled
  -- back must equal st2 exactly, so a Completed touching ANY other
  -- field (version, streak, firstDay, lastPrompt, recs...) fails.
  record cl 12 "a promptless Completed changes psDone and NOTHING else (total-state check)"
    (psDone st3 == Map.insertWith (+) "q-9-99" 1 (psDone st2)
      && st3 { psDone = psDone st2 } == st2)
    "Completed touched a field other than psDone"
  -- M3 re-gate NEW1 residual (extended round-3): an imported blob
  -- carrying absurd (but Int-parseable) values is clamped into semantic
  -- domains on decode -- EVERY numeric field is pinned exactly (R's
  -- seven, D's count, M's three -- NEW16), so no single clamp can be
  -- removed without a red here, and the scheduler can never overflow an
  -- Int multiply (or bumpStreak's +1) from imported data.
  let hostileR = "SXC1PROGRESS\t2\nM\t2000000000\t2000000000\t2000000000\tx#1\nR\thuge#1\t2000000000\t2000000000\t2000000000\t2000000000\t2000000000\t2000000000\t2000000000\nD\thuge-d\t2000000000\n"
      hostileName = "hostile imported values clamp to semantic domains (all R/D/M fields pinned)"
  case decodeState hostileR of
    DecodeOk st -> case Map.lookup "huge#1" (psRecs st) of
      Just rc -> record cl 12 hostileName
        (rcReps rc == 1000000 && rcLapses rc == 1000000 && rcEase rc == 3000
          && rcInterval rc == 180 && unDayNum (rcDue rc) == dayCap
          && unDayNum (rcLastSeen rc) == dayCap && rcSeen rc == 1000000
          && Map.lookup "huge-d" (psDone st) == Just 1000000
          && unDayNum (psStreakDay st) == dayCap && psStreakLen st == 1000000
          && unDayNum (psFirstDay st) == dayCap && psLastPrompt st == "x#1")
        ("ease=" ++ show (rcEase rc) ++ " lap=" ++ show (rcLapses rc)
          ++ " seen=" ++ show (rcSeen rc) ++ " streakLen=" ++ show (psStreakLen st)
          ++ " done=" ++ show (Map.lookup "huge-d" (psDone st)))
      Nothing -> record cl 12 hostileName False "record dropped"
    other -> record cl 12 hostileName False (resultTag other)
  -- Round-4 NEW16: the THREE-FIELD v1 M arm clamps too -- a schema-1
  -- hostile blob exercises the v1 parse arm plus the real v1->v2
  -- migration path, so stripping the clamps from only the v1 arm
  -- (leaving v2's intact) goes red here, not silently green.
  let hostileV1 = "SXC1PROGRESS\t1\nM\t2000000000\t2000000000\t2000000000\n"
      hostileV1Name = "hostile v1 blob clamps via the three-field M arm (and migrates)"
  case decodeState hostileV1 of
    DecodeOk st -> record cl 12 hostileV1Name
      (unDayNum (psStreakDay st) == dayCap && psStreakLen st == 1000000
        && unDayNum (psFirstDay st) == dayCap && psLastPrompt st == ""
        && psVersion st == SchemaVersion 2)
      ("streakDay=" ++ show (unDayNum (psStreakDay st)) ++ " len=" ++ show (psStreakLen st)
        ++ " first=" ++ show (unDayNum (psFirstDay st)))
    other -> record cl 12 hostileV1Name False (resultTag other)
  -- Round-3 addDays totality: DayNum(..) is exported, so the contract
  -- must hold for ARBITRARY Ints, not just decoded ones -- maxBound + 1
  -- previously wrapped on wasm32 before the clamp could see it.
  record cl 12 "addDays is total on all of Int (maxBound operands clamp, never wrap)"
    (addDays (DayNum maxBound) 1 == DayNum dayCap
      && addDays (DayNum 1) maxBound == DayNum dayCap
      && addDays (DayNum maxBound) maxBound == DayNum dayCap
      && addDays (DayNum (-5)) 3 == DayNum 3)
    (show (unDayNum (addDays (DayNum maxBound) 1)))

walkHs :: FilePath -> IO [FilePath]
walkHs dir = do
  entries <- listDirectory dir
  fmap concat . forM entries $ \e -> do
    let path = dir ++ "/" ++ e
    isDir <- doesDirectoryExist path
    if isDir then walkHs path
    else pure [ path | ".hs" `isSuffixOf` e ]

--------------------------------------------------------------------------
-- --replay: minimal flat-object JSON array reader for #sxc1-event-log
--------------------------------------------------------------------------

replay :: FilePath -> IO ()
replay fp = do
  raw <- TIO.readFile fp
  let evs = map objToEvent (splitObjects raw)
  TIO.putStr (encodeState (applyEvents evs emptyProgress))

-- The event log is a flat JSON array of flat objects with only string /
-- number / bool / null fields (see Main.hs's eventJson) -- objects never
-- nest, so brace-splitting is sound here (and this binary is host-side
-- test tooling, never linked into the app).
splitObjects :: Text -> [Text]
splitObjects t = go (T.unpack t) [] [] (0 :: Int) False
  where
    go [] _cur acc _ _ = reverse acc
    go (c : rest) cur acc depth inStr
      | inStr && c == '\\' = case rest of
          (d : rest') -> go rest' (d : c : cur) acc depth True
          []          -> reverse acc
      | inStr && c == '"'  = go rest (c : cur) acc depth False
      | inStr              = go rest (c : cur) acc depth True
      | c == '"'           = go rest (c : cur) acc depth True
      | c == '{'           = go rest (if depth == 0 then "{" else c : cur) acc (depth + 1) False
      | c == '}'           = if depth == 1
          then go rest [] (T.pack (reverse ('}' : cur)) : acc) 0 False
          else go rest (c : cur) acc (max 0 (depth - 1)) False
      | otherwise          = go rest (if depth > 0 then c : cur else cur) acc depth False

jsonField :: Text -> Text -> Maybe Text
jsonField key obj =
  let marker = "\"" <> key <> "\":"
      (_, rest) = T.breakOn marker obj
  in if T.null rest then Nothing
     else Just (T.strip (T.takeWhile (\c -> c /= ',' && c /= '}') (T.drop (T.length marker) rest)))

jsonStr :: Text -> Text -> Maybe Text
jsonStr key obj = do
  v <- jsonField key obj
  if "\"" `T.isPrefixOf` v then Just (T.dropEnd 1 (T.drop 1 v)) else Nothing

-- Parses directly into 'Integer' -- NOT via a 32-bit 'Int' 'read':
-- epoch-millisecond values (~1.8e12) overflow wasm32's 'Int' silently
-- (the M1-NEW8 class; this binary RUNS on wasm32 under wasm-run.mjs),
-- which this function's first version did and the replay smoke test
-- caught as day-0 records.
jsonInt :: Text -> Text -> Integer
jsonInt key obj = case jsonField key obj of
  Just v ->
    let digits = T.takeWhile (\c -> c >= '0' && c <= '9') v
    in T.foldl' (\acc c -> acc * 10 + toInteger (fromEnum c - fromEnum '0')) 0 digits
  Nothing -> 0

objToEvent :: Text -> ProgressEvent
objToEvent o = ProgressEvent
  { peDeck     = DeckId (maybe "?" id (jsonStr "deck" o))
  , peExercise = ExId (maybe "?" id (jsonStr "exercise" o))
  , pePrompt   = PromptId <$> jsonStr "prompt" o
  , peKind     = KQuiz  -- kind does not influence the scheduler
  , peOutcome  = case jsonStr "outcome" o of
      Just "correct"   -> Correct
      Just "incorrect" -> Incorrect
      Just "skipped"   -> Skipped
      _                -> Completed
  , peAttempt  = fromInteger (jsonInt "attempt" o)
  , peRevealed = jsonField "revealed" o == Just "true"
  , peHints    = fromInteger (jsonInt "hints" o)
  , peElapsed  = fromInteger (jsonInt "elapsedMs" o)
  , peAt       = jsonInt "at" o
  }

--------------------------------------------------------------------------
-- main
--------------------------------------------------------------------------

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--replay", fp] -> replay fp
    _ -> do
      cl <- CheckLog <$> newIORef []
      group1 cl; group2 cl; group3 cl; group4 cl; group5 cl; group6 cl
      group7 cl; group8 cl; group9 cl; group10 cl; group11 cl; group12 cl
      checks <- readIORef (clChecks cl)
      let totalOk = length [ () | (_, _, True, _) <- checks ]
          total   = length checks
          emptyGroups = [ g | g <- groupRange, null [ () | (g', _, _, _) <- checks, g' == g ] ]
          failed = total - totalOk
      forM_ groupRange $ \g -> do
        let inG = [ ok | (g', _, ok, _) <- checks, g' == g ]
        putStrLn ("group " ++ show g ++ " (" ++ assertionLabel g ++ "): "
                  ++ show (length [ () | True <- inG ]) ++ "/" ++ show (length inG))
      putStrLn ("progress-check: " ++ show totalOk ++ "/" ++ show total ++ " checks passed")
      unless (null emptyGroups) $ do
        hPutStrLn stderr ("progress-check: EMPTY assertion group(s): " ++ show emptyGroups ++ " (NEW12 guard)")
        exitFailure
      unless (failed == 0) exitFailure
