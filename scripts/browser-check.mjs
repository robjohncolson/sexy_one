#!/usr/bin/env node
// browser-check.mjs -- dependency-free headless-Chrome acceptance driver.
//
// Drives Google Chrome / Chromium over the Chrome DevTools Protocol (CDP)
// using only Node built-ins (global WebSocket, net, child_process, fs, http,
// os, path). No npm packages, no package.json, no node_modules anywhere.
//
// Usage:
//   node scripts/browser-check.mjs [--url URL] [--expect-json FILE] [--quick]
//                                   [--browser PATH] [--timeout MS] [--keep-open]
//
// The whole run is bounded by ONE monotonic deadline derived from
// --timeout: the WebSocket handshake, every individual CDP command and
// every polling loop are all routed through it, so a peer that hangs (TCP
// connects but the WebSocket handshake never completes, a command is sent
// but the response never arrives, the page never boots, ...) fails within
// the --timeout budget instead of hanging indefinitely.
//
// Exit codes:
//   0  every assertion passed
//   1  at least one assertion failed (including a reported boot error, a
//      missing required DOM node, or a click on a missing element)
//   2  harness error: no browser found, CDP unreachable, the browser
//      process died out from under us, or the --timeout deadline expired
//      before the harness itself could finish
//
// See the M1 DOM contract in briefs/M1-manifest.json for the
// window.__SXC1_BOOTED / window.__SXC1_BOOT_ERROR / #boot-status contract
// (unchanged from M0) and the #sxc1-header / #sxc1-home / #sxc1-toc /
// #sxc1-page / #sxc1-footer markup this script asserts on. M0's counter
// assertions (#counter-value, #btn-increment/-decrement/-reset) are gone;
// this drives the manual reader instead.
//
// --- M1 round-3 gate fixes (NEW5 / NEW6 / NEW9) --------------------------
//
// NEW5 (cold deep-link): in addition to the warm in-app hash-change check
// (assertion 6, unchanged), a SEPARATE assertion opens a genuinely fresh
// CDP target whose INITIAL navigation URL already carries
// '#/m/guide-book/p/17/ja' -- i.e. the hash is present before the app ever
// boots, not assigned into an already-booted page. Boot and image decode
// are awaited independently on that fresh target, which is then closed.
// This is the only way to exercise whatever Main.hs does with the startup
// hash, as opposed to its hashchange subscription.
//
// NEW6 (image decode, browser half): the default (non---quick) 108-route
// sweep now visits every route in its '/ja' form and awaits a REAL decode
// (img.decode(), raced against a per-image timeout so a hung fetch cannot
// silently stall the whole run) against the expected 'pages/<slug>/page-
// NN.webp' src, with CDP Network-domain failure listeners armed so a
// failed fetch is named rather than just timing out. --quick keeps doing
// the same decode assertion over its small first/mid/last sample instead
// of all 108 -- it stays a fast local-iteration mode, never the default.
// No new CLI flag was added for this: check-site.sh already invokes this
// script without --quick, so the exhaustive decode sweep is already the
// default it gets for free.
//
// NEW9 (--expect-json vacuity): a supplied --expect-json file is now
// schema-validated BEFORE any comparison happens: it must name exactly
// the four documents {guide-book, startup-guide, midi, oss} (no fewer, no
// extra, no duplicates), and every one of them must carry the full
// required stats field set. A malformed or vacuous file exits 2 with a
// readable message instead of silently producing a vacuous pass. The
// comparison itself is now bidirectional: an extra document present in
// the app's #sxc1-content-stats but absent from --expect-json is also a
// mismatch, not just the reverse. The built-in golden path (no
// --expect-json) is unaffected -- GOLDEN_DOCS already satisfies the same
// schema.

import { spawn } from 'node:child_process';
import * as fs from 'node:fs';
import * as http from 'node:http';
import * as net from 'node:net';
import * as os from 'node:os';
import * as path from 'node:path';

// ---------------------------------------------------------------------------
// Manual page counts (slug -> number of pages), used to build the full
// 108-route sweep and to bound --quick's sample. Mirrors
// briefs/M1-manifest.json's golden corpus table.
// ---------------------------------------------------------------------------

const DOC_PAGES = {
  'guide-book': 71,
  'startup-guide': 15,
  midi: 6,
  oss: 16,
};

// Golden stats table (briefs/M1-manifest.json), used when --expect-json is
// not given. Only the numeric fields that table lists are compared in that
// case; a real --expect-json file (content-check --json's output) is
// compared field-for-field instead.
const GOLDEN_FIELDS = [
  'chars', 'lines', 'pages', 'headings', 'figures', 'tables', 'sections', 'subsections', 'parts',
];
const GOLDEN_DOCS = [
  { slug: 'guide-book', chars: 111559, lines: 2356, pages: 71, headings: 188, figures: 190, tables: 20, sections: 29, subsections: 78, parts: 5 },
  { slug: 'startup-guide', chars: 29145, lines: 567, pages: 15, headings: 51, figures: 43, tables: 5, sections: 21, subsections: 27, parts: 0 },
  { slug: 'midi', chars: 7372, lines: 160, pages: 6, headings: 8, figures: 4, tables: 7, sections: 6, subsections: 1, parts: 0 },
  { slug: 'oss', chars: 42533, lines: 388, pages: 16, headings: 6, figures: 0, tables: 0, sections: 5, subsections: 0, parts: 0 },
];

const GUIDE_BOOK_PART_TITLES = [
  'PART 0 — Part: Preparation',
  'PART 1 — Part: Pad play',
  'PART 2 — Part: Sampling',
  'PART 3 — Part: Sequencer',
  'PART 4 — Part: Leveling up',
];

// ---------------------------------------------------------------------------
// NEW9: --expect-json schema validation.
//
// A supplied --expect-json file must describe exactly the four documents
// content-check tracks (REQUIRED_DOC_SLUGS), no more, no fewer, no
// duplicates, and every one of them must carry every field the comparison
// below can possibly check (REQUIRED_STATS_FIELDS -- the same numeric
// fields GOLDEN_FIELDS lists for the built-in path, plus 'unparsed', which
// the built-in path does not compare but a real content-check --json
// capture always includes). This is deliberately a field ALLOWLIST check
// against a REQUIRED set, not a strict key-set check: a doc may carry
// extra fields (title, partTitles, ...) and every field actually present
// still gets compared field-for-field further down, unchanged.
// ---------------------------------------------------------------------------

const REQUIRED_DOC_SLUGS = ['guide-book', 'startup-guide', 'midi', 'oss'];
// NEW9-partial fix (briefs/M2-manifest.json, task "exercise-ui"): 'title'
// and 'partTitles' were deliberately omitted here at M1's gate, so a
// four-document expectation carrying only the numeric fields passed
// without ever checking those two emitted fields. Both are now required.
const REQUIRED_STATS_FIELDS = [...GOLDEN_FIELDS, 'unparsed', 'title', 'partTitles'];

// Returns null when `parsed` is an acceptable --expect-json payload,
// otherwise a human-readable string explaining exactly what is wrong.
function validateExpectJson(parsed, filePath) {
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return `--expect-json file '${filePath}' must be a JSON object with a top-level "docs" array`;
  }
  if (!Array.isArray(parsed.docs)) {
    return `--expect-json file '${filePath}' has no top-level "docs" array`;
  }
  const seenSlugs = new Set();
  for (let i = 0; i < parsed.docs.length; i++) {
    const edoc = parsed.docs[i];
    if (!edoc || typeof edoc !== 'object' || Array.isArray(edoc) || typeof edoc.slug !== 'string' || edoc.slug === '') {
      return `--expect-json file '${filePath}': docs[${i}] is missing a non-empty string "slug" field`;
    }
    if (seenSlugs.has(edoc.slug)) {
      return `--expect-json file '${filePath}': duplicate slug "${edoc.slug}" in docs[]`;
    }
    seenSlugs.add(edoc.slug);
    const missing = REQUIRED_STATS_FIELDS.filter((f) => !(f in edoc));
    if (missing.length > 0) {
      return `--expect-json file '${filePath}': docs[${i}] (slug "${edoc.slug}") is missing required field(s): ${missing.join(', ')} -- an expectation must supply every stats field it wants compared, not a partial subset`;
    }
  }
  const missingSlugs = REQUIRED_DOC_SLUGS.filter((s) => !seenSlugs.has(s));
  const extraSlugs = [...seenSlugs].filter((s) => !REQUIRED_DOC_SLUGS.includes(s));
  if (missingSlugs.length > 0 || extraSlugs.length > 0) {
    const parts = [`--expect-json file '${filePath}' must name exactly the four documents {${REQUIRED_DOC_SLUGS.join(', ')}}`];
    if (missingSlugs.length > 0) parts.push(`missing: ${missingSlugs.join(', ')}`);
    if (extraSlugs.length > 0) parts.push(`unexpected: ${extraSlugs.join(', ')}`);
    return parts.join('; ');
  }
  return null;
}

// ---------------------------------------------------------------------------
// M2: --expect-exercise-json schema validation and comparison against
// #sxc1-exercise-stats. Same discipline as --expect-json above, but exact
// in BOTH directions from birth (briefs/M2-manifest.json, task
// "exercise-ui"): every expected deck present, none unexpected, none
// duplicated, and every field compared -- an expectation satisfiable by a
// subset is not an expectation. The schema below matches exactly what
// Exercises.Corpus.exerciseStatsJsonOf (site/app/Exercises/Corpus.hs)
// emits.
// ---------------------------------------------------------------------------

const REQUIRED_EX_TOTALS_FIELDS = ['decks', 'exercises', 'prompts', 'quiz', 'drill', 'lookup'];
const REQUIRED_EX_DECK_FIELDS = ['file', 'deck', 'chapter', 'title', 'exercises', 'prompts', 'chars', 'lines', 'fnv1a'];

// Returns null when `parsed` is an acceptable --expect-exercise-json
// payload, otherwise a human-readable string explaining exactly what is
// wrong -- exercised by one of this task's negative controls
// (`--self-test --expect-exercise-json '{"totals":{"exercises":999}}'`
// must be rejected, which it is here because that payload is missing
// almost every required field, never merely because the number itself
// happens to be wrong).
function validateExpectExerciseJson(parsed, filePath) {
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return `--expect-exercise-json '${filePath}' must be a JSON object with "totals" and "decks"`;
  }
  if (!parsed.totals || typeof parsed.totals !== 'object' || Array.isArray(parsed.totals)) {
    return `--expect-exercise-json '${filePath}' has no "totals" object`;
  }
  const missingTotals = REQUIRED_EX_TOTALS_FIELDS.filter((f) => !(f in parsed.totals));
  if (missingTotals.length > 0) {
    return `--expect-exercise-json '${filePath}': totals is missing required field(s): ${missingTotals.join(', ')} -- an expectation must supply every totals field it wants compared, not a partial subset`;
  }
  if (!Array.isArray(parsed.decks)) {
    return `--expect-exercise-json '${filePath}' has no top-level "decks" array`;
  }
  const seenFiles = new Set();
  for (let i = 0; i < parsed.decks.length; i++) {
    const edeck = parsed.decks[i];
    if (!edeck || typeof edeck !== 'object' || Array.isArray(edeck) || typeof edeck.file !== 'string' || edeck.file === '') {
      return `--expect-exercise-json '${filePath}': decks[${i}] is missing a non-empty string "file" field`;
    }
    if (seenFiles.has(edeck.file)) {
      return `--expect-exercise-json '${filePath}': duplicate file "${edeck.file}" in decks[]`;
    }
    seenFiles.add(edeck.file);
    const missing = REQUIRED_EX_DECK_FIELDS.filter((f) => !(f in edeck));
    if (missing.length > 0) {
      return `--expect-exercise-json '${filePath}': decks[${i}] (file "${edeck.file}") is missing required field(s): ${missing.join(', ')}`;
    }
  }
  return null;
}

// Exact bidirectional comparison: every expected totals field and every
// expected deck's every field, PLUS every actual deck accounted for (no
// extra, no duplicate). Returns a list of human-readable mismatches
// (empty means an exact match).
function compareExerciseStats(actual, expected) {
  if (!actual || typeof actual !== 'object') {
    return ['#sxc1-exercise-stats did not parse as a JSON object'];
  }
  const mismatches = [];
  const at = (actual.totals && typeof actual.totals === 'object') ? actual.totals : {};
  for (const f of REQUIRED_EX_TOTALS_FIELDS) {
    if (JSON.stringify(at[f]) !== JSON.stringify(expected.totals[f])) {
      mismatches.push(`totals.${f}: got ${JSON.stringify(at[f])} want ${JSON.stringify(expected.totals[f])}`);
    }
  }
  const actualDecks = Array.isArray(actual.decks) ? actual.decks : [];
  const expectedByFile = new Map(expected.decks.map((d) => [d.file, d]));
  const actualFileCounts = new Map();
  for (const ad of actualDecks) {
    const f = ad && ad.file;
    if (typeof f === 'string') actualFileCounts.set(f, (actualFileCounts.get(f) || 0) + 1);
  }
  for (const [file, count] of actualFileCounts) {
    if (count > 1) mismatches.push(`${file}: appears ${count} times in app exercise stats (duplicate deck)`);
    if (!expectedByFile.has(file)) mismatches.push(`${file}: present in app exercise stats but not named in --expect-exercise-json`);
  }
  for (const ed of expected.decks) {
    const ad = actualDecks.find((d) => d && d.file === ed.file);
    if (!ad) { mismatches.push(`${ed.file}: missing from app exercise stats`); continue; }
    for (const f of REQUIRED_EX_DECK_FIELDS) {
      if (JSON.stringify(ad[f]) !== JSON.stringify(ed[f])) {
        mismatches.push(`${ed.file}.${f}: got ${JSON.stringify(ad[f])} want ${JSON.stringify(ed[f])}`);
      }
    }
  }
  return mismatches;
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const opts = {
    url: 'http://127.0.0.1:8123/',
    browser: null,
    // M4: raised from 45000 -- the run now also carries the 25-assertion
    // device suite (a dozen fresh targets), and the bare default budget
    // no longer covered a full real-app run. Purely an upper bound on
    // hangs; it loosens no assertion.
    timeout: 240000,
    keepOpen: false,
    expectJson: null,
    quick: false,
    selfTest: false,
    selfTestNegative: false,
    selfTestNegativeOnly: null,
    exerciseFixture: null,
    expectExerciseJson: null,
    checkStorageRefused: false,
    checkContentMissing: false,
    checkBadBundle: false,
    checkContentStalled: false,
    checkHintWriteFailure: false,
    checkJaToggle: false,
    // M7 W1 (briefs/M7-plan.md, rulings 1/4): the manual bundle's two
    // behavioural modes.
    checkBadManualBundle: false,
    checkManualFallback: false,
    deviceOnly: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--url':
        opts.url = argv[++i];
        break;
      case '--browser':
        opts.browser = argv[++i];
        break;
      case '--timeout':
        opts.timeout = Number(argv[++i]);
        break;
      case '--expect-json':
        opts.expectJson = argv[++i];
        break;
      case '--quick':
        opts.quick = true;
        break;
      case '--keep-open':
        opts.keepOpen = true;
        break;
      case '--self-test':
        opts.selfTest = true;
        break;
      case '--self-test-negative':
        opts.selfTestNegative = true;
        break;
      case '--self-test-negative-only':
        opts.selfTestNegativeOnly = argv[++i];
        break;
      case '--exercise-fixture':
        opts.exerciseFixture = argv[++i];
        break;
      case '--expect-exercise-json':
        opts.expectExerciseJson = argv[++i];
        break;
      case '--check-storage-refused':
        opts.checkStorageRefused = true;
        break;
      case '--check-content-missing':
        opts.checkContentMissing = true;
        break;
      case '--check-bad-bundle':
        opts.checkBadBundle = true;
        break;
      case '--check-content-stalled':
        opts.checkContentStalled = true;
        break;
      case '--check-hint-write-failure':
        opts.checkHintWriteFailure = true;
        break;
      case '--check-ja-toggle':
        opts.checkJaToggle = true;
        break;
      case '--check-bad-manual-bundle':
        opts.checkBadManualBundle = true;
        break;
      case '--check-manual-fallback':
        opts.checkManualFallback = true;
        break;
      case '--device-only':
        opts.deviceOnly = true;
        break;
      case '--help':
      case '-h':
        printHelp();
        process.exit(0);
        break;
      default:
        console.error(`error: unrecognised argument: ${a}`);
        printHelp();
        process.exit(2);
    }
  }
  if (!Number.isFinite(opts.timeout) || opts.timeout <= 0) {
    console.error('error: --timeout must be a positive number of milliseconds');
    process.exit(2);
  }
  return opts;
}

function printHelp() {
  console.log(`Usage: browser-check.mjs [options]

Options:
  --url <url>         Page to check (default: http://127.0.0.1:8123/)
  --expect-json <file> JSON produced by 'content-check --json'. When given,
                       the running app's #sxc1-content-stats is compared
                       against it field-for-field, in both directions. When
                       absent, it is compared against the golden numbers
                       table baked into this script. The file must name
                       exactly the four documents {guide-book, startup-
                       guide, midi, oss}, each with every required stats
                       field and no duplicate slugs, or the run exits 2
                       before a browser is even launched.
  --quick              Sweep a small sample of pages (first/middle/last of
                       each manual) instead of all 108 routes. The sample
                       still visits each page's '/ja' form and decodes its
                       original-page image, same as the default sweep.
  --browser <path>     Browser executable (default: $SXC1_BROWSER, else the
                       first of google-chrome, google-chrome-stable, chromium,
                       chromium-browser found on PATH)
  --timeout <ms>       Overall run timeout in milliseconds (default: 45000).
                       Bounds the WebSocket connect, every CDP command and
                       every polling loop -- not just the polling loops.
  --keep-open          Do not kill the browser on exit (debugging)
  --self-test          Run the M2/M3 exercise + progress assertions
                       against this script's own self-contained fixture
                       (no --url, no server) and report passed/total.
  --self-test-negative M3 gate fix NEW10: runs ~17 separate throwaway-
                       browser passes -- a "clean" (no sabotage) sanity
                       pass, a 'legacy-all' combined pass (every M2-era
                       AND M3 sabotage at once, for backward-compatible
                       coverage of the M2-era assertion names), and one
                       pass per individually-selectable M3 sabotage
                       point -- asserting for EACH pass that EXACTLY its
                       own mapped assertion(s) failed and nothing else
                       did. Prints a per-selector summary line and exits
                       0 only if every pass was individually clean. Each
                       pass's own --timeout floor is raised to 90000ms
                       regardless of the --timeout flag's value (a
                       sabotaged pass spends more of its own budget on
                       purpose -- broken predicates poll to their FULL
                       timeout instead of settling early); pass a larger
                       --timeout to raise it further.
  --self-test-negative-only <key>
                       Restrict --self-test-negative to one named pass
                       (see its own summary output for valid keys) --
                       a faster dev loop, not part of the documented
                       pass/fail contract.
  --device-only        M4 dev loop: run ONLY the 25 WebMIDI device
                       assertions (D1..D25) against --url, in their own
                       throwaway browser -- the fast cycle for the M4
                       sabotage sweep, not part of the documented
                       pass/fail contract (the full run and check-site
                       both run the same suite as part of everything
                       else).
  --check-storage-refused
                       M3 harness item C, negative control c3 -- NOT part
                       of the ordinary pass/fail run, and NOT invoked by
                       check-site.sh: a standalone diagnostic against
                       --url (a real running app). Launches its own
                       throwaway browser, injects a script (via CDP's
                       Page.addScriptToEvaluateOnNewDocument) that makes
                       window.localStorage's setItem/getItem/removeItem
                       all throw -- a realistic private-mode-style
                       failure (the object itself stays present and
                       accessible; only calling its methods throws,
                       exactly the shape Progress.Store's own guarded
                       probe is meant to catch) -- then reports whether
                       the app boots and #sxc1-progress ends up with
                       "available":false, or names whatever actually
                       happened. See this task's final report for why
                       this is a separate opt-in mode rather than a
                       gating assertion.
  --check-content-missing
                       M6 W1 fetch-failure degradation check, invoked by
                       check-site.sh against a served COPY of the bundle
                       whose content/ directory (the exercise content
                       bundles) has been removed: the app must still
                       boot (the JS-side content guard in index.js must
                       swallow the failed load), render the VISIBLE
                       #sxc1-content-error banner naming the failure,
                       keep a manual page fully readable, and offer
                       #btn-content-retry on the exercise routes. Exits
                       0 only when all four hold -- red-first
                       demonstrated by breaking the index.js guard
                       (rethrowing from the load path kills boot, which
                       this mode reports as its own FAIL).
  --check-bad-bundle   M6 gate round 1 (finding M6-R1-1) bad-body check,
                       invoked by check-site.sh against a served tree
                       carrying six sibling copies of the bundle:
                       wrong-language/, stale/, truncated/, zero-deck/,
                       missing-deck/ (each a 200 response with a
                       DIFFERENT kind of wrong content bundle) and
                       healthy/ (the untouched control). Every sabotaged
                       copy must produce the visible #sxc1-content-error
                       alert AND zero decks in #sxc1-exercise-stats with
                       the degraded #/x notice -- never a smaller-but-
                       "healthy" course; the control must show no banner
                       and the whole 52-deck course. Nothing is injected:
                       the served bytes are the input.
  --check-content-stalled
                       M6 gate round 1 (finding M6-R1-5) stalled-fetch
                       check, invoked by check-site.sh against a server
                       that answers ./content/content.en.txt with 200 +
                       headers and then NEVER completes the body. The
                       app must boot anyway (index.js's AbortController
                       deadline, not the server, ends the wait), name the
                       timeout in the visible banner, keep the manuals
                       readable and offer #btn-content-retry. Red-first:
                       without the deadline the page never boots and this
                       mode reports 0/4.
  --check-hint-write-failure
                       M6 gate round 1 (finding M6-R1-4) UI/content
                       language-split check. Injects a setItem that
                       throws for the key "sxc1.uilang" and ONLY that key
                       (per-key quota / revoked key), clicks #btn-ui-lang
                       once, and requires: no reload (a window marker
                       survives), #sxc1-progress reporting uiLang=ja +
                       contentLang=en + available=false, a VISIBLE
                       #sxc1-lang-split alert with #btn-lang-resync, and
                       document.documentElement.lang switched to 'ja'.
                       Red-first: the pre-fix app reloads on the stale
                       hint and reports 0/4.
  --check-ja-toggle    M6 W2 UI-language roundtrip check, invoked by
                       check-site.sh against a served COPY of the bundle
                       whose ja content bundle carries ONE injected ja:
                       fixture variant (never content/ itself): on a
                       FRESH profile the app must boot EN (fetching
                       content.en.txt), switch to JA through the real
                       #btn-ui-lang (persisting the pref + the
                       sxc1.uilang boot hint, then reloading -- the
                       reload IS the refetch, proven by the fresh
                       document's own resource entries naming
                       content.ja.txt), render the Japanese header and
                       the injected JA exercise title, fire ruling 4's
                       one-time jaFirst suggestion (fresh profile ==
                       never explicitly set), drive a JA device flow
                       (fake-midi injected: enable, JA status/waiting
                       sentences with the describeSpec JA renderer, then
                       a device-confirmed JA sentence), and switch back
                       to EN. Exits 0 only when every assertion holds.
  --check-bad-manual-bundle
                       M7 W1 (briefs/M7-plan.md ruling 1) bad-body check
                       for the MANUAL bundle -- the manual counterpart of
                       --check-bad-bundle, and built on the same
                       openCheckSession helper. check-site.sh serves
                       seven sibling copies from one server: six whose en
                       manual bundle is broken differently (wrong
                       language, altered text, delimiter-complete
                       truncation, zero documents, one document removed
                       with the header adjusted, and the file absent) and
                       one untouched. Every broken copy must show the
                       VISIBLE #sxc1-content-error alert and the named
                       #sxc1-manual-degraded body with #btn-content-retry
                       on a real manual route, WHILE the exercise course
                       still reports its whole 52 decks; the control must
                       show no banner, a readable manual page and the
                       whole course. 14/14. Nothing is injected: the
                       SERVED BYTES are the input.
  --check-manual-fallback
                       M7 ruling 4, FLIPPED BY W3 now that every document
                       is Japanese. Against a served copy of the SHIPPED
                       bundles, on a fresh profile: under EN no
                       #sxc1-manual-fallback exists at all; after the
                       app's own #btn-ui-lang switch (persist + reload =
                       refetch) the ja bundle really loaded, the note
                       exists NOWHERE under ja either (no reading route,
                       no TOC, no home card), the page body carries no
                       lang override, and ALL FOUR documents render their
                       own pinned Japanese sentence. 5/5, ids MF1..MF5.
                       The MECHANISM is unchanged -- View.Pages still
                       renders the note for any document whose record
                       names another language -- so a future
                       untranslated document is caught by check-site's
                       precondition for this stage (every !SXC1-DOC in
                       the served manuals.ja.txt must say 'ja').
  --help               Show this help and exit

By default (no --quick) the page-route sweep visits all 108 routes in
their '/ja' form and awaits a real image decode for every one -- this is
the authoritative decoder for the project's page images (see NEW6). A
separate assertion also opens a genuinely fresh browser target whose
initial URL already carries a JA deep-link hash, to catch a cold-load
regression that a warm hashchange-only check cannot see (see NEW5).

A full run given --exercise-fixture also runs the M6 UI-language flow:
the whole exercise/a11y assertion set a second time under uiLang=ja,
plus (M6 W4) the five JA COURSE assertions -- the shipped ja bundle's
own deck/exercise totals, a real corpus deck title and summary:, a real
corpus quiz completed in Japanese (title, question, both option labels,
graded feedback and rationale) and a real corpus drill step's Japanese
check: sentence, every expectation a LITERAL pinned from
content/exercises/ so an EN-fallback ja bundle turns them red.`);
}

// ---------------------------------------------------------------------------
// Small utilities
// ---------------------------------------------------------------------------

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Remove a temp directory, retrying for a bit: Chrome's headless "browser"
// process forks helper processes (zygote, GPU, renderer, crashpad handler)
// that can still hold files open under --user-data-dir for a short while
// after the main process we spawned has already reported its 'exit' event,
// so a single rmSync attempt can race a lingering child and fail.
async function removeDirWithRetry(dir, attempts = 15, delayMs = 200) {
  for (let i = 0; i < attempts; i++) {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
      return;
    } catch (err) {
      if (i === attempts - 1) {
        console.error(`warning: could not fully remove temp directory ${dir}: ${err.message}`);
        return;
      }
      await sleep(delayMs);
    }
  }
}

// Find an unused TCP port by binding to port 0 and reading back what the OS
// assigned, then closing the listener before anyone else can grab it.
function findFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

// Fetch and JSON-parse a URL using node:http only.
function httpGetJson(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => {
        try {
          resolve(JSON.parse(body));
        } catch (err) {
          reject(err);
        }
      });
    });
    req.on('error', reject);
    req.setTimeout(2000, () => req.destroy(new Error('http request timed out')));
  });
}

// Poll a plain GET until it succeeds (used to wait for the static file
// server to come up), bounded by `deadline` (a Date.now()-style timestamp).
function waitForHttpOk(url, deadline) {
  return new Promise((resolve, reject) => {
    const attempt = () => {
      const req = http.get(url, (res) => {
        res.resume();
        resolve();
      });
      req.on('error', () => {
        if (Date.now() >= deadline) reject(new Error(`timed out waiting for ${url}`));
        else setTimeout(attempt, 150);
      });
      req.setTimeout(1000, () => req.destroy());
    };
    attempt();
  });
}

// Resolve an executable by name against PATH (a minimal `which`).
function which(cmd) {
  const dirs = (process.env.PATH || '').split(path.delimiter).filter(Boolean);
  for (const dir of dirs) {
    const candidate = path.join(dir, cmd);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch {
      // not found here, keep looking
    }
  }
  return null;
}

function resolveBrowser(explicitPath) {
  if (explicitPath) return explicitPath;
  if (process.env.SXC1_BROWSER) return process.env.SXC1_BROWSER;
  for (const name of ['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser']) {
    const found = which(name);
    if (found) return found;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Deadline plumbing (carried over from M0/M4 unchanged).
//
// The whole run shares ONE monotonic deadline, computed once in main() from
// --timeout. `remaining()` reports the budget left; `withDeadline()` races
// an arbitrary promise against it. Every await that could otherwise hang --
// the WebSocket handshake (connectWebSocket), the DevTools HTTP poll, and
// (via CDPClient.send's own per-command timer, which consults the same
// clock through a `getRemaining` callback) every CDP command including the
// boot- and page-sweep-polling loops that repeatedly call it -- is bounded
// by this single clock.
// ---------------------------------------------------------------------------

// Milliseconds left until `deadline` (a Date.now()-style timestamp). Can be
// negative once the deadline has passed.
function remaining(deadline) {
  return deadline - Date.now();
}

// Race `promise` against the remaining deadline budget. Rejects with a
// clearly labelled error the instant the budget runs out; otherwise settles
// exactly as `promise` does. Never leaves a dangling timer behind.
function withDeadline(promise, deadline, label) {
  return new Promise((resolve, reject) => {
    const budget = remaining(deadline);
    if (budget <= 0) {
      reject(new Error(`${label} exceeded the --timeout budget`));
      return;
    }
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      reject(new Error(`${label} exceeded the --timeout budget`));
    }, budget);
    promise.then(
      (value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(value);
      },
      (err) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        reject(err);
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Minimal Chrome DevTools Protocol client over the global WebSocket.
//
// CDP messages are JSON. Commands carry a monotonically increasing `id`;
// the matching response echoes that `id`. Everything else that arrives is
// an event, dispatched by its `method` name. In "flat" session mode
// (Target.attachToTarget with flatten:true) session-scoped commands and
// events carry a `sessionId` alongside the usual fields, sharing the same
// `id` counter and the same websocket connection as the browser-level
// (session-less) commands.
// ---------------------------------------------------------------------------

class CDPClient {
  constructor(ws, { getRemaining } = {}) {
    this.ws = ws;
    this.nextId = 1;
    this.pending = new Map(); // id -> {resolve, reject}
    this.eventHandlers = new Map(); // method -> [handler(params, sessionId)]
    this.getRemaining = getRemaining || (() => Infinity);
    this.fatalError = null; // set once the socket/browser is known dead
    ws.addEventListener('message', (ev) => this._onMessage(ev));
  }

  _onMessage(ev) {
    let msg;
    try {
      msg = JSON.parse(ev.data);
    } catch {
      return;
    }
    if (msg.id !== undefined) {
      const pending = this.pending.get(msg.id);
      if (!pending) return;
      this.pending.delete(msg.id);
      if (msg.error) {
        pending.reject(new Error(`CDP error ${msg.error.code}: ${msg.error.message}`));
      } else {
        pending.resolve(msg.result);
      }
    } else if (msg.method) {
      const handlers = this.eventHandlers.get(msg.method);
      if (handlers) {
        for (const h of handlers) h(msg.params, msg.sessionId);
      }
    }
  }

  on(method, handler) {
    if (!this.eventHandlers.has(method)) this.eventHandlers.set(method, []);
    this.eventHandlers.get(method).push(handler);
  }

  // Send a CDP command, bounded by the shared deadline via getRemaining().
  // A per-command timer guarantees that a dropped response (the peer never
  // replies, e.g. because the socket died without a clean 'close' event)
  // rejects the call instead of leaking a pending entry forever; the timer
  // is cleared the instant the promise settles by any route -- a real
  // response, the timer itself, or failFatally().
  send(method, params = {}, sessionId) {
    return new Promise((resolve, reject) => {
      if (this.fatalError) {
        reject(this.fatalError);
        return;
      }
      const budget = this.getRemaining();
      if (budget <= 0) {
        reject(new Error(`CDP command '${method}' exceeded the --timeout budget`));
        return;
      }

      const id = this.nextId++;
      const payload = { id, method, params };
      if (sessionId) payload.sessionId = sessionId;

      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP command '${method}' exceeded the --timeout budget (no response received)`));
      }, budget);

      this.pending.set(id, {
        resolve: (value) => { clearTimeout(timer); resolve(value); },
        reject: (err) => { clearTimeout(timer); reject(err); },
      });

      try {
        this.ws.send(JSON.stringify(payload));
      } catch (err) {
        this.pending.delete(id);
        clearTimeout(timer);
        reject(err);
      }
    });
  }

  // Reject every currently-pending command with `err` and clear them, so
  // none can outlive whatever just killed the connection (socket
  // close/error, browser process exit/error). Also remembers `err` so any
  // command sent *after* this point fails immediately instead of hanging
  // on a socket already known to be dead.
  failFatally(err) {
    if (!this.fatalError) this.fatalError = err;
    for (const [, entry] of this.pending) {
      entry.reject(err);
    }
    this.pending.clear();
  }

  close() {
    try { this.ws.close(); } catch { /* already closed */ }
  }
}

// Format a WebSocket 'error' event for a diagnostic message. Node's
// WebSocket ErrorEvent commonly stringifies to the unhelpful
// "[object ErrorEvent]"; the actual cause (a plain Error, when present)
// lives on `ev.error`, so prefer its stack, then its message, then the
// event's own `message`, and only fall back to stringifying the event
// itself.
function formatWsErrorEvent(ev) {
  return (ev && ev.error && ev.error.stack)
    || (ev && ev.error && ev.error.message)
    || (ev && ev.message)
    || String(ev);
}

function connectWebSocket(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const onOpen = () => { cleanup(); resolve(ws); };
    const onError = (ev) => { cleanup(); reject(new Error(`WebSocket connect failed: ${formatWsErrorEvent(ev)}`)); };
    const cleanup = () => {
      ws.removeEventListener('open', onOpen);
      ws.removeEventListener('error', onError);
    };
    ws.addEventListener('open', onOpen);
    ws.addEventListener('error', onError);
  });
}

// ---------------------------------------------------------------------------
// M2 exercise engine: the self-test fixture, and the assertion routine
// shared between --self-test/--self-test-negative (driven against the
// fixture below) and a real run (driven against the real app via
// --exercise-fixture) -- briefs/M2-manifest.json, task "exercise-ui":
// "--self-test extension: ... the same assertion code runs against it."
//
// The fixture is a single self-contained HTML document (no server, no
// navigation beyond hash changes) reproducing the DOM contract for one
// quiz, one drill and one lookup exercise in plain JavaScript. It is
// deliberately independent of the real Haskell app: --self-test proves
// the BROWSER ASSERTIONS themselves can fail (and --self-test-negative
// proves it on a SABOTAGED grader), never that the real app matches it.
// ---------------------------------------------------------------------------

const SELF_TEST_FIXTURE = {
  quiz: { deck: 'demo-deck', id: 'demo-quiz', correctOpt: 'opt-a', wrongOpt: 'opt-b', citeSlug: 'guide-book', citePage: 3 },
  // citeSlug/citePage here (H8 gate fix): the real --browser-fixture
  // payload (site/test/CheckExercises.hs's DrillFixture/LookupFixture)
  // carries no citation fields for drill/lookup -- only quiz does -- so
  // this fixture's own drill/lookup citation hrefs are self-test-only
  // constants, never compared against --exercise-fixture. The REAL run's
  // drill assertion checks the href PATTERN only; its lookup assertion
  // checks the page number against fixture.lookup.targetPage, which
  // agrees BY CONSTRUCTION (site/test/CheckExercises.hs's findLookup
  // sets lfTargetPage = citPage of the very find: target it cites).
  drill: { deck: 'demo-deck', id: 'demo-drill', steps: 2, hasVerify: true, citeSlug: 'guide-book', citePage: 5 },
  lookup: { deck: 'demo-deck', id: 'demo-lookup', targetSlug: 'guide-book', targetPage: 7, citeSlug: 'guide-book', citePage: 7 },
};

// The #sxc1-exercise-stats payload the fixture below emits verbatim --
// matches the schema Exercises.Corpus.exerciseStatsJsonOf produces
// (totals + one entry per deck with file/deck/chapter/title/exercises/
// prompts/chars/lines/fnv1a). --self-test's own --expect-exercise-json
// negative control compares against exactly this.
const SELF_TEST_EXERCISE_STATS = {
  totals: { decks: 1, exercises: 3, prompts: 4, quiz: 1, drill: 1, lookup: 1 },
  decks: [
    { file: 'demo-deck.ex.md', deck: 'demo-deck', chapter: 'Front matter', title: 'Demo deck',
      exercises: 3, prompts: 4, chars: 42, lines: 3, fnv1a: 12345 },
  ],
};

// Builds the fixture page. `selector` (a string key, 'legacy-all', or
// null) selects the negative-control sabotage -- M3 gate fix NEW10.
//
// NEW10 background: this used to be one boolean (`sabotage`) that, when
// true, flipped roughly 15 unrelated behaviors at once (every M2-era
// grader AND every M3 progress/JA-first/corrupt/review-queue behavior
// simultaneously) -- so the negative sweep only ever proved "at least
// one thing catches at least one mutation", not that each assertion
// catches ITS OWN named mutation (a gate reviewer showed several M3
// assertions could have their own real comparison deleted and the sweep
// would still report the expected failure, via an unrelated conjunct
// breaking for a different reason -- see this file's own final report
// for the concrete list). `selector` fixes this:
//   null             -- no sabotage at all: the plain --self-test
//                        fixture, and --self-test-negative's own "clean"
//                        sanity pass (proves the selector plumbing
//                        itself has no stray always-on defect).
//   'legacy-all'      -- every M2-era AND M3 sabotage point at once,
//                        BYTE-FOR-BYTE the old global SABOTAGE=true
//                        behaviour. Kept as one combined pass so the
//                        M2-era 8 assertion names (cold-load elapsed,
//                        warm-first elapsed, prompt-baseline, Restart,
//                        drill/lookup citation, wrong-quiz-answer,
//                        wrong-lookup-answer -- H1/H6/H7/H8's own
//                        negative controls) keep a proven combined
//                        negative control -- this task does not attempt
//                        to individually isolate THOSE (M2, not M3;
//                        "keep the M2-era sabotages working the same
//                        way" per this task's own brief).
//   one of the M3_SELECTOR_ASSERTIONS keys below -- exactly ONE M3
//                        sabotage point, isolated from every other one
//                        (see each sabotage site's own comment for
//                        exactly how) -- driven by --self-test-negative
//                        as its own dedicated browser pass, asserting
//                        that EXACTLY that selector's mapped
//                        assertion(s) fail and nothing else does.
//
// `sel(key)` below is true only when `selector` is exactly that key
// (never for 'legacy-all' -- callers that must also fire under the
// combined legacy pass write `sel(key) || LEGACY_ALL` explicitly, so
// the "which sabotage points does legacy-all touch" set stays visible
// at each call site rather than hidden inside `sel` itself).
//
// M3 harness wave: the self-test fixture's own declared deck tier -- must
// match progressCfg.expectedTier at both self-test call sites below, and
// is what "deckCardTierMatches" checks against (an independent constant
// here, not read from any real content/exercises/ file -- the self-test
// fixture is deliberately independent of the real app/content).
const PROGRESS_SELF_TEST_TIER = 'core';

function selfTestFixtureHtml(selector) {
  const fx = SELF_TEST_FIXTURE;
  const statsJson = JSON.stringify(SELF_TEST_EXERCISE_STATS).replace(/</g, '\\u003c');
  const fixtureJson = JSON.stringify(fx).replace(/</g, '\\u003c');
  return `<!doctype html>
<html><head><meta charset="utf-8"><title>sxc1-self-test</title></head>
<body>
<div id="boot-status" hidden></div>
<div id="sxc1-header"></div>
<div id="app">
  <div id="sxc1-exercise-stats" hidden>${statsJson}</div>
  <div id="sxc1-event-log" hidden>[]</div>
  <div id="sxc1-prompt-baseline" hidden>null</div>
  <div id="sxc1-progress" hidden></div>
  <div id="sxc1-device-state" hidden></div>
  <div id="sxc1-root"></div>
</div>
<script>
window.__SXC1_BOOTED = true;
(function () {
  var SELECTOR = ${JSON.stringify(selector || null)};
  var LEGACY_ALL = SELECTOR === 'legacy-all';
  function sel(key) { return SELECTOR === key; }
  var FIXTURE = ${fixtureJson};
  var PROGRESS_DECK_TIER = ${JSON.stringify(PROGRESS_SELF_TEST_TIER)};
  var MANUAL_TOTAL_PAGES = 2;

  // -----------------------------------------------------------------------
  // M6 W2 mirror: the UI-language boot hint + header toggle. Mirrors the
  // real pipeline exactly: site/static/index.js reads the sxc1.uilang
  // hint pre-boot (anything but exactly "ja" is "en") and stamps
  // document.documentElement.lang; the app's PUiLangToggle persists the
  // prefs blob + hint and reloads. trFx() is the fixture's own two-entry
  // string table for the strings the JA-flow assertions pin.
  //   SABOTAGE 'uiLangPref'   (-> UILANG_PREF): the switch keeps the
  //     language in sessionStorage ONLY -- the UI switches (the
  //     rendering keeps working off the session value, so every other
  //     ja assertion stays green) but nothing survives on disk, which
  //     exactly the on-disk assertion must catch.
  //   SABOTAGE 'uiLangHeader' (-> UILANG_HEADER): the header strings
  //     (badge + toggle label) stay EN under ja.
  //   SABOTAGE 'uiLangText'   (-> the ja-pass feedback/verify pins):
  //     the learner-visible body strings stay EN under ja.
  //   SABOTAGE 'uiLangAria'   (-> SR-labels [ja]): the localized
  //     aria-label accessible names stay EN under ja.
  // -----------------------------------------------------------------------
  var UILANG = (function () {
    try {
      var sab = window.sessionStorage.getItem('sxc1.selftest.uilang');
      if (sab === 'ja' || sab === 'en') return sab;
    } catch (e) { /* fall through */ }
    try { return window.localStorage.getItem('sxc1.uilang') === 'ja' ? 'ja' : 'en'; } catch (e) { return 'en'; }
  })();
  try { document.documentElement.lang = UILANG; } catch (e) { /* harmless */ }
  function trFx(en, ja) { return UILANG === 'ja' ? ja : en; }
  function trBody(en, ja) { return sel('uiLangText') ? en : trFx(en, ja); }

  // M6 W1 SABOTAGE 'contentDegraded' (-> CONTENT_ABSENT_ASSERTION_NAME):
  // render the degraded-content surface on a HEALTHY boot -- the exact
  // defect the absent-scenario parity assertion exists to catch (a
  // degraded banner that leaks into ordinary runs). The healthy fixture
  // deliberately has NEITHER element, mirroring the real app, where
  // View.Pages renders them only when the bundle load failed.
  if (sel('contentDegraded')) {
    var degraded = document.createElement('div');
    degraded.id = 'sxc1-content-error';
    degraded.setAttribute('role', 'alert');
    degraded.textContent = 'Exercise content failed to load: SXC1 SELF-TEST sabotage';
    var retryBtn = document.createElement('button');
    retryBtn.id = 'btn-content-retry';
    retryBtn.textContent = 'Reload and try again';
    var appRoot = document.getElementById('app');
    appRoot.insertBefore(degraded, appRoot.firstChild);
    appRoot.insertBefore(retryBtn, appRoot.firstChild.nextSibling);
  }

  // -----------------------------------------------------------------------
  // M5 a11y mirror -- the fixture-side halves of the app's a11y pass, so
  // the SAME shared assertions (keyboard-only completion, focus on
  // advance, SR labels) run against both targets, each with its own
  // named sabotage:
  //   focusEl        mirrors Main.hs's advance-focus wiring (a deferred
  //                  getElementById(id).focus(), like Miso's callFocus).
  //                  SABOTAGE 'a11yFocusAdvance': the move never happens,
  //                  so focus is stranded on <body> after every advance
  //                  (quiz Next, drill confirm -- manual AND device).
  //   CTL_TAG        the tag primary in-prompt controls render as.
  //                  SABOTAGE 'a11yKeyboard': click-only <span>s (the
  //                  classic div-button defect) -- ids/classes/handlers
  //                  identical, so every .click()-driven assertion still
  //                  passes and EXACTLY the three keyboard-only flows
  //                  fail (spans are unfocusable and ignore Enter).
  //   *_ATTR         the ARIA surface (live regions + accessible names).
  //                  SABOTAGE 'a11ySrLabels': all omitted.
  // -----------------------------------------------------------------------
  function focusEl(id) {
    if (sel('a11yFocusAdvance')) return;
    setTimeout(function () { var e = document.getElementById(id); if (e && e.focus) e.focus(); }, 30);
  }
  var CTL_TAG = sel('a11yKeyboard') ? 'span' : 'button';
  var ARIA_LIVE_ATTR = sel('a11ySrLabels') ? '' : ' aria-live="polite"';
  var CHAN_LABEL_ATTR = sel('a11ySrLabels') ? '' : ' aria-label="MIDI listening channel"';
  // M6 W2: the export textarea's accessible name localizes (a11y parity
  // -- the SR-labels assertion pins the EXACT per-language string).
  var EXPORT_ARIA_NAME = sel('uiLangAria') ? 'Exported progress data' : trFx('Exported progress data', 'エクスポートされた進捗データ');
  var EXPORT_LABEL_ATTR = sel('a11ySrLabels') ? '' : (' aria-label="' + EXPORT_ARIA_NAME + '"');
  var SUMMARY_HTML = '<section id="ex-summary" tabindex="-1"><p>You have completed this exercise.</p></section>';

  // -----------------------------------------------------------------------
  // M3 harness wave: a small, self-contained, DELIBERATELY INDEPENDENT
  // mirror of SXC1.Progress.* (mini scheduler + mini wire codec) and of
  // Progress.Store's localStorage keys/never-overwrite rule -- see the
  // big comment above runProgressAssertionsPre/Post in this file for why
  // this exists and what it is (and is not) proving. Everything in this
  // block is fixture-only: it never asks the real Haskell implementation
  // to grade itself.
  // -----------------------------------------------------------------------
  var PROG_KEY = 'sxc1.progress';
  var PREFS_KEY = 'sxc1.prefs';
  var PROG_TODAY = Math.floor(Date.now() / 86400000);
  var EASE_DELTA = { GAgain: -320, GHard: -140, GGood: 0, GEasy: 100 };

  // -----------------------------------------------------------------------
  // NEW10: SELF-TEST-ONLY bookkeeping (never part of the real app's own
  // contract -- this whole block exists only so the sabotage points below
  // can tell WHICH of the several "empty"/"just wiped"/"just imported"
  // moments in runProgressAssertionsPre/Post's fixed script they are
  // currently being read at, so a selector can corrupt exactly ONE of
  // them). Persisted in sessionStorage (survives an ordinary Page.reload
  // of the SAME tab/session -- exactly what runProgressAssertionsPost's
  // own reloads are -- but starts fresh in every NEW browser launch, which
  // is what each --self-test-negative selector pass gets, one per pass).
  //   everBooted       -- was ANY earlier script execution in this
  //                       session already recorded? Captured into
  //                       IS_FIRST_BOOT_EVER (below) BEFORE being set,
  //                       so it is true for exactly the very first-ever
  //                       render (the "freshRecords" moment) and false
  //                       for every render after that, including later
  //                       ones in this SAME first boot.
  //   wipeCount        -- how many #btn-progress-wipe-confirm clicks have
  //                       landed so far, across the WHOLE run (PRE never
  //                       wipes; POST's fixed script wipes at well-known
  //                       points -- see each wipe-confirm handler call
  //                       site's own comment for which count value is
  //                       which named moment).
  //   answersSinceWipe -- gradeQuizPromptForProgress calls (real,
  //                       non-guard-blocked ones only) since the last
  //                       wipe -- resets to 0 on every wipe.
  //   importCount      -- successful (kind==='ok') import commits so far.
  //   corruptBannerReads -- renderHome() calls so far while
  //                       CURRENT_PROGRESS.kind==='corrupt' -- lets
  //                       "corruptBanner" sabotage the FIRST such render
  //                       only (its own assertion's read point) without
  //                       also corrupting "corruptNeverOverwritten"'s
  //                       LATER, independent bannerStillShown read.
  //   jaFirstOnSaves    -- saveJaFirst(true) calls so far -- lets
  //                       "jaFirstPersist" sabotage the FIRST one only
  //                       (D1's own read point) without also denying D2
  //                       ("jaFirstSurvivesWipe") and D3
  //                       ("jaToggleHidesAndSticks") the genuine,
  //                       persisted "jaFirst on" baseline THEIR OWN
  //                       claims need -- see runProgressAssertionsPost's
  //                       own D1b comment.
  // -----------------------------------------------------------------------
  function readSelfTestState() {
    try {
      var raw = window.sessionStorage.getItem('sxc1.selftest.state');
      if (raw) return JSON.parse(raw);
    } catch (e) { /* fall through to a fresh state */ }
    return { everBooted: false, wipeCount: 0, answersSinceWipe: 0, importCount: 0, corruptBannerReads: 0, jaFirstOnSaves: 0 };
  }
  var ST = readSelfTestState();
  var IS_FIRST_BOOT_EVER = !ST.everBooted;
  function writeSelfTestState() {
    ST.everBooted = true;
    try { window.sessionStorage.setItem('sxc1.selftest.state', JSON.stringify(ST)); } catch (e) { /* best effort */ }
  }
  writeSelfTestState();
  // NOTE ON ESCAPING: this whole fixture is LITERAL TEXT inside
  // browser-check.mjs's own outer JS template literal (the backtick
  // string this function returns), which means the OUTER template
  // literal's own backslash-escape processing already runs once on
  // every character below before the browser ever sees it -- a backslash
  // followed by the letter t, or by the letter n, written directly here
  // would arrive as a REAL tab or newline character already spliced into
  // the fixture's SOURCE CODE (breaking any string literal it lands
  // inside), and an unrecognised escape (backslash followed by the
  // letter s, for instance) would arrive with its backslash silently
  // dropped. TAB/NL/BS below side-step the whole class of bugs: no
  // backslash character ever appears in this fixture's literal text, so
  // the outer template literal has nothing to mis-escape.
  var TAB = String.fromCharCode(9);
  var NL = String.fromCharCode(10);
  var BS = String.fromCharCode(92);

  // -----------------------------------------------------------------------
  // M4 harness wave: a small, self-contained, DELIBERATELY INDEPENDENT
  // mirror of the app's device layer (Device.Midi + Main's reconciler /
  // stale-confirm guard / #sxc1-device-state payload) -- the same
  // discipline as the M3 progress mini-mirror above: --self-test proves
  // the D-assertions THEMSELVES can fail (each 'dev*' selector below
  // sabotages exactly one decision point), never that the real app
  // matches this fixture. The fixture drill carries TWO verify hooks so
  // both spec kinds are exercised: step 1 "cc 80 127", step 2
  // "pad 1 bank A" (note 36).
  //
  // The device-confirm APPLY path deliberately runs in TWO queued hops
  // (match -> guard -> guard+apply), mirroring the real app's action
  // queue after the M4 gate-1 HIGH-finding fix (hub callback -> DConfirm
  // guard -> clock read -> DApplyConfirm, which re-runs the FULL guard
  // at batch-application time). The guard carries an ATTEMPT GENERATION
  // (DEV.gen -- bumped on drill load, Restart, and every device
  // enable/disable, captured into the watch at arm time), because a
  // Restart lands the cursor back on the very promptId a stale confirm
  // captured and only the generation can tell the two attempts apart.
  // The one-shot, stale-confirm and in-flight sabotages are observable
  // the same way they would be in the app.
  // -----------------------------------------------------------------------
  var DRILL_SPECS = [
    { kind: 'cc', num: 80, values: [127], text: 'cc 80 127' },
    { kind: 'note', notes: [36], text: 'pad 1 bank A' }
  ];
  var DEV = {
    supported: (typeof navigator.requestMIDIAccess === 'function'),
    status: 'off',
    channel: 1,
    ports: [],
    allPorts: [],
    lastMessage: null,
    lastChannel: null,
    access: null,
    boundPorts: [],
    watchingPrompt: null,
    skipNextReconcile: false,
    // The attempt generation and the generation the active watch was
    // armed under (the app's mAttemptGen / dcWatch pair).
    gen: 0,
    watchGen: 0
  };
  if (!DEV.supported) DEV.status = 'unsupported';
  var drillConfirms = [];
  // SABOTAGE, selector 'devBootRequest' (-> D3): request the permission
  // at boot, with no learner click -- exactly what constraint 2 forbids.
  if (sel('devBootRequest') && DEV.supported) {
    try {
      // The result (and the real browser's rejection, when no fake is
      // installed) is deliberately swallowed: the sabotage is the CALL
      // happening at boot, which D3 reads off the fake's calls array.
      navigator.requestMIDIAccess({ sysex: false }).then(function () { }, function () { });
    } catch (e) { /* ignored */ }
  }

  function onDrillRoute() {
    var parts = location.hash.replace(/^#/, '').split('/').filter(Boolean);
    return parts.length === 3 && parts[0] === 'x' && parts[2] === FIXTURE.drill.id;
  }
  function onQuizRoute() {
    var parts = location.hash.replace(/^#/, '').split('/').filter(Boolean);
    return parts.length === 3 && parts[0] === 'x' && parts[2] === FIXTURE.quiz.id;
  }
  function currentDrillPrompt() {
    if (!onDrillRoute()) return null;
    if (drillCursor >= FIXTURE.drill.steps) return null;
    return FIXTURE.drill.id + '#' + (drillCursor + 1);
  }
  function specTextFor(prompt) {
    var idx = parseInt(prompt.split('#')[1], 10) - 1;
    return DRILL_SPECS[idx] ? DRILL_SPECS[idx].text : '';
  }

  function devUpdateState() {
    var el = document.getElementById('sxc1-device-state');
    if (!el) return;
    el.textContent = JSON.stringify({
      supported: DEV.supported,
      status: DEV.status,
      channel: DEV.channel,
      ports: DEV.ports,
      allPorts: DEV.allPorts,
      watching: DEV.watchingPrompt
        ? { prompt: DEV.watchingPrompt, spec: specTextFor(DEV.watchingPrompt) }
        : null,
      lastMessage: DEV.lastMessage,
      lastChannel: DEV.lastChannel,
      confirms: onDrillRoute() ? drillConfirms.slice() : []
    });
    devRefreshPanel();
  }

  // The reconciler mirror: the desired watch is the drill route's current
  // step, when it exists and is unanswered (the fixture's cursor only
  // ever sits on unanswered steps). Arming (or re-arming) captures the
  // CURRENT attempt generation into DEV.watchGen -- the app captures it
  // at dvWatch-subscribe time in reconcileWatch. SABOTAGE
  // 'devStaleConfirm' (-> D15): a MANUAL confirm skips the disarm
  // exactly once, so the previous step's watch stays armed -- the stale
  // state the app's guard exists to make harmless. SABOTAGE
  // 'devKeepWatchOnNav' (-> D16): a route move away from the drill
  // never disarms.
  function devReconcile() {
    if (DEV.skipNextReconcile) { DEV.skipNextReconcile = false; devUpdateState(); return; }
    var desired = currentDrillPrompt();
    if (sel('devKeepWatchOnNav') && desired === null && DEV.watchingPrompt !== null) {
      devUpdateState();
      return;
    }
    var changed = DEV.watchingPrompt !== desired;
    DEV.watchingPrompt = desired;
    DEV.watchGen = DEV.gen;
    // Keep the verify lines' waiting/idle classes in step with the watch
    // (the real app re-renders everything on every action; this fixture
    // must do it by hand). renderDrill never calls back into
    // devReconcile, so this cannot recurse.
    if (changed && onDrillRoute()) renderDrill();
    devUpdateState();
  }

  function devDecode(bytes) {
    if (!bytes.length) return null;
    var s = bytes[0];
    if (s < 128 || s >= 240) return null;
    var ch = (s % 16) + 1;
    var kind = s - (s % 16);
    if (kind === 176 && bytes.length === 3) return { channel: ch, kind: 'cc', a: bytes[1], b: bytes[2] };
    if (kind === 144 && bytes.length === 3) return { channel: ch, kind: 'note', a: bytes[1], b: bytes[2] };
    return { channel: ch, kind: 'other' };
  }

  // The matcher mirror, with one named sabotage per decision point --
  // each maps to exactly one D-assertion:
  //   'devIgnoreChannel' (-> D10)  drop the channel test
  //   'devWrongCC'       (-> D8)   compare no CC number
  //   'devIgnoreValue'   (-> D9)   ignore the value list
  //   'devPadAnyNote'    (-> D11)  any note satisfies a pad spec
  function devMatches(prompt, m) {
    if (!m || m.kind === 'other') return false;
    if (!sel('devIgnoreChannel') && m.channel !== DEV.channel) return false;
    var idx = parseInt(prompt.split('#')[1], 10) - 1;
    var spec = DRILL_SPECS[idx];
    if (!spec) return false;
    if (spec.kind === 'cc') {
      if (m.kind !== 'cc') return false;
      if (!sel('devWrongCC') && m.a !== spec.num) return false;
      if (!sel('devIgnoreValue') && spec.values.indexOf(m.b) === -1) return false;
      return true;
    }
    if (m.kind !== 'note') return false;
    if (!sel('devPadAnyNote') && spec.notes.indexOf(m.a) === -1) return false;
    return true;
  }

  function devApplyConfirm(stepIdx) {
    pushEvent(FIXTURE.drill.id, 'drill', 'correct', drillStepAt, FIXTURE.drill.id + '#' + (stepIdx + 1));
    drillConfirms.push({ prompt: FIXTURE.drill.id + '#' + (stepIdx + 1), source: 'device' });
    drillCursor += 1;
    drillStepAt = Date.now();
    if (onDrillRoute()) renderDrill();
    devReconcile();
    // M5 a11y (D26): a DEVICE confirm moves the cursor with no click to
    // carry focus -- the same advance-focus move as the manual path
    // (Main.hs's DApplyConfirm applies the same [ConfirmStep, Advance]).
    if (onDrillRoute()) focusEl(drillCursor >= FIXTURE.drill.steps ? 'ex-summary' : ('ex-step-' + (drillCursor + 1)));
  }

  // The FULL stale-confirm guard mirror (the app's guardedConfirmIx,
  // M4 gate-1 HIGH-finding restructure), re-run at BOTH hops of the
  // confirm path -- the second run at application time. Each named
  // sabotage opens exactly one hole:
  //   'devStaleConfirm'     (-> D15)      the cursor/answered half
  //                         degrades to "still on the drill route", so
  //                         a confirm captured for an already-passed
  //                         step applies anyway
  //   'devConfirmAcrossNav' (-> D23)      a confirm whose context
  //                         NAVIGATED away between match and apply is
  //                         applied anyway
  //   'devIgnoreGen'        (-> D24, D25) the attempt-generation
  //                         re-check is dropped -- one root cause, two
  //                         in-flight orderings (Restart and disable),
  //                         the honest single-root-cause grouping the
  //                         map already uses for 'devPanelAlways'
  function devConfirmGuardOk(captured) {
    var promptOk = currentDrillPrompt() === captured.prompt;
    if (sel('devStaleConfirm')) promptOk = onDrillRoute();
    if (sel('devConfirmAcrossNav') && !onDrillRoute()) promptOk = true;
    // SABOTAGE 'devNotOneShot' (-> D14), SECOND layer: the at-most-once
    // invariant is defended twice -- the watch disarms at match time
    // (the hub's one-shot removal) AND a duplicate delivery that slipped
    // past it still fails this guard's cursor-prompt re-check at apply
    // time. Post gate-1 restructure the second layer alone masks a
    // missing first (a duplicate apply of an already-device-confirmed
    // prompt is simply dropped here), so sabotaging only the disarm
    // would demonstrate the defense-in-depth, never a red D14. The
    // selector therefore breaches the INVARIANT at both layers: no
    // disarm (see devOnMessage) and, here, a captured prompt this
    // attempt already device-confirmed passes anyway. Scoped to
    // source 'device' so D15's learner-confirmed stale prompt stays
    // guarded under every other selector's pass.
    if (sel('devNotOneShot') && drillConfirms.some(function (c) { return c.prompt === captured.prompt && c.source === 'device'; })) promptOk = true;
    var genOk = captured.gen === DEV.gen || sel('devIgnoreGen');
    return promptOk && genOk;
  }

  function devOnMessage(ev) {
    var bytes = Array.prototype.slice.call(ev.data);
    DEV.lastMessage = bytes;
    var m = devDecode(bytes);
    DEV.lastChannel = m ? m.channel : null;
    // SABOTAGE trio (-> D21, one selector per exfiltration class): a
    // hostile handler leaks the received MIDI bytes over a SAME-ORIGIN
    // request. Every one of these fetches fails on the fixture's
    // file:// page and that is fine: CDP's Network domain still records
    // requestWillBeSent for each (measured -- see the M4 gate-1 and
    // gate-2 task reports), which is all D21's post-boot zero-delta
    // collector reads.
    //   'devSameOriginEgress'  (gate-1) -- bytes in a QUERY STRING:
    //     exactly the class the pre-gate-1 D21 (cross-origin-only
    //     filter) let through, and the class the zero-delta failure
    //     message still labels separately (d21QueryStringEgress).
    //   'devShapedPathEgress'  (gate-2) -- query-FREE: the bytes ARE
    //     the filename of a path matching gate-1's asset-shape
    //     allowlist (vendor/browser_wasi_shim/<b1>-<b2>-<b3>.js, e.g.
    //     144-36-64.js for a note-on -- the request reaches the server
    //     even as a 404), which shape matching can never reject and
    //     only the zero-delta rule catches.
    //   'devRepeatAssetEgress' (gate-2) -- query-free AND
    //     shape-perfect: an extra fetch of the real 'app.wasm' (the
    //     data rides the request count/timing channel), equally
    //     invisible to any shape allowlist.
    if (sel('devSameOriginEgress')) {
      try { fetch('collect?bytes=' + bytes.join('-')).catch(function () { /* the request event is what matters */ }); } catch (e) { /* ditto */ }
    }
    if (sel('devShapedPathEgress')) {
      try { fetch('vendor/browser_wasi_shim/' + bytes.join('-') + '.js').catch(function () { /* the request event is what matters */ }); } catch (e) { /* ditto */ }
    }
    if (sel('devRepeatAssetEgress')) {
      try { fetch('app.wasm').catch(function () { /* the request event is what matters */ }); } catch (e) { /* ditto */ }
    }
    if (DEV.watchingPrompt && devMatches(DEV.watchingPrompt, m)) {
      // What the app captures at subscribe time: the promptId AND the
      // attempt generation its watch was armed under.
      var captured = { prompt: DEV.watchingPrompt, gen: DEV.watchGen };
      // SABOTAGE 'devNotOneShot' (-> D14): the matched watch is not
      // removed, so a second message in the same turn matches again.
      if (!sel('devNotOneShot')) DEV.watchingPrompt = null;
      setTimeout(function () {
        // hop 1 -- the app's DConfirm validation (before its clock read).
        if (!devConfirmGuardOk(captured)) { devUpdateState(); return; }
        setTimeout(function () {
          // hop 2 -- the app's DApplyConfirm: the SAME full guard again,
          // at application time, against whatever state exists NOW --
          // anything that landed between the hops (navigation, Restart,
          // a manual confirm, a device toggle) is seen here.
          if (!devConfirmGuardOk(captured)) { devUpdateState(); return; }
          devApplyConfirm(drillCursor);
        }, 0);
      }, 0);
    }
    devUpdateState();
  }

  function devBindPorts() {
    DEV.boundPorts.forEach(function (p) { p.onmidimessage = null; });
    DEV.boundPorts = [];
    DEV.ports = [];
    DEV.allPorts = [];
    if (!DEV.access) { devUpdateState(); return; }
    var all = Array.from(DEV.access.inputs.values());
    DEV.allPorts = all.map(function (p) { return p.name; });
    var low = function (s) { return String(s || '').toLowerCase(); };
    var hasAny = function (p, needles) {
      return needles.some(function (ndl) {
        return low(p.name).indexOf(ndl) !== -1 || low(p.manufacturer).indexOf(ndl) !== -1;
      });
    };
    var chosen = all.filter(function (p) { return hasAny(p, ['sxc-1', 'sxc1', 'sxc 1']); });
    if (chosen.length === 0) chosen = all.filter(function (p) { return hasAny(p, ['casio']); });
    // SABOTAGE 'devNoFallback' (-> D13): bind only name-matched ports.
    if (chosen.length === 0 && !sel('devNoFallback')) chosen = all;
    // SABOTAGE 'devBindAll' (-> D12): bind every port, selected or not.
    if (sel('devBindAll')) chosen = all;
    chosen.forEach(function (p) { p.onmidimessage = devOnMessage; });
    DEV.boundPorts = chosen;
    DEV.ports = chosen.map(function (p) { return p.name; });
    devUpdateState();
  }

  function devEnable() {
    if (!DEV.supported || DEV.status === 'pending') return;
    // Parity with the app's DEnable: the attempt generation bumps on
    // EVERY enable/disable click, before the watch is re-armed, so a
    // confirm in flight across the toggle fails the gen re-check.
    DEV.gen += 1;
    if (DEV.status === 'granted') {
      // parity with the app: the same button disables when already on
      DEV.boundPorts.forEach(function (p) { p.onmidimessage = null; });
      if (DEV.access) DEV.access.onstatechange = null;
      DEV.access = null;
      DEV.boundPorts = [];
      DEV.ports = [];
      DEV.allPorts = [];
      DEV.lastMessage = null;
      DEV.lastChannel = null;
      DEV.status = 'off';
      DEV.watchingPrompt = null;
      devReconcile();
      return;
    }
    DEV.status = 'pending';
    devUpdateState();
    navigator.requestMIDIAccess({ sysex: sel('devSysexTrue') ? true : false }).then(function (access) {
      DEV.access = access;
      access.onstatechange = function () { devBindPorts(); };
      DEV.status = 'granted';
      devBindPorts();
      // Re-arm under the CURRENT generation (the enable click bumped
      // it) -- mirrors the app's DEnable, which runs reconcileWatch
      // after hubEnable. Hot-plug (onstatechange above) deliberately
      // does NOT reconcile: rebinding ports never touches watches.
      devReconcile();
    }, function () {
      DEV.status = 'denied';
      devUpdateState();
    });
  }

  function devVerifyLineHtml(stepN) {
    var spec = DRILL_SPECS[stepN - 1];
    if (!spec) return '';
    var prompt = FIXTURE.drill.id + '#' + stepN;
    var confirmedByDevice = drillConfirms.some(function (c) {
      return c.prompt === prompt && c.source === 'device';
    });
    var cls, sentence;
    if (confirmedByDevice) {
      cls = 'ex-verify-confirmed';
      sentence = 'Confirmed by the device: ' + spec.text + '.';
    } else if (DEV.supported && DEV.status === 'granted' && DEV.watchingPrompt === prompt) {
      cls = 'ex-verify-waiting';
      sentence = 'Waiting for the device: ' + spec.text + ' on MIDI channel ' + DEV.channel + '.';
    } else if (DEV.supported && DEV.status === 'granted') {
      // M5 item 11 parity with View.Exercise: verification is ON but this
      // hooked step is not the armed one -- the idle line must not claim
      // verification is off.
      cls = 'ex-verify-idle';
      sentence = DEV.watchingPrompt
        ? 'Device verification is watching the current step ' + String.fromCharCode(8212) + ' confirm this one manually.'
        : 'Device verification is on ' + String.fromCharCode(8212) + ' confirm this step manually.';
    } else {
      cls = 'ex-verify-idle';
      sentence = trBody(
        'Device verification is off ' + String.fromCharCode(8212) + ' confirm manually, or turn it on above.',
        'デバイス検証はオフです ' + String.fromCharCode(8212) + ' 手動で確認するか、上でオンにしてください。'
      );
    }
    return '<p class="ex-verify ' + cls + '" id="ex-step-' + stepN + '-verify"' + ARIA_LIVE_ATTR + '>' + sentence + '</p>';
  }

  // The device panel mirror. Rendered on the drill route when supported
  // -- and, under SABOTAGE 'devPanelAlways' (-> D1 and D4), always,
  // everywhere, exactly the unconditional render the app must never do.
  function devRefreshPanel() {
    var existing = document.getElementById('ex-device');
    if (existing) existing.parentNode.removeChild(existing);
    var show = (DEV.supported && onDrillRoute()) || sel('devPanelAlways');
    if (!show) return;
    var host = root();
    if (!host) return;
    var label = DEV.status === 'granted' ? 'Disable device verification'
      : DEV.status === 'pending' ? 'Requesting MIDI access...'
        : DEV.status === 'denied' ? 'Retry device access'
          : 'Enable device verification';
    var mismatch = DEV.status === 'granted' && DEV.lastChannel !== null && DEV.lastChannel !== DEV.channel;
    var statusText;
    if (DEV.status === 'off') statusText = 'Device verification is off.';
    else if (DEV.status === 'pending') statusText = 'Waiting for the browser to grant MIDI access.';
    else if (DEV.status === 'denied') statusText = 'The browser denied MIDI access. Confirm each step manually, or re-grant access and try again.';
    else if (DEV.status === 'unsupported') statusText = 'This browser has no Web MIDI support; confirm each step manually.';
    else if (mismatch) statusText = 'Received MIDI on channel ' + DEV.lastChannel + '; this drill is listening on channel ' + DEV.channel + '.';
    else statusText = 'Device verification is on, listening on MIDI channel ' + DEV.channel + '.';
    var portsText = DEV.status === 'granted'
      ? (DEV.ports.length === 0
        ? 'No MIDI input detected ' + String.fromCharCode(8212) + ' check the USB cable and that the unit is on.'
        : 'Bound MIDI input: ' + DEV.ports.join(', '))
      : 'No device bound yet.';
    var options = '';
    for (var ci = 1; ci <= 16; ci++) {
      options += '<option value="' + ci + '"' + (ci === DEV.channel ? ' selected' : '') + '>' + ci + '</option>';
    }
    var el = document.createElement('section');
    el.id = 'ex-device';
    el.innerHTML = '<button id="btn-device-enable" type="button">' + label + '</button>' +
      '<p id="device-status"' + ARIA_LIVE_ATTR + '>' + statusText + '</p>' +
      '<select id="sel-device-channel"' + CHAN_LABEL_ATTR + '>' + options + '</select>' +
      '<p id="device-ports">' + portsText + '</p>' +
      (mismatch ? '<button id="btn-device-use-channel" type="button">Use channel ' + DEV.lastChannel + '</button>' : '');
    host.appendChild(el);
    el.querySelector('#btn-device-enable').addEventListener('click', devEnable);
    el.querySelector('#sel-device-channel').addEventListener('change', function (ev2) {
      var v = parseInt(ev2.target.value, 10);
      if (v >= 1 && v <= 16) { DEV.channel = v; devUpdateState(); }
    });
    var useBtn = el.querySelector('#btn-device-use-channel');
    if (useBtn) useBtn.addEventListener('click', function () {
      DEV.channel = DEV.lastChannel;
      devUpdateState();
    });
  }

  function clamp1_180(x) { return Math.max(1, Math.min(180, x)); }

  function gradeOfOutcomeJs(isCorrect, attempt, revealed, hints) {
    if (!isCorrect) return 'GAgain';
    if (revealed) return 'GHard';
    if (attempt >= 2) return 'GHard';
    if (hints > 0) return 'GGood';
    return 'GEasy';
  }

  // SABOTAGE, selector 'answerReloadInterval' (or legacy-all): a fresh
  // GEasy at reps 0 returns 3 instead of the real scheduler's 2. Every
  // other grade/reps combination this fixture can reach (GAgain always;
  // GEasy reps>=1 is never reached by this fixture's own scripted
  // scenarios) stays correct. This is gated on the selector alone (no
  // phase/counter needed): the ONE assertion that reads an absolute
  // interval value is "answerReloadInterval" itself; the only OTHER
  // assertion that touches an interval at all is
  // "exportWipeImportRestores", which compares recA.interval to
  // recB.interval for EQUALITY -- both sides would be sabotaged
  // identically here, so that comparison still holds and this sabotage
  // cannot leak into it.
  function nextIntervalDaysJs(rec, grade) {
    if (grade === 'GAgain') return 0;
    if (grade === 'GHard') return rec.reps === 0 ? 1 : clamp1_180(Math.floor(rec.interval * 12 / 10));
    if (grade === 'GGood') return rec.reps === 0 ? 1 : (rec.reps === 1 ? 3 : clamp1_180(Math.floor(rec.interval * rec.ease / 1000)));
    if (rec.reps === 0) return (sel('answerReloadInterval') || LEGACY_ALL) ? 3 : 2;
    return rec.reps === 1 ? 5 : clamp1_180(Math.floor(rec.interval * rec.ease * 13 / 10000));
  }

  function applyGradeToRec(existing, grade) {
    var interval = nextIntervalDaysJs(existing, grade);
    var ease = Math.max(1300, Math.min(3000, existing.ease + EASE_DELTA[grade]));
    var reps = grade === 'GAgain' ? 0 : existing.reps + 1;
    var lapses = existing.lapses + ((grade === 'GAgain' && existing.reps > 0) ? 1 : 0);
    return { reps: reps, lapses: lapses, ease: ease, interval: interval, due: PROG_TODAY + interval, lastSeen: PROG_TODAY, seen: existing.seen + 1 };
  }

  // Wire format -- mirrors SXC1.Progress.Codec.hs's documented shape
  // exactly: "SXC1PROGRESS<TAB><ver>" header, "M<TAB>...streak...", one
  // "R<TAB>..." line per record, unknown leading tags skipped.
  function encodeProgWire(recs, streakDay, streakLen) {
    var lines = ['SXC1PROGRESS' + TAB + '1', 'M' + TAB + streakDay + TAB + streakLen + TAB + streakDay];
    Object.keys(recs).forEach(function (pid) {
      var r = recs[pid];
      lines.push(['R', pid, r.reps, r.lapses, r.ease, r.interval, r.due, r.lastSeen, r.seen].join(TAB));
    });
    return lines.join(NL) + NL;
  }

  function decodeProgWire(raw) {
    if (raw == null || raw.trim() === '') return { kind: 'empty', recs: {}, streakDay: 0, streakLen: 0 };
    var lines = raw.split(NL);
    var header = (lines[0] || '').split(TAB);
    if (header[0] !== 'SXC1PROGRESS') return { kind: 'corrupt', recs: {}, streakDay: 0, streakLen: 0, reason: 'missing or malformed SXC1PROGRESS header', raw: raw };
    var recs = {}, streakLen = 0, streakDay = 0;
    for (var i = 1; i < lines.length; i++) {
      var line = lines[i];
      if (line.trim() === '') continue;
      var f = line.split(TAB);
      if (f[0] === 'M' && f.length === 4) { streakDay = parseInt(f[1], 10) || 0; streakLen = parseInt(f[2], 10) || 0; }
      else if (f[0] === 'R' && f.length === 9) {
        recs[f[1]] = { reps: +f[2], lapses: +f[3], ease: +f[4], interval: +f[5], due: +f[6], lastSeen: +f[7], seen: +f[8] };
      }
      // any other leading tag: skipped, matching the real degrade-not-reject rule
    }
    return { kind: 'ok', recs: recs, streakDay: streakDay, streakLen: streakLen };
  }

  // jsonEscape/jsonUnescape/importBlobJs are all written as explicit
  // character scans (never a regex containing BS, and never a literal
  // backslash escape) for the reason TAB/NL/BS's own comment gives above.
  function jsonEscape(s) {
    var out = '', str = String(s);
    for (var i = 0; i < str.length; i++) {
      var c = str[i];
      if (c === BS) out += BS + BS;
      else if (c === '"') out += BS + '"';
      else if (c === NL) out += BS + 'n';
      else if (c === String.fromCharCode(13)) out += BS + 'r';
      else if (c === TAB) out += BS + 't';
      else out += c;
    }
    return out;
  }
  function jsonUnescape(s) {
    var out = '';
    for (var i = 0; i < s.length; i++) {
      if (s[i] === BS && i + 1 < s.length) {
        var c = s[i + 1];
        if (c === 'n') { out += NL; i++; }
        else if (c === 'r') { out += String.fromCharCode(13); i++; }
        else if (c === 't') { out += TAB; i++; }
        else if (c === '"' || c === BS) { out += c; i++; }
        else out += s[i];
      } else out += s[i];
    }
    return out;
  }
  function escapeHtml(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  // Finds the string value of a "payload":"..." JSON field by manual
  // scan (mirrors SXC1.Progress.Codec.hs's own extractJsonStringField/
  // takeJsonStringBody exactly: read up to the next UNESCAPED quote) --
  // never a regex, for the same reason as above. Returns null if the
  // marker or a terminating quote is not found.
  function extractPayloadField(raw) {
    var marker = '"payload":"';
    var idx = raw.indexOf(marker);
    if (idx === -1) return null;
    var body = raw.slice(idx + marker.length);
    for (var i = 0; i < body.length; i++) {
      if (body[i] === BS) { i++; continue; }
      if (body[i] === '"') return body.slice(0, i);
    }
    return null;
  }

  // Envelope-or-bare-wire import, mirroring SXC1.Progress.Codec.importBlob.
  function importBlobJs(raw) {
    var trimmed = raw.trim();
    if (trimmed.indexOf('SXC1PROGRESS') === 0) return decodeProgWire(trimmed);
    var payload = extractPayloadField(raw);
    if (payload !== null) return decodeProgWire(jsonUnescape(payload));
    return { kind: 'corrupt', recs: {}, streakDay: 0, streakLen: 0, reason: 'import text is neither a bare SXC1PROGRESS blob nor a recognisable export envelope' };
  }

  // Mirrors site/static/index.js's own countPastedRecords (same counting
  // rule, re-expressed without any literal backslash) -- this fixture is
  // testing browser-check.mjs's OWN "importPreview" assertion, i.e. that
  // it correctly distinguishes a right count from a wrong one; it is not
  // re-testing index.js's logic (the real run below drives the REAL
  // index.js for that).
  // SABOTAGE, selector 'importPreview' (or legacy-all): always reports 0.
  function countPastedRecordsJs(text) {
    if (sel('importPreview') || LEGACY_ALL) return 0;
    var bareLines = text.split(NL).filter(function (line) { return line.indexOf('R' + TAB) === 0; }).length;
    if (bareLines > 0 || text.trim().indexOf('SXC1PROGRESS') === 0) return bareLines;
    var payload = extractPayloadField(text);
    if (payload === null) return 0;
    // The payload is still JSON-escaped here (matching index.js's own
    // countPastedRecords, which counts escaped R-TAB lines directly
    // without unescaping first) -- so the split/prefix markers are the
    // ESCAPED two-character sequences BS+'n' / 'R' + BS+'t'.
    return payload.split(BS + 'n').filter(function (line) { return line.indexOf('R' + BS + 't') === 0; }).length;
  }
  document.addEventListener('input', function (event) {
    if (!event.target || event.target.id !== 'sxc1-import-input') return;
    var preview = document.getElementById('sxc1-import-preview');
    if (!preview) return;
    var n = countPastedRecordsJs(event.target.value);
    preview.textContent = n === 1 ? '1 record found in the pasted text.' : (n + ' records found in the pasted text.');
  });

  // Two-step wipe confirm -- mirrors site/static/index.js's own
  // document-level delegated listener exactly (same reasoning: Miso
  // destroys/recreates the subtree on navigation in the real app; this
  // fixture's renderHome() does the analogous full re-render).
  document.addEventListener('click', function (event) {
    var id = event.target && event.target.id;
    if (id === 'btn-progress-wipe') {
      var confirmBtn = document.getElementById('btn-progress-wipe-confirm');
      if (confirmBtn) confirmBtn.hidden = false;
    }
  });

  var CURRENT_PROGRESS = (function () {
    var raw = null;
    try { raw = window.localStorage.getItem(PROG_KEY); } catch (e) { /* treated as empty */ }
    return decodeProgWire(raw);
  })();
  // decodePrefsWire's own default (nothing stored) is ALWAYS false here,
  // never sabotaged -- see runProgressAssertionsPost's own comment on why
  // "default flipped to true" would cascade into the D-flow's later
  // steps in a way that is hard to reason about; the freshJaFirst
  // negative control instead sabotages the #sxc1-progress PAYLOAD's
  // jaFirst field directly (below), leaving the real toggle/redirect
  // mechanism itself unsabotaged and testable on its own.
  var CURRENT_PREFS = (function () {
    var raw = null;
    try { raw = window.localStorage.getItem(PREFS_KEY); } catch (e) { /* treated as default */ }
    // M6 W2: the blob is v2 now (jaFirst + jaFirstSet + uiLang --
    // mirrors SXC1.Progress.Codec's own defaults/lenience). The
    // fixture's DISPLAY language still comes from the sxc1.uilang boot
    // hint (UILANG above), exactly like the real static shell.
    var defaults = { jaFirst: false, jaFirstSet: false, uiLang: 'en' };
    if (raw == null || raw.trim() === '') return defaults;
    var lines = raw.split(NL);
    var header = (lines[0] || '').split(TAB);
    if (header[0] !== 'SXC1PREFS') return defaults;
    var out = { jaFirst: false, jaFirstSet: false, uiLang: 'en' };
    for (var i = 1; i < lines.length; i++) {
      var f = lines[i].split(TAB);
      if (f[0] === 'P' && f[1] === 'jaFirst') out.jaFirst = (f[2] === '1');
      if (f[0] === 'P' && f[1] === 'jaFirstSet') out.jaFirstSet = (f[2] === '1');
      if (f[0] === 'P' && f[1] === 'uiLang') out.uiLang = (f[2] === 'ja' ? 'ja' : 'en');
    }
    return out;
  })();

  // One writer for the whole v2 blob (the app's savePrefs always writes
  // every field; a partial write would clobber the others).
  function writePrefsBlob() {
    try {
      window.localStorage.setItem(PREFS_KEY, 'SXC1PREFS' + TAB + '2' + NL +
        'P' + TAB + 'jaFirst' + TAB + (CURRENT_PREFS.jaFirst ? '1' : '0') + NL +
        'P' + TAB + 'jaFirstSet' + TAB + (CURRENT_PREFS.jaFirstSet ? '1' : '0') + NL +
        'P' + TAB + 'uiLang' + TAB + CURRENT_PREFS.uiLang + NL);
    } catch (e) { /* best effort */ }
  }

  // M6 W2 mirror of Main.hs's PUiLangToggle: persist prefs + hint, then
  // reload (reload-as-refetch). See the UILANG block's own comment for
  // the 'uiLangPref' sabotage this carries.
  function saveUiLang(code) {
    CURRENT_PREFS.uiLang = code;
    if (sel('uiLangPref')) {
      try { window.sessionStorage.setItem('sxc1.selftest.uilang', code); } catch (e) { /* best effort */ }
      return;
    }
    writePrefsBlob();
    try { window.localStorage.setItem('sxc1.uilang', code); } catch (e) { /* best effort */ }
  }

  // SABOTAGE, selector 'jaFirstPersist' (or legacy-all) -- deliberately
  // maps to BOTH "jaFirstPersistsValue" AND "jaFirstPersistsOrder", which
  // both read state from the SAME post-reload page load and cannot be
  // told apart by any observation the app makes available (a value that
  // did not persist never produces a panel to check the order of
  // either): the in-memory model still updates (so the UI visibly
  // reflects a click), but the localStorage write is skipped, so a
  // RELOAD (a fresh script execution, re-reading from storage) loses it.
  // This is an intentional 1-selector/2-assertion grouping, not a
  // leftover of the old megamutant -- see M3_SELECTOR_ASSERTIONS' own
  // comment.
  function saveJaFirst(v) {
    CURRENT_PREFS.jaFirst = v;
    CURRENT_PREFS.jaFirstSet = true;
    // NEW10: legacy-all skips EVERY write, unchanged from the old
    // combined behaviour (so D2/D3 still fail under legacy-all too, as
    // LEGACY_EXPECTED_TO_FAIL already lists). 'jaFirstPersist' selected
    // ALONE skips ONLY the very FIRST "turn jaFirst on" write (D1's own
    // read point) -- runProgressAssertionsPost's D1b step then
    // re-establishes a genuine, persisted "on" baseline via a SECOND
    // save (this time unsabotaged) before D2/D3 run, so THEIR OWN claims
    // are tested against real state, not a precondition this selector
    // already broke.
    var skipWrite = LEGACY_ALL || (v === true && sel('jaFirstPersist') && ST.jaFirstOnSaves === 0);
    if (v === true) { ST.jaFirstOnSaves += 1; writeSelfTestState(); }
    if (!skipWrite) writePrefsBlob();
  }

  function mergeRec(recs, pid, rec) {
    var out = {};
    for (var k in recs) { if (Object.prototype.hasOwnProperty.call(recs, k)) out[k] = recs[k]; }
    out[pid] = rec;
    return out;
  }

  // The never-overwrite rule (Progress.Store's THE ONE RULE THAT
  // MATTERS): while CURRENT_PROGRESS.kind === 'corrupt', an ordinary
  // grading write is a no-op. SABOTAGE, selector 'corruptNeverOverwritten'
  // (or legacy-all): disables the guard, so the corrupt blob is silently
  // replaced by the next answer, exactly the defect this rule exists to
  // prevent. NEW10: under this selector ALONE (never under
  // 'corruptBanner'), the banner-suppression sabotage below is INACTIVE,
  // so corruptNeverOverwritten's bannerStillShown half fails for the
  // SAME reason its rawAfterAnswer half does (the guard genuinely let the
  // write through, so the state genuinely stopped being corrupt) -- not
  // because banner rendering was independently broken. That is what
  // makes this selector's own pass a real proof that BOTH conjuncts of
  // "hand-corrupted sxc1.progress: the stored key is present and
  // byte-identical after a reload and after answering another question"
  // matter: deleting either one here would still catch a genuine defect
  // in the OTHER, never a stray, unrelated failure.
  function gradeQuizPromptForProgress(isCorrect, attempt) {
    var pid = FIXTURE.quiz.id + '#1';
    if (CURRENT_PROGRESS.kind === 'corrupt' && !(sel('corruptNeverOverwritten') || LEGACY_ALL)) return;
    var existing = (CURRENT_PROGRESS.kind === 'corrupt' ? {} : CURRENT_PROGRESS.recs)[pid]
      || { reps: 0, lapses: 0, ease: 2500, interval: 0, due: 0, lastSeen: 0, seen: 0 };
    var grade = gradeOfOutcomeJs(isCorrect, attempt, false, 0);
    var updated = applyGradeToRec(existing, grade);
    var baseRecs = CURRENT_PROGRESS.kind === 'corrupt' ? {} : CURRENT_PROGRESS.recs;
    CURRENT_PROGRESS = {
      kind: 'ok', recs: mergeRec(baseRecs, pid, updated),
      streakDay: PROG_TODAY, streakLen: Math.max(1, CURRENT_PROGRESS.streakLen || 1),
    };
    try { window.localStorage.setItem(PROG_KEY, encodeProgWire(CURRENT_PROGRESS.recs, CURRENT_PROGRESS.streakDay, CURRENT_PROGRESS.streakLen)); } catch (e) { /* best effort */ }
    // NEW10 bookkeeping (self-test only -- see ST's own comment): counts
    // real, non-guard-blocked grades since the last wipe, so
    // "answerReloadCount"/"answerReloadInterval" can pin their sabotage
    // to exactly assertion A's own read, not any other grading moment.
    ST.answersSinceWipe += 1;
    writeSelfTestState();
  }

  function currentDue() {
    var recs = CURRENT_PROGRESS.recs, out = 0;
    for (var pid in recs) { if (Object.prototype.hasOwnProperty.call(recs, pid) && recs[pid].due <= PROG_TODAY) out++; }
    return out;
  }

  // NEW10: this USED TO BE one SABOTAGE-gated off-by-one covering all
  // four of "freshRecords"/"wipeEmpties"/"answerReloadCount"/
  // "exportWipeImportRestores" at once, unconditionally, whenever the
  // (then-global) flag was set. Records IS genuinely the same field for
  // all four -- they are legitimately testing the SAME counter at
  // different points in the run -- but the OLD version could not isolate
  // any ONE of them: selecting only "answerReloadCount", say, must leave
  // "freshRecords"/"wipeEmpties" reading a correct 0 and
  // "exportWipeImportRestores" reading a correct 1. recordsSabotaged
  // below is true in exactly ONE of these situations at a time (per the
  // ST phase bookkeeping -- see each selector's own condition):
  //   freshRecords          -- IS_FIRST_BOOT_EVER: the very first render
  //                            of the very first script execution this
  //                            browser session has ever done (before
  //                            POST's own setup wipe has even run) --
  //                            the ONLY moment "freshRecords" itself
  //                            reads.
  //   wipeEmpties           -- wipeCount===2 (the "before import" wipe
  //                            has landed) && importCount===0 (import
  //                            has not committed yet) -- the narrow
  //                            window "wipeEmpties" reads.
  //   answerReloadCount     -- wipeCount===1 (only the setup wipe has
  //                            landed) && answersSinceWipe===1 (exactly
  //                            assertion A's own single grade) -- the
  //                            window payloadA is read in.
  // "exportWipeImportRestores" deliberately has NO records-count
  // sabotage here at all (see its own selector below): its sabotage
  // corrupts the imported RECORD's value instead, so its own identity/
  // value comparison -- not this records count -- is what the negative
  // sweep actually proves is load-bearing (a gate reviewer's specific
  // complaint about the old design).
  function updateProgressPayload() {
    var recs = CURRENT_PROGRESS.recs, pids = Object.keys(recs);
    var recordsSabotaged = LEGACY_ALL
      || (sel('freshRecords') && IS_FIRST_BOOT_EVER)
      || (sel('wipeEmpties') && ST.wipeCount === 2 && ST.importCount === 0)
      || (sel('answerReloadCount') && ST.wipeCount === 1 && ST.answersSinceWipe === 1);
    var payload = {
      available: true,
      state: CURRENT_PROGRESS.kind === 'ok' ? 'ok' : (CURRENT_PROGRESS.kind === 'corrupt' ? 'corrupt' : 'empty'),
      schema: 2,
      records: pids.length + (recordsSabotaged ? 1 : 0),
      retired: 0,
      due: currentDue(),
      streak: CURRENT_PROGRESS.streakLen || 0,
      retention: 0,
      queue: pids.filter(function (p) { return recs[p].due <= PROG_TODAY; }),
      // SABOTAGE, selector 'freshJaFirst' (or legacy-all -- see
      // CURRENT_PREFS's own comment on why the DEFAULT itself is never
      // sabotaged): always reports true here regardless of the real
      // preference.
      jaFirst: (sel('freshJaFirst') || LEGACY_ALL) ? true : (CURRENT_PREFS.jaFirst === true),
      // M6 W2: the active UI language (mirrors Main.progressJson).
      uiLang: UILANG,
    };
    document.getElementById('sxc1-progress').textContent = JSON.stringify(payload);
  }

  // NEW11/NEW10: selector 'reviewBadgeMatchesDue' hardcodes the badge to
  // 0 regardless of the real due count -- the EXACT scenario the M3 gate
  // review named as slipping past the old (post-wipe-only, due==0)
  // check: "an implementation that hardcodes both to zero ... passes".
  // Since runProgressAssertionsPost's own "E" section now manufactures a
  // real due>=1 record and reads the badge BEFORE any wipe (see its own
  // comment), this sabotage is a genuine red-first proof of that new,
  // non-vacuous comparison -- not just of the pre-existing post-wipe
  // (0==0) check, which would already have passed against a hardcoded
  // zero. legacy-all keeps the OLD off-by-one behaviour instead (see
  // this file's own selfTestFixtureHtml comment on why legacy-all is not
  // simply unioned with every named selector's own sabotage).
  function renderHeader(onManualRoute) {
    var due = sel('reviewBadgeMatchesDue') ? 0 : (currentDue() + (LEGACY_ALL ? 1 : 0));
    // M6 W2: header strings localize; SABOTAGE 'uiLangHeader' keeps them
    // EN under ja (exactly the UILANG_HEADER assertion's defect).
    var trHeader = function (en, ja) { return sel('uiLangHeader') ? en : trFx(en, ja); };
    var html = '<a id="sxc1-review-badge" href="#/">' + trHeader('Review ', '復習 ') + due + '</a>';
    if (onManualRoute) {
      html += '<button id="btn-ja-first" type="button" aria-pressed="' + (CURRENT_PREFS.jaFirst ? 'true' : 'false') + '">' +
        (CURRENT_PREFS.jaFirst ? trHeader('Japanese first: on', '日本語を先に表示: オン') : trHeader('Japanese first: off', '日本語を先に表示: オフ')) + '</button>';
    }
    // #btn-ui-lang on EVERY route, mirroring View.Progress.uiLangHeaderEls:
    // the label is the language it switches TO, written in that language.
    html += '<button id="btn-ui-lang" type="button" class="nav-toggle">' +
      (UILANG === 'ja' ? trHeader('日本語', 'English') : '日本語') + '</button>';
    document.getElementById('sxc1-header').innerHTML = html;
    if (onManualRoute) {
      document.getElementById('btn-ja-first').addEventListener('click', function () {
        saveJaFirst(!CURRENT_PREFS.jaFirst);
        render();
      });
    }
    document.getElementById('btn-ui-lang').addEventListener('click', function () {
      saveUiLang(UILANG === 'ja' ? 'en' : 'ja');
      location.reload();
    });
  }

  // NEW11: mirrors View.Progress.reviewQueueEls's real DOM contract
  // exactly -- "#sxc1-review-queue" > "ol.queue-list" > "li.queue-item" >
  // "a[href]" -- so runProgressAssertionsPost's new pre-wipe queue check
  // (section E) can assert the SAME selectors against both the self-test
  // fixture and the real app. Never sabotaged directly: the queue is
  // driven by the SAME CURRENT_PROGRESS.recs the badge/payload read, so
  // "reviewBadgeMatchesDue"'s own sabotage (badge hardcoded to 0) is
  // already a genuine red-first proof without also needing to fake an
  // empty queue independently.
  function renderQueueSection() {
    var recs = CURRENT_PROGRESS.recs;
    var dueIds = Object.keys(recs).filter(function (p) { return recs[p].due <= PROG_TODAY; });
    if (dueIds.length === 0) {
      return '<section id="sxc1-review-queue"><p>Nothing is due for review right now.</p></section>';
    }
    var itemsHtml = dueIds.map(function (pid) {
      // This fixture only ever grades ONE prompt ("<exId>#1"), so the
      // owning exercise id is everything before the last '#' -- same
      // rule as View.Progress.exerciseForPromptId.
      var exId = pid.slice(0, pid.lastIndexOf('#'));
      var href = '#/x/' + FIXTURE.quiz.deck + '/' + exId;
      return '<li class="queue-item"><a href="' + href + '">' +
        '<span class="queue-deck">Demo deck</span><span class="queue-ex">Demo quiz</span>' +
        '<span class="queue-due">due today</span></a></li>';
    }).join('');
    return '<section id="sxc1-review-queue"><ol class="queue-list">' + itemsHtml + '</ol></section>';
  }

  function renderHome() {
    var corrupt = CURRENT_PROGRESS.kind === 'corrupt';
    // THIS render's own 0-based index among all renderHome() calls made
    // so far while genuinely corrupt (captured BEFORE bumping ST, so the
    // very first one reads 0).
    var corruptBannerReadIndex = ST.corruptBannerReads;
    if (corrupt) { ST.corruptBannerReads = corruptBannerReadIndex + 1; writeSelfTestState(); }
    // SABOTAGE, selector 'corruptBanner': the banner never renders even
    // when the blob is undecodable -- but ONLY on THIS assertion's own
    // read point (corruptBannerReadIndex===0, the FIRST render while
    // corrupt). "corruptNeverOverwritten"'s own, independent
    // bannerStillShown check reads a LATER corrupt render
    // (corruptBannerReadIndex===1) and must see the banner genuinely
    // present -- selecting 'corruptBanner' alone must not also make that
    // OTHER assertion fail. legacy-all keeps suppressing the banner on
    // EVERY corrupt render (unchanged from the old combined behaviour),
    // which is why it still cascades into corruptNeverOverwritten's own
    // never-overwrite sabotage above (both active at once under
    // legacy-all, an honest legacy-pass-only cascade).
    var bannerHtml = (corrupt && !((sel('corruptBanner') && corruptBannerReadIndex === 0) || LEGACY_ALL))
      ? ('<section id="sxc1-corrupt-banner"><p>Your saved progress could not be read (' + escapeHtml(CURRENT_PROGRESS.reason || '') + '). It has NOT been deleted.</p>' +
        '<textarea id="sxc1-corrupt-raw" readonly>' + escapeHtml(CURRENT_PROGRESS.raw || '') + '</textarea></section>')
      : '';
    root().innerHTML =
      bannerHtml +
      renderQueueSection() +
      renderContinueSection() +
      '<p id="sxc1-streak">Study streak: ' + (CURRENT_PROGRESS.streakLen || 0) + '</p>' +
      '<section id="sxc1-progress-tools">' +
      '<button id="btn-progress-export" type="button">Export</button>' +
      '<textarea id="sxc1-export-blob" readonly' + EXPORT_LABEL_ATTR + '></textarea>' +
      '<form id="sxc1-import-form">' +
      '<label for="sxc1-import-input">Paste an exported blob to import:</label>' +
      '<textarea id="sxc1-import-input" name="sxc1-import-input"></textarea>' +
      '<p id="sxc1-import-preview">Paste text above to see how many records it contains.</p>' +
      '<button id="btn-progress-import" type="submit">Import</button>' +
      '</form>' +
      '<button id="btn-progress-wipe" type="button">Wipe all progress</button>' +
      '<button id="btn-progress-wipe-confirm" type="button" hidden>Yes, permanently wipe my progress</button>' +
      '</section>';

    document.getElementById('btn-progress-export').addEventListener('click', function () {
      var wire = encodeProgWire(CURRENT_PROGRESS.kind === 'corrupt' ? {} : CURRENT_PROGRESS.recs, CURRENT_PROGRESS.streakDay || 0, CURRENT_PROGRESS.streakLen || 0);
      var envelope = '{"format":"sxc1-progress","schema":2,"exportedAt":"epoch-ms:' + Date.now() + '","payload":"' + jsonEscape(wire) + '"}';
      document.getElementById('sxc1-export-blob').value = envelope;
    });
    document.getElementById('sxc1-import-form').addEventListener('submit', function (ev) {
      ev.preventDefault();
      var text = document.getElementById('sxc1-import-input').value;
      var decoded = importBlobJs(text);
      if (decoded.kind === 'ok') {
        // SABOTAGE, selector 'exportWipeImportRestores' (this fixture's
        // only import commit, so no phase gating is needed): corrupts
        // the RESTORED record's own interval field by +1, leaving the
        // records COUNT correct (still exactly 1). NEW10: the old design
        // sabotaged the records count here too, which meant deleting
        // "exportWipeImportRestores"'s own recB-vs-recA identity/value
        // comparison still left the assertion failing (via the SAME
        // records+1 conjunct "answerReloadCount" etc. also relied on) --
        // a gate reviewer's specific example of a weakened assertion the
        // old sweep could not have caught. This sabotage instead breaks
        // ONLY the value comparison, so THIS selector's own pass is a
        // real proof that comparison is load-bearing.
        if (sel('exportWipeImportRestores')) {
          var pid = FIXTURE.quiz.id + '#1';
          var rec = decoded.recs[pid];
          if (rec) {
            decoded.recs[pid] = {
              reps: rec.reps, lapses: rec.lapses, ease: rec.ease, interval: rec.interval + 1,
              due: rec.due, lastSeen: rec.lastSeen, seen: rec.seen,
            };
          }
        }
        CURRENT_PROGRESS = decoded;
        try { window.localStorage.setItem(PROG_KEY, encodeProgWire(decoded.recs, decoded.streakDay, decoded.streakLen)); } catch (e) { /* best effort */ }
        ST.importCount += 1;
        writeSelfTestState();
        // Mirrors Miso's real behaviour: EVERY state change re-renders the
        // WHOLE view (viewModel), header/badge included -- never just the
        // body -- so this fixture's own hand-rolled DOM split must
        // explicitly re-render the header too, not only #sxc1-root. This
        // form (#sxc1-progress-tools) only ever exists on Home, so
        // onManualRoute is always false here.
        renderHeader(false);
        renderHome();
        updateProgressPayload();
      }
    });
    document.getElementById('btn-progress-wipe-confirm').addEventListener('click', function () {
      var wipeIndexBefore = ST.wipeCount; // 0-based: this click is wipe #(wipeIndexBefore+1)
      // SABOTAGE, selector 'jaFirstSurvivesWipe', targeted at exactly
      // the "d2" wipe (runProgressAssertionsPost's own comment: the
      // FOURTH wipe-confirm click overall -- setup, before-import,
      // corrupt-clearing, then this one -- wipeIndexBefore===3). NEW10:
      // the old design never established jaFirstPersist's own
      // "genuinely on-disk true before the wipe" precondition under
      // sabotage (the SAME global flag skipped that earlier save too),
      // so this assertion's negative case never actually exercised "does
      // an explicit wipe clear jaFirst" at all. Here the preceding save
      // is UNSABOTAGED (selector 'jaFirstSurvivesWipe' does not gate
      // saveJaFirst), so jaFirst is genuinely persisted true on disk
      // first; only THIS wipe additionally (and wrongly) clears it.
      var alsoClearPrefs = sel('jaFirstSurvivesWipe') && wipeIndexBefore === 3;
      CURRENT_PROGRESS = { kind: 'empty', recs: {}, streakDay: 0, streakLen: 0 };
      try { window.localStorage.removeItem(PROG_KEY); } catch (e) { /* best effort */ }
      if (alsoClearPrefs) {
        CURRENT_PREFS = { jaFirst: false, jaFirstSet: false, uiLang: CURRENT_PREFS.uiLang };
        try { window.localStorage.removeItem(PREFS_KEY); } catch (e) { /* best effort */ }
      }
      ST.wipeCount = wipeIndexBefore + 1;
      // NEW14: a wipe clears the app's psLastPrompt too -- reset both
      // continue trackers so section F's post-wipe epoch starts clean.
      ST.firstSinceWipe = null;
      ST.lastAnswered = null;
      ST.answersSinceWipe = 0;
      writeSelfTestState();
      // Same reasoning as onImportSubmit above -- and load-bearing here:
      // without it, #sxc1-review-badge stays showing whatever it last
      // rendered (e.g. section E's manufactured "Review 1") even after a
      // wipe that genuinely zeroes #sxc1-progress's own due/records,
      // which is exactly the kind of stale-badge defect
      // "reviewBadgeMatchesDue"'s post-wipe half exists to catch -- it
      // must not be a defect in THIS fixture's own re-render discipline.
      renderHeader(false);
      renderHome();
      updateProgressPayload();
    });
  }

  // SABOTAGE, selector 'jaToggleHidesAndSticks' (or legacy-all): after
  // an explicit hide, a stray re-render forces the panel back on shortly
  // after -- "the preference fights the toggle", exactly the bug d3
  // exists to catch. Only fires when jaFirst is actually on (the real
  // bug's precondition) and only on a genuine hide (not a manual show).
  function renderManualPage(slug, n, ja) {
    var pageBodyHtml = '<div class="page-body" id="page-' + n + '">Manual page ' + n + ' of ' + slug + '.</div>';
    var panelHtml = ja
      ? ('<figure id="ja-panel"><img id="ja-image" src="pages/' + slug + '/page-' + n + '.webp"><figcaption>Page ' + n + ', original Japanese</figcaption></figure>')
      : '';
    var order = (ja && CURRENT_PREFS.jaFirst) ? (panelHtml + pageBodyHtml) : (pageBodyHtml + panelHtml);
    var nextHref = (n < MANUAL_TOTAL_PAGES) ? ('#/m/' + slug + '/p/' + (n + 1)) : null;
    var prevHref = (n > 1) ? ('#/m/' + slug + '/p/' + (n - 1)) : null;
    root().innerHTML = '<article id="sxc1-page">' + order +
      '<button id="btn-ja-toggle" type="button">' + (ja ? 'Hide original page' : 'Show original page (JA)') + '</button>' +
      '<nav class="page-nav">' +
      '<a id="btn-prev-page"' + (prevHref ? (' href="' + prevHref + '"') : '') + '>Previous page</a>' +
      '<a id="btn-next-page"' + (nextHref ? (' href="' + nextHref + '"') : '') + '>Next page</a>' +
      '</nav></article>';
    document.getElementById('btn-ja-toggle').addEventListener('click', function () {
      var wasShowingViaJaFirst = ja && CURRENT_PREFS.jaFirst;
      location.hash = '#/m/' + slug + '/p/' + n + (ja ? '' : '/ja');
      if (wasShowingViaJaFirst && (sel('jaToggleHidesAndSticks') || LEGACY_ALL)) {
        setTimeout(function () { location.hash = '#/m/' + slug + '/p/' + n + '/ja'; }, 200);
      }
    });
  }
  // Mirrors Main.hs's promptBaselineJson contract: a POSITIVE monotonic
  // reading once Begin has run at mount; stays "null" under legacy-all
  // (M2-era H6, never individually isolated -- see this file's own
  // report) -- the lost-mount-Begin scenario --self-test-negative must
  // catch.
  if (!LEGACY_ALL) {
    document.getElementById('sxc1-prompt-baseline').textContent =
      String(Math.max(1, Math.floor(performance.now())));
  }
  var eventLog = [];
  var quizSelected = Object.create(null);
  var quizAttempted = false;
  var lastQuizCorrect = false;
  // M5 a11y: done-state mirrors (the app's esDone) -- set by the Next
  // click after a correct answer, cleared by Restart (quiz) / route
  // entry + Restart (lookup, matching this fixture's long-standing
  // reset-on-entry semantics).
  var quizDone = false;
  var lookupDone = false;
  var quizPromptAt = 0;
  // M3: how many times THIS quiz prompt has been submitted since it was
  // last fresh/Begin/Restart -- mirrors the real engine's own attempt
  // counter, which gradeOfOutcomeJs needs (Correct on attempt >= 2 is
  // GHard, never GEasy, even though this fixture's own quiz-grading
  // legacy-all sabotage forces isCorrect=true regardless of selection).
  var quizAttemptCount = 0;
  var drillCursor = 0;
  var drillStepAt = 0;
  var lookupStartedAt = 0;
  var lookupResult = null;

  function root() { return document.getElementById('sxc1-root'); }
  function setEventLog() { document.getElementById('sxc1-event-log').textContent = JSON.stringify(eventLog); }
  // H1/M5: 'promptAt' is THIS attempt's own monotonic baseline (set when
  // the prompt was FIRST shown -- quizPromptAt/drillStepAt/
  // lookupStartedAt below, one per kind, all reset the same way Main.hs's
  // Begin/Restart/Advance re-baseline esPromptAt). Under legacy-all
  // (M2-era H1, never individually isolated -- see this file's own
  // report), elapsedMs is forced to 0 regardless of the real wait -- the
  // exact H1 defect (a fresh attempt's clock seeded from the WALL epoch
  // instead of the monotonic one gradeStep subtracts against, clamped
  // hugely negative to 0) -- so a cold-load assertion that only checked
  // the M:SS STRING (any value, including "0:00") would miss it; this is
  // why the new cold-load assertion reads elapsedMs itself instead.
  // M4: promptId (optional) lets a DRILL confirm record its own step's
  // prompt id; every pre-M4 caller keeps the '#1' default unchanged.
  function pushEvent(exId, kind, outcome, promptAt, promptId) {
    var elapsedMs = LEGACY_ALL ? 0 : Math.max(0, Date.now() - (promptAt || Date.now()));
    eventLog.push({ deck: FIXTURE.quiz.deck, exercise: exId, prompt: promptId || (exId + '#1'), kind: kind,
      outcome: outcome, attempt: 1, revealed: false, hints: 0, elapsedMs: elapsedMs, at: Date.now() });
    // NEW14 (continueMatchesLast): mirror the app's psLastPrompt -- the
    // LAST graded exercise -- plus the FIRST, which the sabotage renders
    // instead (modelling the old lexicographic/first-scan bug).
    if (!ST.firstAnswered) { ST.firstAnswered = exId; }
    if (!ST.firstSinceWipe) { ST.firstSinceWipe = exId; }
    ST.lastAnswered = exId;
    writeSelfTestState();
    setEventLog();
  }

  function deckOf(exId) {
    if (exId === FIXTURE.drill.id) return FIXTURE.drill.deck;
    if (exId === FIXTURE.lookup.id) return FIXTURE.lookup.deck;
    return FIXTURE.quiz.deck;
  }

  // NEW14: #sxc1-continue mirrors the app's psLastPrompt-driven section.
  // SABOTAGE, selector 'continueMatchesLast': renders the FIRST-ever
  // answered exercise instead of the last -- the old Map-scan bug shape.
  function renderContinueSection() {
    var target = sel('continueMatchesLast') ? ST.firstSinceWipe : ST.lastAnswered;
    if (!target) return '';
    return '<section id="sxc1-continue"><a href="#/x/' + deckOf(target) + '/' + target + '">Continue: ' + target + '</a></section>';
  }

  function renderIndex() {
    root().innerHTML =
      '<section id="sxc1-exercise-index">' +
        '<section class="ex-chapter"><h2 class="ex-chapter-title">Demo chapter</h2>' +
        '<ul class="ex-deck-list"><li><a class="ex-deck-card" href="#/x/' + FIXTURE.quiz.deck + '">' +
        '<span class="ex-deck-title">Demo deck</span><span class="ex-deck-count">3 exercises</span>' +
        '</a></li></ul></section></section>';
  }

  function renderDeck() {
    // SABOTAGE, selector 'deckCardTierMatches' (or legacy-all): the
    // rendered tier disagrees with the deck's own declared tier.
    var renderedTier = (sel('deckCardTierMatches') || LEGACY_ALL) ? 'stretch' : PROGRESS_DECK_TIER;
    root().innerHTML = '<section id="sxc1-deck"><h1 id="ex-deck-title">Demo deck</h1>' +
      '<div class="deck-card" data-tier="' + renderedTier + '"><span class="tier-badge">' + renderedTier + '</span></div>' +
      '<p id="ex-deck-summary">A demo deck.</p><ol class="ex-list">' +
      '<li><a class="ex-link" href="#/x/' + FIXTURE.quiz.deck + '/' + FIXTURE.quiz.id + '"><span class="ex-kind kind-quiz">Quiz</span><span class="ex-title">Demo quiz</span></a></li>' +
      '<li><a class="ex-link" href="#/x/' + FIXTURE.drill.deck + '/' + FIXTURE.drill.id + '"><span class="ex-kind kind-drill">Drill</span><span class="ex-title">Demo drill</span></a></li>' +
      '<li><a class="ex-link" href="#/x/' + FIXTURE.lookup.deck + '/' + FIXTURE.lookup.id + '"><span class="ex-kind kind-lookup">Lookup</span><span class="ex-title">Demo lookup</span></a></li>' +
      '</ol></section>';
  }

  // 'citesHtml' lets a caller supply its OWN citation markup (or ''),
  // since H8's fix is kind-specific: quiz's citation was already correct
  // pre-fix, so its own call site below leaves 'citesHtml' undefined and
  // gets its unconditional default; the lookup call site (H8: citation
  // only after grading, never before) passes one explicitly.
  function feedbackHtml(correct, citesHtml) {
    var cites = citesHtml === undefined
      ? '<ul id="ex-cites"><li><a class="cite" href="#/m/' + FIXTURE.quiz.citeSlug + '/p/' + FIXTURE.quiz.citePage + '">cite</a></li></ul>'
      : citesHtml;
    return '<p id="ex-feedback" class="' + (correct ? 'correct' : 'incorrect') + '" role="status">' +
      (correct ? trBody('Correct.', '正解。') : trBody('Not quite. Try again.', '不正解。もう一度。')) + '</p>' +
      (correct ? ('<div id="ex-note"><p>Why: demo note.</p></div>' + cites +
        '<button id="btn-ex-next">Next</button>') : '');
  }

  function renderQuiz() {
    // H1/H6: lazily seeded, like esPromptAt from a real Begin -- the
    // FIRST renderQuiz() after a fresh load or a Restart (which zeroes
    // this back out below) re-baselines it, exactly once, before any
    // click can occur.
    if (quizPromptAt === 0) quizPromptAt = Date.now();
    // M5 a11y: the done state mirrors the app exactly -- no options, no
    // submit, no feedback; just title/progress/stem, Restart and the
    // summary focus target (View.Exercise.bodyEls hides the prompt once
    // esDone; summaryEl renders).
    if (quizDone) {
      root().innerHTML = '<article id="sxc1-exercise" class="exercise kind-quiz">' +
        '<h1 id="ex-title" tabindex="-1">Demo quiz</h1><p id="ex-progress">1 / 1</p><div id="ex-stem"><p>Pick the right one.</p></div>' +
        '<button id="btn-ex-restart">Restart</button>' + SUMMARY_HTML +
        '</article>';
      document.getElementById('btn-ex-restart').addEventListener('click', function () {
        quizPromptAt = 0;
        quizAttemptCount = 0;
        quizDone = false;
        if (!LEGACY_ALL) {
          quizAttempted = false;
          lastQuizCorrect = false;
          quizSelected = Object.create(null);
        }
        renderQuiz();
        focusEl('ex-title');
      });
      devUpdateState();
      return;
    }
    var optsHtml =
      '<li><' + CTL_TAG + ' id="' + FIXTURE.quiz.correctOpt + '" class="ex-option" aria-pressed="' + (quizSelected[FIXTURE.quiz.correctOpt] ? 'true' : 'false') + '">Correct option</' + CTL_TAG + '></li>' +
      '<li><' + CTL_TAG + ' id="' + FIXTURE.quiz.wrongOpt + '" class="ex-option" aria-pressed="' + (quizSelected[FIXTURE.quiz.wrongOpt] ? 'true' : 'false') + '">Wrong option</' + CTL_TAG + '></li>';
    root().innerHTML = '<article id="sxc1-exercise" class="exercise kind-quiz">' +
      '<h1 id="ex-title" tabindex="-1">Demo quiz</h1><p id="ex-progress">1 / 1</p><div id="ex-stem"><p>Pick the right one.</p></div>' +
      '<ul id="ex-options">' + optsHtml + '</ul>' +
      '<' + CTL_TAG + ' id="btn-ex-submit">Submit</' + CTL_TAG + '>' +
      (quizAttempted ? feedbackHtml(lastQuizCorrect) : '') +
      '<button id="btn-ex-restart">Restart</button>' +
      '</article>';
    // M5 a11y: the final advance -- Next on the one-prompt quiz
    // completes it; Main.hs's wiring then focuses #ex-summary.
    var nextBtn = document.getElementById('btn-ex-next');
    if (nextBtn) nextBtn.addEventListener('click', function () {
      quizDone = true;
      renderQuiz();
      focusEl('ex-summary');
    });
    // H7: Restart must yield a genuinely blank prompt -- clears this
    // attempt's own result state and re-baselines the clock, mirroring
    // Main.hs's applyExActions (Begin/Restart -> dropStale mExResults).
    // legacy-all (M2-era H7, never individually isolated -- see this
    // file's own report) reproduces the pre-fix defect ON PURPOSE: it
    // re-baselines the clock (an unrelated bug) but leaves quizAttempted/
    // lastQuizCorrect/quizSelected exactly as they were, so the stale
    // "Correct."/note/Next/pressed option all survive a restart -- the
    // one thing this task's new Restart assertion exists to catch.
    document.getElementById('btn-ex-restart').addEventListener('click', function () {
      quizPromptAt = 0;
      quizAttemptCount = 0;
      quizDone = false;
      if (!LEGACY_ALL) {
        quizAttempted = false;
        lastQuizCorrect = false;
        quizSelected = Object.create(null);
      }
      renderQuiz();
      // M5 a11y: Restart is a cursor move too (Main.hs advanceFocusTarget).
      focusEl('ex-title');
    });
    Array.prototype.forEach.call(document.querySelectorAll('.ex-option'), function (btn) {
      btn.addEventListener('click', function () {
        // Single-answer replace (radio) semantics -- this fixture's quiz
        // has exactly ONE correct option (FIXTURE.quiz.correctOpt), same
        // as SXC1.Exercise.Engine's Toggle handler now implements for
        // any single-correct prompt (briefs/M2-signoff-fixes.json, task
        // "quiz-selection-semantics", FIX 1/2): selecting a fresh option
        // replaces the whole selection outright; re-clicking the
        // already-selected option still clears it. This is what makes
        // the "wrong option, then correct option, no deselect" path
        // above land on exactly one selected id, matching the grader's
        // selectedIds.length === 1 && selectedIds[0] === correctOpt
        // rule below.
        var wasSelected = quizSelected[btn.id];
        quizSelected = Object.create(null);
        if (!wasSelected) quizSelected[btn.id] = true;
        renderQuiz();
      });
    });
    var submitBtn = document.getElementById('btn-ex-submit');
    submitBtn.addEventListener('click', function () {
      var selectedIds = Object.keys(quizSelected).filter(function (k) { return quizSelected[k]; });
      var isCorrect = LEGACY_ALL ? true : (selectedIds.length === 1 && selectedIds[0] === FIXTURE.quiz.correctOpt);
      quizAttempted = true;
      lastQuizCorrect = isCorrect;
      quizAttemptCount += 1;
      // M3: feed the SAME submit that grades the quiz UI into the
      // progress mini-engine too -- see gradeQuizPromptForProgress's own
      // comment for why this fixture reuses the M2 quiz UI rather than
      // simulating a second one.
      gradeQuizPromptForProgress(isCorrect, quizAttemptCount);
      pushEvent(FIXTURE.quiz.id, 'quiz', isCorrect ? 'correct' : 'incorrect', quizPromptAt);
      renderQuiz();
      updateProgressPayload();
    });
    devUpdateState();
  }

  function renderDrill() {
    if (drillStepAt === 0) drillStepAt = Date.now();
    var stepsHtml = '';
    for (var i = 1; i <= FIXTURE.drill.steps; i++) {
      var idx0 = i - 1;
      var confirmed = idx0 < drillCursor;
      // H8: a drill's own citations live per-step, rendered once (and
      // only once) that step is confirmed -- and, unlike quiz/lookup,
      // stay visible after the WHOLE drill completes (see
      // site/app/View/Exercise.hs's citesEl/bodyEls comments). legacy-all
      // (M2-era H8, never individually isolated -- see this file's own
      // report) omits this entirely, reproducing the pre-fix defect: a
      // drill body never reached the only citation renderer that existed
      // at the time, so a completed drill's citations were unreachable.
      var citeHtml = (confirmed && !LEGACY_ALL)
        ? ('<ul class="ex-step-cites" id="ex-step-' + i + '-cites"><li><a class="cite" href="#/m/' + FIXTURE.drill.citeSlug + '/p/' + FIXTURE.drill.citePage + '">cite</a></li></ul>')
        : '';
      stepsHtml += '<li class="ex-step" id="ex-step-' + i + '" tabindex="-1"><div class="ex-step-instruction"><p>Step ' + i + '.</p></div>' +
        '<p class="ex-step-check" id="ex-step-' + i + '-check">Check ' + i + '.</p>' +
        // M4: the live verify line (idle/waiting/confirmed), mirroring
        // the app's View.Exercise render -- both fixture drill steps
        // carry a spec (see DRILL_SPECS above).
        (FIXTURE.drill.hasVerify ? devVerifyLineHtml(i) : '') +
        citeHtml +
        (idx0 === drillCursor ? ('<' + CTL_TAG + ' class="btn-ex-confirm" id="btn-ex-confirm-' + i + '">Confirm</' + CTL_TAG + '>') : '') +
        '</li>';
    }
    root().innerHTML = '<article id="sxc1-exercise" class="exercise kind-drill">' +
      '<h1 id="ex-title" tabindex="-1">Demo drill</h1><p id="ex-progress">' + Math.min(drillCursor + 1, FIXTURE.drill.steps) + ' / ' + FIXTURE.drill.steps + '</p>' +
      '<div id="ex-stem"><p>Do the thing.</p></div><ol id="ex-steps">' + stepsHtml + '</ol>' +
      '<button id="btn-ex-restart">Restart</button>' +
      // M5 a11y: a completed drill keeps its step list (H8) AND gains the
      // summary focus target, mirroring View.Exercise.summaryEl.
      (drillCursor >= FIXTURE.drill.steps ? SUMMARY_HTML : '') +
      '</article>';
    // M4 gate-1 (D24): the drill's Restart mirror -- the app renders
    // #btn-ex-restart on every runner. Mirrors Main.hs Restart exactly:
    // fresh attempt state, confirms wiped (esResponses resets), the
    // event log KEPT (Restart emits no event), and the attempt
    // generation bumped -- which is what the in-flight-Restart
    // stale-drop rides on.
    document.getElementById('btn-ex-restart').addEventListener('click', function () {
      drillCursor = 0;
      drillStepAt = Date.now();
      drillConfirms = [];
      DEV.gen += 1;
      renderDrill();
      devReconcile();
      // M5 a11y: Restart lands the cursor on step 1 (Main.hs
      // advanceFocusTarget -> "ex-step-1" for a not-done drill).
      focusEl('ex-step-1');
    });
    var btn = document.getElementById('btn-ex-confirm-' + (drillCursor + 1));
    if (btn) btn.addEventListener('click', function () {
      var confirmedIdx = drillCursor;
      pushEvent(FIXTURE.drill.id, 'drill', 'correct', drillStepAt, FIXTURE.drill.id + '#' + (confirmedIdx + 1));
      // M4: mirror the app's esResponses-derived confirms array, and the
      // reconciler's disarm-on-cursor-move (sabotaged once, on exactly
      // this manual path, by 'devStaleConfirm' -- see devReconcile).
      drillConfirms.push({ prompt: FIXTURE.drill.id + '#' + (confirmedIdx + 1), source: 'learner' });
      DEV.skipNextReconcile = sel('devStaleConfirm');
      drillCursor += 1;
      // H1: Advance re-baselines esPromptAt to the NEXT prompt's own
      // monotonic reading -- mirrored here for the step about to become
      // current.
      drillStepAt = Date.now();
      renderDrill();
      devReconcile();
      // M5 a11y: the confirmed step's button is gone from the DOM -- land
      // focus on the next step (or the summary when that was the last).
      focusEl(drillCursor >= FIXTURE.drill.steps ? 'ex-summary' : ('ex-step-' + (drillCursor + 1)));
    });
    devUpdateState();
  }

  function elapsedStr() {
    var ms = Math.max(0, Date.now() - lookupStartedAt);
    var s = Math.floor(ms / 1000);
    var m = Math.floor(s / 60);
    var ss = s % 60;
    return m + ':' + (ss < 10 ? '0' : '') + ss;
  }

  function renderLookup() {
    if (lookupStartedAt === 0) lookupStartedAt = Date.now();
    // M5 a11y: restart resets this lookup to a blank attempt -- the app
    // renders #btn-ex-restart on EVERY runner (this fixture's lookup
    // previously had none), and the keyboard-only lookup flow starts by
    // activating it.
    function attachLookupRestart() {
      document.getElementById('btn-ex-restart').addEventListener('click', function () {
        lookupStartedAt = 0;
        lookupResult = null;
        lookupDone = false;
        renderLookup();
        focusEl('ex-title');
      });
    }
    if (lookupDone) {
      // Done state mirrors the app: prompt hidden, summary shown.
      root().innerHTML = '<article id="sxc1-exercise" class="exercise kind-lookup">' +
        '<h1 id="ex-title" tabindex="-1">Demo lookup</h1><p id="ex-progress">1 / 1</p><div id="ex-stem"><p>Find the page.</p></div>' +
        '<button id="btn-ex-restart">Restart</button>' + SUMMARY_HTML +
        '</article>';
      attachLookupRestart();
      return;
    }
    // H8: a lookup's own citation is its find: TARGET page, rendered
    // ONLY after grading (gated the same way the real app gates it --
    // mAttempted -- never before, or the lookup spoils its own answer).
    // legacy-all (M2-era H8, never individually isolated -- see this
    // file's own report) omits it even once graded, reproducing the
    // pre-fix defect: a lookup's target lives only in its prompt's
    // FindPage payload, which the only citation renderer at the time
    // (keyed off exCites) never visited at all.
    var lookupCiteHtml = LEGACY_ALL
      ? ''
      : ('<ul id="ex-cites"><li><a class="cite" href="#/m/' + FIXTURE.lookup.citeSlug + '/p/' + FIXTURE.lookup.citePage + '">cite</a></li></ul>');
    root().innerHTML = '<article id="sxc1-exercise" class="exercise kind-lookup">' +
      '<h1 id="ex-title" tabindex="-1">Demo lookup</h1><p id="ex-progress">1 / 1</p><div id="ex-stem"><p>Find the page.</p></div>' +
      '<p id="ex-find-task">Find it.</p>' +
      '<input id="ex-find-input" type="number" inputmode="numeric">' +
      '<' + CTL_TAG + ' id="btn-ex-find-submit">Submit</' + CTL_TAG + '>' +
      (lookupResult !== null ? (feedbackHtml(lookupResult, lookupResult ? lookupCiteHtml : '') + (lookupResult ? ('<p id="ex-elapsed">' + elapsedStr() + '</p>') : '')) : '') +
      '<button id="btn-ex-restart">Restart</button>' +
      '</article>';
    attachLookupRestart();
    // M5 a11y: the final advance, exactly like the quiz's Next handler.
    var lookupNext = document.getElementById('btn-ex-next');
    if (lookupNext) lookupNext.addEventListener('click', function () {
      lookupDone = true;
      renderLookup();
      focusEl('ex-summary');
    });
    var input = document.getElementById('ex-find-input');
    var submitBtn = document.getElementById('btn-ex-find-submit');
    submitBtn.addEventListener('click', function () {
      var n = parseInt(input.value, 10);
      var isCorrect = LEGACY_ALL ? true : (n === FIXTURE.lookup.targetPage);
      lookupResult = isCorrect;
      pushEvent(FIXTURE.lookup.id, 'lookup', isCorrect ? 'correct' : 'incorrect', lookupStartedAt);
      renderLookup();
    });
  }

  // M3: tracks whether the mount-time render has already happened and,
  // if so, which manual page it last showed -- mirrors Main.hs's
  // mBooted/mRoute pair exactly, and drives the SAME "freshPage" rule:
  // redirect to /ja only on a genuinely fresh page navigation (mount, or
  // a slug/page change), never on the post-toggle hashchange echo of the
  // SAME page (which is what lets an explicit #btn-ja-toggle win until
  // the learner actually moves to a different page -- assertion
  // "jaToggleHidesAndSticks"'s whole point).
  var BOOTED = false;
  var PREV_PAGE = null;

  function render() {
    var h = location.hash.replace(/^#/, '');
    var parts = h.split('/').filter(Boolean);

    if (parts.length === 0) {
      BOOTED = true; PREV_PAGE = null;
      renderHeader(false);
      renderHome();
      updateProgressPayload();
      return;
    }
    if (parts[0] === 'x' && parts.length === 1) {
      BOOTED = true; PREV_PAGE = null;
      renderHeader(false);
      renderIndex();
      updateProgressPayload();
      return;
    }
    if (parts[0] === 'x' && parts.length === 2) {
      BOOTED = true; PREV_PAGE = null;
      renderHeader(false);
      renderDeck();
      updateProgressPayload();
      return;
    }
    if (parts[0] === 'x' && parts.length === 3) {
      var exId = parts[2];
      BOOTED = true; PREV_PAGE = null;
      renderHeader(false);
      if (exId === FIXTURE.quiz.id) { renderQuiz(); updateProgressPayload(); return; }
      // M4 gate-1: this fixture resets the drill on every route ENTRY
      // (its own long-standing semantics; the app Begins only once), so
      // each entry is a fresh attempt and bumps the generation, exactly
      // as the app's Begin batch does via applyExActions.
      if (exId === FIXTURE.drill.id) { drillCursor = 0; DEV.gen += 1; renderDrill(); updateProgressPayload(); return; }
      if (exId === FIXTURE.lookup.id) { lookupStartedAt = 0; lookupResult = null; lookupDone = false; renderLookup(); updateProgressPayload(); return; }
    }
    if (parts[0] === 'm' && parts.length >= 4 && parts[2] === 'p') {
      var slug = parts[1];
      var n = parseInt(parts[3], 10);
      var ja = parts[4] === 'ja';
      var fresh = !BOOTED || !PREV_PAGE || PREV_PAGE.slug !== slug || PREV_PAGE.n !== n;
      if (!ja && CURRENT_PREFS.jaFirst && fresh) {
        BOOTED = true; PREV_PAGE = { slug: slug, n: n };
        location.hash = '#/m/' + slug + '/p/' + n + '/ja';
        return; // hashchange re-invokes render() with ja=true
      }
      BOOTED = true; PREV_PAGE = { slug: slug, n: n };
      renderHeader(true);
      renderManualPage(slug, n, ja);
      updateProgressPayload();
      return;
    }
    BOOTED = true; PREV_PAGE = null;
    renderHeader(false);
    renderIndex();
    updateProgressPayload();
  }
  // M4: every route render reconciles the device watch (mirrors Main.hs)
  // and keeps #sxc1-device-state fresh on every route.
  function renderWithDevice() { render(); devReconcile(); }
  window.addEventListener('hashchange', renderWithDevice);
  renderWithDevice();
})();
<\/script>
</body></html>`;
}

// M2 gate fix (H1/H6/M5): fixed assertion NAME for the cold-load elapsed
// check below, shared by both call sites (self-test's coldLoadFn and the
// real run's) so --self-test-negative's expectedToFail list matches
// whichever harness produced it.
const COLD_ELAPSED_ASSERTION_NAME =
  'cold-load quiz (fresh target, hash present at initial navigation): FIRST event elapsedMs >= known wait after a first-try correct answer (a false zero must fail)';

// M2 gate fix (H1/M5): fixed name for the WARM companion to the above.
// H6 (Begin never fires on a cold route) and H1 (Begin seeds the WRONG
// clock) are two DIFFERENT defects that happened to overlap on the same
// code path -- and H6's absence of Begin on a cold route means a cold
// load can never actually exercise H1's "Begin . snd" swap in the
// PRE-fix code (esPromptAt just stays at its compile-time 0 default,
// which happens to read back as a plausible elapsed time for a
// genuinely fresh page -- see this task's own report for the measured
// number). A WARM navigation into a never-before-visited exercise fires
// Begin via beginIfNeeded on EVERY SetRoute (Main.hs), pre-fix included,
// so it is the one path that reliably exercises H1 on its own. This is
// the other half of M5's finding ("quiz and drill FIRST-attempt events
// are never checked for elapsedMs") that the cold-load assertion alone
// cannot close.
const WARM_FIRST_ELAPSED_ASSERTION_NAME =
  'warm first-attempt quiz submit: FIRST event elapsedMs >= known wait after Begin fires via an ordinary SetRoute (a false zero must fail)';

// M2 gate fix (H1/H6/M5): the behavioural core of "check 14 certifies
// presence, not wiring" (M4) and "the browser elapsed path steps around
// the defect" (M5). `coldH` is a harness ALREADY navigated to a
// genuinely fresh target/page whose initial URL carried the quiz's own
// deep link (never a warm hashchange -- see each caller's own
// coldLoadFn for how that target was created), bundling just
// evaluate/clickAssert/report for THAT target. Waits a KNOWN interval
// with the prompt on screen, then answers CORRECTLY on the FIRST
// attempt -- deliberately never a wrong answer first, which is exactly
// what let the ONE pre-existing elapsed assertion (the lookup check
// below) re-baseline esPromptAt to a real monotonic reading before ever
// measuring anything (M5's own finding) -- then requires the FIRST
// entry in #sxc1-event-log to report elapsedMs at least that interval.
// Generous slack upward (real browsers are never exactly on time),
// none downward: a false near-zero (H1's actual defect -- a fresh
// attempt's clock seeded from the WALL epoch instead of the monotonic
// one gradeStep subtracts against, clamped hugely negative to 0) must
// fail this, which is precisely why this reads elapsedMs itself rather
// than accepting any well-formed "M:SS" string the way the pre-existing
// #ex-elapsed check does (and still does -- that assertion is untouched;
// this is a new, independent one).
// M2 re-gate fix (cold-route observability): the app renders the CURRENT
// exercise route's monotonic prompt baseline into #sxc1-prompt-baseline --
// "null" when Begin has never run. Deleting the mount-time Begin
// (readerApp's `mount = Just (SetRoute r0)`) makes this "null" on a cold
// deep link, which THIS assertion catches deterministically -- unlike the
// elapsed-time window below, which page uptime can satisfy accidentally
// (the re-gate's exact scenario: boot time + wait falls inside the
// window). The self-test fixture mirrors the contract, and SABOTAGE mode
// renders "null" so --self-test-negative proves this can fail.
const COLD_BASELINE_ASSERTION_NAME =
  'cold-load quiz: #sxc1-prompt-baseline is a positive number (Begin ran at mount; "null" means the mount-time Begin was lost)';

// M3 harness wave, urgent item: the RACE FIX for #sxc1-prompt-baseline.
// This used to sample the element ONCE, immediately after the cold
// target reported window.__SXC1_BOOTED === true. Measured (M3 designer,
// against the full 52-deck/435-exercise artifact, which boots slower
// than M2's): 1 failure in 7 runs on the slower artifact, 0 in 5 on a
// faster one, then five clean re-runs of that SAME slow artifact right
// after -- classic timing-window inference (house verification standard
// 3), because __SXC1_BOOTED only proves Miso's initial render committed,
// not that the mount -> SetRoute -> beginIfNeeded -> ExBatch Begin round
// trip that WRITES this element has flushed to the DOM yet. A "null"
// read mid-flush is indistinguishable from the genuine lost-mount-Begin
// defect this assertion exists to catch (see COLD_BASELINE_ASSERTION_NAME
// above), which is exactly why a bare re-sample/retry-until-different
// approach would not do -- the fix polls to a SETTLED, POSITIVE reading
// with an explicit budget, and only THEN treats a value that never
// arrives as the real defect.
//
// Budget: 3000ms, chosen per this task's own instruction ("poll for a
// positive numeric baseline up to 3000ms after boot"). The negative
// control is unchanged by this fix and still passes: SABOTAGE mode
// (selfTestFixtureHtml(true) / a genuinely lost mount-time Begin) leaves
// #sxc1-prompt-baseline at "null" FOREVER, so it never becomes positive
// and this poll correctly exhausts its budget and reports the assertion
// FAILED with the required "never became positive within Nms" wording --
// see the --self-test-negative sweep in this file's own final report.
const BASELINE_POLL_BUDGET_MS = 3000;
const BASELINE_POLL_INTERVAL_MS = 40;

// ---------------------------------------------------------------------------
// M5 a11y pass (briefs/M5-ship.md ship checklist): keyboard-only
// completion, focus-on-advance, and SR-label assertions -- shared between
// --self-test (the fixture mirrors the app's focus management and ARIA
// surface; see the fixture's own a11y block) and a real run, exactly the
// runExerciseAssertions precedent. Fixed names so the negative sweep's
// M5_SELECTOR_ASSERTIONS map can reference them.
//
// The keyboard flows drive the page EXCLUSIVELY through CDP
// Input.dispatchKeyEvent (trusted key events -- Tab moves real focus,
// Enter genuinely activates; a synthetic page-JS KeyboardEvent does
// neither), never element.click(): they prove a keyboard-only learner
// can complete each exercise kind end to end. The focus assertions are
// deliberately DECOUPLED from the keyboard flows (they drive their
// advances with .click()), so the negative sweep can fail the
// keyboard-reachability sabotage ('a11yKeyboard') and the focus sabotage
// ('a11yFocusAdvance') independently -- see M5_SELECTOR_ASSERTIONS.
// ---------------------------------------------------------------------------

const KB_QUIZ_ASSERTION_NAME =
  'keyboard-only quiz completion: Tab/Enter alone (CDP dispatchKeyEvent, no mouse) restarts, selects, submits and advances to #ex-summary';
const KB_DRILL_ASSERTION_NAME =
  'keyboard-only drill completion: Tab/Enter alone (CDP dispatchKeyEvent, no mouse) restarts and confirms every step to #ex-summary';
const KB_LOOKUP_ASSERTION_NAME =
  'keyboard-only lookup completion: Tab + typed digits + Enter alone (CDP dispatchKeyEvent, no mouse) restarts, submits and advances to #ex-summary';
const FOCUS_QUIZ_ASSERTION_NAME =
  'focus on advance (quiz): after the final Next, document.activeElement is #ex-summary -- never dropped to <body>';
const FOCUS_DRILL_ASSERTION_NAME =
  'focus on advance (drill): after each confirm, document.activeElement is the NEXT .ex-step (then #ex-summary) -- never dropped to <body>';
const SR_LABELS_ASSERTION_NAME =
  'SR labels: #sxc1-export-blob carries an aria-label accessible name; a verify-hooked drill\'s .ex-verify is aria-live=polite';

// M6 W1 (briefs/M6-plan.md, W1 "D2-class absent-scenario parity"): the
// degraded-content surface exists ONLY when the exercise content bundle
// failed to load at boot -- on a healthy boot neither the visible
// #sxc1-content-error banner nor the #btn-content-retry affordance may
// be in the DOM at all (absent, not merely hidden). The positive half
// (bundle really missing -> banner present, names the failure, manuals
// still reachable, retry affordance rendered) is --check-content-missing,
// driven by check-site.sh's fetch-failure stage against a served copy of
// the bundle with content/ removed. Fixed name so the negative sweep's
// M6_SELECTOR_ASSERTIONS map ('contentDegraded' sabotages the fixture
// into rendering the banner on a healthy boot) can reference it.
const CONTENT_ABSENT_ASSERTION_NAME =
  'degraded-content surface absent on a healthy boot: no #sxc1-content-error banner, no #btn-content-retry anywhere in the DOM';

// ---------------------------------------------------------------------------
// M6 W2 (briefs/M6-plan.md ruling 3 + W2): THE UI-TEXT TABLE -- the ONE
// place both language passes read every learner-visible string a browser
// assertion PINS. Mirrors site/app/I18n.hs (the app's own table) entry
// for entry for exactly the strings pinned here; the JA flow runs the
// SAME assertion code with lang='ja' (parameterize, never duplicate --
// ruling 7), so a pinned string can only ever drift in one file.
// ---------------------------------------------------------------------------
const UI_TEXT = {
  en: {
    correctPrefix: 'Correct',
    notQuitePrefix: 'Not quite',
    exportAria: 'Exported progress data',
    verifyIdleOff: 'Device verification is off \u2014 confirm manually, or turn it on above.',
    // What #btn-ui-lang SHOWS while this language is active: the
    // switch-to label, written in the target language (I18n.iUiLangButton).
    uiLangButton: '\u65e5\u672c\u8a9e', // 日本語
    reviewBadgePrefix: 'Review ',
    devStatusOn1: 'Device verification is on, listening on MIDI channel 1.',
    devVerifyWaitingCc: 'Waiting for the device: CC 80 = 127 on MIDI channel 1.',
    devVerifyConfirmedCc: 'Confirmed by the device: CC 80 = 127.',
  },
  ja: {
    correctPrefix: '\u6b63\u89e3',       // 正解
    notQuitePrefix: '\u4e0d\u6b63\u89e3', // 不正解
    exportAria: '\u30a8\u30af\u30b9\u30dd\u30fc\u30c8\u3055\u308c\u305f\u9032\u6357\u30c7\u30fc\u30bf', // エクスポートされた進捗データ
    verifyIdleOff: '\u30c7\u30d0\u30a4\u30b9\u691c\u8a3c\u306f\u30aa\u30d5\u3067\u3059 \u2014 \u624b\u52d5\u3067\u78ba\u8a8d\u3059\u308b\u304b\u3001\u4e0a\u3067\u30aa\u30f3\u306b\u3057\u3066\u304f\u3060\u3055\u3044\u3002',
    uiLangButton: 'English',
    reviewBadgePrefix: '\u5fa9\u7fd2 ', // 復習
    devStatusOn1: '\u30c7\u30d0\u30a4\u30b9\u691c\u8a3c\u306f\u30aa\u30f3\u3067\u3059\u3002MIDI\u30c1\u30e3\u30f3\u30cd\u30eb1\u3067\u5f85\u3061\u53d7\u3051\u3066\u3044\u307e\u3059\u3002',
    devVerifyWaitingCc: '\u30c7\u30d0\u30a4\u30b9\u3092\u5f85\u6a5f\u4e2d: CC 80 = 127\uff08MIDI\u30c1\u30e3\u30f3\u30cd\u30eb1\uff09\u3002',
    devVerifyConfirmedCc: '\u30c7\u30d0\u30a4\u30b9\u3067\u78ba\u8a8d\u6e08\u307f: CC 80 = 127\u3002',
  },
};

// The ja-pass instances of runExerciseAssertions' own fixed names carry
// this suffix (the en pass stays byte-identical to before W2, so the
// LEGACY_EXPECTED_TO_FAIL list and every existing map keep matching).
const JA_NAME_SUFFIX = ' [ja]';

// Fixed names for the feedback-pinning assertions (previously inline
// literals), so the M6 W2 negative map can reference their ja instances.
const WRONG_QUIZ_FEEDBACK_ASSERTION_NAME =
  'wrong quiz answer: #ex-feedback starts with "Not quite" and carries class "incorrect"';
const CORRECT_QUIZ_FEEDBACK_ASSERTION_NAME =
  'correct quiz answer: #ex-feedback starts with "Correct", class "correct", #ex-note visible, #btn-ex-next present';
const LOOKUP_WRONG_ASSERTION_NAME =
  'lookup: wrong page submits to "Not quite"';
const LOOKUP_CORRECT_ASSERTION_NAME =
  'lookup: correct page submits to "Correct" and #ex-elapsed matches ^[0-9]+:[0-9][0-9]$';

// M6 W2: the UI-language toggle flow's own fixed names (shared by the
// self-test fixture and the real run through runUiLangJaAssertions).
const UILANG_SWITCH_ASSERTION_NAME =
  'UI language toggle: #btn-ui-lang shows the switch-to-ja label under EN and clicking it comes back REBOOTED with uiLang "ja" (reload-as-refetch is the switch mechanism)';
const UILANG_HEADER_ASSERTION_NAME =
  'UI language ja: the header renders Japanese (review badge and #btn-ui-lang labels) and document.documentElement.lang is "ja"';
const UILANG_PREF_ASSERTION_NAME =
  'UI language ja: the pref survives on disk -- the sxc1.uilang boot hint is "ja" and the SXC1PREFS blob carries P uiLang ja';
const UILANG_JAFIRST_RESPECT_ASSERTION_NAME =
  'ruling-4 guard: switching to ja never overrides an explicitly chosen jaFirst=off (the blob keeps P jaFirst 0 alongside P jaFirstSet 1)';
const UILANG_BUNDLE_ASSERTION_NAME =
  'UI language ja: the reloaded document fetched content/content.ja.txt and not content.en.txt (the reload IS the refetch)';
const UILANG_VERIFY_JA_ASSERTION_NAME =
  'UI language ja: a verify-hooked drill step renders the JA idle verify sentence in its aria-live region (learner-visible device text localizes)';
const UILANG_ROUNDTRIP_ASSERTION_NAME =
  'UI language toggle roundtrip: switching back restores EN (uiLang "en" after another reboot, #btn-ui-lang shows the switch-to-ja label again)';

// ---------------------------------------------------------------------------
// M6 W4: THE JA COURSE ITSELF -- the five assertions that make "the site
// is available in Japanese" a checked claim rather than a shipped file.
//
// Everything above pins the UI STRINGS (I18n.hs) under ja; these pin the
// COURSE: the Japanese the 52 decks were translated into in wave 3,
// fetched from the bundle the site actually ships, rendered by the real
// wasm, all the way through completing a quiz in Japanese.
//
// WHY THESE ARE LITERALS AND NOT DERIVED FROM THE BUNDLE: a check that
// reads its expectations out of the artifact it is checking cannot fail.
// An EN-fallback ja bundle (the emitter's own documented degenerate
// case: "anything without a variant falls back to English", which is
// exactly what content.ja.txt WAS through waves 1-2) would sail through
// a self-derived comparison, because every string would agree with
// itself. Pinned as literals -- copied from content/exercises/
// 030-pad-04.ex.md's ja: lines, the DEVICE_REAL_CFG precedent of the
// harness pinning real corpus identities -- an EN-fallback bundle turns
// all five of these red at once. RED-FIRST: demonstrated by serving a
// COPY of the bundle whose content.ja.txt is the EN emission relabelled
// "ja" (see the M6 W4 report).
//
// The pinned deck (pad-04) is deliberately NOT one of the decks the
// device suite (DEVICE_REAL_CFG: pad-01, pad-03) or --exercise-fixture
// (ch0-01, prep-02) already drive, so completing its quiz here cannot
// perturb what those assertions observe.
// ---------------------------------------------------------------------------
const JA_COURSE_PINS = {
  totals: { decks: 52, exercises: 435 },
  deck: {
    slug: 'pad-04',
    route: '#/x/pad-04',
    // ループにあわせてフィンガードラム
    titleJa: 'ループにあわせてフィンガードラム',
    // 波形表示を読み取り、... (the deck's summary: field variant)
    summaryJa: '波形表示を読み取り、リズムにドラムやベースを重ねる本章の中心となる練習に取り組み、すべてのループを一度に止める。',
  },
  quiz: {
    route: '#/x/pad-04/q-2-27',
    // パッドを叩くと表示されるもの
    titleJa: 'パッドを叩くと表示されるもの',
    // パッドを叩くと、その音の「波形」が表示されます。
    stemJa: 'パッドを叩くと、その音の「波形」が表示されます。',
    // 左から右へ移動するタテの線 (the [x] option)
    correctOptJa: '左から右へ移動するタテの線',
    // カウントダウンする MASTER BPM の値 (a [ ] option -- device labels stay Latin)
    wrongOptJa: 'カウントダウンする MASTER BPM の値',
    // 移動するタテの線は再生位置を示しています。 (### Why)
    noteJa: '移動するタテの線は再生位置を示しています。',
  },
  drill: {
    route: '#/x/pad-04/d-2-03',
    // ドラム＋パーカッションのループが安定して鳴り続けます。これが参考にするリズムです。
    step1CheckJa: 'ドラム＋パーカッションのループが安定して鳴り続けます。これが参考にするリズムです。',
  },
};

// ---------------------------------------------------------------------------
// M7 W3: THE JA MANUAL PINS -- the milestone's own claim, inside both
// full stages.
//
// M6 gave the learner a Japanese COURSE; M7's claim is the other half:
// with uiLang=ja the MANUAL BODY is real Japanese text -- selectable,
// searchable, copyable, reflowable -- and the original page IMAGE is
// still right there beside it (ruling 4: "/ja still shows it"). Through
// waves 1-2 the ja manual bundle carried ENGLISH for every document, and
// every assertion in these stages stayed green, because none of them
// looked at the manual body's LANGUAGE.
//
// WHY THESE ARE LITERALS AND NOT DERIVED FROM THE BUNDLE: the same
// reason JA_COURSE_PINS gives -- a check that reads its expectations out
// of the artifact it is checking cannot fail. These sentences are copied
// from wave 2's transcriptions of the page IMAGES
// (translations/<slug>.ja.md), so a ja bundle that fell back to English
// for a document turns the pin for that document red. RED-FIRST:
// demonstrated by rebuilding against a scratch translations/ with one
// .ja.md removed and serving the resulting EN-fallback bundle (see the
// W3 report).
//
// Two documents, deliberately: guide-book (71 pages, the bulk of the
// corpus) and midi (6 pages, a different transcription batch with tables
// and device labels in Latin caps).
const JA_MANUAL_PINS = {
  page: {
    slug: 'guide-book',
    route: '#/m/guide-book/p/2',
    jaRoute: '#/m/guide-book/p/2/ja',
    // The page body's own id (View.Pages: "page-<n>"), so the wait
    // cannot be satisfied by a different page's body.
    readySelector: '#page-2',
    // ## あらかじめご了承ください
    headingJa: 'あらかじめご了承ください',
    // 本書の説明・表示例やイラストなどは、実際の製品と異なる場合があります。
    bodyJa: '本書の説明・表示例やイラストなどは、実際の製品と異なる場合があります。',
    // The ORIGINAL page image ruling 4 keeps beside the text.
    imageSuffix: 'pages/guide-book/page-02.webp',
  },
  midi: {
    route: '#/m/midi/p/1',
    readySelector: '#page-1',
    // 本書は本機に搭載された MIDI 機能及びそのインプリメンテーションに関して記載しています。
    bodyJa: '本書は本機に搭載された MIDI 機能及びそのインプリメンテーションに関して記載しています。',
    // MIDI IN Ch. -- ruling 3: on-device labels stay in Latin caps even
    // in the Japanese text, so this must survive TOO.
    deviceLabel: 'MIDI IN Ch.',
  },
  toc: {
    route: '#/m/guide-book',
    // ## 使用環境について -- a section link in the manual outline
    sectionJa: '使用環境について',
  },
};

const JA_MANUAL_PAGE_ASSERTION_NAME =
  'ja manual: [JAM1] the SHIPPED ja manual bundle renders REAL JAPANESE on a real reading route -- the pinned heading and body sentence from guide-book p.2, document lang=ja, no #sxc1-manual-fallback and no lang override on the body (an EN-fallback ja bundle fails here)';
const JA_MANUAL_SECOND_DOC_ASSERTION_NAME =
  'ja manual: [JAM2] a SECOND document is Japanese too -- midi p.1 renders its pinned Japanese sentence and still carries the on-device label in Latin caps (ruling 3)';
const JA_MANUAL_IMAGE_ASSERTION_NAME =
  'ja manual: [JAM3] on the /ja route the ORIGINAL page image is still reachable BESIDE the Japanese text -- #ja-image points at the page scan, that URL really fetches, and the Japanese body is still rendered';
const JA_MANUAL_TOC_ASSERTION_NAME =
  'ja manual: [JAM4] the manual TOC renders the Japanese outline (a pinned JA section link) with no .manual-fallback-note anywhere';

const JA_COURSE_BUNDLE_ASSERTION_NAME =
  'ja course: [JAC1] the SHIPPED ja bundle carries the whole course -- #sxc1-exercise-stats reports 52 decks / 435 exercises and the pinned deck\'s title is its JAPANESE title (an EN-fallback ja bundle fails here)';
const JA_COURSE_INDEX_ASSERTION_NAME =
  'ja course: [JAC2] the deck index card, the deck page title and the deck summary: all render the corpus Japanese for the pinned deck';
const JA_COURSE_QUIZ_RENDER_ASSERTION_NAME =
  'ja course: [JAC3] a real corpus quiz renders in Japanese -- #ex-title, the #ex-stem question and BOTH pinned option labels are the corpus JA text';
const JA_COURSE_QUIZ_COMPLETE_ASSERTION_NAME =
  'ja course: [JAC4] completing that quiz in Japanese -- clicking the JA correct option grades Correct (JA feedback) and #ex-note renders the JA rationale';
const JA_COURSE_DRILL_ASSERTION_NAME =
  'ja course: [JAC5] a real corpus drill step shows its Japanese check: sentence in #ex-step-1-check';

// Trusted keyboard input for a session: returns pressKey(key) driving the
// full keyDown/keyUp pair through CDP's Input domain. 'Tab'/'Enter' are
// the navigation/activation pair the keyboard flows live on; single
// characters (the lookup's typed digits) additionally carry `text` on the
// keyDown so the focused <input> receives real text insertion.
function keyPresserFor(cdp, sessionId) {
  const NAMED = {
    Tab: { key: 'Tab', code: 'Tab', vk: 9 },
    Enter: { key: 'Enter', code: 'Enter', vk: 13, text: '\r' },
    ' ': { key: ' ', code: 'Space', vk: 32, text: ' ' },
  };
  return async (key) => {
    let d = NAMED[key];
    if (!d && /^[0-9]$/.test(key)) d = { key, code: `Digit${key}`, vk: key.charCodeAt(0), text: key };
    if (!d) d = { key, code: `Key${key.toUpperCase()}`, vk: key.toUpperCase().charCodeAt(0), text: key };
    const base = { key: d.key, code: d.code, windowsVirtualKeyCode: d.vk, nativeVirtualKeyCode: d.vk };
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', ...base, ...(d.text ? { text: d.text } : {}) }, sessionId);
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', ...base }, sessionId);
  };
}

async function assertColdFirstTryElapsed(coldH, fixture, waitMs, lang = 'en') {
  const T = UI_TEXT[lang] || UI_TEXT.en;
  const baselinePoll = await coldH.evaluate(`(async () => {
    const budgetMs = ${BASELINE_POLL_BUDGET_MS};
    const intervalMs = ${BASELINE_POLL_INTERVAL_MS};
    const start = Date.now();
    let lastRaw = null;
    while (Date.now() - start < budgetMs) {
      const el = document.querySelector('#sxc1-prompt-baseline');
      lastRaw = el ? el.textContent.trim() : null;
      const n = lastRaw === null ? NaN : Number(lastRaw);
      if (Number.isFinite(n) && n > 0) {
        return { raw: lastRaw, settled: true, waitedMs: Date.now() - start };
      }
      await new Promise((r) => setTimeout(r, intervalMs));
    }
    return { raw: lastRaw, settled: false, waitedMs: Date.now() - start };
  })()`);
  const baselineRaw = baselinePoll ? baselinePoll.raw : null;
  const baselineNum = baselineRaw === null ? NaN : Number(baselineRaw);
  const baselineOk = Number.isFinite(baselineNum) && baselineNum > 0;
  coldH.report(
    COLD_BASELINE_ASSERTION_NAME,
    baselineOk,
    baselineOk
      ? { baselineRaw, polledMs: baselinePoll.waitedMs }
      : {
        baselineRaw,
        polledMs: baselinePoll ? baselinePoll.waitedMs : null,
        note: `#sxc1-prompt-baseline never became positive within ${BASELINE_POLL_BUDGET_MS}ms`,
      },
  );
  await sleep(waitMs);
  const clickedCorrect = await coldH.clickAssert(
    `#${fixture.quiz.correctOpt}`,
    'cold-load quiz: click the correct option on the FIRST attempt (no wrong answer first)',
  );
  const clickedSubmit = clickedCorrect
    ? await coldH.clickAssert('#btn-ex-submit', 'cold-load quiz: click #btn-ex-submit (first attempt, correct)')
    : false;
  if (!clickedSubmit) {
    coldH.report(COLD_ELAPSED_ASSERTION_NAME, false, 'could not submit a first-try correct answer on the cold target');
    return;
  }
  const info = await coldH.evaluate(`(async () => {
    const start = Date.now();
    let fb;
    while (Date.now() - start < 5000) {
      fb = document.querySelector('#ex-feedback');
      if (fb && fb.textContent.indexOf(${JSON.stringify(T.correctPrefix)}) === 0) break;
      await new Promise((r) => setTimeout(r, 20));
    }
    let log = null;
    try {
      const el = document.querySelector('#sxc1-event-log');
      log = JSON.parse(el ? el.textContent : 'null');
    } catch { /* reported as null below */ }
    return {
      feedback: fb ? fb.textContent : null,
      firstEvent: Array.isArray(log) && log.length > 0 ? log[0] : null,
      logLength: Array.isArray(log) ? log.length : null,
    };
  })()`);
  const first = info && info.firstEvent;
  // Printed unconditionally (not just on failure) -- the actual elapsedMs
  // this run observed is exactly the number the M5 gate finding asked for
  // in a re-sign-off report, and report() below only echoes `observed` on
  // FAIL.
  console.log(`info - cold-load quiz: known wait=${waitMs}ms, observed elapsedMs=${first ? first.elapsedMs : '(no first event)'}`);
  coldH.report(
    COLD_ELAPSED_ASSERTION_NAME,
    Boolean(
      first
      && typeof first.elapsedMs === 'number'
      && first.elapsedMs >= waitMs
      && first.elapsedMs < waitMs + 20000,
    ),
    { waitMs, info },
  );
}

// The assertion routine shared between --self-test/--self-test-negative
// and a real run driven with --exercise-fixture. `h` bundles everything
// that differs between "a self-test fixture page" and "the real app" --
// evaluate/report/goto/click/assertElement/typeText -- so this function
// itself never knows which one it is talking to. `coldLoadFn(fixture,
// report)`, supplied by the caller, is the ONE piece that genuinely
// cannot be a fixed member of `h`: it must open (and clean up) its own
// genuinely fresh target/navigation -- see runSelfTest's and main()'s
// own versions, each built on the SAME technique NEW5's JA cold-load
// assertion already uses. Returns the list of {name, ok} results (in
// order), so callers (both --self-test-negative and a real run) can
// inspect individual outcomes, not just the total.
async function runExerciseAssertions(h, fixture, expectedExerciseJson, coldLoadFn, lang = 'en') {
  // M6 W2: the SAME assertion code runs under both languages (ruling 7:
  // parameterize, never duplicate). Every learner-visible text pin below
  // reads UI_TEXT[lang]; under ja every fixed assertion name gains
  // JA_NAME_SUFFIX so the two passes stay distinguishable in the results
  // (and the en pass stays byte-identical to before W2).
  const T = UI_TEXT[lang] || UI_TEXT.en;
  const SUF = lang === 'en' ? '' : JA_NAME_SUFFIX;
  const results = [];
  const report = (name, ok, observed) => {
    const n = name + SUF;
    results.push({ name: n, ok });
    h.report(n, ok, observed);
  };

  // 1. "#/x" renders #sxc1-exercise-index containing the fixture's deck.
  await h.goto('#/x', '#sxc1-exercise-index');
  const indexHtml = await h.evaluate(`(() => {
    const e = document.querySelector('#sxc1-exercise-index');
    return e ? e.outerHTML : null;
  })()`);
  const indexOk = Boolean(indexHtml)
    && indexHtml.includes('ex-chapter')
    && indexHtml.includes('ex-deck-card')
    && indexHtml.includes(`#/x/${fixture.quiz.deck}`);
  report('#/x renders #sxc1-exercise-index with a deck card for the fixture deck', indexOk, indexHtml && indexHtml.slice(0, 300));

  // 2. #sxc1-exercise-stats parses as JSON and matches --expect-exercise-json.
  if (expectedExerciseJson) {
    const statsRaw = await h.evaluate(`(() => {
      const e = document.querySelector('#sxc1-exercise-stats');
      return e ? e.textContent : null;
    })()`);
    let statsParsed = null;
    try { statsParsed = JSON.parse(statsRaw); } catch { /* reported below */ }
    if (statsParsed === null) {
      report('#sxc1-exercise-stats is valid JSON', false, statsRaw);
    } else {
      const mismatches = compareExerciseStats(statsParsed, expectedExerciseJson);
      report('#sxc1-exercise-stats matches --expect-exercise-json', mismatches.length === 0, mismatches);
    }
  }

  // 2b (M2 gate fix H1/H6/M5). COLD LOAD + KNOWN WAIT + FIRST-TRY
  // CORRECT ANSWER, on its OWN genuinely fresh target -- never the warm
  // session the rest of this function drives (so it cannot leak state
  // into, or inherit state from, any other assertion here). See
  // assertColdFirstTryElapsed's own Haddock-style comment above for why
  // first-try-correct (never wrong-then-right) and why elapsedMs itself,
  // not the M:SS string.
  if (typeof coldLoadFn === 'function') {
    await coldLoadFn(fixture, report, lang);
  } else {
    report(COLD_ELAPSED_ASSERTION_NAME, false, 'no coldLoadFn was wired for this harness');
  }

  // 3. QUIZ ANSWER PATH. Ready selectors below are the KIND-specific
  // class (.kind-quiz/.kind-drill/.kind-lookup), never the shared
  // #sxc1-exercise id: that id persists across every exercise route (the
  // runner's own outer wrapper), so waiting for it alone can observe the
  // PREVIOUS exercise still on screen mid-navigation -- MEASURED on a
  // real run under load (the 108-route sweep just before this section):
  // it raced and read a stale drill/lookup page's content.
  await h.goto(`#/x/${fixture.quiz.deck}/${fixture.quiz.id}`, '.kind-quiz');
  // M2 gate fix (H1/M5): a KNOWN wait with the prompt on screen before
  // this exercise's very FIRST submit (see WARM_FIRST_ELAPSED_ASSERTION_NAME
  // above for why this path, specifically, is the one that reliably
  // exercises H1). The wrong-then-right sequence immediately below is
  // otherwise untouched -- this only adds a wait and one new assertion,
  // it changes no existing pass/fail outcome.
  const warmFirstWaitMs = 900;
  await sleep(warmFirstWaitMs);
  await h.clickAssert(`#${fixture.quiz.wrongOpt}`, `click the wrong quiz option (${fixture.quiz.wrongOpt})`);
  await h.clickAssert('#btn-ex-submit', 'click #btn-ex-submit (wrong answer)');
  // Submitting reads both clocks via an async IO round trip (real Main.hs:
  // Miso's 'io' runs "after the VDOM has been patched", and Miso.Date's
  // wall-clock read is itself a real JS round trip) before the graded
  // state materialises, so this polls for #ex-feedback rather than
  // reading it the instant the click's own evaluate() call returns.
  const wrongFeedback = await h.evaluate(`(async () => {
    const start = Date.now();
    let e;
    while (Date.now() - start < 3000) {
      e = document.querySelector('#ex-feedback');
      if (e) break;
      await new Promise((r) => setTimeout(r, 20));
    }
    return e ? { text: e.textContent, cls: e.className } : null;
  })()`);
  report(
    WRONG_QUIZ_FEEDBACK_ASSERTION_NAME,
    Boolean(wrongFeedback && wrongFeedback.text.startsWith(T.notQuitePrefix) && wrongFeedback.cls.split(/\s+/).includes('incorrect')),
    wrongFeedback,
  );
  // M2 gate fix (H1/M5): this wrong-answer submit is the exercise's
  // FIRST-EVER graded event this session (Begin just fired via the
  // h.goto above), and gradeStep computes/re-baselines elapsedMs the
  // same way regardless of whether the attempt was correct -- so it is
  // exactly as diagnostic of H1 as a correct first try would be, without
  // disturbing the existing wrong-then-right sequence at all.
  const warmFirstEvent = await h.evaluate(`(() => {
    const e = document.querySelector('#sxc1-event-log');
    let log = null;
    try { log = JSON.parse(e ? e.textContent : 'null'); } catch { /* reported as null below */ }
    return Array.isArray(log) && log.length > 0 ? log[0] : null;
  })()`);
  console.log(`info - warm first-attempt quiz submit: known wait=${warmFirstWaitMs}ms, observed elapsedMs=${warmFirstEvent ? warmFirstEvent.elapsedMs : '(no first event)'}`);
  report(
    WARM_FIRST_ELAPSED_ASSERTION_NAME,
    Boolean(
      warmFirstEvent
      && typeof warmFirstEvent.elapsedMs === 'number'
      && warmFirstEvent.elapsedMs >= warmFirstWaitMs
      && warmFirstEvent.elapsedMs < warmFirstWaitMs + 20000,
    ),
    warmFirstEvent,
  );
  // NO deselect step here (briefs/M2-signoff-fixes.json, task
  // "quiz-selection-semantics", FIX 2): the ordinary learner path is
  // wrong option -> submit -> correct option -> submit, full stop. A
  // manual deselect between the two clicks made this assertion
  // satisfiable only via a path no real learner takes, which is exactly
  // how the single/multi selection-arity defect (SXC1.Exercise.Engine's
  // 'Toggle') shipped past this harness -- see FIX 1.
  await h.clickAssert(`#${fixture.quiz.correctOpt}`, `click the correct quiz option (${fixture.quiz.correctOpt})`);
  await h.clickAssert('#btn-ex-submit', 'click #btn-ex-submit (correct answer)');
  // #ex-feedback already EXISTS (from the wrong attempt above), so this
  // polls for its TEXT to actually flip to "Correct" -- existence alone
  // would not detect the async re-grade landing (see the comment above).
  const rightFeedback = await h.evaluate(`(async () => {
    const start = Date.now();
    let fb;
    while (Date.now() - start < 3000) {
      fb = document.querySelector('#ex-feedback');
      if (fb && fb.textContent.indexOf(${JSON.stringify(T.correctPrefix)}) === 0) break;
      await new Promise((r) => setTimeout(r, 20));
    }
    const note = document.querySelector('#ex-note');
    const next = document.querySelector('#btn-ex-next');
    return fb ? {
      text: fb.textContent, cls: fb.className,
      noteVisible: Boolean(note) && note.offsetParent !== null,
      nextPresent: Boolean(next),
    } : null;
  })()`);
  report(
    CORRECT_QUIZ_FEEDBACK_ASSERTION_NAME,
    Boolean(rightFeedback && rightFeedback.text.startsWith(T.correctPrefix) && rightFeedback.cls.split(/\s+/).includes('correct')
      && rightFeedback.noteVisible && rightFeedback.nextPresent),
    rightFeedback,
  );

  // 4. CITATION ROUND TRIP.
  const citeInfo = await h.evaluate(`(() => {
    const a = document.querySelector('#ex-cites a.cite');
    return a ? { href: a.getAttribute('href') } : null;
  })()`);
  const expectedHref = `#/m/${fixture.quiz.citeSlug}/p/${fixture.quiz.citePage}`;
  report('#ex-cites a.cite href matches the fixture citation', Boolean(citeInfo && citeInfo.href === expectedHref), citeInfo);
  await h.clickAssert('#ex-cites a.cite', 'click the citation link');
  const pageId = `#page-${fixture.quiz.citePage}`;
  const onManualPage = await h.evaluate(`(async () => {
    const start = Date.now();
    while (Date.now() - start < 5000) {
      if (document.querySelector(${JSON.stringify(pageId)})) return true;
      await new Promise((r) => setTimeout(r, 20));
    }
    return document.querySelector(${JSON.stringify(pageId)}) !== null;
  })()`);
  report(`clicking the citation renders ${pageId}`, onManualPage === true, onManualPage);
  await h.evaluate('window.history.back(); true');
  const backOk = await h.evaluate(`(async () => {
    const start = Date.now();
    while (Date.now() - start < 5000) {
      const opt = document.querySelector(${JSON.stringify(`#${fixture.quiz.correctOpt}`)});
      if (opt && opt.getAttribute('aria-pressed') === 'true') return true;
      await new Promise((r) => setTimeout(r, 20));
    }
    const opt = document.querySelector(${JSON.stringify(`#${fixture.quiz.correctOpt}`)});
    return Boolean(opt) && opt.getAttribute('aria-pressed') === 'true';
  })()`);
  report('going back preserves the quiz prompt with the previous selection still applied', backOk === true, backOk);

  // 4b (M2 gate fix H7). RESTART IS A FRESH SCREEN. The quiz above is
  // still sitting in its "answered correctly, previous selection
  // restored" state from the back-navigation just above -- exactly the
  // state a learner who wants to try again from scratch would be
  // looking at when they click Restart. Requires the FRESH prompt to
  // carry none of the previous attempt's grading: no #ex-feedback text,
  // no #ex-note, no #btn-ex-next, and no option left aria-pressed=true.
  await h.clickAssert('#btn-ex-restart', 'click #btn-ex-restart after a correct quiz answer');
  const afterRestart = await h.evaluate(`(async () => {
    const start = Date.now();
    // Restart round-trips through the same async clock IO as a submit
    // (see the #ex-feedback polls above) -- poll for the pressed option
    // to actually clear rather than reading the instant click() returns.
    while (Date.now() - start < 3000) {
      const opt = document.querySelector(${JSON.stringify(`#${fixture.quiz.correctOpt}`)});
      if (!opt || opt.getAttribute('aria-pressed') !== 'true') break;
      await new Promise((r) => setTimeout(r, 20));
    }
    return {
      feedbackPresent: document.querySelector('#ex-feedback') !== null,
      notePresent: document.querySelector('#ex-note') !== null,
      nextPresent: document.querySelector('#btn-ex-next') !== null,
      anyPressed: Array.prototype.some.call(
        document.querySelectorAll('.ex-option'),
        (b) => b.getAttribute('aria-pressed') === 'true',
      ),
    };
  })()`);
  report(
    'Restart yields a genuinely blank prompt: no #ex-feedback, no #ex-note, no #btn-ex-next, no option aria-pressed="true"',
    Boolean(afterRestart)
      && afterRestart.feedbackPresent === false
      && afterRestart.notePresent === false
      && afterRestart.nextPresent === false
      && afterRestart.anyPressed === false,
    afterRestart,
  );

  // 5. DRILL.
  await h.goto(`#/x/${fixture.drill.deck}/${fixture.drill.id}`, '.kind-drill');
  const stepCount = await h.evaluate('document.querySelectorAll("#ex-steps > li").length');
  report('#ex-steps > li count equals the fixture drill step count', stepCount === fixture.drill.steps, stepCount);
  const progressBefore = await h.evaluate(`(() => {
    const e = document.querySelector('#ex-progress');
    return e ? e.textContent : null;
  })()`);
  await h.clickAssert('#btn-ex-confirm-1', 'click #btn-ex-confirm-1');
  const progressAfter = await h.evaluate(`(async () => {
    const start = Date.now();
    while (Date.now() - start < 5000) {
      const e = document.querySelector('#ex-progress');
      if (e && e.textContent !== ${JSON.stringify(progressBefore)}) return e.textContent;
      await new Promise((r) => setTimeout(r, 20));
    }
    const e = document.querySelector('#ex-progress');
    return e ? e.textContent : null;
  })()`);
  report(
    `confirming step 1 moves #ex-progress from "${progressBefore}" to "2 / ${fixture.drill.steps}"`,
    progressAfter === `2 / ${fixture.drill.steps}`,
    { progressBefore, progressAfter },
  );
  if (fixture.drill.hasVerify) {
    const verifyText = await h.evaluate(`(() => {
      const e = document.querySelector('.ex-verify');
      return e ? e.textContent : null;
    })()`);
    report('a drill step with a verify hook has a non-empty .ex-verify', Boolean(verifyText && verifyText.trim().length > 0), verifyText);
  }

  // 5b (M2 gate fix H8). Confirm every REMAINING step (step 1 is already
  // confirmed above) so the drill is COMPLETE -- citations must survive
  // completion, not just the in-progress view (site/app/View/Exercise.hs
  // keeps a drill's step list visible even once esDone, precisely so
  // this stays true). Then require at least one confirmed step to carry
  // a real citation link.
  for (let stepN = 2; stepN <= fixture.drill.steps; stepN += 1) {
    // Confirming a step is itself an async-clock round trip against the
    // real app (same reasoning as the #ex-feedback polls elsewhere in
    // this function) -- #btn-ex-confirm-N does not exist until the
    // PREVIOUS confirm's state update has actually landed, so this polls
    // for it rather than assuming the previous click() already settled.
    await h.evaluate(`(async () => {
      const start = Date.now();
      while (Date.now() - start < 3000) {
        if (document.querySelector(${JSON.stringify(`#btn-ex-confirm-${stepN}`)})) return true;
        await new Promise((r) => setTimeout(r, 20));
      }
      return document.querySelector(${JSON.stringify(`#btn-ex-confirm-${stepN}`)}) !== null;
    })()`);
    await h.clickAssert(`#btn-ex-confirm-${stepN}`, `click #btn-ex-confirm-${stepN}`);
  }
  const drillCiteHrefs = await h.evaluate(`(async () => {
    const start = Date.now();
    let anchors = [];
    while (Date.now() - start < 3000) {
      anchors = Array.prototype.map.call(document.querySelectorAll('#ex-steps a.cite'), (a) => a.getAttribute('href'));
      if (anchors.length > 0) break;
      await new Promise((r) => setTimeout(r, 20));
    }
    return anchors;
  })()`);
  // M2 re-gate LOW fix: beyond well-formedness, at least one rendered
  // href must EQUAL the fixture's DECLARED citation target -- a drill
  // rendering some other (valid-looking) manual URL must fail.
  const declaredDrillHref = `#/m/${fixture.drill.citeSlug}/p/${fixture.drill.citePage}`;
  report(
    `a completed drill renders a.cite hrefs that are well-formed AND include the declared ${declaredDrillHref}`,
    Array.isArray(drillCiteHrefs) && drillCiteHrefs.length > 0
      && drillCiteHrefs.every((href) => /^#\/m\/[a-z0-9][a-z0-9-]*\/p\/[0-9]+$/.test(href))
      && drillCiteHrefs.includes(declaredDrillHref),
    { drillCiteHrefs, declaredDrillHref },
  );

  // 6. LOOKUP -- CDP Input.insertText, never a synthetic input event (P-D).
  await h.goto(`#/x/${fixture.lookup.deck}/${fixture.lookup.id}`, '.kind-lookup');

  // 6a (M2 gate fix H8). UNGRADED: zero citations before any submission
  // -- a lookup must not spoil its own answer.
  const lookupCitesBefore = await h.evaluate("document.querySelectorAll('#sxc1-exercise a.cite').length");
  report('an ungraded lookup renders zero a.cite (must not spoil its own answer)', lookupCitesBefore === 0, lookupCitesBefore);

  const wrongPage = fixture.lookup.targetPage > 1 ? fixture.lookup.targetPage - 1 : fixture.lookup.targetPage + 1;
  await h.typeText('#ex-find-input', String(wrongPage));
  await h.clickAssert('#btn-ex-find-submit', 'submit the wrong lookup page');
  // Same async-clock-round-trip reasoning as the quiz feedback above.
  const lookupWrong = await h.evaluate(`(async () => {
    const start = Date.now();
    let e;
    while (Date.now() - start < 3000) {
      e = document.querySelector('#ex-feedback');
      if (e) break;
      await new Promise((r) => setTimeout(r, 20));
    }
    return e ? e.textContent : null;
  })()`);
  report(LOOKUP_WRONG_ASSERTION_NAME, Boolean(lookupWrong && lookupWrong.startsWith(T.notQuitePrefix)), lookupWrong);
  await h.typeText('#ex-find-input', String(fixture.lookup.targetPage));
  await h.clickAssert('#btn-ex-find-submit', 'submit the correct lookup page');
  const lookupRight = await h.evaluate(`(async () => {
    const start = Date.now();
    let fb;
    while (Date.now() - start < 3000) {
      fb = document.querySelector('#ex-feedback');
      if (fb && fb.textContent.indexOf(${JSON.stringify(T.correctPrefix)}) === 0) break;
      await new Promise((r) => setTimeout(r, 20));
    }
    const el = document.querySelector('#ex-elapsed');
    return { text: fb ? fb.textContent : null, elapsed: el ? el.textContent : null };
  })()`);
  report(
    LOOKUP_CORRECT_ASSERTION_NAME,
    Boolean(lookupRight.text && lookupRight.text.startsWith(T.correctPrefix) && lookupRight.elapsed && /^[0-9]+:[0-9][0-9]$/.test(lookupRight.elapsed)),
    lookupRight,
  );

  // 6b (M2 gate fix H8). GRADED (correct): at least one a.cite whose
  // page number agrees with the fixture -- fixture.lookup.targetPage is
  // exactly the find: target's own page number BY CONSTRUCTION (a
  // lookup's citation IS the thing it was asked to find; see
  // site/test/CheckExercises.hs's findLookup / site/app/View/Exercise.hs's
  // citesForFeedback), so this is a real agreement check, not merely a
  // pattern match.
  const lookupCiteAfter = await h.evaluate(`(() => {
    const a = document.querySelector('#ex-cites a.cite');
    return a ? { href: a.getAttribute('href') } : null;
  })()`);
  // M2 re-gate LOW fix: the slug must agree too -- the right page under
  // the wrong manual must fail. targetSlug is emitted by
  // browserFixtureJson (real runs) and set in SELF_TEST_FIXTURE.
  const declaredLookupHref = `#/m/${fixture.lookup.targetSlug}/p/${fixture.lookup.targetPage}`;
  report(
    `a graded (correct) lookup renders an a.cite whose href equals the declared ${declaredLookupHref}`,
    Boolean(lookupCiteAfter && lookupCiteAfter.href === declaredLookupHref),
    { lookupCiteAfter, declaredLookupHref },
  );

  // 7. #sxc1-event-log.
  const eventLog = await h.evaluate(`(() => {
    const e = document.querySelector('#sxc1-event-log');
    if (!e) return null;
    try { return JSON.parse(e.textContent); } catch { return 'PARSE_ERROR'; }
  })()`);
  const lastEvent = Array.isArray(eventLog) && eventLog.length > 0 ? eventLog[eventLog.length - 1] : null;
  report(
    '#sxc1-event-log is a non-empty JSON array whose last entry is a correct outcome for the fixture exercise',
    Boolean(lastEvent && lastEvent.outcome === 'correct' && lastEvent.exercise === fixture.lookup.id),
    { length: Array.isArray(eventLog) ? eventLog.length : eventLog, lastEvent },
  );

  // 7b (M5 a11y pass). KEYBOARD-ONLY COMPLETION, FOCUS-ON-ADVANCE, SR
  // LABELS -- see the M5 assertion-name block above for the design
  // (keyboard flows: dispatchKeyEvent ONLY; focus flows: click-driven on
  // purpose, so each sabotage fails exactly its own assertions). Runs
  // AFTER section 7 (the event-log tail assertion) because completing
  // exercises appends Completed events that would change that tail.
  {
    const kbActive = () => h.evaluate(
      "(() => { const a = document.activeElement; return a ? { tag: a.tagName, id: a.id || null, isBody: a === document.body } : null; })()",
    );
    const kbBlur = () => h.evaluate(
      'if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur(); true',
    );
    // Tab until the element with `wantId` holds focus. Two rounds with a
    // blur between them: an app-side focus move mid-walk (the advance
    // focus management this same section pins) can land the walk PAST the
    // target in document order, and after sabotage a lost focus restarts
    // from <body> -- the wrap keeps completion-reachability independent of
    // where focus currently sits, which is exactly what keeps the
    // 'a11yFocusAdvance' sabotage from also failing the keyboard flows.
    const kbTabTo = async (wantId, maxTabs = 45) => {
      for (let round = 0; round < 2; round += 1) {
        for (let i = 0; i < maxTabs; i += 1) {
          await h.pressKey('Tab');
          const a = await kbActive();
          if (a && a.id === wantId) return { found: true, round, tabs: i + 1 };
        }
        await kbBlur();
      }
      return { found: false, at: await kbActive() };
    };
    const waitFor = (exprJs, budget = 3000) => h.evaluate(`(async () => {
      const start = Date.now();
      while (Date.now() - start < ${budget}) {
        if (${exprJs}) return true;
        await new Promise((r) => setTimeout(r, 25));
      }
      return ${exprJs};
    })()`);
    const waitFocusOn = (wantId, budget = 2500) => h.evaluate(`(async () => {
      const start = Date.now();
      while (Date.now() - start < ${budget}) {
        const a = document.activeElement;
        if (a && a.id === ${JSON.stringify(wantId)}) return { ok: true, id: a.id };
        await new Promise((r) => setTimeout(r, 25));
      }
      const a = document.activeElement;
      return { ok: false, want: ${JSON.stringify(wantId)}, got: a ? (a.id || a.tagName) : null, isBody: a === document.body };
    })()`);
    // Existence-guarded click: a missing element becomes an ordinary
    // false observation folded into the owning assertion, never a page
    // exception escaping as a spurious harness error (the m3(a)/(b)
    // rule this whole file follows).
    const fClick = (selector) => h.evaluate(
      `(() => { const e = document.querySelector(${JSON.stringify(selector)}); if (!e) return false; e.click(); return true; })()`,
    );

    // -- FOCUS ON ADVANCE, quiz (click-driven; the quiz is blank after
    // 4b's restart, so restart -> correct -> submit -> Next is a full
    // fresh pass whose final advance removes the focused Next button).
    await h.goto(`#/x/${fixture.quiz.deck}/${fixture.quiz.id}`, '.kind-quiz');
    await fClick('#btn-ex-restart');
    await waitFor("document.querySelector('#ex-feedback') === null");
    await fClick(`#${fixture.quiz.correctOpt}`);
    await fClick('#btn-ex-submit');
    await waitFor(`(() => { const e = document.querySelector('#ex-feedback'); return e && e.textContent.indexOf(${JSON.stringify(T.correctPrefix)}) === 0; })()`);
    await fClick('#btn-ex-next');
    const fqSummary = await waitFor("document.querySelector('#ex-summary') !== null");
    const fqFocus = await waitFocusOn('ex-summary');
    report(
      FOCUS_QUIZ_ASSERTION_NAME,
      fqSummary === true && Boolean(fqFocus) && fqFocus.ok === true,
      { fqSummary, fqFocus },
    );

    // -- FOCUS ON ADVANCE, drill (click-driven): restart, then confirm
    // each step and require focus to land on the NEXT step's li -- and,
    // for the final confirm, on #ex-summary.
    await h.goto(`#/x/${fixture.drill.deck}/${fixture.drill.id}`, '.kind-drill');
    await fClick('#btn-ex-restart');
    await waitFor("document.querySelector('#btn-ex-confirm-1') !== null");
    const fdSeq = [];
    for (let s = 1; s <= fixture.drill.steps; s += 1) {
      const present = await waitFor(`document.querySelector('#btn-ex-confirm-${s}') !== null`);
      if (!present) { fdSeq.push({ step: s, present: false }); break; }
      await fClick(`#btn-ex-confirm-${s}`);
      const want = s === fixture.drill.steps ? 'ex-summary' : `ex-step-${s + 1}`;
      fdSeq.push({ step: s, want, focus: await waitFocusOn(want) });
    }
    report(
      FOCUS_DRILL_ASSERTION_NAME,
      fdSeq.length === fixture.drill.steps && fdSeq.every((e) => e.focus && e.focus.ok === true),
      fdSeq,
    );

    // -- KEYBOARD-ONLY QUIZ (dispatchKeyEvent only from here on: the
    // focus flows above left the quiz/drill completed, so each keyboard
    // flow starts by Tab+Enter on the always-rendered Restart button).
    await h.goto(`#/x/${fixture.quiz.deck}/${fixture.quiz.id}`, '.kind-quiz');
    await kbBlur();
    const kbq = { restart: await kbTabTo('btn-ex-restart') };
    if (kbq.restart.found) await h.pressKey('Enter');
    // Sync only (never a pass criterion): whether the restart left a
    // genuinely blank prompt is the dedicated Restart assertion's own
    // claim (H7) -- and legacy-all deliberately breaks exactly that, so
    // gating THIS assertion on blankness would misattribute an H7
    // failure to the keyboard flow. The keyboard proof below is the
    // aria-pressed flip + the summary, both keyboard-caused.
    await waitFor("document.querySelector('#btn-ex-submit') !== null");
    await sleep(250); // let the app's own restart focus move settle before walking
    kbq.option = await kbTabTo(fixture.quiz.correctOpt);
    if (kbq.option.found) await h.pressKey('Enter');
    kbq.pressed = await waitFor(`(() => { const o = document.querySelector('#${fixture.quiz.correctOpt}'); return o && o.getAttribute('aria-pressed') === 'true'; })()`);
    kbq.submit = await kbTabTo('btn-ex-submit');
    if (kbq.submit.found) await h.pressKey('Enter');
    kbq.correct = await waitFor(`(() => { const e = document.querySelector('#ex-feedback'); return e && e.textContent.indexOf(${JSON.stringify(T.correctPrefix)}) === 0; })()`);
    kbq.next = await kbTabTo('btn-ex-next');
    if (kbq.next.found) await h.pressKey('Enter');
    kbq.summary = await waitFor("document.querySelector('#ex-summary') !== null");
    report(
      KB_QUIZ_ASSERTION_NAME,
      Boolean(kbq.restart.found && kbq.option.found && kbq.pressed && kbq.submit.found
        && kbq.correct && kbq.next.found && kbq.summary),
      kbq,
    );

    // -- KEYBOARD-ONLY DRILL.
    await h.goto(`#/x/${fixture.drill.deck}/${fixture.drill.id}`, '.kind-drill');
    await kbBlur();
    const kbd = { restart: await kbTabTo('btn-ex-restart') };
    if (kbd.restart.found) await h.pressKey('Enter');
    kbd.fresh = await waitFor("document.querySelector('#btn-ex-confirm-1') !== null && document.querySelector('#ex-summary') === null");
    await sleep(250);
    kbd.steps = [];
    let kbdOk = Boolean(kbd.restart.found && kbd.fresh);
    for (let s = 1; kbdOk && s <= fixture.drill.steps; s += 1) {
      await waitFor(`document.querySelector('#btn-ex-confirm-${s}') !== null`);
      const t = await kbTabTo(`btn-ex-confirm-${s}`);
      kbd.steps.push({ step: s, ...t });
      if (!t.found) { kbdOk = false; break; }
      await h.pressKey('Enter');
    }
    kbd.summary = kbdOk && await waitFor("document.querySelector('#ex-summary') !== null && document.querySelector('.btn-ex-confirm') === null");
    report(KB_DRILL_ASSERTION_NAME, Boolean(kbdOk && kbd.summary), kbd);

    // -- KEYBOARD-ONLY LOOKUP (typed digits travel as trusted key events
    // with text payloads -- the same real-input rule as Input.insertText
    // in typeText, one key at a time).
    await h.goto(`#/x/${fixture.lookup.deck}/${fixture.lookup.id}`, '.kind-lookup');
    await kbBlur();
    const kbl = { restart: await kbTabTo('btn-ex-restart') };
    if (kbl.restart.found) await h.pressKey('Enter');
    kbl.blank = await waitFor("document.querySelector('#ex-feedback') === null && document.querySelector('#ex-find-input') !== null");
    await sleep(250);
    kbl.input = await kbTabTo('ex-find-input');
    if (kbl.input.found) {
      for (const ch of String(fixture.lookup.targetPage)) await h.pressKey(ch);
    }
    kbl.typed = await waitFor(`(() => { const e = document.querySelector('#ex-find-input'); return e && e.value === ${JSON.stringify(String(fixture.lookup.targetPage))}; })()`);
    kbl.submit = await kbTabTo('btn-ex-find-submit');
    if (kbl.submit.found) await h.pressKey('Enter');
    kbl.correct = await waitFor(`(() => { const e = document.querySelector('#ex-feedback'); return e && e.textContent.indexOf(${JSON.stringify(T.correctPrefix)}) === 0; })()`);
    kbl.next = await kbTabTo('btn-ex-next');
    if (kbl.next.found) await h.pressKey('Enter');
    kbl.summary = await waitFor("document.querySelector('#ex-summary') !== null");
    report(
      KB_LOOKUP_ASSERTION_NAME,
      Boolean(kbl.restart.found && kbl.blank && kbl.input.found && kbl.typed && kbl.submit.found
        && kbl.correct && kbl.next.found && kbl.summary),
      kbl,
    );

    // -- SR LABELS (the device-panel half lives in the D-suite's D27,
    // whose scenario drill always carries verify hooks; here the check
    // covers what BOTH harness targets render without a fake: the home
    // export textarea's accessible name, plus the verify-line live
    // region whenever THIS fixture's drill does carry hooks).
    let srVerify = { checked: false };
    if (fixture.drill.hasVerify) {
      await h.goto(`#/x/${fixture.drill.deck}/${fixture.drill.id}`, '.kind-drill');
      const live = await h.evaluate("(() => { const e = document.querySelector('.ex-verify'); return e ? e.getAttribute('aria-live') : null; })()");
      srVerify = { checked: true, live };
    }
    await h.goto('#/', '#sxc1-progress-tools');
    const srExport = await h.evaluate("(() => { const e = document.querySelector('#sxc1-export-blob'); return e ? e.getAttribute('aria-label') : null; })()");
    // M6 W2: strengthened from non-empty to the EXACT localized
    // accessible name (UI_TEXT[lang].exportAria), so ARIA parity is a
    // real pin under BOTH languages, not merely presence.
    report(
      SR_LABELS_ASSERTION_NAME,
      srExport === T.exportAria
        && (!srVerify.checked || srVerify.live === 'polite'),
      { srExport, wantAria: T.exportAria, srVerify },
    );

    // Restore the pre-existing route context: section 8 below has always
    // measured the RUNNER's overflow (the lookup was the last runner on
    // screen before this M5 section existed).
    await h.goto(`#/x/${fixture.lookup.deck}/${fixture.lookup.id}`, '.kind-lookup');
  }

  // 8. 390x844: no horizontal overflow on the runner.
  await h.setMobileViewport();
  const overflow = await h.evaluate(`(() => ({
    scrollWidth: document.documentElement.scrollWidth,
    innerWidth: window.innerWidth,
  }))()`);
  await h.clearViewport();
  report(
    'exercise runner has no horizontal overflow at 390x844',
    Boolean(overflow) && overflow.scrollWidth <= overflow.innerWidth + 1,
    overflow,
  );

  // 8c (M6 W1): absent-scenario parity, negative half -- see
  // CONTENT_ABSENT_ASSERTION_NAME's own comment. Queried document-wide
  // (any route) because the banner renders on EVERY route when the
  // bundle load failed.
  const degradedSurface = await h.evaluate(`(() => ({
    banner: document.querySelector('#sxc1-content-error') !== null,
    retry: document.querySelector('#btn-content-retry') !== null,
  }))()`);
  report(
    CONTENT_ABSENT_ASSERTION_NAME,
    Boolean(degradedSurface) && degradedSurface.banner === false && degradedSurface.retry === false,
    degradedSurface,
  );

  // 9. Console hygiene.
  const hygiene = h.consoleHygiene();
  report('zero console errors and uncaught exceptions during the exercise run', hygiene.ok, hygiene);

  return results;
}

// ---------------------------------------------------------------------------
// M6 W2: THE UI-LANGUAGE (JA) FLOW -- shared, exactly like
// runExerciseAssertions, between the self-test fixture (whose header
// mirrors #btn-ui-lang and the sxc1.uilang boot hint -- see the fixture's
// own M6 W2 block) and the real app. Assumes the caller has already run
// runProgressAssertionsPost on this session, whose final step leaves
// jaFirst EXPLICITLY off (jaFirstSet recorded) -- which is precisely what
// lets this flow POSITIVELY assert ruling 4's never-override-an-explicit-
// choice half. (The suggestion-DOES-fire half needs a fresh profile and
// lives in --check-ja-toggle, driven by check-site's own stage.)
//
// Steps: switch EN->JA through the real #btn-ui-lang (the app persists
// the pref + boot hint and reloads itself -- reload-as-refetch); assert
// header/pref/(optionally bundle-fetch); re-run the ENTIRE
// runExerciseAssertions under lang='ja' (every learner-visible text pin
// now pins the JA string -- ruling 7's parameterize-not-duplicate,
// a11y assertions included); pin the JA verify idle sentence; then
// switch back to EN and assert the roundtrip, so everything after this
// flow (mobile sweep, D-suite) still runs under the language it pins.
// `cfg.checkBundleFetch` gates the resource-entry assertion to the real
// run (the file:// fixture fetches no bundle -- documented, never
// silently skipped: the fixture caller passes false).
// ---------------------------------------------------------------------------
async function runUiLangJaAssertions(h, fixture, coldLoadFn, cfg) {
  const results = [];
  const report = (name, ok, observed) => {
    results.push({ name, ok });
    h.report(name, ok, observed);
  };
  const readUiLang = async () => {
    const payload = await h.evaluate("(() => { const e = document.querySelector('#sxc1-progress'); try { return JSON.parse(e ? e.textContent : 'null'); } catch (err) { return null; } })()");
    return payload ? payload.uiLang : null;
  };
  const btnLabel = () => h.evaluate("(() => { const e = document.querySelector('#btn-ui-lang'); return e ? e.textContent : null; })()");
  const clickUiLang = () => h.evaluate("(() => { const e = document.querySelector('#btn-ui-lang'); if (!e) return false; e.click(); return true; })()");

  // -- 1. THE SWITCH. The click persists prefs + hint and triggers a
  // real reload; waitBooted (never Page.reload -- the PAGE reloads
  // itself) then a settled uiLang === 'ja' payload.
  await h.goto('#/', '#sxc1-progress-tools');
  const labelBefore = await btnLabel();
  const uiLangBefore = await readUiLang();
  const clicked = await clickUiLang();
  let rebootedJa = false;
  if (clicked) {
    rebootedJa = await h.waitBooted(20000)
      && await waitForTrue(h.evaluate, "(() => { const e = document.querySelector('#sxc1-progress'); try { return JSON.parse(e ? e.textContent : 'null').uiLang === 'ja'; } catch (err) { return false; } })()", 8000);
  }
  report(
    UILANG_SWITCH_ASSERTION_NAME,
    labelBefore === UI_TEXT.en.uiLangButton && uiLangBefore === 'en' && clicked && rebootedJa === true,
    { labelBefore, uiLangBefore, clicked, rebootedJa },
  );

  // -- 2. Header renders Japanese; the document's own lang tag follows.
  await h.goto('#/', '#sxc1-progress-tools');
  const headerJa = await h.evaluate(`(() => {
    const btn = document.querySelector('#btn-ui-lang');
    const badge = document.querySelector('#sxc1-review-badge');
    return {
      btnLabel: btn ? btn.textContent : null,
      badgeText: badge ? badge.textContent : null,
      docLang: document.documentElement.lang,
    };
  })()`);
  report(
    UILANG_HEADER_ASSERTION_NAME,
    Boolean(headerJa)
      && headerJa.btnLabel === UI_TEXT.ja.uiLangButton
      && typeof headerJa.badgeText === 'string' && headerJa.badgeText.startsWith(UI_TEXT.ja.reviewBadgePrefix)
      && headerJa.docLang === 'ja',
    { headerJa, wantBtn: UI_TEXT.ja.uiLangButton, wantBadgePrefix: UI_TEXT.ja.reviewBadgePrefix },
  );

  // -- 3. The pref really survives on disk: the dedicated boot hint AND
  // the prefs blob's own uiLang line (read raw -- house standard 4's
  // independent re-derivation of the wire format, never the app's own
  // decoder).
  const hintJa = await readLocalStorageRaw(h.evaluate, 'sxc1.uilang');
  const prefsRawJa = await readLocalStorageRaw(h.evaluate, PREFS_KEY);
  report(
    UILANG_PREF_ASSERTION_NAME,
    hintJa === 'ja' && /(^|\n)P\tuiLang\tja(\n|$)/.test(prefsRawJa || ''),
    { hintJa, prefsRawJa },
  );

  // -- 4. Ruling 4's guard, positive half: runProgressAssertionsPost's
  // final step explicitly chose jaFirst=off (and PJaFirst records
  // jaFirstSet), so this ja switch must NOT have flipped it.
  report(
    UILANG_JAFIRST_RESPECT_ASSERTION_NAME,
    /(^|\n)P\tjaFirst\t0(\n|$)/.test(prefsRawJa || '') && /(^|\n)P\tjaFirstSet\t1(\n|$)/.test(prefsRawJa || ''),
    { prefsRawJa },
  );

  // -- 5. The reload really fetched the OTHER bundle (real run only:
  // the file:// fixture fetches no bundle at all).
  if (cfg && cfg.checkBundleFetch) {
    const fetched = await h.evaluate(`(() => {
      const names = performance.getEntriesByType('resource').map((e) => e.name);
      return {
        ja: names.some((n) => n.indexOf('content/content.ja.txt') !== -1),
        en: names.some((n) => n.indexOf('content/content.en.txt') !== -1),
      };
    })()`);
    report(UILANG_BUNDLE_ASSERTION_NAME, Boolean(fetched) && fetched.ja === true && fetched.en === false, fetched);
  }

  // -- 6. THE JA PASS: the same exercise/a11y assertion code, lang='ja'
  // -- every learner-visible text pin now pins the JA string.
  // expectedExerciseJson is deliberately null: #sxc1-exercise-stats
  // derives from the FETCHED (ja) bundle, whose per-deck chars/fnv1a
  // lawfully diverge from the EN disk derivation once W3 fills the ja:
  // fields -- the stats identity is the EN pass's claim.
  const jaResults = await runExerciseAssertions(h, fixture, null, coldLoadFn, 'ja');
  results.push(...jaResults);

  // -- 6b (M6 W4). THE JA COURSE: real corpus text, from the bundle the
  // site ships, all the way through completing a quiz in Japanese. Real
  // run only -- the file:// self-test fixture has no corpus and no
  // bundle at all, so its caller passes no `jaCorpus` (documented here,
  // never a silent skip: without pins there is nothing to compare, and
  // the assertions would be vacuous rather than absent). See
  // JA_COURSE_PINS for why every expectation is a literal.
  if (cfg && cfg.jaCorpus) {
    const P = cfg.jaCorpus;

    // (a) The bundle really is the JA course: totals + a JA deck title
    // read straight out of #sxc1-exercise-stats, which the app computes
    // from the bundle it FETCHED at boot.
    await h.goto('#/x', '#sxc1-exercise-index');
    const statsJa = await h.evaluate(`(() => {
      const e = document.querySelector('#sxc1-exercise-stats');
      try { return JSON.parse(e ? e.textContent : 'null'); } catch (err) { return null; }
    })()`);
    const pinnedDeckStats = statsJa && Array.isArray(statsJa.decks)
      ? statsJa.decks.find((d) => d && d.deck === P.deck.slug) || null
      : null;
    report(
      JA_COURSE_BUNDLE_ASSERTION_NAME,
      Boolean(statsJa && statsJa.totals)
        && statsJa.totals.decks === P.totals.decks
        && statsJa.totals.exercises === P.totals.exercises
        && Boolean(pinnedDeckStats)
        && pinnedDeckStats.title === P.deck.titleJa,
      { totals: statsJa && statsJa.totals, pinnedDeckStats, want: { totals: P.totals, title: P.deck.titleJa } },
    );

    // (b) The learner's way in: the deck card on #/x, then the deck page.
    const deckCard = await h.evaluate(`(() => {
      const a = Array.from(document.querySelectorAll('a.ex-deck-card'))
        .find((el) => (el.getAttribute('href') || '').indexOf(${JSON.stringify(P.deck.route)}) !== -1);
      return a ? a.textContent : null;
    })()`);
    await h.goto(P.deck.route, '#sxc1-deck');
    const deckPageJa = await h.evaluate(`(() => ({
      title: (document.querySelector('#ex-deck-title') || {}).textContent || null,
      summary: (document.querySelector('#ex-deck-summary') || {}).textContent || null,
    }))()`);
    report(
      JA_COURSE_INDEX_ASSERTION_NAME,
      typeof deckCard === 'string' && deckCard.indexOf(P.deck.titleJa) !== -1
        && Boolean(deckPageJa)
        && deckPageJa.title === P.deck.titleJa
        && typeof deckPageJa.summary === 'string' && deckPageJa.summary.indexOf(P.deck.summaryJa) !== -1,
      { deckCard, deckPageJa, want: { title: P.deck.titleJa, summary: P.deck.summaryJa } },
    );

    // (c) The quiz screen itself: title, question, and BOTH pinned
    // option labels (an EN-fallback bundle renders English here).
    // NOTE the ready selectors: '#ex-title' / '#ex-step-1-check', NOT
    // '.kind-quiz' / '.kind-drill'. A DECK page already carries a
    // .kind-<kind> span per exercise link (View.Exercise.renderExLink),
    // so navigating deck-page -> runner with a .kind-* ready selector
    // returns true against the page we are LEAVING and reads the next
    // element before the runner has rendered. Measured: that raced
    // green on the root stage and red on the (slower) sub-path stage.
    await h.goto(P.quiz.route, '#ex-title');
    const quizJa = await h.evaluate(`(() => ({
      title: (document.querySelector('#ex-title') || {}).textContent || null,
      stem: (document.querySelector('#ex-stem') || {}).textContent || null,
      options: Array.from(document.querySelectorAll('.ex-option')).map((b) => b.textContent.trim()),
    }))()`);
    const optionsJa = quizJa && Array.isArray(quizJa.options) ? quizJa.options : [];
    report(
      JA_COURSE_QUIZ_RENDER_ASSERTION_NAME,
      Boolean(quizJa)
        && quizJa.title === P.quiz.titleJa
        && typeof quizJa.stem === 'string' && quizJa.stem.indexOf(P.quiz.stemJa) !== -1
        && optionsJa.indexOf(P.quiz.correctOptJa) !== -1
        && optionsJa.indexOf(P.quiz.wrongOptJa) !== -1,
      { quizJa, want: { title: P.quiz.titleJa, stem: P.quiz.stemJa, correct: P.quiz.correctOptJa, wrong: P.quiz.wrongOptJa } },
    );

    // (d) COMPLETE it in Japanese: the option is located BY ITS JAPANESE
    // LABEL (so a fallback bundle cannot even find something to click),
    // graded by the real engine, and both the feedback and the rationale
    // must come back Japanese.
    const clickedJaOption = await h.evaluate(`(() => {
      const b = Array.from(document.querySelectorAll('.ex-option'))
        .find((el) => el.textContent.trim() === ${JSON.stringify(P.quiz.correctOptJa)});
      if (!b) return false;
      b.click();
      return true;
    })()`);
    const submittedJa = clickedJaOption
      ? await h.evaluate("(() => { const e = document.querySelector('#btn-ex-submit'); if (!e) return false; e.click(); return true; })()")
      : false;
    const gradedJa = submittedJa
      ? await h.evaluate(`(async () => {
          const start = Date.now();
          while (Date.now() - start < 5000) {
            const fb = document.querySelector('#ex-feedback');
            if (fb && fb.textContent.indexOf(${JSON.stringify(UI_TEXT.ja.correctPrefix)}) === 0) break;
            await new Promise((r) => setTimeout(r, 20));
          }
          const fb = document.querySelector('#ex-feedback');
          const note = document.querySelector('#ex-note');
          return {
            feedback: fb ? fb.textContent : null,
            feedbackClass: fb ? fb.className : null,
            note: note ? note.textContent : null,
          };
        })()`)
      : null;
    report(
      JA_COURSE_QUIZ_COMPLETE_ASSERTION_NAME,
      clickedJaOption === true && submittedJa === true && Boolean(gradedJa)
        && typeof gradedJa.feedback === 'string'
        && gradedJa.feedback.indexOf(UI_TEXT.ja.correctPrefix) === 0
        && gradedJa.feedbackClass === 'correct'
        && typeof gradedJa.note === 'string'
        && gradedJa.note.indexOf(P.quiz.noteJa) !== -1,
      { clickedJaOption, submittedJa, gradedJa, wantFeedbackPrefix: UI_TEXT.ja.correctPrefix, wantNote: P.quiz.noteJa },
    );

    // (e) A drill step's check: sentence -- the field kind the ja:
    // grammar treats as a FIELD variant rather than prose, so it is a
    // genuinely different path through the emitter than (c)/(d).
    await h.goto(P.drill.route, '#ex-step-1-check');
    const drillCheckJa = await h.evaluate("(() => { const e = document.querySelector('#ex-step-1-check'); return e ? e.textContent : null; })()");
    report(
      JA_COURSE_DRILL_ASSERTION_NAME,
      typeof drillCheckJa === 'string' && drillCheckJa.indexOf(P.drill.step1CheckJa) !== -1,
      { drillCheckJa, want: P.drill.step1CheckJa },
    );
  }

  // -- 6c (M7 W3). THE JA MANUALS: real Japanese manual TEXT from the
  // bundle the site ships, on real reading routes, with the original
  // page scan still beside it. Real run only, for the same reason 6b is
  // (the file:// self-test fixture fetches no bundle at all), and
  // documented here rather than silently skipped. See JA_MANUAL_PINS.
  if (cfg && cfg.jaManuals) {
    const M = cfg.jaManuals;

    // (a) A real reading route in the reader's own language.
    // EVERY manual hop goes via home first, and waits on a selector the
    // page being LEFT does not carry: goto() resolves the moment its
    // ready selector exists, so hopping page-route -> page-route on
    // '#sxc1-page .page-body' reads the page we are leaving (the same
    // race JA_COURSE_PINS' (c) documents, measured green on the fast
    // stage and red on the slow one).
    await h.goto('#/', '#sxc1-home');
    await h.goto(M.page.route, M.page.readySelector);
    const manualJa = await h.evaluate(`(() => {
      const body = document.querySelector('#sxc1-page .page-body');
      const t = body && body.textContent ? body.textContent : '';
      return {
        chars: t.trim().length,
        heading: t.indexOf(${JSON.stringify(M.page.headingJa)}) !== -1,
        sentence: t.indexOf(${JSON.stringify(M.page.bodyJa)}) !== -1,
        bodyLang: body ? body.getAttribute('lang') : null,
        note: document.querySelector('#sxc1-manual-fallback') !== null,
        docLang: document.documentElement.lang,
      };
    })()`);
    report(
      JA_MANUAL_PAGE_ASSERTION_NAME,
      Boolean(manualJa) && manualJa.heading === true && manualJa.sentence === true
        && manualJa.bodyLang === null && manualJa.note === false
        && manualJa.docLang === 'ja' && manualJa.chars > 100,
      { manualJa, want: { heading: M.page.headingJa, sentence: M.page.bodyJa } },
    );

    // (b) A second document, from a different transcription batch.
    await h.goto('#/', '#sxc1-home');
    await h.goto(M.midi.route, M.midi.readySelector);
    const midiJa = await h.evaluate(`(() => {
      const body = document.querySelector('#sxc1-page .page-body');
      const t = body && body.textContent ? body.textContent : '';
      return {
        sentence: t.indexOf(${JSON.stringify(M.midi.bodyJa)}) !== -1,
        deviceLabel: t.indexOf(${JSON.stringify(M.midi.deviceLabel)}) !== -1,
        bodyLang: body ? body.getAttribute('lang') : null,
        note: document.querySelector('#sxc1-manual-fallback') !== null,
      };
    })()`);
    report(
      JA_MANUAL_SECOND_DOC_ASSERTION_NAME,
      Boolean(midiJa) && midiJa.sentence === true && midiJa.deviceLabel === true
        && midiJa.bodyLang === null && midiJa.note === false,
      { midiJa, want: { sentence: M.midi.bodyJa, deviceLabel: M.midi.deviceLabel } },
    );

    // (c) The /ja route: ruling 4 keeps the ORIGINAL page image exactly
    // as it was -- the body being Japanese now must not have cost the
    // scan. Reachability is a real same-origin fetch of the img's own
    // resolved src (loading="lazy" makes naturalWidth an unreliable
    // proxy for a panel below the fold).
    await h.goto('#/', '#sxc1-home');
    await h.goto(M.page.jaRoute, '#ja-image');
    const jaPanel = await h.evaluate(`(async () => {
      const img = document.querySelector('#ja-image');
      const body = document.querySelector('#sxc1-page .page-body');
      const t = body && body.textContent ? body.textContent : '';
      const src = img ? img.src : null;
      let status = null;
      let bytes = 0;
      if (src) {
        try {
          const r = await fetch(src, { cache: 'no-store' });
          status = r.status;
          const b = await r.blob();
          bytes = b.size;
        } catch (e) { status = String(e && e.message ? e.message : e); }
      }
      return {
        src,
        panel: document.querySelector('#ja-panel') !== null,
        status,
        bytes,
        sentence: t.indexOf(${JSON.stringify(M.page.bodyJa)}) !== -1,
      };
    })()`);
    report(
      JA_MANUAL_IMAGE_ASSERTION_NAME,
      Boolean(jaPanel) && jaPanel.panel === true
        && typeof jaPanel.src === 'string'
        && jaPanel.src.indexOf(M.page.imageSuffix) !== -1
        && jaPanel.status === 200 && jaPanel.bytes > 1000
        && jaPanel.sentence === true,
      { jaPanel, want: M.page.imageSuffix },
    );

    // (d) The outline the learner navigates by.
    await h.goto('#/', '#sxc1-home');
    await h.goto(M.toc.route, '#sxc1-toc');
    const tocJa = await h.evaluate(`(() => {
      const links = Array.from(document.querySelectorAll('#sxc1-toc a')).map((a) => a.textContent.trim());
      return {
        hasSection: links.indexOf(${JSON.stringify(M.toc.sectionJa)}) !== -1,
        links: links.length,
        notes: document.querySelectorAll('#sxc1-toc .manual-fallback-note').length,
      };
    })()`);
    report(
      JA_MANUAL_TOC_ASSERTION_NAME,
      Boolean(tocJa) && tocJa.hasSection === true && tocJa.notes === 0 && tocJa.links > 10,
      { tocJa, want: M.toc.sectionJa },
    );
  }

  // -- 7. The verify line's learner-visible device sentence, in JA, in
  // its aria-live region (a11y parity for the no-fake idle state; the
  // waiting/confirmed sentences are pinned against the real wasm by
  // --check-ja-toggle's device flow).
  if (fixture.drill.hasVerify) {
    await h.goto(`#/x/${fixture.drill.deck}/${fixture.drill.id}`, '.kind-drill');
    const verifyJa = await h.evaluate("(() => { const e = document.querySelector('.ex-verify'); return e ? { text: e.textContent, live: e.getAttribute('aria-live') } : null; })()");
    report(
      UILANG_VERIFY_JA_ASSERTION_NAME,
      Boolean(verifyJa) && verifyJa.text === UI_TEXT.ja.verifyIdleOff && verifyJa.live === 'polite',
      { verifyJa, want: UI_TEXT.ja.verifyIdleOff },
    );
  }

  // -- 8. ROUNDTRIP: back to EN, so every assertion after this flow
  // still runs under the language it pins. (The boot hint's restoration
  // is UILANG_PREF's own concern on the ja side; deliberately not
  // re-checked here so a hint-only sabotage fails exactly one name.)
  await h.goto('#/', '#sxc1-progress-tools');
  const clickedBack = await clickUiLang();
  let rebootedEn = false;
  if (clickedBack) {
    rebootedEn = await h.waitBooted(20000)
      && await waitForTrue(h.evaluate, "(() => { const e = document.querySelector('#sxc1-progress'); try { return JSON.parse(e ? e.textContent : 'null').uiLang === 'en'; } catch (err) { return false; } })()", 8000);
  }
  await h.goto('#/', '#sxc1-progress-tools');
  const labelAfterBack = await btnLabel();
  report(
    UILANG_ROUNDTRIP_ASSERTION_NAME,
    clickedBack && rebootedEn === true && labelAfterBack === UI_TEXT.en.uiLangButton,
    { clickedBack, rebootedEn, labelAfterBack },
  );

  return results;
}

// ---------------------------------------------------------------------------
// M3 harness wave: PERSISTENCE / JA-FIRST / CORRUPT-BLOB / REVIEW-QUEUE
// assertions -- this task's own manifest item C, the milestone's contract
// requirement. Shared between --self-test (driven against
// progressSelfTestFixtureHtml()'s synthetic, in-page mock of the M3
// progress DOM contract) and a real run (driven against the real app's
// real localStorage-backed SXC1.Progress.* system) by the SAME function,
// exactly the way runExerciseAssertions() above is shared between the
// quiz/drill/lookup self-test and the real exercise engine -- "the same
// assertion code runs against it" (M2's own precedent, restated in this
// task's own manifest prompt).
//
// WHY THE SELF-TEST FIXTURE REUSES THE EXISTING QUIZ UI RATHER THAN
// SIMULATING A SECOND ONE: SELF_TEST_FIXTURE's quiz (FIXTURE.quiz)
// already exercises the grading UI end to end (see runExerciseAssertions
// above); this section's job is the STORAGE/PERSISTENCE layer
// underneath it, not re-testing quiz grading a second time.
// progressSelfTestFixtureHtml() hooks the SAME quiz submit handler to
// ALSO update a small, self-contained, DELIBERATELY INDEPENDENT JS mirror
// of SXC1.Progress.* (a mini scheduler + mini codec, documented at its
// own definition) that reads/writes the SAME wire format
// SXC1.Progress.Codec.hs documents to the SAME localStorage keys
// (sxc1.progress / sxc1.prefs) -- independent of the real Haskell
// implementation for exactly the reason SELF_TEST_FIXTURE's own Haddock
// gives: "--self-test proves the BROWSER ASSERTIONS themselves can fail
// ... never that the real app matches it".
//
// Both call sites share ONE route grammar (so no fixture-vs-real
// indirection is needed anywhere below): quiz "#/x/<deck>/<id>", a deck
// page "#/x/<deck>" (with a .deck-card[data-tier] on it), home "#/" with
// #sxc1-progress-tools as its ready marker (only rendered on Home --
// see View.Progress.exportImportEls), and a manual page
// "#/m/<slug>/p/<n>" / ".../ja" with "#page-<n>" as its ready marker.
// ---------------------------------------------------------------------------

const PROGRESS_KEY = 'sxc1.progress';
const PREFS_KEY = 'sxc1.prefs';

// House standard 4 ("a check that counts must count independently"):
// these two re-derive just enough of SXC1.Progress.Codec's documented
// wire format --
//   R <TAB> promptId <TAB> reps <TAB> lapses <TAB> ease <TAB> interval <TAB> due <TAB> lastSeen <TAB> seen
// -- to check specific field VALUES, entirely in Node, from a raw string
// already read back out of localStorage via evaluate(). This never asks
// the app (or the self-test fixture's own mini-codec) to interpret
// itself; it is a second, independent implementation in a different
// language, exactly like scripts/recount-citations.py is for the M2
// citation count.
function findWireRecord(rawBlob, promptId) {
  if (!rawBlob) return null;
  for (const line of rawBlob.split('\n')) {
    const f = line.split('\t');
    if (f[0] === 'R' && f.length === 9 && f[1] === promptId) {
      return {
        promptId: f[1], reps: Number(f[2]), lapses: Number(f[3]), ease: Number(f[4]),
        interval: Number(f[5]), due: Number(f[6]), lastSeen: Number(f[7]), seen: Number(f[8]),
      };
    }
  }
  return null;
}

function countWireRecords(rawBlob) {
  if (!rawBlob) return 0;
  return rawBlob.split('\n').filter((l) => l.startsWith('R\t')).length;
}

// A deck's declared `tier:` field, read straight off
// content/exercises/*.ex.md on DISK -- never from the running app --
// for assertion "deckCardTierMatches" below (house standard 4 again).
const HARNESS_REPO_ROOT = path.dirname(path.dirname(new URL(import.meta.url).pathname));
function deckTierFromDisk(deckSlug) {
  const dir = path.join(HARNESS_REPO_ROOT, 'content', 'exercises');
  let files;
  try { files = fs.readdirSync(dir); } catch { return null; }
  for (const fn of files) {
    if (!fn.endsWith('.ex.md')) continue;
    let raw;
    try { raw = fs.readFileSync(path.join(dir, fn), 'utf8'); } catch { continue; }
    const dm = raw.match(/^deck:[ \t]*(\S+)[ \t]*$/m);
    if (!dm || dm[1] !== deckSlug) continue;
    const tm = raw.match(/^tier:[ \t]*(\S+)[ \t]*$/m);
    return tm ? tm[1] : null;
  }
  return null;
}

async function readSxc1Progress(evaluate) {
  const raw = await evaluate(`(() => {
    const e = document.querySelector('#sxc1-progress');
    return e ? e.textContent : null;
  })()`);
  try { return JSON.parse(raw); } catch { return null; }
}

async function readLocalStorageRaw(evaluate, key) {
  return evaluate(`(() => { try { return window.localStorage.getItem(${JSON.stringify(key)}); } catch (e) { return null; } })()`);
}

// Poll #sxc1-progress until `predicateSrc` (a JS expression string over a
// local `p`, the parsed payload) is true, with an explicit budget --
// house standard 3, and specifically the fix for the SAME class of race
// the #sxc1-prompt-baseline fix above closes: a click that dispatches a
// real Miso action (wipe-confirm, import-submit, ...) returns before
// that action's render has necessarily flushed to the DOM, so reading
// #sxc1-progress exactly once immediately afterward can observe the
// PREVIOUS frame's payload. Every read of #sxc1-progress in
// runProgressAssertionsPost that follows such a click goes through this
// (or an equivalent explicit poll), never a bare readSxc1Progress().
async function waitForProgressPredicate(evaluate, predicateSrc, budgetMs) {
  return waitForTrue(evaluate, `(() => {
    const e = document.querySelector('#sxc1-progress');
    let p = null;
    try { p = JSON.parse(e ? e.textContent : 'null'); } catch (err) { return false; }
    if (!p) return false;
    return Boolean(${predicateSrc});
  })()`, budgetMs);
}

// Poll to a settled TRUE condition with an explicit budget (house
// standard 3) -- `exprJs` is a JS expression string evaluated in-page;
// must resolve to a boolean (or falsy/truthy) value each poll.
async function waitForTrue(evaluate, exprJs, budgetMs, intervalMs = 30) {
  const start = Date.now();
  let last = false;
  while (Date.now() - start < budgetMs) {
    last = await evaluate(exprJs);
    if (last) return true;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return Boolean(last);
}

// The inverse shape, for "hides AND STAYS hidden" (assertion
// jaToggleHidesAndSticks below): confirms `exprJs` is false for the
// WHOLE budget, returning false (the check FAILS) the instant it flips
// true. This is the falsifiable form of "never comes back" -- a single
// sample right after the click would pass even if a stray re-render
// brought the panel straight back a few milliseconds later.
async function staysFalseThroughout(evaluate, exprJs, budgetMs, intervalMs = 50) {
  const start = Date.now();
  while (Date.now() - start < budgetMs) {
    if (await evaluate(exprJs)) return false;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return true;
}

const PROGRESS_ASSERTION_NAMES = {
  freshRecords: 'fresh profile: #sxc1-progress reports records=0, state=empty before any answer',
  freshJaFirst: 'fresh profile: #sxc1-progress reports jaFirst=false and a manual page does not auto-redirect to /ja',
  wipeEmpties: 'export -> wipe -> import: the store is genuinely empty (records=0, state=empty) between wipe and import',
  answerReloadCount: 'answer -> reload: #sxc1-progress records count equals the number of graded prompts (1)',
  answerReloadInterval: "answer -> reload: the graded PromptId's stored interval equals the scheduler's fresh GEasy value (2 days)",
  importPreview: '#sxc1-import-preview shows the correct record count before commit',
  exportWipeImportRestores: 'export -> wipe -> import: restores the same record identity and values as before the wipe',
  corruptBanner: 'hand-corrupted sxc1.progress: #sxc1-corrupt-banner appears with the raw text in #sxc1-corrupt-raw',
  corruptNeverOverwritten: 'hand-corrupted sxc1.progress: the stored key is present and byte-identical after a reload and after answering another question',
  jaFirstPersistsValue: 'JA-first: set -> reload -> sxc1.prefs still stores jaFirst=1 and the manual page auto-shows the JA panel',
  jaFirstPersistsOrder: 'JA-first: set -> reload -> the original-page panel renders before the translated body',
  jaFirstSurvivesWipe: 'JA-first: wiping progress does not clear the reading preference',
  jaToggleHidesAndSticks: 'JA-first ON: an explicit #btn-ja-toggle click hides the panel, and it stays hidden until the learner navigates to a different page',
  // NEW11: strengthened from a post-wipe-only, due=0 comparison (a
  // hardcoded-zero badge/empty queue passed vacuously) to a real
  // due>=1 record established by an incorrect answer FIRST, checked
  // before any wipe, then a real due>=1 -> due=0 transition after one.
  reviewBadgeMatchesDue: "review-queue badge/#sxc1-progress payload/#sxc1-review-queue agree on a REAL due>=1 record (badge text equals payload.due, a .queue-item links to the exercise), then all three genuinely return to zero/empty after a wipe",
  deckCardTierMatches: "a deck card's data-tier matches the deck's declared tier: field (content/exercises, independently re-read)",
  // NEW14 (M3 re-gate): order-discriminating by construction -- the
  // lookup (l-*) is graded FIRST and the quiz (q-*) SECOND, so the old
  // lexicographic Map-scan Continue implementation (which would pick
  // l-* on the same-day tie) fails this while the psLastPrompt pointer
  // passes: the assertion is red against the pre-fix code by design.
  continueMatchesLast: "#sxc1-continue links the LAST-graded exercise (lookup graded first, quiz re-graded second -> continue must point at the quiz, not the lexicographically-first lookup)",
  // c3, DELIBERATELY NOT part of runProgressAssertionsPre/Post or the
  // --self-test-negative sweep -- see --check-storage-refused's own
  // --help text and this task's final report. Kept here only so its
  // name is defined in exactly one place.
  storageRefusedAvailableFalse: 'storage refused: the app still boots and #sxc1-progress reports available=false (never crashes)',
};

// PRE: must run BEFORE anything else (M2's own exercise assertions
// included) ever touches localStorage -- c2 and d1's "fresh profile"
// claims would be vacuous otherwise (a fresh temp --user-data-dir per
// run, see runSelfTest/main below, is what makes "fresh profile" true at
// the point this is called).
async function runProgressAssertionsPre(h, cfg) {
  const payload0 = await readSxc1Progress(h.evaluate);
  h.report(
    PROGRESS_ASSERTION_NAMES.freshRecords,
    Boolean(payload0 && payload0.records === 0 && payload0.state === 'empty'),
    payload0,
  );

  await h.goto(`#/m/${cfg.manualSlug}/p/${cfg.manualPage}`, `#page-${cfg.manualPage}`);
  const hashAfter = await h.evaluate('window.location.hash');
  const noAutoJa = typeof hashAfter === 'string' && !hashAfter.endsWith('/ja');
  h.report(
    PROGRESS_ASSERTION_NAMES.freshJaFirst,
    Boolean(payload0 && payload0.jaFirst === false) && noAutoJa,
    { payload0, hashAfter },
  );
}

// POST: everything else. Run once M2's own exercise assertions have
// already exercised quiz/drill/lookup on this same session (that history
// is DELIBERATELY not relied on here -- every measurement below starts
// from an explicit wipe + reload, which resets both the persisted
// ProgressState (via the wipe) and the in-memory per-exercise engine
// state (mExStates -- a wipe does not touch it, a fresh page load
// always starts it at Map.empty, see Main.hs's readerApp/model0), so
// "first-try correct" really is first-try no matter what earlier
// assertions already did to the SAME quiz exercise.
async function runProgressAssertionsPost(h, cfg) {
  const promptId = `${cfg.quizId}#1`;

  // -- Home, wipe -- a clean-slate SETUP step (the FORMAL "genuinely
  // empty in between" assertion, B's own pre-condition, is checked
  // against the SECOND wipe below, the one between export and import --
  // this first wipe only exists so assertion A starts from nothing).
  // Polls to the settled post-wipe state rather than reading once
  // immediately after the confirm click, which dispatches a real Miso
  // action (phWipe) whose render is not necessarily flushed the instant
  // the click handler returns -- see waitForProgressPredicate's own
  // comment. -----------------------------------------------------------
  await h.goto('#/', '#sxc1-progress-tools');
  await h.clickAssert('#btn-progress-wipe', 'M3: click #btn-progress-wipe');
  await h.clickAssert('#btn-progress-wipe-confirm', 'M3: click #btn-progress-wipe-confirm');
  await waitForProgressPredicate(h.evaluate, "p.records === 0 && p.state === 'empty'", 3000);

  // -- A full RELOAD here resets mExStates to Map.empty (a fresh Haskell
  // Model), so the quiz below really is a first-ever interaction with
  // this ExId in THIS Model instance, on top of the just-wiped (empty)
  // ProgressState. ---------------------------------------------------
  await h.reload('#sxc1-progress-tools');

  // -- A: answer a fresh quiz correct on the first try, then RELOAD, then
  // assert on IDENTITY AND VALUE (house standard 2) -- never "the key is
  // non-empty". -------------------------------------------------------
  await h.goto(`#/x/${cfg.quizDeck}/${cfg.quizId}`, `#${cfg.quizCorrectOpt}`);
  await h.clickAssert(`#${cfg.quizCorrectOpt}`, 'M3: click the correct quiz option (first try, clean)');
  await h.clickAssert('#btn-ex-submit', 'M3: submit the first-try correct answer');
  await waitForTrue(h.evaluate, "document.querySelector('#ex-feedback') !== null && /^Correct/.test(document.querySelector('#ex-feedback').textContent)", 5000);
  await h.reload(`#${cfg.quizCorrectOpt}`);

  const payloadA = await readSxc1Progress(h.evaluate);
  const rawA = await readLocalStorageRaw(h.evaluate, PROGRESS_KEY);
  const recA = findWireRecord(rawA, promptId);
  h.report(
    PROGRESS_ASSERTION_NAMES.answerReloadCount,
    Boolean(payloadA && payloadA.records === 1) && countWireRecords(rawA) === 1,
    { payload: payloadA, wireRecordCount: countWireRecords(rawA) },
  );
  h.report(
    PROGRESS_ASSERTION_NAMES.answerReloadInterval,
    Boolean(recA && recA.reps === 1 && recA.interval === 2),
    recA,
  );

  // -- B: export -> wipe (empty in between) -> import -> survives, plus
  // the import-preview count. ------------------------------------------
  await h.goto('#/', '#sxc1-progress-tools');
  await h.clickAssert('#btn-progress-export', 'M3: click #btn-progress-export');
  await waitForTrue(h.evaluate, "(document.querySelector('#sxc1-export-blob') || {}).value && document.querySelector('#sxc1-export-blob').value.length > 0", 3000);
  const exportedBlob = await h.evaluate("(document.querySelector('#sxc1-export-blob') || {}).value || ''");

  await h.clickAssert('#btn-progress-wipe', 'M3: click #btn-progress-wipe (before import)');
  await h.clickAssert('#btn-progress-wipe-confirm', 'M3: click #btn-progress-wipe-confirm (before import)');
  // THE formal "genuinely empty in between" assertion (house standard 3:
  // poll to settled, never sample once against a Miso action that may
  // not have flushed yet).
  await waitForProgressPredicate(h.evaluate, "p.records === 0 && p.state === 'empty'", 3000);
  const emptiedForImport = await readSxc1Progress(h.evaluate);
  h.report(
    PROGRESS_ASSERTION_NAMES.wipeEmpties,
    Boolean(emptiedForImport && emptiedForImport.records === 0 && emptiedForImport.state === 'empty'),
    emptiedForImport,
  );

  await h.typeText('#sxc1-import-input', exportedBlob);
  // The placeholder text ("Paste text above to see how many records it
  // contains.") is itself non-empty, so waiting for "non-empty" would be
  // vacuous (house standard 2) -- poll for the SPECIFIC expected string
  // instead. There is exactly one graded prompt at this point (the fresh
  // quiz answer from assertion A, just exported), so the real app's own
  // index.js (countPastedRecords) must render exactly "1 record found in
  // the pasted text." -- singular, exact wording -- never merely
  // "contains the word record" or "contains a digit".
  const previewSettled = await waitForTrue(
    h.evaluate,
    "(() => { const e = document.querySelector('#sxc1-import-preview'); return Boolean(e && e.textContent === '1 record found in the pasted text.'); })()",
    3000,
  );
  const previewText = await h.evaluate("(() => { const e = document.querySelector('#sxc1-import-preview'); return e ? e.textContent : null; })()");
  h.report(
    PROGRESS_ASSERTION_NAMES.importPreview,
    previewSettled === true && previewText === '1 record found in the pasted text.',
    { previewText, emptiedForImport },
  );
  await h.clickAssert('#btn-progress-import', 'M3: click #btn-progress-import (submit)');
  await waitForTrue(h.evaluate, "(() => { const e = document.querySelector('#sxc1-progress'); if (!e) return false; try { return JSON.parse(e.textContent).records === 1; } catch (err) { return false; } })()", 3000);

  const payloadB = await readSxc1Progress(h.evaluate);
  const rawB = await readLocalStorageRaw(h.evaluate, PROGRESS_KEY);
  const recB = findWireRecord(rawB, promptId);
  h.report(
    PROGRESS_ASSERTION_NAMES.exportWipeImportRestores,
    Boolean(payloadB && payloadB.records === 1)
      && Boolean(recB && recB.reps === recA.reps && recB.interval === recA.interval && recB.due === recA.due),
    { payload: payloadB, restored: recB, original: recA },
  );

  // -- C: a hand-corrupted blob -> corrupt banner, never overwritten. --
  const CORRUPT_TEXT = 'GARBAGE-NOT-A-VALID-SXC1-BLOB-' + Date.now();
  await h.evaluate(`(() => { window.localStorage.setItem(${JSON.stringify(PROGRESS_KEY)}, ${JSON.stringify(CORRUPT_TEXT)}); return true; })()`);
  await h.reload('#sxc1-progress-tools');
  const bannerShown = await h.evaluate("document.querySelector('#sxc1-corrupt-banner') !== null");
  const rawText = await h.evaluate("(() => { const e = document.querySelector('#sxc1-corrupt-raw'); return e ? (e.value !== undefined ? e.value : e.textContent) : null; })()");
  h.report(
    PROGRESS_ASSERTION_NAMES.corruptBanner,
    bannerShown === true && rawText === CORRUPT_TEXT,
    { bannerShown, rawText },
  );

  // Answer "another question" while corrupt, then reload again -- the
  // never-overwrite rule under test. The corrupt banner is Home-only
  // (progressHomeView/renderHome), so "reload" alone is not enough to
  // observe it -- reload preserves whatever route we were last on (the
  // quiz), so an explicit return to Home is what actually lets the
  // banner (or its absence) be read back.
  await h.goto(`#/x/${cfg.quizDeck}/${cfg.quizId}`, `#${cfg.quizCorrectOpt}`);
  await h.clickAssert(`#${cfg.quizCorrectOpt}`, 'M3: click the correct quiz option (while progress is corrupt)');
  await h.clickAssert('#btn-ex-submit', 'M3: submit an answer while progress is corrupt');
  await waitForTrue(h.evaluate, "document.querySelector('#ex-feedback') !== null && /^Correct/.test(document.querySelector('#ex-feedback').textContent)", 5000);
  await h.reload(`#${cfg.quizCorrectOpt}`);
  await h.goto('#/', '#sxc1-progress-tools');
  const rawAfterAnswer = await readLocalStorageRaw(h.evaluate, PROGRESS_KEY);
  const bannerStillShown = await h.evaluate("document.querySelector('#sxc1-corrupt-banner') !== null");
  h.report(
    PROGRESS_ASSERTION_NAMES.corruptNeverOverwritten,
    rawAfterAnswer === CORRUPT_TEXT && bannerStillShown === true,
    { rawAfterAnswer, bannerStillShown },
  );

  // Explicit wipe clears the corrupt state back to writable/empty before
  // the JA-first section below (which needs a writable progress key for
  // its own wipe-based d2 negative control) -- an explicit learner wipe
  // is the documented, intentional escape from read-only-corrupt mode.
  await h.goto('#/', '#sxc1-progress-tools');
  await h.clickAssert('#btn-progress-wipe', 'M3: click #btn-progress-wipe (clear corrupt state)');
  await h.clickAssert('#btn-progress-wipe-confirm', 'M3: click #btn-progress-wipe-confirm (clear corrupt state)');

  // -- D: JA-first set -> reload -> survives (value AND order), plus its
  // three required negative controls. ----------------------------------
  await h.goto(`#/m/${cfg.manualSlug}/p/${cfg.manualPage}`, `#page-${cfg.manualPage}`);
  await h.clickAssert('#btn-ja-first', 'M3: click #btn-ja-first');
  // reload()'s own ready-selector (#page-N) is satisfied by BOTH the
  // pre-redirect render (ja=false, mount's own initial SetRoute) and the
  // post-redirect one (ja=true, after the freshPage rule's OWN setHash
  // -> hashchange -> SetRoute round trip) -- the page-body div exists in
  // both, just reordered. So reload() alone can settle on the FIRST of
  // those two frames -- the same class of race the #sxc1-prompt-baseline
  // fix and the wipe-predicate fix above both close. Poll to the
  // SPECIFIC settled condition (hash ends /ja AND #ja-panel exists)
  // before reading anything else, rather than trusting reload()'s
  // generic readiness.
  await h.reload(`#page-${cfg.manualPage}`);
  await waitForTrue(
    h.evaluate,
    "window.location.hash.endsWith('/ja') && document.querySelector('#ja-panel') !== null",
    3000,
  );

  const prefsRaw = await readLocalStorageRaw(h.evaluate, PREFS_KEY);
  const hashAfterReload = await h.evaluate('window.location.hash');
  const jaPanelPresent = await h.evaluate("document.querySelector('#ja-panel') !== null");
  h.report(
    PROGRESS_ASSERTION_NAMES.jaFirstPersistsValue,
    /(^|\n)P\tjaFirst\t1(\n|$)/.test(prefsRaw || '') && hashAfterReload.endsWith('/ja') && jaPanelPresent,
    { prefsRaw, hashAfterReload, jaPanelPresent },
  );

  const domOrder = await h.evaluate(`(() => {
    const panel = document.querySelector('#ja-panel');
    const body = document.querySelector('#page-${cfg.manualPage}');
    if (!panel || !body) return { panel: Boolean(panel), body: Boolean(body) };
    // DOCUMENT_POSITION_FOLLOWING (4): panel precedes body.
    const rel = panel.compareDocumentPosition(body);
    return { panelBeforeBody: Boolean(rel & Node.DOCUMENT_POSITION_FOLLOWING) };
  })()`);
  h.report(PROGRESS_ASSERTION_NAMES.jaFirstPersistsOrder, domOrder && domOrder.panelBeforeBody === true, domOrder);

  // -- D1b: re-establish a genuine, persisted "jaFirst on" baseline
  // before D2/D3 -- deliberately NOT just trusting D1's own click+reload
  // above. D2 ("wiping progress does not clear the reading preference")
  // and D3 ("an explicit toggle hides and sticks") each test their OWN,
  // independent claim about jaFirst-on behavior; neither should inherit
  // a failure that was really D1's (--self-test-negative's own
  // 'jaFirstPersist' selector sabotages exactly D1's read point -- see
  // saveJaFirst's own comment -- and must not thereby also make D2/D3
  // fail on cue). A no-op whenever D1 already succeeded (the ordinary
  // case, and every OTHER selector/real-app run).
  if (!(hashAfterReload.endsWith('/ja') && jaPanelPresent)) {
    await h.goto(`#/m/${cfg.manualSlug}/p/${cfg.manualPage}`, `#page-${cfg.manualPage}`);
    await h.clickAssert('#btn-ja-first', 'M3: click #btn-ja-first (D1b: re-establish before D2/D3)');
    await h.reload(`#page-${cfg.manualPage}`);
    await waitForTrue(
      h.evaluate,
      "window.location.hash.endsWith('/ja') && document.querySelector('#ja-panel') !== null",
      3000,
    );
  }

  await h.goto('#/', '#sxc1-progress-tools');
  await h.clickAssert('#btn-progress-wipe', 'M3: click #btn-progress-wipe (d2: must not clear jaFirst)');
  await h.clickAssert('#btn-progress-wipe-confirm', 'M3: click #btn-progress-wipe-confirm (d2)');
  await waitForProgressPredicate(h.evaluate, "p.state === 'empty'", 3000);
  const payloadAfterWipe2 = await readSxc1Progress(h.evaluate);
  const prefsRawAfterWipe = await readLocalStorageRaw(h.evaluate, PREFS_KEY);
  const jaFirstReallyOnDiskAfterWipe = /(^|\n)P\tjaFirst\t1(\n|$)/.test(prefsRawAfterWipe || '');
  h.report(
    PROGRESS_ASSERTION_NAMES.jaFirstSurvivesWipe,
    Boolean(payloadAfterWipe2 && payloadAfterWipe2.jaFirst === true) && jaFirstReallyOnDiskAfterWipe,
    { payloadAfterWipe2, prefsRawAfterWipe },
  );

  // -- D2b: re-establish jaFirst-on before D3 -- same reasoning as D1b.
  // 'jaFirstSurvivesWipe' deliberately (and correctly) makes THIS wipe
  // also clear sxc1.prefs -- see the wipe-confirm handler's own comment
  // -- so D3 ("an explicit toggle hides and sticks") must not inherit
  // that as a false precondition failure of ITS OWN, unrelated claim.
  // Gated on the REAL on-disk signal (jaFirstReallyOnDiskAfterWipe), not
  // payloadAfterWipe2.jaFirst -- selector 'freshJaFirst' (and
  // legacy-all) fake THAT field unconditionally, which would otherwise
  // make this check think jaFirst is fine when the real preference is
  // not (harmlessly, for 'freshJaFirst', since it never actually breaks
  // the real preference; load-bearing for legacy-all, which must keep
  // D3 failing exactly as LEGACY_EXPECTED_TO_FAIL already lists).
  if (!jaFirstReallyOnDiskAfterWipe) {
    await h.goto(`#/m/${cfg.manualSlug}/p/${cfg.manualPage}`, `#page-${cfg.manualPage}`);
    await h.clickAssert('#btn-ja-first', 'M3: click #btn-ja-first (D2b: re-establish before D3)');
    await h.reload(`#page-${cfg.manualPage}`);
    await waitForTrue(
      h.evaluate,
      "window.location.hash.endsWith('/ja') && document.querySelector('#ja-panel') !== null",
      3000,
    );
    // D3's own navigation below relies on landing on the manual page as
    // a genuinely FRESH page transition (PREV_PAGE===null), which is
    // what lets its auto-redirect-to-/ja fire at all -- ordinarily
    // guaranteed by D2's own "go to Home for the wipe" step just above
    // this whole D2b block. D2b's own navigation to the manual page
    // (right above) clobbers that (PREV_PAGE now points AT the manual
    // page, so D3's identical-page revisit reads as a non-fresh,
    // same-page hashchange and never redirects) -- so re-visit Home
    // here to restore the same "coming from Home" precondition D3
    // already assumes in the ordinary (non-re-established) case.
    await h.goto('#/', '#sxc1-progress-tools');
  }

  // d3: an explicit toggle hides the panel and it STAYS hidden until the
  // learner navigates to a different page (jaFirst must not fight it).
  await h.goto(`#/m/${cfg.manualSlug}/p/${cfg.manualPage}`, `#ja-panel`);
  await h.clickAssert('#btn-ja-toggle', 'M3: click #btn-ja-toggle (d3: explicit hide)');
  const hidNow = await waitForTrue(h.evaluate, "document.querySelector('#ja-panel') === null", 2000);
  const staysHidden = hidNow && await staysFalseThroughout(h.evaluate, "document.querySelector('#ja-panel') !== null", 600);
  let reappearsOnNewPage = false;
  if (staysHidden) {
    await h.goto(`#/m/${cfg.manualSlug}/p/${cfg.manualNextPage}`, `#page-${cfg.manualNextPage}`);
    reappearsOnNewPage = await waitForTrue(h.evaluate, "document.querySelector('#ja-panel') !== null", 3000);
  }
  h.report(
    PROGRESS_ASSERTION_NAMES.jaToggleHidesAndSticks,
    hidNow && staysHidden && reappearsOnNewPage,
    { hidNow, staysHidden, reappearsOnNewPage },
  );

  // Leave JA-first off again so it cannot bleed into any check that runs
  // after this function returns (defensive; nothing currently does, but
  // an assertion group should never depend on being last).
  await h.clickAssert('#btn-ja-first', 'M3: click #btn-ja-first (reset to off)');

  // -- E: review-queue badge/payload/queue vs a REAL due-today record;
  // deck-card tier. --------------------------------------------------
  //
  // NEW11 gate fix: the OLD version of this section read #sxc1-progress
  // and the badge right after D2's wipe, at due=0 -- vacuous (a
  // hardcoded-zero badge, an empty/absent queue, or a queue whose link
  // is simply wrong all pass at due=0=0). Fix: manufacture a genuine
  // due-today record FIRST, by re-answering the SAME quiz prompt
  // (already graded once, correctly, in assertion A -- though D2's own
  // wipe means it has since been cleared, so this is really a fresh
  // record) INCORRECTLY. A GAgain grade sets interval=0, i.e.
  // due=today -- see nextIntervalDaysJs/applyGradeToRec above, which
  // agree exactly with the real scheduler
  // (SXC1.Progress.Scheduler.nextIntervalDays GAgain -> 0,
  // applyEvent's due' = addDays today interval'). Assert payload.due>=1
  // AND the badge equals it AND the queue contains a real
  // ".queue-item" linking to the exercise -- all BEFORE any wipe.
  // THEN keep the post-wipe zero check too, now a real, meaningful
  // TRANSITION (due>=1 -> due=0) rather than a vacuous initial zero.
  await h.goto(`#/x/${cfg.quizDeck}/${cfg.quizId}`, `#${cfg.quizWrongOpt}`);
  await h.clickAssert(`#${cfg.quizWrongOpt}`, 'M3: click the wrong quiz option (E: manufacture a due-today record)');
  await h.clickAssert('#btn-ex-submit', 'M3: submit the wrong answer (E: manufacture a due-today record)');

  // Ready selector is '#sxc1-progress-tools' (Home-only -- see every
  // OTHER goto('#/', ...) call in this function), never
  // '#sxc1-review-badge': the badge (like #sxc1-progress itself) is part
  // of the persistent header/app-shell rendered on EVERY route, so it
  // can already be showing "Review 1" on the QUIZ route above (the wrong
  // answer's own grade already updated it) the instant before this
  // navigation -- waiting on it here would let goto()'s readiness poll
  // resolve against that STALE, pre-navigation DOM instead of waiting
  // for the real Home body (specifically #sxc1-review-queue) to render
  // at all. MEASURED against the real app: this exact race made
  // queueInfo read 0 items while payload.due/the badge already correctly
  // read 1 -- i.e. it looked like a genuine "queue missing its item"
  // defect until traced back to the ready-selector itself.
  await h.goto('#/', '#sxc1-progress-tools');
  const dueEstablished = await waitForProgressPredicate(h.evaluate, 'p.due >= 1', 3000);
  const payloadDue = await readSxc1Progress(h.evaluate);
  const badgeTextDue = await h.evaluate("(() => { const e = document.querySelector('#sxc1-review-badge'); return e ? e.textContent : null; })()");
  const badgeNumDue = badgeTextDue ? Number((badgeTextDue.match(/\d+/) || [NaN])[0]) : NaN;
  const queueInfo = await h.evaluate(`(() => {
    const items = Array.from(document.querySelectorAll('#sxc1-review-queue .queue-item'));
    return {
      count: items.length,
      hrefs: items.map((li) => { const a = li.querySelector('a'); return a ? a.getAttribute('href') : null; }),
    };
  })()`);
  const expectedQueueHref = `#/x/${cfg.quizDeck}/${cfg.quizId}`;
  const queueHasItem = queueInfo.count >= 1 && queueInfo.hrefs.includes(expectedQueueHref);
  const preWipeOk = dueEstablished && Boolean(payloadDue) && payloadDue.due >= 1
    && Number.isFinite(badgeNumDue) && badgeNumDue === payloadDue.due && queueHasItem;

  await h.goto('#/', '#sxc1-progress-tools');
  await h.clickAssert('#btn-progress-wipe', 'M3: click #btn-progress-wipe (E: post-due-record wipe)');
  await h.clickAssert('#btn-progress-wipe-confirm', 'M3: click #btn-progress-wipe-confirm (E: post-due-record wipe)');
  await waitForProgressPredicate(h.evaluate, 'p.due === 0 && p.records === 0', 3000);
  const payloadAfterWipeE = await readSxc1Progress(h.evaluate);
  const badgeTextAfterWipeE = await h.evaluate("(() => { const e = document.querySelector('#sxc1-review-badge'); return e ? e.textContent : null; })()");
  const badgeNumAfterWipeE = badgeTextAfterWipeE ? Number((badgeTextAfterWipeE.match(/\d+/) || [NaN])[0]) : NaN;
  const queueEmptyAfterWipe = await h.evaluate("document.querySelectorAll('#sxc1-review-queue .queue-item').length === 0");
  const postWipeOk = Boolean(payloadAfterWipeE) && payloadAfterWipeE.due === 0
    && badgeNumAfterWipeE === 0 && queueEmptyAfterWipe;

  h.report(
    PROGRESS_ASSERTION_NAMES.reviewBadgeMatchesDue,
    preWipeOk && postWipeOk,
    {
      preWipe: { dueEstablished, payloadDue, badgeTextDue, badgeNumDue, queueInfo, expectedQueueHref },
      postWipe: { payloadAfterWipeE, badgeTextAfterWipeE, badgeNumAfterWipeE, queueEmptyAfterWipe },
    },
  );

  await h.goto(`#/x/${cfg.deckSlug}`, '.deck-card');
  const domTier = await h.evaluate("(() => { const e = document.querySelector('.deck-card'); return e ? e.getAttribute('data-tier') : null; })()");
  h.report(
    PROGRESS_ASSERTION_NAMES.deckCardTierMatches,
    Boolean(domTier) && domTier === cfg.expectedTier,
    { domTier, expectedTier: cfg.expectedTier },
  );

  // -- F (M3 re-gate NEW14): Continue tracks LAST activity, not Map
  // order. On the post-E wiped slate: grade the LOOKUP first (l-* sorts
  // lexicographically before q-*), then the QUIZ. psLastPrompt must make
  // #sxc1-continue point at the quiz; the old rcLastSeen/Map-scan
  // implementation picks the same-day lexicographic first (the lookup)
  // and fails -- the assertion is order-discriminating by construction.
  await h.goto(`#/x/${cfg.lookupDeck}/${cfg.lookupId}`, '#ex-find-input');
  await h.typeText('#ex-find-input', String(cfg.lookupTargetPage));
  await h.clickAssert('#btn-ex-find-submit', 'F: submit the correct lookup page (grades the lookup FIRST)');
  await waitForTrue(h.evaluate, "document.querySelector('#ex-feedback') !== null && /^Correct/.test(document.querySelector('#ex-feedback').textContent)", 5000);
  await h.goto(`#/x/${cfg.quizDeck}/${cfg.quizId}`, `#${cfg.quizCorrectOpt}`);
  await h.clickAssert(`#${cfg.quizCorrectOpt}`, 'F: click the correct quiz option (grades the quiz SECOND)');
  await h.clickAssert('#btn-ex-submit', 'F: submit the quiz answer');
  await waitForTrue(h.evaluate, "document.querySelector('#ex-feedback') !== null && /^Correct/.test(document.querySelector('#ex-feedback').textContent)", 5000);
  await h.goto('#/', '#sxc1-progress-tools');
  const continueInfo = await h.evaluate("(() => { const a = document.querySelector('#sxc1-continue a[href]'); return a ? { href: a.getAttribute('href') } : null; })()");
  h.report(
    PROGRESS_ASSERTION_NAMES.continueMatchesLast,
    Boolean(continueInfo && continueInfo.href
      && continueInfo.href.indexOf(cfg.quizId) !== -1
      && continueInfo.href.indexOf(cfg.lookupId) === -1),
    { continueInfo, wantId: cfg.quizId, mustNotBe: cfg.lookupId },
  );
}

// `value` is either inline JSON text or a path to a JSON file (matches
// --exercise-fixture's documented "<path|json>" and, pragmatically,
// --expect-exercise-json too). Tries inline JSON first; falls back to
// reading it as a file.
function parseJsonOrFile(value, label) {
  try {
    return JSON.parse(value);
  } catch {
    // fall through to file
  }
  let raw;
  try {
    raw = fs.readFileSync(value, 'utf8');
  } catch (err) {
    throw new Error(`${label} is neither valid inline JSON nor a readable file path: ${err.message}`);
  }
  return JSON.parse(raw);
}

// M2 gate-3 LOW, closed by the M3 harness wave: this used to require only
// drill deck/id/steps/hasVerify and lookup deck/id/targetPage. A hand-
// supplied or stale fixture missing drill.citeSlug/citePage or
// lookup.targetSlug passed this upfront validation, then produced
// "#/m/undefined/..." expectations deep inside runExerciseAssertions and
// failed later with misleading browser output instead of failing fast,
// here, before a browser is even launched. citeSlug/citePage/targetSlug
// are exactly the fields SELF_TEST_FIXTURE already carries (see its own
// drill/lookup entries above) and exactly what the sabotage-negative
// assertion names below interpolate -- this just makes a REAL
// --exercise-fixture payload missing them fail loudly instead of
// silently.
const EXERCISE_FIXTURE_FIELDS = {
  quiz: ['deck', 'id', 'correctOpt', 'wrongOpt', 'citeSlug', 'citePage'],
  drill: ['deck', 'id', 'steps', 'hasVerify', 'citeSlug', 'citePage'],
  lookup: ['deck', 'id', 'targetPage', 'targetSlug'],
};

// Validates the shape exercise-check --browser-fixture emits. Returns
// null when acceptable, else a human-readable error.
function validateExerciseFixture(fx) {
  if (!fx || typeof fx !== 'object') return '--exercise-fixture must be a JSON object with "quiz", "drill" and "lookup" keys';
  for (const [kind, fields] of Object.entries(EXERCISE_FIXTURE_FIELDS)) {
    const obj = fx[kind];
    if (!obj || typeof obj !== 'object') return `--exercise-fixture is missing its "${kind}" object`;
    const missing = fields.filter((f) => !(f in obj));
    if (missing.length > 0) return `--exercise-fixture's "${kind}" object is missing field(s): ${missing.join(', ')}`;
  }
  return null;
}

// ---------------------------------------------------------------------------
// M4 (task "device-app"): the WebMIDI device suite -- assertions D1..D25
// from briefs/M4-plan.md section 4, driven through scripts/fake-midi.js.
//
// The fake is a COMMITTED REPO FILE (reviewable, one copy drives every
// scenario) loaded with Page.addScriptToEvaluateOnNewDocument on a
// FRESHLY CREATED target (created at about:blank, attached, domains
// enabled, script added, only then Page.navigate) -- creating the target
// directly at the app URL is too late for the app's boot-time feature
// detection to see it (M4 design probe P-B; same technique as NEW5's
// cold-deep-link target).
//
// The suite is shared verbatim between the real app (main() and
// --device-only below, driven against --url) and the self-test fixture
// (runOneSelfTestPass, driven against selfTestFixtureHtml()'s own device
// mirror) -- "the same assertion code runs against it", the
// runExerciseAssertions precedent. Only the DEVICE_*_CFG route/byte
// tables differ.
//
// Every negative control asserts its anti-vacuity evidence: emit()'s
// return value (how many handlers were actually invoked),
// subscribedCount(), and the lastMessage bytes echoed back out of
// #sxc1-device-state -- so a control can never pass because nobody was
// listening. D20 runs the enable flow with NO fake at all: real headless
// Chrome exposes requestMIDIAccess but rejects it (P-C), which is what
// proves the fake is load-bearing in every positive assertion.
// ---------------------------------------------------------------------------

const FAKE_MIDI_PATH = path.join(HARNESS_REPO_ROOT, 'scripts', 'fake-midi.js');

const DEVICE_ASSERTION_NAMES = {
  d1: 'D1: outcome absent -> #sxc1-device-state reports supported:false, status "unsupported", and no #ex-device is rendered',
  d2: 'D2: outcome absent -> the drill still confirms manually end to end, exactly as in M3, with the .ex-verify-idle text',
  d3: 'D3: fake present, no click -> requestMIDIAccess was never called at boot (calls.length === 0)',
  d4: 'D4: #ex-device present on the drill route, absent on a quiz route',
  d5: 'D5: clicking #btn-device-enable makes exactly one new requestMIDIAccess call, with sysex === false',
  d6: 'D6: one SXC-1 port -> status "granted", ports names it, watching is the drill\'s first hook',
  d7: 'D7: emitting the matching bytes auto-confirms step 1: exactly one new event for the prompt, confirms says source "device"',
  d8: 'D8: NEG wrong CC number -> delivered to a live port but no confirm (lastMessage proves receipt)',
  d9: 'D9: NEG wrong CC value -> delivered to a live port but no confirm (lastMessage proves receipt)',
  d10: 'D10: NEG wrong channel -> no confirm, lastChannel names it, #device-status explains the mismatch, #btn-device-use-channel appears',
  d11: 'D11: pad hook -> the wrong note does not confirm, the right note does',
  d12: 'D12: two ports, one SXC-1 -> only the SXC-1 is bound; the other port\'s emit reaches nobody and confirms nothing',
  d13: 'D13: one unrecognised port -> bound anyway (liberal fallback) and confirms',
  d14: 'D14: the matching message emitted twice in one turn (plus once settled) -> still exactly one event for that prompt',
  d15: 'D15: a manual confirm racing/preceding the matching bytes -> no second event, cursor unchanged (stale-confirm protection)',
  d16: 'D16: navigating away from the drill disarms the watch (watching null) and a later matching emit confirms nothing',
  d17: 'D17: zero ports at enable -> granted with ports []; hot-plug addPort rebinds and the drill then confirms',
  d18: 'D18: removePort empties ports without crashing and keeps the watch armed; re-adding a port confirms again',
  d19: 'D19: outcome deny -> status "denied", #device-status explains, manual confirm still works',
  d20: 'D20: no fake injected (real headless Chrome) -> enable lands in status "denied" and never confirms (the fake is load-bearing)',
  d21: 'D21: post-boot zero-delta -- once boot has settled on the drill route, the whole device scenario adds ZERO network requests (no allowlist of any kind; the boot-phase capture itself must be non-empty)',
  d22: 'D22: site/public and site/static contain no fake-midi.js',
  d23: 'D23: in-flight navigation -- matching bytes emitted and the route changed in the SAME JS turn: no confirmation may land once the drill route is gone, and the emit was provably delivered',
  d24: 'D24: in-flight Restart -- matching bytes emitted and #btn-ex-restart clicked in the SAME JS turn: the fresh attempt stays blank (no stale confirm lands on it), and a settled re-emit then confirms it (the generation guard does not over-block)',
  d25: 'D25: in-flight disable -- matching bytes emitted and #btn-device-enable clicked in the SAME JS turn: no confirm lands while the device is off, and re-enable + re-emit then confirms again',
  // M5 a11y pass: a DEVICE confirm advances the cursor with no user
  // click to carry focus, so the advance-focus wiring must run on that
  // path too (D26); and the device panel's controls carry their SR
  // names/live regions (D27). Numbered D26/D27 as M5 additions; the
  // check-site V6 floor was widened to D1..D27 at the M5 final gate
  // (finding M5-R1-1), so unplugging either now turns V6 red like any
  // other D-assertion.
  d26: 'D26: a DEVICE confirm advance moves focus to the next .ex-step (document.activeElement lands on #ex-step-2, never <body>)',
  d27: 'D27: device panel SR labels -- #sel-device-channel carries an aria-label accessible name; #device-status and the .ex-verify line are aria-live=polite',
};

// Preambles (per-scenario driver setup, run right after the fake installs).
const DEV_PRE_GRANT_SXC = "window.__SXC1_FAKE_MIDI.setOutcome('grant'); window.__SXC1_FAKE_MIDI.addPort('sxc1-0', 'CASIO SXC-1 MIDI 1', 'CASIO');";
const DEV_PRE_ABSENT = "window.__SXC1_FAKE_MIDI.setOutcome('absent');";
const DEV_PRE_DENY = "window.__SXC1_FAKE_MIDI.setOutcome('deny');";
const DEV_PRE_TWO = "window.__SXC1_FAKE_MIDI.setOutcome('grant'); window.__SXC1_FAKE_MIDI.addPort('other-0', 'Arturia KeyStep', 'Arturia'); window.__SXC1_FAKE_MIDI.addPort('sxc1-0', 'CASIO SXC-1 MIDI 1', 'CASIO');";
const DEV_PRE_USB = "window.__SXC1_FAKE_MIDI.setOutcome('grant'); window.__SXC1_FAKE_MIDI.addPort('usb-0', 'USB MIDI Device', '');";
const DEV_PRE_ZERO = "window.__SXC1_FAKE_MIDI.setOutcome('grant');";

// Test vectors come from translations/midi.md, not from imagination:
// CC 80 = Bank Select A (127 press / 0 release); note 36 = pad 1 bank A;
// note 37 = pad 2 bank A; note 48 = pad 13 bank A; 0xB1 = CC on ch 2.
// Routes are the merged-M3 tree's seed decks (briefs/M4-budget.json,
// evidence item e): the manifest's tag-m2 route names drifted.
const DEVICE_REAL_CFG = {
  sxcPortName: 'CASIO SXC-1 MIDI 1',
  quizRoute: '#/x/pad-01/q-2-01',
  drill: {
    route: '#/x/pad-01/d-2-01', exId: 'd-2-01', steps: 3,
    prompt1: 'd-2-01#1', spec1Text: 'cc 80 127',
    good: [176, 80, 127], wrongCc: [176, 81, 127], wrongValue: [176, 80, 0],
    wrongChan: [177, 80, 127], wrongChanNum: 2,
    progressAfter1: '2 / 3',
  },
  pad: {
    route: '#/x/pad-03/d-2-02', exId: 'd-2-02', prompt: 'd-2-02#1',
    prepareBytes: null, good: [144, 36, 127], bad: [144, 37, 127],
  },
  twoStep: {
    route: '#/x/pad-03/d-2-02', exId: 'd-2-02',
    first: [144, 36, 127], firstPrompt: 'd-2-02#1',
    second: [144, 48, 127], secondPrompt: 'd-2-02#2',
  },
  // M4 gate-1 (D23): the exercise the in-flight-navigation scenario
  // navigates TO -- its event count must stay untouched by the race.
  quizExId: 'q-2-01',
  // MEASURED in-flight race outcomes against the real app -- see
  // T14/T15/T16's own comments for the schedule these pin: this runtime
  // drains every dispatch chain synchronously within the JS call that
  // triggered it, so an emit's confirm has fully applied before a
  // same-turn navigation/click processes ('hit'-shaped phase A
  // outcomes, nav not strict) and a click's disable has fully torn the
  // JS side down before a same-turn emit runs.
  inflightNavStrict: false,
  inflightDisableRace: 'hit',
};

// The fixture drill (selfTestFixtureHtml) carries two hooks: step 1
// "cc 80 127", step 2 "pad 1 bank A" (note 36) -- so the pad case is
// step 2 of the same drill, reached by first confirming step 1 by device.
const DEVICE_SELFTEST_CFG = {
  sxcPortName: 'CASIO SXC-1 MIDI 1',
  quizRoute: `#/x/${SELF_TEST_FIXTURE.quiz.deck}/${SELF_TEST_FIXTURE.quiz.id}`,
  drill: {
    route: `#/x/${SELF_TEST_FIXTURE.drill.deck}/${SELF_TEST_FIXTURE.drill.id}`,
    exId: SELF_TEST_FIXTURE.drill.id, steps: SELF_TEST_FIXTURE.drill.steps,
    prompt1: `${SELF_TEST_FIXTURE.drill.id}#1`, spec1Text: 'cc 80 127',
    good: [176, 80, 127], wrongCc: [176, 81, 127], wrongValue: [176, 80, 0],
    wrongChan: [177, 80, 127], wrongChanNum: 2,
    progressAfter1: `2 / ${SELF_TEST_FIXTURE.drill.steps}`,
  },
  pad: {
    route: `#/x/${SELF_TEST_FIXTURE.drill.deck}/${SELF_TEST_FIXTURE.drill.id}`,
    exId: SELF_TEST_FIXTURE.drill.id, prompt: `${SELF_TEST_FIXTURE.drill.id}#2`,
    prepareBytes: [176, 80, 127], good: [144, 36, 127], bad: [144, 37, 127],
  },
  twoStep: {
    route: `#/x/${SELF_TEST_FIXTURE.drill.deck}/${SELF_TEST_FIXTURE.drill.id}`,
    exId: SELF_TEST_FIXTURE.drill.id,
    first: [176, 80, 127], firstPrompt: `${SELF_TEST_FIXTURE.drill.id}#1`,
    second: [144, 36, 127], secondPrompt: `${SELF_TEST_FIXTURE.drill.id}#2`,
  },
  // M4 gate-1 (D23): see DEVICE_REAL_CFG.quizExId.
  quizExId: SELF_TEST_FIXTURE.quiz.id,
  // The fixture's mirror queues its confirm hops through REAL
  // setTimeouts (unlike the app's measured synchronous chains), so the
  // emit-FIRST orderings leave a confirm genuinely in flight across the
  // context change and the guard-at-application's drop is
  // deterministic: strict nav (forPrompt stays 0) and 'drop'-shaped
  // T16 phase A. This is the "unit-level" arm the gate asked for, and
  // it is what the mapped sabotage selectors ('devConfirmAcrossNav',
  // 'devIgnoreGen') turn red on cue.
  inflightNavStrict: true,
  inflightDisableRace: 'drop',
};

// M4 negative-sweep map, appended to --self-test-negative exactly like
// M3_SELECTOR_ASSERTIONS: each fixture selector sabotages one decision
// point of the fixture's device mirror (see its own comment at the
// sabotage site) and must make EXACTLY its mapped D-assertion(s) fail.
// 'devPanelAlways' maps to two on purpose: an unconditionally rendered
// panel is one root cause observed on two routes (D1's absent drill and
// D4's quiz), the honest single-root-cause grouping the M3 map already
// uses for 'jaFirstPersist'.
const M4_SELECTOR_ASSERTIONS = {
  devBootRequest: [DEVICE_ASSERTION_NAMES.d3],
  devSysexTrue: [DEVICE_ASSERTION_NAMES.d5],
  devPanelAlways: [DEVICE_ASSERTION_NAMES.d1, DEVICE_ASSERTION_NAMES.d4],
  devWrongCC: [DEVICE_ASSERTION_NAMES.d8],
  devIgnoreValue: [DEVICE_ASSERTION_NAMES.d9],
  devIgnoreChannel: [DEVICE_ASSERTION_NAMES.d10],
  devPadAnyNote: [DEVICE_ASSERTION_NAMES.d11],
  devBindAll: [DEVICE_ASSERTION_NAMES.d12],
  devNoFallback: [DEVICE_ASSERTION_NAMES.d13],
  devNotOneShot: [DEVICE_ASSERTION_NAMES.d14],
  devStaleConfirm: [DEVICE_ASSERTION_NAMES.d15],
  devKeepWatchOnNav: [DEVICE_ASSERTION_NAMES.d16],
  // M4 gate-1 additions (briefs/M4-codex-gate1.json). 'devIgnoreGen'
  // maps to two on purpose: dropping the attempt-generation re-check is
  // ONE root cause observable through two in-flight orderings (Restart
  // and disable), the same honest single-root-cause grouping as
  // 'devPanelAlways' above.
  devConfirmAcrossNav: [DEVICE_ASSERTION_NAMES.d23],
  devIgnoreGen: [DEVICE_ASSERTION_NAMES.d24, DEVICE_ASSERTION_NAMES.d25],
  // D21's red controls -- one selector per same-origin exfiltration
  // class (see the sabotage trio's own comment in devOnMessage), each
  // required to turn exactly D21 red: 'devSameOriginEgress' (gate-1,
  // query-string), 'devShapedPathEgress' (gate-2, query-free
  // asset-shaped path) and 'devRepeatAssetEgress' (gate-2, repeated
  // real asset). The latter two are precisely the requests gate-1's
  // shape allowlist waved through; only the post-boot zero-delta rule
  // (T13) rejects all three.
  devSameOriginEgress: [DEVICE_ASSERTION_NAMES.d21],
  devShapedPathEgress: [DEVICE_ASSERTION_NAMES.d21],
  devRepeatAssetEgress: [DEVICE_ASSERTION_NAMES.d21],
};

// M5 a11y negative-sweep map, appended exactly like the M3/M4 maps: each
// selector sabotages ONE a11y feature of the fixture mirror (see the
// fixture's own M5 a11y block) and must make EXACTLY its mapped
// assertion(s) fail. Each grouping is a single root cause observed at
// several sites (the 'devPanelAlways'/'jaFirstPersist' precedent):
//   a11yKeyboard     click-only <span> controls -- unfocusable, Enter
//                    does nothing -- so all three keyboard-only flows
//                    fail; every .click()-driven assertion (the whole
//                    M2/M3 surface AND the click-driven focus flows)
//                    stays green, which is what proves the keyboard
//                    flows genuinely ride the keyboard.
//   a11yFocusAdvance the advance-focus move is skipped everywhere (quiz
//                    Next, drill confirm, DEVICE confirm), stranding
//                    focus on <body>; the keyboard flows still complete
//                    (their Tab walk restarts from <body> by design), so
//                    exactly the three focus assertions fail. Needs the
//                    device suite for D26.
//   a11ySrLabels     every M5 ARIA attribute omitted (aria-live lines,
//                    the channel select's and export textarea's
//                    accessible names). Needs the device suite for D27.
const M5_SELECTOR_ASSERTIONS = {
  a11yKeyboard: {
    expectedToFail: [KB_QUIZ_ASSERTION_NAME, KB_DRILL_ASSERTION_NAME, KB_LOOKUP_ASSERTION_NAME],
    includeDevice: false,
  },
  a11yFocusAdvance: {
    expectedToFail: [FOCUS_QUIZ_ASSERTION_NAME, FOCUS_DRILL_ASSERTION_NAME, DEVICE_ASSERTION_NAMES.d26],
    includeDevice: true,
  },
  a11ySrLabels: {
    expectedToFail: [SR_LABELS_ASSERTION_NAME, DEVICE_ASSERTION_NAMES.d27],
    includeDevice: true,
  },
};

// M6 W1: one sabotage point for the degraded-content surface -- the
// fixture renders the #sxc1-content-error banner + #btn-content-retry on
// a HEALTHY boot (see selfTestFixtureHtml's 'contentDegraded' block), so
// exactly the absent-scenario parity assertion must fail and nothing
// else. Same {expectedToFail, includeDevice} shape as
// M5_SELECTOR_ASSERTIONS; wired into runSelfTestNegative's passesInOrder
// (sweep 37 -> 38 passes).
const M6_SELECTOR_ASSERTIONS = {
  contentDegraded: {
    expectedToFail: [CONTENT_ABSENT_ASSERTION_NAME],
    includeDevice: false,
  },
};

// M6 W2: the UI-language sabotage points -- each one isolates one layer
// of the JA flow (see the fixture's own UILANG block for how), and every
// pass carries includeJaFlow so the flow actually runs. 'uiLangText'
// maps to several names ON PURPOSE: unlocalized learner-visible body
// strings are ONE root cause observed at every feedback/verify pin the
// ja pass makes (the devPanelAlways/jaFirstPersist honest-grouping
// precedent).
const M6W2_SELECTOR_ASSERTIONS = {
  uiLangHeader: {
    expectedToFail: [UILANG_HEADER_ASSERTION_NAME],
    includeDevice: false, includeJaFlow: true,
  },
  uiLangPref: {
    expectedToFail: [UILANG_PREF_ASSERTION_NAME],
    includeDevice: false, includeJaFlow: true,
  },
  uiLangText: {
    expectedToFail: [
      WRONG_QUIZ_FEEDBACK_ASSERTION_NAME + JA_NAME_SUFFIX,
      CORRECT_QUIZ_FEEDBACK_ASSERTION_NAME + JA_NAME_SUFFIX,
      LOOKUP_WRONG_ASSERTION_NAME + JA_NAME_SUFFIX,
      LOOKUP_CORRECT_ASSERTION_NAME + JA_NAME_SUFFIX,
      KB_QUIZ_ASSERTION_NAME + JA_NAME_SUFFIX,
      KB_LOOKUP_ASSERTION_NAME + JA_NAME_SUFFIX,
      UILANG_VERIFY_JA_ASSERTION_NAME,
    ],
    includeDevice: false, includeJaFlow: true,
  },
  uiLangAria: {
    expectedToFail: [SR_LABELS_ASSERTION_NAME + JA_NAME_SUFFIX],
    includeDevice: false, includeJaFlow: true,
  },
};

// Fresh-target factory: everything a device scenario needs, built the
// P-B way (inject BEFORE navigation). `cdp` and `deadline` come from
// whichever caller owns the browser (main(), --device-only, or a
// self-test pass).
function deviceTargetFactoryFor(cdp, deadline, baseUrl) {
  const baseNoHash = baseUrl.replace(/#.*$/, '');
  return async function makeDeviceTarget({ preamble = '', injectFake = true, hash = '', network = false }) {
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    await cdp.send('Runtime.enable', {}, sessionId);
    await cdp.send('Page.enable', {}, sessionId);
    const requests = [];
    if (network) {
      await cdp.send('Network.enable', {}, sessionId);
      cdp.on('Network.requestWillBeSent', (params, sid) => {
        if (sid === sessionId) requests.push(params.request && params.request.url);
      });
    }
    if (injectFake) {
      const src = fs.readFileSync(FAKE_MIDI_PATH, 'utf8');
      await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
        source: `${src}\n;(function () { try { ${preamble} } catch (e) { console.error('fake-midi preamble failed: ' + e); } })();`,
      }, sessionId);
    }
    await cdp.send('Page.navigate', { url: `${baseNoHash}${hash}` }, sessionId);
    const evaluate = async (expression) => {
      const res = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, sessionId);
      if (res.exceptionDetails) {
        const d = res.exceptionDetails;
        throw new Error(`page evaluation error: ${d.exception?.description || d.text}`);
      }
      return res.result ? res.result.value : undefined;
    };
    let booted = false;
    const bootDeadline = Math.min(deadline, Date.now() + 20000);
    while (Date.now() < bootDeadline) {
      try {
        if ((await evaluate('window.__SXC1_BOOTED === true')) === true) { booted = true; break; }
      } catch { /* document may still be navigating */ }
      await sleep(100);
    }
    return {
      booted,
      evaluate,
      requests,
      baseNoHash,
      close: async () => { try { await cdp.send('Target.closeTarget', { targetId }); } catch { /* best effort */ } },
    };
  };
}

// M4 gate-2 fix (briefs/M4-codex-gate2.json, finding 3): gate-1's
// version of this helper allowlisted asset-path SHAPES, which still let
// a hostile handler exfiltrate MIDI bytes query-free -- either encoded
// as the FILENAME of an asset-shaped path
// (fetch('vendor/browser_wasi_shim/144-36-64.js') matched the shape
// regex and reached the server even as a 404), or as extra fetches of a
// REAL asset (repeated 'app.wasm' requests, the count/timing channel).
// There is no allowlist of any kind anymore: D21's enforcement is now
// the POST-BOOT ZERO-DELTA in T13 (zero new requestWillBeSent events
// across the whole device-scenario window -- measured to hold with
// nothing browser-initiated in the window either, favicon.ico included,
// so NOTHING is permitted). This helper only LABELS the query-string
// subset of an offending scenario-window delta so the failure message
// names the classic exfiltration channel explicitly; it grants nothing
// a pass. The file:// self-test arm's semantics are preserved by the
// same rule: the fixture's boot capture is exactly its own document
// (the anti-vacuity floor), and its scenario window allows nothing.
function d21QueryStringEgress(scenarioRequests) {
  return scenarioRequests.filter((u) => typeof u !== 'string' || u.includes('?'));
}

async function readDeviceStateJson(evaluate) {
  const raw = await evaluate("(() => { const e = document.querySelector('#sxc1-device-state'); return e ? e.textContent : null; })()");
  try { return JSON.parse(raw); } catch { return null; }
}

// Poll #sxc1-device-state until `predicateSrc` (over the parsed payload
// `p`) is true -- the waitForProgressPredicate idiom.
async function waitDeviceState(evaluate, predicateSrc, budgetMs) {
  return waitForTrue(evaluate, `(() => {
    const e = document.querySelector('#sxc1-device-state');
    let p = null;
    try { p = JSON.parse(e ? e.textContent : 'null'); } catch (err) { return false; }
    if (!p) return false;
    return Boolean(${predicateSrc});
  })()`, budgetMs);
}

async function deviceEventCounts(evaluate, exId, promptId) {
  return evaluate(`(() => {
    let log = [];
    try { log = JSON.parse(document.querySelector('#sxc1-event-log').textContent) || []; } catch (e) { /* empty */ }
    return {
      forPrompt: log.filter((ev) => ev.prompt === ${JSON.stringify(promptId)}).length,
      forExercise: log.filter((ev) => ev.exercise === ${JSON.stringify(exId)}).length,
    };
  })()`);
}

// All direct fake reads are typeof-guarded so a run whose fake was never
// injected (the S13 sabotage, or a broken preamble) FAILS its assertions
// with a readable observation (-1 / null) instead of crashing the whole
// suite on a TypeError.
function fakeEmitExpr(bytes, portId) {
  const call = portId === undefined
    ? `window.__SXC1_FAKE_MIDI.emit(${JSON.stringify(bytes)})`
    : `window.__SXC1_FAKE_MIDI.emit(${JSON.stringify(bytes)}, ${JSON.stringify(portId)})`;
  return `(window.__SXC1_FAKE_MIDI ? ${call} : -1)`;
}

const FAKE_CALLS_LEN_EXPR = '(window.__SXC1_FAKE_MIDI ? window.__SXC1_FAKE_MIDI.calls.length : -1)';
const FAKE_CALLS_EXPR = '(window.__SXC1_FAKE_MIDI ? window.__SXC1_FAKE_MIDI.calls.slice() : null)';
const FAKE_SUBSCRIBED_EXPR = '(window.__SXC1_FAKE_MIDI ? window.__SXC1_FAKE_MIDI.subscribedCount() : -1)';

async function devClick(evaluate, selector) {
  return evaluate(`(() => { const e = document.querySelector(${JSON.stringify(selector)}); if (!e) return false; e.click(); return true; })()`);
}

function sameBytes(a, b) {
  return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((x, i) => x === b[i]);
}

// One negative probe: emit `bytes`, wait for the hub to echo them back
// as lastMessage (proof of receipt), give any (wrong) confirm a settle
// window, and report the event-count delta.
async function devNegProbe(evaluate, cfgDrill, bytes) {
  const before = await deviceEventCounts(evaluate, cfgDrill.exId, cfgDrill.prompt1);
  const delivered = await evaluate(fakeEmitExpr(bytes));
  const echoed = await waitDeviceState(evaluate, `p.lastMessage && p.lastMessage.join(',') === ${JSON.stringify(bytes.join(','))}`, 3000);
  await sleep(350);
  const after = await deviceEventCounts(evaluate, cfgDrill.exId, cfgDrill.prompt1);
  const ds = await readDeviceStateJson(evaluate);
  return { delivered, echoed, before, after, ds };
}

// D1..D25. `makeTarget` is deviceTargetFactoryFor's product; `report`
// follows the house report(name, ok, observed) contract; `cfg` is one of
// the DEVICE_*_CFG tables.
async function runDeviceAssertions(makeTarget, report, cfg) {
  const N = DEVICE_ASSERTION_NAMES;

  // --- T1: outcome 'absent' -- D1 (graceful degradation) + D2 (the M3
  // manual drill flow, verbatim, still works). ---------------------------
  {
    const t = await makeTarget({ preamble: DEV_PRE_ABSENT, hash: cfg.drill.route });
    if (!t.booted) {
      report(N.d1, false, 'absent-scenario target did not boot');
      report(N.d2, false, 'absent-scenario target did not boot');
    } else {
      const ds = await readDeviceStateJson(t.evaluate);
      const noPanel = await t.evaluate("document.querySelector('#ex-device') === null");
      report(
        N.d1,
        Boolean(ds && ds.supported === false && ds.status === 'unsupported' && noPanel === true),
        { ds, noPanel },
      );
      const stepCount = await t.evaluate("document.querySelectorAll('#ex-steps > li').length");
      const verifyInfo = await t.evaluate("(() => { const e = document.querySelector('.ex-verify'); return e ? { cls: e.className, text: e.textContent } : null; })()");
      let confirmedAll = true;
      for (let s = 1; s <= cfg.drill.steps; s += 1) {
        const present = await waitForTrue(t.evaluate, `document.querySelector('#btn-ex-confirm-${s}') !== null`, 4000);
        const clicked = present && await devClick(t.evaluate, `#btn-ex-confirm-${s}`);
        if (!clicked) { confirmedAll = false; break; }
      }
      // #ex-progress displays min(cursor+1, steps), so "N / N" is already
      // shown one confirm early -- the settled signal is the confirms
      // array itself reaching all N steps.
      const finished = confirmedAll && await waitDeviceState(
        t.evaluate,
        `p.confirms.length === ${cfg.drill.steps}`,
        5000,
      );
      const dsAfter = await readDeviceStateJson(t.evaluate);
      const confirmsOk = Boolean(dsAfter && Array.isArray(dsAfter.confirms)
        && dsAfter.confirms.length === cfg.drill.steps
        && dsAfter.confirms.every((c) => c.source === 'learner'));
      report(
        N.d2,
        stepCount === cfg.drill.steps
          && Boolean(verifyInfo && verifyInfo.cls.split(/\s+/).includes('ex-verify-idle') && /confirm manually/.test(verifyInfo.text))
          && confirmedAll && finished === true && confirmsOk,
        { stepCount, verifyInfo, confirmedAll, finished, confirms: dsAfter && dsAfter.confirms },
      );
    }
    await t.close();
  }

  // --- T2: grant + one SXC-1 port -- D3/D4/D5/D6/D7. --------------------
  {
    const t = await makeTarget({ preamble: DEV_PRE_GRANT_SXC, hash: cfg.drill.route });
    if (!t.booted) {
      for (const n of [N.d3, N.d4, N.d5, N.d6, N.d7]) report(n, false, 'grant-scenario target did not boot');
    } else {
      const fakePresent = await t.evaluate("typeof window.__SXC1_FAKE_MIDI === 'object'");
      const callsAtBoot = await t.evaluate(FAKE_CALLS_LEN_EXPR);
      report(N.d3, fakePresent === true && callsAtBoot === 0, { fakePresent, callsAtBoot });

      const panelOnDrill = await waitForTrue(t.evaluate, "document.querySelector('#ex-device') !== null", 4000);
      await t.evaluate(`window.location.hash = ${JSON.stringify(cfg.quizRoute)}; true`);
      await waitForTrue(t.evaluate, "document.querySelector('.kind-quiz') !== null", 5000);
      const panelOnQuiz = await t.evaluate("document.querySelector('#ex-device') !== null");
      await t.evaluate(`window.location.hash = ${JSON.stringify(cfg.drill.route)}; true`);
      await waitForTrue(t.evaluate, "document.querySelector('#ex-device') !== null", 5000);
      report(N.d4, panelOnDrill === true && panelOnQuiz === false, { panelOnDrill, panelOnQuiz });

      const callsBefore = await t.evaluate(FAKE_CALLS_LEN_EXPR);
      await devClick(t.evaluate, '#btn-device-enable');
      await waitDeviceState(t.evaluate, "p.status === 'granted' || p.status === 'denied'", 6000);
      const calls = await t.evaluate(FAKE_CALLS_EXPR);
      report(
        N.d5,
        Array.isArray(calls) && calls.length === callsBefore + 1 && calls.length > 0 && calls[calls.length - 1].sysex === false,
        { callsBefore, calls },
      );

      const armed = await waitDeviceState(
        t.evaluate,
        `p.status === 'granted' && p.watching && p.watching.prompt === ${JSON.stringify(cfg.drill.prompt1)} && p.watching.spec === ${JSON.stringify(cfg.drill.spec1Text)}`,
        6000,
      );
      const ds6 = await readDeviceStateJson(t.evaluate);
      report(
        N.d6,
        armed === true && Boolean(ds6 && Array.isArray(ds6.ports) && ds6.ports.includes(cfg.sxcPortName)),
        ds6,
      );

      const before7 = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      const delivered7 = await t.evaluate(fakeEmitExpr(cfg.drill.good));
      const confirmed7 = await waitDeviceState(
        t.evaluate,
        `p.confirms.some((c) => c.prompt === ${JSON.stringify(cfg.drill.prompt1)} && c.source === 'device')`,
        6000,
      );
      const after7 = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      const progress7 = await t.evaluate("(document.querySelector('#ex-progress')||{}).textContent");
      report(
        N.d7,
        delivered7 >= 1 && confirmed7 === true
          && before7.forPrompt === 0 && after7.forPrompt === 1 && after7.forExercise === 1
          && progress7 === cfg.drill.progressAfter1,
        { delivered7, confirmed7, before7, after7, progress7 },
      );
    }
    await t.close();
  }

  // --- T3: grant + SXC-1 port -- the sabotage-proven negatives D8/D9/D10.
  {
    const t = await makeTarget({ preamble: DEV_PRE_GRANT_SXC, hash: cfg.drill.route });
    if (!t.booted) {
      for (const n of [N.d8, N.d9, N.d10]) report(n, false, 'negative-scenario target did not boot');
    } else {
      await devClick(t.evaluate, '#btn-device-enable');
      await waitDeviceState(t.evaluate, `p.status === 'granted' && p.watching && p.watching.prompt === ${JSON.stringify(cfg.drill.prompt1)}`, 6000);

      const r8 = await devNegProbe(t.evaluate, cfg.drill, cfg.drill.wrongCc);
      report(
        N.d8,
        r8.delivered >= 1 && r8.echoed === true && sameBytes(r8.ds && r8.ds.lastMessage, cfg.drill.wrongCc)
          && r8.after.forExercise === r8.before.forExercise,
        r8,
      );

      const r9 = await devNegProbe(t.evaluate, cfg.drill, cfg.drill.wrongValue);
      report(
        N.d9,
        r9.delivered >= 1 && r9.echoed === true && sameBytes(r9.ds && r9.ds.lastMessage, cfg.drill.wrongValue)
          && r9.after.forExercise === r9.before.forExercise,
        r9,
      );

      const r10 = await devNegProbe(t.evaluate, cfg.drill, cfg.drill.wrongChan);
      const statusTxt = await t.evaluate("(document.querySelector('#device-status')||{}).textContent");
      const useBtn = await t.evaluate("document.querySelector('#btn-device-use-channel') !== null");
      const namesMismatch = new RegExp(`channel ${cfg.drill.wrongChanNum}`).test(statusTxt || '');
      report(
        N.d10,
        r10.delivered >= 1 && r10.echoed === true
          && Boolean(r10.ds && r10.ds.lastChannel === cfg.drill.wrongChanNum)
          && r10.after.forExercise === r10.before.forExercise
          && namesMismatch && useBtn === true,
        { r10, statusTxt, useBtn },
      );
    }
    await t.close();
  }

  // --- T4: the pad/note hook -- D11. ------------------------------------
  {
    const t = await makeTarget({ preamble: DEV_PRE_GRANT_SXC, hash: cfg.pad.route });
    if (!t.booted) {
      report(N.d11, false, 'pad-scenario target did not boot');
    } else {
      await devClick(t.evaluate, '#btn-device-enable');
      await waitDeviceState(t.evaluate, "p.status === 'granted'", 6000);
      if (cfg.pad.prepareBytes) await t.evaluate(fakeEmitExpr(cfg.pad.prepareBytes));
      const armed = await waitDeviceState(t.evaluate, `p.watching && p.watching.prompt === ${JSON.stringify(cfg.pad.prompt)}`, 6000);
      const before = await deviceEventCounts(t.evaluate, cfg.pad.exId, cfg.pad.prompt);
      const deliveredBad = await t.evaluate(fakeEmitExpr(cfg.pad.bad));
      await waitDeviceState(t.evaluate, `p.lastMessage && p.lastMessage.join(',') === ${JSON.stringify(cfg.pad.bad.join(','))}`, 3000);
      await sleep(350);
      const mid = await deviceEventCounts(t.evaluate, cfg.pad.exId, cfg.pad.prompt);
      const deliveredGood = await t.evaluate(fakeEmitExpr(cfg.pad.good));
      const confirmed = await waitDeviceState(
        t.evaluate,
        `p.confirms.some((c) => c.prompt === ${JSON.stringify(cfg.pad.prompt)} && c.source === 'device')`,
        6000,
      );
      const after = await deviceEventCounts(t.evaluate, cfg.pad.exId, cfg.pad.prompt);
      report(
        N.d11,
        armed === true && deliveredBad >= 1 && mid.forPrompt === before.forPrompt
          && deliveredGood >= 1 && confirmed === true && after.forPrompt === before.forPrompt + 1,
        { armed, deliveredBad, deliveredGood, before, mid, after, confirmed },
      );
    }
    await t.close();
  }

  // --- T5: two ports, one SXC-1 -- D12. ---------------------------------
  {
    const t = await makeTarget({ preamble: DEV_PRE_TWO, hash: cfg.drill.route });
    if (!t.booted) {
      report(N.d12, false, 'two-port target did not boot');
    } else {
      await devClick(t.evaluate, '#btn-device-enable');
      await waitDeviceState(t.evaluate, `p.status === 'granted' && p.watching && p.watching.prompt === ${JSON.stringify(cfg.drill.prompt1)}`, 6000);
      const ds = await readDeviceStateJson(t.evaluate);
      const deliveredOther = await t.evaluate(fakeEmitExpr(cfg.drill.good, 'other-0'));
      const subscribed = await t.evaluate(FAKE_SUBSCRIBED_EXPR);
      await sleep(350);
      const counts = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      report(
        N.d12,
        Boolean(ds && Array.isArray(ds.ports) && ds.ports.length === 1 && ds.ports[0] === cfg.sxcPortName
          && Array.isArray(ds.allPorts) && ds.allPorts.length === 2)
          && deliveredOther === 0 && subscribed === 1 && counts.forExercise === 0,
        { ds, deliveredOther, subscribed, counts },
      );
    }
    await t.close();
  }

  // --- T6: one unrecognised port -- D13 (the liberal fallback). ---------
  {
    const t = await makeTarget({ preamble: DEV_PRE_USB, hash: cfg.drill.route });
    if (!t.booted) {
      report(N.d13, false, 'fallback-port target did not boot');
    } else {
      await devClick(t.evaluate, '#btn-device-enable');
      await waitDeviceState(t.evaluate, "p.status === 'granted'", 6000);
      const ds = await readDeviceStateJson(t.evaluate);
      const subscribed = await t.evaluate(FAKE_SUBSCRIBED_EXPR);
      const delivered = await t.evaluate(fakeEmitExpr(cfg.drill.good));
      const confirmed = await waitDeviceState(
        t.evaluate,
        `p.confirms.some((c) => c.prompt === ${JSON.stringify(cfg.drill.prompt1)} && c.source === 'device')`,
        6000,
      );
      report(
        N.d13,
        Boolean(ds && Array.isArray(ds.ports) && ds.ports.includes('USB MIDI Device'))
          && subscribed >= 1 && delivered >= 1 && confirmed === true,
        { ds, subscribed, delivered, confirmed },
      );
    }
    await t.close();
  }

  // --- T7: one-shot -- D14 (same-turn double emit + a settled third). ---
  {
    const t = await makeTarget({ preamble: DEV_PRE_GRANT_SXC, hash: cfg.drill.route });
    if (!t.booted) {
      report(N.d14, false, 'one-shot target did not boot');
    } else {
      await devClick(t.evaluate, '#btn-device-enable');
      await waitDeviceState(t.evaluate, `p.status === 'granted' && p.watching && p.watching.prompt === ${JSON.stringify(cfg.drill.prompt1)}`, 6000);
      const deliveredPair = await t.evaluate(`[${fakeEmitExpr(cfg.drill.good)}, ${fakeEmitExpr(cfg.drill.good)}]`);
      await waitDeviceState(t.evaluate, `p.confirms.some((c) => c.prompt === ${JSON.stringify(cfg.drill.prompt1)})`, 6000);
      await sleep(500);
      const counts = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      const deliveredSettled = await t.evaluate(fakeEmitExpr(cfg.drill.good));
      await sleep(400);
      const countsAfter = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      const progress = await t.evaluate("(document.querySelector('#ex-progress')||{}).textContent");
      report(
        N.d14,
        Array.isArray(deliveredPair) && deliveredPair.every((d) => d >= 1)
          && counts.forPrompt === 1 && counts.forExercise === 1
          && deliveredSettled >= 1
          && countsAfter.forPrompt === 1 && countsAfter.forExercise === 1
          && progress === cfg.drill.progressAfter1,
        { deliveredPair, counts, deliveredSettled, countsAfter, progress },
      );
    }
    await t.close();
  }

  // --- T8: the stale-confirm race -- D15 (manual click + matching bytes
  // in ONE synchronous turn, then a settled stale emit). -----------------
  {
    const t = await makeTarget({ preamble: DEV_PRE_GRANT_SXC, hash: cfg.drill.route });
    if (!t.booted) {
      report(N.d15, false, 'stale-confirm target did not boot');
    } else {
      await devClick(t.evaluate, '#btn-device-enable');
      await waitDeviceState(t.evaluate, `p.status === 'granted' && p.watching && p.watching.prompt === ${JSON.stringify(cfg.drill.prompt1)}`, 6000);
      const raceDelivered = await t.evaluate(`(() => {
        const b = document.querySelector('#btn-ex-confirm-1');
        if (!b) return -1;
        b.click();
        return ${fakeEmitExpr(cfg.drill.good)};
      })()`);
      await waitForTrue(t.evaluate, `(document.querySelector('#ex-progress')||{}).textContent === ${JSON.stringify(cfg.drill.progressAfter1)}`, 6000);
      await sleep(600);
      const counts = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      const deliveredSettled = await t.evaluate(fakeEmitExpr(cfg.drill.good));
      await sleep(400);
      const countsAfter = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      const ds = await readDeviceStateJson(t.evaluate);
      const progress = await t.evaluate("(document.querySelector('#ex-progress')||{}).textContent");
      const confirmsOk = Boolean(ds && Array.isArray(ds.confirms)
        && ds.confirms.length === 1
        && ds.confirms[0].prompt === cfg.drill.prompt1
        && ds.confirms[0].source === 'learner');
      report(
        N.d15,
        raceDelivered >= 1
          && counts.forPrompt === 1 && counts.forExercise === 1
          && deliveredSettled >= 1
          && countsAfter.forPrompt === 1 && countsAfter.forExercise === 1
          && progress === cfg.drill.progressAfter1
          && confirmsOk && sameBytes(ds && ds.lastMessage, cfg.drill.good),
        { raceDelivered, counts, deliveredSettled, countsAfter, progress, confirms: ds && ds.confirms },
      );
    }
    await t.close();
  }

  // --- T9: reconciliation on navigation -- D16. -------------------------
  {
    const t = await makeTarget({ preamble: DEV_PRE_GRANT_SXC, hash: cfg.drill.route });
    if (!t.booted) {
      report(N.d16, false, 'navigation target did not boot');
    } else {
      await devClick(t.evaluate, '#btn-device-enable');
      await waitDeviceState(t.evaluate, `p.status === 'granted' && p.watching && p.watching.prompt === ${JSON.stringify(cfg.drill.prompt1)}`, 6000);
      await t.evaluate("window.location.hash = '#/x'; true");
      const disarmed = await waitDeviceState(t.evaluate, 'p.watching === null', 4000);
      const delivered = await t.evaluate(fakeEmitExpr(cfg.drill.good));
      await waitDeviceState(t.evaluate, `p.lastMessage && p.lastMessage.join(',') === ${JSON.stringify(cfg.drill.good.join(','))}`, 3000);
      await sleep(400);
      const counts = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      report(
        N.d16,
        disarmed === true && delivered >= 1 && counts.forPrompt === 0 && counts.forExercise === 0,
        { disarmed, delivered, counts },
      );
    }
    await t.close();
  }

  // --- T10: zero ports, hot-plug, unplug -- D17 + D18. ------------------
  {
    const t = await makeTarget({ preamble: DEV_PRE_ZERO, hash: cfg.twoStep.route });
    if (!t.booted) {
      report(N.d17, false, 'hot-plug target did not boot');
      report(N.d18, false, 'hot-plug target did not boot');
    } else {
      await devClick(t.evaluate, '#btn-device-enable');
      const grantedZero = await waitDeviceState(t.evaluate, "p.status === 'granted' && p.ports.length === 0", 6000);
      const portsLine = await t.evaluate("(document.querySelector('#device-ports')||{}).textContent");
      await t.evaluate(`(window.__SXC1_FAKE_MIDI ? window.__SXC1_FAKE_MIDI.addPort('sxc1-0', ${JSON.stringify(cfg.sxcPortName)}, 'CASIO') : null)`);
      const rebound = await waitDeviceState(t.evaluate, `p.ports.includes(${JSON.stringify(cfg.sxcPortName)})`, 4000);
      const delivered1 = await t.evaluate(fakeEmitExpr(cfg.twoStep.first));
      const confirmed1 = await waitDeviceState(
        t.evaluate,
        `p.confirms.some((c) => c.prompt === ${JSON.stringify(cfg.twoStep.firstPrompt)} && c.source === 'device')`,
        6000,
      );
      report(
        N.d17,
        grantedZero === true && /No MIDI input detected/.test(portsLine || '')
          && rebound === true && delivered1 >= 1 && confirmed1 === true,
        { grantedZero, portsLine, rebound, delivered1, confirmed1 },
      );

      const armed2 = await waitDeviceState(t.evaluate, `p.watching && p.watching.prompt === ${JSON.stringify(cfg.twoStep.secondPrompt)}`, 4000);
      await t.evaluate("(window.__SXC1_FAKE_MIDI ? window.__SXC1_FAKE_MIDI.removePort('sxc1-0') : null)");
      const emptied = await waitDeviceState(t.evaluate, 'p.ports.length === 0', 4000);
      const stillWatching = await waitDeviceState(t.evaluate, `p.watching && p.watching.prompt === ${JSON.stringify(cfg.twoStep.secondPrompt)}`, 2000);
      const alive = await t.evaluate("(document.querySelector('#ex-progress')||{}).textContent !== ''");
      await t.evaluate(`(window.__SXC1_FAKE_MIDI ? window.__SXC1_FAKE_MIDI.addPort('sxc1-1', ${JSON.stringify(cfg.sxcPortName)}, 'CASIO') : null)`);
      await waitDeviceState(t.evaluate, `p.ports.includes(${JSON.stringify(cfg.sxcPortName)})`, 4000);
      const delivered2 = await t.evaluate(fakeEmitExpr(cfg.twoStep.second));
      const confirmed2 = await waitDeviceState(
        t.evaluate,
        `p.confirms.some((c) => c.prompt === ${JSON.stringify(cfg.twoStep.secondPrompt)} && c.source === 'device')`,
        6000,
      );
      report(
        N.d18,
        armed2 === true && emptied === true && stillWatching === true && alive === true
          && delivered2 >= 1 && confirmed2 === true,
        { armed2, emptied, stillWatching, alive, delivered2, confirmed2 },
      );
    }
    await t.close();
  }

  // --- T11: outcome 'deny' -- D19. --------------------------------------
  {
    const t = await makeTarget({ preamble: DEV_PRE_DENY, hash: cfg.drill.route });
    if (!t.booted) {
      report(N.d19, false, 'deny target did not boot');
    } else {
      await devClick(t.evaluate, '#btn-device-enable');
      const denied = await waitDeviceState(t.evaluate, "p.status === 'denied'", 6000);
      const statusTxt = await t.evaluate("(document.querySelector('#device-status')||{}).textContent");
      const clicked = await devClick(t.evaluate, '#btn-ex-confirm-1');
      const moved = clicked && await waitForTrue(
        t.evaluate,
        `(document.querySelector('#ex-progress')||{}).textContent === ${JSON.stringify(cfg.drill.progressAfter1)}`,
        5000,
      );
      const ds = await readDeviceStateJson(t.evaluate);
      const manualOk = Boolean(ds && ds.confirms.some((c) => c.prompt === cfg.drill.prompt1 && c.source === 'learner'));
      report(
        N.d19,
        denied === true && /denied|access/i.test(statusTxt || '') && moved === true && manualOk,
        { denied, statusTxt, moved, confirms: ds && ds.confirms },
      );
    }
    await t.close();
  }

  // --- T12: NO FAKE AT ALL -- D20 (real headless Chrome denies; proves
  // the fake is load-bearing in every positive assertion above). ---------
  {
    const t = await makeTarget({ injectFake: false, hash: cfg.drill.route });
    if (!t.booted) {
      report(N.d20, false, 'no-fake target did not boot');
    } else {
      const noFake = await t.evaluate("typeof window.__SXC1_FAKE_MIDI === 'undefined'");
      const realApi = await t.evaluate("typeof navigator.requestMIDIAccess === 'function'");
      await devClick(t.evaluate, '#btn-device-enable');
      const denied = await waitDeviceState(t.evaluate, "p.status === 'denied'", 10000);
      await sleep(300);
      const ds = await readDeviceStateJson(t.evaluate);
      const noConfirm = Boolean(ds && Array.isArray(ds.confirms) && ds.confirms.length === 0);
      report(
        N.d20,
        noFake === true && realApi === true && denied === true && noConfirm,
        { noFake, realApi, denied, confirms: ds && ds.confirms },
      );
    }
    await t.close();
  }

  // --- T13: the Network domain armed across a full device scenario --
  // D21 (privacy: MIDI bytes never leave the browser). -------------------
  // M4 gate-2 fix (briefs/M4-codex-gate2.json, finding 3): POST-BOOT
  // ZERO-DELTA, replacing gate-1's asset-shape allowlist (see
  // d21QueryStringEgress's comment for the two query-free channels the
  // allowlist still passed). Window boundaries: the collector is armed
  // from target creation; everything the app legitimately requests
  // (document, index.js, ghc_wasm_jsffi.js, app.wasm, wasi shims, page
  // images) belongs to BOOTING the already-rendered drill route, so
  // after makeTarget's own __SXC1_BOOTED wait the harness additionally
  // waits for the request stream to go QUIET (no new requestWillBeSent
  // for 700ms, capped) and snapshots the count -- scenario start. The
  // whole device scenario (enable click, grant, emit, confirm, settle)
  // then runs, and scenario end is after the confirm settles; the delta
  // over the snapshot must be EMPTY -- no shapes, no exceptions, and no
  // favicon allowance. Measured (this task's report): headless Chrome
  // fetches /favicon.ico exactly ONCE per fresh profile, browser-
  // initiated right after the FIRST page load in that profile (the T1
  // target's -- long before this network-armed target exists), and the
  // event is never attributed to THIS target's session: its boot
  // capture holds exactly the app's own asset requests and its scenario
  // delta is empty. Even a hypothetically session-attributed favicon
  // fires at load completion, inside the quiescence wait, so it would
  // land in the boot capture -- never the scenario window -- which is
  // why NOTHING is permitted there. Anti-vacuity stays on the BOOT-phase
  // capture (bootCount >= 1: the collector demonstrably sees traffic --
  // measured to hold for the file:// fixture's own document request too)
  // since the scenario window now expects zero. Red controls: the
  // 'devSameOriginEgress' / 'devShapedPathEgress' /
  // 'devRepeatAssetEgress' sabotage trio, each of which must turn
  // exactly this assertion red in the --self-test-negative sweep.
  {
    const t = await makeTarget({ preamble: DEV_PRE_GRANT_SXC, hash: cfg.drill.route, network: true });
    if (!t.booted) {
      report(N.d21, false, 'network-armed target did not boot');
    } else {
      let bootCount = t.requests.length;
      {
        const settleDeadline = Date.now() + 8000;
        let quietSince = Date.now();
        while (Date.now() < settleDeadline && Date.now() - quietSince < 700) {
          await sleep(120);
          if (t.requests.length !== bootCount) {
            bootCount = t.requests.length;
            quietSince = Date.now();
          }
        }
      }
      await devClick(t.evaluate, '#btn-device-enable');
      await waitDeviceState(t.evaluate, `p.status === 'granted' && p.watching && p.watching.prompt === ${JSON.stringify(cfg.drill.prompt1)}`, 6000);
      await t.evaluate(fakeEmitExpr(cfg.drill.good));
      await waitDeviceState(t.evaluate, `p.confirms.some((c) => c.prompt === ${JSON.stringify(cfg.drill.prompt1)})`, 6000);
      await sleep(400);
      const scenarioRequests = t.requests.slice(bootCount);
      const queryStringEgress = d21QueryStringEgress(scenarioRequests);
      report(
        N.d21,
        scenarioRequests.length === 0 && bootCount >= 1,
        { bootRequestCount: bootCount,
          scenarioRequestCount: scenarioRequests.length,
          queryStringEgress: queryStringEgress.slice(0, 5),
          scenarioRequests: scenarioRequests.slice(0, 5),
          base: t.baseNoHash },
      );
    }
    await t.close();
  }

  // --- T14: in-flight navigation -- D23 (M4 gate-1 HIGH finding). -------
  // The matching bytes are emitted and the route is changed in the SAME
  // JS turn, so the confirm is in flight across its two queued hops when
  // the navigation happens. The guard-at-application must leave exactly
  // one of the two LEGAL outcomes: the confirmation either completed
  // entirely before the route change was processed (a legitimate hit --
  // navigation does not reset exercise state, so this is
  // indistinguishable from a hit a millisecond earlier), or it was
  // dropped. FORBIDDEN either way: more than one event, an event for the
  // navigated-to exercise, or a watch left armed.
  //
  // MEASURED (this task's report): against the real app the HIT arm is
  // what happens, deterministically. This Miso/wasm runtime drains an
  // entire dispatch chain -- update, its io hops, the actions they
  // dispatch -- SYNCHRONOUSLY within the JS call that triggered it:
  // witnessed by T16 phase B, where the fake's subscribedCount() reads 0
  // immediately after .click() on the disable button (the whole
  // DEnable-with-hub-teardown chain already ran), and by T15/T16 phase
  // A, where the emit's confirm has fully applied before the same-turn
  // click processes. The emit's validation and application are therefore
  // ATOMIC against every same-turn JS sequence -- the two-hop window
  // cannot be interleaved in this runtime, which is the empirical
  // demonstration the gate asked for -- and a route change enters only
  // via the "hashchange" macrotask, after the chain finished. The
  // guard-at-application is asserted at unit level by the fixture, whose
  // mirror queues its two hops through real setTimeouts and reads
  // location.hash synchronously in its guard: under the self-test cfg
  // the drop arm IS deterministic and asserted strictly (forPrompt stays
  // 0), and the mapped 'devConfirmAcrossNav' sabotage turns exactly that
  // red. The app arm pins the measured schedule instead, so a future
  // runtime/scheduler change that OPENS the window flips this assertion
  // loudly rather than silently.
  {
    const t = await makeTarget({ preamble: DEV_PRE_GRANT_SXC, hash: cfg.drill.route });
    if (!t.booted) {
      report(N.d23, false, 'in-flight-navigation target did not boot');
    } else {
      await devClick(t.evaluate, '#btn-device-enable');
      await waitDeviceState(t.evaluate, `p.status === 'granted' && p.watching && p.watching.prompt === ${JSON.stringify(cfg.drill.prompt1)}`, 6000);
      const before = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      const delivered = await t.evaluate(`(() => {
        const d = ${fakeEmitExpr(cfg.drill.good)};
        window.location.hash = ${JSON.stringify(cfg.quizRoute)};
        return d;
      })()`);
      const onQuiz = await waitForTrue(t.evaluate, "document.querySelector('.kind-quiz') !== null", 5000);
      const disarmed = await waitDeviceState(t.evaluate, 'p.watching === null', 4000);
      await sleep(700);
      const after = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      const quizCounts = await deviceEventCounts(t.evaluate, cfg.quizExId, `${cfg.quizExId}#1`);
      const ds = await readDeviceStateJson(t.evaluate);
      const landed = after.forPrompt - before.forPrompt;
      const landedOk = cfg.inflightNavStrict ? landed === 0 : (landed === 0 || landed === 1);
      report(
        N.d23,
        delivered >= 1 && onQuiz === true && disarmed === true
          && landedOk && after.forExercise === after.forPrompt
          && quizCounts.forExercise === 0
          && sameBytes(ds && ds.lastMessage, cfg.drill.good),
        { delivered, onQuiz, disarmed, before, after, quizCounts, lastMessage: ds && ds.lastMessage },
      );
    }
    await t.close();
  }

  // --- T15: in-flight Restart -- D24 (M4 gate-1 HIGH finding). ----------
  // The ordering the promptId-only guard could never catch: Restart
  // lands the cursor back on the very promptId the in-flight confirm
  // captured, so only the ATTEMPT GENERATION can tell the old attempt
  // from the new one. Two phases, both in ONE JS turn each:
  //
  //   Phase A, emit-then-Restart (the gate's literal ordering): in the
  //   app the confirm applies SYNCHRONOUSLY inside emit() (see T14's
  //   measured-schedule comment), so the event lands on the OLD attempt
  //   and the Restart then wipes the state; in the fixture the two
  //   queued hops are still in flight when the synchronous Restart
  //   bumps the generation, and the guard-at-application drops them.
  //   Either way the FRESH attempt must end blank: confirms [] and
  //   progress 1/N -- a stale confirm applying to the fresh attempt is
  //   exactly the corruption the gate named, and the fixture's
  //   'devIgnoreGen' sabotage turns THIS check red on cue.
  //
  //   Phase B, Restart-then-emit: in BOTH arms the Restart has fully
  //   applied (bump + watch replacement under the new generation)
  //   before the emit runs, so the emit legitimately belongs to the NEW
  //   attempt and must confirm it -- exactly one event, source
  //   "device". This is the anti-over-blocking half (a guard that
  //   swallowed everything would fail it) AND the watch-identity check:
  //   an app whose reconciler still keys the watch by promptId alone
  //   (the gate's Main.hs:532 evidence) leaves the OLD generation's
  //   watch armed across the Restart, and the guard then rightly drops
  //   the confirm -- flipping this phase red (measured -- the app-side
  //   red demonstration in this task's report).
  {
    const t = await makeTarget({ preamble: DEV_PRE_GRANT_SXC, hash: cfg.drill.route });
    if (!t.booted) {
      report(N.d24, false, 'in-flight-restart target did not boot');
    } else {
      await devClick(t.evaluate, '#btn-device-enable');
      await waitDeviceState(t.evaluate, `p.status === 'granted' && p.watching && p.watching.prompt === ${JSON.stringify(cfg.drill.prompt1)}`, 6000);
      const before = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      // Phase A: emit, then Restart, same turn.
      const deliveredA = await t.evaluate(`(() => {
        const d = ${fakeEmitExpr(cfg.drill.good)};
        const b = document.querySelector('#btn-ex-restart');
        if (!b) return -100;
        b.click();
        return d;
      })()`);
      const rearmedA = await waitDeviceState(t.evaluate, `p.watching && p.watching.prompt === ${JSON.stringify(cfg.drill.prompt1)}`, 5000);
      await sleep(700);
      const dsA = await readDeviceStateJson(t.evaluate);
      const midA = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      const progressA = await t.evaluate("(document.querySelector('#ex-progress')||{}).textContent");
      const landedA = midA.forPrompt - before.forPrompt;
      const phaseAOk = deliveredA >= 1 && rearmedA === true
        && Boolean(dsA && Array.isArray(dsA.confirms) && dsA.confirms.length === 0)
        && progressA === `1 / ${cfg.drill.steps}`
        && (landedA === 0 || landedA === 1);
      // Phase B: Restart, then emit, same turn -- must confirm the NEW
      // attempt exactly once (see the block comment above).
      const deliveredB = await t.evaluate(`(() => {
        const b = document.querySelector('#btn-ex-restart');
        if (!b) return -100;
        b.click();
        return ${fakeEmitExpr(cfg.drill.good)};
      })()`);
      const confirmedB = await waitDeviceState(
        t.evaluate,
        `p.confirms.some((c) => c.prompt === ${JSON.stringify(cfg.drill.prompt1)} && c.source === 'device')`,
        6000,
      );
      await sleep(500);
      const dsB = await readDeviceStateJson(t.evaluate);
      const midB = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      const progressB = await t.evaluate("(document.querySelector('#ex-progress')||{}).textContent");
      const landedB = midB.forPrompt - midA.forPrompt;
      const confirmsB = (dsB && Array.isArray(dsB.confirms)) ? dsB.confirms : null;
      const phaseBOk = deliveredB >= 1 && confirmedB === true && confirmsB !== null
        && landedB === 1 && confirmsB.length === 1
        && confirmsB[0].prompt === cfg.drill.prompt1 && confirmsB[0].source === 'device'
        && progressB === cfg.drill.progressAfter1;
      report(
        N.d24,
        phaseAOk && phaseBOk,
        { phaseA: { deliveredA, rearmedA, landedA, confirms: dsA && dsA.confirms, progressA },
          phaseB: { deliveredB, confirmedB, landedB, confirmsB, progressB } },
      );
    }
    await t.close();
  }

  // --- T16: in-flight disable -- D25 (M4 gate-1 HIGH finding). ----------
  // Three phases against the disable/re-enable toggle:
  //
  //   Phase A, emit-then-disable (the gate's literal ordering): in the
  //   app the confirm applies SYNCHRONOUSLY inside emit() (T14's
  //   measured schedule) BEFORE the click processes -- a legitimate hit
  //   on the still-armed attempt (disable does NOT reset exercise
  //   state, so step 1 stays confirmed), pinned by cfg
  //   inflightDisableRace 'hit'. The fixture's hops are still in
  //   flight when its synchronous disable bumps the generation, so its
  //   guard-at-application drops them -- cfg 'drop', and the fixture's
  //   'devIgnoreGen' sabotage turns exactly that red. Anything else (a
  //   double event, a half-state) fails both arms.
  //
  //   Phase B, disable-then-emit: MEASURED identical in both arms --
  //   the disable's whole chain, JS teardown included, runs
  //   synchronously inside .click() (the subscribedCount() sample taken
  //   immediately after it reads 0 -- the load-bearing witness for
  //   T14's atomicity argument), so nothing is listening by emit time:
  //   subscribed === 0, delivered === 0, and nothing may land. An app
  //   whose disable left handlers installed (the teardown-skipped
  //   defect class) flips this phase red via the subscribed sample
  //   (measured -- the app-side red demonstration in this task's
  //   report); Device.Midi.onMidiMessage's status check is the
  //   defense-in-depth that keeps even a late-processed message inert
  //   under that defect.
  //
  //   Phase C: re-enable + re-emit confirms the (restarted) attempt --
  //   the recovery half a swallow-everything guard would fail.
  {
    const t = await makeTarget({ preamble: DEV_PRE_GRANT_SXC, hash: cfg.drill.route });
    if (!t.booted) {
      report(N.d25, false, 'in-flight-disable target did not boot');
    } else {
      await devClick(t.evaluate, '#btn-device-enable');
      await waitDeviceState(t.evaluate, `p.status === 'granted' && p.watching && p.watching.prompt === ${JSON.stringify(cfg.drill.prompt1)}`, 6000);
      const before = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      // Phase A: emit, then disable, same turn.
      const deliveredA = await t.evaluate(`(() => {
        const d = ${fakeEmitExpr(cfg.drill.good)};
        const b = document.querySelector('#btn-device-enable');
        if (!b) return -100;
        b.click();
        return d;
      })()`);
      const wentOffA = await waitDeviceState(t.evaluate, "p.status === 'off'", 5000);
      await sleep(700);
      const dsA = await readDeviceStateJson(t.evaluate);
      const midA = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      const landedA = midA.forPrompt - before.forPrompt;
      const confirmsA = (dsA && Array.isArray(dsA.confirms)) ? dsA.confirms : null;
      const phaseAOk = deliveredA >= 1 && wentOffA === true && confirmsA !== null && (
        cfg.inflightDisableRace === 'drop'
          ? (landedA === 0 && confirmsA.length === 0)
          : (landedA === 1 && confirmsA.length === 1
             && confirmsA[0].prompt === cfg.drill.prompt1 && confirmsA[0].source === 'device'));
      // Reset to a fresh, armed attempt: re-enable, then Restart.
      await devClick(t.evaluate, '#btn-device-enable');
      await waitDeviceState(t.evaluate, "p.status === 'granted'", 6000);
      await devClick(t.evaluate, '#btn-ex-restart');
      const rearmed = await waitDeviceState(t.evaluate, `p.status === 'granted' && p.watching && p.watching.prompt === ${JSON.stringify(cfg.drill.prompt1)}`, 6000);
      const base = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      // Phase B: disable, then emit, same turn -- subscribed sampled
      // between the two, as the anti-vacuity witness for each arm.
      const phaseBRace = await t.evaluate(`(() => {
        const b = document.querySelector('#btn-device-enable');
        if (!b) return null;
        b.click();
        const s = ${FAKE_SUBSCRIBED_EXPR};
        const d = ${fakeEmitExpr(cfg.drill.good)};
        return { s, d };
      })()`);
      const wentOffB = await waitDeviceState(t.evaluate, "p.status === 'off'", 5000);
      await sleep(700);
      const dsB = await readDeviceStateJson(t.evaluate);
      const midB = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      const landedB = midB.forPrompt - base.forPrompt;
      const confirmsBOk = Boolean(dsB && Array.isArray(dsB.confirms) && dsB.confirms.length === 0);
      const phaseBOk = phaseBRace !== null && wentOffB === true && landedB === 0 && confirmsBOk
        && phaseBRace.s === 0 && phaseBRace.d === 0;
      // Phase C: re-enable + re-emit confirms again.
      await devClick(t.evaluate, '#btn-device-enable');
      const reArmed = await waitDeviceState(t.evaluate, `p.status === 'granted' && p.watching && p.watching.prompt === ${JSON.stringify(cfg.drill.prompt1)}`, 6000);
      const deliveredC = await t.evaluate(fakeEmitExpr(cfg.drill.good));
      const confirmedC = await waitDeviceState(
        t.evaluate,
        `p.confirms.some((c) => c.prompt === ${JSON.stringify(cfg.drill.prompt1)} && c.source === 'device')`,
        6000,
      );
      const afterC = await deviceEventCounts(t.evaluate, cfg.drill.exId, cfg.drill.prompt1);
      report(
        N.d25,
        phaseAOk && rearmed === true && phaseBOk
          && reArmed === true && deliveredC >= 1 && confirmedC === true
          && afterC.forPrompt === midB.forPrompt + 1,
        { phaseA: { deliveredA, wentOffA, landedA, confirmsA },
          phaseB: { phaseBRace, wentOffB, landedB, confirmsBOk, expected: cfg.inflightDisableRace },
          phaseC: { rearmed, reArmed, deliveredC, confirmedC, base, midB, afterC } },
      );
    }
    await t.close();
  }

  // --- T17 (M5 a11y pass): D26 device-confirm advance focus + D27 device
  // panel SR labels. One fresh grant+SXC-port target on the drill route:
  // enable, wait armed, read the panel's ARIA surface (D27), then emit
  // the matching bytes so the DEVICE path confirms step 1 -- the cursor
  // moves with no user click, and focus must land on the next step's own
  // focus target (#ex-step-2, tabindex="-1") rather than being stranded
  // wherever it was. Anti-vacuity: the emit must report a live handler
  // and the confirm must genuinely land before the focus claim counts.
  {
    const t = await makeTarget({ preamble: DEV_PRE_GRANT_SXC, hash: cfg.drill.route });
    if (!t.booted) {
      report(N.d26, false, 'a11y-scenario target did not boot');
      report(N.d27, false, 'a11y-scenario target did not boot');
    } else {
      await waitForTrue(t.evaluate, "document.querySelector('#btn-device-enable') !== null", 5000);
      await devClick(t.evaluate, '#btn-device-enable');
      const armed = await waitDeviceState(
        t.evaluate,
        `p.status === 'granted' && p.watching && p.watching.prompt === ${JSON.stringify(cfg.drill.prompt1)}`,
        5000,
      );
      const labels = await t.evaluate(`(() => {
        const sel = document.querySelector('#sel-device-channel');
        const st = document.querySelector('#device-status');
        const verify = document.querySelector('.ex-verify');
        return {
          panel: document.querySelector('#ex-device') !== null,
          selLabel: sel ? sel.getAttribute('aria-label') : null,
          statusLive: st ? st.getAttribute('aria-live') : null,
          verifyLive: verify ? verify.getAttribute('aria-live') : null,
        };
      })()`);
      report(
        N.d27,
        Boolean(labels && labels.panel === true
          && typeof labels.selLabel === 'string' && labels.selLabel.length > 0
          && labels.statusLive === 'polite' && labels.verifyLive === 'polite'),
        labels,
      );
      const delivered = armed ? await t.evaluate(fakeEmitExpr(cfg.drill.good)) : -1;
      const confirmed = armed && await waitDeviceState(
        t.evaluate,
        `p.confirms.some((c) => c.prompt === ${JSON.stringify(cfg.drill.prompt1)} && c.source === 'device')`,
        5000,
      );
      const focusObs = await t.evaluate(`(async () => {
        const start = Date.now();
        while (Date.now() - start < 3000) {
          const a = document.activeElement;
          if (a && a.id === 'ex-step-2') return { ok: true, id: a.id };
          await new Promise((r) => setTimeout(r, 25));
        }
        const a = document.activeElement;
        return { ok: false, got: a ? (a.id || a.tagName) : null, isBody: a === document.body };
      })()`);
      report(
        N.d26,
        Boolean(armed && delivered >= 1 && confirmed === true && focusObs && focusObs.ok === true),
        { armed, delivered, confirmed, focusObs },
      );
    }
    await t.close();
  }

  // --- D22: the fake is never shipped. ----------------------------------
  {
    const found = [];
    const walk = (dir) => {
      let entries;
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const e of entries) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p);
        else if (e.name === 'fake-midi.js') found.push(p);
      }
    };
    walk(path.join(HARNESS_REPO_ROOT, 'site', 'public'));
    walk(path.join(HARNESS_REPO_ROOT, 'site', 'static'));
    report(N.d22, found.length === 0, { found });
  }
}

// ---------------------------------------------------------------------------
// --self-test / --self-test-negative: launches its OWN throwaway browser
// (independent of --url and of any static file server -- the fixture is
// a data: URL, so there is nothing to serve), navigates to the fixture
// built by selfTestFixtureHtml(), and runs runExerciseAssertions()
// against it -- the SAME function a real run drives against the real
// app via --exercise-fixture. `negative` selects the sabotaged grader
// and the negative-control exit-code rule (see below).
// ---------------------------------------------------------------------------

// M3 harness wave, negative control c3 ("storage refused"): a standalone
// diagnostic, NOT part of the ordinary pass/fail run and NOT invoked by
// check-site.sh -- see --check-storage-refused's own --help text for the
// full rationale, and this task's final report for what running this
// against the real app actually shows. Launches its own throwaway
// browser (same idiom as runSelfTest), injects a script BEFORE the
// page's own via Page.addScriptToEvaluateOnNewDocument that makes
// window.localStorage's setItem/getItem/removeItem all throw --
// window.localStorage itself stays present and accessible, matching
// Progress.Store's own Haddock ("a private-mode browser can expose
// window.localStorage and still throw on the first write") -- then
// navigates to --url and reports what actually happens: the app is
// expected to boot and #sxc1-progress to report "available":false
// (Progress.Store.storageAvailable's guarded probe catching the throw),
// never a crash.
async function runStorageRefusedCheck(opts) {
  const deadline = Date.now() + opts.timeout;
  const cleanupFns = [];
  const runCleanup = async () => {
    for (const fn of cleanupFns.splice(0).reverse()) {
      try { await fn(); } catch { /* best-effort cleanup */ }
    }
  };
  const die = async (code, message) => {
    if (message) console.log(message);
    await runCleanup();
    process.exit(code);
  };

  const browserPath = resolveBrowser(opts.browser);
  if (!browserPath) {
    await die(2, 'error: no browser found for --check-storage-refused. Install Google Chrome/Chromium, or set ' +
      'SXC1_BROWSER to a browser executable path, or pass --browser <path>.');
    return;
  }

  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sxc1-storagerefused-profile-'));
  cleanupFns.push(() => removeDirWithRetry(userDataDir));
  const debugPort = await findFreePort();
  const browserArgs = [
    '--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run', '--no-default-browser-check',
    '--disable-dev-shm-usage', `--user-data-dir=${userDataDir}`, `--remote-debugging-port=${debugPort}`, 'about:blank',
  ];
  const browserProc = spawn(browserPath, browserArgs, { stdio: 'ignore', detached: true });
  let cdp = null;
  let browserFailure = null;
  const noteBrowserFailure = (message) => {
    if (!browserFailure) browserFailure = new Error(message);
    if (cdp) cdp.failFatally(browserFailure);
  };
  browserProc.on('exit', (code, signal) => {
    noteBrowserFailure(`browser process exited unexpectedly (code=${code === null ? 'null' : code}, signal=${signal || 'none'})`);
  });
  browserProc.on('error', (err) => {
    noteBrowserFailure(`browser process error: ${err && err.message ? err.message : err}`);
  });
  cleanupFns.push(() => new Promise((resolve) => {
    const killGroup = (signal) => { try { process.kill(-browserProc.pid, signal); } catch { /* group already gone */ } };
    if (browserProc.exitCode !== null || browserProc.signalCode !== null) { killGroup('SIGKILL'); resolve(); return; }
    const forceKillTimer = setTimeout(() => killGroup('SIGKILL'), 3000);
    browserProc.once('exit', () => { clearTimeout(forceKillTimer); killGroup('SIGKILL'); resolve(); });
    killGroup('SIGTERM');
  }));

  let versionInfo = null;
  while (Date.now() < deadline) {
    if (browserFailure) {
      await die(2, `error: ${browserFailure.message} (before DevTools became reachable at ${browserPath})`);
      return;
    }
    try {
      const info = await withDeadline(
        httpGetJson(`http://127.0.0.1:${debugPort}/json/version`),
        deadline,
        'DevTools /json/version request',
      );
      if (info && info.webSocketDebuggerUrl) { versionInfo = info; break; }
    } catch { /* not up yet, or this attempt ran past the deadline */ }
    await sleep(200);
  }
  if (!versionInfo) {
    await die(2, 'error: timed out waiting for DevTools (--check-storage-refused)');
    return;
  }

  const ws = await withDeadline(connectWebSocket(versionInfo.webSocketDebuggerUrl), deadline, 'WebSocket connect');
  cleanupFns.push(() => { try { ws.close(); } catch { /* ignore */ } });
  cdp = new CDPClient(ws, { getRemaining: () => remaining(deadline) });
  ws.addEventListener('close', () => cdp.failFatally(new Error('CDP WebSocket closed unexpectedly')));
  ws.addEventListener('error', (ev) => cdp.failFatally(new Error(`CDP WebSocket error: ${formatWsErrorEvent(ev)}`)));

  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
  await cdp.send('Page.enable', {}, sessionId);
  await cdp.send('Runtime.enable', {}, sessionId);

  await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
    source: `
      var sxc1RealStorage = window.localStorage;
      var sxc1Thrower = function () { throw new DOMException('SXC1 test: storage refused', 'QuotaExceededError'); };
      Object.defineProperty(window, 'localStorage', {
        configurable: true,
        get: function () {
          return { setItem: sxc1Thrower, getItem: sxc1Thrower, removeItem: sxc1Thrower, clear: sxc1Thrower, key: sxc1Thrower, length: 0 };
        }
      });
    `,
  }, sessionId);

  const evaluate = async (expression) => {
    const res = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, sessionId);
    if (res.exceptionDetails) {
      const d = res.exceptionDetails;
      throw new Error(`page evaluation error: ${d.exception?.description || d.text}`);
    }
    return res.result ? res.result.value : undefined;
  };

  await cdp.send('Page.navigate', { url: opts.url }, sessionId);

  let bootOutcome = null;
  while (Date.now() < deadline) {
    let state;
    try {
      state = await evaluate(`(() => {
        if (typeof window.__SXC1_BOOT_ERROR === 'string') return { error: window.__SXC1_BOOT_ERROR };
        if (window.__SXC1_BOOTED === true) return { booted: true };
        return { pending: true };
      })()`);
    } catch (err) {
      state = { error: `evaluate failed: ${err && err.message ? err.message : err}` };
    }
    if (state.error) { bootOutcome = { ok: false, error: state.error }; break; }
    if (state.booted) { bootOutcome = { ok: true }; break; }
    await sleep(100);
  }

  const NAME = PROGRESS_ASSERTION_NAMES.storageRefusedAvailableFalse;

  if (!bootOutcome) {
    console.log(`FAIL - ${NAME} (observed: timed out waiting for boot or an error)`);
    await die(1, null);
    return;
  }
  if (!bootOutcome.ok) {
    console.log(`FAIL - ${NAME} (observed: the app did NOT boot -- window.__SXC1_BOOT_ERROR = ${JSON.stringify(bootOutcome.error)})`);
    console.log('       This is a REAL, reproducible finding, not a harness bug: forcing window.localStorage.setItem/getItem/removeItem to throw (while leaving');
    console.log('       window.localStorage itself present, matching real private-mode behaviour) makes the app fail to boot instead of gracefully falling back');
    console.log('       to available:false. Progress.Store.storageAvailable is documented to guard exactly this case (guarded = try); this run is evidence that,');
    console.log('       against a real thrown JS exception from a foreign-import call, the app does not currently degrade gracefully. Out of scope for scripts/');
    console.log('       (site/app/Progress/Store.hs is owned by task "storage-sink") -- reported here as this negative control\'s actual, reproducible result.');
    await die(1, null);
    return;
  }

  const payloadRaw = await evaluate(`(() => { const e = document.querySelector('#sxc1-progress'); return e ? e.textContent : null; })()`);
  let payload = null;
  try { payload = JSON.parse(payloadRaw); } catch { /* reported below */ }
  const ok = Boolean(payload && payload.available === false);
  if (ok) {
    console.log(`ok - ${NAME}`);
    await die(0, null);
  } else {
    console.log(`FAIL - ${NAME} (observed: booted, but #sxc1-progress = ${payloadRaw})`);
    await die(1, null);
  }
}

// ---------------------------------------------------------------------------
// M6 W1: --check-content-missing. Driven by check-site.sh's fetch-failure
// degradation stage against a served COPY of the bundle whose content/
// directory has been removed (so ./content/content.en.txt 404s). Four
// named assertions, all required:
//   1. the app still BOOTS -- the JS-side content guard in
//      site/static/index.js must swallow the failed load (a rethrow
//      kills boot exactly like the pre-bridge storage defect, and this
//      mode reports it as its own FAIL -- the red-first demonstration);
//   2. the VISIBLE #sxc1-content-error banner is rendered and names the
//      failure (non-empty, mentions 'content');
//   3. the manuals still work: a real manual page route renders its
//      translated body (the manuals stay embedded in app.wasm);
//   4. the exercise routes render the degraded notice with the
//      #btn-content-retry affordance instead of an empty index.
// Same launch idiom as --check-storage-refused; no script injection --
// the served bundle itself is the broken input.
// ---------------------------------------------------------------------------
async function runContentMissingCheck(opts) {
  const deadline = Date.now() + opts.timeout;
  const cleanupFns = [];
  const runCleanup = async () => {
    for (const fn of cleanupFns.splice(0).reverse()) {
      try { await fn(); } catch { /* best-effort cleanup */ }
    }
  };
  const die = async (code, message) => {
    if (message) console.log(message);
    await runCleanup();
    process.exit(code);
  };

  const browserPath = resolveBrowser(opts.browser);
  if (!browserPath) {
    await die(2, 'error: no browser found for --check-content-missing. Install Google Chrome/Chromium, or set ' +
      'SXC1_BROWSER to a browser executable path, or pass --browser <path>.');
    return;
  }

  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sxc1-contentmissing-profile-'));
  cleanupFns.push(() => removeDirWithRetry(userDataDir));
  const debugPort = await findFreePort();
  const browserProc = spawn(browserPath, [
    '--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run', '--no-default-browser-check',
    '--disable-dev-shm-usage', `--user-data-dir=${userDataDir}`, `--remote-debugging-port=${debugPort}`, 'about:blank',
  ], { stdio: 'ignore', detached: true });
  let cdp = null;
  let browserFailure = null;
  const noteBrowserFailure = (message) => {
    if (!browserFailure) browserFailure = new Error(message);
    if (cdp) cdp.failFatally(browserFailure);
  };
  browserProc.on('exit', (code, signal) => {
    noteBrowserFailure(`browser process exited unexpectedly (code=${code === null ? 'null' : code}, signal=${signal || 'none'})`);
  });
  browserProc.on('error', (err) => {
    noteBrowserFailure(`browser process error: ${err && err.message ? err.message : err}`);
  });
  cleanupFns.push(() => new Promise((resolve) => {
    const killGroup = (signal) => { try { process.kill(-browserProc.pid, signal); } catch { /* group already gone */ } };
    if (browserProc.exitCode !== null || browserProc.signalCode !== null) { killGroup('SIGKILL'); resolve(); return; }
    const forceKillTimer = setTimeout(() => killGroup('SIGKILL'), 3000);
    browserProc.once('exit', () => { clearTimeout(forceKillTimer); killGroup('SIGKILL'); resolve(); });
    killGroup('SIGTERM');
  }));

  let versionInfo = null;
  while (Date.now() < deadline) {
    if (browserFailure) {
      await die(2, `error: ${browserFailure.message} (before DevTools became reachable at ${browserPath})`);
      return;
    }
    try {
      const info = await withDeadline(
        httpGetJson(`http://127.0.0.1:${debugPort}/json/version`),
        deadline,
        'DevTools /json/version request',
      );
      if (info && info.webSocketDebuggerUrl) { versionInfo = info; break; }
    } catch { /* not up yet, or this attempt ran past the deadline */ }
    await sleep(200);
  }
  if (!versionInfo) {
    await die(2, 'error: timed out waiting for DevTools (--check-content-missing)');
    return;
  }

  const ws = await withDeadline(connectWebSocket(versionInfo.webSocketDebuggerUrl), deadline, 'WebSocket connect');
  cleanupFns.push(() => { try { ws.close(); } catch { /* ignore */ } });
  cdp = new CDPClient(ws, { getRemaining: () => remaining(deadline) });
  ws.addEventListener('close', () => cdp.failFatally(new Error('CDP WebSocket closed unexpectedly')));
  ws.addEventListener('error', (ev) => cdp.failFatally(new Error(`CDP WebSocket error: ${formatWsErrorEvent(ev)}`)));

  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
  await cdp.send('Page.enable', {}, sessionId);
  await cdp.send('Runtime.enable', {}, sessionId);

  const evaluate = async (expression) => {
    const res = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, sessionId);
    if (res.exceptionDetails) {
      const d = res.exceptionDetails;
      throw new Error(`page evaluation error: ${d.exception?.description || d.text}`);
    }
    return res.result ? res.result.value : undefined;
  };

  await cdp.send('Page.navigate', { url: opts.url }, sessionId);

  let bootOutcome = null;
  while (Date.now() < deadline) {
    let state;
    try {
      state = await evaluate(`(() => {
        if (typeof window.__SXC1_BOOT_ERROR === 'string') return { error: window.__SXC1_BOOT_ERROR };
        if (window.__SXC1_BOOTED === true) return { booted: true };
        return { pending: true };
      })()`);
    } catch (err) {
      state = { error: `evaluate failed: ${err && err.message ? err.message : err}` };
    }
    if (state.error) { bootOutcome = { ok: false, error: state.error }; break; }
    if (state.booted) { bootOutcome = { ok: true }; break; }
    await sleep(100);
  }

  let passed = 0;
  let total = 0;
  const report = (name, ok, observed) => {
    total += 1;
    if (ok) { passed += 1; console.log(`ok - ${name}`); }
    else { console.log(`FAIL - ${name} (observed: ${JSON.stringify(observed)})`); }
  };
  const NAMES = {
    boots: 'content missing: the app still boots (the JS-side content guard never lets a failed bundle load kill boot)',
    banner: 'content missing: the VISIBLE #sxc1-content-error banner is rendered and names the failure',
    manual: 'content missing: a manual page route still renders its translated body (manuals stay embedded)',
    retry: 'content missing: the exercise route renders the degraded notice with #btn-content-retry',
  };

  if (!bootOutcome || !bootOutcome.ok) {
    report(NAMES.boots, false,
      bootOutcome && bootOutcome.error
        ? { bootError: bootOutcome.error }
        : { timeout: true });
    for (const name of [NAMES.banner, NAMES.manual, NAMES.retry]) {
      report(name, false, 'skipped: app did not boot');
    }
    console.log(`browser-check --check-content-missing: ${passed}/${total} assertions passed`);
    await die(1, null);
    return;
  }
  report(NAMES.boots, true, null);

  const banner = await evaluate(`(() => {
    const e = document.querySelector('#sxc1-content-error');
    if (!e) return { exists: false };
    return {
      exists: true,
      visible: !e.hidden && e.offsetParent !== null,
      role: e.getAttribute('role'),
      text: (e.textContent || '').trim(),
    };
  })()`);
  report(
    NAMES.banner,
    Boolean(banner && banner.exists && banner.visible && banner.role === 'alert'
      && banner.text.length > 0 && /content/i.test(banner.text)),
    banner,
  );

  const manualOk = await evaluate(`(async () => {
    window.location.hash = '#/m/guide-book/p/15';
    const start = Date.now();
    while (Date.now() - start < 8000) {
      const body = document.querySelector('#sxc1-page .page-body');
      if (body && body.textContent && body.textContent.trim().length > 100) {
        return { ok: true, chars: body.textContent.trim().length };
      }
      await new Promise((r) => setTimeout(r, 50));
    }
    const body = document.querySelector('#sxc1-page .page-body');
    return { ok: false, chars: body && body.textContent ? body.textContent.trim().length : null };
  })()`);
  report(NAMES.manual, Boolean(manualOk && manualOk.ok), manualOk);

  const retryOk = await evaluate(`(async () => {
    window.location.hash = '#/x';
    const start = Date.now();
    while (Date.now() - start < 8000) {
      const deg = document.querySelector('#sxc1-exercise-degraded');
      const btn = document.querySelector('#btn-content-retry');
      if (deg && btn) {
        return { ok: true, text: (deg.textContent || '').slice(0, 160) };
      }
      await new Promise((r) => setTimeout(r, 50));
    }
    return {
      ok: false,
      degraded: document.querySelector('#sxc1-exercise-degraded') !== null,
      retry: document.querySelector('#btn-content-retry') !== null,
    };
  })()`);
  report(NAMES.retry, Boolean(retryOk && retryOk.ok), retryOk);

  console.log(`browser-check --check-content-missing: ${passed}/${total} assertions passed`);
  await die(passed === total ? 0 : 1, null);
}

// ---------------------------------------------------------------------------
// M6 gate round 1 (briefs/M6-codex-gate1.json, findings M6-R1-1 and
// M6-R1-5): the two BAD-INPUT modes below drive several fresh targets
// each, so the browser boilerplate every other mode inlines is factored
// out here ONCE. Behaviour is identical to --check-content-missing's
// (same flags, same DevTools wait, same group kill), and like that mode
// NOTHING is injected into the page: the SERVED BYTES (or the server's
// own behaviour) are the input under test.
// ---------------------------------------------------------------------------
async function openCheckSession(opts, modeName, deadline) {
  const cleanupFns = [];
  const runCleanup = async () => {
    for (const fn of cleanupFns.splice(0).reverse()) {
      try { await fn(); } catch { /* best-effort cleanup */ }
    }
  };
  const die = async (code, message) => {
    if (message) console.log(message);
    await runCleanup();
    process.exit(code);
  };

  const browserPath = resolveBrowser(opts.browser);
  if (!browserPath) {
    await die(2, `error: no browser found for ${modeName}. Install Google Chrome/Chromium, or set ` +
      'SXC1_BROWSER to a browser executable path, or pass --browser <path>.');
  }

  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sxc1-badbundle-profile-'));
  cleanupFns.push(() => removeDirWithRetry(userDataDir));
  const debugPort = await findFreePort();
  const browserProc = spawn(browserPath, [
    '--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run', '--no-default-browser-check',
    '--disable-dev-shm-usage', `--user-data-dir=${userDataDir}`, `--remote-debugging-port=${debugPort}`, 'about:blank',
  ], { stdio: 'ignore', detached: true });
  let cdp = null;
  let browserFailure = null;
  const noteBrowserFailure = (message) => {
    if (!browserFailure) browserFailure = new Error(message);
    if (cdp) cdp.failFatally(browserFailure);
  };
  browserProc.on('exit', (code, signal) => {
    noteBrowserFailure(`browser process exited unexpectedly (code=${code === null ? 'null' : code}, signal=${signal || 'none'})`);
  });
  browserProc.on('error', (err) => {
    noteBrowserFailure(`browser process error: ${err && err.message ? err.message : err}`);
  });
  cleanupFns.push(() => new Promise((resolve) => {
    const killGroup = (signal) => { try { process.kill(-browserProc.pid, signal); } catch { /* group already gone */ } };
    if (browserProc.exitCode !== null || browserProc.signalCode !== null) { killGroup('SIGKILL'); resolve(); return; }
    const forceKillTimer = setTimeout(() => killGroup('SIGKILL'), 3000);
    browserProc.once('exit', () => { clearTimeout(forceKillTimer); killGroup('SIGKILL'); resolve(); });
    killGroup('SIGTERM');
  }));

  let versionInfo = null;
  while (Date.now() < deadline) {
    if (browserFailure) {
      await die(2, `error: ${browserFailure.message} (before DevTools became reachable at ${browserPath})`);
      return null;
    }
    try {
      const info = await withDeadline(
        httpGetJson(`http://127.0.0.1:${debugPort}/json/version`),
        deadline,
        'DevTools /json/version request',
      );
      if (info && info.webSocketDebuggerUrl) { versionInfo = info; break; }
    } catch { /* not up yet, or this attempt ran past the deadline */ }
    await sleep(200);
  }
  if (!versionInfo) {
    await die(2, `error: timed out waiting for DevTools (${modeName})`);
    return null;
  }

  const ws = await withDeadline(connectWebSocket(versionInfo.webSocketDebuggerUrl), deadline, 'WebSocket connect');
  cleanupFns.push(() => { try { ws.close(); } catch { /* ignore */ } });
  cdp = new CDPClient(ws, { getRemaining: () => remaining(deadline) });
  ws.addEventListener('close', () => cdp.failFatally(new Error('CDP WebSocket closed unexpectedly')));
  ws.addEventListener('error', (ev) => cdp.failFatally(new Error(`CDP WebSocket error: ${formatWsErrorEvent(ev)}`)));

  // One genuinely fresh target per case (fresh document, fresh boot).
  const newTarget = async (url, bootBudgetMs) => {
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    await cdp.send('Page.enable', {}, sessionId);
    await cdp.send('Runtime.enable', {}, sessionId);
    const evaluate = async (expression) => {
      const res = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, sessionId);
      if (res.exceptionDetails) {
        const d = res.exceptionDetails;
        throw new Error(`page evaluation error: ${d.exception?.description || d.text}`);
      }
      return res.result ? res.result.value : undefined;
    };
    const startedAt = Date.now();
    await cdp.send('Page.navigate', { url }, sessionId);
    let outcome = { ok: false, timeout: true };
    const bootDeadline = Math.min(deadline, Date.now() + bootBudgetMs);
    while (Date.now() < bootDeadline) {
      let state;
      try {
        state = await evaluate(`(() => {
          if (typeof window.__SXC1_BOOT_ERROR === 'string') return { error: window.__SXC1_BOOT_ERROR };
          if (window.__SXC1_BOOTED === true) return { booted: true };
          return { pending: true };
        })()`);
      } catch (err) {
        state = { pending: true };   // document may still be navigating
      }
      if (state && state.error) { outcome = { ok: false, error: state.error }; break; }
      if (state && state.booted) { outcome = { ok: true }; break; }
      await sleep(100);
    }
    return {
      boot: outcome,
      bootMs: Date.now() - startedAt,
      evaluate,
      close: async () => { try { await cdp.send('Target.closeTarget', { targetId }); } catch { /* best effort */ } },
    };
  };

  return { cdp, die, newTarget };
}

// ---------------------------------------------------------------------------
// M6 gate round 1 (finding M6-R1-1): --check-bad-bundle. Five separately
// sabotaged copies of the SHIPPED bundle -- each served at the correct
// URL with a 200 -- must every one of them produce the VISIBLE
// content-error state, never a smaller-but-"healthy" course:
//
//   wrong-language  the ja bundle served at ./content/content.en.txt
//   stale           one deck's TEXT altered (framing untouched)
//   truncated       the last deck's body cut, every !SXC1-DECK delimiter
//                   still present and the header count still right
//   zero-deck       "!SXC1-BUNDLE v1 en 0" and nothing else
//   missing-deck    one whole deck removed, header count adjusted to match
//
// plus a HEALTHY control served from the same server in the same run --
// the anti-vacuity floor: if the app rejected everything (or the pages
// simply failed to load), the control fails too. check-site.sh builds
// the six directories; this mode never injects anything.
//
// Each case asserts BOTH halves, because "no partial course" is the
// actual claim: the visible role=alert banner AND #sxc1-exercise-stats
// reporting zero decks with the degraded #/x notice.
// ---------------------------------------------------------------------------
const BAD_BUNDLE_CASES = [
  { dir: 'wrong-language', why: 'the ja bundle served at the en URL' },
  { dir: 'stale', why: "one deck's text altered, framing untouched" },
  { dir: 'truncated', why: 'the final deck truncated with every delimiter still present' },
  { dir: 'zero-deck', why: 'a syntactically perfect zero-deck bundle' },
  { dir: 'missing-deck', why: 'one whole deck removed, header count adjusted' },
];
const BAD_BUNDLE_HEALTHY_DIR = 'healthy';
const BAD_BUNDLE_EXPECT_DECKS = 52;
const BAD_BUNDLE_EXPECT_EXERCISES = 435;

async function runBadBundleCheck(opts) {
  const deadline = Date.now() + opts.timeout;
  const session = await openCheckSession(opts, '--check-bad-bundle', deadline);
  if (!session) return;
  const { die, newTarget } = session;

  let passed = 0;
  let total = 0;
  const report = (name, ok, observed) => {
    total += 1;
    if (ok) { passed += 1; console.log(`ok - ${name}`); }
    else { console.log(`FAIL - ${name} (observed: ${JSON.stringify(observed)})`); }
  };

  const baseNoHash = opts.url.replace(/#.*$/, '').replace(/\/$/, '');

  // What the running app says about itself: the visible banner, the
  // machine-readable stats payload, and the degraded exercise route.
  const surfaceOf = async (evaluate) => evaluate(`(async () => {
    window.location.hash = '#/x';
    const start = Date.now();
    while (Date.now() - start < 8000) {
      if (document.querySelector('#sxc1-exercise-degraded') || document.querySelector('.deck-card, #sxc1-exercise-index, #sxc1-exercises')) break;
      await new Promise((r) => setTimeout(r, 50));
    }
    const banner = document.querySelector('#sxc1-content-error');
    const stats = document.querySelector('#sxc1-exercise-stats');
    let totals = null;
    try { totals = JSON.parse(stats ? stats.textContent : 'null').totals; } catch (e) { totals = null; }
    return {
      bannerExists: banner !== null,
      bannerVisible: banner !== null && !banner.hidden && banner.offsetParent !== null,
      bannerRole: banner ? banner.getAttribute('role') : null,
      bannerText: banner ? (banner.textContent || '').trim().slice(0, 200) : '',
      totals,
      degraded: document.querySelector('#sxc1-exercise-degraded') !== null,
      retry: document.querySelector('#btn-content-retry') !== null,
      deckLinks: document.querySelectorAll('a[href^="#/x/"]').length,
    };
  })()`);

  for (const c of BAD_BUNDLE_CASES) {
    const alertName = `bad bundle (${c.dir}): a 200 response carrying ${c.why} produces the VISIBLE #sxc1-content-error alert`;
    const emptyName = `bad bundle (${c.dir}): no partial course -- zero decks in #sxc1-exercise-stats and the degraded #/x notice with #btn-content-retry`;
    const t = await newTarget(`${baseNoHash}/${c.dir}/`, 30000);
    if (!t.boot.ok) {
      report(alertName, false, t.boot);
      report(emptyName, false, 'skipped: app did not boot');
      await t.close();
      continue;
    }
    let s = null;
    try { s = await surfaceOf(t.evaluate); } catch (err) { s = { error: String(err && err.message ? err.message : err) }; }
    report(
      alertName,
      Boolean(s && s.bannerExists && s.bannerVisible && s.bannerRole === 'alert' && s.bannerText.length > 0),
      s,
    );
    report(
      emptyName,
      Boolean(s && s.totals && s.totals.decks === 0 && s.totals.exercises === 0 && s.degraded && s.retry),
      s,
    );
    await t.close();
  }

  // The control, from the same server, in the same run.
  const healthyAlertName = 'bad bundle (healthy control): the UNSABOTAGED copy renders NO #sxc1-content-error banner at all';
  const healthyCourseName = `bad bundle (healthy control): the unsabotaged copy renders the whole course (${BAD_BUNDLE_EXPECT_DECKS} decks / ${BAD_BUNDLE_EXPECT_EXERCISES} exercises, deck links present, no degraded notice)`;
  const h = await newTarget(`${baseNoHash}/${BAD_BUNDLE_HEALTHY_DIR}/`, 30000);
  if (!h.boot.ok) {
    report(healthyAlertName, false, h.boot);
    report(healthyCourseName, false, 'skipped: app did not boot');
  } else {
    let s = null;
    try { s = await surfaceOf(h.evaluate); } catch (err) { s = { error: String(err && err.message ? err.message : err) }; }
    report(healthyAlertName, Boolean(s && s.bannerExists === false), s);
    report(
      healthyCourseName,
      Boolean(s && s.totals && s.totals.decks === BAD_BUNDLE_EXPECT_DECKS
        && s.totals.exercises === BAD_BUNDLE_EXPECT_EXERCISES && s.deckLinks > 0 && !s.degraded),
      s,
    );
  }
  await h.close();

  console.log(`browser-check --check-bad-bundle: ${passed}/${total} assertions passed`);
  await die(passed === total ? 0 : 1, null);
}

// ---------------------------------------------------------------------------
// M6 gate round 1 (finding M6-R1-5): --check-content-stalled. The
// content fetch used to have no deadline, so a server that accepts the
// connection and never completes the body blocked hs_start forever --
// no app, no manuals, no retry, only the static loading state. The
// stage's server answers ./content/content.en.txt by sending 200 +
// headers and then nothing, forever; everything else is served
// normally. The app must boot anyway, inside the deadline
// site/static/index.js arms (SXC1_CONTENT_TIMEOUT_MS), and show the
// ordinary degraded surface. No injection: the SERVER is the input.
// ---------------------------------------------------------------------------
const STALL_BOOT_BUDGET_MS = 45000;

async function runContentStalledCheck(opts) {
  const deadline = Date.now() + opts.timeout;
  const session = await openCheckSession(opts, '--check-content-stalled', deadline);
  if (!session) return;
  const { die, newTarget } = session;

  let passed = 0;
  let total = 0;
  const report = (name, ok, observed) => {
    total += 1;
    if (ok) { passed += 1; console.log(`ok - ${name}`); }
    else { console.log(`FAIL - ${name} (observed: ${JSON.stringify(observed)})`); }
  };
  const NAMES = {
    boots: `content stalled: the app boots within ${STALL_BOOT_BUDGET_MS}ms even though the bundle response never completes (the fetch deadline, not the server, ends the wait)`,
    banner: 'content stalled: the VISIBLE #sxc1-content-error banner names the timeout',
    manual: 'content stalled: a manual page still renders its translated body (manuals stay embedded)',
    retry: 'content stalled: the exercise route renders the degraded notice with #btn-content-retry',
  };

  const t = await newTarget(opts.url, STALL_BOOT_BUDGET_MS);
  if (!t.boot.ok) {
    report(NAMES.boots, false, t.boot);
    for (const n of [NAMES.banner, NAMES.manual, NAMES.retry]) report(n, false, 'skipped: app did not boot');
    console.log(`browser-check --check-content-stalled: ${passed}/${total} assertions passed`);
    await die(1, null);
    return;
  }
  report(NAMES.boots, true, { bootMs: t.bootMs });

  const banner = await t.evaluate(`(() => {
    const e = document.querySelector('#sxc1-content-error');
    if (!e) return { exists: false };
    return {
      exists: true,
      visible: !e.hidden && e.offsetParent !== null,
      role: e.getAttribute('role'),
      text: (e.textContent || '').trim(),
    };
  })()`);
  report(
    NAMES.banner,
    Boolean(banner && banner.exists && banner.visible && banner.role === 'alert'
      && /timed out|deadline/i.test(banner.text)),
    banner,
  );

  const manualOk = await t.evaluate(`(async () => {
    window.location.hash = '#/m/guide-book/p/15';
    const start = Date.now();
    while (Date.now() - start < 8000) {
      const body = document.querySelector('#sxc1-page .page-body');
      if (body && body.textContent && body.textContent.trim().length > 100) {
        return { ok: true, chars: body.textContent.trim().length };
      }
      await new Promise((r) => setTimeout(r, 50));
    }
    return { ok: false };
  })()`);
  report(NAMES.manual, Boolean(manualOk && manualOk.ok), manualOk);

  const retryOk = await t.evaluate(`(async () => {
    window.location.hash = '#/x';
    const start = Date.now();
    while (Date.now() - start < 8000) {
      if (document.querySelector('#sxc1-exercise-degraded') && document.querySelector('#btn-content-retry')) return { ok: true };
      await new Promise((r) => setTimeout(r, 50));
    }
    return { ok: false };
  })()`);
  report(NAMES.retry, Boolean(retryOk && retryOk.ok), retryOk);
  await t.close();

  console.log(`browser-check --check-content-stalled: ${passed}/${total} assertions passed`);
  await die(passed === total ? 0 : 1, null);
}

// ---------------------------------------------------------------------------
// M6 gate round 1 (finding M6-R1-4): --check-hint-write-failure. The
// static shell picks the content bundle (and document.documentElement
// .lang) from the pre-boot sxc1.uilang HINT, while the app renders every
// string from the decoded prefs blob. Main used to DISCARD the hint
// write's result and reload unconditionally, so a successful prefs write
// followed by a failed hint write reloaded with the OLD hint: Japanese UI
// over an English course (or the inverse) for the whole session, with
// nothing on screen saying so.
//
// This mode injects the narrowest possible failure -- Storage.prototype
// .setItem throws for the key "sxc1.uilang" and ONLY that key, so every
// other write still lands, which is exactly the partial-failure shape
// (per-key quota, a revoked key) the finding describes -- then clicks
// #btn-ui-lang once and requires: no reload, honest storage degradation,
// a VISIBLE #sxc1-lang-split alert naming both languages, and
// document.documentElement.lang following the in-memory switch.
// ---------------------------------------------------------------------------
const HINT_BLOCK_SCRIPT = `(() => {
  try {
    const origSet = Storage.prototype.setItem;
    Storage.prototype.setItem = function (k, v) {
      if (k === 'sxc1.uilang') {
        window.__SXC1_HINT_WRITES_BLOCKED = (window.__SXC1_HINT_WRITES_BLOCKED || 0) + 1;
        throw new DOMException('QuotaExceededError (simulated, sxc1.uilang only)', 'QuotaExceededError');
      }
      return origSet.call(this, k, v);
    };
  } catch (e) { /* nothing we can do; the assertions below will say so */ }
})();`;

async function runHintWriteFailureCheck(opts) {
  const deadline = Date.now() + opts.timeout;
  const session = await openCheckSession(opts, '--check-hint-write-failure', deadline);
  if (!session) return;
  const { cdp, die } = session;

  let passed = 0;
  let total = 0;
  const report = (name, ok, observed) => {
    total += 1;
    if (ok) { passed += 1; console.log(`ok - ${name}`); }
    else { console.log(`FAIL - ${name} (observed: ${JSON.stringify(observed)})`); }
  };
  const NAMES = {
    noReload: 'hint write failure: the page did NOT reload after the failed boot-hint write (reloading would have re-read the STALE hint and re-fetched the old language)',
    honest: 'hint write failure: #sxc1-progress reports the in-memory switch honestly -- uiLang=ja, contentLang=en, available=false',
    banner: 'hint write failure: the VISIBLE #sxc1-lang-split alert names both languages and offers #btn-lang-resync',
    docLang: "hint write failure: document.documentElement.lang follows the in-memory switch to 'ja' (the shell set it from the stale hint)",
  };

  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
  await cdp.send('Page.enable', {}, sessionId);
  await cdp.send('Runtime.enable', {}, sessionId);
  await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: HINT_BLOCK_SCRIPT }, sessionId);
  const evaluate = async (expression) => {
    const res = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, sessionId);
    if (res.exceptionDetails) {
      const d = res.exceptionDetails;
      throw new Error(`page evaluation error: ${d.exception?.description || d.text}`);
    }
    return res.result ? res.result.value : undefined;
  };
  await cdp.send('Page.navigate', { url: opts.url }, sessionId);

  let booted = false;
  const bootDeadline = Math.min(deadline, Date.now() + 40000);
  while (Date.now() < bootDeadline) {
    let state;
    try {
      state = await evaluate(`(() => {
        if (typeof window.__SXC1_BOOT_ERROR === 'string') return { error: window.__SXC1_BOOT_ERROR };
        if (window.__SXC1_BOOTED === true) return { booted: true };
        return { pending: true };
      })()`);
    } catch { state = { pending: true }; }
    if (state && state.error) break;
    if (state && state.booted) { booted = true; break; }
    await sleep(100);
  }
  if (!booted) {
    for (const n of Object.values(NAMES)) report(n, false, 'app did not boot');
    console.log(`browser-check --check-hint-write-failure: ${passed}/${total} assertions passed`);
    await die(1, null);
    return;
  }

  // A window-scoped marker a reload would destroy: this is how "no
  // reload happened" is OBSERVED rather than assumed.
  // A RELOAD is exactly what the pre-fix app does here, and it kills the
  // in-flight evaluation with "Inspected target navigated or closed" --
  // caught below and reported as the failure it is, rather than crashing
  // the harness (that is the red-first demonstration's own output).
  let outcome = null;
  try {
    outcome = await evaluate(`(async () => {
    window.__SXC1_NO_RELOAD_MARKER = 'alive';
    const btn = document.querySelector('#btn-ui-lang');
    if (!btn) return { error: 'no #btn-ui-lang' };
    btn.click();
    const start = Date.now();
    while (Date.now() - start < 6000) {
      if (window.__SXC1_NO_RELOAD_MARKER !== 'alive') break;
      const split = document.querySelector('#sxc1-lang-split');
      if (split) break;
      await new Promise((r) => setTimeout(r, 50));
    }
    const split = document.querySelector('#sxc1-lang-split');
    let progress = null;
    try { progress = JSON.parse(document.querySelector('#sxc1-progress').textContent); } catch (e) { progress = null; }
    return {
      markerAlive: window.__SXC1_NO_RELOAD_MARKER === 'alive',
      hintWritesBlocked: window.__SXC1_HINT_WRITES_BLOCKED || 0,
      progress,
      docLang: document.documentElement.lang,
      split: split === null ? null : {
        visible: !split.hidden && split.offsetParent !== null,
        role: split.getAttribute('role'),
        text: (split.textContent || '').trim().slice(0, 200),
        resync: split.querySelector('#btn-lang-resync') !== null,
      },
    };
  })()`);
  } catch (err) {
    outcome = { navigated: String(err && err.message ? err.message : err), markerAlive: false };
  }
  if (outcome && outcome.navigated) {
    // Re-read the (new) document: a reload means the whole claim failed,
    // but the report should still describe what is on screen now.
    try {
      outcome.afterReload = await evaluate(`(() => ({
        marker: window.__SXC1_NO_RELOAD_MARKER || null,
        split: document.querySelector('#sxc1-lang-split') !== null,
        docLang: document.documentElement.lang,
      }))()`);
    } catch { /* still navigating; the failure is already recorded */ }
  }

  report(NAMES.noReload, Boolean(outcome && outcome.markerAlive && outcome.hintWritesBlocked > 0), outcome);
  report(
    NAMES.honest,
    Boolean(outcome && outcome.progress && outcome.progress.uiLang === 'ja'
      && outcome.progress.contentLang === 'en' && outcome.progress.available === false),
    outcome && outcome.progress,
  );
  report(
    NAMES.banner,
    Boolean(outcome && outcome.split && outcome.split.visible && outcome.split.role === 'alert'
      && outcome.split.resync && /ja/.test(outcome.split.text) && /en/.test(outcome.split.text)),
    outcome && outcome.split,
  );
  report(NAMES.docLang, Boolean(outcome && outcome.docLang === 'ja'), outcome && outcome.docLang);

  try { await cdp.send('Target.closeTarget', { targetId }); } catch { /* best effort */ }
  console.log(`browser-check --check-hint-write-failure: ${passed}/${total} assertions passed`);
  await die(passed === total ? 0 : 1, null);
}

// ---------------------------------------------------------------------------
// M6 W2: --check-ja-toggle -- see printHelp's own entry. The pinned
// route/title constants live here (the DEVICE_REAL_CFG precedent: the
// harness pins real seed-corpus identities).
//
// M6 gate round 1 (finding M6-R1-1): this stage used to serve a copy
// whose bundles were RE-EMITTED from a corpus copy carrying one injected
// ja: fixture heading. That is no longer possible, and no longer needed:
// a re-emitted bundle is by construction not the bundle THIS app.wasm
// was built against, so the wasm-embedded manifest fingerprint rejects
// it -- which is exactly the protection the finding asked for. The stage
// now serves the SHIPPED bundles unmodified and pins the REAL wave-3
// Japanese title of q-2-01, so the assertion is strictly stronger than
// the fixture it replaces: it proves the artifact that actually ships
// renders the Japanese course.
// ---------------------------------------------------------------------------
const JA_TOGGLE_CFG = {
  quizRoute: '#/x/pad-01/q-2-01',
  quizReady: '.kind-quiz',
  // 「BANK」とは何か -- content/exercises/024-pad-01.ex.md's own
  // ja: variant of q-2-01's title (the real corpus, not a fixture).
  jaQuizTitle: '\u300cBANK\u300d\u3068\u306f\u4f55\u304b',
  drillRoute: DEVICE_REAL_CFG.drill.route,
  goodBytes: DEVICE_REAL_CFG.drill.good,
  // デバイス検証を有効にする -- I18n.iDevEnable (Ja).
  jaDevEnableLabel: '\u30c7\u30d0\u30a4\u30b9\u691c\u8a3c\u3092\u6709\u52b9\u306b\u3059\u308b',
};

async function runJaToggleCheck(opts) {
  const deadline = Date.now() + opts.timeout;
  const cleanupFns = [];
  const runCleanup = async () => {
    for (const fn of cleanupFns.splice(0).reverse()) {
      try { await fn(); } catch { /* best-effort cleanup */ }
    }
  };
  const die = async (code, message) => {
    if (message) console.log(message);
    await runCleanup();
    process.exit(code);
  };

  const browserPath = resolveBrowser(opts.browser);
  if (!browserPath) {
    await die(2, 'error: no browser found for --check-ja-toggle. Install Google Chrome/Chromium, or set ' +
      'SXC1_BROWSER to a browser executable path, or pass --browser <path>.');
    return;
  }

  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sxc1-jatoggle-profile-'));
  cleanupFns.push(() => removeDirWithRetry(userDataDir));
  const debugPort = await findFreePort();
  const browserProc = spawn(browserPath, [
    '--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run', '--no-default-browser-check',
    '--disable-dev-shm-usage', `--user-data-dir=${userDataDir}`, `--remote-debugging-port=${debugPort}`, 'about:blank',
  ], { stdio: 'ignore', detached: true });
  let cdp = null;
  let browserFailure = null;
  const noteBrowserFailure = (message) => {
    if (!browserFailure) browserFailure = new Error(message);
    if (cdp) cdp.failFatally(browserFailure);
  };
  browserProc.on('exit', (code, signal) => {
    noteBrowserFailure(`browser process exited unexpectedly (code=${code === null ? 'null' : code}, signal=${signal || 'none'})`);
  });
  browserProc.on('error', (err) => {
    noteBrowserFailure(`browser process error: ${err && err.message ? err.message : err}`);
  });
  cleanupFns.push(() => new Promise((resolve) => {
    const killGroup = (signal) => { try { process.kill(-browserProc.pid, signal); } catch { /* group already gone */ } };
    if (browserProc.exitCode !== null || browserProc.signalCode !== null) { killGroup('SIGKILL'); resolve(); return; }
    const forceKillTimer = setTimeout(() => killGroup('SIGKILL'), 3000);
    browserProc.once('exit', () => { clearTimeout(forceKillTimer); killGroup('SIGKILL'); resolve(); });
    killGroup('SIGTERM');
  }));

  let versionInfo = null;
  while (Date.now() < deadline) {
    if (browserFailure) {
      await die(2, `error: ${browserFailure.message} (before DevTools became reachable at ${browserPath})`);
      return;
    }
    try {
      const info = await withDeadline(
        httpGetJson(`http://127.0.0.1:${debugPort}/json/version`),
        deadline,
        'DevTools /json/version request',
      );
      if (info && info.webSocketDebuggerUrl) { versionInfo = info; break; }
    } catch { /* not up yet */ }
    await sleep(200);
  }
  if (!versionInfo) {
    await die(2, 'error: timed out waiting for DevTools (--check-ja-toggle)');
    return;
  }

  const ws = await withDeadline(connectWebSocket(versionInfo.webSocketDebuggerUrl), deadline, 'WebSocket connect');
  cleanupFns.push(() => { try { ws.close(); } catch { /* ignore */ } });
  cdp = new CDPClient(ws, { getRemaining: () => remaining(deadline) });
  ws.addEventListener('close', () => cdp.failFatally(new Error('CDP WebSocket closed unexpectedly')));
  ws.addEventListener('error', (ev) => cdp.failFatally(new Error(`CDP WebSocket error: ${formatWsErrorEvent(ev)}`)));

  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
  await cdp.send('Page.enable', {}, sessionId);
  await cdp.send('Runtime.enable', {}, sessionId);

  // The JA device flow needs a grantable Web MIDI: inject the committed
  // harness fake (P-B: BEFORE the first navigation; it reinstalls on
  // every navigation of this target, so the app's own language-switch
  // reload keeps a fresh grant+port fake too).
  const fakeSrc = fs.readFileSync(FAKE_MIDI_PATH, 'utf8');
  await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
    source: `${fakeSrc}\n;(function () { try { ${DEV_PRE_GRANT_SXC} } catch (e) { console.error('fake-midi preamble failed: ' + e); } })();`,
  }, sessionId);

  const evaluate = async (expression) => {
    const res = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, sessionId);
    if (res.exceptionDetails) {
      const d = res.exceptionDetails;
      throw new Error(`page evaluation error: ${d.exception?.description || d.text}`);
    }
    return res.result ? res.result.value : undefined;
  };
  const waitBootedHere = async (timeoutMs = 20000) => {
    await sleep(300);
    const bootDeadline = Date.now() + timeoutMs;
    while (Date.now() < bootDeadline) {
      let b;
      try { b = await evaluate('window.__SXC1_BOOTED === true'); } catch { b = false; }
      if (b === true) return true;
      await sleep(50);
    }
    return false;
  };
  const gotoHash = (hash, readySelector, timeoutMs = 8000) => evaluate(`(async () => {
    window.location.hash = ${JSON.stringify(hash)};
    const start = Date.now();
    while (Date.now() - start < ${timeoutMs}) {
      if (document.querySelector(${JSON.stringify(readySelector)})) return true;
      await new Promise((r) => setTimeout(r, 20));
    }
    return document.querySelector(${JSON.stringify(readySelector)}) !== null;
  })()`);
  const readUiLang = async () => {
    try {
      return await evaluate("(() => { const e = document.querySelector('#sxc1-progress'); try { return JSON.parse(e ? e.textContent : 'null').uiLang; } catch (err) { return null; } })()");
    } catch { return null; }
  };
  const resourceLangs = () => evaluate(`(() => {
    const names = performance.getEntriesByType('resource').map((e) => e.name);
    return {
      ja: names.some((n) => n.indexOf('content/content.ja.txt') !== -1),
      en: names.some((n) => n.indexOf('content/content.en.txt') !== -1),
    };
  })()`);

  let passed = 0;
  let total = 0;
  const report = (name, ok, observed) => {
    total += 1;
    if (ok) { passed += 1; console.log(`ok - ${name}`); }
    else { console.log(`FAIL - ${name} (observed: ${JSON.stringify(observed)})`); }
  };
  const NAMES = {
    bootsEn: 'ja-toggle: fresh profile boots EN -- document lang "en", #btn-ui-lang shows the switch-to-ja label, content.en.txt fetched',
    switchJa: 'ja-toggle: clicking #btn-ui-lang persists and RELOADS into uiLang "ja" (reload-as-refetch)',
    bundleJa: 'ja-toggle: the reloaded document fetched content/content.ja.txt and not content.en.txt',
    headerJa: 'ja-toggle: the header renders Japanese and document.documentElement.lang is "ja"',
    prefSuggest: 'ja-toggle: ruling-4 suggestion on a fresh profile -- sxc1.uilang "ja", P uiLang ja, and the FIRST switch flipped jaFirst on WITHOUT marking it explicitly set (P jaFirst 1, P jaFirstSet 0)',
    jaContent: 'ja-toggle: the injected ja: fixture variant renders -- the quiz title under ja is the Japanese heading from content.ja.txt',
    devWaitingJa: 'ja-toggle: JA device flow -- enable renders the JA enable label/status sentence and the JA waiting sentence (describeSpec JA renderer) in the aria-live verify line',
    devConfirmedJa: 'ja-toggle: JA device flow -- the matching bytes flip the verify line to the JA device-confirmed sentence',
    backToEn: 'ja-toggle: switching back restores EN -- uiLang "en" after another reload, content.en.txt fetched, EN quiz title again',
  };

  await cdp.send('Page.navigate', { url: opts.url }, sessionId);
  const booted = await waitBootedHere(Math.min(30000, Math.max(1, deadline - Date.now())));
  if (!booted) {
    report(NAMES.bootsEn, false, 'the app never reported __SXC1_BOOTED');
    for (const n of [NAMES.switchJa, NAMES.bundleJa, NAMES.headerJa, NAMES.prefSuggest, NAMES.jaContent, NAMES.devWaitingJa, NAMES.devConfirmedJa, NAMES.backToEn]) {
      report(n, false, 'skipped: app did not boot');
    }
    console.log(`browser-check --check-ja-toggle: ${passed}/${total} assertions passed`);
    await die(1, null);
    return;
  }

  // -- 1. Fresh profile boots EN.
  const en0 = await evaluate(`(() => ({
    docLang: document.documentElement.lang,
    btn: (document.querySelector('#btn-ui-lang') || {}).textContent || null,
  }))()`);
  const res0 = await resourceLangs();
  const uiLang0 = await readUiLang();
  report(
    NAMES.bootsEn,
    Boolean(en0) && en0.docLang === 'en' && en0.btn === UI_TEXT.en.uiLangButton
      && uiLang0 === 'en' && res0.en === true && res0.ja === false,
    { en0, res0, uiLang0 },
  );

  // -- 2. Switch to JA (the click triggers the app's own persist+reload).
  const clicked = await evaluate("(() => { const e = document.querySelector('#btn-ui-lang'); if (!e) return false; e.click(); return true; })()");
  const rebooted = clicked && await waitBootedHere(20000);
  const jaSettled = rebooted && await waitForTrue(evaluate, "(() => { const e = document.querySelector('#sxc1-progress'); try { return JSON.parse(e ? e.textContent : 'null').uiLang === 'ja'; } catch (err) { return false; } })()", 8000);
  report(NAMES.switchJa, clicked && rebooted && jaSettled, { clicked, rebooted, jaSettled });

  // -- 3. The reload really fetched the ja bundle.
  const res1 = await resourceLangs();
  report(NAMES.bundleJa, Boolean(res1) && res1.ja === true && res1.en === false, res1);

  // -- 4. Japanese header + document lang.
  const jaHdr = await evaluate(`(() => ({
    docLang: document.documentElement.lang,
    btn: (document.querySelector('#btn-ui-lang') || {}).textContent || null,
    badge: (document.querySelector('#sxc1-review-badge') || {}).textContent || null,
  }))()`);
  report(
    NAMES.headerJa,
    Boolean(jaHdr) && jaHdr.docLang === 'ja' && jaHdr.btn === UI_TEXT.ja.uiLangButton
      && typeof jaHdr.badge === 'string' && jaHdr.badge.startsWith(UI_TEXT.ja.reviewBadgePrefix),
    jaHdr,
  );

  // -- 5. Persistence + the one-time jaFirst suggestion (fresh profile).
  const hint = await evaluate("(() => { try { return window.localStorage.getItem('sxc1.uilang'); } catch (e) { return null; } })()");
  const prefsRaw = await evaluate(`(() => { try { return window.localStorage.getItem(${JSON.stringify(PREFS_KEY)}); } catch (e) { return null; } })()`);
  report(
    NAMES.prefSuggest,
    hint === 'ja'
      && /(^|\n)P\tuiLang\tja(\n|$)/.test(prefsRaw || '')
      && /(^|\n)P\tjaFirst\t1(\n|$)/.test(prefsRaw || '')
      && /(^|\n)P\tjaFirstSet\t0(\n|$)/.test(prefsRaw || ''),
    { hint, prefsRaw },
  );

  // -- 6. The injected ja: fixture variant renders from the ja bundle.
  await gotoHash(JA_TOGGLE_CFG.quizRoute, JA_TOGGLE_CFG.quizReady);
  const jaTitle = await evaluate("(() => { const e = document.querySelector('#ex-title'); return e ? e.textContent : null; })()");
  report(NAMES.jaContent, jaTitle === JA_TOGGLE_CFG.jaQuizTitle, { jaTitle, want: JA_TOGGLE_CFG.jaQuizTitle });

  // -- 7/8. The JA device flow (fake granted, SXC-1 port added).
  await gotoHash(JA_TOGGLE_CFG.drillRoute, '.kind-drill');
  const enableLabel = await evaluate("(() => { const e = document.querySelector('#btn-device-enable'); return e ? e.textContent : null; })()");
  await evaluate("(() => { const e = document.querySelector('#btn-device-enable'); if (e) e.click(); return true; })()");
  const grantedSettled = await waitDeviceState(evaluate, "p.status === 'granted'", 8000);
  const devJa = await evaluate(`(() => ({
    status: (document.querySelector('#device-status') || {}).textContent || null,
    verify: (document.querySelector('#ex-step-1-verify') || {}).textContent || null,
    verifyLive: (document.querySelector('#ex-step-1-verify') || { getAttribute: () => null }).getAttribute('aria-live'),
  }))()`);
  report(
    NAMES.devWaitingJa,
    enableLabel === JA_TOGGLE_CFG.jaDevEnableLabel && grantedSettled === true
      && Boolean(devJa) && devJa.status === UI_TEXT.ja.devStatusOn1
      && devJa.verify === UI_TEXT.ja.devVerifyWaitingCc && devJa.verifyLive === 'polite',
    { enableLabel, wantEnable: JA_TOGGLE_CFG.jaDevEnableLabel, grantedSettled, devJa,
      wantStatus: UI_TEXT.ja.devStatusOn1, wantVerify: UI_TEXT.ja.devVerifyWaitingCc },
  );

  await evaluate(fakeEmitExpr(JA_TOGGLE_CFG.goodBytes));
  const confirmedJa = await waitForTrue(
    evaluate,
    `(() => { const e = document.querySelector('#ex-step-1-verify'); return Boolean(e && e.textContent === ${JSON.stringify(UI_TEXT.ja.devVerifyConfirmedCc)}); })()`,
    8000,
  );
  const verifyAfter = await evaluate("(() => { const e = document.querySelector('#ex-step-1-verify'); return e ? e.textContent : null; })()");
  report(NAMES.devConfirmedJa, confirmedJa === true, { verifyAfter, want: UI_TEXT.ja.devVerifyConfirmedCc });

  // -- 9. Roundtrip back to EN.
  await gotoHash('#/', '#sxc1-progress-tools');
  const clickedBack = await evaluate("(() => { const e = document.querySelector('#btn-ui-lang'); if (!e) return false; e.click(); return true; })()");
  const rebootedEn = clickedBack && await waitBootedHere(20000)
    && await waitForTrue(evaluate, "(() => { const e = document.querySelector('#sxc1-progress'); try { return JSON.parse(e ? e.textContent : 'null').uiLang === 'en'; } catch (err) { return false; } })()", 8000);
  const res2 = await resourceLangs();
  await gotoHash(JA_TOGGLE_CFG.quizRoute, JA_TOGGLE_CFG.quizReady);
  const enTitle = await evaluate("(() => { const e = document.querySelector('#ex-title'); return e ? e.textContent : null; })()");
  report(
    NAMES.backToEn,
    clickedBack && rebootedEn === true && Boolean(res2) && res2.en === true && res2.ja === false
      && typeof enTitle === 'string' && enTitle !== JA_TOGGLE_CFG.jaQuizTitle && enTitle.length > 0,
    { clickedBack, rebootedEn, res2, enTitle },
  );

  console.log(`browser-check --check-ja-toggle: ${passed}/${total} assertions passed`);
  await die(passed === total ? 0 : 1, null);
}

// ---------------------------------------------------------------------------
// M7 W1 (briefs/M7-plan.md, ruling 1): --check-bad-manual-bundle. The
// manual counterpart of --check-bad-bundle, on the same openCheckSession
// helper and with the same claim: a 200 response is not evidence of a
// healthy manual corpus. Six separately broken copies of the SHIPPED
// manual bundle -- each served at the correct URL, five of them with a
// perfectly ordinary HTTP success -- must every one of them produce the
// VISIBLE degraded state, never a shorter-but-"healthy" reader:
//
//   m-wrong-language  the ja bundle served at ./content/manuals.en.txt
//   m-stale           one document's TEXT altered (framing untouched)
//   m-truncated       the last document's body cut, every !SXC1-DOC
//                     delimiter still present and the header count right
//   m-zero-doc        "!SXC1-BUNDLE v1 en 0" and nothing else
//   m-missing-doc     one whole document removed, header count adjusted
//   m-missing         the file simply absent (a 404) -- the manual
//                     mirror of --check-content-missing
//
// plus a HEALTHY control served from the same server in the same run --
// the anti-vacuity floor. check-site.sh builds the seven directories and
// verifies each sabotage structurally first; this mode never injects
// anything.
//
// Each case asserts BOTH halves, because INDEPENDENCE is the actual
// claim: the visible role=alert banner AND the named
// #sxc1-manual-degraded body with #btn-content-retry on a real manual
// route, WHILE #sxc1-exercise-stats still reports the whole 52-deck
// course. A bad manual bundle must not take the course down with it,
// and a shared "everything failed" state would hide exactly that.
// ---------------------------------------------------------------------------
const BAD_MANUAL_CASES = [
  { dir: 'm-wrong-language', why: 'the ja manual bundle served at the en URL' },
  { dir: 'm-stale', why: "one document's text altered, framing untouched" },
  { dir: 'm-truncated', why: 'the final document truncated with every delimiter still present' },
  { dir: 'm-zero-doc', why: 'a syntactically perfect zero-document bundle' },
  { dir: 'm-missing-doc', why: 'one whole document removed, header count adjusted' },
  { dir: 'm-missing', why: 'the manual bundle file absent altogether (404)' },
];
const BAD_MANUAL_HEALTHY_DIR = 'm-healthy';
const BAD_MANUAL_EXPECT_DECKS = 52;
const BAD_MANUAL_ROUTE = '#/m/guide-book/p/15';

async function runBadManualBundleCheck(opts) {
  const deadline = Date.now() + opts.timeout;
  const session = await openCheckSession(opts, '--check-bad-manual-bundle', deadline);
  if (!session) return;
  const { die, newTarget } = session;

  let passed = 0;
  let total = 0;
  const report = (name, ok, observed) => {
    total += 1;
    if (ok) { passed += 1; console.log(`ok - ${name}`); }
    else { console.log(`FAIL - ${name} (observed: ${JSON.stringify(observed)})`); }
  };

  const baseNoHash = opts.url.replace(/#.*$/, '').replace(/\/$/, '');

  // What the running app says about itself on a real MANUAL route --
  // plus, deliberately, what it says about the COURSE, which a manual
  // failure must leave completely alone.
  const surfaceOf = async (evaluate) => evaluate(`(async () => {
    window.location.hash = ${JSON.stringify(BAD_MANUAL_ROUTE)};
    const start = Date.now();
    while (Date.now() - start < 8000) {
      if (document.querySelector('#sxc1-manual-degraded') || document.querySelector('#sxc1-page .page-body')) break;
      await new Promise((r) => setTimeout(r, 50));
    }
    const banner = document.querySelector('#sxc1-content-error');
    const stats = document.querySelector('#sxc1-exercise-stats');
    let totals = null;
    try { totals = JSON.parse(stats ? stats.textContent : 'null').totals; } catch (e) { totals = null; }
    const body = document.querySelector('#sxc1-page .page-body');
    return {
      bannerExists: banner !== null,
      bannerVisible: banner !== null && !banner.hidden && banner.offsetParent !== null,
      bannerRole: banner ? banner.getAttribute('role') : null,
      bannerText: banner ? (banner.textContent || '').trim().slice(0, 200) : '',
      degraded: document.querySelector('#sxc1-manual-degraded') !== null,
      retry: document.querySelector('#btn-content-retry') !== null,
      bodyChars: body && body.textContent ? body.textContent.trim().length : 0,
      manualCards: document.querySelectorAll('a.manual-card').length,
      totals,
    };
  })()`);

  for (const c of BAD_MANUAL_CASES) {
    const alertName = `bad manual bundle (${c.dir}): a response carrying ${c.why} produces the VISIBLE #sxc1-content-error alert`;
    const degradedName = `bad manual bundle (${c.dir}): the manual route renders the named #sxc1-manual-degraded body with #btn-content-retry and NO page text, while the exercise course stays whole (${BAD_MANUAL_EXPECT_DECKS} decks)`;
    const t = await newTarget(`${baseNoHash}/${c.dir}/`, 30000);
    if (!t.boot.ok) {
      report(alertName, false, t.boot);
      report(degradedName, false, 'skipped: app did not boot');
      await t.close();
      continue;
    }
    let s = null;
    try { s = await surfaceOf(t.evaluate); } catch (err) { s = { error: String(err && err.message ? err.message : err) }; }
    report(
      alertName,
      Boolean(s && s.bannerExists && s.bannerVisible && s.bannerRole === 'alert' && s.bannerText.length > 0),
      s,
    );
    report(
      degradedName,
      Boolean(s && s.degraded && s.retry && s.bodyChars === 0
        && s.totals && s.totals.decks === BAD_MANUAL_EXPECT_DECKS),
      s,
    );
    await t.close();
  }

  // The control, from the same server, in the same run.
  const healthyAlertName = 'bad manual bundle (healthy control): the UNSABOTAGED copy renders NO #sxc1-content-error banner at all';
  const healthyManualName = `bad manual bundle (healthy control): the unsabotaged copy renders a real manual page's translated body, no degraded notice, and the whole ${BAD_MANUAL_EXPECT_DECKS}-deck course`;
  const h = await newTarget(`${baseNoHash}/${BAD_MANUAL_HEALTHY_DIR}/`, 30000);
  if (!h.boot.ok) {
    report(healthyAlertName, false, h.boot);
    report(healthyManualName, false, 'skipped: app did not boot');
  } else {
    let s = null;
    try { s = await surfaceOf(h.evaluate); } catch (err) { s = { error: String(err && err.message ? err.message : err) }; }
    report(healthyAlertName, Boolean(s && s.bannerExists === false), s);
    report(
      healthyManualName,
      Boolean(s && s.bodyChars > 100 && !s.degraded
        && s.totals && s.totals.decks === BAD_MANUAL_EXPECT_DECKS),
      s,
    );
  }
  await h.close();

  console.log(`browser-check --check-bad-manual-bundle: ${passed}/${total} assertions passed`);
  await die(passed === total ? 0 : 1, null);
}

// ---------------------------------------------------------------------------
// M7 ruling 4: --check-manual-fallback.
//
// W1 SHIPPED THIS MODE ASSERTING THE NOTE IS PRESENT under ja, because
// the ja manual bundle then carried the ENGLISH text for every document
// (wave 2 had not authored translations/<slug>.ja.md yet) and ruling 4
// requires that state to be VISIBLE rather than silent. W2 landed all
// 108 pages in Japanese, so the note is now correct only by its
// ABSENCE, and W3 FLIPS THE STAGE accordingly: under ja, no
// #sxc1-manual-fallback may exist anywhere and every document's body
// must render REAL JAPANESE.
//
// What the flipped mode exercises, against real served bytes:
//
//   * EN boot: every document IS in the reader's language, so
//     #sxc1-manual-fallback must not exist ANYWHERE (absence, not
//     hidden-ness -- the same discipline as #sxc1-content-error).
//   * JA boot, reached through the app's OWN #btn-ui-lang switch
//     (persist the pref + the boot hint, then reload -- the reload IS
//     the refetch): the ja bundle really loaded (uiLang=ja AND
//     contentLang=ja, with no content-error banner); the note exists
//     NOWHERE (page, TOC, home); the body carries no lang override
//     (the document IS in the reader's language now); and ALL FOUR
//     documents render their own PINNED Japanese sentence.
//
// The pinned sentences are LITERALS here, copied from the wave-2
// transcriptions, never read off the page under test -- so a ja bundle
// that fell back to English (or a document that quietly did) turns
// MF4/MF5 red rather than agreeing with itself. That is exactly what
// makes this stage's red test possible without editing translations/:
// see check-site's own comment, and the W3 report, for the one-off
// EN-fallback build the flip was demonstrated against.
//
// THE MECHANISM ITSELF IS NOT RETIRED, only its current expectation:
// View.Pages still renders the note for any document whose !SXC1-DOC
// record names a language other than the reader's, check-site's M7-i
// still proves the emitter flips that record when a .ja.md appears or
// disappears, and this stage's PRECONDITION in check-site.sh now
// requires every record in the served manuals.ja.txt to say 'ja' -- so
// a future untranslated document turns the precondition red (loudly,
// with the reason) instead of silently asserting an absence that no
// longer holds.
const MANUAL_FALLBACK_TOC_ROUTE = '#/m/guide-book';
// I18n.iManualFallbackNote Ja -- この文書の日本語テキストはまだ用意されていません。
// Kept as a literal even though the note must now be ABSENT: MF3 reads
// it back if one ever appears, so a failure names WHAT appeared.
const MANUAL_FALLBACK_JA_TEXT =
  'この文書の日本語テキストはまだ用意されていません。';

// One real reading route per document, each with a distinctive sentence
// from wave 2's transcription of THAT page's image. Every document is
// listed on purpose: "all four are Japanese now" is the claim, so one
// document falling back must fail here.
const MANUAL_FALLBACK_DOCS = [
  {
    slug: 'guide-book',
    route: '#/m/guide-book/p/2',
    // 本書の説明・表示例やイラストなどは、実際の製品と異なる場合があります。
    jaText: '本書の説明・表示例やイラストなどは、実際の製品と異なる場合があります。',
  },
  {
    slug: 'startup-guide',
    route: '#/m/startup-guide/p/1',
    // ご使用の前に取扱説明書の「安全上のご注意」をよくお読みの上、正しくお使いください。
    jaText: 'ご使用の前に取扱説明書の「安全上のご注意」をよくお読みの上、正しくお使いください。',
  },
  {
    slug: 'midi',
    route: '#/m/midi/p/1',
    // 本書は本機に搭載された MIDI 機能及びそのインプリメンテーションに関して記載しています。
    jaText: '本書は本機に搭載された MIDI 機能及びそのインプリメンテーションに関して記載しています。',
  },
  {
    slug: 'oss',
    route: '#/m/oss/p/1',
    // 本書に記載のソフトウェアについて、各ライセンス条件に基づく必要な表示および条文を掲載しています。
    jaText: '本書に記載のソフトウェアについて、各ライセンス条件に基づく必要な表示および条文を掲載しています。',
  },
];

async function runManualFallbackCheck(opts) {
  const deadline = Date.now() + opts.timeout;
  const session = await openCheckSession(opts, '--check-manual-fallback', deadline);
  if (!session) return;
  const { die, newTarget } = session;

  let passed = 0;
  let total = 0;
  const report = (name, ok, observed) => {
    total += 1;
    if (ok) { passed += 1; console.log(`ok - ${name}`); }
    else { console.log(`FAIL - ${name} (observed: ${JSON.stringify(observed)})`); }
  };

  const baseNoHash = opts.url.replace(/#.*$/, '').replace(/\/$/, '');

  // Stable IDs, the JAC1..JAC5 precedent (M6 W4, finding M6-R1-3):
  // check-site.sh requires this exact SET by id, so an assertion that is
  // renamed, unplugged or swapped for a different "manual fallback:"
  // assertion cannot hide behind the 5/5 count.
  const NAMES = {
    enAbsent: 'manual fallback: [MF1] under EN every document IS in the reader\'s language, so #sxc1-manual-fallback exists NOWHERE (page, TOC or home) while the page body renders normally with no lang override',
    jaLoaded: 'manual fallback: [MF2] the app\'s own #btn-ui-lang switch reloads into a real JA boot -- #sxc1-progress reports uiLang=ja AND contentLang=ja with no #sxc1-content-error banner (the ja manual bundle was accepted)',
    jaNoNote: 'manual fallback: [MF3] wave 2 landed every document in Japanese, so under JA #sxc1-manual-fallback exists NOWHERE either -- not on any of the four reading routes, not in the manual TOC, not on a home card',
    jaBody: 'manual fallback: [MF4] the JA page body renders the pinned Japanese sentence (a literal here, never read off the page) and carries NO lang override, because the document IS in the reader\'s language now',
    jaAllDocs: 'manual fallback: [MF5] ALL FOUR documents render their own pinned Japanese sentence under JA -- a single document still falling back to English fails here by name',
  };

  const t = await newTarget(`${baseNoHash}/`, 30000);
  if (!t.boot.ok) {
    for (const n of Object.values(NAMES)) report(n, false, t.boot);
    console.log(`browser-check --check-manual-fallback: ${passed}/${total} assertions passed`);
    await die(1, null);
    return;
  }

  // One probe visits every document's reading route (going HOME between
  // routes, so the wait for '#sxc1-page .page-body' cannot be satisfied
  // by the page being left), then the TOC and home.
  const probe = async (evaluate) => evaluate(`(async () => {
    const DOCS = ${JSON.stringify(MANUAL_FALLBACK_DOCS)};
    const wait = async (sel) => {
      const start = Date.now();
      while (Date.now() - start < 8000) {
        if (document.querySelector(sel)) return true;
        await new Promise((r) => setTimeout(r, 50));
      }
      return false;
    };
    const docs = [];
    for (const d of DOCS) {
      window.location.hash = '#/';
      await wait('#sxc1-home');
      window.location.hash = d.route;
      await wait('#sxc1-page .page-body');
      const body = document.querySelector('#sxc1-page .page-body');
      const note = document.querySelector('#sxc1-manual-fallback');
      const bodyText = body && body.textContent ? body.textContent : '';
      docs.push({
        slug: d.slug,
        route: d.route,
        noteExists: note !== null,
        noteVisible: note !== null && !note.hidden && note.offsetParent !== null,
        noteRole: note ? note.getAttribute('role') : null,
        noteText: note ? (note.textContent || '').trim() : '',
        bodyChars: bodyText.trim().length,
        bodyLang: body ? body.getAttribute('lang') : null,
        jaTextPresent: bodyText.indexOf(d.jaText) !== -1,
      });
    }
    let prog = null;
    try { prog = JSON.parse(document.querySelector('#sxc1-progress').textContent); } catch (e) { prog = null; }
    window.location.hash = ${JSON.stringify(MANUAL_FALLBACK_TOC_ROUTE)};
    await wait('#sxc1-toc');
    const tocNotes = document.querySelectorAll('#sxc1-toc .manual-fallback-note').length;
    window.location.hash = '#/';
    await wait('#sxc1-home');
    const homeNotes = document.querySelectorAll('#sxc1-home .manual-fallback-note').length;
    return {
      docs,
      tocNotes,
      homeNotes,
      docLang: document.documentElement.lang,
      banner: document.querySelector('#sxc1-content-error') !== null,
      uiLang: prog ? prog.uiLang : null,
      contentLang: prog ? prog.contentLang : null,
    };
  })()`);

  const firstDoc = (r) => (r && Array.isArray(r.docs) && r.docs.length ? r.docs[0] : null);
  const noteFreeEverywhere = (r) => Boolean(
    r && Array.isArray(r.docs) && r.docs.length === MANUAL_FALLBACK_DOCS.length
      && r.docs.every((d) => d.noteExists === false)
      && r.tocNotes === 0 && r.homeNotes === 0,
  );

  let en = null;
  try { en = await probe(t.evaluate); } catch (err) { en = { error: String(err && err.message ? err.message : err) }; }
  const enFirst = firstDoc(en);
  report(
    NAMES.enAbsent,
    Boolean(noteFreeEverywhere(en) && enFirst && enFirst.bodyChars > 100
      && enFirst.bodyLang === null && en.uiLang === 'en'),
    en,
  );

  // The app's own switch: persist the pref + the sxc1.uilang boot hint,
  // then reload -- which is what makes the shell fetch manuals.ja.txt.
  let switched = null;
  try {
    switched = await t.evaluate(`(async () => {
      window.location.hash = '#/';
      const start = Date.now();
      while (Date.now() - start < 8000 && !document.querySelector('#btn-ui-lang')) {
        await new Promise((r) => setTimeout(r, 50));
      }
      const btn = document.querySelector('#btn-ui-lang');
      if (!btn) return { ok: false, why: 'no #btn-ui-lang' };
      window.__SXC1_PRE_RELOAD = true;
      btn.click();
      return { ok: true };
    })()`);
  } catch (err) { switched = { ok: false, why: String(err && err.message ? err.message : err) }; }

  // Wait for the reload to produce a fresh, booted document.
  let ja = null;
  if (switched && switched.ok) {
    const waitUntil = Math.min(deadline, Date.now() + 30000);
    let ready = false;
    while (Date.now() < waitUntil) {
      let st = null;
      try {
        st = await t.evaluate(`(() => ({
          booted: window.__SXC1_BOOTED === true,
          stale: window.__SXC1_PRE_RELOAD === true,
          error: typeof window.__SXC1_BOOT_ERROR === 'string' ? window.__SXC1_BOOT_ERROR : null,
        }))()`);
      } catch (err) { st = null; }   // mid-navigation
      if (st && st.booted && !st.stale) { ready = true; break; }
      await sleep(100);
    }
    if (ready) {
      try { ja = await probe(t.evaluate); } catch (err) { ja = { error: String(err && err.message ? err.message : err) }; }
    } else {
      ja = { error: 'the document never reloaded into a fresh booted app after #btn-ui-lang' };
    }
  } else {
    ja = { error: `switch failed: ${switched && switched.why ? switched.why : 'unknown'}` };
  }

  const jaFirst = firstDoc(ja);
  report(
    NAMES.jaLoaded,
    Boolean(ja && ja.uiLang === 'ja' && ja.contentLang === 'ja' && ja.banner === false),
    ja,
  );
  report(
    NAMES.jaNoNote,
    noteFreeEverywhere(ja),
    // The pinned note text is reported alongside so a REGRESSION (the
    // note reappearing) is named for what it is, not just "!== 0".
    { ja, wouldSay: MANUAL_FALLBACK_JA_TEXT },
  );
  report(
    NAMES.jaBody,
    Boolean(jaFirst && jaFirst.bodyChars > 100 && jaFirst.bodyLang === null
      && jaFirst.jaTextPresent === true && ja.docLang === 'ja'),
    { jaFirst, docLang: ja && ja.docLang, want: MANUAL_FALLBACK_DOCS[0].jaText },
  );
  report(
    NAMES.jaAllDocs,
    Boolean(ja && Array.isArray(ja.docs) && ja.docs.length === MANUAL_FALLBACK_DOCS.length
      && ja.docs.every((d) => d.jaTextPresent === true && d.bodyLang === null && d.bodyChars > 40)),
    { docs: ja && ja.docs, want: MANUAL_FALLBACK_DOCS.map((d) => ({ slug: d.slug, jaText: d.jaText })) },
  );

  await t.close();
  console.log(`browser-check --check-manual-fallback: ${passed}/${total} assertions passed`);
  await die(passed === total ? 0 : 1, null);
}

// ---------------------------------------------------------------------------
// M4: --device-only. Launches its own throwaway browser and runs ONLY
// runDeviceAssertions against --url -- the fast dev loop the sabotage
// sweep uses (each app mutation needs a rebuild + one targeted run, not
// a full 108-route sweep). Same launch idiom as --check-storage-refused.
// ---------------------------------------------------------------------------
async function runDeviceOnly(opts) {
  const deadline = Date.now() + opts.timeout;
  const cleanupFns = [];
  const runCleanup = async () => {
    for (const fn of cleanupFns.splice(0).reverse()) {
      try { await fn(); } catch { /* best-effort cleanup */ }
    }
  };
  const die = async (code, message) => {
    if (message) console.log(message);
    await runCleanup();
    process.exit(code);
  };

  const browserPath = resolveBrowser(opts.browser);
  if (!browserPath) {
    await die(2, 'error: no browser found for --device-only.');
    return;
  }
  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sxc1-deviceonly-profile-'));
  cleanupFns.push(() => removeDirWithRetry(userDataDir));
  const debugPort = await findFreePort();
  const browserProc = spawn(browserPath, [
    '--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run', '--no-default-browser-check',
    '--disable-dev-shm-usage', `--user-data-dir=${userDataDir}`, `--remote-debugging-port=${debugPort}`, 'about:blank',
  ], { stdio: 'ignore', detached: true });
  cleanupFns.push(() => new Promise((resolve) => {
    const killGroup = (signal) => { try { process.kill(-browserProc.pid, signal); } catch { /* gone */ } };
    if (browserProc.exitCode !== null || browserProc.signalCode !== null) { killGroup('SIGKILL'); resolve(); return; }
    const forceKillTimer = setTimeout(() => killGroup('SIGKILL'), 3000);
    browserProc.once('exit', () => { clearTimeout(forceKillTimer); killGroup('SIGKILL'); resolve(); });
    killGroup('SIGTERM');
  }));

  let versionInfo = null;
  while (Date.now() < deadline) {
    try {
      const info = await withDeadline(httpGetJson(`http://127.0.0.1:${debugPort}/json/version`), deadline, 'DevTools /json/version request');
      if (info && info.webSocketDebuggerUrl) { versionInfo = info; break; }
    } catch { /* not up yet */ }
    await sleep(200);
  }
  if (!versionInfo) {
    await die(2, 'error: timed out waiting for DevTools (--device-only)');
    return;
  }
  const ws = await withDeadline(connectWebSocket(versionInfo.webSocketDebuggerUrl), deadline, 'WebSocket connect');
  cleanupFns.push(() => { try { ws.close(); } catch { /* ignore */ } });
  const cdp = new CDPClient(ws, { getRemaining: () => remaining(deadline) });
  ws.addEventListener('close', () => cdp.failFatally(new Error('CDP WebSocket closed unexpectedly')));
  ws.addEventListener('error', (ev) => cdp.failFatally(new Error(`CDP WebSocket error: ${formatWsErrorEvent(ev)}`)));

  let passed = 0;
  let total = 0;
  const report = (name, ok, observed) => {
    total += 1;
    if (ok) { passed += 1; console.log(`ok - ${name}`); } else { console.log(`FAIL - ${name} (observed: ${JSON.stringify(observed)})`); }
  };
  try {
    const makeTarget = deviceTargetFactoryFor(cdp, deadline, opts.url);
    await runDeviceAssertions(makeTarget, report, DEVICE_REAL_CFG);
  } catch (err) {
    await die(2, `error: ${err && err.stack ? err.stack : err}`);
    return;
  }
  console.log(`browser-check --device-only: ${passed}/${total} assertions passed`);
  await die(passed === total ? 0 : 1, null);
}

// ---------------------------------------------------------------------------
// M3 gate fix NEW10: the per-selector sabotage map. Each key is exactly
// one M3 sabotage point (see its own comment inside selfTestFixtureHtml
// for how it is isolated); the value is the exact set of
// PROGRESS_ASSERTION_NAMES entries that selector's own --self-test-negative
// pass must see fail -- and, by the negative-sweep's own bookkeeping
// below, NOTHING ELSE. Two entries deliberately map more than one
// assertion name to a single selector (each documented at its own
// sabotage site as an intentional, honest single-root-cause group, not a
// leftover of the old megamutant):
//   'jaFirstPersist' -> both value AND order, since both read state from
//                        the one post-reload page load a skipped write
//                        equally corrupts.
// Every other selector maps to exactly one assertion.
// ---------------------------------------------------------------------------
const M3_SELECTOR_ASSERTIONS = {
  freshRecords: [PROGRESS_ASSERTION_NAMES.freshRecords],
  freshJaFirst: [PROGRESS_ASSERTION_NAMES.freshJaFirst],
  answerReloadCount: [PROGRESS_ASSERTION_NAMES.answerReloadCount],
  answerReloadInterval: [PROGRESS_ASSERTION_NAMES.answerReloadInterval],
  wipeEmpties: [PROGRESS_ASSERTION_NAMES.wipeEmpties],
  importPreview: [PROGRESS_ASSERTION_NAMES.importPreview],
  exportWipeImportRestores: [PROGRESS_ASSERTION_NAMES.exportWipeImportRestores],
  corruptBanner: [PROGRESS_ASSERTION_NAMES.corruptBanner],
  corruptNeverOverwritten: [PROGRESS_ASSERTION_NAMES.corruptNeverOverwritten],
  jaFirstPersist: [PROGRESS_ASSERTION_NAMES.jaFirstPersistsValue, PROGRESS_ASSERTION_NAMES.jaFirstPersistsOrder],
  jaFirstSurvivesWipe: [PROGRESS_ASSERTION_NAMES.jaFirstSurvivesWipe],
  jaToggleHidesAndSticks: [PROGRESS_ASSERTION_NAMES.jaToggleHidesAndSticks],
  reviewBadgeMatchesDue: [PROGRESS_ASSERTION_NAMES.reviewBadgeMatchesDue],
  deckCardTierMatches: [PROGRESS_ASSERTION_NAMES.deckCardTierMatches],
  continueMatchesLast: [PROGRESS_ASSERTION_NAMES.continueMatchesLast],
};

// The OLD (pre-NEW10) global-SABOTAGE=true expected-failure list, run
// today under selector 'legacy-all' -- unchanged in content from before
// this fix, since legacy-all's own sabotage behaviour is unchanged (see
// selfTestFixtureHtml's own comment on why legacy-all is kept at all).
const LEGACY_EXPECTED_TO_FAIL = [
  'wrong quiz answer: #ex-feedback starts with "Not quite" and carries class "incorrect"',
  'lookup: wrong page submits to "Not quite"',
  // M2 gate fix additions: legacy-all also forces elapsedMs to 0 (H1),
  // skips clearing quiz result state on Restart (H7), and omits
  // drill-step / graded-lookup citations (H8) -- see each's own comment
  // in the fixture builder above.
  COLD_ELAPSED_ASSERTION_NAME,
  // M2 re-gate addition: legacy-all leaves #sxc1-prompt-baseline "null"
  // (the lost-mount-Begin scenario), so the baseline assertion must fail
  // on cue too.
  COLD_BASELINE_ASSERTION_NAME,
  WARM_FIRST_ELAPSED_ASSERTION_NAME,
  'Restart yields a genuinely blank prompt: no #ex-feedback, no #ex-note, no #btn-ex-next, no option aria-pressed="true"',
  `a completed drill renders a.cite hrefs that are well-formed AND include the declared #/m/${SELF_TEST_FIXTURE.drill.citeSlug}/p/${SELF_TEST_FIXTURE.drill.citePage}`,
  `a graded (correct) lookup renders an a.cite whose href equals the declared #/m/${SELF_TEST_FIXTURE.lookup.targetSlug}/p/${SELF_TEST_FIXTURE.lookup.targetPage}`,
  // M3 harness wave: every M3 persistence/JA-first/corrupt-blob/
  // review-queue assertion name -- legacy-all still fires every one of
  // these sabotage points AT ONCE, exactly like the old global flag did.
  PROGRESS_ASSERTION_NAMES.freshRecords,
  PROGRESS_ASSERTION_NAMES.freshJaFirst,
  PROGRESS_ASSERTION_NAMES.wipeEmpties,
  PROGRESS_ASSERTION_NAMES.answerReloadCount,
  PROGRESS_ASSERTION_NAMES.answerReloadInterval,
  PROGRESS_ASSERTION_NAMES.importPreview,
  PROGRESS_ASSERTION_NAMES.exportWipeImportRestores,
  PROGRESS_ASSERTION_NAMES.corruptBanner,
  PROGRESS_ASSERTION_NAMES.corruptNeverOverwritten,
  PROGRESS_ASSERTION_NAMES.jaFirstPersistsValue,
  PROGRESS_ASSERTION_NAMES.jaFirstPersistsOrder,
  PROGRESS_ASSERTION_NAMES.jaFirstSurvivesWipe,
  PROGRESS_ASSERTION_NAMES.jaToggleHidesAndSticks,
  PROGRESS_ASSERTION_NAMES.reviewBadgeMatchesDue,
  PROGRESS_ASSERTION_NAMES.deckCardTierMatches,
];

// Launches ONE throwaway browser, builds the self-test fixture under
// exactly ONE `selector` (see selfTestFixtureHtml's own comment for what
// null/'legacy-all'/a named key each mean), drives PRE + exercise + POST
// assertions against it, and returns `{ results, passed, total }` --
// NEVER calls process.exit itself, so both callers below (--self-test:
// one pass, selector=null; --self-test-negative: many passes, one per
// selector) can each decide what "done" means. Always cleans up its own
// browser/profile/fixture file before returning OR throwing.
async function runOneSelfTestPass(opts, selector, { expectedExJson, verbose, includeDevice, includeJaFlow }) {
  const deadline = Date.now() + opts.timeout;
  const cleanupFns = [];
  const runCleanup = async () => {
    for (const fn of cleanupFns.splice(0).reverse()) {
      try { await fn(); } catch { /* best-effort cleanup */ }
    }
  };

  try {
    const browserPath = resolveBrowser(opts.browser);
    if (!browserPath) {
      throw new Error('no browser found for --self-test. Install Google Chrome/Chromium, or set ' +
        'SXC1_BROWSER to a browser executable path, or pass --browser <path>.');
    }

    const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sxc1-selftest-profile-'));
    cleanupFns.push(() => removeDirWithRetry(userDataDir));
    const debugPort = await findFreePort();
    const browserArgs = [
      '--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run', '--no-default-browser-check',
      '--disable-dev-shm-usage', `--user-data-dir=${userDataDir}`, `--remote-debugging-port=${debugPort}`, 'about:blank',
    ];
    const browserProc = spawn(browserPath, browserArgs, { stdio: 'ignore', detached: true });
    let cdp = null;
    let browserFailure = null;
    const noteBrowserFailure = (message) => {
      if (!browserFailure) browserFailure = new Error(message);
      if (cdp) cdp.failFatally(browserFailure);
    };
    browserProc.on('exit', (code, signal) => {
      noteBrowserFailure(`browser process exited unexpectedly (code=${code === null ? 'null' : code}, signal=${signal || 'none'})`);
    });
    browserProc.on('error', (err) => {
      noteBrowserFailure(`browser process error: ${err && err.message ? err.message : err}`);
    });
    cleanupFns.push(() => new Promise((resolve) => {
      const killGroup = (signal) => { try { process.kill(-browserProc.pid, signal); } catch { /* group already gone */ } };
      if (browserProc.exitCode !== null || browserProc.signalCode !== null) { killGroup('SIGKILL'); resolve(); return; }
      const forceKillTimer = setTimeout(() => killGroup('SIGKILL'), 3000);
      browserProc.once('exit', () => { clearTimeout(forceKillTimer); killGroup('SIGKILL'); resolve(); });
      killGroup('SIGTERM');
    }));

    let versionInfo = null;
    while (Date.now() < deadline) {
      if (browserFailure) {
        throw new Error(`${browserFailure.message} (before DevTools became reachable at ${browserPath})`);
      }
      try {
        const info = await withDeadline(
          httpGetJson(`http://127.0.0.1:${debugPort}/json/version`),
          deadline,
          'DevTools /json/version request',
        );
        if (info && info.webSocketDebuggerUrl) { versionInfo = info; break; }
      } catch { /* not up yet, or this attempt ran past the deadline */ }
      await sleep(200);
    }
    if (!versionInfo) {
      throw new Error(`timed out waiting for DevTools at 127.0.0.1:${debugPort} (--self-test)`);
    }

    const ws = await withDeadline(connectWebSocket(versionInfo.webSocketDebuggerUrl), deadline, 'WebSocket connect');
    cleanupFns.push(() => { try { ws.close(); } catch { /* ignore */ } });
    cdp = new CDPClient(ws, { getRemaining: () => remaining(deadline) });
    ws.addEventListener('close', () => cdp.failFatally(new Error('CDP WebSocket closed unexpectedly')));
    ws.addEventListener('error', (ev) => cdp.failFatally(new Error(`CDP WebSocket error: ${formatWsErrorEvent(ev)}`)));

    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

    const consoleErrors = [];
    const exceptions = [];
    cdp.on('Runtime.consoleAPICalled', (params, sid) => {
      if (sid !== sessionId) return;
      if (params.type === 'error') {
        consoleErrors.push((params.args || []).map((a) => a.description ?? a.value ?? String(a.type)).join(' '));
      }
    });
    cdp.on('Runtime.exceptionThrown', (params, sid) => {
      if (sid !== sessionId) return;
      const detail = params.exceptionDetails;
      exceptions.push(detail?.exception?.description || detail?.text || JSON.stringify(detail));
    });

    await cdp.send('Runtime.enable', {}, sessionId);
    await cdp.send('Page.enable', {}, sessionId);

    const evaluate = async (expression) => {
      const res = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, sessionId);
      if (res.exceptionDetails) {
        const d = res.exceptionDetails;
        throw new Error(`page evaluation error: ${d.exception?.description || d.text}`);
      }
      return res.result ? res.result.value : undefined;
    };

    // A real file:// URL, not a data: URL: hash-based routing (setting
    // window.location.hash and reacting to 'hashchange', exactly like the
    // real app) needs a URL that HAS a path for the fragment to attach to.
    // Still fully offline and hermetic -- a throwaway temp file removed in
    // the same cleanup pass as the browser profile.
    const html = selfTestFixtureHtml(selector);
    const fixturePath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'sxc1-selftest-html-')), 'fixture.html');
    fs.writeFileSync(fixturePath, html, 'utf8');
    cleanupFns.push(() => removeDirWithRetry(path.dirname(fixturePath)));
    await cdp.send('Page.navigate', { url: `file://${fixturePath}` }, sessionId);

    let booted = false;
    while (Date.now() < deadline) {
      let b;
      try { b = await evaluate('window.__SXC1_BOOTED === true'); } catch { b = false; }
      if (b === true) { booted = true; break; }
      await sleep(50);
    }
    if (!booted) {
      throw new Error('the self-test fixture never set window.__SXC1_BOOTED');
    }

    let passed = 0;
    let total = 0;
    const report = (name, ok, observed) => {
      total += 1;
      if (ok) {
        passed += 1;
        if (verbose) console.log(`ok - ${name}`);
      } else if (verbose) {
        console.log(`FAIL - ${name} (observed: ${JSON.stringify(observed)})`);
      }
    };
    const elementExists = (sel2) => evaluate(`document.querySelector(${JSON.stringify(sel2)}) !== null`);
    const assertElement = async (sel2, label) => {
      const exists = await elementExists(sel2);
      report(label, exists === true, exists);
      return exists === true;
    };
    const goto = (hash, readySelector, timeoutMs = 5000) => evaluate(`(async () => {
      window.location.hash = ${JSON.stringify(hash)};
      const start = Date.now();
      while (Date.now() - start < ${timeoutMs}) {
        if (document.querySelector(${JSON.stringify(readySelector)})) return true;
        await new Promise((r) => setTimeout(r, 20));
      }
      return document.querySelector(${JSON.stringify(readySelector)}) !== null;
    })()`);
    const click = (sel2) => evaluate(`document.querySelector(${JSON.stringify(sel2)}).click()`);
    const clickAssert = async (sel2, label) => {
      const present = await assertElement(sel2, `${sel2} is present before clicking it`);
      if (!present) { report(label, false, `skipped: ${sel2} not found`); return false; }
      try {
        await click(sel2);
        report(label, true, null);
        return true;
      } catch (err) {
        report(label, false, { error: err && err.message ? err.message : String(err) });
        return false;
      }
    };
    // P-D: Miso's onInput ignores a synthetic 'input' event dispatched from
    // page JavaScript; only a trusted CDP Input.insertText reaches it. This
    // clears the field with a direct .value assignment (never dispatches a
    // synthetic input event of its own) and then types via the real CDP
    // input pipeline, exactly as a real run must against the real app.
    const typeText = async (sel2, text) => {
      const focused = await evaluate(`(() => {
        const el = document.querySelector(${JSON.stringify(sel2)});
        if (!el) return false;
        el.focus();
        el.value = '';
        return true;
      })()`);
      if (!focused) return false;
      await cdp.send('Input.insertText', { text }, sessionId);
      return true;
    };
    const setMobileViewport = () => cdp.send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 3, mobile: true }, sessionId);
    const clearViewport = () => cdp.send('Emulation.clearDeviceMetricsOverride', {}, sessionId);
    const consoleHygiene = () => ({ ok: consoleErrors.length === 0 && exceptions.length === 0, consoleErrors, exceptions });
    // M5 a11y: trusted keyboard input for the keyboard-only flows.
    const pressKey = keyPresserFor(cdp, sessionId);

    // M3 harness wave: "reload" for the persistence assertions -- an
    // ordinary Page.reload of the SAME file:// fixture, which re-executes
    // the whole inline <script> from scratch (a fresh IIFE invocation,
    // module-scope vars reinitialised) while localStorage -- the very
    // thing under test -- survives, exactly mirroring the real run's own
    // reload (see that one's comment for the full rationale).
    // M6 W2: wait out a reload the PAGE started itself (#btn-ui-lang's
    // own location.reload) -- never issues Page.reload. A short grace
    // sleep first, so a poll racing ahead of the navigation cannot read
    // the OLD document's still-true __SXC1_BOOTED.
    const waitBooted = async (timeoutMs = 20000) => {
      await sleep(300);
      const bootDeadline = Date.now() + timeoutMs;
      while (Date.now() < bootDeadline) {
        let b;
        try { b = await evaluate('window.__SXC1_BOOTED === true'); } catch { b = false; }
        if (b === true) return true;
        await sleep(50);
      }
      return false;
    };

    const reload = async (readySelector, timeoutMs = 15000) => {
      await cdp.send('Page.reload', {}, sessionId);
      const bootDeadline = Date.now() + timeoutMs;
      let rebooted = false;
      while (Date.now() < bootDeadline) {
        let b;
        try { b = await evaluate('window.__SXC1_BOOTED === true'); } catch { b = false; }
        if (b === true) { rebooted = true; break; }
        await sleep(50);
      }
      if (!rebooted) throw new Error(`self-test fixture did not report __SXC1_BOOTED within ${timeoutMs}ms after reload`);
      if (readySelector) {
        const readyDeadline = Date.now() + timeoutMs;
        while (Date.now() < readyDeadline) {
          if (await evaluate(`document.querySelector(${JSON.stringify(readySelector)}) !== null`)) return true;
          await sleep(30);
        }
        return false;
      }
      return true;
    };

    // M2 gate fix (H1/H6/M5): --self-test's own coldLoadFn. A SECOND,
    // independent target attached to the SAME throwaway browser, whose
    // INITIAL navigation URL already carries the quiz's own deep-link hash
    // -- same technique as the real run's (below) and as NEW5's own JA
    // cold-load assertion. Kept on a separate target (rather than
    // Page.navigate-ing the primary session) so it can never leak state
    // into, or read stale state left by, the rest of runExerciseAssertions.
    const coldLoadFn = async (fx, cbReport, lang = 'en') => {
      const waitMs = 1200;
      const coldUrl = `file://${fixturePath}#/x/${fx.quiz.deck}/${fx.quiz.id}`;
      let coldTargetId = null;
      try {
        const created = await cdp.send('Target.createTarget', { url: coldUrl });
        coldTargetId = created.targetId;
        const attached = await cdp.send('Target.attachToTarget', { targetId: coldTargetId, flatten: true });
        const coldSessionId = attached.sessionId;
        await cdp.send('Runtime.enable', {}, coldSessionId);
        await cdp.send('Page.enable', {}, coldSessionId);
        const coldEvaluate = async (expression) => {
          const res = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, coldSessionId);
          if (res.exceptionDetails) {
            const d = res.exceptionDetails;
            throw new Error(`page evaluation error: ${d.exception?.description || d.text}`);
          }
          return res.result ? res.result.value : undefined;
        };
        let coldBooted = false;
        const bootDeadline = Math.min(deadline, Date.now() + 20000);
        while (Date.now() < bootDeadline) {
          let b;
          try { b = await coldEvaluate('window.__SXC1_BOOTED === true'); } catch { b = false; }
          if (b === true) { coldBooted = true; break; }
          await sleep(50);
        }
        if (!coldBooted) {
          cbReport(COLD_ELAPSED_ASSERTION_NAME, false, 'the self-test fixture never booted on the cold target');
          return;
        }
        const coldClickAssert = async (sel2, label) => {
          const present = await coldEvaluate(`document.querySelector(${JSON.stringify(sel2)}) !== null`);
          if (!present) { cbReport(label, false, `skipped: ${sel2} not found`); return false; }
          await coldEvaluate(`document.querySelector(${JSON.stringify(sel2)}).click()`);
          cbReport(label, true, null);
          return true;
        };
        await assertColdFirstTryElapsed({ evaluate: coldEvaluate, clickAssert: coldClickAssert, report: cbReport }, fx, waitMs, lang);
      } catch (err) {
        cbReport(COLD_ELAPSED_ASSERTION_NAME, false, `harness error: ${err && err.message ? err.message : String(err)}`);
      } finally {
        if (coldTargetId) {
          try { await cdp.send('Target.closeTarget', { targetId: coldTargetId }); } catch { /* best effort */ }
        }
      }
    };

    // M3 harness wave: the persistence/JA-first/corrupt-blob/review-queue
    // assertions, driven against THIS SAME fixture page (see
    // selfTestFixtureHtml's own M3 section above) via
    // runProgressAssertionsPre/Post -- the same "one function, two
    // callers" pattern as runExerciseAssertions. `report` here is the
    // outer report() (drives passed/total + console output); progressResults
    // separately tracks {name, ok} pairs so --self-test-negative's
    // expectedToFail matching below can see them, the same way `results`
    // does for the M2 ones.
    const progressResults = [];
    const progressReport = (name, ok, observed) => { progressResults.push({ name, ok }); report(name, ok, observed); };
    const progressHandle = { evaluate, report: progressReport, goto, click, clickAssert, assertElement, typeText, reload };
    const progressCfg = {
      quizDeck: SELF_TEST_FIXTURE.quiz.deck,
      quizId: SELF_TEST_FIXTURE.quiz.id,
      quizCorrectOpt: SELF_TEST_FIXTURE.quiz.correctOpt,
      quizWrongOpt: SELF_TEST_FIXTURE.quiz.wrongOpt,
      lookupDeck: SELF_TEST_FIXTURE.lookup.deck,
      lookupId: SELF_TEST_FIXTURE.lookup.id,
      lookupTargetPage: SELF_TEST_FIXTURE.lookup.targetPage,
      deckSlug: SELF_TEST_FIXTURE.quiz.deck,
      expectedTier: PROGRESS_SELF_TEST_TIER,
      manualSlug: 'demo-manual',
      manualPage: 1,
      manualNextPage: 2,
    };

    // PRE must run before ANYTHING touches localStorage, including
    // runExerciseAssertions below (its own cold-load quiz answer alone
    // would already make "records=0" false).
    await runProgressAssertionsPre(progressHandle, progressCfg);

    const results = await runExerciseAssertions(
      { evaluate, report, goto, click, clickAssert, assertElement, typeText, setMobileViewport, clearViewport, consoleHygiene, pressKey },
      SELF_TEST_FIXTURE,
      expectedExJson,
      coldLoadFn,
    );

    // POST does not rely on anything runExerciseAssertions left behind --
    // it starts with its own wipe + reload.
    await runProgressAssertionsPost(progressHandle, progressCfg);
    results.push(...progressResults);

    // M6 W2: the UI-language JA flow -- runs the whole exercise/a11y
    // assertion set a second time under lang='ja' plus the toggle's own
    // assertions, exactly as the real run does. Gated by includeJaFlow
    // (the plain --self-test, the negative sweep's 'clean' pass and the
    // M6W2 'uiLang*' passes) so every pre-W2 negative pass keeps its
    // expected-failure set and runtime byte-identical.
    if (includeJaFlow) {
      const jaFlowResults = await runUiLangJaAssertions(
        { evaluate, report, goto, click, clickAssert, assertElement, typeText, setMobileViewport, clearViewport, consoleHygiene, pressKey, reload, waitBooted },
        SELF_TEST_FIXTURE,
        coldLoadFn,
        { checkBundleFetch: false },
      );
      results.push(...jaFlowResults);
    }

    // M4: the device suite (D1..D25), driven against THIS SAME fixture
    // file through freshly created targets with scripts/fake-midi.js
    // pre-injected -- the same runDeviceAssertions a real run drives
    // against the real app. Gated by includeDevice: the ordinary
    // --self-test and every M4 'dev*' negative pass run it; the M3-era
    // negative passes (and legacy-all) do not, so their runtime and
    // expected-failure sets stay byte-identical to before M4.
    if (includeDevice) {
      const makeTarget = deviceTargetFactoryFor(cdp, deadline, `file://${fixturePath}`);
      const deviceReport = (name, ok, observed) => { results.push({ name, ok }); report(name, ok, observed); };
      await runDeviceAssertions(makeTarget, deviceReport, DEVICE_SELFTEST_CFG);
    }

    await runCleanup();
    return { results, passed, total };
  } catch (err) {
    await runCleanup();
    throw err;
  }
}

async function runSelfTest(opts, negative) {
  if (negative) {
    await runSelfTestNegative(opts);
    return;
  }

  let expectedExJson = SELF_TEST_EXERCISE_STATS;
  if (opts.expectExerciseJson) {
    let parsed;
    try {
      parsed = parseJsonOrFile(opts.expectExerciseJson, '--expect-exercise-json');
    } catch (err) {
      console.error(`error: ${err.message}`);
      process.exit(2);
      return;
    }
    const schemaError = validateExpectExerciseJson(parsed, '--expect-exercise-json');
    if (schemaError) {
      console.error(`error: ${schemaError}`);
      process.exit(2);
      return;
    }
    expectedExJson = parsed;
  }

  let outcome;
  try {
    // M4: the self-test now also runs the 25-assertion device suite
    // (see runOneSelfTestPass), which multiplies the fresh-target count;
    // the default 45s budget was tuned for the pre-M4 pass, so the floor
    // is raised here the same way the negative sweep already raises its
    // own. An explicit larger --timeout is still honoured.
    const passOpts = { ...opts, timeout: Math.max(opts.timeout, SELF_TEST_MIN_TIMEOUT_MS) };
    outcome = await runOneSelfTestPass(passOpts, null, { expectedExJson, verbose: true, includeDevice: true, includeJaFlow: true });
  } catch (err) {
    console.error(`error: ${err && err.message ? err.message : err}`);
    process.exit(2);
    return;
  }
  console.log(`browser-check --self-test: ${outcome.passed}/${outcome.total} assertions passed`);
  process.exit(outcome.passed === outcome.total ? 0 : 1);
}

const SELF_TEST_MIN_TIMEOUT_MS = 240000;

// M3 gate fix NEW10: runs ONE PASS PER SELECTOR (a "clean"/no-sabotage
// sanity pass, the 'legacy-all' combined pass, then one pass per
// M3_SELECTOR_ASSERTIONS key -- ~17 browser launches total, see
// selfTestFixtureHtml's own comment), asserting for EACH ONE that
// EXACTLY that pass's own mapped assertion(s) failed and nothing else
// did. Prints a per-selector summary line (ok/FAIL per pass) and an
// overall verdict; exits 0 only if every pass was individually clean.
// --self-test-negative-only <key> restricts this to a single named pass
// (a debugging aid -- not documented as part of the pass/fail contract,
// only as a faster dev loop).
// Sabotaged passes spend more of their own budget on purpose: a broken
// predicate polls to its FULL timeout instead of settling early (the
// 'legacy-all' pass alone carries 23 simultaneously-broken assertions,
// several of which are their own multi-second polls), and the
// jaFirstSurvivesWipe-style re-establish steps add a genuine extra
// reload. 45000ms (parseArgs' own --timeout default, tuned for a SINGLE
// ordinary run) measured too tight for 'legacy-all' specifically; this
// floor is applied ONLY inside the negative sweep, never to an ordinary
// --self-test or real-app run, and an explicit --timeout larger than
// this floor is still honoured.
// M5: raised from 90000 -- every pass now also carries the M5 a11y
// section (keyboard flows whose sabotaged variants deliberately walk
// their full two-round Tab budget plus the failed-poll windows), and
// 'legacy-all' was already the measured tight spot at the old floor.
// Purely an upper bound on hangs; it loosens no assertion.
const NEGATIVE_SWEEP_MIN_TIMEOUT_MS = 150000;

async function runSelfTestNegative(opts) {
  // includeDevice per pass (see runOneSelfTestPass): the M3-era passes
  // and legacy-all keep their pre-M4 shape and runtime exactly; 'clean'
  // and every M4 'dev*' pass also run the device suite, with the higher
  // budget floor that suite needs.
  const passesInOrder = [
    { key: 'clean', selector: null, expectedToFail: [], includeDevice: true, includeJaFlow: true },
    { key: 'legacy-all', selector: 'legacy-all', expectedToFail: LEGACY_EXPECTED_TO_FAIL, includeDevice: false },
    ...Object.keys(M3_SELECTOR_ASSERTIONS).map((key) => ({
      key, selector: key, expectedToFail: M3_SELECTOR_ASSERTIONS[key], includeDevice: false,
    })),
    ...Object.keys(M4_SELECTOR_ASSERTIONS).map((key) => ({
      key, selector: key, expectedToFail: M4_SELECTOR_ASSERTIONS[key], includeDevice: true,
    })),
    // M5 a11y passes -- includeDevice varies per selector (see the map's
    // own comment: two of the three need D26/D27 to run).
    ...Object.keys(M5_SELECTOR_ASSERTIONS).map((key) => ({
      key,
      selector: key,
      expectedToFail: M5_SELECTOR_ASSERTIONS[key].expectedToFail,
      includeDevice: M5_SELECTOR_ASSERTIONS[key].includeDevice,
    })),
    // M6 W1 pass -- the degraded-content surface leaking into a healthy
    // boot (sweep 37 -> 38).
    ...Object.keys(M6_SELECTOR_ASSERTIONS).map((key) => ({
      key,
      selector: key,
      expectedToFail: M6_SELECTOR_ASSERTIONS[key].expectedToFail,
      includeDevice: M6_SELECTOR_ASSERTIONS[key].includeDevice,
    })),
    // M6 W2 passes -- the UI-language sabotage points (sweep 38 -> 42).
    ...Object.keys(M6W2_SELECTOR_ASSERTIONS).map((key) => ({
      key,
      selector: key,
      expectedToFail: M6W2_SELECTOR_ASSERTIONS[key].expectedToFail,
      includeDevice: M6W2_SELECTOR_ASSERTIONS[key].includeDevice,
      includeJaFlow: M6W2_SELECTOR_ASSERTIONS[key].includeJaFlow,
    })),
  ];

  const onlyKey = opts.selfTestNegativeOnly;
  const runs = onlyKey ? passesInOrder.filter((p) => p.key === onlyKey) : passesInOrder;
  if (onlyKey && runs.length === 0) {
    console.error(`error: --self-test-negative-only '${onlyKey}' is not a known pass. Known passes: ${passesInOrder.map((p) => p.key).join(', ')}`);
    process.exit(2);
    return;
  }

  const summary = [];
  let anyFailed = false;
  for (let i = 0; i < runs.length; i++) {
    const pass = runs[i];
    console.log(`\n--self-test-negative: pass ${i + 1}/${runs.length} -- '${pass.key}'...`);
    let outcome;
    try {
      // Negative passes never validate --expect-exercise-json (that is
      // its own, separate --self-test-only negative control -- see
      // validateExpectExerciseJson's own comment); null here reproduces
      // the pre-NEW10 behaviour of comparing against the fixture's own
      // built-in SELF_TEST_EXERCISE_STATS regardless.
      const passOpts = {
        ...opts,
        timeout: Math.max(opts.timeout, pass.includeDevice ? SELF_TEST_MIN_TIMEOUT_MS : NEGATIVE_SWEEP_MIN_TIMEOUT_MS),
      };
      // eslint-disable-next-line no-await-in-loop
      outcome = await runOneSelfTestPass(passOpts, pass.selector, { expectedExJson: SELF_TEST_EXERCISE_STATS, verbose: false, includeDevice: pass.includeDevice, includeJaFlow: pass.includeJaFlow === true });
    } catch (err) {
      const message = `harness error: ${err && err.message ? err.message : err}`;
      console.error(`  FAIL - ${message}`);
      summary.push({ key: pass.key, ok: false, problems: [message] });
      anyFailed = true;
      continue;
    }
    const byName = new Map(outcome.results.map((r) => [r.name, r.ok]));
    const problems = [];
    for (const name of pass.expectedToFail) {
      if (byName.get(name) !== false) problems.push(`expected "${name}" to FAIL, but it passed (or did not run)`);
    }
    for (const r of outcome.results) {
      if (!pass.expectedToFail.includes(r.name) && r.ok === false) {
        problems.push(`unrelated assertion "${r.name}" unexpectedly failed`);
      }
    }
    if (problems.length === 0) {
      console.log(`  ok - ${pass.expectedToFail.length} assertion(s) failed on cue, nothing else did (${outcome.passed}/${outcome.total} passed overall)`);
      summary.push({ key: pass.key, ok: true });
    } else {
      console.error('  FAIL:');
      for (const p of problems) console.error(`    - ${p}`);
      summary.push({ key: pass.key, ok: false, problems });
      anyFailed = true;
    }
  }

  console.log(`\nbrowser-check --self-test-negative: per-selector summary (${runs.length} pass(es)):`);
  for (const s of summary) {
    console.log(`  ${s.ok ? 'ok  ' : 'FAIL'} - ${s.key}`);
  }
  if (anyFailed) {
    console.error('\nbrowser-check --self-test-negative: FAILED -- see per-selector summary above');
    process.exit(1);
  } else {
    console.log(`\nbrowser-check --self-test-negative: ok -- all ${runs.length} pass(es) caught exactly their own mapped assertion(s), nothing else`);
    process.exit(0);
  }
}

// ---------------------------------------------------------------------------
// Route helpers -- build the 108-route (or --quick sample) sweep list from
// DOC_PAGES, so the list of routes lives in exactly one place.
// ---------------------------------------------------------------------------

function fullRouteList() {
  const routes = [];
  for (const [slug, count] of Object.entries(DOC_PAGES)) {
    for (let n = 1; n <= count; n++) routes.push({ slug, n });
  }
  return routes;
}

function quickRouteList() {
  const routes = [];
  for (const [slug, count] of Object.entries(DOC_PAGES)) {
    const mid = Math.max(1, Math.ceil(count / 2));
    const set = new Set([1, mid, count]);
    for (const n of set) routes.push({ slug, n });
  }
  return routes;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const opts = parseArgs(process.argv.slice(2));

  // --self-test / --self-test-negative short-circuit the whole real-app
  // flow below: no --url, no static file server, nothing to boot except
  // the fixture itself. Mutually exclusive with each other; checked
  // before anything else so a --self-test run never needs a live server.
  if (opts.selfTest && opts.selfTestNegative) {
    console.error('error: --self-test and --self-test-negative are mutually exclusive');
    process.exit(2);
    return;
  }
  if (opts.selfTest || opts.selfTestNegative) {
    await runSelfTest(opts, opts.selfTestNegative === true);
    return;
  }

  // --check-storage-refused: also a full short-circuit (its own
  // throwaway browser, own target, own deadline) -- see its own --help
  // text and runStorageRefusedCheck's comment.
  if (opts.checkContentMissing) {
    await runContentMissingCheck(opts);
    return;
  }
  if (opts.checkBadBundle) {
    await runBadBundleCheck(opts);
    return;
  }
  if (opts.checkContentStalled) {
    await runContentStalledCheck(opts);
    return;
  }
  if (opts.checkHintWriteFailure) {
    await runHintWriteFailureCheck(opts);
    return;
  }
  if (opts.checkJaToggle) {
    await runJaToggleCheck(opts);
    return;
  }
  if (opts.checkBadManualBundle) {
    await runBadManualBundleCheck(opts);
    return;
  }
  if (opts.checkManualFallback) {
    await runManualFallbackCheck(opts);
    return;
  }
  if (opts.checkStorageRefused) {
    await runStorageRefusedCheck(opts);
    return;
  }

  // --device-only (M4): the D-suite alone against --url, in its own
  // throwaway browser -- the sabotage sweep's fast cycle.
  if (opts.deviceOnly) {
    await runDeviceOnly(opts);
    return;
  }

  const deadline = Date.now() + opts.timeout;

  const cleanupFns = [];
  const runCleanup = async () => {
    for (const fn of cleanupFns.splice(0).reverse()) {
      try {
        await fn();
      } catch {
        // best-effort cleanup; nothing useful to do if it fails
      }
    }
  };

  let sigintHandled = false;
  const onSigint = async () => {
    if (sigintHandled) return;
    sigintHandled = true;
    console.error('\ninterrupted, cleaning up...');
    await runCleanup();
    process.exit(130);
  };
  process.on('SIGINT', onSigint);

  const die = async (code, message) => {
    if (message) console.error(message);
    await runCleanup();
    process.off('SIGINT', onSigint);
    process.exit(code);
  };

  // Set once the CDP client exists, so the browser-process and WebSocket
  // failure listeners below (some registered before the client exists) can
  // reject any command that is in flight -- or sent later -- when the
  // browser dies out from under us, instead of leaving it pending forever.
  let cdp = null;

  // Set by the browser child's 'exit' (unexpected) or 'error' event. Checked
  // by the pre-CDP DevTools-poll loop; fans out to cdp.failFatally() once
  // the CDP client exists so an in-flight or future command fails fast with
  // a message naming the exit code/signal instead of hanging.
  let browserFailure = null;
  const noteBrowserFailure = (message) => {
    if (!browserFailure) browserFailure = new Error(message);
    if (cdp) cdp.failFatally(browserFailure);
  };

  // Load --expect-json up front so a bad path fails fast, before we ever
  // launch a browser.
  let expected = { docs: GOLDEN_DOCS, fields: GOLDEN_FIELDS, full: false };
  if (opts.expectJson) {
    let raw;
    try {
      raw = fs.readFileSync(opts.expectJson, 'utf8');
    } catch (err) {
      console.error(`error: could not read --expect-json file '${opts.expectJson}': ${err.message}`);
      process.exit(2);
      return;
    }
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (err) {
      console.error(`error: --expect-json file '${opts.expectJson}' is not valid JSON: ${err.message}`);
      process.exit(2);
      return;
    }
    // NEW9 fix: reject a malformed or vacuous expectation (wrong document
    // set, missing fields, duplicate slugs) here, before a browser is even
    // launched, rather than silently comparing against whatever subset was
    // supplied and reporting a hollow pass.
    const schemaError = validateExpectJson(parsed, opts.expectJson);
    if (schemaError) {
      console.error(`error: ${schemaError}`);
      process.exit(2);
      return;
    }
    expected = { docs: parsed.docs, fields: null, full: true };
  }

  // M2: load --exercise-fixture / --expect-exercise-json up front too, for
  // the same reason -- a bad fixture must not launch a browser first. Both
  // are optional: when --exercise-fixture is absent, the M2 exercise
  // assertions below are skipped entirely (reported, not silently
  // omitted) rather than run against nothing.
  let exerciseFixture = null;
  if (opts.exerciseFixture) {
    let parsed;
    try {
      parsed = parseJsonOrFile(opts.exerciseFixture, '--exercise-fixture');
    } catch (err) {
      console.error(`error: ${err.message}`);
      process.exit(2);
      return;
    }
    const fixtureError = validateExerciseFixture(parsed);
    if (fixtureError) {
      console.error(`error: ${fixtureError}`);
      process.exit(2);
      return;
    }
    exerciseFixture = parsed;
  }
  let expectedExerciseJson = null;
  if (opts.expectExerciseJson) {
    let parsed;
    try {
      parsed = parseJsonOrFile(opts.expectExerciseJson, '--expect-exercise-json');
    } catch (err) {
      console.error(`error: ${err.message}`);
      process.exit(2);
      return;
    }
    const schemaError = validateExpectExerciseJson(parsed, '--expect-exercise-json');
    if (schemaError) {
      console.error(`error: ${schemaError}`);
      process.exit(2);
      return;
    }
    expectedExerciseJson = parsed;
  }

  try {
    const targetUrl = opts.url;

    // 1. Resolve the browser executable. Missing browser is a hard failure.
    const browserPath = resolveBrowser(opts.browser);
    if (!browserPath) {
      await die(2, 'error: no browser found. Install Google Chrome/Chromium, or set ' +
        'SXC1_BROWSER to a browser executable path, or pass --browser <path>.');
      return;
    }

    // 2. Launch it headless with a throwaway profile and a free debugging port.
    const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sxc1-browsercheck-profile-'));
    cleanupFns.push(() => removeDirWithRetry(userDataDir));

    const debugPort = await findFreePort();
    const browserArgs = [
      '--headless=new',
      '--disable-gpu',
      '--no-sandbox',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-dev-shm-usage',
      `--user-data-dir=${userDataDir}`,
      `--remote-debugging-port=${debugPort}`,
      'about:blank',
    ];
    // detached:true makes browserProc the leader of a brand-new process
    // group. Chrome forks helper processes (zygote, GPU process, renderer)
    // that inherit that same group, so killing the *group* (negative pid)
    // reaches them even though Node only ever tracked the one PID directly
    // -- a plain SIGTERM to just the main PID can leave those helpers
    // running just long enough to keep writing into --user-data-dir after
    // our own cleanup has already tried to remove it.
    const browserProc = spawn(browserPath, browserArgs, { stdio: 'ignore', detached: true });
    // Any exit/error of the browser child while we still need it is a
    // harness failure: note it so both the early DevTools-poll loop and
    // any CDP command already or later in flight can fail fast instead of
    // hanging until the overall deadline.
    browserProc.on('exit', (code, signal) => {
      noteBrowserFailure(
        `browser process exited unexpectedly (code=${code === null ? 'null' : code}, signal=${signal || 'none'})`,
      );
    });
    browserProc.on('error', (err) => {
      noteBrowserFailure(`browser process error: ${err && err.message ? err.message : err}`);
    });
    if (!opts.keepOpen) {
      cleanupFns.push(() => new Promise((resolve) => {
        const killGroup = (signal) => {
          try { process.kill(-browserProc.pid, signal); } catch { /* group already gone */ }
        };
        if (browserProc.exitCode !== null || browserProc.signalCode !== null) {
          killGroup('SIGKILL'); // sweep any surviving helper processes
          resolve();
          return;
        }
        const forceKillTimer = setTimeout(() => killGroup('SIGKILL'), 3000);
        browserProc.once('exit', () => {
          clearTimeout(forceKillTimer);
          killGroup('SIGKILL'); // final sweep for stragglers
          resolve();
        });
        killGroup('SIGTERM');
      }));
    } else {
      browserProc.unref();
    }

    // 3. Poll /json/version until the browser's DevTools HTTP endpoint answers.
    let versionInfo = null;
    while (Date.now() < deadline) {
      if (browserFailure) {
        await die(2, `error: ${browserFailure.message} (before DevTools became reachable at ${browserPath})`);
        return;
      }
      try {
        const info = await withDeadline(
          httpGetJson(`http://127.0.0.1:${debugPort}/json/version`),
          deadline,
          'DevTools /json/version request',
        );
        if (info && info.webSocketDebuggerUrl) {
          versionInfo = info;
          break;
        }
      } catch {
        // not up yet, or this attempt ran past the deadline -- the loop
        // condition above is what ultimately bounds total wait time
      }
      await sleep(200);
    }
    if (!versionInfo) {
      await die(2, `error: timed out waiting for DevTools at 127.0.0.1:${debugPort}`);
      return;
    }

    // 4. Connect and set up a flat CDP session for a fresh page target.
    // The handshake itself is bounded by the shared deadline: a peer that
    // accepts the TCP connection but never completes the WebSocket upgrade
    // must not be able to hang the run.
    const ws = await withDeadline(
      connectWebSocket(versionInfo.webSocketDebuggerUrl),
      deadline,
      'WebSocket connect',
    );
    cleanupFns.push(() => { try { ws.close(); } catch { /* ignore */ } });
    cdp = new CDPClient(ws, { getRemaining: () => remaining(deadline) });

    // If the socket dies underneath us -- cleanly or not -- no in-flight
    // (or future) CDP command may be left hanging.
    ws.addEventListener('close', () => {
      cdp.failFatally(new Error('CDP WebSocket closed unexpectedly'));
    });
    ws.addEventListener('error', (ev) => {
      cdp.failFatally(new Error(`CDP WebSocket error: ${formatWsErrorEvent(ev)}`));
    });

    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

    // NEW5: the cold-load assertion below attaches a SECOND, independent
    // target/session. trackedSessions is every session whose console
    // errors / uncaught exceptions / network failures should count toward
    // this run, so that a fresh target is covered by the same hygiene
    // checks as the primary one instead of flying under the radar.
    const trackedSessions = new Set([sessionId]);

    // 5. Enable Runtime/Page/Network and record console errors + uncaught
    // exceptions + failed resource loads for the ENTIRE run (every
    // navigation below shares this one page target, so this one listener
    // set covers the whole sweep; the cold-load target adds its own
    // session id to trackedSessions when it is created).
    const consoleErrors = [];
    const exceptions = [];
    cdp.on('Runtime.consoleAPICalled', (params, sid) => {
      if (!trackedSessions.has(sid)) return;
      if (params.type === 'error') {
        const text = (params.args || []).map((a) => a.description ?? a.value ?? String(a.type)).join(' ');
        consoleErrors.push(text);
      }
    });
    cdp.on('Runtime.exceptionThrown', (params, sid) => {
      if (!trackedSessions.has(sid)) return;
      const detail = params.exceptionDetails;
      exceptions.push(detail?.exception?.description || detail?.text || JSON.stringify(detail));
    });

    // NEW6: Network-domain failure listeners, armed for the whole run, so
    // a failed fetch (connection refused, aborted, DNS, ...) is reported
    // by URL rather than only ever surfacing as a silent per-route
    // timeout. requestUrls maps requestId -> URL (populated from
    // requestWillBeSent) so a later loadingFailed event can name what
    // failed; imageResourceFailures collects the subset that looks like a
    // page image.
    const requestUrls = new Map();
    const imageResourceFailures = [];
    cdp.on('Network.requestWillBeSent', (params, sid) => {
      if (!trackedSessions.has(sid)) return;
      requestUrls.set(params.requestId, params.request && params.request.url);
    });
    cdp.on('Network.loadingFailed', (params, sid) => {
      if (!trackedSessions.has(sid)) return;
      const url = requestUrls.get(params.requestId) || '(unknown url)';
      if (params.type === 'Image' || /\/pages\/.*\.webp(\?|$)/.test(url)) {
        imageResourceFailures.push({ url, errorText: params.errorText, canceled: Boolean(params.canceled) });
      }
    });

    await cdp.send('Runtime.enable', {}, sessionId);
    await cdp.send('Page.enable', {}, sessionId);
    await cdp.send('Network.enable', {}, sessionId);

    // Evaluate an expression in the page and return its value, throwing on
    // a JS-level exception (as opposed to a CDP transport error). Routed
    // through cdp.send(), so it is bounded by the shared deadline and by
    // failFatally() the same way every other command is. awaitPromise:true
    // lets a single evaluate() run an internal poll loop (used throughout
    // below to wait for a settled render without round-tripping to Node
    // for every tick). Defaults to the primary session; the cold-load
    // assertion passes its own fresh session id.
    const evaluate = async (expression, sid = sessionId) => {
      const res = await cdp.send('Runtime.evaluate', {
        expression,
        returnByValue: true,
        awaitPromise: true,
      }, sid);
      if (res.exceptionDetails) {
        const d = res.exceptionDetails;
        throw new Error(`page evaluation error: ${d.exception?.description || d.text}`);
      }
      return res.result ? res.result.value : undefined;
    };

    // 6. Navigate, then poll until __SXC1_BOOTED or __SXC1_BOOT_ERROR appears.
    await cdp.send('Page.navigate', { url: targetUrl }, sessionId);

    let bootOutcome = null;
    while (Date.now() < deadline) {
      const state = await evaluate(`(() => {
        if (typeof window.__SXC1_BOOT_ERROR === 'string') return { error: window.__SXC1_BOOT_ERROR };
        if (window.__SXC1_BOOTED === true) return { booted: true };
        return { pending: true };
      })()`);
      if (state && typeof state.error === 'string') {
        bootOutcome = { ok: false, error: state.error };
        break;
      }
      if (state && state.booted) {
        bootOutcome = { ok: true };
        break;
      }
      await sleep(100);
    }

    // 7. Run assertions.
    let passed = 0;
    let total = 0;
    const report = (name, ok, observed) => {
      total += 1;
      if (ok) {
        passed += 1;
        console.log(`ok - ${name}`);
      } else {
        console.log(`FAIL - ${name} (observed: ${JSON.stringify(observed)})`);
      }
    };

    // m3(a)/(b) fix (carried over from M0): never let a missing required
    // DOM node throw out of this block (which would escape as an uncaught
    // exception and get misreported as exit 2 "harness error") and never
    // treat absence as a pass. elementExists()/assertElement() always
    // resolve to a boolean and always go through report(), so a missing
    // node is an ordinary FAILED assertion (exit 1).
    const elementExists = (selector) => evaluate(
      `document.querySelector(${JSON.stringify(selector)}) !== null`,
    );
    const assertElement = async (selector, label) => {
      const exists = await elementExists(selector);
      report(label, exists === true, exists);
      return exists === true;
    };

    // Set window.location.hash and poll (inside the page, one round trip)
    // until `readySelector` appears -- this is how every navigation below
    // waits for a settled render instead of a fixed sleep.
    const goto = async (hash, readySelector, timeoutMs = 5000) => evaluate(`(async () => {
      window.location.hash = ${JSON.stringify(hash)};
      const start = Date.now();
      while (Date.now() - start < ${timeoutMs}) {
        if (document.querySelector(${JSON.stringify(readySelector)})) return true;
        await new Promise((r) => setTimeout(r, 20));
      }
      return document.querySelector(${JSON.stringify(readySelector)}) !== null;
    })()`);

    const click = (selector) => evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
    const clickAssert = async (selector, label) => {
      const present = await assertElement(selector, `${selector} is present before clicking it`);
      if (!present) {
        report(label, false, `skipped: ${selector} not found`);
        return false;
      }
      try {
        await click(selector);
        report(label, true, null);
        return true;
      } catch (err) {
        report(label, false, { error: err && err.message ? err.message : String(err) });
        return false;
      }
    };

    if (!bootOutcome || !bootOutcome.ok) {
      // The app never booted successfully. This is the single most useful
      // diagnostic this tool produces, so surface it loudly and skip the
      // remaining assertions rather than pretend they ran.
      if (bootOutcome && bootOutcome.error) {
        console.error(`window.__SXC1_BOOT_ERROR: ${bootOutcome.error}`);
        report('app boots (window.__SXC1_BOOTED becomes true)', false, { bootError: bootOutcome.error });
      } else {
        console.error('timed out waiting for window.__SXC1_BOOTED / window.__SXC1_BOOT_ERROR');
        report('app boots (window.__SXC1_BOOTED becomes true)', false, { timeout: true });
      }
      for (const name of [
        '#boot-status is hidden after boot',
        '#sxc1-content-stats is valid JSON',
        '#sxc1-content-stats matches expected stats',
        'home phone QR is loaded and visible at desktop and mobile widths',
        '#/m/guide-book TOC contains the five PART titles',
        '#/m/guide-book/p/17 renders the expected text',
        'JA toggle shows a decoded original-page image',
        'JA toggle hides the panel again',
        '#/m/guide-book/p/17/ja deep-links into the JA-visible state (warm)',
        '#/m/guide-book/p/17/ja deep-links into the JA-visible state on a genuinely cold load',
        'next/prev navigation',
        'page 1 has no enabled prev / last page has no enabled next',
        'guide-book p.15 has a p.17 cross-reference link',
        '108-route sweep with JA image decode',
        'mobile viewport has no horizontal overflow',
        'mobile sweep at 360x640: no horizontal overflow across the main routes',
        'mobile sweep at 320x568: no horizontal overflow across the main routes',
        '#sxc1-disclaimer names CASIO and non-affiliation',
        'no console errors or uncaught exceptions',
        // M4: the device suite runs on its own fresh targets, but a
        // bundle whose primary target cannot boot is not going to boot
        // them either -- report the D-assertions as failed-skipped
        // rather than silently omitting them.
        ...Object.values(DEVICE_ASSERTION_NAMES),
      ]) {
        report(name, false, 'skipped: app did not boot');
      }
    } else {
      // -- 1. Boot / #boot-status ------------------------------------------------
      const bootStatus = await evaluate(`(() => {
        const e = document.querySelector('#boot-status');
        if (!e) return { exists: false, hidden: false };
        return { exists: true, hidden: Boolean(e.hidden) || e.offsetParent === null };
      })()`);
      report(
        '#boot-status is hidden after boot',
        Boolean(bootStatus && bootStatus.exists === true && bootStatus.hidden === true),
        bootStatus,
      );

      // -- 2. #sxc1-content-stats vs --expect-json / golden numbers --------------
      const statsRaw = await evaluate(`(() => {
        const e = document.querySelector('#sxc1-content-stats');
        return e ? e.textContent : null;
      })()`);
      let statsParsed = null;
      try { statsParsed = JSON.parse(statsRaw); } catch { /* reported below */ }
      report('#sxc1-content-stats is valid JSON', statsParsed !== null, statsRaw);

      if (statsParsed) {
        const mismatches = [];
        const actualDocs = Array.isArray(statsParsed.docs) ? statsParsed.docs : [];
        const expectedSlugs = new Set(expected.docs.map((d) => d.slug));
        for (const edoc of expected.docs) {
          const adoc = actualDocs.find((d) => d.slug === edoc.slug);
          if (!adoc) { mismatches.push(`${edoc.slug}: missing from app stats`); continue; }
          const fields = expected.full ? Object.keys(edoc) : expected.fields;
          for (const f of fields) {
            if (JSON.stringify(adoc[f]) !== JSON.stringify(edoc[f])) {
              mismatches.push(`${edoc.slug}.${f}: got ${JSON.stringify(adoc[f])} want ${JSON.stringify(edoc[f])}`);
            }
          }
        }
        // NEW9 fix, made an EXACT MULTISET comparison for NEW9-partial
        // (briefs/M2-manifest.json, task "exercise-ui"): the previous
        // reverse direction was a Set-membership test, so two actual
        // documents sharing the same known slug were both silently
        // accepted. Count occurrences of every actual slug: more than one
        // is a duplicate-slug mismatch in its own right, and any slug
        // outside the expected set is still a mismatch as before.
        const actualSlugCounts = new Map();
        for (const adoc of actualDocs) {
          if (adoc && typeof adoc.slug === 'string') {
            actualSlugCounts.set(adoc.slug, (actualSlugCounts.get(adoc.slug) || 0) + 1);
          }
        }
        for (const [slug, count] of actualSlugCounts) {
          if (count > 1) mismatches.push(`${slug}: appears ${count} times in app stats (duplicate slug)`);
          if (!expectedSlugs.has(slug)) mismatches.push(`${slug}: present in app stats but not named in the expected document set`);
        }
        report(
          `#sxc1-content-stats matches ${opts.expectJson ? `--expect-json ${opts.expectJson}` : 'the golden numbers'}`,
          mismatches.length === 0,
          mismatches,
        );
      } else {
        report('#sxc1-content-stats matches expected stats', false, 'skipped: stats JSON did not parse');
      }

      // -- 3. Home phone handoff: the SVG loads and remains visible at both the
      // desktop and mobile widths where users can discover/share it. The SVG's
      // own four-module border plus the link's white padding must also provide
      // the quiet zone camera QR readers expect. img.decode()/naturalWidth are
      // intentional: a successful fetch is not proof that the browser could
      // parse and render an SVG (malformed XML can still return HTTP 200).
      await goto('#/', '#sxc1-phone-qr');
      const desktopQr = await evaluate(`(async () => {
        const aside = document.querySelector('#sxc1-phone-qr');
        const link = document.querySelector('#sxc1-phone-qr .phone-qr-link');
        const img = document.querySelector('#sxc1-phone-qr-img');
        let asset = null;
        let decoded = false;
        let decodeError = null;
        if (img) {
          try {
            const response = await fetch(img.src, { cache: 'no-store' });
            const body = await response.blob();
            asset = { status: response.status, bytes: body.size, type: body.type };
          } catch (e) {
            asset = { error: String(e && e.message ? e.message : e) };
          }
          try {
            await img.decode();
            decoded = img.naturalWidth > 0 && img.naturalHeight > 0;
          } catch (e) {
            decodeError = String(e && e.message ? e.message : e);
          }
        }
        const asideBox = aside ? aside.getBoundingClientRect() : null;
        const imgBox = img ? img.getBoundingClientRect() : null;
        const modulePx = imgBox ? imgBox.width / 37 : 0;
        const paddingPx = link ? parseFloat(getComputedStyle(link).paddingLeft) : 0;
        return {
          asideVisible: Boolean(aside && getComputedStyle(aside).display !== 'none'
            && asideBox && asideBox.width > 0 && asideBox.height > 0),
          imageRendered: Boolean(img && img.complete && decoded
            && imgBox && imgBox.width >= 160 && imgBox.height >= 160
            && asset && asset.status === 200 && asset.bytes > 1000
            && asset.type === 'image/svg+xml'),
          src: img ? img.src : null,
          href: link ? link.href : null,
          asset,
          decoded,
          decodeError,
          naturalWidth: img ? img.naturalWidth : null,
          naturalHeight: img ? img.naturalHeight : null,
          effectiveQuietModules: modulePx > 0 ? 4 + paddingPx / modulePx : 0,
        };
      })()`);
      await cdp.send('Emulation.setDeviceMetricsOverride', {
        width: 390, height: 844, deviceScaleFactor: 3, mobile: true,
      }, sessionId);
      const mobileQr = await evaluate(`(() => {
        const aside = document.querySelector('#sxc1-phone-qr');
        const box = aside ? aside.getBoundingClientRect() : null;
        return {
          visible: Boolean(aside && getComputedStyle(aside).display !== 'none'
            && box && box.width > 0 && box.height > 0),
          display: aside ? getComputedStyle(aside).display : null,
          width: box ? box.width : null,
          viewport: window.innerWidth,
        };
      })()`);
      await cdp.send('Emulation.clearDeviceMetricsOverride', {}, sessionId);
      report(
        'home phone QR is loaded and visible at desktop and mobile widths',
        Boolean(desktopQr && desktopQr.asideVisible && desktopQr.imageRendered
          && typeof desktopQr.src === 'string' && desktopQr.src.endsWith('/qr-phone.svg')
          && desktopQr.href === 'https://sexy-one-gray.vercel.app/'
          && desktopQr.effectiveQuietModules >= 4
          && mobileQr && mobileQr.visible && mobileQr.viewport === 390),
        { desktopQr, mobileQr },
      );

      // -- 4. guide-book TOC has the five exact PART titles -----------------------
      await goto('#/m/guide-book', '#sxc1-toc');
      const tocText = await evaluate(`(() => {
        const e = document.querySelector('#sxc1-toc');
        return e ? e.textContent : null;
      })()`);
      const missingParts = GUIDE_BOOK_PART_TITLES.filter((t) => !(tocText || '').includes(t));
      report(
        '#/m/guide-book TOC contains the five PART titles',
        missingParts.length === 0,
        { missingParts },
      );

      // -- 5. guide-book p.17 renders #page-17 with the expected text ------------
      await goto('#/m/guide-book/p/17', '#page-17');
      const page17 = await evaluate(`(() => {
        const e = document.querySelector('#page-17');
        return e ? e.textContent : null;
      })()`);
      report(
        '#/m/guide-book/p/17 renders #page-17 containing the expected text',
        Boolean(page17 && page17.includes('Tap the pads to make sounds')),
        (page17 || '').slice(0, 120),
      );

      // -- 6. JA toggle: image really decodes, then hides again -------------------
      await clickAssert('#btn-ja-toggle', 'click #btn-ja-toggle');
      const jaShown = await evaluate(`(async () => {
        const start = Date.now();
        while (Date.now() - start < 5000) {
          const img = document.querySelector('#ja-image');
          if (img && img.complete && img.naturalWidth > 0) {
            return { ok: true, src: img.getAttribute('src'), naturalWidth: img.naturalWidth };
          }
          await new Promise((r) => setTimeout(r, 30));
        }
        const img = document.querySelector('#ja-image');
        return { ok: false, exists: !!img, complete: img ? img.complete : null, naturalWidth: img ? img.naturalWidth : null };
      })()`);
      report(
        'JA toggle shows a decoded original-page image',
        Boolean(jaShown && jaShown.ok && typeof jaShown.src === 'string' && jaShown.src.endsWith('pages/guide-book/page-17.webp')),
        jaShown,
      );

      await clickAssert('#btn-ja-toggle', 'click #btn-ja-toggle again');
      const jaHidden = await evaluate(`(async () => {
        const start = Date.now();
        while (Date.now() - start < 3000) {
          if (document.querySelector('#ja-panel') === null) return true;
          await new Promise((r) => setTimeout(r, 20));
        }
        return document.querySelector('#ja-panel') === null;
      })()`);
      report('JA toggle hides the panel again', jaHidden === true, jaHidden);

      // -- 6. .../p/17/ja deep-links into the JA-visible state via an in-app
      // hash change on the already-booted page ("warm": this exercises the
      // hashchange subscription, not the startup-hash handling -- see the
      // genuinely cold assertion right after it for that). -----------------
      await goto('#/m/guide-book/p/17/ja', '#ja-panel');
      const deepLinked = await evaluate(`(() => {
        const article = document.querySelector('#sxc1-page');
        const img = document.querySelector('#ja-image');
        return {
          hasJaClass: !!(article && article.classList.contains('ja-visible')),
          panelExists: document.querySelector('#ja-panel') !== null,
          imgOk: !!(img && img.complete && img.naturalWidth > 0),
        };
      })()`);
      report(
        '#/m/guide-book/p/17/ja deep-links into the JA-visible state via an in-app hash change (warm)',
        Boolean(deepLinked && deepLinked.hasJaClass && deepLinked.panelExists && deepLinked.imgOk),
        deepLinked,
      );

      // -- 6b (NEW5 fix). GENUINELY cold load: a fresh CDP target whose
      // INITIAL navigation URL already carries '#/m/guide-book/p/17/ja',
      // so the assertion exercises whatever the app does with the startup
      // hash rather than an in-session hashchange. Boot and image decode
      // are awaited independently on this fresh target; it never inherits
      // any state (DOM, cache warmth, decoded-image state) from the
      // primary target above. Closed again once the assertion is done.
      const coldBase = targetUrl.replace(/#.*$/, '');
      const coldUrl = `${coldBase}#/m/guide-book/p/17/ja`;
      let coldTargetId = null;
      let coldResult = { ok: false, reason: 'cold-load assertion did not run' };
      try {
        const createdCold = await cdp.send('Target.createTarget', { url: coldUrl });
        coldTargetId = createdCold.targetId;
        const attachedCold = await cdp.send('Target.attachToTarget', { targetId: coldTargetId, flatten: true });
        const coldSessionId = attachedCold.sessionId;
        trackedSessions.add(coldSessionId);
        await cdp.send('Runtime.enable', {}, coldSessionId);
        await cdp.send('Page.enable', {}, coldSessionId);

        // Poll for boot independently on the cold target -- it must not
        // inherit bootOutcome from the primary target above.
        let coldBoot = null;
        const coldBootDeadline = Math.min(deadline, Date.now() + 20000);
        while (Date.now() < coldBootDeadline) {
          const state = await evaluate(`(() => {
            if (typeof window.__SXC1_BOOT_ERROR === 'string') return { error: window.__SXC1_BOOT_ERROR };
            if (window.__SXC1_BOOTED === true) return { booted: true };
            return { pending: true };
          })()`, coldSessionId);
          if (state && typeof state.error === 'string') { coldBoot = { ok: false, error: state.error }; break; }
          if (state && state.booted) { coldBoot = { ok: true }; break; }
          await sleep(100);
        }

        if (!coldBoot || !coldBoot.ok) {
          coldResult = { ok: false, reason: 'cold target failed to boot', coldBoot };
        } else {
          coldResult = await evaluate(`(async () => {
            const start = Date.now();
            while (Date.now() - start < 5000) {
              if (document.querySelector('#page-17') && document.querySelector('#ja-panel')) break;
              await new Promise((r) => setTimeout(r, 20));
            }
            const article = document.querySelector('#sxc1-page');
            const panel = document.querySelector('#ja-panel');
            const img = document.querySelector('#ja-image');
            const hasPage17 = document.querySelector('#page-17') !== null;
            const hash = window.location.hash;
            if (!hasPage17 || !panel || !img) {
              return { ok: false, hash, hasPage17, panelExists: !!panel, hasImg: !!img };
            }
            const src = img.getAttribute('src');
            if (!src || !src.endsWith('pages/guide-book/page-17.webp')) {
              return { ok: false, hash, reason: 'unexpected #ja-image src', src };
            }
            // See the sweep below for why this is needed: <img loading=
            // "lazy"> can defer the fetch by a variable amount in a
            // headless tab even though the fetch itself is instant.
            img.loading = 'eager';
            try {
              await Promise.race([
                img.decode(),
                new Promise((_, rej) => setTimeout(() => rej(new Error('decode timed out')), 5000)),
              ]);
            } catch (e) {
              return { ok: false, hash, reason: 'decode failed: ' + (e && e.message ? e.message : String(e)) };
            }
            return {
              ok: true,
              hash,
              hasJaClass: !!(article && article.classList.contains('ja-visible')),
              panelExists: true,
              src,
              naturalWidth: img.naturalWidth,
            };
          })()`, coldSessionId);
        }
      } catch (err) {
        coldResult = { ok: false, reason: `cold-load harness error: ${err && err.message ? err.message : String(err)}` };
      } finally {
        if (coldTargetId) {
          try { await cdp.send('Target.closeTarget', { targetId: coldTargetId }); } catch { /* best effort */ }
        }
      }
      report(
        "#/m/guide-book/p/17/ja deep-links into the JA-visible state on a genuinely cold load (fresh target, hash present on the initial navigation)",
        Boolean(
          coldResult && coldResult.ok
          && coldResult.hash === '#/m/guide-book/p/17/ja'
          && coldResult.hasJaClass === true
          && coldResult.panelExists === true
          && typeof coldResult.src === 'string' && coldResult.src.endsWith('pages/guide-book/page-17.webp'),
        ),
        coldResult,
      );

      // -- 7. prev/next navigation + disabled ends --------------------------------
      await goto('#/m/guide-book/p/17', '#page-17');
      await clickAssert('#btn-next-page', 'click #btn-next-page');
      const afterNext = await evaluate(`(async () => {
        const start = Date.now();
        while (Date.now() - start < 3000) {
          if (document.querySelector('#page-18')) break;
          await new Promise((r) => setTimeout(r, 20));
        }
        return { hash: window.location.hash, has18: document.querySelector('#page-18') !== null };
      })()`);
      report(
        '#btn-next-page moves to page 18 and the content changes',
        Boolean(afterNext && afterNext.hash === '#/m/guide-book/p/18' && afterNext.has18),
        afterNext,
      );

      await clickAssert('#btn-prev-page', 'click #btn-prev-page');
      const afterPrev = await evaluate(`(async () => {
        const start = Date.now();
        while (Date.now() - start < 3000) {
          if (document.querySelector('#page-17')) break;
          await new Promise((r) => setTimeout(r, 20));
        }
        return { hash: window.location.hash, has17: document.querySelector('#page-17') !== null };
      })()`);
      report(
        '#btn-prev-page returns to page 17',
        Boolean(afterPrev && afterPrev.hash === '#/m/guide-book/p/17' && afterPrev.has17),
        afterPrev,
      );

      await goto('#/m/guide-book/p/1', '#page-1');
      const firstPageNav = await evaluate(`(() => {
        const prev = document.querySelector('#btn-prev-page');
        return { exists: !!prev, hasHref: !!(prev && prev.hasAttribute('href')) };
      })()`);
      report(
        'page 1 has no enabled prev link',
        Boolean(firstPageNav && firstPageNav.exists && firstPageNav.hasHref === false),
        firstPageNav,
      );

      await goto('#/m/guide-book/p/71', '#page-71');
      const lastPageNav = await evaluate(`(() => {
        const next = document.querySelector('#btn-next-page');
        return { exists: !!next, hasHref: !!(next && next.hasAttribute('href')) };
      })()`);
      report(
        'last page has no enabled next link',
        Boolean(lastPageNav && lastPageNav.exists && lastPageNav.hasHref === false),
        lastPageNav,
      );

      // -- 8. cross-reference link: guide-book p.15 -> p.17 -----------------------
      await goto('#/m/guide-book/p/15', '#page-15');
      const crossRef = await evaluate(`(() => {
        const a = Array.from(document.querySelectorAll('#page-15 a.page-ref'))
          .find((el) => el.getAttribute('href') === '#/m/guide-book/p/17');
        return a !== undefined;
      })()`);
      report('guide-book p.15 has a p.17 cross-reference link', crossRef === true, crossRef);

      // -- 8b (M5 item 1 / A4). Index linkification: the guide book's Index
      // (p.69) cites pages as BARE numbers and comma/dash lists, which the
      // global p./pp. grammar never matched; the table-cell-scoped
      // "Pages"-column rule must turn them into real a.page-ref links --
      // the DOM half of plan 4.6 rule 7's "makes the Index navigable"
      // claim (the model half is content-check group 23). Pins one bare
      // number ("Auto trigger" -> 29), one range ("Auto chop" 52-53 ->
      // its first page, 52), and that the page's index tables carry a
      // substantial number of links (p.69 alone holds >100 of the Index's
      // 262 citations).
      await goto('#/m/guide-book/p/69', '#page-69');
      const indexLinks = await evaluate(`(() => {
        const links = Array.from(document.querySelectorAll('#page-69 table a.page-ref'));
        const hrefs = links.map((a) => a.getAttribute('href'));
        return {
          total: links.length,
          hasBare29: hrefs.includes('#/m/guide-book/p/29'),
          hasRange52: hrefs.includes('#/m/guide-book/p/52'),
        };
      })()`);
      report(
        'guide-book p.69 index table cells are linkified (bare "29" and range "52-53" render as page links)',
        Boolean(indexLinks) && indexLinks.hasBare29 === true && indexLinks.hasRange52 === true && indexLinks.total > 100,
        indexLinks,
      );

      // -- 8c (M5 item 3). Breadcrumb on co-located-section pages: the route
      // carries only the page number, so the breadcrumb must name the FIRST
      // section starting on the page (the one at the top, where a TOC click
      // lands) -- not the LAST, which is what the pre-M5 rule showed
      // (startup-guide p.10 said "Try sampling", p.14 said "Trademarks").
      // The four pages pinned here are exactly the debt note's examples;
      // the selection rule itself is pinned in content-check group 25.
      for (const c of [
        { hash: '#/m/startup-guide/p/10', ready: '#page-10', want: 'Try applying an effect', reject: 'Try sampling' },
        { hash: '#/m/startup-guide/p/14', ready: '#page-14', want: 'Operating precautions', reject: 'Trademarks' },
        { hash: '#/m/midi/p/2', ready: '#page-2', want: '2. Product information', reject: '3. MIDI implementation chart' },
        { hash: '#/m/oss/p/11', ready: '#page-11', want: 'MIT', reject: 'MICROSOFT AZURE RTOS' },
      ]) {
        await goto(c.hash, c.ready);
        const crumb = await evaluate(`(() => {
          const el = document.querySelector('#sxc1-header nav');
          return el ? el.textContent : null;
        })()`);
        report(
          `breadcrumb on ${c.hash} names the first section starting on the page ("${c.want}", not "${c.reject}")`,
          typeof crumb === 'string' && crumb.includes(c.want) && !crumb.includes(c.reject),
          crumb,
        );
      }

      // -- 9. FULL SWEEP (NEW6 browser half): every page route is visited in
      // its '/ja' form -- rendering #sxc1-page exactly as before AND
      // genuinely decoding that page's original-page image (img.decode(),
      // raced against a per-image timeout so one hung fetch cannot stall
      // the whole sweep) against the expected 'pages/<slug>/page-NN.webp'
      // src. This makes every one of the 108 images the authoritative
      // decoder (Chrome) actually decodes, not just guide-book page 17.
      // --quick keeps this to the small first/mid/last sample; the DEFAULT
      // (no --quick) sweeps all 108, unchanged from before this fix.
      const routes = opts.quick ? quickRouteList() : fullRouteList();
      const sweepStart = Date.now();
      const sweepFailures = [];
      for (const { slug, n } of routes) {
        const hash = `#/m/${slug}/p/${n}/ja`;
        const expectedSrcSuffix = `pages/${slug}/page-${String(n).padStart(2, '0')}.webp`;
        const result = await evaluate(`(async () => {
          window.location.hash = ${JSON.stringify(hash)};
          const pageSelector = ${JSON.stringify(`#page-${n}`)};
          const start = Date.now();
          let el = null;
          let img = null;
          while (Date.now() - start < 4000) {
            el = document.querySelector('#sxc1-page');
            img = document.querySelector('#ja-image');
            if (el && el.textContent.trim().length > 0 && document.querySelector(pageSelector) && img) break;
            await new Promise((r) => setTimeout(r, 15));
          }
          if (!el || el.textContent.trim().length === 0 || !document.querySelector(pageSelector)) {
            return { ok: false, reason: 'page did not render', textLen: el ? el.textContent.trim().length : -1 };
          }
          if (!img) {
            return { ok: false, reason: 'no #ja-image element found' };
          }
          const src = img.getAttribute('src');
          if (!src || !src.endsWith(${JSON.stringify(expectedSrcSuffix)})) {
            return { ok: false, reason: 'unexpected #ja-image src', src };
          }
          // The markup marks this <img loading="lazy">; in a headless tab
          // the IntersectionObserver-driven lazy-load heuristic can defer
          // starting the fetch for a variable, occasionally multi-second
          // window even though the underlying request itself is a
          // millisecond-scale localhost fetch. Flipping to 'eager' forces
          // an immediate fetch so decode() below measures real decode
          // latency, not lazy-load scheduling jitter.
          img.loading = 'eager';
          try {
            await Promise.race([
              img.decode(),
              new Promise((_, rej) => setTimeout(() => rej(new Error('decode timed out')), 4000)),
            ]);
          } catch (e) {
            return { ok: false, reason: 'decode failed: ' + (e && e.message ? e.message : String(e)), src };
          }
          if (!(img.naturalWidth > 0 && img.naturalHeight > 0)) {
            return { ok: false, reason: 'decoded with zero natural size', naturalWidth: img.naturalWidth, naturalHeight: img.naturalHeight, src };
          }
          return { ok: true, src };
        })()`);
        if (!result || result.ok !== true) sweepFailures.push({ hash, result });
      }
      // Cross-check the CDP-level Network failure listeners armed in step 5:
      // a failure that somehow did not surface through img.decode() itself
      // still fails the sweep, named by URL.
      if (imageResourceFailures.length > 0) {
        sweepFailures.push({
          hash: '(network layer, whole run)',
          result: { ok: false, reason: 'resource failures observed on the Network domain', imageResourceFailures: imageResourceFailures.slice(0, 10) },
        });
      }
      const sweepMs = Date.now() - sweepStart;
      report(
        `all ${routes.length} page routes render #sxc1-page and their original-page image genuinely decodes${opts.quick ? ' (--quick sample)' : ''}`,
        sweepFailures.length === 0,
        { count: routes.length, ms: sweepMs, failures: sweepFailures.slice(0, 5) },
      );
      console.log(`[sweep] ${routes.length} routes with JA image decode in ${sweepMs}ms`);

      // -- 10. Mobile viewport: no horizontal overflow ----------------------------
      await cdp.send('Emulation.setDeviceMetricsOverride', {
        width: 390, height: 844, deviceScaleFactor: 3, mobile: true,
      }, sessionId);

      const mobileChecks = [];
      for (const [hash, ready] of [
        ['#/m/guide-book/p/10', '#page-10'],
        ['#/m/midi/p/3', '#page-3'],
      ]) {
        await goto(hash, ready);
        const overflow = await evaluate(`(() => ({
          scrollWidth: document.documentElement.scrollWidth,
          innerWidth: window.innerWidth,
        }))()`);
        const ok = Boolean(overflow) && overflow.scrollWidth <= overflow.innerWidth + 1;
        mobileChecks.push({ hash, ok, overflow });
      }
      await cdp.send('Emulation.clearDeviceMetricsOverride', {}, sessionId);
      report(
        'mobile viewport (390x844) has no horizontal overflow on guide-book p.10 and midi p.3',
        mobileChecks.every((c) => c.ok),
        mobileChecks,
      );

      // -- 11. Disclaimer ----------------------------------------------------------
      await goto('#/m/guide-book/p/1', '#page-1');
      const disclaimer = await evaluate(`(() => {
        const e = document.querySelector('#sxc1-disclaimer');
        return e ? e.textContent : null;
      })()`);
      const disclaimerLower = (disclaimer || '').toLowerCase();
      report(
        '#sxc1-disclaimer names CASIO and non-affiliation',
        disclaimerLower.includes('not affiliated') && (disclaimer || '').includes('CASIO COMPUTER CO., LTD.'),
        disclaimer,
      );

      // -- 12. Console hygiene across the WHOLE run ---------------------------------
      const noErrors = consoleErrors.length === 0 && exceptions.length === 0;
      report('no console errors or uncaught exceptions across the whole run', noErrors, { consoleErrors, exceptions });

      // -- 13 (M2). Exercise engine assertions -- ONLY when --exercise-fixture
      // was supplied (see its up-front loading above): reuses the EXACT
      // same runExerciseAssertions() function --self-test drives against
      // its static fixture, here driven against the real, running app.
      if (exerciseFixture) {
        const typeText = async (selector, text) => {
          const focused = await evaluate(`(() => {
            const el = document.querySelector(${JSON.stringify(selector)});
            if (!el) return false;
            el.focus();
            el.value = '';
            return true;
          })()`);
          if (!focused) return false;
          await cdp.send('Input.insertText', { text }, sessionId);
          return true;
        };
        const setMobileViewport = () => cdp.send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 3, mobile: true }, sessionId);
        const clearViewport = () => cdp.send('Emulation.clearDeviceMetricsOverride', {}, sessionId);
        const consoleHygiene = () => ({ ok: consoleErrors.length === 0 && exceptions.length === 0, consoleErrors, exceptions });
        // M5 a11y: trusted keyboard input for the keyboard-only flows.
        const pressKey = keyPresserFor(cdp, sessionId);

        // M2 gate fix (H1/H6/M5): the real run's own coldLoadFn -- SAME
        // technique as the JA cold-load assertion above (a fresh CDP
        // target whose INITIAL navigation URL already carries the deep
        // link, so this exercises whatever the app does with the
        // startup hash / Miso's `mount` rather than an in-session
        // hashchange -- exactly where H6 lived: a cold RExercise route
        // used to reach viewModel without ever calling beginIfNeeded).
        // Added to trackedSessions so its console errors/exceptions
        // count toward the whole-run hygiene tracking too, same as the
        // JA cold target.
        const coldLoadFn = async (fx, cbReport, lang = 'en') => {
          const waitMs = 1200;
          const coldBase = targetUrl.replace(/#.*$/, '');
          const coldUrl = `${coldBase}#/x/${fx.quiz.deck}/${fx.quiz.id}`;
          let coldTargetId = null;
          try {
            const created = await cdp.send('Target.createTarget', { url: coldUrl });
            coldTargetId = created.targetId;
            const attached = await cdp.send('Target.attachToTarget', { targetId: coldTargetId, flatten: true });
            const coldSessionId = attached.sessionId;
            trackedSessions.add(coldSessionId);
            await cdp.send('Runtime.enable', {}, coldSessionId);
            await cdp.send('Page.enable', {}, coldSessionId);

            let booted = false;
            const bootDeadline = Math.min(deadline, Date.now() + 20000);
            while (Date.now() < bootDeadline) {
              const state = await evaluate(`(() => {
                if (typeof window.__SXC1_BOOT_ERROR === 'string') return { error: window.__SXC1_BOOT_ERROR };
                if (window.__SXC1_BOOTED === true) return { booted: true };
                return { pending: true };
              })()`, coldSessionId);
              if (state && typeof state.error === 'string') {
                cbReport(COLD_ELAPSED_ASSERTION_NAME, false, { reason: 'cold target boot error', state });
                return;
              }
              if (state && state.booted) { booted = true; break; }
              await sleep(100);
            }
            if (!booted) {
              cbReport(COLD_ELAPSED_ASSERTION_NAME, false, 'cold target failed to boot within 20s');
              return;
            }

            const coldEvaluate = (expr) => evaluate(expr, coldSessionId);
            const coldClickAssert = async (selector, label) => {
              const present = await coldEvaluate(`document.querySelector(${JSON.stringify(selector)}) !== null`);
              if (!present) { cbReport(label, false, `skipped: ${selector} not found`); return false; }
              await coldEvaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
              cbReport(label, true, null);
              return true;
            };
            await assertColdFirstTryElapsed({ evaluate: coldEvaluate, clickAssert: coldClickAssert, report: cbReport }, fx, waitMs, lang);
          } catch (err) {
            cbReport(COLD_ELAPSED_ASSERTION_NAME, false, `harness error: ${err && err.message ? err.message : String(err)}`);
          } finally {
            if (coldTargetId) {
              try { await cdp.send('Target.closeTarget', { targetId: coldTargetId }); } catch { /* best effort */ }
            }
          }
        };

        // M3 harness wave: "reload" for the persistence assertions below --
        // an ORDINARY full-page reload (not a hash change), which
        // re-fetches app.wasm and re-runs hs_start(), giving a genuinely
        // fresh Haskell Model (mExStates back to Map.empty) while
        // localStorage -- the very thing under test -- survives, exactly
        // like a learner closing and reopening the tab. Reuses the SAME
        // boot-poll technique as the cold-target boot wait just above,
        // against the SAME sessionId (Page.reload keeps the target/session
        // alive, so the existing console-hygiene listeners keep working
        // across it for free).
        const reload = async (readySelector, timeoutMs = 15000) => {
          await cdp.send('Page.reload', {}, sessionId);
          const bootDeadline = Date.now() + timeoutMs;
          let booted = false;
          while (Date.now() < bootDeadline) {
            const state = await evaluate(`(() => {
              if (typeof window.__SXC1_BOOT_ERROR === 'string') return { error: window.__SXC1_BOOT_ERROR };
              if (window.__SXC1_BOOTED === true) return { booted: true };
              return { pending: true };
            })()`);
            if (state && state.error) throw new Error(`boot error after reload: ${state.error}`);
            if (state && state.booted) { booted = true; break; }
            await sleep(60);
          }
          if (!booted) throw new Error(`app did not report __SXC1_BOOTED within ${timeoutMs}ms after reload`);
          if (readySelector) {
            const readyDeadline = Date.now() + timeoutMs;
            while (Date.now() < readyDeadline) {
              if (await evaluate(`document.querySelector(${JSON.stringify(readySelector)}) !== null`)) return true;
              await sleep(30);
            }
            return false;
          }
          return true;
        };

        // deckTierFromDisk re-derives the quiz's OWN deck's declared
        // tier: straight from content/exercises/ -- independent of
        // whatever the app renders, for assertion "deckCardTierMatches".
        const progressCfg = {
          quizDeck: exerciseFixture.quiz.deck,
          quizId: exerciseFixture.quiz.id,
          quizCorrectOpt: exerciseFixture.quiz.correctOpt,
          // NEW11: section E now manufactures a real due-today record by
          // answering incorrectly first -- see runProgressAssertionsPost.
          quizWrongOpt: exerciseFixture.quiz.wrongOpt,
          lookupDeck: exerciseFixture.lookup.deck,
          lookupId: exerciseFixture.lookup.id,
          lookupTargetPage: exerciseFixture.lookup.targetPage,
          deckSlug: exerciseFixture.quiz.deck,
          expectedTier: deckTierFromDisk(exerciseFixture.quiz.deck),
          manualSlug: 'guide-book',
          manualPage: 17,
          manualNextPage: 18,
        };
        const progressHandle = { evaluate, report, goto, click, clickAssert, assertElement, typeText, reload };

        // PRE must run before ANYTHING touches localStorage, including
        // M2's own runExerciseAssertions below (its cold-load quiz answer
        // alone would already make "records=0" false) -- see
        // runProgressAssertionsPre's own comment.
        await runProgressAssertionsPre(progressHandle, progressCfg);

        await runExerciseAssertions(
          { evaluate, report, goto, click, clickAssert, assertElement, typeText, setMobileViewport, clearViewport, consoleHygiene, pressKey },
          exerciseFixture,
          expectedExerciseJson,
          coldLoadFn,
        );

        // POST does not rely on anything runExerciseAssertions left
        // behind (it starts with its own wipe + reload) -- see
        // runProgressAssertionsPost's own comment.
        await runProgressAssertionsPost(progressHandle, progressCfg);

        // M6 W2: THE UI-LANGUAGE JA FLOW -- the real #btn-ui-lang toggle
        // (persist + reload-as-refetch), then the ENTIRE exercise/a11y
        // assertion set again under lang='ja' (every learner-visible
        // text pin pins the JA string), the JA verify sentence, the
        // bundle-refetch proof, and the roundtrip back to EN -- so the
        // mobile sweep and the D-suite below still run under the
        // language whose strings they pin. Runs AFTER POST on purpose:
        // POST's final step leaves jaFirst EXPLICITLY off, which is the
        // precondition for the ruling-4 never-override assertion (see
        // runUiLangJaAssertions' own comment).
        const waitBooted = async (timeoutMs = 20000) => {
          await sleep(300);
          const bootDeadline = Date.now() + timeoutMs;
          while (Date.now() < bootDeadline) {
            let b;
            try { b = await evaluate('window.__SXC1_BOOTED === true'); } catch { b = false; }
            if (b === true) return true;
            await sleep(50);
          }
          return false;
        };
        await runUiLangJaAssertions(
          { evaluate, report, goto, click, clickAssert, assertElement, typeText, setMobileViewport, clearViewport, consoleHygiene, pressKey, reload, waitBooted },
          exerciseFixture,
          coldLoadFn,
          // M6 W4: jaCorpus turns on the five JA COURSE assertions --
          // real corpus Japanese, from the bundle this server is
          // actually serving (see JA_COURSE_PINS). M7 W3: jaManuals
          // turns on the four JA MANUAL assertions, the same discipline
          // for the manual text (see JA_MANUAL_PINS). The self-test
          // fixture caller passes neither: it has no corpus and no
          // manual bundle to render.
          { checkBundleFetch: true, jaCorpus: JA_COURSE_PINS, jaManuals: JA_MANUAL_PINS },
        );
      }

      // -- 13b (M5). MOBILE POLISH SWEEP: the main routes at the two
      // small-phone viewports (briefs/M5-ship.md ship checklist), pinning
      // no-horizontal-overflow (document.scrollingElement.scrollWidth <=
      // innerWidth, +1 rounding slack as in assertion 10) on every swept
      // route -- MEASURED AGAINST THE EMULATED DEVICE WIDTH, with two
      // reinforcements this task's own red-first probe showed are
      // load-bearing (a 380px-min-width sabotage passed the bare
      // predicate both ways):
      //   1. body{overflow-x:hidden} means overflowing content never
      //      widens the scrolling element -- it gets CLIPPED, so the
      //      sweep also scans for any visible element whose right edge
      //      passes the device width OUTSIDE a horizontal scroll
      //      container (overflow-x auto/scroll ancestors are the
      //      sanctioned pattern: .table-wrap, the header strip);
      //   2. under mobile emulation the LAYOUT VIEWPORT itself inflates
      //      to the widest content (innerWidth read back 380 on a 360
      //      device), so innerWidth staying at the device width is
      //      asserted too, and the scrollWidth comparison uses the
      //      device width, never the elastic innerWidth.
      // Runs AFTER the exercise/progress sections on purpose: visiting
      // an exercise route fires its mount-time Begin, and doing that
      // BEFORE section 13's elapsed-time assertions would shift their
      // measured baselines. The exercise routes come from
      // --exercise-fixture; without one the sweep covers the reader
      // routes only (reported in the observation, never silently).
      {
        const m5MobileRoutes = [
          ['#/', '#sxc1-home'],
          ['#/m/guide-book', '#sxc1-toc'],
          ['#/m/guide-book/p/17', '#page-17'],
          ['#/m/guide-book/p/17/ja', '#ja-panel'],
          ['#/x', '#sxc1-exercise-index'],
        ];
        if (exerciseFixture) {
          m5MobileRoutes.push(
            [`#/x/${exerciseFixture.quiz.deck}`, '#sxc1-deck'],
            [`#/x/${exerciseFixture.quiz.deck}/${exerciseFixture.quiz.id}`, '.kind-quiz'],
            [`#/x/${exerciseFixture.drill.deck}/${exerciseFixture.drill.id}`, '.kind-drill'],
            [`#/x/${exerciseFixture.lookup.deck}/${exerciseFixture.lookup.id}`, '.kind-lookup'],
          );
        }
        for (const [w, hgt] of [[360, 640], [320, 568]]) {
          await cdp.send('Emulation.setDeviceMetricsOverride', {
            width: w, height: hgt, deviceScaleFactor: 2, mobile: true,
          }, sessionId);
          const checks = [];
          for (const [hash, ready] of m5MobileRoutes) {
            await goto(hash, ready);
            const overflowObs = await evaluate(`(() => {
              const deviceW = ${w};
              const offenders = [];
              const inScroller = (el) => {
                for (let a = el.parentElement; a && a !== document.body; a = a.parentElement) {
                  const ox = getComputedStyle(a).overflowX;
                  if (ox === 'auto' || ox === 'scroll') return true;
                }
                return false;
              };
              for (const el of document.querySelectorAll('#app *')) {
                const r = el.getBoundingClientRect();
                if (r.width === 0 || r.height === 0) continue;
                if (r.right > deviceW + 1 && !inScroller(el)) {
                  offenders.push({
                    sel: el.tagName + (el.id ? '#' + el.id : '')
                      + (typeof el.className === 'string' && el.className ? '.' + el.className.split(' ')[0] : ''),
                    right: Math.round(r.right),
                  });
                  if (offenders.length >= 4) break;
                }
              }
              return {
                scrollWidth: document.scrollingElement.scrollWidth,
                innerWidth: window.innerWidth,
                deviceW,
                offenders,
              };
            })()`);
            checks.push({
              hash,
              ok: Boolean(overflowObs)
                && overflowObs.scrollWidth <= w + 1
                && overflowObs.innerWidth <= w + 1
                && overflowObs.offenders.length === 0,
              overflowObs,
            });
          }
          report(
            `mobile sweep at ${w}x${hgt}: no horizontal overflow (scrollingElement.scrollWidth/innerWidth <= device width, and no element clipped past the right edge outside an overflow-x scroll container) across ${m5MobileRoutes.length} main routes${exerciseFixture ? '' : ' (reader routes only: no --exercise-fixture)'}`,
            checks.length === m5MobileRoutes.length && checks.every((c) => c.ok),
            checks.filter((c) => !c.ok),
          );
        }
        await cdp.send('Emulation.clearDeviceMetricsOverride', {}, sessionId);
      }

      // -- 14 (M4). THE DEVICE SUITE, D1..D25 -- always part of a real
      // run (no flag: the routes are the seed corpus's own, present in
      // every real bundle). Each scenario gets its own freshly created
      // target with scripts/fake-midi.js pre-injected BEFORE navigation
      // (P-B); D20 deliberately injects nothing. See runDeviceAssertions.
      const makeDeviceTarget = deviceTargetFactoryFor(cdp, deadline, targetUrl);
      await runDeviceAssertions(makeDeviceTarget, report, DEVICE_REAL_CFG);
    }

    console.log(`browser-check: ${passed}/${total} assertions passed`);
    const exitCode = passed === total ? 0 : 1;
    await die(exitCode, null);
  } catch (err) {
    await die(2, `error: ${err && err.stack ? err.stack : err}`);
  }
}

main();
