{-# LANGUAGE OverloadedStrings #-}

-- | The @.ex.md@ grammar, as a pure function -- see
-- @briefs\/M2-manifest.json@'s \"NORMATIVE EXERCISE CONTENT FORMAT\"
-- section for the grammar this implements. Reuses M1's block and inline
-- parsers for all prose ('SXC1.Content.Markdown.parseBlocksEngine',
-- 'SXC1.Content.Markdown.parseInline'); this module never writes a
-- second Markdown parser.
--
-- 'parseDeck' reports EVERY issue it can find rather than stopping at
-- the first, carries a 1-based line number on every issue, and never
-- throws. Unknown field keys and unknown @###@ role names are ERRORS
-- (@E-FIELD-UNKNOWN@\/@E-ROLE-UNKNOWN@), never silently ignored.
module SXC1.Exercise.Parse
  ( parseDeck
  , parseDeckDetailed
  , validFileName
  , unparsedBlockIssues
  ) where

import           Data.Maybe             (isNothing, mapMaybe)
import           Data.Text              (Text)
import qualified Data.Text              as T

import           SXC1.Content.Markdown  (bulletItemOf, headingLineOf, parseBlocksEngine, parseInline)
import           SXC1.Content.Types     (Block (..), ListItem (liChildren))
import           SXC1.Exercise.Lint     (blocksText, findOccurrencesCI, inlinesText)
import           SXC1.Exercise.Report
import           SXC1.Exercise.Types
import           SXC1.Route             (parseDigits)

--------------------------------------------------------------------------
-- Small text-shape helpers (no regex engine anywhere -- see Lint.hs)
--------------------------------------------------------------------------

isLowerAscii :: Char -> Bool
isLowerAscii c = c >= 'a' && c <= 'z'

isDigitChar :: Char -> Bool
isDigitChar c = c >= '0' && c <= '9'

isSlugChar :: Char -> Bool
isSlugChar c = isLowerAscii c || isDigitChar c || c == '-'

-- | @[a-z0-9-]+@, not starting or ending with @-@ -- the shape shared by
-- @deck:@ ids and exercise @id:@ values (both surface as @E_ID_SYNTAX@).
isSlugLike :: Text -> Bool
isSlugLike t =
  not (T.null t) && T.all isSlugChar t && T.head t /= '-' && T.last t /= '-'

--------------------------------------------------------------------------
-- Filenames -- content/exercises/NN-slug.ex.md
--------------------------------------------------------------------------

baseNameOf :: FilePath -> Text
baseNameOf fp = case reverse (T.splitOn "/" (T.pack fp)) of
  (b : _) -> b
  []      -> T.pack fp

-- | @^[0-9]{2}-[a-z0-9-]+\.ex\.md$@.
validFileName :: FilePath -> Bool
validFileName fp = case T.stripSuffix ".ex.md" (baseNameOf fp) of
  Nothing   -> False
  Just stem -> case T.splitAt 2 stem of
    (nn, rest) ->
      T.length nn == 2 && T.all isDigitChar nn
        && case T.uncons rest of
             Just ('-', slug) -> isSlugLike slug
             _                -> False

--------------------------------------------------------------------------
-- Field blocks
--------------------------------------------------------------------------

data FieldLine = FieldLine { flLine :: !Int, flKey :: !Text, flValue :: !Text }

isBlankL :: Text -> Bool
isBlankL = T.null . T.strip

fieldKeyValueOf :: Text -> Maybe (Text, Text)
fieldKeyValueOf l = case T.uncons l of
  Just (c0, _) | isLowerAscii c0 ->
    let (key, rest) = T.break (== ':') l
    in if not (T.null rest) && T.all (\c -> isLowerAscii c || isDigitChar c || c == '-') key
         then let val0 = T.drop 1 rest
                  val1 = maybe val0 id (T.stripPrefix " " val0)
              in Just (key, val1)
         else Nothing
  _ -> Nothing

isContinuationLine :: Text -> Bool
isContinuationLine l = T.length (T.takeWhile (== ' ') l) >= 2 && not (isBlankL l)

-- | The maximal run of field lines (plus their indented continuations)
-- immediately following a structural heading -- blank lines are allowed
-- BEFORE it, never inside it (a blank line, or any non-field/
-- non-continuation line, ends the block). Returns the field occurrences
-- (in source order) and the remaining lines (the body).
scanFieldBlock :: [(Int, Text)] -> ([FieldLine], [(Int, Text)])
scanFieldBlock lns0 = collect (dropWhile (isBlankL . snd) lns0) []
  where
    collect [] acc = (reverse acc, [])
    collect all0@((ln, l) : rest) acc
      | isBlankL l = (reverse acc, all0)
      | Just (key, val) <- fieldKeyValueOf l = collect rest (FieldLine ln key val : acc)
      | isContinuationLine l, (fl : accRest) <- acc =
          collect rest (fl { flValue = flValue fl <> " " <> T.strip l } : accRest)
      | otherwise = (reverse acc, all0)

fieldValuesOf :: Text -> [FieldLine] -> [FieldLine]
fieldValuesOf key fs = filter ((== key) . flKey) fs

-- | Cardinality of an allowed field key within a given field-block
-- context.
data Card = Req1 | ReqMany | Opt1 | OptMany
  deriving (Eq)

-- | Validate a field block against its context's allowed key set:
-- unknown keys (@E_FIELD_UNKNOWN@), empty values on a known key
-- (@E_FIELD_EMPTY@), extra occurrences of a single-valued key
-- (@E_FIELD_DUPLICATE@), and missing required keys (@E_FIELD_MISSING@,
-- anchored at @anchorLoc@ -- there is no better line to point a "this
-- field never appeared" issue at).
checkFieldBlock :: Text -> Loc -> [(Text, Card)] -> [FieldLine] -> [Issue]
checkFieldBlock file anchorLoc allowed fields =
  unknownIssues ++ emptyIssues ++ dupIssues ++ missingIssues
  where
    allowedKeys = map fst allowed
    unknownIssues =
      [ mkIssue E_FIELD_UNKNOWN (Loc file (flLine f)) ("unknown field \"" <> flKey f <> "\"")
      | f <- fields, flKey f `notElem` allowedKeys
      ]
    emptyIssues =
      [ mkIssue E_FIELD_EMPTY (Loc file (flLine f)) ("field \"" <> flKey f <> "\" has an empty value")
      | f <- fields, flKey f `elem` allowedKeys, T.null (T.strip (flValue f))
      ]
    dupIssues = concat
      [ [ mkIssue E_FIELD_DUPLICATE (Loc file (flLine f)) ("field \"" <> k <> "\" may not repeat") | f <- drop 1 occs ]
      | (k, card) <- allowed, card == Req1 || card == Opt1
      , let occs = fieldValuesOf k fields
      , length occs > 1
      ]
    missingIssues =
      [ mkIssue E_FIELD_MISSING anchorLoc ("missing required field \"" <> k <> "\"")
      | (k, card) <- allowed, card == Req1 || card == ReqMany
      , null (fieldValuesOf k fields)
      ]

--------------------------------------------------------------------------
-- Structural splitting -- headings at a given level, column-0 only
-- (probe P-I: headingLineOf is column-0 only on the raw line).
--------------------------------------------------------------------------

-- | Split a run of lines at every heading of EXACTLY level @lvl@. Returns
-- the lines before the first such heading, and one chunk per heading:
-- its line number, its title text, and its own lines (running until the
-- next heading of level <= @lvl@).
splitAtLevel :: Int -> [(Int, Text)] -> ([(Int, Text)], [(Int, Text, [(Int, Text)])])
splitAtLevel lvl lns = (pre, go rest0)
  where
    (pre, rest0) = break (isLevel lvl) lns
    go [] = []
    go ((ln, l) : more) = case headingLineOf l of
      Just (hlvl, htext) | hlvl == lvl ->
        let (body, more') = break (isLevelLE lvl) more
        in (ln, htext, body) : go more'
      _ -> go more
    isLevel lv (_, l) = case headingLineOf l of { Just (hlvl, _) -> hlvl == lv; Nothing -> False }
    isLevelLE lv (_, l) = case headingLineOf l of { Just (hlvl, _) -> hlvl <= lv; Nothing -> False }

--------------------------------------------------------------------------
-- E-BLOCK-UNPARSED
--
-- With the REAL 'SXC1.Content.Markdown.classifyLine', 'Unparsed' is
-- UNREACHABLE from any file's body prose -- 'parseBlocksEngine' never
-- constructs one for genuine text (see its Haddock: the paragraph rule
-- is a total catch-all). This scan therefore never fires against real
-- content; it exists so the CODE genuinely exists (for
-- @--list-codes@'s enumeration to be honest, and so a future change to
-- the grammar that DID start producing 'Unparsed' would be caught
-- immediately instead of silently passing through unreported). Its
-- reachability is demonstrated only via the
-- 'SXC1.Content.Markdown.parseBlocksEngineWith' test seam, in
-- @exercise-check --self-test@ -- see that module's Haddock and
-- @test\/CheckExercises.hs@.
--------------------------------------------------------------------------

flattenBlocksLocal :: [Block] -> [Block]
flattenBlocksLocal = concatMap oneBlock
  where
    oneBlock b = b : case b of
      Quote inner       -> flattenBlocksLocal inner
      Bullets items      -> concatMap (flattenBlocksLocal . liChildren) items
      Numbered _ items    -> concatMap (flattenBlocksLocal . liChildren) items
      _                    -> []

-- | Scan a block list (recursively, into 'Quote' and list-item children)
-- for 'Unparsed' occurrences, reporting each as 'E_BLOCK_UNPARSED'.
unparsedBlockIssues :: Text -> Loc -> [Block] -> [Issue]
unparsedBlockIssues _file loc blocks =
  [ mkIssue E_BLOCK_UNPARSED loc ("unparsed content: " <> t) | Unparsed t <- flattenBlocksLocal blocks ]

-- | Scan every 'Block' field of a fully-built 'Deck' (intros, Why/Hint/
-- Answer role blocks, and every prompt's stem) for 'Unparsed' -- see
-- 'unparsedBlockIssues' above for why this can never fire on real
-- content.
deckUnparsedIssues :: Text -> Loc -> Maybe Deck -> [Issue]
deckUnparsedIssues _ _ Nothing = []
deckUnparsedIssues file loc (Just d) = scan (dkIntro d) ++ concatMap oneEx (dkExercises d)
  where
    scan = unparsedBlockIssues file loc
    oneEx e = scan (exIntro e) ++ scan (exNote e) ++ concatMap scan (exHints e) ++ concatMap onePrompt (exPrompts e)
    onePrompt p = scan (prStem p) ++ case prBody p of
      Recall ans -> scan ans
      _          -> []

--------------------------------------------------------------------------
-- E-BODY-INDENTED-HEADING
--------------------------------------------------------------------------

isIndentedHeadingLine :: Text -> Bool
isIndentedHeadingLine l =
  let stripped = T.dropWhile (== ' ') l
      indent   = T.length l - T.length stripped
  in indent > 0 && case headingLineOf stripped of { Just _ -> True; Nothing -> False }

indentedHeadingIssues :: Text -> [(Int, Text)] -> [Issue]
indentedHeadingIssues file lns =
  [ mkIssue E_BODY_INDENTED_HEADING (Loc file ln) ("indented heading-shaped line: " <> T.strip l)
  | (ln, l) <- lns, isIndentedHeadingLine l
  ]

--------------------------------------------------------------------------
-- Choice lists (GFM task lists, lifted BEFORE block parsing -- probe P-J)
--------------------------------------------------------------------------

-- | A top-level (indent 0) task-list item -- built on 'bulletItemOf'
-- (probe P-J: a GFM task list parses as an ordinary 'Bullets' item whose
-- inline content still literally begins @\"[x] \"@\/@\"[ ] \"@, so the
-- choice list must be lifted off the raw lines BEFORE block parsing,
-- using 'bulletItemOf' plus a checkbox-prefix test -- exactly what this
-- does), not a hand-rolled @\"- [\"@ prefix check, so @*@\/@+@ markers
-- and 'bulletItemOf''s own indent computation are honoured uniformly
-- with the rest of the corpus.
taskListItemOf :: Text -> Maybe (Bool, Text)
taskListItemOf l = do
  (ind, rest) <- bulletItemOf l
  if ind /= 0 then Nothing else checkboxOf rest

checkboxOf :: Text -> Maybe (Bool, Text)
checkboxOf rest0 = do
  rest1 <- T.stripPrefix "[" rest0
  (c, rest2) <- T.uncons rest1
  checked <- case c of { ' ' -> Just False; 'x' -> Just True; 'X' -> Just True; _ -> Nothing }
  rest3 <- T.stripPrefix "]" rest2
  rest4 <- T.stripPrefix " " rest3
  let label = T.strip rest4
  if T.null label then Nothing else Just (checked, label)

-- | Lift the MAXIMAL contiguous run of task-list-shaped lines out of the
-- raw body, returning its items (in order, with their own line numbers)
-- and the body with that run removed. 'Nothing' if no such run exists.
extractChoiceList :: [(Int, Text)] -> (Maybe [(Int, Bool, Text)], [(Int, Text)])
extractChoiceList lns = case bestRun of
  Nothing -> (Nothing, lns)
  Just (start, len) ->
    let (before, afterStart) = splitAt start lns
        (runLines, after)    = splitAt len afterStart
        items = [ (ln, checked, label) | (ln, l) <- runLines, Just (checked, label) <- [taskListItemOf l] ]
    in (Just items, before ++ after)
  where
    arr = lns
    n   = length arr
    at i = snd (arr !! i)
    runLenFrom i
      | i >= n                                    = 0
      | Just _ <- taskListItemOf (at i) = 1 + runLenFrom (i + 1)
      | otherwise                                  = 0
    runs = findRuns 0
    findRuns i
      | i >= n = []
      | Just _ <- taskListItemOf (at i) = let len = runLenFrom i in (i, len) : findRuns (i + len)
      | otherwise = findRuns (i + 1)
    bestRun = case runs of
      [] -> Nothing
      (r : rs) -> Just (foldl (\a@(_, la) b@(_, lb) -> if lb > la then b else a) r rs)

--------------------------------------------------------------------------
-- cite: / find: syntax -- "<slug> <page> \"<anchor>\""
--------------------------------------------------------------------------

parseCitationValue :: Text -> Maybe Citation
parseCitationValue v =
  let v'              = T.strip v
      (slugPart, r0)   = T.break (== ' ') v'
      r1               = T.stripStart r0
      (pagePart, r2)   = T.break (== ' ') r1
      r3               = T.stripStart r2
  in if T.null slugPart || T.null pagePart
       then Nothing
       else do
         page <- parseDigits pagePart
         afterOpen <- T.stripPrefix "\"" r3
         let strippedTail = T.strip afterOpen
         anchor <- T.stripSuffix "\"" strippedTail
         if T.null anchor then Nothing else Just (Citation slugPart page anchor)

--------------------------------------------------------------------------
-- verify: syntax
--------------------------------------------------------------------------

parseVerifyValue :: Text -> Maybe VerifySpec
parseVerifyValue v = case T.words (T.strip v) of
  ["any"] -> Just VerifyAny
  ["cc", numTxt, valuesTxt] -> do
    n    <- parseDigits numTxt
    vals <- mapM parseDigits (T.splitOn "," valuesTxt)
    if null vals then Nothing else Just (VerifyCC n vals)
  ["note", numsTxt] -> do
    vals <- mapM parseDigits (T.splitOn "," numsTxt)
    if null vals then Nothing else Just (VerifyNote vals)
  ["pad", padTxt, "bank", bankTxt] -> do
    p <- parseDigits padTxt
    case T.unpack bankTxt of
      [c] | c `elem` ("ABCD" :: String) -> Just (VerifyPad p c)
      _                                  -> Nothing
  _ -> Nothing

--------------------------------------------------------------------------
-- Lookup spoiler scan
--------------------------------------------------------------------------

lookupSpoilerHits :: Int -> Text -> Bool
lookupSpoilerHits target text = any tryForm forms
  where
    targetTxt = T.pack (show target)
    forms = [ "p. " <> targetTxt, "p." <> targetTxt, "page " <> targetTxt, "pages " <> targetTxt ]
    tryForm f = any (boundaryOk f) (findOccurrencesCI f text)
    boundaryOk f off =
      let after = off + T.length f
      in after >= T.length text || not (isDigitChar (T.index text after))

--------------------------------------------------------------------------
-- Tags
--------------------------------------------------------------------------

parseTags :: Text -> Maybe [Text]
parseTags v =
  let items = map T.strip (T.splitOn "," v)
  in if all isSlugLike items && not (null items) then Just items else Nothing

--------------------------------------------------------------------------
-- The full parse -- issues, the Deck (if buildable), and everything a
-- resolution pass (SXC1.Exercise.Verify) needs but Citation/VerifySpec/
-- Deck themselves have no room for: a 1-based Loc per citation, per
-- verify hook, the deck's chapter field, and per-exercise id -- plus a
-- list of (Loc, learner-facing text) pairs for the terminology linter
-- (SXC1.Exercise.Lint) to run over.
--------------------------------------------------------------------------

-- | Everything 'parseDeck' computes; 'parseDeck' and
-- 'parseDeckDetailed' are both thin projections of this.
parseDeckFull
  :: FilePath -> Text
  -> ( [Issue], Maybe Deck
     , [(Loc, Citation)]
     , [(Loc, VerifySpec)]
     , Maybe (Loc, Text)               -- deck chapter field's Loc and raw value
     , [(Loc, ExId, Kind, Text)]       -- per-exercise id, kind, and the deck's chapter text
     , [(Loc, Text)]                   -- learner-facing text targets for terminology linting
     )
parseDeckFull fp raw = (allIssues, mDeck, allCites, allVerifies, mChapterField, idRows, lintTargets)
  where
    file = T.pack fp
    numbered = zip [1 :: Int ..] (T.lines raw)

    fileNameIssues = [ mkIssue E_FILE_BAD_NAME (Loc file 1) ("bad file name: " <> T.pack fp) | not (validFileName fp) ]

    nonBlank = dropWhile (isBlankL . snd) numbered

    (titleIssues, mTitleLoc, titleText, afterTitle) = case nonBlank of
      [] -> ([mkIssue E_FILE_TITLE (Loc file 1) "file is empty (no deck title line)"], Nothing, "", [])
      ((ln, l) : rest) -> case headingLineOf l of
        Just (1, txt) -> ([], Just (Loc file ln), txt, rest)
        _              -> ( [mkIssue E_FILE_TITLE (Loc file ln)
                                "the first non-blank line must be a single '#' deck title"]
                           , Nothing, "", rest )

    -- "exactly ONE '#' in the file": any FURTHER level-1 heading is a
    -- second E_FILE_TITLE issue.
    extraTitleIssues =
      [ mkIssue E_FILE_TITLE (Loc file ln) "a second top-level '#' heading is not allowed in one deck file"
      | (ln, l) <- afterTitle, Just (1, _) <- [headingLineOf l]
      ]

    deckAnchorLoc = maybe (Loc file 1) id mTitleLoc

    (deckFields, afterDeckFields) = scanFieldBlock afterTitle
    deckFieldIssues = checkFieldBlock file deckAnchorLoc
      [ ("deck", Req1), ("chapter", Req1), ("summary", Req1), ("cite", ReqMany), ("tags", Opt1) ]
      deckFields

    mDeckIdField    = case fieldValuesOf "deck" deckFields of { (f : _) -> Just f; [] -> Nothing }
    mChapterField   = case fieldValuesOf "chapter" deckFields of
      (f : _) | not (T.null (T.strip (flValue f))) -> Just (Loc file (flLine f), flValue f)
      _ -> Nothing
    mSummaryField   = case fieldValuesOf "summary" deckFields of { (f : _) -> Just f; [] -> Nothing }
    deckCiteFields  = fieldValuesOf "cite" deckFields
    mTagsField      = case fieldValuesOf "tags" deckFields of { (f : _) -> Just f; [] -> Nothing }

    deckIdSyntaxIssues = case mDeckIdField of
      Just f | not (T.null (T.strip (flValue f))), not (isSlugLike (T.strip (flValue f))) ->
        [ mkIssue E_ID_SYNTAX (Loc file (flLine f)) ("deck id \"" <> flValue f <> "\" must match [a-z0-9-]+") ]
      _ -> []

    (deckCiteIssues, deckCites) = parseCitationFields file deckCiteFields
    (deckTagIssues, deckTags)   = parseTagsField file mTagsField

    (deckBodyPre, exerciseChunks) = splitAtLevel 2 afterDeckFields
    deckBodyIndentedIssues = indentedHeadingIssues file deckBodyPre
    deckIntroBlocks = fst (parseBlocksEngine 0 False [] (map snd deckBodyPre))

    deckSummaryInline = case mSummaryField of { Just f -> parseInline 0 (flValue f); Nothing -> [] }

    deckIdForExercises = DeckId (maybe "" (T.strip . flValue) mDeckIdField)

    (exIssuesAll, mExercises, exCitesAll, exVerifiesAll, idRowsAll, exLintTargets) =
      unzip6 (map (parseExercise file deckIdForExercises deckChapterTextForRows) exerciseChunks)

    -- The deck's declared chapter text, used only to populate
    -- idRows (E_ID_CHAPTER_MISMATCH is resolved against it later).
    deckChapterTextForRows = maybe "" snd mChapterField

    exercises = mapMaybe id mExercises

    deckEmptyIssue =
      [ mkIssue E_DECK_EMPTY deckAnchorLoc "deck has no exercises" | null exercises ]

    mDeck = case (mDeckIdField, mTitleLoc) of
      (Just idF, Just _) | not (T.null (T.strip (flValue idF))) ->
        Just Deck
          { dkId        = DeckId (T.strip (flValue idF))
          , dkTitle     = titleText
          , dkChapter   = maybe "" snd mChapterField
          , dkSummary   = deckSummaryInline
          , dkCites     = deckCites
          , dkIntro     = deckIntroBlocks
          , dkTags      = deckTags
          , dkExercises = exercises
          }
      _ -> Nothing

    allIssues = concat
      [ fileNameIssues, titleIssues, extraTitleIssues, deckFieldIssues, deckIdSyntaxIssues
      , deckCiteIssues, deckTagIssues, deckBodyIndentedIssues, deckEmptyIssue
      , concat exIssuesAll, deckUnparsedIssues file deckAnchorLoc mDeck
      ]

    allCites    = [ (deckAnchorLoc, c) | c <- deckCites ] ++ concat exCitesAll
    allVerifies = concat exVerifiesAll
    idRows      = concat idRowsAll
    lintTargets =
      [ (deckAnchorLoc, titleText) ]
        ++ [ (deckAnchorLoc, inlinesText deckSummaryInline) | not (null deckSummaryInline) ]
        ++ [ (deckAnchorLoc, blocksText deckIntroBlocks) | not (null deckIntroBlocks) ]
        ++ concat exLintTargets

unzip6 :: [(a, b, c, d, e, f)] -> ([a], [b], [c], [d], [e], [f])
unzip6 = foldr (\(a, b, c, d, e, f) (as, bs, cs, ds, es, fs) -> (a : as, b : bs, c : cs, d : ds, e : es, f : fs))
               ([], [], [], [], [], [])

parseCitationFields :: Text -> [FieldLine] -> ([Issue], [Citation])
parseCitationFields file fs = (concat issuesList, mapMaybe id citesList)
  where
    (issuesList, citesList) = unzip (map one fs)
    one f
      | T.null (T.strip (flValue f)) = ([], Nothing)  -- E_FIELD_EMPTY already reported by checkFieldBlock
      | otherwise = case parseCitationValue (flValue f) of
          Just c  -> ([], Just c)
          Nothing -> ([mkIssue E_CITE_SYNTAX (Loc file (flLine f))
                         ("malformed cite: expected <slug> <page> \"<anchor>\", got \"" <> flValue f <> "\"")], Nothing)

parseTagsField :: Text -> Maybe FieldLine -> ([Issue], [Text])
parseTagsField _ Nothing = ([], [])
parseTagsField file (Just f)
  | T.null (T.strip (flValue f)) = ([], [])
  | otherwise = case parseTags (flValue f) of
      Just ts -> ([], ts)
      Nothing -> ([mkIssue E_FIELD_SYNTAX (Loc file (flLine f))
                     ("malformed tags: expected comma-separated [a-z0-9-]+, got \"" <> flValue f <> "\"")], [])

--------------------------------------------------------------------------
-- One exercise (## heading)
--------------------------------------------------------------------------

parseExercise
  :: Text -> DeckId -> Text -> (Int, Text, [(Int, Text)])
  -> ([Issue], Maybe Exercise, [(Loc, Citation)], [(Loc, VerifySpec)], [(Loc, ExId, Kind, Text)], [(Loc, Text)])
parseExercise file deckId deckChapterText (headLn, exTitleTxt, chunkLines) =
  (allIssues, mExercise, cites, verifies, idRows, lintTargets)
  where
    exLoc = Loc file headLn
    (exFields, afterExFields) = scanFieldBlock chunkLines

    -- Used for anything that needs SOME 'ExId' even when id: is
    -- missing/invalid (PromptId construction, step numbering); 'mExId'
    -- (below) is the one that gates whether an 'Exercise' is actually
    -- built at all.
    exid = maybe (ExId "") id mExId

    mTypeField = case fieldValuesOf "type" exFields of { (f : _) -> Just f; [] -> Nothing }
    mIdField   = case fieldValuesOf "id" exFields of { (f : _) -> Just f; [] -> Nothing }
    typeTagsExtraKeys = case mTypeField of
      Just f | T.strip (flValue f) == "lookup" -> [("find", Req1), ("limit", Opt1)]
      _                                        -> []

    baseAllowed = [("type", Req1), ("id", Req1), ("cite", cardForCite), ("tags", Opt1)] ++ typeTagsExtraKeys
      where
        cardForCite = case mTypeField of
          Just f | T.strip (flValue f) == "lookup" -> OptMany
          _                                        -> ReqMany

    exFieldIssues = checkFieldBlock file exLoc baseAllowed exFields

    mKind = case fmap (T.strip . flValue) mTypeField of
      Just "quiz"   -> Just KQuiz
      Just "drill"  -> Just KDrill
      Just "lookup" -> Just KLookup
      _             -> Nothing

    typeUnknownIssue = case fmap (T.strip . flValue) mTypeField of
      Just t | t `notElem` (["quiz", "drill", "lookup"] :: [Text]), not (T.null t) ->
        [ mkIssue E_TYPE_UNKNOWN exLoc ("unknown type \"" <> t <> "\" (want quiz, drill or lookup)") ]
      _ -> []

    idSyntaxIssue = case mIdField of
      Just f | not (T.null (T.strip (flValue f))), not (isSlugLike (T.strip (flValue f))) ->
        [ mkIssue E_ID_SYNTAX (Loc file (flLine f)) ("id \"" <> flValue f <> "\" must match [a-z0-9-]+") ]
      _ -> []

    mExId = case mIdField of
      Just f | not (T.null (T.strip (flValue f))) -> Just (ExId (T.strip (flValue f)))
      _ -> Nothing

    exCiteFields = fieldValuesOf "cite" exFields
    (exCiteIssues, theExCites) = parseCitationFields file exCiteFields

    exTagsFieldM = case fieldValuesOf "tags" exFields of { (f : _) -> Just f; [] -> Nothing }
    (exTagIssues, theExTags) = parseTagsField file exTagsFieldM

    findFieldM = case fieldValuesOf "find" exFields of { (f : _) -> Just f; [] -> Nothing }
    (findIssues, mFindCitation) = case findFieldM of
      Nothing -> ([], Nothing)
      Just f | T.null (T.strip (flValue f)) -> ([], Nothing)
             | otherwise -> case parseCitationValue (flValue f) of
                 Just c  -> ([], Just c)
                 Nothing -> ( [ mkIssue E_CITE_SYNTAX (Loc file (flLine f))
                                  ("malformed find: expected <slug> <page> \"<anchor>\", got \"" <> flValue f <> "\"") ]
                            , Nothing )

    limitFieldM = case fieldValuesOf "limit" exFields of { (f : _) -> Just f; [] -> Nothing }
    (limitIssues, mLimit) = case limitFieldM of
      Nothing -> ([], Nothing)
      Just f | T.null (T.strip (flValue f)) -> ([], Nothing)
             | otherwise -> case parseDigits (T.strip (flValue f)) of
                 Just n | n >= 10 && n <= 600 -> ([], Just n)
                 _ -> ( [ mkIssue E_FIELD_SYNTAX (Loc file (flLine f))
                            ("limit: must be an integer 10..600, got \"" <> flValue f <> "\"") ]
                      , Nothing )

    (exBodyPre, roleChunks) = splitAtLevel 3 afterExFields
    bodyIndentedIssues = indentedHeadingIssues file exBodyPre

    -- Choice lists only apply to quiz exercises; for other types the
    -- raw body is block-parsed as-is.
    (mChoiceRaw, bodyAfterChoices) =
      if mKind == Just KQuiz then extractChoiceList exBodyPre else (Nothing, exBodyPre)
    exIntroBlocks = fst (parseBlocksEngine 0 False [] (map snd bodyAfterChoices))

    allowedRoleNames = case mKind of
      Just KQuiz   -> ["Why", "Hint", "Answer"]
      Just KDrill  -> ["Why", "Hint", "Step"]
      Just KLookup -> ["Why", "Hint"]
      Nothing      -> ["Why", "Hint", "Answer", "Step"]  -- degraded: type: itself already broken

    roleUnknownIssues =
      [ mkIssue E_ROLE_UNKNOWN (Loc file rln) ("unknown role \"### " <> rtxt <> "\"")
      | (rln, rtxt, _) <- roleChunks, T.strip rtxt `notElem` allowedRoleNames
      ]

    whyChunks    = [ rc | rc@(_, t, _) <- roleChunks, T.strip t == "Why" ]
    hintChunks   = [ rc | rc@(_, t, _) <- roleChunks, T.strip t == "Hint" ]
    answerChunks = [ rc | rc@(_, t, _) <- roleChunks, T.strip t == "Answer" ]
    stepChunks   = [ rc | rc@(_, t, _) <- roleChunks, T.strip t == "Step" ]

    whyRepeatIssue    = [ mkIssue E_ROLE_REPEATED (Loc file ln) "### Why may appear at most once"
                         | (ln, _, _) <- drop 1 whyChunks ]
    hintRepeatIssue   = [ mkIssue E_ROLE_REPEATED (Loc file ln) "### Hint may appear at most three times"
                         | (ln, _, _) <- drop 3 hintChunks ]
    answerRepeatIssue = [ mkIssue E_ROLE_REPEATED (Loc file ln) "### Answer may appear at most once"
                         | (ln, _, _) <- drop 1 answerChunks ]

    -- Why/Hint/Answer roles carry no fields of their own -- ANY
    -- field-shaped line there is unknown.
    roleNoFieldIssues =
      [ mkIssue E_FIELD_UNKNOWN (Loc file (flLine f)) ("unknown field \"" <> flKey f <> "\" (this role takes no fields)")
      | (_, rtxt, rlines) <- whyChunks ++ hintChunks ++ answerChunks
      , T.strip rtxt `elem` (["Why", "Hint", "Answer"] :: [Text])
      , let (fs, _) = scanFieldBlock rlines
      , f <- fs
      ]

    whyBlocks = case whyChunks of
      ((_, _, rlines) : _) -> fst (parseBlocksEngine 0 False [] (map snd (snd (scanFieldBlock rlines))))
      []                    -> []
    hintBlocksList = [ fst (parseBlocksEngine 0 False [] (map snd (snd (scanFieldBlock rlines))))
                      | (_, _, rlines) <- take 3 hintChunks ]
    answerBlocks = case answerChunks of
      ((_, _, rlines) : _) -> fst (parseBlocksEngine 0 False [] (map snd (snd (scanFieldBlock rlines))))
      []                    -> []

    -- Quiz mode inference: choice XOR recall, never both.
    hasChoiceList = case mChoiceRaw of { Just _ -> True; Nothing -> False }
    hasAnswerRole = not (null answerChunks)
    quizModeAmbiguous = mKind == Just KQuiz && hasChoiceList && hasAnswerRole
    quizModeAmbiguousIssue =
      [ mkIssue E_QUIZ_MODE_AMBIGUOUS exLoc
          "both a choice-mode task list and an ### Answer role are present; a quiz must use exactly one"
      | quizModeAmbiguous
      ]

    (choiceIssues, mChoicePrompt) = case mChoiceRaw of
      Nothing -> ([], Nothing)
      Just items ->
        let opts = [ Option (optIdFor i) (parseInline 0 label) correct
                   | (i, (_, correct, label)) <- zip [0 :: Int ..] items ]
            optIdFor i = T.singleton (toEnum (fromEnum 'a' + i))
            n = length items
            countIssue = [ mkIssue E_CHOICE_COUNT exLoc
                             ("choice list has " <> T.pack (show n) <> " options (want 2..6)")
                         | n < 2 || n > 6 ]
            correctIssue = [ mkIssue E_CHOICE_NO_CORRECT exLoc "no option is marked [x]"
                            | not (any optCorrect opts) ]
            -- M3 (gate finding): compared on NORMALISED, RENDERED label
            -- text (the same 'inlinesText' every learner-facing field is
            -- linted through), not raw Markdown source -- "A" and "**A**"
            -- are pairwise-distinct raw text but render identically, so a
            -- learner faced two visually indistinguishable choices before
            -- this fix.
            renderedLabels = [ inlinesText (optLabel o) | o <- opts ]
            dupIssue = [ mkIssue E_CHOICE_DUPLICATE exLoc "two or more option labels render identically"
                       | length renderedLabels /= length (dedupText renderedLabels) ]
        in (countIssue ++ correctIssue ++ dupIssue, Just (Choice opts))

    recallRequired = mKind == Just KQuiz && not hasChoiceList
    answerMissingIssue =
      [ mkIssue E_ROLE_MISSING exLoc "quiz recall mode requires exactly one ### Answer role"
      | recallRequired, null answerChunks
      ]
    mRecallPrompt = if recallRequired && not (null answerChunks) then Just (Recall answerBlocks) else Nothing

    -- Drill steps.
    stepCountIssue =
      [ mkIssue E_DRILL_STEP_COUNT exLoc ("drill has " <> T.pack (show (length stepChunks)) <> " ### Step roles (want >= 2)")
      | mKind == Just KDrill, length stepChunks < 2
      ]
    (stepIssuesAll, stepPromptsAll, stepCitesAll, stepVerifiesAll, stepLintTargetsAll) =
      unzip5 (zipWith (parseStep file exid) [1 :: Int ..] stepChunks)

    -- Lookup.
    findMissingIssue = [ mkIssue E_FIELD_MISSING exLoc "lookup requires a find: field"
                        | mKind == Just KLookup, isNothing mFindCitation, isNothing findFieldM ]
    lookupSpoilerIssue = case (mKind, mFindCitation) of
      (Just KLookup, Just target) | lookupSpoilerHits (citPage target) (blocksText exIntroBlocks) ->
        [ mkIssue E_LOOKUP_SPOILER exLoc "body text reveals the target page number" ]
      _ -> []
    mLookupPrompt = case (mKind, mFindCitation) of
      (Just KLookup, Just target) -> Just (FindPage target mLimit)
      _                            -> Nothing

    -- Assemble prompts, in type order.
    prompts = case mKind of
      Just KQuiz -> case (mChoicePrompt, mRecallPrompt) of
        (Just body, _) -> [ Prompt (promptIdFor exid 1) exIntroBlocks theExCites body ]
        (_, Just body) -> [ Prompt (promptIdFor exid 1) exIntroBlocks theExCites body ]
        _              -> []
      Just KDrill -> [ p | Just p <- stepPromptsAll ]
      Just KLookup -> case mLookupPrompt of
        Just body -> [ Prompt (promptIdFor exid 1) exIntroBlocks theExCites body ]
        Nothing   -> []
      Nothing -> []

    allIssues = concat
      [ exFieldIssues, typeUnknownIssue, idSyntaxIssue, exCiteIssues, exTagIssues
      , findIssues, limitIssues, bodyIndentedIssues, roleUnknownIssues
      , whyRepeatIssue, hintRepeatIssue, answerRepeatIssue, roleNoFieldIssues
      , quizModeAmbiguousIssue, choiceIssues, answerMissingIssue
      , stepCountIssue, concat stepIssuesAll, findMissingIssue, lookupSpoilerIssue
      ]

    mExercise = case (mExId, mKind) of
      (Just realExId, Just kind) | not (null prompts) || kind == KQuiz || kind == KLookup ->
        Just Exercise
          { exId      = realExId
          , exDeck    = deckId
          , exKind    = kind
          , exTitle   = exTitleTxt
          , exCites   = theExCites
          , exTags    = theExTags
          , exIntro   = exIntroBlocks
          , exPrompts = prompts
          , exNote    = whyBlocks
          , exHints   = hintBlocksList
          }
      _ -> Nothing

    cites = [ (exLoc, c) | c <- theExCites ] ++ concat stepCitesAll
              ++ [ (exLoc, t) | Just t <- [mFindCitation] ]
    verifies = concat stepVerifiesAll

    idRows = [ (exLoc, realExId, kind, deckChapterText) | Just realExId <- [mExId], Just kind <- [mKind] ]

    lintTargets = concat
      [ [ (exLoc, exTitleTxt) ]
      , [ (exLoc, blocksText exIntroBlocks) | not (null exIntroBlocks) ]
      , [ (exLoc, blocksText whyBlocks) | not (null whyBlocks) ]
      , [ (exLoc, blocksText hb) | hb <- hintBlocksList, not (null hb) ]
      , [ (exLoc, blocksText answerBlocks) | not (null answerBlocks) ]
      , case mChoicePrompt of
          Just (Choice opts) -> [ (exLoc, inlinesText (optLabel o)) | o <- opts ]
          _                   -> []
      , concat stepLintTargetsAll
      ]

dedupText :: [Text] -> [Text]
dedupText = go []
  where
    go seen [] = reverse seen
    go seen (x : xs) = if x `elem` seen then go seen xs else go (x : seen) xs

unzip5 :: [(a, b, c, d, e)] -> ([a], [b], [c], [d], [e])
unzip5 = foldr (\(a, b, c, d, e) (as, bs, cs, ds, es) -> (a : as, b : bs, c : cs, d : ds, e : es))
               ([], [], [], [], [])

--------------------------------------------------------------------------
-- One drill step (### Step)
--------------------------------------------------------------------------

parseStep
  :: Text -> ExId -> Int -> (Int, Text, [(Int, Text)])
  -> ([Issue], Maybe Prompt, [(Loc, Citation)], [(Loc, VerifySpec)], [(Loc, Text)])
parseStep file exid stepIndex (ln, _, rlines) = (allIssues, mPrompt, cites, verifies, lintTargets)
  where
    stepLoc = Loc file ln
    (stepFields, afterStepFields) = scanFieldBlock rlines
    -- "check" is cardinality Opt1 here (not Req1): a MISSING check: gets
    -- the dedicated E_DRILL_CHECK_MISSING code below
    -- ('checkMissingIssue'), not the generic E_FIELD_MISSING -- if it
    -- were Req1 too, both codes would fire for the same missing field.
    -- A REPEATED check: (cardinality > 1) still correctly reports the
    -- generic E_FIELD_DUPLICATE via Opt1's duplicate handling.
    fieldIssues = checkFieldBlock file stepLoc [("cite", ReqMany), ("check", Opt1), ("verify", Opt1)] stepFields

    citeFields = fieldValuesOf "cite" stepFields
    (citeIssues, stepCites) = parseCitationFields file citeFields

    checkFieldM = case fieldValuesOf "check" stepFields of { (f : _) -> Just f; [] -> Nothing }
    checkMissingIssue = [ mkIssue E_DRILL_CHECK_MISSING stepLoc "### Step requires a check: field"
                         | isNothing checkFieldM ]
    checkInline = maybe [] (parseInline 0 . flValue) checkFieldM

    verifyFieldM = case fieldValuesOf "verify" stepFields of { (f : _) -> Just f; [] -> Nothing }
    (verifyIssues, mVerify) = case verifyFieldM of
      Nothing -> ([], Nothing)
      Just f | T.null (T.strip (flValue f)) -> ([], Nothing)
             | otherwise -> case parseVerifyValue (flValue f) of
                 Just v  -> ([], Just v)
                 Nothing -> ([ mkIssue E_VERIFY_SYNTAX (Loc file (flLine f))
                                 ("malformed verify: \"" <> flValue f <> "\"") ], Nothing)

    stepBodyBlocks = fst (parseBlocksEngine 0 False [] (map snd afterStepFields))
    bodyIndentedIssues = indentedHeadingIssues file afterStepFields

    -- H5 (gate finding): EXERCISE-FORMAT.md requires a step's own body
    -- (after its field block) to be "the instruction text -- at least one
    -- block". A step carrying only 'cite:'/'check:' fields and no body
    -- text validated clean and rendered a Confirm button with nothing to
    -- confirm.
    bodyEmptyIssue = [ mkIssue E_DRILL_STEP_EMPTY stepLoc "### Step body must contain at least one block (instruction text)"
                     | null stepBodyBlocks ]

    -- 'stepIndex' is this step's 1-based position among ALL ### Step
    -- chunks in the exercise (in source order), independent of whether
    -- any OTHER step failed to parse -- so a step's 'PromptId' does not
    -- shift just because an earlier step in the same file is broken.
    mPrompt = if isNothing checkFieldM then Nothing
              else Just (Prompt (promptIdFor exid stepIndex) stepBodyBlocks stepCites (Confirm checkInline mVerify))

    allIssues = fieldIssues ++ citeIssues ++ checkMissingIssue ++ verifyIssues ++ bodyIndentedIssues ++ bodyEmptyIssue
    cites = [ (stepLoc, c) | c <- stepCites ]
    verifies = [ (stepLoc, v) | Just v <- [mVerify] ]

    -- H3 (gate finding, first half): a step's own body text and its
    -- 'check:' sentence are both "learner-facing text" per
    -- EXERCISE-FORMAT.md's own definition, but 'parseStep' never handed
    -- either to the terminology linter at all -- a drill's entire step
    -- prose was exempt from the binding glossary. Both are now real lint
    -- targets, exactly like every other learner-facing field.
    lintTargets =
      [ (stepLoc, inlinesText checkInline) | not (null checkInline) ]
        ++ [ (stepLoc, blocksText stepBodyBlocks) | not (null stepBodyBlocks) ]

--------------------------------------------------------------------------
-- Public projections
--------------------------------------------------------------------------

parseDeckDetailed
  :: FilePath -> Text
  -> ( [Issue], Maybe Deck
     , [(Loc, Citation)]
     , [(Loc, VerifySpec)]
     , Maybe (Loc, Text)
     , [(Loc, ExId, Kind, Text)]
     , [(Loc, Text)]
     )
parseDeckDetailed = parseDeckFull

parseDeck :: FilePath -> Text -> ([Issue], Maybe Deck)
parseDeck fp raw = let (i, d, _, _, _, _, _) = parseDeckFull fp raw in (i, d)
