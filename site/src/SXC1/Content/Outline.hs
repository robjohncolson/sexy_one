{-# LANGUAGE OverloadedStrings #-}

-- | Navigation outline: @secLevel@, sections, subsections, parts and
-- groups, all derived purely from a document's raw text (see
-- @briefs\/M1-plan.md@ 5.1). This module never touches a parsed 'Doc' or
-- forces 'SXC1.Content.Types.pageBlocks' -- it only does the cheap,
-- line-level heading\/running-header scan that "SXC1.Content.Markdown"
-- exposes, so it is safe to compute for all four documents on every route
-- (the stats blob needs 'outSections'\/'outPartTitles' for all of them).
module SXC1.Content.Outline
  ( Section (..)
  , Group (..)
  , Outline (..)
  , buildOutline
  ) where

import qualified Data.Map.Strict       as Map
import           Data.Maybe            (mapMaybe)
import           Data.Text             (Text)
import qualified Data.Text             as T

import           SXC1.Content.Markdown (extractRunningHeader, headingLineOf, splitPageTexts)

-- | One section (heading at 'outSecLevel'), with its attached subsections.
data Section = Section
  { secPage    :: !Int          -- ^ the page the section's heading is on
  , secTitle   :: !Text
  , secEndPage :: !Int          -- ^ last page before the next section (or doc end)
  , secSubs    :: [(Int, Text)] -- ^ subsection (page, title) pairs, in order
  } deriving (Eq, Show)

-- | A top-level navigation group: \"Front matter\", one per PART, or
-- \"Appendix & reference\". Group titles other than the two UI labels are
-- the PART heading's own verbatim text.
data Group = Group
  { grpTitle    :: !Text
  , grpSections :: [Section]
  } deriving (Eq, Show)

data Outline = Outline
  { outSecLevel   :: !Int
  , outSections   :: [Section]      -- ^ flat list, always present
  , outGroups     :: Maybe [Group]  -- ^ 'Nothing' when the document has fewer than 2 parts
  , outPartTitles :: [Text]         -- ^ [] when the document has no parts
  } deriving (Eq, Show)

-- | Compute the outline of one document from its raw embedded markdown.
buildOutline :: Text -> Outline
buildOutline raw = Outline secLevel sections groups partTitles
  where
    pages     = splitPageTexts raw
    pageCount = length pages

    headsByPage :: [(Int, [(Int, Text)])]
    headsByPage = [ (n, mapMaybe headingLineOf ls) | (n, ls) <- pages ]

    runningHeaderByPage :: Map.Map Int (Maybe Text)
    runningHeaderByPage = Map.fromList [ (n, fst (extractRunningHeader ls)) | (n, ls) <- pages ]

    -- | Every heading line in the document, in SOURCE ORDER: 'pages' is
    -- already page-ascending ('splitPageTexts' walks the markers in
    -- file order), and within each page 'mapMaybe' over that page's own
    -- lines preserves line order -- so this flat list is exactly the
    -- document's front-to-back heading sequence. NEW1's fix rests
    -- entirely on this already being true; see 'attachSubsInOrder'.
    allHeads :: [(Int, Int, Text)]
    allHeads = [ (n, lvl, txt) | (n, hs) <- headsByPage, (lvl, txt) <- hs ]

    levelCounts :: Map.Map Int Int
    levelCounts = Map.fromListWith (+) [ (lvl, 1 :: Int) | (_, lvl, _) <- allHeads ]

    secLevel :: Int
    secLevel = case [ lvl | (lvl, c) <- Map.toList levelCounts, c >= 2 ] of
      (l : ls) -> minimum (l : ls)
      []       -> case [ lvl | (_, lvl, _) <- allHeads ] of
                    (l : _) -> l
                    []      -> 1

    -- | Section- and subsection-level heading events only, STILL in
    -- source order ('filter' preserves order) -- what
    -- 'attachSubsInOrder' walks.
    relevantHeads :: [(Int, Int, Text)]
    relevantHeads = [ h | h@(_, lvl, _) <- allHeads, lvl == secLevel || lvl == secLevel + 1 ]

    sections :: [Section]
    sections = attachSubsInOrder pageCount secLevel relevantHeads

    partIdxs :: [Int]
    partIdxs = [ i | (i, s) <- zip [0 ..] sections, isPartTitle (secTitle s) ]

    partTitles = [ secTitle s | i <- partIdxs, Just s <- [nth i sections] ]

    groups
      | length partIdxs >= 2 = Just (buildGroups sections partIdxs runningHeaderByPage)
      | otherwise            = Nothing

nth :: Int -> [a] -> Maybe a
nth i xs
  | i < 0     = Nothing
  | otherwise = case drop i xs of
      (x : _) -> Just x
      []      -> Nothing

