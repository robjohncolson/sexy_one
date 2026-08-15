# One Practice Home

M17 makes `#/x/today` the single front door for both learning the SXC-1 and
preparing sounds for it. Home no longer asks the learner to choose between a
green course path and a red Sample Lab path. It offers one daily sequence;
direct browsing remains available in the closed tools/library disclosure.

## Session projection

Today's Session still snapshots one tab-scoped, day-scoped plan. It selects its
course work with the existing due → continue → new → maintenance rules, then
looks only at compact Sample Lab metadata—never audio bytes or the readiness
worker. If actionable work exists, it reserves one of five positions for the
highest-priority Lab task:

1. load the next pending/shared handoff pad;
2. prepare a sound with a failed check, or check an unchecked sound;
3. place one active-project Inbox sound;
4. begin handoff for an assigned project.

At most one Lab step appears. The stored plan records the activity ledger's
sequence baseline, project, optional asset/row reference, and accepted outcome
kind. Old activity therefore cannot complete a newly planned task. Course
completion still reconciles from `masteryDone`; Lab completion reconciles from
the activity ledger. Neither source reshuffles the snapshot.

## Continuity and Skip

Practice links carry a local hash intent such as
`#/samples?practice=check&asset=…`. The deferred Sample Lab consumes that intent
and opens the relevant sound, Inbox selection, or handoff. A successful Sound
Check decision, Inbox placement, or `Loaded` handoff outcome marks the task and
routes to the next unhandled session item after a short result paint. It never
asks whether to repeat.

The intent header exposes `Skip for today`. Today also replaces its normal
Reset action with Skip whenever the next item is a Lab step. Skip is tab-local:
it advances the plan, records no successful outcome, and does not affect Weekly
Pulse or future scheduling.

At every Today state there are at most two actions:

- course next: Start/Resume + Build a new plan;
- Lab next: Open Sample Lab + Skip for today;
- complete: Weekly Pulse + Mastery journey.

## Activity ledger

`sxc1.practice-loop.v1` is a small independent JSON envelope:

- `schema: 1`;
- monotonic `nextSeq`;
- at most 200 `{seq, day, kind, projectId, ref}` events;
- kinds: `sound-ready`, `sample-placed`, `pad-loaded`.

Normalization rejects unknown kinds and malformed rows, clips identifiers, sorts
by sequence, and reapplies the cap. The current page keeps an in-memory fallback
when `localStorage` is unavailable. Events contain no filenames, sample names,
provenance, notes, answers, timing, MIDI, or audio.

This ledger does not travel in the progress passport or `.sxc1lab` file. That
keeps both established formats backward-compatible and makes the privacy text
truthful: course history can move with the passport; Lab outcomes stay in the
browser where they occurred.

## Weekly Pulse

Weekly Pulse unions Lab event days with course-history days for the seven-day
active-day rhythm. It reports one visible `Lab outcomes` stat plus a compact
`Prepare · Place · Loaded` breakdown. Answer and steady-answer calculations,
the exact review forecast, strengths, friction, and scheduler focus retain their
existing semantics. The entire route remains semantic DOM with no canvas,
network write, or background analysis.

## Performance and regression boundary

The metadata projection lives in the already-loaded shell. `sample-lab.js`
remains a post-interactivity dynamic import, and `sample-check-worker.js` remains
on-demand. Planning reads bounded JSON metadata only; it does not open IndexedDB,
decode audio, start a worker, or add to `app.wasm`'s course model.

The browser gate proves the single Home action, five-step/one-Lab cap, stable
plan, direct intent, Skip, automatic event completion, private 200-event ledger,
Weekly day union and outcome counts, EN/JA rendering, offline cache version,
mobile overflow, and all pre-M17 Sample Lab/course behavior.
