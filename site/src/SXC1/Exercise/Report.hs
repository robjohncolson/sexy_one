{-# LANGUAGE OverloadedStrings #-}

-- | 'Issue', the CLOSED set of exercise-content issue codes, and the
-- hand-rolled JSON report encoder -- there is no aeson (see
-- "SXC1.Content.Stats"), and this module REUSES that module's
-- 'SXC1.Content.Stats.jsonEscape' rather than writing a second escaper.
--
-- The closed code set is a real Haskell enumeration ('IssueCode',
-- 'allIssueCodes' via 'Bounded'\/'Enum'), not a hand-written string list
-- that can drift from what the validator actually emits -- see
-- 'listCodesLines', which @exercise-check --list-codes@ prints verbatim
-- (plus one dynamically-generated @E-TERM.\<rule_id\>@ line per loaded
-- terminology rule).
module SXC1.Exercise.Report
  ( -- * Locations
    Loc (..)
    -- * Issues
  , Issue (..)
  , mkIssue
  , renderIssue
    -- * The closed code set
  , IssueCode (..)
  , IssueClass (..)
  , allIssueCodes
  , codeText
  , issueClassOf
  , classText
  , listCodesLines
    -- * The JSON report
  , Totals (..)
  , DeckSummary (..)
  , buildTotals
  , buildDeckSummaries
  , renderReport
  ) where

import           Data.List             (nub)
import           Data.Text             (Text)
import qualified Data.Text             as T

import           SXC1.Content.Stats    (jsonEscape)
import           SXC1.Exercise.Types

--------------------------------------------------------------------------
-- Locations
--------------------------------------------------------------------------

-- | Where an 'Issue' (or, in "SXC1.Exercise.Lint"\/"SXC1.Exercise.Verify",
-- the thing being checked) is anchored: a source file and a 1-based line
-- number within it. Shared by "SXC1.Exercise.Parse", "SXC1.Exercise.Lint"
-- and "SXC1.Exercise.Verify" so all four modules attach issues the same
-- way.
data Loc = Loc
  { locFile :: !Text
  , locLine :: !Int  -- ^ 1-based
  } deriving (Eq, Show)

--------------------------------------------------------------------------
-- Issues
--------------------------------------------------------------------------

-- | One validator finding. 'isCode' is a raw code STRING -- for the 39
-- static codes it is always exactly 'codeText' of some 'IssueCode'
-- (built via 'mkIssue'); for terminology violations it is
-- @\"E-TERM.\" <> rule_id@ directly (there is no per-rule 'IssueCode'
-- constructor -- the rule set is data, loaded from
-- @content\/terminology-rules.tsv@, not fixed at compile time). Either
-- way, 'isCode' is what @--fixtures@' exact-code-set matching compares.
data Issue = Issue
  { isCode   :: !Text
  , isFile   :: !Text
  , isLine   :: !Int  -- ^ 1-based
  , isDetail :: !Text
  } deriving (Eq)

mkIssue :: IssueCode -> Loc -> Text -> Issue
mkIssue code (Loc f l) detail = Issue (codeText code) f l detail

-- | @file:line: CODE  detail@ -- the CLI's per-issue line.
renderIssue :: Issue -> Text
renderIssue i = isFile i <> ":" <> T.pack (show (isLine i)) <> ": " <> isCode i <> "  " <> isDetail i

--------------------------------------------------------------------------
-- The closed code set
--------------------------------------------------------------------------

