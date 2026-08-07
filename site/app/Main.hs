{-# LANGUAGE CPP               #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import           Data.IORef            (modifyIORef', newIORef, readIORef)
import           Data.List              (find)
import qualified Data.Map.Strict        as Map
import           Data.Map.Strict        (Map)
import qualified Data.Text              as T
import           Data.Text              (Text)

import           GHC.Clock              (getMonotonicTimeNSec)

import           Miso
import qualified Miso.Date              as Date

import           SXC1.Exercise.Engine
import           SXC1.Exercise.Types
import           SXC1.Progress.Codec    (DecodeResult (..), Prefs (..), currentSchema,
                                         exportBlob, importBlob)
import           SXC1.Progress.Scheduler (applyEvents, dueCount, retention, reviewQueue)
import           SXC1.Progress.Types    (DayNum (..), ProgressState (..), dayOf, emptyProgress)
import           SXC1.Route             (Route (..), parseDigits, parseRoute, renderRoute)

import           Progress.Store         (loadPrefs, loadProgress, savePrefs, saveProgress,
                                         storageAvailable, wipeProgress)

import           Exercises.Corpus       (exerciseCorpus, exerciseStatsJson, jArr, jBool, jInt, jInteger, jKV, jObj,
                                          jStr)
import           View.Exercise          (ExHandlers (..))
import qualified View.Exercise          as Exercise
import           View.Pages             (viewRoute)

-- | Read window.location.hash via Miso's own DSL.
--
-- MEASURED (briefs/M1-plan.md P4): a raw FFI `foreign` `import` binding
-- returning 'GHC.Wasm.Prim.JSString' does not link on this toolchain (GHC
-- emits a C stub referencing HsJSString\/rts_mkJSString that
-- wasm32-wasi-clang rejects). 'jsg', '(!)', 'fromJSValUnchecked' and
-- 'MisoString'\/'fromMisoString' are all re-exported by @import Miso@, so
-- no further imports are needed here.
currentHash :: IO T.Text
currentHash = do
  loc <- jsg ("window" :: MisoString) ! ("location" :: MisoString)
  h   <- fromJSValUnchecked =<< loc ! ("hash" :: MisoString)
  pure (fromMisoString (h :: MisoString))

-- | Write window.location.hash. Assigning it (rather than pushState) is
-- ordinary browser navigation -- it updates the address bar, pushes a
-- history entry and fires \"hashchange\" like any other hash change -- so
-- the JA toggle's state stays a real, shareable deep link instead of
-- an in-memory-only flag.
setHash :: T.Text -> IO ()
setHash h = do
  loc <- jsg ("window" :: MisoString) ! ("location" :: MisoString)
  setProp ("hash" :: MisoString) (ms h) (Object loc)

--------------------------------------------------------------------------
-- Clocks (briefs/M2-manifest.json, task "exercise-ui").
--
-- Monotonic elapsed time: 'GHC.Clock.getMonotonicTimeNSec' (base --
-- always visible). Wall-clock epoch: NOT 'Data.Time.Clock.POSIX' --
-- MEASURED against the real committed site/sxc1-trainer.cabal (not
-- owned by this task): exe:app's build-depends does not list the `time`
-- package, and importing Data.Time.Clock.POSIX anywhere in site/app
-- fails to compile with "Could not load module 'Data.Time.Clock.POSIX'
-- ... hidden package 'time'" (confirmed empirically; see this task's
-- final report). 'Miso.Date' (already exposed by the `miso` dependency
-- exe:app DOES have) wraps the browser's own JS Date object through
-- Miso's ordinary JS DSL -- NOT a `foreign import javascript` -- so
-- 'Date.getTime' gives the same milliseconds-since-epoch value
-- 'Data.Time.Clock.POSIX.getPOSIXTime' would have, without the missing
-- dependency. The engine itself ("SXC1.Exercise.Engine") stays pure: it
-- never reads a clock itself, only ever receives already-read 'Integer'
-- millisecond values as action arguments, exactly as specified.
--------------------------------------------------------------------------

