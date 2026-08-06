{-# LANGUAGE OverloadedStrings #-}

-- | 'Issue', the CLOSED set of exercise-content issue codes, and the
-- hand-rolled JSON report encoder -- there is no aeson (see
-- "SXC1.Content.Stats"), and this module REUSES that module's
-- 'SXC1.Content.Stats.jsonEscape' rather than writing a second escaper.
--
-- The closed code set is a real Haskell 'IssueCode' enumeration --
-- 'allIssueCodes' lists every STATIC (nullary) constructor by hand (see
-- its own Haddock for why 'Bounded'\/'Enum' can no longer do this
-- mechanically now that 'E_TERM' carries a field), plus the one DYNAMIC
-- family member, 'E_TERM' -- and, critically, an 'Issue' can only ever be
-- constructed via 'mkIssue' from a real 'IssueCode' value: the module
-- does not export the raw 'Issue' data constructor. See 'listCodesLines',
-- which @exercise-check --list-codes@ prints verbatim (one line per
-- static code, plus one dynamically-generated @E-TERM.\<rule_id\>@ line
-- per loaded terminology rule).
module SXC1.Exercise.Report
  ( -- * Locations
    Loc (..)
    -- * Issues -- 'Issue' exports ACCESSORS ONLY (never the raw data
    -- constructor -- see 'Issue''s own Haddock and 'mkIssue'), so every
    -- 'Issue' anywhere in the program is guaranteed to have been built by
    -- 'mkIssue' from a real 'IssueCode'.
  , Issue
  , isCode
  , isFile
  , isLine
  , isDetail
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

-- | One validator finding. 'isCode' is a raw code STRING, always exactly
-- 'codeText' of some 'IssueCode' -- for the closed, static family (built
-- via 'mkIssue' from one of the nullary constructors below) and for
-- terminology violations alike (@\"E-TERM.\" <> rule_id@, via 'mkIssue'
-- and the 'E_TERM' constructor -- there is no per-rule static
-- constructor, since the rule set is data loaded from
-- @content\/terminology-rules.tsv@, not fixed at compile time, but it is
-- still a real 'IssueCode' value, not a bare string smuggled in some
-- other way). 'isCode' is what @--fixtures@' exact-code-set matching
-- compares.
--
-- (M2 gate M2): the data CONSTRUCTOR 'Issue' is deliberately NOT
-- exported (see the module export list -- only the field accessors are)
-- so an 'Issue' can only ever be built by 'mkIssue', which only ever
-- accepts a real 'IssueCode'. Before this, any module could construct
-- @Issue \"whatever I like\" file line detail@ directly, a code invisible
-- to both the coverage invariant and the one-seam cap this very type is
-- supposed to make honest.
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

-- | Every code the validator can emit. The first 40 constructors are the
-- CLOSED, static, nullary family; 'E_TERM' is the one DYNAMIC family
-- member (M2 gate M2), carrying the @content\/terminology-rules.tsv@ row
-- id its violation came from -- e.g. @E_TERM \"term-machine\"@ renders as
-- @\"E-TERM.term-machine\"@ (see 'codeText'). Because 'E_TERM' carries a
-- field, this type can no longer derive 'Bounded'\/'Enum' (both require
-- every constructor to be nullary) the way it did when the dynamic
-- family was smuggled in as a raw 'Text' code bypassing this type
-- entirely -- 'allIssueCodes' below is therefore the static family
-- listed by hand, exercised by both @--list-codes@ and the
-- @--fixtures@ coverage invariant (@scripts\/check-site.sh@), so a
-- constructor added here without being added there is caught
-- immediately rather than silently under-enumerated.
data IssueCode
  = E_FILE_TITLE | E_FILE_BAD_NAME | E_DECK_EMPTY
  | E_FIELD_UNKNOWN | E_FIELD_MISSING | E_FIELD_DUPLICATE | E_FIELD_EMPTY | E_FIELD_SYNTAX
  | E_TYPE_UNKNOWN | E_ID_SYNTAX
  | E_CITE_SYNTAX | E_CITE_SLUG | E_CITE_PAGE | E_CITE_ANCHOR
  | E_CHAPTER_UNKNOWN
  | E_ROLE_UNKNOWN | E_ROLE_MISSING | E_ROLE_REPEATED
  | E_CHOICE_COUNT | E_CHOICE_NO_CORRECT | E_CHOICE_DUPLICATE
  | E_QUIZ_MODE_AMBIGUOUS
  | E_DRILL_STEP_COUNT | E_DRILL_CHECK_MISSING | E_DRILL_STEP_EMPTY
  | E_VERIFY_SYNTAX | E_VERIFY_CC_UNKNOWN | E_VERIFY_NOTE_RANGE
  | E_LOOKUP_SPOILER | E_BODY_INDENTED_HEADING
  | E_INDEX_MISSING | E_INDEX_ORPHAN | E_INDEX_DANGLING | E_ID_DUPLICATE
  | E_RULE_UNGROUNDED
  | E_ID_NOT_IN_INVENTORY | E_ID_RETIRED | E_ID_TYPE_MISMATCH | E_ID_CHAPTER_MISMATCH
  | E_BLOCK_UNPARSED
  | E_TERM !Text
  deriving (Eq, Show)

-- | The three coverage classes -- see @briefs\/M2-manifest.json@'s
-- \"COVERAGE CLASSES\" section. 'SeamClass' is capped at exactly one
-- code ('E_BLOCK_UNPARSED'); @check-site.sh@ asserts that literally.
data IssueClass = FileClass | DirClass | SeamClass
  deriving (Eq, Show)

-- | Every STATIC 'IssueCode' -- everything except the dynamic 'E_TERM'
-- family, which @--list-codes@ enumerates separately from the loaded
-- rule set (see 'listCodesLines'). See the 'IssueCode' Haddock for why
-- this is a hand-written list rather than @[minBound .. maxBound]@.
allIssueCodes :: [IssueCode]
allIssueCodes =
  [ E_FILE_TITLE, E_FILE_BAD_NAME, E_DECK_EMPTY
  , E_FIELD_UNKNOWN, E_FIELD_MISSING, E_FIELD_DUPLICATE, E_FIELD_EMPTY, E_FIELD_SYNTAX
  , E_TYPE_UNKNOWN, E_ID_SYNTAX
  , E_CITE_SYNTAX, E_CITE_SLUG, E_CITE_PAGE, E_CITE_ANCHOR
  , E_CHAPTER_UNKNOWN
  , E_ROLE_UNKNOWN, E_ROLE_MISSING, E_ROLE_REPEATED
  , E_CHOICE_COUNT, E_CHOICE_NO_CORRECT, E_CHOICE_DUPLICATE
  , E_QUIZ_MODE_AMBIGUOUS
  , E_DRILL_STEP_COUNT, E_DRILL_CHECK_MISSING, E_DRILL_STEP_EMPTY
  , E_VERIFY_SYNTAX, E_VERIFY_CC_UNKNOWN, E_VERIFY_NOTE_RANGE
  , E_LOOKUP_SPOILER, E_BODY_INDENTED_HEADING
  , E_INDEX_MISSING, E_INDEX_ORPHAN, E_INDEX_DANGLING, E_ID_DUPLICATE
  , E_RULE_UNGROUNDED
  , E_ID_NOT_IN_INVENTORY, E_ID_RETIRED, E_ID_TYPE_MISMATCH, E_ID_CHAPTER_MISMATCH
  , E_BLOCK_UNPARSED
  ]

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
  E_DRILL_STEP_EMPTY       -> "E-DRILL-STEP-EMPTY"
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
  E_TERM rid                 -> "E-TERM." <> rid

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
  [ oneLine c | c <- allIssueCodes ] ++ [ oneLine (E_TERM rid) | rid <- ruleIds ]
  where
    oneLine c = codeText c <> "\t" <> classText (issueClassOf c)

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

-- | (M2 gate M1, model half): 'totCitations' counts DECLARATIONS -- one
-- per @cite:@\/@find:@ line on disk -- not resolved citation OBJECTS.
-- Those are not the same count: a quiz\/lookup's single 'Prompt' is
-- built with 'prCites' set to the SAME list as its 'Exercise''s 'exCites'
-- (see "SXC1.Exercise.Parse"), so naively summing 'exCites' and
-- 'prCites' everywhere double-counted every quiz\/lookup @cite:@ line; a
-- lookup's @find:@ target, meanwhile, lives only in its prompt's
-- 'FindPage' body and was never counted at all. Fixed by counting
-- 'exCites' exactly once per exercise (correct for quiz, drill AND
-- lookup -- a drill's OWN exercise-level @cite:@ is distinct from its
-- per-step ones), adding each drill step's 'prCites' separately (those
-- genuinely are distinct declarations from the exercise-level ones), and
-- adding exactly one per lookup's @find:@ target.
buildTotals :: [Deck] -> Totals
buildTotals decks = Totals
  { totDecks       = length decks
  , totExercises   = length exs
  , totPrompts     = length prompts
  , totQuiz        = length [ () | e <- exs, exKind e == KQuiz ]
  , totDrill       = length [ () | e <- exs, exKind e == KDrill ]
  , totLookup      = length [ () | e <- exs, exKind e == KLookup ]
  , totCitations   = sum (map (length . dkCites) decks)
                       + sum (map (length . exCites) exs)
                       + sum [ length (prCites p) | e <- exs, exKind e == KDrill, p <- exPrompts e ]
                       + length [ () | e <- exs, exKind e == KLookup, p <- exPrompts e, isFindPage (prBody p) ]
  , totVerifyHooks = length [ () | Prompt { prBody = Confirm { pcVerify = Just _ } } <- prompts ]
  , totChapters    = nub (map dkChapter decks)
  }
  where
    exs     = concatMap dkExercises decks
    prompts = concatMap exPrompts exs
    isFindPage b = case b of { FindPage _ _ -> True; _ -> False }

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
