{-# LANGUAGE OverloadedStrings #-}

-- | The three route bodies (home, manual contents, page view), the sticky
-- header\/breadcrumb, and the footer -- per the M1 DOM contract
-- (briefs\/M1-manifest.json). No manual chapter title, section title or
-- body text is ever typed literally here: every such string comes from
-- the parsed corpus (via "Bundle", "SXC1.Content.Outline" and
-- "SXC1.Content.Stats"). The handful of literal strings in this module are
-- UI chrome (the disclaimer text mandated by the brief, "not found"
-- copy, button labels) -- never manual content.
--
-- M7 W1 (briefs\/M7-plan.md, ruling 1): the manual text is no longer a
-- compile-time constant. The module-level @corpusSources@\/@allDocStats@\/
-- @statsJsonText@ CAFs are gone; every one of them is now a field of the
-- 'Manuals' value 'mkManuals' builds ONCE at boot from the fetched
-- bundle and Main threads through. Nothing else about the reader
-- changed: the same 'SXC1.Content.Markdown' parse, the same outline, the
-- same stats payload, the same laziness contract.
module View.Pages
  ( viewRoute
  , contentDegradedView
  , masteryShellView
  , sessionShellView
  , weeklyShellView
    -- * M7 W1: the fetched manual corpus
  , Manuals
  , mkManuals
  , emptyManuals
  ) where

import           Data.List              (find)
import qualified Data.Text              as T

-- 'Miso.DSL' also exports a JS-array-indexing '(!!)', which would
-- otherwise clash with the ordinary list index used below.
import           Miso                   hiding ((!!))
import           Miso.Html.Element      as H
import           Miso.Html.Event        as E
import           Miso.Html.Property     as P

import           Bundle                 (ManualDoc (..))
import           I18n
import           SXC1.Content.Markdown  (mkDoc)
import           SXC1.Content.Outline
import           SXC1.Content.Stats
import           SXC1.Content.Types     (Doc (docPages, docSlug, docTitle),
                                         Page (pageBlocks, pageHeader, pageNumber))
import           SXC1.Route

import qualified View.Blocks            as Blocks
import           View.Progress          (ProgData (..), ProgHandlers)
import qualified View.Progress          as Progress

--------------------------------------------------------------------------
-- THE FETCHED MANUAL CORPUS (M7 W1).
--------------------------------------------------------------------------

-- | Everything the reader derives from the manual bundle, computed
-- exactly once at boot and threaded through every view -- the
-- replacement for M1's module-level CAFs over the TH-embedded sources.
--
-- 'mnFallbacks' is ruling 4's VISIBLE half: the slugs whose text is NOT
-- in the language the learner asked for (until wave 2 authors
-- @translations\/\<slug\>.ja.md@, a @ja@ bundle legitimately carries the
-- English text for some documents). Those documents still render -- a
-- blank page is never acceptable -- but they render UNDER a localized
-- note that says so, and their body carries @lang=\"en\"@ so a screen
-- reader pronounces it correctly instead of reading English with
-- Japanese phonetics.
data Manuals = Manuals
  { mnSources   :: [(T.Text, T.Text)]   -- ^ (slug, raw markdown), bundle order
  , mnDocs      :: [Doc]
  , mnStats     :: [DocStats]
  , mnStatsJson :: T.Text
  , mnFallbacks :: [T.Text]
  }

-- | THE PARSE HALF OF ALL-OR-NOTHING MANUAL-BUNDLE ACCEPTANCE -- the
-- manual counterpart of "Exercises.Corpus".'Exercises.Corpus.checkedCorpusOf'.
-- "Bundle".'Bundle.parseManualBundle' has already agreed the framing,
-- the slug order, the declared page counts and the whole-bundle
-- fingerprint with this build's "Bundle.Manifest"; what only a real
-- parse can establish is that each document's TEXT actually yields the
-- pages the manifest promises. A document whose body was truncated
-- mid-way still carries a perfectly good @!SXC1-DOC@ line, and would
-- otherwise render as a quietly shorter manual with dead nav links.
--
-- 'Left' takes exactly the same visible degraded path a 404 takes.
--
-- Laziness: this forces each document's page SPLIT and title (both
-- cheap line-level passes, the same work @buildStats@ already did at
-- first render) and never a single 'pageBlocks' thunk -- the
-- "SXC1.Content.Types" contract is untouched.
mkManuals :: T.Text -> [ManualDoc] -> Either T.Text Manuals
mkManuals bundleLang mds = do
  docs <- mapM checkOne mds
  let srcs = [ (mdSlug md, mdText md) | md <- mds ]
  Right Manuals
    { mnSources   = srcs
    , mnDocs      = docs
    , mnStats     = buildStats srcs
    , mnStatsJson = renderStatsJson srcs
      -- Ruling 4: a document whose own text is not in the language the
      -- learner asked for. 'Bundle.parseManualBundle' has already
      -- rejected any language that is neither the requested one nor the
      -- documented "en" fallback, so this comparison is total.
    , mnFallbacks = [ mdSlug md | md <- mds, mdLang md /= bundleLang ]
    }
  where
    tshow :: Int -> T.Text
    tshow = T.pack . show

    checkOne md =
      let d = mkDoc (mdSlug md) (mdText md)
          n = length (docPages d)
      in if T.null (T.strip (docTitle d))
           then Left ("manual bundle document '" <> mdSlug md
                        <> "' has no title heading (truncated or corrupted body)")
           else if n /= mdPages md
             then Left ("manual bundle document '" <> mdSlug md <> "' parses to " <> tshow n
                          <> " page(s) but declares " <> tshow (mdPages md)
                          <> " (truncated or corrupted body)")
             else Right d