-- | H1: returns the DISTINCT 'MonoMs'\/'WallMs' newtypes (not a bare
-- @(Integer, Integer)@ pair) precisely so a call site can no longer pick
-- the wrong half by position -- @'Begin' . 'snd'@ (the exact H1 defect:
-- seeding a fresh attempt's prompt clock from the WALL epoch instead of
-- the monotonic one 'gradeStep' subtracts against) no longer typechecks,
-- because 'snd' on this pair yields a 'WallMs' and every clock-consuming
-- 'SXC1.Exercise.Engine.ExerciseAction' constructor wants its first
-- clock argument as 'MonoMs'.
readClocks :: IO (MonoMs, WallMs)
readClocks = do
  monoNs <- getMonotonicTimeNSec
  d      <- Date.new
  wallMs <- Date.getTime d
  pure (MonoMs (toInteger monoNs `div` 1000000), WallMs (round wallMs))

--------------------------------------------------------------------------
-- THE M4 FORWARD HOOK (briefs/M2-manifest.json). Parsed and validated in
-- M2 ("SXC1.Exercise.Verify"), executed in M4. 'noDeviceVerifier' is
-- wired in below; no WebMIDI call and no device permission request
-- exists anywhere in site/app -- the manual confirmation path (a
-- learner clicking a .btn-ex-confirm button) is the only path in M2 and
-- must, and does, work on every browser.
--------------------------------------------------------------------------

data DeviceVerifier = DeviceVerifier
  { dvAvailable :: IO Bool
  , dvWatch     :: VerifySpec -> (ConfirmSource -> IO ()) -> IO (IO ())
  }

noDeviceVerifier :: DeviceVerifier
noDeviceVerifier = DeviceVerifier
  { dvAvailable = pure False
  , dvWatch     = \_spec _onConfirm -> pure (pure ())
  }

--------------------------------------------------------------------------
-- THE M3 FORWARD HOOK. One in-memory 'ProgressSink' over an 'IORef',
-- capped at 200 events. M2 persists nothing: 'sinkLoad' is never called
-- by this module (nothing in M2 needs to read progress back), and
-- nothing else in the app writes progress -- 'applyExAction' below is
-- the single call site for 'sinkRecord'. The Model keeps its OWN capped
-- mirror of the same events ('mEventLog') purely because Miso's
-- 'viewModel' is a pure function of 'Model' and cannot read an 'IORef'
-- at render time; the two are always fed the identical event list in
-- the same handler, so they never drift.
--------------------------------------------------------------------------

eventCap :: Int
eventCap = 200

capEvents :: [ProgressEvent] -> [ProgressEvent]
capEvents xs = let n = length xs in if n > eventCap then drop (n - eventCap) xs else xs

mkProgressSink :: IO ProgressSink
mkProgressSink = do
  ref <- newIORef []
  pure ProgressSink
    { sinkRecord = \ev -> modifyIORef' ref (capEvents . (++ [ev]))
    , sinkLoad   = readIORef ref
    }

--------------------------------------------------------------------------
-- Model / Action
--------------------------------------------------------------------------

-- | Keyed by the raw 'Text' underneath 'ExId'\/'PromptId' rather than
-- those newtypes themselves: "SXC1.Exercise.Types" derives only 'Eq'\/
-- 'Show' for them (its own size-discipline Haddock explains why), and
-- this task does not own that module to add 'Ord'.
data Model = Model
  { mRoute      :: !Route
  , mExStates   :: !(Map Text ExerciseState)
  , mExResults  :: !(Map Text (Outcome, Int))
  , mEventLog   :: ![ProgressEvent]
    -- M3 (task "storage-sink"):
  , mProgress   :: !ProgressState   -- ^ the folded spaced-repetition state
  , mLoad       :: !DecodeResult    -- ^ what startup 'loadProgress' saw; 'DecodeCorrupt' = read-only progress mode
  , mStorageOk  :: !Bool            -- ^ 'storageAvailable' probe result
  , mPrefs      :: !Prefs           -- ^ reader preference (separate key)
  , mToday      :: !DayNum          -- ^ set at startup, advanced by events' own 'peAt' days
  , mBooted     :: !Bool            -- ^ False only until the mount 'SetRoute' has run (JA-first needs to tell mount from toggle-echo)
  , mExportBlob :: !(Maybe Text)    -- ^ last requested export envelope, for the view to render
  , mImportMsg  :: !(Maybe Text)    -- ^ last import's failure reason, for the view to render
  } deriving (Eq)

