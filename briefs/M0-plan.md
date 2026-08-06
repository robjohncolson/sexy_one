# M0 Implementation Plan — Miso + GHC WASM toolchain spike

**From:** Opus 5 design agent · **To:** Fable / Sonnet 5 swarm · **Date:** 2026-08-06
**Companion:** `briefs/M0-manifest.json` (6 tasks, 3 waves)

---

## 1. Decision summary

Build the spike on the **prebuilt `ghc-wasm-meta` bindists, flavour 9.14, installed without
Nix and without `ghcup`**, and on **Miso 1.12.0.0 from Hackage** pinned by
`index-state`. The app compiles to a single WebAssembly *reactor* module that is booted by a
~40-line ES module using a **vendored** copy of `@bjorn3/browser_wasi_shim` — no CDN, no
absolute URLs, so the output drops straight onto GitHub Pages at any sub-path.

Five scripts form the whole build story, all runnable from a fresh clone:

```
scripts/install-toolchain.sh   one-time, ~800 MB download, ~15-40 min
scripts/build-site.sh          → site/public/   (the deployable artifact)
scripts/serve-site.sh          → http://127.0.0.1:8123/
scripts/check-site.sh          structural checks + headless-Chrome smoke test
scripts/browser-check.mjs      the CDP driver check-site.sh calls (zero npm deps)
```

