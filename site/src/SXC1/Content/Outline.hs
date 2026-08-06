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

    sections0    = [ (n, txt) | (n, lvl, txt) <- allHeads, lvl == secLevel ]
    subsections0 = [ (n, txt) | (n, lvl, txt) <- allHeads, lvl == secLevel + 1 ]

    sections :: [Section]
    sections = attachSubs pageCount sections0 subsections0

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

attachSubs :: Int -> [(Int, Text)] -> [(Int, Text)] -> [Section]
attachSubs pageCount = go
  where
    go []            _    = []
    go [(p, t)]      subs = [mk p t pageCount subs]
    go ((p, t) : rest@((p2, _) : _)) subs = mk p t (p2 - 1) subs : go rest subs
    mk p t endP subs = Section p t endP [ (sp, st) | (sp, st) <- subs, sp >= p, sp <= endP ]

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
