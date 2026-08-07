{-# LANGUAGE OverloadedStrings #-}

-- | The exercise content model -- the shape a parsed @.ex.md@ deck takes.
-- Deliberately inert, mirroring "SXC1.Content.Types": this module defines
-- shapes only. See "SXC1.Exercise.Parse" for how values are produced,
-- "SXC1.Exercise.Verify" for how citations\/verify hooks are resolved
-- against the manual corpus, and "SXC1.Exercise.Engine" for the pure
-- state machine that plays a parsed 'Exercise'.
--
-- SIZE DISCIPLINE (briefs\/M2-manifest.json, task \"exercise-core\"): these
-- types are linked into the browser app. 'Deck', 'Exercise', 'Prompt',
-- 'PromptBody', 'Option' and 'Citation' derive 'Eq' ONLY -- no derived
-- 'Show'. Derived 'Show' on wide sum\/record types is a well-known wasm
-- code-size cost, and @app.wasm@ gzips to 828 138 bytes against
-- @check-site.sh@'s hard 1 000 000-byte ceiling: 171 862 bytes of
-- headroom for ALL of M2. Wherever a diagnostic needs to print one of
-- these, hand-write a small renderer instead (see
-- @site\/test\/CheckExercises.hs@'s @render*@ helpers) -- it needs
-- @file:line: CODE detail@ formatting anyway, so a derived 'Show' would
-- not even be the right shape to print. 'Show' on the small enums
-- ('Kind', 'VerifySpec') is fine and is derived below.
module SXC1.Exercise.Types
  ( DeckId (..)
  , ExId (..)
  , PromptId (..)
  , Citation (..)
  , Kind (..)
  , Deck (..)
  , Exercise (..)
  , Prompt (..)
  , PromptBody (..)
  , Option (..)
  , VerifySpec (..)
  , promptIdFor
  ) where

import           Data.Text          (Text)
import qualified Data.Text          as T

import           SXC1.Content.Types (Block, Inline)

-- | A deck's stable identifier, e.g. @\"pad-play-banks\"@.
newtype DeckId = DeckId Text
  deriving (Eq, Show)

-- | An exercise's stable identifier, drawn from
-- @content\/exercise-inventory.md@, e.g. @\"pad-play-bank-a-button\"@.
newtype ExId = ExId Text
  deriving (Eq, Show)

-- | A single prompt's stable identifier: @\"\<exercise-id\>#\<1-based
-- index\>\"@ -- see 'promptIdFor'. Stable across content edits that do
-- not change prompt count or order, which is what lets M3 key saved
-- progress to it.
newtype PromptId = PromptId Text
  deriving (Eq, Show)

-- | A manual citation: one of the four translated documents, a page
-- within it, and the verbatim anchor phrase the citation is grounded in.
-- See "SXC1.Exercise.Verify".'SXC1.Exercise.Verify.resolveCitation' for
-- how this is content-verified against the real corpus.
data Citation = Citation
  { citSlug   :: !Text
  , citPage   :: !Int
  , citAnchor :: !Text
  } deriving (Eq)

-- | The three exercise types the @.ex.md@ grammar recognises.
data Kind = KQuiz | KDrill | KLookup
  deriving (Eq, Show)

-- | One deck: a small ordered group of exercises from one part of one
-- chapter, parsed from one @.ex.md@ file.
data Deck = Deck
  { dkId        :: !DeckId
  , dkTitle     :: !Text
  , dkChapter   :: !Text
  , dkSummary   :: [Inline]
  , dkCites     :: [Citation]
  , dkIntro     :: [Block]
  , dkTags      :: [Text]
  , dkTier      :: !Text    -- ^ @intro@\/@core@\/@stretch@ -- see @tier:@,
                             -- content\/EXERCISE-FORMAT.md
  , dkRequires  :: [Text]   -- ^ deck-level prerequisite deck slugs -- see
                             -- @requires:@, content\/EXERCISE-FORMAT.md
  , dkExercises :: [Exercise]
  } deriving (Eq)

-- | One exercise within a deck: a quiz, a drill, or a lookup.
data Exercise = Exercise
  { exId      :: !ExId
  , exDeck    :: !DeckId
  , exKind    :: !Kind
  , exTitle   :: !Text
  , exCites   :: [Citation]
  , exTags    :: [Text]
  , exIntro   :: [Block]
  , exPrompts :: [Prompt]
  , exNote    :: [Block]    -- ^ the @### Why@ role, if present
  , exHints   :: [[Block]]  -- ^ the @### Hint@ role(s), in order (0..3)
  } deriving (Eq)

-- | One learner-facing prompt: a quiz maps to exactly one 'Prompt', a
-- drill maps to one 'Prompt' per @### Step@ (in order), a lookup maps to
-- exactly one 'Prompt'.
data Prompt = Prompt
  { prId    :: !PromptId
  , prStem  :: [Block]
  , prCites :: [Citation]
  , prBody  :: !PromptBody
  } deriving (Eq)

-- | The four ways a prompt can be graded -- see
-- "SXC1.Exercise.Engine".'SXC1.Exercise.Engine.step' for how each is
-- graded.
data PromptBody
  = Choice   { pcOptions :: [Option] }               -- ^ quiz, choice mode; multi iff >1 correct
  | Recall   { prAnswer  :: [Block] }                 -- ^ quiz, recall mode
  | Confirm  { pcCheck   :: [Inline], pcVerify :: Maybe VerifySpec } -- ^ drill step
  | FindPage { fpTarget  :: !Citation, fpLimitSec :: Maybe Int }     -- ^ lookup
  deriving (Eq)

-- | One choice-mode option. 'optId' is POSITIONAL -- @\"a\"@, @\"b\"@,
-- @\"c\"@, ... by order -- never derived from the label text, so the DOM
-- ids @opt-a@\/@opt-b@ stay stable when an author rewords an option.
data Option = Option
  { optId      :: !Text
  , optLabel   :: [Inline]
  , optCorrect :: !Bool
  } deriving (Eq)

-- | The M4 WebMIDI hook. Parsed and VALIDATED in M2 (against
-- @translations\/midi.md@, see "SXC1.Exercise.Verify"), executed in M4.
data VerifySpec
  = VerifyCC   { vcNumber :: !Int, vcValues :: [Int] }
  | VerifyNote { vnNumbers :: [Int] }
  | VerifyPad  { vpPad :: !Int, vpBank :: !Char }
  | VerifyAny
  deriving (Eq, Show)

-- | @\"\<exercise-id\>#\<1-based index\>\"@ -- STABLE: M3 keys a
-- learner's saved progress and spaced-repetition schedule to this.
promptIdFor :: ExId -> Int -> PromptId
promptIdFor (ExId eid) i = PromptId (eid <> "#" <> T.pack (show i))
