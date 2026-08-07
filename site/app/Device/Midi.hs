{-# LANGUAGE OverloadedStrings #-}

-- | The Web MIDI hub -- M4's ONLY JS glue (briefs\/M4-plan.md section
-- 3.4). Everything that DECIDES whether a message satisfies a hook lives
-- in "SXC1.Midi.Spec" (pure, unit-tested under wasm-run); this module
-- only moves bytes between the browser and that pure core, through
-- Miso's JS DSL exclusively -- no raw @foreign import javascript@, no
-- bridge in site\/static\/index.js (M4 hard constraint 1).
--
-- PERMISSION DISCIPLINE (M4 hard constraint 2): 'hubEnable' is the ONE
-- call site of @navigator.requestMIDIAccess@ in the whole codebase, it
-- always passes @{sysex: false}@, and it is reachable only from
-- @#btn-device-enable@'s click handler in Main.hs. 'midiAvailable' is
-- feature detection ONLY (read the property, test
-- 'isUndefined'\/'isNull') and can never trigger a permission prompt,
-- which is what keeps it safe to call at boot.
--
-- PRIVACY (M4 hard constraint 3): MIDI bytes live in 'HubState' (and in
-- Main's model mirror of it, rendered into the hidden
-- @#sxc1-device-state@ blob) and go nowhere else: no network, no
-- storage, no console, nothing appended to 'ProgressEvent' or the M3
-- sink. This module imports neither "Miso.Storage" nor anything that
-- can reach the network.
--
-- HOSTILE-BROWSER DISCIPLINE: a JS exception does NOT unwind into wasm
-- as a catchable Haskell exception -- a JS-side throw kills the whole
-- calling computation. Every entry point below therefore feature-tests
-- before it calls: 'midiAvailable' only READS a property (never calls
-- it), and 'hubEnable' re-runs the same feature test before invoking
-- @requestMIDIAccess@, so the invoke can only ever run against a real
-- function.
module Device.Midi
  ( DeviceVerifier (..)
  , DeviceStatus (..)
  , Hub
  , HubSnapshot (..)
  , newHub
  , midiAvailable
  , webMidiVerifier
  , hubEnable
  , hubDisable
  , hubSetChannel
  , hubSnapshot
  , statusText
  ) where

import           Prelude               hiding ((!!))

import           Data.IORef            (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import           Data.Text             (Text)

-- 'Miso.DSL.(!!)' (the JS indexer) collides with 'Prelude.(!!)' --
-- measured in the M4 design probe (GHC-87543): the fix is to hide the
-- Prelude one, since this module indexes JS arrays, never Haskell lists.
import           Miso

import           SXC1.Exercise.Engine  (ConfirmSource (..))
import           SXC1.Exercise.Types   (VerifySpec (..))
import           SXC1.Midi.Spec        (decodeMidi, matchSpec, msgChannel, selectPorts)

--------------------------------------------------------------------------
-- The M2 contract, moved here from Main.hs (M2 defined it next to its
-- do-nothing placeholder value; M4 deletes that dead value, so the type
-- now lives with its one real implementation).
--------------------------------------------------------------------------

data DeviceVerifier = DeviceVerifier
  { dvAvailable :: IO Bool
  , dvWatch     :: VerifySpec -> (ConfirmSource -> IO ()) -> IO (IO ())
  }

-- | 'DevUnsupported' is set once, at 'newHub' time, from the same
-- feature detection 'dvAvailable' performs -- a browser cannot gain Web
-- MIDI mid-session.
data DeviceStatus
  = DevOff
  | DevPending
  | DevGranted
  | DevDenied
  | DevUnsupported
  deriving (Eq)

statusText :: DeviceStatus -> Text
statusText DevOff         = "off"
statusText DevPending     = "pending"
statusText DevGranted     = "granted"
statusText DevDenied      = "denied"
statusText DevUnsupported = "unsupported"

--------------------------------------------------------------------------
-- Hub state
--------------------------------------------------------------------------

-- | One registered @verify:@ watch. Pure registry data -- no JS is
-- touched by registering or removing one.
data Watch = Watch
  { wId   :: !Int
  , wSpec :: !VerifySpec
  , wFire :: ConfirmSource -> IO ()
  }

-- | One BOUND input port: its display name, the MIDIInput object, and
-- the one 'Function' installed as its @onmidimessage@. Exactly one
-- Function per bound port, never one per watch -- that is what keeps the
-- 'freeFunction' accounting trivially correct ('bindPorts' and
-- 'hubDisable' free precisely the Functions they find here).
data BoundPort = BoundPort
  { bpName :: !Text
  , bpObj  :: !JSVal
  , bpFn   :: !Function
  }

data HubState = HubState
  { hsStatus    :: !DeviceStatus
  , hsPorts     :: [BoundPort]     -- ^ bound ports (handler installed)
  , hsAllPorts  :: [Text]          -- ^ every input port's name, bound or not
  , hsChannel   :: !Int            -- ^ expected MIDI channel 1..16, default 1
  , hsLastMsg   :: Maybe [Int]     -- ^ raw bytes, recorded BEFORE decode (P-F: a dropped system message must still leave evidence it arrived)
  , hsLastChan  :: Maybe Int       -- ^ Nothing for system messages
  , hsWatches   :: [Watch]
  , hsNextId    :: !Int
  , hsAccess    :: Maybe JSVal     -- ^ the granted MIDIAccess object
  , hsStateCb   :: Maybe Function  -- ^ the installed onstatechange handler
    -- | The CURRENT permission request's two settle callbacks, parked
    -- here and freed on 'hubDisable' AND at the start of the NEXT
    -- request ('hubEnable' -- the M4 gate-1 LOW-finding fix: a denied
    -- request leaves the hub off without ever reaching 'hubDisable', so
    -- repeated deny\/retry cycles used to accumulate a Function pair per
    -- attempt for the page lifetime). Freeing a wrapper from inside its
    -- own invocation is not obviously safe on this runtime, which is why
    -- the settled pair is NOT freed by the settle callback itself but
    -- parked until the next enable\/disable -- both of which run from a
    -- click handler, never from inside a wrapper invocation. At most one
    -- settled pair is therefore ever parked at a time.
  , hsSettleCbs :: [Function]
  }

newtype Hub = Hub (IORef HubState)

-- | The channel survives 'hubDisable' (briefs\/M4-plan.md section 3.4:
-- \"resets everything except the chosen channel\"); everything else is
-- what a fresh hub starts from.
emptyState :: DeviceStatus -> Int -> HubState
emptyState status0 chan = HubState
  { hsStatus    = status0
  , hsPorts     = []
  , hsAllPorts  = []
  , hsChannel   = chan
  , hsLastMsg   = Nothing
  , hsLastChan  = Nothing
  , hsWatches   = []
  , hsNextId    = 0
  , hsAccess    = Nothing
  , hsStateCb   = Nothing
  , hsSettleCbs = []
  }

-- | Feature detection ONLY: read @navigator.requestMIDIAccess@ and test
-- 'isUndefined'\/'isNull'. Reading a property can never trigger a
-- permission prompt and can never throw on a browser without the API,
-- so this is safe at boot -- and it is called there ('main' seeds the
-- model's @supported@ flag from it), exactly as M2's @main@ already
-- called 'dvAvailable'.
midiAvailable :: IO Bool
midiAvailable = do
  nav <- jsg ("navigator" :: MisoString)
  f   <- nav ! midiAccessProp
  u   <- isUndefined f
  n   <- isNull f
  pure (not u && not n)

-- | The permission API's property name, written out exactly once in the
-- whole of site\/app (the M4 structural invariant greps for it):
-- 'midiAvailable' READS the property through this constant and
-- 'hubEnable' INVOKES it through this constant -- the invoke path stays
-- unique, and the name cannot quietly grow a second call site without
-- the grep counting it.
midiAccessProp :: MisoString
midiAccessProp = "requestMIDIAccess"

-- | The channel default is 1: translations\/midi.md section 1.1 -- MIDI
-- IN\/OUT Ch. default to 1, settable 1..16.
newHub :: IO Hub
newHub = do
  ok <- midiAvailable
  Hub <$> newIORef (emptyState (if ok then DevOff else DevUnsupported) 1)

-- | The one real 'DeviceVerifier'. 'dvWatch' is a PURE registry insert
-- returning an idempotent remover; watching before enabling is legal and
-- simply never fires -- that is what lets it be synchronous and total
-- against an asynchronous permission model.
webMidiVerifier :: Hub -> DeviceVerifier
webMidiVerifier hub = DeviceVerifier
  { dvAvailable = midiAvailable
  , dvWatch     = hubWatch hub
  }

--------------------------------------------------------------------------
-- Watch registry
--------------------------------------------------------------------------

hubWatch :: Hub -> VerifySpec -> (ConfirmSource -> IO ()) -> IO (IO ())
hubWatch (Hub ref) spec fire = do
  st <- readIORef ref
  let wid = hsNextId st
  writeIORef ref st
    { hsNextId  = wid + 1
    , hsWatches = hsWatches st ++ [Watch wid spec fire]
    }
  -- The remover filters by the unique id, which makes it idempotent by
  -- construction: calling it twice, calling it after the watch already
  -- fired (the hub's own one-shot removal), and calling it after
  -- 'hubDisable' (which empties the registry) are all no-ops.
  pure (modifyIORef' ref (\s -> s { hsWatches = filter ((/= wid) . wId) (hsWatches s) }))

--------------------------------------------------------------------------
-- Enable / disable
--------------------------------------------------------------------------

-- | THE ONLY CALL SITE of @navigator.requestMIDIAccess@ in the whole
-- codebase, with @{sysex: false}@ always -- reachable only from
-- @#btn-device-enable@'s click handler. @notify@ re-syncs Main's model
-- mirror (it dispatches a refresh action through the component's sink);
-- it is captured here and closed over by every JS callback the hub
-- installs, so asynchronous grant\/deny\/hot-plug\/message events all
-- surface in the DOM without Main polling anything.
hubEnable :: Hub -> IO () -> IO ()
hubEnable hub@(Hub ref) notify = do
  st <- readIORef ref
  case hsStatus st of
    DevPending     -> pure ()  -- a request is already in flight
    DevGranted     -> pure ()  -- already on (Main routes this click to 'hubDisable' instead)
    DevUnsupported -> pure ()
    _ -> do
      ok <- midiAvailable
      if not ok
        then do
          modifyIORef' ref (\s -> s { hsStatus = DevUnsupported })
          notify
        else do
          -- M4 gate-1 fix (briefs/M4-codex-gate1.json, LOW finding):
          -- free the PREVIOUS attempt's settle callbacks before parking
          -- a new pair. Reaching this branch means status is DevOff or
          -- DevDenied (DevPending returned above), so any parked pair
          -- belongs to a request that has already SETTLED (a settled
          -- promise never invokes either callback again) -- freeing
          -- both here is safe, and it is never done from inside a
          -- wrapper's own invocation (see 'hsSettleCbs'). Denied
          -- retries are thereby leak-free: each retry frees the
          -- previous attempt's pair.
          mapM_ freeFunction (hsSettleCbs st)
          modifyIORef' ref (\s -> s { hsStatus = DevPending, hsSettleCbs = [] })
          notify
          nav   <- jsg ("navigator" :: MisoString)
          opts  <- createWith [(("sysex" :: MisoString), False)]
          p     <- nav # midiAccessProp $ [opts]
          okCb  <- Function <$> asyncCallback1 (onGranted hub notify)
          errCb <- Function <$> asyncCallback1 (\_err -> do
                     modifyIORef' ref (\s -> s { hsStatus = DevDenied })
                     notify)
          modifyIORef' ref (\s -> s { hsSettleCbs = okCb : errCb : hsSettleCbs s })
          _ <- p # ("then" :: MisoString) $ [okCb, errCb]
          pure ()

-- | The grant arm: keep the access object, install @onstatechange@
-- (hot-plug rebinds ports; watches are untouched by hot-plug), and bind
-- the selected ports.
onGranted :: Hub -> IO () -> JSVal -> IO ()
onGranted hub@(Hub ref) notify access = do
  scCb <- Function <$> asyncCallback1 (\_ev -> bindPorts hub notify)
  setProp ("onstatechange" :: MisoString) scCb (Object access)
  modifyIORef' ref (\s -> s
    { hsStatus  = DevGranted
    , hsAccess  = Just access
    , hsStateCb = Just scCb
    })
  bindPorts hub notify

-- | Clear every port handler and @onstatechange@, 'freeFunction' all of
-- them (and the parked promise callbacks), and reset everything except
-- the chosen channel -- including the watch registry, so a remover held
-- by Main is a guaranteed no-op afterwards (Main clears its own
-- bookkeeping alongside this call and re-registers on the next
-- reconcile).
hubDisable :: Hub -> IO ()
hubDisable (Hub ref) = do
  st <- readIORef ref
  mapM_ (\bp -> do
          setProp ("onmidimessage" :: MisoString) jsNull (Object (bpObj bp))
          freeFunction (bpFn bp))
        (hsPorts st)
  case hsAccess st of
    Nothing     -> pure ()
    Just access -> setProp ("onstatechange" :: MisoString) jsNull (Object access)
  mapM_ freeFunction (hsStateCb st)
  mapM_ freeFunction (hsSettleCbs st)
  writeIORef ref (emptyState DevOff (hsChannel st))

hubSetChannel :: Hub -> Int -> IO ()
hubSetChannel (Hub ref) c
  | c < 1 || c > 16 = pure ()
  | otherwise       = modifyIORef' ref (\s -> s { hsChannel = c })

--------------------------------------------------------------------------
-- Port binding
--------------------------------------------------------------------------

-- | Idempotent: clears and 'freeFunction's every previously bound
-- handler FIRST, then binds the ports 'selectPorts' picks -- so a
-- hot-plug storm can neither leak Functions nor double-deliver.
bindPorts :: Hub -> IO () -> IO ()
bindPorts hub@(Hub ref) notify = do
  st0 <- readIORef ref
  mapM_ (\bp -> do
          setProp ("onmidimessage" :: MisoString) jsNull (Object (bpObj bp))
          freeFunction (bpFn bp))
        (hsPorts st0)
  modifyIORef' ref (\s -> s { hsPorts = [], hsAllPorts = [] })
  case hsAccess st0 of
    Nothing     -> notify
    Just access -> do
      inputs <- access ! ("inputs" :: MisoString)
      vals   <- inputs # ("values" :: MisoString) $ ()
      arrCls <- jsg ("Array" :: MisoString)
      arr    <- arrCls # ("from" :: MisoString) $ [vals]
      n      <- fromJSValUnchecked =<< (arr ! ("length" :: MisoString))
      infos  <- mapM (\k -> do
                       pobj <- arr !! k
                       nm   <- strField pobj "name"
                       mfr  <- strField pobj "manufacturer"
                       pure (pobj, nm, mfr))
                     [0 .. (n :: Int) - 1]
      let chosen = selectPorts [ (nm, mfr) | (_, nm, mfr) <- infos ]
      bound <- mapM (\(pobj, nm, _) -> do
                      fn <- Function <$> asyncCallback1 (onMidiMessage hub notify)
                      setProp ("onmidimessage" :: MisoString) fn (Object pobj)
                      pure (BoundPort nm pobj fn))
                    [ info | (i, info) <- zip [0 ..] infos, i `elem` chosen ]
      modifyIORef' ref (\s -> s
        { hsAllPorts = [ nm | (_, nm, _) <- infos ]
        , hsPorts    = bound
        })
      notify

-- | Read a string property that may legitimately be null\/undefined
-- (MIDIPort.name and .manufacturer both may be) as a plain 'Text'.
strField :: JSVal -> MisoString -> IO Text
strField v k = do
  x <- v ! k
  u <- isUndefined x
  n <- isNull x
  if u || n
    then pure ""
    else fromMisoString <$> fromJSValUnchecked x

--------------------------------------------------------------------------
-- Message dispatch
--------------------------------------------------------------------------

-- | Dispatch order is load-bearing (briefs\/M4-plan.md section 3.4):
--
--   1. record the raw bytes in 'hsLastMsg' UNCONDITIONALLY, before
--      decoding -- a dropped system message must still leave evidence it
--      arrived, or the \"sysex is ignored\" negative control would be
--      indistinguishable from \"sysex never arrived\" (P-F);
--   2. decode; record 'hsLastChan';
--   3. compute the hits from a snapshot of the registry;
--   4. REMOVE the hits (one-shot: the SXC-1's buttons transmit 127 on
--      press, 0 on release, and 127 again on the next press, so a
--      @cc 80 127@ hook without this would fire repeatedly);
--   5. only THEN fire their callbacks. Firing advances the drill, which
--      re-runs Main's reconciler and registers the NEXT step's watch --
--      removing after firing would delete that freshly registered watch.
onMidiMessage :: Hub -> IO () -> JSVal -> IO ()
onMidiMessage hub@(Hub ref) notify ev = do
  -- M4 gate-1 fix (briefs/M4-codex-gate1.json, HIGH finding, the
  -- enable/disable ordering): the port handler's Haskell body runs
  -- ASYNCHRONOUSLY after the JS-side delivery, so a message delivered
  -- just before a same-turn 'hubDisable' can reach this point with the
  -- hub already off (and Main's reconciler may have legally re-armed a
  -- watch for the next session -- watching-before-enabling is legal).
  -- A disabled hub must be inert: drop the message entirely -- no
  -- 'hsLastMsg' (disable reset it to Nothing; a late message must not
  -- resurrect post-disable evidence), no match, no notify.
  st0 <- readIORef ref
  if hsStatus st0 /= DevGranted
    then pure ()
    else onMidiMessage' hub notify ev

onMidiMessage' :: Hub -> IO () -> JSVal -> IO ()
onMidiMessage' (Hub ref) notify ev = do
  d     <- ev ! ("data" :: MisoString)
  n     <- fromJSValUnchecked =<< (d ! ("length" :: MisoString))
  bytes <- mapM (\k -> fromJSValUnchecked =<< (d !! k)) [0 .. (n :: Int) - 1]
  let mMsg = decodeMidi bytes
  modifyIORef' ref (\s -> s
    { hsLastMsg  = Just bytes
    , hsLastChan = msgChannel <$> mMsg
    })
  st <- readIORef ref
  let hits = case mMsg of
        Nothing  -> []
        Just msg -> [ w | w <- hsWatches st, matchSpec (hsChannel st) (wSpec w) msg ]
      hitIds = map wId hits
  modifyIORef' ref (\s -> s { hsWatches = filter ((`notElem` hitIds) . wId) (hsWatches s) })
  mapM_ (\w -> wFire w ByDevice) hits
  notify

--------------------------------------------------------------------------
-- Snapshot (for Main's model mirror -- Miso's viewModel is a pure
-- function of the Model and cannot read this module's IORef at render
-- time, exactly the mEventLog precedent).
--------------------------------------------------------------------------

data HubSnapshot = HubSnapshot
  { snapStatus   :: !DeviceStatus
  , snapChannel  :: !Int
  , snapPorts    :: [Text]
  , snapAllPorts :: [Text]
  , snapLastMsg  :: Maybe [Int]
  , snapLastChan :: Maybe Int
  } deriving (Eq)

hubSnapshot :: Hub -> IO HubSnapshot
hubSnapshot (Hub ref) = do
  st <- readIORef ref
  pure HubSnapshot
    { snapStatus   = hsStatus st
    , snapChannel  = hsChannel st
    , snapPorts    = map bpName (hsPorts st)
    , snapAllPorts = hsAllPorts st
    , snapLastMsg  = hsLastMsg st
    , snapLastChan = hsLastChan st
    }
