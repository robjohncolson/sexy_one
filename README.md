# SEXY ONE — a Casio SXC-1 trainer

**SEXY ONE** is an unofficial bilingual (English / 日本語) trainer and complete fan
translation of the manuals for the [Casio SXC-1](https://www.casio.com/), a portable
standalone sampler Casio sells only in Japan. Everything runs in your browser — the site is static files
with no server, no account and no analytics, and nothing you do in it ever leaves
your machine. After one successful visit, the executable course can also relaunch
offline and can be installed from a supporting phone or desktop browser.

**Use it now:**

- <https://robjohncolson.github.io/sexy_one/> (GitHub Pages)
- <https://sexy-one-gray.vercel.app/> (Vercel mirror — the same bundle)

In your first minute you can open **Today's session**, a stable five-step mix of due,
in-progress, useful next course work, and—when your local Sample Lab has something
actionable—one prepare/load task; you can also
open the **Weekly pulse** for a calm view of your recent rhythm, the next seven days
of review load, skills in motion, and one recommended focus,
open the **Mastery journey** for a focused review/continue/learn-next route through all 51 skills,
browse any page of the four manuals in English with the original Japanese page right
beside it, or — in desktop Chrome or
Edge — connect an SXC-1 over USB, click **Enable device verification** on a drill,
and watch steps confirm themselves as you perform them on the real hardware.

**日本語でも使えます — the whole thing runs in Japanese too.** Click **日本語** in the
site header and the interface, all **355 exercises across 51 decks**, the device
messages **and the manuals themselves** switch to Japanese (**English** in the same
place switches back). M6 made the *course* Japanese; **M7 makes the manual pages
Japanese TEXT** — all **108 pages of all four documents**, transcribed from Casio's
own page images, so a Japanese reader gets words they can select, search, copy and
reflow on a phone instead of a picture of words. The original scan is still there and
still one click away (**Show original page**), exactly as before: what changed is that
it is no longer the *only* Japanese on the page. Your choice is remembered in this
browser, and **progress is shared between the languages** — the same exercise has the
same id in both, so a prompt you answered in English is the same prompt when it comes
up for review in Japanese. Switching to Japanese also suggests the reader's "Japanese
first" mode the first time (a suggestion, not a lock — both preferences stay
independently settable).

## For SXC-1 owners

