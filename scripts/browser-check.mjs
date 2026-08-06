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
                       against it field-for-field. When absent, it is
                       compared against the golden numbers table baked
                       into this script.
  --quick              Sweep a small sample of pages (first/middle/last of
                       each manual) instead of all 108 routes.
  --browser <path>     Browser executable (default: $SXC1_BROWSER, else the
                       first of google-chrome, google-chrome-stable, chromium,
                       chromium-browser found on PATH)
  --timeout <ms>       Overall run timeout in milliseconds (default: 45000).
                       Bounds the WebSocket connect, every CDP command and
                       every polling loop -- not just the polling loops.
  --keep-open          Do not kill the browser on exit (debugging)
  --help               Show this help and exit`);
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
    if (!parsed || !Array.isArray(parsed.docs)) {
      console.error(`error: --expect-json file '${opts.expectJson}' has no top-level "docs" array`);
      process.exit(2);
      return;
    }
    expected = { docs: parsed.docs, fields: null, full: true };
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

    // 5. Enable Runtime/Page and record console errors + uncaught exceptions
    // for the ENTIRE run (every navigation below shares this one page
    // target, so this one listener pair covers the whole sweep).
    const consoleErrors = [];
    const exceptions = [];
    cdp.on('Runtime.consoleAPICalled', (params, sid) => {
      if (sid !== sessionId) return;
      if (params.type === 'error') {
        const text = (params.args || []).map((a) => a.description ?? a.value ?? String(a.type)).join(' ');
        consoleErrors.push(text);
      }
    });
    cdp.on('Runtime.exceptionThrown', (params, sid) => {
      if (sid !== sessionId) return;
      const detail = params.exceptionDetails;
      exceptions.push(detail?.exception?.description || detail?.text || JSON.stringify(detail));
    });

    await cdp.send('Runtime.enable', {}, sessionId);
    await cdp.send('Page.enable', {}, sessionId);

    // Evaluate an expression in the page and return its value, throwing on
    // a JS-level exception (as opposed to a CDP transport error). Routed
    // through cdp.send(), so it is bounded by the shared deadline and by
    // failFatally() the same way every other command is. awaitPromise:true
    // lets a single evaluate() run an internal poll loop (used throughout
    // below to wait for a settled render without round-tripping to Node
    // for every tick).
    const evaluate = async (expression) => {
      const res = await cdp.send('Runtime.evaluate', {
        expression,
        returnByValue: true,
        awaitPromise: true,
      }, sessionId);
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
        '#/m/guide-book/p/17/ja deep-links into the JA-visible state',
        'next/prev navigation',
        'page 1 has no enabled prev / last page has no enabled next',
        'guide-book p.15 has a p.17 cross-reference link',
        '108-route sweep',
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

      // -- 6. .../p/17/ja deep-links straight into the JA-visible state ----------
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
        '#/m/guide-book/p/17/ja deep-links into the JA-visible state on a cold load',
        Boolean(deepLinked && deepLinked.hasJaClass && deepLinked.panelExists && deepLinked.imgOk),
        deepLinked,
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

      // -- 9. FULL SWEEP: every page route renders a non-empty #sxc1-page --------
      const routes = opts.quick ? quickRouteList() : fullRouteList();
      const sweepStart = Date.now();
      const sweepFailures = [];
      for (const { slug, n } of routes) {
        const hash = `#/m/${slug}/p/${n}`;
        const result = await evaluate(`(async () => {
          window.location.hash = ${JSON.stringify(hash)};
          const start = Date.now();
          while (Date.now() - start < 4000) {
            const el = document.querySelector('#sxc1-page');
            if (el && el.textContent.trim().length > 0 && document.querySelector(${JSON.stringify(`#page-${n}`)})) {
              return { ok: true };
            }
            await new Promise((r) => setTimeout(r, 15));
          }
          const el = document.querySelector('#sxc1-page');
          return { ok: false, textLen: el ? el.textContent.trim().length : -1 };
        })()`);
        if (!result || result.ok !== true) sweepFailures.push({ hash, result });
      }
      const sweepMs = Date.now() - sweepStart;
      report(
        `all ${routes.length} page routes render a non-empty #sxc1-page${opts.quick ? ' (--quick sample)' : ''}`,
        sweepFailures.length === 0,
        { count: routes.length, ms: sweepMs, failures: sweepFailures.slice(0, 5) },
      );
      console.log(`[sweep] ${routes.length} routes in ${sweepMs}ms`);

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
    }

    console.log(`browser-check: ${passed}/${total} assertions passed`);
    const exitCode = passed === total ? 0 : 1;
    await die(exitCode, null);
  } catch (err) {
    await die(2, `error: ${err && err.stack ? err.stack : err}`);
  }
}

main();
