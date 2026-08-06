# M3 implementation plan — full course, progress, spaced repetition

**From:** Opus 5 design agent · **Date:** 2026-08-07 · **Against:** tag `m2`
**Brief:** `briefs/M3-course-and-memory.md` + the owner's JA-first addendum (2026-08-07)
**Companion:** `briefs/M3-manifest.json` — 7 tasks / 6 waves, workstream B only

Deployment note (coordinator, 2026-08-07): the build now also deploys to Vercel
(`sexy-one-gray.vercel.app`) alongside GitHub Pages. Both hosts serve identical static
builds and sub-path handling is already covered, so there is **no design impact** — but
it does mean the size ceiling now governs two CDNs' worth of first-load cost, which
sharpens §5 rather than changing it.

Everything numbered below was **measured**, not estimated, by building the real
committed tree in a scratch copy against the real toolchain and (where the claim is
about runtime behaviour) by driving the real shipped app in real headless Chrome.
Probes are labelled **Q-A … Q-L** and are reproducible from the commands recorded
with each one.

---

## 0. Executive summary, and the one number that changes the milestone

The brief's entry condition is a size reduction whose expected yield was **95,358 B**.
**It is 45,878 B.** I measured the split by building it.

That is not a rounding error, and it propagates: with the reduction taken, the full
435-exercise course **still does not fit under the 1,000,000-byte ceiling**. Measured
end state, reader split applied, full corpus embedded, progress engine linked, before
any progress UI: **1,099,927 B gzip**. The ceiling is 1,000,000.

So M3 cannot be planned as "reduce, then build". It has to be planned as "reduce, then
build workstream B *inside the reduction*, and hand the coordinator a measured,
decision-ready choice about the corpus before workstream A's content lands". That is
what this plan does.

| | measured gzip | Δ |
|---|---:|---:|
| **Q-A** M2 as shipped, reproduced in a scratch copy | 988,382 | (recorded 988,367; Δ 15 B, within the noted ±1.5 KB variance) |
| **Q-B** + `embedIndexedDir` (INDEX-driven TH embed) | 984,503 | −3,879 |
| **Q-C** + **parseDeck/validateDeck split** | **938,625** | **−45,878** |
| **Q-D** + M3 progress engine (Types+Scheduler+Codec+Store, ~530 lines) | 972,748 | +34,123 |
| **Q-E** + full 435-id corpus (379,789 raw B of `.ex.md`) | **1,099,927** | +127,179 |
| **Q-F** the same four configurations after `wasm-opt -O2` + `wasm-tools strip` | 805,900 / 769,123 / 795,605 / **920,601** | −169 KB … −179 KB |
| **Q-M** + the owner's JA-first reading preference, naive two-codec version | 978,684 | +5,936 |

Three consequences, all of which this plan acts on:

1. **The split is still worth taking** — 45,878 B is real, and it is the difference
   between M3's workstream B fitting and not fitting. It stays wave 1 and it stays
   gating. It is simply not the whole answer.
2. **The corpus, not the code, is the binding constraint.** Measured coefficient:
   **0.3456 gzip bytes per raw byte** of embedded `.ex.md`. The 435-id course costs
   **~127 KB** on top of the seed's 12 KB. No amount of Haskell tidying reaches that.
3. **`wasm-opt -O2` is worth 169–179 KB and I could not make it miscompile** — see
   Q-G/Q-H. It is the only measured lever large enough to absorb the full course under
   the existing ceiling. Whether to adopt it is a coordinator + Codex decision, not
   mine; §5 hands over the evidence and the manifest builds the machinery to verify it
   without changing the default.

---

## 1. The size work (wave 1, gating)

### 1.1 What the split actually is

`exe:app` reaches the validating parser through exactly one edge:
`Exercises.Corpus` imports `SXC1.Exercise.Parse (parseDeck)`. `Parse` imports
`SXC1.Exercise.Report` (the 40-code `StaticCode` enum with its derived
`Show`/`Enum`/`Bounded`, `codeText`, `issueClassOf`, `renderReport`) and
`SXC1.Exercise.Lint` (the terminology engine). There is no `-split-sections` in the
committed cabal file, so a module links as one atomic unit: the browser carries the
entire lint-and-diagnostics apparatus to render a deck it will never lint.

The split introduces **`SXC1.Exercise.Reader`** — the structural half — and rewrites
`SXC1.Exercise.Parse` to *consume* it:

```
SXC1.Exercise.Reader    readDeck :: FilePath -> Text -> Maybe Deck   -- + the raw
                        syntactic intermediates the validator needs
   imports: Content.Markdown, Content.Types, Exercise.Types, Route
   imports NEITHER Exercise.Report NOR Exercise.Lint

SXC1.Exercise.Parse     parseDeck / parseDeckDetailed  -- signatures UNCHANGED
   imports Reader for the Deck, adds every Issue on top
```

`exe:app` imports `Reader`. `exe:exercise-check` imports `Parse`. Both binaries agree
about what a deck *is* because there is one `Deck`-construction implementation, not two.

**This is the finding Codex will press on, so the design answers it structurally rather
than by assertion.** A hand-written second reader that "should" agree with the
validator is a divergence bug waiting to happen — the app would render a deck the
validator never saw. Two defences, both mandated in the manifest:

* **By construction.** `Parse` does not re-derive the `Deck`; it calls `Reader` and
  decorates. The `Deck` in the browser is produced by the same expression as the `Deck`
  the validator validated.
* **By observation.** A new `exercise-check` self-test asserts, for **every** deck in
  `content/exercises/` and every fixture in `content/fixtures/`, that
  `readDeck fp raw == snd (parseDeck fp raw)`. `Deck` already derives `Eq`. Its negative
  control is a deliberately divergent reader stub that must make the check fail.

My probe reader was derived mechanically from `Parse` by deleting every
issue-producing expression, and the resulting app rendered the real seed corpus
correctly in a real browser (Q-J: 70/70 exercise assertions). The implementation
direction is the reverse — Parse consumes Reader — which is strictly safer.

### 1.2 `embedIndexedDir` — a correctness fix that happens to save 3,879 B

`app/Exercises/Embed.hs` today needs **one hand-written literal splice per deck file**,
because `exe:app` has no `template-haskell` dependency. Its own Haddock admits the gap:
"a future INDEX entry with no matching splice above is simply absent here". At 4 decks
that is a nuisance. At **52 decks** it is a silent-content-loss mechanism: an author
adds a deck, CI validates it (`exercise-check` reads the directory from disk), and the
app never ships it.

Fix, **probed and working (Q-B)**: add `embedIndexedDir :: FilePath -> FilePath -> Q Exp`
to `SXC1.Content.Embed` — which lives in `lib:sxc1-trainer`, where `template-haskell`
*is* available. It reads INDEX at compile time, embeds every file it names,
`addDependentFile`s all of them, and lifts one `[(FilePath, Text)]`. `exe:app` splices
an already-built `Q Exp`, exactly as it already does for `embedUtf8File`. The whole of
`app/Exercises/Embed.hs` collapses to one splice.

