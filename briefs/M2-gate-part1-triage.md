# M2 gate part 1 — Opus triage

**From:** Opus 5 design agent · **Date:** 2026-08-07
**Reviewing:** `briefs/M2-codex-part1.json` (Codex `gpt-5.6-sol`, xhigh) — `PART1-BLOCKED`
**Status:** triage complete. **Fix manifest held for part 2** — the clock fix crosses the
Engine/app seam and `Main.hs` is part 2's surface.

## Verdict

**I concur with all nine findings. Zero disputes.** Codex worked read-only and ran nothing;
I reproduced **every** finding at runtime — seven against the real `exercise-check` binary,
one against the real engine via a purpose-built probe, one by source. All nine reproduce
exactly as described. On two I go **broader** than filed (H1, M1).

`PART1-BLOCKED` is the right call. H3 in particular is the kind of hole I should have caught
at sign-off and did not: I drove the drill *interaction* and never asked whether drill *text*
was being linted.

| id | sev | verdict | reproduced | fix lands in |
|---|---|---|---|---|
| H1 | HIGH | CONCUR — **broader** | yes, engine probe | `Engine.hs` + `Main.hs` (part 2 seam) |
| H2 | HIGH | CONCUR | yes, both defeats | `Verify.hs` |
| H3 | HIGH | CONCUR (incl. the inline-markup half) | yes, both halves | `Parse.hs` + `Lint.hs` |
| H4 | HIGH | CONCUR | yes | `CheckExercises.hs` |
| H5 | HIGH | CONCUR | yes | `Parse.hs` |
| M1 | MED | CONCUR — **broader** | yes, 32 vs 34 | `Report.hs` + `check-site.sh` |
| M2 | MED | CONCUR | by source | `Report.hs` |
| M3 | MED | CONCUR | yes | `Parse.hs` |
| L1 | LOW | CONCUR | yes | `content/fixtures/README.md` |

## Two facts that shape the whole fix

**1. No content re-authoring is required.** I audited the shipped seed corpus against the
*post-fix* rules for both content-facing findings:

* all **32/32** anchors pass the tightened rule — shortest normalised anchor is 16 characters
  (`Bass drum (kick)`), none is syntax-only, all contain letters;
* the shipped drill steps contain **zero** glossary violations under the rules they were
  wrongly exempt from.

So H2 and H3 are *defeatable*, not *defeated*. The fixes are validator-only, and
"the real corpus still reports 0 issues" is a usable regression guard.

**2. The strong H2 fix is safe.** I checked before mandating it: matching anchors against the
**rendered** page text rather than the raw source preserves **32/32** shipped anchors,
including the 3 that contain Markdown markers, because both sides normalise through the same
renderer. That kills the table-delimiter class outright rather than blacklisting it.

---

## H1 — Begin/Restart write the wall epoch into a monotonic field · CONCUR, broader

Reproduced against the real engine (probe drives `step` directly, no UI):

```
Begin wall0                      -> esPromptAt = 1786100000000   (a WALL epoch)
Toggle, Submit (mono0+8400)      -> peElapsed = 0        TRUE 8400
Advance, Toggle, Submit          -> peElapsed = 3100     TRUE 3100   (correct)
control: Begin mono0 -> Submit   -> peElapsed = 8400     TRUE 8400
Restart wall0 -> Submit          -> peElapsed = 0        TRUE 15000
```

`Main.hs:233` does `Begin . snd <$> readClocks` and `readClocks` returns `(mono, wall)`, so
`snd` is the wall clock; `Main.hs:279` does `Restart wall`. `initialState` seeds `esPromptAt`
from it, and `Submit` computes `monoMs - esPromptAt`, clamped at 0. Every exercise's **first**
graded prompt, and every first prompt after a Restart, reports a false zero.

**Broader than filed.** `Advance` (Engine.hs:262) never re-baselines `esPromptAt` at all — I
checked: `esPromptAt before Advance = 13400; after = 13400`. So prompt *n+1* is timed from the
previous **submit**, not from when it was displayed. Any time the learner spends reading the
explanation before pressing Next is charged to the next prompt. Smaller than the false zero,
but it is the same field feeding the same M3 consumer, and we are opening the file anyway.

