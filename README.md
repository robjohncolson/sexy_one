# SXC-1 Trainer

An interactive English-language training course for the [Casio SXC-1](https://www.casio.com/)
portable standalone sampler. The app is a Haskell/[Miso](https://haskell-miso.org/)
application compiled to WebAssembly and served as static files — no server component.
This is an unofficial fan project and is **not affiliated with Casio**.

## Status

**M0 (toolchain spike).** The site currently ships a counter page whose only job is to
prove the build pipeline end to end: Haskell → GHC's WebAssembly backend → a static
bundle that boots in a real browser. No course content yet — see
[`PLAN.md`](PLAN.md) for the full milestone roadmap.

## Prerequisites

- Linux x86\_64 (aarch64-linux and macOS are also supported by the toolchain, but only
  x86\_64 Linux has been exercised for M0).
- `git`, `curl`, `tar`, `xz`, `unzip`, `unzstd` (zstd), `jq`, `make`, a C compiler, `sed`,
  `realpath`.
- Node.js 22+ is required for the global `WebSocket` that `scripts/browser-check.mjs`
  (the headless-browser driver `check-site.sh` calls) depends on; M0 was validated on
  Node 24. You do not need to install this yourself: `./scripts/install-toolchain.sh`
  also lays down a private Node under `$HOME/.ghc-wasm/nodejs/bin/node`, and
  `check-site.sh` resolves a usable Node in the order `$SXC1_NODE` → that private Node →
  `node` on `PATH`, so the toolchain's own Node is used automatically if nothing better
  qualifies. Set `SXC1_NODE=/path/to/node` to force a specific binary.
- `python3`, for the dev server.
- Google Chrome or Chromium, for the automated headless-browser check.
- About 12 GiB of free disk space.

No system-wide Haskell installation is needed or created — everything the toolchain
installs lands under `$HOME/.ghc-wasm` by default. That default is overridable with
`GHC_WASM_PREFIX`, and a careless value there would be genuinely dangerous: upstream's
`setup.sh` begins with `rm -rf "$PREFIX"`. `install-toolchain.sh` refuses unsafe values
of `GHC_WASM_PREFIX` **before touching the network** — empty, `/`, exactly `$HOME`, the
repository root or anything inside it, an ancestor of either, a path containing `..`, or
an *existing* non-empty directory that is not already one of its own toolchain installs
(recognised by its stamp file, or by having both an `env` file and a `wasm32-wasi-ghc/`
directory). None of these refusals has a `--force` override — `--force` only ever means
"reinstall over an existing toolchain," never "wipe whatever happens to be at this path."

## Build

```sh
git clone <repo> && cd casio-sxc1
./scripts/install-toolchain.sh    # one time; ~785 MB download, 15-40 min
./scripts/build-site.sh           # -> site/public/
./scripts/check-site.sh           # structural checks + headless browser test
./scripts/serve-site.sh           # http://127.0.0.1:8123/
```

Every command above has been run, in this order, as part of building and verifying M0.

## Pinned versions

| Component | Pin |
|---|---|
| `ghc-wasm-meta` | GitHub mirror `haskell-wasm/ghc-wasm-meta` @ commit [`c75985a1b58fb0376eea9149ba5c7b933b3c7455`](https://github.com/haskell-wasm/ghc-wasm-meta/commit/c75985a1b58fb0376eea9149ba5c7b933b3c7455) |
| GHC (wasm backend) | `FLAVOUR=9.14` — resolves to **9.14.1.20260731** (observed on this machine) |
| Boot libraries | base 4.22.0.0, template-haskell 2.24.0.0, text 2.1.3, bytestring 0.12.2.0, containers 0.8, mtl 2.3.1, transformers 0.6.1.2, ghc-experimental 9.1401.0 |
| Miso | `miso == 1.12.0.0` from Hackage, with `index-state: 2026-08-01T00:00:00Z` |
| cabal-install | 3.14.2.0 (shipped by `ghc-wasm-meta`) |
| WASI browser shim | [`@bjorn3/browser_wasi_shim`](https://github.com/bjorn3/browser_wasi_shim) 0.3.0, vendored under `site/static/vendor/` |
| Toolchain root | `$HOME/.ghc-wasm` (activate with `. "$HOME/.ghc-wasm/env"`) |

These match `briefs/M0-plan.md` exactly; that document is the source of truth if this
table and the plan ever drift.

## Why not the documented one-liner

The upstream-documented install for `ghc-wasm-meta` is:

```sh
curl https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta/-/raw/master/bootstrap.sh | sh
```

We do not use it. `gitlab.haskell.org` sits behind an Anubis proof-of-work anti-bot wall:
from this machine that URL returns HTTP 200 with `Content-Type: text/html` — an HTML
challenge page, not a script — for both a plain `curl` user-agent and a spoofed browser
user-agent. Piping that response to `sh` would execute a web page, not an installer.

Instead, `scripts/install-toolchain.sh` clones the read-only GitHub mirror
(`github.com/haskell-wasm/ghc-wasm-meta`) at the pinned commit above and runs its
`setup.sh` directly — git verifies the content of that *source* tree by commit hash.
That is source integrity, not bindist integrity: the commit hash says nothing about the
~785 MB of GHC wasm bindist, wasi-sdk, libffi, Node, binaryen and cabal binaries that
`setup.sh` goes on to download afterwards. Those are verified separately. The pinned
clone's own `autogen.json` carries an SRI digest (`sha256-…`/`sha512-…`) for every one of
them, and `install-toolchain.sh` prepends a `curl` shim to `setup.sh`'s `PATH` that
intercepts each `-o <file>` download, looks its URL up in `autogen.json`, and compares
the file's SHA-256 or SHA-512 against the pinned digest — aborting the install on any
mismatch, and **failing closed** (also aborting) if a download's URL has no pinned digest
at all. The installer's stamp file records how many downloads were checked this way as
`sri_verified_downloads=N` (7 on a full install), so the control is auditable after the
fact rather than merely asserted; `./scripts/install-toolchain.sh --verify-sri-selftest`
regression-tests the digest comparator itself in about a second. Every actual binary
distribution `setup.sh` fetches lives on GitHub Releases or `downloads.haskell.org`, both
reachable from this machine; only `gitlab.haskell.org` is walled off. No script in this
repository ever pipes a downloaded file into a shell.

## Repository layout

```
casio-sxc1/
├── README.md                    this file
├── PLAN.md                      master project plan and milestone roadmap
├── briefs/                      per-milestone design briefs and task manifests
├── scripts/
│   ├── install-toolchain.sh     one-time GHC-wasm toolchain install ($HOME/.ghc-wasm)
│   ├── build-site.sh            site/app + site/static -> site/public/
│   ├── serve-site.sh            python3 -m http.server on 127.0.0.1
│   ├── check-site.sh            structural checks + headless-browser smoke test
│   ├── browser-check.mjs        the zero-npm-deps CDP driver check-site.sh calls
│   └── extract-pages.sh         manual PDF -> page image/text extraction
├── site/
│   ├── sxc1-trainer.cabal       the `app` executable (wasm32 + javascript stanzas)
│   ├── cabal.project            index-state pin, boot-library constraints
│   ├── app/                     Haskell/Miso source
│   ├── static/                  HTML shell, boot loader, vendored WASI shim
│   └── public/                  build output (gitignored, never committed)
├── manuals/                     original Japanese Casio PDFs (source material)
├── translations/                English translations of the manuals
└── .github/workflows/           CI: build, check, and (once enabled) deploy to Pages
```

## How it works

`wasm32-wasi-cabal` builds `site/app/Main.hs` against Miso into a WASI *reactor* module
(not a command) using `-optl-mexec-model=reactor` plus a linker `--export=hs_start`, so
the module can be instantiated and driven from JavaScript instead of just run once and
exiting. GHC's wasm backend then packs every `foreign import javascript` body — and,
because `miso.cabal` declares `js-sources` for `arch(wasm32)`, Miso's own JS runtime too
— into a custom wasm section that `post-link.mjs` extracts into `ghc_wasm_jsffi.js`.
`site/static/` (the HTML shell and boot loader) is copied verbatim over the output
directory, then `app.wasm` and `ghc_wasm_jsffi.js` are added alongside it. In the
browser, `index.js` instantiates `app.wasm` against a vendored WASI shim and the
generated JSFFI import object, runs `_initialize` to start the Haskell RTS, then calls
`hs_start()` to mount the Miso app. Every URL in the output is relative (`./app.wasm`,
never `/app.wasm`), so the same bundle works unmodified at any GitHub Pages sub-path, at
a domain root, or offline when served locally (`./scripts/serve-site.sh`).
`check-site.sh` proves the sub-path claim behaviourally, not just syntactically: it
copies the built bundle under a non-root prefix, serves it there, and requires the full
headless-browser check to pass against that sub-path — a bundle that only works from the
origin root now fails this check even if it slips past the (advisory) grep for absolute
URLs. The bundle does **not** work opened directly as a `file://` URL, though:
`index.js` is an ES module that imports sibling modules and `fetch`es `app.wasm`, and
browsers give `file://` pages an opaque origin that blocks both.

## Deployment

`.github/workflows/site.yml` builds the site and runs `check-site.sh` on every push and
pull request, then uploads `site/public/` as a GitHub Pages artifact — nothing built is
ever committed to the repository. `check-site.sh` prints a final machine-readable marker,
`check-site: result=complete` when every check (including both browser runs — root and
sub-path) actually executed, or `check-site: result=structural-only` if the browser axis
was skipped (`--skip-browser` / `SXC1_SKIP_BROWSER=1`); CI fails the build unless it sees
`result=complete`, so a silently skipped browser axis can never pass as a full gate.

The `deploy` job that publishes to GitHub Pages is separate from `build`/`check` and
stays genuinely inert — it does not run at all — until the repository variable
`ENABLE_PAGES` is explicitly set to `true`. Enabling it needs three things from the
owner, none of which have happened yet (open question in `PLAN.md`): make the repository
public (GitHub Pages requires a public repo on a free account), enable Pages with the
"GitHub Actions" source, and set the `ENABLE_PAGES` repository variable to `true`. Until
then, every push still builds and verifies the site on CI — only the publish step is
gated.

## Measured figures

Measured on this machine (Linux x86\_64, 4 cores, 7.6 GiB RAM), one run each:

| Metric | Value |
|---|---|
| Cold build (`site/dist-newstyle` and the local Miso build absent) | 29s |
| Warm build (`site/dist-newstyle` cache hit, nothing changed) | <1s |
| `app.wasm`, default build | 2,856,541 bytes raw / 644,452 bytes gzipped |
| `app.wasm`, `./scripts/build-site.sh --optimize` (`wasm-opt -O2` + strip) | 1,680,570 bytes raw / 528,716 bytes gzipped |
| `ghc_wasm_jsffi.js` | 48,383 bytes raw / 10,231 bytes gzipped |

`--optimize` is off by default: `wasm-opt` is the one step in this pipeline that can
silently miscompile GHC's output, so M0's definition of done does not depend on it.
`check-site.sh` re-validates `app.wasm`'s exports regardless of which build produced it.

## Troubleshooting

- **Build gets OOM-killed** — set `SXC1_JOBS=1` before `./scripts/build-site.sh` (the
  default `SXC1_JOBS=2` already undercuts the toolchain's usual 4-way default to leave
  headroom on machines with limited RAM/swap).
- **No browser found / want to skip the browser test** — set `SXC1_BROWSER` to a browser
  executable path, or pass `./scripts/check-site.sh --skip-browser` (equivalently,
  `SXC1_SKIP_BROWSER=1`).
- **Need to reinstall the toolchain** — `./scripts/install-toolchain.sh --force`.
- **`wasm32-wasi-ghc: command not found`** — the toolchain env script isn't sourced in
  your shell: run `. "$HOME/.ghc-wasm/env"`.
- **`check-site: no usable Node.js found` / `SXC1_NODE=... is not a usable Node.js`** —
  `check-site.sh` needs Node 22+ with a global `WebSocket` (validated on Node 24), tried
  in the order `$SXC1_NODE` → `$HOME/.ghc-wasm/nodejs/bin/node` → `node` on `PATH`. Run
  `./scripts/install-toolchain.sh` if the private toolchain Node is missing, upgrade
  whatever Node is on `PATH`, or set `SXC1_NODE=/path/to/node` explicitly.

## Design rationale

See [`briefs/M0-plan.md`](briefs/M0-plan.md) for the full design rationale, the risks
considered, and the fallback plan (Miso on GHC's JavaScript backend) if the WebAssembly
backend ever proves unworkable.
