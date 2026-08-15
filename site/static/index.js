// Boot loader for the SXC-1 Trainer WASM application.
//
// Instantiates app.wasm (a WASI *reactor* module compiled from Haskell/Miso)
// against a vendored browser WASI shim and GHC's generated JSFFI import
// object, then starts the Haskell RTS and mounts the Miso app.
//
// NOTE: WebAssembly.instantiateStreaming requires the server to send
// Content-Type: application/wasm for ./app.wasm. Both GitHub Pages and
// `python3 -m http.server` do this out of the box.
import { WASI, OpenFile, File, ConsoleStdout } from "./vendor/browser_wasi_shim/index.js";
import ghc_wasm_jsffi from "./ghc_wasm_jsffi.js";

// M3 storage-refused fix (harness finding, --check-storage-refused): a
// JS exception thrown by localStorage (private mode, quota, disabled)
// does NOT unwind into Haskell as a catchable exception -- it propagates
// out of the wasm import and kills the calling Haskell computation
// (observed: boot death via window.__SXC1_BOOT_ERROR). So the app never
// calls localStorage directly: every access goes through this bridge,
// which catches JS-side and returns sentinel values instead of throwing.
// undefined = "missing or refused"; the wasm side treats any refusal as
// storage-unavailable and runs the fully working no-persistence mode.
window.__sxc1Storage = {
  get: (k) => { try { const v = window.localStorage.getItem(k); return v === null ? undefined : v; } catch (e) { return undefined; } },
  set: (k, v) => { try { window.localStorage.setItem(k, v); return 1; } catch (e) { return 0; } },
  del: (k) => { try { window.localStorage.removeItem(k); return 1; } catch (e) { return 0; } },
  probe: () => {
    try {
      window.localStorage.setItem("sxc1.storage-probe", "1");
      const ok = window.localStorage.getItem("sxc1.storage-probe") === "1";
      window.localStorage.removeItem("sxc1.storage-probe");
      return ok ? 1 : 0;
    } catch (e) { return 0; }
  },
};


// M6 W1 (briefs/M6-plan.md, ruling 1) + M7 W1 (briefs/M7-plan.md,
// ruling 1): NEITHER corpus is embedded in app.wasm any more. The
// exercise course ships as content.<lang>.txt and the manual text as
// manuals.<lang>.txt (both emitted by scripts/emit-content-bundles.py
// into site/public/content/), and BOTH are loaded HERE, on the JS side,
// with the same guard discipline as the storage bridge above: the
// network calls and every failure live entirely in this file (a JS
// exception does not unwind into Haskell -- it kills the boot
// computation), and the wasm side only ever sees total,
// try/catch-wrapped bridge methods. A load failure must NEVER kill
// boot: the app starts with an empty corpus (or empty manuals) plus the
// failure reason and renders its visible degraded state (the ONE
// #sxc1-content-error banner, which names whichever bundle failed; the
// affected routes show #btn-content-retry).
//
// ONE FETCH DISCIPLINE, not two: both requests are issued together,
// share ONE AbortController and ONE deadline (below), and resolve into
// one result object. Whatever succeeded is used; whatever failed
// degrades. A reload -- the retry -- re-runs both.
//
// The bundles are served as PLAIN .txt, deliberately not pre-compressed
// .txt.gz: GitHub Pages (like the local dev servers) compresses text
// responses on the wire via ordinary Content-Encoding negotiation, but
// it does NOT transparently serve a .gz sidecar as gzip-encoded content
// -- a fetched .txt.gz would arrive as opaque bytes needing a manual
// DecompressionStream pass. Plain text + on-the-wire compression is the
// simplest robust choice; check-site.sh's bundle ledgers measure the
// gzip cost against the M6 and M7 ceilings.
//
// M6 W2: the language comes from the JS BOOT HINT -- the dedicated tiny
// localStorage key "sxc1.uilang" (raw "en"/"ja", no envelope), written
// by the app (Progress/Store.hs saveUiLangHint) alongside every prefs-
// blob write that changes uiLang, and re-synced at every boot when the
// two disagree. This deliberately does NOT read the SXC1PREFS blob:
// parsing it here would duplicate the Haskell codec (SXC1.Progress.
// Codec.decodePrefs) in a second language, and the two copies would
// drift. The hint is a cache whose loss is harmless: a missing/corrupt
// hint boots 'en' (the default bundle), the app notices the
// disagreement against the real decoded pref at boot and rewrites the
// hint, and the next reload fetches the right bundle. Anything but the
// exact "ja" value is 'en' -- the same clamp the Haskell codec applies.
function sxc1ContentLang() {
  try {
    return window.localStorage.getItem("sxc1.uilang") === "ja" ? "ja" : "en";
  } catch (e) {
    return "en";
  }
}

// The document's own language tag follows the same pre-boot hint, so
// screen readers pronounce the (localized) UI in the right language
// from the first frame. Purely an attribute write; never throws into
// boot (and localization of the strings themselves is wasm-side).
const sxc1UiLang = sxc1ContentLang();
try { document.documentElement.lang = sxc1UiLang; } catch (e) { /* harmless */ }

// M9 phone-ready shell. Registration waits until the trainer is interactive so
// the service worker's cache fill never competes with the first useful boot.
// Once installed it supplies a coherent connection-failure fallback for the
// executable shell and both text languages. A new worker can activate only
// after its complete versioned core cache exists.
const PHONE_STRINGS = {
  en: {
    offline: "Offline — saved lessons remain available.",
  },
  ja: {
    offline: "オフライン — 保存済みのレッスンを利用できます。",
  },
};
const phoneStrings = PHONE_STRINGS[sxc1UiLang] || PHONE_STRINGS.en;
let sxc1InstallPrompt = null;
window.addEventListener("beforeinstallprompt", (event) => {
  event.preventDefault();
  sxc1InstallPrompt = event;
  if (window.__SXC1_PWA) window.__SXC1_PWA.installable = true;
});
window.addEventListener("appinstalled", () => {
  sxc1InstallPrompt = null;
  if (window.__SXC1_PWA) window.__SXC1_PWA.installed = true;
});

function sxc1UpdateNetworkStatus() {
  const status = document.getElementById("sxc1-network-status");
  const offline = typeof navigator.onLine === "boolean" && !navigator.onLine;
  if (status) {
    status.textContent = offline ? phoneStrings.offline : "";
    status.hidden = !offline;
  }
  document.documentElement.dataset.sxc1Online = String(!offline);
  if (window.__SXC1_PWA) window.__SXC1_PWA.online = !offline;
}

async function sxc1EnablePhoneReadyShell() {
  window.__SXC1_PWA = {
    supported: "serviceWorker" in navigator,
    registered: false,
    ready: false,
    offlineCapable: false,
    online: navigator.onLine !== false,
    installable: Boolean(sxc1InstallPrompt),
    installed: window.matchMedia?.("(display-mode: standalone)")?.matches === true,
    cacheVersion: null,
  };
  sxc1UpdateNetworkStatus();
  window.addEventListener("online", sxc1UpdateNetworkStatus);
  window.addEventListener("offline", sxc1UpdateNetworkStatus);
  if (!("serviceWorker" in navigator)) return;
  try {
    const workerUrl = new URL("./sw.js", import.meta.url);
    const scopeUrl = new URL("./", import.meta.url);
    const registration = await navigator.serviceWorker.register(workerUrl, {
      scope: scopeUrl.href,
      updateViaCache: "none",
    });
    window.__SXC1_PWA.registered = true;
    window.__SXC1_PWA.scope = registration.scope;
    const ready = await navigator.serviceWorker.ready;
    window.__SXC1_PWA.ready = true;
    window.__SXC1_PWA.offlineCapable = true;
    document.documentElement.dataset.sxc1OfflineReady = "true";

    const active = ready.active || navigator.serviceWorker.controller;
    if (active) {
      const onStatus = (event) => {
        if (!event.data || event.data.type !== "SXC1_STATUS") return;
        window.__SXC1_PWA.cacheVersion = event.data.cacheVersion || null;
        navigator.serviceWorker.removeEventListener("message", onStatus);
      };
      navigator.serviceWorker.addEventListener("message", onStatus);
      active.postMessage("SXC1_STATUS");
    }
  } catch (err) {
    // Offline readiness is an enhancement. A refused/unsupported worker must
    // never turn an otherwise healthy trainer boot into an error.
    window.__SXC1_PWA.error = err && err.message ? err.message : String(err);
  }
}

const bootStatus = document.getElementById("boot-status");
const bootStatusText = document.getElementById("boot-status-text");
const BOOT_STRINGS = {
  en: {
    download: "Downloading the trainer…",
    course: "Preparing the course…",
    start: "Starting your session…",
    unsupported: "This browser cannot run the trainer's WebAssembly build. On iPhone or iPad, update to iOS 16.4 or later, then reload. Your progress has not been changed.",
    failed: "The trainer could not start. Check the connection, update the browser, and reload.",
  },
  ja: {
    download: "トレーナーを読み込んでいます…",
    course: "コースを準備しています…",
    start: "セッションを開始しています…",
    unsupported: "このブラウザではトレーナーのWebAssemblyを実行できません。iPhoneまたはiPadではiOS 16.4以降に更新してから、再読み込みしてください。進捗データは変更されていません。",
    failed: "トレーナーを開始できませんでした。接続とブラウザの更新を確認して、再読み込みしてください。",
  },
};
const bootStrings = BOOT_STRINGS[sxc1UiLang] || BOOT_STRINGS.en;
const sxc1BootStartedAt = performance.now();
const setBootStage = (message) => {
  if (bootStatusText) bootStatusText.textContent = message;
};

// GHC's wasm32 runtime is built with fixed SIMD instructions. Test that
// exact baseline before requesting the 850+ KB compressed module so an older
// mobile engine gets a small, useful failure instead of a long generic boot
// error. This 31-byte module returns a v128 and has no imports or side effects.
const SXC1_SIMD_PROBE = new Uint8Array([
  0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 123, 3,
  2, 1, 0, 10, 10, 1, 8, 0, 65, 0, 253, 15, 253, 98, 11,
]);
let sxc1WasmSupported = false;
try {
  sxc1WasmSupported = typeof WebAssembly === "object"
    && typeof WebAssembly.validate === "function"
    && WebAssembly.validate(SXC1_SIMD_PROBE);
} catch (_) {
  sxc1WasmSupported = false;
}
setBootStage(sxc1WasmSupported ? bootStrings.download : bootStrings.unsupported);
// Begin the dominant request before the two text corpora below. Passing the
// response promise into instantiateStreaming preserves streaming compilation.
const sxc1WasmResponsePromise = sxc1WasmSupported ? fetch("./app.wasm") : null;

// M6 gate round 1 (briefs/M6-codex-gate1.json, finding M6-R1-5): THE
// FETCH DEADLINE. The load below is awaited before hs_start, so a
// server that accepts the connection and then never completes the body
// (a stalled CDN edge, a captive portal, a half-open proxy) used to
// block boot FOREVER: no app, no manuals, no retry -- only the static
// loading state, which is precisely the failure mode the JS-side guard
// exists to prevent. Neither fetch() nor Response.text() has a timeout
// of its own, so the whole load (headers AND body) runs under one
// AbortController armed with this deadline; a timeout resolves to the
// same { ok: false, error } shape a 404 or an offline failure does, and
// the app boots into its ordinary visible degraded state with the
// #btn-content-retry affordance.
//
// 15 seconds: an order of magnitude above a realistic worst case for a
// ~280 KB text response over a wire-compressed CDN link, and far below
// any human tolerance for a blank page. The value is a constant, not a
// setting -- scripts/check-site.sh's stalled-fetch stage serves a
// deliberately hung endpoint and asserts the degraded surface appears
// (the harness never injects a shorter deadline: the served endpoint
// IS the input, exactly like --check-content-missing).
//
// M7 W1: the SAME single deadline now covers BOTH bundles. The two
// requests are issued together and share one AbortController, so the
// worst case is still one 15s wait -- not one per bundle -- and a
// server that stalls either one cannot extend boot beyond it.
const SXC1_CONTENT_TIMEOUT_MS = 15000;