-- | NEW1's fix. The OLD 'attachSubs' (page-range based: a subsection
-- belonged to section @s@ iff its page fell in @[secPage s .. secEndPage
-- s]@, and @secEndPage@ was always @nextSectionPage - 1@) silently broke
-- whenever two section-level headings shared a page: the EARLIER one's
-- @secEndPage@ became @secPage - 1@ (an empty, descending range), so it
-- owned no page at all and every same-page subsection fell through to
-- the LATER section instead -- reproduced live on startup-guide p.10/14,
-- midi p.2 and oss p.11 (guide-book has no such page, which is why every
-- guide-book golden stayed green throughout). Aggregate section\/
-- subsection COUNTS were unaffected either way, because the page ranges
-- still partitioned every subsection into exactly one (just sometimes
-- the wrong) section -- which is exactly why a golden-count assertion
-- alone could never have caught it.
--
-- The fix: walk the section\/subsection heading events IN SOURCE ORDER
-- (not by page membership) and attach each subsection to the last
-- section event that precedes it in the text -- 'buildRaw' below does
-- exactly that with a single left-to-right pass, via 'span' peeling off
-- the run of subsection events up to the next section event. 'secEndPage' is
-- then set to the next section's page minus one only when that next
-- section is on a STRICTLY LATER page; when two (or more) sections share
-- a page, each keeps its OWN page as its end page instead of a bogus
-- negative-length range. That makes @secEndPage >= secPage@ an
-- invariant of every 'Section' this function can produce, rather than an
-- accident that only held as long as no two sections ever shared a page
-- (see group 14's invariant check in @test\/CheckContent.hs@).
attachSubsInOrder :: Int -> Int -> [(Int, Int, Text)] -> [Section]
attachSubsInOrder pageCount secLevel heads = setEndPages (buildRaw heads)
  where
    -- | (page, title, subs), subs not yet page-ranged -- 'setEndPages'
    -- fills in 'secEndPage' in a second left-to-right pass once every
    -- section's own page and its immediate successor's page are both
    -- known.
    buildRaw :: [(Int, Int, Text)] -> [(Int, Text, [(Int, Text)])]
    buildRaw [] = []
    buildRaw ((p, lvl, txt) : rest)
      | lvl == secLevel =
          let (subs, rest') = span (\(_, l, _) -> l /= secLevel) rest
          in (p, txt, [ (sp, st) | (sp, _, st) <- subs ]) : buildRaw rest'
      -- A subsection-level event before any section-level event has no
      -- section to attach to. Does not occur in the corpus (every
      -- document's first relevant heading is section-level), but drop
      -- it rather than crash if it ever did.
      | otherwise = buildRaw rest

    setEndPages :: [(Int, Text, [(Int, Text)])] -> [Section]
    setEndPages []                     = []
    setEndPages [(p, t, subs)]         = [Section p t pageCount subs]
    setEndPages ((p, t, subs) : rest@((p2, _, _) : _)) =
      Section p t (if p2 > p then p2 - 1 else p) subs : setEndPages rest

-- | @^PART\\s+\\d+\\b@.
isPartTitle :: Text -> Bool
isPartTitle t = case T.stripPrefix "PART" t of
  Nothing -> False
  Just rest0 ->
    let (spaces, rest1) = T.span (== ' ') rest0
        (digs, rest2)   = T.span isDigit rest1
    in not (T.null spaces) && not (T.null digs) && (T.null rest2 || not (isAlphaNumAscii (T.head rest2)))
  where
    isDigit c = c >= '0' && c <= '9'
    isAlphaNumAscii c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')

-- | Whether any suffix of the text matches @PART\\s+\\d+\\b@. Running
-- headers embed the PART mention mid-string (after an em dash), not as a
-- prefix, which is why this scans every suffix rather than just checking
-- 'isPartTitle' on the whole string.
containsPartMention :: Text -> Bool
containsPartMention t
  | T.null t       = False
  | isPartTitle t  = True
  | otherwise      = containsPartMention (T.drop 1 t)

buildGroups :: [Section] -> [Int] -> Map.Map Int (Maybe Text) -> [Group]
buildGroups sections partIdxs runningHeaders =
  frontGroup ++ partGroups ++ backGroup
  where
    lastPartI = last partIdxs

    hasPartHeaderOnPage :: Int -> Bool
    hasPartHeaderOnPage pn = case Map.lookup pn runningHeaders of
      Just (Just h) -> containsPartMention h
      _             -> False

    sectionSpanPages s = [secPage s .. secEndPage s]

    boundaryIdx :: Maybe Int
    boundaryIdx = findBoundary (lastPartI + 1)
      where
        findBoundary i
          | i >= length sections = Nothing
          | any hasPartHeaderOnPage (sectionSpanPages (sections !! i)) = findBoundary (i + 1)
          | otherwise = Just i

    front = case partIdxs of
      (firstPartI : _) -> take firstPartI sections
      []                -> []
    frontGroup = [ Group "Front matter" front | not (null front) ]

    takeRange a b xs = [ x | (i, x) <- zip [0 ..] xs, i >= a, i <= b ]

    partGroups = [ mkPartGroup k | k <- [0 .. length partIdxs - 1] ]
    mkPartGroup k =
      let pi_  = partIdxs !! k
          endI = if k + 1 < length partIdxs
                   then (partIdxs !! (k + 1)) - 1
                   else maybe (length sections - 1) (subtract 1) boundaryIdx
      in Group (secTitle (sections !! pi_)) (takeRange pi_ endI sections)

    backGroup = case boundaryIdx of
      Just bi -> [ Group "Appendix & reference" (drop bi sections) ]
      Nothing -> []
