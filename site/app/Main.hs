{-# LANGUAGE CPP               #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import           Miso
import           Miso.Html.Element  as H
import           Miso.Html.Event    as E
import           Miso.Html.Property as P
import           Miso.Lens

data Action = Increment | Decrement | Reset deriving (Show, Eq)

#ifdef WASM
foreign export javascript "hs_start" main :: IO ()
#endif

main :: IO ()
main = startApp defaultEvents counterApp

counterApp :: App Int Action
counterApp = component 0 updateModel viewModel

updateModel :: Action -> Effect parent props Int Action
updateModel = \case
  Increment -> this += 1
  Decrement -> this -= 1
  Reset     -> this .= 0

viewModel :: props -> Int -> View Int Action
viewModel _ n = H.main_ [ P.id_ "app" ]
  [ H.h1_ [] [ "SXC-1 Trainer" ]
  , H.p_ [ P.class_ "subtitle" ] [ "M0 toolchain spike - Miso compiled to WebAssembly" ]
  , H.output_ [ P.id_ "counter-value" ] [ text (ms n) ]
  , H.div_ [ P.class_ "buttons" ]
    [ H.button_ [ P.id_ "btn-decrement", E.onClick Decrement ] [ "-" ]
    , H.button_ [ P.id_ "btn-reset",     E.onClick Reset     ] [ "reset" ]
    , H.button_ [ P.id_ "btn-increment", E.onClick Increment ] [ "+" ]
    ]
  ]
