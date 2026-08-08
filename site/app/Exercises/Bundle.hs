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
--
-- ACCEPTANCE IS ALL-OR-NOTHING (M6 gate round 1, finding M6-R1-1). A
-- successful HTTP response is NOT evidence of a healthy corpus: the URL
-- can serve the other language's bundle, a stale build, a truncated
-- body that still carries every delimiter, a zero-deck body, or a body
-- missing a deck -- and every one of those used to render as a
-- smaller-but-"healthy" course with no alert. 'parseBundle' now checks
-- the fetched bytes against "Exercises.Manifest" -- the BUILD-TIME
-- expectation compiled into this same wasm module -- and returns 'Left'
-- (the existing visible alert\/retry state) on ANY disagreement:
--
--   1. the header's language must equal the language the shell actually
--      requested (it used to be parsed and thrown away);
--   2. the @!SXC1-DECK@ names must equal 'manifestDecks' EXACTLY, in
--      INDEX order (which also rejects duplicates, omissions and
--      insertions);
--   3. the header's declared deck count must equal both;
--   4. FNV-1a\/32 over the WHOLE body must equal this build's recorded
--      fingerprint for that language.
--
-- The expectation deliberately does not travel WITH the bundle: a
-- bundle attesting to itself proves only internal consistency, so a
-- complete older build would satisfy it. See "Exercises.Manifest"'s own
-- header. "Exercises.Corpus".'Exercises.Corpus.checkedCorpusOf' then
-- adds the half that needs a parse: every deck must parse, and the
-- aggregate (decks, exercises, prompts) counts must match the same
-- manifest exactly.
module Exercises.Bundle
  ( loadDeckSources
  , parseBundle
  ) where

import           Data.Text          (Text)
import qualified Data.Text          as T

import           Miso               (JSVal, fromJSValUnchecked, jsg, (#))
import           Miso.String        (MisoString, fromMisoString)

import           Exercises.Corpus   (fnv1a32)
import           Exercises.Manifest (manifestDeckCount, manifestDecks, manifestFingerprint)
import           SXC1.Route         (parseDigits)

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

-- | Which language the shell actually ASKED FOR -- the boot hint it
-- picked the URL from, not anything the response says about itself.
-- Anything the bridge cannot report is @\"en\"@, the same clamp the
-- shell and the prefs codec apply.
bridgeLang :: IO Text
bridgeLang = do
  ml <- fromJSValUnchecked =<< bridge "lang"
  pure (case ml of
    Just l | not (T.null (T.strip (fromMisoString l))) -> T.strip (fromMisoString l)
    _ -> "en")

-- | The boot-time read: the language the shell requested, plus 'Right'
-- the INDEX-ordered @(file name, text)@ deck sources (exactly the shape
-- the retired "Exercises.Embed" spliced at compile time) or 'Left' a
-- human-readable reason the app must surface in its degraded state.
-- Never throws.
loadDeckSources :: IO (Text, Either Text [(FilePath, Text)])
loadDeckSources = do
  lang <- bridgeLang
  mt   <- bridgeText
  res  <- case mt of
    Just t  -> pure (parseBundle lang (fromMisoString t))
    Nothing -> do
      me <- bridgeError
      pure (Left (case me of
        Just e | not (T.null (T.strip (fromMisoString e))) -> fromMisoString e
        _ -> "content bundle unavailable (no reason reported by the shell)"))
  pure (lang, res)

deckDelim :: Text
deckDelim = "!SXC1-DECK "

-- | Split a fetched bundle back into decks -- the inverse of the
-- emitter's concatenation -- and check the whole thing against
-- "Exercises.Manifest", this build's own expectation (see the module
-- Haddock: acceptance is ALL-OR-NOTHING). @wantLang@ is the language
-- the shell REQUESTED; the deck text itself is passed through verbatim
-- for "SXC1.Exercise.Reader" to parse exactly as it parsed the embedded
-- text.
parseBundle :: Text -> Text -> Either Text [(FilePath, Text)]
parseBundle wantLang raw = case T.lines raw of
  []           -> Left "content bundle is empty"
  (hdr : rest) -> do
    n     <- headerCheck hdr
    decks <- splitDecks rest
    _     <- if length decks == n
               then Right ()
               else Left ("content bundle header declares " <> tshow n
                            <> " deck(s) but " <> tshow (length decks) <> " were found")
    _     <- checkNames (0 :: Int) (map fst decks) manifestDecks
    _     <- checkFingerprint
    Right decks
  where
    tshow = T.pack . show

    -- (a) The header language must EQUAL the requested language -- it
    -- used to be bound as _lang and ignored, so the ja bundle served at
    -- the en URL (a mis-deployed or mis-cached host) rendered as a
    -- healthy English course in Japanese.
    headerCheck hdr = case T.words hdr of
      ["!SXC1-BUNDLE", "v1", lang, countTxt]
        | lang /= wantLang ->
            Left ("content bundle is for language '" <> lang <> "' but '" <> wantLang
                    <> "' was requested")
        | otherwise -> case parseDigits countTxt of
            Just n
              | n == manifestDeckCount -> Right n
              | otherwise -> Left ("content bundle header declares " <> tshow n
                                     <> " deck(s); this build expects " <> tshow manifestDeckCount)
            Nothing -> Left ("content bundle header has a malformed deck count: " <> T.take 80 hdr)
      _ -> Left ("content bundle does not start with a '!SXC1-BUNDLE v1 <lang> <count>' header: "
                   <> T.take 80 hdr)

    -- (b) The exact INDEX-ordered deck manifest. Equality of the two
    -- ordered lists rejects a missing deck, an extra deck, a renamed
    -- deck, a reordered deck and a duplicated deck in one comparison.
    checkNames _ []       []       = Right ()
    checkNames i (g : gs) (e : es)
      | g == e    = checkNames (i + 1) gs es
      | otherwise = Left ("content bundle deck " <> tshow (i + 1) <> " is '" <> T.pack g
                            <> "'; this build expects '" <> T.pack e <> "'")
    checkNames i gs es = Left ("content bundle carries " <> tshow (i + length gs)
                                 <> " deck(s); this build expects " <> tshow (i + length es))

    -- (c) The catch-all: this build's fingerprint over the WHOLE body.
    -- Anything the checks above cannot see -- a stale build, an edited
    -- deck body, a truncated final deck, whitespace drift -- fails here.
    checkFingerprint = case manifestFingerprint wantLang of
      Nothing -> Left ("this build ships no content bundle for language '" <> wantLang <> "'")
      Just want
        | got == want -> Right ()
        -- Not 'tshow': the fingerprints are 'Word32', and the
        -- monomorphism restriction has already fixed tshow at Int here.
        | otherwise   -> Left ("content bundle does not match this build (fingerprint "
                                 <> T.pack (show got) <> ", expected " <> T.pack (show want)
                                 <> ") -- a stale or altered bundle is being served")
        where got = fnv1a32 raw

    splitDecks [] = Right []
    splitDecks (l : ls) = case T.stripPrefix deckDelim l of
      Nothing -> Left ("expected a '" <> deckDelim <> "<name>' delimiter, got: " <> T.take 80 l)
      Just nameTxt ->
        let name         = T.strip nameTxt
            (body, more) = break (T.isPrefixOf deckDelim) ls
        in if T.null name
             then Left "content bundle has an empty deck name in a !SXC1-DECK delimiter"
             else ((T.unpack name, T.unlines body) :) <$> splitDecks more
