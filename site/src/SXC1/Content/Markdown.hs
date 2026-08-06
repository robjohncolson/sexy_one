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
    -- * Slugs
  , slugify
  , dedupeSlugs
    -- * Inline parsing (exposed for reuse/testing)
  , parseInline
  ) where

import           Data.Char             (isAlphaNum)
import qualified Data.Map.Strict       as Map
import           Data.Maybe            (fromMaybe, mapMaybe)
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
-- Heading lines (top-level only -- see the module note on why nested
-- quote/list content never contributes headings)
--------------------------------------------------------------------------

-- | Match @^(#{1,6}) +(\\S.*)$@. Because this requires the line to begin
-- with @#@, it naturally never matches a blockquote-marked or indented
-- line -- headings are only ever recognised at a page's top level.
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
dedupeSlugs :: [Text] -> [Text]
dedupeSlugs = go Map.empty
  where
    go _ [] = []
    go seen (s : rest) =
      let n  = Map.findWithDefault (0 :: Int) s seen
          s' = if n == 0 then s else s <> "-" <> T.pack (show (n + 1))
      in s' : go (Map.insert s (n + 1) seen) rest

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

-- | The shared block-parsing engine. @allowHeadings@ is true only for a
-- page's top-level pass -- blockquote content and list-item children are
-- always parsed with it off (see the module note: 4.5's blockquote/list
-- rules only ever enumerate paragraphs, figures, blockquotes and nested
-- lists as valid nested content, never headings). This is also what keeps
-- the golden @headings@ count exact: the corpus has a few decorative
-- @###@ lines inside \"Tip\" callouts that are body text, not structural
-- headings.
--
-- The @[Text]@ threaded alongside the blocks is the page's pre-computed
-- anchor-slug supply (see 'mkDoc'); each top-level 'Heading' consumes one.
parseBlocksEngine :: Int -> Bool -> [Text] -> [Text] -> ([Block], [Text])
parseBlocksEngine pageCount allowHeadings = go
  where
    go slugs [] = ([], slugs)
    go slugs (l : ls)
      | isBlankLine l = go slugs ls
      | allowHeadings, Just (lvl, htext) <- headingLineOf l =
          let (slug, slugsRest)        = popSlug slugs
              (restBlocks, slugsFinal) = go slugsRest ls
          in (Heading lvl (parseInline pageCount htext) slug : restBlocks, slugsFinal)
      | isTableRowLine l =
          let (rows, ls')               = span isTableRowLine (l : ls)
              (restBlocks, slugsFinal)   = go slugs ls'
          in (parseTable pageCount rows : restBlocks, slugsFinal)
      | Just _ <- quoteLineContent l =
          let (qraw, ls')              = span (isJustT . quoteLineContent) (l : ls)
              qcontents                 = map (fromMaybe "" . quoteLineContent) qraw
              inner                     = fst (parseBlocksEngine pageCount False [] qcontents)
              (restBlocks, slugsFinal)  = go slugs ls'
          in (Quote inner : restBlocks, slugsFinal)
      | Just _ <- orderedItemOf l =
          let (blk, ls')               = parseList pageCount OrderedK (l : ls)
              (restBlocks, slugsFinal) = go slugs ls'
          in (blk : restBlocks, slugsFinal)
      | Just _ <- bulletItemOf l =
          let (blk, ls')               = parseList pageCount BulletK (l : ls)
              (restBlocks, slugsFinal) = go slugs ls'
          in (blk : restBlocks, slugsFinal)
      | otherwise =
          let (paraLines, ls')        = span isParaLine (l : ls)
              txt                      = T.intercalate " " (map T.strip paraLines)
              inlines                  = parseInline pageCount txt
              blk                      = promote inlines
              (restBlocks, slugsFinal) = go slugs ls'
          in (blk : restBlocks, slugsFinal)
      where
        isParaLine x =
          not (isBlankLine x)
            && not (isTableRowLine x)
            && not (isJustT (quoteLineContent x))
            && not (isJustT (orderedItemOf x))
            && not (isJustT (bulletItemOf x))
            && not (allowHeadings && isJustT (headingLineOf x))

    popSlug (s : rest) = (s, rest)
    popSlug []          = ("section", [])

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
            itemInlines         = parseInline pageCount rest
            itemChildren        = if null childLines
                                     then []
                                     else fst (parseBlocksEngine pageCount False [] childLines)
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