**M0's definition of done maps to:** `git clone && ./scripts/install-toolchain.sh &&
./scripts/build-site.sh && ./scripts/check-site.sh` — the last command drives a real
headless browser that loads the page, asserts the Haskell app mounted, clicks the buttons
and asserts the counter changed.

---

## 2. Verified environment (probed read-only, 2026-08-06)

| Fact | Value |
|---|---|
| Kernel / arch | Linux 6.8, x86_64, 4 cores |
| RAM | 7.6 GiB total, ~3.9 GiB available, 2.0 GiB swap |
| Disk | 1.6 TiB free on `/` (holds `$HOME`) — no constraint |
| Haskell tooling | none (`ghc`/`ghcup`/`cabal`/`stack`/`nix` all absent) |
| Present and needed | `bash`, `git` 2.34.1, `curl`, `tar`, `xz`, `unzip`, `unzstd`, `jq` 1.6, `make`, `cc`/`gcc`, `sed`, `realpath` — **the complete prerequisite set for `ghc-wasm-meta/setup.sh`** |
| Node | v24.16.0 system-wide (global `WebSocket`, `WebAssembly.Module.exports` both available) |
| Python | 3.10.12; `mimetypes` maps `.wasm` → `application/wasm`, so `python3 -m http.server` is a valid dev server for `instantiateStreaming` |
| Browser | **Google Chrome 151.0.7922.71 at `/usr/bin/google-chrome`** (also Firefox) — a headless acceptance test needs zero installs |
| Missing | `shellcheck` (use `bash -n`), `wasmtime` (not needed) |

Two consequences: (a) nothing has to be installed outside `~/.ghc-wasm`, and (b) the
"works in a browser" half of the DoD can be *automated*, not just eyeballed.

---

## 3. Pinned versions

| Component | Pin | Why this pin |
|---|---|---|
| `ghc-wasm-meta` | GitHub mirror `haskell-wasm/ghc-wasm-meta` @ **`c75985a1b58fb0376eea9149ba5c7b933b3c7455`** (2026-08-05) | Pinning the commit pins `autogen.json`, which pins every bindist URL and its SRI digest. **Correction (post-M0 review, M1):** git's commit hash verifies only the `ghc-wasm-meta` *source* tree — it says nothing about the ~785 MB of bindists `setup.sh` goes on to download. That is a separate integrity gap, and it is now closed: `install-toolchain.sh` verifies every download against the SRI digest `autogen.json` already carries for it. See §4.2 and R1's residual, below. |
| GHC wasm flavour | **`FLAVOUR=9.14`** → `wasm32-wasi-ghc-9.14.tar.xz` from `haskell-wasm/ghc-wasm-bindists` release `20260731T193144` (467 MB) | The 9.14 branch is the newest release-branch flavour, is what `ghc-wasm-meta`'s CI job `x86_64-linux-ubuntu-9.14` exercises, **and that job runs `tests/miso.sh`** — i.e. upstream continuously builds Miso against exactly this flavour. |
| Boot libs (verified from the GHC 9.14.1 release notes) | base 4.22.0.0, template-haskell 2.24.0.0, ghc-experimental 9.1401.0, text 2.1.3, bytestring 0.12.2.0, containers 0.8, mtl 2.3.1, transformers 0.6.1.2 | **Every one of miso 1.12.0.0's version bounds is satisfied with no `allow-newer` needed** — notably TH 2.24 sits inside miso's `>= 2.21 && < 2.25`. Checked bound-by-bound against `miso.cabal`. |
| Miso | **`miso == 1.12.0.0`** from Hackage (uploaded 2026-06-27; Stackage nightly-2026-06-28), with `index-state: 2026-08-01T00:00:00Z` | Latest release. I downloaded the sdist and confirmed it ships `js/miso.js`, `js/miso.prod.js`, `cbits/foreign.c` and the whole `ffi/wasm/` tree, so the Hackage tarball is complete for a wasm build. Hackage + `index-state` is more reproducible than upstream's `source-repository-package` git tag (tags move; the index does not). Equivalent git commit, if ever needed: `9f1222293fe92e7d22272e884ac97c205876b943`. |
| cabal-install | 3.14.2.0 (shipped by `ghc-wasm-meta`) | not our choice; recorded for the record |
| wasi-sdk / binaryen / wasm-tools / bundled Node | 29.0 / version_131 / 260729 / 26.6.0 | pinned transitively by the `ghc-wasm-meta` commit |
| WASI browser shim | `@bjorn3/browser_wasi_shim` **0.3.0**, vendored, sha256 `241c96716da84579e1045446f4f76faf637b97b1983ed7e9e590b71667a6c1b7` | the version upstream Miso's own loader uses; MIT OR Apache-2.0; 34 KB |
| GitHub Actions | checkout@v7, cache@v6, upload-pages-artifact@v5, deploy-pages@v5 | current majors as of 2026-08-06 |

Total first-time download: **~785 MB**; installed footprint in `~/.ghc-wasm`: several GB.

---

## 4. Build architecture

### 4.1 Repo layout after M0

```
casio-sxc1/
├── README.md                       ← build story (fresh-clone instructions)
├── .gitignore                      ← + site/public, site/dist-newstyle
├── .github/workflows/site.yml      ← build + check + Pages deploy
├── scripts/
│   ├── extract-pages.sh            (pre-existing, untouched)
│   ├── install-toolchain.sh
│   ├── build-site.sh
│   ├── serve-site.sh
│   ├── check-site.sh
│   └── browser-check.mjs
└── site/
    ├── cabal.project               packages/index-state/installed-constraints
    ├── sxc1-trainer.cabal          exe `app`, wasm32 + javascript stanzas
    ├── .gitignore                  dist-newstyle/, public/
    ├── app/Main.hs                 the Miso counter
    ├── static/                     everything copied verbatim into the output
    │   ├── index.html
    │   ├── index.js                the WASM boot loader
    │   ├── .nojekyll
    │   └── vendor/browser_wasi_shim/{index,wasi,fd,fs_mem,fs_opfs,strace,wasi_defs,debug}.js
    │                               + LICENSE-MIT, LICENSE-APACHE, VERSION.txt
    └── public/                     BUILD OUTPUT (gitignored, deployable as-is)
```

`site/public/` is never committed. GitHub Pages is fed from the Actions artifact, so the
repo carries no build products — important, since the repo already holds a 75 MB PDF.

### 4.2 Toolchain install

`ghc-wasm-meta`'s documented one-liner is
`curl https://gitlab.haskell.org/.../bootstrap.sh | sh`. **We must not use it** (see risk
R1). Instead:

```
git clone https://github.com/haskell-wasm/ghc-wasm-meta.git $tmp
git -C $tmp checkout c75985a1b58fb0376eea9149ba5c7b933b3c7455   # git verifies content
FLAVOUR=9.14 PREFIX=$HOME/.ghc-wasm bash $tmp/setup.sh
```

