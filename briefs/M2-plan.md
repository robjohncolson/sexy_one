# M2 Implementation Plan — Exercise engine

**From:** Opus 5 design agent · **To:** Fable / Sonnet 5 swarm · **Date:** 2026-08-06
**Companion:** `briefs/M2-manifest.json` (7 tasks, 6 waves)
**Builds on:** `briefs/M0-plan.md` (toolchain — **fixed**) and `briefs/M1-plan.md` (content
model, parser, routing, page identity — **authoritative**). M2 adds one library subtree, one
executable, one content tree and one view module. It re-architects nothing.

M2 implementation starts only after **both** the M0-fixes gate and the M1 gate close.

---

## 1. Decision summary

| Question | Decision |
|---|---|
| Exercise content format | **`.ex.md` — "exercise markdown"**: one *deck* per file, `##` sections per exercise, a contiguous `key: value` field block per section, ordinary Markdown prose for every learner-facing string, GFM task lists for multiple choice. Parsed by M1's block/inline parser for all prose. |
| Where it lives | `content/exercises/*.ex.md`, flat, ordered by `content/exercises/INDEX` |
| How the app gets it | **Template Haskell embeds the INDEX and every file it names**, at compile time, in `site/app/` (verified — probe P-B, P-E) |
| How the validator gets it | **From disk at runtime**, in a wasm32-wasi *command* module under `wasm-run.mjs` (verified — probe P-A). The validator never uses TH; it is a pure function of the working tree |
| Citations | `cite: <slug> <page> "<anchor phrase>"` — the anchor must **occur verbatim on that page**. Citations are content-verified, not merely range-checked |
| One engine, three types | Every exercise is an ordered list of **prompts**. A type is a `PromptBody` constructor plus a grading rule plus a renderer. Cursor, response map, grading dispatch, event emission and completion are shared code |
| Validator | New `exe:exercise-check` (wasm command module, host-run). Three independent implementations must agree, exactly as M1 §9.1 |
| Falsifiability | A committed **fixture corpus** whose filenames declare the expected error code, plus a **coverage invariant**: every error code the validator can emit and every terminology rule id must have at least one fixture. Plus live sabotage of real content in `verify_commands` |
| Timing (lookup exercises) | `GHC.Clock.getMonotonicTimeNSec` — works in the browser through the vendored WASI shim (verified — probe P-C). No JS FFI, no new dependency |
| M3 hook | `ProgressEvent` + `ProgressSink`; M2 ships `memorySink`, rendered into `#sxc1-event-log`. M2 persists nothing |
| M4 hook | `verify:` field on drill steps → validated `VerifySpec`; `ConfirmSource = ByLearner \| ByDevice` already exists in the engine. M2 renders a manual self-check |
| Build script changes | One line in `build-site.sh` (build `exe:exercise-check`) so `check-site.sh` keeps M0's "checks never build" property |

Everything below was **verified by compiling and running throwaway probes** against the
installed toolchain, the real translation corpus and a real headless browser (§2).

---

## 2. Probe results — verified facts (2026-08-06)

All probes were built in `/tmp/.../scratchpad`, never in the repo.

**P-A — a wasm32-wasi command module can read the working tree.** `directory-1.3.10.1`,
`filepath-1.5.5.0` and `time-1.15` are boot libraries in the 9.14 bindist. Under
`~/.ghc-wasm/wasm-run/bin/wasm-run.mjs`, `listDirectory`, `BS.readFile`,
`getCurrentDirectory`, `getArgs` and `getPOSIXTime` all work. Absolute paths resolve;
relative paths resolve against the **real cwd** of the `wasm-run.mjs` invocation. Reading
`translations/guide-book.md` yielded `chars=111559`, byte-identical to M1 §3's golden number.
A missing directory raises an uncaught `IOException` and exits **1**.
*Consequence:* the validator reads content from disk, so a negative control is a `cp -R` to
`/tmp`, a `sed`, and one run — **no rebuild**. This is what makes sabotage controls cheap
enough to be mandatory.

**P-B — TH can embed an index-driven file set.** `embedIndexed :: FilePath -> Q Exp` reads
`content/exercises/INDEX`, calls `addDependentFile` on the INDEX *and* on every file it names,
`BS.readFile`s each, and `lift`s `[(FilePath, Text)]`. Compiles and runs; the browser printed
the file list and per-file character counts computed inside WASM. `{-# LANGUAGE
OverloadedStrings #-}` is required in the embed module (Text literals), and M1's P3 lesson
still applies (`import Data.Text ()` for the `Lift Text` instance).

