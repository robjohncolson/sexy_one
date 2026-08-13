{-# LANGUAGE OverloadedStrings #-}

-- | A pure projection of authored prerequisites and saved progress into the
-- mastery map.  This module deliberately owns no rendering and performs no IO:
-- the same course and progress snapshot always produce the same graph.
module SXC1.Mastery
  ( MasteryBand (..)
  , PromptBand (..)
  , DeckMastery (..)
  , GraphNode (..)
  , GraphEdge (..)
  , MasteryGraph (..)
  , buildMasteryGraph
  , promptBand
  , bandCount
  ) where

import           Data.List              (find)
import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map
import           Data.Maybe             (isJust)
import           Data.Text              (Text)

import           SXC1.Exercise.Types
import           SXC1.Progress.Types

-- | Deck-level mastery.  Due work is kept distinct from weak work: a deck can
-- be fully learned and still need consolidation today.
data MasteryBand
  = MUnseen
  | MLearning
  | MPracticed
  | MConsolidating
  | MStrong
  deriving (Eq, Ord, Show, Enum, Bounded)

data PromptBand = PUnseen | PFragile | PBuilding | PDurable
  deriving (Eq, Ord, Show, Enum, Bounded)

data DeckMastery = DeckMastery
  { dmDeck         :: !Deck
  , dmDone         :: !Int
  , dmExercises    :: !Int
  , dmPrompts      :: !Int
  , dmUnseen       :: !Int
  , dmFragile      :: !Int
  , dmBuilding     :: !Int
  , dmDurable      :: !Int
  , dmDue          :: !Int
  , dmBand         :: !MasteryBand
  , dmPrereqsMet   :: !Bool
  } deriving Eq

-- | Stable world coordinates, independent of progress and language.  X is
-- prerequisite depth; Y is an authored chapter band plus a deterministic lane.
data GraphNode = GraphNode
  { gnDeck        :: !Deck
  , gnDepth       :: !Int
  , gnChapterIx   :: !Int
  , gnLane        :: !Int
  , gnX           :: !Int
  , gnY           :: !Int
  , gnMastery     :: !DeckMastery
  , gnRecommended :: !Bool
  } deriving Eq

data GraphEdge = GraphEdge
  { geFrom :: !Text
  , geTo   :: !Text
  } deriving (Eq, Show)

data MasteryGraph = MasteryGraph
  { mgNodes       :: [GraphNode]
  , mgEdges       :: [GraphEdge]
  , mgWorldWidth  :: !Int
  , mgWorldHeight :: !Int
  , mgRecommended :: !(Maybe Text)
  , mgBandCounts  :: !(Map MasteryBand Int)
  } deriving Eq

bandCount :: MasteryBand -> MasteryGraph -> Int
bandCount band = Map.findWithDefault 0 band . mgBandCounts

unDeckId :: DeckId -> Text
unDeckId (DeckId t) = t

unExId :: ExId -> Text
unExId (ExId t) = t

unPromptId :: PromptId -> Text
unPromptId (PromptId t) = t

uniqueInOrder :: Eq a => [a] -> [a]
uniqueInOrder = reverse . foldl' step []
  where
    step seen x = if x `elem` seen then seen else x : seen

promptBand :: Maybe Rec -> PromptBand
promptBand Nothing = PUnseen
promptBand (Just rec)
  | rcReps rec <= 0                         = PFragile
  | rcReps rec == 1 || rcInterval rec < 5   = PBuilding
  | otherwise                               = PDurable

buildMasteryGraph :: DayNum -> ProgressState -> [Deck] -> MasteryGraph
buildMasteryGraph today prog decks = MasteryGraph
  { mgNodes       = nodes
  , mgEdges       = edges
  , mgWorldWidth  = 220 + (maxDepth + 1) * 230
  , mgWorldHeight = 160 + length chapters * 350
  , mgRecommended = recommended
  , mgBandCounts  = foldl' countBand Map.empty masteries
  }
  where
    chapters = uniqueInOrder (map dkChapter decks)
    deckMap = Map.fromList [ (unDeckId (dkId d), d) | d <- decks ]
    depths = Map.fromList
      [ (unDeckId (dkId d), depthOf deckMap [] d) | d <- decks ]
    maxDepth = maximumOr 0 (Map.elems depths)
    masteries = map (masteryFor today prog deckMap) decks
    recommended = firstDue masteries `orElse` firstIncomplete masteries
    nodes = snd (foldl' (placeNode chapters depths recommended) (Map.empty, []) masteries)
    edges =
      [ GraphEdge req (unDeckId (dkId d))
      | d <- decks
      , req <- dkRequires d
      , Map.member req deckMap
      ]

    countBand acc dm = Map.insertWith (+) (dmBand dm) 1 acc
    firstDue = firstDeck ((> 0) . dmDue)
    firstIncomplete = firstDeck (\dm -> dmDone dm < dmExercises dm)
    firstDeck p = fmap (unDeckId . dkId . dmDeck) . find p

    orElse (Just x) _ = Just x
    orElse Nothing  y = y

maximumOr :: Ord a => a -> [a] -> a
maximumOr fallback [] = fallback
maximumOr _ xs = maximum xs

depthOf :: Map Text Deck -> [Text] -> Deck -> Int
depthOf deckMap visiting deck
  | slug `elem` visiting = 0
  | otherwise = case prereqDepths of
      [] -> 0
      ds -> 1 + maximum ds
  where
    slug = unDeckId (dkId deck)
    prereqDepths =
      [ depthOf deckMap (slug : visiting) reqDeck
      | req <- dkRequires deck
      , Just reqDeck <- [Map.lookup req deckMap]
      ]

masteryFor :: DayNum -> ProgressState -> Map Text Deck -> Deck -> DeckMastery
masteryFor today prog deckMap deck = DeckMastery
  { dmDeck       = deck
  , dmDone       = done
  , dmExercises  = exerciseTotal
  , dmPrompts    = length promptRecs
  , dmUnseen     = count PUnseen
  , dmFragile    = count PFragile
  , dmBuilding   = count PBuilding
  , dmDurable    = count PDurable
  , dmDue        = due
  , dmBand       = band
  , dmPrereqsMet = all prereqComplete (dkRequires deck)
  }
  where
    exercises = dkExercises deck
    exerciseTotal = length exercises
    done = length
      [ () | ex <- exercises, Map.findWithDefault 0 (unExId (exId ex)) (psDone prog) > 0 ]
    promptRecs =
      [ (promptBand rec, rec)
      | ex <- exercises
      , p <- exPrompts ex
      , let rec = Map.lookup (unPromptId (prId p)) (psRecs prog)
      ]
    count wanted = length [ () | (actual, _) <- promptRecs, actual == wanted ]
    due = length
      [ ()
      | (_, Just rec) <- promptRecs
      , rcDue rec <= today
      ]
    allExercisesDone = exerciseTotal > 0 && done >= exerciseTotal
    allPromptsDurable = not (null promptRecs) && count PDurable == length promptRecs
    anyEvidence = done > 0 || any (isJust . snd) promptRecs
    band
      | not anyEvidence      = MUnseen
      | not allExercisesDone = MLearning
      | not allPromptsDurable = MPracticed
      | due > 0              = MConsolidating
      | otherwise            = MStrong
    prereqComplete req = case Map.lookup req deckMap of
      Nothing -> False
      Just d  -> all (\ex -> Map.findWithDefault 0 (unExId (exId ex)) (psDone prog) > 0)
                     (dkExercises d)

placeNode
  :: [Text]
  -> Map Text Int
  -> Maybe Text
  -> (Map (Int, Int) Int, [GraphNode])
  -> DeckMastery
  -> (Map (Int, Int) Int, [GraphNode])
placeNode chapters depths recommended (lanes, placed) mastery =
  (Map.insert cell (lane + 1) lanes, placed ++ [node])
  where
    deck = dmDeck mastery
    slug = unDeckId (dkId deck)
    depth = Map.findWithDefault 0 slug depths
    chapterIx = indexOf 0 (dkChapter deck) chapters
    cell = (chapterIx, depth)
    lane = Map.findWithDefault 0 cell lanes
    node = GraphNode
      { gnDeck = deck
      , gnDepth = depth
      , gnChapterIx = chapterIx
      , gnLane = lane
      , gnX = 110 + depth * 230
      , gnY = 90 + chapterIx * 350 + lane * 56
      , gnMastery = mastery
      , gnRecommended = recommended == Just slug
      }

indexOf :: Eq a => Int -> a -> [a] -> Int
indexOf fallback needle haystack = go 0 haystack
  where
    go _ [] = fallback
    go n (x : xs) | x == needle = n
                  | otherwise   = go (n + 1) xs
