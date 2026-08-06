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
- `git`, `curl`, `tar`, `xz`, `unzip`, `unzstd` (zstd), `jq`, `make`, a C compiler, `sed`.
- `python3`, for the dev server.
- Google Chrome or Chromium, for the automated headless-browser check.
- About 12 GiB of free disk space.

No system-wide Haskell installation is needed or created — everything the toolchain
installs lands under `$HOME/.ghc-wasm`, and nothing outside that directory is touched.

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
`setup.sh` directly — git verifies the content by commit hash, so there is no separate
checksum file to maintain. Every actual binary distribution `setup.sh` fetches lives on
GitHub Releases or `downloads.haskell.org`, both reachable from this machine; only
`gitlab.haskell.org` is walled off. No script in this repository ever pipes a downloaded
file into a shell.

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
a domain root, or offline from a local directory.

## Deployment

`.github/workflows/site.yml` builds the site and runs `check-site.sh` on every push, then
uploads `site/public/` as a GitHub Pages artifact — nothing built is ever committed to
the repository. Deploying that artifact still requires GitHub Pages to be **enabled** on
the repository, which is an open question with the owner (see `PLAN.md`).

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

## Design rationale

See [`briefs/M0-plan.md`](briefs/M0-plan.md) for the full design rationale, the risks
considered, and the fallback plan (Miso on GHC's JavaScript backend) if the WebAssembly
backend ever proves unworkable.
