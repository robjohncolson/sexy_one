{-# LANGUAGE OverloadedStrings #-}

-- | Resolution of citations, MIDI @verify:@ hooks, chapter titles and
-- exercise ids against externally-derived truth: the manual corpus
-- (@translations\/*.md@, via M1's own parser), @translations\/midi.md@'s
-- Control Change and Note mapping tables, and
-- @content\/exercise-inventory.md@'s course map and id ledger. Nothing
-- here is hard-coded -- every table this module resolves against is
-- PARSED, not copied by hand, so an edit to the manual corpus is what
-- keeps these checks honest.
module SXC1.Exercise.Verify
  ( -- * Citations against the manual corpus
    ManualIndex (..)
  , buildManualIndex
  , resolveCitation
  , normalizeWs
    -- * @verify:@ hooks against translations\/midi.md
  , MidiFacts (..)
  , buildMidiFacts
  , resolveVerify
    -- * Chapter titles against the inventory's course map
  , parseInventoryChapters
  , resolveChapter
    -- * Exercise ids against the inventory's id ledger
  , resolveInventoryId
  , parseIdShape
  ) where

import           Data.List              (findIndex)
import qualified Data.Map.Strict        as Map
import           Data.Map.Strict        (Map)
import qualified Data.Set               as Set
import           Data.Set               (Set)
import           Data.Text              (Text)
import qualified Data.Text              as T

import           SXC1.Content.Markdown  (headingLineOf, pageCountOf, parseBlocksEngine, splitPageTexts)
import           SXC1.Content.Types     (Block (..), Inline)
import           SXC1.Exercise.Lint     (inlinesText)
import           SXC1.Exercise.Report
import           SXC1.Exercise.Types    (Citation (..), ExId (..), Kind (..), VerifySpec (..))
import           SXC1.Route             (parseDigits)

showT :: Show a => a -> Text
showT = T.pack . show

--------------------------------------------------------------------------
-- Citations against the manual corpus
--------------------------------------------------------------------------

-- | The four documents' page counts and each page's WHITESPACE-NORMALISED
-- source text -- built once by 'buildManualIndex' from raw (slug, text)
-- pairs, so 'resolveCitation' itself never re-parses anything.
data ManualIndex = ManualIndex
  { miPageCount :: Map Text Int
  , miPageText  :: Map Text (Map Int Text)
  }

-- | Collapse every run of whitespace (spaces, tabs, newlines) to a single
-- space, and trim both ends -- exactly the format spec's "collapse runs
-- of whitespace to one space on both sides before comparing", applied
-- identically to a citation's anchor phrase and to the page text it must
-- occur in.
normalizeWs :: Text -> Text
normalizeWs = T.unwords . T.words

knownSlugs :: [Text]
knownSlugs = ["guide-book", "startup-guide", "midi", "oss"]

buildManualIndex :: [(Text, Text)] -> ManualIndex
buildManualIndex sources = ManualIndex
  { miPageCount = Map.fromList [ (slug, pageCountOf raw) | (slug, raw) <- sources ]
  , miPageText  = Map.fromList
      [ (slug, Map.fromList [ (n, normalizeWs (T.unlines ls)) | (n, ls) <- splitPageTexts raw ])
      | (slug, raw) <- sources
      ]
  }

-- | Content-verified citation resolution: slug membership, page range,
-- and (after whitespace normalisation, minimum 12 characters) that the
-- anchor phrase actually occurs on the cited page.
resolveCitation :: ManualIndex -> Loc -> Citation -> [Issue]
resolveCitation idx loc c
  | citSlug c `notElem` knownSlugs =
      [ mkIssue E_CITE_SLUG loc
          ("unknown manual slug \"" <> citSlug c <> "\" (want one of guide-book, startup-guide, midi, oss)") ]
  | not (null pageIssues) = pageIssues
  | otherwise             = anchorIssues
  where
    mPageCount = Map.lookup (citSlug c) (miPageCount idx)
    pageIssues = case mPageCount of
      Just pc | citPage c < 1 || citPage c > pc ->
        [ mkIssue E_CITE_PAGE loc
            ("page " <> showT (citPage c) <> " out of range 1.." <> showT pc <> " for " <> citSlug c) ]
      _ -> []
    anchorIssues
      | T.length (T.strip (citAnchor c)) < 12 =
          [ mkIssue E_CITE_ANCHOR loc "anchor phrase must be at least 12 characters" ]
      | otherwise = case Map.lookup (citSlug c) (miPageText idx) >>= Map.lookup (citPage c) of
          Just pageTxt | normalizeWs (citAnchor c) `T.isInfixOf` pageTxt -> []
          _ -> [ mkIssue E_CITE_ANCHOR loc
                   ("anchor \"" <> citAnchor c <> "\" not found on " <> citSlug c <> " p." <> showT (citPage c)) ]

--------------------------------------------------------------------------
-- verify: hooks against translations/midi.md
--------------------------------------------------------------------------

-- | Facts PARSED out of @translations\/midi.md@ with M1's own block
-- parser -- never hand-copied. 'mfCCNumbers' is every CC number listed in
-- the \"4. Control Change list\" table; 'mfPadBanks' is every (pad
-- number, bank letter) pair the \"5. Note mapping\" table's @Bank X@
-- columns carry a note for; 'mfNoteRange' is the (min, max) note number
-- spanned by every numeric cell of that same table (both the @Bank X@
-- columns and the \"Active (receive only)\" column) -- which happens to
-- be exactly 36..115, the range the format spec states.
data MidiFacts = MidiFacts
  { mfCCNumbers :: Set Int
  , mfPadBanks  :: Set (Int, Char)
  , mfNoteRange :: (Int, Int)
  }

-- | The section of @blocks@ strictly between the (level <= 2) heading
-- whose flattened text is @titleText@ and the next (level <= 2) heading,
-- or @[]@ if no such heading is found.
sectionBlocks :: Text -> [Block] -> [Block]
sectionBlocks titleText blocks = case dropWhile notTarget blocks of
  []             -> []
  (_ : rest) -> takeWhile notNextSection rest
  where
    notTarget b = case b of
      Heading lvl inlines _ | lvl <= 2, T.strip (inlinesText inlines) == titleText -> False
      _ -> True
    notNextSection b = case b of
      Heading lvl _ _ | lvl <= 2 -> False
      _ -> True

parseHeaderBankLetter :: Text -> Maybe Char
parseHeaderBankLetter t = case T.stripPrefix "Bank " (T.strip t) of
  Just rest | T.length rest == 1, c <- T.head rest, c >= 'A', c <= 'Z' -> Just c
  _ -> Nothing

parsePadLabel :: Text -> Maybe Int
parsePadLabel t = case T.stripPrefix "Pad " (T.strip t) of
  Just rest -> parseDigits (T.strip rest)
  Nothing   -> Nothing

-- | Scan one Note-mapping-shaped table: the (pad, bank) pairs its
-- @Bank X@ columns carry a numeric entry for, and every numeric cell
-- value anywhere in the body (for 'mfNoteRange').
noteMappingFromTable :: Maybe [[Inline]] -> [[[Inline]]] -> (Set (Int, Char), [Int])
noteMappingFromTable mHeader rows = (Set.fromList (concat pairsLists), concat numLists)
  where
    headerTexts = maybe [] (map inlinesText) mHeader
    bankCols    = [ (i, c) | (i, h) <- zip [0 :: Int ..] headerTexts, Just c <- [parseHeaderBankLetter h] ]
    perRow cells = case cells of
      []                  -> ([], [])
      (padCell : restCells) ->
        let mPad        = parsePadLabel (inlinesText padCell)
            cellNumAt i  = if i < length restCells then parseDigits (T.strip (inlinesText (restCells !! i))) else Nothing
            allCellNums  = [ n | c <- restCells, Just n <- [parseDigits (T.strip (inlinesText c))] ]
            pairsHere    = case mPad of
              Nothing  -> []
              Just pad -> [ (pad, bankLetter)
                          | (colIdx, bankLetter) <- bankCols
                          , colIdx >= 1
                          , Just _ <- [cellNumAt (colIdx - 1)]
                          ]
        in (pairsHere, allCellNums)
    (pairsLists, numLists) = unzip (map perRow rows)

ccHeaderColumn :: Maybe [[Inline]] -> Maybe Int
ccHeaderColumn mHeader = findIndex (\t -> T.strip t == "CC No.") (maybe [] (map inlinesText) mHeader)

buildMidiFacts :: Text -> MidiFacts
buildMidiFacts raw = MidiFacts
  { mfCCNumbers = Set.fromList
      [ n
      | Table mh rows <- ccSection
      , Just idx <- [ccHeaderColumn mh]
      , row <- rows
      , idx < length row
      , Just n <- [parseDigits (T.strip (inlinesText (row !! idx)))]
      ]
  , mfPadBanks  = Set.unions padBankSets
  , mfNoteRange = if null allNoteNums then (0, 0) else (minimum allNoteNums, maximum allNoteNums)
  }
  where
    (blocks, _)  = parseBlocksEngine 0 False [] (T.lines raw)
    ccSection    = sectionBlocks "4. Control Change list" blocks
    noteSection  = sectionBlocks "5. Note mapping" blocks
    noteResults  = [ noteMappingFromTable mh rows | Table mh rows <- noteSection ]
    padBankSets  = map fst noteResults
    allNoteNums  = concatMap snd noteResults

-- | @verify:@ hook validation. 'VerifyAny' always resolves. A
-- @cc:@ hook's VALUES (the comma-separated list) are a parse-time
-- ("SXC1.Exercise.Parse") concern, not a resolution-time one -- only the
-- CC NUMBER itself is resolved against the table here.
resolveVerify :: MidiFacts -> Loc -> VerifySpec -> [Issue]
resolveVerify facts loc spec = case spec of
  VerifyAny -> []
  VerifyCC num _values
    | Set.member num (mfCCNumbers facts) -> []
    | otherwise ->
        [ mkIssue E_VERIFY_CC_UNKNOWN loc
            ("CC " <> showT num <> " does not appear in midi.md's \"4. Control Change list\" table") ]
  VerifyNote nums ->
    let (lo, hi) = mfNoteRange facts
    in [ mkIssue E_VERIFY_NOTE_RANGE loc ("note " <> showT n <> " out of range " <> showT lo <> ".." <> showT hi)
       | n <- nums, n < lo || n > hi ]
  VerifyPad pad bank
    | Set.member (pad, bank) (mfPadBanks facts) -> []
    | otherwise ->
        [ mkIssue E_VERIFY_CC_UNKNOWN loc
            ("pad " <> showT pad <> " bank " <> T.singleton bank
               <> " does not appear in midi.md's \"5. Note mapping\" table") ]

--------------------------------------------------------------------------
-- Chapter titles against the inventory's course map
--------------------------------------------------------------------------

-- | Parse @content\/exercise-inventory.md@'s
-- \"### Chapter N &#8212; \<title\>\" course-map headings (the separator
-- is a literal em dash, matching the committed file) into a
-- chapter-index -> title map, e.g. @0 -> \"Front matter\"@, @2 ->
-- \"Part: Pad play\"@. A trailing parenthetical (e.g. \" (pp. 1-11)\")
-- is stripped. The heading occurs TWICE per chapter in the real file
-- (once in the course map, once above the inventory proper); both
-- occurrences carry the same title, so a 'Map' naturally collapses them.
parseInventoryChapters :: Text -> Map Int Text
parseInventoryChapters raw = Map.fromList
  [ (n, title)
  | l <- T.lines raw
  , Just (3, htext) <- [headingLineOf l]
  , Just rest0 <- [T.stripPrefix "Chapter " htext]
  , let (digs, rest1) = T.span (\c -> c >= '0' && c <= '9') rest0
  , not (T.null digs)
  , Just n <- [parseDigits digs]
  , Just rest2 <- [T.stripPrefix " \8212 " rest1]
  , let title = T.strip (stripTrailingParenthetical rest2)
  , not (T.null title)
  ]

-- | Strip a trailing @\" (...)\"@ parenthetical, if the text ends with
-- one that balances (a simple last-@\"(\"@\/last-char-is-@\")\"@ check --
-- the course-map headings never nest parentheses).
stripTrailingParenthetical :: Text -> Text
stripTrailingParenthetical t
  | T.isSuffixOf ")" t
  , (before, _) <- T.breakOnEnd " (" t
  , not (T.null before)
  = T.dropEnd 2 before
  | otherwise = t

-- | @dkChapter@ must equal one of the inventory's chapter titles
-- exactly.
resolveChapter :: Map Int Text -> Loc -> Text -> [Issue]
resolveChapter chapterVocab loc chapterText
  | T.strip chapterText `elem` Map.elems chapterVocab = []
  | otherwise =
      [ mkIssue E_CHAPTER_UNKNOWN loc
          ("chapter \"" <> chapterText
             <> "\" is not one of the course map's chapter titles from content/exercise-inventory.md") ]

--------------------------------------------------------------------------
-- Exercise ids against the inventory's id ledger
--------------------------------------------------------------------------

isDigitChar :: Char -> Bool
isDigitChar c = c >= '0' && c <= '9'

-- | @t-c-nn@ -> (type letter, chapter digit), e.g. @\"q-2-03\"@ ->
-- @Just ('q', 2)@. 'Nothing' for anything not shaped that way -- ids that
-- don't parse this way also can't be a real inventory id (every real one
-- is @t-c-nn@), so 'resolveInventoryId' already reports
-- 'E_ID_NOT_IN_INVENTORY' for them via the substring check and simply
-- skips the type\/chapter cross-check.
parseIdShape :: Text -> Maybe (Char, Int)
parseIdShape t = case T.splitOn "-" t of
  [tPart, cPart, nnPart]
    | Just (typeChar, rest) <- T.uncons tPart, T.null rest
    , Just chapterDigit <- parseDigits cPart
    , T.length nnPart == 2, T.all isDigitChar nnPart
      -> Just (typeChar, chapterDigit)
  _ -> Nothing

kindLetter :: Kind -> Char
kindLetter KQuiz   = 'q'
kindLetter KDrill  = 'd'
kindLetter KLookup = 'l'

kindWord :: Kind -> Text
kindWord KQuiz   = "quiz"
kindWord KDrill  = "drill"
kindWord KLookup = "lookup"

-- | The four inventory-binding checks (over @content\/exercises\/@ ONLY;
-- never over @--fixtures@ -- see the caller): existence
-- (@E_ID_NOT_IN_INVENTORY@), not retired (@E_ID_RETIRED@), leading letter
-- matches @type:@ (@E_ID_TYPE_MISMATCH@), and chapter digit matches the
-- deck's @chapter:@ (@E_ID_CHAPTER_MISMATCH@). @inventoryRaw@ is the raw
-- text of @content\/exercise-inventory.md@; existence and retired-status
-- are literal substring checks against it (\"id occurs in the inventory
-- as @**\<id\>**@\", \"its inventory tag is not @(retired)@\" -- both
-- exactly as the format spec states them).
resolveInventoryId :: Text -> Map Int Text -> Loc -> ExId -> Kind -> Text -> [Issue]
resolveInventoryId inventoryRaw chapterVocab loc (ExId idTxt) kind declaredChapter
  | not existsInInventory =
      [ mkIssue E_ID_NOT_IN_INVENTORY loc
          ("id " <> idTxt <> " does not occur in content/exercise-inventory.md as **" <> idTxt <> "**") ]
  | otherwise = retiredIssue ++ shapeIssues
  where
    existsInInventory = ("**" <> idTxt <> "**") `T.isInfixOf` inventoryRaw
    retiredIssue =
      [ mkIssue E_ID_RETIRED loc ("id " <> idTxt <> " is tagged (retired) in the inventory")
      | ("**" <> idTxt <> "** (retired)") `T.isInfixOf` inventoryRaw
      ]
    shapeIssues = case parseIdShape idTxt of
      Nothing -> []
      Just (typeChar, chapterDigit) -> typeIssue ++ chapterIssue
        where
          wantType = kindLetter kind
          typeIssue =
            [ mkIssue E_ID_TYPE_MISMATCH loc
                ("id " <> idTxt <> " starts with '" <> T.singleton typeChar <> "' but type: is "
                   <> kindWord kind <> " (want leading '" <> T.singleton wantType <> "')")
            | typeChar /= wantType
            ]
          chapterIssue = case Map.lookup chapterDigit chapterVocab of
            Nothing -> []
            Just title
              | T.strip declaredChapter == title -> []
              | otherwise ->
                  [ mkIssue E_ID_CHAPTER_MISMATCH loc
                      ("id " <> idTxt <> "'s chapter digit " <> showT chapterDigit <> " is inventory chapter \""
                         <> title <> "\" but this deck's chapter: is \"" <> declaredChapter <> "\"")
                  ]
