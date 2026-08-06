#!/usr/bin/env node
// browser-check.mjs -- dependency-free headless-Chrome acceptance driver.
//
// Drives Google Chrome / Chromium over the Chrome DevTools Protocol (CDP)
// using only Node built-ins (global WebSocket, net, child_process, fs, http,
// os, path). No npm packages, no package.json, no node_modules anywhere.
//
// Usage:
//   node scripts/browser-check.mjs [--url URL] [--browser PATH]
//                                   [--timeout MS] [--self-test] [--keep-open]
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
// See the "Shared boot / test contract" in briefs/M0-manifest.json for the
// window.__SXC1_BOOTED / window.__SXC1_BOOT_ERROR / #boot-status / #counter-value
// / #btn-increment / #btn-decrement / #btn-reset contract this script checks.

import { spawn } from 'node:child_process';
import * as fs from 'node:fs';
import * as http from 'node:http';
import * as net from 'node:net';
import * as os from 'node:os';
import * as path from 'node:path';

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const opts = {
    url: 'http://127.0.0.1:8123/',
    browser: null,
    timeout: 45000,
    selfTest: false,
    keepOpen: false,
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
      case '--self-test':
        opts.selfTest = true;
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
  --url <url>       Page to check (default: http://127.0.0.1:8123/)
  --browser <path>  Browser executable (default: $SXC1_BROWSER, else the
                     first of google-chrome, google-chrome-stable, chromium,
                     chromium-browser found on PATH)
  --timeout <ms>    Overall run timeout in milliseconds (default: 45000).
                     Bounds the WebSocket connect, every CDP command and
                     every polling loop -- not just the polling loops.
  --self-test       Check the driver itself against a synthetic fixture
                     page instead of the real site
  --keep-open       Do not kill the browser on exit (debugging)
  --help            Show this help and exit`);
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
// Deadline plumbing (M4 fix).
//
// The whole run shares ONE monotonic deadline, computed once in main() from
// --timeout. `remaining()` reports the budget left; `withDeadline()` races
// an arbitrary promise against it. Every await that could otherwise hang --
// the WebSocket handshake (connectWebSocket), the DevTools HTTP poll, and
// (via CDPClient.send's own per-command timer, which consults the same
// clock through a `getRemaining` callback) every CDP command including the
// boot- and counter-polling loops that repeatedly call it -- is bounded by
// this single clock.
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

function connectWebSocket(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const onOpen = () => { cleanup(); resolve(ws); };
    const onError = (ev) => { cleanup(); reject(new Error(`WebSocket connect failed: ${ev.message || ev}`)); };
    const cleanup = () => {
      ws.removeEventListener('open', onOpen);
      ws.removeEventListener('error', onError);
    };
    ws.addEventListener('open', onOpen);
    ws.addEventListener('error', onError);
  });
}

// ---------------------------------------------------------------------------
// Self-test fixture: a plain-JS page that reproduces the boot / test
// contract without any WebAssembly involved, so the driver can prove it
// works before the real Miso/WASM app exists.
// ---------------------------------------------------------------------------

const SELF_TEST_FIXTURE_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>browser-check self-test fixture</title>
</head>
<body>
<div id="boot-status">Loading...</div>
<main id="app">
  <output id="counter-value">0</output>
  <div class="buttons">
    <button id="btn-decrement">-</button>
    <button id="btn-reset">reset</button>
    <button id="btn-increment">+</button>
  </div>
</main>
<script>
  let n = 0;
  const counterEl = document.getElementById('counter-value');
  function render() { counterEl.textContent = String(n); }
  document.getElementById('btn-increment').addEventListener('click', () => { n += 1; render(); });
  document.getElementById('btn-decrement').addEventListener('click', () => { n -= 1; render(); });
  document.getElementById('btn-reset').addEventListener('click', () => { n = 0; render(); });
  render();
  // Simulate an async boot, same as the real WASM loader does.
  setTimeout(() => {
    document.getElementById('boot-status').hidden = true;
    window.__SXC1_BOOTED = true;
  }, 50);
</script>
</body>
</html>
`;

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

  try {
    let targetUrl = opts.url;

    // --self-test: stand up a synthetic fixture page and serve it locally,
    // then run the exact same assertion sequence against it below.
    if (opts.selfTest) {
      const fixtureDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sxc1-browsercheck-fixture-'));
      fs.writeFileSync(path.join(fixtureDir, 'index.html'), SELF_TEST_FIXTURE_HTML);
      cleanupFns.push(() => removeDirWithRetry(fixtureDir));

      const fixturePort = await findFreePort();
      const fixtureServer = spawn(
        'python3',
        ['-m', 'http.server', '--bind', '127.0.0.1', '--directory', fixtureDir, String(fixturePort)],
        { stdio: 'ignore' },
      );
      cleanupFns.push(() => new Promise((resolve) => {
        if (fixtureServer.exitCode !== null || fixtureServer.signalCode !== null) {
          resolve();
          return;
        }
        const forceKillTimer = setTimeout(() => {
          try { fixtureServer.kill('SIGKILL'); } catch { /* already gone */ }
        }, 2000);
        fixtureServer.once('exit', () => { clearTimeout(forceKillTimer); resolve(); });
        try {
          fixtureServer.kill('SIGTERM');
        } catch {
          clearTimeout(forceKillTimer);
          resolve();
        }
      }));

      targetUrl = `http://127.0.0.1:${fixturePort}/`;
      await waitForHttpOk(targetUrl, deadline);
      console.log(`[self-test] serving synthetic fixture at ${targetUrl}`);
    }

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
      cdp.failFatally(new Error(`CDP WebSocket error: ${ev && ev.message ? ev.message : ev}`));
    });

    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

    // 5. Enable Runtime/Page and record console errors + uncaught exceptions.
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
    // failFatally() the same way every other command is.
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

    const readCounter = () => evaluate(
      `(() => { const e = document.querySelector('#counter-value'); return e ? e.textContent.trim() : null; })()`,
    );
    const pollCounterFor = async (expected, timeoutMs = 2000) => {
      const localDeadline = Math.min(Date.now() + timeoutMs, deadline);
      let last = null;
      while (true) {
        last = await readCounter();
        if (last === expected) return last;
        if (Date.now() >= localDeadline) return last;
        await sleep(50);
      }
    };
    const click = (selector) => evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);

    // m3(a)/(b) fix: never let a missing required DOM node throw out of
    // this block (which used to escape as an uncaught exception and get
    // misreported as exit 2 "harness error") and never treat absence as a
    // pass. elementExists()/assertElement() always resolve to a boolean and
    // always go through report(), so a missing node is an ordinary FAILED
    // assertion (exit 1).
    const elementExists = (selector) => evaluate(
      `document.querySelector(${JSON.stringify(selector)}) !== null`,
    );
    const assertElement = async (selector, label) => {
      const exists = await elementExists(selector);
      report(label, exists === true, exists);
      return exists === true;
    };

    // Click `selector`, reporting both its presence and the click itself as
    // ordinary assertions, instead of a bare evaluate() whose
    // `.click()` on a null querySelector() result would throw out of this
    // block.
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
        'counter starts at 0',
        'increment sets counter to 1',
        'two decrements set counter to -1',
        'reset sets counter to 0',
        '#boot-status is hidden after boot',
        'no console errors or uncaught exceptions',
      ]) {
        report(name, false, 'skipped: app did not boot');
      }
    } else {
      const initial = await pollCounterFor('0');
      report('counter starts at 0', initial === '0', initial);

      await clickAssert('#btn-increment', 'click #btn-increment');
      const afterIncrement = await pollCounterFor('1');
      report('increment sets counter to 1', afterIncrement === '1', afterIncrement);

      await clickAssert('#btn-decrement', 'click #btn-decrement (1 of 2)');
      await clickAssert('#btn-decrement', 'click #btn-decrement (2 of 2)');
      const afterTwoDecrements = await pollCounterFor('-1');
      report('two decrements set counter to -1', afterTwoDecrements === '-1', afterTwoDecrements);

      await clickAssert('#btn-reset', 'click #btn-reset');
      const afterReset = await pollCounterFor('0');
      report('reset sets counter to 0', afterReset === '0', afterReset);

      // m3(b) fix: the boot-status contract requires #boot-status to exist
      // -- without it a boot failure has nowhere to render -- so absence is
      // now a FAILED assertion rather than a vacuous pass. Existence and
      // hiddenness are asserted together in one CDP round trip so there is
      // no window between checking one and checking the other.
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

      const noErrors = consoleErrors.length === 0 && exceptions.length === 0;
      report('no console errors or uncaught exceptions', noErrors, { consoleErrors, exceptions });
    }

    console.log(`browser-check: ${passed}/${total} assertions passed`);
    const exitCode = passed === total ? 0 : 1;
    await die(exitCode, null);
  } catch (err) {
    await die(2, `error: ${err && err.stack ? err.stack : err}`);
  }
}

main();
