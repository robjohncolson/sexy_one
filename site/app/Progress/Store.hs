{-# LANGUAGE OverloadedStrings #-}

-- | The storage IO boundary. Pure codecs live in "SXC1.Progress.Codec";
-- this module only moves blobs in and out of the browser.
--
-- M3 HARDENING (harness finding, @--check-storage-refused@): the first
-- version imported "Miso.Storage" and wrapped calls in
-- 'Control.Exception.try' -- which CANNOT work here: a JS exception
-- thrown by @localStorage@ (private mode, quota exhaustion, storage
-- disabled) does not unwind into Haskell as a catchable exception; it
-- propagates out of the wasm import and killed the whole boot
-- computation (@window.__SXC1_BOOT_ERROR@). Every access therefore goes
-- through @window.__sxc1Storage@ -- a tiny bridge in
-- @site\/static\/index.js@ that try\/catches JS-SIDE and returns
-- sentinel values (undefined \/ 0) instead of throwing, so no storage
-- exception can ever reach the wasm boundary. The check-site standing
-- guard pins this module as the only Haskell file touching the bridge.
--
-- THE ONE RULE THAT MATTERS: a key that failed to DECODE is never
-- overwritten. 'loadProgress' hands the caller the three-way
-- 'DecodeResult'; Main.hs only ever calls 'saveProgress' when the load
-- was 'DecodeOk'\/'DecodeEmpty' AND 'storageAvailable' probed true. A
-- learner's history is the one thing in this app that cannot be
-- regenerated; a corrupt blob stays on disk untouched ('loadRaw'
-- exposes it for export) until the learner explicitly wipes or imports.
--
-- The reader preference lives under its own separate key ('prefsKey'),
-- so wiping progress ('wipeProgress') cannot wipe the reading
-- preference, and the preference stays settable while a corrupt
-- progress blob has the app in read-only progress mode -- see
-- "SXC1.Progress.Codec"'s two documented asymmetries.
module Progress.Store
  ( storageKey
  , prefsKey
  , storageAvailable
  , loadProgress
  , saveProgress
  , wipeProgress
  , loadRaw
  , loadPrefs
  , savePrefs
  ) where

import           Data.Text            (Text)

import           Miso                 (JSVal, fromJSValUnchecked, jsg, (#))
import           Miso.String          (MisoString, fromMisoString, ms)

import           SXC1.Progress.Codec  (DecodeResult (..), Prefs, decodePrefs, decodeState,
                                       defaultPrefs, encodePrefs, encodeState)
import           SXC1.Progress.Types  (ProgressState)

storageKey :: MisoString
storageKey = "sxc1.progress"

prefsKey :: MisoString
prefsKey = "sxc1.prefs"

-- | Call one method on the @window.__sxc1Storage@ bridge. The bridge is
-- installed by the static shell before the wasm boots; every method is
-- total on the JS side (try\/catch, sentinel returns), so this can never
-- throw across the boundary.
bridge :: MisoString -> [MisoString] -> IO JSVal
bridge method args = do
  o <- jsg ("__sxc1Storage" :: MisoString)
  (o # method) args

-- | @Just blob@ or @Nothing@ for missing-or-refused -- the bridge's
-- @get@ returns undefined for both, which 'fromJSValUnchecked' reads
-- back as 'Nothing' (the same probed behavior Miso.Storage's own
-- reader relied on).
bridgeGet :: MisoString -> IO (Maybe MisoString)
bridgeGet key = fromJSValUnchecked =<< bridge "get" [key]

-- | The write probe, entirely JS-side: set, read back, remove, all
-- inside the bridge's own try\/catch. 1 = genuinely writable.
storageAvailable :: IO Bool
storageAvailable = do
  r <- fromJSValUnchecked =<< bridge "probe" []
  pure (r == Just (1 :: Int))

loadProgress :: IO DecodeResult
loadProgress = do
  mv <- bridgeGet storageKey
  pure $ case mv of
    Just blob -> decodeState (fromMisoString blob)
    Nothing   -> DecodeEmpty

-- | M3 gate NEW9: returns whether the WRITE actually succeeded (the
-- bridge's set returns 1\/0 from its own try\/catch) -- quota can run
-- out or storage be revoked long after the boot probe passed, and a
-- discarded failure is silent history loss. Main degrades to
-- storage-unavailable mode on the first False.
saveProgress :: ProgressState -> IO Bool
saveProgress st = do
  r <- fromJSValUnchecked =<< bridge "set" [storageKey, ms (encodeState st)]
  pure (r == Just (1 :: Int))

-- | Removes ONLY the progress key -- never 'prefsKey' (the module
-- Haddock's separate-key asymmetry). M3 re-gate NEW9 (residual):
-- returns the bridge's real delete result -- a wipe that silently
-- failed must not let the app pretend the key is gone.
wipeProgress :: IO Bool
wipeProgress = do
  r <- fromJSValUnchecked =<< bridge "del" [storageKey]
  pure (r == Just (1 :: Int))

-- | The undecoded blob as stored, for the corrupt-state export path.
loadRaw :: IO (Maybe Text)
loadRaw = fmap (fmap fromMisoString) (bridgeGet storageKey)

-- | Prefs fall back to 'defaultPrefs' on ANY failure -- the documented
-- asymmetry with 'loadProgress': a preference is trivially regenerable.
loadPrefs :: IO Prefs
loadPrefs = do
  mv <- bridgeGet prefsKey
  pure $ case mv of
    Just blob -> decodePrefs (fromMisoString blob)
    Nothing   -> defaultPrefs

-- | Same NEW9 contract as 'saveProgress'.
savePrefs :: Prefs -> IO Bool
savePrefs p = do
  r <- fromJSValUnchecked =<< bridge "set" [prefsKey, ms (encodePrefs p)]
  pure (r == Just (1 :: Int))
