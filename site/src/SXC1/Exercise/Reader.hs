{-# LANGUAGE OverloadedStrings #-}

-- | The @.ex.md@ STRUCTURAL reader -- the half of the grammar that turns
-- source text into a 'Deck', with no notion of "is this well-formed".
-- This is what @exe:app@ links: a learner's browser only ever needs to
-- RENDER a deck, never to validate one (validation, and the 40-code
-- diagnostic apparatus it needs, is a CI concern -- see
-- "SXC1.Exercise.Parse", "SXC1.Exercise.Report" and "SXC1.Exercise.Lint",
-- none of which this module imports, transitively or otherwise).
--
-- M3 gate finding (briefs\/M3-manifest.json, task
-- \"size-split-and-format\"): before this split, @site\/app\/Exercises\/Corpus.hs@
-- imported 'SXC1.Exercise.Parse', which imports "SXC1.Exercise.Report"
-- (the 40-constructor 'SXC1.Exercise.Report.StaticCode' enum, its Show\/
-- Enum\/Bounded instances, 'SXC1.Exercise.Report.renderReport') and
-- "SXC1.Exercise.Lint" (the terminology engine) -- and because there is no
-- @-split-sections@ in the cabal file, a module links as ONE ATOMIC UNIT,
-- so the browser carried the entire lint-and-diagnostics apparatus purely
-- to render a deck it would never lint. Measured saving: 45,878 gzip
-- bytes.
--
-- 'readDeck' and 'readDeckSyn' produce the SAME 'Deck' that
-- "SXC1.Exercise.Parse" reports issues against -- 'SXC1.Exercise.Parse'
-- calls 'readDeckSyn' exactly once per file and takes 'synDeck' from the
-- result directly; it never constructs a second 'Deck'. Every syntactic
-- intermediate the validator needs to compute a precise, per-line issue
-- (a field's own line and raw value, a role chunk's raw lines, a choice
-- list's raw items, ...) is carried on 'DeckSyn'\/'ExSyn'\/'StepSyn' so
-- the validator never has to re-scan raw text to get at it.
module SXC1.Exercise.Reader
  ( -- * Field-line scanning (the syntactic primitive shared with the
    -- validator -- see "SXC1.Exercise.Parse".checkFieldBlock, which reads
    -- 'FieldLine' values straight off 'DeckSyn'\/'ExSyn'\/'StepSyn'
    -- rather than re-scanning)
    FieldLine (..)
  , scanFieldBlock
  , fieldValuesOf
    -- * Filenames \/ slug shape
  , validFileName
  , isSlugLike
    -- * Structural splitting (headings at a given level)
  , splitAtLevel
    -- * Choice-list lifting (GFM task lists, lifted BEFORE block parsing)
  , taskListItemOf
  , checkboxOf
  , extractChoiceList
    -- * Field-value grammars
  , parseCitationValue
  , parseVerifyValue
  , parseTags
  , resolvedSlugList
  , kindOfTypeValue
    -- * The structural read
  , TitleResult (..)
  , DeckSyn (..)
  , ExSyn (..)
  , StepSyn (..)
  , readDeckSyn
  , readDeck
  ) where

import           Data.Maybe             (isNothing, mapMaybe)
import           Data.Text              (Text)
import qualified Data.Text              as T

import           SXC1.Content.Markdown  (bulletItemOf, headingLineOf, parseBlocksEngine, parseInline)
import           SXC1.Content.Types     (Block, Inline)
import           SXC1.Exercise.Types
import           SXC1.Route              (parseDigits)

--------------------------------------------------------------------------
-- Small text-shape helpers (no regex engine anywhere)
--------------------------------------------------------------------------

isLowerAscii :: Char -> Bool
isLowerAscii c = c >= 'a' && c <= 'z'

isDigitChar :: Char -> Bool
isDigitChar c = c >= '0' && c <= '9'

isSlugChar :: Char -> Bool
isSlugChar c = isLowerAscii c || isDigitChar c || c == '-'

-- | @[a-z0-9-]+@, not starting or ending with @-@ -- the shape shared by
-- @deck:@ ids and exercise @id:@ values (both surface as @E_ID_SYNTAX@ on
-- the validator side).
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

-- | @^[0-9]{2,3}-[a-z0-9-]+\.ex\.md$@ -- two OR three leading digits.
-- M2 shipped four decks as @NN-@; M3's 52-deck course (briefs\/M3-plan.md
-- \1672.4) numbers files @NNN-@ spaced by 2 so a deck can be inserted
-- without renumbering -- 52 decks spaced by 2 cannot fit two digits.
-- Both widths stay valid: renaming the M2 seed decks would have churned
-- history for no benefit.
validFileName :: FilePath -> Bool
validFileName fp = case T.stripSuffix ".ex.md" (baseNameOf fp) of
  Nothing   -> False
  Just stem ->
    let (nn, rest) = T.span isDigitChar stem
    in (T.length nn == 2 || T.length nn == 3)
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

firstField :: Text -> [FieldLine] -> Maybe FieldLine
firstField key fs = case fieldValuesOf key fs of { (f : _) -> Just f; [] -> Nothing }

-- | The first occurrence of @key@ whose value is non-blank -- the shape
-- shared by @chapter:@ (Deck-building) and every other "gate on presence
-- AND non-blankness" field.
firstNonBlankField :: Text -> [FieldLine] -> Maybe FieldLine
firstNonBlankField key fs = case [ f | f <- fieldValuesOf key fs, not (T.null (T.strip (flValue f))) ] of
  (f : _) -> Just f
  []      -> Nothing

--------------------------------------------------------------------------
-- Structural splitting -- headings at a given level, column-0 only
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
-- Choice lists (GFM task lists, lifted BEFORE block parsing)
--------------------------------------------------------------------------

-- | A top-level (indent 0) task-list item.
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
      | i >= n                           = 0
      | Just _ <- taskListItemOf (at i) = 1 + runLenFrom (i + 1)
      | otherwise                        = 0
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
-- Tags / slug lists -- shared shape for tags: AND requires:
--------------------------------------------------------------------------

parseTags :: Text -> Maybe [Text]
parseTags v =
  let items = map T.strip (T.splitOn "," v)
  in if all isSlugLike items && not (null items) then Just items else Nothing

-- | The Deck-building projection of an optional comma-separated slug-list
-- field (@tags:@, @requires:@): missing or blank -> @[]@; present,
-- non-blank and malformed -> @[]@ too (the malformed case gets a real
-- issue -- @E_FIELD_SYNTAX@ -- on the validator side; structurally it
-- degrades the same way a missing field does, exactly as today's
-- @tags:@ handling already did).
resolvedSlugList :: Maybe FieldLine -> [Text]
resolvedSlugList Nothing = []
resolvedSlugList (Just f)
  | T.null (T.strip (flValue f)) = []
  | otherwise                    = maybe [] id (parseTags (flValue f))

--------------------------------------------------------------------------
-- type: interpretation -- shared by Deck-building (which prompt shape to
-- build) and the validator (role sets, step-count / find: requirements).
--------------------------------------------------------------------------

kindOfTypeValue :: Text -> Maybe Kind
kindOfTypeValue "quiz"   = Just KQuiz
kindOfTypeValue "drill"  = Just KDrill
kindOfTypeValue "lookup" = Just KLookup
kindOfTypeValue _        = Nothing

--------------------------------------------------------------------------
-- The structural read
--------------------------------------------------------------------------

-- | The three ways the deck-title line can come out. 'TitleOk' carries
-- the line number the title's own 'Loc' is anchored at everywhere else in
-- the file (the validator's @deckAnchorLoc@); 'TitleEmpty'\/'TitleBad'
-- are exactly the two ways @E_FILE_TITLE@ can fire on the validator side.
data TitleResult
  = TitleEmpty
  | TitleBad !Int
  | TitleOk !Int !Text
  deriving (Eq)

-- | Everything 'readDeckSyn' learns about one deck file: the final
-- 'Deck' (Nothing if the two structural preconditions -- a real @deck:@
-- id and a real title -- were not met), plus every raw field\/chunk the
-- validator needs to compute precise per-line issues without re-scanning
-- the source itself.
data DeckSyn = DeckSyn
  { synTitleResult    :: !TitleResult
  , synAfterTitle     :: [(Int, Text)]
  , synDeckFields     :: [FieldLine]
  , synAfterDeckFields :: [(Int, Text)]
  , synDeckBodyPre    :: [(Int, Text)]
  , synDeckIntroBlocks   :: [Block]        -- ^ == 'dkIntro'; also a lint target
  , synDeckSummaryInline :: [Inline]       -- ^ == 'dkSummary'; also a lint target
  , synExerciseChunks :: [(Int, Text, [(Int, Text)])]
  , synDeckIdField    :: Maybe FieldLine
  , synChapterField   :: Maybe FieldLine  -- ^ first non-blank @chapter:@
  , synDeckCiteFields :: [FieldLine]
  , synDeckCites      :: [Citation]       -- ^ successfully-parsed subset; == 'dkCites'
  , synTagsField      :: Maybe FieldLine
  , synRequiresField  :: Maybe FieldLine
  , synTierField      :: Maybe FieldLine
  , synExercises      :: [ExSyn]
  , synDeck           :: Maybe Deck
  }

-- | One @##@ exercise chunk, structurally.
data ExSyn = ExSyn
  { synExHeadLn       :: !Int
  , synExTitleTxt     :: !Text
  , synExFields       :: [FieldLine]
  , synExAfterFields  :: [(Int, Text)]
  , synExTypeField    :: Maybe FieldLine
  , synExIdField      :: Maybe FieldLine
  , synExId           :: Maybe ExId        -- ^ Just iff id: present & non-blank
  , synExKind         :: Maybe Kind
  , synExCiteFields   :: [FieldLine]
  , synExCites        :: [Citation]
  , synExTagsField    :: Maybe FieldLine
  , synExTags         :: [Text]
  , synExFindField    :: Maybe FieldLine
  , synExFindCitation :: Maybe Citation
  , synExLimitField   :: Maybe FieldLine
  , synExLimit        :: Maybe Int
  , synExBodyPre      :: [(Int, Text)]
  , synExChoiceRaw    :: Maybe [(Int, Bool, Text)]
  , synExIntroBlocks  :: [Block]
  , synExRoleChunks   :: [(Int, Text, [(Int, Text)])]
  , synExWhyBlocks       :: [Block]
  , synExHintBlocksList  :: [[Block]]
  , synExAnswerBlocks    :: [Block]
  , synExChoicePrompt    :: Maybe PromptBody
  , synExRecallPrompt    :: Maybe PromptBody
  , synExLookupPrompt    :: Maybe PromptBody
  , synExSteps           :: [StepSyn]
  , synExPrompts         :: [Prompt]
  , synExercise          :: Maybe Exercise
  }

-- | One @### Step@ chunk, structurally.
data StepSyn = StepSyn
  { synStLn          :: !Int
  , synStFields      :: [FieldLine]
  , synStAfterFields :: [(Int, Text)]
  , synStCiteFields  :: [FieldLine]
  , synStCites       :: [Citation]
  , synStCheckField  :: Maybe FieldLine
  , synStCheckInline :: [Inline]
  , synStVerifyField :: Maybe FieldLine
  , synStVerify      :: Maybe VerifySpec
  , synStBodyBlocks  :: [Block]
  , synStPrompt      :: Maybe Prompt
  }

readDeck :: FilePath -> Text -> Maybe Deck
readDeck fp raw = synDeck (readDeckSyn fp raw)

readDeckSyn :: FilePath -> Text -> DeckSyn
readDeckSyn fp raw = DeckSyn
  { synTitleResult     = titleResult
  , synAfterTitle      = afterTitle
  , synDeckFields      = deckFields
  , synAfterDeckFields = afterDeckFields
  , synDeckBodyPre     = deckBodyPre
  , synDeckIntroBlocks    = deckIntroBlocks
  , synDeckSummaryInline  = deckSummaryInline
  , synExerciseChunks  = exerciseChunks
  , synDeckIdField     = mDeckIdField
  , synChapterField    = mChapterField
  , synDeckCiteFields  = deckCiteFields
  , synDeckCites       = deckCites
  , synTagsField       = mTagsField
  , synRequiresField   = mRequiresField
  , synTierField       = mTierField
  , synExercises       = exSyns
  , synDeck            = mDeck
  }
  where
    numbered = zip [1 :: Int ..] (T.lines raw)
    nonBlank = dropWhile (isBlankL . snd) numbered

    (titleResult, afterTitle) = case nonBlank of
      [] -> (TitleEmpty, [])
      ((ln, l) : rest) -> case headingLineOf l of
        Just (1, txt) -> (TitleOk ln txt, rest)
        _             -> (TitleBad ln, rest)

    (deckFields, afterDeckFields) = scanFieldBlock afterTitle

    mDeckIdField  = firstField "deck" deckFields
    mChapterField = firstNonBlankField "chapter" deckFields
    deckCiteFields = fieldValuesOf "cite" deckFields
    mTagsField     = firstField "tags" deckFields
    mRequiresField = firstField "requires" deckFields
    mTierField     = firstField "tier" deckFields

    deckCites = [ c | f <- deckCiteFields, not (T.null (T.strip (flValue f))), Just c <- [parseCitationValue (flValue f)] ]
    deckTags     = resolvedSlugList mTagsField
    deckRequires = resolvedSlugList mRequiresField
    deckTier     = maybe "" (T.strip . flValue) mTierField

    (deckBodyPre, exerciseChunks) = splitAtLevel 2 afterDeckFields
    deckIntroBlocks = fst (parseBlocksEngine 0 False [] (map snd deckBodyPre))
    deckSummaryInline = case firstField "summary" deckFields of
      Just f  -> parseInline 0 (flValue f)
      Nothing -> []
    titleText = case titleResult of { TitleOk _ t -> t; _ -> "" }

    deckIdForExercises = DeckId (maybe "" (T.strip . flValue) mDeckIdField)

    exSyns = map (readExSyn fp deckIdForExercises) exerciseChunks
    exercises = mapMaybe synExercise exSyns

    mDeck = case (mDeckIdField, titleResult) of
      (Just idF, TitleOk _ _) | not (T.null (T.strip (flValue idF))) ->
        Just Deck
          { dkId        = deckIdForExercises
          , dkTitle     = titleText
          , dkChapter   = maybe "" flValue mChapterField
          , dkSummary   = deckSummaryInline
          , dkCites     = deckCites
          , dkIntro     = deckIntroBlocks
          , dkTags      = deckTags
          , dkTier      = deckTier
          , dkRequires  = deckRequires
          , dkExercises = exercises
          }
      _ -> Nothing

--------------------------------------------------------------------------
-- One exercise (## heading)
--------------------------------------------------------------------------

readExSyn :: FilePath -> DeckId -> (Int, Text, [(Int, Text)]) -> ExSyn
readExSyn _fp deckId (headLn, exTitleTxt, chunkLines) = ExSyn
  { synExHeadLn       = headLn
  , synExTitleTxt     = exTitleTxt
  , synExFields       = exFields
  , synExAfterFields  = afterExFields
  , synExTypeField    = mTypeField
  , synExIdField      = mIdField
  , synExId           = mExId
  , synExKind         = mKind
  , synExCiteFields   = exCiteFields
  , synExCites        = theExCites
  , synExTagsField    = exTagsFieldM
  , synExTags         = theExTags
  , synExFindField    = findFieldM
  , synExFindCitation = mFindCitation
  , synExLimitField   = limitFieldM
  , synExLimit        = mLimit
  , synExBodyPre      = exBodyPre
  , synExChoiceRaw    = mChoiceRaw
  , synExIntroBlocks  = exIntroBlocks
  , synExRoleChunks   = roleChunks
  , synExWhyBlocks      = whyBlocks
  , synExHintBlocksList = hintBlocksList
  , synExAnswerBlocks   = answerBlocks
  , synExChoicePrompt   = mChoicePrompt
  , synExRecallPrompt   = mRecallPrompt
  , synExLookupPrompt   = mLookupPrompt
  , synExSteps          = stepSyns
  , synExPrompts        = prompts
  , synExercise         = mExercise
  }
  where
    (exFields, afterExFields) = scanFieldBlock chunkLines

    mTypeField = firstField "type" exFields
    mIdField   = firstField "id" exFields

    mKind = mTypeField >>= kindOfTypeValue . T.strip . flValue

    mExId = case mIdField of
      Just f | not (T.null (T.strip (flValue f))) -> Just (ExId (T.strip (flValue f)))
      _ -> Nothing
    exid = maybe (ExId "") id mExId

    exCiteFields = fieldValuesOf "cite" exFields
    theExCites = [ c | f <- exCiteFields, not (T.null (T.strip (flValue f))), Just c <- [parseCitationValue (flValue f)] ]

    exTagsFieldM = firstField "tags" exFields
    theExTags = resolvedSlugList exTagsFieldM

    findFieldM = firstField "find" exFields
    mFindCitation = case findFieldM of
      Nothing -> Nothing
      Just f | T.null (T.strip (flValue f)) -> Nothing
             | otherwise                    -> parseCitationValue (flValue f)

    limitFieldM = firstField "limit" exFields
    mLimit = case limitFieldM of
      Nothing -> Nothing
      Just f | T.null (T.strip (flValue f)) -> Nothing
             | otherwise -> case parseDigits (T.strip (flValue f)) of
                 Just n | n >= 10 && n <= 600 -> Just n
                 _                            -> Nothing

    (exBodyPre, roleChunks) = splitAtLevel 3 afterExFields

    (mChoiceRaw, bodyAfterChoices) =
      if mKind == Just KQuiz then extractChoiceList exBodyPre else (Nothing, exBodyPre)
    exIntroBlocks = fst (parseBlocksEngine 0 False [] (map snd bodyAfterChoices))

    whyChunks    = [ rc | rc@(_, t, _) <- roleChunks, T.strip t == "Why" ]
    hintChunks   = [ rc | rc@(_, t, _) <- roleChunks, T.strip t == "Hint" ]
    answerChunks = [ rc | rc@(_, t, _) <- roleChunks, T.strip t == "Answer" ]
    stepChunks   = [ rc | rc@(_, t, _) <- roleChunks, T.strip t == "Step" ]

    whyBlocks = case whyChunks of
      ((_, _, rlines) : _) -> fst (parseBlocksEngine 0 False [] (map snd (snd (scanFieldBlock rlines))))
      []                    -> []
    hintBlocksList = [ fst (parseBlocksEngine 0 False [] (map snd (snd (scanFieldBlock rlines))))
                      | (_, _, rlines) <- take 3 hintChunks ]
    answerBlocks = case answerChunks of
      ((_, _, rlines) : _) -> fst (parseBlocksEngine 0 False [] (map snd (snd (scanFieldBlock rlines))))
      []                    -> []

    hasChoiceList = case mChoiceRaw of { Just _ -> True; Nothing -> False }

    mChoicePrompt = case mChoiceRaw of
      Nothing -> Nothing
      Just items ->
        let opts = [ Option (optIdFor i) (parseInline 0 label) correct
                   | (i, (_, correct, label)) <- zip [0 :: Int ..] items ]
            optIdFor i = T.singleton (toEnum (fromEnum 'a' + i))
        in Just (Choice opts)

    recallRequired = mKind == Just KQuiz && not hasChoiceList
    mRecallPrompt = if recallRequired && not (null answerChunks) then Just (Recall answerBlocks) else Nothing

    stepSyns = zipWith (readStepSyn deckId exid) [1 :: Int ..] stepChunks

    mLookupPrompt = case (mKind, mFindCitation) of
      (Just KLookup, Just target) -> Just (FindPage target mLimit)
      _                           -> Nothing

    prompts = case mKind of
      Just KQuiz -> case (mChoicePrompt, mRecallPrompt) of
        (Just body, _) -> [ Prompt (promptIdFor exid 1) exIntroBlocks theExCites body ]
        (_, Just body) -> [ Prompt (promptIdFor exid 1) exIntroBlocks theExCites body ]
        _              -> []
      Just KDrill -> [ p | Just p <- map synStPrompt stepSyns ]
      Just KLookup -> case mLookupPrompt of
        Just body -> [ Prompt (promptIdFor exid 1) exIntroBlocks theExCites body ]
        Nothing   -> []
      Nothing -> []

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

--------------------------------------------------------------------------
-- One drill step (### Step)
--------------------------------------------------------------------------

readStepSyn :: DeckId -> ExId -> Int -> (Int, Text, [(Int, Text)]) -> StepSyn
readStepSyn _deckId exid stepIndex (ln, _, rlines) = StepSyn
  { synStLn          = ln
  , synStFields      = stepFields
  , synStAfterFields = afterStepFields
  , synStCiteFields  = citeFields
  , synStCites       = stepCites
  , synStCheckField  = checkFieldM
  , synStCheckInline = checkInline
  , synStVerifyField = verifyFieldM
  , synStVerify      = mVerify
  , synStBodyBlocks  = stepBodyBlocks
  , synStPrompt      = mPrompt
  }
  where
    (stepFields, afterStepFields) = scanFieldBlock rlines

    citeFields = fieldValuesOf "cite" stepFields
    stepCites = [ c | f <- citeFields, not (T.null (T.strip (flValue f))), Just c <- [parseCitationValue (flValue f)] ]

    checkFieldM = firstField "check" stepFields
    checkInline = maybe [] (parseInline 0 . flValue) checkFieldM

    verifyFieldM = firstField "verify" stepFields
    mVerify = case verifyFieldM of
      Nothing -> Nothing
      Just f | T.null (T.strip (flValue f)) -> Nothing
             | otherwise                    -> parseVerifyValue (flValue f)

    stepBodyBlocks = fst (parseBlocksEngine 0 False [] (map snd afterStepFields))

    mPrompt = if isNothing checkFieldM then Nothing
              else Just (Prompt (promptIdFor exid stepIndex) stepBodyBlocks stepCites (Confirm checkInline mVerify))