**Fix:** give `Begin`/`Restart` both clocks (`Begin mono wall`), seed `esStartedAt`/`esPromptAt`
from the monotonic one, and re-baseline `esPromptAt` on `Advance`. Then make the confusion
unrepresentable rather than merely fixed: wrap the two in distinct newtypes
(`MonoMs`/`WallMs`) so `Begin . snd` cannot typecheck. **Negative control:** a self-test that
supplies deliberately divergent epochs (mono ≈ 5×10³, wall ≈ 1.79×10¹²) and pins
`peElapsed == 8400` — it must fail against today's engine before it passes.

## H2 — anchors are length-checked pre-normalisation and may be pure syntax · CONCUR

Both defeats reproduced, each **0 issues**:

```
cite: guide-book 15 "press          the"     18 raw chars, 9 normalised  -> ACCEPTED
cite: guide-book 10 "|---|---|---|"          a raw table delimiter row   -> ACCEPTED
```

(My first delimiter attempt cited p.15, which has no such row, and correctly failed; p.10 does,
and it passes. The defect is real, my first probe was simply aimed wrong.)

This defeats the central claim of the citation design — *"the anchor is what makes a citation
mean something."* A length gate measured on the wrong string, plus matching against raw
Markdown source, together admit anchors that carry no semantic content at all.

**Fix, three parts:** measure the ≥12 rule on the **normalised** anchor; match against the
**rendered** page text (parsed blocks → inline text), not raw source; and require the
normalised anchor to contain at least one letter. **Negative controls:** both defeats above
must be rejected post-fix, plus the whole shipped corpus must still validate green.

## H3 — drill-step text is entirely exempt from the glossary · CONCUR, both halves

Reproduced. A two-step drill whose check reads *"This machine responds and you should register
the sound source"* and whose body reads *"Press the pad and hit the pad on this machine to
register the sound source"* — six violations across four rules — reports **0 issues**.

The second half reproduces too. In a field that *is* linted, only the unmarked phrase is
caught:

```
"Do not use the machine plainly. But the **machine** with markup is different."
  -> exactly ONE E-TERM.term-machine   (the marked-up one slips through)
```

`inlinesText` joins inline nodes with a space, so `the **machine**` becomes `the  machine` and
the literal phrase matcher misses it. This is worse than the missing-targets half, because it
silently weakens *every* field, including those I believed covered — and an author using
ordinary emphasis is exactly who trips it.

**Fix:** `parseStep` must return lint targets for step bodies and `check:` text; and
`inlinesText` must join without inserting separators (or normalise runs of whitespace before
matching), so rendering-equivalent prose lints identically. **Negative controls:** the
six-violation drill above must produce E-TERM findings for every rule it breaks, and
`the **machine**` must be caught in both a step body and an exercise intro.

## H4 — deck slugs are not checked for uniqueness · CONCUR

Reproduced. Two indexed deck files both declaring `deck: collided-slug`, with distinct valid
exercise ids, validate with **0 issues**, and the report cheerfully lists
`['collided-slug','collided-slug']`. `#/x/collided-slug` resolves to one of them; the other is
unreachable. `EXERCISE-FORMAT.md:134` calls the slug globally unique, so this is documented-but-
unenforced — the exact shape of defect the fixture corpus exists to prevent.

**Fix:** extend `globalIdDuplicateIssues` to deck slugs, reusing `E-ID-DUPLICATE` (its detail
already names the colliding decks). **Negative control:** a `dirs/` fixture with two decks
sharing a slug, expecting exactly `E-ID-DUPLICATE`.

## H5 — drill steps may have an empty instruction body · CONCUR

Reproduced: a two-step drill whose steps carry only `cite:` and `check:` validates with **0
issues**, and would render confirmation buttons with nothing to do.
`EXERCISE-FORMAT.md:175-176` requires at least one block.

**Fix:** `parseStep` emits `E-FIELD-MISSING` (or a dedicated code) when `stepBodyBlocks` is
null. **Negative control:** a file fixture with a body-less step.

