# M2 plan amendments — re-baselined against tag `m1`

**From:** Opus 5 design agent · **Date:** 2026-08-06
**Amends:** `briefs/M2-plan.md` (written against the M1 *plan*)
**Companion:** `briefs/M2-manifest.json` — **regenerated in place**, 7 tasks / 6 waves unchanged

`briefs/M2-plan.md` was designed against `briefs/M1-plan.md` before M1 shipped. M1 then went
through three sign-off rounds and two Codex gate rounds. I re-read the committed tree at tag
`m1` and re-probed the real library. **The drift is material — the manifest does not stand
as-is** — but it is all local: the architecture, the content format's shape, the engine
design, the M3/M4 interfaces and the 7-task / 6-wave structure are unchanged. What changed is
that several assumptions written against a plan are now bound to shipped code, plus three
inherited findings and one budget I did not know about.

Everything below was verified by compiling a throwaway executable against the **real committed
`lib:sxc1-trainer`** and by running the new guards against the live tree. Probe results are
recorded as **P-H … P-N** in the manifest's shared context block.

---

## 1. Parser-reuse assumptions — three confirmed, three corrected

The plan said "reuses M1's block and inline parsers". That is still the design; the API is now
pinned to what `SXC1.Content.Markdown` actually exports.

**Confirmed.**

* `parseBlocksEngine :: Int -> Bool -> [Text] -> [Text] -> ([Block], [Text])` works on
  exercise prose as `parseBlocksEngine 0 False []`, and returns the anchor-slug supply
  untouched (`[]`), so exercise prose never needs and never perturbs one (**P-H**).
* `pageCount = 0` makes `parseInline` **never** emit a `PageRef` — measured both directions:
  `parseInline 0 "see p. 17 now" = [Str "see p. 17 now"]` versus
  `parseInline 71 … = [Str "see ", PageRef 17 "p. 17", Str " now"]` (**P-H**). This is now a
  normative decision rather than an accident: a bare `p. N` is ambiguous across four documents,
  so **every** manual link goes through an explicit `cite:`/`find:` with a slug — which is also
  what makes `E-LOOKUP-SPOILER` meaningful.
* Field lines do not collide with the block grammar: `classifyLine "type: quiz"` and
  `classifyLine "cite: …"` are both `ParaShape`, and indented continuations likewise.

**Corrected.**

* **P-J — task lists are not a construct.** `- [x] \`A\`` parses as an ordinary `Bullets` item
  whose inline content still literally begins `"[x] "`. The plan implied the parser would hand
  back a task list. It will not. The choice list must therefore be **lifted off the raw body
  lines before block parsing**, via `bulletItemOf` plus a `[x] `/`[ ] ` prefix test.
  `bulletItemOf` is **not currently exported** (only `orderedItemOf` is) — widening that export
  is now an explicit wave-1 deliverable.
* **P-I / P-K — heading placement.** `headingLineOf` is column-0 only on the raw line, so the
  structural splitter uses it directly and levels 4–6 stay in the body. But an *indented*
  heading is not reliably a heading: an indent-3 `###` under `1. ` folded into a paragraph and
  would render as literal hash marks. New issue code **`E-BODY-INDENTED-HEADING`** rejects
  indented `#{1,6} ` lines in exercise prose, so content cannot depend on that shape.
* **P-M — the route round-trip test would have been vacuous.** `#/x`, `#/x/deck` and
  `#/x/deck/ex` **already round-trip today**, as `RNotFound`, because
  `renderRoute (RNotFound p) = "#/" <> p`. The self-test must assert the **constructor** and
  carry an explicit negative control that `parseRoute "#/x"` is not `RNotFound`. (Also: `Int`
  is 32-bit on wasm32 — M1's NEW8 — so the lookup's page-number parsing must reuse
  `parseDigits`, fold in `Integer`, and never call `read`.)

**`E-BLOCK-UNPARSED` is now unreachable from any file.** `classifyLine`'s `ParaShape` is a
genuine catch-all, and `Unparsed` is reachable only through `parseBlocksEngineWith`'s
`DeclinedShape` seam. My original coverage invariant ("every code must have a file fixture")
would therefore have been unsatisfiable. Fix: `--list-codes` now emits
`<CODE><TAB><file|dir|seam>`, and **the `seam` class is capped at exactly one code, which must
be `E-BLOCK-UNPARSED`** — asserted literally in `check-site.sh` and at the milestone level, so
`seam` cannot become a hiding place for codes nobody demonstrates.

---

## 2. Content is now bound to the committed exercise inventory

`content/exercise-inventory.md` (657 lines, **440 stable ids**) plus `content/inventory/part-0
… part-5.md` did not exist when the plan was written. It is the master plan for all exercise
content, and it fixes ids permanently: *"Ids are stable: never renumber; retired items keep
their id with a tombstone note."* Since M3 will key saved progress and spaced repetition to
`<exercise-id>#<step>`, the seed set must not invent its own ids.

