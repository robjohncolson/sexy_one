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
import           Data.List              (isSuffixOf, sortOn)
import qualified Data.Map.Strict        as Map
import           Data.Map.Strict        (Map)
import           Data.Maybe             (mapMaybe)
import qualified Data.Set               as Set
import           Data.Text              (Text)
import qualified Data.Text              as T
import qualified Data.Text.Encoding     as TE
import           System.Directory       (doesDirectoryExist, doesFileExist, listDirectory)
import           System.Environment     (getArgs)
import           System.Exit            (ExitCode (ExitFailure), exitFailure, exitSuccess, exitWith)
import           System.FilePath        ((</>))
import           System.IO              (hPutStrLn, hSetEncoding, stderr, stdout, utf8)

import           SXC1.Content.Markdown  (LineShape (..), classifyLine, parseBlocksEngineWith)
import           SXC1.Content.Types     (Block (..))
import           SXC1.Exercise.Engine
import           SXC1.Exercise.Lint
import           SXC1.Exercise.Parse
import           SXC1.Exercise.Report
import           SXC1.Exercise.Types
import           SXC1.Exercise.Verify
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
  }

defaultOpts :: Opts
defaultOpts = Opts
  { optContentDir = "../content", optTranslationsDir = "../translations"
  , optJson = False, optSelfTest = False, optFixtures = Nothing
  , optListCodes = False, optBrowserFixture = False
  }

parseArgs :: [String] -> Either String Opts
parseArgs = go defaultOpts
  where
    go o [] = Right o
    go o ("--content-dir" : d : rest)      = go o { optContentDir = d } rest
    go o ("--translations-dir" : d : rest) = go o { optTranslationsDir = d } rest
    go o ("--json" : rest)                 = go o { optJson = True } rest
    go o ("--self-test" : rest)            = go o { optSelfTest = True } rest
    go o ("--fixtures" : d : rest)         = go o { optFixtures = Just d } rest
    go o ("--list-codes" : rest)           = go o { optListCodes = True } rest
    go o ("--browser-fixture" : rest)      = go o { optBrowserFixture = True } rest
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

-- | @content\/exercise-inventory.md@ is ALWAYS read from this fixed,
-- non-overridable relative path -- never from @--content-dir@ (which
-- only governs where EXERCISE FILES and @terminology-rules.tsv@ come
-- from, and is exactly what @--fixtures@ and ad-hoc sandboxes override).
-- This is what lets chapter-title validation work correctly even when
-- @--content-dir@ points at a sandbox that carries no inventory of its
-- own (see 'isRealContentPath' below for the complementary half of this
-- design: the four id-binding checks are scoped to paths that contain
-- @content\/exercises\/@ literally, which a sandboxed @--content-dir@
-- never does).
fixedInventoryPath :: FilePath
fixedInventoryPath = "../content/exercise-inventory.md"

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
  inventoryRaw <- readUtf8FileOrHarnessError fixedInventoryPath
  let chapterVocab = parseInventoryChapters inventoryRaw
  pure ( ruleIssues ++ groundIssues
       , SharedCtx
           { scRules = rules, scManualIdx = manualIdx, scMidiFacts = midiFacts
           , scChapterVocab = chapterVocab, scInventoryRaw = inventoryRaw
           }
       )

-- | The four id-inventory-binding checks apply "over content/exercises/
-- only, never to --fixtures" (briefs/M2-manifest.json). That scope is
-- decided here, by the deck FILE's own path: real runs (default
-- @--content-dir ../content@, or an explicit path to the real content
-- root) always produce paths containing the literal substring
-- @content/exercises/@; any sandboxed or fixture content root does not.
isRealContentPath :: FilePath -> Bool
isRealContentPath fp = "content/exercises/" `T.isInfixOf` T.pack fp

