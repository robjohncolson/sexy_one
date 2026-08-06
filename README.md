# SXC-1 Trainer

An interactive English-language training course for the [Casio SXC-1](https://www.casio.com/)
portable standalone sampler. The app is a Haskell/[Miso](https://haskell-miso.org/)
application compiled to WebAssembly and served as static files — no server component.
This is an unofficial fan project and is **not affiliated with Casio**.

## Status

**M2 (exercise engine).** The site is now a reader *and* a trainer. M1's manual reader
is unchanged and fully intact (see below); layered on top of it, chapters can now carry
`.ex.md` exercise decks in three kinds: **quiz/flashcard** (choice or free-recall
prompts, graded in the browser), **guided device drill** (a numbered sequence of
on-device steps ending in a self-check), and **timed reference lookup** (find the answer
on a manual page against the clock, without the page number given away up front). The
seed content set — 4 decks, 16 exercises, 24 prompts (7 quiz / 4 drill / 5 lookup),
drawn from `content/exercise-inventory.md`'s Preparation and Pad-play chapters —
exercises every part of the engine end to end. See [`PLAN.md`](PLAN.md) for the full
milestone roadmap, and [`briefs/M2-plan.md`](briefs/M2-plan.md) with
[`briefs/M2-plan-amendments.md`](briefs/M2-plan-amendments.md) for the design this
milestone implements — the amendments correct the original plan's parser-reuse
assumptions against the real, already-committed M1 code, and win wherever the two
disagree.

Two things this milestone deliberately leaves undone, both already seamed for later
milestones rather than left as open design questions: **progress is not persisted** —
an exercise result lives only in the running page's in-memory state and is gone on
reload (M3 binds a `ProgressSink` to `localStorage` with spaced repetition); and
**device verification is not implemented** — a drill's self-check is confirmed by the
learner clicking a button, not by reading the SXC-1 itself over WebMIDI (M4).
`site/app/Main.hs` already wires an explicit no-op `DeviceVerifier` (`noDeviceVerifier`)
so M4 has a seam to fill rather than a design to invent; no WebMIDI call and no device
permission request exists anywhere in this milestone's code.

`app.wasm` measures **978,969 bytes gzipped** (4,694,642 bytes raw) against the
`check-site.sh`-enforced, unchanged 1,000,000-byte ceiling — about 21 KB of headroom,
and that headroom is deliberately thin. It is a considered trade, not an oversight: the
validating parser (`SXC1.Exercise.Parse`/`SXC1.Exercise.Lint`) that `exe:app` currently
links to run the exercise engine costs roughly 95 KB of that gzipped total on its own,
and most of what it validates only `exe:exercise-check` actually needs at CI/build time,
not in the browser. Before any change to the 1,000,000-byte ceiling itself is
considered, M3 opens with a size-reduction task: split `parseDeck` (a pure structural
reader) from `validateDeck` (linting, citations, inventory binding) so `exe:app` links
only the reader.

## Prerequisites

- Linux x86\_64 (aarch64-linux and macOS are also supported by the toolchain, but only
  x86\_64 Linux has been exercised so far).
- `git`, `curl`, `tar`, `xz`, `unzip`, `unzstd` (zstd), `jq`, `make`, a C compiler, `sed`,
  `realpath`.
- Node.js 22+ is required for the global `WebSocket` that `scripts/browser-check.mjs`
  (the headless-browser driver `check-site.sh` calls) depends on; validated on Node 24
  and Node 26. You do not need to install this yourself: `./scripts/install-toolchain.sh`
  also lays down a private Node under `$HOME/.ghc-wasm/nodejs/bin/node`, and
  `check-site.sh` resolves a usable Node in the order `$SXC1_NODE` → that private Node →
  `node` on `PATH`, so the toolchain's own Node is used automatically if nothing better
  qualifies. Set `SXC1_NODE=/path/to/node` to force a specific binary.
- `python3`, for the dev server and for `check-site.sh`'s independent content re-check.
- Google Chrome or Chromium, for the automated headless-browser check.
- To *regenerate* the committed page images (not needed to build or run the site):
  `poppler-utils` (`pdftoppm`, `pdfinfo`) and either `cwebp` or Python 3 with Pillow. See
  [Original page images](#original-page-images) below.
- About 12 GiB of free disk space.

No system-wide Haskell installation is needed or created — everything the toolchain
installs lands under `$HOME/.ghc-wasm` by default. That default is overridable with
`GHC_WASM_PREFIX`, and a careless value there would be genuinely dangerous: upstream's
`setup.sh` begins with `rm -rf "$PREFIX"`. `install-toolchain.sh` refuses unsafe values
of `GHC_WASM_PREFIX` **before touching the network** — empty, `/`, exactly `$HOME`, the
repository root or anything inside it, an ancestor of either, or a path containing `..`;
none of these has a `--force` override. An *existing* non-empty directory is then
classified: a validated toolchain install (recognised by its stamp file) is always
accepted; a directory that merely looks like an interrupted install (an `env` file plus
a `wasm32-wasi-ghc/` directory, but no valid stamp) is refused unless `--force`, which
prints exactly what it is about to remove; anything else is refused always, with no
`--force` override.

## Build

```sh
git clone <repo> && cd casio-sxc1
./scripts/install-toolchain.sh    # one time; ~785 MB download, 15-40 min
./scripts/build-site.sh           # -> site/public/
./scripts/check-site.sh           # structural + content + headless browser checks
./scripts/serve-site.sh           # http://127.0.0.1:8123/
```

Every command above has been run, in this order, on this machine, as part of building
and verifying M1: `install-toolchain.sh` recognised the already-installed toolchain and
returned in well under a second; a from-scratch `site/dist-newstyle` build (package
store still warm from the toolchain install) took 10 s; `check-site.sh` ran all 37
checks — including both the origin-root and GitHub-Pages-sub-path browser sweeps of all
108 page routes — in under 30 s and printed `check-site: result=complete`; and
`serve-site.sh` served `site/public/index.html` over plain HTTP with a `200`.

## How the manuals get into the app

`translations/*.md` are embedded into the wasm **at compile time** by Template Haskell
(`SXC1.Content.Embed.embedUtf8File`, spliced once per document in `SXC1.Content.Corpus`)
and then parsed **lazily, at runtime**, by the miso-free `sxc1-content` library
(`site/src/SXC1/`) — no fetch, no JSON, works offline and at any GitHub Pages sub-path.
`site/sxc1-trainer.cabal` declares:

```
extra-source-files: ../translations/*.md
```

This line is load-bearing, not decorative: `addDependentFile` alone makes GHC recompile
when a translation changes, but only if cabal decides to *invoke* GHC in the first
place, and cabal's own staleness check has no idea a Haskell module depends on a file
three directories away unless `extra-source-files` tells it so. Without this line,
editing a translation and re-running `wasm32-wasi-cabal build` does nothing — cabal
reports the package up to date and never calls GHC. With it, cabal notices the mtime
change and GHC reports `[../translations/guide-book.md changed]` before recompiling.
So the whole content-editing workflow is: edit a file under `translations/`, re-run
`./scripts/build-site.sh`.

That line does produce one expected, harmless cabal warning, printed once per component
configured (the library, `exe:app` and `exe:content-check` — three times per build):

```
Warning: [relative-path-outside] 'extra-source-files: ../translations/*.md' is
a relative path outside of the source tree. This will not work when generating
a tarball with 'sdist'.
```

`cabal sdist` packages a component's declared sources into a distributable tarball and
refuses to reach outside the package directory (`site/`) while doing it. This project
never runs `cabal sdist` — there is nothing to publish to Hackage — so the warning is
inert; it is not worked around.

## Course content

`translations/*.md` remain the single source of truth for everything the app says —
exercises don't restate manual text, they point at it. An exercise deck is one
`.ex.md` file under `content/exercises/`, and every file there must be listed in
`content/exercises/INDEX` (a plain filename-per-line list that controls reading order —
this is *not* just "sorted by filename"; both directions are checked, so a file missing
from `INDEX`, or an `INDEX` entry with no matching file, is a validation error). See
[`content/EXERCISE-FORMAT.md`](content/EXERCISE-FORMAT.md) for the full grammar — it is
the only document a content author needs, written to assume no Haskell knowledge and no
access to the validator's source.

Every exercise cites at least one manual page **by number and by a verbatim anchor
phrase**, e.g. `cite: guide-book 15 "First, select BANK 1"` — the validator checks that
the phrase actually occurs (whitespace-collapsed) on that numbered page of the named
translation, not just that the page number is in range. An exercise's `id` must also be
one of the ids in [`content/exercise-inventory.md`](content/exercise-inventory.md), the
committed 440-id master plan every exercise id is drawn from (`q-`/`d-`/`l-` prefixed for
quiz/drill/lookup, chapter-numbered, sequenced). Ids in that inventory are permanent —
never renumbered, only retired-with-a-tombstone — because M3 keys a learner's persisted
progress to them; an id that moved out from under a learner's history would silently
orphan it.

Exercise decks are embedded into the wasm **at compile time**, the same way the manuals
are (`site/app/Exercises/Embed.hs`, one Template-Haskell splice per deck file, filtered
and ordered by the compiled-in `INDEX`), so — exactly as with a translation — the whole
content-editing workflow is: edit a `.ex.md` file (or `INDEX`), re-run
`./scripts/build-site.sh`.

## Validating exercise content

`exe:exercise-check` is `site/test/CheckExercises.hs`, built and run exactly like
`exe:content-check` above: a wasm32-wasi *command* module, resolved with
`wasm32-wasi-cabal list-bin` and run on the host by `wasm-run.mjs`. From the repository
root:

```sh
. "$HOME/.ghc-wasm/env"
cd site
wasm32-wasi-cabal build exe:exercise-check
BIN="$(wasm32-wasi-cabal list-bin exe:exercise-check | tail -1)"

wasm-run.mjs "$BIN" --content-dir ../content --translations-dir ../translations
                                        # validates the real, working-tree content
wasm-run.mjs "$BIN" --self-test        # the validator's own internal test suite
wasm-run.mjs "$BIN" --fixtures ../content/fixtures
                                        # runs it against the falsifiability corpus below
wasm-run.mjs "$BIN" --list-codes       # every issue code the validator can raise, tab-
                                        # separated with its class (file/dir/seam)
```

Every one of those has been run, in this order, from this repository's root, on this
machine: the real-content run and `--self-test` (101/101 checks) both exit 0 with zero
issues, `--fixtures` reports `51/51 fixtures passed`, and `--list-codes` prints 48 codes.
`./scripts/check-site.sh` runs the same validator (plus everything below) as part of its
own gate — this is the escape hatch for checking content alone, without a full build and
browser sweep, while iterating on a deck.

**Why this gate cannot pass vacuously.** A validator that never fires its own checks, or
that a fixture-free corpus quietly "validates" by never actually exercising a rule, is
worse than no validator — it would pass while checking nothing. Three things close that
gap:

1. **The fixture corpus** (`content/fixtures/`) — one small file or content-root per
   issue code, named for the exact one defect it contains (`E-CITE-PAGE--out-of-range.ex.md`,
   …), plus `OK--*` fixtures that must be *accepted* (the control proving the validator
   hasn't degenerated into rejecting everything).
2. **The coverage invariant** — every issue code `exercise-check --list-codes` can print
   must have at least one matching fixture; a validation rule with no fixture demonstrating
   it fail is itself a failing check. The one code that cannot occur from any real file on
   disk, `E-BLOCK-UNPARSED` (the markdown-parser seam), is instead proven live by
   `--self-test`, and `check-site.sh` asserts it is the *only* code in that "seam" class —
   so nothing can quietly hide behind that exemption.
3. **Three-way agreement**, mirroring the manual reader's own check above: the real
   Haskell validator (`exe:exercise-check --json`), an independent `python3`
   re-derivation of the same deck/exercise/citation counts straight from
   `content/exercises/*.ex.md` (never from the Haskell side), and the running app's
   embedded copy read out of `#sxc1-exercise-stats` in the live DOM must all agree, or
   `check-site.sh` fails red instead of silently shipping a stale or miscounted build.

## Verification

`check-site.sh` computes the same corpus statistics (character/line/page counts,
heading/table/figure counts, section and subsection counts, PART titles, …) **three
independent ways** and fails if any two disagree:

1. **The real Haskell parser** — `exe:content-check`, a wasm32-wasi *command* module
   (not the reactor-model `exe:app`) run on the host by `wasm-run.mjs`, over the
   TH-embedded corpus.
2. **An independent regex sweep** — an embedded `python3` snippet that recomputes the
   same numbers straight from `translations/*.md` by regex, without going anywhere near
   the Haskell parser.
3. **The running app** — the built `site/public/` served over HTTP, driven headlessly,
   reading `#sxc1-content-stats` (a `<div hidden>` whose `textContent` is the same JSON
   shape) out of the live DOM.

This is what catches a *stale build*: if a translation is edited but the site isn't
rebuilt, the running app still serves the old numbers while the regex sweep (which reads
the file directly) sees the new ones, and check 11 goes red instead of silently deploying
stale content. The same captured JSON is also handed to the browser driver via
`--expect-json`, so the headless-browser assertions are checked against numbers derived
from the source of truth rather than constants baked into the test harness.

## Reading the manuals

Every route is a hash fragment, hand-parsed by a pure `parseRoute`/`renderRoute` pair —
there is no server-side router:

| Route | Renders |
|---|---|
| `#/` | Home — a card per manual |
| `#/m/<slug>` | That manual's table of contents (grouped by front matter / PART / appendix) |
| `#/m/<slug>/p/<n>` | Page `n` of that manual |
| `#/m/<slug>/p/<n>/ja` | Page `n`, with the original-Japanese-page panel already open |

`<slug>` is one of `guide-book`, `startup-guide`, `midi`, `oss`. Hash routing was chosen
because GitHub Pages serves static files with no server-side rewrites — a path-based
route like `/m/guide-book/p/17` would 404 on a hard refresh or a direct link unless the
server rewrote every unknown path to `index.html`, which Pages doesn't do — and because
the project's eventual Pages sub-path is not yet decided (`PLAN.md` open question). A
hash fragment is never sent to the server at all, so the same bundle works unmodified at
the domain root, at any sub-path, or served locally. Every route is therefore a
shareable deep link: `check-site.sh`'s browser sweep loads all 108 page routes — plus the
`/ja` variant — directly, cold, with no prior navigation, and requires each one to render
correctly, including landing already in the JA-visible state when the URL says so.

## Original page images

<a id="original-page-images"></a>

108 WebP renders of the original Japanese pages are committed under
`site/static/pages/<slug>/page-NN.webp` — one per page across all four manuals
(guide-book 1–71, startup-guide 1–15, midi 1–6, oss 1–16) — for the reader's "Show
original page (JA)" toggle. They are regenerated from the committed source PDFs with:

```sh
./scripts/render-page-images.sh              # all four documents
./scripts/render-page-images.sh --slug midi  # just one
```

which needs `poppler-utils` (`pdftoppm`) and either `cwebp` or Python 3 + Pillow — **not**
needed to build or serve the site, only to re-render after a source PDF changes.
`build-site.sh` itself needs no image tooling at all: the WebP files are ordinary
committed static assets, copied into `site/public/` by the same `cp -R site/static/.`
step that has copied the HTML shell since M0.

The measured trade-off that motivated committing WebP instead of PNG: `pdftoppm -r 150`
renders of all 108 pages run to **34.4 MB** as PNG (this scratch intermediate is
gitignored under `manuals/pages/` and deleted by the script after encoding, unless
`--keep-png`). The script encodes each page as WebP two ways — lossy quality 88 and
lossless — and keeps whichever is smaller, self-tuning between the two rather than
picking one setting for every document. That was projected at ≈10.4 MB across all 108
pages; the actual committed set, measured directly (`du -sh site/static/pages`,
confirmed independently by `check-site.sh` check 9's exact byte sum), comes in a bit
lighter at **9,375,040 bytes (≈9.4 MB)** — better than projected because this machine has
no `cwebp` and the images were encoded with Python 3.10 + Pillow 9.0.1's WebP encoder
instead. The largest single page is well under the 300 KB ceiling `check-site.sh` checks
for. Because the images are `loading="lazy"` inside a panel that only renders once the
reader clicks the toggle, none of this is fetched by a visitor who never opens an
original page.

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

These match `briefs/M0-plan.md` exactly (M1 pins nothing new — no new dependency was
added, only two new cabal targets against the same toolchain and Miso version); that
document is the source of truth if this table and the plan ever drift.

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
│   ├── build-site.sh            site/app + site/src + site/static -> site/public/
│   ├── serve-site.sh            python3 -m http.server on 127.0.0.1
│   ├── check-site.sh            structural + content + headless-browser checks
│   ├── browser-check.mjs        the zero-npm-deps CDP driver check-site.sh calls
│   ├── extract-pages.sh         manual PDF -> page image/text extraction (scratch)
│   └── render-page-images.sh    manual PDF -> committed site/static/pages/*.webp
├── site/
│   ├── sxc1-trainer.cabal       lib:sxc1-trainer + exe:app + exe:content-check +
│   │                             exe:exercise-check
│   ├── cabal.project            index-state pin, boot-library constraints
│   ├── src/                     SXC1.* -- the miso-free content/route/exercise library
│   ├── app/                     the Miso app (Main.hs, View/, Exercises/) -- depends
│   │                             on the library
│   ├── test/                    CheckContent.hs, CheckExercises.hs -- the two
│   │                             corpus validators (exe:content-check, exe:exercise-check)
│   ├── static/                  HTML shell, boot loader, vendored WASI shim,
│   │                             pages/<slug>/page-NN.webp (committed JA page images)
│   └── public/                  build output (gitignored, never committed)
├── manuals/                     original Japanese Casio PDFs (source material)
├── translations/                English translations of the manuals (embedded at build time)
├── content/
│   ├── EXERCISE-FORMAT.md       the .ex.md authoring guide -- the only doc a content
│   │                             author needs
│   ├── exercise-inventory.md    the committed 440-id master exercise plan
│   ├── terminology-rules.tsv    house style rules exercise-check enforces
│   ├── exercises/                .ex.md decks + INDEX (embedded at compile time)
│   └── fixtures/                 the validator's falsifiability corpus (files/, dirs/)
└── .github/workflows/           CI: build, check, and (once enabled) deploy to Pages
```

## How it works

`wasm32-wasi-cabal` builds `exe:app` — which depends on the `sxc1-content` library in
`site/src/` for content parsing/routing and on Miso for the view layer — against Miso
into a WASI *reactor* module (not a command) using `-optl-mexec-model=reactor` plus a
linker `--export=hs_start`, so the module can be instantiated and driven from JavaScript
instead of just run once and exiting. GHC's wasm backend then packs every
`foreign import javascript` body — and, because `miso.cabal` declares `js-sources` for
`arch(wasm32)`, Miso's own JS runtime too — into a custom wasm section that
`post-link.mjs` extracts into `ghc_wasm_jsffi.js`. `site/static/` (the HTML shell, boot
loader, vendored WASI shim and the committed JA page images) is copied verbatim over the
output directory, then `app.wasm` and `ghc_wasm_jsffi.js` are added alongside it. In the
browser, `index.js` instantiates `app.wasm` against the vendored WASI shim and the
generated JSFFI import object, runs `_initialize` to start the Haskell RTS, then calls
`hs_start()` to mount the Miso app. Every URL in the output is relative (`./app.wasm`,
never `/app.wasm`), so the same bundle works unmodified at any GitHub Pages sub-path, at
a domain root, or offline when served locally (`./scripts/serve-site.sh`).
`check-site.sh` proves the sub-path claim behaviourally, not just syntactically: it
copies the built bundle under a non-root prefix, serves it there, and requires the full
headless-browser check to pass against that sub-path — a bundle that only works from the
origin root now fails this check even if it slips past the (advisory) grep for absolute
URLs. The bundle does **not** work opened directly from local disk with a bare `file:`
URL, though: `index.js` is an ES module that imports sibling modules and `fetch`es
`app.wasm`, and browsers give a page opened straight off disk that way an opaque origin
that blocks both — it must be served (offline is fine; `./scripts/serve-site.sh` serves
`site/public/` over plain local HTTP), not just opened.

`exe:content-check` and `exe:exercise-check` are both built alongside `exe:app` but are
separate, ordinary wasm32-wasi *command* executables (no reactor model, no JS at all) —
they link against the `sxc1-content` library only, not Miso, and are run directly on the
host by `wasm-run.mjs` as part of `check-site.sh`. Neither ever ships to the browser.

## Deployment

`.github/workflows/site.yml` builds the site, runs the exercise validator (`exe:exercise-check
--content-dir/--translations-dir`, `--fixtures`, `--self-test`) as its own early, timed
step so a content-only typo in a `.ex.md` file fails in seconds rather than after a full
browser sweep, then runs `check-site.sh` (which re-runs that same validator as one of its
own checks — the workflow step above is a fast, readable front door onto the same
unskippable gate, not a separate or looser one) on every push and pull request, then
uploads `site/public/` as a GitHub Pages artifact — nothing built is ever committed to
the repository. `check-site.sh` prints a final machine-readable marker,
`check-site: result=complete` when every check (including both browser runs — root and
sub-path) actually executed, or `check-site: result=structural-only` if the browser axis
was skipped (`--skip-browser` / `SXC1_SKIP_BROWSER=1`); CI fails the build unless it sees
`result=complete`, so a silently skipped browser axis can never pass as a full gate. The
`dist-newstyle` cache key now also hashes `site/src/**`, `site/test/**` and
`translations/*.md`, alongside the pre-existing `site/cabal.project`,
`site/sxc1-trainer.cabal` and `site/app/**` — a translation edit changes what gets
compiled into the wasm via Template Haskell, so it has to invalidate the cache exactly
like a source-code change does, or CI could restore a cache built from the old content
and never notice the translation changed.

The `deploy` job that publishes to GitHub Pages is separate from `build`/`check` and
stays genuinely inert — it does not run at all — until the repository variable
`ENABLE_PAGES` is explicitly set to `true`. Enabling it needs three things from the
owner, none of which have happened yet (open question in `PLAN.md`): make the repository
public (GitHub Pages requires a public repo on a free account), enable Pages with the
"GitHub Actions" source, and set the `ENABLE_PAGES` repository variable to `true`. Until
then, every push still builds and verifies the site on CI — only the publish step is
gated.

## Measured figures

Measured on this machine (Linux x86\_64, 4 cores, 7.6 GiB RAM), one run each, M1:

| Metric | Value |
|---|---|
| Cold build (`site/dist-newstyle` absent, toolchain's package store warm) | 10s |
| Warm build (`site/dist-newstyle` cache hit, nothing changed) | <1s |
| `app.wasm`, default build | 3,740,140 bytes raw / 823,140 bytes gzipped |
| `ghc_wasm_jsffi.js` | 49,356 bytes raw / 10,292 bytes gzipped |
| Committed page images (`site/static/pages/`, 108 files) | 9,375,040 bytes (≈9.4 MB) |
| `site/public/` total, after `build-site.sh` | 13,271,184 bytes (≈13 MB) |
| `check-site.sh`, full run (37 checks, both browser sweeps of 108 routes) | well under 1 min |

`app.wasm` grew from M0's counter-page baseline (2,856,541 B raw / 644,452 B gzipped) by
about 883 KB raw / 179 KB gzipped for the whole reader: the content library, the router,
and every view for the home/TOC/page/JA-panel routes. `site/public/` stays well inside
GitHub Pages' 1 GB artifact limit with headroom to spare.

`--optimize` (`wasm-opt -O2` + strip) remains off by default: `wasm-opt` is the one step
in this pipeline that can silently miscompile GHC's output, so M1's definition of done
does not depend on it. `check-site.sh` re-validates `app.wasm`'s exports regardless of
which build produced it.

## Troubleshooting

- **Build gets OOM-killed** — set `SXC1_JOBS=1` before `./scripts/build-site.sh` (the
  default `SXC1_JOBS=2` already undercuts the toolchain's usual 4-way default to leave
  headroom on machines with limited RAM/swap).
- **No browser found / want to skip the browser test** — set `SXC1_BROWSER` to a browser
  executable path, or pass `./scripts/check-site.sh --skip-browser` (equivalently,
  `SXC1_SKIP_BROWSER=1`).
- **Need to reinstall the toolchain** — `./scripts/install-toolchain.sh --force`.
- **`wasm32-wasi-ghc: command not found` / `wasm-run.mjs: command not found`** — the
  toolchain env script isn't sourced in your shell: run `. "$HOME/.ghc-wasm/env"`.
- **`check-site: no usable Node.js found` / `SXC1_NODE=... is not a usable Node.js`** —
  `check-site.sh` needs Node 22+ with a global `WebSocket` (validated on Node 24/26),
  tried in the order `$SXC1_NODE` → `$HOME/.ghc-wasm/nodejs/bin/node` → `node` on `PATH`.
  Run `./scripts/install-toolchain.sh` if the private toolchain Node is missing, upgrade
  whatever Node is on `PATH`, or set `SXC1_NODE=/path/to/node` explicitly.
- **Manual content looks stale** — re-run `./scripts/build-site.sh` after editing a file
  under `translations/`; `extra-source-files` makes cabal notice, but only a fresh build
  picks it up. `./scripts/check-site.sh` will tell you if a build is stale: its three-way
  content agreement check (see [Verification](#verification)) fails loudly rather than
  silently serving old text.

## Copyright

The English text under `translations/` is a fan translation. Original manual content is
© CASIO COMPUTER CO., LTD. This project is an unofficial fan effort and is not
affiliated with, endorsed by, or sponsored by Casio.

## Design rationale

See [`briefs/M0-plan.md`](briefs/M0-plan.md) for the toolchain design rationale, the
risks considered, and the fallback plan (Miso on GHC's JavaScript backend) if the
WebAssembly backend ever proves unworkable; [`briefs/M1-plan.md`](briefs/M1-plan.md) for
the manual-reader design that milestone implements: the content model, the parser
strategy, the routing scheme, and the page-image delivery decision; and
[`briefs/M2-plan.md`](briefs/M2-plan.md) together with
[`briefs/M2-plan-amendments.md`](briefs/M2-plan-amendments.md) for the exercise-engine
design this milestone implements: the `.ex.md` grammar, the engine's state machine, and
the validator's three-way-agreement verification strategy — the amendments correct the
original plan's parser-reuse assumptions against the real, already-committed M1 code and
win wherever the two disagree.