// Started BEFORE wasm instantiation so the loads overlap the compile;
// awaited just before hs_start. This promise NEVER rejects -- all three
// failure shapes (non-2xx, thrown, timed out) resolve, PER BUNDLE, to
// { ok: false, error }, so one failing bundle never hides or aborts the
// other's result.
const sxc1ContentPromise = sxc1WasmSupported ? (async () => {
  const lang = sxc1ContentLang();
  let controller = null;
  let timer = null;
  try {
    controller = typeof AbortController === 'function' ? new AbortController() : null;
  } catch (e) {
    controller = null;
  }
  let timedOut = false;
  if (controller) {
    timer = setTimeout(() => {
      timedOut = true;
      try { controller.abort(); } catch (e) { /* already settled */ }
    }, SXC1_CONTENT_TIMEOUT_MS);
  }
  // ONE loader for both bundles: identical guard, identical failure
  // shapes, identical deadline -- there is no second fetch discipline
  // to keep in sync.
  const loadOne = async (rel) => {
    try {
      const resp = await fetch(rel, controller ? { signal: controller.signal } : undefined);
      if (!resp.ok) {
        return { ok: false, error: `HTTP ${resp.status} fetching ${rel}` };
      }
      // The body is read under the SAME deadline: a server can send
      // headers immediately and then stall the body indefinitely, which
      // is the exact stall this guard exists for.
      const text = await resp.text();
      return { ok: true, text };
    } catch (err) {
      if (timedOut) {
        return { ok: false, error: `${rel} timed out after ${SXC1_CONTENT_TIMEOUT_MS}ms (content load deadline)` };
      }
      return { ok: false, error: `${rel} unreachable: ${err && err.message ? err.message : String(err)}` };
    }
  };
  try {
    const [content, manual] = await Promise.all([
      loadOne(`./content/content.${lang}.txt`),
      loadOne(`./content/manuals.${lang}.txt`),
    ]);
    return { lang, content, manual };
  } catch (err) {
    // Unreachable in practice (loadOne never rejects), but boot must
    // never depend on that being true.
    const reason = `content load failed: ${err && err.message ? err.message : String(err)}`;
    return { lang, content: { ok: false, error: reason }, manual: { ok: false, error: reason } };
  } finally {
    if (timer !== null) clearTimeout(timer);
  }
})() : Promise.resolve({
  lang: sxc1UiLang,
  content: { ok: false, error: "unsupported WebAssembly runtime" },
  manual: { ok: false, error: "unsupported WebAssembly runtime" },
});

try {
  if (!sxc1WasmSupported || !sxc1WasmResponsePromise) {
    throw new Error(bootStrings.unsupported);
  }
  const wasi = new WASI([], ["GHCRTS=-H16m"], [
    new OpenFile(new File([])), // stdin
    ConsoleStdout.lineBuffered((msg) => console.log("[wasm stdout]", msg)),
    ConsoleStdout.lineBuffered((msg) => console.warn("[wasm stderr]", msg)),
  ], { debug: false });

  // GHC's JSFFI import object needs the instance's exports to call back
  // into wasm, but the exports only exist once instantiation finishes, so
  // we pass a mutable placeholder object and fill it in afterwards.
  const instanceExports = {};
  const { instance } = await WebAssembly.instantiateStreaming(sxc1WasmResponsePromise, {
    wasi_snapshot_preview1: wasi.wasiImport,
    ghc_wasm_jsffi: ghc_wasm_jsffi(instanceExports),
  });
  const sxc1WasmReadyAt = performance.now();
  Object.assign(instanceExports, instance.exports);
  setBootStage(bootStrings.course);

  // The content bridge MUST be installed before hs_start: Main.main
  // reads it synchronously at boot (Bundle). Every method is total --
  // try/catch, sentinel returns -- mirroring __sxc1Storage, so no
  // content failure can ever throw across the wasm boundary.
  // undefined = "load failed" for text()/manualText(); undefined =
  // "load succeeded" for error()/manualError().
  //
  // M7 W1: ONE bridge, one requested language, two payloads -- the
  // exercise course and the manual text. Adding a THIRD pair of methods
  // rather than a second bridge keeps the wasm side's read (Bundle.
  // loadVia) one parameterised function instead of two copies.
  const sxc1Content = await sxc1ContentPromise;
  const sxc1ContentReadyAt = performance.now();
  const part = (name) => { try { return sxc1Content[name] || { ok: false, error: "content bridge failure" }; } catch (e) { return { ok: false, error: "content bridge failure" }; } };
  window.__sxc1Content = {
    lang: () => { try { return sxc1Content.lang; } catch (e) { return "en"; } },
    text: () => { const p = part("content"); return p.ok ? p.text : undefined; },
    error: () => { const p = part("content"); return p.ok ? undefined : String(p.error); },
    manualText: () => { const p = part("manual"); return p.ok ? p.text : undefined; },
    manualError: () => { const p = part("manual"); return p.ok ? undefined : String(p.error); },
  };

  setBootStage(bootStrings.start);
  wasi.initialize(instance);          // runs _initialize, starting the Haskell RTS
  await instance.exports.hs_start();  // mounts the Miso app into <body>

  window.__SXC1_BOOT_METRICS = {
    wasmMs: Math.round(sxc1WasmReadyAt - sxc1BootStartedAt),
    contentMs: Math.round(sxc1ContentReadyAt - sxc1BootStartedAt),
    totalMs: Math.round(performance.now() - sxc1BootStartedAt),
    memoryBytes: instance.exports.memory?.buffer?.byteLength || 0,
    transferBytes: performance.getEntriesByType("resource")
      .reduce((sum, entry) => sum + (Number(entry.transferSize) || 0), 0),
    encodedBodyBytes: performance.getEntriesByType("resource")
      .reduce((sum, entry) => sum + (Number(entry.encodedBodySize) || 0), 0),
    effectiveType: navigator.connection?.effectiveType || null,
    saveData: navigator.connection?.saveData === true,
  };
  document.documentElement.dataset.sxc1BootMs = String(window.__SXC1_BOOT_METRICS.totalMs);
  document.documentElement.dataset.sxc1MemoryBytes = String(window.__SXC1_BOOT_METRICS.memoryBytes);

  if (bootStatus) {
    bootStatus.hidden = true;
  }
  window.__SXC1_BOOTED = true;
} catch (err) {
  console.error(err);
  window.__SXC1_BOOT_ERROR = String(err);
  if (bootStatus) {
    bootStatus.hidden = false;
    bootStatus.classList.add("boot-error");
    const message = err && err.message ? err.message : String(err);
    bootStatus.textContent = `${bootStrings.failed}\n\n${message}`;
  }
}

if (window.__SXC1_BOOTED === true) {
  sxc1EnablePhoneReadyShell();
  // Sample Lab is deliberately deferred until the trainer is interactive. It
  // has no place in the first-load module graph or app.wasm size budget.
  import("./sample-lab.js")
    .then((module) => module.startSampleLab({ lang: sxc1UiLang }))
    .catch((error) => {
      console.error("Sample Lab could not start", error);
      window.__SXC1_SAMPLE_LAB_ERROR = String(error);
    });
}

// M3 progress-ui (site/app/View/Progress.hs): two small, Miso-independent
// DOM behaviours that deliberately never touch Haskell state -- see that
// module's own Haddock for why no Action/Model field exists (or should
// exist) for either. Both are event-delegated on `document`, so they
// keep working across Miso's own route-driven DOM rebuilds without
// re-registering anything, and both reset naturally on navigation: Miso
// destroys and recreates the whole #sxc1-home subtree on a route change,
// so leaving the page always restores btn-progress-wipe-confirm's
// [hidden] default and empties the import textarea.

// Wipe: an explicit two-step confirm. #btn-progress-wipe-confirm starts
// [hidden] in the Haskell-rendered markup (see View/Progress.hs) and
// STAYS that way across unrelated re-renders on its own -- Miso's vdom
// diff only ever touches a DOM attribute when the two vdom trees being
// compared actually disagree on it, and nothing in the Model ever
// represents "wipe armed", so the Haskell side renders `hidden=True`
// before AND after any of this file's own re-renders, and the diff never
// revisits it. This toggle is the one and only thing that ever changes
// it.
document.addEventListener("click", (event) => {
  const id = event.target && event.target.id;
  if (id === "btn-progress-wipe") {
    const confirmBtn = document.getElementById("btn-progress-wipe-confirm");
    event.target.hidden = true;
    if (confirmBtn) confirmBtn.hidden = false;
  } else if (id === "btn-progress-wipe-confirm") {
    event.target.hidden = true;
    const wipeBtn = document.getElementById("btn-progress-wipe");
    if (wipeBtn) wipeBtn.hidden = false;
  } else if (id === "btn-content-retry" || id === "btn-lang-resync") {
    // M6 W1: the degraded-content retry affordance. A full reload IS the
    // retry -- it re-runs this file's guarded bundle load and the app's
    // boot-time read of it, with no separate re-fetch path to keep in
    // sync (re-fetch-on-language-switch is W2's seam).
    //
    // M6 gate round 1 (finding M6-R1-4): #btn-lang-resync -- inside the
    // visible #sxc1-lang-split banner -- takes the same path. The app
    // re-syncs the boot hint from the decoded pref at every boot, so
    // once a hint write succeeds again this reload fetches the bundle
    // the UI language actually calls for. It is LEARNER-INITIATED and
    // therefore cannot loop, which is why no automatic corrective
    // reload exists on the boot path (see Main.main).
    window.location.reload();
  }
});

// Import preview: counts "R<TAB>" records (SXC1.Progress.Codec's wire
// format -- one such line per saved spaced-repetition record) in the
// pasted text BEFORE the learner submits the import form, so they see
// what they are about to commit first. Two shapes are accepted, matching
// SXC1.Progress.Codec.importBlob exactly: a bare wire blob (real tab/
// newline bytes), or the JSON export envelope (the same wire text
// escaped as \t/\n inside one "payload" string -- extracted the same way
// SXC1.Progress.Codec.extractJsonStringField does, without a JSON
// parser: read up to the next unescaped quote). Advisory only -- the
// commit itself always re-decodes for real.
function countPastedRecords(text) {
  const bareLines = text.split("\n").filter((line) => line.startsWith("R\t")).length;
  if (bareLines > 0 || text.trim().startsWith("SXC1PROGRESS")) return bareLines;
  const match = text.match(/"payload":"((?:[^"\\]|\\.)*)"/);
  if (!match) return 0;
  return match[1].split("\\n").filter((line) => line.startsWith("R\\t")).length;
}

document.addEventListener("input", (event) => {
  if (!event.target || event.target.id !== "sxc1-import-input") return;
  const preview = document.getElementById("sxc1-import-preview");
  if (!preview) return;
  const n = countPastedRecords(event.target.value);
  // M6 W2: this file owns exactly these two learner-visible strings (the
  // live preview overwrites the Haskell-rendered placeholder), so they
  // localize HERE, keyed off the same boot hint the bundle fetch uses --
  // the wasm-side I18n table cannot reach into this JS-only path.
  preview.textContent = sxc1UiLang === "ja"
    ? `貼り付けたテキストに${n}件のレコードが見つかりました。`
    : n === 1 ? "1 record found in the pasted text." : `${n} records found in the pasted text.`;
});

// M9 progress passport. The Haskell codec remains the only authority: these
// controls only move the already-generated export envelope into or out of a
// local file. File imports populate the existing textarea, show the existing
// preview, and still require the learner to press Import, which sends the text
// through SXC1.Progress.Codec.importBlob before anything is committed.
const PORTABILITY_STRINGS = {
  en: {
    backupHint: "Export first, then save the backup file or share it to another device.",
    download: "Save backup file",
    share: "Share backup",
    importFile: "Choose a SEXY ONE backup file:",
    downloaded: "Backup saved. Keep it somewhere you control.",
    shared: "Backup shared.",
    loaded: "Backup file loaded. Review the record count, then choose Import.",
    tooLarge: "That file is too large to be a SEXY ONE backup.",
    readFailed: "The backup file could not be read.",
    shareFailed: "The backup could not be shared. Save the file instead.",
    title: "SEXY ONE progress backup",
    shareText: "My local SEXY ONE training progress backup.",
  },
  ja: {
    backupHint: "最初にエクスポートしてから、バックアップファイルを保存するか、別の端末へ共有してください。",
    download: "バックアップを保存",
    share: "バックアップを共有",
    importFile: "SEXY ONEのバックアップファイルを選択:",
    downloaded: "バックアップを保存しました。安全な場所に保管してください。",
    shared: "バックアップを共有しました。",
    loaded: "バックアップを読み込みました。件数を確認してから「インポート」を選択してください。",
    tooLarge: "このファイルはSEXY ONEのバックアップとして大きすぎます。",
    readFailed: "バックアップファイルを読み込めませんでした。",
    shareFailed: "バックアップを共有できませんでした。代わりにファイルを保存してください。",
    title: "SEXY ONE 進捗バックアップ",
    shareText: "SEXY ONEのローカル進捗バックアップです。",
  },
};
const portabilityStrings = PORTABILITY_STRINGS[sxc1UiLang] || PORTABILITY_STRINGS.en;
const MAX_PROGRESS_FILE_BYTES = 1024 * 1024;