-- | Resolve every issue for ONE already-read deck file: grammar
-- ("SXC1.Exercise.Parse"), citation and verify-hook resolution
-- ("SXC1.Exercise.Verify"), terminology ("SXC1.Exercise.Lint"), chapter
-- title, and (scoped -- see 'isRealContentPath') the inventory binding.
resolveDeckIssues :: SharedCtx -> FilePath -> Text -> ([Issue], Maybe Deck)
resolveDeckIssues ctx fp raw =
  (parseIssues ++ citeIssues ++ verifyIssues ++ termIssues ++ chapterIssues ++ idIssues, mDeck)
  where
    (parseIssues, mDeck, cites, verifies, mChapterField, idRows, lintTargets) = parseDeckDetailed fp raw
    citeIssues    = concat [ resolveCitation (scManualIdx ctx) loc c | (loc, c) <- cites ]
    verifyIssues  = concat [ resolveVerify (scMidiFacts ctx) loc v | (loc, v) <- verifies ]
    termIssues    = concat [ lintText (scRules ctx) loc t | (loc, t) <- lintTargets ]
    chapterIssues = case mChapterField of
      Just (loc, txt) -> resolveChapter (scChapterVocab ctx) loc txt
      Nothing         -> []
    idIssues
      | isRealContentPath fp =
          concat [ resolveInventoryId (scInventoryRaw ctx) (scChapterVocab ctx) loc eid kind chText
                 | (loc, eid, kind, chText) <- idRows ]
      | otherwise = []

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
  { ldIssues      :: [Issue]
  , ldDecks       :: [Deck]
  , ldSourceChars :: [(Text, Int)]
  }

collectFromDirs :: FilePath -> FilePath -> IO Loaded
collectFromDirs contentDir translationsDir = do
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
           , ldDecks = [], ldSourceChars = []
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
        let (issues, mDeck) = resolveDeckIssues ctx fp raw
        pure (nm, issues, mDeck, T.length raw)

      let allIssues  = ctxIssues ++ orphanIssues ++ danglingIssues ++ concat [ i | (_, i, _, _) <- perDeck ]
          decks      = mapMaybe (\(_, _, d, _) -> d) perDeck
          dupIdIssues = globalIdDuplicateIssues decks
          sourceChars = [ (nm, n) | (nm, _, _, n) <- perDeck ]
      pure Loaded { ldIssues = allIssues ++ dupIdIssues, ldDecks = decks, ldSourceChars = sourceChars }

-- | E-ID-DUPLICATE: the same exercise id used by more than one exercise,
-- anywhere in the loaded content root. One issue per OCCURRENCE of a
-- duplicated id (fixture/report matching is over the SET of codes, so
-- the exact count does not matter, only that the code fires at all).
globalIdDuplicateIssues :: [Deck] -> [Issue]
globalIdDuplicateIssues decks =
  [ mkIssue E_ID_DUPLICATE (Loc (unDeckId (dkId d)) 1)
      ("id " <> idTxt <> " is used by more than one exercise (also in deck " <> unDeckId (dkId d) <> ")")
  | d <- decks, e <- dkExercises d
  , let ExId idTxt = exId e
  , Map.findWithDefault 0 idTxt idCounts > 1
  ]
  where
    idCounts :: Map Text Int
    idCounts = Map.fromListWith (+)
      [ (idTxt, 1 :: Int) | d <- decks, e <- dkExercises d, let ExId idTxt = exId e ]

unDeckId :: DeckId -> Text
unDeckId (DeckId t) = t

--------------------------------------------------------------------------
-- Default mode / --json mode
--------------------------------------------------------------------------

runDefaultMode :: Opts -> IO ()
runDefaultMode opts = do
  loaded <- collectFromDirs (optContentDir opts) (optTranslationsDir opts)
  forM_ (sortOn (\i -> (isFile i, isLine i)) (ldIssues loaded)) $ \i ->
    putStrLn (T.unpack (renderIssue i))
  putStrLn ("exercise-check: " ++ show (length (ldIssues loaded)) ++ " issue(s)")
  if null (ldIssues loaded) then exitSuccess else exitWith (ExitFailure 1)

runJsonMode :: Opts -> IO ()
runJsonMode opts = do
  loaded <- collectFromDirs (optContentDir opts) (optTranslationsDir opts)
  putStrLn (T.unpack (renderReport (null (ldIssues loaded)) (ldDecks loaded) (ldSourceChars loaded) (ldIssues loaded)))

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

