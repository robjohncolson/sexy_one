{-# LANGUAGE OverloadedStrings #-}

-- | The stats record and its hand-rolled JSON encoder (no aeson -- the
-- library must stay miso-free and dependency-minimal, and the browser
-- side only ever needs @JSON.parse@ on the result).
--
-- Every field here is computed from RAW TEXT (via "SXC1.Content.Markdown"
-- and "SXC1.Content.Outline"'s cheap, line-level scanning helpers), never
-- by forcing 'SXC1.Content.Types.pageBlocks'. This is what lets
-- @#sxc1-content-stats@ render on every route without ever block-parsing
-- the whole corpus -- see the laziness contract in "SXC1.Content.Types".
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
-- field matches the measured golden metric.
module SXC1.Content.Stats
  ( DocStats (..)
  , buildDocStats
  , buildStats
  , statsJson
  , renderStatsJson
  ) where

import           Data.Text             (Text)
import qualified Data.Text             as T

import           SXC1.Content.Markdown
import           SXC1.Content.Outline

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
    -- 'Unparsed' is provably unreachable in this grammar: the paragraph
    -- rule is a total fallback for any non-blank line not otherwise
    -- claimed (see 4.5's fallback note), so no line-level scan can ever
    -- observe one. exe:content-check independently confirms this by
    -- forcing the real parser over the whole corpus and asserting zero
    -- 'SXC1.Content.Types.Unparsed' blocks -- that is the actual gate.
  , stUnparsed    = 0
  , stPartTitles  = outPartTitles outline
  }
  where
    outline = buildOutline raw

extractDocTitle :: Text -> Text
extractDocTitle raw = fst (extractTitleAndRest (preambleLinesOf raw))

buildStats :: [(Text, Text)] -> [DocStats]
buildStats = map (uncurry buildDocStats)

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
