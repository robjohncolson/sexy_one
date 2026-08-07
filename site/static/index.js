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
  preview.textContent =
    n === 1 ? "1 record found in the pasted text." : `${n} records found in the pasted text.`;
});
