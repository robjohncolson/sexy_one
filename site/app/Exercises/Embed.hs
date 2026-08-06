{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | Compile-time embedding of the seed exercise decks named by
-- @content\/exercises\/INDEX@.
--
-- DEVIATION FROM briefs\/M2-manifest.json's design item (1), MEASURED
-- AGAINST THE REAL COMMITTED @site\/sxc1-trainer.cabal@ (which this task
-- does not own): the brief asks for an @embedIndexed :: FilePath -> Q
-- Exp@ that reads the INDEX with 'Language.Haskell.TH.Syntax.runIO' and
-- calls 'Language.Haskell.TH.Syntax.addDependentFile' on every file it
-- names. Writing that function requires importing
-- @Language.Haskell.TH(.Syntax)@, which lives in the @template-haskell@
-- package -- and @exe:app@'s @build-depends@ (the already-committed
-- cabal stanza, not owned by this task) does NOT list @template-haskell@
-- (nor @bytestring@, nor @time@). CONFIRMED empirically: adding that
-- import to any module compiled as part of @exe:app@ fails with
-- \"Could not load module 'Language.Haskell.TH' ... hidden package
-- 'template-haskell'\" -- see this task's final report.
--
-- The one splice primitive @exe:app@ CAN use without that dependency is
-- "SXC1.Content.Embed".'SXC1.Content.Embed.embedUtf8File' itself
-- (ALSO confirmed empirically): it is already compiled, with
-- @template-haskell@\/@bytestring@ satisfied, inside @lib:sxc1-trainer@
-- (which every @site\/app@ module already reuses via M1's
-- "SXC1.Content.Corpus" pattern for the four manuals) -- an ALREADY
-- BUILT @Q Exp@ value can be spliced from a module that has no direct
-- @template-haskell@ dependency of its own, only 'Nothing' NEW can be
-- authored there. Since a splice's argument must be a literal (or
-- otherwise compile-time-evaluable) 'FilePath', it cannot be driven by a
-- runtime-parsed file list either -- so every deck file gets its own
-- named, literal 'embedUtf8File' call below, exactly mirroring how
-- @SXC1.Content.Corpus@ embeds the four manuals.
--
-- What IS preserved from the brief: 'addDependentFile' still fires per
-- file (inside 'embedUtf8File' itself), the INDEX is still embedded and
-- parsed (so the reading ORDER and the FILTER of \"only decks this
-- module actually has a splice for\" both come from the real
-- @content\/exercises\/INDEX@, not from a second hand-copied list), and
-- adding a genuinely new deck file still requires touching this module
-- by hand -- which is the one real behavioural gap against the brief's
-- \"read INDEX at compile time\" intent, and is called out again in the
-- final report.
module Exercises.Embed
  ( deckSources
  ) where

import qualified Data.Map.Strict     as Map
import           Data.Text           (Text)
import qualified Data.Text           as T

import           SXC1.Content.Embed  (embedUtf8File)

-- | @content\/exercises\/INDEX@, embedded at compile time.
indexSource :: Text
indexSource = $(embedUtf8File "../content/exercises/INDEX")

-- | @'#' comments and blank lines ignored, one file name per remaining
-- line@ -- the same INDEX grammar "SXC1.Exercise.Parse" uses.
indexEntries :: Text -> [FilePath]
indexEntries raw =
  [ T.unpack s
  | l <- T.lines raw
  , let s = T.strip l
  , not (T.null s)
  , not ("#" `T.isPrefixOf` s)
  ]

-- Every seed deck, embedded by its own literal splice (see the module
-- Haddock for why this cannot be a loop over 'indexEntries').
prepPowerSrc :: Text
prepPowerSrc = $(embedUtf8File "../content/exercises/00-preparation-power.ex.md")

padPlayBanksSrc :: Text
padPlayBanksSrc = $(embedUtf8File "../content/exercises/10-pad-play-banks.ex.md")

padPlaySoundsSrc :: Text
padPlaySoundsSrc = $(embedUtf8File "../content/exercises/20-pad-play-sounds.ex.md")

padPlayPerformanceSrc :: Text
padPlayPerformanceSrc = $(embedUtf8File "../content/exercises/30-pad-play-performance.ex.md")

knownDecks :: Map.Map FilePath Text
knownDecks = Map.fromList
  [ ("00-preparation-power.ex.md",    prepPowerSrc)
  , ("10-pad-play-banks.ex.md",       padPlayBanksSrc)
  , ("20-pad-play-sounds.ex.md",      padPlaySoundsSrc)
  , ("30-pad-play-performance.ex.md", padPlayPerformanceSrc)
  ]

-- | (file name, raw UTF-8 text), in @content\/exercises\/INDEX@ order,
-- restricted to the names this module has an embedded splice for -- a
-- future INDEX entry with no matching splice above is simply absent
-- here (never a crash; see "Exercises.Corpus").
deckSources :: [(FilePath, Text)]
deckSources =
  [ (nm, src) | nm <- indexEntries indexSource, Just src <- [Map.lookup nm knownDecks] ]
