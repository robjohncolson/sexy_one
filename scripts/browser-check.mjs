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
// Exit codes:
//   0  every assertion passed
//   1  at least one assertion failed (including a reported boot error)
//   2  harness error: no browser found, CDP unreachable, or overall timeout
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
  --timeout <ms>    Overall run timeout in milliseconds (default: 45000)
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
  constructor(ws) {
    this.ws = ws;
    this.nextId = 1;
    this.pending = new Map(); // id -> {resolve, reject}
    this.eventHandlers = new Map(); // method -> [handler(params, sessionId)]
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

  send(method, params = {}, sessionId) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      const payload = { id, method, params };
      if (sessionId) payload.sessionId = sessionId;
      this.pending.set(id, { resolve, reject });
      try {
        this.ws.send(JSON.stringify(payload));
      } catch (err) {
        this.pending.delete(id);
        reject(err);
      }
    });
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
    let browserExitedEarly = false;
    browserProc.on('exit', () => { browserExitedEarly = true; });
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
      if (browserExitedEarly) {
        await die(2, `error: browser process exited before DevTools became reachable (${browserPath})`);
        return;
      }
      try {
        const info = await httpGetJson(`http://127.0.0.1:${debugPort}/json/version`);
        if (info && info.webSocketDebuggerUrl) {
          versionInfo = info;
          break;
        }
      } catch {
        // not up yet
      }
      await sleep(200);
    }
    if (!versionInfo) {
      await die(2, `error: timed out waiting for DevTools at 127.0.0.1:${debugPort}`);
      return;
    }

    // 4. Connect and set up a flat CDP session for a fresh page target.
    const ws = await connectWebSocket(versionInfo.webSocketDebuggerUrl);
    cleanupFns.push(() => { try { ws.close(); } catch { /* ignore */ } });
    const cdp = new CDPClient(ws);

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
    // a JS-level exception (as opposed to a CDP transport error).
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

      await click('#btn-increment');
      const afterIncrement = await pollCounterFor('1');
      report('increment sets counter to 1', afterIncrement === '1', afterIncrement);

      await click('#btn-decrement');
      await click('#btn-decrement');
      const afterTwoDecrements = await pollCounterFor('-1');
      report('two decrements set counter to -1', afterTwoDecrements === '-1', afterTwoDecrements);

      await click('#btn-reset');
      const afterReset = await pollCounterFor('0');
      report('reset sets counter to 0', afterReset === '0', afterReset);

      const bootStatusHidden = await evaluate(`(() => {
        const e = document.querySelector('#boot-status');
        if (!e) return true;
        return Boolean(e.hidden) || e.offsetParent === null;
      })()`);
      report('#boot-status is hidden after boot', bootStatusHidden === true, bootStatusHidden);

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