-- | The corpus a FAILED manual load leaves behind: empty, so every
-- manual route takes 'manualDegradedView' rather than rendering a
-- half-built reader. Mirrors Main's empty @[Deck]@ on a failed content
-- bundle.
emptyManuals :: Manuals
emptyManuals = Manuals
  { mnSources = [], mnDocs = [], mnStats = [], mnStatsJson = renderStatsJson [], mnFallbacks = [] }

-- | Is this document's body in a language other than the one the
-- learner asked for? Drives ruling 4's visible note.
isFallbackDoc :: Manuals -> T.Text -> Bool
isFallbackDoc mn slug = slug `elem` mnFallbacks mn

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
  :: Lang                       -- ^ M6 W2: the active UI language -- every learner-visible
                                --   string below renders through the I18n table with it
  -> action
  -> ProgHandlers action        -- ^ M3: export\/import\/wipe\/JA-first action bundle
  -> ProgData                   -- ^ M3: everything the progress panel and JA-first switch render from
  -> T.Text                     -- ^ #sxc1-exercise-stats JSON
  -> T.Text                     -- ^ #sxc1-event-log JSON
  -> T.Text                     -- ^ #sxc1-prompt-baseline JSON (M2 re-gate: see Main.promptBaselineJson)
  -> T.Text                     -- ^ #sxc1-progress JSON (M3: see Main.progressJson)
  -> T.Text                     -- ^ #sxc1-device-state JSON (M4: see Main.deviceStateJson)
  -> Manuals                    -- ^ M7 W1: the manual corpus this boot's bundle produced
                                --   ('emptyManuals' when that load failed)
  -> Maybe T.Text               -- ^ M6: 'Just' the content-bundle load-failure reason
  -> Maybe T.Text               -- ^ M7 W1: 'Just' the MANUAL-bundle load-failure reason. Either
                                --   (or both) renders the visible \#sxc1-content-error banner on
                                --   EVERY route, naming what actually failed (never rendered, not
                                --   merely hidden, on a healthy boot)
  -> Maybe (T.Text, T.Text)     -- ^ M6 gate round 1 (M6-R1-4): 'Just' (UI language code, LOADED course
                                --   language code) when the two disagree -- renders the visible
                                --   \#sxc1-lang-split banner on EVERY route; 'Nothing' (the healthy
                                --   case) renders nothing at all
  -> Maybe (View model action)  -- ^ the exercise body, when the route calls for one
  -> Route
  -> View model action
viewRoute lang toggleAction ph pd exStatsJson eventLogJson baselineJson progressJson deviceJson mn mContentErr mManualErr mLangSplit mExerciseBody route = H.main_ [ P.id_ "app" ]
  ( headerView lang mn ph pd route
  : contentErrorBanner lang mContentErr mManualErr
  ++ langSplitBanner lang mLangSplit
  ++ [ statsView mn
     , exerciseStatsView exStatsJson
     , eventLogView eventLogJson
     , promptBaselineView baselineJson
     , progressPayloadView progressJson
     , deviceStateView deviceJson
     , routeBody lang toggleAction mn ph pd mManualErr mExerciseBody route
     , footerView lang
     ]
  )