`setup.sh` pulls every bindist from **GitHub Releases** (`haskell-wasm/*`) plus
`downloads.haskell.org` for cabal — all reachable from this machine; only
`gitlab.haskell.org` is walled off. It lays down `wasi-sdk`, `libffi-wasm`, a private
Node 26, binaryen, wasm-tools, `wasm32-wasi-ghc`, `cabal`, the `wasm32-wasi-cabal`
wrapper, and `~/.ghc-wasm/env` (the `source`-able PATH/CC/AR/… script). For flavours
9.10–9.14 it installs `cabal.th.config`, the Template-Haskell-capable cabal config — which
we need (risk R3).

The script is **destructive** (`rm -rf $PREFIX` on entry), so our wrapper detects an
existing good install and no-ops unless `--force`, and exposes `--check` for cheap
verification. It writes a stamp file recording the pin and the resolved GHC version.

**Post-M0 review correction (B1, M1):** the destructiveness above was worse in practice
than this paragraph implied. The original "existing good install" detection did not fire
for a directory that was not already a toolchain (only for one containing a readable
`env`), so a caller-supplied `GHC_WASM_PREFIX` — including something as careless as
`$HOME` itself — could reach `setup.sh`'s `rm -rf "$PREFIX"` with **no** `--force` flag
and no warning; this was reproduced. Fixed: `install-toolchain.sh` now canonicalises
`$PREFIX` and, before any network access and with no `--force` override, hard-refuses
empty, `/`, exactly `$HOME`, the repository root or anything inside it, an ancestor of
either, any path containing `..`, and any existing non-empty directory that is not
already a recognized toolchain install (its own stamp file, or an `env` file plus a
`wasm32-wasi-ghc/` directory). Separately, none of `setup.sh`'s downloads were
integrity-checked at all, despite `autogen.json` carrying an SRI digest for every one of
them (M1, table above) — `install-toolchain.sh` now intercepts every `curl -o` download
via a `PATH`-prepended shim, verifies it against that digest, aborts on mismatch, and
fails closed on any download whose URL is not pinned. Both fixes are detailed in
`briefs/M0-fixes-triage.md`.

### 4.3 Compile and link

```
. ~/.ghc-wasm/env
cd site && wasm32-wasi-cabal build -j2 exe:app
WASM=$(wasm32-wasi-cabal list-bin exe:app | tail -n1)
```

The executable is linked as a **WASI reactor**, not a command, via cabal stanza:

```
if arch(wasm32)
  ghc-options: -no-hs-main -optl-mexec-model=reactor "-optl-Wl,--export=hs_start"
  cpp-options: -DWASM
```

and `Main.hs` carries `foreign export javascript "hs_start" main :: IO ()` under `#ifdef WASM`.
`--export=hs_start` is required because linker dead-code-elimination would otherwise drop it.

Then the JSFFI post-link step, which is the piece that makes Miso work at all:

```
$(wasm32-wasi-ghc --print-libdir)/post-link.mjs --input "$WASM" --output public/ghc_wasm_jsffi.js
```

GHC's wasm backend collects every `foreign import javascript` body *and every `js-sources`
file* into a custom wasm section named `ghc_wasm_jsffi`; `post-link.mjs` extracts that
section into an ES module. Because `miso.cabal` declares `js-sources: js/miso.js` under
`arch(wasm32)`, **Miso's entire 37 KB JS runtime ends up inside `ghc_wasm_jsffi.js`** —
there is no separate `miso.js` to serve, and no ordering problem. This is why the output is
exactly three generated files.

`-j2` (not the config default `$ncpus` = 4) — see risk R4.

### 4.4 Browser boot contract

`site/static/index.js` (vendored shim, all-relative URLs):

