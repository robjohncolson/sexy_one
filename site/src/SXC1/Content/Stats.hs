{-# LANGUAGE OverloadedStrings #-}

-- | The stats record and its hand-rolled JSON encoder (no aeson -- the
-- library must stay miso-free and dependency-minimal, and the browser
-- side only ever needs @JSON.parse@ on the result).
--
-- Every field here is computed from RAW TEXT (via "SXC1.Content.Markdown"
-- and "SXC1.Content.Outline"'s cheap, line-level scanning helpers), never
-- by forcing 'SXC1.Content.Types.pageBlocks' -- with ONE deliberate
-- exception, 'stUnparsed', which is cheap-and-approximate here
-- ('buildDocStats'\/'buildStats', what the app uses) but can be
-- recomputed from the real parsed model by 'buildDocStatsFromDoc'\/
-- 'buildStatsFromDocs' (what exe:content-check's producer uses instead --
-- see the Haddock on those two below, and A1's laziness note). This is
-- what lets @#sxc1-content-stats@ render on every route without ever
-- block-parsing the whole corpus -- see the laziness contract in
-- "SXC1.Content.Types".
--
-- A note on the @tables@ field: the golden numbers (measured in
-- @briefs\/M1-plan.md@ \167 3) label it \"tables (separator rows)\" and were
-- measured by counting every line shaped like a pipe-table separator row,
-- INCLUDING an all-blank cell row such as @| | |@ (midi's and
-- startup-guide's blank table headers, which are syntactically their own
-- separator-shaped line even though semantically they are the header of
-- the very next real table, not a table of their own). Reproducing that
-- measurement is what 'countLooseTableLines' does; it is a direct
-- raw-text count, not @length of Table blocks@, precisely so that the
-- real parser can still treat a blank header row as part of ONE table
-- (satisfying \"every Table has at least one body row\") while the stats
-- field matches the measured golden metric. exe:content-check's separate
-- MODEL CENSUS (a content-check-only concern, not part of this JSON
-- schema) checks that the real @Table@-block count coincides with this
-- field exactly -- see @test\/CheckContent.hs@.
module SXC1.Content.Stats
  ( DocStats (..)
  , buildDocStats
  , buildStats
  , buildDocStatsFromDoc
  , buildStatsFromDocs
  , countUnparsedInDoc
  , statsJson
  , renderStatsJson
  ) where

import           Data.Maybe            (fromMaybe)
import           Data.Text             (Text)
import qualified Data.Text             as T

import           SXC1.Content.Markdown
import           SXC1.Content.Outline
import           SXC1.Content.Types    (Block (..), Doc (..), ListItem (liChildren), Page (pageBlocks))

data DocStats = DocStats
  { stSlug        :: !Text
  , stTitle       :: !Text
  , stChars       :: !Int
  , stLines       :: !Int
  , stPages       :: !Int
  , stHeadings    :: !Int
  , stFigures     :: !Int
  , stTables      :: !Int
  , stSections    :: !Int
  , stSubsections :: !Int
  , stParts       :: !Int
  , stUnparsed    :: !Int
  , stPartTitles  :: [Text]
  } deriving (Eq, Show)

-- | Build the stats for one document from its (slug, raw markdown) pair.
buildDocStats :: Text -> Text -> DocStats
buildDocStats slug raw = DocStats
  { stSlug        = slug
  , stTitle       = extractDocTitle raw
  , stChars       = T.length raw
    -- Deliberately 'T.splitOn "\n"', not 'T.lines': the golden number was
    -- measured as Python's @len(text.split(chr(10)))@, which -- unlike
    -- 'T.lines' -- counts the trailing empty segment produced by each
    -- file's trailing newline. This keeps the two independent
    -- implementations (see check-site.sh) agreeing exactly.
  , stLines       = length (T.splitOn "\n" raw)
  , stPages       = pageCountOf raw
  , stHeadings    = countHeadingLines raw
  , stFigures     = countPlaceholderOccurrences raw
  , stTables      = countLooseTableLines raw
  , stSections    = length (outSections outline)
  , stSubsections = sum (map (length . secSubs) (outSections outline))
  , stParts       = length (outPartTitles outline)
    -- CORRECTED (A1, round 3): this used to be the LITERAL @0@, on the
    -- (accurate, but incompletely acted-on) theory that 'Unparsed' is
    -- unreachable for real corpus text -- the paragraph rule is a total
    -- fallback for any non-blank line not otherwise claimed (4.5's
    -- fallback note), so it always was, and still is, true that this
    -- field is 0 for the actual corpus. What was FALSE is the old
    -- comment's second half: it claimed exe:content-check
    -- "independently confirms this by forcing the real parser ... and
    -- asserting zero Unparsed blocks -- that is the actual gate", but
    -- the parser's final branch never called the 'Unparsed' constructor
    -- at all, so there was no real parse for that assertion to be
    -- checking -- every gate built on it was structurally incapable of
    -- ever going red. 'SXC1.Content.Markdown.parseBlocksEngine' now
    -- really does construct 'SXC1.Content.Types.Unparsed' (provably
    -- reachable via 'SXC1.Content.Markdown.parseBlocksEngineWith''s test
    -- seam; see its Haddock), so the guarantee this field can state is
    -- now real, just weaker than the old comment implied: this is the
    -- CHEAP, raw-text approximation ('countUnparsedRawApprox' -- flat,
    -- non-recursive, never strips a blockquote marker or tracks list
    -- indentation), used here and only here so the browser's
    -- @#sxc1-content-stats@ can render on every route without forcing a
    -- single 'SXC1.Content.Types.pageBlocks' thunk (the 4.4 laziness
    -- contract). It can only ever read 0 for real content, by the same
    -- "paragraph is a total catch-all" argument as always. The
    -- AUTHORITATIVE, model-derived count -- computed by actually forcing
    -- the parsed 'SXC1.Content.Types.Doc' and counting real 'Unparsed'
    -- blocks, which CAN in principle go non-zero if this grammar ever
    -- stops being a total catch-all -- is 'buildDocStatsFromDoc' below,
    -- which ONLY exe:content-check's producer calls (a one-shot batch
    -- validator, not the boot path, so forcing every page's blocks there
    -- is fine). That is what makes the three-way agreement
    -- (@content-check --json@ vs the DOM) able to actually catch a real
    -- 'Unparsed' occurrence, and what exe:content-check's own zero-
    -- Unparsed corpus check (group 3, over the real parsed model
    -- directly) is finally a meaningful assertion of, instead of a
    -- comparison the producer could never make fail.
  , stUnparsed    = countUnparsedRawApprox raw
  , stPartTitles  = outPartTitles outline
  }
  where
    outline = buildOutline raw

extractDocTitle :: Text -> Text
extractDocTitle raw = fst (extractTitleAndRest (preambleLinesOf raw))

-- | The APP's stats: every field, including 'stUnparsed', computed
-- cheaply from raw text (see 'buildDocStats'). This is what
-- "SXC1.Content.Corpus" / @app\/View\/Pages.hs@ use, and is exactly what
-- must keep the 4.4 laziness contract -- it never forces a single
-- 'SXC1.Content.Types.pageBlocks' thunk.
buildStats :: [(Text, Text)] -> [DocStats]
buildStats = map (uncurry buildDocStats)

-- | Recompute one document's stats with the AUTHORITATIVE, model-derived
-- 'stUnparsed' -- every other field is left exactly as
-- 'buildDocStats' (cheap raw text) computed it, since those fields are
-- inherently raw-text metrics by design (see the module Haddock) and are
-- not part of A1's laziness trade-off. Forcing @d@'s pages here is
-- intentional and safe: the only caller is exe:content-check, a one-shot
-- batch validator that already forces the whole parsed corpus for its
-- other checks, never the browser boot path (see "SXC1.Content.Types"
-- 4.4).
buildDocStatsFromDoc :: Doc -> Text -> DocStats
buildDocStatsFromDoc d raw = (buildDocStats (docSlug d) raw) { stUnparsed = countUnparsedInDoc d }

-- | 'buildDocStatsFromDoc' over a whole corpus: @docs@ (the parsed
-- models) paired up with @sources@ (slug -> raw text) by slug. Used only
-- by exe:content-check's @--json@ producer and its own golden checks --
-- see @test\/CheckContent.hs@.
buildStatsFromDocs :: [Doc] -> [(Text, Text)] -> [DocStats]
buildStatsFromDocs docsIn sources =
  [ buildDocStatsFromDoc d (fromMaybe "" (lookup (docSlug d) sources)) | d <- docsIn ]

-- | The real, model-derived 'Unparsed' count for one document: forces
-- 'SXC1.Content.Types.docPreamble' and every page's
-- 'SXC1.Content.Types.pageBlocks', recursing into 'Quote' bodies and
-- list-item children (the same places a nested 'SXC1.Content.Types.Heading'
-- can hide -- see "SXC1.Content.Markdown"'s nested-heading note), and
-- counts genuine 'SXC1.Content.Types.Unparsed' blocks.
countUnparsedInDoc :: Doc -> Int
countUnparsedInDoc d =
  countIn (docPreamble d) + sum [ countIn (pageBlocks p) | p <- docPages d ]
  where
    countIn :: [Block] -> Int
    countIn = sum . map oneBlock
    oneBlock b = case b of
      Unparsed _      -> 1
      Quote inner     -> countIn inner
      Bullets items    -> sum (map (countIn . liChildren) items)
      Numbered _ items  -> sum (map (countIn . liChildren) items)
      _                    -> 0

--------------------------------------------------------------------------
-- JSON encoding (hand-rolled; exact key names per the DOM contract)
--------------------------------------------------------------------------

jsonEscape :: Text -> Text
jsonEscape = T.concatMap esc
  where
    esc '"'  = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\r' = "\\r"
    esc '\t' = "\\t"
    esc c    = T.singleton c

jsonStr :: Text -> Text
jsonStr t = "\"" <> jsonEscape t <> "\""

jsonArr :: [Text] -> Text
jsonArr xs = "[" <> T.intercalate "," xs <> "]"

jsonInt :: Int -> Text
jsonInt = T.pack . show

kv :: Text -> Text -> Text
kv k v = jsonStr k <> ":" <> v

docJson :: DocStats -> Text
docJson d =
  "{" <> T.intercalate ","
    [ kv "slug"        (jsonStr (stSlug d))
    , kv "title"       (jsonStr (stTitle d))
    , kv "chars"       (jsonInt (stChars d))
    , kv "lines"       (jsonInt (stLines d))
    , kv "pages"       (jsonInt (stPages d))
    , kv "headings"    (jsonInt (stHeadings d))
    , kv "figures"     (jsonInt (stFigures d))
    , kv "tables"      (jsonInt (stTables d))
    , kv "sections"    (jsonInt (stSections d))
    , kv "subsections" (jsonInt (stSubsections d))
    , kv "parts"       (jsonInt (stParts d))
    , kv "unparsed"    (jsonInt (stUnparsed d))
    , kv "partTitles"  (jsonArr (map jsonStr (stPartTitles d)))
    ] <> "}"

statsJson :: [DocStats] -> Text
statsJson ds = "{" <> kv "docs" (jsonArr (map docJson ds)) <> "}"

-- | The full stats JSON for a corpus, as used by
-- @#sxc1-content-stats@\/@content-check --json@.
renderStatsJson :: [(Text, Text)] -> Text
renderStatsJson = statsJson . buildStats
