{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | Template Haskell helpers for embedding UTF-8 text at compile time.
--
-- This is a separate module from its call sites because GHC 9.14 enforces
-- the TH stage restriction: a splice cannot use a function defined in the
-- same module it is spliced into (\"Level error: 'x' is used at level -1
-- but it is bound at level 0\"). @site\/test\/EmbeddedTranslations.hs@ is
-- 'embedUtf8File''s only remaining splice site.
--
-- M6 W1 (briefs\/M6-plan.md, ruling 1): @embedIndexedDir@ -- the INDEX-
-- driven whole-directory embedder that fed the retired
-- @site\/app\/Exercises\/Embed.hs@ -- is GONE with its sole splice site:
-- the exercise corpus ships as per-language content bundles emitted by
-- @scripts\/emit-content-bundles.py@ and loaded at boot through
-- "Bundle".
--
-- M7 W1 (briefs\/M7-plan.md, ruling 1): the MANUAL translations followed
-- it out of the wasm, into @manuals.{en,ja}.txt@ under the same bundle
-- grammar and the same all-or-nothing acceptance. The library module
-- that used to splice them (@SXC1.Content.Corpus@) is retired; nothing
-- reachable from @exe:app@ embeds manual text any more. 'embedUtf8File'
-- remains for @exe:content-check@ alone, whose @--dump-source@
-- exact-bytes contract needs a genuine COMPILE-TIME copy to be a
-- stale-build detector at all (see "EmbeddedTranslations").
module SXC1.Content.Embed
  ( embedUtf8File
  ) where

import           Data.Text ()   -- REQUIRED: brings the Lift Text instance into scope.
                                -- Without this exact import the build fails with
                                -- "No instance for (...TH.Lift.Lift Data.Text.Internal.Text)".
import qualified Data.ByteString as BS
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
