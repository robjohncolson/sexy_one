{-# LANGUAGE OverloadedStrings #-}

-- | @exe:content-check@ -- a wasm32-wasi COMMAND module (no reactor flags;
-- those live only in @exe:app@'s cabal stanza), run on the host via
-- @wasm-run.mjs@. Real Haskell unit + corpus tests, no browser.
--
-- Usage:
--   content-check              run every assertion, print a summary line
--                               per assertion group (and every failing
--                               sub-check), exit 0 only if all passed
--   content-check --verbose    additionally print every individual sub-check
--   content-check --json       print ONLY the stats JSON (what
--                               scripts\/check-site.sh consumes) -- the
--                               'unparsed' field here is MODEL-derived (see
--                               A1), unlike the app's cheap raw-scan copy
--   content-check --census     print ONLY the per-document model census
--                               (NEW2\/A2) -- top-level Headings, Figures,
--                               Tables, Numbered\/Bullets blocks and their
--                               items, PageRef\/Placeholder inlines -- one
--                               line per document, for a human to read
--   content-check --dump-source <slug>
--                               write the EXACT embedded UTF-8 bytes of
--                               that document to stdout and nothing else
--                               (no banner, no trailing newline of its
--                               own) -- <slug> is one of guide-book,
--                               startup-guide, midi, oss, glossary. Any
--                               other slug: readable message on stderr,
--                               exit 1. NEW4's contract, consumed by
--                               scripts\/check-site.sh (task
--                               'harness-completeness') to diff against
--                               @translations\/\<slug\>.md@ and catch a
--                               stale-build-with-preserved-structure edit
--                               a purely structural fingerprint would miss.
module Main (main) where

import           Control.Exception     (SomeException, evaluate, try)
import           Control.Monad         (forM_, unless, when)
import           Data.List             (nub)
import qualified Data.Map.Strict       as Map
import           Data.Text             (Text)
import qualified Data.Text             as T
import qualified Data.Text.IO          as TIO
import           System.Environment    (getArgs)
import           System.Exit           (ExitCode (ExitFailure), exitFailure, exitSuccess, exitWith)
import           System.IO             (hPutStrLn, hSetEncoding, hSetNewlineMode, noNewlineTranslation,
                                         stderr, stdout, utf8)

import           SXC1.Content.Corpus   (corpusSources, docs, glossarySource)
import           SXC1.Content.Markdown (LineShape (..), classifyLine, countStrictTableSeparators,
                                         dedupeSlugs, headingLineOf, mkDoc, orderedItemOf,
                                         parseBlocksEngineWith)
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
assertionLabel 12 = "12. titled-step headings inside list items, per page (pp. 50-54)"
assertionLabel 13 = "13. A1: Unparsed fallback is reachable and terminates (fixture)"
assertionLabel 14 = "14. NEW1: subsection ownership follows source order, not page range"
assertionLabel 15 = "15. NEW2/A2: model census over the parsed blocks/inlines"
assertionLabel 16 = "16. NEW2: anchorChecks vacuity guard (permanent negative-control demo)"
assertionLabel 17 = "17. NEW3: dedupeSlugs reserves every emitted name"
assertionLabel 18 = "18. NEW8: route classifications (zero/out-of-range/overflow/malformed/unknown)"
assertionLabel 19 = "19. A6: anchor-supply invariant fixture (nested heading before a duplicate)"
assertionLabel 20 = "20. A7 guard: ordered-list numbers consecutive-ascending; fragment census pinned"
assertionLabel 21 = "21. NEW11: OrderedShape/BulletShape dishonest-classifier fixtures (list-branch progress evidence)"
assertionLabel 22 = "22. NEW12: groupsOk vacuity guard (permanent negative-control demo)"
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
    -- | A1: model-derived, not 'buildStats' (the app's cheap raw-scan
    -- copy) -- every field but 'unparsed' is identical either way (they
    -- are inherently raw-text metrics), but this makes the
    -- "golden/*/unparsed" sub-check below a real assertion over the
    -- parsed model, belt-and-suspenders with group 3's own direct model
    -- traversal.
    allStats = buildStatsFromDocs docs corpusSources
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
--
-- CORRECTED (A1, round 3): this group always DID force the real parsed
-- model directly (@Unparsed t <- flattenBlocks (...)@ below), so it was
-- never itself vacuous -- but the producer it was guarding
-- ('SXC1.Content.Markdown.parseBlocksEngine') never actually constructed
-- an 'Unparsed' block on ANY input, so this assertion was checking a
-- real corpus against a constructor that could not fire: it was
-- incapable of being red no matter what the corpus contained, which is
-- exactly the "checks whose failing case was never constructed" pattern
-- the round-3 gate was about. 'parseBlocksEngine' now really can produce
-- 'Unparsed' (see its Haddock and 'SXC1.Content.Markdown.parseBlocksEngineWith'
-- 's test seam for how reachability is engineered and demonstrated),
-- so THIS group is now the meaningful zero-Unparsed guarantee over the
-- real corpus -- not the JSON 'stUnparsed' field (which the app computes
-- cheaply from raw text and can only ever read 0 for real content; see
-- "SXC1.Content.Stats").
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

-- | NEW2\/A2: the old version was @all (not . T.null) slugs && length
-- slugs == length (nub slugs)@ -- both 'all' and 'nub' accept @[]@
-- vacuously, so a document with ZERO top-level headings (e.g. every
-- 'Heading' silently swallowed by a broken producer, Codex's own
-- worked example) would still read \"ok\", because there was nothing to
-- find non-unique or non-empty. 'hasSlugs' below closes that: a document
-- is required to have at least one top-level anchor slug, which is true
-- of all four real documents (their golden @headings@ counts are all
-- nonzero) and is exactly what a producer regression like Codex's
-- worked example (deleting the @Para [Placeholder] -> Figure@
-- promotion, or -- for this specific check -- silently dropping
-- headings) would now actually turn red. See NEGATIVE CONTROL 3(iii)
-- ('anchorVacuityGuardChecks' below) for a permanent, self-verifying
-- demonstration that the OLD predicate passes on @[]@ and this one does
-- not.
anchorChecks :: [Check]
anchorChecks =
  [ mkCheck 6 ("anchors/" ++ T.unpack (docSlug d))
      (hasSlugsOk && nonEmpty && unique)
      ("count=" ++ show (length slugs) ++ " unique=" ++ show (length (nub slugs)))
  | d <- docs
  , let slugs      = [ s | p <- docPages d, Heading _ _ s <- pageBlocks p ]
        hasSlugsOk = anchorChecksSlugsOk slugs
        nonEmpty   = all (not . T.null) slugs
        unique     = length slugs == length (nub slugs)
  ]

-- | The NEW (fixed) predicate's \"has at least one slug\" half, factored
-- out so 'anchorVacuityGuardChecks' can compare it against the OLD
-- (vacuous-on-@[]@) predicate on the exact same inputs.
anchorChecksSlugsOk :: [Text] -> Bool
anchorChecksSlugsOk slugs = not (null slugs)

-- | The OLD (pre-round-3) predicate, kept ONLY here for NEGATIVE CONTROL
-- 3(iii)'s comparison -- never used by 'anchorChecks' itself.
anchorChecksOldPredicate :: [Text] -> Bool
anchorChecksOldPredicate slugs = all (not . T.null) slugs && length slugs == length (nub slugs)

anchorChecksNewPredicate :: [Text] -> Bool
anchorChecksNewPredicate slugs = anchorChecksSlugsOk slugs && all (not . T.null) slugs
                                    && length slugs == length (nub slugs)

-- | NEGATIVE CONTROL 3(iii): \"empty the top-level heading list for one
-- document\" -- simulated directly (no producer sabotage needed) by
-- calling both predicates on @[]@, exactly what a document with zero
-- top-level headings would feed 'anchorChecks'. This is a PERMANENT,
-- self-verifying demonstration: it fails loudly (via group 16) if either
-- half of the claim it makes stops being true.
anchorVacuityGuardChecks :: [Check]
anchorVacuityGuardChecks =
  [ mkCheck 16 "anchor-vacuity-guard/old-predicate-passes-on-empty"
      (anchorChecksOldPredicate [] == True)
      ("old predicate on [] = " ++ show (anchorChecksOldPredicate []) ++ " (want True -- this is the bug)")
  , mkCheck 16 "anchor-vacuity-guard/new-predicate-fails-on-empty"
      (anchorChecksNewPredicate [] == False)
      ("new predicate on [] = " ++ show (anchorChecksNewPredicate []) ++ " (want False -- this is the fix)")
  , mkCheck 16 "anchor-vacuity-guard/new-predicate-agrees-on-real-corpus"
      (and [ anchorChecksNewPredicate slugs == anchorChecksOldPredicate slugs
           | d <- docs
           , let slugs = [ s | p <- docPages d, Heading _ _ s <- pageBlocks p ]
           ])
      "old and new predicates must still agree on every real (nonempty) document"
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

-- | guide-book carries 16 nested headings: the 3 pre-existing blockquote
-- "Tip"-callout headings (pp. 41/43/47) plus the 13 list-item "titled
-- step" headings pp. 50-54's @N. ### <title>@ items now parse to
-- (briefs/M1-fixes-2-manifest.json, task "titled-steps"). The other three
-- documents have none of either shape.
nestedHeadingChecks :: [Check]
nestedHeadingChecks =
  [ mkCheck 9 ("nested-headings/" ++ T.unpack (docSlug d))
      (got == want)
      ("nested Heading count=" ++ show got ++ " (want " ++ show want ++ ")")
  | d <- docs
  , let want = if docSlug d == "guide-book" then 16 else 0
        got  = nestedHeadingCount (docPreamble d)
                 + sum [ nestedHeadingCount (pageBlocks p) | p <- docPages d ]
  ]

--------------------------------------------------------------------------
-- 10. General literal-hash guard: no 'Str' inline ANYWHERE in the corpus
-- -- every inline position -- may begin with a literal heading marker
-- (one to six '#' characters then a space). This covers 'Quote' bodies
-- and list-item CHILDREN (recursively; the places 4.5 recursively
-- re-parses raw lines as blocks), a list item's own marker-line caption
-- ('liContent'), top-level Heading\/Para\/Figure captions, and table
-- cells (header and body). This is the general form of group 9's
-- regression: it catches the whole class of "a heading line fell through
-- to plain text because it was nested" bug, not just specific known
-- lines, and reuses 'headingLineOf' so the predicate is exactly the one
-- that decides real headings, applied to inline text instead of a whole
-- source line.
--
-- 'liContent' used to be deliberately excluded here: 4.5's
-- ordered\/bullet-item rule captures @(.*)$@ after the marker directly as
-- that item's @[Inline]@ content, and until briefs/M1-fixes-2-manifest.json
-- task "titled-steps", a heading-shaped @(.*)$@ (guide-book pp. 50-54's
-- 13 @N. ### <title>@ "titled steps") landed there as literal text
-- instead of being recognised. Now that 'parseList' (in
-- "SXC1.Content.Markdown") checks 'liContent'\'s own text for
-- 'headingLineOf' and, when it matches, promotes it to a 'Heading' at the
-- head of 'liChildren' (leaving 'liContent' empty) instead, that
-- exemption is no longer needed: after the fix, no inline position in the
-- corpus should ever start with a literal heading marker, so the guard
-- now covers every position with no exclusions.
--------------------------------------------------------------------------

isJustT :: Maybe a -> Bool
isJustT (Just _) = True
isJustT Nothing  = False

-- | Every 'Str' text anywhere in a block list: descends into 'Quote' inner
-- blocks, list items' own marker-line caption ('liContent') AND their
-- CHILDREN ('liChildren'), table cells (header and body), figure\/heading
-- captions, and 'Strong'\/'Em' formatting -- i.e. every inline position in
-- the corpus.
allStrText :: [Block] -> [Text]
allStrText = concatMap blockStrs
  where
    blockStrs b = case b of
      Heading _ inlines _ -> inlineStrs inlines
      Para inlines         -> inlineStrs inlines
      Figure _ capInlines   -> inlineStrs capInlines
      Bullets items          -> concatMap itemStrs items
      Numbered _ items        -> concatMap itemStrs items
      Quote inner               -> allStrText inner
      Table mHeader rows          ->
        concatMap inlineStrs (maybe [] id mHeader) ++ concatMap (concatMap inlineStrs) rows
      Unparsed _                    -> []

    itemStrs (ListItem content children) = inlineStrs content ++ allStrText children

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
-- 12. Titled steps: guide-book pp. 50-54's 13 "N. ### <title>" list items
-- (briefs/M1-fixes-2-manifest.json, task "titled-steps") must each parse
-- to a 'Heading' block at the head of their list item's 'liChildren',
-- with the printed manual's own per-page count of titled steps preserved:
-- p.50 -> 3, p.51 -> 1, p.52 -> 3, p.53 -> 1, p.54 -> 5.
--------------------------------------------------------------------------

-- | Count list items (anywhere among the given top-level blocks, including
-- inside a 'Quote' or a nested list, recursively -- though the corpus has
-- no such nesting for titled steps) whose own first child is a 'Heading'.
titledStepHeadingCount :: [Block] -> Int
titledStepHeadingCount = sum . map oneBlock
  where
    oneBlock b = case b of
      Quote inner     -> titledStepHeadingCount inner
      Bullets items    -> sum (map oneItem items)
      Numbered _ items  -> sum (map oneItem items)
      _                    -> 0

    oneItem (ListItem _ children) =
      headHeading children + titledStepHeadingCount children

    headHeading (Heading {} : _) = 1
    headHeading _                 = 0

titledStepChecks :: [Check]
titledStepChecks =
  [ mkCheck 12 ("titled-step/guide-book/p" ++ show pn)
      (got == want)
      ("titled-step Heading count=" ++ show got ++ " (want " ++ show want ++ ")")
  | (pn, want) <- expected
  , let got = case [ p | d <- docs, docSlug d == "guide-book", p <- docPages d, pageNumber p == pn ] of
                (p : _) -> titledStepHeadingCount (pageBlocks p)
                []      -> -1
  ]
  where
    expected = [(50, 3), (51, 1), (52, 3), (53, 1), (54, 5)]

--------------------------------------------------------------------------
-- 13. A1: the 'Unparsed' fallback is REACHABLE and the engine TERMINATES
-- on the input that reaches it -- see
-- "SXC1.Content.Markdown".'SXC1.Content.Markdown.parseBlocksEngineWith'
-- for the full mechanism. The paragraph rule is a genuine catch-all for
-- any REAL corpus line (see its Haddock), so no fixture built from real
-- text could ever reach 'Unparsed' through 'parseBlocksEngine' itself --
-- that unreachability is exactly what made plan \167 8.4's promised
-- negative control undemonstrable pre-round-3. This fixture instead
-- drives the classifier-injecting variant with a classifier that behaves
-- exactly like the real one EXCEPT for one specific line, which it
-- DECLINES (maps to 'DeclinedShape', a shape 'classifyLine' itself never
-- produces) -- \"a line the classifier declines\", A1 1c's own phrase.
--------------------------------------------------------------------------

-- | The one line 'a1DecliningClassifier' refuses to name -- ordinary
-- text that 'classifyLine' would otherwise call 'ParaShape' (it is not
-- blank, not a heading\/table\/quote\/list-item line).
a1PoisonLine :: Text
a1PoisonLine = "This line is ordinary text that the fixture's classifier declines to classify."

-- | Behaves exactly like the real 'classifyLine' for every line except
-- 'a1PoisonLine', for which it reports 'DeclinedShape'. This is the test
-- seam A1 1c calls for in miniature: production passes 'classifyLine'
-- unchanged (via 'SXC1.Content.Markdown.parseBlocksEngine'); only a test
-- passes a variant like this one.
a1DecliningClassifier :: Text -> LineShape
a1DecliningClassifier l
  | l == a1PoisonLine = DeclinedShape
  | otherwise         = classifyLine l

-- | An ordinary paragraph line, then the declined line, then another
-- ordinary paragraph line -- so a correct result must be three blocks,
-- with the fallback's 'Unparsed' sandwiched between two real 'Para's,
-- and 'go' must have recursed strictly on a shrinking tail to produce
-- that finite three-element list at all (see the Haddock on
-- 'SXC1.Content.Markdown.parseBlocksEngineWith' for why 'span' consuming
-- nothing on the declined line is what makes this fixture exercise the
-- 1a structural-progress branch instead of any of the six named rules).
a1FixtureInput :: [Text]
a1FixtureInput =
  [ "An ordinary paragraph line before the declined one."
  , a1PoisonLine
  , "An ordinary paragraph line after the declined one."
  ]

a1FixtureBlocks :: [Block]
a1FixtureBlocks = fst (parseBlocksEngineWith a1DecliningClassifier 1 False [] a1FixtureInput)

a1Checks :: [Check]
a1Checks =
  [ mkCheck 13 "a1-fixture/terminates-with-three-blocks"
      (length a1FixtureBlocks == 3)
      ("blocks=" ++ show (length a1FixtureBlocks) ++ " (want 3 -- proves 'go' terminated on the finite input)")
  , mkCheck 13 "a1-fixture/produces-real-Unparsed-for-the-declined-line"
      (case a1FixtureBlocks of
         [Para _, Unparsed t, Para _] -> t == a1PoisonLine
         _                             -> False)
      ("blocks=" ++ show a1FixtureBlocks)
  , mkCheck 13 "a1-fixture/real-classifier-never-declines-any-corpus-line"
      -- Belt-and-suspenders: confirm 'classifyLine' (the REAL, production
      -- classifier) never itself returns 'DeclinedShape' for any actual
      -- corpus line -- i.e. reachability genuinely depends on the
      -- fixture's injected classifier, not on some corpus line that
      -- happens to be unclassifiable today.
      (null [ () | (_, raw) <- corpusSources, l <- T.lines raw, classifyLine l == DeclinedShape ])
      "classifyLine must never produce DeclinedShape for real corpus text"
  ]

--------------------------------------------------------------------------
-- 14. NEW1: subsections attach to the preceding SECTION EVENT in source
-- order, not to a (sometimes-corrupted) page range -- see
-- "SXC1.Content.Outline".'SXC1.Content.Outline.attachSubsInOrder'.
--------------------------------------------------------------------------

-- | (a) secEndPage >= secPage for EVERY section of EVERY document -- the
-- invariant the fix establishes; the old page-range attachment could
-- (and, on 6 real pages, did) violate it.
secEndPageInvariantChecks :: [Check]
secEndPageInvariantChecks =
  [ mkCheck 14 ("outline-invariant/" ++ T.unpack slug)
      (all (\s -> secEndPage s >= secPage s) secs)
      (show [ (secPage s, secEndPage s) | s <- secs, secEndPage s < secPage s ] ++ " violate secEndPage>=secPage")
  | (slug, raw) <- corpusSources
  , let secs = outSections (buildOutline raw)
  ]

-- | (b) exact representative ownership on the four pages NEW1 named:
-- startup-guide p.10 and p.14, midi p.2, oss p.11. Filtered to subs
-- landing ON that same page specifically (not the section's whole span),
-- since that is exactly what the bug misattributed.
subsOnPage :: Text -> Int -> Text -> [(Int, Text)]
subsOnPage slug pn title =
  case lookup slug corpusSources of
    Nothing  -> []
    Just raw ->
      case [ s | s <- outSections (buildOutline raw), secPage s == pn, secTitle s == title ] of
        (s : _) -> [ sub | sub@(sp, _) <- secSubs s, sp == pn ]
        []      -> []

ownershipChecks :: [Check]
ownershipChecks =
  [ mkCheck 14 name (got == want) ("got=" ++ show got ++ " want=" ++ show want)
  | (name, slug, pn, title, want) <-
      [ ( "ownership/startup-guide/p10/Try-applying-an-effect", "startup-guide", 10
        , "Try applying an effect"
        , [ (10, "Applying an effect"), (10, "How to use the FX1/FX2 buttons") ] )
      , ( "ownership/startup-guide/p10/Try-sampling", "startup-guide", 10
        , "Try sampling"
        , [ (10, "Sampling") ] )
      , ( "ownership/startup-guide/p14/Operating-precautions", "startup-guide", 14
        , "Operating precautions"
        , [ (14, "Operating environment"), (14, "Make backup copies of important data.")
          , (14, "Auto Power Off") ] )
      , ( "ownership/startup-guide/p14/Copyright-precaution", "startup-guide", 14
        , "Copyright precaution", [] )
      , ( "ownership/startup-guide/p14/Trademarks", "startup-guide", 14
        , "Trademarks", [] )
      , ( "ownership/midi/p2/2-Product-information", "midi", 2, "2. Product information", [] )
      , ( "ownership/midi/p2/3-MIDI-implementation-chart", "midi", 2, "3. MIDI implementation chart", [] )
      , ( "ownership/oss/p11/MIT", "oss", 11, "MIT", [] )
      , ( "ownership/oss/p11/MICROSOFT-AZURE-RTOS", "oss", 11, "MICROSOFT AZURE RTOS", [] )
      ]
  , let got = subsOnPage slug pn title
  ]

-- | (c) the golden section\/subsection TOTALS -- 29\/78, 21\/27, 6\/1,
-- 5\/0 -- are UNMOVED by the ownership fix (the bug preserved totals
-- while corrupting ownership; group 4's existing checks already assert
-- these exact numbers, so this group deliberately does not duplicate
-- them -- see @outlineChecks@ above).

--------------------------------------------------------------------------
-- 15. NEW2\/A2: the MODEL CENSUS. Every 'DocStats' field used to be
-- raw-text-derived -- chars\/lines\/pages are 'Text' ops, headings\/
-- figures\/tables are raw scans, sections\/subsections\/parts come from
-- 'buildOutline' (itself a raw line scan) -- so "Haskell vs Python" was
-- two raw scanners agreeing with each other, and the DOM was a third
-- copy of the FIRST. The parsed 'SXC1.Content.Types.Doc' model was never
-- on any side of the three-way agreement; Codex's worked regression
-- (delete the @Para [Placeholder] -> Figure@ promotion) stays green
-- under every existing check. This group adds a genuine, ADDITIONAL
-- census computed by walking the real parsed blocks\/inlines -- it never
-- replaces or loosens a raw golden.
--
-- CENSUS VALUES ARE DERIVED, NOT COPIED from @briefs\/M1-plan.md@ \167 3's
-- \"... of which block-level 186\/35\/4\/0\" row -- per the round-3 triage,
-- that row is suspect. See this task's report for the derived numbers,
-- the justification, and where \167 3 is simply wrong. The ONE census
-- dimension pinned as a HARD target against the existing raw golden is
-- Table blocks: a separator row and a real 'Table' block genuinely
-- coincide in this grammar (every table has exactly one separator row,
-- and 'isTableSeparator'\/'countLooseTableLines' agree on every real
-- table), so the census must read EXACTLY 20\/5\/7\/0 -- that is what
-- kills A2 (@stTables = countLooseTableLines raw@ was never checked
-- against a real 'Table' block count until now).
--------------------------------------------------------------------------

data Census = Census
  { cnsHeadingsTop    :: !Int  -- ^ top-level 'Heading' blocks only (not nested in Quote/list)
  , cnsFigures        :: !Int  -- ^ 'Figure' blocks, anywhere in the model
  , cnsTables         :: !Int  -- ^ 'Table' blocks, anywhere in the model
  , cnsNumberedBlocks :: !Int  -- ^ 'Numbered' blocks, anywhere in the model
  , cnsNumberedItems  :: !Int  -- ^ total 'ListItem's across all 'Numbered' blocks
  , cnsBulletsBlocks  :: !Int  -- ^ 'Bullets' blocks, anywhere in the model
  , cnsBulletsItems   :: !Int  -- ^ total 'ListItem's across all 'Bullets' blocks
  , cnsPageRefs       :: !Int  -- ^ 'PageRef' inlines, anywhere (incl. inside Strong/Em)
  , cnsPlaceholders   :: !Int  -- ^ 'Placeholder' inlines, anywhere (incl. inside Strong/Em)
  } deriving (Eq, Show)

-- | Every block in a document, top-level AND nested (inside 'Quote' or a
-- list item's children) -- reuses 'flattenBlocks' (already the module's
-- one recursive-descent helper, shared with groups 8-10).
docAllBlocks :: Doc -> [Block]
docAllBlocks d = flattenBlocks (docPreamble d) ++ concatMap (flattenBlocks . pageBlocks) (docPages d)

-- | TOP-LEVEL blocks only -- what 'cnsHeadingsTop' counts over, matching
-- the codebase's existing top-level\/nested distinction (group 6's
-- anchor slugs, group 11's pinned anchors, group 9's nested-heading
-- count all draw the same line).
docTopBlocks :: Doc -> [Block]
docTopBlocks d = docPreamble d ++ concatMap pageBlocks (docPages d)

-- | Every inline, anywhere in a block list, with 'Strong'\/'Em' expanded
-- so a 'PageRef' or 'Placeholder' nested inside bold\/italic text is
-- still counted (parallel structure to 'allStrText' above, which instead
-- keeps only 'Str').
allInlinesFlat :: [Block] -> [Inline]
allInlinesFlat = concatMap (expand . blockInlines)
  where
    blockInlines b = case b of
      Heading _ inlines _  -> inlines
      Para inlines          -> inlines
      Figure _ capInlines    -> capInlines
      Bullets items           -> concatMap itemInlines items
      Numbered _ items         -> concatMap itemInlines items
      Quote inner                -> allInlinesFlat inner
      Table mHeader rows           -> concat (maybe [] id mHeader) ++ concatMap concat rows
      Unparsed _                     -> []
    itemInlines (ListItem content children) = content ++ allInlinesFlat children
    expand = concatMap oneInline
    oneInline i = case i of
      Strong xs -> expand xs
      Em xs     -> expand xs
      other     -> [other]

censusOf :: Doc -> Census
censusOf d = Census
  { cnsHeadingsTop    = length [ () | Heading {} <- docTopBlocks d ]
  , cnsFigures        = length [ () | Figure {} <- allBlocks ]
  , cnsTables         = length [ () | Table {} <- allBlocks ]
  , cnsNumberedBlocks = length numbereds
  , cnsNumberedItems  = sum [ length items | Numbered _ items <- numbereds ]
  , cnsBulletsBlocks  = length bulletss
  , cnsBulletsItems   = sum [ length items | Bullets items <- bulletss ]
  , cnsPageRefs       = length [ () | PageRef {} <- allInlines ]
  , cnsPlaceholders   = length [ () | Placeholder {} <- allInlines ]
  }
  where
    allBlocks  = docAllBlocks d
    numbereds  = [ b | b@(Numbered _ _) <- allBlocks ]
    bulletss   = [ b | b@(Bullets _) <- allBlocks ]
    -- 'allInlinesFlat' recurses into 'Quote'\/list-item children ON ITS
    -- OWN (see its definition), so calling it on the TOP-LEVEL blocks
    -- alone already reaches every inline in the whole document -- no
    -- need to also traverse 'allBlocks' here.
    allInlines = allInlinesFlat (docTopBlocks d)

-- | Print the derived census, one line per document -- @content-check
-- --census@'s entire job, and exactly what this task's report pastes.
renderCensus :: [(Text, Census)] -> Text
renderCensus cs = T.unlines
  [ slug <> ": headingsTop=" <> sh cnsHeadingsTop
         <> " figures="      <> sh cnsFigures
         <> " tables="       <> sh cnsTables
         <> " numberedBlocks=" <> sh cnsNumberedBlocks
         <> " numberedItems="  <> sh cnsNumberedItems
         <> " bulletsBlocks="  <> sh cnsBulletsBlocks
         <> " bulletsItems="   <> sh cnsBulletsItems
         <> " pageRefs="       <> sh cnsPageRefs
         <> " placeholders="   <> sh cnsPlaceholders
  | (slug, c) <- cs
  , let sh f = T.pack (show (f c))
  ]

corpusCensus :: [(Text, Census)]
corpusCensus = [ (docSlug d, censusOf d) | d <- docs ]

-- | Golden census values, DERIVED by running @content-check --census@
-- against the real parsed corpus and pinning exactly what it printed
-- (pasted verbatim in this task's report, together with the
-- justification below and the plan \167 3 / triage discrepancies).
--
-- FIELD ORDER: headingsTop, figures, tables, numberedBlocks,
-- numberedItems, bulletsBlocks, bulletsItems, pageRefs, placeholders.
--
-- TWO CONTRADICTIONS WITH THE ROUND-3 TRIAGE, both explained and both
-- cross-checked below by an INDEPENDENT raw-text computation (not just
-- asserted):
--
-- 1. @headingsTop@ is the raw @headings@ golden MINUS ONE for every
--    document (187\/50\/7\/5 vs 188\/51\/8\/6) -- NOT because of a bug,
--    but because 'countHeadingLines' (the raw golden) scans the WHOLE
--    file including the document's OWN @# Title@ line before
--    @\<!-- page 1 --\>@, while 'mkDoc' \/ 'extractTitleAndRest' pulls
--    that line out as 'SXC1.Content.Types.docTitle' and never leaves it
--    behind as a 'Heading' block. See @census\/*\/headingsTop-is-raw-minus-title@
--    below.
--
-- 2. @tables@ (Table BLOCKS) is 20\/4\/6\/0, NOT the triage's predicted
--    \"MUST come out 20\/5\/7\/0\" -- startup-guide and midi are each
--    ONE LOWER than the raw @tables@ golden. This is not a bug either:
--    both documents have exactly one table with an ALL-BLANK header row
--    (@| | |@ -- see midi.md:42 and startup-guide.md:45), which
--    "SXC1.Content.Stats"'s own pre-existing note on the @tables@ field
--    already documents as "syntactically their own separator-shaped
--    line even though semantically they are the header of the very next
--    real table, not a table of their own". The raw golden
--    ('countLooseTableLines') counts that blank line as a SECOND loose
--    separator-shaped row (it has no dash requirement), so it over-counts
--    real tables by exactly one per blank-header table; guide-book and
--    oss have none, so they DO match the raw golden exactly (20 and 0).
--    'SXC1.Content.Markdown.countStrictTableSeparators' (dash required,
--    same predicate 'parseTable' itself uses to find the header/body
--    boundary) does NOT have this artifact and equals the real Table-
--    block census exactly for all four documents -- see
--    @census\/*\/tables-match-strict-separator-count@ below, which is
--    the actual hard, always-true cross-check; the loose-golden
--    comparison is intentionally NOT asserted for startup-guide\/midi
--    because it would be asserting a false equality.
censusGoldenTable :: [(Text, Census)]
censusGoldenTable =
  [ ("guide-book",    Census 187 178 20 45 53 105 322 57 12)
  , ("startup-guide", Census  50  35  4 20 28  26  87  6  8)
  , ("midi",           Census   7   4  6  4  4   0   0  0  0)
  , ("oss",            Census   5   0  0 34 34  12  17  0  0)
  ]

censusChecks :: [Check]
censusChecks = concat
  [ [ mkCheck 15 ("census/" ++ T.unpack slug ++ "/headingsTop")
        (cnsHeadingsTop got == cnsHeadingsTop want) (fld cnsHeadingsTop)
    , mkCheck 15 ("census/" ++ T.unpack slug ++ "/figures")
        (cnsFigures got == cnsFigures want) (fld cnsFigures)
    , mkCheck 15 ("census/" ++ T.unpack slug ++ "/tables")
        (cnsTables got == cnsTables want) (fld cnsTables)
    , mkCheck 15 ("census/" ++ T.unpack slug ++ "/numberedBlocks")
        (cnsNumberedBlocks got == cnsNumberedBlocks want) (fld cnsNumberedBlocks)
    , mkCheck 15 ("census/" ++ T.unpack slug ++ "/numberedItems")
        (cnsNumberedItems got == cnsNumberedItems want) (fld cnsNumberedItems)
    , mkCheck 15 ("census/" ++ T.unpack slug ++ "/bulletsBlocks")
        (cnsBulletsBlocks got == cnsBulletsBlocks want) (fld cnsBulletsBlocks)
    , mkCheck 15 ("census/" ++ T.unpack slug ++ "/bulletsItems")
        (cnsBulletsItems got == cnsBulletsItems want) (fld cnsBulletsItems)
    , mkCheck 15 ("census/" ++ T.unpack slug ++ "/pageRefs")
        (cnsPageRefs got == cnsPageRefs want) (fld cnsPageRefs)
    , mkCheck 15 ("census/" ++ T.unpack slug ++ "/placeholders")
        (cnsPlaceholders got == cnsPlaceholders want) (fld cnsPlaceholders)
    ]
  | (slug, want) <- censusGoldenTable
  , let got = maybe (Census (-1) (-1) (-1) (-1) (-1) (-1) (-1) (-1) (-1)) id (lookup slug corpusCensus)
        fld f = show (f got) ++ " (want " ++ show (f want) ++ ")"
  ]

-- | The census dimensions that genuinely coincide with an existing raw
-- golden or with another cheap raw-text metric, cross-checked
-- INDEPENDENTLY of the pinned 'censusGoldenTable' numbers above (i.e.
-- these would catch a mistake in that table too, not just a producer
-- regression):
--
--  * headingsTop = raw headings golden - 1 (the document's own title
--    line, present in the raw scan, absent from the parsed model) --
--    true for all four documents;
--  * tables (Table blocks) = 'countStrictTableSeparators' (dash-required
--    raw scan) EXACTLY, for all four documents -- see the discussion
--    above for why the LOOSE golden does not hold this exactly;
--  * figures (Figure blocks) + placeholders (residual Placeholder
--    inlines) = the raw 'figures' golden EXACTLY, for all four documents
--    -- every @*[...]*@ occurrence ends up as EITHER a promoted 'Figure'
--    block OR a residual inline 'Placeholder', never both, never
--    neither. This is what actually kills A2\/NEW2's Codex regression
--    (delete the promotion -> figures drops to 0 while placeholders
--    jumps by the same amount the raw golden does not move at all).
censusReconciliationChecks :: [Check]
censusReconciliationChecks = concat
  [ [ mkCheck 15 ("census/" ++ T.unpack slug ++ "/headingsTop-is-raw-minus-title")
        (cnsHeadingsTop c == gHeadings g - 1)
        (show (cnsHeadingsTop c) ++ " (want raw headings - 1 = " ++ show (gHeadings g - 1) ++ ")")
    , mkCheck 15 ("census/" ++ T.unpack slug ++ "/tables-match-strict-separator-count")
        (cnsTables c == countStrictTableSeparators raw)
        (show (cnsTables c) ++ " (want countStrictTableSeparators = " ++ show (countStrictTableSeparators raw) ++ ")")
    , mkCheck 15 ("census/" ++ T.unpack slug ++ "/figures-plus-placeholders-equals-raw-figures-golden")
        (cnsFigures c + cnsPlaceholders c == gFigures g)
        (show (cnsFigures c + cnsPlaceholders c) ++ " (want raw figures golden = " ++ show (gFigures g) ++ ")")
    ]
  | (slug, g) <- goldenTable
  , Just raw <- [lookup slug corpusSources]
  , Just c <- [lookup slug corpusCensus]
  ]

-- | Where the census DOES equal the loose raw @tables@ golden exactly
-- (guide-book, oss -- the two documents with no blank-header-row table):
-- assert that equality too, so the "genuinely coincide" case the triage
-- described is still checked field-for-field where it is actually true.
censusTablesMatchRawGoldenChecks :: [Check]
censusTablesMatchRawGoldenChecks =
  [ mkCheck 15 ("census/" ++ T.unpack slug ++ "/tables-match-raw-golden")
      (cnsTables c == gTables g)
      (show (cnsTables c) ++ " (raw golden wants " ++ show (gTables g) ++ ")")
  | (slug, g) <- goldenTable
  , slug `elem` (["guide-book", "oss"] :: [Text])
  , Just c <- [lookup slug corpusCensus]
  ]

--------------------------------------------------------------------------
-- 17. NEW3: 'dedupeSlugs' must reserve every emitted name, not just
-- count occurrences per original base -- see
-- "SXC1.Content.Markdown".'SXC1.Content.Markdown.dedupeSlugs'.
--------------------------------------------------------------------------

-- | The OLD (pre-round-3) algorithm, reproduced ONLY for this negative
-- control's before\/after comparison -- never used by production code.
oldDedupeSlugs :: [Text] -> [Text]
oldDedupeSlugs = go Map.empty
  where
    go _ [] = []
    go seen (s : rest) =
      let n  = Map.findWithDefault (0 :: Int) s seen
          s' = if n == 0 then s else s <> "-" <> T.pack (show (n + 1 :: Int))
      in s' : go (Map.insert s (n + 1) seen) rest

hasDuplicates :: Ord a => [a] -> Bool
hasDuplicates xs = length xs /= length (nub xs)

dedupeSlugsChecks :: [Check]
dedupeSlugsChecks = concat
  [ [ mkCheck 17 (name ++ "/old-algorithm-collides")
        (hasDuplicates (oldDedupeSlugs input))
        ("old " ++ show input ++ " -> " ++ show (oldDedupeSlugs input) ++ " (want a duplicate -- this is the bug)")
    , mkCheck 17 (name ++ "/new-algorithm-is-unique")
        (not (hasDuplicates (dedupeSlugs input)))
        ("new " ++ show input ++ " -> " ++ show (dedupeSlugs input) ++ " (want no duplicates -- this is the fix)")
    , mkCheck 17 (name ++ "/new-algorithm-preserves-count")
        (length (dedupeSlugs input) == length input)
        ("new produced " ++ show (length (dedupeSlugs input)) ++ " slugs for " ++ show (length input) ++ " inputs")
    ]
  | (name, input) <-
      [ ("dedup-adversarial/natural-suffix-collision", ["x", "x", "x-2"])
      , ("dedup-adversarial/heading-text-collision", ["foo", "foo", "foo-2"])
      , ("dedup-adversarial/double-collision", ["a", "a", "a-2", "a-2"])
      , ("dedup-adversarial/three-way", ["z", "z", "z", "z-2"])
      ]
  ]

--------------------------------------------------------------------------
-- 18. NEW8: route CLASSIFICATIONS (not just totality) for zero,
-- out-of-range, overflow-width, malformed-suffix, unknown-slug and the
-- exact reported overflow value 4294967297 -- see "SXC1.Route".
--------------------------------------------------------------------------

routeClassificationChecks :: [Check]
routeClassificationChecks =
  [ mkCheck 18 name (parseRoute input == want) (show (parseRoute input) ++ " (want " ++ show want ++ ")")
  | (name, input, want) <-
      [ ( "route-classify/zero", "#/m/guide-book/p/0"
        , RPage "guide-book" 0 False )
      , ( "route-classify/out-of-range", "#/m/guide-book/p/9999"
        , RPage "guide-book" 9999 False )
      , ( "route-classify/overflow-exact-4294967297", "#/m/guide-book/p/4294967297"
        , RNotFound "m/guide-book/p/4294967297" )
      , ( "route-classify/overflow-width-40-digits", "#/m/guide-book/p/" <> T.replicate 40 "9"
        , RNotFound ("m/guide-book/p/" <> T.replicate 40 "9") )
      , ( "route-classify/malformed-suffix", "#/m/guide-book/p/17x"
        , RNotFound "m/guide-book/p/17x" )
      , ( "route-classify/unknown-slug", "#/m/no-such-doc"
        , RManual "no-such-doc" )
      , ( "route-classify/unknown-slug-page", "#/m/no-such-doc/p/5"
        , RPage "no-such-doc" 5 False )
      ]
  ]

--------------------------------------------------------------------------
-- 19. A6: the anchor-supply invariant (nested headings never consume the
-- top-level anchor-slug supply) has no case in the real corpus that can
-- OBSERVE a violation -- on pp. 41\/43\/47 the nested heading is the LAST
-- heading on its page, so a sabotage making nested headings consume
-- slugs still passed 247\/247. This synthetic 'mkDoc' fixture places a
-- nested heading BEFORE a later top-level heading whose text duplicates
-- an earlier one, so a slug leak becomes directly observable.
--------------------------------------------------------------------------

a6FixtureRaw :: Text
a6FixtureRaw = T.unlines
  [ "# A6 Fixture Doc"
  , "<!-- page 1 -->"
  , "## Alpha"
  , ""
  , "> ### Nested Tip"
  , "> Some quoted content that a Tip callout would carry."
  , ""
  , "## Alpha"
  ]

a6FixtureDoc :: Doc
a6FixtureDoc = mkDoc "a6-fixture" a6FixtureRaw

a6FixtureTopBlocks :: [Block]
a6FixtureTopBlocks = case docPages a6FixtureDoc of
  (p : _) -> pageBlocks p
  []      -> []

a6FixtureTopSlugs :: [Text]
a6FixtureTopSlugs = [ s | Heading _ _ s <- a6FixtureTopBlocks ]

a6FixtureNestedSlug :: Maybe Text
a6FixtureNestedSlug = case a6FixtureTopBlocks of
  (_ : Quote (Heading _ _ s : _) : _) -> Just s
  _                                    -> Nothing

a6Checks :: [Check]
a6Checks =
  [ mkCheck 19 "a6-fixture/nested-heading-has-empty-anchor"
      (a6FixtureNestedSlug == Just "")
      ("nested anchor=" ++ show a6FixtureNestedSlug ++ " (want Just \"\")")
  , mkCheck 19 "a6-fixture/later-duplicate-top-level-slug"
      (case a6FixtureTopSlugs of
         [_, later] -> later == "alpha-2"
         _          -> False)
      ("top-level slugs=" ++ show a6FixtureTopSlugs ++ " (want the second entry to be \"alpha-2\")")
  , mkCheck 19 "a6-fixture/full-top-level-slug-sequence"
      (a6FixtureTopSlugs == ["alpha", "alpha-2"])
      ("top-level slugs=" ++ show a6FixtureTopSlugs ++ " (want [\"alpha\",\"alpha-2\"])")
  ]

--------------------------------------------------------------------------
-- 20. A7 GUARD ONLY (ruled M5; 'gatherChildren'\/'collect' in
-- "SXC1.Content.Markdown" UNCHANGED). A SOURCE-LEVEL assertion that
-- every ordered list's numbers are consecutive-ascending, so a future
-- translation using the lazy \"1. \/ 1. \/ 1.\" idiom turns red instead
-- of silently mis-rendering. Also pins the current list\/fragment census
-- (group 15's Numbered counts) so an eventual M5 grouping fix is a
-- deliberate, visible change rather than a silent one.
--------------------------------------------------------------------------

rawOrderedMarkers :: Text -> [(Int, Int)]
rawOrderedMarkers raw = [ (ind, n) | l <- T.lines raw, Just (ind, n, _) <- [orderedItemOf l] ]

-- | Two same-indent markers in a row are fine if the second is exactly
-- one more than the first (continuing the list) OR strictly LOWER (4.5's
-- restart rule -- e.g. guide-book p.29 begins \"3.\", continuing a list
-- from an earlier page, or a brand-new list starting fresh elsewhere).
-- Anything else -- equal (the lazy \"1.\/1.\/1.\" idiom) or a skipped
-- number -- is a violation. Measured fact (see this task's report): all
-- four documents currently have zero.
consecutiveAscendingViolations :: Text -> [((Int, Int), (Int, Int))]
consecutiveAscendingViolations raw = go Map.empty (rawOrderedMarkers raw)
  where
    go _ [] = []
    go prevByIndent ((ind, n) : rest) = case Map.lookup ind prevByIndent of
      Just p | n /= p + 1 && n >= p -> ((ind, p), (ind, n)) : go nextMap rest
      _                              -> go nextMap rest
      where nextMap = Map.insert ind n prevByIndent

orderedListAscendingChecks :: [Check]
orderedListAscendingChecks =
  [ mkCheck 20 ("ordered-ascending/" ++ T.unpack slug)
      (null violations)
      (show (length violations) ++ " violation(s): " ++ show (take 5 violations))
  | (slug, raw) <- corpusSources
  , let violations = consecutiveAscendingViolations raw
  ]

-- | NEGATIVE CONTROL 7: the lazy \"1. \/ 1. \/ 1.\" idiom, permanently
-- pinned so it stays red forever if this check regresses -- a scratch
-- fixture, not real corpus text.
a7SabotageFixtureRaw :: Text
a7SabotageFixtureRaw = T.unlines
  [ "1. Foo"
  , ""
  , "1. Bar"
  , ""
  , "1. Baz"
  ]

a7GuardDemoChecks :: [Check]
a7GuardDemoChecks =
  [ mkCheck 20 "ordered-ascending/scratch-fixture-repeated-1-is-red"
      (not (null (consecutiveAscendingViolations a7SabotageFixtureRaw)))
      ("violations=" ++ show (consecutiveAscendingViolations a7SabotageFixtureRaw) ++ " (want at least one)")
  ]

-- | The current list\/fragment census -- pins group 15's Numbered block
-- count explicitly under the A7 label too, so an eventual M5 grouping
-- fix changes THIS number on purpose.
a7FragmentCensusChecks :: [Check]
a7FragmentCensusChecks =
  [ mkCheck 20 ("ordered-fragment-census/" ++ T.unpack slug)
      (cnsNumberedBlocks got == cnsNumberedBlocks want)
      ("numberedBlocks=" ++ show (cnsNumberedBlocks got) ++ " (want " ++ show (cnsNumberedBlocks want) ++ ")")
  | (slug, want) <- censusGoldenTable
  , Just got <- [lookup slug corpusCensus]
  ]

--------------------------------------------------------------------------
-- 21. NEW11: 'parseBlocksEngineWith' must TERMINATE and emit 'Unparsed'
-- when a dishonest classifier claims 'OrderedShape'\/'BulletShape' for a
-- line 'orderedItemOf'\/'bulletItemOf' does not actually recognise --
-- see "SXC1.Content.Markdown"'s Haddock on 'parseBlocksEngineWith''s list
-- branches for the mechanism, and briefs/M2-manifest.json's probe P-L
-- for the live reproduction (a 60-second timeout against the pre-fix
-- engine; the same binary with only that probe call removed finished in
-- well under a second).
--------------------------------------------------------------------------

-- | Ordinary prose -- not heading/table/quote/list-shaped by any honest
-- rule -- so a classifier that nonetheless reports 'OrderedShape' or
-- 'BulletShape' for it is lying, exactly as A1's 'a1DecliningClassifier'
-- lies about 'DeclinedShape'.
new11PoisonLine :: Text
new11PoisonLine = "ordinary text that is not an ordered or bulleted list item"

new11SecondPoisonLine :: Text
new11SecondPoisonLine = "a second ordinary line, also not list-shaped"

-- | Always reports 'OrderedShape', regardless of the line's real shape --
-- the exact probe from P-L (@const OrderedShape@).
new11OrderedLiar :: Text -> LineShape
new11OrderedLiar = const OrderedShape

-- | Always reports 'BulletShape', regardless of the line's real shape.
new11BulletLiar :: Text -> LineShape
new11BulletLiar = const BulletShape

new11OrderedSingle :: [Block]
new11OrderedSingle = fst (parseBlocksEngineWith new11OrderedLiar 1 False [] [new11PoisonLine])

new11BulletSingle :: [Block]
new11BulletSingle = fst (parseBlocksEngineWith new11BulletLiar 1 False [] [new11PoisonLine])

-- | Two poisoned lines in a row -- proves 'go' recursed on the
-- STRICTLY SHRINKING tail (never on the untouched input) across more
-- than one call, not just that a single-line input happens to stop.
new11OrderedPair :: [Block]
new11OrderedPair =
  fst (parseBlocksEngineWith new11OrderedLiar 1 False [] [new11PoisonLine, new11SecondPoisonLine])

new11Checks :: [Check]
new11Checks =
  [ mkCheck 21 "new11/ordered-liar-terminates"
      (length new11OrderedSingle == 1)
      ("blocks=" ++ show (length new11OrderedSingle) ++ " (want 1 -- proves 'go' terminated on the finite input)")
  , mkCheck 21 "new11/ordered-liar-emits-unparsed"
      (case new11OrderedSingle of
         [Unparsed t] -> t == new11PoisonLine
         _            -> False)
      ("blocks=" ++ show new11OrderedSingle)
  , mkCheck 21 "new11/bullet-liar-terminates"
      (length new11BulletSingle == 1)
      ("blocks=" ++ show (length new11BulletSingle) ++ " (want 1 -- proves 'go' terminated on the finite input)")
  , mkCheck 21 "new11/bullet-liar-emits-unparsed"
      (case new11BulletSingle of
         [Unparsed t] -> t == new11PoisonLine
         _            -> False)
      ("blocks=" ++ show new11BulletSingle)
  , mkCheck 21 "new11/ordered-liar-recurses-on-shrinking-tail"
      (new11OrderedPair == [Unparsed new11PoisonLine, Unparsed new11SecondPoisonLine])
      ("blocks=" ++ show new11OrderedPair ++ " (want both lines individually Unparsed, in order)")
  , mkCheck 21 "new11/real-classifier-never-lies-about-this-line"
      -- Belt-and-suspenders, mirroring a1Checks' third case: the REAL
      -- 'classifyLine' never reports OrderedShape/BulletShape for
      -- 'new11PoisonLine', so this fix path is unreachable via
      -- production -- reachable only via the two liar classifiers above.
      (classifyLine new11PoisonLine /= OrderedShape && classifyLine new11PoisonLine /= BulletShape)
      ("classifyLine new11PoisonLine = " ++ show (classifyLine new11PoisonLine))
  ]

--------------------------------------------------------------------------
-- 22. NEW12: an empty assertion group must make the run exit non-zero,
-- not print FAIL and still exit 0. 'groupsAllOk' is the accumulator
-- 'runChecks' folds into its final exit condition; these are a permanent,
-- self-verifying demonstration that it actually closes the hole -- see
-- 'anchorVacuityGuardChecks' (group 16) for the pattern this follows.
--------------------------------------------------------------------------

-- | 'True' iff every group @1..maxGroup@ is present in @checks@ (has at
-- least one 'Check') AND every 'Check' in it passed. A group with ZERO
-- checks -- the NEW12 hole -- reads 'False' here, unlike the old exit
-- condition (@totalPassed == totalAll@), which such a group cannot
-- perturb at all since it contributes nothing to either side of that
-- equality.
groupsAllOk :: Int -> [Check] -> Bool
groupsAllOk maxGroup checks = all groupOk [1 .. maxGroup]
  where
    groupOk g =
      let inGroup = filter ((== g) . chkGroup) checks
      in not (null inGroup) && all chkOk inGroup

-- | The adversarial checklist NEW12 is about: three groups declared
-- (@maxGroup = 3@) but group 2 contributes zero 'Check's -- exactly what
-- a group dropped from @allChecks@, or a dynamic generator that becomes
-- empty, looks like from the exit condition's point of view.
new12MissingGroupChecklist :: [Check]
new12MissingGroupChecklist = [mkCheck 1 "a" True "", mkCheck 3 "c" True ""]

new12GuardChecks :: [Check]
new12GuardChecks =
  [ mkCheck 22 "new12-guard/missing-group-is-not-ok"
      (groupsAllOk 3 new12MissingGroupChecklist == False)
      "a checklist that never mentions group 2 at all must make groupsAllOk report False -- this is the bug NEW12 fixes"
  , mkCheck 22 "new12-guard/fully-passing-groups-are-ok"
      (groupsAllOk 3 [mkCheck 1 "a" True "", mkCheck 2 "b" True "", mkCheck 3 "c" True ""] == True)
      "three non-empty, fully-passing groups must read True"
  , mkCheck 22 "new12-guard/one-failing-check-is-not-ok"
      (groupsAllOk 3 [mkCheck 1 "a" True "", mkCheck 2 "b" False "", mkCheck 3 "c" True ""] == False)
      "a failing check inside an otherwise-present group must still make groupsAllOk report False"
  , mkCheck 22 "new12-guard/old-exit-condition-would-have-missed-the-missing-group"
      -- The OLD exit condition ('totalPassed == totalAll && totalAll > 0')
      -- applied to the SAME adversarial checklist as the first case above
      -- (group 2 entirely absent) still reads True, because an absent
      -- group contributes zero to both totalPassed and totalAll -- this
      -- is NEW12 itself, reproduced as a permanent demonstration that the
      -- old condition really was insufficient, not just theoretically so.
      (let totalPassed = length (filter chkOk new12MissingGroupChecklist)
           totalAll    = length new12MissingGroupChecklist
       in totalPassed == totalAll && totalAll > 0)
      "the pre-NEW12 exit condition reads True on a checklist missing group 2 entirely -- this is the bug"
  ]

--------------------------------------------------------------------------
-- main
--------------------------------------------------------------------------

-- | NEW4 (refined per the round-3 triage; consumed by task
-- 'harness-completeness'): every embedded document, by slug, exactly as
-- @--dump-source@ writes it.
dumpSourceMap :: [(Text, Text)]
dumpSourceMap = corpusSources ++ [("glossary", glossarySource)]

-- | @--dump-source \<slug\>@: write the EXACT embedded UTF-8 bytes for
-- that document to stdout and nothing else -- no banner, no trailing
-- newline of our own (whatever trailing newline the source file has is
-- already part of the embedded 'Text' itself; see "SXC1.Content.Embed").
-- 'hSetNewlineMode' with 'noNewlineTranslation' additionally guarantees
-- no @\\n@\/@\\r\\n@ translation can silently change the byte count.
-- Unknown slug: readable message on stderr, exit 1.
runDumpSource :: Text -> IO ()
runDumpSource slug = case lookup slug dumpSourceMap of
  Just raw -> do
    hSetEncoding stdout utf8
    hSetNewlineMode stdout noNewlineTranslation
    TIO.putStr raw
  Nothing -> do
    hPutStrLn stderr
      ("content-check --dump-source: unknown slug " ++ show slug
        ++ " (known: " ++ show (map fst dumpSourceMap) ++ ")")
    exitWith (ExitFailure 1)

main :: IO ()
main = do
  hSetEncoding stdout utf8
  args <- getArgs
  case args of
    ("--dump-source" : slug : _) -> runDumpSource (T.pack slug)
    ["--dump-source"] -> do
      hPutStrLn stderr "content-check --dump-source: missing <slug> argument"
      exitWith (ExitFailure 1)
    _ | "--census" `elem` args -> TIO.putStr (renderCensus corpusCensus)
      | "--json"   `elem` args -> TIO.putStrLn (statsJson (buildStatsFromDocs docs corpusSources))
      | otherwise               -> runChecks ("--verbose" `elem` args)

runChecks :: Bool -> IO ()
runChecks verboseMode = do
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
          ++ titledStepChecks
          ++ a1Checks
          ++ secEndPageInvariantChecks
          ++ ownershipChecks
          ++ censusChecks
          ++ censusReconciliationChecks
          ++ censusTablesMatchRawGoldenChecks
          ++ anchorVacuityGuardChecks
          ++ dedupeSlugsChecks
          ++ routeClassificationChecks
          ++ a6Checks
          ++ orderedListAscendingChecks
          ++ a7GuardDemoChecks
          ++ a7FragmentCensusChecks
          ++ new11Checks
          ++ new12GuardChecks
      maxGroup = 22 :: Int
  forM_ [1 .. maxGroup] $ \g -> do
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
  -- NEW12: 'totalPassed == totalAll' alone cannot see a group that
  -- contributes ZERO checks to 'allChecks' -- such a group prints FAIL
  -- above (via 'allOk' in the loop) but perturbs neither side of that
  -- equality below. 'groupsOk' (via 'groupsAllOk') is the accumulator
  -- that closes the hole: it requires every group 1..maxGroup to be
  -- BOTH present and fully passing, and is folded into the exit
  -- condition directly, so a labelled-but-empty group can no longer
  -- print FAIL and still exit 0 (see group 22's permanent
  -- negative-control demonstration).
  let totalPassed = length (filter chkOk allChecks)
      totalAll    = length allChecks
      groupsOk    = groupsAllOk maxGroup allChecks
  putStrLn ("content-check: " ++ show totalPassed ++ "/" ++ show totalAll ++ " checks passed")
  if totalPassed == totalAll && totalAll > 0 && groupsOk then exitSuccess else exitFailure