function progressExportValue() {
  return document.getElementById("sxc1-export-blob")?.value?.trim() || "";
}

function progressBackupFile(value) {
  const day = new Date().toISOString().slice(0, 10);
  // `File` is also the name of the WASI shim class imported at the top of
  // this module. The progress passport needs the browser-native constructor.
  return new window.File([value], `sexy-one-progress-${day}.sxc1`, { type: "application/json" });
}

function setBackupStatus(message) {
  const status = document.getElementById("sxc1-backup-status");
  if (status) status.textContent = message || "";
}

function scanForProgressPortability() {
  const root = document.getElementById("sxc1-progress-passport");
  if (root && !root.querySelector("#btn-progress-download")) {
    const hint = document.createElement("p");
    hint.className = "progress-backup-hint";
    hint.textContent = portabilityStrings.backupHint;
    const actions = document.createElement("div");
    actions.className = "progress-file-actions";
    const downloadButton = document.createElement("button");
    downloadButton.id = "btn-progress-download";
    downloadButton.type = "button";
    downloadButton.disabled = true;
    downloadButton.textContent = portabilityStrings.download;
    const shareButton = document.createElement("button");
    shareButton.id = "btn-progress-share";
    shareButton.type = "button";
    shareButton.disabled = true;
    shareButton.hidden = true;
    shareButton.textContent = portabilityStrings.share;
    actions.append(downloadButton, shareButton);
    const status = document.createElement("p");
    status.id = "sxc1-backup-status";
    status.setAttribute("aria-live", "polite");
    root.replaceChildren(hint, actions, status);
  }
  const fileRoot = document.getElementById("sxc1-import-file-shell");
  if (fileRoot && !fileRoot.querySelector("#sxc1-import-file")) {
    const fileLabel = document.createElement("label");
    fileLabel.htmlFor = "sxc1-import-file";
    fileLabel.textContent = portabilityStrings.importFile;
    const fileInput = document.createElement("input");
    fileInput.id = "sxc1-import-file";
    fileInput.type = "file";
    fileInput.accept = ".sxc1,.json,.txt,application/json,text/plain";
    fileRoot.replaceChildren(fileLabel, fileInput);
  }
  const value = progressExportValue();
  const exportButton = document.getElementById("btn-progress-export");
  const download = document.getElementById("btn-progress-download");
  const share = document.getElementById("btn-progress-share");
  if (download) {
    download.hidden = !value;
    download.disabled = !value;
  }
  if (exportButton) exportButton.hidden = Boolean(value);
  let shareSupported = false;
  if (value && typeof window.File === "function" && typeof navigator.share === "function") {
    try {
      const file = progressBackupFile(value);
      shareSupported = typeof navigator.canShare !== "function" || navigator.canShare({ files: [file] });
    } catch (_) { shareSupported = false; }
  }
  if (share) {
    share.hidden = !shareSupported;
    share.disabled = !value || !shareSupported;
  }
  window.__SXC1_PROGRESS_PORTABILITY = {
    ready: Boolean(value),
    download: Boolean(download),
    share: shareSupported,
    fileImport: Boolean(document.getElementById("sxc1-import-file")),
    maxFileBytes: MAX_PROGRESS_FILE_BYTES,
  };
}

function downloadProgressBackup() {
  const value = progressExportValue();
  if (!value || typeof window.File !== "function") return;
  const file = progressBackupFile(value);
  const href = URL.createObjectURL(file);
  const anchor = document.createElement("a");
  anchor.href = href;
  anchor.download = file.name;
  anchor.hidden = true;
  document.body.append(anchor);
  anchor.click();
  anchor.remove();
  setTimeout(() => URL.revokeObjectURL(href), 0);
  setBackupStatus(portabilityStrings.downloaded);
}

async function shareProgressBackup() {
  const value = progressExportValue();
  if (!value) return;
  try {
    const file = progressBackupFile(value);
    await navigator.share({ files: [file], title: portabilityStrings.title, text: portabilityStrings.shareText });
    setBackupStatus(portabilityStrings.shared);
  } catch (err) {
    if (err && err.name === "AbortError") return;
    setBackupStatus(portabilityStrings.shareFailed);
  }
}

function readProgressFile(file) {
  if (file && typeof file.text === "function") return file.text();
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.addEventListener("load", () => resolve(String(reader.result || "")));
    reader.addEventListener("error", () => reject(reader.error || new Error("read failed")));
    reader.readAsText(file);
  });
}

document.addEventListener("click", (event) => {
  const id = event.target && event.target.id;
  if (id === "btn-progress-export") {
    [0, 40, 120, 300, 700].forEach((delay) => setTimeout(scanForProgressPortability, delay));
  } else if (id === "btn-progress-download") {
    downloadProgressBackup();
  } else if (id === "btn-progress-share") {
    shareProgressBackup();
  }
});

document.addEventListener("change", async (event) => {
  if (!event.target || event.target.id !== "sxc1-import-file") return;
  const file = event.target.files && event.target.files[0];
  if (!file) return;
  if (file.size > MAX_PROGRESS_FILE_BYTES) {
    setBackupStatus(portabilityStrings.tooLarge);
    event.target.value = "";
    return;
  }
  try {
    const value = await readProgressFile(file);
    const input = document.getElementById("sxc1-import-input");
    if (!input) return;
    input.value = value;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    setBackupStatus(portabilityStrings.loaded);
  } catch (_) {
    setBackupStatus(portabilityStrings.readFailed);
  }
});

scanForProgressPortability();