-- | Every code the validator can emit, EXCEPT the data-driven
-- @E-TERM.\<rule_id\>@ family (one per row of
-- @content\/terminology-rules.tsv@, handled separately -- see
-- 'listCodesLines').
data IssueCode
  = E_FILE_TITLE | E_FILE_BAD_NAME | E_DECK_EMPTY
  | E_FIELD_UNKNOWN | E_FIELD_MISSING | E_FIELD_DUPLICATE | E_FIELD_EMPTY | E_FIELD_SYNTAX
  | E_TYPE_UNKNOWN | E_ID_SYNTAX
  | E_CITE_SYNTAX | E_CITE_SLUG | E_CITE_PAGE | E_CITE_ANCHOR
  | E_CHAPTER_UNKNOWN
  | E_ROLE_UNKNOWN | E_ROLE_MISSING | E_ROLE_REPEATED
  | E_CHOICE_COUNT | E_CHOICE_NO_CORRECT | E_CHOICE_DUPLICATE
  | E_QUIZ_MODE_AMBIGUOUS
  | E_DRILL_STEP_COUNT | E_DRILL_CHECK_MISSING
  | E_VERIFY_SYNTAX | E_VERIFY_CC_UNKNOWN | E_VERIFY_NOTE_RANGE
  | E_LOOKUP_SPOILER | E_BODY_INDENTED_HEADING
  | E_INDEX_MISSING | E_INDEX_ORPHAN | E_INDEX_DANGLING | E_ID_DUPLICATE
  | E_RULE_UNGROUNDED
  | E_ID_NOT_IN_INVENTORY | E_ID_RETIRED | E_ID_TYPE_MISMATCH | E_ID_CHAPTER_MISMATCH
  | E_BLOCK_UNPARSED
  deriving (Eq, Show, Enum, Bounded)

-- | The three coverage classes -- see @briefs\/M2-manifest.json@'s
-- \"COVERAGE CLASSES\" section. 'SeamClass' is capped at exactly one
-- code ('E_BLOCK_UNPARSED'); @check-site.sh@ asserts that literally.
data IssueClass = FileClass | DirClass | SeamClass
  deriving (Eq, Show)

-- | Every 'IssueCode', via 'Bounded'\/'Enum' -- this is what makes
-- 'listCodesLines' a real enumeration of the type rather than a
-- hand-written list that can silently stop matching what the validator
-- emits.
allIssueCodes :: [IssueCode]
allIssueCodes = [minBound .. maxBound]

codeText :: IssueCode -> Text
codeText c = case c of
  E_FILE_TITLE           -> "E-FILE-TITLE"
  E_FILE_BAD_NAME        -> "E-FILE-BAD-NAME"
  E_DECK_EMPTY            -> "E-DECK-EMPTY"
  E_FIELD_UNKNOWN         -> "E-FIELD-UNKNOWN"
  E_FIELD_MISSING         -> "E-FIELD-MISSING"
  E_FIELD_DUPLICATE       -> "E-FIELD-DUPLICATE"
  E_FIELD_EMPTY           -> "E-FIELD-EMPTY"
  E_FIELD_SYNTAX          -> "E-FIELD-SYNTAX"
  E_TYPE_UNKNOWN          -> "E-TYPE-UNKNOWN"
  E_ID_SYNTAX              -> "E-ID-SYNTAX"
  E_CITE_SYNTAX            -> "E-CITE-SYNTAX"
  E_CITE_SLUG              -> "E-CITE-SLUG"
  E_CITE_PAGE              -> "E-CITE-PAGE"
  E_CITE_ANCHOR            -> "E-CITE-ANCHOR"
  E_CHAPTER_UNKNOWN        -> "E-CHAPTER-UNKNOWN"
  E_ROLE_UNKNOWN           -> "E-ROLE-UNKNOWN"
  E_ROLE_MISSING           -> "E-ROLE-MISSING"
  E_ROLE_REPEATED          -> "E-ROLE-REPEATED"
  E_CHOICE_COUNT           -> "E-CHOICE-COUNT"
  E_CHOICE_NO_CORRECT      -> "E-CHOICE-NO-CORRECT"
  E_CHOICE_DUPLICATE       -> "E-CHOICE-DUPLICATE"
  E_QUIZ_MODE_AMBIGUOUS    -> "E-QUIZ-MODE-AMBIGUOUS"
  E_DRILL_STEP_COUNT       -> "E-DRILL-STEP-COUNT"
  E_DRILL_CHECK_MISSING    -> "E-DRILL-CHECK-MISSING"
  E_VERIFY_SYNTAX          -> "E-VERIFY-SYNTAX"
  E_VERIFY_CC_UNKNOWN      -> "E-VERIFY-CC-UNKNOWN"
  E_VERIFY_NOTE_RANGE      -> "E-VERIFY-NOTE-RANGE"
  E_LOOKUP_SPOILER         -> "E-LOOKUP-SPOILER"
  E_BODY_INDENTED_HEADING  -> "E-BODY-INDENTED-HEADING"
  E_INDEX_MISSING          -> "E-INDEX-MISSING"
  E_INDEX_ORPHAN           -> "E-INDEX-ORPHAN"
  E_INDEX_DANGLING         -> "E-INDEX-DANGLING"
  E_ID_DUPLICATE           -> "E-ID-DUPLICATE"
  E_RULE_UNGROUNDED        -> "E-RULE-UNGROUNDED"
  E_ID_NOT_IN_INVENTORY    -> "E-ID-NOT-IN-INVENTORY"
  E_ID_RETIRED              -> "E-ID-RETIRED"
  E_ID_TYPE_MISMATCH        -> "E-ID-TYPE-MISMATCH"
  E_ID_CHAPTER_MISMATCH     -> "E-ID-CHAPTER-MISMATCH"
  E_BLOCK_UNPARSED           -> "E-BLOCK-UNPARSED"

