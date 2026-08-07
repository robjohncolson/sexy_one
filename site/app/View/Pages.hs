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
import           View.Progress          (ProgData (..), ProgHandlers)
import qualified View.Progress          as Progress

-- | The whole Miso root for the given route: header, the two hidden
-- stats\/log blobs (M1's own @#sxc1-content-stats@ plus M2's
-- @#sxc1-exercise-stats@\/@#sxc1-event-log@), one of the route bodies,
-- and the footer -- identical shape on every route, per the DOM
-- contract. @mExerciseBody@ is 'Just' the already-built exercise-runner
-- view (from "View.Exercise", built in Main.hs, which alone knows the
-- concrete 'Action' type) exactly when @route@ is one of M2's three
-- exercise routes -- this module never constructs exercise views
-- itself, only slots one in, keeping "View.Exercise" reusable and this
-- module free of a Main-import cycle.
viewRoute
  :: action
  -> ProgHandlers action        -- ^ M3: export\/import\/wipe\/JA-first action bundle
  -> ProgData                   -- ^ M3: everything the progress panel and JA-first switch render from
  -> T.Text                     -- ^ #sxc1-exercise-stats JSON
  -> T.Text                     -- ^ #sxc1-event-log JSON
  -> T.Text                     -- ^ #sxc1-prompt-baseline JSON (M2 re-gate: see Main.promptBaselineJson)
  -> T.Text                     -- ^ #sxc1-progress JSON (M3: see Main.progressJson)
  -> T.Text                     -- ^ #sxc1-device-state JSON (M4: see Main.deviceStateJson)
  -> Maybe (View model action)  -- ^ the exercise body, when the route calls for one
  -> Route
  -> View model action
viewRoute toggleAction ph pd exStatsJson eventLogJson baselineJson progressJson deviceJson mExerciseBody route = H.main_ [ P.id_ "app" ]
  [ headerView ph pd route
  , statsView
  , exerciseStatsView exStatsJson
  , eventLogView eventLogJson
  , promptBaselineView baselineJson
  , progressPayloadView progressJson
  , deviceStateView deviceJson
  , routeBody toggleAction ph pd mExerciseBody route
  , footerView
  ]

routeBody :: action -> ProgHandlers action -> ProgData -> Maybe (View model action) -> Route -> View model action
routeBody _   ph pd _             RHome              = homeView ph pd
routeBody _   _  _  _             (RManual slug)      = tocView slug
routeBody act _  pd _             (RPage slug n ja)    = pageView act (pdJaFirst pd) slug n ja
routeBody _   _  _  (Just exBody) RExercises           = exBody
routeBody _   _  _  (Just exBody) (RDeck _)            = exBody
routeBody _   _  _  (Just exBody) (RExercise _ _)      = exBody
routeBody _   _  _  Nothing       r@RExercises         = notFoundView (renderRoute r)
routeBody _   _  _  Nothing       r@(RDeck _)          = notFoundView (renderRoute r)
routeBody _   _  _  Nothing       r@(RExercise _ _)    = notFoundView (renderRoute r)
routeBody _   _  _  _             (RNotFound path)     = notFoundView path

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

headerView :: ProgHandlers action -> ProgData -> Route -> View model action
headerView ph pd route = H.header_ [ P.id_ "sxc1-header" ]
  ( [ H.a_ [ P.class_ "brand", P.href_ (ms (renderRoute RHome)) ] [ "SXC-1 Trainer" ]
    , Progress.reviewBadgeEl (Progress.dueCountLive pd)
    ]
    ++ breadcrumbFor route
    ++ Progress.jaFirstHeaderEls ph pd route
  )

breadcrumbFor :: Route -> [View model action]
breadcrumbFor RHome = []
breadcrumbFor (RManual slug) = case statsFor slug of
  Just st -> [ H.nav_ [] [ text (ms (stTitle st)) ] ]
  Nothing -> []
breadcrumbFor (RPage slug n _ja) = case (statsFor slug, rawFor slug) of
  (Just st, Just raw) | n >= 1 && n <= stPages st -> [ pageBreadcrumb slug st (buildOutline raw) n ]
  _                                                 -> []
breadcrumbFor RExercises      = [ H.nav_ [] [ text "Training" ] ]
breadcrumbFor (RDeck _)       = [ H.nav_ [] [ text "Training" ] ]
breadcrumbFor (RExercise _ _) = [ H.nav_ [] [ text "Training" ] ]
breadcrumbFor (RNotFound _) = []

pageBreadcrumb :: T.Text -> DocStats -> Outline -> Int -> View model action
pageBreadcrumb slug st outline n =
  H.nav_ [] ( manualCrumb : groupCrumb ++ sectionCrumb ++ pageCrumb )
  where
    manualCrumb = H.a_ [ P.href_ (ms (renderRoute (RManual slug))) ] [ text (ms (stTitle st)) ]

    -- | The section considered "current" for page @n@. NEW1's fix made
    -- @secEndPage >= secPage@ an invariant of 'SXC1.Content.Outline', which
    -- means a page carrying two-or-more section-level headings
    -- (startup-guide pp. 1\/2\/3\/4\/10\/14, midi p.2, oss p.11 -- see
    -- @briefs\/M1-fixes-3-triage.md@'s NEW1 writeup; guide-book has none)
    -- is now genuinely ambiguous for "the current section" rather than
    -- accidentally resolving one way. The rule: the LAST section (in
    -- source order) whose heading is on page @n@ or earlier -- i.e. the
    -- most recently opened section governs its own page and every page up
    -- to the next section change. This is deterministic, total (front
    -- matter before the first section resolves to 'Nothing' without
    -- crashing), and it reproduces exactly what the app already showed
    -- before this round's outline fix (startup-guide p.10 -> "Try
    -- sampling", p.14 -> "Trademarks") -- we are formalising the existing
    -- observable behaviour, not changing it.
    msec :: Maybe Section
    msec = lastSectionAtOrBefore n (outSections outline)

    mgroup :: Maybe Group
    mgroup = case (outGroups outline, msec) of
      (Just groups, Just sec) -> find (elem sec . grpSections) groups
      _                       -> Nothing

    groupCrumb = case mgroup of
      Just g  -> [ crumbSep, text (ms (grpTitle g)) ]
      Nothing -> []

    -- | A3: a PART heading is simultaneously a Group's title and the
    -- first Section of that group -- 'SXC1.Content.Outline.buildGroups'
    -- names the group after the PART section's own 'secTitle' and
    -- deliberately keeps that section at the head of 'grpSections' (it is
    -- a real section with a real page, and the TOC must keep listing it).
    -- So on a PART page the group crumb and the section crumb are the
    -- same string; suppress the section crumb in that one case rather
    -- than dropping the section from the outline. Every other page keeps
    -- three distinct crumbs (manual \/ group \/ section).
    sectionCrumb = case msec of
      Nothing  -> []
      Just sec
        | Just (secTitle sec) == fmap grpTitle mgroup -> []
        | otherwise -> [ crumbSep, text (ms (secTitle sec)) ]

    pageCrumb = [ crumbSep
                , text (ms ("page " <> T.pack (show n) <> " of " <> T.pack (show (stPages st))))
                ]

    crumbSep = text " / "

-- | See 'pageBreadcrumb''s @msec@ for the rule this implements: the last
-- section (by source order, which 'outSections' is always in) whose
-- 'secPage' does not exceed @n@. A single left-to-right fold, so it is
-- total over the empty list and never inspects 'secEndPage'.
lastSectionAtOrBefore :: Int -> [Section] -> Maybe Section
lastSectionAtOrBefore n = foldl' step Nothing
  where
    step acc s
      | secPage s <= n = Just s
      | otherwise      = acc

--------------------------------------------------------------------------
-- #sxc1-content-stats: always [hidden]; never rendered visibly.
--------------------------------------------------------------------------

statsView :: View model action
statsView = H.div_ [ P.id_ "sxc1-content-stats", P.hidden_ True ] [ text (ms statsJsonText) ]

--------------------------------------------------------------------------
-- #sxc1-exercise-stats / #sxc1-event-log: always [hidden]; M2's own
-- machine-readable carriers, present on every route beside M1's own
-- #sxc1-content-stats above -- see "Exercises.Corpus" and Main.hs.
--------------------------------------------------------------------------

exerciseStatsView :: T.Text -> View model action
exerciseStatsView t = H.div_ [ P.id_ "sxc1-exercise-stats", P.hidden_ True ] [ text (ms t) ]

eventLogView :: T.Text -> View model action
eventLogView t = H.div_ [ P.id_ "sxc1-event-log", P.hidden_ True ] [ text (ms t) ]

-- | M2 re-gate fix (cold-route observability): the CURRENT exercise
-- route's monotonic prompt baseline ('esPromptAt'), or @null@ when no
-- 'ExerciseState' exists -- i.e. when 'Begin' has not run. A cold deep
-- link whose mount-time 'Begin' was lost renders @null@ here, so the
-- harness asserts this directly instead of inferring from elapsed-time
-- windows that page uptime can satisfy accidentally.
promptBaselineView :: T.Text -> View model action
promptBaselineView t = H.div_ [ P.id_ "sxc1-prompt-baseline", P.hidden_ True ] [ text (ms t) ]

-- | M3: the #sxc1-progress machine-readable payload -- always [hidden],
-- value-asserted by the harness. See Main.progressJson.
progressPayloadView :: T.Text -> View model action
progressPayloadView t = H.div_ [ P.id_ "sxc1-progress", P.hidden_ True ] [ text (ms t) ]

-- | M4: the #sxc1-device-state payload -- always present, always
-- [hidden], on EVERY route, exactly the way #sxc1-content-stats is
-- rendered. This is the only DOM difference M4 may create on a browser
-- without Web MIDI (constraint 5). See Main.deviceStateJson.
deviceStateView :: T.Text -> View model action
deviceStateView t = H.div_ [ P.id_ "sxc1-device-state", P.hidden_ True ] [ text (ms t) ]

--------------------------------------------------------------------------
-- Home ("#/"): project blurb + one card per manual.
--------------------------------------------------------------------------

homeView :: ProgHandlers action -> ProgData -> View model action
homeView ph pd = H.section_ [ P.id_ "sxc1-home" ]
  ( [ H.p_ []
        [ "An interactive reader for the SXC-1 manuals: browse each translated "
        , "document page by page, with the original Japanese page a tap away."
        ]
    , H.ul_ [ P.class_ "manual-list" ] (map manualCard allDocStats ++ [ trainingCard ])
    ]
    ++ Progress.progressHomeView ph pd
  )

-- | The Training entry point (briefs/M2-manifest.json, task
-- "exercise-ui", item 4): links to "#/x", the exercise index -- reuses
-- M1's own @.manual-card@ styling rather than inventing a new one.
trainingCard :: View model action
trainingCard = H.li_ []
  [ H.a_ [ P.class_ "manual-card", P.href_ (ms (renderRoute RExercises)) ]
      [ H.strong_ [] [ "Training" ]
      , H.small_ [] [ "Quizzes, drills and lookups from the manuals" ]
      ]
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

pageView :: action -> Bool -> T.Text -> Int -> Bool -> View model action
pageView toggleAction jaFirst slug n ja = case (statsFor slug, lookupDoc slug) of
  (Just st, Just doc) | n >= 1 && n <= stPages st ->
    renderPage toggleAction jaFirst slug (stPages st) ja (docPages doc !! (n - 1))
  _ -> notFoundView (slug <> "/p/" <> T.pack (show n))

-- | @jaFirst@ (M3 owner addendum, item 8) governs ONLY the DOM order of
-- the JA panel relative to the translated body -- OFF (the default) keeps
-- the panel after the body, byte-identical to M1\/M2; ON puts it first,
-- so a phone (which stacks in DOM order; the >=60rem grid below pins the
-- panel by NAMED AREA regardless of DOM order, so a wide reader's layout
-- is unaffected either way) shows the original page before the English.
renderPage :: action -> Bool -> T.Text -> Int -> Bool -> Page -> View model action
renderPage toggleAction jaFirst slug total ja pg =
  H.article_ articleAttrs
    ( runningHeaderEl
        ++ bodyOrderedEls
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

    pageBodyEl = H.div_ [ P.class_ "page-body", P.id_ (ms ("page-" <> T.pack (show n))) ]
      (Blocks.renderBlocks slug (pageBlocks pg))

    bodyOrderedEls
      | ja && jaFirst = jaPanelEl ++ [ pageBodyEl ]
      | otherwise     = pageBodyEl : jaPanelEl

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
