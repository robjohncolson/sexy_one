{-# LANGUAGE TemplateHaskell #-}

-- | Template Haskell helper for embedding a UTF-8 text file at compile time.
--
-- This is a separate module from its call sites because GHC 9.14 enforces
-- the TH stage restriction: a splice cannot use a function defined in the
-- same module it is spliced into (\"Level error: 'x' is used at level -1
-- but it is bound at level 0\"). See "SXC1.Content.Corpus" for the splice
-- sites.
module SXC1.Content.Embed (embedUtf8File) where

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
