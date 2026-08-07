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
// Exercises.Corpus.exerciseStatsJson (site/app/Exercises/Corpus.hs)
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
    timeout: 45000,
    keepOpen: false,
    expectJson: null,
    quick: false,
    selfTest: false,
    selfTestNegative: false,
    exerciseFixture: null,
    expectExerciseJson: null,
    checkStorageRefused: false,
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
      case '--exercise-fixture':
        opts.exerciseFixture = argv[++i];
        break;
      case '--expect-exercise-json':
        opts.expectExerciseJson = argv[++i];
        break;
      case '--check-storage-refused':
        opts.checkStorageRefused = true;
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
  --help               Show this help and exit

By default (no --quick) the page-route sweep visits all 108 routes in
their '/ja' form and awaits a real image decode for every one -- this is
the authoritative decoder for the project's page images (see NEW6). A
separate assertion also opens a genuinely fresh browser target whose
initial URL already carries a JA deep-link hash, to catch a cold-load
regression that a warm hashchange-only check cannot see (see NEW5).`);
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
// matches the schema Exercises.Corpus.exerciseStatsJson produces
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

// Builds the fixture page. `sabotage` selects the negative-control
// grader: when true, EVERY submit reports "correct" regardless of what
// was actually selected/entered/confirmed -- the one and only thing
// --self-test-negative changes.
// M3 harness wave: the self-test fixture's own declared deck tier -- must
// match progressCfg.expectedTier at both self-test call sites below, and
// is what "deckCardTierMatches" checks against (an independent constant
// here, not read from any real content/exercises/ file -- the self-test
// fixture is deliberately independent of the real app/content).
const PROGRESS_SELF_TEST_TIER = 'core';

function selfTestFixtureHtml(sabotage) {
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
  <div id="sxc1-root"></div>
</div>
<script>
window.__SXC1_BOOTED = true;
(function () {
  var SABOTAGE = ${sabotage ? 'true' : 'false'};
  var FIXTURE = ${fixtureJson};
  var PROGRESS_DECK_TIER = ${JSON.stringify(PROGRESS_SELF_TEST_TIER)};
  var MANUAL_TOTAL_PAGES = 2;

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

  function clamp1_180(x) { return Math.max(1, Math.min(180, x)); }

  function gradeOfOutcomeJs(isCorrect, attempt, revealed, hints) {
    if (!isCorrect) return 'GAgain';
    if (revealed) return 'GHard';
    if (attempt >= 2) return 'GHard';
    if (hints > 0) return 'GGood';
    return 'GEasy';
  }

  // SABOTAGE (sub-point 3, isolated to "answerReloadInterval" only -- see
  // this file's runProgressAssertionsPost comment): a fresh GEasy at
  // reps 0 returns 3 instead of the real scheduler's 2. Every other
  // grade/reps combination this fixture can reach (GAgain always; GEasy
  // reps>=1 is never reached by this fixture's own scripted scenarios)
  // stays correct, so this sabotage cannot be masked by "everything is
  // wrong" -- only the ONE value the assertion actually pins.
  function nextIntervalDaysJs(rec, grade) {
    if (grade === 'GAgain') return 0;
    if (grade === 'GHard') return rec.reps === 0 ? 1 : clamp1_180(Math.floor(rec.interval * 12 / 10));
    if (grade === 'GGood') return rec.reps === 0 ? 1 : (rec.reps === 1 ? 3 : clamp1_180(Math.floor(rec.interval * rec.ease / 1000)));
    if (rec.reps === 0) return SABOTAGE ? 3 : 2;
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
  // SABOTAGE (isolated to "importPreview" only): always reports 0.
  function countPastedRecordsJs(text) {
    if (SABOTAGE) return 0;
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
    if (raw == null || raw.trim() === '') return { jaFirst: false };
    var lines = raw.split(NL);
    var header = (lines[0] || '').split(TAB);
    if (header[0] !== 'SXC1PREFS') return { jaFirst: false };
    var jaFirst = false;
    for (var i = 1; i < lines.length; i++) {
      var f = lines[i].split(TAB);
      if (f[0] === 'P' && f[1] === 'jaFirst') jaFirst = (f[2] === '1');
    }
    return { jaFirst: jaFirst };
  })();

  // SABOTAGE (isolated to "jaFirstPersistsValue" + "jaFirstPersistsOrder",
  // both of which read state from the SAME post-reload page load -- see
  // runProgressAssertionsPost's own comment): the in-memory model still
  // updates (so the UI visibly reflects a click), but the localStorage
  // write is skipped, so a RELOAD (a fresh script execution, re-reading
  // from storage) loses it.
  function saveJaFirst(v) {
    CURRENT_PREFS = { jaFirst: v };
    if (!SABOTAGE) {
      try {
        window.localStorage.setItem(PREFS_KEY, 'SXC1PREFS' + TAB + '1' + NL + 'P' + TAB + 'jaFirst' + TAB + (v ? '1' : '0') + NL);
      } catch (e) { /* best effort */ }
    }
  }

  function mergeRec(recs, pid, rec) {
    var out = {};
    for (var k in recs) { if (Object.prototype.hasOwnProperty.call(recs, k)) out[k] = recs[k]; }
    out[pid] = rec;
    return out;
  }

  // The never-overwrite rule (Progress.Store's THE ONE RULE THAT
  // MATTERS): while CURRENT_PROGRESS.kind === 'corrupt', an ordinary
  // grading write is a no-op. SABOTAGE (isolated to
  // "corruptNeverOverwritten" only): disables the guard, so the corrupt
  // blob is silently replaced by the next answer, exactly the defect
  // this rule exists to prevent.
  function gradeQuizPromptForProgress(isCorrect, attempt) {
    var pid = FIXTURE.quiz.id + '#1';
    if (CURRENT_PROGRESS.kind === 'corrupt' && !SABOTAGE) return;
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
  }

  function currentDue() {
    var recs = CURRENT_PROGRESS.recs, out = 0;
    for (var pid in recs) { if (Object.prototype.hasOwnProperty.call(recs, pid) && recs[pid].due <= PROG_TODAY) out++; }
    return out;
  }

  // SABOTAGE (isolated to "freshRecords" + "wipeEmpties" +
  // "answerReloadCount" + "exportWipeImportRestores" -- all four are
  // legitimately testing the SAME counter, just at different points in
  // the run, so a records-counting bug breaking all four together is an
  // honest cascade, not test sloppiness): off by one, always.
  function updateProgressPayload() {
    var recs = CURRENT_PROGRESS.recs, pids = Object.keys(recs);
    var payload = {
      available: true,
      state: CURRENT_PROGRESS.kind === 'ok' ? 'ok' : (CURRENT_PROGRESS.kind === 'corrupt' ? 'corrupt' : 'empty'),
      schema: 1,
      records: pids.length + (SABOTAGE ? 1 : 0),
      retired: 0,
      due: currentDue(),
      streak: CURRENT_PROGRESS.streakLen || 0,
      retention: 0,
      queue: pids.filter(function (p) { return recs[p].due <= PROG_TODAY; }),
      // SABOTAGE (isolated to "freshJaFirst" only -- see CURRENT_PREFS's
      // own comment on why the DEFAULT itself is never sabotaged):
      // always reports true here regardless of the real preference.
      jaFirst: SABOTAGE ? true : (CURRENT_PREFS.jaFirst === true),
    };
    document.getElementById('sxc1-progress').textContent = JSON.stringify(payload);
  }

  // SABOTAGE (isolated to "reviewBadgeMatchesDue" only): off by one.
  function renderHeader(onManualRoute) {
    var due = currentDue() + (SABOTAGE ? 1 : 0);
    var html = '<a id="sxc1-review-badge" href="#/">Review ' + due + '</a>';
    if (onManualRoute) {
      html += '<button id="btn-ja-first" type="button" aria-pressed="' + (CURRENT_PREFS.jaFirst ? 'true' : 'false') + '">' +
        (CURRENT_PREFS.jaFirst ? 'Japanese first: on' : 'Japanese first: off') + '</button>';
    }
    document.getElementById('sxc1-header').innerHTML = html;
    if (onManualRoute) {
      document.getElementById('btn-ja-first').addEventListener('click', function () {
        saveJaFirst(!CURRENT_PREFS.jaFirst);
        render();
      });
    }
  }

  function renderHome() {
    var corrupt = CURRENT_PROGRESS.kind === 'corrupt';
    // SABOTAGE (isolated to "corruptBanner" -- and, honestly, cascading
    // into "corruptNeverOverwritten"'s OWN bannerStillShown half, which
    // is ALSO already covered by the never-overwrite sabotage above):
    // the banner never renders even when the blob is undecodable.
    var bannerHtml = (corrupt && !SABOTAGE)
      ? ('<section id="sxc1-corrupt-banner"><p>Your saved progress could not be read (' + escapeHtml(CURRENT_PROGRESS.reason || '') + '). It has NOT been deleted.</p>' +
        '<textarea id="sxc1-corrupt-raw" readonly>' + escapeHtml(CURRENT_PROGRESS.raw || '') + '</textarea></section>')
      : '';
    root().innerHTML =
      bannerHtml +
      '<p id="sxc1-streak">Study streak: ' + (CURRENT_PROGRESS.streakLen || 0) + '</p>' +
      '<section id="sxc1-progress-tools">' +
      '<button id="btn-progress-export" type="button">Export</button>' +
      '<textarea id="sxc1-export-blob" readonly></textarea>' +
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
      var envelope = '{"format":"sxc1-progress","schema":1,"exportedAt":"epoch-ms:' + Date.now() + '","payload":"' + jsonEscape(wire) + '"}';
      document.getElementById('sxc1-export-blob').value = envelope;
    });
    document.getElementById('sxc1-import-form').addEventListener('submit', function (ev) {
      ev.preventDefault();
      var text = document.getElementById('sxc1-import-input').value;
      var decoded = importBlobJs(text);
      if (decoded.kind === 'ok') {
        CURRENT_PROGRESS = decoded;
        try { window.localStorage.setItem(PROG_KEY, encodeProgWire(decoded.recs, decoded.streakDay, decoded.streakLen)); } catch (e) { /* best effort */ }
        renderHome();
        updateProgressPayload();
      }
    });
    document.getElementById('btn-progress-wipe-confirm').addEventListener('click', function () {
      CURRENT_PROGRESS = { kind: 'empty', recs: {}, streakDay: 0, streakLen: 0 };
      try { window.localStorage.removeItem(PROG_KEY); } catch (e) { /* best effort */ }
      renderHome();
      updateProgressPayload();
    });
  }

  // SABOTAGE (isolated to "jaToggleHidesAndSticks" only): after an
  // explicit hide, a stray re-render forces the panel back on shortly
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
      if (wasShowingViaJaFirst && SABOTAGE) {
        setTimeout(function () { location.hash = '#/m/' + slug + '/p/' + n + '/ja'; }, 200);
      }
    });
  }
  // Mirrors Main.hs's promptBaselineJson contract: a POSITIVE monotonic
  // reading once Begin has run at mount; stays "null" under SABOTAGE --
  // the lost-mount-Begin scenario --self-test-negative must catch.
  if (!SABOTAGE) {
    document.getElementById('sxc1-prompt-baseline').textContent =
      String(Math.max(1, Math.floor(performance.now())));
  }
  var eventLog = [];
  var quizSelected = Object.create(null);
  var quizAttempted = false;
  var lastQuizCorrect = false;
  var quizPromptAt = 0;
  // M3: how many times THIS quiz prompt has been submitted since it was
  // last fresh/Begin/Restart -- mirrors the real engine's own attempt
  // counter, which gradeOfOutcomeJs needs (Correct on attempt >= 2 is
  // GHard, never GEasy, even though this fixture's own quiz-grading
  // SABOTAGE forces isCorrect=true regardless of selection).
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
  // Begin/Restart/Advance re-baseline esPromptAt). Under SABOTAGE,
  // elapsedMs is forced to 0 regardless of the real wait -- the exact H1
  // defect (a fresh attempt's clock seeded from the WALL epoch instead of
  // the monotonic one gradeStep subtracts against, clamped hugely
  // negative to 0) -- so a cold-load assertion that only checked the
  // M:SS STRING (any value, including "0:00") would miss it; this is why
  // the new cold-load assertion reads elapsedMs itself instead.
  function pushEvent(exId, kind, outcome, promptAt) {
    var elapsedMs = SABOTAGE ? 0 : Math.max(0, Date.now() - (promptAt || Date.now()));
    eventLog.push({ deck: FIXTURE.quiz.deck, exercise: exId, prompt: exId + '#1', kind: kind,
      outcome: outcome, attempt: 1, revealed: false, hints: 0, elapsedMs: elapsedMs, at: Date.now() });
    setEventLog();
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
    // SABOTAGE (isolated to "deckCardTierMatches" only): the rendered
    // tier disagrees with the deck's own declared tier.
    var renderedTier = SABOTAGE ? 'stretch' : PROGRESS_DECK_TIER;
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
      (correct ? 'Correct.' : 'Not quite. Try again.') + '</p>' +
      (correct ? ('<div id="ex-note"><p>Why: demo note.</p></div>' + cites +
        '<button id="btn-ex-next">Next</button>') : '');
  }

  function renderQuiz() {
    // H1/H6: lazily seeded, like esPromptAt from a real Begin -- the
    // FIRST renderQuiz() after a fresh load or a Restart (which zeroes
    // this back out below) re-baselines it, exactly once, before any
    // click can occur.
    if (quizPromptAt === 0) quizPromptAt = Date.now();
    var optsHtml =
      '<li><button id="' + FIXTURE.quiz.correctOpt + '" class="ex-option" aria-pressed="' + (quizSelected[FIXTURE.quiz.correctOpt] ? 'true' : 'false') + '">Correct option</button></li>' +
      '<li><button id="' + FIXTURE.quiz.wrongOpt + '" class="ex-option" aria-pressed="' + (quizSelected[FIXTURE.quiz.wrongOpt] ? 'true' : 'false') + '">Wrong option</button></li>';
    root().innerHTML = '<article id="sxc1-exercise" class="exercise kind-quiz">' +
      '<h1 id="ex-title">Demo quiz</h1><p id="ex-progress">1 / 1</p><div id="ex-stem"><p>Pick the right one.</p></div>' +
      '<ul id="ex-options">' + optsHtml + '</ul>' +
      '<button id="btn-ex-submit">Submit</button>' +
      (quizAttempted ? feedbackHtml(lastQuizCorrect) : '') +
      '<button id="btn-ex-restart">Restart</button>' +
      '</article>';
    // H7: Restart must yield a genuinely blank prompt -- clears this
    // attempt's own result state and re-baselines the clock, mirroring
    // Main.hs's applyExActions (Begin/Restart -> dropStale mExResults).
    // SABOTAGE reproduces the pre-fix defect ON PURPOSE: it re-baselines
    // the clock (an unrelated bug) but leaves quizAttempted/
    // lastQuizCorrect/quizSelected exactly as they were, so the stale
    // "Correct."/note/Next/pressed option all survive a restart -- the
    // one thing this task's new Restart assertion exists to catch.
    document.getElementById('btn-ex-restart').addEventListener('click', function () {
      quizPromptAt = 0;
      quizAttemptCount = 0;
      if (!SABOTAGE) {
        quizAttempted = false;
        lastQuizCorrect = false;
        quizSelected = Object.create(null);
      }
      renderQuiz();
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
      var isCorrect = SABOTAGE ? true : (selectedIds.length === 1 && selectedIds[0] === FIXTURE.quiz.correctOpt);
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
      // site/app/View/Exercise.hs's citesEl/bodyEls comments). SABOTAGE
      // omits this entirely, reproducing the pre-fix defect: a drill
      // body never reached the only citation renderer that existed at
      // the time, so a completed drill's citations were unreachable.
      var citeHtml = (confirmed && !SABOTAGE)
        ? ('<ul class="ex-step-cites" id="ex-step-' + i + '-cites"><li><a class="cite" href="#/m/' + FIXTURE.drill.citeSlug + '/p/' + FIXTURE.drill.citePage + '">cite</a></li></ul>')
        : '';
      stepsHtml += '<li class="ex-step" id="ex-step-' + i + '"><div class="ex-step-instruction"><p>Step ' + i + '.</p></div>' +
        '<p class="ex-step-check" id="ex-step-' + i + '-check">Check ' + i + '.</p>' +
        ((FIXTURE.drill.hasVerify && i === 1) ? '<p class="ex-verify" id="ex-step-1-verify">Automatic device confirmation arrives with WebMIDI support in a future update; confirm manually for now.</p>' : '') +
        citeHtml +
        (idx0 === drillCursor ? ('<button class="btn-ex-confirm" id="btn-ex-confirm-' + i + '">Confirm</button>') : '') +
        '</li>';
    }
    root().innerHTML = '<article id="sxc1-exercise" class="exercise kind-drill">' +
      '<h1 id="ex-title">Demo drill</h1><p id="ex-progress">' + Math.min(drillCursor + 1, FIXTURE.drill.steps) + ' / ' + FIXTURE.drill.steps + '</p>' +
      '<div id="ex-stem"><p>Do the thing.</p></div><ol id="ex-steps">' + stepsHtml + '</ol></article>';
    var btn = document.getElementById('btn-ex-confirm-' + (drillCursor + 1));
    if (btn) btn.addEventListener('click', function () {
      pushEvent(FIXTURE.drill.id, 'drill', 'correct', drillStepAt);
      drillCursor += 1;
      // H1: Advance re-baselines esPromptAt to the NEXT prompt's own
      // monotonic reading -- mirrored here for the step about to become
      // current.
      drillStepAt = Date.now();
      renderDrill();
    });
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
    // H8: a lookup's own citation is its find: TARGET page, rendered
    // ONLY after grading (gated the same way the real app gates it --
    // mAttempted -- never before, or the lookup spoils its own answer).
    // SABOTAGE omits it even once graded, reproducing the pre-fix
    // defect: a lookup's target lives only in its prompt's FindPage
    // payload, which the only citation renderer at the time (keyed off
    // exCites) never visited at all.
    var lookupCiteHtml = SABOTAGE
      ? ''
      : ('<ul id="ex-cites"><li><a class="cite" href="#/m/' + FIXTURE.lookup.citeSlug + '/p/' + FIXTURE.lookup.citePage + '">cite</a></li></ul>');
    root().innerHTML = '<article id="sxc1-exercise" class="exercise kind-lookup">' +
      '<h1 id="ex-title">Demo lookup</h1><p id="ex-progress">1 / 1</p><div id="ex-stem"><p>Find the page.</p></div>' +
      '<p id="ex-find-task">Find it.</p>' +
      '<input id="ex-find-input" type="number" inputmode="numeric">' +
      '<button id="btn-ex-find-submit">Submit</button>' +
      (lookupResult !== null ? (feedbackHtml(lookupResult, lookupResult ? lookupCiteHtml : '') + (lookupResult ? ('<p id="ex-elapsed">' + elapsedStr() + '</p>') : '')) : '') +
      '</article>';
    var input = document.getElementById('ex-find-input');
    var submitBtn = document.getElementById('btn-ex-find-submit');
    submitBtn.addEventListener('click', function () {
      var n = parseInt(input.value, 10);
      var isCorrect = SABOTAGE ? true : (n === FIXTURE.lookup.targetPage);
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
      if (exId === FIXTURE.drill.id) { drillCursor = 0; renderDrill(); updateProgressPayload(); return; }
      if (exId === FIXTURE.lookup.id) { lookupStartedAt = 0; lookupResult = null; renderLookup(); updateProgressPayload(); return; }
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
  window.addEventListener('hashchange', render);
  render();
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

async function assertColdFirstTryElapsed(coldH, fixture, waitMs) {
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
      if (fb && /^Correct/.test(fb.textContent)) break;
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
async function runExerciseAssertions(h, fixture, expectedExerciseJson, coldLoadFn) {
  const results = [];
  const report = (name, ok, observed) => {
    results.push({ name, ok });
    h.report(name, ok, observed);
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
    await coldLoadFn(fixture, report);
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
    'wrong quiz answer: #ex-feedback starts with "Not quite" and carries class "incorrect"',
    Boolean(wrongFeedback && /^Not quite/.test(wrongFeedback.text) && wrongFeedback.cls.split(/\s+/).includes('incorrect')),
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
      if (fb && /^Correct/.test(fb.textContent)) break;
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
    'correct quiz answer: #ex-feedback starts with "Correct", class "correct", #ex-note visible, #btn-ex-next present',
    Boolean(rightFeedback && /^Correct/.test(rightFeedback.text) && rightFeedback.cls.split(/\s+/).includes('correct')
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
  report('lookup: wrong page submits to "Not quite"', Boolean(lookupWrong && /^Not quite/.test(lookupWrong)), lookupWrong);
  await h.typeText('#ex-find-input', String(fixture.lookup.targetPage));
  await h.clickAssert('#btn-ex-find-submit', 'submit the correct lookup page');
  const lookupRight = await h.evaluate(`(async () => {
    const start = Date.now();
    let fb;
    while (Date.now() - start < 3000) {
      fb = document.querySelector('#ex-feedback');
      if (fb && /^Correct/.test(fb.textContent)) break;
      await new Promise((r) => setTimeout(r, 20));
    }
    const el = document.querySelector('#ex-elapsed');
    return { text: fb ? fb.textContent : null, elapsed: el ? el.textContent : null };
  })()`);
  report(
    'lookup: correct page submits to "Correct" and #ex-elapsed matches ^[0-9]+:[0-9][0-9]$',
    Boolean(lookupRight.text && /^Correct/.test(lookupRight.text) && lookupRight.elapsed && /^[0-9]+:[0-9][0-9]$/.test(lookupRight.elapsed)),
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

  // 9. Console hygiene.
  const hygiene = h.consoleHygiene();
  report('zero console errors and uncaught exceptions during the exercise run', hygiene.ok, hygiene);

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
  reviewBadgeMatchesDue: "review-queue badge (#sxc1-review-badge) count equals the #sxc1-progress payload's due count",
  deckCardTierMatches: "a deck card's data-tier matches the deck's declared tier: field (content/exercises, independently re-read)",
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

  await h.goto('#/', '#sxc1-progress-tools');
  await h.clickAssert('#btn-progress-wipe', 'M3: click #btn-progress-wipe (d2: must not clear jaFirst)');
  await h.clickAssert('#btn-progress-wipe-confirm', 'M3: click #btn-progress-wipe-confirm (d2)');
  await waitForProgressPredicate(h.evaluate, "p.state === 'empty'", 3000);
  const payloadAfterWipe2 = await readSxc1Progress(h.evaluate);
  const prefsRawAfterWipe = await readLocalStorageRaw(h.evaluate, PREFS_KEY);
  h.report(
    PROGRESS_ASSERTION_NAMES.jaFirstSurvivesWipe,
    Boolean(payloadAfterWipe2 && payloadAfterWipe2.jaFirst === true) && /(^|\n)P\tjaFirst\t1(\n|$)/.test(prefsRawAfterWipe || ''),
    { payloadAfterWipe2, prefsRawAfterWipe },
  );

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

  // -- E: review-queue badge vs payload's due; deck-card tier. ----------
  // payloadE is read AFTER the goto below (not immediately after the
  // ja-first reset click above) -- goto's own ready-selector poll
  // already waits for THIS navigation's render to settle, which is a
  // safe point to read #sxc1-progress from (unlike reading immediately
  // after a click that dispatches a Miso action with no intervening
  // wait -- see waitForProgressPredicate's own comment).
  await h.goto('#/', '#sxc1-review-badge');
  const payloadE = await readSxc1Progress(h.evaluate);
  const badgeText = await h.evaluate("(() => { const e = document.querySelector('#sxc1-review-badge'); return e ? e.textContent : null; })()");
  const badgeNum = badgeText ? Number((badgeText.match(/\d+/) || [NaN])[0]) : NaN;
  h.report(
    PROGRESS_ASSERTION_NAMES.reviewBadgeMatchesDue,
    Boolean(payloadE) && Number.isFinite(badgeNum) && badgeNum === payloadE.due,
    { badgeText, badgeNum, due: payloadE ? payloadE.due : null },
  );

  await h.goto(`#/x/${cfg.deckSlug}`, '.deck-card');
  const domTier = await h.evaluate("(() => { const e = document.querySelector('.deck-card'); return e ? e.getAttribute('data-tier') : null; })()");
  h.report(
    PROGRESS_ASSERTION_NAMES.deckCardTierMatches,
    Boolean(domTier) && domTier === cfg.expectedTier,
    { domTier, expectedTier: cfg.expectedTier },
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

async function runSelfTest(opts, negative) {
  const deadline = Date.now() + opts.timeout;
  const cleanupFns = [];
  const runCleanup = async () => {
    for (const fn of cleanupFns.splice(0).reverse()) {
      try { await fn(); } catch { /* best-effort cleanup */ }
    }
  };
  const die = async (code, message) => {
    if (message) console.error(message);
    await runCleanup();
    process.exit(code);
  };

  let expectedExJson = SELF_TEST_EXERCISE_STATS;
  if (!negative && opts.expectExerciseJson) {
    let parsed;
    try {
      parsed = parseJsonOrFile(opts.expectExerciseJson, '--expect-exercise-json');
    } catch (err) {
      await die(2, `error: ${err.message}`);
      return;
    }
    const schemaError = validateExpectExerciseJson(parsed, '--expect-exercise-json');
    if (schemaError) {
      await die(2, `error: ${schemaError}`);
      return;
    }
    expectedExJson = parsed;
  }

  const browserPath = resolveBrowser(opts.browser);
  if (!browserPath) {
    await die(2, 'error: no browser found for --self-test. Install Google Chrome/Chromium, or set ' +
      'SXC1_BROWSER to a browser executable path, or pass --browser <path>.');
    return;
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
    await die(2, `error: timed out waiting for DevTools at 127.0.0.1:${debugPort} (--self-test)`);
    return;
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
  const html = selfTestFixtureHtml(negative);
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
    await die(2, 'error: the self-test fixture never set window.__SXC1_BOOTED');
    return;
  }

  let passed = 0;
  let total = 0;
  const report = (name, ok, observed) => {
    total += 1;
    if (ok) { passed += 1; console.log(`ok - ${name}`); } else { console.log(`FAIL - ${name} (observed: ${JSON.stringify(observed)})`); }
  };
  const elementExists = (selector) => evaluate(`document.querySelector(${JSON.stringify(selector)}) !== null`);
  const assertElement = async (selector, label) => {
    const exists = await elementExists(selector);
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
  const click = (selector) => evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
  const clickAssert = async (selector, label) => {
    const present = await assertElement(selector, `${selector} is present before clicking it`);
    if (!present) { report(label, false, `skipped: ${selector} not found`); return false; }
    try {
      await click(selector);
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

  // M3 harness wave: "reload" for the persistence assertions -- an
  // ordinary Page.reload of the SAME file:// fixture, which re-executes
  // the whole inline <script> from scratch (a fresh IIFE invocation,
  // module-scope vars reinitialised) while localStorage -- the very
  // thing under test -- survives, exactly mirroring the real run's own
  // reload (see that one's comment for the full rationale).
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
  const coldLoadFn = async (fx, report) => {
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
      let booted = false;
      const bootDeadline = Math.min(deadline, Date.now() + 20000);
      while (Date.now() < bootDeadline) {
        let b;
        try { b = await coldEvaluate('window.__SXC1_BOOTED === true'); } catch { b = false; }
        if (b === true) { booted = true; break; }
        await sleep(50);
      }
      if (!booted) {
        report(COLD_ELAPSED_ASSERTION_NAME, false, 'the self-test fixture never booted on the cold target');
        return;
      }
      const coldClickAssert = async (selector, label) => {
        const present = await coldEvaluate(`document.querySelector(${JSON.stringify(selector)}) !== null`);
        if (!present) { report(label, false, `skipped: ${selector} not found`); return false; }
        await coldEvaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
        report(label, true, null);
        return true;
      };
      await assertColdFirstTryElapsed({ evaluate: coldEvaluate, clickAssert: coldClickAssert, report }, fx, waitMs);
    } catch (err) {
      report(COLD_ELAPSED_ASSERTION_NAME, false, `harness error: ${err && err.message ? err.message : String(err)}`);
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
    { evaluate, report, goto, click, clickAssert, assertElement, typeText, setMobileViewport, clearViewport, consoleHygiene },
    SELF_TEST_FIXTURE,
    negative ? null : expectedExJson,
    coldLoadFn,
  );

  // POST does not rely on anything runExerciseAssertions left behind --
  // it starts with its own wipe + reload.
  await runProgressAssertionsPost(progressHandle, progressCfg);
  results.push(...progressResults);

  await runCleanup();

  if (negative) {
    // --self-test-negative: exit 0 ONLY IF the specific assertions this
    // sabotaged grader is expected to break actually failed, and nothing
    // else did -- a re-runnable proof the browser assertions can fail on
    // their own subject, not a one-time manual demonstration.
    const expectedToFail = [
      'wrong quiz answer: #ex-feedback starts with "Not quite" and carries class "incorrect"',
      'lookup: wrong page submits to "Not quite"',
      // M2 gate fix additions: SABOTAGE (selfTestFixtureHtml(true)) also
      // forces elapsedMs to 0 (H1), skips clearing quiz result state on
      // Restart (H7), and omits drill-step / graded-lookup citations
      // (H8) -- see each's own comment in the fixture builder above.
      COLD_ELAPSED_ASSERTION_NAME,
      // M2 re-gate addition: SABOTAGE leaves #sxc1-prompt-baseline "null"
      // (the lost-mount-Begin scenario), so the baseline assertion must
      // fail on cue too.
      COLD_BASELINE_ASSERTION_NAME,
      WARM_FIRST_ELAPSED_ASSERTION_NAME,
      'Restart yields a genuinely blank prompt: no #ex-feedback, no #ex-note, no #btn-ex-next, no option aria-pressed="true"',
      `a completed drill renders a.cite hrefs that are well-formed AND include the declared #/m/${SELF_TEST_FIXTURE.drill.citeSlug}/p/${SELF_TEST_FIXTURE.drill.citePage}`,
      `a graded (correct) lookup renders an a.cite whose href equals the declared #/m/${SELF_TEST_FIXTURE.lookup.targetSlug}/p/${SELF_TEST_FIXTURE.lookup.targetPage}`,
      // M3 harness wave: every new persistence/JA-first/corrupt-blob/
      // review-queue assertion name -- see selfTestFixtureHtml's own M3
      // section for exactly which SABOTAGE branch breaks each one, and
      // runProgressAssertionsPost's inline comments for why each is
      // isolated (or, where honestly unavoidable, cascades) the way it
      // does.
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
    const byName = new Map(results.map((r) => [r.name, r.ok]));
    const problems = [];
    for (const name of expectedToFail) {
      if (byName.get(name) !== false) problems.push(`expected "${name}" to FAIL under the sabotaged grader, but it passed (or did not run)`);
    }
    for (const r of results) {
      if (!expectedToFail.includes(r.name) && r.ok === false) {
        problems.push(`unrelated assertion "${r.name}" unexpectedly failed`);
      }
    }
    if (problems.length === 0) {
      console.log(`browser-check --self-test-negative: ok -- the sabotaged grader was caught exactly as expected (${expectedToFail.length} assertion(s) failed on cue, nothing else did)`);
      process.exit(0);
    } else {
      console.error('browser-check --self-test-negative: FAILED');
      for (const p of problems) console.error(`  - ${p}`);
      process.exit(1);
    }
  } else {
    console.log(`browser-check --self-test: ${passed}/${total} assertions passed`);
    process.exit(passed === total ? 0 : 1);
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
  if (opts.checkStorageRefused) {
    await runStorageRefusedCheck(opts);
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
        '#sxc1-disclaimer names CASIO and non-affiliation',
        'no console errors or uncaught exceptions',
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

      // -- 3. guide-book TOC has the five exact PART titles -----------------------
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

      // -- 4. guide-book p.17 renders #page-17 with the expected text ------------
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

      // -- 5. JA toggle: image really decodes, then hides again -------------------
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
        const coldLoadFn = async (fx, cbReport) => {
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
            await assertColdFirstTryElapsed({ evaluate: coldEvaluate, clickAssert: coldClickAssert, report: cbReport }, fx, waitMs);
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
          { evaluate, report, goto, click, clickAssert, assertElement, typeText, setMobileViewport, clearViewport, consoleHygiene },
          exerciseFixture,
          expectedExerciseJson,
          coldLoadFn,
        );

        // POST does not rely on anything runExerciseAssertions left
        // behind (it starts with its own wipe + reload) -- see
        // runProgressAssertionsPost's own comment.
        await runProgressAssertionsPost(progressHandle, progressCfg);
      }
    }

    console.log(`browser-check: ${passed}/${total} assertions passed`);
    const exitCode = passed === total ? 0 : 1;
    await die(exitCode, null);
  } catch (err) {
    await die(2, `error: ${err && err.stack ? err.stack : err}`);
  }
}

main();