issueClassOf :: IssueCode -> IssueClass
issueClassOf c = case c of
  E_INDEX_MISSING       -> DirClass
  E_INDEX_ORPHAN        -> DirClass
  E_INDEX_DANGLING      -> DirClass
  E_ID_DUPLICATE        -> DirClass
  E_RULE_UNGROUNDED     -> DirClass
  E_ID_NOT_IN_INVENTORY -> DirClass
  E_ID_RETIRED          -> DirClass
  E_ID_TYPE_MISMATCH    -> DirClass
  E_ID_CHAPTER_MISMATCH -> DirClass
  E_BLOCK_UNPARSED      -> SeamClass
  _                     -> FileClass

classText :: IssueClass -> Text
classText FileClass = "file"
classText DirClass  = "dir"
classText SeamClass = "seam"

-- | @exercise-check --list-codes@'s entire payload: one @\<CODE\>\\t\<class\>@
-- line per static 'IssueCode', plus one @E-TERM.\<rule_id\>\\tfile@ line
-- per rule id supplied (i.e. per row of the loaded
-- @content\/terminology-rules.tsv@). Takes the rule ids as a parameter
-- rather than reading the file itself -- this module performs no IO (see
-- the module Haddock) -- so the caller (@exercise-check@'s default-mode
-- driver, or a @--list-codes@-only run that still loads the rules file)
-- supplies them.
listCodesLines :: [Text] -> [Text]
listCodesLines ruleIds =
  [ codeText c <> "\t" <> classText (issueClassOf c) | c <- allIssueCodes ]
    ++ [ "E-TERM." <> rid <> "\tfile" | rid <- ruleIds ]

--------------------------------------------------------------------------
-- The JSON report
--------------------------------------------------------------------------

data Totals = Totals
  { totDecks       :: !Int
  , totExercises   :: !Int
  , totPrompts     :: !Int
  , totQuiz        :: !Int
  , totDrill       :: !Int
  , totLookup      :: !Int
  , totCitations   :: !Int
  , totVerifyHooks :: !Int
  , totChapters    :: [Text]
  }

data DeckSummary = DeckSummary
  { dsDeck      :: !Text
  , dsChapter   :: !Text
  , dsTitle     :: !Text
  , dsExercises :: !Int
  , dsPrompts   :: !Int
  , dsIds       :: [Text]
  }

unDeckId :: DeckId -> Text
unDeckId (DeckId t) = t

unExId :: ExId -> Text
unExId (ExId t) = t