unDeckId :: DeckId -> Text
unDeckId (DeckId t) = t

unExId :: ExId -> Text
unExId (ExId t) = t

unPromptId :: PromptId -> Text
unPromptId (PromptId t) = t

-- | Two exercise-action constructors cover everything the runner needs
-- (kept to two, rather than one per 'ExerciseAction' shape, to hold
-- app.wasm's size down -- see this task's final report): 'ExBatch' applies
-- an already-resolved list of engine actions in order against the SAME
-- pre-batch state (so e.g. a drill confirm's 'ConfirmStep' immediately
-- followed by 'Advance' is one undivided step from the learner's
-- perspective); 'ExClocked' reads both clocks once and then dispatches
-- an 'ExBatch' built from them -- covers Submit\/SelfGrade_\/ConfirmStep\/
-- SubmitPage\/Advance\/Restart\/Begin uniformly.
data Action
  = HashChanged
  | SetRoute Route
  | ToggleJA
  | NoOp
  | ExBatch ExId [ExerciseAction]
  | ExClocked ExId (MonoMs -> WallMs -> [ExerciseAction])
    -- M3: ONE additional constructor wrapping every progress operation
    -- (the ExBatch/ExClocked two-constructor size discipline, applied
    -- again rather than five new constructors).
  | Prog ProgressOp

data ProgressOp
  = PExportReq          -- ^ learner asked for an export
  | PExportGot Text     -- ^ IO produced the envelope (stamped)
  | PImport Text        -- ^ learner submitted import text
  | PWipe               -- ^ learner confirmed a wipe
  | PJaFirst Bool       -- ^ learner flipped the JA-first reader preference

#ifdef WASM
foreign export javascript "hs_start" main :: IO ()
#endif

main :: IO ()
main = do
  h    <- currentHash
  sink <- mkProgressSink
  -- THE M4 FORWARD HOOK, wired in (never a WebMIDI call, never a device
  -- permission request -- 'dvAvailable' is a constant 'pure False' in M2):
  _ <- dvAvailable noDeviceVerifier
  -- M3 startup: probe storage by WRITING (see Progress.Store), load both
  -- blobs, and take today's day from a real wall reading. A corrupt
  -- progress blob puts the app into read-only progress mode from the
  -- first frame -- the blob on disk is never touched again until the
  -- learner explicitly wipes or imports.
  avail   <- storageAvailable
  loadRes <- loadProgress
  prefs   <- loadPrefs
  (_, WallMs wall0) <- readClocks
  let st0 = case loadRes of { DecodeOk s -> s; _ -> emptyProgress }
  startApp defaultEvents (readerApp sink avail loadRes st0 prefs (dayOf wall0) (parseRoute h))

