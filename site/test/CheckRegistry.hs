-- WAVE 2 (task "id-registry") WILL REPLACE THIS.
--
-- Placeholder pre-declared by wave 1 ("size-split-and-format") purely so
-- exe:registry-check exists and builds with this module's final cabal
-- shape already in place -- see that task's cabal-file deliverable (6)
-- and final report. Not a real implementation: the "id-registry" task
-- owns site/test/CheckRegistry.hs and replaces this file wholesale.
module Main (main) where

import System.Exit (exitFailure)

main :: IO ()
main = putStrLn "not yet implemented" >> exitFailure