--------------------------------------------------------------------------
-- M6 W1 (briefs/M6-plan.md, ruling 1) + M7 W1 (briefs/M7-plan.md,
-- ruling 1): the DEGRADED bundle state. BOTH corpora are loaded at boot
-- (site/static/index.js + Bundle); when either load fails the app must
-- still boot, name the failure visibly, keep whatever DID load fully
-- usable, and offer a retry. ONE degraded state, three pieces:
--   * 'contentErrorBanner' -- a VISIBLE role="alert" banner under the
--     header, on every route, naming the failure. ONE banner, one
--     #sxc1-content-error id, one retry path, whichever bundle (or
--     both) failed -- only the sentence changes, because "the manuals
--     are unaffected" stopped being unconditionally true the moment the
--     manuals became a fetched bundle too. Absent entirely (not hidden)
--     on a healthy boot -- the harness asserts both directions.
--   * 'contentDegradedView' -- what Main.exerciseBodyView renders on
--     the three exercise routes instead of an empty index/deck/runner.
--   * 'manualDegradedView' -- its manual-route counterpart, so a failed
--     manual bundle is a NAMED failure with a retry rather than an
--     empty home page and "no manual page matches" everywhere.
--     #btn-content-retry is handled JS-side (site/static/index.js
--     click delegation -> location.reload()), like the wipe-confirm
--     toggle: a reload re-runs the guarded boot-time load, which is
--     the retry -- and it re-runs BOTH loads, which is exactly why one
--     retry affordance is the right number.
--------------------------------------------------------------------------

contentErrorBanner :: Lang -> Maybe T.Text -> Maybe T.Text -> [View model action]
contentErrorBanner lang mContentErr mManualErr = case (mContentErr, mManualErr) of
  (Nothing, Nothing) -> []
  (Just c,  Nothing) -> [ bannerEl (iContentErrorBanner lang c) ]
  (Nothing, Just m)  -> [ bannerEl (iManualErrorBanner lang m) ]
  (Just c,  Just m)  -> [ bannerEl (iBothErrorBanner lang c m) ]
  where
    bannerEl t = H.div_ [ P.id_ "sxc1-content-error", textProp "role" "alert" ] [ text (ms t) ]