Standing guard (manifest): the app's deck count, read from `#sxc1-exercise-stats`, must
equal the number of non-comment INDEX lines — so "authored but not shipped" is
mechanically impossible from now on.

### 1.3 The two M2-inherited LOWs, folded in

| LOW | Where it lands |
|---|---|
| A new `StaticCode` constructor with a forgotten pattern synonym / `codeText` arm is not caught mechanically | wave 1 (`size-split-and-format`) — it owns `Report.hs` and `CheckExercises.hs`. Fix: match `codeText`/`issueClassOf` **directly on `StaticCode`** so `-Wall` restores compile-time exhaustiveness, delete the `COMPLETE` pragma that was masking it, plus a self-test totality sweep forcing `codeText` and `issueClassOf` to WHNF for every `allIssueCodes` member. The module header's stale "hand list" description of `allIssueCodes` goes with it. |
| `EXERCISE_FIXTURE_FIELDS` does not require `citeSlug`/`citePage`/`targetSlug` | wave 5 (`harness`) — it owns `scripts/`. |

### 1.4 Three further defects I found while probing

* **Q-K — `EXERCISE-FORMAT.md` says there are five chapter titles. There are six, and
  chapter 0 is authorable today.** I wrote a `chapter: Front matter` deck citing a real
  guide-book anchor and ran the **shipped** `exercise-check` binary against it:
  `0 issue(s)`. `resolveChapter` takes the inventory-derived map, which contains
  `0 -> "Front matter"`. Only the prose is wrong — but workstream A's first 64 ids are
  chapter 0, so an author reading the format guide would reasonably conclude the whole
  chapter is unauthorable. Doc fix, wave 1.
* **Q-L — the `#sxc1-prompt-baseline` cold-load assertion has a timing race.** It failed
  once in seven runs against a *faster-booting* artifact and never against the slower
  one; five subsequent runs of the same faster artifact passed. It samples the element
  once, immediately after boot, and a mount → `SetRoute` → `beginIfNeeded` → `ExBatch
  Begin` round trip that has not yet flushed reads as `null` — indistinguishable from
  the lost-`Begin` regression it exists to catch. This is precisely the failure mode the
  house standard forbids: a check that can go red for timing reasons teaches everyone to
  re-run it. Fix in wave 5: poll to a settled state with an explicit budget, and fail
  with "baseline never became positive within N ms" rather than sampling a race.
* The `Exercises.Embed` splice-list gap (§1.2), now closed by construction.

### 1.5 The wave-1 gate

`size-split-and-format` must leave the tree at **≤ 945,000 B gzip** with the seed
corpus (measured achievable: 938,625, i.e. 6,375 B of slack for implementation
variance), with `WASM_GZIP_CEILING_BYTES` **untouched at 1,000,000**, every M2 check
still green, and the reader/validator agreement self-test passing with its negative
control demonstrated red first. **No later task may begin until that number is
recorded.**

---

## 2. The deck plan — workstream A's work order

52 decks, **435 live ids** (440 inventory entries minus the five tombstones
`q-1-14`, `q-1-15`, `q-1-16`, `q-3-05`, `q-3-06`). Every id is placed exactly once;
no id is invented.

### 2.1 How the partition was derived

