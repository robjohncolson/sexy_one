{-# LANGUAGE CPP               #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import qualified Data.Text   as T

import           Miso

import           SXC1.Route  (Route (..), parseRoute, renderRoute)

import           View.Pages  (viewRoute)

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

newtype Model = Model { mRoute :: Route } deriving (Eq)

data Action
  = HashChanged
  | SetRoute Route
  | ToggleJA

#ifdef WASM
foreign export javascript "hs_start" main :: IO ()
#endif

main :: IO ()
main = do
  h <- currentHash
  startApp defaultEvents (readerApp (parseRoute h))

readerApp :: Route -> App Model Action
readerApp r0 = (component (Model r0) updateModel viewModel)
  { subs = [ windowSub "hashchange" emptyDecoder (const HashChanged) ] }

updateModel :: Action -> Effect parent props Model Action
updateModel = \case
  HashChanged ->
    io (SetRoute . parseRoute <$> currentHash)

  SetRoute r -> do
    modify (\m -> m { mRoute = r })
    io_ (scrollIntoView "app")

  ToggleJA -> do
    r <- gets mRoute
    case r of
      RPage slug n ja -> do
        let r' = RPage slug n (not ja)
        modify (\m -> m { mRoute = r' })
        io_ (setHash (renderRoute r'))
      _ -> pure ()

viewModel :: props -> Model -> View Model Action
viewModel _ (Model r) = viewRoute ToggleJA r
