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
const sxc1ContentPromise = (async () => {
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
})();

const bootStatus = document.getElementById("boot-status");

try {
  const wasi = new WASI([], ["GHCRTS=-H64m"], [
    new OpenFile(new File([])), // stdin
    ConsoleStdout.lineBuffered((msg) => console.log("[wasm stdout]", msg)),
    ConsoleStdout.lineBuffered((msg) => console.warn("[wasm stderr]", msg)),
  ], { debug: false });

  // GHC's JSFFI import object needs the instance's exports to call back
  // into wasm, but the exports only exist once instantiation finishes, so
  // we pass a mutable placeholder object and fill it in afterwards.
  const instanceExports = {};
  const { instance } = await WebAssembly.instantiateStreaming(fetch("./app.wasm"), {
    wasi_snapshot_preview1: wasi.wasiImport,
    ghc_wasm_jsffi: ghc_wasm_jsffi(instanceExports),
  });
  Object.assign(instanceExports, instance.exports);

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
  const part = (name) => { try { return sxc1Content[name] || { ok: false, error: "content bridge failure" }; } catch (e) { return { ok: false, error: "content bridge failure" }; } };
  window.__sxc1Content = {
    lang: () => { try { return sxc1Content.lang; } catch (e) { return "en"; } },
    text: () => { const p = part("content"); return p.ok ? p.text : undefined; },
    error: () => { const p = part("content"); return p.ok ? undefined : String(p.error); },
    manualText: () => { const p = part("manual"); return p.ok ? p.text : undefined; },
    manualError: () => { const p = part("manual"); return p.ok ? undefined : String(p.error); },
  };

  wasi.initialize(instance);          // runs _initialize, starting the Haskell RTS
  await instance.exports.hs_start();  // mounts the Miso app into <body>

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
    bootStatus.textContent = `Failed to start the SXC-1 Trainer application: ${message}`;
  }
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
    if (confirmBtn) confirmBtn.hidden = false;
  } else if (id === "btn-progress-wipe-confirm") {
    event.target.hidden = true;
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
