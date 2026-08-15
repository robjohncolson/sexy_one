# M17 brief — One Practice Home

## Outcome

Turn SEXY ONE's course and Sample Lab from two competing home-screen paths into
one daily loop:

> Learn → Prepare → Load → Reflect

Today's Session is the sole primary Home action. When local Sample Lab state has
honest, actionable work, the stable five-step session replaces one course card
with at most one Lab step. Completing that work counts in Weekly Pulse and moves
directly to the next session step.

## Product rulings

- Home has one primary action. Direct Sample Lab, course, manuals, Mastery, and
  Weekly access remain in the existing disclosure.
- A session always has five steps when the course has enough material. It has
  either five course cards or four course cards plus one Lab task—never a Lab
  dashboard or synthetic busywork.
- Lab priority is: resume an unresolved phone handoff; prepare/check a relevant
  Library sound; place an Inbox sound; start loading an assigned project.
- A plan is still a tab/day snapshot. Later Lab changes complete a planned step
  but never reshuffle the other four.
- `Loaded`, successful Sound Check, and Inbox-to-pad placement are the only Lab
  outcomes. The event itself continues the session; no “repeat” or “did you do
  it?” confirmation follows.
- A Lab step always has `Skip for today`, including on the Sample Lab route, for
  times when the learner is away from the files, phone, or SXC-1. Skip advances
  without claiming completion or adding a Weekly outcome.
- Every decision surface keeps the two-action ceiling. Session completion shows
  Weekly and Mastery only; it does not append Reset as a third choice.

## Data boundary

Course marks stay in the validated `sxc1.progress` passport. Cross-Lab outcomes
use `sxc1.practice-loop.v1`:

```json
{"schema":1,"nextSeq":4,"events":[
  {"seq":1,"day":20680,"kind":"sound-ready","projectId":"…","ref":"…"},
  {"seq":2,"day":20680,"kind":"sample-placed","projectId":"…","ref":"…"},
  {"seq":3,"day":20680,"kind":"pad-loaded","projectId":"…","ref":"…"}
]}
```

The ledger is local, independently repairable, and capped at the latest 200
valid events on both read and write. It stores no filename, sound name, source,
rights note, answer, MIDI data, or elapsed time. It is intentionally not added
to the frozen progress codec or `.sxc1lab` schema.

## Acceptance

1. Home exposes exactly one primary wizard choice and keeps Sample Lab in the
   closed secondary disclosure.
2. Real workspace/library/handoff fixtures yield exactly one correctly routed
   Lab step and four course steps in a stable five-step plan.
3. Hostile/oversized activity data normalizes to schema 1 and 200 events; event
   rows retain only the five documented fields.
4. A matching real outcome completes the Lab step after its plan baseline and
   automatically continues. A pre-plan event cannot complete it.
5. The Sample Lab task route opens the relevant Sound Check, placement, or
   handoff state and offers a working away-from-device Skip.
6. Weekly Pulse unions course and Lab active days and visibly reports Prepare,
   Place, and Loaded outcomes without canvas or analytics.
7. EN/JA copy, 320 px overflow, offline boot, root/nested hosting, existing
   Sample Lab migrations, and all prior course flows remain green.
8. The deferred Sample Lab architecture and existing JS-island gzip ceiling
   remain intact; no graphics/runtime dependency or eager audio scan is added.

## Explicitly out of scope

Generated pad-specific drills, WebMIDI proof of playing an assigned sample,
streak/scheduler credit for Lab outcomes, activity transfer between browsers,
cloud sync, accounts, analytics, `.sxc1lab` schema changes, and M18 Pad Practice.