* Ids come **from the inventory**. Four new `dir`-class codes: `E-ID-NOT-IN-INVENTORY`,
  `E-ID-RETIRED` (q-1-14/15/16 are genuine tombstones), `E-ID-TYPE-MISMATCH` (leading letter
  vs `type:`), `E-ID-CHAPTER-MISMATCH` (chapter digit vs the deck's `chapter:`). They apply to
  `content/exercises/` **only**, never to `--fixtures`.
* The `chapter:` vocabulary is no longer a hard-coded list of five titles. It is **parsed from
  the inventory's `### Chapter N — <title>` course map** and cross-checked against
  `Outline.outPartTitles` and the glossary — three independent sources. I ran that parser
  against the real file: 440 entries and
  `{0: Front matter, 1: Part: Preparation, 2: Part: Pad play, 3: Part: Sampling,
  4: Part: Sequencer, 5: Part: Leveling up}`. This also removes a latent problem: the
  inventory's chapter 0 (front matter, pp. 1–11) has no `Part:` title, so a hard-coded
  five-title list would have forced a format change in M3. It no longer will.
* Seed scope restated in inventory terms: **chapters 1 and 2**, 112 candidates
  (19+57 quiz, 6+10 drill, 8+12 lookup). Note the inventory's chapter numbers are offset by one
  from the book's PART numbers.
* The inventory's citation shorthand — bare `(p. N)` = guide book, `Startup Guide p. N`,
  `midi.md p. N` — must be translated into explicit slugged `cite:`/`find:` lines.

---

## 3. The three inherited findings, folded into the tasks that own the files

| Finding | File | Task | Wave |
|---|---|---|---|
| **NEW11** — classifier seam recurses without consuming input | `site/src/SXC1/Content/Markdown.hs`, `site/test/CheckContent.hs` | `exercise-core` | 1 |
| **NEW12** — an empty assertion group prints FAIL but exits 0 | `site/test/CheckContent.hs` | `exercise-core` | 1 |
| **NEW9-partial** — `--expect-json` schema still partly vacuous | `scripts/browser-check.mjs` | `exercise-ui` | 4 |

**NEW11 is not theoretical — I reproduced the hang.** A probe calling
`parseBlocksEngineWith (const OrderedShape) 1 False [] ["ordinary text"]` did not terminate and
was killed by a 60-second timeout (exit 124); the same binary with only that line removed
finished in well under a second (**P-L**). This lands on `exercise-core` for a reason beyond
ownership: the exercise parser becomes the **second production caller** of that engine, so the
seam's termination guarantee stops being someone else's problem. The fix is progress evidence
from the list branch plus `OrderedShape`/`BulletShape` dishonest-classifier fixtures — and the
module's Haddock claim that termination holds for any classifier must be made *true*, not
softened.

**NEW12** is fixed with a `groupsOk` accumulator (every group non-empty **and** fully passing,
folded into the exit condition) plus a permanent negative-control demo, following the existing
group-16 vacuity-guard pattern. The new `exercise-check` runner must not reproduce the pattern
from birth. I ran the guard against today's tree: it correctly **fails** (`no
groups-completeness accumulator in CheckContent.hs`), so it is a real check, not a formality.

**NEW9-partial**: `REQUIRED_STATS_FIELDS` gains `title` and `partTitles`, and the reverse
comparison becomes an exact multiset comparison that rejects duplicate slugs in the app
payload. The *new* `--expect-exercise-json` is specified exact-in-both-directions from birth,
so M2 does not ship a fresh copy of the same weakness.

---

## 4. Harness extension points, bound to current numbering and semantics

* **`content-check`** has **20 assertion groups / 347 checks**, labelled by
  `assertionLabel :: Int -> String`, run by `forM_ [1 .. 20]` over `allChecks` filtered on
  `chkGroup`. M2 adds group(s) 21+ for the NEW11 fixtures and must move the loop bound and
  `assertionLabel` together, so no labelled group goes unchecked and no group goes unlabelled.
* **`check-site.sh`** is **55 checks**. `result=complete` is emitted **iff `SKIPPED == 0`**, and
  the file's own comment notes a future third axis is covered for free *as long as it reports
  through `skip()`*. **M2 adds no new skip flag**: the exercise checks live on the existing
  **content axis**, so `--skip-content` / `SXC1_SKIP_CONTENT=1` skips them through `skip()`.
  One fewer switch is one fewer route to `result=complete` without having checked. A new
  negative control asserts `SXC1_SKIP_CONTENT=1` yields `result=structural-only`.
* **Staleness.** M1 proves the app is not stale by byte-diffing
  `content-check --dump-source <slug>` against each translations file. **That trick cannot
  transfer**: `exercise-check` reads content off disk, so it can never witness what the app
  *embedded*. M2's equivalent is `#sxc1-exercise-stats` carrying, per deck, `chars`, `lines`
  and **`fnv1a`** — FNV-1a/32 over the **UTF-8 bytes** of the embedded text (basis 2166136261,
  prime 16777619, mod 2³²), recomputed from disk in Python by `check-site.sh`. `chars` alone
  would miss a same-length edit. Test vectors are pinned in both task prompts:
  `"" → 2166136261`, `"hello" → 1335831723`, `"SELECT BANK 1" → 1835518890`,
  `U+2295 U+2296 → 3369799694` (the last one proves *bytes*, not code points).
* **`build-site.sh`** line 90 currently builds `exe:app exe:content-check`; M2 appends
  `exe:exercise-check`. Inside `check-site.sh` the runner is `wasm-run.mjs` **from PATH** after
  sourcing the toolchain env — the new checks follow that convention, while task-level verify
  commands may use the absolute path.
* **Invariant greps** are anchored to non-comment lines (`^[^-]*…`), per M0's finding n2, and
  the persistence grep is case-insensitive because Miso's API is `setLocalStorage` — a
  case-sensitive search for `localStorage` would have missed it entirely.

---

## 5. Size budget — the constraint I did not have

M1 added check 13, the **A5 size tripwire**: `WASM_GZIP_CEILING_BYTES = 1000000`. Measured at
tag `m1`:

| | bytes |
|---|---:|
| `site/public/app.wasm` raw | 3 780 124 |
| `site/public/app.wasm` gzip | **828 138** |
| ceiling | 1 000 000 |
| **headroom for all of M2** | **171 862** |

M1's own growth is the best available estimate: M0 → M1 was +183 686 gzip bytes, of which
~79 KB was the embedded corpus, so ~105 KB of gzip bought ~1 750 lines of Haskell — roughly
**60 gzip bytes per line**. M2 adds on the order of 1 900 lines (parser, lint, verify, engine,
report, views, embed) plus ~16 KB of deck markdown, i.e. **≈120 KB gzip against 171.8 KB of
headroom**. That fits, with perhaps 50 KB of slack — too tight to discover in wave 5.

Amendments:

1. `exercise-ui` (wave 4) must measure `gzip -c site/public/app.wasm | wc -c` after its **first**
   successful build and again at the end, and its verify enforces a **tighter task-local budget
   of 950 000 bytes** — so the problem surfaces with the author who can fix it.
2. **No M2 task may edit `WASM_GZIP_CEILING_BYTES`.** `verification` carries an explicit guard
   asserting it is still `1000000`, and the milestone gate asserts both the constant and that
   the artefact fits. Silently raising a tripwire is precisely the failure mode this project
   has been burned by twice.
3. A code-size ladder is written into the prompts, in order: derive **`Eq` only** on
   `Deck`/`Exercise`/`Prompt`/`PromptBody`/`Option`/`Citation` (no derived `Show` — the
   validator hand-writes its diagnostics renderer, which it needs anyway); **reuse
   `SXC1.Content.Stats`'s JSON encoder and `jsonEscape`** rather than writing a second; share
   helpers with `View.Blocks`; keep `-O1`; do **not** enable `build-site.sh --optimize`.
   If it still does not fit, stop and escalate — raising the ceiling is a coordinator decision.

---

## 6. What did **not** change

The content format's shape (`.ex.md`, one deck per file, `##` exercises, `key: value` field
blocks, `###` roles, GFM choices); anchored citations; the terminology TSV with its
`glossary_anchor` grounding; the one-engine/`PromptBody` architecture; `step` as a pure total
function taking both clocks; the `ProgressEvent`/`ProgressSink` M3 shape and `#sxc1-event-log`;
the `VerifySpec`/`DeviceVerifier` M4 shape validated against `midi.md`; the DOM contract; the
fixture corpus with filename-declared verdicts and exact code-set matching; the sabotage
controls; and the 7 tasks in 6 waves with the same ownership map. `site/cabal.project` is still
untouched (**P-G**).