-- | M6 gate round 1 (finding M6-R1-4): the UI\/CONTENT LANGUAGE SPLIT
-- banner. The shell picks the bundle from the pre-boot @sxc1.uilang@
-- hint; Main renders every string from the decoded prefs blob. A hint
-- write that FAILED (quota, revoked storage) therefore used to produce
-- a Japanese UI over an English course -- or the inverse -- for the
-- whole session with nothing on screen saying so. Same discipline as
-- 'contentErrorBanner': a visible role="alert" element on every route,
-- ABSENT ENTIRELY (never merely hidden) when the two agree. The button
-- is handled JS-side by the same delegated click listener as
-- \#btn-content-retry (site\/static\/index.js) -- a reload re-reads the
-- (already re-synced) hint and fetches the right bundle.
-- MEASURED (this fix's own red run): the explicit @hidden=False@ below
-- is load-bearing, not decoration. Unlike 'contentErrorBanner' -- whose
-- presence is decided once at boot and never changes -- this banner
-- APPEARS MID-SESSION (the in-memory language switch), growing
-- @main#app@'s child list by one. Miso's diff is positional, and the
-- slot this node takes over previously held @#sxc1-content-stats@,
-- which renders @hidden=True@; with no @hidden@ in the new node's
-- attribute list the diff has nothing to disagree with, so the old
-- property survived and the freshly inserted alert was
-- @display:none@ (visible in the DOM, invisible on screen -- the worst
-- possible outcome for an accessibility alert). Stating @hidden=False@
-- makes the two trees disagree, so the diff clears it.
langSplitBanner :: Lang -> Maybe (T.Text, T.Text) -> [View model action]
langSplitBanner _    Nothing              = []
langSplitBanner lang (Just (ui, content)) =
  [ H.div_ [ P.id_ "sxc1-lang-split", P.hidden_ False, textProp "role" "alert" ]
      [ text (ms (iLangSplitNotice lang ui content))
      , H.button_ [ P.id_ "btn-lang-resync" ] [ text (ms (iLangSplitButton lang)) ]
      ]
  ]

contentDegradedView :: Lang -> T.Text -> View model action
contentDegradedView lang err = H.section_ [ P.id_ "sxc1-exercise-degraded" ]
  [ H.h1_ [] [ text (ms (iDegradedTitle lang)) ]
  , H.p_ [] [ text (ms (iDegradedBody lang err)) ]
  , H.p_ [] [ text (ms (iDegradedManualsOk lang)) ]
  , H.button_ [ P.id_ "btn-content-retry" ] [ text (ms (iRetryButton lang)) ]
  , H.p_ [] [ H.a_ [ P.class_ "manual-card", P.href_ (ms (renderRoute RHome)) ] [ text (ms (iBackToManuals lang)) ] ]
  ]

-- | A deliberately tiny shell: the already-loaded course bundle and the
-- machine-readable progress payload are both available to index.js. Keeping
-- journey hydration there avoids linking a second wide rendering surface into
-- the size-constrained wasm artifact.
masteryShellView :: Lang -> View model action
masteryShellView lang = H.section_
  [ P.id_ "sxc1-mastery"
  , textProp "data-lang" (ms (langCode lang))
  ] []

-- | The daily coach is hydrated by the static shell from the same validated
-- course bundle and machine-readable progress payload as the mastery journey.
-- Keeping the Haskell surface this small avoids growing app.wasm for a view
-- whose plan is intentionally tab-scoped and progressively enhanced.
sessionShellView :: Lang -> View model action
sessionShellView lang = H.article_
  [ P.id_ "sxc1-session"
  , textProp "data-lang" (ms (langCode lang))
  ] []

-- | M10's Weekly Pulse is another deliberately tiny, progressively hydrated
-- shell. Its durable source is the versioned progress payload; the static DOM
-- renderer keeps the phone surface out of the size-constrained wasm artifact.
weeklyShellView :: Lang -> View model action
weeklyShellView lang = H.section_
  [ P.id_ "sxc1-weekly"
  , textProp "data-lang" (ms (langCode lang))
  ] []

-- | M7 W1: the manual-route counterpart of 'contentDegradedView'. Same
-- id vocabulary, same single retry affordance, same "what still works"
-- reassurance in the other direction.
manualDegradedView :: Lang -> T.Text -> View model action
manualDegradedView lang err = H.section_ [ P.id_ "sxc1-manual-degraded" ]
  [ H.h1_ [] [ text (ms (iManualDegradedTitle lang)) ]
  , H.p_ [] [ text (ms (iManualDegradedBody lang err)) ]
  , H.p_ [] [ text (ms (iManualDegradedTrainingOk lang)) ]
  , H.button_ [ P.id_ "btn-content-retry" ] [ text (ms (iRetryButton lang)) ]
  , H.p_ [] [ H.a_ [ P.class_ "manual-card", P.href_ (ms (renderRoute RExercises)) ] [ text (ms (iBackToTraining lang)) ] ]
  ]

-- | M7 W1: the three MANUAL routes degrade exactly as the three
-- exercise routes do when their bundle failed -- a named failure with a
-- retry, never an empty home page or a spurious "no manual page
-- matches".
routeBody :: Lang -> action -> Manuals -> ProgHandlers action -> ProgData -> Maybe T.Text -> Maybe (View model action) -> Route -> View model action
routeBody lang _   _  _  _  (Just err) _             RHome             = manualDegradedView lang err
routeBody lang _   _  _  _  (Just err) _             (RManual _)        = manualDegradedView lang err
routeBody lang _   _  _  _  (Just err) _             (RPage _ _ _)      = manualDegradedView lang err
routeBody lang _   mn ph pd _          _             RHome              = homeView lang mn ph pd
routeBody lang _   mn _  _  _          _             (RManual slug)      = tocView lang mn slug
routeBody lang act mn _  pd _          _             (RPage slug n ja)   = pageView lang act mn (pdJaFirst pd) slug n ja
routeBody _    _   _  _  _  _          (Just exBody) RExercises          = exBody
routeBody _    _   _  _  _  _          (Just exBody) RSession            = exBody
routeBody _    _   _  _  _  _          (Just exBody) RMastery            = exBody
routeBody _    _   _  _  _  _          (Just exBody) RWeekly             = exBody
routeBody _    _   _  _  _  _          (Just exBody) (RDeck _)           = exBody
routeBody _    _   _  _  _  _          (Just exBody) (RExercise _ _)     = exBody
routeBody lang _   _  _  _  _          Nothing       r@RExercises        = notFoundView lang (renderRoute r)
routeBody lang _   _  _  _  _          Nothing       r@RSession          = notFoundView lang (renderRoute r)
routeBody lang _   _  _  _  _          Nothing       r@RMastery          = notFoundView lang (renderRoute r)
routeBody lang _   _  _  _  _          Nothing       r@RWeekly           = notFoundView lang (renderRoute r)
routeBody lang _   _  _  _  _          Nothing       r@(RDeck _)         = notFoundView lang (renderRoute r)
routeBody lang _   _  _  _  _          Nothing       r@(RExercise _ _)   = notFoundView lang (renderRoute r)
routeBody lang _   _  _  _  _          _             (RNotFound path)    = notFoundView lang path

--------------------------------------------------------------------------
-- Corpus-wide, text-level lookups shared by several views below. None of
-- these force any 'Page's 'pageBlocks' -- see the laziness contract in
-- "SXC1.Content.Types".
--------------------------------------------------------------------------

statsFor :: Manuals -> T.Text -> Maybe DocStats
statsFor mn slug = find ((== slug) . stSlug) (mnStats mn)

rawFor :: Manuals -> T.Text -> Maybe T.Text
rawFor mn slug = lookup slug (mnSources mn)

lookupDocIn :: Manuals -> T.Text -> Maybe Doc
lookupDocIn mn slug = find ((== slug) . docSlug) (mnDocs mn)

--------------------------------------------------------------------------
-- Header: brand + route-dependent breadcrumb.
--------------------------------------------------------------------------

-- | The brand line is deliberately NOT localized: "SEXY ONE" and
-- "SXC-1 Trainer" are product names (the same discipline that keeps
-- on-device labels Latin), and the browser gate pins the brand text.
headerView :: Lang -> Manuals -> ProgHandlers action -> ProgData -> Route -> View model action
headerView _ mn ph pd route = H.header_ [ P.id_ "sxc1-header" ]
  ( [ H.a_ [ P.class_ "brand", P.href_ (ms (renderRoute RHome)) ] [ "SEXY ONE — SXC-1 Trainer" ]
    , Progress.reviewBadgeEl (pdLang pd) (Progress.dueCountLive pd)
    ]
    ++ breadcrumbFor (pdLang pd) mn route
    ++ Progress.jaFirstHeaderEls ph pd route
    ++ Progress.uiLangHeaderEls ph pd
  )

-- | M5 a11y: every breadcrumb \<nav\> carries a localized
-- @aria-label@ ("Breadcrumb") so the landmark is distinguishable from
-- the page-nav landmark (two unnamed navs read as interchangeable
-- "navigation" to a screen reader).
breadcrumbFor :: Lang -> Manuals -> Route -> [View model action]
breadcrumbFor _ _ RHome = []
breadcrumbFor lang mn (RManual slug) = case statsFor mn slug of
  Just st -> [ H.nav_ [ textProp "aria-label" (ms (iBreadcrumbAria lang)) ] [ text (ms (stTitle st)) ] ]
  Nothing -> []
breadcrumbFor lang mn (RPage slug n _ja) = case (statsFor mn slug, rawFor mn slug) of
  (Just st, Just raw) | n >= 1 && n <= stPages st -> [ pageBreadcrumb lang slug st (buildOutline raw) n ]
  _                                                 -> []
breadcrumbFor lang _ RExercises      = [ trainingCrumb lang ]
breadcrumbFor lang _ RSession        = [ trainingCrumb lang ]
breadcrumbFor lang _ RMastery        = [ trainingCrumb lang ]
breadcrumbFor lang _ RWeekly         = [ trainingCrumb lang ]
breadcrumbFor lang _ (RDeck _)       = [ trainingCrumb lang ]
breadcrumbFor lang _ (RExercise _ _) = [ trainingCrumb lang ]
breadcrumbFor _ _ (RNotFound _) = []

trainingCrumb :: Lang -> View model action
trainingCrumb lang =
  H.nav_ [ textProp "aria-label" (ms (iBreadcrumbAria lang)) ] [ text (ms (iTraining lang)) ]

pageBreadcrumb :: Lang -> T.Text -> DocStats -> Outline -> Int -> View model action
pageBreadcrumb lang slug st outline n =
  H.nav_ [ textProp "aria-label" (ms (iBreadcrumbAria lang)) ] ( manualCrumb : groupCrumb ++ sectionCrumb ++ pageCrumb )
  where
    manualCrumb = H.a_ [ P.href_ (ms (renderRoute (RManual slug))) ] [ text (ms (stTitle st)) ]

    -- | The section considered "current" for page @n@ -- M5 item 3 (M1
    -- final sign-off advisory 1): 'breadcrumbSectionForPage' names the
    -- FIRST section starting on page @n@ when one does (the section at
    -- the top of the page, where a TOC click to this page actually
    -- lands -- the route carries only the page, so the co-located
    -- sections of startup-guide pp. 10\/14, midi p.2 and oss p.11 are
    -- otherwise indistinguishable here), falling back to the containing
    -- section (last at or before @n@) on mid-span pages. Deterministic
    -- and total (front matter before the first section resolves to
    -- 'Nothing' without crashing); pinned for the cited pages in
    -- @test\/CheckContent.hs@ group 25 and in the browser suite.
    msec :: Maybe Section
    msec = breadcrumbSectionForPage n (outSections outline)

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
                , text (ms (iPageOf lang n (stPages st)))
                ]

    crumbSep = text " / "

