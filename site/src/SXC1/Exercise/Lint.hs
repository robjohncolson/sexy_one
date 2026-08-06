{-# LANGUAGE OverloadedStrings #-}

-- | The terminology linter: @content\/terminology-rules.tsv@'s
-- six-tab-separated-column format, and literal (NO REGEX -- there is no
-- regex engine in the boot libraries, and every match here must be
-- re-derivable in Python line for line, since @scripts\/check-site.sh@
-- and the negative-control harness do exactly that) phrase matching
-- against learner-facing text.
module SXC1.Exercise.Lint
  ( RuleKind (..)
  , Rule (..)
  , parseRules
  , groundRules
  , lintText
  , lintInlines
  , lintBlocks
  , inlinesText
  , blocksText
  , findOccurrencesCI
  ) where

import           Data.Text             (Text)
import qualified Data.Text             as T

import           SXC1.Content.Types    (Block (..), Inline (..), ListItem (..))
import           SXC1.Exercise.Report

--------------------------------------------------------------------------
-- Rules
--------------------------------------------------------------------------

data RuleKind = Forbid | CaseOf
  deriving (Eq, Show)

data Rule = Rule
  { ruleId          :: !Text
  , ruleLine        :: !Int  -- ^ 1-based line in @content\/terminology-rules.tsv@
  , ruleKind        :: !RuleKind
  , rulePhrases     :: [Text]
  , ruleReplacement :: !Text
  , ruleAnchor      :: !Text
  , ruleMessage     :: !Text
  } deriving (Eq)

rulesFileName :: Text
rulesFileName = "content/terminology-rules.tsv"

parseKind :: Text -> Maybe RuleKind
parseKind t = case T.strip t of
  "forbid" -> Just Forbid
  "caseof" -> Just CaseOf
  _        -> Nothing

-- | One non-blank, non-comment row -> either why it is malformed, or the
-- 'Rule' it describes. There is no dedicated issue code for "malformed
-- terminology rule row" in the closed set (@content\/terminology-rules.tsv@
-- is validator CONFIGURATION, not exercise content) -- structural
-- problems here are reported as 'E_RULE_UNGROUNDED' (the one dir-class
-- code this file owns), with the specific reason in the detail field.
parseRuleRow' :: Int -> Text -> Either Text Rule
parseRuleRow' ln l = case T.splitOn "\t" l of
  [ridT, kindT, phrasesT, replT, anchorT, msgT] ->
    let rid     = T.strip ridT
        phrases = filter (not . T.null) (map T.strip (T.splitOn "," phrasesT))
        anchor  = T.strip anchorT
        msg     = T.strip msgT
    in if T.null rid
         then Left "empty rule_id"
         else case parseKind kindT of
                Nothing -> Left ("unknown rule kind " <> T.strip kindT <> " (want forbid or caseof)")
                Just kind
                  | null phrases   -> Left "rule has no phrases"
                  | T.null anchor  -> Left "rule has an empty glossary_anchor"
                  | T.null msg     -> Left "rule has an empty message"
                  | kind == CaseOf, any ((<= 1) . T.length) phrases
                      -> Left "a caseof rule may not have a single-character phrase (it would collide with ordinary English)"
                  | otherwise -> Right (Rule rid ln kind phrases (T.strip replT) anchor msg)
  cols -> Left ("want 6 tab-separated columns, got " <> T.pack (show (length cols)))

-- | Parse the whole TSV: @#@ comment lines and blank lines are ignored;
-- every other line is either a well-formed 'Rule' or an 'Issue'. Never
-- throws.
parseRules :: Text -> ([Issue], [Rule])
parseRules raw = go (zip [1 :: Int ..] (T.lines raw)) [] []
  where
    go [] issuesAcc rulesAcc = (reverse issuesAcc, reverse rulesAcc)
    go ((ln, l) : rest) issuesAcc rulesAcc
      | T.null stripped               = go rest issuesAcc rulesAcc
      | "#" `T.isPrefixOf` stripped   = go rest issuesAcc rulesAcc
      | otherwise = case parseRuleRow' ln l of
          Left problem -> go rest (mkIssue E_RULE_UNGROUNDED (Loc rulesFileName ln) problem : issuesAcc) rulesAcc
          Right rule   -> go rest issuesAcc (rule : rulesAcc)
      where
        stripped = T.strip l