-- | H6: a cold @RExercise@ route (a deep link, or the very first paint --
-- Miso's own \"hashchange\" DOM event never fires for the page's INITIAL
-- hash, only for later navigation) used to reach 'viewModel' without ever
-- calling 'beginIfNeeded', so its 'ExerciseState' came straight from
-- @'initialState' exid 0@ -- a zero 'MonoMs' baseline dated from the UNIX
-- epoch, not from display time. Miso's 'mount' field fires ONE action the
-- moment the component mounts (the initial paint), before any DOM event
-- can occur; dispatching the SAME 'SetRoute' the "hashchange" 'Sub' would
-- have dispatched for this route re-runs 'beginIfNeeded' exactly once at
-- startup, with a real 'readClocks' reading, closing the gap deliberately
-- instead of "correctly by coincidence" (a cold load happening to measure
-- runtime age as prompt age only because the browser's monotonic origin
-- is page load -- see this task's final report).
readerApp :: ProgressSink -> Bool -> DecodeResult -> ProgressState -> Prefs -> DayNum -> Route -> App Model Action
readerApp sink avail loadRes st0 prefs today0 r0 =
  (component model0 (updateModel sink) viewModel)
    { subs  = [ windowSub "hashchange" emptyDecoder (const HashChanged) ]
    , mount = Just (SetRoute r0)
    }
  where
    model0 = Model
      { mRoute = r0, mExStates = Map.empty, mExResults = Map.empty, mEventLog = []
      , mProgress = st0, mLoad = loadRes, mStorageOk = avail, mPrefs = prefs
      , mToday = today0, mBooted = False, mExportBlob = Nothing, mImportMsg = Nothing
      }

findExerciseById :: [Deck] -> ExId -> Maybe Exercise
findExerciseById decks eid = find ((== eid) . exId) (concatMap dkExercises decks)

safeIndexL :: [a] -> Int -> Maybe a
safeIndexL xs i
  | i < 0     = Nothing
  | otherwise = case drop i xs of { (x : _) -> Just x; [] -> Nothing }

updateModel :: ProgressSink -> Action -> Effect parent props Model Action
updateModel sink = \case
  HashChanged ->
    io (SetRoute . parseRoute <$> currentHash)

  NoOp -> pure ()

  SetRoute r -> do
    prev   <- gets mRoute
    booted <- gets mBooted
    ja     <- gets (prfJaFirst . mPrefs)
    -- M3 JA-first (owner addendum): a NAVIGATION DEFAULT, never a forced
    -- state. Redirect a plain page route to its /ja form only when the
    -- preference is on AND this is a genuinely fresh page navigation:
    -- either the mount dispatch (mBooted False -- prev EQUALS r there, so
    -- route comparison alone cannot see it) or a route whose slug/page
    -- differs from the previous one. The post-ToggleJA "hashchange" echo
    -- re-delivers the SAME slug+page with mBooted True, so it falls
    -- through and the toggle genuinely wins until the next page move --
    -- the exact preference-fights-toggle bug the manifest warns about.
    let freshPage slug n = not booted || case prev of
          RPage ps pn _ -> ps /= slug || pn /= n
          _             -> True
    case r of
      RPage slug n False | ja && freshPage slug n -> do
        let r' = RPage slug n True
        modify (\m -> m { mRoute = r', mBooted = True })
        io_ (setHash (renderRoute r'))
      _ -> modify (\m -> m { mRoute = r, mBooted = True })
    beginIfNeeded r
    io_ (scrollIntoView "app")

  Prog op -> handleProg op

  ToggleJA -> do
    r <- gets mRoute
    case r of
      RPage slug n ja -> do
        let r' = RPage slug n (not ja)
        modify (\m -> m { mRoute = r' })
        io_ (setHash (renderRoute r'))
      _ -> pure ()

  ExBatch exid acts -> applyExActions sink exid acts

  ExClocked exid mk -> io $ do
    (mono, wall) <- readClocks
    pure (ExBatch exid (mk mono wall))

-- | May THIS model save progress? True only when storage probed
-- available AND the startup load was not corrupt -- the never-overwrite-
-- what-you-could-not-decode rule. Import and wipe are the two explicit
-- learner actions that clear a corrupt 'mLoad'.
progressWritable :: Model -> Bool
progressWritable m = mStorageOk m && case mLoad m of
  DecodeCorrupt _ -> False
  _               -> True

handleProg :: ProgressOp -> Effect parent props Model Action
handleProg op = case op of
  PExportReq -> io $ do
    (_, WallMs wall) <- readClocks
    pure (Prog (PExportGot ("epoch-ms:" <> T.pack (show wall))))
  PExportGot stamp -> do
    st <- gets mProgress
    modify (\m -> m { mExportBlob = Just (exportBlob stamp st) })
  PImport raw -> case importBlob raw of
    DecodeOk st -> do
      modify (\m -> m { mProgress = st, mLoad = DecodeOk st
                      , mImportMsg = Nothing, mExportBlob = Nothing })
      writable <- gets mStorageOk
      io_ (if writable then saveProgress st else pure ())
    DecodeCorrupt reason -> modify (\m -> m { mImportMsg = Just reason })
    DecodeEmpty -> modify (\m -> m { mImportMsg = Just "import text was empty" })
  PWipe -> do
    -- An explicit learner decision: the stored key (corrupt or not) is
    -- removed and the app returns to a writable empty state. Prefs are
    -- untouched -- separate key, by design.
    modify (\m -> m { mProgress = emptyProgress, mLoad = DecodeEmpty
                    , mExportBlob = Nothing, mImportMsg = Nothing })
    io_ wipeProgress
  PJaFirst b -> do
    modify (\m -> m { mPrefs = Prefs b })
    io_ (savePrefs (Prefs b))

-- | On first navigation to an exercise (no state recorded for it yet),
-- seed a fresh attempt with a real wall-clock reading. Never re-fires
-- for an exercise that already has state -- this is what lets following
-- a citation into the manual reader and coming back preserve the
-- learner's prompt and selections (the model keys state by 'ExId', not
-- by "the current exercise", exactly per the acceptance criteria).
beginIfNeeded :: Route -> Effect parent props Model Action
beginIfNeeded (RExercise _ exSlug) = do
  let exid = ExId exSlug
  states <- gets mExStates
  if Map.member (unExId exid) states
    then pure ()
    else case findExerciseById exerciseCorpus exid of
      Nothing -> pure ()
      Just _  -> io $ do
        (mono, wall) <- readClocks
        pure (ExBatch exid [Begin mono wall])
beginIfNeeded _ = pure ()

-- | Apply a list of pure engine steps IN ORDER against one pre-batch
-- state, fold the combined state change into the model, record each
-- event's per-prompt outcome (for the runner's feedback), append the
-- events to the capped log, and forward them to the M3 sink -- the ONE
-- call site that ever touches 'sinkRecord'.
--
-- H7: 'Begin'\/'Restart' reset 'SXC1.Exercise.Engine.ExerciseState' but
-- (correctly -- see "SXC1.Exercise.Engine"'s Haddock) emit no
-- 'ProgressEvent', so 'mExResults' -- a flat, cross-exercise map keyed by
-- 'PromptId' text, never cleared on its own -- used to keep the PREVIOUS
-- attempt's outcome around: a learner who restarted saw a brand new,
-- unselected prompt that was ALREADY reporting "Correct.", with the
-- explanation and a working Next button, and could complete a "fresh"
-- attempt without answering. Fixed by clearing exactly this exercise's
-- prompt results (its 'PromptId's all share the @\<exercise-id\>#@
-- prefix -- see 'SXC1.Exercise.Types.promptIdFor') whenever the batch
-- contains a 'Begin' or 'Restart', rather than switching 'View.Exercise'
-- to a second, attempt-scoped result shape: this keeps the fix entirely
-- in the one place that already owns 'mExResults'' lifetime, and
-- "View.Exercise" (already correct: it only ever renders whatever
-- @mResult@ it is handed) needs no change at all.
applyExActions :: ProgressSink -> ExId -> [ExerciseAction] -> Effect parent props Model Action
applyExActions sink exid acts = case findExerciseById exerciseCorpus exid of
  Nothing -> pure ()
  Just ex -> do
    states <- gets mExStates
    let key            = unExId exid
        st0            = Map.findWithDefault (initialState exid (MonoMs 0)) key states
        (st1, evsAll)   = foldl' applyOne (st0, []) acts
        applyOne (st, evs) act = let (st', ev') = step ex act st in (st', evs ++ ev')
        startsFresh a = case a of { Begin _ _ -> True; Restart _ _ -> True; _ -> False }
        thisExPromptPrefix = key <> "#"
        clearStale = any startsFresh acts
        dropStale rs
          | clearStale = Map.filterWithKey (\k _ -> not (thisExPromptPrefix `T.isPrefixOf` k)) rs
          | otherwise  = rs
    -- M3: fold the new events into the spaced-repetition state and
    -- persist -- IF AND ONLY IF the model is writable (storage probed
    -- available and the startup load was not corrupt). Days advance from
    -- the events' own peAt (never a clock read here), so mToday tracks a
    -- midnight rollover mid-session as soon as the next event lands.
    prog0    <- gets mProgress
    writable <- gets progressWritable
    let prog1  = applyEvents evsAll prog0
        today' = foldr (max . dayOf . peAt) minDay evsAll
        minDay = DayNum 0
    modify (\m -> m
      { mExStates  = Map.insert key st1 (mExStates m)
      , mExResults = foldr recordResult (dropStale (mExResults m)) evsAll
      , mEventLog  = capEvents (mEventLog m ++ evsAll)
      , mProgress  = prog1
      , mToday     = max (mToday m) today'
      })
    io_ (mapM_ (sinkRecord sink) evsAll)
    io_ (if writable && not (null evsAll) then saveProgress prog1 else pure ())
  where
    recordResult ev acc = case pePrompt ev of
      Nothing  -> acc
      Just pid -> Map.insert (unPromptId pid) (peOutcome ev, peElapsed ev) acc

--------------------------------------------------------------------------
-- View
--------------------------------------------------------------------------

exHandlersFor :: ExId -> ExHandlers Action
exHandlersFor exid = ExHandlers
  { exOnToggle     = \i optIdent -> ExBatch exid [Toggle i optIdent]
  , exOnSubmit     = \i -> ExClocked exid (\mono wall -> [Submit i mono wall])
  , exOnReveal     = \i -> ExBatch exid [Reveal i]
  , exOnGot        = \i -> ExClocked exid (\mono wall -> [SelfGrade_ i Got mono wall])
  , exOnMissed     = \i -> ExClocked exid (\mono wall -> [SelfGrade_ i Missed mono wall])
  , exOnConfirm    = \i -> ExClocked exid (\mono wall -> [ConfirmStep i ByLearner mono wall, Advance mono wall])
  , exOnFindInput  = \i txt -> case parseDigits (fromMisoString txt) of
      Just n  -> ExBatch exid [EnterPage i n]
      Nothing -> NoOp
  , exOnFindSubmit = \i -> ExClocked exid (\mono wall -> [SubmitPage i mono wall])
  , exOnShowHint   = \i -> ExBatch exid [ShowHint i]
  , exOnNext       = ExClocked exid (\mono wall -> [Advance mono wall])
  , exOnRestart    = ExClocked exid (\mono wall -> [Restart mono wall])
  }

-- | The current prompt's last graded result, if any -- looked up by
-- 'PromptId' text so the runner never re-derives correctness itself
-- (see "View.Exercise"'s Haddock).
currentResult :: Model -> ExId -> ExerciseState -> Maybe (Outcome, Int)
currentResult m exid st = do
  ex     <- findExerciseById exerciseCorpus exid
  prompt <- safeIndexL (exPrompts ex) (esCursor st)
  Map.lookup (unPromptId (prId prompt)) (mExResults m)

exerciseBodyView :: Model -> Route -> Maybe (View Model Action)
exerciseBodyView m route = case route of
  RExercises -> Just (Exercise.viewExerciseIndex exerciseCorpus)
  RDeck slug -> Just (Exercise.viewDeck exerciseCorpus slug)
  RExercise deckSlug exSlug ->
    let exid   = ExId exSlug
        st     = Map.findWithDefault (initialState exid (MonoMs 0)) (unExId exid) (mExStates m)
        result = currentResult m exid st
    in Just (Exercise.viewExerciseRunner (exHandlersFor exid) exerciseCorpus deckSlug exSlug st result)
  _ -> Nothing

eventLogJson :: [ProgressEvent] -> Text
eventLogJson evs = jArr (map eventJson evs)

-- | Reuses "Exercises.Corpus"'s tiny JSON combinators (themselves built
-- on 'SXC1.Content.Stats.jsonEscape') rather than a second encoder.
eventJson :: ProgressEvent -> Text
eventJson ev = jObj
  [ jKV "deck"      (jStr (unDeckId (peDeck ev)))
  , jKV "exercise"  (jStr (unExId (peExercise ev)))
  , jKV "prompt"    (maybe "null" (jStr . unPromptId) (pePrompt ev))
  , jKV "kind"      (jStr (kindText (peKind ev)))
  , jKV "outcome"   (jStr (outcomeText (peOutcome ev)))
  , jKV "attempt"   (jInt (peAttempt ev))
  , jKV "revealed"  (jBool (peRevealed ev))
  , jKV "hints"     (jInt (peHints ev))
  , jKV "elapsedMs" (jInt (peElapsed ev))
  , jKV "at"        (jInteger (peAt ev))
  ]

kindText :: Kind -> Text
kindText KQuiz   = "quiz"
kindText KDrill  = "drill"
kindText KLookup = "lookup"

outcomeText :: Outcome -> Text
outcomeText Correct   = "correct"
outcomeText Incorrect = "incorrect"
outcomeText Skipped   = "skipped"
outcomeText Completed = "completed"

-- | M2 re-gate fix: the current exercise route's monotonic prompt
-- baseline, "null" when 'Begin' has never run for it (no state entry) --
-- rendered into @#sxc1-prompt-baseline@ so the harness can detect a lost
-- mount-time 'Begin' deterministically. See 'View.Pages.promptBaselineView'.
promptBaselineJson :: Model -> Text
promptBaselineJson m = case mRoute m of
  RExercise _ exSlug -> case Map.lookup exSlug (mExStates m) of
    Just st -> jInteger (unMonoMs (esPromptAt st))
    Nothing -> "null"
  _ -> "null"

-- | Every PromptId the CURRENT corpus can mint -- the yardstick that
-- tells a live stored record from a RETIRED one (a record whose prompt
-- no longer exists). Retired records are kept in 'psRecs' (dropping
-- them would let a content edit silently destroy history), excluded
-- from the review queue, and counted separately here.
allCorpusPromptIds :: Map Text ()
allCorpusPromptIds = Map.fromList
  [ (unPromptId (promptIdFor (exId e) i), ())
  | d <- exerciseCorpus, e <- dkExercises d, i <- [1 .. length (exPrompts e)] ]

-- | The #sxc1-progress machine-readable payload (M3 DOM contract).
-- Every number derives from the real model state -- the harness asserts
-- on VALUES here.
progressJson :: Model -> Text
progressJson m = jObj
  [ jKV "available" (jBool (mStorageOk m))
  , jKV "state" (jStr (case mLoad m of
      DecodeOk _      -> "ok"
      DecodeEmpty     -> "empty"
      DecodeCorrupt _ -> "corrupt"))
  , jKV "schema" (jInt currentSchema)
  , jKV "records" (jInt (Map.size (psRecs st)))
  , jKV "retired" (jInt (Map.size retiredRecs))
  , jKV "due" (jInt (dueCount today liveState))
  , jKV "streak" (jInt (psStreakLen st))
  , jKV "retention" (jInt (retention today liveState))
  , jKV "queue" (jArr (map (jStr . fst) (reviewQueue today liveState)))
  , jKV "jaFirst" (jBool (prfJaFirst (mPrefs m)))
  ]
  where
    st    = mProgress m
    today = mToday m
    (liveRecs, retiredRecs) =
      Map.partitionWithKey (\k _ -> Map.member k allCorpusPromptIds) (psRecs st)
    liveState = st { psRecs = liveRecs }

viewModel :: props -> Model -> View Model Action
viewModel _ m = viewRoute ToggleJA exerciseStatsJson (eventLogJson (mEventLog m)) (promptBaselineJson m) (progressJson m) (exerciseBodyView m (mRoute m)) (mRoute m)