--------------------------------------------------------------------------
-- #sxc1-content-stats: always [hidden]; never rendered visibly.
--------------------------------------------------------------------------

statsView :: Manuals -> View model action
statsView mn = H.div_ [ P.id_ "sxc1-content-stats", P.hidden_ True ] [ text (ms (mnStatsJson mn)) ]

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
-- Home ("#/"): a visible phone handoff, then a two-choice wizard fork.
-- The green path goes straight to the best next card; the red path opens
-- the deferred local Sample Lab. Course/manual/progress tools remain in a
-- quieter disclosure below, without becoming a third primary choice.
--------------------------------------------------------------------------

-- | The shareable production URL encoded in @site\/static\/qr-phone.svg@.
-- Kept as a named constant so the visible link and the image never drift
-- apart in source -- if the QR asset is regenerated for a new host, this
-- string is the one place to update (and the SVG must be rebuilt to match).
phoneQrUrl :: T.Text
phoneQrUrl = "https://sexy-one-gray.vercel.app/"

homeView :: Lang -> Manuals -> ProgHandlers action -> ProgData -> View model action
homeView lang mn ph pd = H.section_ [ P.id_ "sxc1-home" ]
  ( [ H.p_ [] [ text (ms (iHomeBlurb lang)) ]
    , phoneQrView lang
    ]
    ++ Progress.progressHomeNotices pd
    ++ [ H.div_ [ P.id_ "sxc1-wizard-actions", P.class_ "wizard-actions" ]
          [ Progress.primaryTrainingView pd
          , H.a_ [ P.id_ "btn-sample-lab", P.class_ "wizard-choice wizard-no sample-lab-home-action"
                 , P.href_ "#/samples" ]
              [ H.strong_ [] [ text (ms (iSampleLabTitle lang)) ]
              , H.small_ [ P.class_ "primary-training-card" ] [ text (ms (iSampleLabCardSub lang)) ]
              ]
          ]
       , H.details_ [ P.id_ "sxc1-browse-library", P.class_ "home-disclosure sample-library-disclosure" ]
            ( H.summary_ [] [ text (ms (iBrowseLibrary lang)) ]
            : H.ul_ [ P.class_ "manual-list" ]
                (trainingCard lang : weeklyCard lang : masteryCard lang : map (manualCard lang mn) (mnStats mn))
            : Progress.progressHomeView ph pd
            )
       ]
  )

