# M3 Brief — Full course content, progress, spaced repetition

**From:** Fable (planning tier) · **To:** Opus 5 design agent · **Status:** drafted
2026-08-06; dispatches after M2 implementation is underway (design against
`briefs/M2-plan.md` §M3-interface as authoritative; adjust only if the M2 gate
rounds amend those shapes).

## Goal

Turn the exercise engine into a training *program*: the full six-chapter course
authored from the inventory, plus persistent progress and spaced repetition so
the site remembers the learner and resurfaces weak material.

Read `PLAN.md`, `briefs/M2-plan.md` (especially the ProgressEvent / ProgressSink
/ PromptId contract — M2 ships an in-memory sink; M3 binds it), and
`content/exercise-inventory.md` (440 candidate ids, page-cited, with the drill
dependency graph).

## Size mandate (from the M2 designer's budget ruling, 2026-08-07)

M2 shipped at 988,367 B gzip against the 1,000,000 ceiling — 11,633 B of
headroom (final gate-cleared artifact; per-build variance ~±1.5 KB, so plan
for ~10 KB usable), deliberately not raised at the M2 gate. Codex's gate-3
condition: M2 is FROZEN (no further feature growth) and M3 must reduce
before any feature work. Two further LOWs inherited by M3: a new
StaticCode constructor with a forgotten pattern synonym/codeText arm is
not caught mechanically (add a self-test totality sweep over
allIssueCodes), and EXERCISE_FIXTURE_FIELDS validation in browser-check
does not yet require the declared-target fields (citeSlug/citePage/
targetSlug). **M3's first implementation task is
size reduction, before any feature work**: split `parseDeck` (pure structural
reader) from `validateDeck` (lint + citations + inventory binding) so
`exe:app` links only the reader — the validating parser's measured browser
cost is 95,358 B gzip and linting is a CI concern. Second lever if needed:
compile-time lifting of a pre-parsed compact exercise model (~16 KB corpus,
unlike the manuals' 191 KB, so the M1-era rejection doesn't apply). Order of
operations: reduce first, measure, and only then raise the ceiling
deliberately at a gate with Codex's eyes on it.

## Two workstreams, one milestone

### A. Bulk content (Fable-tier authoring, NOT the Sonnet swarm)

The swarm builds no content in M3. I run content workflows that author
`.ex.md` decks from the inventory against `content/EXERCISE-FORMAT.md`, chapter
by chapter, validated by `exercise-check` in CI. Your manifest's job is only to
make room for that content: chapter/deck navigation that scales to the full
course, INDEX conventions, and any per-deck metadata the course map needs
(difficulty tier, prerequisite deck ids from the drill graph).

Design input you must produce: a **deck plan** — how the 440 inventory ids
partition into decks (per chapter? per topic within chapter? separate
intro/core/stretch tiers?), with target deck sizes for a phone session
(~5–10 min). This becomes the work order for my authoring workflows.

### B. Progress + spaced repetition (Opus → Sonnet swarm)

1. **Persistence**: bind ProgressSink to localStorage. Schema versioned from
   day one (a `schemaVersion` key and a documented migration story — losing a
   learner's history on upgrade is a bug class, treat it as such). The
   `Miso.Storage` grep-ban from M2 lifts for exactly the sink module and
   nothing else.
2. **Spaced repetition**: pick and justify a scheduler (SM-2-family or FSRS-lite
   are the obvious candidates — your call, but it must be a pure function of
   the event history so it is unit-testable and replayable). Review queue
   surfaces due items across all decks.
3. **Progress UI**: per-deck and per-chapter completion, streaks, a "continue
   where you left off" entry point, and a review-queue badge. Respect the
   existing style system.
4. **Privacy**: everything stays in the browser. No network writes, no
   analytics. State export/import (a JSON blob the user copies) is in scope —
   it is the only way to move progress between devices without a backend.

## Contract requirements

1. Determinism: scheduler decisions derive from (event history, current time
   passed as argument) — never from wall-clock reads inside pure code. M2's
   clock-as-argument discipline extends to M3.
2. A learner with existing M2-era in-memory events loses nothing they could
   have kept: first-run migration from empty is trivially fine, but the sink
   interface must not change in ways that would orphan M2 content ids.
3. PromptId stability: content re-authoring must not silently orphan progress —
   the validator gains a check that deck edits preserve exercise ids present in
   a committed id-registry (tombstone process for genuine removals, mirroring
   the inventory's never-renumber rule).
4. Harness: browser-check gains persistence assertions (answer → reload →
   state survives; export → wipe → import → state survives), with negative
   controls, all green alongside every earlier gate's checks.

## Manifest rules

Unchanged house rules: same schema, disjoint owned_paths, self-contained
prompts, dependency-closure, sabotage-proven negative controls (the
storage-migration and id-stability checks especially must be falsifiable).

## Deliverables

1. `briefs/M3-plan.md` — including the deck plan (workstream A's work order).
2. `briefs/M3-manifest.json` — workstream B tasks only.

Design only; write nothing outside `briefs/`.

## Sign-off protocol

Unchanged: swarm → your sign-off → Codex (`gpt-5.6-sol`, xhigh) adversarial
gate. Expect Codex to press on storage schema versioning, scheduler
determinism, and whether the id-stability check can pass vacuously.
