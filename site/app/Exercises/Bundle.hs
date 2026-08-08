{-# LANGUAGE OverloadedStrings #-}

-- | M6 W1 (briefs\/M6-plan.md, ruling 1): the exercise corpus is no
-- longer TH-embedded in app.wasm ("Exercises.Embed" is retired). The
-- static shell (@site\/static\/index.js@) loads the active language's
-- content bundle over the network BEFORE it starts the wasm reactor,
-- with the SAME JS-side-guard discipline as the @__sxc1Storage@ bridge
-- ("Progress.Store"): the network call and its failure handling live
-- ENTIRELY on the JS side, because a JS exception does not unwind into
-- Haskell as a catchable exception -- it kills the calling computation
-- (the measured M3 storage-refused lesson). The shell always installs
-- @window.__sxc1Content@ -- a bridge whose three methods are total
-- (try\/catch, sentinel returns) -- before @hs_start@ runs, so 'main'
-- can read the result synchronously at boot and a load failure
-- degrades into a visible in-app state instead of a dead page.
--
-- THE BUNDLE FORMAT (produced by @scripts\/emit-content-bundles.py@,
-- consumed by 'parseBundle'; both fail loudly on violations):
--
-- @
-- !SXC1-BUNDLE v1 \<lang\> \<deck-count\>
-- !SXC1-DECK \<file name, e.g. 000-ch0-01.ex.md\>
-- \<that deck's text, exactly as authored (EN emission) or with ja:
--  variants substituted (JA emission) -- never containing a line that
--  starts with \"!SXC1-\", which the emitter enforces\>
-- !SXC1-DECK \<next file name\>
-- ...
-- @
--
-- Deck order is @content\/exercises\/INDEX@ order, and the name after
-- each @!SXC1-DECK@ is the BARE INDEX entry -- the same identity
-- "Exercises.Embed" used to embed and the harness's Python
-- re-derivation keys off. Every source file ends with a newline and
-- the emitter refuses files that do not, so @T.lines@\/'T.unlines'
-- round-trips each deck's text byte-identically and the per-deck
-- FNV-1a\/chars\/lines numbers in "Exercises.Corpus" stay equal to the
-- disk-derived ones.
module Exercises.Bundle
  ( loadDeckSources
  , parseBundle
  ) where

import           Data.Text   (Text)
import qualified Data.Text   as T

import           Miso        (JSVal, fromJSValUnchecked, jsg, (#))
import           Miso.String (MisoString, fromMisoString)

import           SXC1.Route  (parseDigits)

-- | Call one niladic method on the @window.__sxc1Content@ bridge. The
-- bridge is installed by the static shell before the wasm boots; every
-- method is total on the JS side (try\/catch, sentinel returns), so
-- this can never throw across the boundary -- the "Progress.Store"
-- bridge discipline, verbatim.
bridge :: MisoString -> IO JSVal
bridge method = do
  o <- jsg ("__sxc1Content" :: MisoString)
  (o # method) ([] :: [MisoString])

-- | @Just text@ when the shell's load succeeded; @Nothing@ (JS
-- undefined) when it failed or the bridge itself is broken.
bridgeText :: IO (Maybe MisoString)
bridgeText = fromJSValUnchecked =<< bridge "text"

-- | The shell's failure reason, when the load failed.
bridgeError :: IO (Maybe MisoString)
bridgeError = fromJSValUnchecked =<< bridge "error"

-- | The boot-time read: 'Right' the INDEX-ordered @(file name, text)@
-- deck sources (exactly the shape the retired "Exercises.Embed" spliced
-- at compile time), or 'Left' a human-readable reason the app must
-- surface in its degraded state. Never throws.
loadDeckSources :: IO (Either Text [(FilePath, Text)])
loadDeckSources = do
  mt <- bridgeText
  case mt of
    Just t  -> pure (parseBundle (fromMisoString t))
    Nothing -> do
      me <- bridgeError
      pure (Left (case me of
        Just e | not (T.null (T.strip (fromMisoString e))) -> fromMisoString e
        _ -> "content bundle unavailable (no reason reported by the shell)"))

deckDelim :: Text
deckDelim = "!SXC1-DECK "

-- | Split a fetched bundle back into decks -- the inverse of the
-- emitter's concatenation. Strict about its own framing (a malformed
-- bundle is a degraded state naming the problem, never a silent
-- half-corpus), while the deck text itself is passed through verbatim
-- for "SXC1.Exercise.Reader" to parse exactly as it parsed the
-- embedded text.
parseBundle :: Text -> Either Text [(FilePath, Text)]
parseBundle raw = case T.lines raw of
  []           -> Left "content bundle is empty"
  (hdr : rest) -> do
    n     <- headerDeckCount hdr
    decks <- splitDecks rest
    if length decks == n
      then Right decks
      else Left ("content bundle header declares " <> tshow n
                   <> " deck(s) but " <> tshow (length decks) <> " were found")
  where
    tshow = T.pack . show

    headerDeckCount hdr = case T.words hdr of
      ["!SXC1-BUNDLE", "v1", _lang, countTxt] ->
        case parseDigits countTxt of
          Just n  -> Right n
          Nothing -> Left ("content bundle header has a malformed deck count: " <> T.take 80 hdr)
      _ -> Left ("content bundle does not start with a '!SXC1-BUNDLE v1 <lang> <count>' header: "
                   <> T.take 80 hdr)

    splitDecks [] = Right []
    splitDecks (l : ls) = case T.stripPrefix deckDelim l of
      Nothing -> Left ("expected a '" <> deckDelim <> "<name>' delimiter, got: " <> T.take 80 l)
      Just nameTxt ->
        let name         = T.strip nameTxt
            (body, more) = break (T.isPrefixOf deckDelim) ls
        in if T.null name
             then Left "content bundle has an empty deck name in a !SXC1-DECK delimiter"
             else ((T.unpack name, T.unlines body) :) <$> splitDecks more