runBrowserFixture :: Opts -> IO ()
runBrowserFixture opts = do
  loaded <- collectFromDirs (optContentDir opts) (optTranslationsDir opts)
  case (findQuiz loaded, findDrill loaded, findLookup loaded) of
    (Just qz, Just dr, Just lk) -> putStrLn (T.unpack (browserFixtureJson qz dr lk))
    _ -> do
      hPutStrLn stderr "exercise-check --browser-fixture: real content does not yet have one of each exercise kind"
      exitWith (ExitFailure 1)

data QuizFixture = QuizFixture { qfDeck, qfId, qfCorrectOpt, qfWrongOpt, qfCiteSlug :: Text, qfCitePage :: Int }
data DrillFixture = DrillFixture { dfDeck, dfId :: Text, dfSteps :: Int, dfHasVerify :: Bool }
data LookupFixture = LookupFixture { lfDeck, lfId :: Text, lfTargetPage :: Int }

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
  [ DrillFixture (unDeckId (dkId d)) i (length (exPrompts e)) hasV
  | d <- ldDecks loaded, e <- dkExercises d, exKind e == KDrill
  , let ExId i = exId e
        hasV = any promptHasVerify (exPrompts e)
        promptHasVerify p = case prBody p of { Confirm _ (Just _) -> True; _ -> False }
  ]

findLookup :: Loaded -> Maybe LookupFixture
findLookup loaded = firstJust
  [ LookupFixture (unDeckId (dkId d)) i (citPage target)
  | d <- ldDecks loaded, e <- dkExercises d, exKind e == KLookup
  , (p : _) <- [exPrompts e]
  , FindPage target _ <- [prBody p]
  , let ExId i = exId e
  ]

firstJust :: [a] -> Maybe a
firstJust (x : _) = Just x
firstJust []      = Nothing

browserFixtureJson :: QuizFixture -> DrillFixture -> LookupFixture -> Text
browserFixtureJson qz dr lk =
  "{" <> T.intercalate ","
    [ "\"quiz\":" <> obj
        [ kv "deck" (str (qfDeck qz)), kv "id" (str (qfId qz))
        , kv "correctOpt" (str ("opt-" <> qfCorrectOpt qz)), kv "wrongOpt" (str ("opt-" <> qfWrongOpt qz))
        , kv "citeSlug" (str (qfCiteSlug qz)), kv "citePage" (T.pack (show (qfCitePage qz)))
        ]
    , "\"drill\":" <> obj
        [ kv "deck" (str (dfDeck dr)), kv "id" (str (dfId dr))
        , kv "steps" (T.pack (show (dfSteps dr))), kv "hasVerify" (if dfHasVerify dr then "true" else "false")
        ]
    , "\"lookup\":" <> obj
        [ kv "deck" (str (lfDeck lk)), kv "id" (str (lfId lk)), kv "targetPage" (T.pack (show (lfTargetPage lk))) ]
    ] <> "}"
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

  fileResults <- forM (filter (".ex.md" `isSuffixOf`) fileNames) $ \fn -> do
    raw <- readUtf8FileOrHarnessError (filesDir </> fn)
    let fp = filesDir </> fn
        (issues, _) = resolveDeckIssues ctx fp raw
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
        -- checks below are already scoped by 'isRealContentPath' rather
        -- than applied unconditionally. This only changes what this
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
      loaded <- collectFromDirs (dirsDir </> dn) (optTranslationsDir opts)
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
  args <- getArgs
  case parseArgs args of
    Left err -> harnessError err
    Right opts
      | optSelfTest opts       -> runSelfTest
      | optListCodes opts      -> runListCodes opts
      | Just fdir <- optFixtures opts -> runFixtures opts fdir
      | optBrowserFixture opts -> runBrowserFixture opts
      | optJson opts           -> runJsonMode opts
      | otherwise               -> runDefaultMode opts

--------------------------------------------------------------------------
-- --self-test: inline unit tests, NO filesystem access. This is the
-- gate: "treat exercise-check --self-test passing as the deliverable,
-- not merely writing the modules."
--------------------------------------------------------------------------

data STCheck = STCheck { stGroup :: !Int, stName :: !String, stOk :: !Bool, stMsg :: !String }

mkST :: Int -> String -> Bool -> String -> STCheck
mkST = STCheck