-- | Cross-check every rule's 'ruleAnchor' against the binding glossary --
-- the actual "is this rule traceable to house style" grounding check
-- ('parseRuleRow'' only catches STRUCTURALLY malformed rows). A rule
-- whose anchor is not a literal substring of @translations\/glossary.md@
-- is 'E_RULE_UNGROUNDED'.
groundRules :: Text -> [Rule] -> [Issue]
groundRules glossarySrc rules =
  [ mkIssue E_RULE_UNGROUNDED (Loc rulesFileName (ruleLine r))
      ("rule " <> ruleId r <> "'s glossary_anchor \"" <> ruleAnchor r
         <> "\" does not occur in translations/glossary.md")
  | r <- rules
  , not (ruleAnchor r `T.isInfixOf` glossarySrc)
  ]

--------------------------------------------------------------------------
-- Matching -- literal, case-insensitive, word-bounded. NO REGEX.
--------------------------------------------------------------------------

-- | "ASCII letter, digit or hyphen" -- the exact boundary alphabet the
-- format spec defines for @forbid@. Applied to 'CaseOf' matches too (not
-- required by the spec in so many words, but the same reasoning applies:
-- without it, a caseof phrase like @\"SXC-1\"@ would also match inside
-- an unrelated longer token such as a hypothetical @\"SXC-10\"@ -- a
-- false positive a word boundary check avoids for both rule kinds).
isWordChar :: Char -> Bool
isWordChar c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-'

-- | Every 0-based start offset in @haystack@ where @needle@ occurs,
-- compared case-insensitively. Naive @O(n*m)@ scan -- learner-facing
-- text fields are at most a few hundred characters, so this is fine, and
-- (per the module Haddock) it is exactly what a from-scratch Python
-- re-derivation would also do: no regex engine, either side.
findOccurrencesCI :: Text -> Text -> [Int]
findOccurrencesCI needle haystack
  | T.null needle = []
  | otherwise     = go 0 haystack
  where
    lowNeedle = T.toLower needle
    nlen      = T.length needle
    go offset hs
      | T.length hs < nlen        = []
      | T.toLower (T.take nlen hs) == lowNeedle = offset : go (offset + 1) (T.drop 1 hs)
      | otherwise                                = go (offset + 1) (T.drop 1 hs)

-- | 'findOccurrencesCI', filtered to occurrences not flanked by a word
-- character on either side.
wordBoundedHits :: Text -> Text -> [Int]
wordBoundedHits needle haystack =
  [ off
  | off <- findOccurrencesCI needle haystack
  , boundaryOk (charAt (off - 1))
  , boundaryOk (charAt (off + T.length needle))
  ]
  where
    n = T.length haystack
    charAt i
      | i < 0 || i >= n = Nothing
      | otherwise       = Just (T.index haystack i)
    boundaryOk = maybe True (not . isWordChar)

termIssue :: Rule -> Loc -> Text -> Issue
termIssue r loc detail = Issue ("E-TERM." <> ruleId r) (locFile loc) (locLine loc) detail

forbidDetail :: Rule -> Text -> Text
forbidDetail r p = "forbidden phrase \"" <> p <> "\" -- " <> ruleMessage r
  <> (if T.null (ruleReplacement r) then "" else " (use \"" <> ruleReplacement r <> "\" instead)")

caseofDetail :: Rule -> Text -> Text -> Text
caseofDetail r canonical got = "\"" <> got <> "\" must be spelled exactly \"" <> canonical <> "\" -- " <> ruleMessage r

-- | Lint one field's learner-facing plain text against every rule.
-- Word-bounded, case-insensitive literal matching only -- see the module
-- Haddock.
lintText :: [Rule] -> Loc -> Text -> [Issue]
lintText rules loc text = concatMap oneRule rules
  where
    oneRule r = case ruleKind r of
      Forbid ->
        [ termIssue r loc (forbidDetail r p)
        | p <- rulePhrases r
        , not (null (wordBoundedHits p text))
        ]
      CaseOf ->
        [ termIssue r loc (caseofDetail r p got)
        | p <- rulePhrases r
        , off <- wordBoundedHits p text
        , let got = T.take (T.length p) (T.drop off text)
        , got /= p
        ]

-- | Lint a run of inline content (a title, a summary line, an option
-- label, a @check:@ sentence, ...) -- flattens it to plain text first
-- via 'inlinesText'.
lintInlines :: [Rule] -> Loc -> [Inline] -> [Issue]
lintInlines rules loc inlines = lintText rules loc (inlinesText inlines)

-- | Lint a run of body blocks (a deck's intro, an exercise's body, an
-- @### Why@\/@### Answer@\/@### Hint@ role's blocks, ...) -- flattens it
-- to plain text first via 'blocksText'.
lintBlocks :: [Rule] -> Loc -> [Block] -> [Issue]
lintBlocks rules loc blocks = lintText rules loc (blocksText blocks)

--------------------------------------------------------------------------
-- Flattening [Block]/[Inline] to plain learner-facing text
--
-- Per the format spec, learner-facing text is "deck title/summary,
-- exercise titles, all body prose (including inline code spans), option
-- labels, check: sentences, and Answer/Why/Hint blocks". 'Code' spans are
-- therefore included (unlike "SXC1.Content.Markdown"'s own literal-hash
-- guard in test/CheckContent.hs, which deliberately keeps only 'Str');
-- 'Break' carries no text; 'PageRef'/'Placeholder' contribute their
-- display text (a bare page reference cannot fire in exercise prose
-- anyway -- pageCount is 0, probe P-H -- but a citation's rendered anchor
-- text or a figure caption still might, so both are included for safety).
--------------------------------------------------------------------------

inlinesText :: [Inline] -> Text
inlinesText = T.intercalate " " . map inlineText

inlineText :: Inline -> Text
inlineText i = case i of
  Str t          -> t
  Strong xs      -> inlinesText xs
  Em xs          -> inlinesText xs
  Code t         -> t
  Break          -> ""
  Placeholder _ t -> t
  PageRef _ t     -> t

blocksText :: [Block] -> Text
blocksText = T.intercalate " " . map blockText

blockText :: Block -> Text
blockText b = case b of
  Heading _ inlines _ -> inlinesText inlines
  Para inlines         -> inlinesText inlines
  Figure _ capInlines   -> inlinesText capInlines
  Bullets items          -> T.intercalate " " (map listItemText items)
  Numbered _ items        -> T.intercalate " " (map listItemText items)
  Quote inner               -> blocksText inner
  Table mHeader rows          ->
    T.intercalate " " (map inlinesText (maybe [] id mHeader) ++ concatMap (map inlinesText) rows)
  Unparsed t                    -> t

listItemText :: ListItem -> Text
listItemText (ListItem content children) = inlinesText content <> " " <> blocksText children