-- | Laptop -> phone handoff: a static QR for the Vercel mirror, so a
-- learner with the site open on a laptop can point a phone camera at the
-- screen and land on the same app. Home-only (not every route) -- the
-- use case is "I found this on my computer, open it on the device in my
-- hand". The image is a pre-generated SVG under the static shell (no
-- runtime QR library; zero cost to app.wasm beyond these few nodes).
phoneQrView :: Lang -> View model action
phoneQrView lang = H.aside_ [ P.id_ "sxc1-phone-qr", textProp "aria-label" (ms (iPhoneQrTitle lang)) ]
  [ H.p_ [ P.class_ "phone-qr-title" ] [ text (ms (iPhoneQrTitle lang)) ]
  , H.p_ [ P.class_ "phone-qr-hint" ] [ text (ms (iPhoneQrHint lang)) ]
  , H.a_ [ P.class_ "phone-qr-link", P.href_ (ms phoneQrUrl)
         , textProp "target" "_blank", textProp "rel" "noopener noreferrer" ]
      [ H.img_
          [ P.id_ "sxc1-phone-qr-img"
          , P.src_ "./qr-phone.svg"
          , P.alt_ (ms (iPhoneQrAlt lang))
          , textProp "width" "180"
          , textProp "height" "180"
          , textProp "decoding" "async"
          ]
      ]
  , H.p_ [ P.class_ "phone-qr-url" ]
      [ H.a_ [ P.href_ (ms phoneQrUrl)
             , textProp "target" "_blank", textProp "rel" "noopener noreferrer" ]
          [ text (ms phoneQrUrl) ]
      ]
  ]