stLabel :: Int -> String
stLabel 1  = "1. grammar: exact issue-code sets over >=20 embedded .ex.md sources"
stLabel 2  = "2. NEW12-safe runner: groupsOk vacuity guard (permanent negative-control demo)"
stLabel 3  = "3. engine: Choice grading (exact-set, multi-select)"
stLabel 4  = "4. engine: Recall grading (SelfGrade)"
stLabel 5  = "5. engine: Confirm grading (drill step + device confirm)"
stLabel 6  = "6. engine: FindPage grading (lookup)"
stLabel 7  = "7. engine: wrong-then-right retry path (attempts do not lock the prompt)"
stLabel 8  = "8. engine: hint counting"
stLabel 9  = "9. engine: ProgressEvent fields, incl. exercise-completed on Advance past the end"
stLabel 10 = "10. engine: PromptId stability (<exercise-id>#<step>)"
stLabel 11 = "11. route: CONSTRUCTOR assertions for the three new routes (round-trip alone is vacuous, P-M)"
stLabel 12 = "12. route: totality on malformed inputs"
stLabel 13 = "13. seam: E-BLOCK-UNPARSED via parseBlocksEngineWith (the only way it is reachable)"
stLabel 14 = "14. resolution: resolveCitation/resolveVerify/resolveChapter/resolveInventoryId on synthetic data"
stLabel n  = show n ++ ". ?"

stMaxGroup :: Int
stMaxGroup = 14

stGroupsAllOk :: Int -> [STCheck] -> Bool
stGroupsAllOk maxG cs = all oneGroupOk [1 .. maxG]
  where
    oneGroupOk g = let ig = filter ((== g) . stGroup) cs in not (null ig) && all stOk ig

runSelfTest :: IO ()
runSelfTest = do
  let allChecks = concat
        [ grammarChecks, new12GuardSelfChecks, choiceChecks, recallChecks, confirmChecks
        , findPageChecks, retryChecks, hintChecks, progressEventChecks, promptIdChecks
        , routeConstructorChecks, routeTotalityChecks, blockUnparsedSeamChecks, resolutionChecks
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
      validFp (joinL (take 8 quizChoiceLines))
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

  , grammarCheck "E-DRILL-STEP-COUNT/one-step"
      validFp (joinL (take 20 drillLines))
      ["E-DRILL-STEP-COUNT"]

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
  ]

insertAfter :: Text -> Text -> [Text] -> [Text]
insertAfter anchor new = concatMap (\l -> if l == anchor then [l, new] else [l])

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
  let st0 = initialState (ExId "st-choice-ex") 1000
      (st1, ev1) = step choiceExercise (Toggle 0 "a") st0
      (st2, ev2) = step choiceExercise (Toggle 0 "c") st1
      (st3, ev3) = step choiceExercise (Submit 0 1500 1000) st2
  in
  [ mkST 3 "choice/toggle-emits-no-event" (null ev1 && null ev2) ("ev1=" ++ show ev1 ++ " ev2=" ++ show ev2)
  , mkST 3 "choice/exact-set-match-is-correct"
      (case ev3 of { [e] -> peOutcome e == Correct; _ -> False }) ("ev3=" ++ show ev3)
  , mkST 3 "choice/response-recorded"
      (case IntMap.lookup 0 (esResponses st3) of { Just (RChosen sel) -> sortT sel == ["a", "c"]; _ -> False })
      (show (esResponses st3))
  , mkST 3 "choice/wrong-set-is-incorrect"
      (let (_, ev) = step choiceExercise (Submit 0 1500 1000) (fst (step choiceExercise (Toggle 0 "b") st0))
       in case ev of { [e] -> peOutcome e == Incorrect; _ -> False })
      "selecting only b (missing a,c and including a non-correct option) must grade Incorrect"
  ]

