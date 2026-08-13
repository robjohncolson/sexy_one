{-# LANGUAGE OverloadedStrings #-}

-- | The @.ex.md@ VALIDATING parser -- issue emission layered directly on
-- top of "SXC1.Exercise.Reader"'s structural read. This module is a CI
-- concern (@exe:content-check@\/@exe:exercise-check@ link it; @exe:app@
-- never does -- see "SXC1.Exercise.Reader"'s Haddock for the size
-- history).
--
-- M3 gate (briefs\/M3-manifest.json, task \"size-split-and-format\"):
-- 'parseDeck' and 'parseDeckDetailed' keep their exact pre-M3 signatures
-- and behaviour, but the 'Deck' they return is now the ONE
-- "SXC1.Exercise.Reader".'SXC1.Exercise.Reader.readDeckSyn' built --
-- 'parseDeckFull' calls it exactly once per file and takes 'synDeck'
-- straight out of the result; this module never constructs a second
-- 'Deck'. Every syntactic intermediate an issue needs (a field's own
-- line, a role chunk's raw lines, a choice list's raw items, ...) comes
-- off the 'DeckSyn'\/'ExSyn'\/'StepSyn' tree 'readDeckSyn' already built,
-- never from a fresh scan of the raw text -- the handful of grammar
-- primitives this module DOES call directly (`parseCitationValue`,
-- `parseVerifyValue`, `parseTags`, `scanFieldBlock`) are the SAME
-- functions "SXC1.Exercise.Reader" itself used to build that tree, so
-- calling them again on a value already stored on the tree can never
-- disagree with what the tree encodes -- it is the one place a field's
-- raw text is inspected a second time, and only ever through that one
-- shared, pure grammar function.
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

import           SXC1.Content.Markdown  (headingLineOf)
import           SXC1.Content.Types     (Block (..), ListItem (liChildren))
import           SXC1.Exercise.Lint     (blocksText, findOccurrencesCI, inlinesText)
import           SXC1.Exercise.Reader
import           SXC1.Exercise.Report
import           SXC1.Exercise.Types

--------------------------------------------------------------------------
-- Cardinality of an allowed field key within a given field-block context,
-- and the generic field-block validator (unknown/empty/duplicate/missing
-- -- see 'FieldLine', imported from "SXC1.Exercise.Reader").
--------------------------------------------------------------------------

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

-- | The Deck\/exercise-level projection of "a comma-separated
-- @[a-z0-9-]+@ list field" (@tags:@, @requires:@): missing or blank ->
-- no issue (a missing REQUIRED field is 'checkFieldBlock''s
-- @E_FIELD_MISSING@; a blank one is its @E_FIELD_EMPTY@); present,
-- non-blank and malformed -> @E_FIELD_SYNTAX@. Calls
-- 'SXC1.Exercise.Reader.parseTags' -- the SAME function
-- 'SXC1.Exercise.Reader.resolvedSlugList' used to build the Deck\/
-- Exercise's own tag\/requires list -- so this can never disagree with
-- what actually got stored there.
tagsLikeSyntaxIssues :: Text -> Text -> Maybe FieldLine -> [Issue]
tagsLikeSyntaxIssues file label mField = case mField of
  Nothing -> []
  Just f | T.null (T.strip (flValue f)) -> []
         | Just _ <- parseTags (flValue f) -> []
         | otherwise ->
             [ mkIssue E_FIELD_SYNTAX (Loc file (flLine f))
                 ("malformed " <> label <> ": expected comma-separated [a-z0-9-]+, got \"" <> flValue f <> "\"") ]

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
-- Lookup spoiler scan
--------------------------------------------------------------------------

isDigitCharP :: Char -> Bool
isDigitCharP c = c >= '0' && c <= '9'

lookupSpoilerHits :: Int -> Text -> Bool
lookupSpoilerHits target text = any tryForm forms
  where
    targetTxt = T.pack (show target)
    forms = [ "p. " <> targetTxt, "p." <> targetTxt, "page " <> targetTxt, "pages " <> targetTxt ]
    tryForm f = any (boundaryOk f) (findOccurrencesCI f text)
    boundaryOk f off =
      let after = off + T.length f
      in after >= T.length text || not (isDigitCharP (T.index text after))

--------------------------------------------------------------------------
-- Small helper
--------------------------------------------------------------------------

dedupText :: [Text] -> [Text]
dedupText = go []
  where
    go seen [] = reverse seen
    go seen (x : xs) = if x `elem` seen then go seen xs else go (x : seen) xs

unzip4Local :: [(a, b, c, d)] -> ([a], [b], [c], [d])
unzip4Local = foldr (\(a, b, c, d) (as, bs, cs, ds) -> (a : as, b : bs, c : cs, d : ds)) ([], [], [], [])

unzip5Local :: [(a, b, c, d, e)] -> ([a], [b], [c], [d], [e])
unzip5Local = foldr (\(a, b, c, d, e) (as, bs, cs, ds, es) -> (a : as, b : bs, c : cs, d : ds, e : es))
                     ([], [], [], [], [])

--------------------------------------------------------------------------
-- The full parse -- issues, the Deck (if buildable, taken directly from
-- "SXC1.Exercise.Reader"), and everything a resolution pass
-- (SXC1.Exercise.Verify) needs but Citation/VerifySpec/Deck themselves
-- have no room for.
--------------------------------------------------------------------------

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
    syn  = readDeckSyn fp raw

    fileNameIssues = [ mkIssue E_FILE_BAD_NAME (Loc file 1) ("bad file name: " <> T.pack fp) | not (validFileName fp) ]

    titleIssues = case synTitleResult syn of
      TitleEmpty  -> [ mkIssue E_FILE_TITLE (Loc file 1) "file is empty (no deck title line)" ]
      TitleBad ln -> [ mkIssue E_FILE_TITLE (Loc file ln) "the first non-blank line must be a single '#' deck title" ]
      TitleOk _ _ -> []

    titleText = case synTitleResult syn of { TitleOk _ t -> t; _ -> "" }

    mTitleLoc = case synTitleResult syn of
      TitleOk ln _ -> Just (Loc file ln)
      _            -> Nothing

    -- "exactly ONE '#' in the file": any FURTHER level-1 heading is a
    -- second E_FILE_TITLE issue.
    extraTitleIssues =
      [ mkIssue E_FILE_TITLE (Loc file ln) "a second top-level '#' heading is not allowed in one deck file"
      | (ln, l) <- synAfterTitle syn, Just (1, _) <- [headingLineOf l]
      ]

    deckAnchorLoc = maybe (Loc file 1) id mTitleLoc

    deckFields = synDeckFields syn
    deckFieldIssues = checkFieldBlock file deckAnchorLoc
      [ ("deck", Req1), ("chapter", Req1), ("summary", Req1), ("cite", ReqMany), ("tags", Opt1)
      , ("tier", Req1), ("requires", Opt1)
      ]
      deckFields

    mDeckIdField = synDeckIdField syn

    deckIdSyntaxIssues = case mDeckIdField of
      Just f | not (T.null (T.strip (flValue f))), not (isSlugLike (T.strip (flValue f))) ->
        [ mkIssue E_ID_SYNTAX (Loc file (flLine f)) ("deck id \"" <> flValue f <> "\" must match [a-z0-9-]+") ]
      _ -> []

    deckCiteIssues =
      [ mkIssue E_CITE_SYNTAX (Loc file (flLine f))
          ("malformed cite: expected <slug> <page> \"<anchor>\", got \"" <> flValue f <> "\"")
      | f <- synDeckCiteFields syn
      , not (T.null (T.strip (flValue f)))
      , Nothing <- [parseCitationValue (flValue f)]
      ]

    deckTagIssues     = tagsLikeSyntaxIssues file "tags" (synTagsField syn)
    deckRequiresIssue = tagsLikeSyntaxIssues file "requires" (synRequiresField syn)

    tierUnknownIssue = case fmap (T.strip . flValue) (synTierField syn) of
      Just t | t `notElem` (["intro", "core", "stretch"] :: [Text]), not (T.null t) ->
        [ mkIssue E_DECK_TIER_UNKNOWN deckAnchorLoc ("unknown tier \"" <> t <> "\" (want intro, core or stretch)") ]
      _ -> []

    deckBodyIndentedIssues = indentedHeadingIssues file (synDeckBodyPre syn)

    mDeck = synDeck syn

    mChapterField = case synChapterField syn of
      Just f  -> Just (Loc file (flLine f), flValue f)
      Nothing -> Nothing
    deckChapterTextForRows = maybe "" flValue (synChapterField syn)

    -- 'null exercises' is checked INDEPENDENTLY of whether the Deck
    -- itself builds (a bad title/id does not suppress this issue) -- see
    -- 'SXC1.Exercise.Reader.synExercise'.
    deckEmptyIssue =
      [ mkIssue E_DECK_EMPTY deckAnchorLoc "deck has no exercises"
      | null (mapMaybe synExercise (synExercises syn))
      ]

    (exIssuesAll, exCitesAll, exVerifiesAll, idRowsAll, exLintTargetsAll) =
      unzip5Local (map (exerciseOutputs file deckChapterTextForRows) (synExercises syn))

    allIssues = concat
      [ fileNameIssues, titleIssues, extraTitleIssues, deckFieldIssues, deckIdSyntaxIssues
      , deckCiteIssues, deckTagIssues, deckRequiresIssue, tierUnknownIssue
      , deckBodyIndentedIssues, deckEmptyIssue
      , concat exIssuesAll, deckUnparsedIssues file deckAnchorLoc mDeck
      ]

    allCites    = [ (deckAnchorLoc, c) | c <- synDeckCites syn ] ++ concat exCitesAll
    allVerifies = concat exVerifiesAll
    idRows      = concat idRowsAll
    lintTargets =
      [ (deckAnchorLoc, titleText) ]
        ++ [ (deckAnchorLoc, inlinesText (synDeckSummaryInline syn)) | not (null (synDeckSummaryInline syn)) ]
        ++ [ (deckAnchorLoc, blocksText (synDeckIntroBlocks syn)) | not (null (synDeckIntroBlocks syn)) ]
        ++ concat exLintTargetsAll

--------------------------------------------------------------------------
-- One exercise (## heading) -- issues + external returns, read off the
-- 'ExSyn' "SXC1.Exercise.Reader".readDeckSyn already built.
--------------------------------------------------------------------------

exerciseOutputs
  :: Text -> Text -> ExSyn
  -> ([Issue], [(Loc, Citation)], [(Loc, VerifySpec)], [(Loc, ExId, Kind, Text)], [(Loc, Text)])
exerciseOutputs file deckChapterText exS =
  (allIssues, cites, verifies, idRows, lintTargets)
  where
    exLoc = Loc file (synExHeadLn exS)
    mTypeField = synExTypeField exS
    mKind = synExKind exS

    typeTagsExtraKeys = case mTypeField of
      Just f | T.strip (flValue f) == "lookup" -> [("find", Req1), ("limit", Opt1)]
      _                                        -> []
    baseAllowed = [("type", Req1), ("id", Req1), ("cite", cardForCite), ("tags", Opt1)] ++ typeTagsExtraKeys
      where
        cardForCite = case mTypeField of
          Just f | T.strip (flValue f) == "lookup" -> OptMany
          _                                        -> ReqMany

    exFieldIssues = checkFieldBlock file exLoc baseAllowed (synExFields exS)

    typeUnknownIssue = case fmap (T.strip . flValue) mTypeField of
      Just t | t `notElem` (["quiz", "drill", "lookup"] :: [Text]), not (T.null t) ->
        [ mkIssue E_TYPE_UNKNOWN exLoc ("unknown type \"" <> t <> "\" (want quiz, drill or lookup)") ]
      _ -> []

    idSyntaxIssue = case synExIdField exS of
      Just f | not (T.null (T.strip (flValue f))), not (isSlugLike (T.strip (flValue f))) ->
        [ mkIssue E_ID_SYNTAX (Loc file (flLine f)) ("id \"" <> flValue f <> "\" must match [a-z0-9-]+") ]
      _ -> []

    exCiteIssues =
      [ mkIssue E_CITE_SYNTAX (Loc file (flLine f))
          ("malformed cite: expected <slug> <page> \"<anchor>\", got \"" <> flValue f <> "\"")
      | f <- synExCiteFields exS
      , not (T.null (T.strip (flValue f)))
      , Nothing <- [parseCitationValue (flValue f)]
      ]

    exTagIssues = tagsLikeSyntaxIssues file "tags" (synExTagsField exS)

    findIssues = case synExFindField exS of
      Nothing -> []
      Just f | T.null (T.strip (flValue f)) -> []
             | Nothing <- parseCitationValue (flValue f) ->
                 [ mkIssue E_CITE_SYNTAX (Loc file (flLine f))
                     ("malformed find: expected <slug> <page> \"<anchor>\", got \"" <> flValue f <> "\"") ]
             | otherwise -> []

    limitIssues = case synExLimitField exS of
      Nothing -> []
      Just f | T.null (T.strip (flValue f)) -> []
             | isNothing (synExLimit exS) ->
                 [ mkIssue E_FIELD_SYNTAX (Loc file (flLine f))
                     ("limit: must be an integer 10..600, got \"" <> flValue f <> "\"") ]
             | otherwise -> []

    bodyIndentedIssues = indentedHeadingIssues file (synExBodyPre exS)

    roleChunks = synExRoleChunks exS

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
    stepChunksMeta = [ rc | rc@(_, t, _) <- roleChunks, T.strip t == "Step" ]

    whyRepeatIssue    = [ mkIssue E_ROLE_REPEATED (Loc file ln) "### Why may appear at most once"
                         | (ln, _, _) <- drop 1 whyChunks ]
    hintRepeatIssue   = [ mkIssue E_ROLE_REPEATED (Loc file ln) "### Hint may appear at most three times"
                         | (ln, _, _) <- drop 3 hintChunks ]
    answerRepeatIssue = [ mkIssue E_ROLE_REPEATED (Loc file ln) "### Answer may appear at most once"
                         | (ln, _, _) <- drop 1 answerChunks ]

    -- Why/Hint carry no fields. Answer may carry one learner-visible
    -- distractor, which turns a recall-only quiz into a binary flashcard.
    roleNoFieldIssues =
      [ mkIssue E_FIELD_UNKNOWN (Loc file (flLine f)) ("unknown field \"" <> flKey f <> "\" (this role takes no fields)")
      | (_, rtxt, rlines) <- whyChunks ++ hintChunks
      , T.strip rtxt `elem` (["Why", "Hint"] :: [Text])
      , let (fs, _) = scanFieldBlock rlines
      , f <- fs
      ]
    answerFieldIssues = concat
      [ checkFieldBlock file (Loc file rln) [("distractor", Opt1)] fs
      | (rln, _, rlines) <- answerChunks
      , let (fs, _) = scanFieldBlock rlines
      ]

    hasChoiceList = case synExChoiceRaw exS of { Just _ -> True; Nothing -> False }
    hasAnswerRole = not (null answerChunks)
    quizModeAmbiguous = mKind == Just KQuiz && hasChoiceList && hasAnswerRole
    quizModeAmbiguousIssue =
      [ mkIssue E_QUIZ_MODE_AMBIGUOUS exLoc
          "both a choice-mode task list and an ### Answer role are present; a quiz must use exactly one"
      | quizModeAmbiguous
      ]

    -- Reuses the ALREADY-BUILT 'Choice' options (from
    -- "SXC1.Exercise.Reader") rather than reconstructing them.
    choiceIssues = concatMap checkChoice [synExChoicePrompt exS, synExFlashPrompt exS]
      where
        checkChoice (Just (Choice opts)) =
          let n = length opts
              countIssue = [ mkIssue E_CHOICE_COUNT exLoc
                               ("choice list has " <> T.pack (show n) <> " options (want 2..6)")
                           | n < 2 || n > 6 ]
              correctIssue = [ mkIssue E_CHOICE_NO_CORRECT exLoc "no option is marked [x]"
                              | not (any optCorrect opts) ]
              renderedLabels = [ inlinesText (optLabel o) | o <- opts ]
              dupIssue = [ mkIssue E_CHOICE_DUPLICATE exLoc "two or more option labels render identically"
                         | length renderedLabels /= length (dedupText renderedLabels) ]
          in countIssue ++ correctIssue ++ dupIssue
        checkChoice _ = []

    recallRequired = mKind == Just KQuiz && not hasChoiceList
    answerMissingIssue =
      [ mkIssue E_ROLE_MISSING exLoc "quiz recall mode requires exactly one ### Answer role"
      | recallRequired, null answerChunks
      ]

    stepCountIssue =
      [ mkIssue E_DRILL_STEP_COUNT exLoc ("drill has " <> T.pack (show (length stepChunksMeta)) <> " ### Step roles (want >= 2)")
      | mKind == Just KDrill, length stepChunksMeta < 2
      ]

    (stepIssuesAll, stepCitesAll, stepVerifiesAll, stepLintTargetsAll) =
      unzip4Local (map (stepOutputs file) (synExSteps exS))

    findMissingIssue = [ mkIssue E_FIELD_MISSING exLoc "lookup requires a find: field"
                        | mKind == Just KLookup, isNothing (synExFindCitation exS), isNothing (synExFindField exS) ]
    lookupSpoilerIssue = case (mKind, synExFindCitation exS) of
      (Just KLookup, Just target) | lookupSpoilerHits (citPage target) (blocksText (synExIntroBlocks exS)) ->
        [ mkIssue E_LOOKUP_SPOILER exLoc "body text reveals the target page number" ]
      _ -> []

    allIssues = concat
      [ exFieldIssues, typeUnknownIssue, idSyntaxIssue, exCiteIssues, exTagIssues
      , findIssues, limitIssues, bodyIndentedIssues, roleUnknownIssues
      , whyRepeatIssue, hintRepeatIssue, answerRepeatIssue, roleNoFieldIssues, answerFieldIssues
      , quizModeAmbiguousIssue, choiceIssues, answerMissingIssue
      , stepCountIssue, concat stepIssuesAll, findMissingIssue, lookupSpoilerIssue
      ]

    cites = [ (exLoc, c) | c <- synExCites exS ] ++ concat stepCitesAll
              ++ [ (exLoc, t) | Just t <- [synExFindCitation exS] ]
    verifies = concat stepVerifiesAll

    idRows = [ (exLoc, realExId, kind, deckChapterText) | Just realExId <- [synExId exS], Just kind <- [mKind] ]

    lintTargets = concat
      [ [ (exLoc, synExTitleTxt exS) ]
      , [ (exLoc, blocksText (synExIntroBlocks exS)) | not (null (synExIntroBlocks exS)) ]
      , [ (exLoc, blocksText (synExWhyBlocks exS)) | not (null (synExWhyBlocks exS)) ]
      , [ (exLoc, blocksText hb) | hb <- synExHintBlocksList exS, not (null hb) ]
      , [ (exLoc, blocksText (synExAnswerBlocks exS)) | not (null (synExAnswerBlocks exS)) ]
      , case synExChoicePrompt exS of
          Just (Choice opts) -> [ (exLoc, inlinesText (optLabel o)) | o <- opts ]
          _                   -> []
      , case synExDistractorField exS of
          Just f  -> [(exLoc, flValue f)]
          Nothing -> []
      , concat stepLintTargetsAll
      ]

--------------------------------------------------------------------------
-- One drill step (### Step) -- issues + external returns, read off the
-- 'StepSyn' "SXC1.Exercise.Reader".readDeckSyn already built.
--------------------------------------------------------------------------

stepOutputs :: Text -> StepSyn -> ([Issue], [(Loc, Citation)], [(Loc, VerifySpec)], [(Loc, Text)])
stepOutputs file stS = (allIssues, cites, verifies, lintTargets)
  where
    stepLoc = Loc file (synStLn stS)

    -- "check" is cardinality Opt1 here (not Req1): a MISSING check: gets
    -- the dedicated E_DRILL_CHECK_MISSING code below, not the generic
    -- E_FIELD_MISSING.
    fieldIssues = checkFieldBlock file stepLoc [("cite", ReqMany), ("check", Opt1), ("verify", Opt1)] (synStFields stS)

    citeIssues =
      [ mkIssue E_CITE_SYNTAX (Loc file (flLine f))
          ("malformed cite: expected <slug> <page> \"<anchor>\", got \"" <> flValue f <> "\"")
      | f <- synStCiteFields stS
      , not (T.null (T.strip (flValue f)))
      , Nothing <- [parseCitationValue (flValue f)]
      ]

    checkMissingIssue = [ mkIssue E_DRILL_CHECK_MISSING stepLoc "### Step requires a check: field"
                         | isNothing (synStCheckField stS) ]

    verifyIssues = case synStVerifyField stS of
      Nothing -> []
      Just f | T.null (T.strip (flValue f)) -> []
             | isNothing (synStVerify stS) ->
                 [ mkIssue E_VERIFY_SYNTAX (Loc file (flLine f)) ("malformed verify: \"" <> flValue f <> "\"") ]
             | otherwise -> []

    bodyIndentedIssues = indentedHeadingIssues file (synStAfterFields stS)

    -- H5 (M2 gate finding): a step's own body (after its field block)
    -- must contain at least one block.
    bodyEmptyIssue = [ mkIssue E_DRILL_STEP_EMPTY stepLoc "### Step body must contain at least one block (instruction text)"
                     | null (synStBodyBlocks stS) ]

    allIssues = fieldIssues ++ citeIssues ++ checkMissingIssue ++ verifyIssues ++ bodyIndentedIssues ++ bodyEmptyIssue
    cites = [ (stepLoc, c) | c <- synStCites stS ]
    verifies = [ (stepLoc, v) | Just v <- [synStVerify stS] ]

    lintTargets =
      [ (stepLoc, inlinesText (synStCheckInline stS)) | not (null (synStCheckInline stS)) ]
        ++ [ (stepLoc, blocksText (synStBodyBlocks stS)) | not (null (synStBodyBlocks stS)) ]

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
