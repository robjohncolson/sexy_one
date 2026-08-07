{-# LANGUAGE OverloadedStrings #-}

-- | The versioned wire format for a learner's saved progress, the
-- migration mechanism, and the (separately-keyed, separately-decoded)
-- reader-preference blob. See "SXC1.Progress.Types" for the module-wide
-- purity discipline this module inherits exactly: no IO, no @Miso@, no
-- clock reads -- 'encodeState'\/'decodeState'\/'exportBlob'\/'importBlob'
-- are pure 'Text' functions, and the ONE module allowed to actually read
-- or write @localStorage@ with them is "SXC1.Progress.Store" (M3 wave
-- 3), owned by a different task.
--
-- WIRE FORMAT. Line-oriented, tab-separated, ASCII, NOT JSON: the app
-- has a hand-rolled JSON ENCODER ("SXC1.Content.Stats".'jsonEscape' and
-- the @jStr@\/@jArr@\/... combinators elsewhere) and no JSON DECODER, and
-- every field in this format is an 'Int' or an already-slug-shaped id --
-- nothing to quote, nothing to escape -- so the reader is a
-- @'T.splitOn' \"\\t\"@ fold with strictly fewer failure modes than
-- linking a JSON parser would have.
--
-- > SXC1PROGRESS <TAB> <schemaVersion>          -- currently 2
-- > M <TAB> streakDay <TAB> streakLen <TAB> firstDay <TAB> lastPrompt   -- v2; v1 had no lastPrompt
-- > R <TAB> promptId <TAB> reps <TAB> lapses <TAB> ease <TAB> interval <TAB> due <TAB> lastSeen <TAB> seen
-- > D <TAB> exerciseId <TAB> completions
--
-- Unknown leading tags are SKIPPED, not rejected, so a newer schema's
-- extra record types degrade to \"ignored\" in an older build rather
-- than discarding a whole history. Integers are parsed with
-- "SXC1.Route".'SXC1.Route.parseDigits' (never @read@).
--
-- THE THREE-WAY 'DecodeResult' SPLIT IS LOAD-BEARING. A learner's
-- history is the one thing in this app that cannot be regenerated, so
-- \"I could not read it\" ('DecodeCorrupt') must never be
-- indistinguishable from \"there was nothing to read\" ('DecodeEmpty') --
-- a 'Maybe' would let the first case be silently overwritten by the next
-- write. A blob whose version EXCEEDS 'currentSchema' is always
-- 'DecodeCorrupt', never read as current.
--
-- TWO DELIBERATE ASYMMETRIES BETWEEN THE PROGRESS CODEC AND THE PREFS
-- CODEC (both required, both documented here rather than only in the
-- manifest):
--
--   1. 'decodePrefs' returns a bare 'Prefs', never a 'DecodeResult'. An
--      unreadable PREFERENCE blob falls back to 'defaultPrefs' and MAY
--      be overwritten on the next save, because a preference is
--      trivially regenerable (the learner flips one switch). An
--      unreadable PROGRESS blob is never overwritten, because a
--      history cannot be regenerated.
--   2. The reader preference lives under a SEPARATE storage key
--      (@sxc1.prefs@, via a distinct @SXC1PREFS@ magic string), never as
--      a field on 'ProgressState' itself. A corrupt progress blob must
--      still leave the reading preference settable -- wiping progress
--      must not wipe the reading preference -- which a shared record
--      could not guarantee.
--
-- COST DISCIPLINE (briefs\/M3-plan.md \167 4.5, Q-M): a naive
-- second-magic-string\/second-decoder\/second-store-pair implementation
-- of the prefs feature measured +5,936 gzip bytes on its own. This
-- module instead shares ONE line-oriented tag\/key\/value splitter
-- ('tagFields') between both blobs -- the prefs half adds only a magic
-- string, a two-field record and an encoder, never a second parser.
module SXC1.Progress.Codec
  ( currentSchema
  , DecodeResult (..)
  , encodeState
  , decodeState
  , migrateWith
  , migrate
  , productionSteps
  , exportBlob
  , importBlob
  , jsonUnescape
  , Prefs (..)
  , defaultPrefs
  , prefsSchema
  , encodePrefs
  , decodePrefs
  ) where

import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map
import           Data.Text              (Text)
import qualified Data.Text              as T

import           SXC1.Content.Stats     (jsonEscape)
import           SXC1.Progress.Scheduler (easeMax, easeMin)
import           SXC1.Progress.Types
import           SXC1.Route             (parseDigits)

--------------------------------------------------------------------------
-- The shared line-oriented splitter (Q-M's cost fix): every wire line,
-- progress or prefs, is @tag <TAB> field <TAB> field ...@. This is the
-- ONLY place either codec ever calls 'T.splitOn' on a wire line.
--------------------------------------------------------------------------

tagFields :: Text -> (Text, [Text])
tagFields line = case T.splitOn "\t" line of
  []       -> ("", [])
  (t : fs) -> (t, fs)

tshow :: Int -> Text
tshow = T.pack . show

--------------------------------------------------------------------------
-- Progress: schema, DecodeResult, encode/decode
--------------------------------------------------------------------------

currentSchema :: Int
currentSchema = 2

magicProgress :: Text
magicProgress = "SXC1PROGRESS"

-- | @DecodeEmpty@: nothing was stored (never overwrite-on-corrupt with
-- this). @DecodeOk@: a well-formed, current-schema state.
-- @DecodeCorrupt reason@: something was stored and could not be read --
-- the caller MUST NOT discard it. See the module Haddock.
data DecodeResult
  = DecodeEmpty
  | DecodeOk !ProgressState
  | DecodeCorrupt !Text
  deriving Eq

encodeState :: ProgressState -> Text
encodeState st = T.unlines (headerLine : mLine : rLines ++ dLines)
  where
    headerLine = T.intercalate "\t" [magicProgress, tshow currentSchema]
    mLine = T.intercalate "\t"
      [ "M", tshow (unDayNum (psStreakDay st)), tshow (psStreakLen st), tshow (unDayNum (psFirstDay st))
      , psLastPrompt st ]  -- v2: lastPrompt column (may be empty; slug-shaped, tab-free)
    rLines = [ rLine pid rc | (pid, rc) <- Map.toList (psRecs st) ]
    rLine pid rc = T.intercalate "\t"
      [ "R", pid, tshow (rcReps rc), tshow (rcLapses rc), tshow (rcEase rc), tshow (rcInterval rc)
      , tshow (unDayNum (rcDue rc)), tshow (unDayNum (rcLastSeen rc)), tshow (rcSeen rc)
      ]
    dLines = [ T.intercalate "\t" [ "D", eid, tshow n ] | (eid, n) <- Map.toList (psDone st) ]

-- | Accumulates the body (everything after the header line) leniently:
-- an unrecognised leading tag, or a record whose field count or field
-- shapes don't parse, is SKIPPED -- the rest of the blob still decodes
-- (manifest requirement: an unknown tag and a truncated @R@ line each
-- lose only themselves, never the sibling records).
data BodyAcc = BodyAcc
  { baStreakDay :: !DayNum
  , baStreakLen :: !Int
  , baFirstDay  :: !DayNum
  , baLastPrompt :: !Text
  , baRecs      :: !(Map Text Rec)
  , baDone      :: !(Map Text Int)
  }

emptyBodyAcc :: BodyAcc
emptyBodyAcc = BodyAcc (DayNum 0) 0 (DayNum 0) "" Map.empty Map.empty

clampDay :: Int -> DayNum
clampDay = DayNum . min dayCap

parseBodyLine :: BodyAcc -> Text -> BodyAcc
parseBodyLine acc line
  | T.null (T.strip line) = acc
  | otherwise = case tagFields line of
      -- v1 M line: three fields (lastPrompt stays ""); v2: four. NEW16:
      -- the metadata fields clamp into their semantic domains exactly
      -- like the R fields below -- an imported streakDay near maxBound
      -- would otherwise overflow bumpStreak's +1 on wasm32.
      ("M", [sdTxt, slTxt, fdTxt])
        | Just sd <- parseDigits sdTxt, Just sl <- parseDigits slTxt, Just fd <- parseDigits fdTxt
        -> acc { baStreakDay = clampDay sd, baStreakLen = min 1000000 sl, baFirstDay = clampDay fd }
      ("M", [sdTxt, slTxt, fdTxt, lp])
        | Just sd <- parseDigits sdTxt, Just sl <- parseDigits slTxt, Just fd <- parseDigits fdTxt
        -> acc { baStreakDay = clampDay sd, baStreakLen = min 1000000 sl, baFirstDay = clampDay fd, baLastPrompt = lp }
      -- M3 re-gate NEW1 (residual): every ACCEPTED numeric field is
      -- clamped into its semantic domain on decode -- an imported blob
      -- can carry any Int-sized value parseDigits admits, and an
      -- unclamped interval/ease would overflow the scheduler's Int
      -- multiplies (interval * ease) on wasm32 exactly like the
      -- max-day path did. Clamping (not rejecting) preserves history.
      ("R", [pid, repsT, lapT, easeT, intT, dueT, lastT, seenT])
        | Just reps <- parseDigits repsT, Just lap <- parseDigits lapT, Just ease <- parseDigits easeT
        , Just intv <- parseDigits intT, Just due <- parseDigits dueT, Just lastSeen <- parseDigits lastT
        , Just seen <- parseDigits seenT
        -> let cnt  = min 1000000
               day' = DayNum . min dayCap
               rec' = Rec (cnt reps) (cnt lap)
                          (max easeMin (min easeMax ease))
                          (max 0 (min 180 intv))
                          (day' due) (day' lastSeen) (cnt seen)
           in acc { baRecs = Map.insert pid rec' (baRecs acc) }
      ("D", [eid, nTxt])
        | Just n <- parseDigits nTxt
        -> acc { baDone = Map.insert eid (min 1000000 n) (baDone acc) }
      _ -> acc

-- | Decode one stored progress blob. Empty\/whitespace-only input is
-- 'DecodeEmpty'; a missing or malformed @SXC1PROGRESS@ header, or a
-- version that does not migrate cleanly to 'currentSchema' (below 1, or
-- above 'currentSchema'), is 'DecodeCorrupt'. Otherwise the body is
-- parsed leniently ('parseBodyLine') and threaded through 'migrate'.
decodeState :: Text -> DecodeResult
decodeState raw
  | T.null (T.strip raw) = DecodeEmpty
  | otherwise = case T.lines raw of
      []                       -> DecodeEmpty
      (headerLine : bodyLines) -> case tagFields headerLine of
        (tag, [verTxt]) | tag == magicProgress -> case parseDigits verTxt of
          Nothing -> DecodeCorrupt "malformed schema version in SXC1PROGRESS header"
          Just v  ->
            let acc = foldl' parseBodyLine emptyBodyAcc bodyLines
                st = ProgressState
                  { psVersion   = SchemaVersion v
                  , psRecs      = baRecs acc
                  , psDone      = baDone acc
                  , psStreakDay = baStreakDay acc
                  , psStreakLen = baStreakLen acc
                  , psFirstDay  = baFirstDay acc
                  , psLastPrompt = baLastPrompt acc
                  }
            in migrate v st
        _ -> DecodeCorrupt "missing or malformed SXC1PROGRESS header"

--------------------------------------------------------------------------
-- Migration
--------------------------------------------------------------------------

-- | Walk @v -> v+1 -> ... -> 'currentSchema'@, applying @stepTable n@ at
-- each hop. A version already at (or somehow past validation and still
-- greater than) 'currentSchema' is 'DecodeCorrupt' -- never read as
-- current. A hop with no step in the table is 'DecodeCorrupt' (the
-- history cannot be silently dropped). THE PARAMETERISATION IS THE WHOLE
-- POINT: production code always calls 'migrate' (= @migrateWith
-- 'productionSteps'@, which since v2 carries its first real step), but
-- the self-test also drives 'migrateWith' directly with a TEST-ONLY step
-- table over a synthetic schema-0 state -- the mechanism was genuinely
-- exercised before any production step existed, which is why v1 -> v2
-- needed no new machinery.
migrateWith :: (Int -> Maybe (ProgressState -> ProgressState)) -> Int -> ProgressState -> DecodeResult
migrateWith stepTable v st
  | v > currentSchema  = DecodeCorrupt ("schema version " <> tshow v <> " is newer than this build supports (max " <> tshow currentSchema <> ")")
  | v == currentSchema = DecodeOk (st { psVersion = SchemaVersion currentSchema })
  | otherwise = case stepTable v of
      Just step -> migrateWith stepTable (v + 1) (step st)
      Nothing   -> DecodeCorrupt ("no migration step from schema " <> tshow v <> " to " <> tshow (v + 1))

migrate :: Int -> ProgressState -> DecodeResult
migrate = migrateWith productionSteps

-- | The real, shipped migration steps. First production use at v2
-- (M3 gate NEW12): v1 -> v2 adds 'psLastPrompt', which the body parser
-- already defaults to empty for a three-field v1 M line, so the step is
-- the identity -- the mechanism, exercised generically by tests since
-- v1, carried its first real migration without modification.
productionSteps :: Int -> Maybe (ProgressState -> ProgressState)
productionSteps 1 = Just id  -- v1 -> v2: psLastPrompt joins, defaulted "" by the body parser
productionSteps _ = Nothing

--------------------------------------------------------------------------
-- Export / import envelope
--------------------------------------------------------------------------

-- | @{"format":"sxc1-progress","schema":<n>,"exportedAt":"<stamp>","payload":"<wire text>"}@
-- -- the payload is the SAME text 'encodeState' produces, so there is one
-- format to keep correct. Reuses "SXC1.Content.Stats".'jsonEscape' rather
-- than adding a second JSON encoder (this is fixed-shape string
-- interpolation, not a general encoder).
exportBlob :: Text -> ProgressState -> Text
exportBlob stamp st = T.concat
  [ "{\"format\":\"sxc1-progress\",\"schema\":", tshow currentSchema
  , ",\"exportedAt\":\"", jsonEscape stamp
  , "\",\"payload\":\"", jsonEscape (encodeState st), "\"}"
  ]

-- | Accepts EITHER the envelope above OR a bare wire blob (text starting
-- with @SXC1PROGRESS@ once leading\/trailing whitespace is trimmed), so
-- a learner who copies only the inner text still recovers their
-- history. For the envelope case, only enough of the JSON is read to
-- pull the @payload@ string field back out ('extractJsonStringField') --
-- not a general JSON parser, matching 'exportBlob''s "one format" note.
importBlob :: Text -> DecodeResult
importBlob raw
  | magicProgress `T.isPrefixOf` trimmed = decodeState trimmed
  | otherwise = case extractJsonStringField "payload" raw of
      Just payload -> decodeState (jsonUnescape payload)
      Nothing      -> DecodeCorrupt "import text is neither a bare SXC1PROGRESS blob nor a recognisable export envelope"
  where
    trimmed = T.strip raw

-- | The text right after @"payload":"@ up to (not including) the next
-- UNESCAPED double quote, or 'Nothing' if @key@'s marker is absent or
-- the string is left unterminated.
extractJsonStringField :: Text -> Text -> Maybe Text
extractJsonStringField key raw
  | T.null afterMarker = Nothing
  | otherwise           = takeJsonStringBody (T.drop (T.length marker) afterMarker)
  where
    marker = "\"" <> key <> "\":\""
    (_, afterMarker) = T.breakOn marker raw

takeJsonStringBody :: Text -> Maybe Text
takeJsonStringBody = fmap T.pack . go . T.unpack
  where
    go []               = Nothing          -- unterminated string
    go ('"' : _)         = Just []
    go ('\\' : c : rest) = (\r -> '\\' : c : r) <$> go rest
    go ['\\']            = Nothing          -- trailing lone backslash
    go (c : rest)        = (c :) <$> go rest

-- | Undo 'jsonEscape': @\\"@, @\\\\@, @\\n@, @\\r@, @\\t@ -> the literal
-- character; any other backslash-escape is passed through unchanged
-- (lenient -- this is not a general JSON string decoder, only the
-- inverse of the exact five escapes 'jsonEscape' ever produces).
jsonUnescape :: Text -> Text
jsonUnescape = T.pack . unescList . T.unpack
  where
    unescList []               = []
    unescList ('\\' : c : rest) = unescapeChar c : unescList rest
    unescList ['\\']            = ['\\']
    unescList (c : rest)        = c : unescList rest

unescapeChar :: Char -> Char
unescapeChar '"'  = '"'
unescapeChar '\\' = '\\'
unescapeChar 'n'  = '\n'
unescapeChar 'r'  = '\r'
unescapeChar 't'  = '\t'
unescapeChar c    = c

--------------------------------------------------------------------------
-- The reader-preference blob -- see the module Haddock's two asymmetries.
--------------------------------------------------------------------------

magicPrefs :: Text
magicPrefs = "SXC1PREFS"

prefsSchema :: Int
prefsSchema = 1

data Prefs = Prefs { prfJaFirst :: !Bool }
  deriving Eq

-- | @jaFirst = False@ -- OFF by default, which is the safety property
-- the whole JA-first feature rests on: a fresh profile behaves
-- byte-identically to before the feature existed. Sabotage-checked in
-- @exe:progress-check --self-test@ group 10: flipping this literal to
-- 'True' must fail that group.
defaultPrefs :: Prefs
defaultPrefs = Prefs { prfJaFirst = False }

encodePrefs :: Prefs -> Text
encodePrefs p = T.unlines
  [ T.intercalate "\t" [magicPrefs, tshow prefsSchema]
  , T.intercalate "\t" ["P", "jaFirst", if prfJaFirst p then "1" else "0"]
  ]

-- | UNLIKE 'decodeState', this never fails to a corrupt-marker value --
-- see the module Haddock's asymmetry (1). A missing\/short header, a
-- version above 'prefsSchema', or anything unparseable simply yields
-- 'defaultPrefs'. An unknown @P@ name is skipped (same degrade-not-
-- reject rule as the progress blob) while any @P jaFirst@ line
-- elsewhere in the same blob still decodes.
decodePrefs :: Text -> Prefs
decodePrefs raw
  | T.null (T.strip raw) = defaultPrefs
  | otherwise = case T.lines raw of
      []                       -> defaultPrefs
      (headerLine : bodyLines) -> case tagFields headerLine of
        (tag, [verTxt]) | tag == magicPrefs -> case parseDigits verTxt of
          Just v | v >= 1 && v <= prefsSchema -> foldl' applyPrefLine defaultPrefs bodyLines
          _                                    -> defaultPrefs
        _ -> defaultPrefs

applyPrefLine :: Prefs -> Text -> Prefs
applyPrefLine p line = case tagFields line of
  ("P", ["jaFirst", v]) -> p { prfJaFirst = v == "1" }
  _                      -> p
