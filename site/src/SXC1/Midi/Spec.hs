{-# LANGUAGE OverloadedStrings #-}

-- | The pure half of M4's WebMIDI live-device verification: everything
-- that DECIDES whether a MIDI message satisfies a @verify:@ hook
-- ('SXC1.Exercise.Types.VerifySpec'). No IO, no browser -- the JS glue
-- lives in @exe:app@'s @Device.Midi@ and never decides anything; every
-- function here is total and is unit-tested by
-- @exercise-check --self-test@ under @wasm-run@ (no Chrome required).
-- The CI-only agreement proof against @translations\/midi.md@'s parsed
-- Note-mapping table lives in "SXC1.Midi.Table", which must NOT be
-- reachable from @exe:app@'s import graph.
--
-- SIZE DISCIPLINE: this module is linked into the browser app.
-- 'MidiMsg' derives 'Eq' ONLY -- no derived 'Show' (see
-- "SXC1.Exercise.Types"' size-discipline Haddock for why). 'describeSpec'
-- is plain "Data.Text" concatenation: no printf-style machinery.
module SXC1.Midi.Spec
  ( MidiMsg (..)
  , msgChannel
  , decodeMidi
  , padNoteTable
  , padNote
  , matchSpec
  , selectPorts
  , describeSpec
  ) where

import           Data.Text           (Text)
import qualified Data.Text           as T

import           SXC1.Exercise.Types (VerifySpec (..))

-- | One decoded channel-voice message. The first 'Int' of every
-- constructor is the 1-based MIDI channel (1..16). 'MsgCC' carries the
-- controller number and value; 'MsgNote' carries the note number and
-- velocity; 'MsgOther' is any other channel-voice shape (note-off,
-- aftertouch, program change, channel pressure, pitch bend) -- decoded
-- only far enough to know its channel, because no @verify:@ hook can
-- ever match one.
data MidiMsg
  = MsgCC    !Int !Int !Int   -- ^ channel, CC number, value
  | MsgNote  !Int !Int !Int   -- ^ channel, note number, velocity
  | MsgOther !Int             -- ^ channel only
  deriving (Eq)

-- | The 1-based MIDI channel of any decoded message.
msgChannel :: MidiMsg -> Int
msgChannel (MsgCC c _ _)   = c
msgChannel (MsgNote c _ _) = c
msgChannel (MsgOther c)    = c

-- | Decode one complete Web MIDI message (the byte list read off
-- @MIDIMessageEvent.data@) into a 'MidiMsg'.
--
-- A status byte in @0x80..0xEF@ yields
-- @channel = (status \`mod\` 16) + 1@ and
-- @kind = status - (status \`mod\` 16)@: kind @0xB0@ with two data bytes
-- is 'MsgCC', kind @0x90@ with two data bytes is 'MsgNote', and any
-- other complete channel-voice shape (@0x80@, @0xA0@, @0xE0@ with two
-- data bytes; @0xC0@, @0xD0@ with one) is 'MsgOther'.
--
-- A status byte @>= 0xF0@ (system messages, including sysex) yields
-- 'Nothing' -- those are never a verification. A status byte @< 0x80@,
-- or a truncated message (fewer data bytes than its kind requires),
-- yields 'Nothing'. Web MIDI always delivers complete messages, so
-- RUNNING STATUS CANNOT OCCUR here -- a leading data byte is simply
-- malformed input, not an abbreviated message, and this function
-- deliberately carries no dead code for it. A message with MORE bytes
-- than its kind requires is likewise 'Nothing': Web MIDI never delivers
-- one, and guessing at its meaning could only misfire a verification.
decodeMidi :: [Int] -> Maybe MidiMsg
decodeMidi bytes = case bytes of
  [] -> Nothing
  (status : dataBytes)
    | status < 0x80 || status >= 0xF0 -> Nothing
    | otherwise ->
        let channel = (status `mod` 16) + 1
            kind    = status - (status `mod` 16)
        in case dataBytes of
             [d1, d2] | kind == 0xB0                 -> Just (MsgCC channel d1 d2)
                      | kind == 0x90                 -> Just (MsgNote channel d1 d2)
                      | kind /= 0xC0 && kind /= 0xD0 -> Just (MsgOther channel)
             [_]      | kind == 0xC0 || kind == 0xD0 -> Just (MsgOther channel)
             _ -> Nothing

-- | The SXC-1's pad-to-note-number table, transcribed from
-- @translations\/midi.md@ section \"5. Note mapping\": 64 entries,
-- bank-major (bank A pads 1..16, then B, then C, then D). The
-- @\"Active (receive only)\"@ column is NOT here -- the device receives
-- those notes but never transmits them, so they can never verify a
-- drill.
--
-- This is deliberately a LITERAL table, not a formula. The arithmetic
-- @A=35+p, B=51+p, C=67+p, D=83+p@ is wrong for exactly one cell: the
-- source prints Pad 2 \/ Bank C = 68, duplicating Pad 1's 68 where the
-- sequence implies 69. @translations\/midi.qa-notes.md@ confirms this
-- against the page image and reproduces it deliberately. A formula plus
-- a special case would bury the erratum; a literal table shows it.
-- @exercise-check --self-test@ (group 20) proves this table agrees,
-- cell by cell, with "SXC1.Midi.Table"'s freshly-PARSED copy of the
-- same source table, and pins the erratum cell by name.
--
-- Consequence, documented rather than fixed: note 68 is ambiguous in
-- reverse (pad 1 bank C and pad 2 bank C both map to it), so a
-- @verify: pad 1 bank C@ hook would also be satisfied by tapping pad 2
-- in bank C. Mapping here is forward-only and no seed content uses
-- bank C.
padNoteTable :: [Int]
padNoteTable =
  [ 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51
  , 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67
  , 68, 68, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83
  , 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99
  ]

-- | The note number the SXC-1 transmits for pad @p@ in bank @b@,
-- straight out of 'padNoteTable'. 'Nothing' outside @p@ in 1..16 or
-- @b@ outside @\"ABCD\"@.
padNote :: Int -> Char -> Maybe Int
padNote p b
  | p < 1 || p > 16 = Nothing
  | otherwise = case bankIndex b of
      Nothing -> Nothing
      Just bi -> Just (padNoteTable !! (bi * 16 + (p - 1)))
  where
    bankIndex 'A' = Just (0 :: Int)
    bankIndex 'B' = Just 1
    bankIndex 'C' = Just 2
    bankIndex 'D' = Just 3
    bankIndex _   = Nothing

-- | Does @msg@ satisfy @spec@ on the expected channel? A message on any
-- other channel never matches, whatever the spec -- the wrong-channel
-- rejection happens here, once, so it cannot be forgotten per-spec.
--
-- 'VerifyAny' matches 'MsgCC' and 'MsgNote' but NOT 'MsgOther': \"any
-- MIDI activity\" means activity the SXC-1 actually transmits
-- (@translations\/midi.md@ section 3 marks every non-CC, non-note
-- function \"x\" for Transmit), not stray channel-voice traffic from
-- some other controller on the same channel.
--
-- VELOCITY: a note\/pad hook matches @0x90@ regardless of the velocity
-- byte, and @0x80@ (note-off, decoded 'MsgOther') never matches.
-- @translations\/midi.md@ section 3 records Velocity as \"x\" for both
-- Note ON and Note OFF, so the SXC-1's velocity byte is not meaningful;
-- if the device transmits velocity 0 for every pad press, honouring the
-- usual \"Note On with velocity 0 is a Note Off\" convention would make
-- every pad hook permanently dead. This is the single assumption in M4
-- that only the owner's physical device can settle --
-- @docs\/M4-device-test-protocol.md@ asks them to capture the raw bytes
-- of one pad press, and whatever they report becomes the pinned test
-- vector.
matchSpec :: Int -> VerifySpec -> MidiMsg -> Bool
matchSpec wantChannel spec msg
  | msgChannel msg /= wantChannel = False
  | otherwise = case (spec, msg) of
      (VerifyAny,      MsgCC {})       -> True
      (VerifyAny,      MsgNote {})     -> True
      -- 'null vs' is unreachable from real content:
      -- 'SXC1.Exercise.Reader.parseVerifyValue' cannot currently produce
      -- an empty value list. The branch is kept because it costs nothing
      -- and keeps this function total over the type.
      (VerifyCC n vs,  MsgCC _ c v)    -> c == n && (null vs || v `elem` vs)
      (VerifyNote ns,  MsgNote _ n _)  -> n `elem` ns
      (VerifyPad p b,  MsgNote _ n _)  -> padNote p b == Just n
      _                                -> False

-- | Which MIDI input ports to bind, given each port's
-- @(name, manufacturer)@ pair: the INDICES of
--
--   1. ports whose name or manufacturer case-foldedly contains
--      @\"sxc-1\"@, @\"sxc1\"@ or @\"sxc 1\"@; else
--   2. ports whose name or manufacturer case-foldedly contains
--      @\"casio\"@; else
--   3. EVERY index.
--
-- The fallback is the point: the SXC-1 is post-cutoff and nobody in
-- this project has seen the string it presents over USB-MIDI. Binding
-- nothing because a guessed name missed would be a silent total failure
-- for the one person with the hardware; binding every port when we
-- cannot tell costs nothing and always works. When we CAN tell, only
-- the SXC-1-looking ports are bound, which is what makes \"a message
-- from the other controller must not confirm\" a real negative control.
selectPorts :: [(Text, Text)] -> [Int]
selectPorts ports
  | not (null sxc)   = sxc
  | not (null casio) = casio
  | otherwise        = map fst indexed
  where
    indexed = zip [0 ..] ports
    matchesAny needles (nm, mfr) =
      let nm'  = T.toCaseFold nm
          mfr' = T.toCaseFold mfr
      in any (\needle -> needle `T.isInfixOf` nm' || needle `T.isInfixOf` mfr') needles
    sxc   = [ i | (i, p) <- indexed, matchesAny ["sxc-1", "sxc1", "sxc 1"] p ]
    casio = [ i | (i, p) <- indexed, matchesAny ["casio"] p ]

-- | Render a spec for the learner, e.g. @\"CC 80 = 127\"@,
-- @\"CC 80 = 0 or 127\"@ (comma-separated with a final \"or\" for three
-- or more values), @\"note 36\"@, @\"pad 1 in bank A (note 36)\"@,
-- @\"any MIDI activity from the device\"@.
--
-- There is deliberately NO CC-number-to-button-name table in M4: it
-- would need its own grounding proof against @translations\/midi.md@
-- section 4 and cost bytes, and each step's authored instruction
-- already names the button. Recorded as a possible M5 nicety.
describeSpec :: VerifySpec -> Text
describeSpec spec = case spec of
  VerifyCC n vs -> "CC " <> intText n <> " = " <> orList (map intText vs)
  VerifyNote ns -> "note " <> orList (map intText ns)
  VerifyPad p b ->
    "pad " <> intText p <> " in bank " <> T.singleton b
      <> maybe "" (\n -> " (note " <> intText n <> ")") (padNote p b)
  VerifyAny     -> "any MIDI activity from the device"

intText :: Int -> Text
intText = T.pack . show

-- | @[\"0\",\"1\",\"2\"]@ -> @\"0, 1 or 2\"@; @[\"0\",\"127\"]@ ->
-- @\"0 or 127\"@; a singleton is itself. Total: @[]@ renders empty
-- (unreachable from validated content -- see 'matchSpec' on @null vs@).
orList :: [Text] -> Text
orList xs = case reverse xs of
  []                -> ""
  [only]            -> only
  (lastX : restRev) -> T.intercalate ", " (reverse restRev) <> " or " <> lastX
