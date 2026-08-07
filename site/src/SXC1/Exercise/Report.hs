{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms   #-}

-- | 'Issue', the CLOSED set of exercise-content issue codes, and the
-- hand-rolled JSON report encoder -- there is no aeson (see
-- "SXC1.Content.Stats"), and this module REUSES that module's
-- 'SXC1.Content.Stats.jsonEscape' rather than writing a second escaper.
--
-- The closed code set is a real Haskell 'IssueCode' enumeration.
-- 'IssueCode''s static family ('StaticCode', wrapped by 'Static') is an
-- ordinary nullary sum type deriving 'Enum'\/'Bounded', so 'allIssueCodes'
-- is MECHANICALLY DERIVED as @map Static [minBound .. maxBound]@ -- it is
-- NOT a hand-maintained list, and cannot under-enumerate (a new
-- constructor appears there automatically) -- plus the one DYNAMIC family
-- member, 'E_TERM'. Critically, an 'Issue' can only ever be constructed
-- via 'mkIssue' from a real 'IssueCode' value: the module does not export
-- the raw 'Issue' data constructor. See 'listCodesLines', which
-- @exercise-check --list-codes@ prints verbatim (one line per static
-- code, plus one dynamically-generated @E-TERM.\<rule_id\>@ line per
-- loaded terminology rule).
--
-- M3 gate fix (task \"size-split-and-format\", the inherited M2 LOW): the
-- one place that COULD still under-enumerate is 'codeText'\/'issueClassOf'
-- themselves -- before this fix they matched on the 'IssueCode' pattern
-- synonyms under a @{-\# COMPLETE ... \#-}@ pragma, so a new
-- 'StaticCode' constructor added without a matching 'codeText' arm was
-- silently accepted by @-Wall@ (the pragma told the exhaustiveness
-- checker to trust the hand-maintained COMPLETE list instead of the real
-- type) and only blew up at RUNTIME, inside @--list-codes@, with a
-- non-exhaustive-pattern exception. 'codeText' and 'issueClassOf' now
-- match DIRECTLY on the real 'StaticCode' constructors (via
-- 'staticCodeText'\/'staticIssueClassOf') with no COMPLETE pragma
-- anywhere in this module, so @-Wall@'s ordinary exhaustiveness check is
-- restored: forgetting a 'codeText' arm for a new constructor is a
-- COMPILE-TIME warning again, not a runtime crash.
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
    --
    -- 'IssueCode''s static family is a separate nullary 'StaticCode'
    -- enumeration wrapped by 'Static', with pattern synonyms preserving
    -- the flat @E_*@ names at every use site -- so 'allIssueCodes' is
    -- @map Static [minBound .. maxBound]@ and CANNOT under-enumerate
    -- (M2 re-gate finding: the previous hand-written list was driftable).
  , IssueCode
      ( Static, E_TERM
      , E_FILE_TITLE, E_FILE_BAD_NAME, E_DECK_EMPTY
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
      , E_DECK_TIER_UNKNOWN, E_DECK_REQUIRES_UNKNOWN, E_DECK_REQUIRES_CYCLE
      )
  , StaticCode
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
-- CLOSED, static, nullary family ('StaticCode', wrapped by 'Static');
-- 'E_TERM' is the one DYNAMIC family member (M2 gate M2), carrying the
-- @content\/terminology-rules.tsv@ row id its violation came from --
-- e.g. @E_TERM \"term-machine\"@ renders as @\"E-TERM.term-machine\"@
-- (see 'codeText').
--
-- M2 RE-GATE FIX: the static family lives in its own nullary type so it
-- derives 'Enum'\/'Bounded' again, and 'allIssueCodes' is DERIVED as
-- @map Static [minBound .. maxBound]@ -- adding a constructor without it
-- appearing there is now impossible, closing the hand-list drift escape.
-- The @E_*@ pattern synonyms below keep every existing use site (Parse\/
-- Lint\/Verify\/CheckExercises) source-compatible, and the COMPLETE
-- pragma keeps their case matches exhaustiveness-checked under -Wall.
data StaticCode
  = E_FILE_TITLE_ | E_FILE_BAD_NAME_ | E_DECK_EMPTY_
  | E_FIELD_UNKNOWN_ | E_FIELD_MISSING_ | E_FIELD_DUPLICATE_ | E_FIELD_EMPTY_ | E_FIELD_SYNTAX_
  | E_TYPE_UNKNOWN_ | E_ID_SYNTAX_
  | E_CITE_SYNTAX_ | E_CITE_SLUG_ | E_CITE_PAGE_ | E_CITE_ANCHOR_
  | E_CHAPTER_UNKNOWN_
  | E_ROLE_UNKNOWN_ | E_ROLE_MISSING_ | E_ROLE_REPEATED_
  | E_CHOICE_COUNT_ | E_CHOICE_NO_CORRECT_ | E_CHOICE_DUPLICATE_
  | E_QUIZ_MODE_AMBIGUOUS_
  | E_DRILL_STEP_COUNT_ | E_DRILL_CHECK_MISSING_ | E_DRILL_STEP_EMPTY_
  | E_VERIFY_SYNTAX_ | E_VERIFY_CC_UNKNOWN_ | E_VERIFY_NOTE_RANGE_
  | E_LOOKUP_SPOILER_ | E_BODY_INDENTED_HEADING_
  | E_INDEX_MISSING_ | E_INDEX_ORPHAN_ | E_INDEX_DANGLING_ | E_ID_DUPLICATE_
  | E_RULE_UNGROUNDED_
  | E_ID_NOT_IN_INVENTORY_ | E_ID_RETIRED_ | E_ID_TYPE_MISMATCH_ | E_ID_CHAPTER_MISMATCH_
  | E_BLOCK_UNPARSED_
  | E_DECK_TIER_UNKNOWN_ | E_DECK_REQUIRES_UNKNOWN_ | E_DECK_REQUIRES_CYCLE_
  deriving (Eq, Show, Enum, Bounded)

data IssueCode
  = Static !StaticCode
  | E_TERM !Text
  deriving (Eq, Show)

pattern E_FILE_TITLE, E_FILE_BAD_NAME, E_DECK_EMPTY :: IssueCode
pattern E_FILE_TITLE  = Static E_FILE_TITLE_
pattern E_FILE_BAD_NAME = Static E_FILE_BAD_NAME_
pattern E_DECK_EMPTY  = Static E_DECK_EMPTY_
pattern E_FIELD_UNKNOWN, E_FIELD_MISSING, E_FIELD_DUPLICATE, E_FIELD_EMPTY, E_FIELD_SYNTAX :: IssueCode
pattern E_FIELD_UNKNOWN   = Static E_FIELD_UNKNOWN_
pattern E_FIELD_MISSING   = Static E_FIELD_MISSING_
pattern E_FIELD_DUPLICATE = Static E_FIELD_DUPLICATE_
pattern E_FIELD_EMPTY     = Static E_FIELD_EMPTY_
pattern E_FIELD_SYNTAX    = Static E_FIELD_SYNTAX_
pattern E_TYPE_UNKNOWN, E_ID_SYNTAX :: IssueCode
pattern E_TYPE_UNKNOWN = Static E_TYPE_UNKNOWN_
pattern E_ID_SYNTAX    = Static E_ID_SYNTAX_
pattern E_CITE_SYNTAX, E_CITE_SLUG, E_CITE_PAGE, E_CITE_ANCHOR :: IssueCode
pattern E_CITE_SYNTAX = Static E_CITE_SYNTAX_
pattern E_CITE_SLUG   = Static E_CITE_SLUG_
pattern E_CITE_PAGE   = Static E_CITE_PAGE_
pattern E_CITE_ANCHOR = Static E_CITE_ANCHOR_
pattern E_CHAPTER_UNKNOWN :: IssueCode
pattern E_CHAPTER_UNKNOWN = Static E_CHAPTER_UNKNOWN_
pattern E_ROLE_UNKNOWN, E_ROLE_MISSING, E_ROLE_REPEATED :: IssueCode
pattern E_ROLE_UNKNOWN  = Static E_ROLE_UNKNOWN_
pattern E_ROLE_MISSING  = Static E_ROLE_MISSING_
pattern E_ROLE_REPEATED = Static E_ROLE_REPEATED_
pattern E_CHOICE_COUNT, E_CHOICE_NO_CORRECT, E_CHOICE_DUPLICATE :: IssueCode
pattern E_CHOICE_COUNT      = Static E_CHOICE_COUNT_
pattern E_CHOICE_NO_CORRECT = Static E_CHOICE_NO_CORRECT_
pattern E_CHOICE_DUPLICATE  = Static E_CHOICE_DUPLICATE_
pattern E_QUIZ_MODE_AMBIGUOUS :: IssueCode
pattern E_QUIZ_MODE_AMBIGUOUS = Static E_QUIZ_MODE_AMBIGUOUS_
pattern E_DRILL_STEP_COUNT, E_DRILL_CHECK_MISSING, E_DRILL_STEP_EMPTY :: IssueCode
pattern E_DRILL_STEP_COUNT    = Static E_DRILL_STEP_COUNT_
pattern E_DRILL_CHECK_MISSING = Static E_DRILL_CHECK_MISSING_
pattern E_DRILL_STEP_EMPTY    = Static E_DRILL_STEP_EMPTY_
pattern E_VERIFY_SYNTAX, E_VERIFY_CC_UNKNOWN, E_VERIFY_NOTE_RANGE :: IssueCode
pattern E_VERIFY_SYNTAX     = Static E_VERIFY_SYNTAX_
pattern E_VERIFY_CC_UNKNOWN = Static E_VERIFY_CC_UNKNOWN_
pattern E_VERIFY_NOTE_RANGE = Static E_VERIFY_NOTE_RANGE_
pattern E_LOOKUP_SPOILER, E_BODY_INDENTED_HEADING :: IssueCode
pattern E_LOOKUP_SPOILER        = Static E_LOOKUP_SPOILER_
pattern E_BODY_INDENTED_HEADING = Static E_BODY_INDENTED_HEADING_
pattern E_INDEX_MISSING, E_INDEX_ORPHAN, E_INDEX_DANGLING, E_ID_DUPLICATE :: IssueCode
pattern E_INDEX_MISSING  = Static E_INDEX_MISSING_
pattern E_INDEX_ORPHAN   = Static E_INDEX_ORPHAN_
pattern E_INDEX_DANGLING = Static E_INDEX_DANGLING_
pattern E_ID_DUPLICATE   = Static E_ID_DUPLICATE_
pattern E_RULE_UNGROUNDED :: IssueCode
pattern E_RULE_UNGROUNDED = Static E_RULE_UNGROUNDED_
pattern E_ID_NOT_IN_INVENTORY, E_ID_RETIRED, E_ID_TYPE_MISMATCH, E_ID_CHAPTER_MISMATCH :: IssueCode
pattern E_ID_NOT_IN_INVENTORY = Static E_ID_NOT_IN_INVENTORY_
pattern E_ID_RETIRED          = Static E_ID_RETIRED_
pattern E_ID_TYPE_MISMATCH    = Static E_ID_TYPE_MISMATCH_
pattern E_ID_CHAPTER_MISMATCH = Static E_ID_CHAPTER_MISMATCH_
pattern E_BLOCK_UNPARSED :: IssueCode
pattern E_BLOCK_UNPARSED = Static E_BLOCK_UNPARSED_
pattern E_DECK_TIER_UNKNOWN, E_DECK_REQUIRES_UNKNOWN, E_DECK_REQUIRES_CYCLE :: IssueCode
pattern E_DECK_TIER_UNKNOWN     = Static E_DECK_TIER_UNKNOWN_
pattern E_DECK_REQUIRES_UNKNOWN = Static E_DECK_REQUIRES_UNKNOWN_
pattern E_DECK_REQUIRES_CYCLE   = Static E_DECK_REQUIRES_CYCLE_

-- NOTE: deliberately NO {-# COMPLETE ... #-} pragma here (M3 gate fix --
-- see the module Haddock above). 'codeText' and 'issueClassOf' match
-- directly on the real 'StaticCode' constructors below, which -Wall
-- checks for exhaustiveness on its own; a COMPLETE pragma on the
-- 'IssueCode' pattern synonyms would only mask that check again.

-- | The three coverage classes -- see @briefs\/M2-manifest.json@'s
-- \"COVERAGE CLASSES\" section. 'SeamClass' is capped at exactly one
-- code ('E_BLOCK_UNPARSED'); @check-site.sh@ asserts that literally.
data IssueClass = FileClass | DirClass | SeamClass
  deriving (Eq, Show)

-- | Every STATIC 'IssueCode' -- everything except the dynamic 'E_TERM'
-- family, which @--list-codes@ enumerates separately from the loaded
-- rule set (see 'listCodesLines'). DERIVED from 'StaticCode''s
-- 'Bounded'\/'Enum' instances (M2 re-gate fix), so it is total by
-- construction -- a new static constructor appears here automatically.
allIssueCodes :: [IssueCode]
allIssueCodes = map Static [minBound .. maxBound]

-- | Dispatches to 'staticCodeText' for the closed family; the one dynamic
-- member ('E_TERM') is handled here directly since it carries a field a
-- 'StaticCode'-only function cannot see.
codeText :: IssueCode -> Text
codeText (Static sc)  = staticCodeText sc
codeText (E_TERM rid) = "E-TERM." <> rid

-- | Matches DIRECTLY on 'StaticCode' -- see the module Haddock's M3 gate
-- fix note: this is what makes an added constructor with no arm here a
-- COMPILE-TIME @-Wall@ incomplete-pattern warning instead of a runtime
-- exception inside @--list-codes@.
staticCodeText :: StaticCode -> Text
staticCodeText c = case c of
  E_FILE_TITLE_            -> "E-FILE-TITLE"
  E_FILE_BAD_NAME_         -> "E-FILE-BAD-NAME"
  E_DECK_EMPTY_            -> "E-DECK-EMPTY"
  E_FIELD_UNKNOWN_         -> "E-FIELD-UNKNOWN"
  E_FIELD_MISSING_         -> "E-FIELD-MISSING"
  E_FIELD_DUPLICATE_       -> "E-FIELD-DUPLICATE"
  E_FIELD_EMPTY_           -> "E-FIELD-EMPTY"
  E_FIELD_SYNTAX_          -> "E-FIELD-SYNTAX"
  E_TYPE_UNKNOWN_          -> "E-TYPE-UNKNOWN"
  E_ID_SYNTAX_             -> "E-ID-SYNTAX"
  E_CITE_SYNTAX_           -> "E-CITE-SYNTAX"
  E_CITE_SLUG_             -> "E-CITE-SLUG"
  E_CITE_PAGE_             -> "E-CITE-PAGE"
  E_CITE_ANCHOR_           -> "E-CITE-ANCHOR"
  E_CHAPTER_UNKNOWN_       -> "E-CHAPTER-UNKNOWN"
  E_ROLE_UNKNOWN_          -> "E-ROLE-UNKNOWN"
  E_ROLE_MISSING_          -> "E-ROLE-MISSING"
  E_ROLE_REPEATED_         -> "E-ROLE-REPEATED"
  E_CHOICE_COUNT_          -> "E-CHOICE-COUNT"
  E_CHOICE_NO_CORRECT_     -> "E-CHOICE-NO-CORRECT"
  E_CHOICE_DUPLICATE_      -> "E-CHOICE-DUPLICATE"
  E_QUIZ_MODE_AMBIGUOUS_   -> "E-QUIZ-MODE-AMBIGUOUS"
  E_DRILL_STEP_COUNT_      -> "E-DRILL-STEP-COUNT"
  E_DRILL_CHECK_MISSING_   -> "E-DRILL-CHECK-MISSING"
  E_DRILL_STEP_EMPTY_      -> "E-DRILL-STEP-EMPTY"
  E_VERIFY_SYNTAX_         -> "E-VERIFY-SYNTAX"
  E_VERIFY_CC_UNKNOWN_     -> "E-VERIFY-CC-UNKNOWN"
  E_VERIFY_NOTE_RANGE_     -> "E-VERIFY-NOTE-RANGE"
  E_LOOKUP_SPOILER_        -> "E-LOOKUP-SPOILER"
  E_BODY_INDENTED_HEADING_ -> "E-BODY-INDENTED-HEADING"
  E_INDEX_MISSING_         -> "E-INDEX-MISSING"
  E_INDEX_ORPHAN_          -> "E-INDEX-ORPHAN"
  E_INDEX_DANGLING_        -> "E-INDEX-DANGLING"
  E_ID_DUPLICATE_          -> "E-ID-DUPLICATE"
  E_RULE_UNGROUNDED_       -> "E-RULE-UNGROUNDED"
  E_ID_NOT_IN_INVENTORY_   -> "E-ID-NOT-IN-INVENTORY"
  E_ID_RETIRED_            -> "E-ID-RETIRED"
  E_ID_TYPE_MISMATCH_      -> "E-ID-TYPE-MISMATCH"
  E_ID_CHAPTER_MISMATCH_   -> "E-ID-CHAPTER-MISMATCH"
  E_BLOCK_UNPARSED_        -> "E-BLOCK-UNPARSED"
  E_DECK_TIER_UNKNOWN_     -> "E-DECK-TIER-UNKNOWN"
  E_DECK_REQUIRES_UNKNOWN_ -> "E-DECK-REQUIRES-UNKNOWN"
  E_DECK_REQUIRES_CYCLE_   -> "E-DECK-REQUIRES-CYCLE"

issueClassOf :: IssueCode -> IssueClass
issueClassOf (E_TERM _)  = FileClass
issueClassOf (Static sc) = staticIssueClassOf sc

staticIssueClassOf :: StaticCode -> IssueClass
staticIssueClassOf c = case c of
  E_INDEX_MISSING_         -> DirClass
  E_INDEX_ORPHAN_          -> DirClass
  E_INDEX_DANGLING_        -> DirClass
  E_ID_DUPLICATE_          -> DirClass
  E_RULE_UNGROUNDED_       -> DirClass
  E_ID_NOT_IN_INVENTORY_   -> DirClass
  E_ID_RETIRED_            -> DirClass
  E_ID_TYPE_MISMATCH_      -> DirClass
  E_ID_CHAPTER_MISMATCH_   -> DirClass
  E_DECK_REQUIRES_UNKNOWN_ -> DirClass
  E_DECK_REQUIRES_CYCLE_   -> DirClass
  E_BLOCK_UNPARSED_        -> SeamClass
  _                        -> FileClass

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