-- | Secondary access to the full course outline. The primary home action
-- links directly to the next exercise; this link is for deliberate
-- browsing and therefore lives inside the red wizard choice.
trainingCard :: Lang -> View model action
trainingCard lang = H.li_ []
  [ H.a_ [ P.class_ "manual-card", P.href_ (ms (renderRoute RExercises)) ]
      [ H.strong_ [] [ text (ms (iTraining lang)) ]
      , H.small_ [] [ text (ms (iTrainingCardSub lang)) ]
      ]
  ]

masteryCard :: Lang -> View model action
masteryCard lang = H.li_ []
  [ H.a_ [ P.class_ "manual-card mastery-home-card", P.href_ (ms (renderRoute RMastery)) ]
      [ H.strong_ [] [ text (ms (iMasteryTitle lang)) ]
      , H.small_ [] [ text (ms (iMasteryCardSub lang)) ]
      ]
  ]

weeklyCard :: Lang -> View model action
weeklyCard lang = H.li_ []
  [ H.a_ [ P.class_ "manual-card weekly-home-card", P.href_ (ms (renderRoute RWeekly)) ]
      [ H.strong_ [] [ text (ms (iWeeklyTitle lang)) ]
      , H.small_ [] [ text (ms (iWeeklyCardSub lang)) ]
      ]
  ]

-- | M7 W1 (ruling 4): a document still rendered in English because its
-- Japanese text has not been authored yet is FLAGGED on the card the
-- learner clicks, not only once they are inside it.
manualCard :: Lang -> Manuals -> DocStats -> View model action
manualCard lang mn st = H.li_ []
  [ H.a_ [ P.class_ "manual-card", P.href_ (ms (renderRoute (RManual (stSlug st)))) ]
      ( [ H.strong_ [] [ text (ms (stTitle st)) ]
        , H.small_ []
            [ text (ms (iPagesSections lang (stPages st) (stSections st))) ]
        ]
        ++ manualFallbackEls lang mn (stSlug st)
      )
  ]

-- | Ruling 4's VISIBLE note, rendered wherever a fallback document is
-- offered or read. Absent ENTIRELY (never merely hidden) for a document
-- whose text really is in the learner's language -- which is what makes
-- the same assertion prove both directions, and what makes wave 2
-- flipping one document at a time observable.
manualFallbackEls :: Lang -> Manuals -> T.Text -> [View model action]
manualFallbackEls lang mn slug
  | isFallbackDoc mn slug =
      [ H.p_ [ P.class_ "manual-fallback-note", textProp "role" "note" ]
          [ text (ms (iManualFallbackNote lang)) ] ]
  | otherwise = []

--------------------------------------------------------------------------
-- Manual contents ("#/m/<slug>"): the grouped outline.
--------------------------------------------------------------------------

tocView :: Lang -> Manuals -> T.Text -> View model action
tocView lang mn slug = case rawFor mn slug of
  Nothing  -> notFoundView lang slug
  Just raw ->
    let outline   = buildOutline raw
        titleText = maybe slug stTitle (statsFor mn slug)
        groups    = case outGroups outline of
          Just gs -> gs
          Nothing -> [ Group titleText (outSections outline) ]
    in H.section_ [ P.id_ "sxc1-toc" ]
         (manualFallbackEls lang mn slug ++ map (renderGroup lang slug) groups)

renderGroup :: Lang -> T.Text -> Group -> View model action
renderGroup lang slug g = H.section_ [ P.class_ "toc-group" ]
  [ H.h2_ [ P.class_ "toc-group-title" ] [ text (ms (grpTitle g)) ]
  , H.ol_ [ P.class_ "toc-sections" ] (map (renderSection lang slug) (grpSections g))
  ]

