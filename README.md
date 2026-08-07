# SXC-1 Trainer

An interactive English-language training course for the [Casio SXC-1](https://www.casio.com/)
portable standalone sampler. The app is a Haskell/[Miso](https://haskell-miso.org/)
application compiled to WebAssembly and served as static files — no server component.
This is an unofficial fan project and is **not affiliated with Casio**.

## Status

**M3 (full course + memory).** The site is now a reader, a trainer, *and* a spaced-
repetition study tool. M1's manual reader and M2's exercise engine are unchanged and
fully intact; M3 adds the rest of the course content, persists progress across visits,
and resurfaces due prompts on a schedule. See [`PLAN.md`](PLAN.md) for the full
milestone roadmap, [`briefs/M3-plan.md`](briefs/M3-plan.md) for the design this
milestone implements, and [`briefs/M3-manifest.json`](briefs/M3-manifest.json) for the
task-by-task breakdown a Sonnet swarm built it from.

**Course content.** The full **52-deck, 435-exercise** course is authored, embedded and
shipping — up from M2's 4-deck/16-exercise seed. Decks are grouped into **six chapters**
(chapter 0, `Front matter`, plus five numbered `Part: …` chapters mirroring the guide
book's own progression — Preparation, Pad play, Sampling, Sequencer, Leveling up) and
tagged `tier: intro | core | stretch` (14 / 32 / 6 decks respectively) for course-map
navigation; 36 decks also carry an optional `requires:` list of deck-slug prerequisites.
Decks are still embedded into the wasm at compile time, but no longer via one
hand-written Template Haskell splice per file — `SXC1.Content.Embed.embedIndexedDir`
reads `content/exercises/INDEX` at compile time and splices every listed file in one
shot, so an author adding deck 53 only has to add it to `INDEX`, not to
`site/app/Exercises/Embed.hs` by hand.

**Progress and spaced repetition.** Every graded prompt now feeds an integer SM-2
scheduler (see [Progress, spaced repetition and the id registry](#progress-spaced-repetition-and-the-id-registry)
below) whose state is persisted to `localStorage` under `sxc1.progress` — a
learner's history, streak and due queue survive a reload, a browser restart, and (via
export/import) moving to a different device. A separate `sxc1.prefs` key remembers a
"show the original Japanese page first" reading preference for the manual reader; it is
a reader-only setting (the trainer and every exercise stay English) and defaults off, so
a fresh profile is still byte-identical to M1/M2. Every localStorage access — both keys
— goes through a JS-side `window.__sxc1Storage` bridge, not `Miso.Storage` or a direct
Haskell FFI call, because a JS exception thrown by `localStorage` (private browsing,
quota exhaustion, storage disabled entirely) does not unwind into Haskell as a catchable
exception — it used to kill the whole boot. The bridge try/catches on the JS side and
returns sentinel values instead, so the app now boots and runs normally, just without
persistence, when storage throws; `check-site.sh` proves this behaviourally by
simulating a throwing `localStorage` in a real headless-Chrome run (see below).

**Sizing.** M3's course growth (52 decks of embedded content plus the progress engine)
does not fit under `check-site.sh`'s frozen 1,000,000-byte gzip ceiling in the
*unoptimized* default build — measured on this tree, `./scripts/build-site.sh` (no
flags) produces an `app.wasm` that gzips to roughly **1,094,000–1,097,000 bytes**
(run-to-run jitter of a few KB; consistently ~94–97 KB over budget). Per `PLAN.md`'s
"Size ruling" (2026-08-07, coordinator decision, explicitly flagged for Codex scrutiny
at the M3 gate), **the shipping artifact is the `wasm-opt`-optimized build**:
`./scripts/build-site.sh --optimize` runs `wasm-opt -all -O2` then `wasm-tools strip` on
`app.wasm`, and measures **907,575–908,037 bytes gzipped** on this tree — comfortably
under the ceiling, and smaller than M2's entire footprint. `.github/workflows/site.yml`
now builds with `--optimize` for exactly this reason (see
[Deployment](#deployment)); `./scripts/build-site.sh`'s own default stays unoptimized
(`--optimize` remains opt-in, never assumed) so local iteration stays fast, and
`check-site.sh` always measures whatever is *actually* sitting at `site/public/app.wasm`
— optimized or not — never a hardcoded assumption about which flavour was built. The
wasm-opt lever was adopted only after empirical scrutiny: the M3 designer could not make
it miscompile (byte-identical `exe:*-check --self-test` output either way, and the real
optimized app has passed every headless-browser assertion this project runs, repeatedly).
`./scripts/check-site.sh --optimized` reproduces this exact pipeline on demand, against
a *copy* of whatever is at `--dir` (never mutating the original), and re-runs the entire
check suite against it — see that flag's own `--help` text for the full story.

`check-site.sh` now runs **80 checks** (up from M2's 71), including the two new checker
binaries below, the `--optimized` mode just described, and a "storage refused" check
that simulates a throwing `localStorage` in a real headless-Chrome run and asserts the
app still boots and reports `available=false` rather than dying at boot.

**The two new checker binaries.** `exe:progress-check` (the pure spaced-repetition core:
scheduler, codec, migration mechanism) passes **69/69** self-test assertions across 11
groups; `exe:registry-check` (PromptId-stability: `content/id-registry.tsv` against the
real corpus) passes **7/7** against the real tree and **15/15** in `--self-test`. Both
are documented in detail below.

**The id registry.** [`content/id-registry.tsv`](content/id-registry.tsv) now tracks all
**440** exercise ids ever minted (435 live, 5 tombstoned) so a drill that gains or loses
a step doesn't silently orphan a learner's saved progress — see
[Progress, spaced repetition and the id registry](#progress-spaced-repetition-and-the-id-registry).

One thing this milestone still deliberately leaves undone, already seamed for M4 rather
than left as an open design question: **device verification is not implemented** — a
drill's self-check is confirmed by the learner clicking a button, not by reading the
SXC-1 itself over WebMIDI. `site/app/Main.hs` still wires an explicit no-op
`DeviceVerifier` (`noDeviceVerifier`) so M4 has a seam to fill rather than a design to
invent; no WebMIDI call and no device permission request exists anywhere in this
milestone's code.

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
and verifying M3: `install-toolchain.sh` recognised the already-installed toolchain and
returned in well under a second; a from-scratch `site/dist-newstyle` build (package
store still warm from the toolchain install; now compiling five executables —
`exe:app`, `exe:content-check`, `exe:exercise-check`, `exe:progress-check` and
`exe:registry-check` — instead of M1's three) took 27 s; `check-site.sh` ran all 80
checks — including both the origin-root and GitHub-Pages-sub-path browser sweeps of all
108 page routes plus the two new checker binaries and the storage-refused simulation —
in under 30 s and printed `check-site: result=complete`; and `serve-site.sh` served
`site/public/index.html` over plain HTTP with a `200`. This quickstart builds the plain,
**unoptimized** `app.wasm` (`build-site.sh`'s own default); see
[Status](#status)/[Deployment](#deployment) for why CI instead builds with `--optimize`.

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
are, so — exactly as with a translation — the whole content-editing workflow is: edit a
`.ex.md` file (or `INDEX`), re-run `./scripts/build-site.sh`. As of M3 this is a single
compile-time splice, not one hand-written literal per deck: `SXC1.Content.Embed`'s
`embedIndexedDir` reads `INDEX` at compile time and `addDependentFile`s every file it
names, and `site/app/Exercises/Embed.hs` is just
`deckSources = $(embedIndexedDir "../content/exercises/INDEX" "../content/exercises")`.
The earlier one-splice-per-file design silently shipped fewer decks than existed on disk
whenever an `INDEX` entry had no matching splice — `exercise-check` (which reads the
directory) would validate a deck the app never actually embedded. `exercise-check`'s
self-test now asserts the app's reported deck count equals the number of non-comment
`INDEX` lines, closing that gap.

Every deck also carries two fields in its field block, right after the `#` title:
`chapter:` (one of six fixed titles — `Front matter` plus five `Part: …` titles mirroring
the guide book's own progression) and, new in M3, `tier: intro | core | stretch`
(required, a closed set the course map uses to group decks by depth) and an optional
`requires: <deck-slug>[, <deck-slug>...]` list of deck-level prerequisites, validated
across the whole corpus for unknown slugs (`E-DECK-REQUIRES-UNKNOWN`) and cycles
(`E-DECK-REQUIRES-CYCLE`). See
[`content/EXERCISE-FORMAT.md`](content/EXERCISE-FORMAT.md) for the full field reference
and worked examples.

The shipped course is **52 decks / 435 exercises**: 8 `Front matter`, 4 `Preparation`, 9
`Pad play`, 7 `Sampling`, 9 `Sequencer`, 15 `Leveling up`; 14 decks `tier: intro`, 32
`core`, 6 `stretch`; 36 decks declare at least one `requires:` prerequisite.

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
machine, against the full 52-deck/435-exercise course: the real-content run reports `0
issue(s)`, `--self-test` passes `272/272` checks, `--fixtures` reports `55/55 fixtures
passed`, and `--list-codes` prints 52 codes (up from M2's 48 — M3 added
`E-DECK-TIER-UNKNOWN`, `E-DECK-REQUIRES-UNKNOWN`, `E-DECK-REQUIRES-CYCLE` and one more
for id-registry/inventory cross-checking; run `--list-codes` yourself for the exact,
current list rather than trusting this count to stay still).
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

## Progress, spaced repetition and the id registry

M3 persists a learner's progress across visits and resurfaces due prompts on an integer
SM-2 schedule. Everything below lives under `site/src/SXC1/Progress/` (the pure model —
no IO, no Miso, no clock reads anywhere in that tree, enforced by both `-Wall`-clean
imports and a source-grep self-test group) and `site/app/Progress/Store.hs` (the one IO
boundary that actually touches storage).

**What is stored, and where.** A learner's progress lives under exactly one
`localStorage` key, `sxc1.progress`. The value is **not JSON** — it's a line-oriented,
tab-separated, ASCII wire format (the app already has a hand-rolled JSON *encoder* for
the content-stats blobs above and no JSON *decoder*, and every field here is an `Int` or
an already-slug-shaped id, so there is nothing to quote or escape):

```
SXC1PROGRESS <TAB> <schemaVersion>          (currently 2)
M <TAB> streakDay <TAB> streakLen <TAB> firstDay <TAB> lastPrompt
R <TAB> promptId <TAB> reps <TAB> lapses <TAB> ease <TAB> interval <TAB> due <TAB> lastSeen <TAB> seen
D <TAB> exerciseId <TAB> completions
```

The schema version lives **inside the first line of the payload itself**, not in the
storage key name or anywhere external to the blob — so a copied blob (see Export/import
below) is fully self-describing: nothing outside the text you copy is needed to read it
back, on this device or another one. Unknown leading tags (a record type a newer schema
introduced) are **skipped, not rejected**, so an older build of the app degrades
gracefully to "ignored" on a record type it doesn't understand instead of refusing the
whole blob; the same is true of a truncated or malformed individual `R`/`D`/`M` line —
only that one record is dropped, never its siblings.

**The migration story.** `SXC1.Progress.Codec.migrateWith` walks a decoded version `v`
forward, `v -> v+1 -> ... -> currentSchema` (currently `2`; the v1 -> v2 step added the M line's `lastPrompt` column for "continue where you left off"), applying one step per hop
from a step table; a hop with no registered step is `DecodeCorrupt`, never a silently
dropped history. Migration is forward-only by construction — there is no downgrade path,
by design, since an older build encountering a newer schema version it cannot even
partially understand is exactly the "unknown tags are skipped" case above, not a
migration. `productionSteps` is empty today (schema 1 is the only schema that has ever
shipped), but the mechanism itself is already exercised by `exe:progress-check`'s
self-test using a synthetic schema-0 blob and a test-only step table — not left
untested until a schema 2 is invented under pressure.

**The corrupt-state promise.** Decoding a stored blob yields one of three outcomes, and
the three-way split is load-bearing:

```haskell
data DecodeResult = DecodeEmpty | DecodeOk !ProgressState | DecodeCorrupt !Text
```

`DecodeEmpty` means there was genuinely nothing stored yet. `DecodeCorrupt reason` means
something *was* stored and could not be read back — and a `Maybe` could never distinguish
that from `DecodeEmpty`, which matters enormously here: if "I couldn't read it" collapsed
into "there was nothing to read", the app would treat a corrupt blob as an empty history
and the very next save would silently overwrite it. **A key that failed to decode is
never overwritten.** `site/app/Main.hs` only ever calls `saveProgress` after a load that
came back `DecodeOk`/`DecodeEmpty` (and after `storageAvailable` probed true) — never
after `DecodeCorrupt`. Instead the app shows a corrupt-state banner
(`#sxc1-corrupt-banner`) with the raw, undecoded text in a read-only field
(`#sxc1-corrupt-raw`) so the learner can copy it out by hand before deciding whether to
wipe. A blob whose version number is *higher* than the build's own `currentSchema` (a
learner who used a newer build, then opened the same profile in an older one) is also
always `DecodeCorrupt`, never optimistically read as current.

**The scheduler.** Every graded prompt updates an integer SM-2 record
(`SXC1.Progress.Scheduler`, `SXC1.Progress.Types.Rec`) — deliberately **no floating point
anywhere** in the scheduler, because `Int` is 32-bit on `wasm32` and a schedule replayed
from a stored event log (`exe:progress-check --replay`, see below) must decode to
bit-identical records forever on any target; a `Double` anywhere in that path risks a
platform-dependent rounding difference an `Int` computation cannot have. The ease factor
is therefore carried as **milli-units in a plain `Int`** (`2500` means ease factor
`2.5`), bounded `[1300, 3000]`, defaulted to `2500`. Every graded prompt is first reduced
to one of four grades — `gradeOfOutcome` is the *only* place an `Outcome` is ever
interpreted this way:

| Outcome | Condition | Grade |
|---|---|---|
| `Incorrect` or `Skipped` | — | `GAgain` (start the item over) |
| `Correct` | answer was revealed first | `GHard` |
| `Correct` | took a 2nd+ attempt | `GHard` |
| `Correct` | first try, but a hint was used | `GGood` |
| `Correct` | first try, no reveal, no hint | `GEasy` |
| `Completed` (exercise-level, promptless) | — | `GGood` |

Each grade moves the ease factor by an exact literal (`GAgain -320`, `GHard -140`,
`GGood 0`, `GEasy +100` — these are SM-2's own `EF' = EF + (0.1 - (5-q)(0.08+(5-q)0.02))`
evaluated ahead of time at `q = 2,3,4,5`, never computed at runtime) and picks the next
interval in whole days from a small table keyed on the grade and the prompt's rep count,
**capped at 180 days**. The cap is deliberate: this is a course for learning a specific
piece of hardware, not an indefinitely-lived flashcard deck, and an uncapped SM-2 curve
would schedule an item past the point where the learner still plausibly owns the SXC-1.
Day boundaries are UTC and computed by simple integer division of the event's own
wall-clock epoch milliseconds (`dayOf`, `86,400,000` ms/day) — coarse enough that a
learner who studies at 23:59 and again at 00:01 the same UTC day is never charged a
whole extra interval for it. Critically, **`applyEvent` takes no clock argument at
all** — the day always comes from the graded event's own timestamp, never a clock read
inside the scheduler — which is what makes replay exact: folding the same
`[ProgressEvent]` through `applyEvents` twice, at any two different real times, produces
the identical `ProgressState` both times.

The home page's review queue reads `reviewQueue :: DayNum -> ProgressState ->
[(PromptId, Rec)]` — every prompt currently due, sorted by `(dueDay, promptId)`, a total
order so two prompts due the same day always come back in the same order regardless of
insertion order or `Map` iteration order.

**Export/import.** The *only* way progress moves between devices — there is no account
and no backend, by design (see Privacy below) — is the learner copying an export blob by
hand. Clicking Export (`#btn-progress-export`) fills a read-only textarea
(`#sxc1-export-blob`) with a small JSON envelope:

```json
{"format":"sxc1-progress","schema":2,"exportedAt":"<stamp>","payload":"<wire text>"}
```

`payload` is exactly the same tab-separated wire text `encodeState` produces internally —
one format to keep correct, not two. Pasting that text back into the Import box
(`#sxc1-import-input`) and submitting decodes it the normal way; `importBlob` also
accepts a **bare** wire blob (raw text starting with `SXC1PROGRESS`, no JSON envelope at
all), so a learner who only copied the inner payload — or hand-edited it — still
recovers their history. `"` `\` newline `\t` and `\r` are escaped going out and unescaped
coming back, using the app's existing `jsonEscape` rather than a second JSON encoder.

**The JA-first reading preference.** A second, entirely separate `localStorage` key,
`sxc1.prefs`, remembers one switch: "show the original Japanese manual page before the
English translation" (`#btn-ja-first`, in the manual reader's header). This is a
**reader preference only** — flipping it changes which panel the manual reader shows
first; it does not translate, relabel, or otherwise touch a single exercise, and no
i18n framework or string catalogue exists anywhere in the app. It defaults to **off**,
which is a safety property, not an accident: a fresh profile with no stored preference
behaves byte-identically to the app before this feature existed, so every pre-M3
browser assertion still holds unmodified. Wiping progress (`#btn-progress-wipe` →
confirm) deletes *only* the `sxc1.progress` key — `wipeProgress` never touches
`sxc1.prefs` — so clearing a corrupted or unwanted history never resets the reading
preference.

The prefs codec is deliberately **asymmetric** with the progress codec, and both
asymmetries are load-bearing:

1. `decodePrefs` returns a bare `Prefs`, **never** a `DecodeResult`. Anything it can't
   read — a missing key, a short or malformed header, a future schema version, garbage —
   falls back to `defaultPrefs` (`jaFirst = False`) and *may* be silently overwritten on
   the next save. A reading preference is one switch a learner can re-flip in a second;
   a progress history spanning months of spaced-repetition data cannot be regenerated at
   all. `decodeState`'s never-overwrite-corrupt rule exists because the thing it guards
   is irreplaceable; `decodePrefs`'s fall-back-to-default exists because the thing it
   guards isn't.
2. The preference is its own key with its own `SXC1PREFS` magic string, never a field on
   `ProgressState`. A corrupt *progress* blob puts the app into read-only progress mode
   (nothing new is saved until the learner exports, wipes, or imports) — but the reading
   preference has to stay independently settable through all of that, which a shared
   record could never guarantee. Both codecs do share one line-oriented `tag/key/value`
   splitter internally (a cost discipline: a naive second-magic-string/second-decoder
   implementation of this feature measured +5,936 gzip bytes on its own during design;
   sharing the splitter keeps the whole feature's actual cost far below that).

**The storage bridge.** No Haskell module reaches `localStorage` directly, and — as of
an M3 hardening fix — none imports `Miso.Storage` either. The first version of
`Progress/Store.hs` did import `Miso.Storage` and wrapped every call in
`Control.Exception.try`, which cannot actually work here: a JS exception thrown by
`localStorage` (private browsing in Safari/Firefox, quota exhaustion, storage disabled
by policy) does not unwind into Haskell as a catchable exception at all — it propagates
straight out of the wasm import and used to kill the whole boot sequence
(`window.__SXC1_BOOT_ERROR`), before the learner ever saw a page. Every storage access
now goes instead through `window.__sxc1Storage`, a small bridge installed by
`site/static/index.js` *before* the wasm boots, whose `get`/`set`/`del`/`probe` methods
try/catch **on the JS side** and return sentinel values (`undefined`, `0`) instead of
ever throwing across the wasm boundary:

```js
window.__sxc1Storage = {
  get: (k) => { try { const v = window.localStorage.getItem(k); return v === null ? undefined : v; } catch (e) { return undefined; } },
  set: (k, v) => { try { window.localStorage.setItem(k, v); return 1; } catch (e) { return 0; } },
  del: (k) => { try { window.localStorage.removeItem(k); return 1; } catch (e) { return 0; } },
  probe: () => { try { /* write, read back, remove */ ... } catch (e) { return 0; } },
};
```

`site/app/Progress/Store.hs` is the **one** Haskell module in the whole project allowed
to name that bridge or touch storage at all; `storageAvailable` calls `probe`, which
writes a throwaway value, reads it back, and removes it, entirely inside the bridge's own
try/catch, so the app can tell genuine read/write availability apart from "the key
happened to be empty." When storage throws (or is simply disabled), the app now boots
and runs completely normally — reader, exercises, everything — just without persistence;
nothing is saved and nothing crashes. `check-site.sh` proves this behaviourally, not just
by inspection: it drives a real headless-Chrome session with `localStorage` overridden to
throw on every call, and asserts the app still boots and reports `available=false`
instead of dying. Two `check-site.sh` checks stand permanent guard over this design: one
asserts zero Haskell files anywhere under `site/src`/`site/app`/`site/test` mention
`Miso.Storage` or `localStorage` (case-insensitive, comment-lines excluded), and the
other asserts `__sxc1Storage` is named by exactly `site/app/Progress/Store.hs` and
nowhere else.

**Privacy**, stated plainly: everything above stays in the browser. Nothing is ever
uploaded anywhere — there is no analytics, no telemetry, no backend of any kind, and the
only way progress or a reading preference travels off the device it was recorded on is
the learner deliberately copying an export blob themselves.

**The id registry.** [`content/id-registry.tsv`](content/id-registry.tsv) is a committed,
tab-separated file tracking every exercise id **ever minted**, live or retired — 440 rows
as of M3 (435 live, 5 tombstoned), one row per id: the id itself, its `promptCount`
(`length (exPrompts ex)` for a live row, always `0` for a tombstone), `live`/`tombstone`
status, the milestone tag the id first shipped under, and a free-text note. It exists
because a saved `Rec` is keyed by `PromptId` (`<exercise-id>#<1-based prompt index>`) —
if a drill gains or loses a step, its `id:` can stay exactly the same while the *set* of
`PromptId`s it mints changes underneath a learner's already-saved schedule, silently
orphaning some of their progress without any id ever having moved. `promptCount` is what
lets `exe:registry-check` catch that drift the moment it happens, rather than a learner
discovering it as inexplicably-missing history months later.

**The tombstone process**, documented in the registry file's own header: an id is
**never deleted** from this file and **never reused** for a different exercise later.
Retiring an exercise flips its row in place from `live` to `tombstone`, sets
`promptCount` to `0`, and updates the note to say why and what (if anything) replaces
it — the row itself stays, forever, so a learner's saved record whose id resolves to a
tombstone can be reported as "this exercise was retired, see `<replacement>`" instead of
being indistinguishable from ordinary corruption. "Retired" and "corrupt" have to stay
different failure modes for a learner, which requires every retired id to remain
look-up-able here permanently. (`content/id-registry.tsv` is distinct from
[`content/exercise-inventory.md`](content/exercise-inventory.md) above: the inventory is
the pre-authored master *plan* of which ids may exist; the registry is the
*runtime-relevant* record of what each shipped id actually mints, which the inventory
alone cannot capture.)

**Running the two new checkers.** Both are ordinary `wasm32-wasi` *command* executables,
built alongside `exe:app` by `build-site.sh` and run the same way as `exe:content-check`/
`exe:exercise-check` above:

```sh
. "$HOME/.ghc-wasm/env"
cd site
PBIN="$(wasm32-wasi-cabal list-bin exe:progress-check | tail -1)"
RBIN="$(wasm32-wasi-cabal list-bin exe:registry-check | tail -1)"

wasm-run.mjs "$PBIN" --self-test        # 69/69 checks across 11 groups: the SM-2 table,
                                         # grade mapping, replay determinism, codec round
                                         # trip, review-queue order, the streak rule,
                                         # dayOf, codec/migration robustness, export/
                                         # import, prefs, and a source-inspection purity
                                         # guard -- all run and passing on this tree.
wasm-run.mjs "$PBIN" --replay <file>    # reads a #sxc1-event-log JSON array from <file>,
                                         # folds it through applyEvents from
                                         # emptyProgress, and prints encodeState of the
                                         # result -- used at sign-off to diff a pure
                                         # replay against what a real browser actually
                                         # stored, byte for byte.

wasm-run.mjs "$RBIN"                    # checks content/id-registry.tsv against the
                                         # real corpus (R1-R6): 7/7 on this tree
                                         # (435 corpus / 440 registry).
wasm-run.mjs "$RBIN" --self-test        # 15/15: every rule (R1-R6) proven able to fire,
                                         # on synthetic inputs, in both directions.
wasm-run.mjs "$RBIN" --list             # prints the registry as read, for inspection.
```

`exe:registry-check` deliberately has **no `--update` flag**: a checker that can
regenerate the very file it checks can never fail and proves nothing. The registry is a
file a human edits by hand in the same commit as the content change that requires it;
the tombstone process above is the whole procedure. `./scripts/check-site.sh` runs both
binaries' `--self-test` (and `registry-check` with no args, against the real tree) as
part of its own content-axis gate, so a plain `check-site.sh` run already covers both —
the commands above are for iterating on the progress core or the registry in isolation.

**The size discipline.** `check-site.sh` still enforces the same frozen
**1,000,000-byte** gzip ceiling on `app.wasm` (`WASM_GZIP_CEILING_BYTES`, unchanged since
M1) — see [Status](#status) above for how M3 fits the full course under it. Part of how
`exe:app` stays small enough to matter: it links `SXC1.Exercise.Reader`, a pure
*structural* deck reader with no knowledge of citations, terminology rules, or issue
codes, rather than the full validating parser (`SXC1.Exercise.{Parse,Report,Lint,Verify}`)
that `exe:exercise-check`/`exe:content-check` use at CI/build time. The browser never
needs to know *why* a deck would fail to validate — only the CI-time checkers do — so
splitting that apparatus out of the browser-linked module saved roughly 46 KB gzipped on
its own; `check-site.sh` greps `site/app/` on every run to prove none of `.Parse`,
`.Report`, `.Lint` or `.Verify` is reachable from `exe:app` any more. `check-site.sh`
also prints a standing **size ledger** on every run — a linear projection (0.3456 gzip
bytes per raw byte of `.ex.md`, a measured coefficient, re-derived and commented at the
ledger's own definition in `scripts/check-site.sh`) of what the corpus contributes to
`app.wasm`'s size — so a coordinator can see the trend before it becomes a crisis, rather
than rediscovering it by hand once the course has grown further.

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
│   │                             exe:exercise-check + exe:progress-check +
│   │                             exe:registry-check
│   ├── cabal.project            index-state pin, boot-library constraints
│   ├── src/                     SXC1.* -- the miso-free content/route/exercise library;
│   │                             SXC1/Progress/{Types,Scheduler,Codec}.hs -- the pure
│   │                             spaced-repetition core (no IO, no Miso, no clock reads)
│   ├── app/                     the Miso app (Main.hs, View/, Exercises/, Progress/) --
│   │                             depends on the library; Progress/Store.hs is the one
│   │                             module allowed to touch localStorage
│   ├── test/                    CheckContent.hs, CheckExercises.hs, CheckProgress.hs,
│   │                             CheckRegistry.hs -- the four corpus/engine validators
│   │                             (exe:content-check, exe:exercise-check,
│   │                             exe:progress-check, exe:registry-check)
│   ├── static/                  HTML shell, boot loader, the __sxc1Storage JS bridge,
│   │                             vendored WASI shim, pages/<slug>/page-NN.webp
│   │                             (committed JA page images)
│   └── public/                  build output (gitignored, never committed)
├── manuals/                     original Japanese Casio PDFs (source material)
├── translations/                English translations of the manuals (embedded at build time)
├── content/
│   ├── EXERCISE-FORMAT.md       the .ex.md authoring guide -- the only doc a content
│   │                             author needs
│   ├── exercise-inventory.md    the committed 440-id master exercise plan
│   ├── id-registry.tsv          the 440-row PromptId-stability registry (promptCount +
│   │                             the tombstone process; see exe:registry-check)
│   ├── terminology-rules.tsv    house style rules exercise-check enforces
│   ├── exercises/                52 .ex.md decks + INDEX (embedded at compile time)
│   └── fixtures/                 the validator's falsifiability corpus (files/, dirs/)
└── .github/workflows/           CI: build (with --optimize), check, and (once enabled)
                                  deploy to Pages
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

`exe:content-check`, `exe:exercise-check`, `exe:progress-check` and `exe:registry-check`
are all built alongside `exe:app` but are separate, ordinary wasm32-wasi *command*
executables (no reactor model, no JS at all) — they link against the `sxc1-content`
library only, not Miso, and are run directly on the host by `wasm-run.mjs` as part of
`check-site.sh`. None of the four ever ships to the browser.

## Deployment

`.github/workflows/site.yml` builds the site with `./scripts/build-site.sh --optimize`
(see below for why), runs the exercise validator (`exe:exercise-check
--content-dir/--translations-dir`, `--fixtures`, `--self-test`) and, new in M3, the
progress-core and id-registry checkers (`exe:progress-check --self-test`,
`exe:registry-check --self-test` and a plain run) each as their own early, timed step so
a content-only or progress-core-only defect fails in seconds rather than after a full
browser sweep, then runs `check-site.sh` (which re-runs all of the above as part of its
own checks — the fast early steps are a readable front door onto the same unskippable
gate, not a separate or looser one) on every push and pull request, then uploads
`site/public/` as a GitHub Pages artifact — nothing built is ever committed to the
repository. `check-site.sh` prints a final machine-readable marker,
`check-site: result=complete` when every check (including both browser runs — root and
sub-path) actually executed, or `check-site: result=structural-only` if the browser axis
was skipped (`--skip-browser` / `SXC1_SKIP_BROWSER=1`); CI fails the build unless it sees
`result=complete`, so a silently skipped browser axis can never pass as a full gate. The
`dist-newstyle` cache key hashes `site/src/**`, `site/test/**`, `site/app/**` and
`translations/*.md`, alongside the pre-existing `site/cabal.project` and
`site/sxc1-trainer.cabal` — a translation or progress-core edit changes what gets
compiled into the wasm, so it has to invalidate the cache exactly like any other
source-code change does, or CI could restore a cache built from stale content and never
notice.

**Why CI builds with `--optimize`.** Per `PLAN.md`'s "Size ruling" (2026-08-07,
coordinator decision): the full 52-deck/435-exercise course does not fit under
`check-site.sh`'s 1,000,000-byte gzip ceiling in the plain, unoptimized build (see
[Status](#status) for the measured numbers), so the artifact CI actually verifies and
would deploy has to be the `wasm-opt`-optimized one. `build-site.sh`'s own default stays
unoptimized — only this workflow's own build step passes `--optimize` — so a bare local
`./scripts/build-site.sh` is still the fast, iteration-friendly default the
[Build](#build) quickstart above uses; only CI's build needs to produce the artifact that
actually ships. `check-site.sh` itself needed no change for this: it always measures
whatever is *actually* sitting at `site/public/app.wasm`, optimized or not, so pointing
its input at an optimized build was the only change required.

The `deploy` job that publishes to GitHub Pages is separate from `build`/`check` and
stays inert — it does not run at all — unless the repository variable `ENABLE_PAGES` is
`true`. As of this milestone the GitHub repository is public
(`robjohncolson/sexy_one`) and GitHub Pages *is* configured for it, but the workflow's
own Pages-deployment queue got stuck (repeated `deployment_queued` timeouts, no posted
GitHub incident) — so, per `PLAN.md`'s "Deploy-path note", `ENABLE_PAGES` is
**deliberately left `false`** for now, and the site is instead deployed via the legacy
`gh-pages` branch: build and verify locally, copy `site/public/` onto the `gh-pages`
branch, push. This is a coordinator decision this task does not change. What this task
*does* guarantee is that the workflow would do the right thing the moment `ENABLE_PAGES`
flips back to `true`: the `build` job already produces the optimized, under-ceiling
artifact every run, `deploy` just publishes whatever `build` uploaded, so no further
change is needed to re-enable workflow deploys — only the coordinator's variable flip
and, per the deploy-path note, setting the Pages source back to `build_type=workflow`.
Until then, every push still builds and verifies the site on CI — only the publish step
is gated, and the currently-live deployment is refreshed manually via the branch path
above.

## Measured figures

Measured on this machine (Linux x86\_64, 4 cores, 7.6 GiB RAM), M3, against the full
52-deck/435-exercise course:

| Metric | Value |
|---|---|
| Cold build (`site/dist-newstyle` absent, package store warm; 5 executables) | 27s |
| Warm build, unoptimized (nothing changed) | <1s |
| Warm build, `--optimize` (nothing changed — `wasm-opt`/strip still re-run every time) | ~5s |
| `app.wasm`, unoptimized default build (`build-site.sh`, no flags) | ≈5,220,000 bytes raw / **≈1,094,000–1,097,000 bytes gzipped** — *over* the 1,000,000 ceiling |
| `app.wasm`, `--optimize`d build (`build-site.sh --optimize` — the shipping artifact) | ≈3,238,550 bytes raw / **907,575–908,037 bytes gzipped** |
| `ghc_wasm_jsffi.js` | 49,500 bytes raw / 10,307 bytes gzipped (identical either way — `wasm-opt` only touches `app.wasm`) |
| Committed page images (`site/static/pages/`, 108 files) | 9,375,040 bytes (≈9.4 MB, unchanged since M1) |
| `site/public/` total, after `build-site.sh --optimize` | 12,799,585 bytes (≈12.8 MB) |
| `check-site.sh`, full run (**80** checks, both browser sweeps of 108 routes, 120 browser assertions) | ≈29s |
| `exe:progress-check --self-test` | **69/69** checks, 11 groups |
| `exe:registry-check` (real tree) / `--self-test` | **7/7** (435 corpus / 440 registry) / **15/15** |
| `exe:exercise-check` real-content / `--self-test` / `--fixtures` / `--list-codes` | 0 issues / **272/272** / **55/55** fixtures / 52 codes |

The two `app.wasm` gzip ranges above are ranges, not single numbers, deliberately: this
project observed a few hundred bytes of run-to-run jitter across otherwise-identical
rebuilds (e.g. two `--optimize` runs on an unchanged tree measured 907,575 and 908,037),
which `scripts/check-site.sh`'s own size-ledger comment independently records too — never
enough to cross the ceiling either way on this tree, but real, so this table reports what
was actually observed rather than a single cherry-picked run. `app.wasm` grew from M2's
978,969-byte gzipped baseline mainly for two reasons: the course grew from 4 decks/16
exercises to 52 decks/435 exercises (embedded content costs ≈0.3456 gzip bytes per raw
byte of `.ex.md`), and the M3 progress engine (`SXC1.Progress.*`, `Progress/Store.hs`,
`View/Progress.hs`) added roughly another 34 KB gzipped. See
[Status](#status) for the full size story and why CI now builds the `--optimize`d
flavour. `site/public/` stays well inside GitHub Pages' 1 GB artifact limit either way.

`--optimize` (`wasm-opt -O2` + `wasm-tools strip`) remains **off by default** in
`build-site.sh` itself — `wasm-opt` is the one step in this pipeline that could in
principle silently miscompile GHC's output, so a plain local build never depends on it,
and this project's own definition of done never assumed it. What changed in M3 is what
CI *asks* `build-site.sh` to do, not the script's own default (see
[Deployment](#deployment)): the unoptimized build no longer fits under the ceiling once
the whole course is embedded, and the M3 designer's adversarial testing — byte-identical
checker `--self-test` output whether the app was optimized or not, and every
headless-browser assertion this project runs passing repeatedly against the optimized
artifact — found no evidence of miscompilation on this codebase.
`./scripts/check-site.sh --optimized` reproduces the exact optimize-then-strip pipeline
on demand, against a disposable copy, for local re-verification; `check-site.sh` itself
re-validates `app.wasm`'s exports and behaviour regardless of which build produced the
file actually sitting at `site/public/app.wasm`.

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
- **`app.wasm` gzip size is over the 1,000,000-byte ceiling** — you're most likely running
  the plain, unoptimized default build against the full course. Build with
  `./scripts/build-site.sh --optimize` (what CI does; see
  [Progress, spaced repetition and the id registry](#progress-spaced-repetition-and-the-id-registry)
  and [Deployment](#deployment)) — the optimized build measures well under the ceiling on
  this tree.
- **Progress doesn't seem to be saved (e.g. in a private/incognito window)** — this is
  expected, working behaviour, not a bug: when `localStorage` is disabled or throws (many
  browsers do this in private browsing), the app boots and runs completely normally, it
  just can't persist anything. Look for the storage-unavailable state in the progress
  panel rather than assuming something crashed.
- **"This progress could not be read" banner** — the stored `sxc1.progress` blob failed
  to decode; it is deliberately left untouched rather than silently discarded (see
  [Progress, spaced repetition and the id registry](#progress-spaced-repetition-and-the-id-registry)).
  Copy the raw text out of the banner (or Export, if the app can still read enough to
  offer it) before choosing to wipe.

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
win wherever the two disagree; and [`briefs/M3-plan.md`](briefs/M3-plan.md) for the
full-course-and-memory design this milestone implements — the reader/validator split and
INDEX-driven embedding that made room for the course, the integer SM-2 scheduler and
versioned storage codec, and the measured size-reduction levers (including the
`wasm-opt` adoption `PLAN.md`'s "Size ruling" section formalises as a coordinator
decision).
