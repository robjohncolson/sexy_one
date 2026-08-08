-- | Content model for the SXC-1 Trainer manual reader.
--
-- This module is deliberately inert: it defines the shape of a parsed
-- document and nothing else. See "SXC1.Content.Markdown" for how values of
-- these types are produced, and "Bundle" (@site\/app@) for where the raw
-- text they are built from comes from: since M7 W1 the manual text is
-- FETCHED at boot as a per-language bundle, never embedded in the wasm.
--
-- LAZINESS CONTRACT: 'pageBlocks' must remain a thunk. A document is split
-- into pages by one linear pass over its embedded text; the block parser
-- for a given page only runs when that page's 'pageBlocks' is forced (i.e.
-- when the page is actually viewed). Do not add strictness annotations to
-- 'pageBlocks' and do not force it eagerly anywhere in this library.
module SXC1.Content.Types
  ( Doc (..)
  , Page (..)
  , Block (..)
  , ListItem (..)
  , Inline (..)
  ) where

import Data.Text (Text)

-- | One translated manual.
data Doc = Doc
  { docSlug     :: !Text          -- ^ e.g. @"guide-book"@
  , docTitle    :: !Text          -- ^ from the @# @ line before @\<!-- page 1 --\>@
  , docPreamble :: [Block]        -- ^ the translator's-note blockquote
  , docPages    :: [Page]         -- ^ lazily parsed, in order, 1..N
  } deriving (Eq, Show)

-- | One page of a document, delimited by @\<!-- page N --\>@ markers.
data Page = Page
  { pageNumber :: !Int
  , pageHeader :: Maybe Text      -- ^ running header, verbatim, without the @*@s
  , pageBlocks :: [Block]         -- ^ LAZY: forced only when the page is viewed
  } deriving (Eq, Show)

-- | Block-level content.
data Block
  = Heading  !Int [Inline] !Text          -- ^ level, inlines, unique anchor slug
  | Para     [Inline]
  | Figure   !Text [Inline]               -- ^ kind (\"Figure\"\/\"QR code\"\/...), caption
  | Bullets  [ListItem]
  | Numbered !Int [ListItem]              -- ^ literal start number
  | Quote    [Block]
  | Table    (Maybe [[Inline]]) [[[Inline]]]  -- ^ header row (Nothing if blank), body
  | Unparsed !Text                        -- ^ MUST never occur; see the parser's fallback rule
  deriving (Eq, Show)

-- | One item of a bulleted or numbered list.
data ListItem = ListItem
  { liContent  :: [Inline]
  , liChildren :: [Block]
  } deriving (Eq, Show)

-- | Inline (span-level) content.
data Inline
  = Str         !Text
  | Strong      [Inline]
  | Em          [Inline]
  | Code        !Text                     -- ^ @`...`@
  | Break                                 -- ^ @\<br\>@
  | Placeholder !Text !Text               -- ^ kind, full text of @*[...]*@
  | PageRef     !Int !Text                -- ^ cross-reference, display text
  deriving (Eq, Show)
