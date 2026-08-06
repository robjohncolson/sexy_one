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
parseDigits :: Text -> Maybe Int
parseDigits t
  | T.null t          = Nothing
  | T.all isDigitChar t = Just (T.foldl' (\acc c -> acc * 10 + digitVal c) 0 t)
  | otherwise          = Nothing
  where
    isDigitChar c = c >= '0' && c <= '9'
    digitVal c    = fromEnum c - fromEnum '0'

-- | Always starts with @\"#/\"@.
renderRoute :: Route -> Text
renderRoute RHome            = "#/"
renderRoute (RManual slug)   = "#/m/" <> slug
renderRoute (RPage slug n ja) =
  "#/m/" <> slug <> "/p/" <> T.pack (show n) <> (if ja then "/ja" else "")
renderRoute (RNotFound path) = "#/" <> path
