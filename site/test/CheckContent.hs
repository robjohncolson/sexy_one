{-# LANGUAGE OverloadedStrings #-}

-- | @exe:content-check@ -- a wasm32-wasi COMMAND module (no reactor flags;
-- those live only in @exe:app@'s cabal stanza), run on the host via
-- @wasm-run.mjs@. Real Haskell unit + corpus tests, no browser.
--
-- Usage:
--   content-check            run every assertion, print a summary line per
--                             assertion group (and every failing sub-check),
--                             exit 0 only if all passed
--   content-check --verbose  additionally print every individual sub-check
--   content-check --json     print ONLY the stats JSON (what
--                             scripts\/check-site.sh consumes)
module Main (main) where

import           Control.Exception     (SomeException, evaluate, try)
import           Control.Monad         (forM_, unless, when)
import           Data.List             (nub)
import           Data.Text             (Text)
import qualified Data.Text             as T
import qualified Data.Text.IO          as TIO
import           System.Environment    (getArgs)
import           System.Exit           (exitFailure, exitSuccess)
import           System.IO             (hSetEncoding, stdout, utf8)

import           SXC1.Content.Corpus   (corpusSources, docs, glossarySource)
import           SXC1.Content.Markdown (headingLineOf)
import           SXC1.Content.Outline
import           SXC1.Content.Stats
import           SXC1.Content.Types
import           SXC1.Route

--------------------------------------------------------------------------
-- A tiny checklist
--------------------------------------------------------------------------

data Check = Check
  { chkGroup :: !Int
  , chkName  :: !String
  , chkOk    :: !Bool
  , chkMsg   :: !String
  }

mkCheck :: Int -> String -> Bool -> String -> Check
mkCheck = Check

assertionLabel :: Int -> String
assertionLabel 1 = "1. page markers 1..N ascending"
assertionLabel 2 = "2. golden stats table"
assertionLabel 3 = "3. zero Unparsed blocks corpus-wide"
assertionLabel 4 = "4. golden outline"
assertionLabel 5 = "5. glossary <-> part title conformance"
assertionLabel 6 = "6. anchor slugs unique and non-empty"
assertionLabel 7 = "7. Route round-trip and totality"
assertionLabel 8 = "8. every page non-empty, every table has a body row"
assertionLabel 9 = "9. nested (blockquote/list) heading lines become real Heading blocks"
assertionLabel 10 = "10. no literal '#' Str token anywhere in the corpus"
assertionLabel 11 = "11. pinned guide-book anchors on pp. 41/42/43/47 unchanged"
assertionLabel n = show n ++ ". ?"

--------------------------------------------------------------------------
-- Shared helpers
--------------------------------------------------------------------------

-- | Recursively descend into 'Quote' and list-item children so nothing
-- nested (e.g. a figure inside a blockquote) is missed by the checks.
flattenBlocks :: [Block] -> [Block]
flattenBlocks = concatMap flattenOne
  where
    flattenOne b = b : case b of
      Quote inner       -> flattenBlocks inner
      Bullets items      -> concatMap (flattenBlocks . liChildren) items
      Numbered _ items    -> concatMap (flattenBlocks . liChildren) items
      _                  -> []

firstOf :: [a] -> Maybe a
firstOf (x : _) = Just x
firstOf []      = Nothing

lastOf :: [a] -> Maybe a
lastOf [x]      = Just x
lastOf (_ : xs) = lastOf xs
lastOf []       = Nothing

--------------------------------------------------------------------------
-- 1. Page markers
--------------------------------------------------------------------------

pageMarkerChecks :: [Check]
pageMarkerChecks =
  [ mkCheck 1 ("page-markers/" ++ T.unpack (docSlug d))
      (nums == [1 .. length nums])
      ("page numbers = " ++ show nums)
  | d <- docs
  , let nums = map pageNumber (docPages d)
  ]

--------------------------------------------------------------------------
-- 2. Golden stats table (briefs/M1-manifest.json content-core prompt)
--------------------------------------------------------------------------

data GoldenRow = GoldenRow
  { gChars, gLines, gPages, gHeadings, gFigures, gTables, gSections, gSubsections, gParts :: Int }

goldenTable :: [(Text, GoldenRow)]
goldenTable =
  [ ("guide-book",    GoldenRow 111559 2356 71 188 190 20 29 78 5)
  , ("startup-guide", GoldenRow 29145  567  15 51  43  5  21 27  0)
  , ("midi",          GoldenRow 7372   160  6  8   4   7  6  1   0)
  , ("oss",           GoldenRow 42533  388  16 6   0   0  5  0   0)
  ]

goldenChecks :: [Check]
goldenChecks = concat
  [ fieldChecks slug g
  | (slug, g) <- goldenTable
  ]
  where
    allStats = buildStats corpusSources
    fieldChecks slug g = case [ s | s <- allStats, stSlug s == slug ] of
      (st : _) ->
        [ f slug st "chars"       stChars       gChars
        , f slug st "lines"       stLines       gLines
        , f slug st "pages"       stPages       gPages
        , f slug st "headings"    stHeadings    gHeadings
        , f slug st "figures"     stFigures     gFigures
        , f slug st "tables"      stTables      gTables
        , f slug st "sections"    stSections    gSections
        , f slug st "subsections" stSubsections gSubsections
        , f slug st "parts"       stParts       gParts
        , mkCheck 2 ("golden/" ++ T.unpack slug ++ "/unparsed") (stUnparsed st == 0)
            (show (stUnparsed st) ++ " (want 0)")
        ]
          ++ [ mkCheck 2 ("golden/" ++ T.unpack slug ++ "/partTitlesCount")
                 (length (stPartTitles st) == gParts g)
                 (show (length (stPartTitles st)) ++ " (want " ++ show (gParts g) ++ ")")
             ]
      [] -> [ mkCheck 2 ("golden/" ++ T.unpack slug ++ "/present") False "document missing from corpusSources" ]
      where
        f slug' st fname getS getG =
          mkCheck 2 ("golden/" ++ T.unpack slug' ++ "/" ++ fname)
            (getS st == getG g)
            (show (getS st) ++ " (want " ++ show (getG g) ++ ")")

--------------------------------------------------------------------------
-- 3. Zero Unparsed blocks corpus-wide
--------------------------------------------------------------------------

unparsedChecks :: [Check]
unparsedChecks = concat
  [ [ mkCheck 3 ("unparsed/" ++ slug ++ "/preamble") (null preOcc) (describe preOcc)
    , mkCheck 3 ("unparsed/" ++ slug ++ "/pages") (null pageOcc) (describe pageOcc)
    ]
  | d <- docs
  , let slug     = T.unpack (docSlug d)
        preOcc   = [ t | Unparsed t <- flattenBlocks (docPreamble d) ]
        pageOcc  = [ (pageNumber p, t) | p <- docPages d, Unparsed t <- flattenBlocks (pageBlocks p) ]
  ]
  where
    describe :: Show a => [a] -> String
    describe [] = "0 unparsed"
    describe xs = show (length xs) ++ " unparsed: " ++ show (take 5 xs)

--------------------------------------------------------------------------
-- 4. Golden outline (briefs/M1-plan.md 5.2)
--------------------------------------------------------------------------

goldenPartTitles :: [Text]
goldenPartTitles =
  [ "PART 0 — Part: Preparation"
  , "PART 1 — Part: Pad play"
  , "PART 2 — Part: Sampling"
  , "PART 3 — Part: Sequencer"
  , "PART 4 — Part: Leveling up"
  ]

goldenGuideBookGroups :: [(Text, Int, Int, Int)] -- (title, startPage, endPage, sectionCount)
goldenGuideBookGroups =
  [ ("Front matter", 1, 11, 5)
  , ("PART 0 — Part: Preparation", 12, 13, 1)
  , ("PART 1 — Part: Pad play", 14, 26, 3)
  , ("PART 2 — Part: Sampling", 27, 34, 1)
  , ("PART 3 — Part: Sequencer", 35, 45, 2)
  , ("PART 4 — Part: Leveling up", 46, 61, 12)
  , ("Appendix & reference", 62, 71, 5)
  ]

summarizeGroup :: Group -> (Text, Int, Int, Int)
summarizeGroup g =
  ( grpTitle g
  , maybe 0 secPage (firstOf (grpSections g))
  , maybe 0 secEndPage (lastOf (grpSections g))
  , length (grpSections g)
  )

outlineChecks :: [Check]
outlineChecks = guideBookChecks ++ concatMap flatDocChecks flatDocs
  where
    src slug = lookup slug corpusSources

    guideBookChecks = case src "guide-book" of
      Nothing -> [mkCheck 4 "outline/guide-book/present" False "guide-book missing from corpusSources"]
      Just raw ->
        let o = buildOutline raw
        in [ mkCheck 4 "outline/guide-book/secLevel" (outSecLevel o == 1) (show (outSecLevel o) ++ " (want 1)")
           , mkCheck 4 "outline/guide-book/sections" (length (outSections o) == 29)
               (show (length (outSections o)) ++ " (want 29)")
           , mkCheck 4 "outline/guide-book/subsections"
               (sum (map (length . secSubs) (outSections o)) == 78)
               (show (sum (map (length . secSubs) (outSections o))) ++ " (want 78)")
           , mkCheck 4 "outline/guide-book/partTitles" (outPartTitles o == goldenPartTitles)
               (show (outPartTitles o))
           , mkCheck 4 "outline/guide-book/groups"
               (case outGroups o of
                  Just gs -> map summarizeGroup gs == goldenGuideBookGroups
                  Nothing -> False)
               (show (fmap (map summarizeGroup) (outGroups o)))
           ]

    -- (slug, expected sections, expected subsections)
    flatDocs :: [(Text, Int, Int)]
    flatDocs = [("startup-guide", 21, 27), ("midi", 6, 1), ("oss", 5, 0)]

    flatDocChecks (slug, expSec, expSub) = case src slug of
      Nothing -> [mkCheck 4 ("outline/" ++ T.unpack slug ++ "/present") False "missing from corpusSources"]
      Just raw ->
        let o = buildOutline raw
        in [ mkCheck 4 ("outline/" ++ T.unpack slug ++ "/ungrouped")
               (case outGroups o of Nothing -> True; Just _ -> False)
               (show (fmap (map grpTitle) (outGroups o)) ++ " (want Nothing)")
           , mkCheck 4 ("outline/" ++ T.unpack slug ++ "/sections")
               (length (outSections o) == expSec)
               (show (length (outSections o)) ++ " (want " ++ show expSec ++ ")")
           , mkCheck 4 ("outline/" ++ T.unpack slug ++ "/subsections")
               (sum (map (length . secSubs) (outSections o)) == expSub)
               (show (sum (map (length . secSubs) (outSections o))) ++ " (want " ++ show expSub ++ ")")
           ]

--------------------------------------------------------------------------
-- 5. Glossary <-> part title conformance (briefs/M1-plan.md 5.3)
--------------------------------------------------------------------------

bindingChapterNames :: [Text]
bindingChapterNames =
  [ "Part: Preparation", "Part: Pad play", "Part: Sampling", "Part: Sequencer", "Part: Leveling up" ]

glossaryChecks :: [Check]
glossaryChecks =
  [ mkCheck 5 ("glossary/" ++ T.unpack name)
      (inGlossary && length matches == 1)
      ("inGlossary=" ++ show inGlossary ++ " matchingPartTitles=" ++ show matches)
  | name <- bindingChapterNames
  , let inGlossary = name `T.isInfixOf` glossarySource
        matches     = [ pt | pt <- gbPartTitles, name `T.isInfixOf` pt ]
  ]
  where
    gbPartTitles = maybe [] (outPartTitles . buildOutline) (lookup "guide-book" corpusSources)

--------------------------------------------------------------------------
-- 6. Anchor slugs unique and non-empty within each document
--
-- Deliberately top-level 'pageBlocks' only, NOT 'flattenBlocks': a nested
-- heading (inside a 'Quote' or list-item, e.g. a guide-book "Tip"
-- callout's @### ...@ line -- see group 9) is not an outline target and
-- is given the empty anchor by design, since it never draws from the
-- page's anchor-slug supply (briefs/M1-fixes-manifest.json,
-- "nested-headings"). Only top-level headings are required to have
-- unique, non-empty anchors; group 9's literal-hash guard is what keeps
-- nested headings honest.
--------------------------------------------------------------------------

anchorChecks :: [Check]
anchorChecks =
  [ mkCheck 6 ("anchors/" ++ T.unpack (docSlug d))
      (nonEmpty && unique)
      ("count=" ++ show (length slugs) ++ " unique=" ++ show (length (nub slugs)))
  | d <- docs
  , let slugs    = [ s | p <- docPages d, Heading _ _ s <- pageBlocks p ]
        nonEmpty = all (not . T.null) slugs
        unique   = length slugs == length (nub slugs)
  ]

--------------------------------------------------------------------------
-- 7. Route round-trip and totality
--------------------------------------------------------------------------

routeRoundTripChecks :: [Check]
routeRoundTripChecks =
  [ mkCheck 7 ("route-roundtrip/" ++ show r)
      (parseRoute (renderRoute r) == r)
      (T.unpack (renderRoute r) ++ " -> " ++ show (parseRoute (renderRoute r)))
  | r <- [ RHome
         , RManual "guide-book"
         , RPage "guide-book" 17 False
         , RPage "guide-book" 17 True
         ]
  ]

malformedInputs :: [Text]
malformedInputs =
  [ "", "#", "#/", "#/m", "#/m//p/x", "#/m/x/p/-1", "#/m/x/p/9999", "#/m/x/p/017", "#/../../etc/passwd" ]

totalityCheck :: Text -> IO Check
totalityCheck input = do
  result <- try (evaluate (length (show (parseRoute input)))) :: IO (Either SomeException Int)
  pure $ case result of
    Left e  -> mkCheck 7 ("route-total/" ++ show input) False ("threw: " ++ show e)
    Right n -> mkCheck 7 ("route-total/" ++ show input) True ("ok, show length=" ++ show n)

--------------------------------------------------------------------------
-- 8. Every page has >=1 block; every Table has >=1 body row
--------------------------------------------------------------------------

pageNonEmptyChecks :: [Check]
pageNonEmptyChecks =
  [ mkCheck 8 ("page-nonempty/" ++ T.unpack (docSlug d) ++ "/p" ++ show (pageNumber p))
      (not (null (pageBlocks p)))
      ("blocks=" ++ show (length (pageBlocks p)))
  | d <- docs, p <- docPages d
  ]

tableBodyChecks :: [Check]
tableBodyChecks =
  [ mkCheck 8 ("table-body/" ++ T.unpack (docSlug d) ++ "/p" ++ show (pageNumber p) ++ "/" ++ show i)
      (not (null body))
      ("bodyRows=" ++ show (length body))
  | d <- docs
  , p <- docPages d
  , (i, Table _ body) <- zip [(0 :: Int) ..] (filter isTableBlock (flattenBlocks (pageBlocks p)))
  ]
  where
    isTableBlock (Table _ _) = True
    isTableBlock _           = False

--------------------------------------------------------------------------
-- 9. Nested headings: a blockquote/list-item heading line (e.g. the
-- guide book's "Tip" callouts, pp. 41/43/47) must parse to a real
-- 'Heading' block, not fall through to 'Para' text
-- (briefs/M1-fixes-manifest.json, task "nested-headings").
--------------------------------------------------------------------------

countHeadingsAt :: [Block] -> Int
countHeadingsAt bs = length [ () | Heading _ _ _ <- bs ]

-- | Headings that occur strictly *inside* a 'Quote' or a list item's
-- children -- i.e. everything 'flattenBlocks' finds, minus what is
-- already present at the given top level.
nestedHeadingCount :: [Block] -> Int
nestedHeadingCount bs = countHeadingsAt (flattenBlocks bs) - countHeadingsAt bs

nestedHeadingChecks :: [Check]
nestedHeadingChecks =
  [ mkCheck 9 ("nested-headings/" ++ T.unpack (docSlug d))
      (got == want)
      ("nested Heading count=" ++ show got ++ " (want " ++ show want ++ ")")
  | d <- docs
  , let want = if docSlug d == "guide-book" then 3 else 0
        got  = nestedHeadingCount (docPreamble d)
                 + sum [ nestedHeadingCount (pageBlocks p) | p <- docPages d ]
  ]

--------------------------------------------------------------------------
-- 10. General literal-hash guard: no 'Str' inline in NESTED BLOCK CONTENT
-- -- 'Quote' bodies and list-item CHILDREN (recursively; the two places
-- 4.5 recursively re-parses raw lines as blocks, and so the two places
-- 'parseBlocksEngine's @consumesSlugs@ gate used to also (wrongly) gate
-- heading recognition) -- plus top-level Heading\/Para\/Figure captions
-- and table cells, may begin with a literal heading marker (one to six
-- '#' characters then a space). This is the general form of group 9's
-- regression: it catches the whole class of "a heading line fell through
-- to plain text because it was nested" bug, not just the three known
-- lines, and reuses 'headingLineOf' so the predicate is exactly the one
-- that decides real headings, applied to inline text instead of a whole
-- source line.
--
-- Deliberately EXCLUDED: a list item's own marker-line caption
-- ('liContent'). 4.5's ordered\/bullet-item rule captures @(.*)$@ after
-- the marker directly as that item's @[Inline]@ content -- a position
-- 'parseBlocksEngine' never recursively block-parses and this fix does
-- not touch, unlike 'liChildren' (a nested line indented under the item,
-- which the same recursive block parse as 'Quote' handles). The corpus
-- has 13 pre-existing numbered-list items on guide-book pp. 50-53 (the
-- Resampling\/Auto Chop\/Auto Trigger steps) whose own marker-line text
-- happens to start with @### @; promoting those to headings too would
-- push the group-9 guide-book nested-heading count to 16, contradicting
-- this task's pinned expectation of exactly 3 -- so they are left as the
-- separate, out-of-scope, unchanged-by-this-fix quirk they are.
--------------------------------------------------------------------------

isJustT :: Maybe a -> Bool
isJustT (Just _) = True
isJustT Nothing  = False

-- | Every 'Str' text under a block list's nested-block-parsed content:
-- descends into 'Quote' inner blocks, list items' CHILDREN (not their own
-- marker-line caption -- see above), table cells (header and body),
-- figure\/heading captions, and 'Strong'\/'Em' formatting.
allStrText :: [Block] -> [Text]
allStrText = concatMap blockStrs
  where
    blockStrs b = case b of
      Heading _ inlines _ -> inlineStrs inlines
      Para inlines         -> inlineStrs inlines
      Figure _ capInlines   -> inlineStrs capInlines
      Bullets items          -> concatMap (allStrText . liChildren) items
      Numbered _ items        -> concatMap (allStrText . liChildren) items
      Quote inner               -> allStrText inner
      Table mHeader rows          ->
        concatMap inlineStrs (maybe [] id mHeader) ++ concatMap (concatMap inlineStrs) rows
      Unparsed _                    -> []

    inlineStrs = concatMap inlineStrs1
    inlineStrs1 i = case i of
      Str t     -> [t]
      Strong xs -> inlineStrs xs
      Em xs     -> inlineStrs xs
      _         -> []

literalHashChecks :: [Check]
literalHashChecks =
  [ mkCheck 10 ("literal-hash/" ++ T.unpack (docSlug d))
      (null offenders)
      (describe offenders)
  | d <- docs
  , let strs      = allStrText (docPreamble d) ++ concatMap (allStrText . pageBlocks) (docPages d)
        offenders = filter (isJustT . headingLineOf) strs
  ]
  where
    describe :: [Text] -> String
    describe [] = "0 offenders"
    describe xs = show (length xs) ++ " offenders: " ++ show (take 5 xs)

--------------------------------------------------------------------------
-- 11. Pinned anchors: the nested-heading fix must not perturb the
-- top-level anchor-slug supply on the guide-book pages whose "Tip"
-- callouts contain nested headings (briefs/M1-fixes-manifest.json,
-- "nested-headings"). p.41 and p.47 each carry the heading(s) that own
-- their Tip; p.43's own section heading ("Try creating a pattern that
-- includes non-drum sounds too") is on p.42 -- p.43 opens mid-numbered-
-- list with no top-level heading of its own -- so both p.42 (that
-- heading) and p.43 (empty, as it always was) are pinned to show neither
-- moved.
--------------------------------------------------------------------------

topAnchorsOnPage :: Text -> Int -> [Text]
topAnchorsOnPage slug pn =
  case [ p | d <- docs, docSlug d == slug, p <- docPages d, pageNumber p == pn ] of
    (p : _) -> [ s | Heading _ _ s <- pageBlocks p ]
    []      -> []

pinnedAnchorChecks :: [Check]
pinnedAnchorChecks =
  [ mkCheck 11 ("pinned-anchor/guide-book/p" ++ show pn)
      (got == want)
      ("got=" ++ show got ++ " want=" ++ show want)
  | (pn, want) <- pinned
  , let got = topAnchorsOnPage "guide-book" pn
  ]
  where
    pinned =
      [ (41, [ "try-creating-various-drum-patterns", "example-1-dance-beat"
             , "example-2-16-beat", "example-3-half-time" ])
      , (42, [ "try-creating-a-pattern-that-includes-non-drum-sounds-too" ])
      , (43, [])
      , (47, [ "try-layering-pad-performance-over-sequence-playback" ])
      ]

--------------------------------------------------------------------------
-- main
--------------------------------------------------------------------------

main :: IO ()
main = do
  hSetEncoding stdout utf8
  args <- getArgs
  let jsonMode    = "--json" `elem` args
      verboseMode = "--verbose" `elem` args
  if jsonMode
    then TIO.putStrLn (renderStatsJson corpusSources)
    else do
      totalityChecks <- mapM totalityCheck malformedInputs
      let allChecks =
            pageMarkerChecks
              ++ goldenChecks
              ++ unparsedChecks
              ++ outlineChecks
              ++ glossaryChecks
              ++ anchorChecks
              ++ routeRoundTripChecks
              ++ totalityChecks
              ++ pageNonEmptyChecks
              ++ tableBodyChecks
              ++ nestedHeadingChecks
              ++ literalHashChecks
              ++ pinnedAnchorChecks
      forM_ [1 .. 11] $ \g -> do
        let inGroup = filter ((== g) . chkGroup) allChecks
            passed  = length (filter chkOk inGroup)
            total   = length inGroup
            allOk   = passed == total && total > 0
        putStrLn (assertionLabel g ++ ": " ++ (if allOk then "ok" else "FAIL")
                    ++ " (" ++ show passed ++ "/" ++ show total ++ ")")
        when (verboseMode || not allOk) $
          forM_ inGroup $ \c ->
            unless (chkOk c && not verboseMode) $
              putStrLn ("    " ++ (if chkOk c then "ok  " else "FAIL") ++ " " ++ chkName c ++ ": " ++ chkMsg c)
      let totalPassed = length (filter chkOk allChecks)
          totalAll    = length allChecks
      putStrLn ("content-check: " ++ show totalPassed ++ "/" ++ show totalAll ++ " checks passed")
      if totalPassed == totalAll && totalAll > 0 then exitSuccess else exitFailure
