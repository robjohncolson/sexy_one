# M2 Codex gate — consolidated Opus triage (parts 1 + 2)

**From:** Opus 5 design agent · **Date:** 2026-08-07
**Reviewing:** `briefs/M2-codex-part1.json` (PART1-BLOCKED) and `briefs/M2-codex-part2.json`
(GLOBAL VERDICT: **GATE-BLOCKED**)
**Companion:** `briefs/M2-gate-fixes-manifest.json` (2 tasks, 2 waves)
**Supersedes:** `briefs/M2-gate-part1-triage.md` (part 1 only; retained for its reproductions)

## Verdict

**I concur with all sixteen findings. Zero disputes.** Codex ran nothing — both parts were
read-only by subagent constraint — so I reproduced every finding at runtime: eight against the
real `exercise-check` binary, one against the real engine via a purpose-built probe, six in a
real browser against the shipped build, one by source.

**GATE-BLOCKED is correct, and my sign-off was wrong.** I granted M2 having driven a quiz, a
drill and a lookup by hand. I checked `#ex-cites` on the quiz and never re-checked it on the
other two — where it does not exist at all. That is the same shape of mistake as the deselect
pathology I caught in the swarm: I verified the path I had specified rather than the path a
learner walks.

| id | sev | source | verdict | reproduced |
|---|---|---|---|---|
| H1 clock epoch conflation | HIGH | p1 | CONCUR — **broader** | engine probe |
| H2 anchor length/syntax defeats | HIGH | p1 | CONCUR | both defeats, validator |
| H3 drill-step lint exemption | HIGH | p1 | CONCUR — both halves | validator |
| H4 deck slug not unique | HIGH | p1 | CONCUR | validator |
| H5 empty drill-step body | HIGH | p1 | CONCUR | validator |
| H6 cold deep link never begins | HIGH | p2 | CONCUR — **narrower impact** | browser |
| H7 Restart shows stale result | HIGH | p2 | CONCUR | browser |
| H8 drill/lookup citations never render | HIGH | p2 | CONCUR — **broader** | browser |
| M1 citation totals + correlated recount | MED | p1 | CONCUR — **broader** | 32 vs 34 |
| M2 seam cap not closed over emitted codes | MED | p1 | CONCUR | source |
| M3 rendered-identical choice labels | MED | p1 | CONCUR | validator |
| M4 check 14 certifies presence not wiring | MED | p2 | CONCUR | source + browser |
| M5 browser elapsed path steps around the bug | MED | p2 | CONCUR | source |
| M6 lookup prose double-rendered, p-in-p | MED | p2 | CONCUR | browser |
| L1 fixtures README describes a fixed defect | LOW | p1 | CONCUR | source |
| L2 `--skip-content` drops 2 counted checks | LOW | p2 | CONCUR | source |
| L3 routes collapse empty segments | LOW | p2 | CONCUR | browser |

Also recorded by Codex and unchanged: the embed census guard **PASSES**, the `ok`-field CI
chain is **non-vacuous for the full chain**, arity-derived selection **PASSES**, NEW11/NEW12
closures **remain effective**, and size is **PASS-WITH-RISK** with the reduce-first M3 plan
accepted. Those stay closed.

---

## Two facts that scope the whole fix

**1. No content re-authoring is required.** I audited the shipped seed corpus against the
*post-fix* rules for both content-facing findings: **32/32** anchors pass the tightened rule
(shortest normalised anchor 16 characters, `Bass drum (kick)`; none syntax-only; all contain
letters), and shipped drill steps contain **zero** glossary violations under the rules they
were wrongly exempt from. H2 and H3 are *defeatable*, not *defeated*. Every fix is code-only,
and "the shipped corpus still reports 0 issues" is a usable standing guard.

**2. The strong H2 fix is safe — I checked before mandating it.** Matching anchors against the
**rendered** page text rather than the raw Markdown source preserves **32/32** shipped anchors,
including the three containing Markdown markers, because both sides normalise through the same
renderer. That eliminates the table-delimiter class by construction instead of blacklisting it.

---

## The clock seam (H1, H6, M4, M5) — one defect with four faces

Reproduced against the real engine, driving `step` directly:

