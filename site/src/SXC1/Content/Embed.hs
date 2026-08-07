{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | Template Haskell helpers for embedding UTF-8 text at compile time.
--
-- This is a separate module from its call sites because GHC 9.14 enforces
-- the TH stage restriction: a splice cannot use a function defined in the
-- same module it is spliced into (\"Level error: 'x' is used at level -1
-- but it is bound at level 0\"). See "SXC1.Content.Corpus" for
-- 'embedUtf8File''s splice sites and "Exercises.Embed" for
-- 'embedIndexedDir''s.
module SXC1.Content.Embed
  ( embedUtf8File
  , embedIndexedDir
  ) where

import           Data.Text ()   -- REQUIRED: brings the Lift Text instance into scope.
                                -- Without this exact import the build fails with
                                -- "No instance for (...TH.Lift.Lift Data.Text.Internal.Text)".
import qualified Data.ByteString as BS
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           Language.Haskell.TH (Exp, Q)
import           Language.Haskell.TH.Syntax (addDependentFile, lift, runIO)

-- | Read a file as UTF-8 text and lift it into a compile-time string
-- literal, registering it as a dependency so GHC recompiles this module
-- when the file changes (provided the file is also listed under
-- @extra-source-files@ in the cabal file -- see the cabal file for why).
--
-- Decodes explicitly from 'BS.ByteString' via 'TE.decodeUtf8' rather than
-- using @Data.Text.IO.readFile@, whose decoding depends on the locale of
-- the machine running the build.
embedUtf8File :: FilePath -> Q Exp
embedUtf8File p = do
  addDependentFile p
  t <- runIO (TE.decodeUtf8 <$> BS.readFile p)
  lift t

-- | One filename per non-blank, non-@#@-comment line -- the INDEX
-- grammar shared with "SXC1.Exercise.Reader" and
-- @test\/CheckExercises.hs@.
indexEntryNames :: Text -> [FilePath]
indexEntryNames raw =
  [ T.unpack s
  | l <- T.lines raw
  , let s = T.strip l
  , not (T.null s)
  , not ("#" `T.isPrefixOf` s)
  ]

-- | M3 gate fix (briefs\/M3-manifest.json, task \"size-split-and-format\",
-- deliverable (2)): reads an INDEX file (@dependent-file@-registered, so
-- editing the INDEX itself triggers a rebuild) at COMPILE TIME, filters
-- blank\/@#@-comment lines exactly like 'indexEntryNames', then for each
-- named file 'addDependentFile's and reads IT too (so editing any one
-- embedded deck file also triggers a rebuild -- proven by touching a deck
-- file and observing a rebuild, per this task's final report), and
-- 'lift's the whole @[(FilePath, Text)]@ list as one compile-time value.
--
-- The 'FilePath' half of each pair is the BARE INDEX entry (e.g.
-- @\"00-preparation-power.ex.md\"@), NOT @dirPath@-prefixed -- this is
-- load-bearing, not cosmetic: it is what @#sxc1-exercise-stats@'
-- per-deck @\"file\"@ key reports (via "Exercises.Corpus"), and
-- @scripts\/check-site.sh@'s independent Python re-derivation and
-- @browser-check.mjs --expect-exercise-json@ both key off the SAME bare
-- name @os.listdir@\/the INDEX itself produce -- exactly what the M2
-- one-splice-per-file scheme this replaces also produced. @dirPath@ is
-- used ONLY to locate each file ON DISK at compile time (for
-- 'addDependentFile' and the read itself), never folded into the
-- embedded identity.
--
-- This replaces the old one-hand-written-splice-per-file scheme in
-- @site\/app\/Exercises\/Embed.hs@ (that module's git history, or the M2
-- manifest, has the old shape): that scheme's own Haddock admitted "a
-- future INDEX entry with no matching splice above is simply absent
-- here" -- silent content loss the moment an author adds a new deck
-- without also hand-editing the embedding module. 'embedIndexedDir' makes
-- the INDEX the single source of truth for what gets embedded; a named
-- file that does not exist on disk fails LOUDLY at compile time (via
-- 'BS.readFile''s own exception), never silently.
--
-- Lives in @lib:sxc1-trainer@ (this module), where @template-haskell@ IS
-- a dependency, exactly like 'embedUtf8File' -- @exe:app@ splices the
-- ALREADY-BUILT 'Q' 'Exp' this produces and needs no direct
-- @template-haskell@ dependency of its own.
embedIndexedDir :: FilePath -> FilePath -> Q Exp
embedIndexedDir indexPath dirPath = do
  addDependentFile indexPath
  names <- runIO (indexEntryNames . TE.decodeUtf8 <$> BS.readFile indexPath)
  pairs <- mapM readOne names
  lift pairs
  where
    readOne nm = do
      let fp = dirPath ++ "/" ++ nm
      addDependentFile fp
      t <- runIO (TE.decodeUtf8 <$> BS.readFile fp)
      pure (nm, t)
