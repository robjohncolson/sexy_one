{-# LANGUAGE OverloadedStrings #-}

-- | THE FETCHED-BUNDLE LAYER -- one grammar, one fetch discipline, one
-- degraded state, for BOTH externalized corpora.
--
-- M6 W1 (briefs\/M6-plan.md, ruling 1) moved the exercise corpus out of
-- app.wasm; M7 W1 (briefs\/M7-plan.md, ruling 1) moved the manual text
-- out for the same reason -- ~396 KB of Japanese manual text does not
-- fit under the frozen wasm ceiling, and the four EN translations were
-- already 193,460 raw bytes of the binary. Both now ship as
-- per-language files the static shell (@site\/static\/index.js@) loads
-- over the network BEFORE it starts the wasm reactor, with the SAME
-- JS-side-guard discipline as the @__sxc1Storage@ bridge
-- ("Progress.Store"): the network calls and their failure handling live
-- ENTIRELY on the JS side, because a JS exception does not unwind into
-- Haskell as a catchable exception -- it kills the calling computation
-- (the measured M3 storage-refused lesson). The shell always installs
-- @window.__sxc1Content@ -- a bridge whose methods are total (try\/catch,
-- sentinel returns) -- before @hs_start@ runs, so 'main' can read the
-- result synchronously at boot and a load failure degrades into a
-- visible in-app state instead of a dead page. BOTH loads run under the
-- shell's ONE 15-second deadline.
--
-- THE BUNDLE FORMAT -- ONE GRAMMAR, TWO RECORD KINDS (produced by
-- @scripts\/emit-content-bundles.py@, consumed by 'parseBundle' and
-- 'parseManualBundle'; both ends fail loudly on violations):
--
-- @
-- !SXC1-BUNDLE v1 \<lang\> \<record-count\>
-- !SXC1-DECK \<file name, e.g. 000-ch0-01.ex.md\>
-- \<that deck's text, exactly as authored (EN emission) or with ja:
--  variants substituted (JA emission)\>
-- ...
--
-- !SXC1-BUNDLE v1 \<lang\> \<record-count\>
-- !SXC1-DOC \<slug\> \<the language THIS document carries\> \<page count\>
-- \<that document's markdown, byte-identical to translations\/\<slug\>.md
--  (or \<slug\>.ja.md once wave 2 authors it)\>
-- ...
-- @
--
-- ONE grammar rather than two was a deliberate ruling: the header line,
-- the reserved @\"!SXC1-\"@ column-0 delimiter prefix (no source line may
-- start with it -- the emitter enforces that for every file of both
-- corpora, which is what makes splitting unambiguous), the
-- newline-terminated record bodies that @T.lines@\/'T.unlines'
-- round-trip byte-identically, the whole-body FNV-1a\/32 fingerprint and
-- the wasm-embedded expectation are all shared. Only the delimiter
-- KEYWORD and its field list differ per kind, and even the splitting is
-- one function ('framedRecords') parameterised by that keyword -- so
-- there is exactly one place where a framing bug can live, and exactly
-- one place to fix it.
--
-- ACCEPTANCE IS ALL-OR-NOTHING, FOR BOTH KINDS (M6 gate round 1,
-- finding M6-R1-1; extended to manuals by M7 W1). A successful HTTP
-- response is NOT evidence of a healthy corpus: the URL can serve the
-- other language's bundle, a stale build, a truncated body that still
-- carries every delimiter, an empty body, or a body missing a record --
-- and every one of those used to render as a smaller-but-\"healthy\"
-- artifact with no alert. Both parsers check the fetched bytes against
-- "Bundle.Manifest" -- the BUILD-TIME expectation compiled into this
-- same wasm module -- and return 'Left' (the existing visible
-- alert\/retry state) on ANY disagreement:
--
--   1. the header's language must equal the language the shell actually
--      requested (it used to be parsed and thrown away);
--   2. the record names must equal the manifest's list EXACTLY, in
--      order (which also rejects duplicates, omissions and insertions);
--   3. the header's declared record count must equal both;
--   4. FNV-1a\/32 over the WHOLE body must equal this build's recorded
--      fingerprint for that language and kind.
--
-- The expectation deliberately does not travel WITH the bundle: a
-- bundle attesting to itself proves only internal consistency, so a
-- complete older build would satisfy it. See "Bundle.Manifest"'s own
-- header. The half that needs a real parse is layered on top by each
-- corpus's own module -- "Exercises.Corpus".'Exercises.Corpus.checkedCorpusOf'
-- (every deck must parse; aggregate counts must match) and
-- "View.Pages".'View.Pages.mkManuals' (every document must parse and
-- yield exactly the manifest's page count).
module Bundle
  ( loadDeckSources
  , parseBundle
    -- * M7 W1: the manual half
  , ManualDoc (..)
  , loadManualSources
  , parseManualBundle
  ) where

import           Data.Text       (Text)
import qualified Data.Text       as T
import           Data.Word       (Word32)

import           Miso            (JSVal, fromJSValUnchecked, jsg, (#))
import           Miso.String     (MisoString, fromMisoString)

import           Bundle.Manifest (manifestDeckCount, manifestDecks, manifestFingerprint,
                                  manifestManualDocCount, manifestManualDocs,
                                  manifestManualFingerprint)
import           Exercises.Corpus (fnv1a32)
import           SXC1.Route      (parseDigits)

-- | Call one niladic method on the @window.__sxc1Content@ bridge. The
-- bridge is installed by the static shell before the wasm boots; every
-- method is total on the JS side (try\/catch, sentinel returns), so
-- this can never throw across the boundary -- the "Progress.Store"
-- bridge discipline, verbatim.
bridge :: MisoString -> IO JSVal
bridge method = do
  o <- jsg ("__sxc1Content" :: MisoString)
  (o # method) ([] :: [MisoString])

-- | @Just text@ when the shell's load of that bundle succeeded;
-- @Nothing@ (JS undefined) when it failed or the bridge itself is
-- broken.
bridgeText :: MisoString -> IO (Maybe MisoString)
bridgeText method = fromJSValUnchecked =<< bridge method

-- | Which language the shell actually ASKED FOR -- the boot hint it
-- picked both URLs from, not anything either response says about
-- itself. Anything the bridge cannot report is @\"en\"@, the same clamp
-- the shell and the prefs codec apply.
bridgeLang :: IO Text
bridgeLang = do
  ml <- fromJSValUnchecked =<< bridge "lang"
  pure (case ml of
    Just l | not (T.null (T.strip (fromMisoString l))) -> T.strip (fromMisoString l)
    _ -> "en")

-- | The shared boot-time read: ask the bridge for one bundle's text,
-- then either parse it or report the shell's own failure reason. Never
-- throws. @fallbackReason@ names the bundle in the (rare) case the
-- shell reported a failure without saying why.
loadVia
  :: MisoString                          -- ^ the bridge's text method
  -> MisoString                          -- ^ the bridge's error method
  -> Text                                -- ^ fallback reason
  -> (Text -> Text -> Either Text a)     -- ^ the parser, given the REQUESTED language
  -> IO (Text, Either Text a)
loadVia textMethod errMethod fallbackReason parse = do
  lang <- bridgeLang
  mt   <- bridgeText textMethod
  res  <- case mt of
    Just t  -> pure (parse lang (fromMisoString t))
    Nothing -> do
      me <- bridgeText errMethod
      pure (Left (case me of
        Just e | not (T.null (T.strip (fromMisoString e))) -> fromMisoString e
        _ -> fallbackReason))
  pure (lang, res)

-- | The boot-time read for the EXERCISE corpus: the language the shell
-- requested, plus 'Right' the INDEX-ordered @(file name, text)@ deck
-- sources (exactly the shape the retired "Exercises.Embed" spliced at
-- compile time) or 'Left' a human-readable reason the app must surface
-- in its degraded state. Never throws.
loadDeckSources :: IO (Text, Either Text [(FilePath, Text)])
loadDeckSources =
  loadVia "text" "error" "content bundle unavailable (no reason reported by the shell)" parseBundle

-- | The boot-time read for the MANUAL text (M7 W1) -- the same shape,
-- the same guarantees, through the same bridge, for the same requested
-- language. Never throws.
loadManualSources :: IO (Text, Either Text [ManualDoc])
loadManualSources =
  loadVia "manualText" "manualError"
    "manual bundle unavailable (no reason reported by the shell)" parseManualBundle

--------------------------------------------------------------------------
-- The shared framing (see the module Haddock: ONE grammar).
--------------------------------------------------------------------------

-- | Split a fetched bundle into (the count its header declares, its
-- records) -- each record being (the text after the delimiter keyword,
-- the record's body). The inverse of the emitter's concatenation, for
-- either kind: @kind@ is the delimiter keyword (@\"DECK\"@ \/ @\"DOC\"@).
--
-- @wantLang@ is the language the shell REQUESTED, and the header's
-- language must EQUAL it -- it used to be bound as @_lang@ and ignored,
-- so the ja bundle served at the en URL (a mis-deployed or mis-cached
-- host) rendered as a healthy English artifact in Japanese. Record
-- bodies are passed through verbatim for each corpus's own parser.
framedRecords :: Text -> Text -> Text -> Text -> Either Text (Int, [(Text, Text)])
framedRecords what kind wantLang raw = case T.lines raw of
  []           -> Left (what <> " bundle is empty")
  (hdr : rest) -> do
    n    <- headerCheck hdr
    recs <- splitRecords rest
    Right (n, recs)
  where
    delim = "!SXC1-" <> kind <> " "

    headerCheck hdr = case T.words hdr of
      ["!SXC1-BUNDLE", "v1", lang, countTxt]
        | lang /= wantLang ->
            Left (what <> " bundle is for language '" <> lang <> "' but '" <> wantLang
                    <> "' was requested")
        | otherwise -> case parseDigits countTxt of
            Just n  -> Right n
            Nothing -> Left (what <> " bundle header has a malformed record count: " <> T.take 80 hdr)
      _ -> Left (what <> " bundle does not start with a '!SXC1-BUNDLE v1 <lang> <count>' header: "
                   <> T.take 80 hdr)

    splitRecords [] = Right []
    splitRecords (l : ls) = case T.stripPrefix delim l of
      Nothing -> Left ("expected a '" <> delim <> "...' delimiter, got: " <> T.take 80 l)
      Just fieldsTxt ->
        let fields       = T.strip fieldsTxt
            (body, more) = break (T.isPrefixOf delim) ls
        in if T.null fields
             then Left (what <> " bundle has an empty " <> delim <> "delimiter")
             else ((fields, T.unlines body) :) <$> splitRecords more

tshow :: Int -> Text
tshow = T.pack . show

-- | The header's declared record count must equal both the number of
-- records found AND this build's expectation.
countCheck :: Text -> Int -> Int -> Int -> Either Text ()
countCheck what declared found expected
  | declared /= expected =
      Left (what <> " bundle header declares " <> tshow declared
              <> " record(s); this build expects " <> tshow expected)
  | found /= declared =
      Left (what <> " bundle header declares " <> tshow declared
              <> " record(s) but " <> tshow found <> " were found")
  | otherwise = Right ()

-- | The catch-all: this build's fingerprint over the WHOLE body.
-- Anything the structural checks cannot see -- a stale build, an edited
-- record, a truncated final record, whitespace drift -- fails here.
fingerprintCheck :: Text -> (Text -> Maybe Word32) -> Text -> Text -> Either Text ()
fingerprintCheck what expectOf wantLang raw = case expectOf wantLang of
  Nothing -> Left ("this build ships no " <> what <> " bundle for language '" <> wantLang <> "'")
  Just want
    | got == want -> Right ()
    -- Not 'tshow': the fingerprints are 'Word32', and 'tshow' above is
    -- monomorphically fixed at 'Int'.
    | otherwise   -> Left (what <> " bundle does not match this build (fingerprint "
                             <> T.pack (show got) <> ", expected " <> T.pack (show want)
                             <> ") -- a stale or altered bundle is being served")
    where got = fnv1a32 raw

--------------------------------------------------------------------------
-- The exercise half.
--------------------------------------------------------------------------

-- | Split a fetched exercise bundle back into decks and check the whole
-- thing against "Bundle.Manifest" (see the module Haddock: acceptance is
-- ALL-OR-NOTHING).
parseBundle :: Text -> Text -> Either Text [(FilePath, Text)]
parseBundle wantLang raw = do
  (n, recs) <- framedRecords "content" "DECK" wantLang raw
  countCheck "content" n (length recs) manifestDeckCount
  -- Equality of the two ordered lists rejects a missing deck, an extra
  -- deck, a renamed deck, a reordered deck and a duplicated deck in one
  -- comparison.
  checkNames (0 :: Int) (map (T.unpack . fst) recs) manifestDecks
  fingerprintCheck "content" manifestFingerprint wantLang raw
  Right [ (T.unpack name, body) | (name, body) <- recs ]
  where
    checkNames _ []       []       = Right ()
    checkNames i (g : gs) (e : es)
      | g == e    = checkNames (i + 1) gs es
      | otherwise = Left ("content bundle deck " <> tshow (i + 1) <> " is '" <> T.pack g
                            <> "'; this build expects '" <> T.pack e <> "'")
    checkNames i gs es = Left ("content bundle carries " <> tshow (i + length gs)
                                 <> " deck(s); this build expects " <> tshow (i + length es))

--------------------------------------------------------------------------
-- The manual half (M7 W1).
--------------------------------------------------------------------------

-- | One document as the bundle carries it. 'mdLang' is the language
-- this document's TEXT is actually written in, which is not necessarily
-- the bundle's: until wave 2 authors every @translations\/\<slug\>.ja.md@,
-- the ja bundle carries the EN text for the documents that have none
-- yet. That is the DOCUMENTED, TEMPORARY fallback of briefs\/M7-plan.md
-- ruling 4 -- and it is deliberately VISIBLE, not silent: 'mdLang'
-- travels all the way to "View.Pages", which renders the localized
-- \"Japanese text not available for this document yet\" note rather than
-- presenting English as Japanese.
data ManualDoc = ManualDoc
  { mdSlug  :: !Text
  , mdLang  :: !Text
  , mdPages :: !Int
  , mdText  :: Text     -- ^ LAZY on purpose: nothing forces a document's
                        --   markdown until a route actually reads it.
  } deriving (Eq)

-- | Split a fetched manual bundle back into documents and check the
-- whole thing against "Bundle.Manifest", under exactly the exercise
-- bundle's all-or-nothing rules plus the two the manual records add:
--
--   * each @!SXC1-DOC@ line's slug and page count must equal
--     'manifestManualDocs' in order;
--   * each document's declared LANGUAGE must be legal for this bundle
--     -- the requested language itself, or (only in a non-English
--     bundle) the @\"en\"@ fallback. An English bundle carrying a
--     document that claims some other language, or any bundle claiming
--     a third language, is rejected rather than rendered.
parseManualBundle :: Text -> Text -> Either Text [ManualDoc]
parseManualBundle wantLang raw = do
  (n, recs) <- framedRecords "manual" "DOC" wantLang raw
  countCheck "manual" n (length recs) manifestManualDocCount
  docs <- mapM parseFields (zip [1 :: Int ..] recs)
  checkDocs (1 :: Int) docs manifestManualDocs
  fingerprintCheck "manual" manifestManualFingerprint wantLang raw
  Right docs
  where
    parseFields (i, (fields, body)) = case T.words fields of
      [slug, dl, pagesTxt] -> case parseDigits pagesTxt of
        Just p
          | legalLang dl -> Right (ManualDoc { mdSlug = slug, mdLang = dl, mdPages = p, mdText = body })
          | otherwise    -> Left ("manual bundle document " <> tshow i <> " ('" <> slug
                                    <> "') claims language '" <> dl <> "', which is not legal in a '"
                                    <> wantLang <> "' bundle")
        Nothing -> Left ("manual bundle document " <> tshow i
                           <> " has a malformed page count: " <> T.take 80 fields)
      _ -> Left ("manual bundle document " <> tshow i
                   <> " does not carry a '<slug> <lang> <pages>' delimiter: " <> T.take 80 fields)

    -- The EN bundle must be all-English; a non-English bundle may carry
    -- the documented per-document EN fallback and nothing else.
    legalLang dl = dl == wantLang || (wantLang /= "en" && dl == "en")

    checkDocs _ []       []                 = Right ()
    checkDocs i (d : ds) ((slug, pages) : es)
      | mdSlug d /= slug =
          Left ("manual bundle document " <> tshow i <> " is '" <> mdSlug d
                  <> "'; this build expects '" <> slug <> "'")
      | mdPages d /= pages =
          Left ("manual bundle document '" <> slug <> "' declares " <> tshow (mdPages d)
                  <> " page(s); this build expects " <> tshow pages)
      | otherwise = checkDocs (i + 1) ds es
    checkDocs i ds es = Left ("manual bundle carries " <> tshow (i - 1 + length ds)
                                <> " document(s); this build expects " <> tshow (i - 1 + length es))