```
Begin wall0                    -> esPromptAt = 1786100000000  (a WALL epoch)
Toggle, Submit (mono0+8400)    -> peElapsed = 0      TRUE 8400
control: Begin mono0, same     -> peElapsed = 8400   TRUE 8400
Restart wall0 -> Submit        -> peElapsed = 0      TRUE 15000
```

`Main.hs:233` is `Begin . snd <$> readClocks` where `readClocks` returns `(mono, wall)`;
`Main.hs:279` is `Restart wall`. **Broader than filed:** `Advance` never re-baselines
`esPromptAt` either — measured 13400 before and 13400 after — so every prompt after the first
is timed from the previous *submit*, charging the learner's explanation-reading time to the
next prompt.

**H6, narrower than filed, and I want to be precise because the difference matters for the
test.** Codex is right that a cold `RExercise` route never calls `beginIfNeeded`, so state comes
from `initialState exid 0`. But the *observable* error is small: I cold-loaded
`#/x/preparation-power/q-1-03`, waited 3 s, answered, and got `elapsedMs = 3723` — plausible,
because Chrome's monotonic origin is page load, so runtime age ≈ time on prompt for a cold deep
link. It is accidentally-correct, not correct: `esStartedAt` is still wrong, and the moment the
H1 fix lands the two paths must be made to agree deliberately rather than by coincidence. A
test that only cold-loads will not distinguish them — which is exactly M5's point.

**M4 and M5 are why none of this was caught, and both are my design's fault.** I specified check
14 as an identifier grep and said so in my own condition; it certifies presence, not wiring, and
passes today against provably wrong wiring. And the browser's only elapsed assertion submits a
**wrong answer first**, which re-baselines `esPromptAt` to a real monotonic reading before the
measured attempt — the timing twin of the deselect pathology, in an assertion I wrote. It then
accepts any `M:SS`, including `0:00`.

**Fix:** one task owning `Engine.hs` **and** `Main.hs` so the seam cannot split. Give
`Begin`/`Restart` both clocks, seed from the monotonic one, re-baseline on `Advance`, issue an
initial `Begin` for a cold exercise route, and make the confusion unrepresentable with
`MonoMs`/`WallMs` newtypes so `Begin . snd` cannot typecheck. **Controls:** a self-test with
deliberately divergent epochs (mono ≈ 5×10³, wall ≈ 1.79×10¹²) pinning `peElapsed == 8400`, and
a browser assertion that cold-loads, waits a known interval, submits **first try**, and requires
the first event's `elapsedMs >= ` that interval.

## H8 — drill and lookup citations are never rendered · CONCUR, broader

Reproduced cold on all three kinds, then again after completion:

```
quiz   #ex-cites a.cite = 0    (pre-answer; they appear post-answer via sharedFeedbackEls)
drill  a.cite = 0  ... and still 0 after all three steps are confirmed
lookup a.cite = 0  ... and still 0 after a CORRECT answer
```

The only citation renderer lives in `sharedFeedbackEls`, which drill bodies never use, and a
lookup's target lives in `FindPage` rather than `exCites`. So **two of the three exercise types
have no path back to the manual at all** — which guts the milestone's stated promise that every
exercise cites manual pages and renders that citation as an internal link. `l-1-04`'s whole
point is finding a page, and after finding it the learner is offered no link to it.

**Fix:** render prompt-level `prCites` for drill steps (after confirmation) and the `FindPage`
target (after grading only — never before, or the lookup spoils itself). **Control:** browser
assertions requiring ≥1 `a.cite` with a correct `#/m/<slug>/p/<n>` href on a completed drill and
a graded lookup, and requiring **zero** on an ungraded lookup.

## H7 — Restart shows a stale graded screen · CONCUR

Reproduced:

```
after correct submit : feedback "Correct."  note? true  next? true
after RESTART        : feedback "Correct."  note? true  next? true  any option pressed? false
```

`Restart` resets `ExerciseState` but emits no event, so `mExResults` keeps the previous
outcome. The learner sees a fresh, unselected prompt that is already telling them they were
right, with the explanation and a working Next. **Fix:** clear this exercise's prompt results on
`Begin`/`Restart`, or derive displayed feedback from attempt-scoped state. **Control:** the
browser sequence above, asserting no feedback, no note and no Next after Restart.

## H2, H3, H4, H5, M1, M2, M3 — carried from part 1, all reproduced

Full reproductions are in `briefs/M2-gate-part1-triage.md` and stand unchanged. In brief:

