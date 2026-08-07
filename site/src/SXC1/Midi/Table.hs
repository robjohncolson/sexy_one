{-# LANGUAGE OverloadedStrings #-}

-- | CI-ONLY: the freshly-parsed copy of @translations\/midi.md@'s
-- \"5. Note mapping\" table that @exercise-check --self-test@ compares,
-- cell by cell, against "SXC1.Midi.Spec"'s hand-transcribed literal
-- 'SXC1.Midi.Spec.padNoteTable'. This module is exposed from
-- @lib:sxc1-trainer@ so the test executable can import it, but it must
-- NOT be reachable from @exe:app@'s import graph -- the browser app
-- ships the literal table only, and the agreement between the two is
-- proven in CI, not at runtime.
--
-- The table is PARSED with M1's own block parser, exactly the way
-- "SXC1.Exercise.Verify".'SXC1.Exercise.Verify.buildMidiFacts' already
-- parses this same table (that module is frozen, so the small
-- section\/header\/label helpers are re-stated here rather than
-- exported from it). Only the \"Bank A\"..\"Bank D\" columns are kept;
-- the \"Active (receive only)\" column is ignored -- the device
-- receives those notes but never transmits them, so they can never
-- verify a drill.
module SXC1.Midi.Table
  ( parsePadNotes
  ) where

import           Data.Map.Strict       (Map)
import qualified Data.Map.Strict       as Map
import           Data.Text             (Text)
import qualified Data.Text             as T

import           SXC1.Content.Markdown (parseBlocksEngine)
import           SXC1.Content.Types    (Block (..), Inline)
import           SXC1.Exercise.Lint    (inlinesText)
import           SXC1.Route            (parseDigits)

-- | Parse the raw text of @translations\/midi.md@ into a
-- @(pad, bank) -> note@ map covering every numeric \"Bank A\"..\"Bank
-- D\" cell of the \"5. Note mapping\" table. On the committed source
-- this yields exactly 64 entries -- pads 1..16 across banks A..D --
-- including the deliberate Pad 2 \/ Bank C = 68 erratum (see
-- 'SXC1.Midi.Spec.padNoteTable').
parsePadNotes :: Text -> Map (Int, Char) Int
parsePadNotes raw = Map.fromList
  [ ((pad, bank), note)
  | Table mHeader rows <- noteSection
  , let bankCols = [ (i, c)
                   | (i, h) <- zip [0 :: Int ..] (headerTexts mHeader)
                   , Just c <- [parseHeaderBankLetter h]
                   ]
  , (padCell : restCells) <- rows
  , Just pad <- [parsePadLabel (inlinesText padCell)]
  , (colIdx, bank) <- bankCols
  , colIdx >= 1
  , Just note <- [cellNumAt restCells (colIdx - 1)]
  ]
  where
    (blocks, _) = parseBlocksEngine 0 False [] (T.lines raw)
    noteSection = sectionBlocks "5. Note mapping" blocks

headerTexts :: Maybe [[Inline]] -> [Text]
headerTexts = maybe [] (map inlinesText)

-- | The section of @blocks@ strictly between the (level <= 2) heading
-- whose flattened text is @titleText@ and the next (level <= 2)
-- heading, or @[]@ if no such heading is found -- the same shape
-- 'SXC1.Exercise.Verify.buildMidiFacts' uses.
sectionBlocks :: Text -> [Block] -> [Block]
sectionBlocks titleText blocks = case dropWhile notTarget blocks of
  []         -> []
  (_ : rest) -> takeWhile notNextSection rest
  where
    notTarget b = case b of
      Heading lvl inlines _ | lvl <= 2, T.strip (inlinesText inlines) == titleText -> False
      _ -> True
    notNextSection b = case b of
      Heading lvl _ _ | lvl <= 2 -> False
      _ -> True

-- | @\"Bank C\"@ -> @Just \'C\'@, restricted to the four transmit banks
-- A..D -- which is also what naturally excludes the
-- \"Active (receive only)\" column header.
parseHeaderBankLetter :: Text -> Maybe Char
parseHeaderBankLetter t = case T.stripPrefix "Bank " (T.strip t) of
  Just rest | T.length rest == 1, c <- T.head rest, c >= 'A', c <= 'D' -> Just c
  _ -> Nothing

-- | @\"Pad 13\"@ -> @Just 13@.
parsePadLabel :: Text -> Maybe Int
parsePadLabel t = case T.stripPrefix "Pad " (T.strip t) of
  Just rest -> parseDigits (T.strip rest)
  Nothing   -> Nothing

-- | The numeric value of cell @i@ of a row's non-label cells, if the
-- row is wide enough and the cell is a number.
cellNumAt :: [[Inline]] -> Int -> Maybe Int
cellNumAt cells i
  | i >= 0 && i < length cells = parseDigits (T.strip (inlinesText (cells !! i)))
  | otherwise                  = Nothing
