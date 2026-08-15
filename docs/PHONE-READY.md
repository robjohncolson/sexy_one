# Phone-ready release

M9 makes the existing static trainer installable, repeatably usable on weak or
absent connections, measurable in the field, and easier to move between a
computer and a phone. It does not add an account, backend, analytics endpoint,
or second progress format.

## Install and offline contract

`manifest.webmanifest` uses only scope-relative URLs, starts at
`#/x/today`, and describes one standalone application at either the origin root
or a GitHub Pages-style nested path. `app-icon.svg` is the maskable application
icon.

`sw.js` registers only after the real WASM app has become interactive, so its
cache fill never competes with the first useful boot. Installation atomically
precaches:

- the HTML/JavaScript/WASM executable shell;
- the on-demand Sound Check worker (cached for offline use, but not started at boot);
- the generated GHC JSFFI module and vendored WASI runtime modules;
- both exercise languages and both manual-text languages;
- the manifest, app icon, and phone QR.

The 108 manual scans are deliberately excluded. A scan enters the versioned
runtime cache only after the learner opens it. This keeps installation near the
executable size instead of silently adding roughly 9.4 MB of images.

Core requests are network-first with cache fallback. This gives an online load
the current deployment while allowing a disconnected load to boot coherently.
A new worker activates only after every file in its new versioned core cache is
present, then removes earlier SEXY ONE cache versions. Both the worker and the
manifest remain subpath-safe.

`window.__SXC1_PWA` publishes registration, readiness, scope, cache version,
connectivity, and installability diagnostics. A body-level bilingual live region
appears only while the browser reports that it is offline.

## Progress passport

The existing `SXC1.Progress.Codec` remains the only data authority. Pressing
Export still asks Haskell to produce its stamped JSON envelope. The DOM-owned
passport shell can then:

- save those exact bytes as `sexy-one-progress-YYYY-MM-DD.sxc1`;
- offer the native share sheet when the browser supports sharing files;
- read a `.sxc1`, JSON, or text backup no larger than 1 MiB into the existing
  import textarea.

Choosing a file never commits it. The existing record-count preview updates,
and the learner must still press Import; only then does Haskell validate the
envelope and write progress. Corrupt imports therefore retain the same visible,
non-destructive failure behavior as pasted imports. Settings remain local to the
browser; the passport moves training progress.

The empty `#sxc1-progress-passport` and `#sxc1-import-file-shell` elements are
the Haskell/DOM ownership seams. Miso owns the stable Export and Import
disclosures; `index.js` owns only the Save/Share children of the first and file
picker children of the second. Once bytes exist Save/Share replace Export, so
the surface never accumulates three backup buttons. `window.__SXC1_PROGRESS_PORTABILITY`
exposes the available file operations for regression diagnostics.

## Field measurements and regressions

`window.__SXC1_BOOT_METRICS` now includes total resource transfer bytes, encoded
body bytes, effective connection type, and data-saver state in addition to WASM,
content, total time, and memory. No measurement is transmitted.

The permanent browser gate proves that:

- the manifest, scope, icon, registered worker, and current `m16-v1` core cache agree;
- a genuinely network-disabled fresh page boots the real optimized WASM app
  from cache and shows the offline live region;
- the same checks pass from both the origin root and a nested deployment path;
- a generated export becomes a correctly named file with identical bytes;
- choosing that file updates preview text without mutating localStorage;
- the expanded passport has no overflow and retains 44 px controls at 320 px;
- boot memory remains at or below 24 MiB and the new measurements are finite.

Automated emulation cannot replace the final field pass. Before declaring the
physical-phone portion closed, hand-check a current iPhone and Android phone for
cold QR entry, install, offline relaunch, Today’s Session completion, Japanese
switching, backup sharing, and backup restore.
