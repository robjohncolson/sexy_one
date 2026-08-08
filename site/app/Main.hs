{-# LANGUAGE CPP               #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import           Data.IORef            (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.IntMap.Strict     as IntMap
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

import           Progress.Store         (loadPrefs, loadProgress, loadRaw, savePrefs, saveProgress,
                                         storageAvailable, wipeProgress)

import           Device.Midi            (DeviceStatus (..), DeviceVerifier (..), Hub,
                                         HubSnapshot (..), hubDisable, hubEnable, hubSetChannel,
                                         hubSnapshot, newHub, statusText, webMidiVerifier)
import           Exercises.Bundle       (loadDeckSources)
import           Exercises.Corpus       (exerciseCorpusOf, exerciseStatsJsonOf, jArr, jBool, jInt, jInteger, jKV, jObj,
                                          jStr)
import           View.Exercise          (DevView (..), ExHandlers (..))
import qualified View.Exercise          as Exercise
import           View.Pages             (contentDegradedView, viewRoute)
import           View.Progress          (ProgData (..), ProgHandlers (..))

-- | Read window.location.hash via Miso's own DSL.
--
-- CORRECTION (measured 2026-08-07, M4 design probe P-D -- superseding
-- M1's P4 claim that used to live here): a raw @foreign import
-- javascript@ binding -- including one returning
-- 'GHC.Wasm.Prim.JSString' and a @foreign import javascript \"wrapper\"@
-- -- COMPILES, LINKS AND RUNS in this executable. The real blocker is
-- mundane: 'GHC.Wasm.Prim' lives in the @ghc-experimental@ package,
-- which is not in exe:app's build-depends, so the import does not
-- compile at all (GHC-87110) until that dependency is added -- with it,
-- everything links (Miso's own @ffi\/wasm\/Miso\/DSL\/FFI.hs@ has used
-- exactly these declarations all along). Miso's DSL remains the chosen
-- route because it needs no new dependency and is proven end to end;
-- raw JSFFI stays recorded as the escape hatch of last resort for a
-- future size crunch (briefs\/M4-plan.md section 1, P-D). 'jsg', '(!)',
-- 'fromJSValUnchecked' and 'MisoString'\/'fromMisoString' are all
-- re-exported by @import Miso@, so no further imports are needed here.
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
-- THE M4 DEVICE LAYER (briefs/M4-plan.md sections 3.4/3.7/3.8) -- what
-- M2's forward hook became. The 'DeviceVerifier' record now lives in
-- "Device.Midi" beside its one real implementation,
-- 'Device.Midi.webMidiVerifier' over one 'Device.Midi.Hub'; M2's
-- do-nothing verifier value is gone. The permission request lives in
-- 'Device.Midi.hubEnable' -- the ONLY requestMIDIAccess call site in the
-- codebase, always @{sysex: false}@, reachable only from
-- #btn-device-enable's click (the 'DEnable' handler below). 'dvAvailable'
-- remains feature detection only and is still called at boot from 'main',
-- exactly as M2 already did. The manual confirmation path (a learner
-- clicking a .btn-ex-confirm button) REMAINS the default and is never
-- removed, hidden or disabled while device verification is on.
--
-- 'DevCtx' bundles what the update loop threads through: the hub, the
-- verifier built over it, and the watch reconciler's bookkeeping -- the
-- ACTIVE watch as (promptId text, attempt generation captured at
-- subscribe time, verify: source text, remover). The generation is part
-- of the watch's IDENTITY (briefs/M4-codex-gate1.json, HIGH finding:
-- keying on promptId alone cannot tell a restarted or re-enabled
-- attempt from the old one when the cursor lands back on the same
-- prompt), so a generation bump replaces the watch even when the
-- promptId is unchanged. The remover is idempotent ('Device.Midi'
-- filters by unique id), so running it on reconciliation, after the
-- watch already fired, or around a disable are all safe in any order.
--------------------------------------------------------------------------

data DevCtx = DevCtx
  { dcHub      :: Hub
  , dcVerifier :: DeviceVerifier
  , dcWatch    :: IORef (Maybe (Text, Int, Text, IO ()))
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
    -- M3 (task "progress-ui"): captured once at boot alongside 'mLoad'
    -- (never re-read, never written back) so the corrupt-state banner can
    -- offer 'Progress.Store.loadRaw''s raw blob for the learner to copy
    -- by hand -- 'mLoad' only carries the decode FAILURE REASON, not the
    -- bytes that failed to decode, and nothing else in this Model keeps
    -- them.
  , mRawCorrupt :: !(Maybe Text)
    -- M4 (task "device-app"): the model's MIRROR of the device hub --
    -- Miso's 'viewModel' is a pure function of 'Model' and cannot read
    -- the hub's IORef at render time (the mEventLog precedent), so every
    -- hub change re-syncs this snapshot via 'DSynced'. 'mDevSupported'
    -- is the boot-time feature-detect result (a browser cannot gain Web
    -- MIDI mid-session); 'mDevWatching' mirrors the reconciler's active
    -- watch as (promptId text, verify: source text).
  , mDevice       :: !HubSnapshot
  , mDevSupported :: !Bool
  , mDevWatching  :: !(Maybe (Text, Text))
    -- M4 gate-1 fix (briefs/M4-codex-gate1.json, HIGH finding): the
    -- ATTEMPT GENERATION -- a monotonically increasing counter naming
    -- which drill ATTEMPT (and device-session) the model is currently
    -- in. Bumped on every exercise load and Restart ('applyExActions',
    -- on any batch containing 'Begin'/'Restart') and on every hub
    -- enable/disable click ('DEnable'). Captured at watch-subscribe
    -- time ('reconcileWatch') for the device path and at
    -- click-PROCESSING time for the manual button (never at render
    -- time -- see 'DConfirm'), carried through 'DConfirm' into
    -- 'DApplyConfirm', and re-checked by 'guardedConfirmIx' AT BATCH
    -- APPLICATION TIME -- so an in-flight confirmation whose attempt
    -- was restarted, reloaded, or device-toggled out from under it is
    -- dropped even when its prompt id LOOKS current again (Restart
    -- lands the cursor back on the very promptId the stale confirm
    -- captured; only the generation can tell the two attempts apart).
    -- wasm32 'Int' is 32-bit: fine -- a session cannot plausibly bump
    -- this 2^31 times.
  , mAttemptGen   :: !Int
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
-- an 'ExBatch' built from them -- covers Submit\/SelfGrade_\/SubmitPage\/
-- Advance\/Restart\/Begin uniformly. 'ConfirmStep' no longer travels
-- this path: BOTH confirm sources go through 'DConfirm'\/'DApplyConfirm'
-- (the guarded two-hop path -- briefs\/M4-codex-gate1.json, HIGH
-- finding), which re-validates at batch-application time; an unguarded
-- 'ExBatch' hop would reopen the stale-confirm window.
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
    -- M4: the same discipline once more -- ONE constructor wrapping
    -- every device operation.
  | Dev DeviceOp

data DeviceOp
  = DEnable                              -- ^ #btn-device-enable clicked (enable, or disable when already granted)
  | DSetChannel Int                      -- ^ #sel-device-channel change \/ #btn-device-use-channel click
  | DSynced HubSnapshot (Maybe (Text, Text)) -- ^ store a freshly read hub snapshot + active-watch mirror
    -- M4 gate-1 fix (briefs/M4-codex-gate1.json, HIGH finding): the ONE
    -- guarded confirm request -- issued by the device watch callback
    -- (source 'ByDevice', promptId text + 'Just' the generation captured
    -- at SUBSCRIBE time in 'reconcileWatch') AND by the manual Confirm
    -- button (source 'ByLearner', generation 'Nothing' = capture the
    -- CURRENT generation when this action is PROCESSED). The manual path
    -- deliberately does NOT capture the generation at render time: the
    -- generation is invisible in the rendered output, so two frames
    -- differing only in it diff as unchanged and the DOM keeps the
    -- OLDER frame's listener closure -- MEASURED (this task's report): a
    -- drill entered under load renders once before its 'Begin' bump and
    -- once after, the diff kept the pre-Begin closure, and every manual
    -- confirm on that attempt was dropped as stale. The click being
    -- processed IS the manual context capture -- everything BETWEEN that
    -- capture and the batch's application is then guarded exactly as for
    -- the device path. One shared guarded path: the full guard
    -- ('guardedConfirmIx') runs here AND again at 'DApplyConfirm', the
    -- batch-application hop.
  | DConfirm ConfirmSource ExId Text (Maybe Int)
    -- ^ the clock-read hop's result: same identity, plus the two clock
    -- readings. 'handleDev' re-runs the FULL guard on this action --
    -- i.e. at the moment the batch is actually applied -- so nothing
    -- that lands between the two hops (SetRoute, Restart, a manual
    -- confirm, a hub enable\/disable) can slip a stale confirmation
    -- through. Never dispatched from anywhere but 'DConfirm''s own
    -- effect.
  | DApplyConfirm ConfirmSource ExId Text Int MonoMs WallMs

data ProgressOp
  = PExportReq          -- ^ learner asked for an export
  | PExportGot Text     -- ^ IO produced the envelope (stamped)
  | PImport Text        -- ^ learner submitted import text
  | PWipe               -- ^ learner confirmed a wipe
  | PJaFirst Bool       -- ^ learner flipped the JA-first reader preference
  | PSetToday DayNum    -- ^ NEW13: today refreshed from a real wall reading on navigation
  | PStorageLost        -- ^ NEW9: a write failed after boot; storage is no longer trusted
  | PSaved ProgressState -- ^ NEW8: a save landed; DecodeEmpty graduates to DecodeOk
  | PWipedOk            -- ^ NEW9 residual: the delete really landed; safe to reset

#ifdef WASM
foreign export javascript "hs_start" main :: IO ()
#endif

main :: IO ()
main = do
  h    <- currentHash
  sink <- mkProgressSink
  -- M6 W1 (briefs/M6-plan.md, ruling 1): the exercise corpus arrives
  -- through the static shell's JS-side-guarded loader ("Exercises.
  -- Bundle") instead of a TH splice. Read ONCE, here, before the app
  -- starts; a failure yields an EMPTY corpus plus the failure reason,
  -- and the app boots into a visible degraded state (banner + per-route
  -- notice with a retry affordance) -- the manuals, which stay
  -- embedded, are unaffected. Retry is a plain page reload, delegated
  -- JS-side in site/static/index.js (#btn-content-retry), so the
  -- re-load takes exactly this same boot path again.
  bootContent <- loadDeckSources
  let (deckSrcs, mContentErr) = case bootContent of
        Right srcs -> (srcs, Nothing)
        Left err   -> ([], Just err)
      corpus     = exerciseCorpusOf deckSrcs
      exStatsTxt = exerciseStatsJsonOf deckSrcs
  -- M4: the device hub. 'newHub' and 'dvAvailable' are feature detection
  -- ONLY (they read navigator.requestMIDIAccess and test undefined/null;
  -- they never call it), so both stay safe at boot -- the permission
  -- request itself lives in 'Device.Midi.hubEnable', reachable only from
  -- #btn-device-enable's click handler.
  hub <- newHub
  let verifier = webMidiVerifier hub
  supported <- dvAvailable verifier
  watchRef  <- newIORef Nothing
  snap0     <- hubSnapshot hub
  let dev = DevCtx { dcHub = hub, dcVerifier = verifier, dcWatch = watchRef }
  -- M3 startup: probe storage by WRITING (see Progress.Store), load both
  -- blobs, and take today's day from a real wall reading. A corrupt
  -- progress blob puts the app into read-only progress mode from the
  -- first frame -- the blob on disk is never touched again until the
  -- learner explicitly wipes or imports.
  avail   <- storageAvailable
  loadRes <- loadProgress
  -- M3 (task "progress-ui"): the raw undecoded blob, for the corrupt-state
  -- banner's "offer the raw export first" requirement -- see 'mRawCorrupt'.
  -- Harmless (and simply unused by any view) when 'loadRes' is not
  -- 'DecodeCorrupt'; reading it never writes anything back.
  rawBlob <- loadRaw
  prefs   <- loadPrefs
  (_, WallMs wall0) <- readClocks
  let st0 = case loadRes of { DecodeOk s -> s; _ -> emptyProgress }
  startApp defaultEvents (readerApp corpus exStatsTxt mContentErr sink dev supported snap0 avail loadRes rawBlob st0 prefs (dayOf wall0) (parseRoute h))

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
readerApp
  :: [Deck] -> Text -> Maybe Text
  -> ProgressSink -> DevCtx -> Bool -> HubSnapshot -> Bool -> DecodeResult -> Maybe Text -> ProgressState -> Prefs -> DayNum -> Route
  -> App Model Action
readerApp corpus exStatsTxt mContentErr sink dev supported snap0 avail loadRes rawBlob st0 prefs today0 r0 =
  (component model0 (updateModel corpus sink dev) (viewModel corpus exStatsTxt mContentErr))
    { subs  = [ windowSub "hashchange" emptyDecoder (const HashChanged) ]
    , mount = Just (SetRoute r0)
    }
  where
    model0 = Model
      { mRoute = r0, mExStates = Map.empty, mExResults = Map.empty, mEventLog = []
      , mProgress = st0, mLoad = loadRes, mStorageOk = avail, mPrefs = prefs
      , mToday = today0, mBooted = False, mExportBlob = Nothing, mImportMsg = Nothing
      , mRawCorrupt = rawBlob
      , mDevice = snap0, mDevSupported = supported, mDevWatching = Nothing
      , mAttemptGen = 0
      }

findExerciseById :: [Deck] -> ExId -> Maybe Exercise
findExerciseById decks eid = find ((== eid) . exId) (concatMap dkExercises decks)

safeIndexL :: [a] -> Int -> Maybe a
safeIndexL xs i
  | i < 0     = Nothing
  | otherwise = case drop i xs of { (x : _) -> Just x; [] -> Nothing }

updateModel :: [Deck] -> ProgressSink -> DevCtx -> Action -> Effect parent props Model Action
updateModel corpus sink dev = \case
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
    beginIfNeeded corpus r
    io_ (scrollIntoView "app")
    -- NEW13: mToday was captured once at startup and previously only
    -- advanced from later events' own peAt -- an open tab crossing UTC
    -- midnight kept yesterday's due/queue until something was graded.
    -- Every navigation now refreshes it from a real wall reading.
    io (do { (_, WallMs w) <- readClocks; pure (Prog (PSetToday (dayOf w))) })
    -- M4: a route move can change which prompt (if any) should be
    -- watched -- see 'reconcileEff'.
    reconcileEff corpus dev

  Prog op -> handleProg op

  Dev op -> handleDev corpus sink dev op

  ToggleJA -> do
    r <- gets mRoute
    case r of
      RPage slug n ja -> do
        let r' = RPage slug n (not ja)
        modify (\m -> m { mRoute = r' })
        io_ (setHash (renderRoute r'))
      _ -> pure ()

  ExBatch exid acts -> do
    applyExActions corpus sink exid acts
    -- M4: a batch can move the cursor (ConfirmStep/Advance/Restart/
    -- Begin), which changes which prompt should be watched.
    reconcileEff corpus dev

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
      if writable
        then io $ do
          okW <- saveProgress st
          pure (if okW then NoOp else Prog PStorageLost)
        else pure ()
    DecodeCorrupt reason -> modify (\m -> m { mImportMsg = Just reason })
    DecodeEmpty -> modify (\m -> m { mImportMsg = Just "import text was empty" })
  PWipe ->
    -- An explicit learner decision -- but the state resets ONLY if the
    -- delete actually landed (M3 re-gate NEW9 residual): a wipe the
    -- bridge reports failed leaves the model exactly as it was and
    -- degrades to storage-unavailable mode, so the app can never claim
    -- an empty slate while the old key still exists on disk.
    io $ do
      okW <- wipeProgress
      pure (if okW then Prog PWipedOk else Prog PStorageLost)
  PWipedOk ->
    modify (\m -> m { mProgress = emptyProgress, mLoad = DecodeEmpty
                    , mExportBlob = Nothing, mImportMsg = Nothing })
  PJaFirst b -> do
    modify (\m -> m { mPrefs = Prefs b })
    -- NEW9: a failed prefs write degrades to storage-unavailable mode
    -- (visible in the payload/notice) instead of being discarded.
    io $ do
      okW <- savePrefs (Prefs b)
      pure (if okW then NoOp else Prog PStorageLost)
  PSetToday d -> modify (\m -> m { mToday = max (mToday m) d })
  PStorageLost -> modify (\m -> m { mStorageOk = False })
  PSaved st -> modify (\m -> case mLoad m of
    DecodeEmpty -> m { mLoad = DecodeOk st }
    _           -> m)

--------------------------------------------------------------------------
-- M4 device layer: the reconciler, the stale-confirm guard, and the
-- hidden #sxc1-device-state payload.
--------------------------------------------------------------------------

handleDev :: [Deck] -> ProgressSink -> DevCtx -> DeviceOp -> Effect parent props Model Action
handleDev corpus sink dev op = case op of
  -- #btn-device-enable. When already granted the same button disables
  -- (its label tracks the status): run the active watch's remover (a
  -- no-op if none), clear the bookkeeping, and tear the JS side down --
  -- then reconcile, so a later re-enable starts from consistent state.
  --
  -- M4 gate-1 fix (briefs/M4-codex-gate1.json, HIGH finding): the
  -- attempt generation bumps FIRST, on every enable AND disable click,
  -- BEFORE the watch is replaced -- so 'reconcileWatch' below registers
  -- the fresh watch under the NEW generation and any confirmation still
  -- in flight from the previous device session (captured under the old
  -- generation) is dropped at 'DApplyConfirm' even though its promptId
  -- still names the cursor's prompt.
  DEnable -> do
    modify (\m -> m { mAttemptGen = mAttemptGen m + 1 })
    m <- get
    withSink $ \snk -> do
      snap <- hubSnapshot (dcHub dev)
      if snapStatus snap == DevGranted
        then do
          mw <- readIORef (dcWatch dev)
          mapM_ (\(_, _, _, remover) -> remover) mw
          writeIORef (dcWatch dev) Nothing
          hubDisable (dcHub dev)
        else
          -- The notify callback the hub closes over: every asynchronous
          -- hub event (grant, deny, hot-plug rebind, message) re-syncs
          -- the model's mirror through the component's own sink.
          hubEnable (dcHub dev) (syncDevice dev snk)
      reconcileWatch corpus dev m snk
      syncDevice dev snk

  DSetChannel c -> withSink $ \snk -> do
    hubSetChannel (dcHub dev) c
    syncDevice dev snk

  DSynced snap watching ->
    modify (\m -> m { mDevice = snap, mDevWatching = watching })

  -- THE STALE-CONFIRM GUARD, hop 1 of 2 (briefs/M4-plan.md section 3.7,
  -- finding M4-F3; RESTRUCTURED for briefs/M4-codex-gate1.json's HIGH
  -- finding): 'SXC1.Exercise.Engine.gradeStep' does NOT check that the
  -- graded index is the cursor, so a 'ConfirmStep' for an already-passed
  -- step would re-grade it and emit a duplicate event. The engine is
  -- frozen, so the guard lives here -- and it now lives at BOTH hops of
  -- the confirm path, because the gate showed that guarding only here
  -- leaves the clock-read hop open: an action landing between this
  -- validation and the batch's application (SetRoute, Restart, a manual
  -- confirm, a hub enable/disable) used to change the context AFTER the
  -- guard had already passed. 'guardedConfirmIx' checks route, cursor
  -- prompt, answered-state, done-state AND the attempt generation; a
  -- request failing it is dropped silently. On success the ONLY effect
  -- is the clock read -- the state-mutating batch is built and guarded
  -- again at 'DApplyConfirm', the application hop.
  --
  -- BOTH confirm sources take this same path: the device watch callback
  -- ('ByDevice') and the manual Confirm button ('ByLearner' -- see
  -- 'exOnConfirm'). For the manual button this is a zero-behavior-change
  -- refactor in every non-racing schedule: the button is rendered ONLY
  -- for the unanswered cursor step ('View.Exercise.confirmEl'), so its
  -- captured promptId names the cursor's prompt at click time and the
  -- generation is bound fresh right here; the guard can only drop a
  -- manual click that raced a context change through these same two
  -- hops -- exactly the duplicate-grade schedules the guard exists to
  -- kill.
  DConfirm src exid pidText mGen -> do
    m <- get
    -- 'Nothing' = the manual button: bind the CURRENT generation now,
    -- at click-processing time (see the constructor's own comment for
    -- why render-time capture is unsound). 'Just' = the device watch's
    -- subscribe-time capture, taken as-is.
    let gen = case mGen of { Just g -> g; Nothing -> mAttemptGen m }
    case guardedConfirmIx m exid pidText gen of
      Nothing -> pure ()
      Just _  -> io $ do
        (mono, wall) <- readClocks
        pure (Dev (DApplyConfirm src exid pidText gen mono wall))

  -- THE STALE-CONFIRM GUARD, hop 2 of 2 -- BATCH-APPLICATION time. The
  -- full guard re-runs against the model AS IT IS NOW, in the same
  -- undivided 'Effect' that applies the batch, so nothing can interpose
  -- between this check and 'applyExActions'. The batch is byte-identical
  -- to what the pre-fix 'ExClocked' path produced -- @[ConfirmStep i src
  -- mono wall, Advance mono wall]@ through the SAME 'applyExActions' --
  -- so events, mExResults, the capped log and the M3 sink all behave
  -- exactly as before, followed by the same reconcile 'ExBatch' runs.
  DApplyConfirm src exid pidText gen mono wall -> do
    m <- get
    case guardedConfirmIx m exid pidText gen of
      Nothing -> pure ()
      Just i  -> do
        applyExActions corpus sink exid [ConfirmStep i src mono wall, Advance mono wall]
        reconcileEff corpus dev

-- | The FULL stale-confirm guard (briefs/M4-codex-gate1.json, HIGH
-- finding), shared verbatim by both hops of the confirm path: 'Just'
-- the cursor index to confirm iff, IN THIS model,
--
--   1. the route still shows exactly this exercise (a confirmation must
--      never mutate an exercise the learner has navigated away from);
--   2. the exercise is not done and its cursor step is still unanswered
--      (the original M4-F3 duplicate-grade guard);
--   3. the captured promptId text still names the cursor's prompt; and
--   4. the captured attempt generation is CURRENT -- the one check that
--      can tell a restarted/reloaded/device-toggled attempt from the
--      old one when the cursor lands back on the very same promptId
--      (checks 2 and 3 are blind to that).
guardedConfirmIx :: Model -> ExId -> Text -> Int -> Maybe Int
guardedConfirmIx m exid pidText gen = case mRoute m of
  RExercise _ exSlug
    | exSlug == unExId exid
    , gen == mAttemptGen m
    , let st = Map.findWithDefault (initialState exid (MonoMs 0)) exSlug (mExStates m)
    , let i  = esCursor st
    , let unanswered = case IntMap.lookup i (esResponses st) of
            Nothing          -> True
            Just RUnanswered -> True
            _                -> False
    , not (esDone st) && unanswered
    , unPromptId (promptIdFor exid (i + 1)) == pidText
    -> Just i
  _ -> Nothing

-- | Push the hub's current state (and the reconciler's active-watch
-- bookkeeping) into the model mirror, through the sink.
syncDevice :: DevCtx -> Sink Action -> IO ()
syncDevice dev snk = do
  snap <- hubSnapshot (dcHub dev)
  mw   <- readIORef (dcWatch dev)
  snk (Dev (DSynced snap (fmap (\(p, _, s, _) -> (p, s)) mw)))

-- | THE WATCH RECONCILER (briefs/M4-plan.md section 3.7; amended by the
-- M4 gate-1 fix): one function, run after every action that can move
-- the route, the cursor, or the attempt generation ('SetRoute',
-- 'ExBatch', 'DEnable', and 'DApplyConfirm'). The desired watch is the
-- current exercise route's prompt at the cursor, when it is a Confirm
-- carrying a 'VerifySpec' and is not already answered; if its key --
-- the (promptId text, attempt generation) PAIR, see 'reconcileWatch' --
-- differs from the active one, the old remover runs and the new spec is
-- watched. Registering a watch touches no JS and is legal before
-- enabling ("watching before enabling is legal and simply never
-- fires"), so this runs unconditionally.
reconcileEff :: [Deck] -> DevCtx -> Effect parent props Model Action
reconcileEff corpus dev = do
  m <- get
  withSink $ \snk -> do
    reconcileWatch corpus dev m snk
    syncDevice dev snk

reconcileWatch :: [Deck] -> DevCtx -> Model -> Sink Action -> IO ()
reconcileWatch corpus dev m snk = do
  active <- readIORef (dcWatch dev)
  let desired = desiredWatch corpus m
      gen     = mAttemptGen m
  case (desired, active) of
    (Nothing, Nothing) -> pure ()
    -- The watch's identity is (promptId, ATTEMPT GENERATION) -- not the
    -- promptId alone (briefs/M4-codex-gate1.json, HIGH finding): a
    -- Restart or an enable/disable bump replaces the watch even though
    -- the cursor lands back on the very same prompt, so the fresh
    -- attempt's watch captures the fresh generation and the old
    -- attempt's in-flight confirm (old generation) can no longer pass
    -- 'guardedConfirmIx'.
    (Just (_, pid, _), Just (apid, agen, _, _)) | pid == apid && agen == gen -> pure ()
    _ -> do
      mapM_ (\(_, _, _, remover) -> remover) active
      case desired of
        Nothing -> writeIORef (dcWatch dev) Nothing
        Just (exid, pid, spec) -> do
          -- The generation captured HERE, at subscribe time, is what the
          -- callback carries into 'DConfirm' -- the whole point of the
          -- guard: it names the attempt this watch was armed FOR, not
          -- whatever attempt exists when the message finally arrives.
          remover <- dvWatch (dcVerifier dev) spec
                       (\_src -> snk (Dev (DConfirm ByDevice exid pid (Just gen))))
          writeIORef (dcWatch dev) (Just (pid, gen, specSourceText spec, remover))

-- | The watch the current model calls for: an exercise route whose
-- cursor prompt is a Confirm with a @verify:@ hook, not yet answered.
desiredWatch :: [Deck] -> Model -> Maybe (ExId, Text, VerifySpec)
desiredWatch corpus m = case mRoute m of
  RExercise _ exSlug -> do
    let exid = ExId exSlug
    ex <- findExerciseById corpus exid
    let st = Map.findWithDefault (initialState exid (MonoMs 0)) exSlug (mExStates m)
        i  = esCursor st
    prompt <- safeIndexL (exPrompts ex) i
    spec   <- case prBody prompt of
      Confirm _ (Just v) -> Just v
      _                  -> Nothing
    let unanswered = case IntMap.lookup i (esResponses st) of
          Nothing          -> True
          Just RUnanswered -> True
          _                -> False
    if esDone st || not unanswered
      then Nothing
      else Just (exid, unPromptId (prId prompt), spec)
  _ -> Nothing

-- | A spec rendered back in the @verify:@ source grammar (the form CI
-- and the content files speak), for the #sxc1-device-state payload --
-- distinct from 'SXC1.Midi.Spec.describeSpec', which renders for the
-- learner.
specSourceText :: VerifySpec -> Text
specSourceText v = case v of
  VerifyCC n vs -> "cc " <> tshow n <> " " <> T.intercalate "," (map tshow vs)
  VerifyNote ns -> "note " <> T.intercalate "," (map tshow ns)
  VerifyPad p b -> "pad " <> tshow p <> " bank " <> T.singleton b
  VerifyAny     -> "any"
  where tshow = T.pack . show

-- | The #sxc1-device-state machine-readable payload (briefs/M4-plan.md
-- section 3.8) -- always rendered, always hidden, on every route.
-- Built with "Exercises.Corpus"'s existing JSON combinators, never a
-- second encoder. @confirms@ derives from the CURRENT exercise's
-- 'esResponses' ('RConfirmed' 'ByDevice'/'ByLearner'), which is how CI
-- asserts WHO confirmed a step without touching 'ProgressEvent'.
deviceStateJson :: Model -> Text
deviceStateJson m = jObj
  [ jKV "supported"   (jBool (mDevSupported m))
  , jKV "status"      (jStr (statusText (snapStatus snap)))
  , jKV "channel"     (jInt (snapChannel snap))
  , jKV "ports"       (jArr (map jStr (snapPorts snap)))
  , jKV "allPorts"    (jArr (map jStr (snapAllPorts snap)))
  , jKV "watching"    watchingJson
  , jKV "lastMessage" (maybe "null" (jArr . map jInt) (snapLastMsg snap))
  , jKV "lastChannel" (maybe "null" jInt (snapLastChan snap))
  , jKV "confirms"    (jArr confirms)
  ]
  where
    snap = mDevice m
    watchingJson = case mDevWatching m of
      Nothing         -> "null"
      Just (pid, src) -> jObj [ jKV "prompt" (jStr pid), jKV "spec" (jStr src) ]
    confirms = case mRoute m of
      RExercise _ exSlug -> case Map.lookup exSlug (mExStates m) of
        Nothing -> []
        Just st ->
          [ jObj [ jKV "prompt" (jStr (unPromptId (promptIdFor (ExId exSlug) (i + 1))))
                 , jKV "source" (jStr (case src of { ByDevice -> "device"; ByLearner -> "learner" }))
                 ]
          | (i, RConfirmed src) <- IntMap.toAscList (esResponses st)
          ]
      _ -> []

-- | On first navigation to an exercise (no state recorded for it yet),
-- seed a fresh attempt with a real wall-clock reading. Never re-fires
-- for an exercise that already has state -- this is what lets following
-- a citation into the manual reader and coming back preserve the
-- learner's prompt and selections (the model keys state by 'ExId', not
-- by "the current exercise", exactly per the acceptance criteria).
beginIfNeeded :: [Deck] -> Route -> Effect parent props Model Action
beginIfNeeded corpus (RExercise _ exSlug) = do
  let exid = ExId exSlug
  states <- gets mExStates
  if Map.member (unExId exid) states
    then pure ()
    else case findExerciseById corpus exid of
      Nothing -> pure ()
      Just _  -> io $ do
        (mono, wall) <- readClocks
        pure (ExBatch exid [Begin mono wall])
beginIfNeeded _ _ = pure ()

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
-- | M5 a11y (briefs/M5-ship.md ship checklist, focus management on
-- prompt advance): where keyboard\/screen-reader focus lands after a
-- batch that MOVED the cursor -- an 'Advance' (every graded advance:
-- quiz\/lookup Next, and BOTH confirm sources, since 'DApplyConfirm'
-- applies @[ConfirmStep, Advance]@ -- so a DEVICE confirm, which changes
-- the focus context without any user click, takes exactly this path
-- too) or a 'Restart'. Without this, the element that HELD focus (the
-- clicked #btn-ex-next \/ .btn-ex-confirm) is removed by the re-render
-- and the browser drops focus to \<body\>, stranding keyboard and SR
-- users. Targets carry @tabindex="-1"@ in "View.Exercise":
--
--   * whole exercise done -> @#ex-summary@ (the completion message);
--   * drill mid-run       -> the NEXT step's own \<li\>
--                            (@#ex-step-\<cursor+1\>@);
--   * quiz\/lookup        -> @#ex-title@ (the exercise heading -- the
--                            fresh prompt's own container ids are
--                            kind-specific, the heading is not).
--
-- 'Begin' deliberately does NOT move focus: it fires on ordinary
-- navigation (mount included), where stealing focus from the header\/
-- address bar would be a WCAG 3.2.1-style surprise, not a repair.
advanceFocusTarget :: Exercise -> ExerciseState -> Text
advanceFocusTarget ex st
  | esDone st           = "ex-summary"
  | exKind ex == KDrill = "ex-step-" <> T.pack (show (esCursor st + 1))
  | otherwise           = "ex-title"

applyExActions :: [Deck] -> ProgressSink -> ExId -> [ExerciseAction] -> Effect parent props Model Action
applyExActions corpus sink exid acts = case findExerciseById corpus exid of
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
        -- M4 gate-1 fix (briefs/M4-codex-gate1.json, HIGH finding): a
        -- 'Begin' (every exercise load) or 'Restart' starts a FRESH
        -- attempt, so the attempt generation bumps in the same modify
        -- that folds the batch in -- the ExBatch handler's reconcile
        -- runs right after this and re-registers the watch under the
        -- new generation, and any confirmation still in flight for the
        -- OLD attempt fails 'guardedConfirmIx''s generation check even
        -- though a restarted cursor names the same promptId again.
      , mAttemptGen = mAttemptGen m + (if clearStale then 1 else 0)
      })
    io_ (mapM_ (sinkRecord sink) evsAll)
    -- M5 a11y: see 'advanceFocusTarget'. Guarded on the route still
    -- showing THIS exercise (a focus move must never fire for state
    -- changes on an exercise the learner is not looking at). 'io_' runs
    -- after the VDOM has been patched, and Miso's 'focus' adds its own
    -- 50ms defer, so the target element exists when the call lands.
    let cursorMoved = any (\a -> case a of { Advance _ _ -> True; Restart _ _ -> True; _ -> False }) acts
    routeNow <- gets mRoute
    case routeNow of
      RExercise _ exSlug | cursorMoved, exSlug == key ->
        io_ (focus (ms (advanceFocusTarget ex st1)))
      _ -> pure ()
    -- NEW8: the first successful save of real progress moves the load
    -- state from DecodeEmpty to DecodeOk, so #sxc1-progress can never
    -- report state=empty while records exist and are persisted. NEW9: a
    -- FAILED save (quota, revocation -- the bridge returns 0) degrades
    -- to storage-unavailable mode instead of being silently discarded.
    if writable && not (null evsAll)
      then io $ do
        okW <- saveProgress prog1
        pure (if okW then Prog (PSaved prog1) else Prog PStorageLost)
      else pure ()
  where
    recordResult ev acc = case pePrompt ev of
      Nothing  -> acc
      Just pid -> Map.insert (unPromptId pid) (peOutcome ev, peElapsed ev) acc

--------------------------------------------------------------------------
-- View
--------------------------------------------------------------------------

-- | M4 gate-1 fix (briefs/M4-codex-gate1.json, HIGH finding):
-- 'exOnConfirm' routes the manual Confirm click through the same
-- two-hop guarded path the device callback takes ('DConfirm' with
-- 'ByLearner') instead of a raw unguarded 'ExClocked'. The promptId
-- text is captured at render time -- sound, because the Confirm button
-- is only ever rendered for the unanswered cursor step
-- ('View.Exercise.confirmEl') and its rendered identity changes with
-- the step -- but the GENERATION is deliberately not ('Nothing' = bound
-- at click-processing time; see 'DConfirm''s own comment for the
-- measured listener-staleness defect that render-time capture causes).
-- The guard passes for every ordinary click and can only drop a click
-- that raced a context change through the confirm path's two hops --
-- the exact duplicate-grade schedules the guard exists to kill. Events,
-- results, log and sink behavior are unchanged ('DApplyConfirm' applies
-- the byte-identical batch through the same 'applyExActions').
exHandlersFor :: ExId -> ExHandlers Action
exHandlersFor exid = ExHandlers
  { exOnToggle     = \i optIdent -> ExBatch exid [Toggle i optIdent]
  , exOnSubmit     = \i -> ExClocked exid (\mono wall -> [Submit i mono wall])
  , exOnReveal     = \i -> ExBatch exid [Reveal i]
  , exOnGot        = \i -> ExClocked exid (\mono wall -> [SelfGrade_ i Got mono wall])
  , exOnMissed     = \i -> ExClocked exid (\mono wall -> [SelfGrade_ i Missed mono wall])
  , exOnConfirm    = \i -> Dev (DConfirm ByLearner exid (unPromptId (promptIdFor exid (i + 1))) Nothing)
  , exOnFindInput  = \i txt -> case parseDigits (fromMisoString txt) of
      Just n  -> ExBatch exid [EnterPage i n]
      Nothing -> NoOp
  , exOnFindSubmit = \i -> ExClocked exid (\mono wall -> [SubmitPage i mono wall])
  , exOnShowHint   = \i -> ExBatch exid [ShowHint i]
  , exOnNext       = ExClocked exid (\mono wall -> [Advance mono wall])
  , exOnRestart    = ExClocked exid (\mono wall -> [Restart mono wall])
    -- M4 (task "device-app"): the device panel's two controls.
  , exOnDevEnable  = Dev DEnable
  , exOnDevChannel = Dev . DSetChannel
  }

-- | Everything "View.Exercise" renders the device panel and the verify
-- lines from -- assembled fresh each frame straight from the model
-- mirror, exactly like 'progDataFor'.
devViewFor :: Model -> DevView
devViewFor m = DevView
  { dvwSupported = mDevSupported m
  , dvwSnap      = mDevice m
  , dvwWatching  = fmap fst (mDevWatching m)
  }

-- | The current prompt's last graded result, if any -- looked up by
-- 'PromptId' text so the runner never re-derives correctness itself
-- (see "View.Exercise"'s Haddock).
currentResult :: [Deck] -> Model -> ExId -> ExerciseState -> Maybe (Outcome, Int)
currentResult corpus m exid st = do
  ex     <- findExerciseById corpus exid
  prompt <- safeIndexL (exPrompts ex) (esCursor st)
  Map.lookup (unPromptId (prId prompt)) (mExResults m)

-- | M6 W1: when the content bundle failed to load, EVERY exercise route
-- renders the degraded notice (naming the failure, with the
-- #btn-content-retry affordance) instead of an empty index/deck/runner
-- built from the empty corpus -- the manuals routes are untouched.
exerciseBodyView :: [Deck] -> Maybe Text -> Model -> Route -> Maybe (View Model Action)
exerciseBodyView corpus mContentErr m route = case route of
  RExercises   | Just err <- mContentErr -> Just (contentDegradedView err)
  RDeck _      | Just err <- mContentErr -> Just (contentDegradedView err)
  RExercise _ _ | Just err <- mContentErr -> Just (contentDegradedView err)
  RExercises -> Just (Exercise.viewExerciseIndex (mProgress m) corpus)
  RDeck slug -> Just (Exercise.viewDeck (mProgress m) corpus slug)
  RExercise deckSlug exSlug ->
    let exid   = ExId exSlug
        st     = Map.findWithDefault (initialState exid (MonoMs 0)) (unExId exid) (mExStates m)
        result = currentResult corpus m exid st
    in Just (Exercise.viewExerciseRunner (exHandlersFor exid) (devViewFor m) corpus deckSlug exSlug st result)
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
allCorpusPromptIds :: [Deck] -> Map Text ()
allCorpusPromptIds corpus = Map.fromList
  [ (unPromptId (promptIdFor (exId e) i), ())
  | d <- corpus, e <- dkExercises d, i <- [1 .. length (exPrompts e)] ]

-- | The #sxc1-progress machine-readable payload (M3 DOM contract).
-- Every number derives from the real model state -- the harness asserts
-- on VALUES here.
progressJson :: [Deck] -> Model -> Text
progressJson corpus m = jObj
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
      Map.partitionWithKey (\k _ -> Map.member k (allCorpusPromptIds corpus)) (psRecs st)
    liveState = st { psRecs = liveRecs }

-- | M3 (task "progress-ui"): the "View.Exercise"\/"View.Pages" call
-- sites' handler bundle -- mirrors 'exHandlersFor' exactly. 'phJaFirst' is
-- built ALREADY NEGATED (the button always dispatches "flip whatever
-- 'mPrefs' currently says"), so "View.Progress" never needs to know
-- Main's concrete 'Action' shape to compute the next state, only render
-- the current one.
progHandlersFor :: Model -> ProgHandlers Action
progHandlersFor m = ProgHandlers
  { phExport  = Prog PExportReq
  , phImport  = Prog . PImport
  , phWipe    = Prog PWipe
  , phJaFirst = Prog (PJaFirst (not (prfJaFirst (mPrefs m))))
  }

-- | M3: everything "View.Progress" renders from, assembled fresh each
-- frame straight from the Model -- never stored, never diffed.
progDataFor :: [Deck] -> Model -> ProgData
progDataFor corpus m = ProgData
  { pdDecks      = corpus
  , pdProgress   = mProgress m
  , pdToday      = mToday m
  , pdLoad       = mLoad m
  , pdJaFirst    = prfJaFirst (mPrefs m)
  , pdExportBlob = mExportBlob m
  , pdImportMsg  = mImportMsg m
  , pdRawCorrupt = mRawCorrupt m
  , pdStorageOk  = mStorageOk m
  }

viewModel :: [Deck] -> Text -> Maybe Text -> props -> Model -> View Model Action
viewModel corpus exStatsTxt mContentErr _ m = viewRoute ToggleJA (progHandlersFor m) (progDataFor corpus m) exStatsTxt (eventLogJson (mEventLog m)) (promptBaselineJson m) (progressJson corpus m) (deviceStateJson m) mContentErr (exerciseBodyView corpus mContentErr m (mRoute m)) (mRoute m)
