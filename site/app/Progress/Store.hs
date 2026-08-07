{-# LANGUAGE OverloadedStrings #-}

-- | The ONE module in the project allowed to import "Miso.Storage" (the
-- M2-era project-wide grep ban lifts for exactly this file -- the
-- harness enforces that with a case-insensitive grep). Pure codecs live
-- in "SXC1.Progress.Codec"; this module is only the IO boundary.
--
-- THE ONE RULE THAT MATTERS: a key that failed to DECODE is never
-- overwritten. 'loadProgress' hands the caller the three-way
-- 'DecodeResult'; Main.hs only ever calls 'saveProgress' when the load
-- was 'DecodeOk'\/'DecodeEmpty' AND 'storageAvailable' probed true. A
-- learner's history is the one thing in this app that cannot be
-- regenerated; a corrupt blob stays on disk untouched ('loadRaw' exposes
-- it for export) until the learner explicitly wipes or imports.
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

import           Control.Exception    (SomeException, try)
import           Control.Monad        (void)
import           Data.Text            (Text)

import           Miso.Storage         (getLocalStorage, removeLocalStorage, setLocalStorage)
import           Miso.String          (MisoString, fromMisoString, ms)

import           SXC1.Progress.Codec  (DecodeResult (..), Prefs, decodePrefs, decodeState,
                                       defaultPrefs, encodePrefs, encodeState)
import           SXC1.Progress.Types  (ProgressState)

storageKey :: MisoString
storageKey = "sxc1.progress"

prefsKey :: MisoString
prefsKey = "sxc1.prefs"

probeKey :: MisoString
probeKey = "sxc1.storage-probe"

guarded :: IO a -> IO (Either SomeException a)
guarded = try

-- | WRITE a probe key, read it back, remove it -- never merely test for
-- the storage object's presence: a private-mode browser can expose
-- @window.localStorage@ and still throw on the first write, and a
-- quota-exhausted one can too. Any exception anywhere in the probe means
-- "not available", and every write in the app is gated on this.
storageAvailable :: IO Bool
storageAvailable = do
  r <- guarded $ do
    setLocalStorage probeKey "1"
    v <- getLocalStorage probeKey
    removeLocalStorage probeKey
    pure (v == Just ("1" :: MisoString))
  pure (either (const False) id r)

-- | A missing key is 'DecodeEmpty' (probed behavior: 'getLocalStorage'
-- on a missing key returns 'Nothing' cleanly); a throwing storage is
-- also 'DecodeEmpty' -- writes are separately gated by
-- 'storageAvailable', so a throwing read can never lead to an overwrite.
loadProgress :: IO DecodeResult
loadProgress = do
  r <- guarded (getLocalStorage storageKey)
  pure $ case r of
    Right (Just blob) -> decodeState (fromMisoString blob)
    _                 -> DecodeEmpty

saveProgress :: ProgressState -> IO ()
saveProgress st = void (guarded (setLocalStorage storageKey (ms (encodeState st))))

-- | Removes ONLY the progress key -- never 'prefsKey' (the module
-- Haddock's separate-key asymmetry).
wipeProgress :: IO ()
wipeProgress = void (guarded (removeLocalStorage storageKey))

-- | The undecoded blob as stored, for the corrupt-state export path.
loadRaw :: IO (Maybe Text)
loadRaw = do
  r <- guarded (getLocalStorage storageKey)
  pure $ case r of
    Right (Just blob) -> Just (fromMisoString blob)
    _                 -> Nothing

-- | Prefs fall back to 'defaultPrefs' on ANY failure -- the documented
-- asymmetry with 'loadProgress': a preference is trivially regenerable.
loadPrefs :: IO Prefs
loadPrefs = do
  r <- guarded (getLocalStorage prefsKey)
  pure $ case r of
    Right (Just blob) -> decodePrefs (fromMisoString blob)
    _                 -> defaultPrefs

savePrefs :: Prefs -> IO ()
savePrefs p = void (guarded (setLocalStorage prefsKey (ms (encodePrefs p))))