```js
import { WASI, OpenFile, File, ConsoleStdout } from "./vendor/browser_wasi_shim/index.js";
import ghc_wasm_jsffi from "./ghc_wasm_jsffi.js";
const wasi = new WASI([], ["GHCRTS=-H64m"], [...fds], { debug: false });
const exports_ = {};
const { instance } = await WebAssembly.instantiateStreaming(fetch("./app.wasm"), {
  wasi_snapshot_preview1: wasi.wasiImport,
  ghc_wasm_jsffi: ghc_wasm_jsffi(exports_),
});
Object.assign(exports_, instance.exports);
wasi.initialize(instance);       // runs _initialize → hs_init; RTS is live
await instance.exports.hs_start();
```

The whole thing is wrapped in try/catch so a boot failure paints a readable message into
`#boot-status` instead of dying silently in the console.

**Testability contract** — fixed now so the app, the loader and the browser driver can be
built in parallel by three different agents, and so M1+ inherits a stable hook:

| Hook | Meaning |
|---|---|
| `window.__SXC1_BOOTED === true` | set by `index.js` after `hs_start()` resolves |
| `window.__SXC1_BOOT_ERROR` | string; set instead if boot threw |
| `#boot-status` | visible before boot; hidden on success, shows the error on failure |
| `#counter-value` | element whose `textContent` is the model integer |
| `#btn-increment`, `#btn-decrement`, `#btn-reset` | the buttons |

Element **ids**, deliberately, not `data-*`: Miso's `data_` helper routes through
`textProp`, and `miso.js`'s prop differ only falls back to `setAttribute` for keys that are
not DOM properties. `id` *is* a DOM property, so `P.id_` provably produces a
`querySelector`-visible hook on both code paths.

### 4.5 Output and hosting

`site/public/` = `site/static/` copied verbatim + `app.wasm` + `ghc_wasm_jsffi.js`.
Everything is relative (`./app.wasm`, `./vendor/...`), so the same bundle works at
`https://user.github.io/repo/`, at a domain root, and from `python3 -m http.server`.
`.nojekyll` is shipped so Pages doesn't eat underscore-prefixed paths. No COOP/COEP headers
are needed (no SharedArrayBuffer), which matters because Pages cannot set headers.

`wasm-opt -all -O2` + `wasm-tools strip` are wired up but **off by default**
(`build-site.sh --optimize`): binaryen is the one step in the chain that can silently
miscompile a GHC-produced module, and M0 must not have its DoD hostage to it. The build
prints both sizes so the README can record the real trade-off. Order is fixed — post-link
*before* strip, because stripping removes the `ghc_wasm_jsffi` custom section.

### 4.6 Verification (`check-site.sh`)

1. Required files exist in `site/public/`.
2. `app.wasm` begins `\0asm\x01\0\0\0`.
3. The resolved Node (see correction below) parses the module and asserts
   `WebAssembly.Module.exports` contains **`hs_start`**, `memory` and `_initialize` — a
   direct check that the reactor/export linker flags took effect.
4. `ghc_wasm_jsffi.js` is non-empty and default-exports a function.
5. `index.html` / `index.js` contain **no** root-absolute URLs and **no** external origins,
   by a syntactic scan.
6. Headless-Chrome run of `browser-check.mjs` against a locally served copy, at the
   origin root.
7. The same headless-Chrome run again, against the bundle served under a non-root
   sub-path (`<tmp>/sub/path/`) — the **authoritative** Pages-subpath deployability check.

