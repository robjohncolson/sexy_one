{-# LANGUAGE OverloadedStrings #-}

-- | @exe:exercise-check@ -- a wasm32-wasi COMMAND module (no reactor
-- flags), run on the host via @wasm-run.mjs@. THE ONLY MODULE IN THE
-- PROJECT THAT TOUCHES THE FILESYSTEM -- every other exercise module
-- (SXC1.Exercise.Parse\/Lint\/Verify\/Engine\/Report) is pure.
--
-- Usage:
--   exercise-check [--content-dir DIR] [--translations-dir DIR]
--                  [--json] [--self-test] [--fixtures DIR]
--                  [--list-codes] [--browser-fixture]
--                  [--bundle-structural-diff EN JA]
--                  [--manual-structural-diff EN JA]
--
-- See briefs\/M2-manifest.json, task \"exercise-core\", item (9) for the
-- full contract. Exit codes: 0 all good; 1 validation\/assertion
-- failures; 2 harness error (missing directory, unreadable file, bad
-- arguments).
module Main (main) where

import           Control.Exception      (IOException, try)
import           Control.Monad          (forM, forM_, unless, when)
import qualified Data.ByteString        as BS
import qualified Data.IntMap.Strict     as IntMap
import qualified Data.IntSet            as IntSet
import           Data.List              (intercalate, isPrefixOf, isSuffixOf, sortOn)
import qualified Data.Map.Strict        as Map
import           Data.Map.Strict        (Map)
import           Data.Maybe             (mapMaybe, maybeToList)
import qualified Data.Set               as Set
import           Data.Text              (Text)
import qualified Data.Text              as T
import qualified Data.Text.Encoding     as TE
import           System.Directory       (doesDirectoryExist, doesFileExist, listDirectory)
import           System.Environment     (getArgs)
import           System.Exit            (ExitCode (ExitFailure), exitFailure, exitSuccess, exitWith)
import           System.FilePath        ((</>))
import           System.IO              (hPutStrLn, hSetEncoding, stderr, stdout, utf8)

-- 'mkDoc' is imported for --manual-structural-diff (M7 W3, ruling 5):
-- the checker parses both manual bundles with the READER'S OWN parser,
-- the exact function View.Pages.mkManuals calls, so the two cannot
-- drift.
import           SXC1.Content.Markdown  (LineShape (..), classifyLine, mkDoc, parseBlocksEngineWith)
import           SXC1.Content.Types     (Block (..), Doc (docPages), ListItem (liChildren),
                                          Page (pageBlocks, pageHeader, pageNumber))
import           SXC1.Exercise.Engine
import           SXC1.Exercise.Lint
import           SXC1.Exercise.Parse
import           SXC1.Exercise.Reader   (DeckSyn (..), ExSyn (..), FieldLine (..), StepSyn (..),
                                          isJaLine, readDeck, readDeckSyn)
import           SXC1.Exercise.Report
import           SXC1.Exercise.Types
import           SXC1.Exercise.Verify
import           SXC1.Midi.Spec
import           SXC1.Midi.Table        (parsePadNotes)
import           SXC1.Mastery
import           SXC1.Progress.Types
import           SXC1.Route             (Route (..), parseRoute, renderRoute)

--------------------------------------------------------------------------
-- CLI
--------------------------------------------------------------------------

data Opts = Opts
  { optContentDir      :: FilePath
  , optTranslationsDir :: FilePath
  , optJson            :: Bool
  , optSelfTest         :: Bool
  , optFixtures         :: Maybe FilePath
  , optListCodes        :: Bool
  , optBrowserFixture   :: Bool
    -- | M6 gate round 1 (briefs\/M6-codex-gate1.json, finding M6-R1-2):
    -- @--bundle-structural-diff EN JA@ -- the two emitted content
    -- bundles to compare for STRUCTURAL identity.
  , optBundleDiff       :: Maybe (FilePath, FilePath)
    -- | M7 W3 (briefs\/M7-plan.md, ruling 5):
    -- @--manual-structural-diff EN JA@ -- the two emitted MANUAL
    -- bundles to compare for STRUCTURAL identity, page by page.
  , optManualDiff       :: Maybe (FilePath, FilePath)
  }

defaultOpts :: FilePath -> Opts
defaultOpts root = Opts
  { optContentDir = root </> "content", optTranslationsDir = root </> "translations"
  , optJson = False, optSelfTest = False, optFixtures = Nothing
  , optListCodes = False, optBrowserFixture = False
  , optBundleDiff = Nothing
  , optManualDiff = Nothing
  }

-- | @content\/fixtures@'s default location under the resolved repo root
-- ('resolveRootPrefix' -- the same root the default @--content-dir@\/
-- @--translations-dir@ hang off). Letting @--fixtures@ omit its
-- directory (defaulting to this) is what lets @exercise-check
-- --fixtures@ (no path) work the same way @exercise-check@ alone already
-- does for @--content-dir@.
defaultFixturesDir :: FilePath -> FilePath
defaultFixturesDir root = root </> "content" </> "fixtures"

parseArgs :: FilePath -> [String] -> Either String Opts
parseArgs root = go (defaultOpts root)
  where
    go o [] = Right o
    go o ("--content-dir" : d : rest)      = go o { optContentDir = d } rest
    go o ("--translations-dir" : d : rest) = go o { optTranslationsDir = d } rest
    go o ("--json" : rest)                 = go o { optJson = True } rest
    go o ("--self-test" : rest)            = go o { optSelfTest = True } rest
    -- '--fixtures' takes an OPTIONAL directory: the next token if it does
    -- not itself look like another flag, else 'defaultFixturesDir'.
    go o ("--fixtures" : d : rest) | not ("--" `isPrefixOf` d) = go o { optFixtures = Just d } rest
    go o ("--fixtures" : rest)             = go o { optFixtures = Just (defaultFixturesDir root) } rest
    go o ("--list-codes" : rest)           = go o { optListCodes = True } rest
    go o ("--browser-fixture" : rest)      = go o { optBrowserFixture = True } rest
    go o ("--bundle-structural-diff" : en : ja : rest)
      | not ("--" `isPrefixOf` en), not ("--" `isPrefixOf` ja)
      = go o { optBundleDiff = Just (en, ja) } rest
    go o ("--manual-structural-diff" : en : ja : rest)
      | not ("--" `isPrefixOf` en), not ("--" `isPrefixOf` ja)
      = go o { optManualDiff = Just (en, ja) } rest
    go _ (bad : _)                         = Left ("unknown or incomplete argument: " ++ bad)

--------------------------------------------------------------------------
-- Harness plumbing (IO -- everything else in the project is pure)
--------------------------------------------------------------------------

harnessError :: String -> IO a
harnessError msg = do
  hPutStrLn stderr ("exercise-check: " ++ msg)
  exitWith (ExitFailure 2)

-- | UTF-8 decode explicitly from bytes (not 'Data.Text.IO', whose
-- decoding depends on the host locale -- same reasoning as
-- "SXC1.Content.Embed").
readUtf8File :: FilePath -> IO Text
readUtf8File fp = TE.decodeUtf8 <$> BS.readFile fp

readUtf8FileOrHarnessError :: FilePath -> IO Text
readUtf8FileOrHarnessError fp = do
  r <- try (readUtf8File fp) :: IO (Either IOException Text)
  case r of
    Right t -> pure t
    Left e  -> harnessError ("cannot read " ++ fp ++ ": " ++ show e)

-- | M5 (briefs\/M5-ship.md, debt item 6): the resolved repo-root prefix
-- every DEFAULT path in this module hangs off. Historically all of them
-- were spelled @..@-relative (@..\/content@, @..\/translations@, ...),
-- which silently assumed @site\/@ as the working directory: run from
-- the repo root, every disk-touching mode died with a harness error
-- (M2 advisory, authoring-UX wart). The root is now probed: the first
-- of @.@, @..@, @..\/..@, @..\/..\/..@ that carries
-- @content\/exercise-inventory.md@ (the one file that structurally
-- marks this project's root, and the very file 'fixedInventoryPath'
-- must reach anyway) wins. If none matches, @..@ is returned so the
-- historical default -- and its error messages -- are preserved
-- exactly. Explicit @--content-dir@\/@--translations-dir@\/
-- @--fixtures DIR@ arguments are never affected: only the defaults
-- (and the self-test's disk groups 17\/18\/20) move with the resolved
-- root.
resolveRootPrefix :: IO FilePath
resolveRootPrefix = go [".", "..", "../..", "../../.."]
  where
    go []       = pure ".."
    go (c : cs) = do
      hit <- doesFileExist (c </> "content" </> "exercise-inventory.md")
      if hit then pure c else go cs

-- | @content\/exercise-inventory.md@ is ALWAYS read from this fixed
-- root-relative path (under 'resolveRootPrefix') -- never from
-- @--content-dir@ (which only governs where EXERCISE FILES and
-- @terminology-rules.tsv@ come from, and is exactly what @--fixtures@
-- and ad-hoc sandboxes override). This is what lets chapter-title
-- validation work correctly even when @--content-dir@ points at a
-- sandbox that carries no inventory of its own (see
-- 'inventoryScopedCodes' below for the complementary half of this
-- design: which runs the id-binding checks apply to is a STRUCTURAL,
-- per-run decision, never a path-spelling one).
fixedInventoryPath :: FilePath -> FilePath
fixedInventoryPath root = root </> "content" </> "exercise-inventory.md"

--------------------------------------------------------------------------
-- The shared resolution context
--------------------------------------------------------------------------

data SharedCtx = SharedCtx
  { scRules        :: [Rule]
  , scManualIdx    :: ManualIndex
  , scMidiFacts    :: MidiFacts
  , scChapterVocab :: Map Int Text
  , scInventoryRaw :: Text
  }

loadSharedCtx :: FilePath -> FilePath -> IO ([Issue], SharedCtx)
loadSharedCtx contentDir translationsDir = do
  rulesRaw <- readUtf8FileOrHarnessError (contentDir </> "terminology-rules.tsv")
  let (ruleIssues, rules) = parseRules rulesRaw
  glossaryRaw <- readUtf8FileOrHarnessError (translationsDir </> "glossary.md")
  let groundIssues = groundRules glossaryRaw rules
  manualSources <- forM
    [ ("guide-book", "guide-book.md"), ("startup-guide", "startup-guide.md")
    , ("midi", "midi.md"), ("oss", "oss.md")
    ] $ \(slug, fn) -> do
      raw <- readUtf8FileOrHarnessError (translationsDir </> fn)
      pure (slug, raw)
  let manualIdx = buildManualIndex manualSources
      midiRaw   = maybe "" id (lookup "midi" manualSources)
      midiFacts = buildMidiFacts midiRaw
  root <- resolveRootPrefix
  inventoryRaw <- readUtf8FileOrHarnessError (fixedInventoryPath root)
  let chapterVocab = parseInventoryChapters inventoryRaw
  pure ( ruleIssues ++ groundIssues
       , SharedCtx
           { scRules = rules, scManualIdx = manualIdx, scMidiFacts = midiFacts
           , scChapterVocab = chapterVocab, scInventoryRaw = inventoryRaw
           }
       )

-- | M5 (briefs\/M5-ship.md, debt item 7): the STRUCTURAL id-binding
-- scope. The four id-inventory-binding checks (E-ID-NOT-IN-INVENTORY\/
-- E-ID-RETIRED\/E-ID-TYPE-MISMATCH\/E-ID-CHAPTER-MISMATCH) and the two
-- corpus-wide @requires:@ checks (E-DECK-REQUIRES-UNKNOWN\/-CYCLE)
-- apply "over content\/exercises\/ only, never to --fixtures"
-- (briefs\/M2-manifest.json). Until M5 that scope was decided by a PATH
-- SUBSTRING -- a deck bound iff its own file path contained the literal
-- @content\/exercises\/@ -- which is exactly why every dirs\/ fixture
-- that wants these checks is named @...--fixture-content@ (its decks
-- then live under @...-content\/exercises\/@), and why a moved, copied
-- or renamed content root silently disabled all six checks with
-- everything else still green (M2 advisory; M5 debt registry item 7).
-- The scope is now decided STRUCTURALLY, per run, with no path
-- inspection at all:
--
--   * the real-corpus modes (default, @--json@, @--browser-fixture@)
--     ALWAYS bind -- their contract is the corpus governed by
--     'fixedInventoryPath', wherever that tree happens to sit on disk;
--   * a @--fixtures@ dirs\/ fixture binds iff the code its own name
--     declares is one of the six inventory-scoped codes below -- the
--     fixture opts in by what it claims to falsify, not by how its
--     path happens to be spelled;
--   * loose files\/ fixtures never bind (a single file is no corpus).
--
-- The scope actually firing on the real corpus stays observable as
-- @totals.inventoryChecked@ (see 'ldInventoryChecked' and
-- scripts\/check-site.sh's "inventory-binding-scope-fired" check).
inventoryScopedCodes :: [Text]
inventoryScopedCodes = map codeText
  [ E_ID_NOT_IN_INVENTORY, E_ID_RETIRED, E_ID_TYPE_MISMATCH, E_ID_CHAPTER_MISMATCH
  , E_DECK_REQUIRES_UNKNOWN, E_DECK_REQUIRES_CYCLE
  ]

-- | M6 W4 (briefs\/M6-plan.md ruling 2): the SECOND structural scope,
-- built the same way 'inventoryScopedCodes' is and for the same reason.
-- JA completeness (E-JA-MISSING, see 'jaCompletenessIssues') is a
-- LIVE-CORPUS contract: the decks @content\/exercises\/INDEX@ ships are
-- the decks @scripts\/emit-content-bundles.py@ translates into
-- @content.ja.txt@, so those -- and only those -- must carry a @ja:@
-- variant for every learner-visible piece. A loose @content\/fixtures@
-- deck is not a shipping deck (none of them carries a single @ja:@
-- line, and demanding one would say nothing true about the course), so
-- the check is scoped exactly like the six inventory-scoped codes:
--
--   * the real-corpus modes (default, @--json@, @--browser-fixture@)
--     ALWAYS bind it;
--   * a @--fixtures@ dirs\/ fixture binds it iff the code its own name
--     declares is one of the codes below -- it opts in by what it
--     claims to falsify, never by how its path is spelled;
--   * loose files\/ fixtures never bind it.
--
-- Kept as its OWN list (rather than folded into
-- 'inventoryScopedCodes') precisely so the two scopes stay
-- independent: every existing dirs\/ fixture opts into the inventory
-- binding WITHOUT thereby acquiring a JA-completeness demand it was
-- never written to satisfy.
jaScopedCodes :: [Text]
jaScopedCodes = map codeText [ E_JA_MISSING ]

-- | Which corpus-wide check families apply to ONE 'collectFromDirs'
-- run. Decided STRUCTURALLY, per run, by the caller (never by
-- inspecting a path) -- see 'inventoryScopedCodes' and 'jaScopedCodes'.
data BindScope = BindScope
  { bsInventory :: !Bool  -- ^ the four E-ID-* inventory bindings + the two requires: checks
  , bsJa        :: !Bool  -- ^ E-JA-MISSING (M6 W4)
  }

-- | The real corpus governed by 'fixedInventoryPath': every corpus-wide
-- family binds, wherever that tree sits on disk.
realCorpusScope :: BindScope
realCorpusScope = BindScope { bsInventory = True, bsJa = True }

-- | A loose @files\/@ fixture: a single deck file is no corpus, so no
-- corpus-wide family binds.
looseFileScope :: BindScope
looseFileScope = BindScope { bsInventory = False, bsJa = False }

-- | A @dirs\/@ fixture opts into each family by the code its own
-- directory name declares.
fixtureDirScope :: Text -> BindScope
fixtureDirScope declared = BindScope
  { bsInventory = declared `elem` inventoryScopedCodes
  , bsJa        = declared `elem` jaScopedCodes
  }

-- | Resolve every issue for ONE already-read deck file: grammar
-- ("SXC1.Exercise.Parse"), citation and verify-hook resolution
-- ("SXC1.Exercise.Verify"), terminology ("SXC1.Exercise.Lint"), chapter
-- title, and -- each iff its own family binds for this run (decided
-- structurally by the caller, see 'BindScope') -- the inventory binding
-- and the M6 JA-completeness check.
resolveDeckIssues :: SharedCtx -> BindScope -> FilePath -> Text -> ([Issue], Maybe Deck)
resolveDeckIssues ctx scope fp raw =
  (parseIssues ++ citeIssues ++ verifyIssues ++ termIssues ++ chapterIssues ++ idIssues ++ jaIssues, mDeck)
  where
    (parseIssues, mDeck, cites, verifies, mChapterField, idRows, lintTargets) = parseDeckDetailed fp raw
    citeIssues    = concat [ resolveCitation (scManualIdx ctx) loc c | (loc, c) <- cites ]
    verifyIssues  = concat [ resolveVerify (scMidiFacts ctx) loc v | (loc, v) <- verifies ]
    termIssues    = concat [ lintText (scRules ctx) loc t | (loc, t) <- lintTargets ]
    chapterIssues = case mChapterField of
      Just (loc, txt) -> resolveChapter (scChapterVocab ctx) loc txt
      Nothing         -> []
    idIssues
      | bsInventory scope =
          concat [ resolveInventoryId (scInventoryRaw ctx) (scChapterVocab ctx) loc eid kind chText
                 | (loc, eid, kind, chText) <- idRows ]
      | otherwise = []
    jaIssues
      | bsJa scope = jaCompletenessIssues fp raw
      | otherwise  = []

--------------------------------------------------------------------------
-- M6 W4: JA COMPLETENESS (E-JA-MISSING)
--
-- briefs/M6-plan.md ruling 2: "exercise-check gains JA-completeness
-- enforcement (a live exercise missing any ja: variant is an issue, not
-- a warning, once wave 3 lands)". Wave 3 landed (all 52 decks
-- translated and QA-ACCEPTED), so this is now HARD: a live deck with an
-- untranslated learner-visible piece makes exercise-check exit 1, which
-- makes check-site's exercise-validator gate red.
--
-- THE RULE, in one sentence: every learner-visible UNIT of a deck file
-- must be immediately followed by a column-0 @ja:@ line.
--
-- That is exactly the emitter's own substitution rule read backwards.
-- scripts/emit-content-bundles.py attaches each maximal @ja:@ run to
-- the segment of English lines ENDING AT THE LINE DIRECTLY ABOVE IT
-- (heading -> that heading; option -> that option; field -> that field
-- plus its continuation lines; otherwise -> the whole contiguous prose
-- block). So a unit ends up in content.ja.txt in Japanese iff the line
-- after the unit's LAST line is a variant line, and "is this piece
-- translated?" needs no re-implementation of the substitution itself --
-- only the same classification of lines, done here independently in
-- Haskell (house standard: a check that counts must count
-- independently; if the two classifications ever disagree the emitter
-- fails the build loudly rather than shipping something this check
-- blessed).
--
-- THE LEARNER-VISIBLE UNITS are content/EXERCISE-FORMAT.md sec. 12's
-- table, one for one:
--   * the deck title (a level-1 heading)          -> 'JuHeading'
--   * every exercise title (a level-2 heading)    -> 'JuHeading'
--   * the deck's summary: and every step's check: -> 'JuField'
--   * every choice-list option line               -> 'JuOption'
--   * every prose block (deck intro, exercise body, ### Why/Hint/Answer
--     block, drill step body)                     -> 'JuProse'
--
-- THE EXCLUSIONS are structural and exhaustive -- there is no per-file,
-- per-deck or per-line opt-out anywhere in this checker:
--   1. LEVEL-3 ROLE HEADINGS (### Step/Why/Hint/Answer). The UI
--      localizes those labels (I18n.hs), the content does not -- sec.
--      12's "What may NOT carry a variant" list says so, and the
--      emitter would accept a variant here, so excluding them is a
--      deliberate contract, not an oversight.
--   2. EVERY FIELD KEY EXCEPT summary:/check:. cite:/find:/verify:/
--      type:/id:/deck:/chapter:/tier:/tags:/requires:/limit: are
--      language-invariant by ruling 2, and the emitter REFUSES a
--      variant on them (its ALLOWED_FIELD_KEYS); this checker's
--      'jaTranslatableFieldKeys' is the same set, so the two ends of
--      the contract cannot drift apart silently.
--   3. Blank lines and the @ja:@ lines themselves.
--------------------------------------------------------------------------

-- | The ONLY field keys whose VALUE is learner-visible, and therefore
-- the only ones that may (and must) carry a @ja:@ variant. Mirrors
-- @scripts/emit-content-bundles.py@'s @ALLOWED_FIELD_KEYS@ exactly --
-- see exclusion 2 above.
jaTranslatableFieldKeys :: [Text]
jaTranslatableFieldKeys = ["summary", "check"]

-- | One learner-visible piece of a deck source file.
data JaUnit = JaUnit
  { juKind  :: !Text  -- ^ what it is, in the words of EXERCISE-FORMAT.md sec. 12
  , juHead  :: !Text  -- ^ its first line (quoted back in the issue detail)
  , juStart :: !Int   -- ^ 1-based line the unit starts on
  , juEnd   :: !Int   -- ^ 1-based line it ends on -- the @ja:@ run must sit directly below THIS
  }

-- | @#@\/@##@\/@###@ at column 0, followed by a space and a non-space --
-- the same structural-heading shape the emitter's @HEADING_RE@ uses.
jaHeadingLevelOf :: Text -> Maybe Int
jaHeadingLevelOf l =
  let (hashes, rest) = T.span (== '#') l
      n = T.length hashes
  in if n >= 1 && n <= 3
       then case T.uncons rest of
              Just (' ', more) | not (T.null (T.stripStart more)) -> Just n
              _ -> Nothing
       else Nothing

-- | A column-0 GFM task-list option line (the emitter's @OPTION_RE@).
jaIsOptionLine :: Text -> Bool
jaIsOptionLine l =
  any (`T.isPrefixOf` l) ["- [ ] ", "- [x] ", "- [X] "]
    && not (T.null (T.stripStart (T.drop 6 l)))

-- | A column-0 @key:@ field line, returning its key (the emitter's
-- @FIELD_RE@ / "SXC1.Exercise.Reader".@fieldKeyValueOf@'s key shape).
jaFieldKeyOf :: Text -> Maybe Text
jaFieldKeyOf l =
  let (key, rest) = T.span (\c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') l
  in if not (T.null key) && ":" `T.isPrefixOf` rest
       && (let c = T.head key in c >= 'a' && c <= 'z')
       then Just key
       else Nothing

jaIsBlankLine :: Text -> Bool
jaIsBlankLine = T.null . T.strip

-- | A field-block CONTINUATION line: non-blank, indented by >= 2 spaces.
jaIsContinuationLine :: Text -> Bool
jaIsContinuationLine l =
  not (jaIsBlankLine l) && T.length (T.takeWhile (== ' ') l) >= 2

-- | For each 0-based line index inside a FIELD BLOCK, the index of the
-- field line that owns it (itself for a field line). Mirrors
-- "SXC1.Exercise.Reader".@scanFieldBlock@ -- and
-- @emit-content-bundles.py@'s @field_block_map@ -- exactly: a block
-- starts after a structural heading, blank lines are allowed BEFORE it
-- but end it, and @ja:@ lines inside it are transparent (they are
-- field-shaped but own nothing, because the Reader strips them from the
-- stream before its own scan ever runs).
jaFieldOwners :: IntMap.IntMap Text -> Int -> IntMap.IntMap Int
jaFieldOwners lineMap n = IntMap.fromList (outer 0)
  where
    at i = IntMap.findWithDefault "" i lineMap
    outer i
      | i >= n = []
      | Just _ <- jaHeadingLevelOf (at i) =
          let start = skipLead (i + 1)
              (pairs, next) = inner start Nothing
          in pairs ++ outer next
      | otherwise = outer (i + 1)
    skipLead j
      | j < n && (jaIsBlankLine (at j) || isJaLine (at j)) = skipLead (j + 1)
      | otherwise = j
    inner j cur
      | j >= n = ([], j)
      | jaIsBlankLine l = ([], j)
      | isJaLine l = inner (j + 1) cur
      | Just _ <- jaFieldKeyOf l = let (ps, e) = inner (j + 1) (Just j) in ((j, j) : ps, e)
      | jaIsContinuationLine l, Just owner <- cur = let (ps, e) = inner (j + 1) cur in ((j, owner) : ps, e)
      | otherwise = ([], j)
      where l = at j

-- | Every learner-visible unit of one deck source, in source order.
-- @ctx@ carries the most recent structural heading so a prose block can
-- name itself the way EXERCISE-FORMAT.md sec. 12 names it (deck intro /
-- exercise body / @### Why@ block / drill step body).
jaUnitsOf :: [Text] -> [JaUnit]
jaUnitsOf ls = go 0 "deck intro prose"
  where
    n = length ls
    lineMap = IntMap.fromList (zip [0 ..] ls)
    owners = jaFieldOwners lineMap n
    at i = IntMap.findWithDefault "" i lineMap
    go i ctx
      | i >= n = []
      | isJaLine l || jaIsBlankLine l = go (i + 1) ctx
      | Just lvl <- jaHeadingLevelOf l =
          let ctx' = case lvl of
                1 -> "deck intro prose"
                2 -> "exercise body prose"
                _ -> roleProseKind (T.strip (T.drop 4 l))
          in if lvl <= 2
               then JaUnit (if lvl == 1 then "deck title" else "exercise title") l (i + 1) (i + 1)
                      : go (i + 1) ctx'
               -- exclusion 1: the role heading itself is UI-localized.
               else go (i + 1) ctx'
      | jaIsOptionLine l = JaUnit "choice option" l (i + 1) (i + 1) : go (i + 1) ctx
      | Just owner <- IntMap.lookup i owners =
          if owner /= i
            then go (i + 1) ctx  -- a continuation; its field line already emitted the unit
            else
              let lastLine = fieldEnd i i
                  key = maybe "" id (jaFieldKeyOf l)
              in if key `elem` jaTranslatableFieldKeys
                   then JaUnit (key <> ": field") l (i + 1) (lastLine + 1) : go (lastLine + 1) ctx
                   -- exclusion 2: language-invariant field.
                   else go (lastLine + 1) ctx
      | otherwise =
          let end = proseEnd i
          in JaUnit ctx l (i + 1) (end + 1) : go (end + 1) ctx
      where l = at i
    roleProseKind role
      | role == "Step" = "drill step prose"
      | otherwise      = "### " <> role <> " prose"
    -- the last line owned by field line @f@ (itself, or its final
    -- continuation -- the emitter requires the variant to follow THAT).
    fieldEnd f j
      | j + 1 < n, IntMap.lookup (j + 1) owners == Just f = fieldEnd f (j + 1)
      | otherwise = j
    -- one Markdown block: contiguous non-blank, non-variant,
    -- non-heading, non-option lines outside any field block.
    proseEnd j
      | j + 1 < n
      , let k = j + 1
      , not (jaIsBlankLine (at k)), not (isJaLine (at k))
      , jaHeadingLevelOf (at k) == Nothing, not (jaIsOptionLine (at k))
      , IntMap.notMember k owners = proseEnd k
      | otherwise = j

-- | E-JA-MISSING for every learner-visible unit of this deck with no
-- @ja:@ variant directly below it. Reads the RAW source (never the
-- parsed 'Deck'): the variants are deliberately invisible to every
-- structural pass, and the raw text is the only place the contract can
-- be seen.
jaCompletenessIssues :: FilePath -> Text -> [Issue]
jaCompletenessIssues fp raw =
  [ mkIssue E_JA_MISSING (Loc (T.pack fp) (juStart u))
      (juKind u <> " has no ja: variant -- add a \"ja: \" replacement line directly below line "
         <> T.pack (show (juEnd u)) <> " (" <> excerpt (juHead u) <> ")")
  | u <- jaUnitsOf ls
  , not (translated (juEnd u))
  ]
  where
    ls = T.lines raw
    n = length ls
    lineMap = IntMap.fromList (zip [0 ..] ls)
    -- juEnd is 1-based, so the line BELOW it is index juEnd.
    translated e = e < n && isJaLine (IntMap.findWithDefault "" e lineMap)
    excerpt t = let s = T.strip t
                in if T.length s > 60 then T.take 57 s <> "..." else s

--------------------------------------------------------------------------
-- INDEX
--------------------------------------------------------------------------

-- | One filename per (non-comment, non-blank) line, with its 1-based
-- line number preserved.
parseIndexEntries :: Text -> [(Int, Text)]
parseIndexEntries raw =
  [ (ln, s) | (ln, l) <- zip [1 :: Int ..] (T.lines raw), let s = T.strip l, not (T.null s), not ("#" `T.isPrefixOf` s) ]

--------------------------------------------------------------------------
-- Loading a whole content root (default / --json / dir-fixture modes)
--------------------------------------------------------------------------

data Loaded = Loaded
  { ldIssues          :: [Issue]
  , ldDecks           :: [Deck]
  , ldSourceChars     :: [(Text, Int)]
  -- | briefs/M2-signoff-fixes.json, task "quiz-selection-semantics",
  -- FIX 3: the number of successfully-parsed decks for which the four
  -- id-inventory-binding checks in 'resolveDeckIssues' actually fired
  -- (i.e. the run's structural 'bsInventory' scope held -- M5 item 7). This
  -- makes the scope OBSERVABLE -- see 'runJsonMode' and
  -- @scripts/check-site.sh@'s "inventory-binding-scope-fired" check,
  -- which asserts this equals 'ldDecks'' length on the real corpus.
  , ldInventoryChecked :: !Int
  }

-- | Load and validate one whole content root. @scope@ is the structural
-- corpus-wide check scope for every deck in this run -- see 'BindScope',
-- 'inventoryScopedCodes' (M5 debt item 7) and 'jaScopedCodes' (M6 W4):
-- everything binds for the real-corpus modes, per-fixture for dirs\/
-- fixtures, nothing binds for loose files.
collectFromDirs :: BindScope -> FilePath -> FilePath -> IO Loaded
collectFromDirs scope contentDir translationsDir = do
  contentDirExists <- doesDirectoryExist contentDir
  unless contentDirExists $
    () <$ harnessError ("content directory does not exist: " ++ contentDir)
  translationsDirExists <- doesDirectoryExist translationsDir
  unless translationsDirExists $
    () <$ harnessError ("translations directory does not exist: " ++ translationsDir)

  (ctxIssues, ctx) <- loadSharedCtx contentDir translationsDir

  let exercisesDir = contentDir </> "exercises"
      indexPath    = exercisesDir </> "INDEX"
  indexExists <- doesFileExist indexPath
  if not indexExists
    then pure Loaded
           { ldIssues = ctxIssues ++
               [ mkIssue E_INDEX_MISSING (Loc (T.pack indexPath) 1)
                   (T.pack indexPath <> " is missing") ]
           , ldDecks = [], ldSourceChars = [], ldInventoryChecked = 0
           }
    else do
      indexRaw <- readUtf8FileOrHarnessError indexPath
      let indexEntries = parseIndexEntries indexRaw
      exDirExists <- doesDirectoryExist exercisesDir
      onDisk <- if exDirExists then listDirectory exercisesDir else pure []
      let exFilesOnDisk = Set.fromList [ T.pack f | f <- onDisk, ".ex.md" `isSuffixOf` f ]
          indexNamesSet = Set.fromList (map snd indexEntries)
          orphanIssues =
            [ mkIssue E_INDEX_ORPHAN (Loc (T.pack indexPath) 1)
                ("file exists in exercises/ but is not listed in INDEX: " <> f)
            | f <- Set.toList (exFilesOnDisk `Set.difference` indexNamesSet)
            ]
          danglingIssues =
            [ mkIssue E_INDEX_DANGLING (Loc (T.pack indexPath) ln)
                ("INDEX names a file that does not exist: " <> nm)
            | (ln, nm) <- indexEntries, not (nm `Set.member` exFilesOnDisk)
            ]
          existingEntries = [ (ln, nm) | (ln, nm) <- indexEntries, nm `Set.member` exFilesOnDisk ]

      perDeck <- forM existingEntries $ \(_, nm) -> do
        let fp = exercisesDir </> T.unpack nm
        raw <- readUtf8FileOrHarnessError fp
        let (issues, mDeck) = resolveDeckIssues ctx scope fp raw
            -- M6 W2 seam repair: sourceChars reports the EN EMISSION's
            -- length (column-0 ja: variant lines deleted -- the same
            -- rule scripts/emit-content-bundles.py applies), because
            -- that is the text the app actually loads and reports in
            -- #sxc1-exercise-stats; a RAW length went red against the
            -- app the moment W3 landed real ja: lines. T.unlines
            -- round-trips byte-identically here because every source
            -- file ends with a newline (the emitter enforces it).
            enChars = T.length (T.unlines (filter (not . isJaLine) (T.lines raw)))
        pure (nm, issues, mDeck, enChars, bsInventory scope)

      let allIssues  = ctxIssues ++ orphanIssues ++ danglingIssues ++ concat [ i | (_, i, _, _, _) <- perDeck ]
          decks      = mapMaybe (\(_, _, d, _, _) -> d) perDeck
          dupIdIssues = globalIdDuplicateIssues decks
          sourceChars = [ (nm, n) | (nm, _, _, n, _) <- perDeck ]
          -- FIX 3: count only successfully-parsed decks (mDeck == Just)
          -- for which 'resolveDeckIssues' actually applied the four
          -- E-ID-* id-inventory-binding checks (M5 debt item 7: the
          -- per-deck flag is this run's structural 'bsInventory' scope, not
          -- a path-substring probe), not merely attempted them.
          inventoryChecked = length [ () | (_, _, Just _, _, real) <- perDeck, real ]
          -- M3 (briefs/M3-manifest.json, task "size-split-and-format"):
          -- requires: resolution is DIR-class (it needs the whole
          -- corpus) and, like the four id-inventory-binding checks above,
          -- must NEVER apply to plain --fixtures runs -- scoped by the
          -- SAME structural 'bsInventory' signal (every deck loaded in
          -- one 'collectFromDirs' call shares the same content root, so
          -- one per-run flag covers both check families -- exactly the
          -- coupling the old per-path probe emulated).
          requiresIssues = if bsInventory scope then globalRequiresIssues decks else []
      pure Loaded
        { ldIssues = allIssues ++ dupIdIssues ++ requiresIssues, ldDecks = decks, ldSourceChars = sourceChars
        , ldInventoryChecked = inventoryChecked
        }

-- | E-ID-DUPLICATE: the same exercise id used by more than one exercise,
-- OR the same deck slug declared by more than one deck (H4, M2 gate --
-- EXERCISE-FORMAT.md:134 calls a deck slug "globally unique" just as
-- plainly as it does an exercise id, but only the exercise-id half was
-- ever checked; two decks sharing a slug validated clean, the report
-- listed the slug twice, and @#/x/\<slug\>@ resolved to whichever deck
-- happened to load last, silently shadowing the other), anywhere in the
-- loaded content root. One issue per OCCURRENCE of a duplicate (of
-- either kind) -- fixture/report matching is over the SET of codes, so
-- the exact count does not matter, only that the code fires at all.
globalIdDuplicateIssues :: [Deck] -> [Issue]
globalIdDuplicateIssues decks = exerciseIdDupIssues ++ deckSlugDupIssues
  where
    exerciseIdDupIssues =
      [ mkIssue E_ID_DUPLICATE (Loc (unDeckId (dkId d)) 1)
          ("id " <> idTxt <> " is used by more than one exercise (also in deck " <> unDeckId (dkId d) <> ")")
      | d <- decks, e <- dkExercises d
      , let ExId idTxt = exId e
      , Map.findWithDefault 0 idTxt idCounts > 1
      ]
    idCounts :: Map Text Int
    idCounts = Map.fromListWith (+)
      [ (idTxt, 1 :: Int) | d <- decks, e <- dkExercises d, let ExId idTxt = exId e ]

    deckSlugDupIssues =
      [ mkIssue E_ID_DUPLICATE (Loc (unDeckId (dkId d)) 1)
          ("deck slug " <> slugTxt <> " is used by more than one deck")
      | d <- decks
      , let DeckId slugTxt = dkId d
      , Map.findWithDefault 0 slugTxt slugCounts > 1
      ]
    slugCounts :: Map Text Int
    slugCounts = Map.fromListWith (+) [ (slugTxt, 1 :: Int) | d <- decks, let DeckId slugTxt = dkId d ]

-- | M3 (briefs/M3-manifest.json, task "size-split-and-format"):
-- E-DECK-REQUIRES-UNKNOWN (a @requires:@ entry naming a deck slug that
-- does not exist anywhere in the loaded corpus) and E-DECK-REQUIRES-CYCLE
-- (the @requires:@ graph has a cycle -- a deck that, following zero or
-- more @requires:@ edges, requires itself). Both are DIR-class: they need
-- the whole corpus, exactly like 'globalIdDuplicateIssues' above, and the
-- caller ('collectFromDirs') scopes them the same way it scopes the
-- four id-inventory-binding checks -- structurally, per run (M5 item 7;
-- see 'inventoryScopedCodes'), never to plain --fixtures runs.
--
-- One issue per code per deck involved (fixture/report matching is over
-- the SET of codes, so the exact count does not matter, only that the
-- code fires at all for at least one deck -- same rationale as
-- 'globalIdDuplicateIssues').
globalRequiresIssues :: [Deck] -> [Issue]
globalRequiresIssues decks = unknownIssues ++ cycleIssues
  where
    slugSet = Set.fromList [ unDeckId (dkId d) | d <- decks ]
    graph :: Map Text [Text]
    graph = Map.fromList [ (unDeckId (dkId d), dkRequires d) | d <- decks ]

    unknownIssues =
      [ mkIssue E_DECK_REQUIRES_UNKNOWN (Loc (unDeckId (dkId d)) 1)
          ("deck \"" <> unDeckId (dkId d) <> "\" requires unknown deck slug \"" <> r <> "\"")
      | d <- decks, r <- dkRequires d, not (r `Set.member` slugSet)
      ]

    -- 'onCycle n': is @n@ reachable from itself via at least one
    -- 'requires:' edge? (Edges into a slug not present as a deck --
    -- already reported by 'unknownIssues' above -- simply dead-end in
    -- this graph, so they can never contribute to a cycle.)
    onCycle n = n `Set.member` closureOf (Map.findWithDefault [] n graph)
    closureOf = go Set.empty
      where
        go seen [] = seen
        go seen (x : xs)
          | x `Set.member` seen = go seen xs
          | otherwise           = go (Set.insert x seen) (Map.findWithDefault [] x graph ++ xs)

    cycleIssues =
      [ mkIssue E_DECK_REQUIRES_CYCLE (Loc (unDeckId (dkId d)) 1)
          ("deck \"" <> unDeckId (dkId d) <> "\" is part of a requires: cycle")
      | d <- decks, onCycle (unDeckId (dkId d))
      ]

unDeckId :: DeckId -> Text
unDeckId (DeckId t) = t

--------------------------------------------------------------------------
-- Default mode / --json mode
--------------------------------------------------------------------------

-- The real-corpus modes below always bind the inventory checks
-- (structural scope, M5 debt item 7 -- see 'inventoryScopedCodes'):
-- their contract is THE corpus 'fixedInventoryPath' governs, wherever
-- that tree sits on disk.

runDefaultMode :: Opts -> IO ()
runDefaultMode opts = do
  loaded <- collectFromDirs realCorpusScope (optContentDir opts) (optTranslationsDir opts)
  forM_ (sortOn (\i -> (isFile i, isLine i)) (ldIssues loaded)) $ \i ->
    putStrLn (T.unpack (renderIssue i))
  putStrLn ("exercise-check: " ++ show (length (ldIssues loaded)) ++ " issue(s)")
  if null (ldIssues loaded) then exitSuccess else exitWith (ExitFailure 1)

runJsonMode :: Opts -> IO ()
runJsonMode opts = do
  loaded <- collectFromDirs realCorpusScope (optContentDir opts) (optTranslationsDir opts)
  let report = renderReport (null (ldIssues loaded)) (ldDecks loaded) (ldSourceChars loaded) (ldIssues loaded)
  putStrLn (T.unpack (injectInventoryChecked (ldInventoryChecked loaded) report))

-- | Splices @"inventoryChecked":<n>,@ just inside the opening brace of
-- the @"totals"@ object 'SXC1.Exercise.Report.renderReport' already
-- emits, WITHOUT touching that module (owned by another task -- see
-- briefs/M2-signoff-fixes.json, task "quiz-selection-semantics": "Do not
-- ... edit anything else ... unless a compile error forces it"; adding a
-- JSON field is not one). The marker is only @"totals":{@ -- this does
-- NOT assume anything about 'SXC1.Exercise.Report.totalsJson''s own key
-- order, so a future reshuffle of its fields cannot silently break this.
-- A missing marker (the report's shape changed underneath this) leaves
-- the report untouched rather than corrupt it -- 'check-site.sh' then
-- reads a null/absent @inventoryChecked@ and fails loudly instead.
injectInventoryChecked :: Int -> Text -> Text
injectInventoryChecked n report =
  let marker = "\"totals\":{"
      (before, after) = T.breakOn marker report
  in if T.null after
       then report
       else before <> marker <> "\"inventoryChecked\":" <> T.pack (show n) <> "," <> T.drop (T.length marker) after

--------------------------------------------------------------------------
-- --list-codes
--------------------------------------------------------------------------

runListCodes :: Opts -> IO ()
runListCodes opts = do
  rulesRaw <- readUtf8FileOrHarnessError (optContentDir opts </> "terminology-rules.tsv")
  let (_, rules) = parseRules rulesRaw
  mapM_ (putStrLn . T.unpack) (listCodesLines (map ruleId rules))

--------------------------------------------------------------------------
-- --browser-fixture
--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- --bundle-structural-diff: EN vs JA STRUCTURAL IDENTITY (M6 gate round
-- 1, briefs/M6-codex-gate1.json, finding M6-R1-2).
--
-- E-JA-MISSING is a PRESENCE check (a ja: line directly follows the
-- line it translates) and the JA browser pass disables the disk-derived
-- exercise-JSON comparison, so nothing in the M6 suite actually
-- compared the two EMITTED bundles' structure. A ja: prose payload that
-- the Reader reclassifies structurally after substitution (an option
-- line, a field line) could therefore change what a JA learner is asked
-- -- a recall prompt becoming a choice, an option's correctness moving
-- -- with every check green.
--
-- This mode parses BOTH freshly emitted bundles with the SAME
-- SXC1.Exercise.Reader the app links, and requires complete ORDERED
-- structural identity: deck ids in order, exercise ids/order/kind per
-- deck, prompt count and prompt ids per exercise, prompt BODY SHAPE per
-- prompt, and for choice prompts the option count, the positional
-- option ids and exactly which options are correct. Only TEXT may
-- differ -- titles, stems, labels, answers, check sentences are never
-- compared.
--
-- Its own bundle splitter is deliberately a small independent
-- re-implementation of the framing (this binary cannot import
-- exe:app's Bundle module), so an error in the app-side splitter
-- cannot hide here.
--------------------------------------------------------------------------

-- | Split a bundle body into INDEX-ordered @(deck file name, text)@ --
-- the framing only; nothing here knows the app's manifest.
splitBundleDecks :: Text -> Either String [(FilePath, Text)]
splitBundleDecks raw = case T.lines raw of
  [] -> Left "bundle is empty"
  (hdr : rest)
    | not ("!SXC1-BUNDLE v1 " `T.isPrefixOf` hdr) ->
        Left ("bundle does not start with a '!SXC1-BUNDLE v1 <lang> <count>' header: " ++ T.unpack (T.take 60 hdr))
    | otherwise -> go rest
  where
    delim = "!SXC1-DECK "
    go [] = Right []
    go (l : ls) = case T.stripPrefix delim l of
      Nothing -> Left ("expected a '" ++ T.unpack delim ++ "<name>' delimiter, got: " ++ T.unpack (T.take 60 l))
      Just nameTxt ->
        let (body, more) = break (T.isPrefixOf delim) ls
        in ((T.unpack (T.strip nameTxt), T.unlines body) :) <$> go more

-- | The comparable SHAPE of one prompt body: constructor identity plus,
-- for a choice list, the positional option ids and which are correct.
-- Never any learner-visible text.
bodyShapeOf :: PromptBody -> String
bodyShapeOf b = case b of
  Choice opts -> "choice[" ++ concatMap one opts ++ "]"
    where one o = T.unpack (optId o) ++ (if optCorrect o then "+" else "-")
  Recall _    -> "recall"
  Confirm _ v -> "confirm" ++ maybe "" (const "+verify") v
  FindPage c l -> "findpage(" ++ T.unpack (citSlug c) ++ " " ++ show (citPage c)
                    ++ maybe "" ((" limit " ++) . show) l ++ ")"

-- | The whole structural signature of one deck, as comparable lines.
deckSignature :: Deck -> [String]
deckSignature d =
  ("deck " ++ T.unpack (unDeckIdT (dkId d)) ++ " exercises=" ++ show (length (dkExercises d)))
  : concatMap exSignature (dkExercises d)
  where
    exSignature e =
      ("  exercise " ++ T.unpack (unExIdT (exId e))
         ++ " kind=" ++ kindWord (exKind e)
         ++ " prompts=" ++ show (length (exPrompts e))
         ++ " hints=" ++ show (length (exHints e)))
      : [ "    prompt " ++ T.unpack (unPromptIdT (prId p)) ++ " " ++ bodyShapeOf (prBody p)
        | p <- exPrompts e ]
    kindWord KQuiz = "quiz"
    kindWord KDrill = "drill"
    kindWord KLookup = "lookup"
    unDeckIdT (DeckId t) = t
    unExIdT (ExId t) = t
    unPromptIdT (PromptId t) = t

runBundleStructuralDiff :: FilePath -> FilePath -> IO ()
runBundleStructuralDiff enPath jaPath = do
  enRaw <- readUtf8FileOrHarnessError enPath
  jaRaw <- readUtf8FileOrHarnessError jaPath
  case (splitBundleDecks enRaw, splitBundleDecks jaRaw) of
    (Left e, _) -> harnessError (enPath ++ ": " ++ e)
    (_, Left e) -> harnessError (jaPath ++ ": " ++ e)
    (Right enDecks, Right jaDecks) -> do
      let names = ["en/ja deck file names and order are identical"]
          nameOk = map fst enDecks == map fst jaDecks
          problems0
            | nameOk    = []
            | otherwise = ["deck file names/order differ: en=" ++ show (map fst enDecks)
                             ++ " ja=" ++ show (map fst jaDecks)]
          -- Parse EVERY deck of BOTH bundles: an unparsable deck is a
          -- failure here too, never a silent drop.
          parseAll lbl ds = [ case readDeck fp txt of
                                Just d  -> Right (fp, d)
                                Nothing -> Left (lbl ++ " deck '" ++ fp ++ "' does not parse")
                            | (fp, txt) <- ds ]
          enParsed = parseAll "en" enDecks
          jaParsed = parseAll "ja" jaDecks
          parseProblems = [ e | Left e <- enParsed ++ jaParsed ]
          sigProblems =
            [ "deck '" ++ fp ++ "': structural difference at " ++ show (i :: Int)
                ++ ": en=" ++ show a ++ " ja=" ++ show b
            | (Right (fp, dEn), Right (_, dJa)) <- zip enParsed jaParsed
            , (i, a, b) <- firstDiff (deckSignature dEn) (deckSignature dJa)
            ]
          problems = problems0 ++ parseProblems ++ (if null parseProblems then sigProblems else [])
      mapM_ putStrLn [ "ok - " ++ n | n <- names, nameOk ]
      forM_ problems (\p -> putStrLn ("FAIL - " ++ p))
      let deckCount = length enDecks
          passed = (if nameOk then 1 else 0) + (if null problems then deckCount else 0)
          total  = 1 + deckCount
      when (null problems) $
        forM_ enParsed $ \r -> case r of
          Right (fp, _) -> putStrLn ("ok - " ++ fp ++ ": en/ja structurally identical (deck/exercise ids and order, kinds, prompt ids, body shapes, option ids and correctness)")
          Left _        -> pure ()
      putStrLn ("exercise-check --bundle-structural-diff: " ++ show passed ++ "/" ++ show total ++ " checks passed")
      if null problems then exitSuccess else exitFailure

--------------------------------------------------------------------------
-- --manual-structural-diff: EN vs JA STRUCTURAL IDENTITY OF THE MANUAL
-- DOCUMENTS (M7 W3, briefs/M7-plan.md ruling 5).
--
-- Ruling 2 says translations/<slug>.ja.md is PAGE-FOR-PAGE with its EN
-- sibling and carries the same block structure, so the one Blocks
-- renderer renders either language with no per-language branch. The
-- emitter only counts page markers; nothing checked that the two
-- documents PARSE to the same shape. A JA page that turned a
-- *[Figure: ...]* callout into prose, dropped a heading level, split a
-- table, or lost a page section entirely would render as a quietly
-- different document for a Japanese reader, with every other check
-- green -- exactly the class of drift E-JA-MISSING and
-- --bundle-structural-diff closed on the exercise corpus.
--
-- WHY THIS MODE LIVES IN exe:exercise-check AND NOT IN
-- exe:content-check (the manual axis's own checker):
--
--   * It must run the READER'S OWN PARSER, not a re-implementation:
--     'mkDoc' is the exact function View.Pages.mkManuals calls on every
--     fetched document, so the checker and the reader cannot drift.
--     Every checker in this package links it -- that alone does not
--     pick a binary.
--   * exe:exercise-check is the ONLY checker that takes its inputs as
--     PATHS at run time (its module Haddock: "the only module in the
--     project that touches the filesystem"). exe:content-check is
--     TH-embedded BY CONTRACT -- that is precisely what makes
--     `--dump-source` check-site's stale-BUILD detector -- so giving it
--     run-time file inputs would weaken the contract it exists to hold,
--     and every negative control below would need a checker RECOMPILE
--     instead of a scratch file.
--   * exe:exercise-check already owns "EN/JA structural identity over
--     an emitted bundle" ('runBundleStructuralDiff'), including
--     'firstDiff' and the framing splitter idiom. The manual half is
--     the same claim over the other corpus: one binary, one flag
--     idiom, one diff engine, one place a diffing bug can live.
--
-- Like its exercise sibling, the bundle splitter here is a small
-- INDEPENDENT re-implementation of the framing (this binary cannot
-- import exe:app's Bundle module), so a bug in the app-side splitter
-- cannot hide here. The PARSER, by contrast, is deliberately shared --
-- that is the whole point.
--
-- What is compared, per document, per page: the page marker (its
-- number) and the running header's presence, then the block sequence --
-- block type by position, heading LEVEL, figure-callout KIND (hence its
-- position in the sequence), bullet/numbered list item counts and start
-- numbers, blockquote nesting, and table header/row/column shape --
-- recursively into list children and quotes. Only TEXT may differ. A JA
-- page missing while its EN page exists is a hard failure naming the
-- document and the page.
--------------------------------------------------------------------------

-- | Split a manual bundle body into @(slug, declared language, declared
-- page count, text)@ in bundle order -- the framing only; nothing here
-- knows the app's manifest.
splitBundleDocs :: Text -> Either String [(Text, Text, Int, Text)]
splitBundleDocs raw = case T.lines raw of
  [] -> Left "bundle is empty"
  (hdr : rest)
    | not ("!SXC1-BUNDLE v1 " `T.isPrefixOf` hdr) ->
        Left ("bundle does not start with a '!SXC1-BUNDLE v1 <lang> <count>' header: " ++ T.unpack (T.take 60 hdr))
    | otherwise -> go rest
  where
    delim = "!SXC1-DOC "
    go [] = Right []
    go (l : ls) = case T.stripPrefix delim l of
      Nothing -> Left ("expected a '" ++ T.unpack delim ++ "<slug> <lang> <pages>' delimiter, got: "
                         ++ T.unpack (T.take 60 l))
      Just fieldsTxt ->
        let (body, more) = break (T.isPrefixOf delim) ls
        in case T.words fieldsTxt of
             [slug, dl, pagesTxt] | Just p <- readDigits pagesTxt ->
               ((slug, dl, p, T.unlines body) :) <$> go more
             _ -> Left ("malformed '" ++ T.unpack delim ++ "<slug> <lang> <pages>' delimiter: "
                          ++ T.unpack (T.take 60 fieldsTxt))
    readDigits t
      | not (T.null t), T.all (\c -> c >= '0' && c <= '9') t = Just (read (T.unpack t) :: Int)
      | otherwise = Nothing

-- | The comparable SHAPE of one block, as one line per block plus one
-- per nested block, each carrying its POSITION so a divergence names
-- where it is. Never any reader-visible text -- only the structure the
-- Blocks renderer branches on.
manualBlockSig :: String -> Block -> [String]
manualBlockSig pos b = case b of
  Heading lvl _ _   -> [pos ++ ": heading level " ++ show lvl]
  Para _            -> [pos ++ ": paragraph"]
  -- POSITION, not wording: 'Figure''s kind and caption are both
  -- reader-visible TEXT (View.Blocks renders them as one figcaption),
  -- and ruling 3 has the JA callouts DESCRIBING the figure in Japanese
  -- -- guide-book's transcription writes *[写真：...]* where the EN
  -- writes *[Photo: ...]*, which the placeholder grammar (an ASCII ':'
  -- kind separator) reads as an all-kind, no-caption callout. Both are
  -- a Figure block in the same slot, which is exactly what ruling 5
  -- asks this check to hold; comparing the kind string would be
  -- comparing a translation.
  Figure _ _        -> [pos ++ ": figure callout"]
  Bullets items     -> (pos ++ ": bullet list, " ++ show (length items) ++ " item(s)")
                         : itemSigs pos items
  Numbered start is -> (pos ++ ": numbered list from " ++ show start ++ ", " ++ show (length is) ++ " item(s)")
                         : itemSigs pos is
  Quote bs          -> (pos ++ ": blockquote, " ++ show (length bs) ++ " block(s)")
                         : manualBlockSigs (pos ++ ".") bs
  Table mhdr rows   -> [pos ++ ": table, header " ++ maybe "absent" (\h -> show (length h) ++ " cell(s)") mhdr
                          ++ ", " ++ show (length rows) ++ " body row(s), widths "
                          ++ show (map length rows)]
  -- Never legal in either language: the parser's fallback shape is
  -- itself a corpus defect (E-BLOCK-UNPARSED's seam class), and a page
  -- that produced one in BOTH languages would otherwise compare equal.
  Unparsed _        -> [pos ++ ": UNPARSED BLOCK (the parser's fallback -- must never occur)"]
  where
    itemSigs p items = concat
      [ manualBlockSigs (p ++ ".item" ++ show (j :: Int) ++ ".") (liChildren it)
      | (j, it) <- zip [1 ..] items ]

manualBlockSigs :: String -> [Block] -> [String]
manualBlockSigs prefix bs = concat
  [ manualBlockSig (prefix ++ "block " ++ show (i :: Int)) b | (i, b) <- zip [1 ..] bs ]

-- | The whole structural signature of one page.
manualPageSig :: Page -> [String]
manualPageSig pg =
  ("page marker " ++ show (pageNumber pg)
     ++ ", running header " ++ maybe "absent" (const "present") (pageHeader pg))
  : manualBlockSigs "" (pageBlocks pg)

runManualStructuralDiff :: FilePath -> FilePath -> IO ()
runManualStructuralDiff enPath jaPath = do
  enRaw <- readUtf8FileOrHarnessError enPath
  jaRaw <- readUtf8FileOrHarnessError jaPath
  case (splitBundleDocs enRaw, splitBundleDocs jaRaw) of
    (Left e, _) -> harnessError (enPath ++ ": " ++ e)
    (_, Left e) -> harnessError (jaPath ++ ": " ++ e)
    (Right enDocs, Right jaDocs) -> do
      let ident (slug, _, pages, _) = (slug, pages)
          headerName = "en/ja manual document slugs, order and declared page counts are identical ("
                         ++ show (length enDocs) ++ " document(s): "
                         ++ intercalate ", " [ T.unpack s ++ " " ++ show p | (s, p) <- map ident enDocs ]
                         ++ ")"
          headerOk = map ident enDocs == map ident jaDocs
          headerProblems
            | headerOk  = []
            | otherwise = ["manual document slugs/order/page counts differ: en="
                             ++ show (map ident enDocs) ++ " ja=" ++ show (map ident jaDocs)]
          -- Both documents go through the READER'S parser. Pairing is
          -- positional and only meaningful once the header check holds,
          -- which is why a header failure suppresses the page report.
          paired = zip enDocs jaDocs
          docReport ((slug, _, declared, enText), (_, _, _, jaText)) =
            let enPages = docPages (mkDoc slug enText)
                jaPages = docPages (mkDoc slug jaText)
                jaByNum = [ (pageNumber p, p) | p <- jaPages ]
                extraJa = [ pageNumber p | p <- jaPages
                          , pageNumber p `notElem` map pageNumber enPages ]
                -- The reader indexes pages POSITIONALLY, so a declared
                -- count the text does not yield is the same defect
                -- View.Pages.mkManuals rejects at boot; naming it here
                -- keeps a truncated record from reading as "pages
                -- missing from JA" further down.
                countProblems =
                  [ "document '" ++ T.unpack slug ++ "': the en record declares " ++ show declared
                      ++ " page(s) but its text parses to " ++ show (length enPages)
                  | length enPages /= declared ]
                  ++
                  [ "document '" ++ T.unpack slug ++ "': the ja record declares " ++ show declared
                      ++ " page(s) but its text parses to " ++ show (length jaPages)
                  | length jaPages /= declared ]
                  ++
                  [ "document '" ++ T.unpack slug ++ "': ja carries page " ++ show n
                      ++ ", which has no en counterpart"
                  | n <- extraJa ]
                pageResult enPg = case lookup (pageNumber enPg) jaByNum of
                  Nothing ->
                    Left ("document '" ++ T.unpack slug ++ "' page " ++ show (pageNumber enPg)
                            ++ ": MISSING from the ja document (its en page exists)")
                  Just jaPg -> case firstDiff (manualPageSig enPg) (manualPageSig jaPg) of
                    [] -> Right ("ok - " ++ T.unpack slug ++ " page " ++ show (pageNumber enPg)
                                   ++ ": en/ja structurally identical (page marker, block sequence, "
                                   ++ "heading levels, list/table shapes, figure-callout positions)")
                    ((i, a, b) : _) ->
                      Left ("document '" ++ T.unpack slug ++ "' page " ++ show (pageNumber enPg)
                              ++ ": structural difference at position " ++ show i
                              ++ ": en=" ++ show a ++ " ja=" ++ show b)
                results = map pageResult enPages
            in (length enPages, countProblems ++ [ e | Left e <- results ], [ s | Right s <- results ])
          perDoc = map docReport paired
          pageTotal = sum [ n | (n, _, _) <- perDoc ]
          pageProblems = concat [ ps | (_, ps, _) <- perDoc ]
          okLines = concat [ ls | (_, _, ls) <- perDoc ]
          problems = headerProblems ++ (if headerOk then pageProblems else [])
      when headerOk $ putStrLn ("ok - " ++ headerName)
      forM_ problems (\p -> putStrLn ("FAIL - " ++ p))
      when (null problems) (mapM_ putStrLn okLines)
      let passed = (if headerOk then 1 else 0) + (if null problems then pageTotal else 0)
          total  = 1 + (if headerOk then pageTotal else 0)
      putStrLn ("exercise-check --manual-structural-diff: " ++ show passed ++ "/" ++ show total
                  ++ " checks passed")
      if null problems then exitSuccess else exitFailure

-- | The first index at which two signature lists differ (as a
-- singleton list, or empty when identical) -- a differing LENGTH counts
-- as a difference at the first missing position.
firstDiff :: [String] -> [String] -> [(Int, String, String)]
firstDiff xs ys = go 0 xs ys
  where
    go _ []       []       = []
    go i (a : as) (b : bs)
      | a == b    = go (i + 1) as bs
      | otherwise = [(i, a, b)]
    go i as       bs       = [(i, headOr as, headOr bs)]
    headOr (x : _) = x
    headOr []      = "<absent>"

runBrowserFixture :: Opts -> IO ()
runBrowserFixture opts = do
  loaded <- collectFromDirs realCorpusScope (optContentDir opts) (optTranslationsDir opts)
  case (findQuiz loaded, findDrill loaded) of
    (Just qz, Just dr) -> putStrLn (T.unpack (browserFixtureJson qz dr (findLookup loaded)))
    _ -> do
      hPutStrLn stderr "exercise-check --browser-fixture: real content needs at least one quiz and one drill"
      exitWith (ExitFailure 1)

data QuizFixture = QuizFixture { qfDeck, qfId, qfCorrectOpt, qfWrongOpt, qfCiteSlug :: Text, qfCitePage :: Int }
data DrillFixture = DrillFixture
  { dfDeck, dfId :: Text, dfSteps :: Int, dfHasVerify :: Bool
    -- M2 re-gate LOW fix: the first step's declared citation, so the
    -- browser assertion can require the RENDERED href to equal the
    -- DECLARED target rather than merely look like a manual URL.
  , dfCiteSlug :: Text, dfCitePage :: Int
  }
data LookupFixture = LookupFixture
  { lfDeck, lfId :: Text
    -- M2 re-gate LOW fix: slug included alongside the page for the same
    -- declared-vs-rendered equality reason as 'dfCiteSlug'.
  , lfTargetSlug :: Text, lfTargetPage :: Int
  }

findQuiz :: Loaded -> Maybe QuizFixture
findQuiz loaded = firstJust
  [ QuizFixture (unDeckId (dkId d)) i correctId wrongId slug page
  | d <- ldDecks loaded, e <- dkExercises d, exKind e == KQuiz
  , (p : _) <- [exPrompts e]
  , Choice opts' <- [prBody p]
  , (correctId : _) <- [[ optId o | o <- opts', optCorrect o ]]
  , (wrongId : _) <- [[ optId o | o <- opts', not (optCorrect o) ]]
  , (c : _) <- [exCites e]
  , let ExId i = exId e
        slug = citSlug c
        page = citPage c
  ]

findDrill :: Loaded -> Maybe DrillFixture
findDrill loaded = firstJust
  [ DrillFixture (unDeckId (dkId d)) i (length (exPrompts e)) hasV (citSlug c) (citPage c)
  | d <- ldDecks loaded, e <- dkExercises d, exKind e == KDrill
  , (p0 : _) <- [exPrompts e]
  , (c : _) <- [prCites p0]
  , let ExId i = exId e
        hasV = any promptHasVerify (exPrompts e)
        promptHasVerify p = case prBody p of { Confirm _ (Just _) -> True; _ -> False }
  ]

findLookup :: Loaded -> Maybe LookupFixture
findLookup loaded = firstJust
  [ LookupFixture (unDeckId (dkId d)) i (citSlug target) (citPage target)
  | d <- ldDecks loaded, e <- dkExercises d, exKind e == KLookup
  , (p : _) <- [exPrompts e]
  , FindPage target _ <- [prBody p]
  , let ExId i = exId e
  ]

firstJust :: [a] -> Maybe a
firstJust (x : _) = Just x
firstJust []      = Nothing

browserFixtureJson :: QuizFixture -> DrillFixture -> Maybe LookupFixture -> Text
browserFixtureJson qz dr mLk =
  "{" <> T.intercalate ","
    ([ "\"quiz\":" <> obj
        [ kv "deck" (str (qfDeck qz)), kv "id" (str (qfId qz))
        , kv "correctOpt" (str ("opt-" <> qfCorrectOpt qz)), kv "wrongOpt" (str ("opt-" <> qfWrongOpt qz))
        , kv "citeSlug" (str (qfCiteSlug qz)), kv "citePage" (T.pack (show (qfCitePage qz)))
        ]
    , "\"drill\":" <> obj
        [ kv "deck" (str (dfDeck dr)), kv "id" (str (dfId dr))
        , kv "steps" (T.pack (show (dfSteps dr))), kv "hasVerify" (if dfHasVerify dr then "true" else "false")
        , kv "citeSlug" (str (dfCiteSlug dr)), kv "citePage" (T.pack (show (dfCitePage dr)))
        ]
    ] ++ [ "\"lookup\":" <> obj
        [ kv "deck" (str (lfDeck lk)), kv "id" (str (lfId lk))
        , kv "targetSlug" (str (lfTargetSlug lk)), kv "targetPage" (T.pack (show (lfTargetPage lk))) ]
      | lk <- maybeToList mLk
      ]) <> "}"
  where
    obj kvs = "{" <> T.intercalate "," kvs <> "}"
    kv k v = str k <> ":" <> v
    str t = "\"" <> T.concatMap esc t <> "\""
    esc '"' = "\\\""
    esc c   = T.singleton c

--------------------------------------------------------------------------
-- --fixtures DIR
--------------------------------------------------------------------------

data FixtureResult = FixtureResult { frName :: Text, frExpected :: Text, frGot :: [Text], frPass :: Bool }

expectedCodeOf :: Text -> Text
expectedCodeOf nm = fst (T.breakOn "--" nm)

runFixtures :: Opts -> FilePath -> IO ()
runFixtures opts fixturesDir = do
  (ctxIssues, ctx) <- loadSharedCtx (optContentDir opts) (optTranslationsDir opts)
  let filesDir = fixturesDir </> "files"
      dirsDir  = fixturesDir </> "dirs"
  filesDirExists <- doesDirectoryExist filesDir
  fileNames <- if filesDirExists then listDirectory filesDir else pure []
  dirsDirExists <- doesDirectoryExist dirsDir
  dirNames <- if dirsDirExists then listDirectory dirsDir else pure []

  -- Loose files/ fixtures NEVER bind the inventory checks (structural
  -- scope, M5 debt item 7): a single deck file is not a corpus, and no
  -- files/ fixture declares one of the 'inventoryScopedCodes'.
  fileResults <- forM (filter (".ex.md" `isSuffixOf`) fileNames) $ \fn -> do
    raw <- readUtf8FileOrHarnessError (filesDir </> fn)
    let fp = filesDir </> fn
        (issues, _) = resolveDeckIssues ctx looseFileScope fp raw
        nm = T.pack fn
        expected = expectedCodeOf nm
        -- A files/ fixture's own on-disk name is <CODE>--<slug>.ex.md
        -- (content/fixtures/README.md), which is exactly what
        -- 'expectedCodeOf' needs to read the expected code back out of
        -- the filename -- but it can never itself satisfy
        -- 'SXC1.Exercise.Parse.validFileName's real content-file shape
        -- (^[0-9]{2}-[a-z0-9-]+\.ex\.md$) unless <CODE> literally IS
        -- "E-FILE-BAD-NAME": every other real issue code starts with an
        -- uppercase letter (or, for terminology rules, contains a
        -- literal '.'), which validFileName's two-digit prefix can never
        -- match. So E-FILE-BAD-NAME is unconditionally spurious for
        -- every files/ fixture except the one that is deliberately
        -- exercising the naming rule itself; drop it from the comparison
        -- set everywhere else -- symmetric to how the four inventory
        -- checks are already scoped structurally (see
        -- 'inventoryScopedCodes') rather than applied unconditionally.
        -- This only changes what this
        -- --fixtures comparison considers relevant: 'resolveDeckIssues'
        -- and 'validFileName' are untouched, so real content/exercises/
        -- validation (default mode, --json, --browser-fixture) and the
        -- dirs/ branch below (whose inner deck names come from each
        -- fixture's own exercises/INDEX, never from this outer fixture
        -- directory name) are both unaffected.
        codes = map isCode issues
        relevantCodes
          | expected == "E-FILE-BAD-NAME" = codes
          | otherwise                     = filter (/= "E-FILE-BAD-NAME") codes
        got = Set.toList (Set.fromList relevantCodes)
        pass = if expected == "OK" then null got else got == [expected]
    pure FixtureResult { frName = nm, frExpected = expected, frGot = got, frPass = pass }

  dirResults <- forM dirNames $ \dn -> do
    isDir <- doesDirectoryExist (dirsDir </> dn)
    if not isDir then pure Nothing else do
      -- M5 debt item 7: a dirs/ fixture opts into the six
      -- inventory-scoped checks by the code its own name declares
      -- (structural scope -- see 'inventoryScopedCodes'); every other
      -- dirs/ fixture runs with the binding off, exactly as before.
      -- (Until M5 the same opt-in rode on the "--fixture-content" name
      -- suffix satisfying a path-substring probe.) M6 W4 adds the
      -- SECOND, INDEPENDENT family on the same opt-in rule
      -- ('jaScopedCodes' -- E-JA-MISSING), which is why 'fixtureDirScope'
      -- decides the two separately: the eleven pre-M6 dirs/ fixtures
      -- carry no ja: lines and must keep reporting exactly the one code
      -- their own name declares.
      let dirScope = fixtureDirScope (expectedCodeOf (T.pack dn))
      loaded <- collectFromDirs dirScope (dirsDir </> dn) (optTranslationsDir opts)
      let got = Set.toList (Set.fromList (map isCode (ldIssues loaded)))
          nm = T.pack dn
          expected = expectedCodeOf nm
          pass = if expected == "OK" then null got else got == [expected]
      pure (Just FixtureResult { frName = nm, frExpected = expected, frGot = got, frPass = pass })

  let results = fileResults ++ mapMaybe id dirResults
      allPass = all frPass results && null ctxIssues

  if optJson opts
    then putStrLn (T.unpack (fixturesJson results allPass))
    else do
      forM_ results $ \r ->
        putStrLn ((if frPass r then "ok  " else "FAIL ") ++ T.unpack (frName r)
                     ++ ": want=" ++ T.unpack (frExpected r) ++ " got=" ++ show (map T.unpack (frGot r)))
      unless (null ctxIssues) $
        putStrLn ("harness terminology/glossary issues: " ++ show (length ctxIssues))
      putStrLn (show (length (filter frPass results)) ++ "/" ++ show (length results) ++ " fixtures passed")
  if allPass && not (null results) then exitSuccess else exitWith (ExitFailure 1)

fixturesJson :: [FixtureResult] -> Bool -> Text
fixturesJson results ok =
  "{\"fixtures\":[" <> T.intercalate "," (map one results) <> "],\"ok\":" <> (if ok then "true" else "false") <> "}"
  where
    one r = "{\"name\":\"" <> frName r <> "\",\"expected\":\"" <> frExpected r <> "\",\"got\":["
              <> T.intercalate "," (map (\c -> "\"" <> c <> "\"") (frGot r)) <> "],\"pass\":"
              <> (if frPass r then "true" else "false") <> "}"

--------------------------------------------------------------------------
-- main
--------------------------------------------------------------------------

main :: IO ()
main = do
  hSetEncoding stdout utf8
  -- M5 debt item 6: resolve the repo root ONCE, up front -- the CLI
  -- defaults hang off it, so the binary now works from the repo root
  -- exactly as it always has from site/.
  root <- resolveRootPrefix
  args <- getArgs
  case parseArgs root args of
    Left err -> harnessError err
    Right opts
      | optSelfTest opts       -> runSelfTest
      | Just (en, ja) <- optBundleDiff opts -> runBundleStructuralDiff en ja
      | Just (en, ja) <- optManualDiff opts -> runManualStructuralDiff en ja
      | optListCodes opts      -> runListCodes opts
      | Just fdir <- optFixtures opts -> runFixtures opts fdir
      | optBrowserFixture opts -> runBrowserFixture opts
      | optJson opts           -> runJsonMode opts
      | otherwise               -> runDefaultMode opts

--------------------------------------------------------------------------
-- --self-test: inline unit tests. This is the gate: "treat
-- exercise-check --self-test passing as the deliverable, not merely
-- writing the modules."
--
-- M3 (briefs/M3-manifest.json, task "size-split-and-format") amends the
-- long-standing "NO filesystem access" claim above: groups 1-16 are still
-- pure, in-memory checks, but group 17 (the SXC1.Exercise.Reader/
-- SXC1.Exercise.Parse agreement sweep) legitimately reads
-- content/exercises/ and content/fixtures/ off disk -- there is no other
-- way to compare the two parsers over the REAL corpus and fixture set
-- rather than a hand-picked sample -- and group 18's real-corpus half
-- reads content/exercises/INDEX the same way. M4 (briefs/M4-manifest.json,
-- task "midi-spec") adds group 20 to the same amendment: it reads
-- translations/midi.md (to prove SXC1.Midi.Spec.padNoteTable agrees with
-- SXC1.Midi.Table's freshly-parsed copy of the source table) and the
-- three committed deck files carrying the six live verify: hooks.
-- Neither ever degrades to a
-- SILENT pass: an absent directory (M5 debt item 6: the disk groups
-- reach content\/ and translations\/ through 'resolveRootPrefix', so
-- this binary works from the repo root as well as from site\/) still
-- yields a non-empty group with an explicit FAIL naming what was
-- missing, never an empty (vacuously "passing") group -- see
-- 'stGroupsAllOk'\/NEW12.
--------------------------------------------------------------------------

data STCheck = STCheck { stGroup :: !Int, stName :: !String, stOk :: !Bool, stMsg :: !String }

mkST :: Int -> String -> Bool -> String -> STCheck
mkST = STCheck

stLabel :: Int -> String
stLabel 1  = "1. grammar: exact issue-code sets over >=20 embedded .ex.md sources"
stLabel 2  = "2. NEW12-safe runner: groupsOk vacuity guard (permanent negative-control demo)"
stLabel 3  = "3. engine: Choice grading (exact-set) and Toggle selection arity (replace vs. additive)"
stLabel 4  = "4. engine: Recall grading (SelfGrade)"
stLabel 5  = "5. engine: Confirm grading (drill step + device confirm)"
stLabel 6  = "6. engine: FindPage grading (lookup)"
stLabel 7  = "7. engine: wrong-then-right retry path (attempts do not lock the prompt)"
stLabel 8  = "8. engine: hint counting"
stLabel 9  = "9. engine: ProgressEvent fields, incl. exercise-completed on Advance past the end"
stLabel 10 = "10. engine: PromptId stability (<exercise-id>#<step>)"
stLabel 11 = "11. route: constructor assertions for exercise and mastery routes (round-trip alone is vacuous, P-M)"
stLabel 12 = "12. route: totality on malformed inputs"
stLabel 13 = "13. seam: E-BLOCK-UNPARSED via parseBlocksEngineWith (the only way it is reachable)"
stLabel 14 = "14. resolution: resolveCitation/resolveVerify/resolveChapter/resolveInventoryId on synthetic data"
stLabel 15 = "15. clock: Begin/Restart seed esPromptAt from MonoMs (not WallMs); Advance re-baselines it (H1)"
stLabel 16 = "16. route: empty interior/trailing segments and non-[a-z0-9-] ids are RNotFound (L3)"
stLabel 17 = "17. M3: SXC1.Exercise.Reader.readDeck agrees with parseDeck over the real corpus + fixtures"
stLabel 18 = "18. M3: INDEX-driven embedding -- embeddable deck count == non-comment INDEX lines"
stLabel 19 = "19. M3: StaticCode totality sweep (codeText/issueClassOf WHNF non-empty for every allIssueCodes member)"
stLabel 20 = "20. M4: SXC1.Midi.Spec vs translations/midi.md -- decode/match/pads/ports/describe + the six live verify: hooks"
stLabel 21 = "21. M6: `ja:` variant lines -- skipped for EN (byte-identical Deck), invisible to the validator, line numbers preserved"
stLabel 22 = "22. M6 W4: JA completeness (E-JA-MISSING) -- per-unit-kind negative controls, the documented exclusions, and a sweep over the REAL corpus"
stLabel 23 = "23. mastery map: deterministic DAG layout, evidence bands, due-first recommendation, advisory prerequisites"
stLabel 24 = "24. flashcards: every live recall has a bilingual distractor and explicit two-step review grading"
stLabel n  = show n ++ ". ?"

stMaxGroup :: Int
stMaxGroup = 24

stGroupsAllOk :: Int -> [STCheck] -> Bool
stGroupsAllOk maxG cs = all oneGroupOk [1 .. maxG]
  where
    oneGroupOk g = let ig = filter ((== g) . stGroup) cs in not (null ig) && all stOk ig

runSelfTest :: IO ()
runSelfTest = do
  root <- resolveRootPrefix
  agreementChecks  <- readerAgreementChecks root
  indexCountChecks <- indexDrivenEmbeddingChecks root
  midiSpecCks      <- midiSpecChecks root
  jaCompleteCks    <- jaCompletenessCorpusChecks root
  flashcardCks     <- flashcardCorpusChecks root
  let allChecks = concat
        [ grammarChecks, new12GuardSelfChecks, choiceChecks, recallChecks, confirmChecks
        , findPageChecks, retryChecks, hintChecks, progressEventChecks, promptIdChecks
        , routeConstructorChecks, routeTotalityChecks, blockUnparsedSeamChecks, resolutionChecks
        , clockChecks, routeStrictnessChecks
        , agreementChecks, indexCountChecks, staticCodeTotalityChecks
        , midiSpecCks
        , jaVariantChecks
        , jaCompletenessChecks, jaCompleteCks
        , masteryChecks
        , flashcardCks
        ]
  forM_ [1 .. stMaxGroup] $ \g -> do
    let inGroup = filter ((== g) . stGroup) allChecks
        passed  = length (filter stOk inGroup)
        total   = length inGroup
        allOk   = passed == total && total > 0
    putStrLn (stLabel g ++ ": " ++ (if allOk then "ok" else "FAIL") ++ " (" ++ show passed ++ "/" ++ show total ++ ")")
    when (not allOk) $
      forM_ inGroup $ \c ->
        unless (stOk c) $ putStrLn ("    FAIL " ++ stName c ++ ": " ++ stMsg c)
  let totalPassed = length (filter stOk allChecks)
      totalAll    = length allChecks
      groupsOk    = stGroupsAllOk stMaxGroup allChecks
  putStrLn ("exercise-check --self-test: " ++ show totalPassed ++ "/" ++ show totalAll ++ " checks passed")
  if totalPassed == totalAll && totalAll > 0 && groupsOk then exitSuccess else exitFailure

--------------------------------------------------------------------------
-- Group 1: grammar over embedded sources
--------------------------------------------------------------------------

grammarCheck :: String -> FilePath -> Text -> [Text] -> STCheck
grammarCheck name fp src expectedList =
  let (issues, _) = parseDeck fp src
      got = Set.toList (Set.fromList (map isCode issues))
      want = Set.toList (Set.fromList expectedList)
  in mkST 1 name (got == want) ("got=" ++ show (map T.unpack got) ++ " want=" ++ show (map T.unpack want))

validFp :: FilePath
validFp = "content/exercises/00-quiz-test.ex.md"

quizChoiceLines :: [Text]
quizChoiceLines =
  [ "# Choosing a bank"
  , ""
  , "deck: st-pad-play-banks"
  , "chapter: Part: Pad play"
  , "tier: core"
  , "summary: Choose BANK 1 in Performance mode and read the bank indicator."
  , "cite: guide-book 15 \"First, select BANK 1\""
  , ""
  , "Before you start, turn the unit on and let the `SXC-1` logo disappear."
  , ""
  , "## Which button returns you to BANK 1"
  , ""
  , "type: quiz"
  , "id: st-bank-a-button"
  , "cite: guide-book 15 \"press the `A` button\""
  , "tags: banks, performance-mode"
  , ""
  , "The display shows `D:4` and the `D` button is lit. Which single button do you press"
  , "to start selecting BANK 1?"
  , ""
  , "- [x] `A`"
  , "- [ ] `B`"
  , "- [ ] `EDIT`"
  , "- [ ] The up directional button"
  , ""
  , "### Why"
  , ""
  , "Pressing `A` shows `SELECT BANK 1` on the display."
  ]

quizRecallLines :: [Text]
quizRecallLines =
  [ "# Choosing a bank"
  , ""
  , "deck: st-pad-play-banks-2"
  , "chapter: Part: Pad play"
  , "tier: core"
  , "summary: Choose BANK 1 in Performance mode and read the bank indicator."
  , "cite: guide-book 15 \"First, select BANK 1\""
  , ""
  , "## What does the bank indicator show"
  , ""
  , "type: quiz"
  , "id: st-bank-indicator"
  , "cite: guide-book 15 \"First, select BANK 1\""
  , ""
  , "Describe what the bank indicator on the Performance-mode display shows."
  , ""
  , "### Answer"
  , ""
  , "It shows the currently selected bank letter, A through D."
  ]

drillLines :: [Text]
drillLines =
  [ "# Tap the pads"
  , ""
  , "deck: st-pad-play-tap"
  , "chapter: Part: Pad play"
  , "tier: core"
  , "summary: Tap pads and listen to one-shot and looped sounds."
  , "cite: guide-book 17 \"Tap the pads to make sounds\""
  , ""
  , "## Tap the pads and listen"
  , ""
  , "type: drill"
  , "id: st-first-drill"
  , "cite: guide-book 17 \"Tap the pads to make sounds\""
  , ""
  , "Make your first sounds. Later decks assign your own samples to the pads."
  , ""
  , "### Step"
  , ""
  , "cite: guide-book 17 \"Tap the pads to make sounds\""
  , "check: The pad you tapped lights white while the sound plays."
  , "verify: cc 104 127"
  , ""
  , "Tap pad `13` and listen to the drums plus percussion rhythm."
  , ""
  , "### Step"
  , ""
  , "cite: guide-book 17 \"Tap the pads to make sounds\""
  , "check: The pad returns to its original color when the sound finishes."
  , ""
  , "Wait for the one-shot sound to finish."
  ]

lookupLines :: [Text]
lookupLines =
  [ "# Finding Beat Sync"
  , ""
  , "deck: st-leveling-lookup"
  , "chapter: Part: Leveling up"
  , "tier: core"
  , "summary: Find where Beat Sync is documented."
  , "cite: guide-book 55 \"Beat Sync\""
  , ""
  , "## Locate the Beat Sync setting"
  , ""
  , "type: lookup"
  , "find: guide-book 55 \"Beat Sync\""
  , "id: st-find-beat-sync"
  , "limit: 60"
  , ""
  , "Find the system setting that controls tempo-matched playback timing."
  , ""
  , "### Hint"
  , ""
  , "Look in the system settings, reached by long-pressing `EDIT`."
  ]

joinL :: [Text] -> Text
joinL = T.unlines

replaceLine :: Text -> Text -> [Text] -> [Text]
replaceLine old new = map (\l -> if l == old then new else l)

grammarChecks :: [STCheck]
grammarChecks =
  [ grammarCheck "ok/quiz-choice" validFp (joinL quizChoiceLines) []
  , grammarCheck "ok/quiz-recall" validFp (joinL quizRecallLines) []
  , grammarCheck "ok/drill" validFp (joinL drillLines) []
  , grammarCheck "ok/lookup" validFp (joinL lookupLines) []

  , grammarCheck "E-FILE-TITLE/no-title"
      validFp (joinL ("Not a heading at all." : drop 1 quizChoiceLines))
      ["E-FILE-TITLE"]

  , grammarCheck "E-FILE-TITLE/second-hash-heading"
      validFp (joinL (quizChoiceLines ++ ["", "# A second top-level heading"]))
      ["E-FILE-TITLE"]

  , grammarCheck "E-FILE-BAD-NAME/bad-name"
      "content/exercises/bad-name.md" (joinL quizChoiceLines)
      ["E-FILE-BAD-NAME"]

  , grammarCheck "E-DECK-EMPTY/no-exercises"
      -- 9, not 8, since M3 inserted one "tier: core" line into the deck
      -- field block -- this must still capture the WHOLE deck header
      -- (title/blank/deck/chapter/tier/summary/cite/blank/intro-line) and
      -- nothing past it (no "## " heading yet).
      validFp (joinL (take 9 quizChoiceLines))
      ["E-DECK-EMPTY"]

  , grammarCheck "E-FIELD-UNKNOWN/deck-level"
      validFp (joinL (insertAfter "deck: st-pad-play-banks" "frobnicate: yes" quizChoiceLines))
      ["E-FIELD-UNKNOWN"]

  , grammarCheck "E-FIELD-MISSING/deck-summary"
      validFp (joinL (filter (not . ("summary:" `T.isPrefixOf`)) quizChoiceLines))
      ["E-FIELD-MISSING"]

  , grammarCheck "E-FIELD-DUPLICATE/deck-id-twice"
      validFp (joinL (insertAfter "deck: st-pad-play-banks" "deck: st-pad-play-banks-dup" quizChoiceLines))
      ["E-FIELD-DUPLICATE"]

  , grammarCheck "E-FIELD-EMPTY/chapter-empty"
      validFp (joinL (replaceLine "chapter: Part: Pad play" "chapter:" quizChoiceLines))
      ["E-FIELD-EMPTY"]

  , grammarCheck "E-FIELD-SYNTAX/tags-malformed"
      validFp (joinL (replaceLine "tags: banks, performance-mode" "tags: Bad Tag!" quizChoiceLines))
      ["E-FIELD-SYNTAX"]

  , grammarCheck "E-TYPE-UNKNOWN/bogus-type"
      -- An unrecognised type: also means no Exercise could be built at
      -- all for this (this deck's only) "## " chunk, so E-DECK-EMPTY is
      -- a correct, honest cascading consequence, not a double-report of
      -- the same problem under two codes.
      validFp (joinL (replaceLine "type: quiz" "type: essay" quizChoiceLines))
      ["E-TYPE-UNKNOWN", "E-DECK-EMPTY"]

  , grammarCheck "E-ID-SYNTAX/bad-id"
      validFp (joinL (replaceLine "id: st-bank-a-button" "id: Not An Id!" quizChoiceLines))
      ["E-ID-SYNTAX"]

  , grammarCheck "E-CITE-SYNTAX/malformed-page"
      validFp (joinL (replaceLine "cite: guide-book 15 \"press the `A` button\""
                                    "cite: guide-book fifteen \"press the `A` button\"" quizChoiceLines))
      ["E-CITE-SYNTAX"]

  , grammarCheck "E-ROLE-UNKNOWN/bogus-role"
      validFp (joinL (replaceLine "### Why" "### Notes" quizChoiceLines))
      ["E-ROLE-UNKNOWN"]

  , grammarCheck "E-ROLE-MISSING/recall-no-answer"
      validFp (joinL (filter (\l -> l /= "### Answer") quizRecallLines))
      ["E-ROLE-MISSING"]

  , grammarCheck "E-ROLE-REPEATED/why-twice"
      validFp (joinL (quizChoiceLines ++ ["", "### Why", "", "A second Why block."]))
      ["E-ROLE-REPEATED"]

  , grammarCheck "E-CHOICE-COUNT/only-one-option"
      validFp (joinL (filter (`notElem` (["- [ ] `B`", "- [ ] `EDIT`", "- [ ] The up directional button"] :: [Text]))
                             quizChoiceLines))
      ["E-CHOICE-COUNT"]

  , grammarCheck "E-CHOICE-NO-CORRECT/no-x"
      validFp (joinL (replaceLine "- [x] `A`" "- [ ] `A`" quizChoiceLines))
      ["E-CHOICE-NO-CORRECT"]

  , grammarCheck "E-CHOICE-DUPLICATE/dup-label"
      validFp (joinL (replaceLine "- [ ] `B`" "- [ ] `A`" quizChoiceLines))
      ["E-CHOICE-DUPLICATE"]

  , grammarCheck "E-QUIZ-MODE-AMBIGUOUS/both-modes"
      validFp (joinL (quizChoiceLines ++ ["", "### Answer", "", "This should not be here alongside a choice list."]))
      ["E-QUIZ-MODE-AMBIGUOUS"]

  , -- Truncated to a single step whose field block (cite:/check:/verify:)
    -- is also its LAST line -- honestly, that single step has no body
    -- text of its own either, so H5's E-DRILL-STEP-EMPTY is a correct,
    -- cascading second finding here, not a double-report of one problem.
    grammarCheck "E-DRILL-STEP-COUNT/one-step"
      -- 21, not 20 -- see the E-DECK-EMPTY/no-exercises note above; this
      -- must still capture exactly one full Step's field block (cite:/
      -- check:/verify:) and no body text.
      validFp (joinL (take 21 drillLines))
      ["E-DRILL-STEP-COUNT", "E-DRILL-STEP-EMPTY"]

  , grammarCheck "E-DRILL-CHECK-MISSING/step-no-check"
      validFp (joinL (filter (not . ("check: The pad you tapped" `T.isPrefixOf`)) drillLines))
      ["E-DRILL-CHECK-MISSING"]

  , grammarCheck "E-VERIFY-SYNTAX/bogus-verify"
      validFp (joinL (replaceLine "verify: cc 104 127" "verify: bogus thing" drillLines))
      ["E-VERIFY-SYNTAX"]

  , grammarCheck "E-LOOKUP-SPOILER/reveals-page"
      validFp (joinL (replaceLine "Find the system setting that controls tempo-matched playback timing."
                                    "Find the system setting on p. 55 that controls tempo-matched playback timing."
                                    lookupLines))
      ["E-LOOKUP-SPOILER"]

  , grammarCheck "E-BODY-INDENTED-HEADING/indented-hash"
      validFp (joinL (insertAfter "Before you start, turn the unit on and let the `SXC-1` logo disappear."
                                    "   ### This looks like a heading but is indented" quizChoiceLines))
      ["E-BODY-INDENTED-HEADING"]

  , grammarCheck "E-FIELD-UNKNOWN/step-level"
      validFp (joinL (insertAfter "check: The pad you tapped lights white while the sound plays."
                                    "frobnicate: yes" drillLines))
      ["E-FIELD-UNKNOWN"]

  , grammarCheck "E-FIELD-MISSING/lookup-no-find"
      validFp (joinL (filter (not . ("find:" `T.isPrefixOf`)) lookupLines))
      ["E-FIELD-MISSING"]

  -- M3 (briefs/M3-manifest.json, task "size-split-and-format"): tier:/
  -- requires:.
  , grammarCheck "E-DECK-TIER-UNKNOWN/bogus-tier"
      validFp (joinL (replaceLine "tier: core" "tier: bogus" quizChoiceLines))
      ["E-DECK-TIER-UNKNOWN"]

  , grammarCheck "E-FIELD-MISSING/tier-missing"
      validFp (joinL (filter (not . ("tier:" `T.isPrefixOf`)) quizChoiceLines))
      ["E-FIELD-MISSING"]

  , grammarCheck "E-FIELD-SYNTAX/requires-malformed"
      validFp (joinL (insertAfter "tier: core" "requires: Not A Slug!" quizChoiceLines))
      ["E-FIELD-SYNTAX"]

  , grammarCheck "ok/requires-well-formed"
      validFp (joinL (insertAfter "tier: core" "requires: st-pad-play-banks-2, st-pad-play-tap" quizChoiceLines))
      []

  , let (_, mD) = parseDeck validFp
          (joinL (insertAfter "tier: core" "requires: st-pad-play-banks-2, st-pad-play-tap" quizChoiceLines))
    in mkST 1 "tier-requires/carried-on-Deck"
         (case mD of
            Just d  -> dkTier d == "core" && dkRequires d == ["st-pad-play-banks-2", "st-pad-play-tap"]
            Nothing -> False)
         (show (fmap (\d -> (dkTier d, dkRequires d)) mD))
  ]

insertAfter :: Text -> Text -> [Text] -> [Text]
insertAfter anchor new = concatMap (\l -> if l == anchor then [l, new] else [l])

--------------------------------------------------------------------------
-- Group 21 (M6 W1): the bilingual `ja:` variant-line contract
-- (briefs/M6-plan.md, ruling 2 + wave W1). A column-0 line beginning
-- "ja:" is a JAPANESE VARIANT of the learner-visible line(s) directly
-- above it. The STRUCTURAL Reader must skip such lines entirely, so:
--   * the Deck built from a ja:-annotated file is EQUAL to the Deck
--     built from the same file with every ja: line deleted (the EN
--     emission -- byte-identical EN behavior);
--   * the frozen validator (SXC1.Exercise.Parse, which consumes the
--     Reader's DeckSyn and never re-scans raw text) reports ZERO issues
--     for a well-formed ja:-annotated deck -- no E-FIELD-UNKNOWN for a
--     "ja" field key, no E-CHOICE-COUNT from a ja: line splitting a
--     task-list run;
--   * issue LINE NUMBERS still point at the ORIGINAL file's lines (the
--     Reader filters ja: lines out of the numbered stream, it never
--     renumbers what remains);
--   * the raw ja: lines are carried on DeckSyn ('synJaLines', original
--     line number + payload) for wave-3's completeness/terminology
--     validation to consume without re-scanning.
-- Checks 1-4 were demonstrated RED against the pre-M6 Reader (which
-- collected "ja" as a field key and let ja: lines split choice runs)
-- before the Reader change landed -- see the M6 W1 report.
--------------------------------------------------------------------------

-- | Mirrors the Reader's own variant-line rule (column-0 @ja:@ prefix).
isJaVariantLine :: Text -> Bool
isJaVariantLine l = "ja:" `T.isPrefixOf` l

-- | A well-formed two-exercise deck (choice quiz + two-step drill) with
-- a @ja:@ variant attached to EVERY learner-visible line kind the format
-- has: deck title, deck summary, deck intro prose, exercise titles,
-- prompt prose, option lines, a Why block, step check: fields and step
-- body prose. cite:/verify:/type:/id:/deck:/chapter:/tier: carry NO
-- variants -- they are language-invariant by ruling 2.
jaAnnotatedLines :: [Text]
jaAnnotatedLines =
  [ "# Choosing a bank"
  , "ja: # バンクの選択"
  , ""
  , "deck: st-ja-variants"
  , "chapter: Part: Pad play"
  , "tier: core"
  , "summary: Choose BANK 1 in Performance mode and read the bank indicator."
  , "ja: summary: パフォーマンスモードで BANK 1 を選び、バンク表示を読み取る。"
  , "cite: guide-book 15 \"First, select BANK 1\""
  , ""
  , "Before you start, turn the unit on."
  , "ja: 始める前に、本体の電源を入れてください。"
  , ""
  , "## Which button returns you to BANK 1"
  , "ja: ## どのボタンで BANK 1 に戻りますか"
  , ""
  , "type: quiz"
  , "id: st-ja-quiz"
  , "cite: guide-book 15 \"press the `A` button\""
  , ""
  , "Which single button do you press to start selecting BANK 1?"
  , "ja: BANK 1 の選択を始めるには、どのボタンを押しますか。"
  , ""
  , "- [x] `A`"
  , "ja: - [x] `A`"
  , "- [ ] `B`"
  , "ja: - [ ] `B`"
  , ""
  , "### Why"
  , ""
  , "Pressing `A` shows `SELECT BANK 1` on the display."
  , "ja: `A` を押すと `SELECT BANK 1` と表示されます。"
  , ""
  , "## Tap the pads and listen"
  , "ja: ## パッドを叩いて聞く"
  , ""
  , "type: drill"
  , "id: st-ja-drill"
  , "cite: guide-book 17 \"Tap the pads to make sounds\""
  , ""
  , "Tap pads in BANK 1."
  , "ja: BANK 1 のパッドを叩きます。"
  , ""
  , "### Step"
  , ""
  , "cite: guide-book 17 \"Tap the pads to make sounds\""
  , "check: The pad lights white while the sound plays."
  , "ja: check: 音が鳴っている間、パッドが白く光ります。"
  , ""
  , "Tap pad `1`."
  , "ja: パッド `1` を叩きます。"
  , ""
  , "### Step"
  , ""
  , "cite: guide-book 17 \"Tap the pads to make sounds\""
  , "check: The loop repeats until you tap the pad again."
  , "ja: check: もう一度パッドを叩くまでループします。"
  , ""
  , "Tap pad `13`."
  , "ja: パッド `13` を叩きます。"
  ]

-- | The EN emission of 'jaAnnotatedLines': every ja: line deleted,
-- nothing else touched -- exactly what build-site's bundle emitter
-- produces for the EN bundle.
jaStrippedLines :: [Text]
jaStrippedLines = filter (not . isJaVariantLine) jaAnnotatedLines

-- | Line-number preservation fixture: the ONE real issue (a misspelled
-- @summry:@ field) sits on ORIGINAL line 9, below two ja: lines (lines
-- 2 and 8). The validator must report exactly one E-FIELD-UNKNOWN at
-- line 9 -- not a second one for a "ja" field key, and not a shifted
-- line number from a renumbered stream.
jaUnknownFieldLines :: [Text]
jaUnknownFieldLines =
  [ "# Title"                                        -- line 1
  , "ja: # タイトル"                                  -- line 2
  , ""                                               -- line 3
  , "deck: st-ja-lines"                              -- line 4
  , "chapter: Part: Pad play"                        -- line 5
  , "tier: core"                                     -- line 6
  , "summary: A line-number preservation fixture."   -- line 7
  , "ja: summary: 行番号の検査。"                      -- line 8
  , "summry: a misspelled field"                     -- line 9  <- the one real issue
  , "cite: guide-book 15 \"First, select BANK 1\""   -- line 10
  , ""
  , "## One quiz"
  , ""
  , "type: quiz"
  , "id: st-ja-lines-quiz"
  , "cite: guide-book 15 \"press the `A` button\""
  , ""
  , "Which button?"
  , ""
  , "- [x] `A`"
  , "- [ ] `B`"
  ]

jaVariantChecks :: [STCheck]
jaVariantChecks =
  [ let ann = readDeck validFp (joinL jaAnnotatedLines)
        en  = readDeck validFp (joinL jaStrippedLines)
    in mkST 21 "ja/readDeck-equal-to-stripped"
         (ann == en && ann /= Nothing)
         ("annotated parse " ++ (case ann of { Just _ -> "Just"; Nothing -> "Nothing" })
            ++ (if ann == en then " == " else " /= ") ++ "stripped parse")

  , let (issues, _) = parseDeck validFp (joinL jaAnnotatedLines)
    in mkST 21 "ja/parseDeck-zero-issues"
         (null issues)
         ("codes=" ++ show (map (T.unpack . isCode) issues))

  , let optCount = do
          d  <- readDeck validFp (joinL jaAnnotatedLines)
          e0 <- case dkExercises d of { (e : _) -> Just e; [] -> Nothing }
          p0 <- case exPrompts e0 of { (p : _) -> Just p; [] -> Nothing }
          case prBody p0 of { Choice opts -> Just (length opts); _ -> Nothing }
    in mkST 21 "ja/choice-options-preserved"
         (optCount == Just 2)
         ("interleaved ja: lines must not split the task-list run; option count = " ++ show optCount)

  , let (issues, _) = parseDeck validFp (joinL jaUnknownFieldLines)
        got = [ (T.unpack (isCode i), isLine i) | i <- issues ]
    in mkST 21 "ja/issue-lines-point-at-original"
         (got == [("E-FIELD-UNKNOWN", 9)])
         ("want exactly [(\"E-FIELD-UNKNOWN\",9)] (original numbering), got " ++ show got)

  , let syn  = readDeckSyn validFp (joinL jaAnnotatedLines)
        want = [ (i, jaPayload l)
               | (i, l) <- zip [1 :: Int ..] jaAnnotatedLines, isJaVariantLine l ]
        jaPayload l = let rest = T.drop 3 l in maybe rest id (T.stripPrefix " " rest)
    in mkST 21 "ja/synJaLines-captured"
         (synJaLines syn == want)
         ("synJaLines must carry every ja: line as (original line number, payload); got "
            ++ show (length (synJaLines syn)) ++ " of " ++ show (length want))

  , let syn = readDeckSyn validFp (joinL jaAnnotatedLines)
        allFieldLines = synDeckFields syn
          ++ concat [ synExFields e ++ concatMap synStFields (synExSteps e) | e <- synExercises syn ]
        jaKeyed = [ flKey f | f <- allFieldLines, flKey f == "ja" ]
    in mkST 21 "ja/no-ja-fieldline-leaks-to-validator"
         (null jaKeyed)
         ("no FieldLine with key \"ja\" may reach the validator's field blocks; got "
            ++ show (length jaKeyed))
  ]

--------------------------------------------------------------------------
-- Group 22 (M6 W4): JA COMPLETENESS -- 'jaCompletenessIssues' itself.
-- briefs/M6-plan.md ruling 2's enforcement flipped from report-only to
-- HARD at wave 3's completion, so this group has to prove three
-- separate things, none of which the real corpus being green can show
-- on its own:
--
--   (a) a fully-annotated deck reports NOTHING (no false positives --
--       otherwise the hard check would be unshippable);
--   (b) removing the ja: variant of EACH learner-visible unit KIND in
--       turn fires EXACTLY ONE E-JA-MISSING, on the right line, naming
--       the right kind. These nine are the permanent, in-memory half of
--       this deliverable's red-first demonstration (the by-hand half --
--       one ja: line deleted from a scratch COPY of a real deck, run
--       through --content-dir -- is in the M6 W4 report);
--   (c) the DOCUMENTED EXCLUSIONS really are exclusions: the same
--       fully-annotated deck carries no variant for cite:/type:/id:/
--       verify: or any ### role heading and STILL reports nothing, so
--       the exclusion list is a property of this checker rather than a
--       lucky absence of those constructs.
--
-- Plus the sweep over the REAL corpus (one check per INDEX-named deck),
-- which is the milestone claim itself: all 52 shipping decks are
-- completely translated. It reads disk for exactly the reason groups
-- 17/18/20 do (see the runSelfTest Haddock) and never degrades to a
-- vacuous pass: a missing INDEX or a missing deck file is a FAIL that
-- names the path.
--------------------------------------------------------------------------

-- | Drop the FIRST line equal to @target@ (the negative controls'
-- mutation: one ja: line removed, nothing else touched).
jaDropLine :: Text -> [Text] -> [Text]
jaDropLine target ls = case break (== target) ls of
  (before, _ : after) -> before ++ after
  (before, [])        -> before

-- | 1-based line number of the first line equal to @target@ (0 when
-- absent, which makes the expectation unsatisfiable rather than
-- vacuously true).
jaLineNumberOf :: Text -> [Text] -> Int
jaLineNumberOf target ls = case [ i | (i, l) <- zip [1 :: Int ..] ls, l == target ] of
  (i : _) -> i
  []      -> 0

-- | One negative control: delete @jaLine@ from the fully-annotated
-- fixture and require exactly one E-JA-MISSING, anchored on
-- @anchorLine@'s own line number, whose detail starts with @wantKind@.
jaNegativeCase :: String -> Text -> Text -> Text -> STCheck
jaNegativeCase name jaLine anchorLine wantKind =
  let mutated = jaDropLine jaLine jaAnnotatedLines
      issues  = jaCompletenessIssues validFp (joinL mutated)
      wantLn  = jaLineNumberOf anchorLine mutated
      got     = [ (T.unpack (isCode i), isLine i, T.unpack (isDetail i)) | i <- issues ]
      ok = length mutated == length jaAnnotatedLines - 1
             && wantLn > 0
             && case issues of
                  [i] -> isCode i == codeText E_JA_MISSING
                           && isLine i == wantLn
                           && (wantKind <> " has no ja: variant") `T.isPrefixOf` isDetail i
                  _   -> False
  in mkST 22 name ok
       ("want exactly one " ++ T.unpack (codeText E_JA_MISSING) ++ " (" ++ T.unpack wantKind
          ++ ") at line " ++ show wantLn ++ ", got " ++ show got)

jaCompletenessChecks :: [STCheck]
jaCompletenessChecks =
  [ -- (a) no false positives on a completely translated deck.
    let issues = jaCompletenessIssues validFp (joinL jaAnnotatedLines)
    in mkST 22 "ja-complete/fully-annotated-deck-is-silent"
         (null issues)
         ("a deck with a ja: variant on every learner-visible piece must report nothing; got "
            ++ showIssues issues)

    -- (c) the exclusions are structural, not accidental: this same
    -- silent deck deliberately carries NO variant for the
    -- language-invariant fields or the role headings.
  , let noVariantFor p = not (any (T.isPrefixOf p) jaAnnotatedLines)
        excluded = map noVariantFor ["ja: cite:", "ja: type:", "ja: id:", "ja: verify:", "ja: ###"]
    in mkST 22 "ja-complete/documented-exclusions-carry-no-variant"
         (and excluded && null (jaCompletenessIssues validFp (joinL jaAnnotatedLines)))
         ("cite:/type:/id:/verify: and the ### role headings are language-invariant (ruling 2, "
            ++ "EXERCISE-FORMAT.md sec. 12) -- the silent fixture must translate none of them; got "
            ++ show excluded)

    -- The counting mechanism can detect absence at all: an EN-only deck
    -- (every ja: line deleted -- exactly the EN bundle emission) fires
    -- one issue per learner-visible unit, i.e. exactly as many issues as
    -- the annotated deck has variant lines.
  , let issues = jaCompletenessIssues validFp (joinL jaStrippedLines)
        wanted = length (filter isJaVariantLine jaAnnotatedLines)
    in mkST 22 "ja-complete/en-only-deck-fires-once-per-unit"
         (length issues == wanted && wanted > 0
            && all ((== codeText E_JA_MISSING) . isCode) issues)
         ("an untranslated deck must fire one E-JA-MISSING per learner-visible unit: want "
            ++ show wanted ++ ", got " ++ show (length issues))
  ]
  -- (b) one negative control per learner-visible unit KIND -- the
  -- complete list from content/EXERCISE-FORMAT.md sec. 12's table.
  ++ [ jaNegativeCase "ja-complete/missing-deck-title"
         "ja: # バンクの選択" "# Choosing a bank" "deck title"
     , jaNegativeCase "ja-complete/missing-deck-summary"
         "ja: summary: パフォーマンスモードで BANK 1 を選び、バンク表示を読み取る。"
         "summary: Choose BANK 1 in Performance mode and read the bank indicator." "summary: field"
     , jaNegativeCase "ja-complete/missing-deck-intro-prose"
         "ja: 始める前に、本体の電源を入れてください。"
         "Before you start, turn the unit on." "deck intro prose"
     , jaNegativeCase "ja-complete/missing-exercise-title"
         "ja: ## どのボタンで BANK 1 に戻りますか"
         "## Which button returns you to BANK 1" "exercise title"
     , jaNegativeCase "ja-complete/missing-body-prose"
         "ja: BANK 1 の選択を始めるには、どのボタンを押しますか。"
         "Which single button do you press to start selecting BANK 1?" "exercise body prose"
     , jaNegativeCase "ja-complete/missing-choice-option"
         "ja: - [ ] `B`" "- [ ] `B`" "choice option"
     , jaNegativeCase "ja-complete/missing-why-prose"
         "ja: `A` を押すと `SELECT BANK 1` と表示されます。"
         "Pressing `A` shows `SELECT BANK 1` on the display." "### Why prose"
     , jaNegativeCase "ja-complete/missing-step-check"
         "ja: check: 音が鳴っている間、パッドが白く光ります。"
         "check: The pad lights white while the sound plays." "check: field"
     , jaNegativeCase "ja-complete/missing-step-prose"
         "ja: パッド `1` を叩きます。" "Tap pad `1`." "drill step prose"
     ]

-- | The milestone claim, swept over the REAL corpus: every deck
-- @content\/exercises\/INDEX@ ships is completely translated. One check
-- per deck so a failure names the file (group 17's pattern).
jaCompletenessCorpusChecks :: FilePath -> IO [STCheck]
jaCompletenessCorpusChecks root = do
  let exercisesDir = root </> "content" </> "exercises"
      indexPath    = exercisesDir </> "INDEX"
  indexExists <- doesFileExist indexPath
  if not indexExists
    then pure [ mkST 22 "ja-complete/corpus-not-found" False
                  (indexPath ++ " does not exist -- the JA-completeness sweep had nothing to check") ]
    else do
      raw <- readUtf8File indexPath
      let names = map snd (parseIndexEntries raw)
      if null names
        then pure [ mkST 22 "ja-complete/corpus-not-found" False
                      (indexPath ++ " names no deck files -- the JA-completeness sweep had nothing to check") ]
        else forM names $ \nm -> do
          let fp = exercisesDir </> T.unpack nm
          fileExists <- doesFileExist fp
          if not fileExists
            then pure (mkST 22 ("ja-complete/" ++ fp) False
                         (fp ++ " is named by INDEX but does not exist on disk"))
            else do
              deckRaw <- readUtf8File fp
              let issues = jaCompletenessIssues fp deckRaw
              pure (mkST 22 ("ja-complete/" ++ fp) (null issues)
                      (show (length issues) ++ " learner-visible piece(s) with no ja: variant; first: "
                         ++ (case issues of { (i : _) -> T.unpack (renderIssue i); [] -> "<none>" })))

--------------------------------------------------------------------------
-- Group 24: the M11 flashcard migration and review-grade seam.
--------------------------------------------------------------------------

flashcardCorpusChecks :: FilePath -> IO [STCheck]
flashcardCorpusChecks root = do
  let exercisesDir = root </> "content" </> "exercises"
      indexPath = exercisesDir </> "INDEX"
  indexExists <- doesFileExist indexPath
  if not indexExists
    then pure [mkST 24 "flashcards/corpus-not-found" False (indexPath ++ " does not exist")]
    else do
      indexRaw <- readUtf8File indexPath
      loaded <- forM (map snd (parseIndexEntries indexRaw)) $ \name -> do
        let fp = exercisesDir </> T.unpack name
        exists <- doesFileExist fp
        if not exists then pure (Left fp) else do
          raw <- readUtf8File fp
          pure (Right (readDeckSyn fp raw, raw))
      let missing = [fp | Left fp <- loaded]
          syns = [syn | Right (syn, _) <- loaded]
          raws = [raw | Right (_, raw) <- loaded]
          exSyns = concatMap synExercises syns
          decks = mapMaybe synDeck syns
          flashOptions = [opts | exS <- exSyns, Just (Choice opts) <- [synExFlashPrompt exS]]
          liveRecalls =
            [ unExIdLocal (exId ex)
            | deck <- decks, ex <- dkExercises deck, prompt <- exPrompts ex
            , Recall _ <- [prBody prompt]
            ]
          correctSides =
            [optId opt | opts <- flashOptions, opt <- opts, optCorrect opt]
          authoredEn = sum (map (T.count "\ndistractor:") raws)
          authoredJa = sum (map (T.count "\nja: distractor:") raws)
          binaryOneCorrect opts = length opts == 2 && length (filter optCorrect opts) == 1
      pure
        ([ mkST 24 "flashcards/all-index-files-loaded" (null missing)
            ("missing INDEX files: " ++ show missing)
        , mkST 24 "flashcards/128-bilingual-authored-distractors"
            (authoredEn == 128 && authoredJa == 128)
            ("EN=" ++ show authoredEn ++ " JA=" ++ show authoredJa ++ ", want 128 each")
        , mkST 24 "flashcards/128-binary-one-correct-prompts"
            (length flashOptions == 128 && all binaryOneCorrect flashOptions)
            ("generated=" ++ show (length flashOptions) ++ ", malformed="
              ++ show (length (filter (not . binaryOneCorrect) flashOptions)))
        , mkST 24 "flashcards/live-corpus-has-no-self-certified-recall"
            (null liveRecalls)
            ("Recall prompts survived in: " ++ show liveRecalls)
        , mkST 24 "flashcards/correct-side-varies-stably"
            (Set.fromList correctSides == Set.fromList ["a", "b"])
            ("correct option ids=" ++ show correctSides)
        ] ++ explicitReviewGradeChecks)
  where
    unExIdLocal (ExId t) = t

explicitReviewGradeChecks :: [STCheck]
explicitReviewGradeChecks =
  let st0 = initialState (ExId "st-single-choice-ex") (MonoMs 1000)
      (st1, _) = step singleChoiceExercise (Toggle 0 "a") st0
      (st2, checkEvents) = step singleChoiceExercise (Check 0 False) st1
      (st3, rateEvents) = step singleChoiceExercise
        (Rate 0 ReviewGood (MonoMs 1800) (WallMs 86400000)) st2
      (_, duplicateEvents) = step singleChoiceExercise
        (Rate 0 ReviewEasy (MonoMs 1900) (WallMs 86400100)) st3
      (unsureState, unsureEvents) = step singleChoiceExercise (Check 0 True) st0
      (_, hardEvents) = step singleChoiceExercise
        (Rate 0 ReviewHard (MonoMs 1600) (WallMs 86400000)) unsureState
  in
  [ mkST 24 "review/check-evaluates-without-persisting"
      (null checkEvents && IntMap.lookup 0 (esEvaluated st2) == Just Correct)
      ("events=" ++ show checkEvents ++ " evaluated=" ++ show (esEvaluated st2))
  , mkST 24 "review/good-is-carried-verbatim"
      (case rateEvents of { [ev] -> peOutcome ev == Correct && peReview ev == Just ReviewGood; _ -> False })
      (show rateEvents)
  , mkST 24 "review/rating-is-idempotent"
      (null duplicateEvents) (show duplicateEvents)
  , mkST 24 "review/not-sure-branches-to-hard"
      (null unsureEvents && IntMap.lookup 0 (esEvaluated unsureState) == Just Incorrect
        && case hardEvents of { [ev] -> peReview ev == Just ReviewHard; _ -> False })
      ("check=" ++ show unsureEvents ++ " rate=" ++ show hardEvents)
  ]

--------------------------------------------------------------------------
-- Group 2: NEW12-safe runner demonstration (mirrors CheckContent.hs's
-- group-16/group-22 pattern: a permanent, self-verifying comparison of
-- the OLD (insufficient) exit condition against 'stGroupsAllOk').
--------------------------------------------------------------------------

new12AdversarialChecklist :: [STCheck]
new12AdversarialChecklist = [mkST 1 "a" True "", mkST 3 "c" True ""]  -- group 2 entirely absent

new12GuardSelfChecks :: [STCheck]
new12GuardSelfChecks =
  [ mkST 2 "new12/missing-group-is-not-ok"
      (stGroupsAllOk 3 new12AdversarialChecklist == False)
      "a checklist that never mentions group 2 must make stGroupsAllOk report False"
  , mkST 2 "new12/old-condition-would-have-missed-it"
      (let tp = length (filter stOk new12AdversarialChecklist)
           ta = length new12AdversarialChecklist
       in tp == ta && ta > 0)
      "the pre-NEW12-style exit condition reads True on the same adversarial checklist -- this is the bug"
  , mkST 2 "new12/fully-passing-is-ok"
      (stGroupsAllOk 3 [mkST 1 "a" True "", mkST 2 "b" True "", mkST 3 "c" True ""] == True)
      "three non-empty, fully-passing groups must read True"
  ]

--------------------------------------------------------------------------
-- Hand-built exercises for the engine checks (groups 3-10)
--------------------------------------------------------------------------

mkOpt :: Text -> Bool -> Option
mkOpt i correct = Option i [] correct

choiceExercise :: Exercise
choiceExercise = Exercise
  { exId = ExId "st-choice-ex", exDeck = DeckId "st-deck", exKind = KQuiz, exTitle = "Choice test"
  , exCites = [], exTags = [], exIntro = []
  , exPrompts = [ Prompt (promptIdFor (ExId "st-choice-ex") 1) [] []
                    (Choice [mkOpt "a" True, mkOpt "b" False, mkOpt "c" True]) ]
  , exNote = [], exHints = []
  }

-- | Single-correct (exactly one 'optCorrect'): mirrors the real q-1-03
-- shape the M2 designer hand-drove at sign-off (four options, one
-- correct) -- see briefs/M2-signoff-fixes.json, task
-- "quiz-selection-semantics", FIX 1.
singleChoiceExercise :: Exercise
singleChoiceExercise = Exercise
  { exId = ExId "st-single-choice-ex", exDeck = DeckId "st-deck", exKind = KQuiz, exTitle = "Single choice test"
  , exCites = [], exTags = [], exIntro = []
  , exPrompts = [ Prompt (promptIdFor (ExId "st-single-choice-ex") 1) [] []
                    (Choice [mkOpt "a" True, mkOpt "b" False, mkOpt "c" False, mkOpt "d" False]) ]
  , exNote = [], exHints = []
  }

-- | Multi-correct (exactly two 'optCorrect'): distinct from
-- 'choiceExercise' (whose correct set is {a,c}, not contiguous) so a
-- "select both correct options" case can submit the EXACT correct set
-- and a "select only one" case can submit a genuine STRICT SUBSET of it.
multiChoiceExercise :: Exercise
multiChoiceExercise = Exercise
  { exId = ExId "st-multi-choice-ex", exDeck = DeckId "st-deck", exKind = KQuiz, exTitle = "Multi choice test"
  , exCites = [], exTags = [], exIntro = []
  , exPrompts = [ Prompt (promptIdFor (ExId "st-multi-choice-ex") 1) [] []
                    (Choice [mkOpt "a" True, mkOpt "b" True, mkOpt "c" False]) ]
  , exNote = [], exHints = []
  }

recallExercise :: Exercise
recallExercise = Exercise
  { exId = ExId "st-recall-ex", exDeck = DeckId "st-deck", exKind = KQuiz, exTitle = "Recall test"
  , exCites = [], exTags = [], exIntro = []
  , exPrompts = [ Prompt (promptIdFor (ExId "st-recall-ex") 1) [] [] (Recall []) ]
  , exNote = [], exHints = []
  }

drillExercise :: Exercise
drillExercise = Exercise
  { exId = ExId "st-drill-ex", exDeck = DeckId "st-deck", exKind = KDrill, exTitle = "Drill test"
  , exCites = [], exTags = [], exIntro = []
  , exPrompts =
      [ Prompt (promptIdFor (ExId "st-drill-ex") 1) [] [] (Confirm [] Nothing)
      , Prompt (promptIdFor (ExId "st-drill-ex") 2) [] [] (Confirm [] (Just (VerifyCC 104 [127])))
      ]
  , exNote = [], exHints = []
  }

lookupExercise :: Exercise
lookupExercise = Exercise
  { exId = ExId "st-lookup-ex", exDeck = DeckId "st-deck", exKind = KLookup, exTitle = "Lookup test"
  , exCites = [], exTags = [], exIntro = []
  , exPrompts = [ Prompt (promptIdFor (ExId "st-lookup-ex") 1) [] []
                    (FindPage (Citation "guide-book" 55 "Beat Sync") (Just 60)) ]
  , exNote = [], exHints = []
  }

choiceChecks :: [STCheck]
choiceChecks =
  let st0 = initialState (ExId "st-choice-ex") (MonoMs 1000)
      (st1, ev1) = step choiceExercise (Toggle 0 "a") st0
      (st2, ev2) = step choiceExercise (Toggle 0 "c") st1
      (st3, ev3) = step choiceExercise (Submit 0 (MonoMs 1500) (WallMs 1000)) st2
  in
  [ mkST 3 "choice/toggle-emits-no-event" (null ev1 && null ev2) ("ev1=" ++ show ev1 ++ " ev2=" ++ show ev2)
  , mkST 3 "choice/exact-set-match-is-correct"
      (case ev3 of { [e] -> peOutcome e == Correct; _ -> False }) ("ev3=" ++ show ev3)
  , mkST 3 "choice/response-recorded"
      (case IntMap.lookup 0 (esResponses st3) of { Just (RChosen sel) -> sortT sel == ["a", "c"]; _ -> False })
      (show (esResponses st3))
  , mkST 3 "choice/wrong-set-is-incorrect"
      (let (_, ev) = step choiceExercise (Submit 0 (MonoMs 1500) (WallMs 1000)) (fst (step choiceExercise (Toggle 0 "b") st0))
       in case ev of { [e] -> peOutcome e == Incorrect; _ -> False })
      "selecting only b (missing a,c and including a non-correct option) must grade Incorrect"
  ] ++ singleAnswerReplaceChecks ++ multiSelectAdditiveChecks

-- | briefs/M2-signoff-fixes.json, task "quiz-selection-semantics", FIX 1:
-- these two cases PIN the learner path the M2 designer hand-drove at
-- sign-off and would FAIL against the pre-fix engine (whose 'Toggle' was
-- unconditionally additive): clicking a wrong option then the single
-- correct one must leave ONLY the correct one selected (never both), and
-- re-clicking an already-selected option must still clear it.
singleAnswerReplaceChecks :: [STCheck]
singleAnswerReplaceChecks =
  let st0 = initialState (ExId "st-single-choice-ex") (MonoMs 1000)
      -- wrong (b) then right (a), NO deselect in between -- the ordinary
      -- learner path this whole fix exists for.
      (st1, _)   = step singleChoiceExercise (Toggle 0 "b") st0
      (st2, _)   = step singleChoiceExercise (Toggle 0 "a") st1
      (_, ev3)   = step singleChoiceExercise (Submit 0 (MonoMs 1500) (WallMs 1000)) st2
      -- re-clicking the already-selected option clears it.
      (st1r, _)  = step singleChoiceExercise (Toggle 0 "a") st0
      (st2r, _)  = step singleChoiceExercise (Toggle 0 "a") st1r
  in
  [ mkST 3 "choice-arity/single-answer-toggle-replaces-not-adds"
      (case IntMap.lookup 0 (esResponses st2) of { Just (RChosen sel) -> sel == ["a"]; _ -> False })
      ("wrong-then-right must leave selection exactly [a], got " ++ show (IntMap.lookup 0 (esResponses st2)))
  , mkST 3 "choice-arity/single-answer-wrong-then-right-grades-correct"
      (case ev3 of { [e] -> peOutcome e == Correct; _ -> False })
      ("clicking the correct option after a wrong one must grade Correct, got " ++ show ev3)
  , mkST 3 "choice-arity/single-answer-re-click-still-clears"
      (case IntMap.lookup 0 (esResponses st2r) of { Just (RChosen sel) -> null sel; _ -> False })
      ("re-clicking the selected option must clear it, got " ++ show (IntMap.lookup 0 (esResponses st2r)))
  ]

-- | briefs/M2-signoff-fixes.json, task "quiz-selection-semantics", FIX 1:
-- a prompt with two or more correct options must keep today's additive
-- Toggle behaviour -- the grading rule (exact-set equality) is otherwise
-- unchanged, so both the exact correct set and a strict subset of it are
-- exercised here.
multiSelectAdditiveChecks :: [STCheck]
multiSelectAdditiveChecks =
  let st0 = initialState (ExId "st-multi-choice-ex") (MonoMs 1000)
      (st1, _)  = step multiChoiceExercise (Toggle 0 "a") st0
      (st2, _)  = step multiChoiceExercise (Toggle 0 "b") st1
      (_, evEx) = step multiChoiceExercise (Submit 0 (MonoMs 1500) (WallMs 1000)) st2
      (st1s, _) = step multiChoiceExercise (Toggle 0 "a") st0
      (_, evSs) = step multiChoiceExercise (Submit 0 (MonoMs 1500) (WallMs 1000)) st1s
  in
  [ mkST 3 "choice-arity/multi-select-toggle-stays-additive"
      (case IntMap.lookup 0 (esResponses st2) of { Just (RChosen sel) -> sortT sel == ["a", "b"]; _ -> False })
      ("toggling a then b on a multi-correct prompt must select both, got " ++ show (IntMap.lookup 0 (esResponses st2)))
  , mkST 3 "choice-arity/multi-select-exact-correct-set-is-correct"
      (case evEx of { [e] -> peOutcome e == Correct; _ -> False })
      ("selecting exactly the correct set {a,b} must grade Correct, got " ++ show evEx)
  , mkST 3 "choice-arity/multi-select-strict-subset-is-incorrect"
      (case evSs of { [e] -> peOutcome e == Incorrect; _ -> False })
      ("selecting only {a}, a strict subset of the correct set {a,b}, must grade Incorrect, got " ++ show evSs)
  ]

recallChecks :: [STCheck]
recallChecks =
  let st0 = initialState (ExId "st-recall-ex") (MonoMs 1000)
      (st1, ev1) = step recallExercise (Reveal 0) st0
      (_, ev2) = step recallExercise (SelfGrade_ 0 Got (MonoMs 1500) (WallMs 2000)) st1
  in
  [ mkST 4 "recall/reveal-emits-no-event-but-marks-revealed" (null ev1 && IntSet.member 0 (esRevealed st1)) (show ev1)
  , mkST 4 "recall/self-grade-got-is-correct-and-revealed"
      (case ev2 of { [e] -> peOutcome e == Correct && peRevealed e; _ -> False }) (show ev2)
  , mkST 4 "recall/self-grade-missed-is-incorrect"
      (let (_, ev) = step recallExercise (SelfGrade_ 0 Missed (MonoMs 1500) (WallMs 2000)) st1
       in case ev of { [e] -> peOutcome e == Incorrect && peRevealed e; _ -> False })
      "Missed after showing the model answer must grade Incorrect and retain revealed=true"
  ]

confirmChecks :: [STCheck]
confirmChecks =
  let st0 = initialState (ExId "st-drill-ex") (MonoMs 1000)
      (st1, ev1) = step drillExercise (ConfirmStep 0 ByLearner (MonoMs 1200) (WallMs 2000)) st0
      (_, ev2) = step drillExercise (ConfirmStep 1 ByDevice (MonoMs 1400) (WallMs 2200)) st1
  in
  [ mkST 5 "confirm/by-learner-is-correct"
      (case ev1 of { [e] -> peOutcome e == Correct; _ -> False }) (show ev1)
  , mkST 5 "confirm/records-confirm-source"
      (case IntMap.lookup 0 (esResponses st1) of { Just (RConfirmed ByLearner) -> True; _ -> False })
      (show (esResponses st1))
  , mkST 5 "confirm/by-device-also-correct"
      (case ev2 of { [e] -> peOutcome e == Correct; _ -> False }) (show ev2)
  ]

findPageChecks :: [STCheck]
findPageChecks =
  let st0 = initialState (ExId "st-lookup-ex") (MonoMs 1000)
      (st1, _) = step lookupExercise (EnterPage 0 55) st0
      (_, ev2) = step lookupExercise (SubmitPage 0 (MonoMs 1500) (WallMs 2000)) st1
      (st1w, _) = step lookupExercise (EnterPage 0 12) st0
      (_, evw) = step lookupExercise (SubmitPage 0 (MonoMs 1500) (WallMs 2000)) st1w
  in
  [ mkST 6 "findpage/correct-page-is-correct"
      (case ev2 of { [e] -> peOutcome e == Correct; _ -> False }) (show ev2)
  , mkST 6 "findpage/wrong-page-is-incorrect"
      (case evw of { [e] -> peOutcome e == Incorrect; _ -> False }) (show evw)
  , mkST 6 "findpage/unanswered-submit-is-incorrect"
      (case step lookupExercise (SubmitPage 0 (MonoMs 1500) (WallMs 2000)) st0 of { (_, [e]) -> peOutcome e == Incorrect; _ -> False })
      "submitting with no EnterPage first must not crash and must grade Incorrect"
  ]

--------------------------------------------------------------------------
-- Group 7: wrong-then-right retry path + attempt counting
--------------------------------------------------------------------------

retryChecks :: [STCheck]
retryChecks =
  let st0 = initialState (ExId "st-choice-ex") (MonoMs 1000)
      (st1, _)   = step choiceExercise (Toggle 0 "b") st0                  -- wrong selection
      (st2, ev2) = step choiceExercise (Submit 0 (MonoMs 1200) (WallMs 1000)) st1            -- attempt 1: wrong
      (st3, _)   = step choiceExercise (Toggle 0 "b") st2                  -- learner retries: deselect b
      (st4, _)   = step choiceExercise (Toggle 0 "a") st3
      (st5, _)   = step choiceExercise (Toggle 0 "c") st4
      (st6, ev6) = step choiceExercise (Submit 0 (MonoMs 1800) (WallMs 1600))                -- attempt 2: right
                     st5
  in
  [ mkST 7 "retry/first-attempt-incorrect-does-not-lock"
      (case ev2 of { [e] -> peOutcome e == Incorrect && peAttempt e == 1; _ -> False }) (show ev2)
  , mkST 7 "retry/not-done-after-wrong-answer" (not (esDone st2)) "esDone must stay False after an incorrect Submit"
  , mkST 7 "retry/second-attempt-correct-with-attempt-number-2"
      (case ev6 of { [e] -> peOutcome e == Correct && peAttempt e == 2; _ -> False }) (show ev6)
  , mkST 7 "retry/attempts-counter-is-2"
      (IntMap.lookup 0 (esAttempts st6) == Just 2) (show (esAttempts st6))
  ]

--------------------------------------------------------------------------
-- Group 8: hint counting
--------------------------------------------------------------------------

hintChecks :: [STCheck]
hintChecks =
  let st0 = initialState (ExId "st-choice-ex") (MonoMs 1000)
      (st1, ev1) = step choiceExercise (ShowHint 0) st0
      (st2, ev2) = step choiceExercise (ShowHint 0) st1
      (st3, _)   = step choiceExercise (Toggle 0 "a") st2
      (st4, _)   = step choiceExercise (Toggle 0 "c") st3
      (_, ev5)   = step choiceExercise (Submit 0 (MonoMs 2000) (WallMs 2000)) st4
  in
  [ mkST 8 "hints/shown-emits-no-event" (null ev1 && null ev2) (show (ev1, ev2))
  , mkST 8 "hints/counter-is-2" (IntMap.lookup 0 (esHints st2) == Just 2) (show (esHints st2))
  , mkST 8 "hints/count-carried-into-grading-event"
      (case ev5 of { [e] -> peHints e == 2; _ -> False }) (show ev5)
  ]

--------------------------------------------------------------------------
-- Group 9: ProgressEvent fields, incl. exercise-completed
--------------------------------------------------------------------------

progressEventChecks :: [STCheck]
progressEventChecks =
  let st0 = initialState (ExId "st-drill-ex") (MonoMs 5000)
      (st1, _)  = step drillExercise (ConfirmStep 0 ByLearner (MonoMs 5200) (WallMs 6000)) st0
      (st2, ev2) = step drillExercise (Advance (MonoMs 6100) (WallMs 6100)) st1                  -- 1 of 2 prompts done -> not complete
      (st3, _)  = step drillExercise (ConfirmStep 1 ByLearner (MonoMs 6300) (WallMs 6400)) st2
      (st4, ev4) = step drillExercise (Advance (MonoMs 6500) (WallMs 6500)) st3                  -- 2 of 2 -> exercise-completed
  in
  [ mkST 9 "progress/deck-and-exercise-fields"
      (case ev4 of
         (e : _) -> peDeck e == DeckId "st-deck" && peExercise e == ExId "st-drill-ex"
         _       -> False)
      (show ev4)
  , mkST 9 "progress/advance-mid-exercise-does-not-complete" (not (esDone st2)) (show (esDone st2))
  , mkST 9 "progress/advance-past-an-already-answered-prompt-emits-no-skip" (null ev2) (show ev2)
  , mkST 9 "progress/advance-past-last-prompt-completes" (esDone st4) (show (esDone st4))
  , mkST 9 "progress/completed-event-present-with-no-prompt"
      (any (\e -> peOutcome e == Completed && pePrompt e == Nothing) ev4) (show ev4)
  , mkST 9 "progress/wall-clock-carried-through" (any (\e -> peAt e == 6500) ev4) (show ev4)
  ]

--------------------------------------------------------------------------
-- Group 10: PromptId stability
--------------------------------------------------------------------------

promptIdChecks :: [STCheck]
promptIdChecks =
  [ mkST 10 "promptid/format" (promptIdFor (ExId "q-2-03") 1 == PromptId "q-2-03#1") "promptIdFor must be <id>#<step>"
  , mkST 10 "promptid/second-step" (promptIdFor (ExId "q-2-03") 2 == PromptId "q-2-03#2") "step index must vary"
  , mkST 10 "promptid/stable-across-unrelated-exercise"
      (promptIdFor (ExId "d-1-05") 1 /= promptIdFor (ExId "q-2-03") 1) "different exercise ids must not collide"
  , mkST 10 "promptid/drill-steps-numbered-in-source-order"
      (case map prId (exPrompts drillExercise) of
         [PromptId a, PromptId b] -> a == "st-drill-ex#1" && b == "st-drill-ex#2"
         _                        -> False)
      (show (map prId (exPrompts drillExercise)))
  ]

--------------------------------------------------------------------------
-- Group 11-12: routes
--------------------------------------------------------------------------

routeConstructorChecks :: [STCheck]
routeConstructorChecks =
  [ mkST 11 "route/x-is-RExercises" (parseRoute "#/x" == RExercises) (show (parseRoute "#/x"))
  , mkST 11 "route/x-today-is-RSession" (parseRoute "#/x/today" == RSession) (show (parseRoute "#/x/today"))
  , mkST 11 "route/x-is-not-RNotFound"
      -- P-M: "#/x" already round-tripped as RNotFound BEFORE these routes
      -- existed, so a bare round-trip assertion is vacuous. This is the
      -- explicit negative control the manifest requires.
      (case parseRoute "#/x" of { RNotFound _ -> False; _ -> True }) (show (parseRoute "#/x"))
  , mkST 11 "route/x-deck-is-RDeck" (parseRoute "#/x/pad-play-banks" == RDeck "pad-play-banks")
      (show (parseRoute "#/x/pad-play-banks"))
  , mkST 11 "route/x-deck-is-not-RNotFound"
      (case parseRoute "#/x/pad-play-banks" of { RNotFound _ -> False; _ -> True })
      (show (parseRoute "#/x/pad-play-banks"))
  , mkST 11 "route/x-deck-ex-is-RExercise"
      (parseRoute "#/x/pad-play-banks/pad-play-bank-a-button"
         == RExercise "pad-play-banks" "pad-play-bank-a-button")
      (show (parseRoute "#/x/pad-play-banks/pad-play-bank-a-button"))
  , mkST 11 "route/x-deck-ex-is-not-RNotFound"
      (case parseRoute "#/x/pad-play-banks/pad-play-bank-a-button" of { RNotFound _ -> False; _ -> True })
      (show (parseRoute "#/x/pad-play-banks/pad-play-bank-a-button"))
  , mkST 11 "route/round-trip-RExercises" (parseRoute (renderRoute RExercises) == RExercises) "round-trip"
  , mkST 11 "route/round-trip-RSession" (parseRoute (renderRoute RSession) == RSession) "round-trip"
  , mkST 11 "route/x-map-is-RMastery" (parseRoute "#/x/map" == RMastery) (show (parseRoute "#/x/map"))
  , mkST 11 "route/x-map-is-not-RDeck" (parseRoute "#/x/map" /= RDeck "map") (show (parseRoute "#/x/map"))
  , mkST 11 "route/round-trip-RMastery" (parseRoute (renderRoute RMastery) == RMastery) "round-trip"
  , mkST 11 "route/x-week-is-RWeekly" (parseRoute "#/x/week" == RWeekly) (show (parseRoute "#/x/week"))
  , mkST 11 "route/x-week-is-not-RDeck" (parseRoute "#/x/week" /= RDeck "week") (show (parseRoute "#/x/week"))
  , mkST 11 "route/round-trip-RWeekly" (parseRoute (renderRoute RWeekly) == RWeekly) "round-trip"
  , mkST 11 "route/round-trip-RDeck" (parseRoute (renderRoute (RDeck "d")) == RDeck "d") "round-trip"
  , mkST 11 "route/round-trip-RExercise"
      (parseRoute (renderRoute (RExercise "d" "e")) == RExercise "d" "e") "round-trip"
  ]

routeTotalityChecks :: [STCheck]
routeTotalityChecks =
  [ mkST 12 ("route-total/" ++ show (T.unpack input))
      (lengthForced (show (parseRoute input)) >= 0)
      ("ok, parsed to " ++ show (parseRoute input))
  | input <- ["", "#", "#/x/", "#/x//y", "#/x/a/b/c"]
  ]
  where lengthForced s = length s `seq` length s

--------------------------------------------------------------------------
-- Group 23: mastery graph. The visual layer consumes only this projection,
-- so these checks pin the meaning of every color and recommendation.
--------------------------------------------------------------------------

masteryChecks :: [STCheck]
masteryChecks =
  [ mkST 23 "mastery/prompt-bands"
      ( [ promptBand Nothing
        , promptBand (Just (masteryRec 0 0 100))
        , promptBand (Just (masteryRec 1 7 100))
        , promptBand (Just (masteryRec 3 7 100))
        ] == [PUnseen, PFragile, PBuilding, PDurable] )
      "missing, lapsed, single-rep, and mature prompts must classify distinctly"
  , mkST 23 "mastery/authored-edge"
      (mgEdges emptyGraph == [GraphEdge "map-a" "map-b"])
      (show (mgEdges emptyGraph))
  , mkST 23 "mastery/topological-depth"
      (map gnDepth (mgNodes emptyGraph) == [0, 1])
      (show (map gnDepth (mgNodes emptyGraph)))
  , mkST 23 "mastery/empty-is-unseen"
      (map (dmBand . gnMastery) (mgNodes emptyGraph) == [MUnseen, MUnseen])
      (show (map (dmBand . gnMastery) (mgNodes emptyGraph)))
  , mkST 23 "mastery/recommend-first-incomplete"
      (mgRecommended strongGraph == Just "map-b")
      (show (mgRecommended strongGraph))
  , mkST 23 "mastery/strong-requires-completion-and-durable-recall"
      (nodeBand "map-a" strongGraph == Just MStrong)
      (show (nodeBand "map-a" strongGraph))
  , mkST 23 "mastery/due-is-consolidating-and-recommended-first"
      (nodeBand "map-a" dueGraph == Just MConsolidating && mgRecommended dueGraph == Just "map-a")
      (show (nodeBand "map-a" dueGraph, mgRecommended dueGraph))
  , mkST 23 "mastery/prerequisites-are-advisory"
      (case findMastery "map-b" emptyGraph of
         Just dm -> not (dmPrereqsMet dm)
         Nothing -> False)
      "dependent node must remain present while its advisory prerequisite is incomplete"
  , mkST 23 "mastery/layout-stable-across-progress"
      (map coords (mgNodes emptyGraph) == map coords (mgNodes dueGraph))
      "progress may recolor the graph but must never move its authored nodes"
  , mkST 23 "mastery/band-count-ledger"
      (bandCount MConsolidating dueGraph == 1 && bandCount MUnseen dueGraph == 1)
      (show (Map.toList (mgBandCounts dueGraph)))
  ]
  where
    today = DayNum 100
    emptyGraph = buildMasteryGraph today emptyProgress masteryDecks
    strongGraph = buildMasteryGraph today strongProgress masteryDecks
    dueGraph = buildMasteryGraph today dueProgress masteryDecks
    coords n = (gnX n, gnY n)

masteryDecks :: [Deck]
masteryDecks =
  [ masteryDeck "map-a" "Map A" "Chapter A" [] "map-a-ex" "map-a-ex#1"
  , masteryDeck "map-b" "Map B" "Chapter B" ["map-a"] "map-b-ex" "map-b-ex#1"
  ]

masteryDeck :: Text -> Text -> Text -> [Text] -> Text -> Text -> Deck
masteryDeck did title chapter requires eid pid = Deck
  { dkId = DeckId did, dkTitle = title, dkChapter = chapter
  , dkSummary = [], dkCites = [], dkIntro = [], dkTags = []
  , dkTier = "core", dkRequires = requires
  , dkExercises =
      [ choiceExercise
          { exId = ExId eid
          , exDeck = DeckId did
          , exTitle = title
          , exPrompts = [ Prompt (PromptId pid) [] [] (Recall []) ]
          }
      ]
  }

masteryRec :: Int -> Int -> Int -> Rec
masteryRec reps interval due = Rec
  { rcReps = reps, rcLapses = 0, rcEase = 2500, rcInterval = interval
  , rcDue = DayNum due, rcLastSeen = DayNum 90, rcSeen = max 1 reps
  }

strongProgress :: ProgressState
strongProgress = emptyProgress
  { psDone = Map.fromList [("map-a-ex", 1)]
  , psRecs = Map.fromList [("map-a-ex#1", masteryRec 3 7 110)]
  }

dueProgress :: ProgressState
dueProgress = strongProgress
  { psRecs = Map.fromList [("map-a-ex#1", masteryRec 3 7 100)] }

findMastery :: Text -> MasteryGraph -> Maybe DeckMastery
findMastery slug graph =
  case [ gnMastery n | n <- mgNodes graph, dkId (gnDeck n) == DeckId slug ] of
    (dm : _) -> Just dm
    []       -> Nothing

nodeBand :: Text -> MasteryGraph -> Maybe MasteryBand
nodeBand slug = fmap dmBand . findMastery slug

--------------------------------------------------------------------------
-- Group 13: E-BLOCK-UNPARSED, via the parseBlocksEngineWith test seam --
-- the only way it is reachable at all (see SXC1.Content.Markdown and
-- SXC1.Exercise.Parse's Haddock on this).
--------------------------------------------------------------------------

blockUnparsedSeamChecks :: [STCheck]
blockUnparsedSeamChecks =
  let poisonLine = "an ordinary line the self-test's classifier declines to classify"
      decliningClassifier l = if l == poisonLine then DeclinedShape else classifyLine l
      (synthBlocks, _) = parseBlocksEngineWith decliningClassifier 1 False []
                            ["An ordinary paragraph before it.", poisonLine, "An ordinary paragraph after it."]
      issues = unparsedBlockIssues "seam-test" (Loc "seam-test" 1) synthBlocks
  in
  [ mkST 13 "seam/synthetic-Unparsed-block-produced"
      (case synthBlocks of { [Para _, Unparsed t, Para _] -> t == poisonLine; _ -> False })
      (show (length synthBlocks))
  , mkST 13 "seam/unparsedBlockIssues-reports-E-BLOCK-UNPARSED"
      (case issues of { [i] -> isCode i == "E-BLOCK-UNPARSED"; _ -> False })
      (show (map isCode issues))
  , mkST 13 "seam/real-classifyLine-never-declines-this-line"
      (classifyLine poisonLine /= DeclinedShape) (show (classifyLine poisonLine))
  , mkST 13 "seam/real-parseDeck-never-produces-E-BLOCK-UNPARSED"
      -- Belt-and-suspenders over the SAME valid fixtures used in group 1:
      -- the real classifier can never reach 'Unparsed', so none of them
      -- should ever carry this code.
      (all (\src -> "E-BLOCK-UNPARSED" `notElem` map isCode (fst (parseDeck validFp src)))
         [joinL quizChoiceLines, joinL quizRecallLines, joinL drillLines, joinL lookupLines])
      "no real fixture may ever produce E-BLOCK-UNPARSED"
  ]

--------------------------------------------------------------------------
-- Group 14: resolution functions, exercised directly on synthetic data
-- (no filesystem -- ManualIndex/MidiFacts/chapter vocab are ordinary
-- pure values here, not read from disk).
--------------------------------------------------------------------------

resolutionChecks :: [STCheck]
resolutionChecks =
  let idx = buildManualIndex [("guide-book", T.unlines ["<!-- page 1 -->", "Intro text.", "<!-- page 2 -->", "The bank indicator shows BANK 1 clearly on this page."])]
      loc = Loc "synthetic" 1
      okCite = Citation "guide-book" 2 "The bank indicator shows BANK 1"
      badSlug = Citation "guidebook" 2 "The bank indicator shows BANK 1"
      badPage = Citation "guide-book" 99 "The bank indicator shows BANK 1"
      badAnchor = Citation "guide-book" 2 "This text is nowhere on the page"
      shortAnchor = Citation "guide-book" 2 "short"

      midi = buildMidiFacts (T.unlines
        [ "## 4. Control Change list"
        , "| Function | | CC No. | Transmit | Receive | Remarks |"
        , "|---|---|---|---|---|---|"
        , "| SLIDE BAR | INPUT VOL | 11 | 0-127 | 0-127 | x |"
        , "## 5. Note mapping"
        , "| Pad | Bank A | Bank B |"
        , "|---|---|---|"
        , "| Pad 1 | 36 | 52 |"
        , "| Pad 2 | 37 | 53 |"
        ])

      chapterVocab = Map.fromList [(0, "Front matter"), (2, "Part: Pad play")]
      invRaw = T.unlines
        [ "- **q-2-03** (intro) Some flashcard."
        , "- **q-1-14** (retired) Tombstone."
        ]
  in
  [ mkST 14 "resolve-citation/ok" (null (resolveCitation idx loc okCite)) (showIssues (resolveCitation idx loc okCite))
  , mkST 14 "resolve-citation/bad-slug"
      (map isCode (resolveCitation idx loc badSlug) == ["E-CITE-SLUG"]) (showIssues (resolveCitation idx loc badSlug))
  , mkST 14 "resolve-citation/bad-page"
      (map isCode (resolveCitation idx loc badPage) == ["E-CITE-PAGE"]) (showIssues (resolveCitation idx loc badPage))
  , mkST 14 "resolve-citation/bad-anchor"
      (map isCode (resolveCitation idx loc badAnchor) == ["E-CITE-ANCHOR"]) (showIssues (resolveCitation idx loc badAnchor))
  , mkST 14 "resolve-citation/short-anchor"
      (map isCode (resolveCitation idx loc shortAnchor) == ["E-CITE-ANCHOR"]) "anchors under 12 chars must fail"

  , mkST 14 "resolve-verify/known-cc" (null (resolveVerify midi loc (VerifyCC 11 [0]))) "CC 11 is in the table"
  , mkST 14 "resolve-verify/unknown-cc"
      (map isCode (resolveVerify midi loc (VerifyCC 999 [0])) == ["E-VERIFY-CC-UNKNOWN"]) "CC 999 is not in the table"
  , mkST 14 "resolve-verify/note-in-range" (null (resolveVerify midi loc (VerifyNote [40]))) "40 is within 36..53"
  , mkST 14 "resolve-verify/note-out-of-range"
      (map isCode (resolveVerify midi loc (VerifyNote [200])) == ["E-VERIFY-NOTE-RANGE"]) "200 must be out of range"
  , mkST 14 "resolve-verify/known-pad-bank" (null (resolveVerify midi loc (VerifyPad 1 'A'))) "pad 1 bank A exists"
  , mkST 14 "resolve-verify/unknown-pad-bank"
      (map isCode (resolveVerify midi loc (VerifyPad 1 'D')) == ["E-VERIFY-CC-UNKNOWN"]) "bank D is not in this table"
  , mkST 14 "resolve-verify/any-always-ok" (null (resolveVerify midi loc VerifyAny)) "VerifyAny must never fail"

  , mkST 14 "resolve-chapter/ok" (null (resolveChapter chapterVocab loc "Part: Pad play")) "known chapter"
  , mkST 14 "resolve-chapter/unknown"
      (map isCode (resolveChapter chapterVocab loc "Pad Play") == ["E-CHAPTER-UNKNOWN"]) "must not fuzzy-match"

  , mkST 14 "resolve-inventory-id/ok"
      (null (resolveInventoryId invRaw chapterVocab loc (ExId "q-2-03") KQuiz "Part: Pad play")) "known, non-retired, matching id"
  , mkST 14 "resolve-inventory-id/not-in-inventory"
      (map isCode (resolveInventoryId invRaw chapterVocab loc (ExId "q-9-99") KQuiz "Part: Pad play")
         == ["E-ID-NOT-IN-INVENTORY"]) "q-9-99 is not in the synthetic inventory"
  , mkST 14 "resolve-inventory-id/retired"
      (map isCode (resolveInventoryId invRaw chapterVocab loc (ExId "q-1-14") KQuiz "Front matter")
         == ["E-ID-RETIRED"]) "q-1-14 is tagged (retired)"
  , mkST 14 "resolve-inventory-id/type-mismatch"
      (map isCode (resolveInventoryId invRaw chapterVocab loc (ExId "q-2-03") KDrill "Part: Pad play")
         == ["E-ID-TYPE-MISMATCH"]) "q-2-03 starts with q but type: is drill"
  , mkST 14 "resolve-inventory-id/chapter-mismatch"
      (map isCode (resolveInventoryId invRaw chapterVocab loc (ExId "q-2-03") KQuiz "Front matter")
         == ["E-ID-CHAPTER-MISMATCH"]) "q-2-03's chapter digit 2 is Part: Pad play, not Front matter"
  , mkST 14 "resolve-inventory-id/parseIdShape"
      (parseIdShape "q-2-03" == Just ('q', 2) && parseIdShape "not-shaped" == Nothing)
      (show (parseIdShape "q-2-03", parseIdShape "not-shaped"))
  ]

--------------------------------------------------------------------------
-- Group 15: the clock seam (H1, M2 gate). A deliberately DIVERGENT-epoch
-- probe -- mono around 5,000, wall around 1,786,100,000,000 -- exactly
-- like the gate's own reproduction. Demonstrated failing against the
-- pre-fix engine (Begin/Restart seeded esPromptAt from the WALL epoch,
-- Advance never touched esPromptAt at all) before this fix landed; see
-- this task's final report for both outputs.
--------------------------------------------------------------------------

clockChecks :: [STCheck]
clockChecks =
  let mono0 = MonoMs 5000
      wall0 = WallMs 1786100000000
      st0   = fst (step choiceExercise (Begin mono0 wall0) (initialState (ExId "unused") (MonoMs 0)))
      st1   = fst (step choiceExercise (Toggle 0 "a") st0)
      st2   = fst (step choiceExercise (Toggle 0 "c") st1)
      (_, ev3) = step choiceExercise (Submit 0 (MonoMs 13400) wall0) st2 -- mono0 + 8400

      monoR = MonoMs 90000
      wallR = WallMs 1786200000000
      stR0  = fst (step choiceExercise (Restart monoR wallR) st2)
      stR1  = fst (step choiceExercise (Toggle 0 "a") stR0)
      stR2  = fst (step choiceExercise (Toggle 0 "c") stR1)
      (_, evR3) = step choiceExercise (Submit 0 (MonoMs 105000) wallR) stR2 -- monoR + 15000

      stC0 = initialState (ExId "st-drill-ex") (MonoMs 500)
      (stC1, _) = step drillExercise (ConfirmStep 0 ByLearner (MonoMs 1000) (WallMs 1000)) stC0
      (stC2, _) = step drillExercise (Advance (MonoMs 9000) (WallMs 9000)) stC1
      (_, evC3) = step drillExercise (ConfirmStep 1 ByLearner (MonoMs 9700) (WallMs 9700)) stC2 -- 9000 + 700
  in
  [ mkST 15 "clock/begin-seeds-esPromptAt-from-monotonic-not-wall"
      (case ev3 of { [e] -> peElapsed e == 8400; _ -> False })
      ("first graded prompt after Begin must read peElapsed==8400 (mono-based), got " ++ show ev3)
  , mkST 15 "clock/restart-rebaselines-esPromptAt-from-monotonic"
      (case evR3 of { [e] -> peElapsed e == 15000; _ -> False })
      ("first graded prompt after Restart must read peElapsed==15000 (mono-based), got " ++ show evR3)
  , mkST 15 "clock/advance-rebaselines-esPromptAt-for-the-next-prompt"
      (case evC3 of { [e] -> peElapsed e == 700; _ -> False })
      ("second drill step must read peElapsed==700 (timed from Advance, not the first step's submit), got " ++ show evC3)
  ]

--------------------------------------------------------------------------
-- Group 16: route strictness (L3, M2 gate) -- empty interior/trailing
-- segments and non-[a-z0-9-] route ids must all classify as 'RNotFound',
-- alongside the existing constructor/round-trip assertions (groups 11-12).
--------------------------------------------------------------------------

routeStrictnessChecks :: [STCheck]
routeStrictnessChecks =
  [ mkST 16 ("route-strict/" ++ T.unpack input ++ "-is-not-found")
      (case parseRoute input of { RNotFound _ -> True; _ -> False })
      ("expected RNotFound, got " ++ show (parseRoute input))
  | input <- ["#/x//a/b", "#/x/a//b", "#/x/A B/c"]
  ]

--------------------------------------------------------------------------
-- Group 17: SXC1.Exercise.Reader.readDeck / SXC1.Exercise.Parse.parseDeck
-- agreement, over EVERY real corpus file and EVERY fixture file (M3,
-- briefs/M3-manifest.json, task "size-split-and-format", deliverable
-- (1d)). One 'STCheck' per file, so a failure names the exact file --
-- see the module Haddock above for why this group legitimately touches
-- disk.
--------------------------------------------------------------------------

exMdFilesIn :: FilePath -> IO [FilePath]
exMdFilesIn dir = do
  exists <- doesDirectoryExist dir
  if not exists then pure [] else do
    names <- listDirectory dir
    pure [ dir </> n | n <- names, ".ex.md" `isSuffixOf` n ]

safeListDirectory :: FilePath -> IO [FilePath]
safeListDirectory dir = do
  exists <- doesDirectoryExist dir
  if exists then listDirectory dir else pure []

readerAgreementChecks :: FilePath -> IO [STCheck]
readerAgreementChecks root = do
  let exercisesDir     = root </> "content" </> "exercises"
      fixturesFilesDir = root </> "content" </> "fixtures" </> "files"
      fixturesDirsDir  = root </> "content" </> "fixtures" </> "dirs"
  exFiles     <- exMdFilesIn exercisesDir
  fxFileFiles <- exMdFilesIn fixturesFilesDir
  dirNames    <- safeListDirectory fixturesDirsDir
  fxDirFiles  <- fmap concat $ forM dirNames $ \dn ->
    exMdFilesIn (fixturesDirsDir </> dn </> "exercises")
  let allFiles = exFiles ++ fxFileFiles ++ fxDirFiles
  if null allFiles
    then pure [ mkST 17 "agreement/corpus-not-found" False
                  ("none of " ++ exercisesDir ++ ", " ++ fixturesFilesDir ++ ", " ++ fixturesDirsDir
                     ++ " contained any .ex.md file -- cannot run the agreement sweep") ]
    else forM allFiles $ \fp -> do
      raw <- readUtf8File fp
      let agree = readDeck fp raw == snd (parseDeck fp raw)
      pure (mkST 17 ("agreement/" ++ fp) agree
              ("SXC1.Exercise.Reader.readDeck fp raw /= snd (SXC1.Exercise.Parse.parseDeck fp raw) for " ++ fp))

--------------------------------------------------------------------------
-- Group 18: INDEX-driven embedding -- the number of decks the app will
-- embed (every INDEX-named, on-disk, readDeck-parseable file) must equal
-- the number of non-comment INDEX lines (M3, deliverable (2)).
--------------------------------------------------------------------------

indexDrivenEmbeddingChecks :: FilePath -> IO [STCheck]
indexDrivenEmbeddingChecks root = do
  let indexPath    = root </> "content" </> "exercises" </> "INDEX"
      exercisesDir = root </> "content" </> "exercises"
  indexExists <- doesFileExist indexPath
  realCheck <-
    if not indexExists
      then pure [ mkST 18 "index-count/real-corpus" False (indexPath ++ " does not exist") ]
      else do
        raw <- readUtf8File indexPath
        let names = map snd (parseIndexEntries raw)
        mDecks <- forM names $ \nm -> do
          let fp = exercisesDir </> T.unpack nm
          fileExists <- doesFileExist fp
          if not fileExists then pure Nothing else do
            rawDeck <- readUtf8File fp
            pure (readDeck fp rawDeck)
        let nIndex      = length names
            nEmbeddable = length (mapMaybe id mDecks)
        pure [ mkST 18 "index-count/real-corpus" (nIndex == nEmbeddable)
                 ("INDEX (" ++ indexPath ++ ") has " ++ show nIndex
                    ++ " non-comment line(s) but only " ++ show nEmbeddable
                    ++ " named file(s) exist on disk and parse via readDeck") ]
  -- Permanent negative-control demo (mirrors 'new12GuardSelfChecks''s
  -- pattern): a synthetic 2-entry INDEX where only 1 entry's file
  -- actually exists must NOT compare equal -- proving the counting
  -- mechanism can detect a mismatch at all, independent of whatever the
  -- REAL corpus happens to look like today. This is the permanent
  -- in-memory half of the "add a line to a scratch copy of INDEX naming
  -- a file that does not exist" negative control this task's final
  -- report also demonstrates by hand against a real scratch INDEX.
  let syntheticIndexText = "a.ex.md\n# a comment, ignored\nb.ex.md\n"
      syntheticNames     = map snd (parseIndexEntries syntheticIndexText)
      syntheticFound     = Map.fromList [("a.ex.md", True)]  -- "b.ex.md" deliberately absent
      syntheticEmbeddable = length [ () | nm <- syntheticNames, Map.member nm syntheticFound ]
      syntheticCheck = mkST 18 "index-count/synthetic-mismatch-is-detected"
        (length syntheticNames /= syntheticEmbeddable)
        ("a synthetic 2-entry INDEX with only 1 matching file must not compare equal to its embeddable count, got names="
           ++ show (length syntheticNames) ++ " embeddable=" ++ show syntheticEmbeddable)
  pure (realCheck ++ [syntheticCheck])

--------------------------------------------------------------------------
-- Group 19: StaticCode totality sweep (M3, the inherited M2 LOW --
-- deliverable (4)). Forces 'codeText' and 'issueClassOf' to WHNF for
-- every member of 'allIssueCodes' and requires a non-empty 'codeText'.
--------------------------------------------------------------------------

staticCodeTotalityChecks :: [STCheck]
staticCodeTotalityChecks =
  [ mkST 19 ("totality/" ++ T.unpack (codeText c))
      (codeText c `seq` issueClassOf c `seq` not (T.null (codeText c)))
      "codeText/issueClassOf must force to WHNF and produce a non-empty codeText for every allIssueCodes member"
  | c <- allIssueCodes
  ]

--------------------------------------------------------------------------
-- Group 20: M4 (briefs/M4-manifest.json, task "midi-spec") --
-- SXC1.Midi.Spec proven against translations/midi.md. T1/T2/T3: the
-- hand-transcribed literal padNoteTable agrees, CELL BY CELL, with
-- SXC1.Midi.Table's freshly-parsed copy of the real source table, and
-- the Pad 2 / Bank C = 68 erratum is pinned BY NAME on both sides -- so
-- "correcting" translations/midi.md upstream turns CI red and forces a
-- human decision instead of silently changing what a drill verifies.
-- T5..T10: decodeMidi / matchSpec / selectPorts / describeSpec on fixed
-- vectors. T11: the six live verify: hooks committed in the corpus,
-- extracted from the real deck files, each satisfiable by a byte
-- sequence constructed from translations/midi.md. d-2-09 step 1's
-- mid-range dial values are additionally pinned as NON-confirming
-- (finding M4-F1 as revised by owner evidence,
-- docs/M4-device-evidence.md: only the dial ENDPOINTS 0/127 confirm,
-- and the M5 content pass reworded the step to a full sweep).
--------------------------------------------------------------------------

midiSpecMidiPath :: FilePath -> FilePath
midiSpecMidiPath root = root </> "translations" </> "midi.md"

-- | The three committed deck files carrying the six live verify: hooks
-- (ids per briefs/M4-manifest.json; file names per the merged M3 tree).
midiSpecHookFiles :: FilePath -> [(FilePath, Text)]
midiSpecHookFiles root =
  [ (exDir </> "024-pad-01.ex.md", "d-2-01")
  , (exDir </> "028-pad-03.ex.md", "d-2-02")
  , (exDir </> "036-pad-07.ex.md", "d-2-09")
  ]
  where
    exDir = root </> "content" </> "exercises"

-- | decode-then-match: does @bytes@, as delivered by Web MIDI, satisfy
-- @spec@ on channel @ch@?
hookSatisfied :: Int -> VerifySpec -> [Int] -> Bool
hookSatisfied ch spec bytes = case decodeMidi bytes of
  Just m  -> matchSpec ch spec m
  Nothing -> False

-- | The ordered verify: specs of exercise @wantId@'s drill steps, or
-- Nothing if the deck did not parse or the exercise is absent.
extractVerifies :: Text -> Maybe Deck -> Maybe [VerifySpec]
extractVerifies wantId mDeck = case mDeck of
  Nothing -> Nothing
  Just d  -> case [ e | e <- dkExercises d, exId e == ExId wantId ] of
    (e : _) -> Just [ v | p <- exPrompts e, Confirm _ (Just v) <- [prBody p] ]
    []      -> Nothing

renderSpecs :: Maybe [VerifySpec] -> String
renderSpecs = show

midiSpecChecks :: FilePath -> IO [STCheck]
midiSpecChecks root = do
  let midiPath = midiSpecMidiPath root
  midiExists <- doesFileExist midiPath
  if not midiExists
    then pure [ mkST 20 "midi-spec/midi.md-not-found" False
                  (midiPath ++ " does not exist -- cannot run the SXC1.Midi.Spec agreement group") ]
    else do
      midiRaw <- readUtf8File midiPath
      let parsed = parsePadNotes midiRaw
      hookSpecs <- forM (midiSpecHookFiles root) $ \(fp, wantId) -> do
        fileExists <- doesFileExist fp
        if not fileExists
          then pure Nothing
          else do
            raw <- readUtf8File fp
            pure (extractVerifies wantId (readDeck fp raw))
      let (mSpecs01, mSpecs02, mSpecs09) = case hookSpecs of
            [a, b, c] -> (a, b, c)
            _         -> (Nothing, Nothing, Nothing)
      pure (concat
        [ padTableChecks parsed
        , decodeChecks
        , matchSpecChecks
        , selectPortsChecks
        , describeSpecChecks
        , verifyHookChecks parsed mSpecs01 mSpecs02 mSpecs09
        ])

-- | T1..T4.
padTableChecks :: Map (Int, Char) Int -> [STCheck]
padTableChecks parsed =
  [ mkST 20 "pad-table/parsed-has-exactly-64-entries"
      (Map.size parsed == 64)
      ("parsePadNotes on the real translations/midi.md must yield exactly 64 entries, got "
         ++ show (Map.size parsed))
  , mkST 20 "pad-table/parsed-keys-are-pads-1-16-banks-A-D"
      (all (\(p, b) -> p >= 1 && p <= 16 && b `elem` ("ABCD" :: String)) (Map.keys parsed))
      ("every parsed key must be (1..16, A..D), got keys " ++ show (Map.keys parsed))
  ]
  ++
  -- T2: cell by cell, not a spot check -- a failure names the exact cell.
  [ mkST 20 ("pad-agreement/pad-" ++ show p ++ "-bank-" ++ [b])
      (padNote p b == Map.lookup (p, b) parsed)
      ("padNote " ++ show p ++ " " ++ show b ++ " = " ++ show (padNote p b)
         ++ " but the cell parsed out of translations/midi.md = " ++ show (Map.lookup (p, b) parsed))
  | p <- [1 .. 16], b <- "ABCD"
  ]
  ++
  -- T3: the erratum pinned by name, on BOTH the literal and the parsed
  -- side.
  [ mkST 20 "pad-erratum/pad-1-bank-C-is-68"
      (padNote 1 'C' == Just 68 && Map.lookup (1, 'C') parsed == Just 68)
      ("pad 1 bank C must be 68 in both the literal table and the parsed source, got literal="
         ++ show (padNote 1 'C') ++ " parsed=" ++ show (Map.lookup (1, 'C') parsed))
  , mkST 20 "pad-erratum/pad-2-bank-C-is-68-the-pinned-source-erratum"
      (padNote 2 'C' == Just 68 && Map.lookup (2, 'C') parsed == Just 68)
      ("midi.md prints Pad 2 / Bank C = 68 (duplicating Pad 1 -- the recorded erratum, "
         ++ "translations/midi.qa-notes.md); 'correcting' it upstream must turn this red, got literal="
         ++ show (padNote 2 'C') ++ " parsed=" ++ show (Map.lookup (2, 'C') parsed))
  -- T4: out-of-domain lookups.
  , mkST 20 "pad-domain/pad-0-is-Nothing" (padNote 0 'A' == Nothing) (show (padNote 0 'A'))
  , mkST 20 "pad-domain/pad-17-is-Nothing" (padNote 17 'A' == Nothing) (show (padNote 17 'A'))
  , mkST 20 "pad-domain/bank-E-is-Nothing" (padNote 1 'E' == Nothing) (show (padNote 1 'E'))
  ]

-- | T5.
decodeChecks :: [STCheck]
decodeChecks =
  [ mkST 20 "decode/cc-80-127-ch1"
      (decodeMidi [0xB0, 0x50, 0x7F] == Just (MsgCC 1 80 127)) "want Just (MsgCC 1 80 127)"
  , mkST 20 "decode/cc-80-127-ch2"
      (decodeMidi [0xB1, 0x50, 0x7F] == Just (MsgCC 2 80 127)) "want Just (MsgCC 2 80 127)"
  , mkST 20 "decode/note-36-127-ch1"
      (decodeMidi [0x90, 0x24, 0x7F] == Just (MsgNote 1 36 127)) "want Just (MsgNote 1 36 127)"
  , mkST 20 "decode/note-36-velocity-0-is-still-a-note-on"
      (decodeMidi [0x90, 0x24, 0x00] == Just (MsgNote 1 36 0)) "want Just (MsgNote 1 36 0)"
  , mkST 20 "decode/system-message-is-Nothing"
      (decodeMidi [0xF0, 0x7E, 0xF7] == Nothing) "sysex/system (>= 0xF0) is never a verification"
  , mkST 20 "decode/truncated-cc-is-Nothing"
      (decodeMidi [0xB0, 0x50] == Nothing) "a 0xB0 message needs two data bytes"
  , mkST 20 "decode/empty-is-Nothing"
      (decodeMidi [] == Nothing) "the empty byte list decodes to Nothing"
  ]

-- | T6..T8. All positive vectors are on channel 1 against wantChannel 1.
matchSpecChecks :: [STCheck]
matchSpecChecks =
  let cc80 = VerifyCC 80 [127]
  in
  [ mkST 20 "match-cc/exact-is-true"
      (matchSpec 1 cc80 (MsgCC 1 80 127)) "CC 80 = 127 on channel 1 must match"
  , mkST 20 "match-cc/wrong-cc-is-false"
      (not (matchSpec 1 cc80 (MsgCC 1 81 127))) "CC 81 must not match a cc 80 hook"
  , mkST 20 "match-cc/wrong-value-is-false"
      (not (matchSpec 1 cc80 (MsgCC 1 80 0))) "value 0 must not match a cc 80 127 hook"
  , mkST 20 "match-cc/wrong-channel-is-false"
      (not (matchSpec 1 cc80 (MsgCC 2 80 127))) "channel 2 must not match when channel 1 is expected"
  , mkST 20 "match-cc/note-is-false"
      (not (matchSpec 1 cc80 (MsgNote 1 80 127))) "a note message must not match a cc hook"

  -- T7: velocity-agnostic pad matching (see SXC1.Midi.Spec's VELOCITY
  -- Haddock -- the one assumption only the owner's device can settle).
  , mkST 20 "match-pad/note-36-matches-pad-1-bank-A"
      (matchSpec 1 (VerifyPad 1 'A') (MsgNote 1 36 127)) "note 36 is pad 1 bank A"
  , mkST 20 "match-pad/velocity-0-still-matches"
      (matchSpec 1 (VerifyPad 1 'A') (MsgNote 1 36 0))
      "a 0x90 with velocity 0 must still match -- the SXC-1's velocity byte is not meaningful"
  , mkST 20 "match-pad/note-37-is-false"
      (not (matchSpec 1 (VerifyPad 1 'A') (MsgNote 1 37 127))) "note 37 is pad 2, not pad 1"

  -- T8: VerifyAny matches transmit-shaped activity only.
  , mkST 20 "match-any/cc-is-true" (matchSpec 1 VerifyAny (MsgCC 1 80 127)) "any must match a CC"
  , mkST 20 "match-any/note-is-true" (matchSpec 1 VerifyAny (MsgNote 1 36 127)) "any must match a note"
  , mkST 20 "match-any/other-is-false"
      (not (matchSpec 1 VerifyAny (MsgOther 1)))
      "any must NOT match MsgOther -- the SXC-1 transmits only CC and note messages"
  ]

-- | T9.
selectPortsChecks :: [STCheck]
selectPortsChecks =
  [ mkST 20 "ports/sxc1-name-wins-among-several"
      (selectPorts [("Arturia KeyStep", "Arturia"), ("CASIO SXC-1 MIDI 1", "CASIO"), ("USB MIDI Device", "")]
         == [1])
      "only the SXC-1-looking index must be picked when one exists"
  , mkST 20 "ports/sxc1-manufacturer-match-case-folded"
      (selectPorts [("USB MIDI Device", "Casio SXC1"), ("Other Keyboard", "")] == [0])
      "the sxc1 needle must match case-foldedly in the manufacturer field too"
  , mkST 20 "ports/casio-fallback"
      (selectPorts [("Arturia KeyStep", ""), ("CASIO USB MIDI", "")] == [1])
      "with no sxc-1-looking port, casio-looking ports must be picked"
  , mkST 20 "ports/unrecognised-falls-back-to-all"
      (selectPorts [("USB MIDI Device", ""), ("Some Keyboard", "")] == [0, 1])
      "nobody has seen the SXC-1's real port string -- an unmatched list must bind EVERY index"
  , mkST 20 "ports/empty-is-empty" (selectPorts [] == []) "no ports, no indices"
  ]

-- | T10.
describeSpecChecks :: [STCheck]
describeSpecChecks =
  [ mkST 20 "describe/cc-single" (describeSpec (VerifyCC 80 [127]) == "CC 80 = 127")
      (T.unpack (describeSpec (VerifyCC 80 [127])))
  , mkST 20 "describe/cc-pair" (describeSpec (VerifyCC 80 [0, 127]) == "CC 80 = 0 or 127")
      (T.unpack (describeSpec (VerifyCC 80 [0, 127])))
  , mkST 20 "describe/cc-comma-list-final-or" (describeSpec (VerifyCC 16 [0, 1, 2]) == "CC 16 = 0, 1 or 2")
      (T.unpack (describeSpec (VerifyCC 16 [0, 1, 2])))
  , mkST 20 "describe/note-single" (describeSpec (VerifyNote [36]) == "note 36")
      (T.unpack (describeSpec (VerifyNote [36])))
  , mkST 20 "describe/note-pair" (describeSpec (VerifyNote [36, 48]) == "note 36 or 48")
      (T.unpack (describeSpec (VerifyNote [36, 48])))
  , mkST 20 "describe/pad" (describeSpec (VerifyPad 1 'A') == "pad 1 in bank A (note 36)")
      (T.unpack (describeSpec (VerifyPad 1 'A')))
  , mkST 20 "describe/any" (describeSpec VerifyAny == "any MIDI activity from the device")
      (T.unpack (describeSpec VerifyAny))
  ]

-- | T11: the six committed hooks, extracted from the real deck files.
-- Byte sequences are constructed from translations/midi.md: CC numbers
-- 80/108/109 from the "4. Control Change list" table (Bank Select A,
-- EFFECT FX1, EFFECT FX2), pad notes looked up in the freshly-PARSED
-- "5. Note mapping" table rather than hard-coded. The M5 content pass
-- recalibrated d-2-09 to the owner's device evidence
-- (docs/M4-device-evidence.md): step 1 (verify: cc 16 0,127) is the
-- continuous FX1 dial (initial 0, +/-1 per detent), confirmable only
-- at its range ENDPOINTS -- mid-range values 1..126 stay pinned as
-- non-confirming (finding M4-F1 as revised); steps 2 and 3 accept
-- 0,127 because the FX buttons are toggles transmitting 127 on the
-- ON edge and 0 on the OFF edge, so BOTH edges must satisfy.
verifyHookChecks
  :: Map (Int, Char) Int
  -> Maybe [VerifySpec] -> Maybe [VerifySpec] -> Maybe [VerifySpec]
  -> [STCheck]
verifyHookChecks parsed mSpecs01 mSpecs02 mSpecs09 =
  [ mkST 20 "hooks/d-2-01-spec-is-cc-80-127"
      (mSpecs01 == Just [VerifyCC 80 [127]]) (renderSpecs mSpecs01)
  , mkST 20 "hooks/d-2-01-satisfied-by-bank-select-A-press"
      (case mSpecs01 of
         Just [s] -> hookSatisfied 1 s [0xB0, 0x50, 0x7F]
         _        -> False)
      "CC 80 = 127 (Bank Select A pressed, midi.md section 4) must satisfy d-2-01 step 1"

  , mkST 20 "hooks/d-2-02-specs-are-pad-1-A-and-pad-13-A"
      (mSpecs02 == Just [VerifyPad 1 'A', VerifyPad 13 'A']) (renderSpecs mSpecs02)
  , mkST 20 "hooks/d-2-02-step-1-satisfied-by-parsed-pad-1-bank-A-note"
      (case (mSpecs02, Map.lookup (1, 'A') parsed) of
         (Just (s : _), Just n) -> hookSatisfied 1 s [0x90, n, 0x7F]
         _                      -> False)
      "the note midi.md's parsed table gives for pad 1 bank A must satisfy d-2-02 step 1"
  , mkST 20 "hooks/d-2-02-step-2-satisfied-by-parsed-pad-13-bank-A-note"
      (case (mSpecs02, Map.lookup (13, 'A') parsed) of
         (Just [_, s], Just n) -> hookSatisfied 1 s [0x90, n, 0x7F]
         _                     -> False)
      "the note midi.md's parsed table gives for pad 13 bank A must satisfy d-2-02 step 2"

  , mkST 20 "hooks/d-2-09-specs-as-committed"
      (mSpecs09 == Just [VerifyCC 16 [0, 127], VerifyCC 108 [0, 127], VerifyCC 109 [0, 127]])
      (renderSpecs mSpecs09)
  , mkST 20 "hooks/d-2-09-step-1-M4-F1-no-dial-value-1-126-satisfies-it"
      (case mSpecs09 of
         Just (s : _) -> all (\v -> not (hookSatisfied 1 s [0xB0, 16, v])) [1 .. 126]
         _            -> False)
      ("finding M4-F1 as revised by owner evidence (docs/M4-device-evidence.md): verify: "
         ++ "cc 16 0,127 names the continuous FX1 dial, confirmable only at its range "
         ++ "endpoints -- mid-range values 1..126 must never satisfy the hook")
  , mkST 20 "hooks/d-2-09-step-2-satisfied-by-effect-fx1-press"
      (case mSpecs09 of
         Just [_, s, _] -> hookSatisfied 1 s [0xB0, 0x6C, 0x7F] && hookSatisfied 1 s [0xB0, 0x6C, 0x00]
         _              -> False)
      ("CC 108 = 127 (FX1 switching ON) and CC 108 = 0 (FX1 switching OFF) must BOTH satisfy "
         ++ "d-2-09 step 2 -- the FX buttons are toggles (midi.md section 4; owner evidence)")
  , mkST 20 "hooks/d-2-09-step-3-satisfied-by-effect-fx2-press"
      (case mSpecs09 of
         Just [_, _, s] -> hookSatisfied 1 s [0xB0, 0x6D, 0x7F] && hookSatisfied 1 s [0xB0, 0x6D, 0x00]
         _              -> False)
      ("CC 109 = 127 (FX2 switching ON) and CC 109 = 0 (FX2 switching OFF) must BOTH satisfy "
         ++ "d-2-09 step 3 -- the FX buttons are toggles (midi.md section 4; owner evidence)")
  ]

--------------------------------------------------------------------------
-- Tiny local helper
--------------------------------------------------------------------------

sortT :: [Text] -> [Text]
sortT = sortOn id

-- | 'Issue' derives no 'Show' (size discipline -- see
-- "SXC1.Exercise.Report"), so self-test failure messages render issues
-- via 'renderIssue' instead.
showIssues :: [Issue] -> String
showIssues = show . map (T.unpack . renderIssue)