recallChecks :: [STCheck]
recallChecks =
  let st0 = initialState (ExId "st-recall-ex") 1000
      (st1, ev1) = step recallExercise (Reveal 0) st0
      (_, ev2) = step recallExercise (SelfGrade_ 0 Got 1500 2000) st1
  in
  [ mkST 4 "recall/reveal-emits-no-event-but-marks-revealed" (null ev1 && IntSet.member 0 (esRevealed st1)) (show ev1)
  , mkST 4 "recall/self-grade-got-is-correct-and-revealed"
      (case ev2 of { [e] -> peOutcome e == Correct && peRevealed e; _ -> False }) (show ev2)
  , mkST 4 "recall/self-grade-missed-is-incorrect"
      (let (_, ev) = step recallExercise (SelfGrade_ 0 Missed 1500 2000) st1
       in case ev of { [e] -> peOutcome e == Incorrect; _ -> False }) "Missed must grade Incorrect"
  ]

confirmChecks :: [STCheck]
confirmChecks =
  let st0 = initialState (ExId "st-drill-ex") 1000
      (st1, ev1) = step drillExercise (ConfirmStep 0 ByLearner 1200 2000) st0
      (_, ev2) = step drillExercise (ConfirmStep 1 ByDevice 1400 2200) st1
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
  let st0 = initialState (ExId "st-lookup-ex") 1000
      (st1, _) = step lookupExercise (EnterPage 0 55) st0
      (_, ev2) = step lookupExercise (SubmitPage 0 1500 2000) st1
      (st1w, _) = step lookupExercise (EnterPage 0 12) st0
      (_, evw) = step lookupExercise (SubmitPage 0 1500 2000) st1w
  in
  [ mkST 6 "findpage/correct-page-is-correct"
      (case ev2 of { [e] -> peOutcome e == Correct; _ -> False }) (show ev2)
  , mkST 6 "findpage/wrong-page-is-incorrect"
      (case evw of { [e] -> peOutcome e == Incorrect; _ -> False }) (show evw)
  , mkST 6 "findpage/unanswered-submit-is-incorrect"
      (case step lookupExercise (SubmitPage 0 1500 2000) st0 of { (_, [e]) -> peOutcome e == Incorrect; _ -> False })
      "submitting with no EnterPage first must not crash and must grade Incorrect"
  ]

--------------------------------------------------------------------------
-- Group 7: wrong-then-right retry path + attempt counting
--------------------------------------------------------------------------

retryChecks :: [STCheck]
retryChecks =
  let st0 = initialState (ExId "st-choice-ex") 1000
      (st1, _)   = step choiceExercise (Toggle 0 "b") st0                  -- wrong selection
      (st2, ev2) = step choiceExercise (Submit 0 1200 1000) st1            -- attempt 1: wrong
      (st3, _)   = step choiceExercise (Toggle 0 "b") st2                  -- learner retries: deselect b
      (st4, _)   = step choiceExercise (Toggle 0 "a") st3
      (st5, _)   = step choiceExercise (Toggle 0 "c") st4
      (st6, ev6) = step choiceExercise (Submit 0 1800 1600)                -- attempt 2: right
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
  let st0 = initialState (ExId "st-choice-ex") 1000
      (st1, ev1) = step choiceExercise (ShowHint 0) st0
      (st2, ev2) = step choiceExercise (ShowHint 0) st1
      (st3, _)   = step choiceExercise (Toggle 0 "a") st2
      (st4, _)   = step choiceExercise (Toggle 0 "c") st3
      (_, ev5)   = step choiceExercise (Submit 0 2000 2000) st4
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
  let st0 = initialState (ExId "st-drill-ex") 5000
      (st1, _)  = step drillExercise (ConfirmStep 0 ByLearner 5200 6000) st0
      (st2, ev2) = step drillExercise (Advance 6100) st1                  -- 1 of 2 prompts done -> not complete
      (st3, _)  = step drillExercise (ConfirmStep 1 ByLearner 6300 6400) st2
      (st4, ev4) = step drillExercise (Advance 6500) st3                  -- 2 of 2 -> exercise-completed
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
-- Tiny local helper
--------------------------------------------------------------------------

sortT :: [Text] -> [Text]
sortT = sortOn id

-- | 'Issue' derives no 'Show' (size discipline -- see
-- "SXC1.Exercise.Report"), so self-test failure messages render issues
-- via 'renderIssue' instead.
showIssues :: [Issue] -> String
showIssues = show . map (T.unpack . renderIssue)