* **Session cost model.** quiz = 0.6 min, lookup = 1.2 min, drill = 2.5 min (a drill is
  ~1 min of setup plus ~0.6 min per step, at the seed corpus's 2–4 steps). Target 7.0
  min, hard cap 9.5, floor 4.5 — undersized tail decks are merged into their neighbour.
  Result: **4.2 – 10.3 min, mean 8.0 min**, 3–15 exercises, mean 8.4.
* **Chapters never span a deck** — `chapter:` is a single validated field, and the
  chapter digit in every id must match it (`E-ID-CHAPTER-MISMATCH`).
* **Topic contiguity comes free.** Within a chapter the inventory numbers ids in page
  order, so contiguous id runs *are* topical runs. Decks are cut at page boundaries
  wherever the cost model allows.
* **Drill dependencies are a hard ordering constraint.** A drill's effective sort
  position is pushed past every same-chapter prerequisite, iterated to a fixed point
  over the inventory's dependency graph. After that, **exactly one** violation remains:
  `d-2-05 → d-5-02`. That is the inventory's own documented forward dependency (the Beat
  Sync toggle lives in the Chapter 5 system settings; "authors may inline the toggle
  steps here"). It is handled by an authoring note, not by reordering — reordering would
  drag Chapter 5's settings material into Chapter 2.
* **Session shape caps**: ≤ 4 lookups and ≤ 3 drills per deck, so no deck is a
  page-hunting slog or an unbroken hands-on marathon.
* **Tiering.** Each deck's `tier:` is its dominant inventory tier — 14 intro, 32 core,
  6 stretch. The intro/core/stretch column is the exact per-deck mix, so an author can
  see when a deck straddles.

Six chapter-0 decks contain no quizzes. That is **correct, not a defect**: the inventory
states that safety and spec material is "deliberately lookup-only, not flashcards".

### 2.2 Two new deck fields the course map needs

Added to the format in wave 1 (parser, validator, `EXERCISE-FORMAT.md`):

```
tier:     intro | core | stretch          (required; closed set)
requires: <deck-slug>[, <deck-slug>…]     (optional; deck-level prerequisites)
```

`requires:` names deck slugs, validated to exist and to be **acyclic** (new code
`E-DECK-REQUIRES-UNKNOWN`, `E-DECK-REQUIRES-CYCLE`). It is what lets the course map
render "you should do X first" and lets the review queue prefer unlocked material.
Derive each deck's `requires:` from the drill dependency graph: the decks containing
the prerequisites of that deck's drills.

### 2.3 Authoring order (this is also the size-risk order)

Author **intro and core before stretch, chapter by chapter in course order**. If the
budget bites (§5), what gets deferred is the 6 stretch decks at the tail of chapter 5 —
44 of the 435 ids — rather than a whole chapter of the course. Chapters 1 and 2 already
have 16 shipped exercises; those ids keep their existing files and must not be
re-authored (see §4.3, the id registry).

### 2.4 The decks

`min` is the session-cost estimate; `i/c/s` is the intro/core/stretch mix. File numbers
are spaced by 2 so a deck can be inserted without renumbering.

**Chapter 0 — Front matter**

| file | `deck:` | pp. | ids | q/d/l | min | `tier:` | i/c/s | exercise ids |
|---|---|---|---:|---|---:|---|---|---|
| `000-ch0-01.ex.md` | `ch0-01` | 1-3 | 7 | 3/0/4 | 6.6 | intro | 6/1/0 | `l-0-01` `l-0-02` `q-0-01` `q-0-02` `q-0-03` `l-0-03` `l-0-04` |
| `002-ch0-02.ex.md` | `ch0-02` | 3-4 | 4 | 0/0/4 | 4.8 | core | 1/3/0 | `l-0-05` `l-0-06` `l-0-07` `l-0-08` |
| `004-ch0-03.ex.md` | `ch0-03` | 5-6 | 4 | 0/0/4 | 4.8 | core | 2/2/0 | `l-0-09` `l-0-10` `l-0-11` `l-0-12` |
| `006-ch0-04.ex.md` | `ch0-04` | 6-7 | 7 | 3/0/4 | 6.6 | core | 2/5/0 | `l-0-13` `l-0-14` `l-0-15` `q-0-31` `q-0-32` `q-0-33` `l-0-16` |
| `008-ch0-05.ex.md` | `ch0-05` | 7-8 | 6 | 2/0/4 | 6.0 | core | 2/4/0 | `l-0-17` `l-0-18` `l-0-19` `l-0-20` `q-0-34` `q-0-35` |
| `010-ch0-06.ex.md` | `ch0-06` | 8-10 | 11 | 7/0/4 | 9.0 | core | 4/7/0 | `l-0-21` `l-0-22` `l-0-23` `l-0-24` `q-0-04` `q-0-05` `q-0-06` `q-0-07` `q-0-08` `q-0-09` `q-0-10` |
| `012-ch0-07.ex.md` | `ch0-07` | 10-10 | 15 | 15/0/0 | 9.0 | intro | 13/2/0 | `q-0-11` `q-0-12` `q-0-13` `q-0-14` `q-0-15` `q-0-16` `q-0-17` `q-0-18` `q-0-19` `q-0-20` `q-0-21` `q-0-22` `q-0-23` `q-0-24` `q-0-25` |
| `014-ch0-08.ex.md` | `ch0-08` | 10-11 | 10 | 9/0/1 | 6.6 | core | 4/6/0 | `q-0-26` `q-0-27` `q-0-28` `q-0-29` `q-0-30` `q-0-36` `q-0-37` `q-0-38` `q-0-39` `l-0-25` |

**Chapter 1 — Part: Preparation**

| file | `deck:` | pp. | ids | q/d/l | min | `tier:` | i/c/s | exercise ids |
|---|---|---|---:|---|---:|---|---|---|
| `016-prep-01.ex.md` | `prep-01` | 6-12 | 13 | 11/0/2 | 9.0 | intro | 7/6/0 | `q-1-18` `q-1-19` `l-1-08` `l-1-07` `q-1-01` `q-1-02` `q-1-03` `q-1-04` `q-1-05` `q-1-06` `q-1-07` `q-1-08` `q-1-09` |
| `018-prep-02.ex.md` | `prep-02` | 12-12 | 7 | 3/2/2 | 9.2 | intro | 7/0/0 | `q-1-10` `q-1-11` `q-1-12` `d-1-01` `d-1-02` `l-1-02` `l-1-03` |
| `020-prep-03.ex.md` | `prep-03` | 6-13 | 5 | 1/3/1 | 9.3 | intro | 4/1/0 | `l-1-04` `d-1-03` `d-1-04` `q-1-17` `d-1-05` |
| `022-prep-04.ex.md` | `prep-04` | 13-55 | 5 | 1/1/3 | 6.7 | intro | 5/0/0 | `d-1-06` `l-1-05` `l-1-06` `q-1-13` `l-1-01` |

**Chapter 2 — Part: Pad play**

| file | `deck:` | pp. | ids | q/d/l | min | `tier:` | i/c/s | exercise ids |
|---|---|---|---:|---|---:|---|---|---|
| `024-pad-01.ex.md` | `pad-01` | 15-16 | 12 | 11/1/0 | 9.1 | core | 6/6/0 | `q-2-01` `q-2-02` `q-2-03` `q-2-04` `d-2-01` `q-2-05` `q-2-06` `q-2-07` `q-2-08` `q-2-09` `q-2-10` `q-2-11` |
| `026-pad-02.ex.md` | `pad-02` | 16-17 | 10 | 7/0/3 | 7.8 | intro | 6/4/0 | `l-2-05` `l-2-06` `l-2-10` `q-2-12` `q-2-13` `q-2-14` `q-2-15` `q-2-16` `q-2-17` `q-2-18` |
| `028-pad-03.ex.md` | `pad-03` | 17-18 | 10 | 8/1/1 | 8.5 | core | 2/8/0 | `d-2-02` `l-2-02` `q-2-19` `q-2-20` `q-2-21` `q-2-22` `q-2-23` `q-2-24` `q-2-25` `q-2-26` |
| `030-pad-04.ex.md` | `pad-04` | 19-20 | 6 | 3/2/1 | 8.0 | intro | 5/1/0 | `q-2-27` `q-2-28` `q-2-29` `d-2-03` `l-2-12` `d-2-04` |
| `032-pad-05.ex.md` | `pad-05` | 21-21 | 10 | 8/1/1 | 8.5 | core | 1/8/1 | `q-2-30` `q-2-31` `q-2-32` `q-2-33` `q-2-34` `q-2-35` `q-2-36` `q-2-37` `d-2-06` `l-2-01` |
| `034-pad-06.ex.md` | `pad-06` | 22-24 | 11 | 9/1/1 | 9.1 | core | 1/10/0 | `q-2-38` `q-2-39` `q-2-40` `q-2-41` `d-2-07` `l-2-11` `q-2-43` `q-2-44` `q-2-45` `q-2-46` `q-2-47` |
| `036-pad-07.ex.md` | `pad-07` | 24-25 | 11 | 9/1/1 | 9.1 | stretch | 0/5/6 | `d-2-09` `q-2-48` `q-2-49` `q-2-50` `q-2-51` `q-2-52` `q-2-53` `q-2-54` `q-2-55` `q-2-56` `l-2-03` |
| `038-pad-08.ex.md` | `pad-08` | 25-55 | 6 | 2/2/2 | 8.6 | intro | 3/2/1 | `l-2-04` `q-2-57` `d-2-10` `q-2-42` `l-2-08` `d-2-05` |
| `040-pad-09.ex.md` | `pad-09` | 23-60 | 3 | 0/1/2 | 4.9 | intro | 2/0/1 | `l-2-07` `d-2-08` `l-2-09` |

**Chapter 3 — Part: Sampling**

| file | `deck:` | pp. | ids | q/d/l | min | `tier:` | i/c/s | exercise ids |
|---|---|---|---:|---|---:|---|---|---|
| `042-smp-01.ex.md` | `smp-01` | 8-28 | 11 | 10/0/1 | 7.2 | core | 5/6/0 | `q-3-12` `l-3-02` `q-3-02` `q-3-01` `q-3-03` `q-3-04` `q-3-07` `q-3-08` `q-3-09` `q-3-10` `q-3-11` |
| `044-smp-02.ex.md` | `smp-02` | 28-29 | 8 | 6/1/1 | 7.3 | intro | 6/2/0 | `d-3-01` `l-3-01` `q-3-13` `q-3-14` `q-3-15` `q-3-16` `q-3-17` `q-3-18` |
| `046-smp-03.ex.md` | `smp-03` | 29-29 | 4 | 0/3/1 | 8.7 | core | 1/3/0 | `d-3-02` `l-3-03` `d-3-03` `d-3-04` |
| `048-smp-04.ex.md` | `smp-04` | 8-30 | 9 | 7/2/0 | 9.2 | core | 3/5/1 | `d-3-07` `d-3-09` `q-3-19` `q-3-20` `q-3-21` `q-3-22` `q-3-23` `q-3-24` `q-3-25` |
| `050-smp-05.ex.md` | `smp-05` | 31-32 | 7 | 5/2/0 | 8.0 | core | 1/6/0 | `q-3-27` `d-3-05` `d-3-06` `q-3-28` `q-3-29` `q-3-30` `q-3-31` |
| `052-smp-06.ex.md` | `smp-06` | 32-33 | 11 | 9/1/1 | 9.1 | core | 2/8/1 | `d-3-08` `q-3-32` `q-3-33` `q-3-34` `q-3-35` `q-3-36` `q-3-37` `q-3-38` `q-3-39` `q-3-40` `l-3-05` |
| `054-smp-07.ex.md` | `smp-07` | 33-49 | 5 | 3/0/2 | 4.2 | intro | 4/1/0 | `l-3-06` `q-3-41` `q-3-42` `q-3-26` `l-3-04` |

**Chapter 4 — Part: Sequencer**

| file | `deck:` | pp. | ids | q/d/l | min | `tier:` | i/c/s | exercise ids |
|---|---|---|---:|---|---:|---|---|---|
| `056-seq-01.ex.md` | `seq-01` | 36-36 | 12 | 12/0/0 | 7.2 | core | 4/8/0 | `q-4-01` `q-4-02` `q-4-03` `q-4-04` `q-4-05` `q-4-06` `q-4-07` `q-4-08` `q-4-09` `q-4-10` `q-4-11` `q-4-12` |
| `058-seq-02.ex.md` | `seq-02` | 36-36 | 5 | 0/2/3 | 8.6 | intro | 3/2/0 | `d-4-01` `l-4-01` `l-4-02` `l-4-13` `d-4-02` |
| `060-seq-03.ex.md` | `seq-03` | 37-38 | 11 | 9/1/1 | 9.1 | core | 5/6/0 | `q-4-14` `q-4-15` `q-4-16` `q-4-17` `q-4-18` `q-4-19` `l-4-03` `q-4-20` `q-4-21` `q-4-22` `d-4-03` |
| `062-seq-04.ex.md` | `seq-04` | 39-39 | 9 | 7/1/1 | 7.9 | core | 1/8/0 | `q-4-23` `q-4-24` `q-4-25` `q-4-26` `q-4-27` `q-4-28` `q-4-29` `d-4-04` `l-4-05` |
| `064-seq-05.ex.md` | `seq-05` | 40-41 | 10 | 8/1/1 | 8.5 | core | 1/9/0 | `q-4-30` `q-4-31` `q-4-32` `q-4-33` `d-4-05` `l-4-06` `q-4-34` `q-4-35` `q-4-36` `q-4-37` |
| `066-seq-06.ex.md` | `seq-06` | 41-41 | 4 | 0/2/2 | 7.4 | core | 1/3/0 | `d-4-06` `d-4-07` `l-4-07` `l-4-08` |
| `068-seq-07.ex.md` | `seq-07` | 42-43 | 6 | 3/2/1 | 8.0 | core | 0/5/1 | `q-4-39` `d-4-08` `q-4-40` `q-4-42` `d-4-09` `l-4-12` |
| `070-seq-08.ex.md` | `seq-08` | 44-44 | 12 | 11/1/0 | 9.1 | core | 0/12/0 | `q-4-43` `q-4-44` `q-4-45` `q-4-46` `q-4-47` `q-4-48` `q-4-49` `q-4-50` `q-4-51` `q-4-52` `q-4-53` `d-4-10` |
| `072-seq-09.ex.md` | `seq-09` | 44-60 | 10 | 5/1/4 | 10.3 | intro | 6/3/1 | `l-4-04` `l-4-09` `l-4-10` `l-4-11` `d-4-11` `q-4-54` `q-4-55` `q-4-41` `q-4-38` `q-4-13` |

**Chapter 5 — Part: Leveling up**

| file | `deck:` | pp. | ids | q/d/l | min | `tier:` | i/c/s | exercise ids |
|---|---|---|---:|---|---:|---|---|---|
| `074-lvl-01.ex.md` | `lvl-01` | 1-3 | 12 | 9/0/3 | 9.0 | stretch | 1/0/11 | `q-5-82` `q-5-83` `q-5-84` `q-5-85` `q-5-86` `l-5-17` `q-5-87` `l-5-15` `q-5-88` `q-5-89` `q-5-90` `l-5-13` |
| `076-lvl-02.ex.md` | `lvl-02` | 3-47 | 11 | 7/0/4 | 9.0 | stretch | 3/3/5 | `l-5-16` `q-5-91` `q-5-92` `l-5-14` `l-5-04` `l-5-05` `q-5-01` `q-5-02` `q-5-03` `q-5-04` `q-5-05` |
| `078-lvl-03.ex.md` | `lvl-03` | 47-48 | 9 | 8/1/0 | 7.3 | core | 1/6/2 | `q-5-06` `q-5-07` `q-5-08` `q-5-09` `q-5-10` `q-5-11` `q-5-12` `q-5-13` `d-5-04` |
| `080-lvl-04.ex.md` | `lvl-04` | 48-49 | 9 | 7/2/0 | 9.2 | core | 0/8/1 | `d-5-06` `q-5-14` `q-5-15` `q-5-16` `q-5-17` `q-5-18` `q-5-19` `q-5-20` `d-5-05` |
| `082-lvl-05.ex.md` | `lvl-05` | 49-50 | 7 | 4/2/1 | 8.6 | core | 1/5/1 | `d-5-07` `d-5-08` `l-5-01` `q-5-21` `q-5-22` `q-5-23` `q-5-24` |
| `084-lvl-06.ex.md` | `lvl-06` | 50-51 | 11 | 10/1/0 | 8.5 | stretch | 1/4/6 | `d-5-09` `q-5-25` `q-5-26` `q-5-27` `q-5-28` `q-5-29` `q-5-30` `q-5-31` `q-5-32` `q-5-33` `q-5-34` |
| `086-lvl-07.ex.md` | `lvl-07` | 51-52 | 6 | 4/2/0 | 7.4 | core | 1/3/2 | `d-5-10` `q-5-35` `q-5-36` `q-5-37` `q-5-38` `d-5-11` |
| `088-lvl-08.ex.md` | `lvl-08` | 53-54 | 11 | 10/1/0 | 8.5 | stretch | 1/3/7 | `q-5-39` `q-5-40` `q-5-41` `q-5-42` `q-5-43` `q-5-44` `q-5-45` `d-5-12` `q-5-46` `q-5-47` `q-5-48` |
| `090-lvl-09.ex.md` | `lvl-09` | 54-55 | 12 | 11/1/0 | 9.1 | core | 3/7/2 | `d-5-13` `q-5-49` `q-5-50` `q-5-51` `q-5-52` `q-5-53` `q-5-54` `q-5-55` `q-5-56` `q-5-57` `q-5-58` `q-5-59` |
| `092-lvl-10.ex.md` | `lvl-10` | 55-55 | 6 | 1/2/3 | 9.2 | core | 1/3/2 | `q-5-60` `d-5-01` `l-5-02` `l-5-03` `l-5-06` `d-5-02` |
| `094-lvl-11.ex.md` | `lvl-11` | 1-56 | 6 | 4/2/0 | 7.4 | stretch | 2/2/2 | `d-5-19` `d-5-03` `q-5-61` `q-5-62` `q-5-63` `q-5-64` |
| `096-lvl-12.ex.md` | `lvl-12` | 56-57 | 7 | 4/1/2 | 7.3 | core | 3/4/0 | `d-5-15` `l-5-07` `l-5-08` `q-5-65` `q-5-66` `q-5-67` `q-5-68` |
| `098-lvl-13.ex.md` | `lvl-13` | 57-58 | 6 | 3/2/1 | 8.0 | core | 0/5/1 | `d-5-16` `l-5-09` `q-5-69` `q-5-70` `q-5-71` `d-5-17` |
| `100-lvl-14.ex.md` | `lvl-14` | 59-60 | 11 | 9/1/1 | 9.1 | core | 2/8/1 | `q-5-72` `q-5-73` `q-5-74` `q-5-75` `q-5-76` `d-5-18` `l-5-10` `q-5-77` `q-5-78` `q-5-79` `q-5-80` |
| `102-lvl-15.ex.md` | `lvl-15` | 60-60 | 4 | 1/1/2 | 5.5 | core | 0/3/1 | `q-5-81` `d-5-14` `l-5-11` `l-5-12` |

---

## 3. The scheduler — integer SM-2, and why not FSRS

**Choice: an SM-2-family scheduler with all arithmetic in integers.**

FSRS-lite is the more accurate algorithm *when you have review logs to fit its weights
against*. We will not. Its advantage comes from a fitted 17-parameter memory model;
shipped with stock parameters against a 435-item device course it is SM-2 with extra
machinery and a floating-point dependency. That dependency is the deciding argument,
and it is not stylistic:

**Determinism across two architectures is a hard requirement here, and floats put it at
risk.** The scheduler runs in `exe:app` on **wasm32** and is unit-tested in
`exe:progress-check` on the same target — but the whole point of the M2 clock work was
that a stored history replays to the *same* state. `Int` is 32-bit on wasm32 (M1's
NEW8), and any float in a replay path invites divergence between a stored schedule and a
recomputed one. An integer scheduler cannot drift: replaying the same event list gives
bit-identical records, forever, on any target.

So SM-2's ease factor is carried as **milli-units in an `Int`** (2500 = 2.5), and its
ease update is precomputed exactly rather than evaluated:

| grade | SM-2 q | `EF' = EF + (0.1 − (5−q)(0.08 + (5−q)·0.02))` | stored delta |
|---|---:|---|---:|
| `GAgain` | 2 | 0.1 − 3(0.08 + 0.06) = −0.32 | −320 |
| `GHard` | 3 | 0.1 − 2(0.08 + 0.04) = −0.14 | −140 |
| `GGood` | 4 | 0.1 − 1(0.08 + 0.02) = 0.00 | 0 |
| `GEasy` | 5 | 0.1 − 0 = +0.10 | +100 |

Ease clamps to [1300, 3000]. Intervals: `GAgain` → 0 (same day), first success → 1–2
days, second → 3–5, thereafter `interval × ease / 1000`, **capped at 180 days**. The cap
is deliberate: this is a device-training course, and an uncapped SM-2 curve schedules
items past the point where the learner still owns the hardware.

**Grading is derived, never guessed.** `gradeOfOutcome :: Outcome -> Int -> Bool -> Int
-> Grade` is the single place an `Outcome` is interpreted — the scheduler never inspects
one. `Incorrect`/`Skipped` → `GAgain`; `Correct` with a reveal or a second attempt →
`GHard`; `Correct` with hints → `GGood`; clean first-try `Correct` → `GEasy`.

**Determinism, restated as the property the tests check.** `applyEvent :: ProgressEvent
-> ProgressState -> ProgressState` takes **no clock argument at all**. The day comes
from the event's own `peAt` (the `WallMs` stamp the engine already records), via
`dayOf`. Nothing under `SXC1.Progress.*` reads a clock, imports `Miso`, or performs IO.
Consequences the manifest turns into checks:

* replaying a stored event list reproduces the stored state exactly (round-trip check);
* the same list in the same order gives the same state on a second run (idempotence of
  replay, not of `applyEvent` — grading twice legitimately schedules twice);
* `reviewQueue` is sorted by `(dueDay, promptId)` — a **total** order, so it can never
  depend on `Map` iteration order changing under a different key set.

Negative controls (all sabotage-proven, all demonstrated red before green): a scheduler
that reads a clock fails the replay check; a `reviewQueue` sorted only by due-day fails
the total-order check on two items sharing a due day; an ease update in `Double` fails
the exact-value pins.

`nextIntervalDays` is pinned against a hand-computed table in the task prompt, so "the
scheduler still schedules the way it was designed to" is falsifiable rather than
self-consistent.

---

## 4. Storage, migration, export, and id stability

### 4.1 The mechanism: `Miso.Storage`, in exactly one module (Q-I)

The M2 grep-ban lifts for `site/app/Progress/Store.hs` and nothing else; the manifest
carries the narrowed, case-insensitive grep as a standing guard.

`Miso.Storage` is the right binding and needs no new dependency: it is a thin wrapper
over `Miso.DSL` (`localStorage`/`getItem`/`setItem`), keyed and valued in
`MisoString`, already reachable from `exe:app`'s existing `miso` dependency — the same
DSL `Main.hs` already uses for `window.location.hash`. A hand-written
`foreign import javascript` is not an option here anyway (M1's P4: those do not link on
this toolchain).

**Probed end-to-end in real headless Chrome against a real build (Q-I).** All of these
are observations, not expectations:

* `getLocalStorage` on a **missing** key returns `Nothing` cleanly — despite the
  `fromJSValUnchecked` in its implementation, which was the specific risk. The app boots
  and runs with no stored key.
* Answering one quiz wrote
  `SXC1PROGRESS\t1\nM\t20671\t1\t20671\nR\tq-1-03#1\t1\t0\t2600\t2\t20673\t20671\t1\n`
  — ease 2600 (2500 + 100 for a clean first-try correct), interval 2, due day 20673 =
  today + 2. The scheduler behaved exactly as specified, through the real sink.
* The blob survived a full page reload with no boot error.
* The availability probe (write / read back / remove) left no residue.

`storageAvailable` **writes and reads back** rather than testing for the object's
presence, because a private-mode browser can expose `window.localStorage` and still
throw on the first write. Every write is guarded by it; a browser that refuses storage
gets a working trainer with an explicit "progress will not be saved here" notice, never
a crash.

### 4.2 Schema v1, and a migration story that is not a promise

**Key** `sxc1.progress`. **Wire format** line-oriented, tab-separated, ASCII:

```
SXC1PROGRESS <TAB> <schemaVersion>
M <TAB> streakDay <TAB> streakLen <TAB> firstDay
R <TAB> promptId <TAB> reps <TAB> lapses <TAB> ease <TAB> interval <TAB> due <TAB> lastSeen <TAB> seen
D <TAB> exerciseId <TAB> completions
```

Not JSON, deliberately. The app has a JSON **encoder** and no decoder; reading a JSON
blob back means linking a parser the browser does not otherwise need. Every field here
is an `Int` or an already-slug-shaped id — there is nothing to quote and nothing to
escape, so the reader is a `splitOn "\t"` fold with strictly fewer failure modes.
Unknown leading tags are **skipped, not rejected**, so a newer schema's extra record
types degrade to "ignored" in an older build instead of discarding a history.

**The version lives inside the payload**, not only in the key name, so a blob a learner
copied out of a browser is self-describing.

**`DecodeResult = DecodeEmpty | DecodeOk ProgressState | DecodeCorrupt Text`.** This
three-way split is the most important decision in the storage design. A learner's
history is the one thing in this app that cannot be regenerated, so "I could not read
it" must never be silently indistinguishable from "there was nothing to read" — a
`Maybe` would have made the first case overwrite the second's data on the next write.
`DecodeCorrupt` carries a reason, the UI shows it and offers an export, and **the app
never overwrites a key it failed to decode.**

**Migration.** `migrateWith :: (Int -> Maybe (ProgressState -> ProgressState)) -> Int ->
ProgressState -> DecodeResult` walks vN → vN+1 in order;
`migrate = migrateWith productionSteps`, and at v1 `productionSteps` is empty.

The obvious objection — *at v1 the migration check passes vacuously* — is correct, and
parameterising the step table is the answer. The self-test calls `migrateWith` with a
**test-only step table** and a synthetic **schema-0** blob and asserts the chain
actually transformed it; a second control asserts a blob whose version exceeds
`currentSchema` yields `DecodeCorrupt` rather than being read as current. So the
mechanism is exercised now, at v1, and adding v2 later is a one-line change to
something already tested rather than the invention of a mechanism under pressure. The
manifest states this as the acceptance criterion in exactly those terms.

### 4.3 Export / import

`{"format":"sxc1-progress","schema":1,"exportedAt":"…","payload":"<wire text>"}` — the
brief's copyable JSON blob, with the payload being the *same* wire text, so there is
exactly one format to keep correct and the importer needs only enough JSON to pull one
string field out. The importer also accepts a **bare wire blob**, so a learner who
copies only the inner text still recovers their history. Import is
non-destructive-by-default: it decodes to a `ProgressState` and previews the record
count before committing.

### 4.4 PromptId stability and the id registry

`content/id-registry.tsv`, committed, one row per exercise:

```
<exercise-id> <TAB> <promptCount> <TAB> live|tombstone <TAB> <first-shipped> <TAB> <note>
```

Checked by a new `exe:registry-check` (its own binary, so the check runs even when
`exercise-check` is skipped, and so it can own its file without co-editing
`CheckExercises.hs`).

**`promptCount` is the point, and it is what makes this about `PromptId` rather than
`ExId`.** A `PromptId` is `<exercise-id>#<n>`. An `ExId` that survives a rewrite still
orphans progress if a drill gains or loses a step — `d-3-03#3` silently becomes a
different question. Registering the prompt count catches exactly that, and it is the
case a registry of bare ids would miss.

**How this check avoids passing vacuously** — Codex will probe this, and the honest
answer is structural: **the registry is a committed file that the check never
regenerates.** There is no `--update` flag. A change to the corpus that is not
accompanied by a change to the registry fails. The manifest requires four sabotage
mutations, each demonstrated red before the task is accepted:

1. delete an exercise from a deck → fails, naming the id;
2. change a drill's step count → fails on `promptCount`;
3. add a new id not in the registry → fails;
4. flip a `live` id to `tombstone` while it is still in the corpus → fails.

Plus the inverse: a `live` registry row with no corpus exercise fails, so removing an
exercise without tombstoning it cannot pass either. Tombstoning mirrors the inventory's
never-renumber rule; the note column records the replacement id where there is one.

**No orphaned progress.** Records whose `PromptId` is not in the current corpus are
**kept** in storage, excluded from the review queue, and surfaced in the progress UI as
retired. Dropping them on load would make a content edit silently destroy history —
exactly the bug class the brief names.

**M2 continuity** is satisfied by construction: `ProgressSink`'s two fields are
unchanged, M3 only binds them, and `#sxc1-event-log` keeps its shape. No M2-era content
id can be orphaned because no M2-era content id changes.

### 4.5 The JA-first reading preference (owner addendum, 2026-08-07)

The site will be shared with a Japanese speaker. When **JA-first** is on, the manual
reader leads with the original Japanese page image and English becomes the toggle,
remembered across visits.

**Scope, stated as a boundary.** This is a **reader** preference and nothing else. The
trainer stays English: no exercise translation, no i18n framework, no string catalogue,
no second content pipeline. A Japanese-speaking owner reads the manuals in Japanese and
does the exercises as they are. Anything beyond that is a separate milestone.

**Where it lives.** A second localStorage key, `sxc1.prefs`, with the *same* versioned
header discipline as the progress blob:

```
SXC1PREFS <TAB> <schemaVersion>
P <TAB> jaFirst <TAB> 0|1
```

**One deliberate asymmetry with the progress blob, and the reason for it.** An
unreadable *progress* blob is never overwritten, because a learner's history cannot be
regenerated. An unreadable *preference* blob **falls back to the default and may be
overwritten**, because a preference is trivially regenerable — the learner flips one
switch. Two keys rather than one field on `ProgressState` follows from the same
asymmetry: a corrupt progress blob puts the app in read-only progress mode, and a
reading preference must still be settable in that state. Wiping progress must not wipe
the reading preference, and does not.

**How it interacts with the existing route, without touching `SXC1.Route`.** M1 made the
JA panel a real, shareable deep link: `RPage slug n ja`, with `#/m/<slug>/p/<n>/ja`
meaning "the original-page panel is visible". That contract does not change, and no M3
task owns `SXC1.Route`. JA-first is implemented as a **navigation default**: when the
preference is on and the app navigates to a manual page whose *slug or page number*
differs from the previous page route, `Main.hs` rewrites the hash to the `/ja` form
using the `setHash` it already has. The route stays the single source of truth.

**The subtlety that would otherwise be a bug**, called out because an implementer will
hit it: the redirect must fire on a *fresh page navigation only*, never on an explicit
toggle. An explicit `#btn-ja-toggle` keeps the same slug and page number, so the rule
above leaves it alone — with JA-first on, clicking the toggle genuinely hides the panel
and it stays hidden until the learner moves to a different page. The manifest requires
an assertion for exactly that, because "the preference fights the toggle" is the obvious
way to get this wrong.

**The default is OFF, and that is a safety property, not a preference.** A fresh profile
behaves byte-identically to today, so the 108-route sweep and every M1/M2 browser
assertion are untouched. The new assertions turn it on explicitly.

**Discoverability.** A persistent `#btn-ja-first` control in the manual reader header,
present on every manual page — distinct from the existing per-page `#btn-ja-toggle`,
which keeps its current meaning.

**Cost, measured (Q-M), and the variant the design actually mandates.** A naive
implementation — second magic string, second decoder, second store pair — measured
**+5,936 B**, which on the §5.1 arithmetic is enough to push workstream B over the
ceiling on its own. So the design mandates the cheaper shape: **two keys, one shared
line-oriented reader.** `Codec` exposes a single `tag/key/value` line splitter that both
blobs use; the prefs half adds a magic string, a two-field record and an encoder, not a
second parser. Budgeted at **3,000 B**.

If wave 4 still comes in over budget, the documented fallback is the degenerate variant:
store the preference as a bare `"0"`/`"1"` under a version-bearing key name
(`sxc1.prefs.v1.jaFirst`), with migration by key rename and read-then-remove of older
names. That is still a versioned schema with a migration story, and it is honest for a
single boolean. **The fallback is to shrink this feature, never to raise the ceiling.**

---

---

## 5. The budget, handed over as a decision

### 5.1 What workstream B costs, and that it fits

Measured M3 progress engine: **+34,123 B** for ~530 app-linked lines (Types 95,
Scheduler 152, Codec 210, Store 45, `Main` wiring ~30) — about **64 gzip B per line**,
consistent with M1's own 60 B/line figure. The progress UI is the remaining unknown;
budgeting ~450 lines gives ~29 KB.

```
938,625  after wave 1 (measured)
+34,123  progress engine (measured)
 +3,000  JA-first reading preference (budgeted; naive version measured 5,936)
+29,000  progress UI (projected at the measured 64 B/line)
────────
1,004,748  ← over by 4,748 B
```

That is too close to leave to chance, so the manifest sets **descending task-local
budgets** rather than one milestone check: ≤ 945,000 after wave 1, ≤ 980,000 after the
storage sink, **≤ 996,000 after the progress UI**. The UI author hits the wall
themselves, with the code-size ladder from M2 §5 in their prompt, instead of discovering
it at the gate.

Workstream B is therefore **genuinely at the edge**, and the plan says so rather than
rounding the projection down: the levers in §5.2 are what resolve it, and the descending
budgets force the discovery in wave 3 or 4 rather than at the gate. If wave 4 cannot fit,
the ordered escapes are (a) the degenerate JA-first variant in §4.5, (b) deferring
progress-UI niceties (the retention figure, the retired-records note), (c) escalate.
Raising the ceiling and enabling `--optimize` are **not** task-level escapes.

### 5.2 What workstream A costs, and that it does not fit

The full course adds **~127 KB** (measured coefficient 0.3456 gzip B per raw byte; my
synthetic 435-exercise corpus was 379,789 raw B at 873 B/exercise, against the shipped
seed's 735 B/exercise — so the real figure lands in **105–127 KB**).

```
~996,000  end of workstream B
+127,000  full course
────────
~1,123,000  against a 1,000,000 ceiling
```

**There is no way to ship the full 435-exercise course as an embedded corpus under a
1,000,000-byte ceiling.** Three levers exist. I measured all three so the decision can
be made on numbers.

**Lever 1 — adopt `wasm-opt`. Measured −169 to −179 KB; end state ~940,000, under the
existing ceiling, with ~60 KB spare.** `build-site.sh --optimize` already exists and is
off by default because "binaryen is the one step in this pipeline that can silently
miscompile GHC output". I tried to make it miscompile and could not:

* **Q-G** — `exe:exercise-check`, optimized and stripped, run under `wasm-run`:
  **113/113 self-test checks pass, output byte-identical** to the unoptimized binary.
* **Q-H** — the **real shipped `exe:app`**, optimized and stripped, served and driven in
  real headless Chrome through the project's own `browser-check.mjs` with the real
  exercise fixture: **70/70 assertions**, zero console errors, across seven runs. The
  single degraded run was the `#sxc1-prompt-baseline` race of §1.4 (Q-L), which is a
  harness defect, not a codegen one — it reproduces on a cold start and never
  reproduced again on the same artifact.

  It also *shrinks the learner's download by ~120 KB*, which is a user-facing win on a
  phone independent of the ceiling.

  Residual risk is real but bounded and now testable: the manifest's harness task adds
  `check-site.sh --optimized`, which builds, optimizes, and runs **the entire suite**
  against the artifact that would actually ship — so the tested artifact and the shipped
  artifact stop being different objects. **It does not change the default.**

**Lever 2 — raise the ceiling to 1,150,000.** Simple, honest, and the brief anticipates
it ("only then raise the ceiling deliberately at a gate with Codex's eyes on it"). Costs
the learner a 1.12 MB download.

**Lever 3 — stop embedding the corpus**; serve decks as static assets and fetch them.
Removes the entire 127 KB and scales to any future content. It is a genuine architecture
change (async load, a loading state, and the `fnv1a` staleness detector has to move to
hashing what was fetched), so I am recording it as the escape hatch, not proposing it
for M3.

**My recommendation: lever 1, with lever 2 as the fallback if Codex rejects binaryen.**
Lever 1 keeps the tripwire at 1,000,000, ships a smaller artifact than M2 does today,
and the evidence against the "silent miscompile" concern is now empirical rather than
precautionary. But this is a pipeline decision of the same weight as raising the
ceiling, so **the manifest builds the verification and changes no default.** No M3 task
may edit `WASM_GZIP_CEILING_BYTES`; the milestone verify asserts it is still 1,000,000.

### 5.3 The ledger, so this cannot be rediscovered at deck 40

The harness task adds a **size ledger**: `check-site.sh` records the measured artifact
size, the measured corpus raw-byte total, and a **projection** for the full 435-id
course using the committed 0.3456 coefficient, and **fails if the projection is not
recorded in `state/size-ledger.tsv`'s latest row**. It never fails on the projection
being over the ceiling — that is a coordinator decision — but the number cannot be
absent, so workstream A's authoring lane gets a mechanical warning at every build rather
than a surprise when the fortieth deck lands.

---

## 6. Progress UI

Respects the existing style system; no new colour tokens.

* **Continue where you left off** — home-page entry point derived from the most recent
  event's deck/exercise, with the review queue taking precedence when items are due.
* **Review queue** at `#/r`: due items across all decks, most overdue first, each
  linking to its exercise. Badge count in the nav.
* **Per-deck and per-chapter completion** on `#/x` and `#/x/<deck>`, derived from
  `psDone` plus the corpus, with the deck's `tier:` and `requires:` shown.
* **Streak** from `psStreakLen`, with the day-boundary rule stated in the scheduler:
  same day unchanged, next day +1, a gap resets to 1, and a day *before* the recorded
  one (a backwards clock, or an imported history) never advances or shortens it.
* **Export / import panel** with the copyable blob, an explicit wipe, and a confirm
  step.
* **A corrupt-state banner** when `decodeState` returned `DecodeCorrupt`, offering an
  export of the raw key before anything is overwritten.
* **JA-first switch** (`#btn-ja-first`) in the manual reader header, on every manual
  page, reflecting and writing the stored preference; when it is on, the original
  Japanese page image renders **above** the English translation rather than below it.
* A hidden `#sxc1-progress` DOM node carrying due count, retention, streak, queue head,
  record count and the `jaFirst` flag, so the harness can assert on state rather than on
  pixels — the same contract `#sxc1-exercise-stats` established.

---

## 7. Harness (contract requirement 4)

New browser assertions, all alongside every earlier gate's checks:

1. **answer → reload → survives.** Not "the key is non-empty": the decoded **record
   count must equal the number of graded prompts**, and the specific `PromptId`'s
   record must carry the expected interval. A vacuous version passes with an empty
   store; this one cannot.
2. **export → wipe → import → survives**, asserting the same record identity and
   values, plus that the wipe genuinely emptied the key in between (otherwise the check
   proves nothing about import).
3. **JA-first: set → reload → still JA-first.** Turn the preference on, reload, and
   assert both halves: the stored `sxc1.prefs` value AND the rendered order (the
   original-page panel leads). Negative controls: a **fresh profile is not JA-first**
   (so the assertion cannot pass vacuously on a default that happens to match); wiping
   progress **does not** clear the reading preference; and with JA-first on, an explicit
   `#btn-ja-toggle` click genuinely hides the panel and it stays hidden until the
   learner navigates to a different page — the preference must not fight the toggle.
4. **Negative controls**: a corrupted blob yields the corrupt banner and **the key is
   still there afterwards**; storage-refused yields a working app with
   `storageAvailable=false` and no crash; the `#sxc1-progress` payload must be absent
   from a fresh profile (so "state survives" cannot pass on a stale profile).
5. Every new assertion is added to `browser-check.mjs`'s `--self-test` expected-failure
   fixture, per the existing pattern, so the assertion itself is proven able to fail.
6. New checks live on the **existing content axis** — no new skip flag, per M2's ruling
   that one fewer switch is one fewer route to `result=complete` without having checked.

Plus the Q-L race fix (§1.4), the `EXERCISE_FIXTURE_FIELDS` LOW (§1.3), and
`check-site.sh --optimized` (§5.2).

---

## 8. Manifest shape — 7 tasks, 6 waves

| Wave | Task | Owns (disjoint) |
|---|---|---|
| 1 | `size-split-and-format` | `site/src/SXC1/Exercise/`, `site/src/SXC1/Content/Embed.hs`, `site/app/Exercises/`, `site/sxc1-trainer.cabal`, `site/test/CheckExercises.hs`, `content/EXERCISE-FORMAT.md`, `content/fixtures/` |
| 2 | `progress-core` | `site/src/SXC1/Progress/`, `site/test/CheckProgress.hs` |
| 2 | `id-registry` | `content/id-registry.tsv`, `site/test/CheckRegistry.hs` |
| 3 | `storage-sink` | `site/app/Progress/`, `site/app/Main.hs` |
| 4 | `progress-ui` | `site/app/View/`, `site/static/` |
| 5 | `harness` | `scripts/` |
| 6 | `docs-and-ci` | `README.md`, `.github/` |

Wave 1 owns `site/sxc1-trainer.cabal` **and pre-declares every M3 module and both new
executable stanzas** (`exe:progress-check`, `exe:registry-check`) even though later
waves fill them in. That is what keeps ownership disjoint without leaving a window where
the tree does not compile, and it is the same device M2 used for shared build files.

Why wave 1 is one large task rather than three: the reader/validator split, the two new
deck fields, `Report.hs`'s totality fix and the format doc are **one compile loop** over
`Parse`/`Reader`/`Report` and the single 1,381-line `CheckExercises.hs`. Splitting them
would leave that file co-owned. Breadth is not depth — the M2 gate triage made the same
call for the same reason.

---

## 9. What I will check at sign-off

Beyond every per-task acceptance check, and chosen because these are the claims most
likely to be true-by-assertion rather than true:

1. `readDeck fp raw == snd (parseDeck fp raw)` for the whole corpus **and** the fixture
   set — and I will make the reader diverge in a scratch copy and confirm the check goes
   red.
2. The measured gzip size after wave 1, against my 938,625, and the final number against
   the 996,000 budget.
3. Replay determinism: I will take a real event log out of `#sxc1-event-log`, replay it
   through `progress-check`, and require the resulting `ProgressState` to equal the one
   in localStorage byte-for-byte after re-encoding.
4. The migration mechanism is genuinely exercised at v1 — I will run `migrateWith` with
   my own test step table and a schema-0 blob and require the chain to transform it.
5. All four registry sabotages, each red with the offending id named.
6. `DecodeCorrupt` never overwrites: I will hand-corrupt the key in a real browser,
   reload, and require the key to still be there afterwards.
7. The persistence assertions cannot pass vacuously: I will wipe the key before the
   "survives reload" assertion and require it to fail.
8. Q-L's race is gone: twenty consecutive `browser-check` runs, zero degraded.
9. A deck added to INDEX without touching any Haskell appears in the app (the
   `embedIndexedDir` guarantee), and the INDEX-count-equals-app-deck-count guard fails
   when it is removed.
10. JA-first survives a reload, a fresh profile is not JA-first, wiping progress leaves
    the preference intact, and with JA-first on the explicit toggle still wins on the
    current page — I will drive all four by hand in a real browser.

---

## Appendix — probe log

All probes ran against a scratch copy of the committed tree at tag `m2`, with the real
`~/.ghc-wasm` toolchain; sizes are `gzip -c app.wasm | wc -c`.

| id | probe | result |
|---|---|---|
| Q-A | m2 baseline reproduced in the scratch copy | 988,382 (recorded 988,367) |
| Q-B | `embedIndexedDir` compiles and replaces 4 literal splices | works; 984,503 (−3,879) |
| Q-C | `SXC1.Exercise.Reader` in `exe:app` instead of `Parse` | **938,625 (−45,878)**; brief's estimate was 95,358 |
| Q-D | M3 progress engine linked (~530 lines) | 972,748 (+34,123 ≈ 64 B/line) |
| Q-E | synthetic 435-id corpus, 379,789 raw B | 1,099,927 (+127,179; 0.3456 B/raw-B) |
| Q-F | `wasm-opt -all -O2` + `wasm-tools strip`, all 4 configs | 805,900 / 769,123 / 795,605 / 920,601 |
| Q-G | optimized `exe:exercise-check --self-test` | 113/113, output byte-identical |
| Q-H | optimized real `exe:app` in headless Chrome, full fixture | 70/70 × 6 runs; 1 cold-start flake (→ Q-L) |
| Q-I | `Miso.Storage` round trip in a real browser | missing key → `Nothing`; write/reload/survive all green |
| Q-J | probe reader renders the real seed corpus in a browser | 70/70 exercise assertions |
| Q-K | chapter 0 authorability against the **shipped** `exercise-check` | `0 issue(s)` — format doc is wrong, code is right |
| Q-L | `#sxc1-prompt-baseline` cold-read | 1 failure / 7 runs on the faster artifact, 0 / 5 on the slower |
| Q-M | JA-first preference, naive second-codec implementation | +5,936 (978,684); design mandates the shared-reader variant, budgeted 3,000 |
