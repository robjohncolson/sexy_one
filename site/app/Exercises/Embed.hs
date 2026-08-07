{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | Compile-time embedding of every deck named by
-- @content\/exercises\/INDEX@.
--
-- M3 gate fix (briefs\/M3-manifest.json, task \"size-split-and-format\",
-- deliverable (2); measured saving: 3,879 gzip bytes; also a real bug
-- fix). The M2 shape of this module needed one hand-written literal
-- 'SXC1.Content.Embed.embedUtf8File' splice PER DECK FILE, because
-- @exe:app@'s @build-depends@ has no @template-haskell@ of its own (see
-- "SXC1.Content.Embed"'s Haddock for why that constraint exists and why
-- it does not block this fix). Its own Haddock admitted the consequence:
-- \"a future INDEX entry with no matching splice above is simply absent
-- here\" -- silent content loss the moment a new deck is authored and
-- this module is not also hand-edited. M3 authors ~52 decks, which turns
-- that from a nuisance into a real risk.
--
-- FIX: 'SXC1.Content.Embed.embedIndexedDir' (itself compiled inside
-- @lib:sxc1-trainer@, where @template-haskell@ IS available) reads
-- @content\/exercises\/INDEX@ at COMPILE TIME, filters blank\/@#@-comment
-- lines, and 'Language.Haskell.TH.Syntax.addDependentFile's + reads every
-- named deck file, producing an ALREADY-BUILT @Q Exp@ for the whole
-- @[(FilePath, Text)]@ list. This module splices that value directly --
-- exactly as it already did for a single file via 'embedUtf8File' -- so
-- it still needs no @template-haskell@ dependency of its own, and adding
-- a new deck to the real course now requires touching ONLY
-- @content\/exercises\/INDEX@ (plus authoring the file itself), never
-- this module.
module Exercises.Embed
  ( deckSources
  ) where

import           Data.Text          (Text)

import           SXC1.Content.Embed (embedIndexedDir)

-- | (file name, raw UTF-8 text), in @content\/exercises\/INDEX@ order --
-- EVERY entry INDEX names, unconditionally (a named file that does not
-- exist fails the BUILD loudly, at compile time, inside
-- 'embedIndexedDir' -- never silently absent, unlike the scheme this
-- replaced).
deckSources :: [(FilePath, Text)]
deckSources = $(embedIndexedDir "../content/exercises/INDEX" "../content/exercises")
