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
  drill: { deck: 'demo-deck', id: 'demo-drill', steps: 2, hasVerify: true },
  lookup: { deck: 'demo-deck', id: 'demo-lookup', targetPage: 7 },
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
function selfTestFixtureHtml(sabotage) {
  const fx = SELF_TEST_FIXTURE;
  const statsJson = JSON.stringify(SELF_TEST_EXERCISE_STATS).replace(/</g, '\\u003c');
  const fixtureJson = JSON.stringify(fx).replace(/</g, '\\u003c');
  return `<!doctype html>
<html><head><meta charset="utf-8"><title>sxc1-self-test</title></head>
<body>
<div id="boot-status" hidden></div>
<div id="app">
  <div id="sxc1-exercise-stats" hidden>${statsJson}</div>
  <div id="sxc1-event-log" hidden>[]</div>
  <div id="sxc1-root"></div>
</div>
<script>
window.__SXC1_BOOTED = true;
(function () {
  var SABOTAGE = ${sabotage ? 'true' : 'false'};
  var FIXTURE = ${fixtureJson};
  var eventLog = [];
  var quizSelected = Object.create(null);
  var quizAttempted = false;
  var lastQuizCorrect = false;
  var drillCursor = 0;
  var lookupStartedAt = 0;
  var lookupResult = null;

  function root() { return document.getElementById('sxc1-root'); }
  function setEventLog() { document.getElementById('sxc1-event-log').textContent = JSON.stringify(eventLog); }
  function pushEvent(exId, kind, outcome) {
    eventLog.push({ deck: FIXTURE.quiz.deck, exercise: exId, prompt: exId + '#1', kind: kind,
      outcome: outcome, attempt: 1, revealed: false, hints: 0, elapsedMs: 1, at: Date.now() });
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
    root().innerHTML = '<section id="sxc1-deck"><h1 id="ex-deck-title">Demo deck</h1>' +
      '<p id="ex-deck-summary">A demo deck.</p><ol class="ex-list">' +
      '<li><a class="ex-link" href="#/x/' + FIXTURE.quiz.deck + '/' + FIXTURE.quiz.id + '"><span class="ex-kind kind-quiz">Quiz</span><span class="ex-title">Demo quiz</span></a></li>' +
      '<li><a class="ex-link" href="#/x/' + FIXTURE.drill.deck + '/' + FIXTURE.drill.id + '"><span class="ex-kind kind-drill">Drill</span><span class="ex-title">Demo drill</span></a></li>' +
      '<li><a class="ex-link" href="#/x/' + FIXTURE.lookup.deck + '/' + FIXTURE.lookup.id + '"><span class="ex-kind kind-lookup">Lookup</span><span class="ex-title">Demo lookup</span></a></li>' +
      '</ol></section>';
  }

  function feedbackHtml(correct) {
    return '<p id="ex-feedback" class="' + (correct ? 'correct' : 'incorrect') + '" role="status">' +
      (correct ? 'Correct.' : 'Not quite. Try again.') + '</p>' +
      (correct ? ('<div id="ex-note"><p>Why: demo note.</p></div>' +
        '<ul id="ex-cites"><li><a class="cite" href="#/m/' + FIXTURE.quiz.citeSlug + '/p/' + FIXTURE.quiz.citePage + '">cite</a></li></ul>' +
        '<button id="btn-ex-next">Next</button>') : '');
  }

  function renderQuiz() {
    var optsHtml =
      '<li><button id="' + FIXTURE.quiz.correctOpt + '" class="ex-option" aria-pressed="' + (quizSelected[FIXTURE.quiz.correctOpt] ? 'true' : 'false') + '">Correct option</button></li>' +
      '<li><button id="' + FIXTURE.quiz.wrongOpt + '" class="ex-option" aria-pressed="' + (quizSelected[FIXTURE.quiz.wrongOpt] ? 'true' : 'false') + '">Wrong option</button></li>';
    root().innerHTML = '<article id="sxc1-exercise" class="exercise kind-quiz">' +
      '<h1 id="ex-title">Demo quiz</h1><p id="ex-progress">1 / 1</p><div id="ex-stem"><p>Pick the right one.</p></div>' +
      '<ul id="ex-options">' + optsHtml + '</ul>' +
      '<button id="btn-ex-submit">Submit</button>' +
      (quizAttempted ? feedbackHtml(lastQuizCorrect) : '') +
      '</article>';
    Array.prototype.forEach.call(document.querySelectorAll('.ex-option'), function (btn) {
      btn.addEventListener('click', function () {
        quizSelected[btn.id] = !quizSelected[btn.id];
        renderQuiz();
      });
    });
    var submitBtn = document.getElementById('btn-ex-submit');
    submitBtn.addEventListener('click', function () {
      var selectedIds = Object.keys(quizSelected).filter(function (k) { return quizSelected[k]; });
      var isCorrect = SABOTAGE ? true : (selectedIds.length === 1 && selectedIds[0] === FIXTURE.quiz.correctOpt);
      quizAttempted = true;
      lastQuizCorrect = isCorrect;
      pushEvent(FIXTURE.quiz.id, 'quiz', isCorrect ? 'correct' : 'incorrect');
      renderQuiz();
    });
  }

  function renderDrill() {
    var stepsHtml = '';
    for (var i = 1; i <= FIXTURE.drill.steps; i++) {
      var idx0 = i - 1;
      stepsHtml += '<li class="ex-step" id="ex-step-' + i + '"><div class="ex-step-instruction"><p>Step ' + i + '.</p></div>' +
        '<p class="ex-step-check" id="ex-step-' + i + '-check">Check ' + i + '.</p>' +
        ((FIXTURE.drill.hasVerify && i === 1) ? '<p class="ex-verify" id="ex-step-1-verify">Automatic device confirmation arrives with WebMIDI support in a future update; confirm manually for now.</p>' : '') +
        (idx0 === drillCursor ? ('<button class="btn-ex-confirm" id="btn-ex-confirm-' + i + '">Confirm</button>') : '') +
        '</li>';
    }
    root().innerHTML = '<article id="sxc1-exercise" class="exercise kind-drill">' +
      '<h1 id="ex-title">Demo drill</h1><p id="ex-progress">' + Math.min(drillCursor + 1, FIXTURE.drill.steps) + ' / ' + FIXTURE.drill.steps + '</p>' +
      '<div id="ex-stem"><p>Do the thing.</p></div><ol id="ex-steps">' + stepsHtml + '</ol></article>';
    var btn = document.getElementById('btn-ex-confirm-' + (drillCursor + 1));
    if (btn) btn.addEventListener('click', function () {
      pushEvent(FIXTURE.drill.id, 'drill', 'correct');
      drillCursor += 1;
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
    root().innerHTML = '<article id="sxc1-exercise" class="exercise kind-lookup">' +
      '<h1 id="ex-title">Demo lookup</h1><p id="ex-progress">1 / 1</p><div id="ex-stem"><p>Find the page.</p></div>' +
      '<p id="ex-find-task">Find it.</p>' +
      '<input id="ex-find-input" type="number" inputmode="numeric">' +
      '<button id="btn-ex-find-submit">Submit</button>' +
      (lookupResult !== null ? (feedbackHtml(lookupResult) + (lookupResult ? ('<p id="ex-elapsed">' + elapsedStr() + '</p>') : '')) : '') +
      '</article>';
    if (lookupStartedAt === 0) lookupStartedAt = Date.now();
    var input = document.getElementById('ex-find-input');
    var submitBtn = document.getElementById('btn-ex-find-submit');
    submitBtn.addEventListener('click', function () {
      var n = parseInt(input.value, 10);
      var isCorrect = SABOTAGE ? true : (n === FIXTURE.lookup.targetPage);
      lookupResult = isCorrect;
      pushEvent(FIXTURE.lookup.id, 'lookup', isCorrect ? 'correct' : 'incorrect');
      renderLookup();
    });
  }

  function renderManualPage(slug, n) {
    root().innerHTML = '<article id="sxc1-page"><div class="page-body" id="page-' + n + '">Manual page ' + n + ' of ' + slug + '.</div></article>';
  }

  function render() {
    var h = location.hash.replace(/^#/, '');
    var parts = h.split('/').filter(Boolean);
    if (parts[0] === 'x' && parts.length === 1) { renderIndex(); return; }
    if (parts[0] === 'x' && parts.length === 2) { renderDeck(); return; }
    if (parts[0] === 'x' && parts.length === 3) {
      var exId = parts[2];
      if (exId === FIXTURE.quiz.id) { renderQuiz(); return; }
      if (exId === FIXTURE.drill.id) { drillCursor = 0; renderDrill(); return; }
      if (exId === FIXTURE.lookup.id) { lookupStartedAt = 0; lookupResult = null; renderLookup(); return; }
    }
    if (parts[0] === 'm' && parts.length >= 4 && parts[2] === 'p') { renderManualPage(parts[1], parts[3]); return; }
    renderIndex();
  }
  window.addEventListener('hashchange', render);
  render();
})();
<\/script>
</body></html>`;
}