The manual reader keeps the original Japanese page one click away at all times, and
a "Japanese first" reading preference makes the reader open the original page before
the English translation — useful if you read Japanese and want the translation as
the aid rather than the text. If you would rather work entirely in Japanese, the
**日本語** button in the header switches the interface *and the whole course*; every
on-device label (`BANK`, `EDIT`, `SELECT BANK 1`, …) stays in Latin caps inside the
Japanese text, exactly as the hardware prints it. Your course progress lives only in your own browser;
**Export/Import** on the progress panel produces a small validated backup you can
save, share, paste, or load from a file to move your history to another device,
and that backup is the *only* way
progress ever travels anywhere. Device verification — the trainer confirming drill
steps by watching your real SXC-1 over USB-MIDI — is optional and off until you
click **Enable device verification** on a drill page; it needs a Chromium browser
(desktop Chrome or Edge — Firefox and Safari have no Web MIDI, and the trainer works
fully there with manual confirmation), and received MIDI data never leaves the
browser. The translations are a fan effort: this project is **not affiliated with,
endorsed by, or sponsored by Casio**, and original manual content remains
© CASIO COMPUTER CO., LTD. — see [Copyright](#copyright).

## For developers

The app is written in Haskell with [Miso](https://haskell-miso.org/) and compiled to
WebAssembly by GHC's wasm backend; both corpora — the exercise decks (M6) and the
manual text (M7) — are fetched at boot as per-language text bundles
(`content/content.{en,ja}.txt` and `content/manuals.{en,ja}.txt`, accepted
all-or-nothing against an expectation compiled into the wasm — see
[Status](#status) and [How the manuals get into the app](#how-the-manuals-get-into-the-app)),
so the whole deployment is still static files — zero servers, working unchanged at any
sub-path or served locally. The project runs on a
check-suite culture: nearly every claim in this README is enforced by a named check
in `./scripts/check-site.sh`, which computes the content statistics three
independent ways and drives the built site in headless Chrome before anything ships.
Start with [Prerequisites](#prerequisites) and [Build](#build) to build it yourself,
[Verification](#verification) for how the checks work, and
[Measured figures](#measured-figures) for current sizes, counts and timings.

## Status

**M11 flashcard continuity.** All 128 quizzes that formerly revealed a
model answer and asked the learner whether they knew it are now real, authored
two-option flashcards. A learner selects an answer, then the two `Check answer` /
`I’m not sure` actions are replaced in place by `Good` / `Easy` after a correct
answer or `Again` / `Hard` after a miss. The chosen grade is the scheduler input;
checking alone writes no progress, and every grade opens the next session/course
card without a second repeat decision. `Again` schedules an earlier return instead
of looping immediately. Hands-on cards expose `Skip for now` / `Yes — done`; Skip
records unfinished steps as due work and continues. Native radio/checkbox cards keep answer options from
becoming a button wall. Hints and progress-data operations use disclosures, and
backup/reset follow-up actions replace the prior action rather than accumulating.
The contract is in [`docs/FLASHCARD-FLOW.md`](docs/FLASHCARD-FLOW.md).
This optimized M11 artifact is deployed at the Vercel mirror below and passed the
complete 135/135 local gate plus 73/73 assertions against production.

**Current (M17 One Practice Home).** Home now has one primary path: **Today's
session**. Its stable five-step plan keeps the existing due/continue/new course
logic and may reserve exactly one step for real local Sample Lab work: resume a
handoff, prepare/check a sound, place an Inbox sound, or begin loading an assigned
project. Real Ready/Placed/Loaded outcomes complete that step and continue to the
next one without a redundant confirmation. `Skip for today` handles times when
the learner is away from the phone, files, or SXC-1 without claiming success.
Weekly Pulse now unions those Lab days into the rhythm and visibly reports
Prepare, Place, and Loaded totals. Its independent `sxc1.practice-loop.v1` ledger
keeps only 200 privacy-light events—no names, filenames, provenance, audio, MIDI,
answers, or timing—and intentionally changes neither the progress passport nor
`.sxc1lab`. The planner reads metadata only; the Lab and readiness worker remain
deferred. See [`docs/ONE-PRACTICE-HOME.md`](docs/ONE-PRACTICE-HOME.md).
The optimized artifact passed the complete 139/139 local release gate with
242/242 browser assertions at both root and nested paths; production release
verification is in progress.

**M16 Sound Check.** A Library sound now has an on-demand, entirely
local readiness check before phone handoff. A deferred worker reads the original
WAV header and, for PCM data up to 48 MB, scans the file's own samples for
full-scale clipping and edge silence without blocking the interface or silently
resampling the audio. Required findings target the SXC-1's documented stereo
48 kHz, 16-bit linear PCM WAV format, 15-minute limit, and approximate 173 MB
limit; non-WAV and larger files receive explicit partial results rather than
invented facts. Failed and advisory findings become a copyable, finding-specific
Audacity recipe. Re-importing an edited export preserves metadata and both files,
then one **Use this version / Keep current** decision either repoints every matching
placement across projects or changes none. Existing handoff receipts re-queue only
changed pads, `.sxc1lab` stays schema 1, and a new bilingual three-card deck explains
the underlying specification. See [`docs/SOUND-CHECK.md`](docs/SOUND-CHECK.md).
The optimized artifact passed the complete 138/138 release gate with 242/242
browser assertions at both root and nested paths. That byte-identical artifact is
live on Vercel (`dpl_Hbo81r9TnDyBMm8zXEVjQcYLoT4z`) and GitHub Pages
(`71356d4`), and each production URL passed 78/78 browser assertions.

**M15 Phone Bridge + resumable handoff.** The computer's **Send
project to phone** action shares the existing schema-1 `.sxc1lab` file through
the native file share sheet when available and saves the same file otherwise.
Opening that project on the phone enters handoff review directly. Each pad now
offers only **Share/Skip**, then replaces that pair with **Loaded/Problem** after
the file leaves SEXY ONE; the outcome itself advances to the next unresolved
destination. The exact cursor and a Loaded/Problem/Skipped receipt survive app
switching and reloads in a bounded, independently repairable local ledger.
Loaded rows remain complete when unresolved rows are retried, and changing a
pad destination or sound safely returns only that changed row to pending.
`.sxc1lab` remains schema 1 and no server, account, or CASIO protocol imitation
is introduced. The optimized artifact passed the complete 136/136 release gate
with 241/241 browser assertions at both root and nested paths, including the real
project send/import controls, exact-cursor reload, receipt retry, ledger repair,
offline cache, Japanese UI, and the 320 px mobile sweep. The byte-identical
artifact is deployed at the Vercel mirror and passed 77/77 assertions against
production. See
[`docs/PHONE-BRIDGE.md`](docs/PHONE-BRIDGE.md).

**M14 Sample Library + named projects.** `#/samples` keeps one
searchable local catalog shared by up to 32 projects. Identical imports reuse
the same IndexedDB audio; legacy M12/M13 sounds are fingerprinted lazily only
when a same-size import makes a duplicate possible, so the upgrade adds no
startup scan. Name, source, tags, edit notes, permission/credit, BPM, format,
duration, and Raw/Edited/Ready stage are searchable; one sound can feed any
project's Inbox without copying its bytes. Deleting a project keeps the
Library, and removing a Library record keeps existing project assignments.
The portable `.sxc1lab` boundary stays one project and schema 1, while imported
audio is content-deduplicated before references are connected. M13 browser
state migrates automatically and remains mirrored for rollback. The optimized
artifact passed the complete 136/136 release gate with 240/240 browser
assertions at both root and nested paths, including 320 px, keyboard,
migration, deduplication, project reuse, offline-cache, and Japanese UI
coverage. The byte-identical artifact is deployed at the Vercel mirror and
passed 76/76 assertions against production. See
[`docs/SAMPLE-LIBRARY.md`](docs/SAMPLE-LIBRARY.md).

**M13 Sample Inbox.** Sample Lab accepts an Audacity batch into
an ordered, unassigned tray. Sounds can be auditioned and placed by tap or
desktop drag, filled into empty pads in order, returned to the Inbox, or moved
and swapped across A-D banks without discarding audio. Unassigned sounds travel
inside the existing `.sxc1lab` project, while M12 browser state and project
files migrate without conversion. A pre-handoff review blocks missing local
audio and calls out duplicate destinations, unassigned sounds, duplicate names,
and non-recommended formats. The optimized artifact passed the complete
136/136 release gate with 238/238 browser assertions at both root and nested
paths, including 320 px, keyboard, migration, offline-cache, and Japanese UI
coverage. The byte-identical artifact is deployed at the Vercel mirror and
passed 75/75 assertions against production. See
[`docs/SAMPLE-INBOX.md`](docs/SAMPLE-INBOX.md).

**M12 Sample Lab.** `#/samples` is a deferred, local-first 4×4 pad and bank
planner for Audacity exports. It accepts the same WAV/MP3/FLAC/`.cswp` choices
documented by CASIO, keeps audio in IndexedDB, previews playable files, and
auto-saves pad names, source notes, tags, colour, playback intent, BPM, and mute
group. One binary `.sxc1lab` file carries the plan and original audio to a phone
without an account or upload; Phone handoff then presents one exact bank/pad
destination at a time while CASIO Sampler App performs the hardware assignment.
The module loads only after the trainer is interactive and adds nothing to
the critical boot graph. The shipping artifact passed 136/136 checks with
236/236 browser assertions at both root and nested paths, is deployed at the
Vercel mirror, and passed 74/74 against production. See
[`docs/SAMPLE-LAB.md`](docs/SAMPLE-LAB.md).

**M10 Weekly Pulse.** `#/x/week` turns the learner's saved schedule
and latest 200 coarse learning marks into a seven-day reflection: practice
rhythm, exact upcoming review buckets, recently strengthened skills, repeated
difficulty, and one due-first next focus. The ledger is local-only, travels in
the existing progress passport, and deliberately excludes answer content,
elapsed time, hints, and MIDI/device data. Existing schema-v1/v2 histories
migrate without scheduler loss; detailed weekly history starts with the next
answer. The surface is bilingual semantic DOM with no canvas or graph runtime,
and is covered at 360 px and 320 px. See
[`docs/WEEKLY-PULSE.md`](docs/WEEKLY-PULSE.md).

**M9 phone-ready release.** A subpath-safe web-app manifest and
versioned service worker make the executable shell, WASM runtime, and both text
languages installable and available after the connection disappears. Worker
registration waits until first interactivity; core requests stay network-first
to prevent mixed-version deployments, while manual scans cache only after they
are opened. The existing validated progress envelope now has phone-native file
save/share and file-load controls without an account, backend, or second codec.
Boot diagnostics also record transfer size, connection class, and data-saver
state locally. The product and cache contracts are in
[`docs/PHONE-READY.md`](docs/PHONE-READY.md). Automated real-offline boots pass at
both root and nested paths; physical iPhone/Android acceptance remains the final
field check.

**Today's session coach.** `#/x/today` is the single primary path from Home: a
stable, tab-scoped five-step plan balancing due review, unfinished work, a
prerequisite-aware next step, and at most one actionable Sample Lab task. The
plan prefers a mix of quizzes and drills, stays fixed while the learner works
through it, reconciles course and Lab completions, provides an away-from-device
Skip, and carries a mobile-safe next-step coach into planned exercises. It is a
DOM-only projection over accepted course/progress data and bounded Lab metadata,
so it adds no graph or rendering dependency to `app.wasm`. Contracts are in
[`docs/TODAYS-SESSION.md`](docs/TODAYS-SESSION.md).

**M8 (mastery journey + mobile boot).** `#/x/map` turns the course’s authored
51-deck/50-prerequisite model into a due-first three-action queue and one
progressively disclosed chapter trail. Exercise completion, review durability, due
work, and advisory prerequisites still drive every recommendation, but the route no
longer creates a canvas, WebGL context, camera, or 50-node scene. The same revision
cuts measured startup WASM memory from about 65 MiB to about 20 MiB, begins the WASM
request earlier on supported browsers, and rejects older mobile engines with useful
recovery guidance before downloading `app.wasm`. The implementation and invariants
are recorded in [`docs/MASTERY-MAP.md`](docs/MASTERY-MAP.md).

**M7 (Japanese manual text).** The manuals are now first-class in both languages.
Before this milestone, `uiLang=ja` gave a Japanese *interface* around an English
manual body, with Casio's original page as an **image** beside it — a picture a
Japanese reader cannot select, search, copy or reflow. All **108 pages** of all four
documents (`guide-book` 71, `startup-guide` 15, `midi` 6, `oss` 16) now exist as
Japanese **text** in `translations/<slug>.ja.md`, and the reader renders them with the
same block renderer, the same outline and the same routes as the English. Three
decisions carry it:

* **The manual text left the wasm too.** Adding ~396 KB of Japanese to the
  TH-embedded translations would have blown the frozen 1,000,000-byte gzip ceiling,
  so the manuals became fetched per-language bundles
  (`site/public/content/manuals.{en,ja}.txt`) under the *same* discipline M6's gate
  forced on the course: one bundle grammar, an expectation compiled into `app.wasm`
  (slugs in order, per-document page counts, a whole-bundle FNV-1a/32 fingerprint per
  language), header-language match, every document must parse, **all-or-nothing**
  acceptance, and a visible degraded state on any failure. The wasm *shed* 48,984
  gzipped bytes doing it, so the Japanese text cost the binary nothing — it lands in
  the `ja` bundle.
* **Transcribed, not translated.** Ground truth is the page **image**; the OCR was a
  draft to be corrected against it. The Japanese is what Casio printed — including
  on-device labels in Latin caps (`BANK`, `MIDI IN Ch.`) and the documented on-screen
  misspelling `LOW STRAGE SPACE` — never a back-translation of the English.
* **Structural parity is a check, not a hope.** Each `.ja.md` is page-for-page with
  its English sibling *and* block-for-block: `exercise-check --manual-structural-diff`
  parses both bundles with the reader's own parser and requires identical page
  markers, block-type sequences, heading levels, list/table shapes and
  figure-callout positions — **109/109** (one document/order check plus one per page),
  with three negative controls. A missing `ja` page is a hard failure by name.

Ruling 4's per-document English fallback — a visible, localized note rather than
English silently passed off as Japanese — is still in the app and still enforced, but
**no document uses it any more**, so the gate asserts its *absence*: the
manual-language-of-record stage requires every `!SXC1-DOC` record in the served
`manuals.ja.txt` to say `ja` and the note to exist nowhere, and four ID-pinned
`ja manual:` assertions in **both** full browser stages read real Japanese sentences
off real reading routes with the original page image still reachable on `/ja`.

The gate is now **131 checks** with **227 assertions per live browser stage** (plus
lookup behavior in the 198-assertion synthetic self-test). The figures below identify
historical milestone values where relevant.

**M6 (Japanese).** The course itself is now bilingual. The interface, every
learner-visible string in all **435 exercises across 52 decks**, the device
messages and the ARIA/live-region text all exist in Japanese, selectable at
runtime from the header's **日本語** / **English** button and remembered in
`sxc1.prefs` (`uiLang`, schema v2) plus a small `sxc1.uilang` boot hint. Three
structural decisions carry it:

* **The corpus left the wasm.** Doubling the embedded course would have broken
  the frozen 1,000,000-byte gzip ceiling, so `content/exercises/` is now built
  into two fetched text bundles (`site/public/content/content.{en,ja}.txt`) that
  the app loads at boot behind the same JS-side guard the storage bridge uses —
  a failed fetch degrades visibly (banner + retry) instead of killing boot. This
  supersedes M3's "decks are embedded into the wasm at compile time" below, and
  gave back ~74 KB gzipped before the Japanese UI strings added ~19 KB of it
  back; see [Measured figures](#measured-figures).
* **One file, one id, one registry.** The Japanese lives in the *same*
  `.ex.md` files, on `ja:`-prefixed lines directly under the English they
  replace (`content/EXERCISE-FORMAT.md` section 12), so prompt ids and counts
  are identical across languages **by construction** — which is why progress is
  shared between them and the id registry never had to change. `cite:`,
  `verify:`, `find:` and the other structural fields are language-invariant and
  the build refuses a variant on them.
* **Completeness is enforced, not audited.** A learner-visible piece of a live
  deck with no `ja:` variant is a hard `E-JA-MISSING` issue: `exercise-check`
  exits non-zero and the gate goes red (see
  [Validating exercise content](#validating-exercise-content) and
  [Verification](#verification)). All 52 decks were translated with the original
  Japanese manual pages and `translations/glossary.md` as ground truth for
  terminology, then QA-verified deck by deck against the pages their exercises
  cite.

The gate grew to **109 checks** with **238 assertions per browser stage**, both
stages now completing a real Japanese quiz out of the shipped `ja` bundle — the
numbers as they stood at M6's close; M7 raised both (see above).

**M5 (ship).** The closing milestone: the SEXY ONE rename, a full content audit
(94% topic coverage, twelve citation defects found and fixed, hooks recalibrated
to measured hardware behavior), the M1-era reader debts paid (Index linkified,
list fragmentation fixed, breadcrumbs corrected), keyboard-only completion and
screen-reader labels with focus management on advance, a mobile sweep that
caught a clipped control, and the gate hardened to **99 checks** with pinned
cardinality floors (175 assertions per browser stage, D1–D27) — the numbers as
they stood at M5's close; M6 raised both (see above).

**M4 (live-device verification).** The trainer can now confirm a drill step by
watching the learner perform it on the real hardware: with a Casio SXC-1 connected
over USB-MIDI, clicking **Enable device verification** on a drill page asks the
browser for (sysex-free) MIDI access, and a step that carries a `verify:` hook
confirms itself the moment the matching message arrives — see
[Device verification](#device-verification) below for the guarantees, which are the
point: strictly progressive enhancement, Chromium-only, off until the learner
clicks, manual confirmation still the default first-class path everywhere, and
MIDI data never leaving the browser. M1's reader, M2's engine and M3's course,
progress persistence and spaced repetition are unchanged and fully intact — on any
browser without Web MIDI the app looks and behaves exactly as M3 did (the only DOM
difference is one always-hidden `#sxc1-device-state` diagnostics node). See
[`briefs/M4-plan.md`](briefs/M4-plan.md) for the design this milestone implements
and [`briefs/M4-manifest.json`](briefs/M4-manifest.json) for the task-by-task
breakdown. `check-site.sh` reached **95 checks** at M4's close (up from M3's 80;
now 99 — see the M5 entry above), and the headless-browser driver asserts
**160 assertions per served stage** at that point (now a pinned 175-assertion
floor incl. the D1–D27 suite) — the device suite driven entirely through a committed fake with no
hardware in the loop (see [Verification](#verification)); the one thing automation
cannot produce, a walk with the real unit in hand, has its own owner's checklist
in [`docs/M4-device-test-protocol.md`](docs/M4-device-test-protocol.md).

**M3 (full course + memory).** The site is now a reader, a trainer, *and* a spaced-
repetition study tool. M1's manual reader and M2's exercise engine are unchanged and
fully intact; M3 adds the rest of the course content, persists progress across visits,
and resurfaces due prompts on a schedule. See [`PLAN.md`](PLAN.md) for the full
milestone roadmap, [`briefs/M3-plan.md`](briefs/M3-plan.md) for the design this
milestone implements, and [`briefs/M3-manifest.json`](briefs/M3-manifest.json) for the
task-by-task breakdown a Sonnet swarm built it from.

**Course content.** M3 originally expanded the seed to 52 decks / 435 exercises; the
current operation-first course ships **51 decks / 355 exercises** after retiring 81
printed-manual lookups and two guide-context trivia cards. Decks are grouped into **six chapters**
(chapter 0, `Front matter`, plus five numbered `Part: …` chapters mirroring the guide
book's own progression — Preparation, Pad play, Sampling, Sequencer, Leveling up) and
tagged `tier: intro | core | stretch` (14 / 30 / 6 decks respectively) for course-map
navigation; 36 decks also carry an optional `requires:` list of deck-slug prerequisites.
Decks were embedded into the wasm at compile time through M5 — `INDEX`-driven, one
Template Haskell splice for the whole directory rather than one per file — so an author
adding deck 53 only had to add it to `INDEX`. **M6 moved them out of the wasm
entirely** (see the M6 entry above): `INDEX` is still the single list an author edits,
but it is now read at *build* time by `scripts/emit-content-bundles.py`, which writes
the two fetched bundles.

**Guided interface.** Home keeps the phone QR visible, then presents two large
choices: a green recommended path directly to the next due or incomplete card, and a
red alternate path that reveals the course outline, manuals and progress utilities.
Completed cards repeat the same two-way pattern with green **next card** and red
**repeat card** actions. Every quiz now requires an actual answer. The 128 compact
flashcards synthesize a stable two-option choice from their authored correct answer and
plausible distractor; larger multiple-choice questions keep their full option sets as
native radio/checkbox cards. The active decision surface is always a pair: **Check
answer / I’m not sure**, replaced after feedback by **Good / Easy** or **Again /
Hard**, with the selected grade driving spaced repetition and continuing immediately.

The rationale and regression anchors for this UX are recorded in
[`docs/UX-HANDOFF-2026-08-10.md`](docs/UX-HANDOFF-2026-08-10.md).

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
*unoptimized* default build — measured at M3's close, `./scripts/build-site.sh` (no
flags) produced an `app.wasm` that gzips to roughly **1,094,000–1,097,000 bytes**
(run-to-run jitter of a few KB; consistently ~94–97 KB over budget). Per `PLAN.md`'s
"Size ruling" (2026-08-07, coordinator decision, explicitly flagged for Codex scrutiny
at the M3 gate), **the shipping artifact is the `wasm-opt`-optimized build**:
`./scripts/build-site.sh --optimize` runs `wasm-opt` then `wasm-tools strip` on
`app.wasm`. The exact `wasm-opt` flags are `--detect-features -Oz --converge` (a
2026-08-07 amendment to the Size ruling, adopted at the start of M4: the original
`-all -O2` left too little headroom for M4's budget, and `-all` at `-Oz` emitted an
experimental heap-type encoding shipping V8 rejects — see the comment at the
`wasm-opt` call in `scripts/build-site.sh`); at M3's close, under the original
`-all -O2` flags, the optimized artifact measured **907,575–908,037 bytes gzipped**,
and the current M4 figure is in [Measured figures](#measured-figures) — either way
comfortably under the ceiling, and smaller than M2's entire footprint. `.github/workflows/site.yml`
now builds with `--optimize` for exactly this reason (see
[Deployment](#deployment)); `./scripts/build-site.sh`'s own default stays unoptimized
(`--optimize` remains opt-in, never assumed) so local iteration stays fast, and
`check-site.sh` always measures whatever is *actually* sitting at `site/public/app.wasm`
— optimized or not — never a hardcoded assumption about which flavour was built. The
wasm-opt lever was adopted only after empirical scrutiny: the M3 designer could not make
it miscompile (byte-identical `exe:*-check --self-test` output either way, and the real
optimized app has passed every headless-browser assertion this project runs, repeatedly).
`./scripts/check-site.sh --optimized` demonstrates an optimize-then-strip pass on
demand, against a *copy* of whatever is at `--dir` (never mutating the original), and
re-runs the entire check suite against it, using the same `--detect-features -Oz
--converge` flags as the shipping build (aligned with the Size-ruling amendment at M4's
close); see that flag's own `--help` text for the full story.

`check-site.sh` grew to **80 checks** at M3's close (up from M2's 71; **95** as of M4 —
see above), including the two new checker binaries below, the `--optimized` mode just
described, and a "storage refused" check that simulates a throwing `localStorage` in a
real headless-Chrome run and asserts the app still boots and reports `available=false`
rather than dying at boot.

**The two new checker binaries.** `exe:progress-check` (the pure spaced-repetition core:
scheduler, codec, migration mechanism) passes **69/69** self-test assertions across 11
groups; `exe:registry-check` (PromptId-stability: `content/id-registry.tsv` against the
real corpus) passes **7/7** against the real tree and **15/15** in `--self-test`. Both
are documented in detail below.

**The id registry.** [`content/id-registry.tsv`](content/id-registry.tsv) now tracks all
**440** exercise ids ever minted (435 live, 5 tombstoned) so a drill that gains or loses
a step doesn't silently orphan a learner's saved progress — see
[Progress, spaced repetition and the id registry](#progress-spaced-repetition-and-the-id-registry).

One thing M3 still deliberately left undone, already seamed rather than left as an open
design question, is exactly what M4 has now filled: **device verification**. M3 wired an
explicit no-op `DeviceVerifier` (`noDeviceVerifier`) in `site/app/Main.hs` so M4 would
have a seam to fill rather than a design to invent; M4's `site/app/Device/Midi.hs` now
provides the real WebMIDI-backed implementation behind that same seam — see the M4
entry at the top of this section and [Device verification](#device-verification) below.

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
and verifying M3, and re-run end to end for M4 and again at M5's close: `install-toolchain.sh` recognised the
already-installed toolchain and returned in well under a second; a from-scratch
`site/dist-newstyle` build (package store still warm from the toolchain install; now
compiling five executables — `exe:app`, `exe:content-check`, `exe:exercise-check`,
`exe:progress-check` and `exe:registry-check` — instead of M1's three) took 27 s at
M3's close; `check-site.sh` ran all 99 checks (the M5 total) — including both the origin-root and
GitHub-Pages-sub-path browser sweeps of all 108 page routes, the two M3 checker
binaries, the storage-refused simulation and the D1–D27 device suite — and
printed `check-site: result=complete`; and `serve-site.sh` served
`site/public/index.html` over plain HTTP with a `200`. This quickstart builds the plain,
**unoptimized** `app.wasm` (`build-site.sh`'s own default); see
[Status](#status)/[Deployment](#deployment) for why CI instead builds with `--optimize`.

## How the manuals get into the app

<a id="how-the-manuals-get-into-the-app"></a>

`translations/<slug>.md` (English) and `translations/<slug>.ja.md` (Japanese, M7) are
emitted by `scripts/emit-content-bundles.py` into **two per-language text bundles**,
`site/public/content/manuals.{en,ja}.txt`, which the static shell fetches **before**
the wasm reactor starts and hands to the app through the same JS-side-guarded
`window.__sxc1Content` bridge the exercise bundles use. Each bundle is one
`!SXC1-BUNDLE v1 <lang> <count>` header plus one `!SXC1-DOC <slug> <lang> <pages>`
record per document, and the text inside a record is the `.md` file **byte for byte**.
It is then parsed **lazily, at runtime**, by the miso-free `sxc1-content` library
(`site/src/SXC1/`) — the same parser, the same `Doc`/`Page`/`Block` model and the same
laziness contract the compile-time embedding had.

Acceptance is **all-or-nothing** and is checked against `site/app/Bundle/Manifest.hs`
— a *generated* module compiled **into `app.wasm`** that records the document slugs in
order, each document's page count and one FNV-1a/32 fingerprint per language over the
whole bundle. The requested language must match the header's, the record list must
equal the manifest's exactly, the declared count must match both, the fingerprint must
match this build's, and every document must *parse* to exactly the page count the
manifest promises. Anything else renders the visible degraded state (`#sxc1-content-error`
plus `#sxc1-manual-degraded` with a retry) instead of a quietly smaller manual. The
expectation deliberately does **not** travel with the bundle: a bundle attesting to
itself proves only internal consistency, so a complete *older* build would satisfy it.

Per document, the `!SXC1-DOC` line names the language **that document's own text** is
in. A `ja` bundle may legally carry `en` for a document with no `.ja.md` yet, and the
reader then renders ruling 4's visible localized note above an `lang="en"`-marked body
— never a blank page, never English passed off as Japanese. As of M7 **no document
takes that path**: all four records read `ja`.

`site/sxc1-trainer.cabal` still declares:

```
extra-source-files: ../translations/*.md
```

This line is load-bearing, not decorative — now for `exe:content-check`, which is the
one component that still TH-embeds the translations (`site/test/EmbeddedTranslations.hs`;
its `--dump-source` is check-site's stale-*build* detector, and that only works if the
bytes are fixed at compile time). `addDependentFile` alone makes GHC recompile
when a translation changes, but only if cabal decides to *invoke* GHC in the first
place, and cabal's own staleness check has no idea a Haskell module depends on a file
three directories away unless `extra-source-files` tells it so. Without this line,
editing a translation and re-running `wasm32-wasi-cabal build` does nothing — cabal
reports the package up to date and never calls GHC. With it, cabal notices the mtime
change and GHC reports `[../translations/guide-book.md changed]` before recompiling.
The glob covers `*.ja.md` too, so a Japanese page edit is just as visible. On the
*shipped* path the equivalent guarantee is stronger and needs no recompilation at all:
`check-site.sh` requires `manuals.{en,ja}.txt` to be byte-identical to a fresh emission
from `translations/`, and requires `site/app/Bundle/Manifest.hs` to be byte-identical
to a fresh regeneration — so a translation edited without rebuilding is red either way.
The whole content-editing workflow is unchanged: edit a file under `translations/`,
re-run `./scripts/build-site.sh`.

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
committed 443-id master plan every exercise id is drawn from (`q-`/`d-`/`l-` prefixed for
quiz/drill/lookup, chapter-numbered, sequenced). Ids in that inventory are permanent —
never renumbered, only retired-with-a-tombstone — because M3 keys a learner's persisted
progress to them; an id that moved out from under a learner's history would silently
orphan it.

Neither corpus is compiled into the wasm any more — the decks left in M6 and the
manual text in M7, both into fetched per-language bundles (see
[How the manuals get into the app](#how-the-manuals-get-into-the-app)) — but the
content-editing workflow is unchanged either way: edit a `.ex.md` file (or `INDEX`),
re-run `./scripts/build-site.sh`, which re-emits the bundles *and* the wasm-embedded
expectation they are checked against. The compile-time design they replaced is
recorded here because its lesson still binds the emitter: as of M3 embedding was a
single compile-time splice, not one hand-written literal per deck: `SXC1.Content.Embed`'s
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

The shipped operation-first course is **51 decks / 355 exercises**: 6 `Front matter`,
4 `Preparation`, 9 `Pad play`, 7 `Sampling`, 9 `Sequencer`, 16 `Leveling up`; 14 decks
`tier: intro`, 31 `core`, 6 `stretch`; 37 decks declare at least one `requires:`
prerequisite. All 81 manual-navigation lookups and two remaining guide-context trivia
questions are retired with permanent ID tombstones: the app links sources directly,
so the learner is tested on the SXC-1 rather than on remembering the printed book.

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
machine, against the full 51-deck/355-exercise course: the real-content run reports `0
issue(s)`, `--self-test` passes `465/465` checks, `--fixtures` reports `56/56 fixtures
passed`, and `--list-codes` prints 53 codes (up from M2's 48 — M3 added
`E-DECK-TIER-UNKNOWN`, `E-DECK-REQUIRES-UNKNOWN`, `E-DECK-REQUIRES-CYCLE` and one more
for id-registry/inventory cross-checking, and M6 added `E-JA-MISSING`; run
`--list-codes` yourself for the exact, current list rather than trusting this count to
stay still). Both directory flags default correctly from either the repository root or
`site/`, so the same commands work from both.
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
   `content/exercises/*.ex.md` (never from the Haskell side), and the numbers the
   running app computes from the bundle it *fetched at boot*, read out of
   `#sxc1-exercise-stats` in the live DOM, must all agree, or `check-site.sh` fails red
   instead of silently shipping a stale or miscounted build. (Since M6 the same
   comparison also catches a stale **bundle**: `check-site.sh` re-emits both bundles
   from `content/exercises/` and requires the shipped files to match byte for byte.)

**Japanese completeness is part of this gate (M6).** Every learner-visible piece of
every live deck — deck title, `summary:`, deck intro prose, exercise titles, body
prose, *every* choice option, `### Why`/`### Hint`/`### Answer` prose, drill step prose
and every step `check:` — must carry a `ja:` variant, or `exercise-check` reports
**`E-JA-MISSING`** and exits non-zero. The rule is the bundle emitter's own
substitution rule read backwards (the line directly below a learner-visible unit must
be a `ja:` line), implemented independently in the checker, so "the check is green" and
"that text is really Japanese in `content.ja.txt`" are the same statement. The
exclusions are structural and exhaustive — the `### Why`-style role headings (the UI
localizes those labels) and the language-invariant fields (`cite:`, `find:`, `verify:`,
`type:`, `id:`, `deck:`, `chapter:`, `tier:`, `tags:`, `requires:`, `limit:`) — with no
per-file opt-out anywhere. `--self-test` group 22 both sweeps all 51 live decks and
carries one negative control per learner-visible kind (delete that kind's `ja:` line and
exactly one `E-JA-MISSING` must fire, on the right line, naming the right kind), and
`content/fixtures/dirs/E-JA-MISSING--untranslated-option/` is the standing falsifying
example: a deck translated except for one option.

## Device verification

<a id="device-verification"></a>

New in M4: when a drill step instructs an action the SXC-1 reports over MIDI — press
the `A` bank button, tap pad 1 — the trainer can watch the learner do it on the real
unit and confirm the step automatically, with no click. **37** drill steps across the
course carry a `verify:` hook (e.g. `verify: cc 80 127`, `verify: pad 1 bank A`); the
six seed hooks live in the drills at `#/x/pad-01/d-2-01`, `#/x/pad-03/d-2-02` and
`#/x/pad-07/d-2-09`. Every fact the matcher relies on — CC numbers, note numbers,
channels — comes from [`translations/midi.md`](translations/midi.md), the SXC-1's own
MIDI implementation chart. What follows is stated as guarantees, not goals; each one is
enforced by a named check (see [Verification](#verification)):

- **Progressive enhancement, Chromium-only.** Web MIDI exists in Chromium-family
  browsers (desktop Chrome or Edge) only. On Firefox, Safari, or anything else without
  it, the device panel never renders and the app looks and behaves exactly as M3 did —
  the only DOM difference on such a browser is the always-hidden `#sxc1-device-state`
  diagnostics node.
- **Off until the learner clicks.** `navigator.requestMIDIAccess` is called from
  exactly one place in the whole codebase, reachable only from the explicit
  **Enable device verification** button (`#btn-device-enable`) on a drill page — never
  at boot, never from feature detection. The browser suite proves both directions:
  zero permission requests before the click (D3), exactly one after it (D5).
- **Manual confirmation is and remains the default path.** The ordinary **Confirm**
  button works identically in every device state — unsupported, denied, granted,
  device unplugged mid-drill — and no drill can ever be blocked by MIDI. Device
  confirmation is a convenience layered on top of the M2/M3 engine, never a gate.
- **No sysex.** MIDI access is requested with `{sysex: false}` — a structural check
  proves that is the only shape the call site can take — and system-exclusive
  messages are dropped at decode. The fake harness records every request's `sysex`
  flag, so a sysex request anywhere would turn the suite red.
- **MIDI data never leaves the browser.** Received bytes live in the app's state and
  the hidden `#sxc1-device-state` node and go nowhere else: no fetch, no storage, no
  console output, and nothing added to the M3 progress wire format or its sink. A CDP
  network assertion (D21) watches an entire device scenario end to end and requires
  zero network requests beyond the app's own assets.

Have the actual hardware? [`docs/M4-device-test-protocol.md`](docs/M4-device-test-protocol.md)
is the owner's fifteen-minute walk through the feature with a real SXC-1 in hand — the
one piece of M4 evidence the automated suite below cannot produce.

## Verification

`check-site.sh` computes the same corpus statistics (character/line/page counts,
heading/table/figure counts, section and subsection counts, PART titles, …) **three
independent ways** and fails if any two disagree:

1. **The real Haskell parser** — `exe:content-check`, a wasm32-wasi *command* module
   (not the reactor-model `exe:app`) run on the host by `wasm-run.mjs`, over its own
   TH-embedded copy of the manual corpus. Both corpora are *fetched* by the app now
   (decks since M6, manual text since M7) and each has its own bundle-freshness check;
   the checker keeps a compile-time copy on purpose, because that is what makes its
   `--dump-source` byte comparison a stale-**build** detector.
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

**How the device checks are tested without a device.** Real headless Chrome exposes
`navigator.requestMIDIAccess` but always **rejects** the permission request, so nothing
in this harness can ever be granted real MIDI access. The device suite therefore runs
against [`scripts/fake-midi.js`](scripts/fake-midi.js) — a committed, reviewable fake of
the Web MIDI surface, not a string inside the driver — which `scripts/browser-check.mjs`
pre-loads into a **freshly created** CDP target with
`Page.addScriptToEvaluateOnNewDocument`, so it is installed before the app boots and the
app's own feature detection sees it as the genuine article. Twenty-seven assertions
(D1–D27; D26/D27 are M5's focus-management and screen-reader additions) drive the
full matrix through it: grant, deny and API-absent outcomes,
hot-plug and unplug, multi-port binding, exactly-once confirmation, and the negative
controls that keep a green run honest — a **wrong CC**, a **wrong CC value**, a
**wrong channel** and a **wrong note** must each be *delivered* and must each *fail* to
confirm the step. Delivery is proven, not assumed: the fake's `emit` returns the number
of handlers actually invoked, so "did not confirm" can never be confused with "nobody
was listening". The **no-fake control** (D20) matters most: it runs the same enable
flow in a target with *no* fake injected at all, and requires it to land in "denied"
and never confirm — because real headless Chrome denies the permission, a positive
result anywhere else in the suite can only have come from the fake's scripted
messages, never from the real API by accident. All of this sits inside
`check-site.sh`'s ordinary gate (**131 checks**): the browser driver asserts
**227 assertions per served stage** (**198** in `node scripts/browser-check.mjs
--self-test`), and a named check-site check independently counts the 27 distinct
`ok - D<n>` lines in the root stage's captured output — so silently unplugging the
device suite from the driver turns check-site red even while the browser stages
themselves stay green. The device sentences are asserted in **both languages**: the
Japanese status, waiting and confirmed lines (including the JA renderer for a
`verify:` spec) are pinned by their own stage. `check-site.sh` also carries M4-specific structural checks: the
fake exists and names its whole driver surface, the fake is **never** shipped (no
`fake-midi.js` under `site/public/` or `site/static/`), `requestMIDIAccess` has exactly
one call site (in `site/app/Device/Midi.hs`) carrying `sysex: False`, no network-egress
primitive appears anywhere in `site/app/`, and the frozen size ceiling and M4 budget
file are intact and authorised.

**How both languages are proven (M6).** Being able to *serve* a Japanese bundle is not
the same as the Japanese course working, so the gate checks the course, not the file:

* **The UI, twice.** The entire exercise/a11y assertion set runs a second time with
  `uiLang=ja` — the same assertion code parameterised by language, never a duplicated
  copy — so every learner-visible string it pins (grading feedback, the device
  sentences, ARIA names, the keyboard-only flows) is pinned in Japanese too.
* **The switch itself.** A dedicated stage drives a *fresh profile* through the real
  header button: boot English fetching `content.en.txt`, click **日本語**, and the app
  persists the preference and reloads — the reload *is* the refetch, proven by the new
  document's own resource entries naming `content.ja.txt` and not `content.en.txt` —
  then Japanese header, the one-time "Japanese first" suggestion, a Japanese device
  flow, and back to English.
* **The course, from the shipped bundle.** Five assertions in both full stages open the
  Japanese course the site actually ships: `#sxc1-exercise-stats` must report 51 decks
  and 355 exercises *and* the pinned deck's **Japanese** title; the deck index card,
  deck page title and deck `summary:` must be the corpus Japanese; a real corpus quiz
  must render its Japanese title, question and both pinned option labels, and — clicked
  **by its Japanese label** — grade to the Japanese "correct" feedback with the Japanese
  rationale; and a real corpus drill step must show its Japanese `check:` sentence.
  Every expectation is a literal copied out of `content/exercises/`, never derived from
  the bundle under test: that is what makes a silently English-fallback `ja` bundle
  (the emitter's documented degenerate case, and exactly what `content.ja.txt` was
  before the decks were translated) turn red instead of agreeing with itself. It was
  demonstrated red that way — a served copy whose `content.ja.txt` was the English
  emission relabelled `ja` failed exactly those five assertions and nothing else — and
  a named check-site check counts them *by name* in each stage's capture, so removing
  them cannot hide under the per-stage assertion floor.

**How the Japanese MANUALS are proven (M7).** Shipping 108 pages of Japanese is not
the same as a Japanese reader getting them, and "the file is bigger" is not evidence.
Three checks carry the claim, and each was demonstrated red before it was trusted:

* **Structural parity, by the reader's own parser.** `exercise-check
  --manual-structural-diff <en-bundle> <ja-bundle>` parses **both** freshly emitted
  manual bundles with `SXC1.Content.Markdown.mkDoc` — the exact function
  `View.Pages.mkManuals` calls on every fetched document, so the checker and the reader
  cannot drift — and requires, per document per page: the same page markers in the same
  order, the same block-type sequence, the same heading levels, the same list and table
  shapes, and the same figure-callout positions. Only *text* may differ. A `ja` page
  **missing** while its English page exists is a hard failure naming the document and
  the page. The reported total is 1 + one per page (**109/109**), so a document quietly
  dropped from either bundle cannot hide behind a smaller all-green run. Its three
  negative controls run in the same check, each on a copy of the fresh `ja` emission
  and each grep-confirmed in first: a whole-line `*[Figure: …]*` callout stripped to
  prose (`en=figure callout` vs `ja=paragraph`), a `###` heading dropped to `##`
  (`heading level 3` vs `heading level 2`), and one whole `<!-- page N -->` section
  deleted (`page 3: MISSING from the ja document`). All three exit non-zero and name
  exactly the document, page and position.
* **Real Japanese on real routes, in both full stages.** Four ID-pinned `ja manual:`
  assertions (JAM1–JAM4) run inside the `uiLang=ja` flow of *both* served stages:
  guide-book p.2 renders its pinned Japanese heading and sentence with
  `document.documentElement.lang="ja"`, no fallback note and no `lang` override on the
  body; `midi` p.1 renders its own pinned sentence **and still carries `MIDI IN Ch.` in
  Latin caps** (ruling 3); on the `/ja` route the original page image is still there
  beside the Japanese text and the scan URL really fetches (a same-origin `fetch` of
  `#ja-image`'s own `src`, 200 + non-trivial bytes); and the manual TOC renders the
  Japanese outline. Every expectation is a literal copied out of
  `translations/<slug>.ja.md`, never read off the page under test — so an English
  fallback `ja` bundle turns them red instead of agreeing with itself. It was
  demonstrated red exactly that way: rebuilding against a scratch `translations/` with
  the `.ja.md` files removed (and the matching manifest regenerated, so the app still
  *accepts* the bundle) failed all four, while removing only `guide-book.ja.md` failed
  JAM1/JAM3/JAM4 and left JAM2 green. A named check-site check counts them **by ID** in
  each stage's capture.
* **The fallback note, now proven by its absence.** The per-document English fallback
  of ruling 4 is unchanged in the app, but no document uses it, so the
  manual-language-of-record stage (`browser-check --check-manual-fallback`, **5/5**,
  IDs MF1–MF5) asserts that under `ja` `#sxc1-manual-fallback` exists **nowhere** — no
  reading route, no TOC, no home card — while all four documents render their own
  pinned Japanese sentence. The mechanism is kept honest rather than retired: the stage
  first requires every `!SXC1-DOC` record in the served `manuals.ja.txt` to say `ja`,
  so a future untranslated document turns the stage red *by name* instead of asserting
  an absence that no longer holds; the emitter half (adding or removing a `.ja.md`
  flips exactly that document's record) has its own check; and the note-**present**
  direction was re-demonstrated on real served bytes against the scratch build above,
  where the note appeared for `guide-book` only and for none of the other three.

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
SXC1PROGRESS <TAB> <schemaVersion>          (currently 3)
M <TAB> streakDay <TAB> streakLen <TAB> firstDay <TAB> lastPrompt
R <TAB> promptId <TAB> reps <TAB> lapses <TAB> ease <TAB> interval <TAB> due <TAB> lastSeen <TAB> seen
D <TAB> exerciseId <TAB> completions
W <TAB> day <TAB> deckId <TAB> exerciseId <TAB> promptId-or-- <TAB> grade
```

The schema version lives **inside the first line of the payload itself**, not in the
storage key name or anywhere external to the blob — so a copied blob (see Export/import
below) is fully self-describing: nothing outside the text you copy is needed to read it
back, on this device or another one. *Within a blob whose header version this build
understands*, unknown leading tags are **skipped, not rejected** — as is a truncated or
malformed individual `R`/`D`/`M` line: only that one record is dropped, never its
siblings. That lenience never applies across schema versions: a blob whose **header**
declares a version newer than the build's `currentSchema` is `DecodeCorrupt` outright
(fail-closed, see below), never partially read via tag-skipping.

**The migration story.** `SXC1.Progress.Codec.migrateWith` walks a decoded version `v`
forward, `v -> v+1 -> ... -> currentSchema` (currently `3`; v1 -> v2 added
the M line's `lastPrompt` column and v2 -> v3 added the bounded Weekly Pulse
ledger), applying one step per hop
from a step table; a hop with no registered step is `DecodeCorrupt`, never a silently
dropped history. Migration is forward-only by construction — there is no downgrade path,
by design: an older build encountering a newer schema version fails closed
(`DecodeCorrupt`, the header rule above), it does not attempt a partial read.
`productionSteps` carries both production steps: v1 → v2 and v2 → v3 are identities
(the body parser already defaults `lastPrompt` to empty for a three-field v1 M line),
with the pulse ledger likewise defaulting to empty. The mechanism itself was exercised by
`exe:progress-check`'s self-test (synthetic schema-0 blob, test-only step table) since
before v2 existed, which is why the first real migration needed no new machinery.

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
to one of four grades. M11 events preserve the learner's explicit Again/Hard/Good/Easy
choice through `gradeOfReview`; older events without that field retain the following
`gradeOfOutcome` inference for backwards-compatible replay:

| Outcome | Condition | Grade |
|---|---|---|
| `Incorrect` or `Skipped` | — | `GAgain` (due again today) |
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
{"format":"sxc1-progress","schema":3,"exportedAt":"<stamp>","payload":"<wire text>"}
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
uploaded anywhere — there is no analytics, no telemetry, no backend of any kind.
Progress moves only through a deliberate progress export; sounds move only through a
deliberate audio share/download or `.sxc1lab` project export.

**The id registry.** [`content/id-registry.tsv`](content/id-registry.tsv) is a committed,
tab-separated file tracking every exercise id **ever minted**, live or retired — 443 rows
now (355 live, 88 tombstoned; M3 began with 435 live and 5 tombstones), one row per id:
the id itself, its `promptCount`
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
                                         # (355 live corpus / 443 registry).
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
| `#/m/<slug>/p/<n>` | Page `n` of that manual, in the reader's language (English, or Japanese since M7) |
| `#/m/<slug>/p/<n>/ja` | The same page, with the original-Japanese-page **scan** panel already open |

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
├── docs/                        owner-facing documents: M4-device-test-protocol.md,
│                                 the real-hardware device-verification test walk
├── scripts/
│   ├── install-toolchain.sh     one-time GHC-wasm toolchain install ($HOME/.ghc-wasm)
│   ├── build-site.sh            site/app + site/src + site/static -> site/public/
│   ├── serve-site.sh            python3 -m http.server on 127.0.0.1
│   ├── check-site.sh            structural + content + headless-browser checks
│   ├── browser-check.mjs        the zero-npm-deps CDP driver check-site.sh calls
│   ├── fake-midi.js             the committed Web MIDI fake browser-check.mjs
│   │                             pre-loads for the D1-D27 device suite (test
│   │                             harness only -- never shipped to site/public/)
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
│   ├── app/                     the Miso app (Main.hs, View/, Exercises/, Progress/,
│   │                             Device/) -- depends on the library; Progress/Store.hs
│   │                             is the one module allowed to touch localStorage;
│   │                             site/app/Device/ (Midi.hs) is M4's WebMIDI hub, the
│   │                             only place navigator.requestMIDIAccess is ever called
│   ├── test/                    CheckContent.hs, CheckExercises.hs, CheckProgress.hs,
│   │                             CheckRegistry.hs -- the four corpus/engine validators
│   │                             (exe:content-check, exe:exercise-check,
│   │                             exe:progress-check, exe:registry-check)
│   ├── static/                  HTML shell, boot loader, the __sxc1Storage JS bridge,
│   │                             vendored WASI shim, pages/<slug>/page-NN.webp
│   │                             (committed JA page images)
│   └── public/                  build output (gitignored, never committed)
├── manuals/                     original Japanese Casio PDFs (source material)
├── translations/                <slug>.md  -- the English translation of each manual
│                                 <slug>.ja.md -- the Japanese TEXT of the same pages
│                                 (M7, transcribed from the page images); both are
│                                 emitted into content/manuals.{en,ja}.txt at build
├── content/
│   ├── EXERCISE-FORMAT.md       the .ex.md authoring guide -- the only doc a content
│   │                             author needs
│   ├── exercise-inventory.md    the committed 443-id master exercise plan
│   ├── id-registry.tsv          the 443-row PromptId-stability registry (promptCount +
│   │                             the tombstone process; see exe:registry-check)
│   ├── terminology-rules.tsv    house style rules exercise-check enforces
│   ├── exercises/                51 .ex.md decks + INDEX (emitted into the fetched
│   │                             content/content.{en,ja}.txt bundles at build time)
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
above. The same built `site/public/` bundle is also deployed to Vercel (project
`sexy-one`), at <https://sexy-one-gray.vercel.app/>.

## Measured figures

<a id="measured-figures"></a>

Measured on this machine (Linux x86\_64, 4 cores, 7.6 GiB RAM), against the current
51-deck/355-exercise course **and all 108 manual pages** in **both languages** (rows
measured at an earlier milestone's close say so):

| Metric | Value |
|---|---|
| Cold build (`site/dist-newstyle` absent, package store warm; 5 executables; measured at M3's close) | 27s |
| Warm build, unoptimized (nothing changed) | <1s |
| Warm build, `--optimize` (nothing changed — `wasm-opt`/strip still re-run every time; `-Oz --converge` iterates to a fixed point, so it costs more than M3's `-O2` ~5s: the `wasm-opt` pass alone measures ≈11s on this machine) | ~15s |
| `app.wasm`, unoptimized default build (`build-site.sh`, no flags; measured at M3's close — M4 ships only the optimized flavour, and grew, so this is still *over* the ceiling) | ≈5,220,000 bytes raw / **≈1,094,000–1,097,000 bytes gzipped** — *over* the 1,000,000 ceiling |
| `app.wasm`, `--optimize`d build (`build-site.sh --optimize` — **the shipping artifact**) | 2,380,327 bytes raw / **865,795 bytes gzipped** |
| `app.wasm` at M6's close, for comparison (the pre-manual-externalization baseline `briefs/M7-budget.json` records as `m6_final`) | 2,439,911 bytes raw / 887,732 bytes gzipped |
| Current gzip delta over the M6 close after manual externalization and subsequent UI revisions | **−21,937 bytes** — beyond the M11-rebaselined `M7_SHRINK_MIN` of 20,000 |
| `app.wasm` at M5's close, for comparison (the pre-externalization baseline `briefs/M6-budget.json` records as `m5_final`) | 2,662,016 bytes raw / 933,305 bytes gzipped |
| M6 gzip delta over the M5 close: corpus externalization **−73,560**, then the JA UI string table **+19,416** | **−54,144 bytes** net — no new wasm ceiling was granted or needed |
| `content/content.en.txt` (the EN exercise bundle the app fetches at boot) | 255,177 bytes raw / **69,008 bytes gzipped** |
| `content/content.ja.txt` (the JA bundle — real Japanese for all 51 live decks, not an EN fallback) | 320,038 bytes raw / **81,912 bytes gzipped** |
| Combined exercise-bundle gzip against `M6_BUNDLE_CEILING` (pinned in `check-site.sh`, recorded in `briefs/M6-budget.json`, logged to `state/bundle-ledger.tsv` every run) | **150,920 / 300,000 bytes** — 149,080 of headroom |
| `content/manuals.en.txt` (the EN manual bundle — all four documents, 108 pages) | 193,578 bytes raw / **57,818 bytes gzipped** |
| `content/manuals.ja.txt` (the JA manual bundle — real Japanese for all 108 pages, all four `!SXC1-DOC` records `ja`, not an EN fallback) | 217,067 bytes raw / **60,205 bytes gzipped** |
| Combined manual-bundle gzip against `M7_MANUAL_BUNDLE_CEILING` (pinned in `check-site.sh`, recorded in `briefs/M7-budget.json`, logged to `state/manual-bundle-ledger.tsv` every run) | **118,023 / 250,000 bytes** — 131,977 of headroom |
| **All four language bundles fetched at boot**, against `M7_BUNDLE_TOTAL_CEILING` (= 300,000 + 250,000, asserted with its arithmetic in `check-site.sh`) | **268,943 / 550,000 bytes** — 281,057 of headroom |
| M4 gzip delta over the M3 baseline (890,713 bytes, `briefs/M4-budget.json`; M4 closed at 927,008) | **+36,295 bytes** — inside M4's 42,000-byte budget |
| M5 gzip delta over the M4 close (927,008 bytes; ruling in `briefs/M5-budget.json`, constants pinned in `check-site.sh`) | **+6,297 bytes** — under the M5 task-local 987,008-byte ceiling (headroom 53,703) |
| Frozen gzip ceiling (`WASM_GZIP_CEILING_BYTES` in `scripts/check-site.sh`, unchanged since M1) | **1,000,000 bytes** — 134,205 bytes of headroom remain |
| `ghc_wasm_jsffi.js` | 49,500 bytes raw / 10,307 bytes gzipped (identical either way — `wasm-opt` only touches `app.wasm`) |
| Deferred Sample Lab island | `sample-lab.js` 152,306 raw / **37,755 gzip** + on-demand `sample-check-worker.js` 5,958 raw / **2,201 gzip** = **39,956 / 50,000 gzip** |
| Committed page images (`site/static/pages/`, 108 files) | 9,375,040 bytes (≈9.4 MB, unchanged since M1) |
| `site/public/` total, after `build-site.sh --optimize` (`du -sb`) | 13,266,435 bytes (≈13.3 MB) |
| `check-site.sh`, full run (**139** checks, both browser sweeps of 108 routes, **242** browser assertions per served stage incl. real offline boot, One Practice Home's bounded Lab projection/ledger/Skip, Sound Check replacement across projects, resumable Phone Bridge receipt, Sample Library/Inbox migration, deduplication and project round-trip, progress passport, Today's Session, Weekly Pulse, the bilingual mastery journey, mobile boot/memory guards, visual-card and flashcard-grade flows, hands-on Skip, D1–D27 device suite, JA course and manuals) | ≈2–3 min |
| Per-stage browser floor / JA course floor / JA manual floor (pinned in `check-site.sh`; floors, never equalities) | **242** assertions per stage / **9** named `ja course:` (JAC1–JAC9, including mastery, Weekly Pulse, Sample Inbox/Phone Bridge, and Sample Library) / **4** named `ja manual:` (JAM1–JAM4) per stage |
| `exe:exercise-check --bundle-structural-diff` (EN/JA exercise corpus) / `--manual-structural-diff` (EN/JA manual documents, the reader's own parser) | **52/52** checks (1 + one per live deck) / **109/109** checks (1 + one per page), each with its own negative controls |
| `node scripts/browser-check.mjs --self-test` / `--self-test-negative` | **198/198** assertions / **42/42** sabotage passes, each catching exactly its own mapped assertion(s) |
| `exe:content-check --self-test` | **412/412** checks |
| `exe:progress-check --self-test` | **102/102** checks |
| `exe:registry-check` (real tree) / `--self-test` | **8/8** (355 live corpus / 443 permanent registry entries) / **16/16** |
| `exe:exercise-check` real-content / `--self-test` / `--fixtures` / `--list-codes` | 0 issues / **479/479** (incl. the **110**-assertion M4 group grounding `SXC1.Midi.Spec`, the live-deck M6 JA-completeness group, the M8 mastery projection group, the Today's Session/Weekly Pulse route contracts, and the 128-card authored-distractor invariant) / **56/56** fixtures / 53 codes |

The *unoptimized* `app.wasm` gzip figure above is a range, not a single number,
deliberately: this project observed a few hundred bytes of run-to-run jitter across
otherwise-identical rebuilds under M3's `-all -O2` optimize flags too (two runs on an
unchanged tree measured 907,575 and 908,037), which `scripts/check-site.sh`'s own
size-ledger comment independently records. The current `--detect-features -Oz
--converge` pipeline is far tighter but not perfectly bit-stable either: M4's wave-0
probe built the same tree twice and measured zero inter-build variance (890,713 bytes
both times), while later repeat runs of the same optimize pipeline against evolving M4
trees measured small deltas against their contemporaneous artifacts — **5 gzipped
bytes** on one probe, **441** on the milestone cold rebuild — so expect any fresh
rebuild to land within roughly half a kilobyte of the number below, not on it
exactly. The table therefore reports the shipping artifact's own measured
number — the bytes actually sitting at `site/public/app.wasm` are what `check-site.sh`
measures and what deploys. `app.wasm` grew from M2's 978,969-byte
gzipped baseline mainly for two reasons: the course grew from 4 decks/16 exercises to
52 decks/435 exercises before the operation-first retirement (embedded content costs ≈0.3456 gzip bytes per raw byte of
`.ex.md`), and the M3 progress engine (`SXC1.Progress.*`, `Progress/Store.hs`,
`View/Progress.hs`) added roughly another 34 KB gzipped; M4's device layer
(`site/app/Device/Midi.hs`, `SXC1.Midi.Spec`, the device panel) added the **+36,295**
gzipped bytes recorded above. **M6 reversed the first of those two causes**: the course
is no longer inside `app.wasm` at all (it is fetched as the two bundles in the table),
which is what paid for a second full language without touching the frozen ceiling.
**M7 did the same to the manual text**, shedding another 48,984 gzipped bytes, so
`app.wasm` now embeds neither corpus — only the generated `Bundle.Manifest`
expectation (names, counts and hashes, never text) it checks both fetched bundles
against. See [Status](#status) for the full size story and why CI now builds the
`--optimize`d flavour. `site/public/` stays well inside GitHub Pages' 1 GB artifact limit either way.

`--optimize` (`wasm-opt --detect-features -Oz --converge` + `wasm-tools strip`) remains **off by default** in
`build-site.sh` itself — `wasm-opt` is the one step in this pipeline that could in
principle silently miscompile GHC's output, so a plain local build never depends on it,
and this project's own definition of done never assumed it. What changed in M3 is what
CI *asks* `build-site.sh` to do, not the script's own default (see
[Deployment](#deployment)): the unoptimized build no longer fits under the ceiling once
the whole course is embedded, and the M3 designer's adversarial testing — byte-identical
checker `--self-test` output whether the app was optimized or not, and every
headless-browser assertion this project runs passing repeatedly against the optimized
artifact — found no evidence of miscompilation on this codebase.
`./scripts/check-site.sh --optimized` demonstrates an optimize-then-strip pass on
demand, against a disposable copy, for local re-verification (it still applies the
M3-era `-all -O2` recipe rather than the amended shipping flags — see
[Status](#status)); `check-site.sh` itself re-validates `app.wasm`'s exports and
behaviour regardless of which build produced the file actually sitting at
`site/public/app.wasm`.

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
- **Device verification shows "denied" in a local headless-Chrome run** — correct,
  expected behaviour, not a bug: headless Chrome *always* denies the Web MIDI
  permission, so any run without `scripts/fake-midi.js` injected lands in "denied".
  That is exactly why the automated suite pre-loads the fake (and why its no-fake
  control D20 requires "denied" — see [Verification](#verification)). To exercise the
  granted path by hand you need a real, headed Chrome or Edge; to exercise it with the
  real hardware, follow
  [`docs/M4-device-test-protocol.md`](docs/M4-device-test-protocol.md).
- **No device panel in Firefox or Safari** — absent by design, not broken: those
  browsers have no Web MIDI at all, so the device feature never renders there
  (progressive enhancement, see [Device verification](#device-verification)). The app
  looks and behaves exactly as M3 did; manual confirmation covers every drill.

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
decision); and [`briefs/M4-plan.md`](briefs/M4-plan.md) for the live-device
verification design M4 implements — the Miso-DSL-only FFI route, the single
explicit-click permission path, the fake-MIDI verification strategy, and the design
probe's measured findings.

**Known issue (M4-F1, revised by owner evidence).** `d-2-09` step 1's hook,
`verify: cc 16 0,127`, watches the SXC-1's continuous FX1 *dial* (CC 16). M4's design
probe predicted the hook unreachable (±1 per detent, never 0/127); the first
physical-device run (2026-08-07, [`docs/M4-device-evidence.md`](docs/M4-device-evidence.md))
proved that prediction wrong at the extremes — the dial's range ENDPOINTS emit 0/127,
so a full sweep auto-confirms while mid-range clicks confirm nothing. The same run
characterized the FX *buttons* as on/off toggles (127 on switching on, 0 on switching
off), so a `cc 108 127`-style button hook only fires on the switching-ON press.
Deliberately not "fixed" in M4 (the content corpus and validator are frozen for the
milestone); the step wording/hook recalibration is deferred to M5 as
[`briefs/M5-ship.md`](briefs/M5-ship.md) item 10;
[`docs/M4-device-test-protocol.md`](docs/M4-device-test-protocol.md) tells the
hardware owner either outcome is a PASS and asks them to record which occurred.
