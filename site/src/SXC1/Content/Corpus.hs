{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | The splice site: embeds all four manual translations plus the
-- glossary at compile time (see "SXC1.Content.Embed"), and builds the
-- parsed, lazy 'Doc' corpus from them.
--
-- Paths are relative to the cabal package directory, which is @site\/@.
module SXC1.Content.Corpus
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

-- | (slug, raw markdown), in this fixed order.
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