## M1 — citation totals miscount, and the "independent" recount copies the model · CONCUR, broader

Reproduced against the shipped corpus: **27 `cite:` + 5 `find:` = 32 declarations on disk; the
validator reports `citations: 34`.** Quiz citations live in both `exCites` and `prCites` and
count twice; lookup `find:` targets live only in `FindPage` and count zero.

The part that matters more is the second half, and I want to be blunt about it because it is my
design that is implicated. `check-site.sh:1559-1597` does not independently count `^cite:`/
`^find:` lines — it *documents the model's counting rule and reproduces it*. So the two
implementations agree because the second was written to match the first. That is not a
three-way agreement; it is one implementation checked twice. The whole point of §6.1 was to
have a genuinely independent derivation, and on this field it was quietly abandoned.

**Fix:** define `citations` as **declarations** (one per `cite:`/`find:` line, deduplicated
nowhere), make the model count that, and rewrite the Python side as a true line scan with no
knowledge of the Haskell model. **Negative control:** desynchronise them deliberately —
add a `cite:` line to a scratch copy and require the two counts to disagree and the check to go
red. If the recount cannot fail when the model is wrong, it is not a recount.

## M2 — the seam cap is not closed over emitted codes · CONCUR (my advisory 6, sharpened)

Confirmed by source. `Report.hs` exports `Issue (..)` with `isCode :: !Text`, so any module can
construct an issue carrying an arbitrary code string without passing through `mkIssue`/
`IssueCode`. `--list-codes` derives from `allIssueCodes` plus the dynamic `E-TERM` lines, so a
hand-constructed code is invisible to **both** the coverage invariant and the one-seam cap.
Latent today — the escape hatch exists because `Lint` legitimately emits `E-TERM.<rule_id>` —
but the cap is exactly the guarantee I told the gate to test.

**Fix:** make the dynamic family typed (`IssueCode = … | E_TERM Text`, with
`codeText (E_TERM r) = "E-TERM." <> r`) and stop exporting the raw `Issue` constructor —
accessors only, construction via `mkIssue`. Then every emitted code is enumerable by
construction. **Negative control:** a compile-level demonstration that the old raw form no
longer builds.

## M3 — rendered-identical choice labels evade duplicate detection · CONCUR

Reproduced: options `A` and `**A**` in one quiz validate with **0 issues** and render as the
same visible label, so the learner faces two identical choices and one is unselectable-by-
meaning. Detection compares stripped raw Markdown; labels are parsed as inline Markdown.

**Fix:** compare normalised `inlinesText` — which is the same normalisation H3's fix needs, so
the two changes should land together. **Negative control:** the `A` / `**A**` pair expecting
`E-CHOICE-DUPLICATE`.

## L1 — fixtures README describes a fixed defect as current · CONCUR

Confirmed: `content/fixtures/README.md:45` still opens *"Known defect this corpus could not
route around"* and states `--fixtures` exits non-zero, while the filter it recommends is
implemented and the run is 51/51. Rewrite as historical context. Trivial, but a maintainer
chasing a resolved failure is a real cost.

---

## Fix-manifest shape (held for part 2)

One task, or two if part 2 forces an app-side split:

* `Engine.hs`, `Parse.hs`, `Lint.hs`, `Verify.hs`, `Report.hs` — H1 (engine half), H2, H3, H5,
  M2, M3
* `CheckExercises.hs` — H4, plus the self-tests for all of the above
* `check-site.sh` — M1's genuinely independent recount
* `content/fixtures/` — new fixtures for H4, H5, M3 (coverage invariant will demand them)
* `content/fixtures/README.md` — L1
* `site/app/Main.hs` — H1's call sites (**part 2 surface; do not dispatch until part 2 lands**)

Every fix carries a sabotage-proven negative control, each demonstrated red against today's
code before it goes green. Two standing regression guards for the whole task: the shipped
corpus must still report **0 issues**, and `content-check` must stay at **357/357**.

I will fold part 2's findings into this and issue one consolidated manifest.
