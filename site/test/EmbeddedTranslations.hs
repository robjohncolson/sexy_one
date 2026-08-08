{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | THE CHECKER'S OWN COMPILE-TIME COPY of the manual translations --
-- and, since M7 W1, the ONLY place in the tree that TH-embeds them.
--
-- M7 W1 (briefs\/M7-plan.md, ruling 1): the manual TEXT moved out of
-- @app.wasm@ into fetched per-language bundles
-- (@site\/public\/content\/manuals.{en,ja}.txt@, emitted by
-- @scripts\/emit-content-bundles.py@ and accepted at boot by "Bundle"),
-- exactly as the exercise corpus did in M6. The library module that
-- used to hold the splices (@SXC1.Content.Corpus@) is therefore GONE:
-- had it stayed, any future import from @exe:app@ would have silently
-- re-inflated the binary by 193,460 raw bytes, which is precisely the
-- cost this milestone paid to remove.
--
-- The splices live HERE, in @exe:content-check@'s own source directory,
-- because the CHECKER genuinely needs a compile-time copy and its
-- binary is never shipped:
--
--   * @content-check --dump-source \<slug\>@ writes these EXACT embedded
--     bytes, which @scripts\/check-site.sh@ (check 12) diffs against
--     @translations\/\<slug\>.md@ byte for byte. That is the content
--     axis's stale-BUILD detector: it is what proves checks 10\/11 ran
--     against the translations as they are on disk RIGHT NOW, and it
--     only works if the bytes were fixed at compile time. Reading the
--     files at run time would turn that comparison into a file compared
--     with itself.
--   * The SHIPPED path has its own, stronger equivalent: check-site's
--     manual-bundle freshness checks require @manuals.{en,ja}.txt@ to
--     be byte-identical to a fresh emission from @translations\/@, and
--     the wasm-embedded "Bundle.Manifest" fingerprint makes the running
--     app refuse any bundle that is not this build's.
--
-- Paths are relative to the cabal package directory, which is @site\/@
-- (the same convention the splices had in their previous home), and
-- @extra-source-files@ lists @..\/translations\/*.md@ so a translation
-- edit really does force a recompile.
module EmbeddedTranslations
  ( corpusSources
  , glossarySource
  , docs
  , lookupDoc
  ) where

import           Data.Text              (Text)

import           SXC1.Content.Embed     (embedUtf8File)
import           SXC1.Content.Markdown  (mkDoc)
import           SXC1.Content.Types     (Doc (docSlug))

guideBookSrc :: Text
guideBookSrc = $(embedUtf8File "../translations/guide-book.md")

startupGuideSrc :: Text
startupGuideSrc = $(embedUtf8File "../translations/startup-guide.md")

midiSrc :: Text
midiSrc = $(embedUtf8File "../translations/midi.md")

ossSrc :: Text
ossSrc = $(embedUtf8File "../translations/oss.md")

-- | (slug, raw markdown), in the reader's fixed presentation order --
-- the SAME order @scripts\/emit-content-bundles.py@'s @MANUAL_SLUGS@
-- emits @!SXC1-DOC@ records in, which is what lets this checker's
-- numbers and the shipped bundle's be compared position by position.
corpusSources :: [(Text, Text)]
corpusSources =
  [ ("guide-book",    guideBookSrc)
  , ("startup-guide", startupGuideSrc)
  , ("midi",          midiSrc)
  , ("oss",           ossSrc)
  ]

glossarySource :: Text
glossarySource = $(embedUtf8File "../translations/glossary.md")

-- | The parsed corpus, in 'corpusSources' order. LAZY: constructing this
-- list, and each 'Doc' in it, never forces a page's block parse -- see
-- the laziness contract in "SXC1.Content.Types".
docs :: [Doc]
docs = [ mkDoc slug src | (slug, src) <- corpusSources ]

lookupDoc :: Text -> Maybe Doc
lookupDoc slug = go docs
  where
    go []       = Nothing
    go (d : ds) = if docSlug d == slug then Just d else go ds
