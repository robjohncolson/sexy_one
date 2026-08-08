{-# LANGUAGE OverloadedStrings #-}

-- | M6 W2 (briefs\/M6-plan.md, ruling 3): THE UI STRING TABLE. Every
-- learner-visible literal that "View.Pages"\/"View.Exercise"\/
-- "View.Progress"\/"Main" used to type inline lives HERE, as one named
-- entry per string, indexed by 'Lang' -- so the whole learner-visible
-- surface of the app is greppable, auditable and translated in exactly
-- one place. The table is tiny and stays embedded in app.wasm (the
-- corpus, by contrast, ships as external per-language bundles -- W1).
--
-- WHAT LOCALIZES AND WHAT NEVER DOES (rulings 3\/5):
--
--   * Navigation, buttons, statuses, feedback, the device panel, the
--     progress screens, the degraded-content state, ARIA labels and
--     live-region sentences: ALL localize (a11y parity is part of the
--     gate -- a screen-reader user gets the same language as a sighted
--     one).
--   * DOM ids, classes, wire formats, storage keys, route grammar,
--     language codes: NEVER localize.
--   * On-device labels stay EXACTLY as the hardware prints them, Latin
--     caps included (BANK, EDIT, FX1, REC, @A@-@D@ ...) -- the
--     translations\/glossary.md style rule 2, applied to UI strings.
--   * The brand line ("SEXY ONE \8212 SXC-1 Trainer") and the manual\/
--     deck\/exercise TITLES are not here: the brand is a product name
--     (proper noun, same in both languages), and every content title
--     comes from the corpus (W1's per-language bundles), never from
--     this table.
--   * DIAGNOSTIC REASON STRINGS threaded through localized templates
--     (a bundle-load failure reason from the JS shell, a codec decode
--     reason from the FROZEN "SXC1.Progress.Codec") stay as produced;
--     the sentence AROUND them localizes. The codec is not this wave's
--     to edit, and the JS shell's reasons are network diagnostics.
--
-- 'describeSpecJa' is the JA renderer for 'SXC1.Midi.Spec.describeSpec'
-- and lives HERE, in the app layer, rather than beside the EN renderer
-- in the (frozen) library: the lib API already exports everything it
-- needs -- 'VerifySpec's constructors and 'padNote' -- so the JA
-- renderer duplicates ZERO match logic (matchSpec is untouched and
-- remains the only decision-maker); it mirrors the EN renderer's five
-- output shapes one for one. See 'describeSpecFor'.
module I18n
  ( Lang (..)
  , langCode
  , langFromCode
  , describeSpecFor
    -- * The table (one named entry per learner-visible string)
  , iContentErrorBanner, iDegradedTitle, iDegradedBody, iDegradedManualsOk
  , iRetryButton, iBackToManuals
  , iBreadcrumbAria, iTraining, iPageOf
  , iHomeBlurb, iTrainingCardSub, iPagesSections, iTocPageAbbrev
  , iHideOriginal, iShowOriginal, iManualPagesAria, iPrevPage, iNextPage
  , iJaImageAlt, iJaImageCaption
  , iNotFoundTitle, iNoPageMatches, iDisclaimer
  , iKindLabel, iExNotFoundTitle, iNoExerciseMatches, iBackToTraining
  , iNExercises, iRestart, iSubmit, iRevealAnswer, iGotIt, iMissedIt
  , iPageNumberLabel, iNextButton, iCorrectFeedback, iIncorrectFeedback
  , iShowHint, iExerciseCompleted, iConfirm, iCitePage
  , iVerifyConfirmed, iVerifyWaiting, iVerifyIdleWatching, iVerifyIdleOn, iVerifyIdleOff
  , iDevEnable, iDevDisable, iDevRequesting, iDevRetryAccess
  , iDevStatusOff, iDevStatusPending, iDevStatusDenied, iDevStatusUnsupported
  , iDevStatusMismatch, iDevStatusOn, iDevNoInput, iDevBoundInput, iDevNoneBound
  , iUseChannel, iChannelAria
  , iReviewBadge, iJaFirstOn, iJaFirstOff, iUiLangButton, iUiLangButtonLangAttr
  , iStudyStreak, iRetiredNote
  , iNothingDue, iStartNextDeck, iDueToday, iDaysOverdue
  , iContinueLabel, iGetStarted, iBrowseDecks
  , iStorageNoteStrong, iStorageNoteBody
  , iCorruptBanner, iCorruptCopyHint, iCorruptNoRaw, iCorruptRawAria
  , iYourProgress, iExport, iExportAria, iImportLabel, iImportPreviewInit
  , iImport, iImportError, iWipe, iWipeConfirm
  , iDeckDone, iRequiresLabel
  , iImportEmptyReason
  ) where

import           Data.Text           (Text)
import qualified Data.Text           as T

import           SXC1.Exercise.Types (VerifySpec (..))
import           SXC1.Midi.Spec      (describeSpec, padNote)

-- | The two UI languages. 'En' is the default ('SXC1.Progress.Codec.
-- defaultPrefs'); the JA\/EN header toggle flips between exactly these.
data Lang = En | Ja
  deriving Eq

-- | The WIRE code for a language -- storage\/bundle vocabulary, never
-- localized ("en"\/"ja" name the content bundles and the prefs value).
langCode :: Lang -> Text
langCode En = "en"
langCode Ja = "ja"

-- | Total inverse: anything but the exact "ja" code is 'En' (the same
-- clamp 'SXC1.Progress.Codec.decodePrefs' applies on the wire).
langFromCode :: Text -> Lang
langFromCode c = if c == "ja" then Ja else En

-- | The one selector every entry below goes through.
t :: Text -> Text -> Lang -> Text
t en _  En = en
t _  ja Ja = ja

tshow :: Int -> Text
tshow = T.pack . show

--------------------------------------------------------------------------
-- describeSpec, per language (ruling 3: "describeSpec gains a JA
-- renderer"). EN delegates to the library's own renderer verbatim; JA
-- mirrors its five output shapes (CC single-value, CC value-list,
-- note-list, pad-with-note-lookup, any) using the SAME exported
-- 'padNote' table -- no match logic re-derived. Numbers and the bank
-- letters stay Latin (they mirror the hardware's own labels).
--------------------------------------------------------------------------

describeSpecFor :: Lang -> VerifySpec -> Text
describeSpecFor En spec = describeSpec spec
describeSpecFor Ja spec = case spec of
  VerifyCC n vs -> "CC " <> tshow n <> " = " <> jaOrList (map tshow vs)
  VerifyNote ns -> "\12494\12540\12488 " <> jaOrList (map tshow ns)          -- ノート 36
  VerifyPad p b ->
    -- バンクAのパッド1（ノート36） -- mirrors "pad 1 in bank A (note 36)"
    "\12496\12531\12463" <> T.singleton b <> "\12398\12497\12483\12489" <> tshow p
      <> maybe "" (\n -> "\65288\12494\12540\12488" <> tshow n <> "\65289") (padNote p b)
  VerifyAny     -> "\12487\12496\12452\12473\12363\12425\12398\20219\24847\12398MIDI\20449\21495" -- デバイスからの任意のMIDI信号

-- | JA counterpart of the EN renderer's @orList@: 「、」-separated with a
-- final 「 または 」 -- @["0","1","2"]@ -> 「0、1 または 2」, @["0","127"]@
-- -> 「0 または 127」, a singleton is itself, @[]@ renders empty (same
-- unreachable-from-content totality note as the EN one).
jaOrList :: [Text] -> Text
jaOrList xs = case reverse xs of
  []                -> ""
  [only]            -> only
  (lastX : restRev) -> T.intercalate "\12289" (reverse restRev) <> " \12414\12383\12399 " <> lastX

--------------------------------------------------------------------------
-- View.Pages: chrome, degraded-content state, manual reader, footer.
--------------------------------------------------------------------------

-- | The visible role=alert banner around the (diagnostic, unlocalized)
-- bundle-failure reason -- W1's degraded state, localized (W2).
iContentErrorBanner :: Lang -> Text -> Text
iContentErrorBanner En err = "Exercise content failed to load: " <> err
  <> " \8212 the manuals are unaffected; training exercises are temporarily unavailable."
iContentErrorBanner Ja err = "\28436\32722\12467\12531\12486\12531\12484\12398\35501\12415\36796\12415\12395\22833\25943\12375\12414\12375\12383: " <> err
  <> " \8212 \12510\12491\12517\12450\12523\12395\24433\38911\12399\12354\12426\12414\12379\12435\12290\12488\12524\12540\12491\12531\12464\28436\32722\12399\19968\26178\30340\12395\21033\29992\12391\12365\12414\12379\12435\12290"

iDegradedTitle :: Lang -> Text
iDegradedTitle = t "Training is unavailable"
                   "\12488\12524\12540\12491\12531\12464\12399\21033\29992\12391\12365\12414\12379\12435"

iDegradedBody :: Lang -> Text -> Text
iDegradedBody En err = "The exercise content bundle could not be loaded: " <> err
iDegradedBody Ja err = "\28436\32722\12467\12531\12486\12531\12484\12496\12531\12489\12523\12434\35501\12415\36796\12417\12414\12379\12435\12391\12375\12383: " <> err

iDegradedManualsOk :: Lang -> Text
iDegradedManualsOk = t "The manuals are unaffected and remain fully readable."
                       "\12510\12491\12517\12450\12523\12395\24433\38911\12399\12394\12367\12289\24341\12365\32154\12365\12377\12409\12390\38322\35239\12391\12365\12414\12377\12290"

iRetryButton :: Lang -> Text
iRetryButton = t "Reload and try again"
                 "\20877\35501\12415\36796\12415\12375\12390\20877\35430\34892"

iBackToManuals :: Lang -> Text
iBackToManuals = t "Back to the manuals"
                   "\12510\12491\12517\12450\12523\12395\25147\12427"

iBreadcrumbAria :: Lang -> Text
iBreadcrumbAria = t "Breadcrumb" "\12497\12531\12367\12378\12522\12473\12488"

iTraining :: Lang -> Text
iTraining = t "Training" "\12488\12524\12540\12491\12531\12464"

iPageOf :: Lang -> Int -> Int -> Text
iPageOf En n total = "page " <> tshow n <> " of " <> tshow total
iPageOf Ja n total = tshow total <> "\12506\12540\12472\20013" <> tshow n <> "\12506\12540\12472\30446"

iHomeBlurb :: Lang -> Text
iHomeBlurb En = "An interactive reader for the SXC-1 manuals: browse each translated document page by page, with the original Japanese page a tap away."
iHomeBlurb Ja = "SXC-1\12510\12491\12517\12450\12523\12398\12452\12531\12479\12521\12463\12486\12451\12502\12522\12540\12480\12540\12290\32763\35379\28168\12415\12398\21508\12489\12461\12517\12513\12531\12488\12434\12506\12540\12472\12372\12392\12395\38322\35239\12391\12365\12289\26085\26412\35486\12398\21407\26412\12506\12540\12472\12418\12377\12368\12395\34920\31034\12391\12365\12414\12377\12290"

iTrainingCardSub :: Lang -> Text
iTrainingCardSub = t "Quizzes, drills and lookups from the manuals"
                     "\12510\12491\12517\12450\12523\12395\12418\12392\12389\12367\12463\12452\12474\12539\12489\12522\12523\12539\12523\12483\12463\12450\12483\12503"

iPagesSections :: Lang -> Int -> Int -> Text
iPagesSections En p s = tshow p <> " pages, " <> tshow s <> " sections"
iPagesSections Ja p s = tshow p <> "\12506\12540\12472\12539" <> tshow s <> "\12475\12463\12471\12519\12531"

-- | The TOC's page abbreviation ("p. 15") -- deliberately identical in
-- both languages (page numbers are cited Latin-style throughout, and
-- the manuals themselves print p.NN).
iTocPageAbbrev :: Lang -> Int -> Text
iTocPageAbbrev _ n = "p. " <> tshow n

iHideOriginal :: Lang -> Text
iHideOriginal = t "Hide original page" "\21407\26412\12506\12540\12472\12434\38560\12377"

iShowOriginal :: Lang -> Text
iShowOriginal = t "Show original page (JA)" "\21407\26412\12506\12540\12472\12434\34920\31034"

iManualPagesAria :: Lang -> Text
iManualPagesAria = t "Manual pages" "\12510\12491\12517\12450\12523\12506\12540\12472"

iPrevPage :: Lang -> Text
iPrevPage = t "Previous page" "\21069\12398\12506\12540\12472"

iNextPage :: Lang -> Text
iNextPage = t "Next page" "\27425\12398\12506\12540\12472"

iJaImageAlt :: Lang -> Int -> Text
iJaImageAlt En n = "Original Japanese page " <> tshow n
iJaImageAlt Ja n = "\26085\26412\35486\21407\26412\12506\12540\12472" <> tshow n

iJaImageCaption :: Lang -> Int -> Text
iJaImageCaption En n = "Page " <> tshow n <> ", original Japanese"
iJaImageCaption Ja n = "\12506\12540\12472" <> tshow n <> "\65288\26085\26412\35486\21407\26412\65289"

iNotFoundTitle :: Lang -> Text
iNotFoundTitle = t "Page not found" "\12506\12540\12472\12364\35211\12388\12363\12426\12414\12379\12435"

iNoPageMatches :: Lang -> Text -> Text
iNoPageMatches En label = "No manual page matches: " <> label
iNoPageMatches Ja label = "\35442\24403\12377\12427\12510\12491\12517\12450\12523\12506\12540\12472\12364\12354\12426\12414\12379\12435: " <> label

-- | The footer disclaimer. The company name stays exactly
-- "CASIO COMPUTER CO., LTD." in both languages (legal name, and the
-- browser gate greps for it verbatim).
iDisclaimer :: Lang -> Text
iDisclaimer En = "Unofficial fan translation. Not affiliated with, or endorsed by, CASIO COMPUTER CO., LTD. Original manual content (c) CASIO COMPUTER CO., LTD."
iDisclaimer Ja = "\38750\20844\24335\12398\12501\12449\12531\32763\35379\12391\12377\12290CASIO COMPUTER CO., LTD. \12392\12399\28961\38306\20418\12391\12354\12426\12289\25215\35469\12418\21463\12369\12390\12356\12414\12379\12435\12290\21407\26412\12398\33879\20316\27177\12399 CASIO COMPUTER CO., LTD. \12395\24112\23646\12375\12414\12377\12290"

--------------------------------------------------------------------------
-- View.Exercise: index/deck/runner chrome, feedback, device panel.
--------------------------------------------------------------------------

-- | @KQuiz \/ KDrill \/ KLookup@ display labels, keyed by the (wire)
-- kind class the caller already computes -- the caller passes
-- "quiz"\/"drill"\/"lookup" (kindClass, never localized) back in.
iKindLabel :: Lang -> Text -> Text
iKindLabel En k = case k of { "quiz" -> "Quiz"; "drill" -> "Drill"; _ -> "Lookup" }
iKindLabel Ja k = case k of
  "quiz"  -> "\12463\12452\12474"
  "drill" -> "\12489\12522\12523"
  _       -> "\12523\12483\12463\12450\12483\12503"

iExNotFoundTitle :: Lang -> Text
iExNotFoundTitle = t "Not found" "\35211\12388\12363\12426\12414\12379\12435"

iNoExerciseMatches :: Lang -> Text -> Text
iNoExerciseMatches En label = "No exercise matches: " <> label
iNoExerciseMatches Ja label = "\35442\24403\12377\12427\28436\32722\12364\12354\12426\12414\12379\12435: " <> label

iBackToTraining :: Lang -> Text
iBackToTraining = t "Back to Training" "\12488\12524\12540\12491\12531\12464\12395\25147\12427"

iNExercises :: Lang -> Int -> Text
iNExercises En n = tshow n <> " exercises"
iNExercises Ja n = tshow n <> "\20214\12398\28436\32722"

iRestart :: Lang -> Text
iRestart = t "Restart" "\12420\12426\30452\12377"

iSubmit :: Lang -> Text
iSubmit = t "Submit" "\36865\20449"

iRevealAnswer :: Lang -> Text
iRevealAnswer = t "Reveal answer" "\31572\12360\12434\34920\31034"

iGotIt :: Lang -> Text
iGotIt = t "I got it" "\12391\12365\12383"

iMissedIt :: Lang -> Text
iMissedIt = t "I missed it" "\12391\12365\12394\12363\12387\12383"

iPageNumberLabel :: Lang -> Text
iPageNumberLabel = t "Page number:" "\12506\12540\12472\30058\21495:"

iNextButton :: Lang -> Text
iNextButton = t "Next" "\27425\12408"

iCorrectFeedback :: Lang -> Text
iCorrectFeedback = t "Correct." "\27491\35299\12290"

iIncorrectFeedback :: Lang -> Text
iIncorrectFeedback = t "Not quite. Try again." "\19981\27491\35299\12290\12418\12358\19968\24230\12290"

iShowHint :: Lang -> Text
iShowHint = t "Show a hint" "\12498\12531\12488\12434\34920\31034"

iExerciseCompleted :: Lang -> Text
iExerciseCompleted = t "You've completed this exercise."
                       "\12371\12398\28436\32722\12434\23436\20102\12375\12414\12375\12383\12290"

iConfirm :: Lang -> Text
iConfirm = t "Confirm" "\30906\35469"

-- | A citation link's text: slug + page. Identical shape in both
-- languages on purpose (slugs are wire ids; the manuals cite p.NN).
iCitePage :: Lang -> Text -> Int -> Text
iCitePage _ slug page = slug <> " p. " <> tshow page

-- The verify line's four sentences (aria-live region -- localizes,
-- ruling 3). The spec text comes from 'describeSpecFor' at the call
-- site, so both renderers stay in one place.

iVerifyConfirmed :: Lang -> Text -> Text
iVerifyConfirmed En specTxt = "Confirmed by the device: " <> specTxt <> "."
iVerifyConfirmed Ja specTxt = "\12487\12496\12452\12473\12391\30906\35469\28168\12415: " <> specTxt <> "\12290"

iVerifyWaiting :: Lang -> Text -> Int -> Text
iVerifyWaiting En specTxt chan = "Waiting for the device: " <> specTxt
  <> " on MIDI channel " <> tshow chan <> "."
iVerifyWaiting Ja specTxt chan = "\12487\12496\12452\12473\12434\24453\27231\20013: " <> specTxt
  <> "\65288MIDI\12481\12515\12531\12493\12523" <> tshow chan <> "\65289\12290"

iVerifyIdleWatching :: Lang -> Text
iVerifyIdleWatching = t "Device verification is watching the current step \8212 confirm this one manually."
                        "\12487\12496\12452\12473\26908\35388\12399\29694\22312\12398\12473\12486\12483\12503\12434\30435\35222\12375\12390\12356\12414\12377 \8212 \12371\12398\12473\12486\12483\12503\12399\25163\21205\12391\30906\35469\12375\12390\12367\12384\12373\12356\12290"

iVerifyIdleOn :: Lang -> Text
iVerifyIdleOn = t "Device verification is on \8212 confirm this step manually."
                  "\12487\12496\12452\12473\26908\35388\12399\12458\12531\12391\12377 \8212 \12371\12398\12473\12486\12483\12503\12399\25163\21205\12391\30906\35469\12375\12390\12367\12384\12373\12356\12290"

iVerifyIdleOff :: Lang -> Text
iVerifyIdleOff = t "Device verification is off \8212 confirm manually, or turn it on above."
                   "\12487\12496\12452\12473\26908\35388\12399\12458\12501\12391\12377 \8212 \25163\21205\12391\30906\35469\12377\12427\12363\12289\19978\12391\12458\12531\12395\12375\12390\12367\12384\12373\12356\12290"

iDevEnable :: Lang -> Text
iDevEnable = t "Enable device verification" "\12487\12496\12452\12473\26908\35388\12434\26377\21177\12395\12377\12427"

iDevDisable :: Lang -> Text
iDevDisable = t "Disable device verification" "\12487\12496\12452\12473\26908\35388\12434\28961\21177\12395\12377\12427"

iDevRequesting :: Lang -> Text
iDevRequesting = t "Requesting MIDI access\x2026" "MIDI\12450\12463\12475\12473\12434\35201\27714\20013\x2026"

iDevRetryAccess :: Lang -> Text
iDevRetryAccess = t "Retry device access" "\12487\12496\12452\12473\12450\12463\12475\12473\12434\20877\35430\34892"

iDevStatusOff :: Lang -> Text
iDevStatusOff = t "Device verification is off." "\12487\12496\12452\12473\26908\35388\12399\12458\12501\12391\12377\12290"

iDevStatusPending :: Lang -> Text
iDevStatusPending = t "Waiting for the browser to grant MIDI access."
                      "\12502\12521\12454\12470\12540\12364MIDI\12450\12463\12475\12473\12434\35377\21487\12377\12427\12398\12434\24453\12387\12390\12356\12414\12377\12290"

iDevStatusDenied :: Lang -> Text
iDevStatusDenied = t "The browser denied MIDI access. Confirm each step manually, or re-grant access in your browser's site settings and try again."
                     "\12502\12521\12454\12470\12540\12364MIDI\12450\12463\12475\12473\12434\25298\21542\12375\12414\12375\12383\12290\21508\12473\12486\12483\12503\12434\25163\21205\12391\30906\35469\12377\12427\12363\12289\12502\12521\12454\12470\12540\12398\12469\12452\12488\35373\23450\12391\12450\12463\12475\12473\12434\20877\35377\21487\12375\12390\12363\12425\12418\12358\19968\24230\12362\35430\12375\12367\12384\12373\12356\12290"

iDevStatusUnsupported :: Lang -> Text
iDevStatusUnsupported = t "This browser has no Web MIDI support; confirm each step manually."
                          "\12371\12398\12502\12521\12454\12470\12540\12399Web MIDI\12395\23550\24540\12375\12390\12356\12414\12379\12435\12290\21508\12473\12486\12483\12503\12434\25163\21205\12391\30906\35469\12375\12390\12367\12384\12373\12356\12290"

iDevStatusMismatch :: Lang -> Int -> Int -> Text
iDevStatusMismatch En got want = "Received MIDI on channel " <> tshow got
  <> "; this drill is listening on channel " <> tshow want <> "."
iDevStatusMismatch Ja got want = "\12481\12515\12531\12493\12523" <> tshow got
  <> "\12391MIDI\12434\21463\20449\12375\12414\12375\12383\12290\12371\12398\12489\12522\12523\12399\12481\12515\12531\12493\12523" <> tshow want <> "\12391\24453\12385\21463\12369\12390\12356\12414\12377\12290"

iDevStatusOn :: Lang -> Int -> Text
iDevStatusOn En chan = "Device verification is on, listening on MIDI channel " <> tshow chan <> "."
iDevStatusOn Ja chan = "\12487\12496\12452\12473\26908\35388\12399\12458\12531\12391\12377\12290MIDI\12481\12515\12531\12493\12523" <> tshow chan <> "\12391\24453\12385\21463\12369\12390\12356\12414\12377\12290"

iDevNoInput :: Lang -> Text
iDevNoInput = t "No MIDI input detected \8212 check the USB cable and that the unit is on."
                "MIDI\20837\21147\12364\26908\20986\12373\12428\12414\12379\12435 \8212 USB\12465\12540\12502\12523\12392\26412\20307\12398\38651\28304\12434\30906\35469\12375\12390\12367\12384\12373\12356\12290"

iDevBoundInput :: Lang -> Text -> Text
iDevBoundInput En ports = "Bound MIDI input: " <> ports
iDevBoundInput Ja ports = "\25509\32154\20013\12398MIDI\20837\21147: " <> ports

iDevNoneBound :: Lang -> Text
iDevNoneBound = t "No device bound yet." "\12487\12496\12452\12473\12399\26410\25509\32154\12391\12377\12290"

iUseChannel :: Lang -> Int -> Text
iUseChannel En c = "Use channel " <> tshow c
iUseChannel Ja c = "\12481\12515\12531\12493\12523" <> tshow c <> "\12434\20351\12358"

iChannelAria :: Lang -> Text
iChannelAria = t "MIDI listening channel" "MIDI\21463\20449\12481\12515\12531\12493\12523"

--------------------------------------------------------------------------
-- View.Progress: header toggles, badge, home progress panel.
--------------------------------------------------------------------------

iReviewBadge :: Lang -> Int -> Text
iReviewBadge En n = "Review " <> tshow n
iReviewBadge Ja n = "\24489\32722 " <> tshow n

iJaFirstOn :: Lang -> Text
iJaFirstOn = t "Japanese first: on" "\26085\26412\35486\12434\20808\12395\34920\31034: \12458\12531"

iJaFirstOff :: Lang -> Text
iJaFirstOff = t "Japanese first: off" "\26085\26412\35486\12434\20808\12395\34920\31034: \12458\12501"

-- | #btn-ui-lang shows the language it SWITCHES TO, written in that
-- language (the convention that stays legible whichever language is
-- active) -- so its label under En is Japanese text and vice versa.
iUiLangButton :: Lang -> Text
iUiLangButton En = "\26085\26412\35486"   -- 日本語 (switch to JA)
iUiLangButton Ja = "English"              -- switch back to EN

-- | The @lang@ attribute carried by #btn-ui-lang -- names the language
-- its LABEL is written in (the target language), for correct SR
-- pronunciation. A wire code, never localized text.
iUiLangButtonLangAttr :: Lang -> Text
iUiLangButtonLangAttr En = "ja"
iUiLangButtonLangAttr Ja = "en"

iStudyStreak :: Lang -> Int -> Text
iStudyStreak En n = "Study streak: " <> tshow n <> (if n == 1 then " day" else " days")
iStudyStreak Ja n = "\23398\32722\36899\32154\26085\25968: " <> tshow n <> "\26085"

iRetiredNote :: Lang -> Int -> Text
iRetiredNote En n = "Note: " <> tshow n
  <> " saved item(s) refer to exercises that have since been revised, and are excluded from review."
iRetiredNote Ja n = "\27880: \20445\23384\28168\12415\12398" <> tshow n
  <> "\20214\12399\25913\35330\12373\12428\12383\28436\32722\12434\21442\29031\12375\12390\12356\12427\12383\12417\12289\24489\32722\12363\12425\12399\38500\22806\12373\12428\12390\12356\12414\12377\12290"

iNothingDue :: Lang -> Text
iNothingDue = t "Nothing is due for review right now."
                "\29694\22312\12289\24489\32722\26399\38480\12398\12418\12398\12399\12354\12426\12414\12379\12435\12290"

iStartNextDeck :: Lang -> Text
iStartNextDeck = t "Start the next deck: " "\27425\12398\12487\12483\12461\12434\22987\12417\12427: "

iDueToday :: Lang -> Text
iDueToday = t "due today" "\20170\26085\12364\26399\38480"

iDaysOverdue :: Lang -> Int -> Text
iDaysOverdue En n = tshow n <> " day(s) overdue"
iDaysOverdue Ja n = "\26399\38480\12434" <> tshow n <> "\26085\36229\36942"

iContinueLabel :: Lang -> Text
iContinueLabel = t "Continue: " "\32154\12365\12363\12425: "

iGetStarted :: Lang -> Text
iGetStarted = t "Get started: " "\22987\12417\12427: "

iBrowseDecks :: Lang -> Text
iBrowseDecks = t "Browse the training decks"
                 "\12488\12524\12540\12491\12531\12464\12487\12483\12461\12434\35211\12427"

iStorageNoteStrong :: Lang -> Text
iStorageNoteStrong = t "Progress is not being saved. "
                       "\36914\25431\12399\20445\23384\12373\12428\12390\12356\12414\12379\12435\12290"

iStorageNoteBody :: Lang -> Text
iStorageNoteBody En = "This browser is refusing storage (private mode, exhausted quota, or storage disabled), so everything works but nothing survives closing the tab. Use Export below to copy your progress out before you leave."
iStorageNoteBody Ja = "\12371\12398\12502\12521\12454\12470\12540\12399\12473\12488\12524\12540\12472\12434\25298\21542\12375\12390\12356\12414\12377\65288\12503\12521\12452\12505\12540\12488\12514\12540\12489\12289\23481\37327\19981\36275\12289\12414\12383\12399\12473\12488\12524\12540\12472\28961\21177\65289\12290\12377\12409\12390\27231\33021\12375\12414\12377\12364\12289\12479\12502\12434\38281\12376\12427\12392\20309\12418\27531\12426\12414\12379\12435\12290\38281\12376\12427\21069\12395\19979\12398\12456\12463\12473\12509\12540\12488\12391\36914\25431\12434\12467\12500\12540\12375\12390\12367\12384\12373\12356\12290"

iCorruptBanner :: Lang -> Text -> Text
iCorruptBanner En reason = "Your saved progress could not be read (" <> reason
  <> "). It has NOT been deleted."
iCorruptBanner Ja reason = "\20445\23384\12373\12428\12383\36914\25431\12434\35501\12415\36796\12417\12414\12379\12435\12391\12375\12383\65288" <> reason
  <> "\65289\12290\12487\12540\12479\12399\21066\38500\12373\12428\12390\12356\12414\12379\12435\12290"

iCorruptCopyHint :: Lang -> Text
iCorruptCopyHint = t "Copy the raw text below to keep it safe, or use Export/Wipe further down."
                     "\19979\12398\12486\12461\12473\12488\12434\12467\12500\12540\12375\12390\20445\31649\12377\12427\12363\12289\12371\12398\20808\12398\12456\12463\12473\12509\12540\12488\65295\28040\21435\12434\20351\12387\12390\12367\12384\12373\12356\12290"

iCorruptNoRaw :: Lang -> Text
iCorruptNoRaw = t "(No raw data could be read either.)"
                  "\65288\20803\12487\12540\12479\12418\35501\12415\21462\12428\12414\12379\12435\12391\12375\12383\12290\65289"

iCorruptRawAria :: Lang -> Text
iCorruptRawAria = t "Raw saved progress data"
                    "\20445\23384\12373\12428\12383\36914\25431\12398\20803\12487\12540\12479"

iYourProgress :: Lang -> Text
iYourProgress = t "Your saved progress" "\20445\23384\12373\12428\12383\36914\25431"

iExport :: Lang -> Text
iExport = t "Export" "\12456\12463\12473\12509\12540\12488"

iExportAria :: Lang -> Text
iExportAria = t "Exported progress data"
                "\12456\12463\12473\12509\12540\12488\12373\12428\12383\36914\25431\12487\12540\12479"

iImportLabel :: Lang -> Text
iImportLabel = t "Paste an exported blob to import:"
                 "\12456\12463\12473\12509\12540\12488\12375\12383\12487\12540\12479\12434\36028\12426\20184\12369\12390\12452\12531\12509\12540\12488:"

iImportPreviewInit :: Lang -> Text
iImportPreviewInit = t "Paste text above to see how many records it contains."
                       "\19978\12395\12486\12461\12473\12488\12434\36028\12426\20184\12369\12427\12392\12289\21547\12414\12428\12427\12524\12467\12540\12489\25968\12364\34920\31034\12373\12428\12414\12377\12290"

iImport :: Lang -> Text
iImport = t "Import" "\12452\12531\12509\12540\12488"

iImportError :: Lang -> Text -> Text
iImportError En msg = "Import could not be read: " <> msg
iImportError Ja msg = "\12452\12531\12509\12540\12488\12434\35501\12415\36796\12417\12414\12379\12435\12391\12375\12383: " <> msg

iWipe :: Lang -> Text
iWipe = t "Wipe all progress" "\36914\25431\12434\12377\12409\12390\28040\21435"

iWipeConfirm :: Lang -> Text
iWipeConfirm = t "Yes, permanently wipe my progress"
                 "\12399\12356\12289\36914\25431\12434\23436\20840\12395\28040\21435\12375\12414\12377"

iDeckDone :: Lang -> Int -> Int -> Text
iDeckDone En done total = tshow done <> "/" <> tshow total <> " done"
iDeckDone Ja done total = tshow done <> "/" <> tshow total <> " \23436\20102"

iRequiresLabel :: Lang -> Text
iRequiresLabel = t "Requires: " "\21069\25552: "

--------------------------------------------------------------------------
-- Main.hs: the one learner-visible literal it owns.
--------------------------------------------------------------------------

iImportEmptyReason :: Lang -> Text
iImportEmptyReason = t "import text was empty"
                       "\12452\12531\12509\12540\12488\12377\12427\12486\12461\12473\12488\12364\31354\12391\12375\12383"