renderSection :: Lang -> T.Text -> Section -> View model action
renderSection lang slug sec = H.li_ []
  ( H.a_ [ P.href_ (ms (renderRoute (RPage slug (secPage sec) False))) ] [ text (ms (secTitle sec)) ]
  : H.span_ [ P.class_ "toc-page" ] [ text (ms (iTocPageAbbrev lang (secPage sec))) ]
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

pageView :: Lang -> action -> Manuals -> Bool -> T.Text -> Int -> Bool -> View model action
pageView lang toggleAction mn jaFirst slug n ja = case (statsFor mn slug, lookupDocIn mn slug) of
  (Just st, Just doc) | n >= 1 && n <= stPages st ->
    renderPage lang toggleAction mn jaFirst slug (stPages st) ja (docPages doc !! (n - 1))
  _ -> notFoundView lang (slug <> "/p/" <> T.pack (show n))

-- | @jaFirst@ (M3 owner addendum, item 8) governs ONLY the DOM order of
-- the JA panel relative to the translated body -- OFF (the default) keeps
-- the panel after the body, byte-identical to M1\/M2; ON puts it first,
-- so a phone (which stacks in DOM order; the >=60rem grid below pins the
-- panel by NAMED AREA regardless of DOM order, so a wide reader's layout
-- is unaffected either way) shows the original page before the English.
--
-- M7 W1 (ruling 4): the body renders whatever language the bundle
-- actually carried for this document -- Japanese once wave 2 authors
-- @translations\/\<slug\>.ja.md@, English until then -- and the ORIGINAL
-- PAGE IMAGE beside it keeps its exact previous meaning (it is the
-- scan, and \/ja still shows it). When the body IS the English
-- fallback, ruling 4's localized note is rendered ABOVE it (never a
-- blank page, never English passed off as Japanese) and the body itself
-- is marked @lang=\"en\"@ so a screen reader does not pronounce English
-- with Japanese phonetics.
renderPage :: Lang -> action -> Manuals -> Bool -> T.Text -> Int -> Bool -> Page -> View model action
renderPage lang toggleAction mn jaFirst slug total ja pg =
  H.article_ articleAttrs
    ( runningHeaderEl
        ++ fallbackEls
        ++ bodyOrderedEls
        ++ [ H.button_ [ P.id_ "btn-ja-toggle", E.onClick toggleAction ]
               [ text (ms ((if ja then iHideOriginal else iShowOriginal) lang)) ]
             -- M5 a11y: named nav landmark (see 'breadcrumbFor'), localized.
           , H.nav_ [ P.class_ "page-nav", textProp "aria-label" (ms (iManualPagesAria lang)) ] (navLinks lang slug n total)
           ]
    )
  where
    n = pageNumber pg

    articleAttrs = P.id_ "sxc1-page" : [ P.class_ "ja-visible" | ja ]

    isFallback = isFallbackDoc mn slug

    -- The note carries its OWN id (not just the shared class the card
    -- and TOC use) so the harness can assert its presence and, once
    -- wave 2 lands a document, its ABSENCE on a real reading route.
    fallbackEls
      | isFallback =
          [ H.p_ [ P.id_ "sxc1-manual-fallback", P.class_ "manual-fallback-note"
                 , P.hidden_ False, textProp "role" "note" ]
              [ text (ms (iManualFallbackNote lang)) ] ]
      | otherwise = []

    runningHeaderEl = case pageHeader pg of
      Just h  -> [ H.p_ [ P.class_ "page-running-header" ] [ text (ms h) ] ]
      Nothing -> []

    pageBodyEl = H.div_
      ( [ P.class_ "page-body", P.id_ (ms ("page-" <> T.pack (show n))) ]
          ++ [ textProp "lang" "en" | isFallback ] )
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
                      , P.alt_ (ms (iJaImageAlt lang n))
                      , P.src_ (ms imgSrc)
                      ]
                  ]
              , H.figcaption_ [] [ text (ms (iJaImageCaption lang n)) ]
              ]
          ]
      where
        imgSrc = "pages/" <> slug <> "/page-" <> zeroPad2 n <> ".webp"

navLinks :: Lang -> T.Text -> Int -> Int -> [View model action]
navLinks lang slug n total =
  [ navLink "btn-prev-page" (iPrevPage lang) prevHref
  , navLink "btn-next-page" (iNextPage lang) nextHref
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

notFoundView :: Lang -> T.Text -> View model action
notFoundView lang label = H.section_ [ P.id_ "sxc1-not-found" ]
  [ H.h1_ [] [ text (ms (iNotFoundTitle lang)) ]
  , H.p_ [] [ text (ms (iNoPageMatches lang label)) ]
  , H.a_ [ P.class_ "manual-card", P.href_ (ms (renderRoute RHome)) ] [ text (ms (iBackToManuals lang)) ]
  ]

--------------------------------------------------------------------------
-- Footer / disclaimer, verbatim on every route.
--------------------------------------------------------------------------

footerView :: Lang -> View model action
footerView lang = H.footer_ [ P.id_ "sxc1-footer" ]
  [ H.p_ [ P.id_ "sxc1-disclaimer" ]
      [ text (ms (iDisclaimer lang)) ]
  ]
