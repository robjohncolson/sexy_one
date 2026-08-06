{-# LANGUAGE OverloadedStrings #-}

-- | Hand-written hash routing. Pure, total, no miso -- see
-- @briefs\/M1-plan.md@ 6. 'parseRoute' never throws, never calls 'read',
-- and accepts input with or without the leading @#@.
module SXC1.Route
  ( Route (..)
  , parseRoute
  , renderRoute
  , parseDigits
  ) where

import           Data.Maybe (fromMaybe)
import           Data.Text  (Text)
import qualified Data.Text  as T

data Route
  = RHome
  | RManual    !Text               -- ^ \"#/m/guide-book\"
  | RPage      !Text !Int !Bool    -- ^ \"#/m/guide-book/p/17\" (+ \"/ja\")
  | RExercises                     -- ^ \"#/x\" (M2)
  | RDeck      !Text               -- ^ \"#/x/\<deck\>\" (M2)
  | RExercise  !Text !Text         -- ^ \"#/x/\<deck\>/\<ex\>\" (M2)
  | RNotFound !Text
  deriving (Eq, Show)

-- | Split on @\/@ after dropping a leading @#@, and REJECT (as
-- 'RNotFound', never by throwing) any input whose segments -- once the
-- one leading empty component the leading @\/@ itself always produces is
-- dropped -- still contain an empty component: @#\/x\/\/a@,
-- @#\/x\/a\/\/b@ and any other doubled or trailing @\/@ all fail to
-- classify, rather than silently collapsing (L3 gate finding: the OLD
-- 'nonEmptySegments' filtered out EVERY empty component wherever it
-- occurred, so @#\/x\/\/preparation-power\/q-1-03@ classified exactly
-- like @#\/x\/preparation-power\/q-1-03@ and rendered the exercise
-- instead of the not-found panel). Total: returns a value for any input,
-- never throws, never calls 'read'.
parseRoute :: Text -> Route
parseRoute raw = case segmentsOf stripped of
  Just segs -> classify segs
  -- Path text carries no leading "/" (renderRoute's RNotFound case adds
  -- exactly one), matching every other 'notFound' call in 'classify' --
  -- this makes "#/x//a" round-trip back to itself via 'renderRoute'
  -- instead of picking up a doubled leading slash.
  Nothing   -> RNotFound (fromMaybe stripped (T.stripPrefix "/" stripped))
  where
    stripped = fromMaybe raw (T.stripPrefix "#" raw)

-- | @Nothing@ if the text has a leading @\/@ but any segment after it is
-- empty (a doubled or trailing @\/@); @Just@ the segments otherwise.
-- Three "no real segments" shapes all give @Just []@ ('RHome', M1's
-- original behaviour, kept exactly): a bare @\"\"@ or @\"#\"@ (no
-- leading @\/@ at all -- 'T.stripPrefix' fails, and the text itself is
-- empty), and the canonical bare root @\"#\/\"@ (stripping its one
-- leading @\/@ leaves @\"\"@). This is deliberately NOT
-- @'T.splitOn' \"\/\" t@'s naive leading-empty-then-null-check: for
-- @t = \"\/\"@ that splits to @[\"\",\"\"]@, and a NAIVE check (drop the
-- first \"\", then reject if any of the rest is null) wrongly rejects the
-- bare root too, because its OWN trailing empty is indistinguishable
-- from a genuine trailing-@\/@-after-content one under that scheme --
-- exactly the H1-sibling regression this 'stripPrefix'-first version
-- avoids.
segmentsOf :: Text -> Maybe [Text]
segmentsOf t = case T.stripPrefix "/" t of
  Nothing              -> if T.null t then Just [] else Nothing
  Just rest | T.null rest -> Just []
            | otherwise    ->
                let segs = T.splitOn "/" rest
                in if any T.null segs then Nothing else Just segs

-- | @[a-z0-9-]+@ -- the shape every real route id (manual slug, deck
-- slug, exercise id) is already required to match at the CONTENT layer
-- (see "SXC1.Exercise.Parse"'s @isSlugLike@); rejecting anything else
-- here too (L3) means @#\/x\/A B\/c@ classifies as 'RNotFound' instead
-- of silently accepting a segment no real content id could ever be.
isRouteId :: Text -> Bool
isRouteId t = not (T.null t) && T.all isRouteIdChar t
  where
    isRouteIdChar c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'

classify :: [Text] -> Route
classify [] = RHome
classify ["m", slug] | isRouteId slug = RManual slug
classify ["m", slug, "p", nTxt] | isRouteId slug = case parseDigits nTxt of
  Just n  -> RPage slug n False
  Nothing -> notFound ["m", slug, "p", nTxt]
classify ["m", slug, "p", nTxt, "ja"] | isRouteId slug = case parseDigits nTxt of
  Just n  -> RPage slug n True
  Nothing -> notFound ["m", slug, "p", nTxt, "ja"]
-- M2: the exercise engine's own three routes. NOTE (probe P-M): before
-- these clauses existed, "#/x", "#/x/deck" and "#/x/deck/ex" ALREADY
-- round-tripped through 'renderRoute' . 'parseRoute' as 'RNotFound',
-- because @renderRoute (RNotFound p) = \"#/\" <> p@ -- so a bare
-- round-trip assertion over these three strings is VACUOUS and proves
-- nothing about whether this clause is even reached; the self-test must
-- assert the CONSTRUCTOR (@parseRoute \"#/x\" == RExercises@) and carry a
-- negative control that it is NOT 'RNotFound'.
classify ["x"] = RExercises
classify ["x", deck] | isRouteId deck = RDeck deck
classify ["x", deck, ex] | isRouteId deck, isRouteId ex = RExercise deck ex
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
renderRoute RExercises            = "#/x"
renderRoute (RDeck deck)          = "#/x/" <> deck
renderRoute (RExercise deck exId) = "#/x/" <> deck <> "/" <> exId
renderRoute (RNotFound path) = "#/" <> path
