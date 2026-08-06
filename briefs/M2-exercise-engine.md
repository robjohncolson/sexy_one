# M2 Brief — Exercise engine

**From:** Fable (planning tier) · **To:** Opus 5 design agent · **Status:** written
2026-08-06; dispatches to Opus once the M1 design (`briefs/M1-plan.md`) exists,
because the engine builds on M1's content model and app structure. M2
*implementation* additionally waits for the M1 gate to close.

## Goal

A generic exercise engine in Haskell inside the Miso app, three exercise types,
a stable authorable content format with a mechanical validator, and a seed
exercise set proving the format end-to-end. This milestone turns the site from
a reader into a trainer.

Read `PLAN.md`, `briefs/M0-plan.md` (toolchain — fixed), and `briefs/M1-plan.md`
(content model, routing, build pipeline — build on it, don't re-architect it).

## Exercise types (all three, designed as one engine with pluggable types)

1. **Quiz / flashcard** — multiple choice and prompted-recall cards: panel and
   button identification, menu paths, signal flow, spec facts, MIDI CC facts.
2. **Guided device drill** — multi-step "do this on your SXC-1 now" missions
   mirroring the guide book's procedures (record a sample, trim it, assign it,
   sequence a pattern), each step with instruction text, manual-page citation,
   and a self-check the learner confirms manually ("the pad LED blinks red").
3. **Reference lookup** — timed find-the-answer tasks that train navigating the
   manuals ("which page covers Beat Sync? go find the APO setting").

## Contract requirements (Opus latitude applies to everything else)

1. **Content format**: exercises live in data files with a documented schema —
   never hardcoded in Haskell UI code. Every exercise cites at least one manual
   page via the `<!-- page N -->` identity from M1's content model, and rendered
   exercises link to that page in the reader.
2. **Validator**: a runnable content validator (usable locally and in CI) that
   rejects malformed exercises, dangling page citations, and glossary-violating
   terminology in UI-facing labels. It must be falsifiable — the manifest needs
   negative controls sabotaging real content and expecting rejection. M0's
   lesson stands: a check that cannot fail is what let the vacuous passes through.
3. **Seed content, not bulk content**: the Sonnet swarm hand-authors a small seed
   set (roughly 10–20 exercises spanning all three types) drawn from
   `translations/guide-book.md` Part: Preparation and Part: Pad play, proving
   the format is authorable. Bulk authoring of the full two-chapter banks is
   NOT a swarm task — Fable runs dedicated content workflows against the schema
   afterward. Design the format documentation so a content agent that has never
   seen the engine source can author valid exercises from it.
4. **Forward hooks, no forward implementation**: completion/answer events go
   through one interface that M3 will later bind to localStorage progress and
   spaced repetition — M2 itself persists nothing. Drill steps carry an optional
   verification hook field that M4 will later bind to WebMIDI CC listening —
   M2 renders these as manual self-checks. Neither M3 nor M4 behavior gets
   implemented now; the shapes just must not require redesign later.
5. **Harness**: extend `check-site.sh` / `browser-check.mjs` with M2 assertions
   (an exercise renders, an answer path works, the validator gate runs in CI),
   with negative controls, keeping everything green.
6. Glossary chapter titles and terminology are binding in all learner-facing text.

## Manifest rules (unchanged from M1's brief, both lessons encoded)

Same JSON schema as `briefs/M0-manifest.json`. Disjoint `owned_paths`;
self-contained prompts; runnable verify commands with negative controls proven
against sabotage; and the dependency-closure rule — every file a task's
verify_commands or prompt reads must be in its own owned_paths, its
`depends_on` closure, or already committed.

## Deliverables

1. `briefs/M2-plan.md` — engine architecture, content format spec draft,
   validator strategy, how the three types share one engine.
2. `briefs/M2-manifest.json` — Sonnet swarm manifest.

Design only: probe read-only (throwaway compile probes in the scratchpad are
fine), research freely, write nothing in the repo outside `briefs/`.

## Sign-off protocol

Unchanged: you review the swarm's work against your acceptance checks, then
Codex (`gpt-5.6-sol`, xhigh) runs the adversarial pass; findings route back
through you. Expect Codex to press hardest on validator falsifiability and the
M3/M4 interface shapes.
