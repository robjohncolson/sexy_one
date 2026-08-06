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