---

## 7. Verification of these amendments

* The manifest is regenerated and passes a mechanical validator: M0-schema parity, disjoint
  `owned_paths`, wave-ordered `depends_on`, dependency closure over every path any verify
  command reads, `bash -n` on all **89** verify commands and their inner scripts, and
  `compile()` on all **12** embedded Python programs.
* New guards were run against the live `m1` tree and behave correctly:
  A5 ceiling guard **passes**; size measurement reports `828138`; `no new skip axis` **passes**;
  the seam-cap and `--list-codes` shape checks accept a well-formed listing and **reject** both
  a second `seam` code and a missing class column; the inventory guard **fails** with
  `no exercises found` (wave 3 has not run); and the NEW12 guard **fails** with
  `no groups-completeness accumulator in CheckContent.hs` — i.e. the inherited findings' checks
  are red today and will only go green when actually fixed.
* Every mutation in the wave-1 and wave-3 sabotage sweeps was re-run and produces exactly one
  intended defect.

## 8. Sign-off additions

To §10 of `briefs/M2-plan.md` I add: (11) `content-check` still reports 20+ groups with every
group non-empty, and I will delete a group from a scratch copy and confirm a non-zero exit;
(12) the NEW11 seam reproduction terminates with an `Unparsed` report rather than hanging, and
I will re-run my own `(const OrderedShape)` probe; (13) `gzip -c app.wasm` is recorded in the
sign-off with its delta from 828 138; (14) every seed id resolves to a live, non-retired
inventory entry, and I will retire one in a scratch copy and confirm rejection.
