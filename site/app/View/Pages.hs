{-# LANGUAGE OverloadedStrings #-}

-- | The three route bodies (home, manual contents, page view), the sticky
-- header\/breadcrumb, and the footer -- per the M1 DOM contract
-- (briefs\/M1-manifest.json). No manual chapter title, section title or
-- body text is ever typed literally here: every such string comes from
-- the parsed corpus (via "SXC1.Content.Corpus", "SXC1.Content.Outline" and
-- "SXC1.Content.Stats"). The handful of literal strings in this module are
-- UI chrome (the disclaimer text mandated by the brief, "not found"
-- copy, button labels) -- never manual content.
module View.Pages
  ( viewRoute
  ) where

import           Data.List              (find)
import qualified Data.Text              as T

-- 'Miso.DSL' also exports a JS-array-indexing '(!!)', which would
-- otherwise clash with the ordinary list index used below.
import           Miso                   hiding ((!!))
import           Miso.Html.Element      as H
import           Miso.Html.Event        as E
import           Miso.Html.Property     as P

import           SXC1.Content.Corpus    (corpusSources, lookupDoc)
import           SXC1.Content.Outline
import           SXC1.Content.Stats
import           SXC1.Content.Types     (Doc (docPages), Page (pageBlocks, pageHeader, pageNumber))
import           SXC1.Route

import qualified View.Blocks            as Blocks

-- | The whole Miso root for the given route: header, the hidden stats
-- blob, one of the three route bodies, and the footer -- identical shape
-- on every route, per the DOM contract.
viewRoute :: action -> Route -> View model action
viewRoute toggleAction route = H.main_ [ P.id_ "app" ]
  [ headerView route
  , statsView
  , routeBody toggleAction route
  , footerView
  ]

routeBody :: action -> Route -> View model action
routeBody _   RHome              = homeView
routeBody _   (RManual slug)     = tocView slug
routeBody act (RPage slug n ja)  = pageView act slug n ja
routeBody _   (RNotFound path)   = notFoundView path

--------------------------------------------------------------------------
-- Corpus-wide, text-level lookups shared by several views below. None of
-- these force any 'Page's 'pageBlocks' -- see the laziness contract in
-- "SXC1.Content.Types".
--------------------------------------------------------------------------

allDocStats :: [DocStats]
allDocStats = buildStats corpusSources

statsFor :: T.Text -> Maybe DocStats
statsFor slug = find ((== slug) . stSlug) allDocStats

rawFor :: T.Text -> Maybe T.Text
rawFor slug = lookup slug corpusSources

statsJsonText :: T.Text
statsJsonText = renderStatsJson corpusSources

--------------------------------------------------------------------------
-- Header: brand + route-dependent breadcrumb.
--------------------------------------------------------------------------

headerView :: Route -> View model action
headerView route = H.header_ [ P.id_ "sxc1-header" ]
  ( H.a_ [ P.class_ "brand", P.href_ (ms (renderRoute RHome)) ] [ "SXC-1 Trainer" ]
  : breadcrumbFor route
  )

breadcrumbFor :: Route -> [View model action]
breadcrumbFor RHome = []
breadcrumbFor (RManual slug) = case statsFor slug of
  Just st -> [ H.nav_ [] [ text (ms (stTitle st)) ] ]
  Nothing -> []
breadcrumbFor (RPage slug n _ja) = case (statsFor slug, rawFor slug) of
  (Just st, Just raw) | n >= 1 && n <= stPages st -> [ pageBreadcrumb slug st (buildOutline raw) n ]
  _                                                 -> []
breadcrumbFor (RNotFound _) = []

pageBreadcrumb :: T.Text -> DocStats -> Outline -> Int -> View model action
pageBreadcrumb slug st outline n =
  H.nav_ [] ( manualCrumb : groupCrumb ++ sectionCrumb ++ pageCrumb )
  where
    manualCrumb = H.a_ [ P.href_ (ms (renderRoute (RManual slug))) ] [ text (ms (stTitle st)) ]
    msec        = find (\s -> secPage s <= n && n <= secEndPage s) (outSections outline)

    groupCrumb = case (outGroups outline, msec) of
      (Just groups, Just sec) -> case find (elem sec . grpSections) groups of
        Just g  -> [ crumbSep, text (ms (grpTitle g)) ]
        Nothing -> []
      _ -> []

    sectionCrumb = case msec of
      Just sec -> [ crumbSep, text (ms (secTitle sec)) ]
      Nothing  -> []

    pageCrumb = [ crumbSep
                , text (ms ("page " <> T.pack (show n) <> " of " <> T.pack (show (stPages st))))
                ]

    crumbSep = text " / "

--------------------------------------------------------------------------
-- #sxc1-content-stats: always [hidden]; never rendered visibly.
--------------------------------------------------------------------------

statsView :: View model action
statsView = H.div_ [ P.id_ "sxc1-content-stats", P.hidden_ True ] [ text (ms statsJsonText) ]

--------------------------------------------------------------------------
-- Home ("#/"): project blurb + one card per manual.
--------------------------------------------------------------------------

homeView :: View model action
homeView = H.section_ [ P.id_ "sxc1-home" ]
  [ H.p_ []
      [ "An interactive reader for the SXC-1 manuals: browse each translated "
      , "document page by page, with the original Japanese page a tap away."
      ]
  , H.ul_ [ P.class_ "manual-list" ] (map manualCard allDocStats)
  ]

manualCard :: DocStats -> View model action
manualCard st = H.li_ []
  [ H.a_ [ P.class_ "manual-card", P.href_ (ms (renderRoute (RManual (stSlug st)))) ]
      [ H.strong_ [] [ text (ms (stTitle st)) ]
      , H.small_ []
          [ text (ms (T.pack (show (stPages st)) <> " pages, "
                        <> T.pack (show (stSections st)) <> " sections")) ]
      ]
  ]

--------------------------------------------------------------------------
-- Manual contents ("#/m/<slug>"): the grouped outline.
--------------------------------------------------------------------------

tocView :: T.Text -> View model action
tocView slug = case rawFor slug of
  Nothing  -> notFoundView slug
  Just raw ->
    let outline   = buildOutline raw
        titleText = maybe slug stTitle (statsFor slug)
        groups    = case outGroups outline of
          Just gs -> gs
          Nothing -> [ Group titleText (outSections outline) ]
    in H.section_ [ P.id_ "sxc1-toc" ] (map (renderGroup slug) groups)

renderGroup :: T.Text -> Group -> View model action
renderGroup slug g = H.section_ [ P.class_ "toc-group" ]
  [ H.h2_ [ P.class_ "toc-group-title" ] [ text (ms (grpTitle g)) ]
  , H.ol_ [ P.class_ "toc-sections" ] (map (renderSection slug) (grpSections g))
  ]

renderSection :: T.Text -> Section -> View model action
renderSection slug sec = H.li_ []
  ( H.a_ [ P.href_ (ms (renderRoute (RPage slug (secPage sec) False))) ] [ text (ms (secTitle sec)) ]
  : H.span_ [ P.class_ "toc-page" ] [ text (ms ("p. " <> T.pack (show (secPage sec)))) ]
  : subsEl
  )
  where
    subsEl
      | null (secSubs sec) = []
      | otherwise          = [ H.ul_ [ P.class_ "toc-subs" ] (map (renderSub slug) (secSubs sec)) ]

renderSub :: T.Text -> (Int, T.Text) -> View model action
renderSub slug (p, t) = H.li_ [] [ H.a_ [ P.href_ (ms (renderRoute (RPage slug p False))) ] [ text (ms t) ] ]

--------------------------------------------------------------------------
-- Page ("#/m/<slug>/p/<n>", "+/ja"): the rendered blocks + the JA panel.
--------------------------------------------------------------------------

pageView :: action -> T.Text -> Int -> Bool -> View model action
pageView toggleAction slug n ja = case (statsFor slug, lookupDoc slug) of
  (Just st, Just doc) | n >= 1 && n <= stPages st ->
    renderPage toggleAction slug (stPages st) ja (docPages doc !! (n - 1))
  _ -> notFoundView (slug <> "/p/" <> T.pack (show n))

renderPage :: action -> T.Text -> Int -> Bool -> Page -> View model action
renderPage toggleAction slug total ja pg =
  H.article_ articleAttrs
    ( runningHeaderEl
        ++ [ H.div_ [ P.class_ "page-body", P.id_ (ms ("page-" <> T.pack (show n))) ]
               (Blocks.renderBlocks slug (pageBlocks pg)) ]
        ++ jaPanelEl
        ++ [ H.button_ [ P.id_ "btn-ja-toggle", E.onClick toggleAction ]
               [ if ja then "Hide original page" else "Show original page (JA)" ]
           , H.nav_ [ P.class_ "page-nav" ] (navLinks slug n total)
           ]
    )
  where
    n = pageNumber pg

    articleAttrs = P.id_ "sxc1-page" : [ P.class_ "ja-visible" | ja ]

    runningHeaderEl = case pageHeader pg of
      Just h  -> [ H.p_ [ P.class_ "page-running-header" ] [ text (ms h) ] ]
      Nothing -> []

    jaPanelEl
      | not ja    = []
      | otherwise =
          [ H.figure_ [ P.id_ "ja-panel" ]
              [ H.a_ [ P.href_ (ms imgSrc) ]
                  [ H.img_
                      [ P.id_ "ja-image"
                      , P.loading_ "lazy"
                      , textProp "decoding" "async"
                      , P.alt_ (ms ("Original Japanese page " <> T.pack (show n)))
                      , P.src_ (ms imgSrc)
                      ]
                  ]
              , H.figcaption_ [] [ text (ms ("Page " <> T.pack (show n) <> ", original Japanese")) ]
              ]
          ]
      where
        imgSrc = "pages/" <> slug <> "/page-" <> zeroPad2 n <> ".webp"

navLinks :: T.Text -> Int -> Int -> [View model action]
navLinks slug n total =
  [ navLink "btn-prev-page" "Previous page" prevHref
  , navLink "btn-next-page" "Next page"     nextHref
  ]
  where
    prevHref = if n > 1     then Just (renderRoute (RPage slug (n - 1) False)) else Nothing
    nextHref = if n < total then Just (renderRoute (RPage slug (n + 1) False)) else Nothing

-- | Present at both ends of a manual, but with no @href@ (i.e. not a real
-- link) when there is no such page -- "absent or disabled at the ends".
navLink :: T.Text -> T.Text -> Maybe T.Text -> View model action
navLink elId label mHref =
  H.a_ ( P.id_ (ms elId) : maybe [] (\h -> [ P.href_ (ms h) ]) mHref ) [ text (ms label) ]

zeroPad2 :: Int -> T.Text
zeroPad2 n
  | n < 10    = "0" <> T.pack (show n)
  | otherwise = T.pack (show n)

--------------------------------------------------------------------------
-- Not found: unknown slug or an out-of-range page. Never a blank screen.
--------------------------------------------------------------------------

notFoundView :: T.Text -> View model action
notFoundView label = H.section_ [ P.id_ "sxc1-not-found" ]
  [ H.h1_ [] [ "Page not found" ]
  , H.p_ [] [ text (ms ("No manual page matches: " <> label)) ]
  , H.a_ [ P.class_ "manual-card", P.href_ (ms (renderRoute RHome)) ] [ "Back to the manuals" ]
  ]

--------------------------------------------------------------------------
-- Footer / disclaimer, verbatim on every route.
--------------------------------------------------------------------------

footerView :: View model action
footerView = H.footer_ [ P.id_ "sxc1-footer" ]
  [ H.p_ [ P.id_ "sxc1-disclaimer" ]
      [ "Unofficial fan translation. Not affiliated with, or endorsed by, "
      , "CASIO COMPUTER CO., LTD. Original manual content (c) CASIO COMPUTER CO., LTD."
      ]
  ]