// Mastery journey: a deliberately small, DOM-only progress surface. The pure
// SXC1.Mastery module remains the executable specification; this projection
// turns the same completion, recall, due-date, and prerequisite evidence into
// an actionable queue and one progressively disclosed chapter trail. There is
// no canvas, GPU context, camera, animation loop, or graph-layout dependency.
(() => {
  const makeEl = (tag, className, value) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (value !== undefined && value !== null) element.textContent = value;
    return element;
  };

  // This JS-owned surface follows the same narrow localization exception as
  // the import preview above: the shell creates these nodes, so the complete
  // locale records live alongside their behavior.
  const MASTERY_STRINGS = {
    en: {
      kicker: "Training",
      title: "Mastery journey",
      intro: "A focused route through what to review, continue, and learn next. Prerequisites shape the guidance, but never lock a lesson.",
      summary: "{strong} of {total} skills are strong",
      evidence: "{done}/{exercises} exercises · {durable}/{prompts} durable · {due} due",
      nextTitle: "Your next moves",
      nextHint: "Review comes first, then the strongest continuation of your course.",
      routeTitle: "Course route",
      routeHint: "Choose a chapter to inspect its skill trail.",
      complete: "{done} of {total} exercises complete",
      recommended: "Recommended next",
      open: "Open deck",
      review: "Review {due} due prompt",
      reviewMany: "Review {due} due prompts",
      continue: "Continue this skill",
      begin: "Build the next foundation",
      maintain: "Keep this skill strong",
      follows: "Builds on {titles}",
      foundation: "Foundation skill",
      prereqsMet: "Suggested foundations complete",
      prereqsOpen: "Suggested foundations remain — you can still begin",
      fullList: "Browse every skill",
      weekly: "Open weekly pulse",
      bands: { unseen: "Unseen", learning: "Learning", practiced: "Practiced", consolidating: "Review due", strong: "Strong" },
    },
    ja: {
      kicker: "トレーニング",
      title: "習熟の道筋",
      intro: "復習・継続・次の学習を、迷わず選べる道筋です。前提スキルは案内に使いますが、レッスンを制限しません。",
      summary: "{total}スキル中{strong}件が定着",
      evidence: "演習 {done}/{exercises}・記憶 {durable}/{prompts} 定着・復習 {due}件",
      nextTitle: "次にやること",
      nextHint: "復習を優先し、その後にコースを最も自然に進めます。",
      routeTitle: "コースの道筋",
      routeHint: "章を選ぶと、スキルの流れを確認できます。",
      complete: "演習 {total}件中{done}件完了",
      recommended: "次のおすすめ",
      open: "デッキを開く",
      review: "期限の来た問題を{due}件復習",
      reviewMany: "期限の来た問題を{due}件復習",
      continue: "このスキルを続ける",
      begin: "次の基礎を身につける",
      maintain: "定着を維持する",
      follows: "{titles}の上に積み上げます",
      foundation: "基礎スキル",
      prereqsMet: "推奨の基礎は完了済み",
      prereqsOpen: "推奨の基礎が未完了です（今すぐ開始できます）",
      fullList: "全スキルを表示",
      weekly: "週間パルスを開く",
      bands: { unseen: "未学習", learning: "学習中", practiced: "練習済み", consolidating: "復習時期", strong: "定着" },
    },
  };

  const fill = (template, values) => Object.entries(values)
    .reduce((text, [key, value]) => text.split(`{${key}}`).join(String(value)), template || "");

  // Parse only stable structural lines from the already validated course
  // bundle. The full exercise grammar and its integrity checks remain
  // Haskell-owned.
  function courseFromBundle(text) {
    if (typeof text !== "string") return [];
    const chunks = text.split(/^!SXC1-DECK [^\n]*\n/gm).slice(1);
    return chunks.map((chunk) => {
      const lines = chunk.split("\n");
      const valueOf = (prefix) => {
        const line = lines.find((candidate) => candidate.startsWith(prefix));
        return line ? line.slice(prefix.length).trim() : "";
      };
      const exercises = [];
      let current = null;
      const finishExercise = () => {
        if (!current || !current.id) return;
        const count = current.type === "drill" ? Math.max(1, current.steps) : 1;
        current.prompts = Array.from({ length: count }, (_, index) => `${current.id}#${index + 1}`);
        exercises.push(current);
      };
      for (const line of lines) {
        if (/^## [^#]/.test(line)) {
          finishExercise();
          current = { id: "", title: line.slice(3).trim(), type: "", steps: 0, prompts: [] };
        } else if (current && line.startsWith("type: ")) {
          current.type = line.slice(6).trim();
        } else if (current && line.startsWith("id: ")) {
          current.id = line.slice(4).trim();
        } else if (current && /^### Step(?:\s|$)/.test(line)) {
          current.steps += 1;
        }
      }
      finishExercise();
      const requiresText = valueOf("requires:");
      return {
        id: valueOf("deck:"),
        title: valueOf("# "),
        chapter: valueOf("chapter:"),
        requires: requiresText ? requiresText.split(",").map((value) => value.trim()).filter(Boolean) : [],
        exercises,
      };
    }).filter((deck) => deck.id);
  }

  function masteryProjection(strings) {
    let bundle;
    try { bundle = window.__sxc1Content && window.__sxc1Content.text(); }
    catch (_) { return null; }
    const decks = courseFromBundle(bundle);
    const progressElement = document.getElementById("sxc1-progress");
    let progress;
    try { progress = JSON.parse(progressElement ? progressElement.textContent : ""); }
    catch (_) { return null; }
    if (!decks.length || !progress) return null;

    const today = Number(progress.masteryToday) || 0;
    const recs = new Map((progress.masteryRecs || []).map((rec) => [rec[0], {
      reps: Number(rec[1]) || 0,
      interval: Number(rec[2]) || 0,
      due: Number(rec[3]) || 0,
    }]));
    const done = new Set(progress.masteryDone || []);
    const deckById = new Map(decks.map((deck) => [deck.id, deck]));
    const chapters = [...new Set(decks.map((deck) => deck.chapter))];

    const nodes = decks.map((deck, courseIndex) => {
      const prompts = deck.exercises.flatMap((exercise) => exercise.prompts);
      const doneCount = deck.exercises.filter((exercise) => done.has(exercise.id)).length;
      let durable = 0;
      let due = 0;
      for (const prompt of prompts) {
        const rec = recs.get(prompt);
        if (!rec) continue;
        if (rec.reps > 1 && rec.interval >= 5) durable += 1;
        if (rec.due <= today) due += 1;
      }
      const complete = deck.exercises.length > 0 && doneCount >= deck.exercises.length;
      const allDurable = prompts.length > 0 && durable === prompts.length;
      const anyEvidence = doneCount > 0 || prompts.some((prompt) => recs.has(prompt));
      const band = !anyEvidence ? "unseen"
        : !complete ? "learning"
        : !allDurable ? "practiced"
        : due > 0 ? "consolidating" : "strong";
      const prereqsMet = deck.requires.every((requiredId) => {
        const required = deckById.get(requiredId);
        return Boolean(required && required.exercises.every((exercise) => done.has(exercise.id)));
      });
      return {
        id: deck.id,
        title: deck.title,
        chapter: deck.chapter,
        requires: deck.requires,
        exercises: deck.exercises.length,
        done: doneCount,
        prompts: prompts.length,
        durable,
        due,
        band,
        bandLabel: strings.bands[band],
        prereqsMet,
        courseIndex,
      };
    });
    const nodeById = new Map(nodes.map((node) => [node.id, node]));
    const recommended = nodes.find((node) => node.due > 0)
      || nodes.find((node) => node.done < node.exercises)
      || null;
    if (recommended) recommended.recommended = true;

    for (const node of nodes) {
      node.evidence = fill(strings.evidence, node);
      node.prereqStatus = node.prereqsMet ? strings.prereqsMet : strings.prereqsOpen;
      const titles = node.requires.map((id) => nodeById.get(id)?.title || id).join(", ");
      node.dependency = titles ? fill(strings.follows, { titles }) : strings.foundation;
    }

    const counts = new Map(["unseen", "learning", "practiced", "consolidating", "strong"].map((key) => [key, 0]));
    nodes.forEach((node) => counts.set(node.band, (counts.get(node.band) || 0) + 1));

    // The action queue is the graph's useful decision: due work first,
    // followed by incomplete work whose suggested foundations are ready,
    // then the remaining course order. Keep it short enough to scan.
    const queue = [];
    const add = (candidates) => {
      for (const node of candidates) {
        if (queue.length >= 3) break;
        if (!queue.includes(node)) queue.push(node);
      }
    };
    add(recommended ? [recommended] : []);
    add(nodes.filter((node) => node.due > 0).sort((a, b) => b.due - a.due || a.courseIndex - b.courseIndex));
    add(nodes.filter((node) => node.band !== "strong" && node.prereqsMet));
    add(nodes.filter((node) => node.band !== "strong"));
    add(nodes);

    const chapterData = chapters.map((title) => {
      const chapterNodes = nodes.filter((node) => node.chapter === title);
      const doneExercises = chapterNodes.reduce((sum, node) => sum + node.done, 0);
      const exercises = chapterNodes.reduce((sum, node) => sum + node.exercises, 0);
      return {
        title,
        nodes: chapterNodes,
        done: doneExercises,
        total: exercises,
        strong: chapterNodes.filter((node) => node.band === "strong").length,
      };
    });
    return {
      nodes,
      queue,
      chapters: chapterData,
      edgeCount: decks.reduce((sum, deck) => sum + deck.requires.filter((id) => deckById.has(id)).length, 0),
      legend: [...counts].map(([key, count]) => [key, strings.bands[key], count]),
      summary: fill(strings.summary, { strong: counts.get("strong") || 0, total: nodes.length }),
      recommended,
    };
  }

  function reasonFor(node, strings) {
    if (node.due === 1) return fill(strings.review, { due: node.due });
    if (node.due > 1) return fill(strings.reviewMany, { due: node.due });
    if (node.band === "learning" || node.band === "practiced") return strings.continue;
    if (node.band === "strong") return strings.maintain;
    return strings.begin;
  }

  function deckLink(node, strings, className) {
    const link = makeEl("a", className);
    link.href = `#/x/${node.id}`;
    link.dataset.deck = node.id;
    link.dataset.band = node.band;
    link.dataset.recommended = String(node.recommended === true);
    link.setAttribute("aria-label", `${node.title}. ${node.bandLabel}. ${node.evidence}`);
    const copy = makeEl("span", "mastery-deck-copy");
    copy.append(
      makeEl("strong", "mastery-deck-title", node.title),
      makeEl("span", "mastery-deck-evidence", node.evidence),
    );
    const status = makeEl("span", `mastery-band mastery-band-${node.band}`, node.bandLabel);
    link.append(copy, status);
    return link;
  }

  function hydrateMasteryJourney(root) {
    if (!root || (root.dataset.masteryHydrated === "true" && root.querySelector("#mastery-next"))) return;
    const strings = MASTERY_STRINGS[root.dataset.lang === "ja" ? "ja" : "en"];
    const model = masteryProjection(strings);
    if (!model) return;
    root.dataset.masteryHydrated = "true";

    const hero = makeEl("header", "mastery-hero");
    hero.append(
      makeEl("p", "mastery-kicker", strings.kicker),
      makeEl("h1", "", strings.title),
      makeEl("p", "mastery-intro", strings.intro),
    );
    const progressCard = makeEl("div", "mastery-summary");
    progressCard.append(makeEl("strong", "", model.summary));
    const strongCount = model.nodes.filter((node) => node.band === "strong").length;
    const overall = makeEl("progress", "mastery-overall-progress");
    overall.max = model.nodes.length;
    overall.value = strongCount;
    overall.setAttribute("aria-label", model.summary);
    const weeklyLink = makeEl("a", "mastery-weekly-link", strings.weekly);
    weeklyLink.href = "#/x/week";
    progressCard.append(overall, weeklyLink);
    hero.append(progressCard);

    const legend = makeEl("ul", "mastery-legend");
    legend.setAttribute("aria-label", strings.title);
    for (const [key, label, count] of model.legend) {
      const item = makeEl("li", `mastery-legend-${key}`);
      item.append(makeEl("span", "mastery-legend-count", String(count)), makeEl("span", "", label));
      legend.append(item);
    }
    hero.append(legend);

    const next = makeEl("section", "mastery-next");
    next.id = "mastery-next";
    const nextHeader = makeEl("header", "mastery-section-heading");
    nextHeader.append(makeEl("h2", "", strings.nextTitle), makeEl("p", "", strings.nextHint));
    const queue = makeEl("ol", "mastery-queue");
    for (const [index, node] of model.queue.entries()) {
      const item = makeEl("li", index === 0 ? "is-primary" : "");
      const reason = makeEl("span", "mastery-queue-reason",
        `${index === 0 ? `${strings.recommended} · ` : ""}${reasonFor(node, strings)}`);
      const link = deckLink(node, strings, "mastery-queue-card");
      link.prepend(reason);
      item.append(link);
      queue.append(item);
    }
    next.append(nextHeader, queue);

    const route = makeEl("section", "mastery-route");
    route.id = "mastery-route";
    const routeHeader = makeEl("header", "mastery-section-heading");
    routeHeader.append(makeEl("h2", "", strings.routeTitle), makeEl("p", "", strings.routeHint));
    const tabs = makeEl("div", "mastery-chapter-tabs");
    tabs.setAttribute("role", "tablist");
    tabs.setAttribute("aria-label", strings.routeTitle);
    const panel = makeEl("div", "mastery-chapter-panel");
    panel.id = "mastery-chapter-panel";
    panel.setAttribute("role", "tabpanel");

    let selectedChapter = Math.max(0, model.chapters.findIndex((chapter) =>
      chapter.nodes.some((node) => node.recommended)));
    const renderChapter = () => {
      const chapter = model.chapters[selectedChapter] || model.chapters[0];
      if (!chapter) return;
      const heading = makeEl("header", "mastery-chapter-heading");
      heading.append(
        makeEl("h3", "", chapter.title),
        makeEl("p", "", fill(strings.complete, { done: chapter.done, total: chapter.total })),
      );
      const progress = makeEl("progress", "mastery-chapter-progress");
      progress.max = Math.max(1, chapter.total);
      progress.value = chapter.done;
      progress.setAttribute("aria-label", fill(strings.complete, { done: chapter.done, total: chapter.total }));
      heading.append(progress);
      const trail = makeEl("ol", "mastery-trail");
      for (const node of chapter.nodes) {
        const item = makeEl("li", `mastery-trail-item mastery-trail-${node.band}${node.recommended ? " is-recommended" : ""}`);
        const link = deckLink(node, strings, "mastery-trail-link");
        const context = makeEl("p", "mastery-trail-context", `${node.dependency} · ${node.prereqStatus}`);
        item.append(link, context);
        trail.append(item);
      }
      panel.setAttribute("aria-labelledby", `mastery-chapter-tab-${selectedChapter}`);
      panel.replaceChildren(heading, trail);
      tabs.querySelectorAll("[role=tab]").forEach((tab, index) => {
        tab.setAttribute("aria-selected", String(index === selectedChapter));
        tab.tabIndex = index === selectedChapter ? 0 : -1;
      });
      publish();
    };

    model.chapters.forEach((chapter, index) => {
      const tab = makeEl("button", "mastery-chapter-tab");
      tab.id = `mastery-chapter-tab-${index}`;
      tab.type = "button";
      tab.setAttribute("role", "tab");
      tab.setAttribute("aria-controls", panel.id);
      tab.append(
        makeEl("strong", "", chapter.title),
        makeEl("span", "", fill(strings.complete, { done: chapter.done, total: chapter.total })),
      );
      tab.addEventListener("click", () => {
        selectedChapter = index;
        renderChapter();
      });
      tab.addEventListener("keydown", (event) => {
        if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
        const direction = event.key === "ArrowRight" ? 1 : -1;
        selectedChapter = (selectedChapter + direction + model.chapters.length) % model.chapters.length;
        renderChapter();
        tabs.querySelectorAll("[role=tab]")[selectedChapter]?.focus();
        event.preventDefault();
      });
      tabs.append(tab);
    });
    route.append(routeHeader, tabs, panel);

    const fullList = makeEl("details", "mastery-full-list");
    fullList.id = "mastery-full-list";
    fullList.append(makeEl("summary", "", strings.fullList));
    const list = makeEl("ul", "");
    for (const node of model.nodes) {
      const item = makeEl("li", "");
      const link = makeEl("a", "", node.title);
      link.href = `#/x/${node.id}`;
      link.dataset.deck = node.id;
      link.setAttribute("aria-label", `${node.title}. ${node.bandLabel}`);
      const band = makeEl("span", `mastery-band mastery-band-${node.band}`, node.bandLabel);
      item.append(link, band);
      list.append(item);
    }
    fullList.append(list);

    root.replaceChildren(hero, next, route, fullList);

    function publish() {
      const state = {
        mounted: true,
        renderer: "dom",
        nodeCount: model.nodes.length,
        edgeCount: model.edgeCount,
        chapterCount: model.chapters.length,
        queueCount: model.queue.length,
        renderedDeckCount: panel.querySelectorAll(".mastery-trail-link").length,
        selectedChapter,
        recommended: model.recommended?.id || null,
      };
      window.__sxc1MasteryJourney = state;
      // Keep one release of diagnostic compatibility for field reports while
      // making the retired renderer unambiguous.
      window.__sxc1MasteryMap = { ...state, webgl: false, retired: true };
    }

    renderChapter();
  }

  function scanForMasteryJourney() {
    hydrateMasteryJourney(document.getElementById("sxc1-mastery"));
  }

  // M17 One Practice Home. Course progress remains owned by the Haskell
  // progress passport; these small, privacy-light events are the bridge from
  // Sample Lab into Today's Session and Weekly Pulse. The ledger deliberately
  // stores no filenames or sample names, is independently recoverable, and is
  // bounded to the same 200-event horizon as the learning history.
  const PRACTICE_KEY = "sxc1.practice-loop.v1";
  const PRACTICE_CAP = 200;
  let memoryPracticeLedger = { schema: 1, nextSeq: 1, events: [] };

  function positivePracticeInt(value, max) {
    const number = Number(value);
    return Number.isSafeInteger(number) && number > 0 && number <= max ? number : 0;
  }

  function normalizedPracticeLedger(raw) {
    const events = [];
    const sequences = new Set();
    if (raw && typeof raw === "object" && Array.isArray(raw.events)) {
      raw.events.forEach((candidate) => {
        if (!candidate || typeof candidate !== "object") return;
        const seq = positivePracticeInt(candidate.seq, Number.MAX_SAFE_INTEGER - 1);
        const day = positivePracticeInt(candidate.day, 100000000);
        const kind = String(candidate.kind || "").slice(0, 32);
        if (!seq || !day || sequences.has(seq)
          || !["sample-placed", "sound-ready", "pad-loaded", "pad-played"].includes(kind)) return;
        sequences.add(seq);
        events.push({
          seq, day, kind,
          projectId: String(candidate.projectId || "").slice(0, 180),
          ref: String(candidate.ref || "").slice(0, 320),
        });
        events.sort((a, b) => a.seq - b.seq);
        if (events.length > PRACTICE_CAP) {
          const dropped = events.shift();
          sequences.delete(dropped.seq);
        }
      });
    }
    const lastSeq = events.at(-1)?.seq || 0;
    const storedNext = positivePracticeInt(raw?.nextSeq, Number.MAX_SAFE_INTEGER) || 1;
    return {
      schema: 1,
      nextSeq: Math.max(lastSeq + 1, storedNext),
      events: events.slice(-PRACTICE_CAP),
    };
  }

  function readPracticeLedger() {
    try {
      const raw = window.localStorage.getItem(PRACTICE_KEY);
      memoryPracticeLedger = normalizedPracticeLedger(raw ? JSON.parse(raw) : null);
    } catch (_) { memoryPracticeLedger = normalizedPracticeLedger(memoryPracticeLedger); }
    return memoryPracticeLedger;
  }

  function writePracticeLedger(ledger) {
    memoryPracticeLedger = normalizedPracticeLedger(ledger);
    try { window.localStorage.setItem(PRACTICE_KEY, JSON.stringify(memoryPracticeLedger)); }
    catch (_) { /* the current page still sees the event */ }
    return memoryPracticeLedger;
  }

  function practiceEventMatches(item, event) {
    return item?.type === "lab"
      && Array.isArray(item.eventKinds) && item.eventKinds.includes(event.kind)
      && (!item.projectId || item.projectId === event.projectId)
      && (item.matchProject === true || !item.ref || item.ref === event.ref)
      && event.seq > (Number(item.afterSeq) || 0);
  }

  function recordPracticeEvent(kind, detail = {}) {
    if (!["sample-placed", "sound-ready", "pad-loaded", "pad-played"].includes(kind)) return null;
    const ledger = readPracticeLedger();
    const event = {
      seq: ledger.nextSeq,
      day: Math.floor(Date.now() / 86400000),
      kind,
      projectId: String(detail.projectId || "").slice(0, 180),
      ref: String(detail.ref || "").slice(0, 320),
    };
    ledger.nextSeq += 1;
    ledger.events.push(event);
    if (ledger.events.length > PRACTICE_CAP) ledger.events.splice(0, ledger.events.length - PRACTICE_CAP);
    writePracticeLedger(ledger);
    window.dispatchEvent(new CustomEvent("sxc1:practice", { detail: event }));

    // A completed Lab outcome is already the learner's decision. When that
    // outcome belongs to today's plan, mark it and continue to the next item
    // instead of asking for a redundant confirmation screen.
    const plan = readSession();
    if (plan?.day !== event.day) return event;
    const item = plan?.items?.find((candidate) => practiceEventMatches(candidate, event));
    if (item) {
      const completed = new Set(Array.isArray(plan.completed) ? plan.completed : []);
      completed.add(item.id);
      writeSession({ ...plan, completed: plan.items.filter((candidate) => completed.has(candidate.id)).map((candidate) => candidate.id) });
      const handled = new Set([...completed, ...(Array.isArray(plan.skipped) ? plan.skipped : [])]);
      const index = plan.items.findIndex((candidate) => candidate.id === item.id);
      const next = plan.items.slice(index + 1).find((candidate) => !handled.has(candidate.id))
        || plan.items.find((candidate) => !handled.has(candidate.id));
      if (window.location.hash.startsWith("#/samples")) {
        window.setTimeout(() => { window.location.hash = next?.href || "#/x/today"; }, 240);
      }
    }
    return event;
  }

  function skipCurrentLabTask(targetId) {
    const plan = readSession();
    if (!plan?.items || plan.day !== Math.floor(Date.now() / 86400000)) return false;
    const completed = new Set(Array.isArray(plan.completed) ? plan.completed : []);
    const skipped = new Set(Array.isArray(plan.skipped) ? plan.skipped : []);
    const item = plan.items.find((candidate) => candidate.id === targetId && candidate.type === "lab"
      && !completed.has(candidate.id) && !skipped.has(candidate.id));
    if (!item) return false;
    skipped.add(item.id);
    const updated = { ...plan, skipped: plan.items.filter((candidate) => skipped.has(candidate.id)).map((candidate) => candidate.id) };
    writeSession(updated);
    const handled = new Set([...completed, ...skipped]);
    const index = plan.items.findIndex((candidate) => candidate.id === item.id);
    const next = plan.items.slice(index + 1).find((candidate) => !handled.has(candidate.id))
      || plan.items.find((candidate) => !handled.has(candidate.id));
    window.location.hash = next?.href || "#/x/today";
    return true;
  }

  function readJsonStorage(key) {
    try {
      const raw = window.localStorage.getItem(key);
      return raw ? JSON.parse(raw) : null;
    } catch (_) { return null; }
  }

  function practiceLabTask(lang = "en") {
    const workspace = readJsonStorage("sxc1.sample-workspace.v1");
    const library = readJsonStorage("sxc1.sample-library.v1");
    const handoffs = readJsonStorage("sxc1.sample-handoffs.v1");
    const projects = Array.isArray(workspace?.projects) ? workspace.projects : [];
    const project = projects.find((candidate) => candidate?.id === workspace?.activeProjectId) || projects[0];
    if (!project?.id) return null;
    const ledger = readPracticeLedger();
    const base = {
      type: "lab", deckId: "sample-lab", deckTitle: "Sample Lab", projectId: String(project.id).slice(0, 180),
      reason: "prepare", minutes: 2, afterSeq: ledger.nextSeq - 1,
    };
    const session = (Array.isArray(handoffs?.sessions) ? handoffs.sessions : [])
      .find((candidate) => candidate?.projectId === project.id);
    const pending = Array.isArray(session?.entries)
      ? session.entries.find((entry) => entry && ["pending", "shared"].includes(entry.status))
      : null;
    if (pending) return {
      ...base, id: `lab:load:${project.id}`, ref: String(pending.key || "").slice(0, 320), matchProject: true,
      eventKinds: ["pad-loaded"], href: `#/samples?practice=handoff&project=${encodeURIComponent(project.id)}`,
      title: lang === "ja" ? "次のパッドを読み込む" : "Load the next pad",
    };

    const assigned = Object.entries(project.slots || {}).flatMap(([slot, bank]) =>
      Object.entries(bank?.pads || {}).map(([pad, data]) => ({ slot, bank: bank.bank, pad: Number(pad), blobId: data?.blobId })));
    const projectBlobIds = new Set([
      ...(Array.isArray(project.inbox) ? project.inbox : []),
      ...Object.values(project.slots || {}).flatMap((slot) => Object.values(slot?.pads || {})),
    ].map((item) => item?.blobId).filter(Boolean));
    const assets = Array.isArray(library?.items) ? library.items : [];
    const relevant = assets.filter((asset) => projectBlobIds.has(asset?.blobId));
    const candidates = relevant.length ? relevant : assets;
    const needsWork = candidates.find((asset) => asset?.readiness && asset.readiness.ready !== true);
    const unchecked = candidates.find((asset) => !asset?.readiness?.checkedAt);
    const sound = needsWork || unchecked;
    if (sound?.id) return {
      ...base, id: `lab:check:${sound.id}`, ref: String(sound.id).slice(0, 180),
      eventKinds: ["sound-ready"], href: `#/samples?practice=check&project=${encodeURIComponent(project.id)}&asset=${encodeURIComponent(sound.id)}`,
      title: lang === "ja"
        ? (needsWork ? "音を1つ仕上げる" : "音を1つチェックする")
        : (needsWork ? "Prepare one sound" : "Check one sound"),
    };
    if (Array.isArray(project.inbox) && project.inbox.length) return {
      ...base, id: `lab:place:${project.id}`, ref: "", matchProject: true,
      eventKinds: ["sample-placed"], href: `#/samples?practice=organize&project=${encodeURIComponent(project.id)}`,
      title: lang === "ja" ? "受信箱の音を1つ配置する" : "Place one inbox sound",
    };
    if (assigned.length) {
      const receipts = new Map((session?.entries || []).map((entry) =>
        [`${entry.slot}:${entry.bank}:${entry.pad}:${entry.blobId}`, entry.status]));
      const unloaded = assigned.some((row) =>
        receipts.get(`${row.slot}:${row.bank}:${row.pad}:${row.blobId}`) !== "loaded");
      if (unloaded) return {
        ...base, id: `lab:load:${project.id}`, ref: "", matchProject: true,
        eventKinds: ["pad-loaded"], href: `#/samples?practice=handoff&project=${encodeURIComponent(project.id)}`,
        title: lang === "ja" ? "パッドを1つ読み込む" : "Load one pad",
      };
      const banks = [...new Map(assigned.map((row) => [`${row.slot}:${row.bank}`, row])).values()];
      const lastPlayed = new Map();
      ledger.events.forEach((event) => {
        if (event.kind === "pad-played" && event.projectId === project.id) {
          lastPlayed.set(event.ref, Math.max(lastPlayed.get(event.ref) || 0, event.day));
        }
      });
      banks.sort((a, b) => (lastPlayed.get(`${a.slot}:${a.bank}`) || 0)
        - (lastPlayed.get(`${b.slot}:${b.bank}`) || 0) || a.slot.localeCompare(b.slot));
      const bank = banks[0];
      const ref = `${bank.slot}:${bank.bank}`;
      return {
        ...base, id: `lab:practice:${project.id}:${ref}`, ref,
        eventKinds: ["pad-played"],
        href: `#/samples?practice=pads&project=${encodeURIComponent(project.id)}&slot=${bank.slot}&bank=${bank.bank}&today=1`,
        title: lang === "ja" ? `BANK ${bank.bank}を練習` : `Practice Bank ${bank.bank}`,
      };
    }
    return null;
  }

  window.__SXC1_PRACTICE_LOOP = {
    schema: 1,
    cap: PRACTICE_CAP,
    read: () => readPracticeLedger(),
    record: recordPracticeEvent,
    task: (lang) => practiceLabTask(lang === "ja" ? "ja" : "en"),
    skip: skipCurrentLabTask,
  };

  // M10/M17 Weekly Pulse. This is a projection over the versioned, bounded
  // progress ledger and review schedule. It is all ordinary DOM/CSS: no
  // canvas, animation loop, analytics endpoint, or background work.
  const WEEKLY_STRINGS = {
    en: {
      kicker: "Reflection",
      title: "Weekly pulse",
      intro: "A calm view of your recent learning, Sample Lab outcomes, review load, and next focus.",
      rhythms: ["A clean week ahead", "Momentum started", "A steady rhythm", "A strong rhythm"],
      rhythmBody: "{days} active days · {answers} answers · {lab} Lab outcomes",
      activeDays: "Active days",
      answers: "Answers",
      steady: "Steady answers",
      labOutcomes: "Lab outcomes",
      labSummary: "Prepare {prepared} · Place {placed} · Loaded {loaded} · Practiced {practiced}",
      streak: "Current rhythm",
      dayUnit: "days",
      forecastTitle: "Seven-day review outlook",
      forecastBody: "Overdue work is gathered into Today; later bars show when saved prompts return.",
      dueCount: "{count} reviews",
      today: "Today",
      strengthenedTitle: "Skills in motion",
      strengthenedBody: "Skills with recent steady answers, ranked by fresh evidence.",
      strengthenedCount: "{count} prompts strengthened",
      fallbackCount: "{count} prompts practiced recently",
      frictionTitle: "Worth another pass",
      frictionBody: "Recent retries and shorter schedules surface here—never as a lock or penalty.",
      frictionRecent: "{count} recent retries · {lapses} lifetime lapses",
      frictionLifetime: "{lapses} lifetime lapses · shorter review interval",
      emptyStrength: "Complete a card and recent strengths will appear here.",
      emptyFriction: "No repeated difficulty is asking for attention right now.",
      focusLabel: "Your next focus",
      focusDue: "Clear {count} due prompts while they are fresh.",
      focusFriction: "Revisit {title} with one short, deliberate pass.",
      focusNext: "Build the next foundation: {title}.",
      focusComplete: "Keep your strongest skills warm with a short mixed session.",
      openSession: "Open today's session",
      openExercise: "Open focused practice",
      openDeck: "Open this skill",
      trackingNote: "Detailed weekly history starts with your next answer. The outlook already uses your saved review schedule.",
      localNote: "Learning marks are included in your progress passport. The latest 200 Lab outcomes stay in this browser's Sample Lab.",
    },
    ja: {
      kicker: "振り返り",
      title: "週間パルス",
      intro: "最近の学習、Sample Labの成果、これからの復習量、次の重点を落ち着いて確認できます。",
      rhythms: ["新しい一週間へ", "勢いが生まれています", "安定したリズム", "力強いリズム"],
      rhythmBody: "学習日 {days}日・解答 {answers}件・ラボ成果 {lab}件",
      activeDays: "学習日",
      answers: "解答",
      steady: "安定した解答",
      labOutcomes: "ラボ成果",
      labSummary: "準備 {prepared}・配置 {placed}・読込済み {loaded}・練習済み {practiced}",
      streak: "現在のリズム",
      dayUnit: "日",
      forecastTitle: "7日間の復習見通し",
      forecastBody: "期限を過ぎた内容は「今日」にまとめ、その後に戻ってくる問題を日別に表示します。",
      dueCount: "復習 {count}件",
      today: "今日",
      strengthenedTitle: "伸びているスキル",
      strengthenedBody: "最近の安定した解答をもとに、伸びが見えるスキルを表示します。",
      strengthenedCount: "定着した問題 {count}件",
      fallbackCount: "最近練習した問題 {count}件",
      frictionTitle: "もう一度取り組む価値あり",
      frictionBody: "最近のやり直しや短い復習間隔を案内します。制限やペナルティにはなりません。",
      frictionRecent: "最近のやり直し {count}件・累計つまずき {lapses}件",
      frictionLifetime: "累計つまずき {lapses}件・短めの復習間隔",
      emptyStrength: "カードを完了すると、最近伸びたスキルがここに表示されます。",
      emptyFriction: "今すぐ重点的に見直す必要のある項目はありません。",
      focusLabel: "次の重点",
      focusDue: "記憶が新しいうちに、期限の来た問題 {count}件を復習しましょう。",
      focusFriction: "「{title}」を短く丁寧にもう一度確認しましょう。",
      focusNext: "次の基礎「{title}」を身につけましょう。",
      focusComplete: "短いミックスセッションで、定着したスキルを保ちましょう。",
      openSession: "今日のセッションを開く",
      openExercise: "重点練習を開く",
      openDeck: "このスキルを開く",
      trackingNote: "詳しい週間履歴は次の解答から始まります。復習見通しには、保存済みの予定をすでに反映しています。",
      localNote: "学習記録は進捗パスポートに含まれます。最新200件のラボ成果は、このブラウザーのSample Labに保存されます。",
    },
  };

  function weeklyInputs() {
    let bundle;
    try { bundle = window.__sxc1Content && window.__sxc1Content.text(); }
    catch (_) { return null; }
    const decks = courseFromBundle(bundle);
    const progressElement = document.getElementById("sxc1-progress");
    let progress;
    try { progress = JSON.parse(progressElement ? progressElement.textContent : ""); }
    catch (_) { return null; }
    return decks.length && progress ? { decks, progress, practice: readPracticeLedger() } : null;
  }

  function weeklyProjection(inputs, lang, strings) {
    const { decks, progress, practice } = inputs;
    const today = Number(progress.masteryToday) || Math.floor(Date.now() / 86400000);
    const recs = new Map((progress.masteryRecs || []).map((rec) => [rec[0], {
      reps: Number(rec[1]) || 0,
      interval: Number(rec[2]) || 0,
      due: Number(rec[3]) || 0,
      lapses: Number(rec[4]) || 0,
      ease: Number(rec[5]) || 2500,
      lastSeen: Number(rec[6]) || 0,
      seen: Number(rec[7]) || 0,
    }]));
    const done = new Set(progress.masteryDone || []);
    const deckById = new Map(decks.map((deck) => [deck.id, deck]));
    const exerciseById = new Map();
    const promptContext = new Map();
    decks.forEach((deck) => deck.exercises.forEach((exercise) => {
      exerciseById.set(exercise.id, { deck, exercise });
      exercise.prompts.forEach((prompt) => promptContext.set(prompt, { deck, exercise }));
    }));

    const history = (progress.weeklyPulse || []).map((entry) => ({
      day: Number(entry[0]) || 0,
      deck: String(entry[1] || ""),
      exercise: String(entry[2] || ""),
      prompt: entry[3] == null ? null : String(entry[3]),
      grade: String(entry[4] || ""),
    })).filter((entry) => entry.day > 0 && entry.deck && entry.exercise);
    const weekStart = today - 6;
    const recent = history.filter((entry) => entry.day >= weekStart && entry.day <= today);
    const answers = recent.filter((entry) => entry.prompt !== null);
    const steadyAnswers = answers.filter((entry) => entry.grade === "good" || entry.grade === "easy");
    const labEvents = (practice?.events || []).filter((entry) => entry.day >= weekStart && entry.day <= today);
    const prepared = labEvents.filter((entry) => entry.kind === "sound-ready").length;
    const placed = labEvents.filter((entry) => entry.kind === "sample-placed").length;
    const loaded = labEvents.filter((entry) => entry.kind === "pad-loaded").length;
    const practiced = labEvents.filter((entry) => entry.kind === "pad-played").length;
    const activeDaySet = new Set(recent.map((entry) => entry.day));
    if (!activeDaySet.size) {
      recs.forEach((rec) => {
        if (rec.lastSeen >= weekStart && rec.lastSeen <= today) activeDaySet.add(rec.lastSeen);
      });
    }
    labEvents.forEach((entry) => activeDaySet.add(entry.day));
    const activeDays = activeDaySet.size;
    const rhythmIndex = activeDays >= 5 ? 3 : activeDays >= 3 ? 2 : activeDays >= 1 ? 1 : 0;

    const outlook = Array.from({ length: 7 }, (_, index) => ({ day: today + index, count: 0 }));
    recs.forEach((rec) => {
      if (!rec.due || rec.due > today + 6) return;
      const index = Math.max(0, rec.due - today);
      outlook[index].count += 1;
    });
    const maxLoad = Math.max(1, ...outlook.map((day) => day.count));
    const weekday = new Intl.DateTimeFormat(lang === "ja" ? "ja-JP" : "en", {
      weekday: "narrow", timeZone: "UTC",
    });
    outlook.forEach((day, index) => {
      day.label = index === 0 ? strings.today : weekday.format(new Date(day.day * 86400000));
      day.percent = Math.max(day.count ? 12 : 2, Math.round((day.count / maxLoad) * 100));
    });

    const strengthMap = new Map();
    steadyAnswers.forEach((entry) => {
      const item = strengthMap.get(entry.deck) || { id: entry.deck, count: 0, fallback: false };
      item.count += 1;
      strengthMap.set(entry.deck, item);
    });
    if (!strengthMap.size) {
      recs.forEach((rec, prompt) => {
        if (rec.lastSeen < weekStart || rec.lastSeen > today || rec.reps <= 0) return;
        const context = promptContext.get(prompt);
        if (!context) return;
        const item = strengthMap.get(context.deck.id)
          || { id: context.deck.id, count: 0, fallback: true };
        item.count += 1;
        strengthMap.set(context.deck.id, item);
      });
    }
    const strengths = [...strengthMap.values()]
      .map((item) => ({ ...item, title: deckById.get(item.id)?.title || item.id, href: `#/x/${item.id}` }))
      .sort((a, b) => b.count - a.count || a.title.localeCompare(b.title)).slice(0, 3);

    const recentFriction = new Map();
    answers.filter((entry) => entry.grade === "again" || entry.grade === "hard")
      .forEach((entry) => recentFriction.set(entry.prompt, (recentFriction.get(entry.prompt) || 0) + 1));
    const friction = [];
    recs.forEach((rec, prompt) => {
      const retries = recentFriction.get(prompt) || 0;
      if (!retries && rec.lapses <= 0 && rec.ease >= 2300) return;
      const context = promptContext.get(prompt);
      if (!context) return;
      friction.push({
        prompt,
        title: context.exercise.title || context.exercise.id,
        href: `#/x/${context.deck.id}/${context.exercise.id}`,
        retries,
        lapses: rec.lapses,
        score: retries * 1000 + rec.lapses * 20 + Math.max(0, 2500 - rec.ease),
      });
    });
    friction.sort((a, b) => b.score - a.score || a.title.localeCompare(b.title));
    const frictionTop = friction.slice(0, 3);

    const due = outlook[0].count;
    let focus;
    if (due > 0) {
      focus = { text: fill(strings.focusDue, { count: due }), href: "#/x/today", action: strings.openSession };
    } else if (frictionTop[0]) {
      focus = { text: fill(strings.focusFriction, frictionTop[0]), href: frictionTop[0].href, action: strings.openExercise };
    } else {
      const next = decks.find((deck) => deck.exercises.some((exercise) => !done.has(exercise.id)));
      focus = next
        ? { text: fill(strings.focusNext, { title: next.title }), href: `#/x/${next.id}`, action: strings.openDeck }
        : { text: strings.focusComplete, href: "#/x/today", action: strings.openSession };
    }

    return {
      today, historyCount: history.length, records: recs.size, activeDays,
      answers: answers.length, steadyAnswers: steadyAnswers.length,
      labOutcomes: labEvents.length, prepared, placed, loaded, practiced,
      streak: Number(progress.streak) || 0, rhythm: strings.rhythms[rhythmIndex],
      outlook, strengths, friction: frictionTop, focus,
    };
  }

  function hydrateWeeklyPulse(root) {
    // Miso may reuse the same empty <section> node while moving between the
    // DOM-owned Mastery and Weekly shells. A dataset flag can therefore
    // survive an id change after another renderer replaced the children;
    // require this surface's own marker as well as the flag.
    if (!root || (root.dataset.weeklyHydrated === "true" && root.querySelector(".weekly-hero"))) return;
    const lang = root.dataset.lang === "ja" ? "ja" : "en";
    const strings = WEEKLY_STRINGS[lang];
    const inputs = weeklyInputs();
    const model = inputs ? weeklyProjection(inputs, lang, strings) : null;
    if (!model) return;
    root.dataset.weeklyHydrated = "true";

    const hero = makeEl("header", "weekly-hero");
    hero.append(
      makeEl("p", "weekly-kicker", strings.kicker),
      makeEl("h1", "", strings.title),
      makeEl("p", "weekly-intro", strings.intro),
    );
    const rhythm = makeEl("div", "weekly-rhythm");
    rhythm.append(
      makeEl("strong", "", model.rhythm),
      makeEl("span", "", fill(strings.rhythmBody,
        { days: model.activeDays, answers: model.answers, lab: model.labOutcomes })),
    );
    hero.append(rhythm);

    const stats = makeEl("ul", "weekly-stats");
    [
      [strings.activeDays, `${model.activeDays}/7`],
      [strings.answers, String(model.answers)],
      [strings.labOutcomes, String(model.labOutcomes)],
      [strings.streak, `${model.streak} ${strings.dayUnit}`],
    ].forEach(([label, value]) => {
      const item = makeEl("li", "");
      item.append(makeEl("strong", "", value), makeEl("span", "", label));
      stats.append(item);
    });

    const labSummary = makeEl("p", "weekly-lab-summary",
      fill(strings.labSummary, { prepared: model.prepared, placed: model.placed, loaded: model.loaded, practiced: model.practiced }));
    labSummary.setAttribute("aria-label", strings.labOutcomes);

    const forecast = makeEl("section", "weekly-section weekly-forecast-section");
    const forecastHeader = makeEl("header", "weekly-section-heading");
    forecastHeader.append(makeEl("h2", "", strings.forecastTitle), makeEl("p", "", strings.forecastBody));
    const bars = makeEl("ol", "weekly-forecast");
    bars.setAttribute("aria-label", strings.forecastTitle);
    model.outlook.forEach((day) => {
      const item = makeEl("li", "");
      item.setAttribute("aria-label", `${day.label}: ${fill(strings.dueCount, day)}`);
      const track = makeEl("span", "weekly-bar-track");
      const fillBar = makeEl("span", "weekly-bar-fill");
      fillBar.style.height = `${day.percent}%`;
      track.append(fillBar);
      item.append(
        makeEl("strong", "weekly-bar-count", String(day.count)),
        track,
        makeEl("span", "weekly-bar-day", day.label),
      );
      bars.append(item);
    });
    forecast.append(forecastHeader, bars);

    const insightGrid = makeEl("div", "weekly-insight-grid");
    const makeInsight = (className, title, body, items, emptyText, renderItem) => {
      const section = makeEl("section", `weekly-section ${className}`);
      const heading = makeEl("header", "weekly-section-heading");
      heading.append(makeEl("h2", "", title), makeEl("p", "", body));
      section.append(heading);
      if (!items.length) section.append(makeEl("p", "weekly-empty", emptyText));
      else {
        const list = makeEl("ul", "weekly-insight-list");
        items.forEach((item) => list.append(renderItem(item)));
        section.append(list);
      }
      return section;
    };
    const strengths = makeInsight("weekly-strengths", strings.strengthenedTitle, strings.strengthenedBody,
      model.strengths, strings.emptyStrength, (item) => {
        const row = makeEl("li", "");
        const link = makeEl("a", "weekly-insight-link");
        link.href = item.href;
        link.append(
          makeEl("strong", "", item.title),
          makeEl("span", "", fill(item.fallback ? strings.fallbackCount : strings.strengthenedCount, item)),
        );
        row.append(link);
        return row;
      });
    const difficulties = makeInsight("weekly-friction", strings.frictionTitle, strings.frictionBody,
      model.friction, strings.emptyFriction, (item) => {
        const row = makeEl("li", "");
        const link = makeEl("a", "weekly-insight-link");
        link.href = item.href;
        link.append(
          makeEl("strong", "", item.title),
          makeEl("span", "", fill(item.retries ? strings.frictionRecent : strings.frictionLifetime,
            { count: item.retries, lapses: item.lapses })),
        );
        row.append(link);
        return row;
      });
    insightGrid.append(strengths, difficulties);

    const focus = makeEl("section", "weekly-focus");
    const focusCopy = makeEl("div", "weekly-focus-copy");
    focusCopy.append(makeEl("span", "weekly-focus-label", strings.focusLabel), makeEl("strong", "", model.focus.text));
    const focusLink = makeEl("a", "primary-training-action wizard-choice wizard-yes", model.focus.action);
    focusLink.id = "btn-weekly-focus";
    focusLink.href = model.focus.href;
    focus.append(focusCopy, focusLink);

    const notes = makeEl("footer", "weekly-notes");
    if (!model.historyCount && model.records) notes.append(makeEl("p", "weekly-tracking-note", strings.trackingNote));
    notes.append(makeEl("p", "", strings.localNote));

    root.replaceChildren(hero, stats, labSummary, forecast, insightGrid, focus, notes);
    window.__SXC1_WEEKLY = {
      mounted: true,
      renderer: "dom",
      historyCap: 200,
      historyCount: model.historyCount,
      activeDays: model.activeDays,
      answers: model.answers,
      steadyAnswers: model.steadyAnswers,
      labOutcomes: model.labOutcomes,
      prepared: model.prepared,
      placed: model.placed,
      loaded: model.loaded,
      practiced: model.practiced,
      outlook: model.outlook.map((day) => day.count),
      strengthenedCount: model.strengths.length,
      frictionCount: model.friction.length,
      focusHref: model.focus.href,
    };
  }

  function scanForWeeklyPulse() {
    hydrateWeeklyPulse(document.getElementById("sxc1-weekly"));
  }

  // Today's Session is a tab-scoped coaching layer over course progress and,
  // when real Sample Lab work is waiting, one concrete Lab outcome. Its
  // five-item plan is deliberately stable while the
  // learner moves between routes: progress can update the completion marks,
  // but does not reshuffle the work underneath them. sessionStorage is only a
  // convenience; privacy modes that refuse it fall back to in-memory state.
  const SESSION_KEY = "sxc1.today-session.v1";
  let memorySession = null;
  const renderedSessionKeys = new WeakMap();
  const SESSION_STRINGS = {
    en: {
      kicker: "Training",
      title: "Today's session",
      intro: "Five calm steps across learning, preparation, and loading—only the work that is ready now.",
      measure: "{count} steps · about {minutes} min",
      progress: "{done} of {total} complete",
      due: "Review due",
      continue: "Continue",
      new: "Learn next",
      maintain: "Keep sharp",
      prepare: "Prepare / load",
      ready: "Ready",
      done: "Done",
      skipped: "Skipped today",
      start: "Start session",
      resume: "Resume session",
      reset: "Build a new plan",
      skipLab: "Skip for today",
      completeTitle: "Session complete",
      completeBody: "Nicely done. Your review schedule and mastery journey now reflect this work.",
      mastery: "See your mastery journey",
      weekly: "See your weekly pulse",
      back: "Session plan",
      inExercise: "Card {current} of {total}",
      next: "Next session card",
      finish: "Finish session",
      kinds: { quiz: "Quiz", drill: "Practice", lookup: "Find it", lab: "Lab task" },
    },
    ja: {
      kicker: "トレーニング",
      title: "今日のセッション",
      intro: "学習・準備・読込みを、今できる5つの落ち着いたステップにまとめます。",
      measure: "{count}ステップ・約{minutes}分",
      progress: "{total}件中{done}件完了",
      due: "復習時期",
      continue: "続きから",
      new: "次を学ぶ",
      maintain: "定着を保つ",
      prepare: "準備・読込み",
      ready: "準備完了",
      done: "完了",
      skipped: "今日はスキップ",
      start: "セッションを開始",
      resume: "セッションを再開",
      reset: "新しいプランを作成",
      skipLab: "今日はスキップ",
      completeTitle: "セッション完了",
      completeBody: "お疲れさまでした。今回の学習は復習予定と習熟の道筋に反映されました。",
      mastery: "習熟の道筋を見る",
      weekly: "週間パルスを見る",
      back: "セッションプラン",
      inExercise: "{total}件中{current}件目",
      next: "次のセッションカード",
      finish: "セッションを完了",
      kinds: { quiz: "クイズ", drill: "練習", lookup: "検索", lab: "ラボタスク" },
    },
  };

  function readSession() {
    try {
      const raw = window.sessionStorage.getItem(SESSION_KEY);
      return raw ? JSON.parse(raw) : null;
    } catch (_) { /* in-memory fallback below */ }
    return memorySession;
  }

  function writeSession(plan) {
    memorySession = plan;
    try { window.sessionStorage.setItem(SESSION_KEY, JSON.stringify(plan)); }
    catch (_) { /* the plan remains stable in this page */ }
  }

  function removeSession() {
    memorySession = null;
    try { window.sessionStorage.removeItem(SESSION_KEY); }
    catch (_) { /* no persisted copy */ }
  }

  function sessionInputs() {
    let bundle;
    try { bundle = window.__sxc1Content && window.__sxc1Content.text(); }
    catch (_) { return null; }
    const decks = courseFromBundle(bundle);
    const progressElement = document.getElementById("sxc1-progress");
    let progress;
    try { progress = JSON.parse(progressElement ? progressElement.textContent : ""); }
    catch (_) { return null; }
    return decks.length && progress ? { decks, progress, labTask: practiceLabTask(progress.uiLang === "ja" ? "ja" : "en") } : null;
  }

  function makeSessionPlan(inputs, lang) {
    const { decks, progress, labTask } = inputs;
    const today = Number(progress.masteryToday) || 0;
    const done = new Set(progress.masteryDone || []);
    const recs = new Map((progress.masteryRecs || []).map((rec) => [rec[0], {
      reps: Number(rec[1]) || 0,
      interval: Number(rec[2]) || 0,
      due: Number(rec[3]) || 0,
    }]));
    const deckById = new Map(decks.map((deck) => [deck.id, deck]));
    const deckComplete = (id) => {
      const deck = deckById.get(id);
      return Boolean(deck && deck.exercises.length
        && deck.exercises.every((exercise) => done.has(exercise.id)));
    };
    const all = [];
    decks.forEach((deck) => deck.exercises.forEach((exercise) => {
      const promptRecs = exercise.prompts.map((prompt) => recs.get(prompt)).filter(Boolean);
      all.push({
        id: exercise.id,
        title: exercise.title || exercise.id,
        type: exercise.type || "quiz",
        deckId: deck.id,
        deckTitle: deck.title,
        href: `#/x/${deck.id}/${exercise.id}`,
        due: promptRecs.filter((rec) => rec.due <= today).length,
        seen: promptRecs.length > 0,
        finished: done.has(exercise.id),
        prereqsMet: deck.requires.every(deckComplete),
        courseIndex: all.length,
        minutes: exercise.type === "drill" ? 2 : 1,
      });
    }));

    const chosen = [];
    const courseLimit = labTask ? 4 : 5;
    const used = new Set();
    const usedKinds = new Set();
    const addFrom = (candidates, reason, limit = 99) => {
      let added = 0;
      while (chosen.length < courseLimit && added < limit) {
        const available = candidates.filter((item) => !used.has(item.id));
        if (!available.length) break;
        const item = available.find((candidate) => !usedKinds.has(candidate.type)) || available[0];
        chosen.push({ ...item, reason });
        used.add(item.id);
        usedKinds.add(item.type);
        added += 1;
      }
    };
    const due = all.filter((item) => item.due > 0)
      .sort((a, b) => b.due - a.due || a.courseIndex - b.courseIndex);
    const continuing = all.filter((item) => !item.finished && item.seen)
      .sort((a, b) => a.courseIndex - b.courseIndex);
    const fresh = all.filter((item) => !item.finished && !item.seen && item.prereqsMet)
      .sort((a, b) => a.courseIndex - b.courseIndex);
    addFrom(due, "due", 2);
    addFrom(continuing, "continue", 2);
    addFrom(fresh, "new", 1);
    addFrom(due, "due");
    addFrom(continuing, "continue");
    addFrom(fresh, "new");
    addFrom(all.filter((item) => !item.finished), "new");
    addFrom(all, "maintain");

    const signature = `${lang}:${all.length}:${all[0]?.id || "none"}:${all.at(-1)?.id || "none"}`;
    const courseItems = chosen.map(({ courseIndex, prereqsMet, seen, finished, ...item }) => item);
    const items = labTask && courseItems.length
      ? [courseItems[0], labTask, ...courseItems.slice(1)]
      : labTask ? [labTask] : courseItems;
    return {
      version: 2,
      day: today,
      signature,
      id: `${today}:${signature}:${items.map((item) => `${item.id}:${item.reason}`).join(",")}`,
      items,
      completed: items.filter((item) => done.has(item.id)).map((item) => item.id),
      skipped: [],
    };
  }

  function reconcileSessionCompletion(plan, progress) {
    const persisted = new Set(progress.masteryDone || []);
    const ledger = readPracticeLedger();
    const completed = plan.items
      .filter((item) => item.type === "lab"
        ? ledger.events.some((event) => practiceEventMatches(item, event))
        : persisted.has(item.id))
      .map((item) => item.id);
    const previous = Array.isArray(plan.completed) ? plan.completed : [];
    if (completed.length === previous.length
      && completed.every((id, index) => id === previous[index])) return plan;
    const reconciled = { ...plan, completed };
    writeSession(reconciled);
    return reconciled;
  }

  function normalizedStoredSession(stored, exerciseIds) {
    if (!stored || stored.version !== 2 || !Array.isArray(stored.items) || stored.items.length > 5) return null;
    const itemIds = new Set();
    let labCount = 0;
    for (const item of stored.items) {
      if (!item || typeof item.id !== "string" || itemIds.has(item.id)) return null;
      itemIds.add(item.id);
      if (item.type === "lab") {
        labCount += 1;
        if (labCount > 1 || !item.id.startsWith("lab:")
          || typeof item.href !== "string" || !item.href.startsWith("#/samples?practice=")
          || !Array.isArray(item.eventKinds) || item.eventKinds.length !== 1
          || !Number.isSafeInteger(item.afterSeq) || item.afterSeq < 0
          || !["sample-placed", "sound-ready", "pad-loaded", "pad-played"].includes(item.eventKinds[0])) return null;
      } else if (!exerciseIds.has(item.id)
        || typeof item.href !== "string" || !/^#\/x\/[^/]+\/[^/]+$/.test(item.href)) return null;
    }
    const completed = [...new Set(Array.isArray(stored.completed) ? stored.completed : [])]
      .filter((id) => itemIds.has(id));
    const skipped = [...new Set(Array.isArray(stored.skipped) ? stored.skipped : [])]
      .filter((id) => itemIds.has(id) && !completed.includes(id));
    return { ...stored, items: stored.items.slice(), completed, skipped };
  }

  function currentSession(inputs, lang) {
    const allExercises = inputs.decks.flatMap((deck) => deck.exercises);
    const signature = `${lang}:${allExercises.length}:${allExercises[0]?.id || "none"}:${allExercises.at(-1)?.id || "none"}`;
    const today = Number(inputs.progress.masteryToday) || 0;
    const ids = new Set(allExercises.map((exercise) => exercise.id));
    const stored = normalizedStoredSession(readSession(), ids);
    if (stored && stored.day === today && stored.signature === signature) {
      return reconcileSessionCompletion(stored, inputs.progress);
    }
    const plan = makeSessionPlan(inputs, lang);
    writeSession(plan);
    return plan;
  }

  function publishSession(plan, mounted) {
    const completed = new Set(plan.completed || []);
    const skipped = new Set(plan.skipped || []);
    const reasonCounts = plan.items.reduce((counts, item) => {
      counts[item.reason] = (counts[item.reason] || 0) + 1;
      return counts;
    }, {});
    window.__sxc1TodaySession = {
      mounted,
      renderer: "dom",
      stable: true,
      planId: plan.id,
      itemCount: plan.items.length,
      completedCount: completed.size,
      handledCount: new Set([...completed, ...skipped]).size,
      skippedCount: skipped.size,
      labCount: plan.items.filter((item) => item.type === "lab").length,
      ids: plan.items.map((item) => item.id),
      types: plan.items.map((item) => item.type),
      reasonCounts,
      estimatedMinutes: Math.max(5, plan.items.reduce((sum, item) => sum + item.minutes, 0)),
    };
  }

  function hydrateTodaySession(root) {
    if (!root) return;
    const lang = root.dataset.lang === "ja" ? "ja" : "en";
    const strings = SESSION_STRINGS[lang];
    const inputs = sessionInputs();
    if (!inputs) return;
    let plan = currentSession(inputs, lang);
    const renderKey = () => `${plan.id}:${(plan.completed || []).join(",")}:${(plan.skipped || []).join(",")}`;
    if (renderedSessionKeys.get(root) === renderKey() && root.querySelector(".session-hero")) return;

    const render = () => {
      renderedSessionKeys.set(root, renderKey());
      const completed = new Set(plan.completed || []);
      const skipped = new Set(plan.skipped || []);
      const handled = new Set([...completed, ...skipped]);
      const remaining = plan.items.filter((item) => !handled.has(item.id));
      const minutes = Math.max(5, plan.items.reduce((sum, item) => sum + item.minutes, 0));
      const hero = makeEl("header", "session-hero");
      hero.append(
        makeEl("p", "session-kicker", strings.kicker),
        makeEl("h1", "", remaining.length ? strings.title : strings.completeTitle),
        makeEl("p", "session-intro", remaining.length ? strings.intro : strings.completeBody),
      );
      const meter = makeEl("div", "session-meter");
      const progressText = fill(strings.progress, { done: handled.size, total: plan.items.length });
      meter.append(
        makeEl("strong", "", remaining.length ? fill(strings.measure, { count: plan.items.length, minutes }) : progressText),
        makeEl("span", "", progressText),
      );
      const progress = makeEl("progress", "session-progress");
      progress.max = plan.items.length;
      progress.value = handled.size;
      progress.setAttribute("aria-label", progressText);
      meter.append(progress);
      hero.append(meter);

      const list = makeEl("ol", "session-list");
      plan.items.forEach((item, index) => {
        const isDone = completed.has(item.id);
        const isSkipped = skipped.has(item.id);
        const row = makeEl("li", `session-item session-reason-${item.reason}${isDone ? " is-done" : ""}${isSkipped ? " is-skipped" : ""}`);
        row.dataset.exercise = item.id;
        row.dataset.reason = item.reason;
        const link = makeEl("a", "session-card");
        link.href = item.href;
        const number = makeEl("span", "session-number", isDone ? "✓" : isSkipped ? "—" : String(index + 1));
        const copy = makeEl("span", "session-copy");
        copy.append(
          makeEl("span", "session-reason", strings[item.reason]),
          makeEl("strong", "session-title", item.title),
          makeEl("span", "session-context", `${item.deckTitle} · ${strings.kinds[item.type] || item.type}`),
        );
        const status = makeEl("span", "session-status", isDone ? strings.done : isSkipped ? strings.skipped : strings.ready);
        link.append(number, copy, status);
        row.append(link);
        list.append(row);
      });

      const actions = makeEl("div", "session-actions");
      if (remaining.length) {
        const start = makeEl("a", "primary-training-action wizard-choice wizard-yes",
          handled.size ? strings.resume : strings.start);
        start.id = "btn-session-start";
        start.href = remaining[0].href;
        actions.append(start);
        if (remaining[0].type === "lab") {
          const skip = makeEl("button", "session-reset", strings.skipLab);
          skip.id = "btn-session-skip-lab";
          skip.type = "button";
          skip.addEventListener("click", () => {
            plan = { ...plan, skipped: [...skipped, remaining[0].id] };
            writeSession(plan);
            render();
          });
          actions.append(skip);
        } else {
          const reset = makeEl("button", "session-reset", strings.reset);
          reset.id = "btn-session-reset";
          reset.type = "button";
          reset.addEventListener("click", () => {
            removeSession();
            plan = makeSessionPlan(inputs, lang);
            writeSession(plan);
            render();
          });
          actions.append(reset);
        }
      } else {
        const weekly = makeEl("a", "primary-training-action wizard-choice wizard-yes", strings.weekly);
        weekly.id = "btn-session-weekly";
        weekly.href = "#/x/week";
        actions.append(weekly);
        const mastery = makeEl("a", "session-secondary", strings.mastery);
        mastery.id = "btn-session-mastery";
        mastery.href = "#/x/map";
        actions.append(mastery);
      }
      root.replaceChildren(hero, list, actions);
      publishSession(plan, true);
    };
    render();
  }

  function sessionExerciseRoute() {
    const match = window.location.hash.match(/^#\/x\/([^/]+)\/([^/]+)$/);
    return match ? { deck: match[1], exercise: match[2] } : null;
  }

  function updateSessionCoach() {
    const oldBar = document.getElementById("sxc1-session-coach");
    const route = sessionExerciseRoute();
    const stored = readSession();
    if (!route || !stored) {
      oldBar?.remove();
      document.body.classList.remove("session-coach-active");
      return;
    }
    const inputs = sessionInputs();
    const lang = inputs?.progress?.uiLang === "ja" ? "ja" : "en";
    const strings = SESSION_STRINGS[lang];
    const plan = inputs ? currentSession(inputs, lang) : null;
    const index = route && plan ? plan.items.findIndex((item) => item.id === route.exercise && item.deckId === route.deck) : -1;
    if (!plan || index < 0 || !document.getElementById("sxc1-exercise")) {
      oldBar?.remove();
      document.body.classList.remove("session-coach-active");
      return;
    }

    const summaryVisible = Boolean(document.getElementById("ex-summary"));
    if (summaryVisible && !(plan.completed || []).includes(route.exercise)) {
      plan.completed = [...(plan.completed || []), route.exercise];
      writeSession(plan);
    }
    const completed = new Set(plan.completed || []);
    const handled = new Set([...completed, ...(plan.skipped || [])]);
    const next = plan.items.slice(index + 1).find((item) => !handled.has(item.id))
      || plan.items.find((item) => !handled.has(item.id));
    const signature = `${plan.id}:${route.exercise}:${summaryVisible}:${completed.size}:${next?.id || "done"}`;
    if (oldBar?.dataset.signature === signature) return;

    const bar = oldBar || makeEl("aside", "session-coach");
    bar.id = "sxc1-session-coach";
    bar.dataset.signature = signature;
    bar.setAttribute("aria-label", strings.title);
    const back = makeEl("a", "session-coach-back", `← ${strings.back}`);
    back.href = "#/x/today";
    const position = makeEl("strong", "session-coach-position",
      fill(strings.inExercise, { current: index + 1, total: plan.items.length }));
    const live = makeEl("span", "session-coach-live",
      fill(strings.progress, { done: completed.size, total: plan.items.length }));
    live.setAttribute("aria-live", "polite");
    bar.replaceChildren(back, position, live);
    if (summaryVisible) {
      const forward = makeEl("a", "session-coach-next", next ? strings.next : strings.finish);
      forward.href = next ? next.href : "#/x/today";
      bar.append(forward);
    }
    if (!oldBar) document.body.append(bar);
    document.body.classList.add("session-coach-active");
    publishSession(plan, false);
  }

  function scanForTodaySession() {
    hydrateTodaySession(document.getElementById("sxc1-session"));
    updateSessionCoach();
  }

  // A review grade or hands-on decision already means "keep going".
  // Remember that intent across Miso's render, then replace the otherwise
  // redundant completion summary with the next card. Today's Session owns
  // its own order, so prefer the coach's next planned link; direct course
  // study falls back to the authored next-card link rendered by Haskell.
  // Again still changes the spaced-repetition interval, but never traps the
  // learner in an immediate loop. Skip records unfinished drill prompts and
  // leaves them due rather than pretending the work was mastered.
  let pendingRatedAdvance = null;
  let pendingRatedFocus = null;
  document.addEventListener("click", (event) => {
    const button = event.target instanceof Element
      ? event.target.closest("#btn-ex-grade-again, #btn-ex-grade-hard, #btn-ex-grade-good, #btn-ex-grade-easy, #btn-ex-skip, .btn-ex-confirm")
      : null;
    if (!button) return;
    pendingRatedAdvance = window.location.hash;
  }, true);

  function advanceRatedCard() {
    if (pendingRatedFocus) {
      if (window.location.hash !== pendingRatedFocus) {
        pendingRatedFocus = null;
      } else {
        const title = document.querySelector("#sxc1-exercise #ex-title");
        if (title && !document.getElementById("ex-summary")) {
          title.focus();
          pendingRatedFocus = null;
        }
      }
    }
    if (!pendingRatedAdvance) return;
    if (window.location.hash !== pendingRatedAdvance) {
      pendingRatedAdvance = null;
      return;
    }
    const summary = document.getElementById("ex-summary");
    if (!summary) return;
    const forward = document.querySelector("#sxc1-session-coach .session-coach-next")
      || summary.querySelector("#btn-ex-next-card");
    const href = forward?.getAttribute("href");
    pendingRatedAdvance = null;
    if (!href || !href.startsWith("#/")) return;
    pendingRatedFocus = href;
    window.location.hash = href;
  }

  scanForMasteryJourney();
  scanForTodaySession();
  advanceRatedCard();
  scanForWeeklyPulse();
  scanForProgressPortability();
  new MutationObserver(() => {
    scanForMasteryJourney();
    scanForTodaySession();
    advanceRatedCard();
    scanForWeeklyPulse();
    scanForProgressPortability();
  }).observe(document.body, {
    childList: true,
    subtree: true,
    // The Mastery and Weekly Haskell shells are both empty <section>s.
    // Miso can reuse that node and change only its id, which produces no
    // childList mutation; observing the two routing attributes makes that
    // legitimate empty-shell transition visible to the DOM hydrators.
    attributes: true,
    attributeFilter: ["id", "data-lang"],
  });
})();
