{-# LANGUAGE OverloadedStrings #-}

-- | Hand-written hash routing. Pure, total, no miso -- see
-- @briefs\/M1-plan.md@ 6. 'parseRoute' never throws, never calls 'read',
-- and accepts input with or without the leading @#@.
module SXC1.Route
  ( Route (..)
  , parseRoute
  , renderRoute
  ) where

import           Data.Maybe (fromMaybe)
import           Data.Text  (Text)
import qualified Data.Text  as T

data Route
  = RHome
  | RManual   !Text                -- ^ \"#/m/guide-book\"
  | RPage     !Text !Int !Bool     -- ^ \"#/m/guide-book/p/17\" (+ \"/ja\")
  | RNotFound !Text
  deriving (Eq, Show)

-- | Split on @\/@ after dropping a leading @#@, ignore empty segments,
-- accept only all-digit page numbers. Total: returns a value for any
-- input, never throws.
parseRoute :: Text -> Route
parseRoute raw = classify (nonEmptySegments (fromMaybe raw (T.stripPrefix "#" raw)))

nonEmptySegments :: Text -> [Text]
nonEmptySegments = filter (not . T.null) . T.splitOn "/"

classify :: [Text] -> Route
classify [] = RHome
classify ["m", slug] = RManual slug
classify ["m", slug, "p", nTxt] = case parseDigits nTxt of
  Just n  -> RPage slug n False
  Nothing -> notFound ["m", slug, "p", nTxt]
classify ["m", slug, "p", nTxt, "ja"] = case parseDigits nTxt of
  Just n  -> RPage slug n True
  Nothing -> notFound ["m", slug, "p", nTxt, "ja"]
classify segs = notFound segs

notFound :: [Text] -> Route
notFound segs = RNotFound (T.intercalate "/" segs)

-- | All-digit only; never negative, never calls 'read'.
--
-- NEW8: 'Int' is 32-bit on wasm32 (unlike a native x86_64 GHC), and the
-- previous version folded @acc * 10 + d@ directly in 'Int', unchecked.
-- @maxBound :: Int@ on wasm32 is 2 147 483 647 (2^31 - 1); the route
-- @#\/m\/guide-book\/p\/4294967297@ (2^32 + 1) wrapped straight back round
-- to @1@, so the overflow route rendered page 1 of 71 instead of the
-- not-found panel every other out-of-range page number correctly shows.
-- Folding in 'Integer' first (arbitrary precision, no wraparound
-- possible) and rejecting anything that would not fit back in 'Int'
-- fixes it without depending on any particular 'Int' width, and without
-- ever calling 'read' or risking a partial-parse exception.
parseDigits :: Text -> Maybe Int
parseDigits t
  | T.null t              = Nothing
  | not (T.all isDigitChar t) = Nothing
  | big > toInteger (maxBound :: Int) = Nothing
  | otherwise              = Just (fromInteger big)
  where
    big = T.foldl' (\acc c -> acc * 10 + toInteger (digitVal c)) (0 :: Integer) t
    isDigitChar c = c >= '0' && c <= '9'
    digitVal c    = fromEnum c - fromEnum '0'

-- | Always starts with @\"#/\"@.
renderRoute :: Route -> Text
renderRoute RHome            = "#/"
renderRoute (RManual slug)   = "#/m/" <> slug
renderRoute (RPage slug n ja) =
  "#/m/" <> slug <> "/p/" <> T.pack (show n) <> (if ja then "/ja" else "")
renderRoute (RNotFound path) = "#/" <> path
