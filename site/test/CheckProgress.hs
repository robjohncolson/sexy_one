-- WAVE 2 (task "progress-core") WILL REPLACE THIS.
--
-- Placeholder pre-declared by wave 1 ("size-split-and-format") purely so
-- exe:progress-check exists and builds with this module's final cabal
-- shape already in place -- see that task's cabal-file deliverable (6)
-- and final report. Not a real implementation: wave 2 owns
-- site/test/CheckProgress.hs and replaces this file wholesale.
module Main (main) where

import System.Exit (exitFailure)

main :: IO ()
main = putStrLn "not yet implemented" >> exitFailure
