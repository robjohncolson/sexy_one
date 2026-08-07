{-# LANGUAGE OverloadedStrings #-}

-- | @exe:registry-check@ -- PromptId stability (M3). Reads the COMMITTED
-- @content\/id-registry.tsv@ and the real corpus (via
-- "SXC1.Exercise.Reader" -- the same structural reader @exe:app@ links,
-- so the registry is always checked against exactly what a learner's
-- browser sees) and enforces R1-R6 (see 'assertionLabel').
--
-- THERE IS NO @--update@ FLAG, DELIBERATELY. A check that regenerates
-- the registry from the corpus it is checking can never fail and proves
-- nothing. The registry is a committed file a human edits in the same
-- commit as the content change; the tombstone process is documented in
-- the registry file's own header.
--
-- Modes: (none) = check the real tree; @--self-test@ = run the checker's
-- own comparison logic over synthetic in-memory registries\/corpora,
-- proving every rule CAN fire (each violation class red on a violating
-- input, green on a clean one); @--list@ = print the registry as read.
module Main (main) where

import           Control.Monad          (forM, forM_, unless)
import           Data.IORef             (IORef, modifyIORef', newIORef, readIORef)
import           Data.List              (sort)
import qualified Data.Map.Strict        as Map
import           Data.Text              (Text)
import qualified Data.Text              as T
import qualified Data.Text.IO           as TIO
import           System.Environment     (getArgs)
import           System.Exit            (exitFailure)
import           System.IO              (hPutStrLn, stderr)

import           SXC1.Exercise.Reader   (readDeck)
import           SXC1.Exercise.Types    (Deck (..), DeckId (..), ExId (..), Exercise (..))
import           SXC1.Route             (parseDigits)

--------------------------------------------------------------------------
-- Registry model
--------------------------------------------------------------------------

data RegRow = RegRow
  { rrId     :: !Text
  , rrCount  :: !Int
  , rrStatus :: !Text   -- "live" | "tombstone"
  , rrShip   :: !Text
  , rrNote   :: !Text
  } deriving Eq

parseRegistry :: Text -> ([RegRow], [Text])
parseRegistry raw = foldr step ([], []) (zip [1 :: Int ..] (T.lines raw))
  where
    step (n, ln) (rows, errs)
      | T.null (T.strip ln) || "#" `T.isPrefixOf` T.strip ln = (rows, errs)
      | otherwise = case T.splitOn "\t" ln of
          -- M3 gate NEW6: EXACTLY five columns (the note may be empty
          -- text but its column must exist), and first-shipped must be
          -- a milestone tag (m0, m1, ...). A four-column row or a
          -- free-text ship tag is malformed, not leniently accepted.
          [i, cnt, st, ship, note]
            | Just c <- parseDigits cnt
            , st == "live" || st == "tombstone"
            -- NEW6 (round-3): a tombstone MUST carry promptCount 0 --
            -- a retired id mints no prompts; a nonzero count on a
            -- tombstone row is malformed, not leniently accepted.
            , st == "live" || c == 0
            , validShipTag ship
            -> (RegRow i c st ship note : rows, errs)
          _ -> (rows, ("line " <> T.pack (show n) <> ": malformed row") : errs)

validShipTag :: Text -> Bool
validShipTag s = case T.uncons s of
  Just ('m', ds) -> not (T.null ds) && T.all (\c -> c >= '0' && c <= '9') ds
  _              -> False

-- | One corpus exercise as the app sees it: (id, promptCount, deckSlug, chapterTitle).
data CorpusEx = CorpusEx
  { ceId      :: !Text
  , ceCount   :: !Int
  , ceDeck    :: !Text
  , ceChapter :: !Text
  } deriving Eq

chapterDigitOf :: Text -> Maybe Char
chapterDigitOf title = lookup title
  [ ("Front matter", '0'), ("Part: Preparation", '1'), ("Part: Pad play", '2')
  , ("Part: Sampling", '3'), ("Part: Sequencer", '4'), ("Part: Leveling up", '5') ]

idChapterDigit :: Text -> Maybe Char
idChapterDigit i = case T.splitOn "-" i of
  (_ : c : _) | T.length c == 1 -> Just (T.head c)
  _                              -> Nothing

idSyntaxOk :: Text -> Bool
idSyntaxOk i = not (T.null i) && T.all (\c -> c == '-' || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) i

--------------------------------------------------------------------------
-- The rule engine -- pure, shared by the real check and the self-test.
-- Each rule yields human-readable violation strings; empty = pass.
--------------------------------------------------------------------------

r1MissingLive, r2Deleted, r3CountDrift, r4Dupes, r5Resurrected, r6Shape
  :: [RegRow] -> [CorpusEx] -> [Text]

r1MissingLive rows corpus =
  [ "corpus exercise " <> ceId ce <> " (deck " <> ceDeck ce <> ") is not registered as live"
  | ce <- corpus
  , Map.lookup (ceId ce) liveMap /= Just True ]
  where liveMap = Map.fromList [ (rrId r, rrStatus r == "live") | r <- rows ]

r2Deleted rows corpus =
  [ "registry live row " <> rrId r <> " has no corpus exercise (delete requires a tombstone)"
  | r <- rows, rrStatus r == "live", not (Map.member (rrId r) corpusMap) ]
  where corpusMap = Map.fromList [ (ceId ce, ()) | ce <- corpus ]

r3CountDrift rows corpus =
  [ rrId r <> ": registry promptCount " <> tshow (rrCount r) <> " /= corpus " <> tshow (ceCount ce)
  | r <- rows, rrStatus r == "live"
  , Just ce <- [Map.lookup (rrId r) corpusMap]
  , rrCount r /= ceCount ce ]
  where corpusMap = Map.fromList [ (ceId ce, ce) | ce <- corpus ]

r4Dupes rows _ =
  [ "id " <> i <> " appears " <> tshow n <> " times in the registry"
  | (i, n) <- Map.toList (Map.fromListWith (+) [ (rrId r, 1 :: Int) | r <- rows ]), n > 1 ]

r5Resurrected rows corpus =
  [ "tombstoned id " <> rrId r <> " exists in the corpus (ids are never reused)"
  | r <- rows, rrStatus r == "tombstone", Map.member (rrId r) corpusMap ]
  where corpusMap = Map.fromList [ (ceId ce, ()) | ce <- corpus ]

r6Shape rows corpus =
  [ "registry id " <> rrId r <> " is not [a-z0-9-]+" | r <- rows, not (idSyntaxOk (rrId r)) ]
  ++
  [ ceId ce <> ": chapter digit disagrees with deck chapter " <> ceChapter ce
  | ce <- corpus
  , Just d <- [idChapterDigit (ceId ce)]
  , Just d' <- [chapterDigitOf (ceChapter ce)]
  , d /= d' ]

tshow :: Int -> Text
tshow = T.pack . show

--------------------------------------------------------------------------
-- Harness (CheckExercises.hs's shape: groups, label, NEW12 guard)
--------------------------------------------------------------------------

groupRange :: [Int]
groupRange = [1 .. 6]

assertionLabel :: Int -> String
assertionLabel g = case g of
  1 -> "R1 every corpus id registered live"
  2 -> "R2 every live row has a corpus exercise"
  3 -> "R3 promptCount agrees with the corpus"
  4 -> "R4 no duplicate registry ids"
  5 -> "R5 no tombstone is resurrected"
  6 -> "R6 id syntax + chapter-digit consistency"
  _ -> "?"

rules :: [(Int, [RegRow] -> [CorpusEx] -> [Text])]
rules = [(1, r1MissingLive), (2, r2Deleted), (3, r3CountDrift), (4, r4Dupes), (5, r5Resurrected), (6, r6Shape)]

record :: IORef [(Int, Bool)] -> Int -> String -> Bool -> String -> IO ()
record ref g name ok detail = do
  modifyIORef' ref (++ [(g, ok)])
  putStrLn ((if ok then "ok   - " else "FAIL - ") ++ "[" ++ show g ++ "] " ++ name
            ++ (if ok then "" else " (observed: " ++ take 400 detail ++ ")"))

finish :: IORef [(Int, Bool)] -> IO ()
finish ref = do
  checks <- readIORef ref
  let okN = length [ () | (_, True) <- checks ]
      emptyGroups = [ g | g <- groupRange, null [ () | (g', _) <- checks, g' == g ] ]
  putStrLn ("registry-check: " ++ show okN ++ "/" ++ show (length checks) ++ " checks passed")
  unless (null emptyGroups) $ do
    hPutStrLn stderr ("registry-check: EMPTY assertion group(s): " ++ show emptyGroups ++ " (NEW12 guard)")
    exitFailure
  unless (okN == length checks) exitFailure

--------------------------------------------------------------------------
-- Disk loading (check mode)
--------------------------------------------------------------------------

loadCorpus :: IO [CorpusEx]
loadCorpus = do
  idx <- TIO.readFile "../content/exercises/INDEX"
  let files = [ T.unpack (T.strip l) | l <- T.lines idx
              , not (T.null (T.strip l)), not ("#" `T.isPrefixOf` T.strip l) ]
  fmap concat . forM files $ \f -> do
    let path = "../content/exercises/" ++ f
    txt <- TIO.readFile path
    case readDeck path txt of
      Nothing -> do
        hPutStrLn stderr ("registry-check: UNREADABLE deck (Reader returned Nothing): " ++ path)
        exitFailure
      Just d ->
        let DeckId slug = dkId d
        in pure [ CorpusEx eid (length (exPrompts e)) slug (dkChapter d)
                | e <- dkExercises d, let ExId eid = exId e ]

runCheck :: IO ()
runCheck = do
  raw <- TIO.readFile "../content/id-registry.tsv"
  let (rows, errs) = parseRegistry raw
  corpus <- loadCorpus
  ref <- newIORef []
  record ref 6 "registry file parses with zero malformed rows" (null errs) (T.unpack (T.intercalate "; " errs))
  -- M3 gate NEW6: the header's sorted-by-id claim is now ENFORCED against
  -- the rows as read from disk, not a synthetic list.
  let diskIds = map rrId rows
  record ref 4 "registry rows are sorted by id ON DISK"
    (sort diskIds == diskIds)
    (T.unpack (T.intercalate " " (take 4 [ b | (a, b) <- zip diskIds (drop 1 diskIds), a > b ])))
  forM_ rules $ \(g, rule) -> do
    let vs = rule rows corpus
    record ref g (assertionLabel g ++ " (" ++ show (length corpus) ++ " corpus / " ++ show (length rows) ++ " registry)")
      (null vs) (T.unpack (T.intercalate " | " (take 4 vs)))
  finish ref

--------------------------------------------------------------------------
-- --self-test: every rule proven able to fire on synthetic inputs
--------------------------------------------------------------------------

selfTest :: IO ()
selfTest = do
  ref <- newIORef []
  let live i n   = RegRow i n "live" "m3" "test"
      tomb i     = RegRow i 0 "tombstone" "m3" "retired"
      ex i n     = CorpusEx i n "prep-01" "Part: Preparation"
      cleanRows  = [live "d-1-01" 3, live "q-1-01" 1, tomb "q-1-14"]
      cleanCorp  = [ex "d-1-01" 3, ex "q-1-01" 1]
  forM_ rules $ \(g, rule) ->
    record ref g ("clean synthetic input passes " ++ assertionLabel g)
      (null (rule cleanRows cleanCorp)) (T.unpack (T.intercalate "|" (rule cleanRows cleanCorp)))
  let fires g rule rows corp nm =
        record ref g (nm ++ " fires") (not (null (rule rows corp))) "rule did not fire on violating input"
  fires 1 r1MissingLive cleanRows (ex "q-9-01" 1 : cleanCorp) "R1 (unregistered corpus id)"
  fires 2 r2Deleted     cleanRows [ex "q-1-01" 1]             "R2 (live row, exercise deleted)"
  fires 3 r3CountDrift  cleanRows (ex "d-1-01" 4 : [ex "q-1-01" 1]) "R3 (prompt count drift 3->4)"
  fires 4 r4Dupes       (live "q-1-01" 1 : cleanRows) cleanCorp "R4 (duplicate id)"
  fires 5 r5Resurrected cleanRows (ex "q-1-14" 1 : cleanCorp)  "R5 (tombstone resurrected)"
  fires 6 r6Shape       [live "Q_bad!" 1] []                   "R6 (bad id syntax)"
  fires 6 r6Shape       cleanRows [CorpusEx "q-2-01" 1 "prep-01" "Part: Preparation"] "R6 (chapter digit mismatch)"
  -- parser robustness: malformed row reported, well-formed rows still parse
  let (rs, es) = parseRegistry "# c\nq-1-01\t1\tlive\tm2\tdeck\nbroken row\nq-1-02\t2\tlive\tm2\tdeck\n"
  record ref 6 "malformed registry row reported without losing siblings"
    (length rs == 2 && length es == 1) ("rows " ++ show (length rs) ++ " errs " ++ show (length es))
  -- M3 gate NEW6 (round-3): a tombstone with a NONZERO promptCount is
  -- malformed at parse -- proven able to fire, not just claimed.
  let (rsT, esT) = parseRegistry "q-1-14\t3\ttombstone\tm3\tretired\nq-1-15\t0\ttombstone\tm3\tretired\n"
  record ref 6 "nonzero-count tombstone row is malformed (zero-count one still parses)"
    (length rsT == 1 && length esT == 1 && rrId (head rsT) == "q-1-15")
    ("rows " ++ show (length rsT) ++ " errs " ++ show (length esT))
  record ref 4 "registry sort order is checkable (sorted ids compare equal)"
    (sort (map rrId cleanRows) == map rrId cleanRows) "synthetic rows unsorted"
  finish ref

--------------------------------------------------------------------------

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--self-test"] -> selfTest
    ["--list"] -> do
      raw <- TIO.readFile "../content/id-registry.tsv"
      let (rows, _) = parseRegistry raw
      forM_ rows $ \r -> TIO.putStrLn (T.intercalate "\t" [rrId r, tshow (rrCount r), rrStatus r, rrShip r, rrNote r])
    _ -> runCheck