buildTotals :: [Deck] -> Totals
buildTotals decks = Totals
  { totDecks       = length decks
  , totExercises   = length exs
  , totPrompts     = length prompts
  , totQuiz        = length [ () | e <- exs, exKind e == KQuiz ]
  , totDrill       = length [ () | e <- exs, exKind e == KDrill ]
  , totLookup      = length [ () | e <- exs, exKind e == KLookup ]
  , totCitations   = sum (map (length . dkCites) decks) + sum (map (length . exCites) exs)
                       + sum (map (length . prCites) prompts)
  , totVerifyHooks = length [ () | Prompt { prBody = Confirm { pcVerify = Just _ } } <- prompts ]
  , totChapters    = nub (map dkChapter decks)
  }
  where
    exs     = concatMap dkExercises decks
    prompts = concatMap exPrompts exs

buildDeckSummaries :: [Deck] -> [DeckSummary]
buildDeckSummaries decks =
  [ DeckSummary
      { dsDeck      = unDeckId (dkId d)
      , dsChapter   = dkChapter d
      , dsTitle     = dkTitle d
      , dsExercises = length (dkExercises d)
      , dsPrompts   = sum (map (length . exPrompts) (dkExercises d))
      , dsIds       = map (unExId . exId) (dkExercises d)
      }
  | d <- decks
  ]

jStr :: Text -> Text
jStr t = "\"" <> jsonEscape t <> "\""

jArr :: [Text] -> Text
jArr xs = "[" <> T.intercalate "," xs <> "]"

jInt :: Int -> Text
jInt = T.pack . show

jBool :: Bool -> Text
jBool True  = "true"
jBool False = "false"

jKV :: Text -> Text -> Text
jKV k v = jStr k <> ":" <> v

jObj :: [Text] -> Text
jObj kvs = "{" <> T.intercalate "," kvs <> "}"

totalsJson :: Totals -> Text
totalsJson t = jObj
  [ jKV "decks"       (jInt (totDecks t))
  , jKV "exercises"   (jInt (totExercises t))
  , jKV "prompts"     (jInt (totPrompts t))
  , jKV "quiz"        (jInt (totQuiz t))
  , jKV "drill"       (jInt (totDrill t))
  , jKV "lookup"      (jInt (totLookup t))
  , jKV "citations"   (jInt (totCitations t))
  , jKV "verifyHooks" (jInt (totVerifyHooks t))
  , jKV "chapters"    (jArr (map jStr (totChapters t)))
  ]

deckSummaryJson :: DeckSummary -> Text
deckSummaryJson d = jObj
  [ jKV "deck"      (jStr (dsDeck d))
  , jKV "chapter"   (jStr (dsChapter d))
  , jKV "title"     (jStr (dsTitle d))
  , jKV "exercises" (jInt (dsExercises d))
  , jKV "prompts"   (jInt (dsPrompts d))
  , jKV "ids"       (jArr (map jStr (dsIds d)))
  ]

sourceCharsJson :: (Text, Int) -> Text
sourceCharsJson (name, n) = "[" <> jStr name <> "," <> jInt n <> "]"

issueJson :: Issue -> Text
issueJson i = jObj
  [ jKV "code"   (jStr (isCode i))
  , jKV "file"   (jStr (isFile i))
  , jKV "line"   (jInt (isLine i))
  , jKV "detail" (jStr (isDetail i))
  ]

-- | The full @--json@ report: @{\"ok\",\"totals\",\"decks\",
-- \"sourceChars\",\"issues\"}@ -- see @briefs\/M2-manifest.json@, task
-- \"exercise-core\", item (7) for the exact schema.
renderReport :: Bool -> [Deck] -> [(Text, Int)] -> [Issue] -> Text
renderReport ok decks sourceChars issues = jObj
  [ jKV "ok"           (jBool ok)
  , jKV "totals"       (totalsJson (buildTotals decks))
  , jKV "decks"        (jArr (map deckSummaryJson (buildDeckSummaries decks)))
  , jKV "sourceChars"  (jArr (map sourceCharsJson sourceChars))
  , jKV "issues"       (jArr (map issueJson issues))
  ]