// The assertion routine shared between --self-test/--self-test-negative
// and a real run driven with --exercise-fixture. `h` bundles everything
// that differs between "a self-test fixture page" and "the real app" --
// evaluate/report/goto/click/assertElement/typeText -- so this function
// itself never knows which one it is talking to. Returns the list of
// {name, ok} results (in order), so callers (both --self-test-negative
// and a real run) can inspect individual outcomes, not just the total.
async function runExerciseAssertions(h, fixture, expectedExerciseJson) {
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

  // 3. QUIZ ANSWER PATH. Ready selectors below are the KIND-specific
  // class (.kind-quiz/.kind-drill/.kind-lookup), never the shared
  // #sxc1-exercise id: that id persists across every exercise route (the
  // runner's own outer wrapper), so waiting for it alone can observe the
  // PREVIOUS exercise still on screen mid-navigation -- MEASURED on a
  // real run under load (the 108-route sweep just before this section):
  // it raced and read a stale drill/lookup page's content.
  await h.goto(`#/x/${fixture.quiz.deck}/${fixture.quiz.id}`, '.kind-quiz');
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
  await h.clickAssert(`#${fixture.quiz.wrongOpt}`, 'deselect the wrong quiz option');
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

  // 6. LOOKUP -- CDP Input.insertText, never a synthetic input event (P-D).
  await h.goto(`#/x/${fixture.lookup.deck}/${fixture.lookup.id}`, '.kind-lookup');
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

const EXERCISE_FIXTURE_FIELDS = {
  quiz: ['deck', 'id', 'correctOpt', 'wrongOpt', 'citeSlug', 'citePage'],
  drill: ['deck', 'id', 'steps', 'hasVerify'],
  lookup: ['deck', 'id', 'targetPage'],
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

  const results = await runExerciseAssertions(
    { evaluate, report, goto, click, clickAssert, assertElement, typeText, setMobileViewport, clearViewport, consoleHygiene },
    SELF_TEST_FIXTURE,
    negative ? null : expectedExJson,
  );

  await runCleanup();

  if (negative) {
    // --self-test-negative: exit 0 ONLY IF the specific assertions this
    // sabotaged grader is expected to break actually failed, and nothing
    // else did -- a re-runnable proof the browser assertions can fail on
    // their own subject, not a one-time manual demonstration.
    const expectedToFail = [
      'wrong quiz answer: #ex-feedback starts with "Not quite" and carries class "incorrect"',
      'lookup: wrong page submits to "Not quite"',
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
        await runExerciseAssertions(
          { evaluate, report, goto, click, clickAssert, assertElement, typeText, setMobileViewport, clearViewport, consoleHygiene },
          exerciseFixture,
          expectedExerciseJson,
        );
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
