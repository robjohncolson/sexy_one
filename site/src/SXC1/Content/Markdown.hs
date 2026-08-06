{-# LANGUAGE OverloadedStrings #-}

-- | The content parser: a line-oriented, indentation-aware parser for the
-- SXC-1 manual translations specifically (see @briefs\/M1-plan.md@ 4.5-4.7).
-- It is deliberately NOT a general CommonMark implementation.
--
-- This module also exposes a handful of cheap, text-level scanning helpers
-- (page splitting, running-header extraction, top-level heading lines,
-- placeholder/table counting) that "SXC1.Content.Outline" and
-- "SXC1.Content.Stats" reuse so that computing the outline and the stats
-- blob never forces full block parsing of the corpus -- see the laziness
-- contract on 'SXC1.Content.Types.pageBlocks'.
module SXC1.Content.Markdown
  ( -- * Building a document
    mkDoc
    -- * Cheap, text-level scanning (no block parsing)
  , splitPageTexts
  , pageCountOf
  , headingLineOf
  , extractRunningHeader
  , preambleLinesOf
  , extractTitleAndRest
  , countHeadingLines
  , countPlaceholderOccurrences
  , countLooseTableLines
  , countStrictTableSeparators
  , countUnparsedRawApprox
  , orderedItemOf
  , bulletItemOf
    -- * Slugs
  , slugify
  , dedupeSlugs
    -- * Inline parsing (exposed for reuse/testing)
  , parseInline
    -- * The block-parsing engine and its test seam (A1; see the "Block
    -- grammar" section below for the full account)
  , LineShape (..)
  , classifyLine
  , parseBlocksEngine
  , parseBlocksEngineWith
  ) where

import           Data.Char             (isAlphaNum)
import qualified Data.Map.Strict       as Map
import           Data.Maybe            (fromMaybe, mapMaybe)
import qualified Data.Set              as Set
import           Data.Text             (Text)
import qualified Data.Text             as T

import           SXC1.Content.Types

--------------------------------------------------------------------------
-- Doc construction
--------------------------------------------------------------------------

-- | Parse one document from its raw embedded markdown text.
--
-- Splitting into pages and locating the anchor-slug supply is one cheap
-- linear pass over the whole document (line-level only). Each page's
-- 'pageBlocks' is left as an ordinary (unforced) thunk closing over that
-- pass's results, so viewing page /k/ only ever runs the block/inline
-- parser over page /k/'s own text.
mkDoc :: Text -> Text -> Doc
mkDoc slug raw =
  let pages0        = splitPageTexts raw
      pageCount      = length pages0
      (title, preRest) = extractTitleAndRest (preambleLinesOf raw)
      preambleBlocks = fst (parseBlocksEngine pageCount False [] preRest)
      perPageHeads   = [ (n, mapMaybe headingLineOf ls) | (n, ls) <- pages0 ]
      flatHeads      = concatMap snd perPageHeads
      dedupedSlugs   = dedupeSlugs (map (slugify . snd) flatHeads)
      slugsByPage    = regroup (map (length . snd) perPageHeads) dedupedSlugs
      pages          = [ mkPage pageCount n ls slugs
                        | ((n, ls), slugs) <- zip pages0 slugsByPage ]
  in Doc { docSlug = slug, docTitle = title, docPreamble = preambleBlocks, docPages = pages }

mkPage :: Int -> Int -> [Text] -> [Text] -> Page
mkPage pageCount n rawLines slugs =
  let (header, contentLines) = extractRunningHeader rawLines
  in Page
       { pageNumber = n
       , pageHeader = header
       , pageBlocks = fst (parseBlocksEngine pageCount True slugs contentLines)
       }

regroup :: [Int] -> [a] -> [[a]]
regroup []     _  = []
regroup (n:ns) xs = let (h, t) = splitAt n xs in h : regroup ns t

--------------------------------------------------------------------------
-- Page splitting (cheap; text-level)
--------------------------------------------------------------------------

-- | Split the raw document text on @\<!-- page N --\>@ markers, returning
-- each page's number and its own raw lines (marker lines removed). This
-- never inspects anything but line shape, so it is safe to run eagerly.
splitPageTexts :: Text -> [(Int, [Text])]
splitPageTexts raw = go markers
  where
    allLines = T.lines raw
    n        = length allLines
    markers  = [ (i, num) | (i, l) <- zip [0 ..] allLines, Just num <- [pageMarkerNum l] ]

    go []              = []
    go [(i, num)]      = [(num, slice i n)]
    go ((i, num) : rest@((j, _) : _)) = (num, slice i j) : go rest

    slice i j = take (j - i - 1) (drop (i + 1) allLines)

pageCountOf :: Text -> Int
pageCountOf = length . splitPageTexts

pageMarkerNum :: Text -> Maybe Int
pageMarkerNum line = do
  rest1 <- T.stripPrefix "<!-- page " (T.strip line)
  let (digs, rest2) = T.span isDigitChar rest1
  if T.null digs
    then Nothing
    else do
      rest3 <- T.stripPrefix " -->" rest2
      if T.null (T.strip rest3) then Just (digitsToInt digs) else Nothing

--------------------------------------------------------------------------
-- Preamble / title (cheap; text-level)
--------------------------------------------------------------------------

-- | Every line of the document up to (not including) the first page
-- marker.
preambleLinesOf :: Text -> [Text]
preambleLinesOf raw = takeWhile (not . isPageMarkerLine) (T.lines raw)
  where
    isPageMarkerLine l = case pageMarkerNum l of
      Just _  -> True
      Nothing -> False

-- | Pull the document title (the first level-1 heading) out of the
-- preamble, returning the title text and the remaining preamble lines in
-- their original order (the translator's-note blockquote, typically).
extractTitleAndRest :: [Text] -> (Text, [Text])
extractTitleAndRest = go []
  where
    go acc [] = ("", reverse acc)
    go acc (l : ls) = case headingLineOf l of
      Just (1, txt) -> (txt, reverse acc ++ ls)
      _             -> go (l : acc) ls

--------------------------------------------------------------------------
-- Heading lines
--------------------------------------------------------------------------

-- | Match @^(#{1,6}) +(\\S.*)$@. Because this requires the line to begin
-- with @#@, it never matches a line still carrying a @>@ blockquote
-- marker or leading indentation. The cheap text-level scanners in this
-- module ('mkDoc'\'s per-page anchor supply, 'countHeadingLines',
-- "SXC1.Content.Outline"\'s heading scan) all apply this to raw,
-- unstripped lines, so for them it really is top-level-only. The block
-- parser ('parseBlocksEngine') strips a blockquote's @>@ marker before
-- recursing, so the very same predicate also recognises a de-quoted
-- @### ...@ line as a heading -- which is exactly what fixes the
-- \"Tip\" callouts' nested headings without changing this function.
headingLineOf :: Text -> Maybe (Int, Text)
headingLineOf line
  | n >= 1, n <= 6, not (T.null rest), T.head rest == ' ', not (T.null txt) = Just (n, txt)
  | otherwise = Nothing
  where
    (hashes, rest) = T.span (== '#') line
    n               = T.length hashes
    txt             = T.strip rest

countHeadingLines :: Text -> Int
countHeadingLines raw = length (mapMaybe headingLineOf (T.lines raw))

--------------------------------------------------------------------------
-- Running header extraction
--------------------------------------------------------------------------

-- | A page's running header is a whole-line-italic line (@*...*@, not a
-- placeholder) among the first two non-blank lines of the page. It is
-- consumed (removed from the returned lines), not a block.
extractRunningHeader :: [Text] -> (Maybe Text, [Text])
extractRunningHeader ls =
  case candidate of
    Nothing      -> (Nothing, ls)
    Just (i, h)  -> (Just h, [ l | (j, l) <- zip [(0 :: Int) ..] ls, j /= i ])
  where
    nonBlankIdx = take 2 [ i | (i, l) <- zip [(0 :: Int) ..] ls, not (isBlankLine l) ]
    candidate =
      listToMaybe' [ (i, h) | i <- nonBlankIdx, Just h <- [italicWholeLine (T.strip (ls !! i))] ]
    listToMaybe' (x : _) = Just x
    listToMaybe' []      = Nothing

-- | @^\*([^*].*[^*])\*$@, excluding the @*[...]*@ placeholder shape.
italicWholeLine :: Text -> Maybe Text
italicWholeLine s
  | T.length s < 2                      = Nothing
  | T.head s /= '*' || T.last s /= '*'   = Nothing
  | T.null inner                         = Nothing
  | T.head inner == '*' || T.last inner == '*' = Nothing
  | isPlaceholderShape s                 = Nothing
  | otherwise                            = Just inner
  where
    inner = T.init (T.tail s)

isPlaceholderShape :: Text -> Bool
isPlaceholderShape s = "*[" `T.isPrefixOf` s && "]*" `T.isSuffixOf` s

--------------------------------------------------------------------------
-- Placeholder / table counting (cheap; text-level; used by Stats)
--------------------------------------------------------------------------

-- | Count @*[...]*@ occurrences in raw text, the same way the inline
-- parser would: @**\[...\]**@ (bold wrapping a bracket) is excluded, since
-- @**@ must be matched before @*[@ (see 'parseInline').
countPlaceholderOccurrences :: Text -> Int
countPlaceholderOccurrences = go
  where
    go t =
      let (before, rest) = T.breakOn "*[" t
      in if T.null rest
           then 0
           else
             let afterMarker      = T.drop 2 rest
                 (_inner, closing) = T.breakOn "]*" afterMarker
             in if T.null closing
                  then go (T.drop 2 rest)
                  else
                    let afterClose     = T.drop 2 closing
                        precededByStar = not (T.null before) && T.last before == '*'
                        followedByStar = not (T.null afterClose) && T.head afterClose == '*'
                        isReal         = not precededByStar && not followedByStar
                        continueFrom   = if followedByStar then T.drop 1 afterClose else afterClose
                    in (if isReal then 1 else 0) + go continueFrom

-- | Loose separator-row-shaped line count: @^\s*\|[\s:\|-]+\|\s*$@ with NO
-- requirement that a literal @-@ be present. This intentionally also
-- matches an all-blank cell row like @| | |@ (midi's and startup-guide's
-- blank table header rows) -- see the note on the @tables@ stats field in
-- "SXC1.Content.Stats" for why that is the metric the golden numbers use.
countLooseTableLines :: Text -> Int
countLooseTableLines raw = length (filter isLooseSep (T.lines raw))
  where
    isLooseSep l =
      let s = T.strip l
      in not (T.null s)
           && "|" `T.isPrefixOf` s
           && "|" `T.isSuffixOf` s
           && T.all (`elem` (" :|-" :: String)) s

-- | STRICT separator row count: like 'countLooseTableLines', but ALSO
-- requires at least one literal @-@ -- i.e. exactly 'isTableSeparator'
-- (the block parser's own predicate for the row that splits a table's
-- header from its body), counted at the raw-text level. Unlike
-- 'countLooseTableLines' (what the golden @tables@ metric measures),
-- this does NOT double-count a table whose header row happens to be
-- all-blank (@| | |@, midi's and startup-guide's blank table headers --
-- see 'SXC1.Content.Stats''s note on the @tables@ field): an all-blank
-- row matches the loose shape but never the strict one, so it is not
-- counted here. This is what makes 'countStrictTableSeparators' equal
-- the real, MODEL-DERIVED count of 'SXC1.Content.Types.Table' blocks
-- exactly, for all four corpus documents (verified in
-- @test\/CheckContent.hs@'s NEW2 census, group 15) -- unlike the loose
-- count, which over-counts by exactly one per blank-header table.
countStrictTableSeparators :: Text -> Int
countStrictTableSeparators raw = length (filter isTableSeparator (T.lines raw))

-- | The CHEAP, raw-text approximation of the corpus-wide 'Unparsed' count
-- (A1 / 4.4). It applies the exact same single classifier
-- ('classifyLine', see the \"Block grammar\" section below) to every line
-- of the raw document, flat and top-level only -- it does not strip
-- blockquote markers or track list-item indentation the way the real
-- block parser does, so it is only an approximation, not a re-derivation.
-- It counts lines 'classifyLine' maps to 'DeclinedShape' -- which, for
-- the REAL 'classifyLine' used here, is never (see its Haddock): the
-- paragraph rule is a genuine catch-all in this grammar, so no line-level
-- scan, cheap or not, can ever observe an unparseable line in the actual
-- corpus. That is precisely why this function is safe to run on every
-- route without forcing a single block parse (the laziness contract in
-- "SXC1.Content.Types"): it can only ever return 0 for real content, and
-- exists as a real computation -- not a hard-coded literal -- so that if
-- 'classifyLine' itself ever grows a genuine decline case, this cheap
-- scan tracks it for free. The AUTHORITATIVE count -- the one that can
-- actually go non-zero, because it forces the real parsed model instead
-- of guessing from raw lines -- is computed only by exe:content-check's
-- producer; see 'SXC1.Content.Stats.buildDocStatsFromDoc'.
countUnparsedRawApprox :: Text -> Int
countUnparsedRawApprox raw =
  length (filter ((== DeclinedShape) . classifyLine) (T.lines raw))

--------------------------------------------------------------------------
-- Slugs
--------------------------------------------------------------------------

-- | strip inline markers -> lowercase -> replace runs of non-alphanumeric
-- with @-@ -> trim @-@ -> empty becomes @"section"@. 'isAlphaNum' is
-- Unicode-aware, so kana (e.g. the Index's @### \12354 row@) survive.
slugify :: Text -> Text
slugify raw =
  let pieces   = T.split (not . isAlphaNum) (T.toLower raw)
      nonEmpty = filter (not . T.null) pieces
      slug     = T.intercalate "-" nonEmpty
  in if T.null slug then "section" else slug

-- | De-duplicate a list of slugs in order, appending @-2@, @-3@, ... to
-- repeats.
--
-- NEW3: the previous version keyed its suffix counter on the ORIGINAL
-- BASE only and never checked what had actually been emitted, so
-- @["x","x","x-2"]@ produced @["x","x-2","x-2"]@ -- a genuine duplicate,
-- because the third input's own base ("x-2") had never been seen before
-- and so got emitted unchanged, colliding with the suffix the second "x"
-- had already produced. The fix tracks every name actually EMITTED so
-- far (not just a per-base occurrence count) and advances the candidate
-- suffix -- starting from that base's own running counter, so unrelated
-- bases don't all restart at "-2" and collide with each other either --
-- until it lands on a candidate nothing has emitted yet.
dedupeSlugs :: [Text] -> [Text]
dedupeSlugs = go Map.empty Set.empty
  where
    go _ _ [] = []
    go counts emitted (s : rest) =
      let (s', usedCount) = reserve s (Map.findWithDefault (0 :: Int) s counts) emitted
      in s' : go (Map.insert s usedCount counts) (Set.insert s' emitted) rest

    -- | Starting from candidate number @n@ (0 means "the bare base"),
    -- find the first candidate not already in @emitted@, and return it
    -- together with the counter value the base should resume from next
    -- time the same base recurs.
    reserve :: Text -> Int -> Set.Set Text -> (Text, Int)
    reserve base n emitted
      | not (Set.member candidate emitted) = (candidate, n + 1)
      | otherwise                          = reserve base (n + 1) emitted
      where
        candidate = if n == 0 then base else base <> "-" <> T.pack (show (n + 1))

--------------------------------------------------------------------------
-- Block grammar
--------------------------------------------------------------------------

data ListKind = OrderedK | BulletK

isBlankLine :: Text -> Bool
isBlankLine = T.null . T.strip

isTableRowLine :: Text -> Bool
isTableRowLine l = "|" `T.isPrefixOf` T.stripStart l

-- | Strict separator row: @^\s*\|[\s:\|-]+\|\s*$@ AND at least one literal
-- @-@. This is what actually separates a table's header from its body; it
-- deliberately does NOT match an all-blank row like @| | |@, which is
-- instead the table's (blank) header -- see 4.5's note on blank header
-- rows.
isTableSeparator :: Text -> Bool
isTableSeparator l =
  let s = T.strip l
  in not (T.null s)
       && "|" `T.isPrefixOf` s
       && "|" `T.isSuffixOf` s
       && T.all (`elem` (" :|-" :: String)) s
       && T.any (== '-') s

quoteLineContent :: Text -> Maybe Text
quoteLineContent l =
  case T.uncons (T.dropWhile (== ' ') l) of
    Just ('>', rest) -> Just (dropOneSpace rest)
    _                -> Nothing
  where
    dropOneSpace t = case T.uncons t of
      Just (' ', t') -> t'
      _              -> t

indentOf :: Text -> Int
indentOf = T.length . T.takeWhile (== ' ')

-- | @^(\s*)(\d+)[.)]\s+(.*)$@ -> (indent, number, rest).
orderedItemOf :: Text -> Maybe (Int, Int, Text)
orderedItemOf l
  | T.null digs = Nothing
  | otherwise = case T.uncons rest0 of
      Just (c, rest1) | c == '.' || c == ')' -> case T.uncons rest1 of
        Just (' ', rest2) -> Just (ind, digitsToInt digs, T.stripStart rest2)
        _                 -> Nothing
      _ -> Nothing
  where
    ind            = indentOf l
    s              = T.drop ind l
    (digs, rest0)  = T.span isDigitChar s

-- | @^(\s*)[-*+]\s+(.*)$@ -> (indent, rest).
bulletItemOf :: Text -> Maybe (Int, Text)
bulletItemOf l = case T.uncons s of
  Just (c, rest) | c `elem` ("-*+" :: String) -> case T.uncons rest of
    Just (' ', rest2) -> Just (ind, T.stripStart rest2)
    _                 -> Nothing
  _ -> Nothing
  where
    ind = indentOf l
    s   = T.drop ind l

isDigitChar :: Char -> Bool
isDigitChar c = c >= '0' && c <= '9'

digitsToInt :: Text -> Int
digitsToInt = T.foldl' (\acc c -> acc * 10 + (fromEnum c - fromEnum '0')) 0

-- | The seven ways 'classifyLine' can name a raw line: the six block
-- rules of 4.5's guard chain, \"paragraph-eligible\" (matches none of
-- them), and 'DeclinedShape' -- see 'classifyLine' immediately below for
-- why an eighth constructor exists that the real classifier never
-- produces.
data LineShape
  = BlankShape
  | HeadingShape
  | TableRowShape
  | QuoteShape
  | OrderedShape
  | BulletShape
  | ParaShape
  | DeclinedShape
  deriving (Eq, Show)

-- | THE single classifier (A1 1b): the ONE place that decides which of
-- 4.5's six block rules (or none of them, i.e. \"paragraph-eligible\")
-- a raw line matches. 'parseBlocksEngine' derives BOTH its guard-chain
-- dispatch AND its paragraph/'Unparsed' span boundary from this one
-- function -- literally the same function call on the same line in both
-- places -- so the two can no longer independently drift apart the way
-- Codex's and the Opus reviewer's \"one-sided classifier edit\" (a block
-- rule added to one side and not the other) demonstrated pre-round-3: see
-- NEGATIVE CONTROL 1 in the round-3 report for what reintroducing two
-- hand-written copies costs.
--
-- 'DeclinedShape' is never produced by THIS function -- every real line
-- is exactly one of the first seven shapes, and 'ParaShape' is a genuine
-- catch-all in this grammar (see 4.5's fallback note), so no corpus line
-- can ever reach it. It exists purely as a TEST SEAM: 'parseBlocksEngine'
-- is a specialisation of 'parseBlocksEngineWith', which takes the
-- classifier as an explicit argument, production always supplying
-- 'classifyLine' unchanged. A test can supply a variant classifier that
-- returns 'DeclinedShape' for one specific line -- \"a line the
-- classifier declines\" -- which is the only way to make the 'Unparsed'
-- fallback REACHABLE at all in this grammar; see A1's fixture in
-- @test\/CheckContent.hs@.
classifyLine :: Text -> LineShape
classifyLine l
  | isBlankLine l                 = BlankShape
  | isJustT (headingLineOf l)     = HeadingShape
  | isTableRowLine l              = TableRowShape
  | isJustT (quoteLineContent l)  = QuoteShape
  | isJustT (orderedItemOf l)     = OrderedShape
  | isJustT (bulletItemOf l)      = BulletShape
  | otherwise                     = ParaShape

-- | The shared block-parsing engine, specialised to production's real
-- classifier. See 'parseBlocksEngineWith' for the full account -- this is
-- just @'parseBlocksEngineWith' 'classifyLine'@.
--
-- Heading lines (4.5's heading rule) are recognised everywhere -- at a
-- page's top level AND inside blockquote content and list-item children,
-- per 4.5's blockquote\/list rules (\"recursively parse the remainder as
-- blocks\", which includes headings). What is NOT shared is the
-- anchor-slug supply: @consumesSlugs@ is true only for a page's top-level
-- pass, so only top-level headings pop from it (see 'mkDoc'). A nested
-- heading (inside a 'Quote' or a list item's children) gets the empty
-- anchor @\"\"@ instead -- it is not an outline target and must not
-- perturb the slugs later top-level headings on the same page are waiting
-- to consume.
--
-- Earlier, headings were recognised only when @consumesSlugs@ was true,
-- on the theory that this was needed to keep the golden @headings@ count
-- exact. That theory was wrong: the golden count comes from
-- 'countHeadingLines', which scans raw @^#{1,6} ...@ lines and already
-- excludes any @> ###@ line because it does not begin with @#@. Gating
-- heading recognition on @consumesSlugs@ bought nothing and cost
-- rendering fidelity -- a handful of \"Tip\" callouts' @### ...@ lines
-- were falling through to the paragraph rule and rendering as literal
-- hash marks (briefs/M1-fixes-manifest.json, task \"nested-headings\").
--
-- The @[Text]@ threaded alongside the blocks is the page's pre-computed
-- anchor-slug supply (see 'mkDoc'); each top-level 'Heading' consumes one.
parseBlocksEngine :: Int -> Bool -> [Text] -> [Text] -> ([Block], [Text])
parseBlocksEngine = parseBlocksEngineWith classifyLine

-- | 'parseBlocksEngine', generalised over the line classifier (A1 1c's
-- test seam). Production only ever calls this via 'parseBlocksEngine'
-- (i.e. with 'classifyLine'); a test can pass a different classifier to
-- construct a genuinely unclassifiable line and observe both that
-- 'Unparsed' is produced AND that the engine terminates -- see
-- @test\/CheckContent.hs@'s A1 fixture.
--
-- STRUCTURAL PROGRESS (A1 1a; widened by NEW11): every branch below that
-- groups a run of lines with 'span' consumes the CURRENT line @l@
-- unconditionally before ever re-checking anything -- 'span' is only
-- ever applied to @(l : ls)@, and each of the four 'span'-based shapes'
-- own grouping predicate is true of @l@ by construction (that is what
-- selected this case alternative). Only the final, catch-all arm can
-- fail to consume @l@ -- when @classify l@ is 'ParaShape' but a later
-- line breaks the run, @l@ is still consumed; the ONLY way 'span' can
-- consume nothing is @classify l@ being something the arm's own
-- predicate (@classify x == 'ParaShape'@) rejects, i.e. 'DeclinedShape'
-- (or, for a dishonest classifier, a shape whose own specific predicate
-- does not actually hold on re-check, e.g. a claimed 'HeadingShape' that
-- 'headingLineOf' disagrees with). In THAT case the branch below
-- unconditionally emits 'Unparsed' for just @l@ and recurses on @ls@ --
-- never on the untouched @(l : ls)@.
--
-- 'OrderedShape' and 'BulletShape' do NOT use 'span' -- they hand @(l :
-- ls)@ to 'parseList', which decides for itself how much of the input a
-- list item claims. Production's 'classifyLine' guarantees 'OrderedShape'
-- only when @'orderedItemOf' l@ already succeeds ('BulletShape' /
-- 'bulletItemOf' likewise), so 'parseList' always collects at least
-- @l@ itself as its first item and 'parseList''s own @remaining@ is
-- always a strict suffix of @ls@ (never the untouched @l : ls@) for any
-- real corpus line. NEW11: a dishonest test classifier can claim
-- 'OrderedShape'\/'BulletShape' for a line its own matcher rejects --
-- @'parseBlocksEngineWith' (const 'OrderedShape') 1 False []
-- [\"ordinary text\"]@ is exactly this, and it used to loop forever,
-- because 'parseList' then collects ZERO items and returns the
-- untouched @(l : ls)@ as its remaining, and @go@ recursed on that
-- identical list under the very same dishonest classifier -- a real,
-- reproduced (not theoretical) non-terminating case, contradicting this
-- Haddock's own claim. The fix is the same progress check as the
-- catch-all arm's, applied to 'parseList''s result: 'blockHasNoItems'
-- below is 'True' exactly when 'parseList' collected nothing (which, by
-- the guarantee above, cannot happen for the real classifier), and in
-- that case the 'OrderedShape'\/'BulletShape' branches also fall back to
-- emitting 'Unparsed' for just @l@ and recursing on @ls@ -- never on
-- 'parseList''s own @remaining@, which would just be @l : ls@ again.
-- With this, EVERY branch below either structurally shrinks its input by
-- at least one line or explicitly falls back to the same
-- shrink-by-emitting-'Unparsed' rule, so termination now genuinely holds
-- for every finite input regardless of how @classify@ behaves -- true,
-- not merely claimed. This is what turns Codex's \">10 minute hang\"
-- reproduction (and NEW11's P-L reproduction, a 60-second timeout on the
-- @(const OrderedShape)@ probe) into a red-but-terminating 'Unparsed'
-- report instead.
parseBlocksEngineWith :: (Text -> LineShape) -> Int -> Bool -> [Text] -> [Text] -> ([Block], [Text])
parseBlocksEngineWith classify pageCount consumesSlugs = go
  where
    go slugs [] = ([], slugs)
    go slugs (l : ls) = case classify l of
      BlankShape -> go slugs ls

      HeadingShape
        | Just (lvl, htext) <- headingLineOf l ->
            let (slug, slugsRest)
                  | consumesSlugs = popSlug slugs
                  | otherwise     = ("", slugs)
                (restBlocks, slugsFinal) = go slugsRest ls
            in (Heading lvl (parseInline pageCount htext) slug : restBlocks, slugsFinal)
        -- A dishonest classifier claimed HeadingShape for a line
        -- 'headingLineOf' does not actually recognise. 'classifyLine'
        -- itself can never do this (its HeadingShape case IS
        -- @isJustT . headingLineOf@); reachable only via
        -- 'parseBlocksEngineWith''s test seam.
        | otherwise -> emitUnparsed slugs l ls

      TableRowShape ->
          let (rows, ls')             = span ((== TableRowShape) . classify) (l : ls)
              (restBlocks, slugsFinal) = go slugs ls'
          in (parseTable pageCount rows : restBlocks, slugsFinal)

      QuoteShape ->
          let (qraw, ls')              = span ((== QuoteShape) . classify) (l : ls)
              qcontents                 = map (fromMaybe "" . quoteLineContent) qraw
              -- Nested headings inside a blockquote recurse with
              -- consumesSlugs=False and an empty supply, so they get the
              -- empty anchor "" and never touch the top-level anchor-slug
              -- supply that later top-level headings on this page are
              -- waiting to consume (see the Haddock above
              -- 'parseBlocksEngine' and A6's fixture in
              -- @test\/CheckContent.hs@, group 19).
              (inner, _quoteSlugs)     = parseBlocksEngine pageCount False [] qcontents
              (restBlocks, slugsFinal)  = go slugs ls'
          in (Quote inner : restBlocks, slugsFinal)

      -- NEW11: 'parseList' is trusted to make progress only because
      -- 'classify l' being 'OrderedShape'/'BulletShape' is SUPPOSED to
      -- guarantee @'orderedItemOf' l@/@'bulletItemOf' l@ already succeeds
      -- (true of the real 'classifyLine', by its own definition). A
      -- dishonest test classifier can break that guarantee; 'blockHasNoItems'
      -- below is the progress check that catches it -- see this
      -- function's Haddock.
      OrderedShape ->
          let (blk, ls') = parseList pageCount OrderedK (l : ls)
          in if blockHasNoItems blk
               then emitUnparsed slugs l ls
               else
                 let (restBlocks, slugsFinal) = go slugs ls'
                 in (blk : restBlocks, slugsFinal)

      BulletShape ->
          let (blk, ls') = parseList pageCount BulletK (l : ls)
          in if blockHasNoItems blk
               then emitUnparsed slugs l ls
               else
                 let (restBlocks, slugsFinal) = go slugs ls'
                 in (blk : restBlocks, slugsFinal)

      -- ParaShape (the normal case) or DeclinedShape (only ever supplied
      -- by a test classifier). The span predicate below is intentionally
      -- @classify x == ParaShape@, NOT "not one of the other six" -- so
      -- when @classify l@ is 'DeclinedShape', 'span' rejects @l@ itself
      -- and consumes nothing, taking the 'Unparsed' branch (see this
      -- function's Haddock for why that is the ONLY way to reach it).
      _ ->
          let (paraLines, ls') = span ((== ParaShape) . classify) (l : ls)
          in case paraLines of
               [] -> emitUnparsed slugs l ls
               _  ->
                 let txt                      = T.intercalate " " (map T.strip paraLines)
                     inlines                  = parseInline pageCount txt
                     blk                      = promote inlines
                     (restBlocks, slugsFinal) = go slugs ls'
                 in (blk : restBlocks, slugsFinal)

    -- | STRUCTURAL PROGRESS (A1 1a): unconditionally emit 'Unparsed' for
    -- exactly the one line that no rule could consume, and recurse on the
    -- REMAINING tail @ls@ (never on @l : ls@ again) -- so the input list
    -- strictly shrinks on every call to 'go' no matter what @classify@
    -- does.
    emitUnparsed slugs l ls =
      let (restBlocks, slugsFinal) = go slugs ls
      in (Unparsed l : restBlocks, slugsFinal)

    popSlug (s : rest) = (s, rest)
    popSlug []          = ("section", [])

    -- | NEW11's progress check for the 'OrderedShape'\/'BulletShape'
    -- branches: 'True' exactly when 'parseList' collected zero items,
    -- which by construction (see 'parseList') means its @remaining@ is
    -- the untouched input it was given -- unreachable for the real
    -- classifier, reachable only via a dishonest test classifier.
    blockHasNoItems :: Block -> Bool
    blockHasNoItems (Numbered _ items) = null items
    blockHasNoItems (Bullets items)    = null items
    blockHasNoItems _                  = False

    promote [Placeholder k full] = Figure k (parseInline pageCount (placeholderCaptionOf (placeholderInner full)))
    promote inlines               = Para inlines

isJustT :: Maybe a -> Bool
isJustT (Just _) = True
isJustT Nothing  = False

parseTable :: Int -> [Text] -> Block
parseTable pageCount rows = case (rows, map splitRowCells rows) of
  ((_ : sepLine : _), (headerCells : _ : bodyCellRows)) | isTableSeparator sepLine ->
    let header = if all T.null headerCells
                   then Nothing
                   else Just (map (parseInline pageCount) headerCells)
    in Table header (map (map (parseInline pageCount)) bodyCellRows)
  (_, cellRows) -> Table Nothing (map (map (parseInline pageCount)) cellRows)

splitRowCells :: Text -> [Text]
splitRowCells l = map T.strip (dropLast (dropFirst raw))
  where
    s   = T.strip l
    raw = T.splitOn "|" s
    dropFirst xs = case xs of
      (x : xs') | T.null x -> xs'
      _                    -> xs
    dropLast xs = reverse (dropFirst (reverse xs))

-- | Gather the item's own indented child lines. A blank line does not by
-- itself end the item -- only a subsequent non-blank line that dedents
-- below @threshold@ does -- so figures/quotes/paragraphs separated by
-- blank lines still nest correctly (measured fact: page 28 of the guide
-- book).
gatherChildren :: [Text] -> Int -> ([Text], [Text])
gatherChildren input threshold = go input [] []
  where
    go [] childrenRev _pending = (reverse childrenRev, [])
    go (l : ls) childrenRev pending
      | isBlankLine l      = go ls childrenRev (l : pending)
      | indentOf l >= threshold = go ls (l : pending ++ childrenRev) []
      | otherwise          = (reverse childrenRev, reverse pending ++ (l : ls))

parseList :: Int -> ListKind -> [Text] -> (Block, [Text])
parseList _ _ [] = error "SXC1.Content.Markdown.parseList: called with no input (unreachable)"
parseList pageCount kind lns0@(first : _) = (blk, remaining)
  where
    baseIndent = case kind of
      OrderedK -> maybe 0 (\(i, _, _) -> i) (orderedItemOf first)
      BulletK  -> maybe 0 fst (bulletItemOf first)
    threshold = baseIndent + 2

    matchAt :: Text -> Maybe (Int, Maybe Int, Text)
    matchAt x = case kind of
      OrderedK -> (\(i, num, r) -> (i, Just num, r)) <$> orderedItemOf x
      BulletK  -> (\(i, r) -> (i, Nothing, r)) <$> bulletItemOf x

    collect [] curStart accItems = (curStart, reverse accItems, [])
    collect (x : xs) curStart accItems = case matchAt x of
      Just (ind, mNum, rest) | ind == baseIndent ->
        let (childLines, xs')  = gatherChildren xs threshold
            childBlocks         = if null childLines
                                     then []
                                     else fst (parseBlocksEngine pageCount False [] childLines)
            -- An item's own marker-line text (@rest@) is ordinarily just
            -- inline content. But guide-book pp.50-54's "titled steps"
            -- (briefs/M1-fixes-2-manifest.json, task "titled-steps") put a
            -- heading marker on the SAME line as the list marker, e.g.
            -- @1. ### In Sampling mode ... select \`RESAMPLING\`@. When
            -- @rest@ is itself heading-shaped, emit it as a 'Heading'
            -- block at the head of 'liChildren' -- reusing the
            -- anchor-less nested-heading path used for blockquote/list
            -- content elsewhere in this engine, so it takes the empty
            -- anchor, is not an outline target, and does not touch the
            -- page's anchor-slug supply (which 'parseList' never threads
            -- through in the first place) -- and leave 'liContent' empty,
            -- rather than letting the raw @###@ text become literal
            -- inline content the way it used to (which is what let the
            -- \'#\'s leak out to the reader as literal characters).
            -- Applies to ordered and bullet items alike, via 'rest',
            -- which 'matchAt' produces uniformly for both; only ordered
            -- items exercise this in the corpus.
            (itemInlines, itemChildren) = case headingLineOf rest of
              Just (lvl, htext) -> ([], Heading lvl (parseInline pageCount htext) "" : childBlocks)
              Nothing            -> (parseInline pageCount rest, childBlocks)
            item                = ListItem itemInlines itemChildren
            curStart'           = case curStart of
                                     Nothing -> mNum
                                     s       -> s
        in collect xs' curStart' (item : accItems)
      _ -> (curStart, reverse accItems, x : xs)

    (mStart, items, remaining) = collect lns0 Nothing []
    blk = case kind of
      OrderedK -> Numbered (fromMaybe 1 mStart) items
      BulletK  -> Bullets items

placeholderInner :: Text -> Text
placeholderInner full = fromMaybe full (T.stripSuffix "]*" =<< T.stripPrefix "*[" full)

placeholderKindOf :: Text -> Text
placeholderKindOf inner = fst (T.break (\c -> c == ':' || c == ']') inner)

placeholderCaptionOf :: Text -> Text
placeholderCaptionOf inner = case T.break (== ':') inner of
  (_, rest) | not (T.null rest) -> T.strip (T.drop 1 rest)
  _                             -> ""

--------------------------------------------------------------------------
-- Inline grammar
--------------------------------------------------------------------------

-- | Scanned left to right, longest\/most-specific marker first: escape,
-- code, strong (before placeholder, so @**[Example]**@ is bold), inline
-- figure placeholder, emphasis, @\<br\>@, page cross-reference, else plain
-- text. @pageCount@ bounds which @p.\/pp.@ numbers become 'PageRef'.
parseInline :: Int -> Text -> [Inline]
parseInline pageCount = mergeStr . go
  where
    triggerChars :: String
    triggerChars = "\\`*<pP"

    go :: Text -> [Inline]
    go t = case T.findIndex (`elem` triggerChars) t of
      Nothing -> [Str t | not (T.null t)]
      Just 0  -> tryOne t
      Just i  -> Str (T.take i t) : tryOne (T.drop i t)

    tryOne :: Text -> [Inline]
    tryOne t
      | Just rest1 <- T.stripPrefix "\\" t, Just (c, rest2) <- T.uncons rest1
          = Str (T.singleton c) : go rest2
      | Just rest1 <- T.stripPrefix "`" t
          = case T.breakOn "`" rest1 of
              (code, closing) | not (T.null closing) -> Code code : go (T.drop 1 closing)
              _ -> Str "`" : go rest1
      | Just rest1 <- T.stripPrefix "**" t
          = case findClose "**" rest1 of
              Just (inner, after) -> Strong (parseInline pageCount inner) : go after
              Nothing              -> Str "*" : go (T.drop 1 t)
      | Just rest1 <- T.stripPrefix "*[" t
          = case T.breakOn "]*" rest1 of
              (inner, closing) | not (T.null closing) ->
                Placeholder (placeholderKindOf inner) ("*[" <> inner <> "]*") : go (T.drop 2 closing)
              _ -> Str "*" : go rest1
      | Just rest1 <- T.stripPrefix "*" t
          = case findClose "*" rest1 of
              Just (inner, after) -> Em (parseInline pageCount inner) : go after
              Nothing              -> Str "*" : go rest1
      | Just after <- matchBreak t
          = Break : go after
      | Just (num, disp, after) <- matchPageRef pageCount t
          = PageRef num disp : go after
      | otherwise = case T.uncons t of
          Just (c, rest) -> Str (T.singleton c) : go rest
          Nothing        -> []

findClose :: Text -> Text -> Maybe (Text, Text)
findClose marker t = case T.breakOn marker t of
  (inner, closing) | not (T.null closing) -> Just (inner, T.drop (T.length marker) closing)
  _                                       -> Nothing

matchBreak :: Text -> Maybe Text
matchBreak t = do
  rest1 <- ciStripPrefix "<br" t
  let rest2 = T.dropWhile (== ' ') rest1
      rest3 = fromMaybe rest2 (T.stripPrefix "/" rest2)
  T.stripPrefix ">" rest3

ciStripPrefix :: Text -> Text -> Maybe Text
ciStripPrefix p t =
  let n           = T.length p
      (h, rest)   = T.splitAt n t
  in if T.toLower h == T.toLower p then Just rest else Nothing

-- | @p. N@, @p.N@, @pp. N-M@, @pp. N\8211M@ -> 'PageRef', bounded by
-- @1 <= N <= pageCount@; otherwise left as plain text (returns 'Nothing').
matchPageRef :: Int -> Text -> Maybe (Int, Text, Text)
matchPageRef pageCount t
  | Just rest0 <- T.stripPrefix "pp." t = tryRange rest0
  | Just rest0 <- T.stripPrefix "p." t  = trySingle rest0
  | otherwise = Nothing
  where
    inRange n = n >= 1 && n <= pageCount

    trySingle rest0 =
      let rest1 = T.dropWhile (== ' ') rest0
      in case parseDecimal rest1 of
           Just (n, rest2) | inRange n -> Just (n, matchedSpan rest2, rest2)
           _                            -> Nothing

    tryRange rest0 =
      let rest1 = T.dropWhile (== ' ') rest0
      in case parseDecimal rest1 of
           Nothing -> Nothing
           Just (n1, rest2) ->
             let rest3 = T.dropWhile (== ' ') rest2
             in case T.uncons rest3 of
                  Just (c, rest4) | c == '-' || c == '\x2013' ->
                    case parseDecimal rest4 of
                      Just (_n2, rest5) | inRange n1 -> Just (n1, matchedSpan rest5, rest5)
                      _                               -> singleFallback n1 rest2
                  _ -> singleFallback n1 rest2
      where
        singleFallback n1 rest2
          | inRange n1 = Just (n1, matchedSpan rest2, rest2)
          | otherwise  = Nothing

    matchedSpan restAfter = T.take (T.length t - T.length restAfter) t

parseDecimal :: Text -> Maybe (Int, Text)
parseDecimal t =
  let (digs, rest) = T.span isDigitChar t
  in if T.null digs then Nothing else Just (digitsToInt digs, rest)

-- | Merge adjacent 'Str' tokens produced while scanning.
mergeStr :: [Inline] -> [Inline]
mergeStr (Str a : Str b : rest) = mergeStr (Str (a <> b) : rest)
mergeStr (x : xs)               = x : mergeStr xs
mergeStr []                     = []