* **H2** — `"press          the"` (18 raw chars, 9 normalised) and `"|---|---|---|"` cited to
  p.10 both validate with **0 issues**. Fix: measure the ≥12 rule post-normalisation, match
  against rendered text, require at least one letter.
* **H3** — a drill step reading *"This machine responds and you should register the sound
  source"* with body *"Press the pad and hit the pad on this machine to register the sound
  source"* — six violations across four rules — reports **0 issues**. Second half also
  reproduced: `the **machine**` slips through even in covered fields, because `inlinesText`
  joins nodes with a space. Ordinary emphasis defeats the glossary.
* **H4** — two decks both declaring `deck: collided-slug` validate clean; the report lists the
  slug twice and one deck is route-shadowed.
* **H5** — a two-step drill whose steps carry only `cite:` and `check:` validates clean and
  renders confirm buttons with no instructions.
* **M1** — disk has 27 `cite:` + 5 `find:` = **32**; the model reports **34**. Worse, and this
  is my design that is implicated: `check-site.sh` does not independently count those lines, it
  *documents the model's rule and reproduces it*. That is one implementation checked twice, not
  a three-way agreement.
* **M2** — `Report.hs` exports `Issue (..)` with `isCode :: !Text`, so a code can be emitted
  without entering `IssueCode`, invisible to both the coverage invariant and the one-seam cap.
  My own advisory 6, confirmed and sharpened.
* **M3** — options `A` and `**A**` validate clean and render identically.

## M6, L1, L2, L3

* **M6** reproduced: `#ex-stem` and `#ex-find-task` carry identical text and `#ex-find-task`
  contains a block-level child — a `<p>` inside a `<p>`, invalid HTML.
* **L1** confirmed: `content/fixtures/README.md:45` still opens *"Known defect this corpus could
  not route around"* for a defect that is fixed and green at 51/51.
* **L2** confirmed by source: the skip branch omits `skip()` for two checks the full run counts,
  so the totals differ between modes. CI cannot pass either way, but it contradicts the NEW7
  promise that skipped checks stay members of the total.
* **L3** reproduced: `#/x//preparation-power/q-1-03` renders the exercise rather than the
  not-found panel, because `nonEmptySegments` collapses empty components before classification.

---

## Manifest shape — 2 tasks, 2 waves

`briefs/M2-gate-fixes-manifest.json`.

| Wave | Task | Owns | Covers |
|---|---|---|---|
| 1 | `engine-and-validator` | `site/src/SXC1/Exercise/`, `site/src/SXC1/Route.hs`, `site/test/CheckExercises.hs`, `site/app/Main.hs`, `site/app/View/Exercise.hs`, `content/fixtures/` | H1–H8, M1(model), M2, M3, M6, L1, L3 |
| 2 | `harness-honesty` | `scripts/check-site.sh`, `scripts/browser-check.mjs` | M1(recount), M4, M5, L2 + assertions for wave 1 |

**Why the Haskell is one task and not three.** The clock fix must own `Engine.hs` *and*
`Main.hs` together — the coordinator is right that it cannot split. `Begin`/`Restart` changing
shape (and gaining `MonoMs`/`WallMs`) breaks every engine self-test, and all self-tests live in
one 1170-line `CheckExercises.hs`; so does every new validator test. Splitting along
engine-versus-validator lines would leave that file co-owned or leave a window where the tree
does not compile. Breadth is not depth here: thirteen findings, each a small localised change,
one compile loop.

Standing guards on both tasks: the shipped corpus reports **0 issues**, `content-check` stays
**357/357**, `--fixtures` stays green (it grows past 51 as new codes gain fixtures), and the
**32/32 anchor audit** is the H2 regression guard. Every fix carries a sabotage-proven negative
control, each demonstrated **red against today's code before it goes green**.

## What I will check at re-sign-off

Beyond every per-task acceptance check, and chosen because these are the paths I personally
missed: a completed drill and a graded lookup each show a working citation link, and an ungraded
lookup shows none; Restart yields a genuinely blank prompt; a cold-loaded quiz answered
**first try** after a measured wait reports an `elapsedMs` matching that wait; and I will re-run
my own six-violation drill, both anchor defeats, the deck-slug collision and the `A`/`**A**`
pair and require each to be rejected with its exact code.
