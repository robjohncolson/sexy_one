{-# LANGUAGE OverloadedStrings #-}

-- | The parsed, lazy exercise corpus, plus the DOM contract's
-- @#sxc1-exercise-stats@ JSON -- the stale-build detector. M6 W1
-- (briefs\/M6-plan.md, ruling 1): the corpus is no longer a
-- compile-time-embedded constant ("Exercises.Embed" is retired) --
-- every projection here is now a pure FUNCTION of the deck sources the
-- boot path loaded through "Exercises.Bundle", applied exactly once in
-- Main.main and shared from there. Reads still never touch disk.
--
-- M3 gate (briefs\/M3-manifest.json, task \"size-split-and-format\"):
-- reads via 'SXC1.Exercise.Reader.readDeck' -- the STRUCTURAL reader --
-- rather than the validating 'SXC1.Exercise.Parse.parseDeck', which this
-- module (and everything reachable from @exe:app@) must never import.
-- See "SXC1.Exercise.Reader"'s Haddock for the size history.
module Exercises.Corpus
  ( exerciseCorpusOf
  , checkedCorpusOf
  , exerciseStatsJsonOf
  , fnv1a32
    -- * Tiny JSON combinators, reused verbatim by Main.hs's event-log
    -- encoder rather than duplicated (see this module's Haddock).
  , jStr
  , jArr
  , jInt
  , jInteger
  , jKV
  , jObj
  , jBool
  ) where

import           Data.Bits           (shiftR, xor, (.&.), (.|.))
import           Data.Char           (ord)
import qualified Data.Text           as T
import           Data.Text           (Text)
import           Data.Word           (Word32)

import           Exercises.Manifest   (manifestDeckCount, manifestExercises, manifestPrompts)
import           SXC1.Content.Stats   (jsonEscape)
import           SXC1.Exercise.Reader (readDeck)
import           SXC1.Exercise.Types

--------------------------------------------------------------------------
-- The parsed corpus. LAZY exactly as M1's manual corpus is (see
-- SXC1.Content.Corpus.docs): matching 'Just d' only forces 'parseDeck'
-- to WHNF, never any individual 'Block' or prompt inside the resulting
-- 'Deck' -- those stay unevaluated thunks until a view actually demands
-- them.
--------------------------------------------------------------------------

-- | (file name, raw bundle text, parsed 'Deck' if any), in INDEX
-- order -- the one place that keeps a deck's raw source paired with its
-- parse, for 'exerciseStatsJsonOf' below.
parsedDecksOf :: [(FilePath, Text)] -> [(FilePath, Text, Maybe Deck)]
parsedDecksOf srcs = [ (fp, raw, readDeck fp raw) | (fp, raw) <- srcs ]

-- | The unchecked projection, kept for 'exerciseStatsJsonOf' (which
-- must be able to describe a corpus warts and all). Every LIVE path
-- goes through 'checkedCorpusOf' instead.
exerciseCorpusOf :: [(FilePath, Text)] -> [Deck]
exerciseCorpusOf srcs = [ d | (_, _, Just d) <- parsedDecksOf srcs ]

-- | THE PARSE HALF OF ALL-OR-NOTHING BUNDLE ACCEPTANCE (M6 gate round
-- 1, finding M6-R1-1c\/d). 'exerciseCorpusOf' above DROPS a deck whose
-- 'readDeck' returned 'Nothing', which meant a bundle whose framing was
-- perfect but whose final deck was truncated mid-exercise produced a
-- SMALLER corpus and no error at all -- retired-looking progress
-- records and a quietly shorter course. Here a parse failure is a hard,
-- deck-NAMING error, and the corpus must additionally agree with this
-- build's "Exercises.Manifest" on all three aggregate counts and carry
-- no duplicate deck id. Any violation returns 'Left', which Main turns
-- into the same visible alert\/retry state a failed fetch produces.
checkedCorpusOf :: [(FilePath, Text)] -> Either Text [Deck]
checkedCorpusOf srcs = do
  decks <- mapM parseOne srcs
  noDuplicateIds (map dkId decks)
  let exs     = concatMap dkExercises decks
      prompts = concatMap exPrompts exs
  expect "deck"     manifestDeckCount (length decks)
  expect "exercise" manifestExercises (length exs)
  expect "prompt"   manifestPrompts   (length prompts)
  Right decks
  where
    parseOne (fp, raw) = case readDeck fp raw of
      Just d  -> Right d
      Nothing -> Left ("content bundle deck '" <> T.pack fp
                         <> "' does not parse (truncated or corrupted body)")

    tshow :: Int -> Text
    tshow = T.pack . show

    expect what want got
      | want == got = Right ()
      | otherwise   = Left ("content bundle carries " <> tshow got <> " " <> what
                              <> "(s); this build expects " <> tshow want)

    noDuplicateIds ids = go [] ids
      where
        go _    []       = Right ()
        go seen (i : is)
          | i `elem` seen = Left ("content bundle repeats deck id '" <> unDeckId i <> "'")
          | otherwise     = go (i : seen) is

--------------------------------------------------------------------------
-- FNV-1a/32 over the UTF-8 BYTES of a 'Text' -- hand-rolled because
-- neither 'Data.ByteString' nor 'Data.Text.Encoding' is reachable from
-- exe:app (build-depends discipline): this walks 'Text' directly
-- with 'Data.Text.foldl'' and encodes each 'Char' to its UTF-8 byte
-- sequence by hand (both 'Data.Bits' and 'Data.Char' are re-exported by
-- @base@, already a dependency). Pinned against the test vectors in
-- briefs/M2-manifest.json (task "exercise-ui"):
--   ""               -> 2166136261
--   "a"               -> 3826002220
--   "hello"           -> 1335831723
--   "# Deck" <> LF   -> 647974047
--   "SELECT BANK 1"  -> 1835518890
--   "Part: Pad play" -> 3412542811
--   U+2295 U+2296     -> 3369799694
--------------------------------------------------------------------------

fnvOffsetBasis :: Word32
fnvOffsetBasis = 2166136261

fnvPrime :: Word32
fnvPrime = 16777619

-- | UTF-8 byte sequence of a single code point, most-significant byte
-- first -- exactly what 'Data.Text.Encoding.encodeUtf8' would produce,
-- computed without it.
utf8Bytes :: Char -> [Word32]
utf8Bytes c
  | cp < 0x80    = [ cp ]
  | cp < 0x800   = [ 0xC0 .|. (cp `shiftR` 6)
                    , 0x80 .|. (cp .&. 0x3F)
                    ]
  | cp < 0x10000 = [ 0xE0 .|. (cp `shiftR` 12)
                    , 0x80 .|. ((cp `shiftR` 6) .&. 0x3F)
                    , 0x80 .|. (cp .&. 0x3F)
                    ]
  | otherwise    = [ 0xF0 .|. (cp `shiftR` 18)
                    , 0x80 .|. ((cp `shiftR` 12) .&. 0x3F)
                    , 0x80 .|. ((cp `shiftR` 6) .&. 0x3F)
                    , 0x80 .|. (cp .&. 0x3F)
                    ]
  where
    cp = fromIntegral (ord c) :: Word32

fnv1a32 :: Text -> Word32
fnv1a32 = T.foldl' stepChar fnvOffsetBasis
  where
    stepChar acc c = foldl' stepByte acc (utf8Bytes c)
    stepByte acc byte = (acc `xor` byte) * fnvPrime

--------------------------------------------------------------------------
-- #sxc1-exercise-stats: {"totals": {...}, "decks": [...]}. A hand-rolled
-- encoder in the same small combinator style as
-- SXC1.Exercise.Report.renderReport / SXC1.Content.Stats.renderStatsJson
-- -- REUSES 'jsonEscape' from SXC1.Content.Stats rather than writing a
-- second escaper, per that module's own Haddock instruction.
--------------------------------------------------------------------------

jStr :: Text -> Text
jStr t = "\"" <> jsonEscape t <> "\""

jArr :: [Text] -> Text
jArr xs = "[" <> T.intercalate "," xs <> "]"

jInt :: Int -> Text
jInt = T.pack . show

-- | For 'Integer' values that must NOT be narrowed to 'Int' first --
-- 'Int' is 32-bit on wasm32 (M1's NEW8; see "SXC1.Route".'SXC1.Route.parseDigits'),
-- and a wall-clock epoch-millisecond value is already far outside that
-- range in 2026, so 'jInt' would silently wrap it.
jInteger :: Integer -> Text
jInteger = T.pack . show

jWord32 :: Word32 -> Text
jWord32 = T.pack . show

jKV :: Text -> Text -> Text
jKV k v = jStr k <> ":" <> v

jObj :: [Text] -> Text
jObj kvs = "{" <> T.intercalate "," kvs <> "}"

jBool :: Bool -> Text
jBool True  = "true"
jBool False = "false"

unDeckId :: DeckId -> Text
unDeckId (DeckId t) = t

-- | Deliberately NOT 'SXC1.Exercise.Report.buildTotals': that function
-- lives in the same module (no @-split-sections@ in the committed cabal
-- file, so a module is linked as one atomic unit) as the 39-constructor
-- 'SXC1.Exercise.Report.IssueCode' enum and its DERIVED 'Show' instance
-- -- exactly the "well-known wasm code-size cost" "SXC1.Exercise.Types"'s
-- own Haddock warns about, just paid on a type this module never
-- otherwise touches. MEASURED: importing 'SXC1.Exercise.Report' at all
-- cost app.wasm several tens of KB of gzip size for six integers this
-- module can trivially recompute itself (see this task's final report).
totalsJson :: [Deck] -> Text
totalsJson decks = jObj
  [ jKV "decks"     (jInt (length decks))
  , jKV "exercises" (jInt (length exs))
  , jKV "prompts"   (jInt (length prompts))
  , jKV "quiz"      (jInt (length [ () | e <- exs, exKind e == KQuiz ]))
  , jKV "drill"     (jInt (length [ () | e <- exs, exKind e == KDrill ]))
  , jKV "lookup"    (jInt (length [ () | e <- exs, exKind e == KLookup ]))
  ]
  where
    exs     = concatMap dkExercises decks
    prompts = concatMap exPrompts exs

-- | Per-deck: identity, size (from the parse, when it succeeded), and
-- the three LOADED-source integrity numbers (from the raw bundle text
-- regardless of parse success, so a genuinely broken deck still shows
-- up here rather than vanishing silently). Because the EN bundle's
-- per-deck text is byte-identical to the deck's on-disk EN emission,
-- chars/lines/fnv1a keep matching the harness's disk-derived numbers
-- -- the stale-BUNDLE detector, exactly as they were the stale-BUILD
-- detector when the corpus was embedded.
deckStatsJson :: (FilePath, Text, Maybe Deck) -> Text
deckStatsJson (fp, raw, mDeck) = jObj
  [ jKV "file"      (jStr (T.pack fp))
  , jKV "deck"      (jStr (maybe "" (unDeckId . dkId) mDeck))
  , jKV "chapter"   (jStr (maybe "" dkChapter mDeck))
  , jKV "title"     (jStr (maybe "" dkTitle mDeck))
  , jKV "exercises" (jInt (maybe 0 (length . dkExercises) mDeck))
  , jKV "prompts"   (jInt (maybe 0 (sum . map (length . exPrompts) . dkExercises) mDeck))
  , jKV "chars"     (jInt (T.length raw))
  , jKV "lines"     (jInt (length (T.splitOn "\n" raw)))
  , jKV "fnv1a"     (jWord32 (fnv1a32 raw))
  ]

exerciseStatsJsonOf :: [(FilePath, Text)] -> Text
exerciseStatsJsonOf srcs = jObj
  [ jKV "totals" (totalsJson (exerciseCorpusOf srcs))
  , jKV "decks"  (jArr (map deckStatsJson (parsedDecksOf srcs)))
  ]