**P-C — the browser has a working monotonic clock, in pure Haskell.** The vendored
`browser_wasi_shim` 0.3.0 implements `clock_time_get` for **both** `CLOCKID_MONOTONIC`
(`performance.now()` × 1e6) and `CLOCKID_REALTIME` (`Date.getTime()` × 1e6). Driving the
probe app over CDP: boot `t0 = 67 000 000` ns, first tick `elapsed = 718 000 000` ns, second
tick `elapsed = 1 560 000 000` ns, `performance.now() = 2046` ms. So
`GHC.Clock.getMonotonicTimeNSec` (elapsed timing) and `Data.Time.Clock.POSIX.getPOSIXTime`
(wall clock, for M3's scheduler) both work with **no `foreign import javascript`** — which
matters, because M1's P4 established that JSFFI returning `JSString` does not link.

**P-D — Miso's `onInput` ignores synthetic events (harness-critical).** Dispatching
`new InputEvent('input', {bubbles:true})` (or `Event('change')`) from page JavaScript after
setting `input.value` **does not** reach Miso's handler: the model never updated. Trusted CDP
input **does**: after `document.querySelector('#answer').focus()`,
`Input.insertText {text:"17"}` produced `typed = "17"`, and a subsequent
`Input.dispatchKeyEvent` digit produced `"175"`. `element.click()` from page JS *does* reach
`onClick`.
*Consequence:* `browser-check.mjs` **must** drive the lookup answer field with CDP
`Input.insertText` after focusing it. A synthetic-event implementation would silently do
nothing — precisely the vacuous-success shape M0's review punished. This is written into the
manifest prompt and into the assertion list.

**P-E — content edits flow to the site.** With
`extra-source-files: ../content/exercises/*.md` plus `../content/exercises/INDEX`, appending a
line to a deck made cabal re-invoke GHC and GHC report
`[../content/exercises/01-pad-play-banks.ex.md changed]`, recompiling the corpus module, the
app module and the link. The `*.md` glob **does** match `*.ex.md` files. M1's P2 lesson
(`addDependentFile` alone is not enough) transfers unchanged, and cabal emits the same
documented `[relative-path-outside]` warning.

**P-F — cabal tolerates a not-yet-existing content tree.** With `content/exercises/` emptied,
`wasm32-wasi-cabal build` still *configures* (the non-matching glob and the missing explicit
INDEX in `extra-source-files` are not errors at build time; only `sdist` would care, and this
project never runs it). A TH splice over a missing INDEX, however, fails loudly at compile
time with `withBinaryFile: does not exist`.
*Consequence:* the cabal file may declare the content globs in wave 1, but the **splice must
live in `site/app/`** (wave 4, after seed content exists), not in the library — otherwise
wave 1 cannot build its own validator. This is the reason for §4.2's module placement.

**P-G — no `cabal.project` change is needed.** A dry-run resolve **without**
`directory installed, filepath installed, time installed` still selects the bindist copies.
`site/cabal.project` is therefore untouched in M2 and is owned by nobody.

---

## 3. The exercise content format

This section is **normative**. It is reproduced, in full, in the manifest prompts of the
tasks that implement the parser, write the authoring guide, and author the seed content.

### 3.1 Shape of a file

One file = one **deck** (a small, ordered group of exercises drawn from one part of one
chapter). Extension `.ex.md`. Flat directory. Filename `NN-slug.ex.md` where `NN` is two
digits used only for reading order.

```markdown
# Choosing a bank

deck: pad-play-banks
chapter: Part: Pad play
summary: Select BANK 1 in Performance mode and read the bank indicator.
cite: guide-book 15 "First, select BANK 1"

Before you start, turn the unit on and let the `SXC-1` logo disappear.

## Which button returns you to BANK 1

type: quiz
id: pad-play-bank-a-button
cite: guide-book 15 "press the `A` button"
tags: banks, performance-mode

The display shows `D:4` and the `D` button is lit. Which single button do you press
to start selecting BANK 1?

- [x] `A`
- [ ] `B`
- [ ] `EDIT`
- [ ] The up directional button

### Why

Pressing `A` shows `SELECT BANK 1` on the display. The directional buttons change the
number *after* a bank select button has been pressed.
```

### 3.2 Grammar

Line-oriented. Applied to the whole file.

| Rule | Pattern | Meaning |
|---|---|---|
| deck title | the first non-blank line, `^# +(.*\S)\s*$` | deck title; **exactly one** `#` in the file |
| exercise | `^## +(.*\S)\s*$` | starts an exercise; the text is its learner-facing title |
| role | `^### +(.*\S)\s*$` | starts a *role block* inside the current exercise |
| field | `^([a-z][a-z0-9-]*): ?(.*)$` | a field, **only inside a field block** |
| field continuation | a line indented ≥ 2 spaces, inside a field block | appended to the previous field's value with a single space |
| field block | the maximal run of field lines (blank lines allowed before it, **not inside it**) immediately following a `#`/`##`/`###` heading | the metadata of that heading |
| body | everything after the field block up to the next `##`/`###` | Markdown blocks, parsed by **M1 §4.5 unchanged** |
| choices | a top-level GFM task list `^- \[([ xX])\] +(.*\S)\s*$` in an exercise body | the option list; its items are removed from the body |

Prose is parsed by M1's parser, so `**bold**`, `*em*`, `` `code` ``, `*[Figure: …]*`
placeholders, tables, blockquotes and nested lists all work exactly as in the manuals, and an
`Unparsed` block anywhere in exercise prose is error **`E-BLOCK-UNPARSED`** (M1's fallback rule
exists precisely so it can be asserted empty).

Single-line field values (`summary`, `check`, `message`) are parsed with M1's **inline** parser.

### 3.3 Deck fields

| Field | Req. | Value |
|---|---|---|
| `deck` | ✔ | `[a-z0-9-]+`, globally unique, stable forever (M3 keys progress by it) |
| `chapter` | ✔ | one of the five glossary chapter titles, **verbatim** |
| `summary` | ✔ | one line, learner-facing |
| `cite` | ✔ (≥1) | see §3.5; repeatable |
| `tags` | — | comma-separated `[a-z0-9-]+` |

### 3.4 Exercise fields and roles, per type

Common required fields: `type`, `id` (`[a-z0-9-]+`, globally unique, stable forever),
`cite` (≥1, repeatable). Common optional: `tags`. Common optional roles: `### Why` (×1),
`### Hint` (×0..3, ordered).

**`type: quiz`** — two modes, inferred, never both:

* *choice mode* — the body contains a task list of **2–6** items with **≥1** `[x]`.
  Two or more `[x]` means multi-select and grading requires the exact set. Option labels are
  inline Markdown and must be pairwise distinct.
* *recall mode* — no task list; `### Answer` (×1, required) holds the answer blocks.

**`type: drill`** — a multi-step "do this on your SXC-1 now" mission.

* body = the goal.
* `### Step` ×N, **N ≥ 2**, in order. Each step's field block:
  * `cite:` ✔ — the manual page this step mirrors
  * `check:` ✔ — the learner-verifiable observation, one line
    (e.g. `check: The pad you tapped lights white while the sound plays.`)
  * `verify:` — optional M4 hook, §3.7
  * body = the instruction, ≥1 block.

**`type: lookup`** — a timed find-the-answer task that trains manual navigation.

* `find:` ✔ — exactly one citation (§3.5); this is the page the learner must locate.
  It also counts as the exercise's citation, so `cite:` is optional for lookups.
* `limit:` — optional integer seconds, 10–600, a *target*, never a hard cut-off.
* body = the task, which **must not reveal the answer**: it may not contain the target page
  number in any `p. N` / `page N` form (error `E-LOOKUP-SPOILER`).
* `### Hint` is the intended escape hatch.

### 3.5 Citations — content-verified, not range-checked

```
cite: <slug> <page> "<anchor phrase>"
```

* `<slug>` ∈ `guide-book`, `startup-guide`, `midi`, `oss` — else `E-CITE-SLUG`
* `<page>` an integer in `1..pageCount(slug)`, taken from the **parsed** manual corpus
  (71 / 15 / 6 / 16 per M1 §3) — else `E-CITE-PAGE`
* `<anchor phrase>` must occur in that page's source text after whitespace normalisation —
  else `E-CITE-ANCHOR`

The anchor is what makes a citation *mean* something. Range checking alone accepts
"guide-book 42" for a question about banks; the anchor does not. It costs an author one
copy-paste from the page they were already reading, and it is trivially re-derivable in
Python, which is what makes it the strongest of the three-way cross-checks (§6.1).

Rendered, every citation becomes `<a class="cite" href="#/m/<slug>/p/<n>">` — M1's page
identity, M1's route, M1's reader.

### 3.6 Terminology rules — `content/terminology-rules.tsv`

Six tab-separated columns; `#` comments; one rule per line.

```
rule_id  kind  phrases  replacement  glossary_anchor  message
```

* `kind = forbid` — none of the comma-separated `phrases` may appear in learner-facing text.
  Matching is case-insensitive and word-bounded (a match must not be flanked by an ASCII
  letter, digit or hyphen). **No regex engine** — there is none in the boot libraries, and
  literal phrase matching is re-derivable in Python line for line.
* `kind = caseof` — each phrase is a canonical on-device spelling; any case-insensitive
  occurrence that is **not byte-exact** is an error. This is how `SELECT BANK`, `MASTER BPM`,
  `AUTO TRIGGER`, `ONE SHOT`, `LOW STRAGE SPACE` and the five `Part: …` chapter titles are
  enforced without enumerating every wrong spelling.
* `glossary_anchor` — a substring that **must occur in `translations/glossary.md`**, else
  `E-RULE-UNGROUNDED`. This mechanically forbids inventing house style: every rule must be
  traceable to the binding glossary.

Learner-facing text = deck title/summary, exercise titles, all body prose (including inline
code spans), option labels, `check:` sentences, answer/why/hint blocks. **Excluded:** `id`,
`deck`, `tags`, `verify:`, and the quoted anchor inside `cite:`/`find:` — anchors are verbatim
manual quotations and linting them would punish correct citation of the device's own
misspelling `LOW STRAGE SPACE`.

Violations report `E-TERM` with the offending `rule_id` in the detail field.

### 3.7 `verify:` — the M4 hook, validated now, executed later

```
verify: cc 104 127          # ONE SHOT button pressed
verify: cc 80 0,127         # bank select A, either edge
verify: note 36             # pad 1 in bank A
verify: pad 13 bank A       # sugar for note 48
verify: any                 # any MIDI activity from the unit
```

Parsed into `VerifySpec` (§5.4) and **validated against `translations/midi.md`**: the CC
number must appear in the parsed Control Change list (`E-VERIFY-CC-UNKNOWN`), note numbers
must be in 36–115 (`E-VERIFY-NOTE-RANGE`), `pad N bank X` must be in the parsed Note-mapping
table, anything else is `E-VERIFY-SYNTAX`. So M4's vocabulary is grounded in the MIDI document
by the same mechanism as citations, and a hook that references a control the device does not
send cannot be committed.

M2 **renders** the hook and does not execute it: the step shows its manual `check:` sentence
plus one muted line inside `<p class="ex-verify">`. Confirmation is by button.

### 3.8 What the author actually has to get right

The whole format is: one `#`, some `##`s, a few `key: value` lines under each, ordinary
Markdown, and `- [x]` for the right answer. Everything unusual about it — the anchor in a
citation, the closed role vocabulary, the terminology table — exists to be *checked*, and each
produces one named error with a file, a line and a suggestion. `content/EXERCISE-FORMAT.md`
(§7, wave 2) is the authoring guide; it is written for someone who will never read a line of
Haskell, and every example in it is validated by the real validator in CI.

---

## 4. Engine architecture

### 4.1 The unifying idea

> An exercise is an ordered list of **prompts**. An exercise *type* is a `PromptBody`
> constructor, a grading rule, and a renderer. Everything else is shared.

That is what makes one engine serve all three types rather than three engines behind a sum
type. Concretely, the shared code owns: the cursor, the response map, attempt counting, hint
revelation, elapsed timing, the grading dispatch, event emission, completion summary, and all
chrome (progress, citations, feedback, next/restart). A quiz is one prompt (or a few); a drill
is N `Confirm` prompts; a lookup is one `FindPage` prompt. Adding a fourth type in M3+ means
one constructor, one grading equation, one renderer — and no change to the format's spine, the
event stream, or the harness.

### 4.2 Module layout

```
site/
├── sxc1-trainer.cabal              + exe:exercise-check, + Exercise.* modules, + content globs
├── src/SXC1/                       THE LIBRARY — pure, no miso, no filesystem
│   ├── Content/…                   M1's parser (unchanged behaviour; exports may be widened)
│   ├── Route.hs                    M1's routes + RExercises / RDeck / RExercise
│   └── Exercise/
│       ├── Types.hs                Deck, Exercise, Prompt, PromptBody, Citation, VerifySpec
│       ├── Parse.hs                Text -> Either [Issue] Deck   (the §3 grammar)
│       ├── Lint.hs                 terminology rules: parse the TSV, apply forbid/caseof
│       ├── Verify.hs               citation + verify-hook resolution against a manual corpus
│       ├── Engine.hs               ExerciseState, ExerciseAction, step, grade, ProgressEvent
│       └── Report.hs               Issue codes, JSON report encoder, stats record
├── test/
│   ├── CheckContent.hs             M1's exe:content-check — untouched
│   └── CheckExercises.hs           exe:exercise-check — the only module that touches the FS
├── app/
│   ├── Main.hs                     + exercise routes, model, ProgressSink wiring
│   ├── Exercises/Embed.hs          embedIndexed :: FilePath -> Q Exp        (TH helper)
│   ├── Exercises/Corpus.hs         the splice site + parse-at-boot           (stage rule P8)
│   ├── View/Exercise.hs            the runner, index and deck views
│   ├── View/Blocks.hs              M1's renderer — reused verbatim for all exercise prose
│   └── View/Pages.hs               + a "Training" entry point on the home page
└── static/index.html               + exercise CSS (no new DOM decisions)
```

`Embed.hs` and `Corpus.hs` are separate modules because of M1's P8 stage restriction. Both live
in `app/` because of P-F: the library must compile in wave 1, before any content exists.

**The library is pure.** No `IO`, no `directory`, no `miso`. All filesystem access is in
`test/CheckExercises.hs`. This is what lets the same parser serve the validator (disk) and the
app (TH-embedded) with zero divergence, and it keeps `step` unit-testable without a browser.

### 4.3 Types

```haskell
newtype DeckId   = DeckId   Text     -- "pad-play-banks"
newtype ExId     = ExId     Text     -- "pad-play-bank-a-button"
newtype PromptId = PromptId Text     -- "pad-play-bank-a-button#1"   (1-based, stable)

data Citation = Citation
  { citSlug :: !Text, citPage :: !Int, citAnchor :: !Text }

data Kind = KQuiz | KDrill | KLookup

data Deck = Deck
  { dkId :: !DeckId, dkTitle :: !Text, dkChapter :: !Text, dkSummary :: [Inline]
  , dkCites :: [Citation], dkIntro :: [Block], dkTags :: [Text]
  , dkExercises :: [Exercise] }

data Exercise = Exercise
  { exId :: !ExId, exDeck :: !DeckId, exKind :: !Kind, exTitle :: !Text
  , exCites :: [Citation], exTags :: [Text], exIntro :: [Block]
  , exPrompts :: [Prompt]                       -- >= 1, ordered
  , exNote :: [Block], exHints :: [[Block]] }

data Prompt = Prompt
  { prId :: !PromptId, prStem :: [Block], prCites :: [Citation], prBody :: !PromptBody }

data PromptBody
  = Choice   { pcOptions :: [Option] }               -- multi iff >1 correct
  | Recall   { prAnswer  :: [Block] }
  | Confirm  { pcCheck   :: [Inline], pcVerify :: Maybe VerifySpec }
  | FindPage { fpTarget  :: !Citation, fpLimitSec :: Maybe Int }

data Option = Option { optId :: !Text, optLabel :: [Inline], optCorrect :: !Bool }
```

`optId` is derived from the option's position (`a`,`b`,`c`,…) so that DOM ids are stable and
the browser fixture (§6.3) can name them without depending on label text.

### 4.4 State machine

```haskell
data Response
  = RUnanswered
  | RChosen     [Text]            -- option ids, in click order
  | RRevealed   SelfGrade         -- Got | Missed          (recall)
  | RConfirmed  ConfirmSource     -- ByLearner | ByDevice   (drill; M4 supplies ByDevice)
  | RFound      !Int              -- page number entered    (lookup)

data Outcome = Correct | Incorrect | Skipped | Completed

data ExerciseState = ExerciseState
  { esExercise  :: !ExId
  , esCursor    :: !Int                        -- 0-based index into exPrompts
  , esResponses :: IntMap Response
  , esAttempts  :: IntMap Int
  , esHints     :: IntMap Int                  -- hints revealed per prompt
  , esRevealed  :: IntSet
  , esStartedAt :: !Millis                     -- monotonic, from getMonotonicTimeNSec
  , esPromptAt  :: !Millis
  , esDone      :: !Bool }

data ExerciseAction
  = Begin Millis | Toggle Int Text | Submit Int Millis Millis
  | Reveal Int | SelfGrade Int SelfGrade Millis Millis
  | ConfirmStep Int ConfirmSource Millis Millis
  | EnterPage Int Int | SubmitPage Int Millis Millis
  | ShowHint Int | Advance Millis | Restart Millis

step :: Exercise -> ExerciseAction -> ExerciseState -> (ExerciseState, [ProgressEvent])
```

`step` is **pure and total**. The two `Millis` arguments are the monotonic clock and the wall
clock, both supplied by the caller — so the engine has no ambient time and is deterministic
under unit test. Grading:

| `PromptBody` | Correct when |
|---|---|
| `Choice` | the selected option-id set equals the correct set exactly |
| `Recall` | `SelfGrade Got` (the event records `revealed = true` either way) |
| `Confirm` | the learner (or, from M4, the device) confirms — drills are *completed*, not scored |
| `FindPage` | the entered page equals `citPage (fpTarget …)` |

Incorrect answers do not lock the prompt: `esAttempts` increments and the learner may retry.
That is a pedagogical choice *and* a harness convenience — the browser check can assert the
wrong-then-right path in one visit.

### 4.5 Rendering

`View/Exercise.hs` is a dispatch over `PromptBody` into four small renderers plus shared
chrome, all built from M1's `View/Blocks.hs`. No exercise prose is ever constructed in Haskell:
every learner-facing string in the app that is not UI chrome comes from `content/`, and every
chapter title comes from the parsed manual corpus. M1's R3 grep must keep
passing, in the comment-anchored form of §6.6, over both `site/src` and `site/app`.

---

## 5. Forward interfaces — shapes only

The rule for both: **M2 must not need redesign in M3/M4.** Neither behaviour is implemented.

### 5.1 M3 — progress and spaced repetition

```haskell
data ProgressEvent = ProgressEvent
  { peDeck     :: !DeckId
  , peExercise :: !ExId
  , pePrompt   :: Maybe PromptId     -- Nothing for the exercise-completed event
  , peKind     :: !Kind
  , peOutcome  :: !Outcome
  , peAttempt  :: !Int
  , peRevealed :: !Bool
  , peHints    :: !Int
  , peElapsed  :: !Int               -- ms on this prompt, monotonic
  , peAt       :: !Integer           -- wall-clock epoch ms  (scheduling needs a date)
  } deriving (Eq, Show)

data ProgressSink = ProgressSink
  { sinkRecord :: ProgressEvent -> IO ()
  , sinkLoad   :: IO [ProgressEvent] }

memorySink :: IORef [ProgressEvent] -> ProgressSink     -- M2: bounded at 200, in-memory only
```

M2 wires exactly one `ProgressSink` into `Main.hs` and renders its contents as JSON into
`<div id="sxc1-event-log" hidden>`. M3 replaces `memorySink` with a `Miso.Storage`-backed sink
(`getLocalStorage`/`setLocalStorage`, confirmed present in miso 1.12) and adds a scheduler; it
changes no engine code, no content, and no view.

Three properties make that safe, and each is asserted in M2:

1. **`PromptId` is stable and canonical** — `"<exercise-id>#<1-based index>"`. Exercise and
   deck ids are declared immutable by the format spec and checked unique by the validator.
   Reordering a drill's steps changes prompt ids; the guide says so, and M3's contract is that
   an unknown prompt id is simply a new item.
2. **Every event carries both clocks** — monotonic elapsed for latency-style grading, wall
   epoch for interval scheduling. Adding a wall clock later would have meant re-plumbing.
3. **The sink is the only egress.** Nothing else in the engine or view writes progress, so
   there is exactly one place for M3 to bind.

`#sxc1-event-log` is deliberately observable: the forward hook is *falsifiable today* (the
browser check reads real events out of it) rather than a promise about later.

Explicitly **not** designed here: the scheduling algorithm, review queues, streaks, mastery
state, or any storage schema. Those are M3's to choose.

### 5.2 M4 — WebMIDI drill verification

```haskell
data VerifySpec
  = VerifyCC   { vcNumber :: !Int, vcValues :: [Int] }
  | VerifyNote { vnNumbers :: [Int] }
  | VerifyPad  { vpPad :: !Int, vpBank :: !Char }
  | VerifyAny
  deriving (Eq, Show)

data DeviceVerifier = DeviceVerifier
  { dvAvailable :: IO Bool
  , dvWatch     :: VerifySpec -> (ConfirmSource -> IO ()) -> IO (IO ()) }  -- returns unsubscribe

noDeviceVerifier :: DeviceVerifier      -- M2: dvAvailable = pure False; dvWatch = no-op
```

The engine already accepts `ConfirmStep i ByDevice`, so M4 adds a subscription and swaps
`noDeviceVerifier` for a WebMIDI-backed one. The content format needs no change: `verify:`
already exists, is already validated against `translations/midi.md`, and already renders.
M2's rendering degrades exactly the way M4 must on non-Chromium browsers — a manual self-check
— so the "graceful degradation" path is the *default* path and is exercised from day one.

---

## 6. Verification design

M1's harness shape is preserved: `build-site.sh` → `check-site.sh` → headless Chrome via
`browser-check.mjs`, same boot contract, same `result=complete` discipline from the M0 fixes.

### 6.1 Three independent implementations must agree

Exactly M1 §9.1, applied to exercises:

1. **`exe:exercise-check`** — the real Haskell parser + engine, reading `content/` and
   `translations/` from disk, printing a JSON report.
2. **`check-site.sh`** — a Python re-derivation straight from the files: deck/exercise/prompt
   counts, per-kind counts, id lists, and — the important one — **every citation re-resolved
   independently**: page in range, anchor found on that page. Diffed against (1).
3. **the running app** — `#sxc1-exercise-stats`, a hidden div whose `textContent` is the same
   stats JSON, asserted by `browser-check.mjs` against what `check-site.sh` passes it.

(1) vs (2) catches parser drift with a genuinely independent implementation. (2) vs (3) catches
a **stale build**: the app embeds content at compile time while the validator reads disk, so
if someone edits an exercise and forgets to rebuild, `sourceChars` diverges and the check fails
loudly instead of serving old content. That divergence risk is the price of the
disk-reading validator, and this is the mechanism that pays it.

### 6.2 `exe:exercise-check`

```
exercise-check [--content-dir DIR] [--translations-dir DIR] [--json] [--self-test]
               [--fixtures DIR] [--list-codes] [--browser-fixture]
```

* default mode — validate `content/exercises/` against `translations/`; exit non-zero on any
  issue; print `file:line: CODE  detail` lines and a summary.
* `--json` — the machine-readable report:
  `{"ok":bool,"totals":{…},"decks":[…],"sourceChars":[[file,chars],…],"issues":[{code,file,line,detail},…]}`
* `--self-test` — inline unit tests, no filesystem: the §3 grammar over ~20 embedded sources
  (valid and invalid), `step` grading for all four `PromptBody` constructors, hint/attempt
  counting, event emission, `PromptId` stability, and `parseRoute`/`renderRoute` round-trips
  for the three new constructors. **This is wave 1's gate** — it makes the task independently
  verifiable before any content exists (M0's wave-1 principle).
* `--fixtures DIR` — the falsifiability harness, §6.4.
* `--list-codes` — every issue code the binary can emit, plus every `rule_id` in
  `terminology-rules.tsv`, one per line. This is what makes the coverage invariant checkable.
* `--browser-fixture` — emits the small JSON `check-site.sh` hands to `browser-check.mjs`
  (§6.3), so the browser assertions never hard-code content.

Assertions beyond the §3 grammar: ids unique across the corpus; INDEX ↔ directory agreement in
both directions (`E-INDEX-ORPHAN`, `E-INDEX-DANGLING`); chapter titles map onto guide-book part
titles parsed from the corpus (`E-CHAPTER-UNKNOWN`); every terminology rule grounded in the
glossary; `Unparsed` count zero; at least one citation per exercise.

### 6.3 `browser-check.mjs` — M2 assertions

Added to M1's list, all against the real build, driven by `--exercise-fixture <json>` produced
by `check-site.sh` from `exercise-check --browser-fixture` (so content edits never break the
driver, and the driver never guesses an answer):

1. `#/x` renders `#sxc1-exercise-index` with every deck, grouped under its chapter title.
2. `#sxc1-exercise-stats` parses as JSON and equals the expected stats.
3. **Quiz answer path** — open the fixture's quiz; click the fixture's *wrong* option id →
   `#ex-feedback` textContent starts `Not quite` and carries class `incorrect`; click the
   fixture's *correct* option id → starts `Correct`, class `correct`, `#ex-note` becomes
   visible, `#btn-ex-next` appears. This is the milestone's "an answer path works".
4. **Citation round trip** — `#ex-cites a.cite` has `href="#/m/<slug>/p/<n>"` matching the
   fixture; click it → M1's `#page-<n>` renders; history back → the exercise is on the same
   prompt **with the previous selection still applied** (progress survives navigation).
5. **Drill** — `#ex-steps > li` count equals the fixture's; `#btn-ex-confirm-1` advances
   `#ex-progress` from `1 / N` to `2 / N`; a step with a hook shows a non-empty `.ex-verify`.
6. **Lookup** — focus `#ex-find-input`, enter a wrong page **with CDP `Input.insertText`**
   (P-D), submit → `Not quite`; clear, enter the fixture's target page → `Correct` and
   `#ex-elapsed` is non-empty and matches `^\d+:\d\d$`.
7. `#sxc1-event-log` parses as a JSON array, is non-empty, and its last entry has
   `outcome:"correct"` and the fixture's exercise id — the M3 hook, observed carrying data.
8. Mobile: at 390×844 the exercise runner has no horizontal overflow.
9. Zero console errors and zero uncaught exceptions across the whole run (M1, unchanged).

### 6.4 Falsifiability — the fixture corpus and its coverage invariant

M0's lesson was not "add a negative control"; it was that a check which *cannot fail on the
specific thing it claims to guarantee* reports green on a broken artifact. So the validator's
falsifiability is itself mechanised, and re-runs on every CI job rather than being demonstrated
once by an implementer.

**`content/fixtures/<CODE>--<slug>.ex.md`** — each file contains **exactly one** defect and
declares its expected verdict in its own filename: either `OK` or an issue code
(`E-CITE-ANCHOR--wrong-phrase.ex.md`), with terminology rules spelled `E-TERM.<rule-id>--…`.
`exercise-check --fixtures` requires, for every file, that the **set** of codes reported equals
exactly `{expected}` — not "some error occurred". A fixture that trips a second rule fails the
fixture run, which keeps the fixtures honest.

Three properties fall out, and each is asserted:

1. **The harness is not "reject everything"** — at least three `OK--*.ex.md` fixtures must be
   accepted. If validation degrades into rejecting all input, the fixture run goes red.
2. **The harness is not "accept everything"** — every `E-*` fixture must be rejected with its
   exact code.
3. **Coverage** — `check-site.sh` reads `exercise-check --list-codes` and requires every code
   and every `rule_id` to have ≥1 fixture. **Adding a validation rule without a fixture fails
   CI.** This is the invariant that would have caught M0's M9: it makes "the check exists" and
   "the check can fail on its own subject" the same statement.

`check-site.sh` re-derives the expected code set from the filenames in Python and diffs it
against the validator's JSON — so the fixture harness is itself cross-checked by an independent
implementation.

### 6.5 Negative controls proven live against sabotage

Each is a `verify_commands` entry in the manifest, runs against a `/tmp` copy, restores
nothing in the repo, and was designed to be cheap because the validator reads disk (P-A).

| # | Sabotage | Expected |
|---|---|---|
| N1 | Rename an `E-CITE-PAGE--*` fixture to `OK--*` | `--fixtures` exits non-zero (proves code comparison, not blanket rejection) |
| N2 | Delete an `OK--*` fixture's `cite:` line | non-zero, `E-FIELD-MISSING` |
| N3 | Point a real seed citation at page 9999 | non-zero, `E-CITE-PAGE` |
| N4 | Change a real seed citation's anchor to a phrase not on that page | non-zero, `E-CITE-ANCHOR` |
| N5 | Replace `assign` with `register` in real seed prose | non-zero, `E-TERM` naming the rule |
| N6 | Rewrite `SELECT BANK` as `Select Bank` in real seed prose | non-zero, `E-TERM` (`caseof`) |
| N7 | Change a deck's `chapter:` to `Pad Play` | non-zero, `E-CHAPTER-UNKNOWN` |
| N8 | Add an unlisted `.ex.md` to a copy of `content/exercises/` | non-zero, `E-INDEX-ORPHAN` |
| N9 | Point `verify:` at a CC number absent from `midi.md` | non-zero, `E-VERIFY-CC-UNKNOWN` |
| N10 | Corrupt a seed deck in `content/` and run `check-site.sh` | non-zero (the gate, not just the tool) |
| N11 | `browser-check.mjs --self-test --expect-exercise-json` with a wrong exercise count | non-zero (hermetic — needs no server) |
| N12 | `browser-check.mjs --self-test-negative` — a fixture page whose grader always answers "Correct" | **exit 0 only if the wrong-option assertion failed**, by name |

N3–N7 sabotage **real content**, which is what the brief demands. N12 is the browser half of
the same idea, and it is re-runnable in CI rather than a one-time manual demonstration: it
passes only when the *specific* expected assertions fail, so it cannot decay into "something
went wrong somewhere".

### 6.6 Invariant greps are anchored to non-comment lines

M0's finding n2 concluded that validating behaviour by grepping prose is brittle and invites
contortion — an implementer obfuscated a hostname to dodge a grep that would not have matched
it anyway. Every M2 invariant grep is therefore anchored so that comments are exempt and only
real code can trip it:

```
! grep -RniE '^[^-]*(pad play|part: preparation|…|SELECT BANK|CREATIVE NOTE)'  site/src site/app
! grep -RniE '^[^-]*(miso\.storage|localstorage|sessionstorage|requestmidiaccess)' site/app site/src
! grep -RnE  '^import +(qualified +)?(Miso|System\.Directory|System\.FilePath)\b'  site/src
! grep -RnE  '^[^-]*foreign import javascript'  site/app
```

`[^-]*` cannot advance past a Haskell `--`, so a comment may say "M3 will bind localStorage
here" or "chapter titles like Part: Pad play must come from the parse" while
`setLocalStorage "k"` and `title = "Part: Pad play"` still match. Verified live against both
cases. The case-insensitive spelling matters: Miso's API is `setLocalStorage`, which a
case-sensitive search for `localStorage` misses entirely.

### 6.6 `check-site.sh` and CI

`check-site.sh` gains, keeping every M0-fix property (explicit Node resolution, skip accounting,
`result=complete`, trap-based teardown, sub-path serve):

* run `exercise-check --json` under `wasm-run.mjs` with the toolchain env sourced (M1 R5), fail
  with an actionable message if the env or the binary is absent — never silently skip;
* the Python re-derivation and diff of §6.1;
* the fixture run and the coverage invariant of §6.4;
* hand `--exercise-fixture` and `--expect-exercise-json` to `browser-check.mjs`;
* count the exercise checks into the total, and refuse to report `result=complete` if any of
  them was skipped.

CI (`.github/workflows/site.yml`) runs the same script and asserts `result=complete`, so "the
validator gate runs in CI" is true by construction rather than by a separate step that could be
removed without turning anything red.

---

## 7. Task manifest — waves

`briefs/M2-manifest.json`, **7 tasks, 6 waves**, disjoint `owned_paths`. Every file a task's
`verify_commands` or prompt reads is inside its own `owned_paths`, produced by its `depends_on`
closure, or already committed by M0/M1 — stated explicitly in each prompt.

| Wave | Task | Owns | depends_on |
|---|---|---|---|
| 1 | `exercise-core` | `site/src/`, `site/test/`, `site/sxc1-trainer.cabal`, `content/terminology-rules.tsv` | — |
| 1 | `exercise-styles` | `site/static/index.html` | — |
| 2 | `format-guide` | `content/EXERCISE-FORMAT.md`, `content/fixtures/` | exercise-core |
| 3 | `seed-content` | `content/exercises/` | format-guide, exercise-core |
| 4 | `exercise-ui` | `site/app/`, `scripts/browser-check.mjs` | exercise-core, exercise-styles, seed-content |
| 5 | `verification` | `scripts/check-site.sh`, `scripts/build-site.sh` | exercise-ui, seed-content, format-guide |
| 6 | `docs-and-ci` | `README.md`, `.github/workflows/site.yml` | verification, exercise-ui |

Notes on the shape:

* **`exercise-core` owns all of `site/src/` and `site/test/`**, not just its own subtree. M2 is
  designed against the M1 *plan*, and the M1 code lands in a parallel track; if M1's actual
  exports turn out narrower than M2 needs, the wave-1 agent can widen an export list instead of
  being blocked by an ownership boundary. Its prompt forbids changing M1's parser *behaviour*
  and requires `exe:content-check` to keep passing unchanged — that is the guard rail.
* **`exercise-core` owns the cabal** and declares everything up front, including `View.Exercise`
  and the `Exercises.*` modules that arrive in wave 4. It therefore **cannot build `exe:app`**,
  and its `verify_commands` build only `lib`, `exe:content-check` and `exe:exercise-check`.
  `build-site.sh` is expected to be red from wave 1 until wave 4; that is stated in the prompt
  so nobody "fixes" it by inventing stub modules. Nothing between those waves compiles the app.
* **The TH splice is in `site/app/`, not the library** — P-F. This is what lets wave 1 build a
  working validator before any exercise content exists.
* **`format-guide` owns the fixture corpus as well as the guide.** Both artefacts answer the
  same question — "what exactly is a valid exercise, and what exactly is not?" — and both are
  written by running the wave-1 validator. Pairing them also keeps wave 1 from carrying
  ~45 fixture files on top of the parser, the lint engine and the state machine. Wave 1 is
  still independently falsifiable through `--self-test`'s inline invalid sources and its own
  `/tmp` sabotage controls.
* **`format-guide` is separated from `seed-content` on purpose.** The brief requires a format
  documented well enough for a content agent that has never seen the engine source. So
  `seed-content`'s prompt **forbids reading `site/`**: its only inputs are
  `content/EXERCISE-FORMAT.md`, the fixtures, `translations/*.md`, the terminology table, and
  the validator binary. If the guide is inadequate, that task fails — which is the empirical
  test of the requirement, run inside the milestone instead of after it.
* **`exercise-ui` owns `browser-check.mjs`**, for the reason M1 kept them together: the DOM
  hooks and the driver that asserts them are one contract and one debugging loop.
* **`verification` owns `build-site.sh`** only to add `exe:exercise-check` to the build, so
  `check-site.sh` keeps M0's "checks never build" property.
* **`docs-and-ci` is a wave of its own** because it reads `scripts/check-site.sh` — the M0
  `ci-workflow` race, removed by construction.
* Waves 2 and 3 are single-task but cheap: neither compiles anything.

### 7.1 Seed content target

`seed-content` hand-authors **14–20 exercises across 4 decks**, drawn from `Part: Preparation`
(guide-book pp. 12–13, plus the startup guide) and `Part: Pad play` (pp. 14–26), with at least:
6 quiz, 3 drill (each ≥ 3 steps), 3 lookup, and ≥ 2 drill steps carrying a `verify:` hook. Bulk
authoring of the full two-chapter banks is **not** a swarm task; Fable runs dedicated content
workflows against this schema afterwards.

---

## 8. DOM and CSS contract

Fixed here so the CSS (wave 1), the app (wave 4) and both checkers (waves 4–5) are built against
the same hooks. Reproduced verbatim in every manifest prompt that touches it. M1's contract is
unchanged; this is additive.

```
Shell (every route, beside M1's #sxc1-content-stats):
  <div id="sxc1-exercise-stats" hidden>   textContent = the stats JSON of §6.1
  <div id="sxc1-event-log"      hidden>   textContent = JSON array of ProgressEvents

"#/x"            <section id="sxc1-exercise-index">
                   <section class="ex-chapter"><h2 class="ex-chapter-title">
                     <ul class="ex-deck-list"><li><a class="ex-deck-card" href="#/x/<deck>">
                       <span class="ex-deck-title"> <span class="ex-deck-count">

"#/x/<deck>"     <section id="sxc1-deck">
                   <h1 id="ex-deck-title"> <p id="ex-deck-summary">
                   <ol class="ex-list"><li><a class="ex-link" href="#/x/<deck>/<ex>">
                     <span class="ex-kind kind-quiz|kind-drill|kind-lookup"> <span class="ex-title">

"#/x/<deck>/<ex>"  <article id="sxc1-exercise" class="exercise kind-<kind>">
                     <h1 id="ex-title">
                     <p  id="ex-progress">            "2 / 5"
                     <div id="ex-stem">
   quiz choice:      <ul id="ex-options"><li><button class="ex-option" id="opt-<a|b|c|…>"
                                                     aria-pressed="false">
                     <button id="btn-ex-submit">
   quiz recall:      <button id="btn-ex-reveal">  <div id="ex-answer">      (after reveal)
                     <button id="btn-ex-got">     <button id="btn-ex-missed">
   drill:            <ol id="ex-steps"><li class="ex-step" id="ex-step-<n>">
                       <div class="ex-step-instruction">
                       <p class="ex-step-check"  id="ex-step-<n>-check">
                       <p class="ex-verify"      id="ex-step-<n>-verify">   (only with verify:)
                       <button class="btn-ex-confirm" id="btn-ex-confirm-<n>">
   lookup:           <p id="ex-find-task">
                     <input id="ex-find-input" type="number" inputmode="numeric">
                     <button id="btn-ex-find-submit">
                     <p id="ex-elapsed">            "1:24"   (after submit)
   shared:           <button id="btn-ex-hint">  <ul id="ex-hints"><li class="ex-hint">
                     <p id="ex-feedback" class="correct|incorrect" role="status">
                     <div id="ex-note">                        (after answering)
                     <ul id="ex-cites"><li><a class="cite" href="#/m/<slug>/p/<n>">
                     <button id="btn-ex-next">  <button id="btn-ex-restart">
                     <section id="ex-summary">                 (when finished)
```

Contract details the checkers rely on: `#ex-feedback` textContent **starts with** `Correct` or
`Not quite`; `#ex-progress` is exactly `N / M`; `#ex-elapsed` matches `^\d+:\d\d$`; option ids
are positional (`opt-a`, `opt-b`, …), never derived from label text. Element **ids**, not
`data-*`, for M0's reason. Every internal `href` is a hash route. No new image or font origins.

New routes (M1's `Route` gains three constructors; `parseRoute`/`renderRoute` round-trip
asserted in `--self-test`):

```haskell
| RExercises            -- "#/x"
| RDeck     !Text       -- "#/x/pad-play-banks"
| RExercise !Text !Text -- "#/x/pad-play-banks/pad-play-bank-a-button"
```

Unknown deck or exercise renders a visible not-found panel with a link back to `#/x` — never a
blank screen.

---

## 9. Risks

**R1 — validator reads disk, app embeds at compile time.** Two delivery paths for one corpus.
Mitigated structurally by §6.1's three-way comparison: `sourceChars` in
`#sxc1-exercise-stats` versus the on-disk files turns a stale build into a red check. Accepted
deliberately, because the alternative (TH-embedding into the validator) makes every negative
control a full rebuild and would have made §6.5 too expensive to be mandatory.

**R2 — M1 has not landed yet.** M2 is designed against the M1 plan. Mitigations: `exercise-core`
owns all of `site/src/` so it can widen exports rather than be blocked; M2 depends only on
interfaces the M1 plan states normatively (`Block`/`Inline`, the block and inline parsers,
`slugify`, the page corpus, `Route`); and every M2 task prompt states which M1 artefacts it
assumes and requires `exe:content-check` to still pass. If M1's parser is not yet committed when
wave 1 starts, wave 1 stalls — that is the intended gate, not a workaround.

**R3 — anchor citations could be gamed.** An author could paste a one-word anchor that occurs on
every page. Mitigated by requiring anchors of ≥ 12 characters and by sign-off review (§10.4). It
is a weaker bound than the machine check, and I would rather say so than pretend otherwise.

**R4 — fixture corpus rot.** Fixtures are content, and content rots. Mitigated by the coverage
invariant (§6.4): a rule without a fixture fails CI, and a fixture whose code no longer exists
fails `--fixtures` because `--list-codes` will not contain it.

**R5 — terminology linting false positives.** `caseof` on short labels (`A`–`D`, `REC`) will
flag ordinary English words. Mitigation: the TSV ships only multi-character, unambiguous labels
plus the five chapter titles; single-letter button labels are **not** linted, and the guide says
to write them as inline code. The rules file is data, so tightening it later costs no code
change.

**R6 — engine complexity in one wave-1 task.** Parser + lint + engine + report + validator is
the largest task in the milestone. Mitigated by `--self-test` being its gate: the task is
independently verifiable without content, without a browser and without the UI, so it cannot
defer its risk to wave 4.

**R7 — 6 waves is serial.** Content genuinely depends on the validator, and the UI genuinely
depends on content. Waves 2 and 3 compile nothing and should be fast. The alternative — letting
content and engine proceed in parallel against a written spec alone — is what produces a format
nobody can author, which is the specific failure this milestone must avoid.

---

## 10. What I will check at sign-off

Beyond every per-task `acceptance_checks`:

1. `rm -rf site/public site/dist-newstyle && ./scripts/build-site.sh && ./scripts/check-site.sh`
   passes from a clean tree, prints `result=complete`, and the browser step really ran.
2. **Content really flows.** I will edit a seed deck's prose in place, rebuild, confirm the new
   text appears in the browser and that `sourceChars` moved in all three implementations, then
   restore it. A pipeline that cannot notice an edit is not a pipeline.
3. **The validator really fails.** I will run all twelve negative controls of §6.5 myself, and
   additionally invent two sabotages the manifest does *not* name — because a control the
   implementer optimised against is not a control.
4. **Citations are real.** I will pick five citations at random, open the cited page in the
   reader, and confirm the anchor text is on it and the exercise is actually about that page.
   Then I will shorten one anchor to a common word and confirm R3's bound is where I said it is.
5. `exercise-check --list-codes` versus `ls content/fixtures/` — the coverage invariant holds,
   and I will add a new issue code to a scratch copy and confirm CI would go red.
6. **The format is authorable.** I will read `content/EXERCISE-FORMAT.md` only, author one new
   exercise from it without opening `site/`, and require it to validate first try.
7. **No manual prose or chapter titles in Haskell.** The §6.6 comment-anchored greps over
   `site/src` and `site/app` find nothing, and the library imports neither `Miso` nor
   `System.Directory`. I will also add a comment containing a chapter title and confirm the
   grep stays green — a check that fires on prose is a check people learn to dodge.
8. **M3/M4 shapes.** `#sxc1-event-log` carries well-formed events with both clocks after a real
   session; `verify:` hooks parse, validate against `midi.md`, and render; `noDeviceVerifier` is
   the only verifier wired in and nothing persists — `localStorage` is untouched after a full
   run (I will check it is empty).
9. Mobile at 390×844 over the exercise index, a quiz, a drill and a lookup: no horizontal
   overflow, tap targets usable, `#ex-find-input` reachable.
10. M0/M1 invariants survive: no external origins or root-absolute URLs in the bundle,
    `.nojekyll` present, the sub-path browser run still passes, `exe:content-check` still
    reproduces M1 §3 and §5.2 exactly.

---

## 11. Out of scope for M2

localStorage, progress persistence, spaced repetition, streaks and mastery UI (M3); WebMIDI,
device detection and automatic step verification (M4); content for Sampling, Sequencer and
Leveling up (M3); bulk authoring of the full Preparation and Pad play banks (Fable's content
workflows); exercise search, printing, sharing, a glossary page; and any change to M0's
toolchain pins, `install-toolchain.sh`, `serve-site.sh`, `site/static/index.js`, the vendored
WASI shim, or M1's parser behaviour, outline rule, routing scheme or page-image delivery.