**Post-M0 review correction (M9, M5):** item 5's original framing — "the Pages-subpath
and no-CDN invariants, enforced mechanically" — overstated what a four-pattern grep over
double-quoted spellings can prove. `fetch('/app.wasm')` (single-quoted, otherwise
identical) passed that grep while being completely dead once served from a project
sub-path — reproduced, and it scored a full "17/17 checks passed." Item 5 is now
explicitly *advisory* defence-in-depth with a broadened pattern set (single/double
quotes, template literals, `url(/...)`, `new URL('/...')`, protocol-relative `//host`);
item 7 above, the behavioural sub-path run, is the actual enforcement and its failure is
a hard failure of `check-site.sh`. Separately, Node was assumed to be on `PATH` and was
never actually resolved or version-checked by the script; `check-site.sh` now resolves it
explicitly (`$SXC1_NODE` → the toolchain's own private Node → `node` on `PATH`) and
validates it exposes a global `WebSocket` and `WebAssembly` before using it for items 3,
6 and 7 — a fresh clone on a host meeting every *other* documented prerequisite but with
no system Node previously had no working verification path at all.

`browser-check.mjs` speaks the Chrome DevTools Protocol directly over Node's built-in
`WebSocket` — **no npm install, no puppeteer, no playwright**. It launches
`google-chrome --headless=new` into a throwaway profile, navigates, waits for
`__SXC1_BOOTED`, asserts `#counter-value` is `0`, clicks increment → `1`, decrement twice
→ `-1`, and fails on any console error or uncaught exception. It ships a `--self-test`
mode that runs the same assertions against a generated static fixture, so the driver is
provably working *before* the Haskell app exists (that is what lets it be a wave-1 task).

### 4.7 CI

`.github/workflows/site.yml`: cache `~/.ghc-wasm` keyed on the installer hash → install if
cold → cache `site/dist-newstyle` → build → check (GitHub's `ubuntu-latest` image ships
Chrome, so the browser test runs for real in CI) → `upload-pages-artifact`. A second job
deploys to Pages, gated on `refs/heads/main`, so it stays inert until the owner answers
PLAN open question #1 (repo name/visibility).

**Post-M0 review correction (M6, M3):** two claims above did not survive review.
First, "gated on `refs/heads/main`, so it stays inert" was wrong — the `refs/heads/main`
condition alone does not depend on Pages being enabled, so the first push to `main` after
the repository exists would have run `actions/deploy-pages` and failed the whole
workflow. `deploy` is now gated on **both** the `main`-ref condition **and** the
repository variable `vars.ENABLE_PAGES == 'true'`, which is unset (and so the job is
skipped, `main` stays green) until the owner makes the repo public, enables Pages with
the GitHub Actions source, and sets that variable — safe under either outcome of PLAN
open question #1, with no workflow change needed once the decision lands. Second,
"install if cold" no longer describes the toolchain step: the cache key dropped its
`restore-keys` (a partial match after a pin bump would restore a stale toolchain and then
get re-saved under the new key, poisoning the cache) and `install-toolchain.sh` now runs
**unconditionally** — it is idempotent (~1s when the stamp already matches the pin) and
self-heals a stale or mismatched cache restore via a strict stamp comparison instead of
trusting `cache-hit`.

---

## 5. Risks found in research

**R1 — `gitlab.haskell.org` is behind an Anubis proof-of-work wall (verified, high impact).**
Every documented install path for the GHC wasm backend runs
`curl https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta/-/raw/master/bootstrap.sh | sh`.
From this machine that URL returns **HTTP 200 `text/html`** — an Anubis v1.26.2 challenge
page — for both a `curl/7.81.0` UA and a spoofed Chrome UA. The `-/archive/master.tar.gz`
endpoint `bootstrap.sh` itself fetches is walled the same way. Piping that to `sh` executes
a challenge page. *Mitigation:* clone the GitHub read-only mirror at a pinned commit and run
`setup.sh` directly; never pipe a download to a shell. All real bindists live on GitHub
Releases and `downloads.haskell.org`, both reachable. *Residual:* if the mirror lags,
`autogen.json` may point at an older bindist — acceptable, and pinned anyway. **Residual,
updated (post-M0 review, M1):** this plan originally left a second gap unaddressed —
`setup.sh`'s ~785 MB of downloaded bindists were not hash-verified at all, even though
`autogen.json` carries an SRI digest for each of them. That gap is now **closed**, not
residual: `install-toolchain.sh` intercepts every download via a `curl` shim, verifies it
against the pinned SRI digest (SHA-256 or SHA-512), aborts the install on mismatch, and
fails closed on any download whose URL has no pinned digest — see §4.2.

**R2 — the wasm backend is still officially a tech preview.** The GHC 9.15 user's guide
(2026-03) still says "The wasm backend is still a tech preview and not included in the
official bindists yet." We are on unreleased-by-HQ infrastructure by definition; this is
precisely why M0 exists. Mitigated by pinning everything and by the fallback in §6.

**R3 — Miso on wasm *requires* working Template Haskell.** `miso.cabal`'s `arch(wasm32)`
branch depends on `template-haskell` and `ffi/wasm/Miso/DSL/FFI.hs`,
`Miso/DSL/TH.hs`, `Miso/DSL/TH/File.hs` all enable `TemplateHaskell` and evaluate real
splices. TH under the wasm cross-compiler runs the external interpreter through the
bundled Node. This **rules out flavours 9.6 and 9.8** (they get `cabal.legacy.config`, not
`cabal.th.config`) and makes the bundled Node a hard runtime dependency of the *build*.
Flavour 9.14 is correct and CI-tested upstream.

**R4 — memory.** `ghc-wasm-meta` writes `jobs: $ncpus` into its cabal config: 4 concurrent
GHC processes against 3.9 GiB available and only 2 GiB of swap. *Mitigation:* build with
`-j2`, expose `SXC1_JOBS` to drop to 1, and compile the app at `-O1` rather than the `-O2
-fspecialise-aggressively` upstream's sampler uses. The dependency closure is tiny — every
library Miso needs is a boot library already in the bindist, so `miso` itself is the only
package actually compiled from source.

**R5 — upstream's loader is unshippable as-is.** Miso's reference `static/index.js` imports
the WASI shim **from `cdn.jsdelivr.net`** and uses **root-absolute** `"/index.js"` /
`"/app.wasm"`. On a GitHub Pages *project* site (`user.github.io/repo/`) the absolute paths
404, and the CDN import is a third-party runtime dependency on a site that is otherwise
fully static. *Mitigation:* vendor the shim (checksum-verified, licences included) and use
`./`-relative URLs everywhere, enforced by a `check-site.sh` grep.

**R6 — upstream's docs and CI are Nix-only.** `miso-sampler`'s README is
`nix develop .#wasm` throughout; the non-Nix path exists only as an under-documented
`ghcup-build` Makefile target. We are on a path upstream tests less. *Mitigation:* the
`x86_64-linux-ubuntu-9.14` CI job in `ghc-wasm-meta` *is* non-Nix-ish and does run
`tests/miso.sh`; and we pin, so a regression upstream cannot reach us.

**R7 — solver vs. boot libraries.** Without help, cabal may try to build a *newer* `text`
or `containers` from Hackage for wasm32 instead of using the bindist's. *Mitigation:* copy
`ghc-wasm-meta`'s technique — `constraints: <boot pkg> installed` in `site/cabal.project` —
plus defensive `allow-newer: all:base, all:template-haskell` (harmless; our bound analysis
says neither is needed).

**R8 — binaryen may break GHC output.** `wasm-opt` on a module using tail calls, reference
types and exception handling is the least-guaranteed step. *Mitigation:* optimisation is
opt-in, and `check-site.sh` re-validates exports on whatever artifact is produced.

**R9 — install cost.** ~785 MB download, 15–40 min, several GB on disk. *Mitigation:*
idempotent installer with `--check`; CI caches `~/.ghc-wasm`. **Note for implementers: the
install will exceed a 10-minute foreground command timeout — it must be run as a background
job and polled.**

**R10 — no GitHub repo yet.** PLAN open question #1 is unanswered, so the Pages deploy path
cannot be exercised end-to-end in M0. *Mitigation:* the workflow's build+check job is
unconditional and fully testable; only the `deploy` job is gated. The GitHub Pages claim
that M0 can honestly make is "the output is a static directory with no absolute URLs, no
external origins, no server requirements, and a `.nojekyll`" — all of which `check-site.sh`
proves.

---

## 6. Fallback recommendation

**If the WASM backend proves unworkable, go to Miso on the GHC JavaScript backend — not to
jsaddle.**

PLAN.md lists "the jsaddle route" as the fallback. Research says that is not a shipping
fallback: `jsaddle-warp` is a *WebSocket server* driving a browser, which violates the
non-negotiable "no server component / fully static" constraint. `jsaddle-wasm` sits on top
of the very backend we would be retreating from. jsaddle's real value here is as a
*development* aid (run the app under a native GHC with a live browser bridge), not as a
deployment target.

The right escape hatch is `arch(javascript)` — GHC's JS backend, which Miso 1.12 supports
first-class (`if arch(javascript) || impl(ghcjs)` → `ffi/js`, `ghcjs-base`, the same
`js-sources: js/miso.js`), and which upstream's own Makefile exercises via `make js`. It
still produces a single static bundle for GitHub Pages, and — crucially — **the application
source does not change**. Only the compiler and the build script do.

So the plan bakes the hatch in now, at near-zero cost: `sxc1-trainer.cabal` carries the
`if arch(javascript)` stanza from day one, `Main.hs` guards the wasm-only foreign export
behind `#ifdef WASM`, and all styling/markup lives outside Haskell. Switching backends is
then a `scripts/build-site.sh` change plus installing `javascript-unknown-ghcjs-ghc`
(which needs emsdk — the reason it is a fallback and not the default).

Ordered escape ladder:

1. **WASM backend, flavour 9.14** (this plan).
2. **WASM backend, different flavour** — `FLAVOUR=9.12` or `FLAVOUR=gmp`; one env var in
   `install-toolchain.sh`. Try this first for any *compiler* failure, before abandoning wasm.
3. **Miso on the GHC JS backend** — same source, emsdk + `javascript-unknown-ghcjs-ghc`,
   `cabal build --with-ghc=javascript-unknown-ghcjs-ghc`, ship `all.js`. Recommended fallback.
4. **jsaddle** — development convenience only; do not plan to ship it.
5. **Hakyll + hand-written JS** — requires owner approval per PLAN; last resort.

---

## 7. What I will check at sign-off

Beyond the per-task `acceptance_checks` in the manifest, I will personally verify:

1. `~/.ghc-wasm/env` exists and `wasm32-wasi-ghc --numeric-version` reports a 9.14.x, and
   the installer's stamp file records the pinned `ghc-wasm-meta` commit.
2. **No script anywhere pipes a download into a shell**, and no file references
   `gitlab.haskell.org` as a download source.
3. `site/public/` contains exactly the expected set; `app.wasm` exports `hs_start`.
4. `grep -RnE 'https?://' site/public/index.html site/public/index.js` is empty, and no
   root-absolute URL appears in either.
5. `./scripts/check-site.sh` exits 0 on a clean tree, and the browser step really drove
   Chrome (its output names the browser and the assertions, not a skip).
6. A deliberately broken build is *caught*: I will corrupt `site/public/app.wasm` and
   confirm `check-site.sh` fails. A verification script that cannot fail is not a check.
7. `rm -rf site/public site/dist-newstyle && ./scripts/build-site.sh` reproduces the site.
8. README's commands are literally the ones that work, in order, from a fresh clone.
9. Versions in README match §3 of this plan exactly.

---

## 8. Task manifest — waves

`briefs/M0-manifest.json`, 6 tasks, disjoint `owned_paths`:

| Wave | Task | Owns |
|---|---|---|
| 1 | `install-toolchain` | `scripts/install-toolchain.sh` |
| 1 | `static-shell` | `site/static/**` |
| 1 | `browser-check-harness` | `scripts/browser-check.mjs`, `scripts/serve-site.sh` |
| 2 | `miso-app-and-build` | `site/app/**`, `site/sxc1-trainer.cabal`, `site/cabal.project`, `site/.gitignore`, `scripts/build-site.sh` |
| 3 | `site-verification-and-readme` | `scripts/check-site.sh`, `README.md`, `.gitignore` |
| 3 | `ci-workflow` | `.github/workflows/site.yml` |

Wave 2 is a single task on purpose: the cabal files, `Main.hs` and `build-site.sh` are one
compile-fix loop and cannot be split across agents without shared ownership. Wave 1's three
tasks are genuinely independent — and each is independently *verifiable* (the browser
driver via `--self-test`, the static shell via checksum + ESM parse + invariant greps),
which is what keeps the critical path honest rather than deferring all risk to wave 2.

---

## 9. Explicitly out of scope for M0

Routing, content loading, `translations/` ingestion, localStorage, WebMIDI, exercise
schema, mobile/a11y polish, the JS-backend build, and any Casio content. M0 ships a counter.
