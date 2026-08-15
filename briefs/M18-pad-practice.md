# M18 brief — Pad Practice

Date: 2026-08-15 JST

## Outcome

Close the loop the app has been building toward since M16:

> Learn → Prepare → Load → **Play** → Reflect

M18 owns **Play**. A practiced bank — real assignments, loaded onto the real
SXC-1 — gets a guided practice walk that shows the player what is on their
pads, ends in one honest attestation, and counts in Weekly Pulse. Practice
appears in Today's Session only when the day's preparation loop is genuinely
complete; it is the reward state, never a queue-jumper.

## Product rulings

- The practice walk lives in the Sample Lab island as a phase-driven sub-view
  following the Sound Check session pattern. It walks one bank: an intro
  showing the bank's pad grid (slot letter, user bank number, each assigned
  pad's number, name, and color), then optional pad-by-pad steps, then a
  closing receipt. Every state keeps the two-action ceiling.
- Stepping through pads is navigation, not evidence. There is no per-pad
  Confirm; sixteen taps on a phone attest nothing while the player's hands
  are on the sampler. The only evidence decision is at the end of the walk:
  **Mark practiced / Skip for today**. Skip and mid-walk abandonment record
  nothing.
- Eligibility is honest: a bank qualifies for the walk when it has at least
  one assigned pad. The planner suggests practice only for a bank whose
  assigned pads carry Loaded receipts and only when no prepare/place/load
  work is pending. A Loaded receipt is described as "last loaded", never as
  proof of what the device holds now.
- On-demand entry: **Practice this bank** from the bank's view in the Sample
  Lab, via a new `practice=pads` intent. A bank without Loaded receipts opens
  with a reminder to load first, linking the existing handoff flow.
- Today's Session integration is one planner change: the terminal "Load one
  pad" fallback yields to "Practice Bank X" when every assigned pad of some
  bank is Loaded and no earlier-priority Lab work exists. When unloaded
  assignments remain, "Load one pad" stands. At most one Lab step per plan,
  as shipped in M17.
  This eligibility fence is project-global: any unloaded current assignment
  keeps the project on Load, and only then does recurrence choose among banks.
- Bank recurrence is a one-line rule: suggest the eligible bank practiced
  longest ago (oldest `pad-played` day from the ledger; never practiced wins).
  No coverage model, no scheduler, no ease.
- Instruction copy may name sounds on screen ("pad 3 — rain-loop"); ledger
  events never carry names. Setup instructions ("load bank 42 into slot B",
  "switch to slot B") are display-only guidance.
- No WebMIDI. Verification of pad taps is wasm-only machinery by the M4
  single-call-site discipline; `requestMIDIAccess` must not appear outside
  `site/app/Device/Midi.hs`, in any runtime, in this milestone.

## Data boundary

- One new `sxc1.practice-loop.v1` event kind: `pad-played`, one event per
  completed walk, `ref` = slot letter and user bank number (e.g. `"B:42"`),
  `projectId` as today. Schema stays 1; row shape is unchanged; the 200-event
  cap is shared, so per-pad or per-tap events are forbidden.
- The kind whitelist is duplicated literals with no shared constant. One
  commit must change all sites together: the ledger normalizer, the record
  guard, and the stored-plan validator in `index.js`; the Lab's
  `recordPractice` emission; the M17 static-contract assertion block in
  `check-site.sh`; the Weekly Pulse counters and EN/JA strings; and a
  same-commit `sw.js` cache-version bump — a stale cached `index.js`
  permanently erases unknown-kind events on its first ledger write.
- Frozen surfaces stay frozen: no writes to `sxc1.progress`, no SM-2 or
  streak credit, no `.sxc1lab` change, no app.wasm change.
- Budget stance: the walk, intent, and strings land in the Sample Lab island
  (39,956 of 50,000 gz used). Shell-side spend in `index.js` (29,067 of
  32,000 gz — the tightest budget in the repo) is limited to the planner
  branch, whitelist literals, pulse counter, and strings; no new Home or
  coach surfaces there.

## Acceptance

1. A bank with assigned pads opens a practice walk showing slot, bank number,
   and each pad's coordinates, name, and color; every state shows at most two
   decision buttons; EN/JA complete; 320 px clean; works offline.
2. Mark practiced records exactly one `pad-played` event with a coordinate
   ref; Skip and abandonment record nothing; a pre-plan event cannot complete
   the day's planned step.
3. The planner suggests "Practice Bank X" only when the bank's assigned pads
   are all Loaded and no prepare/place/load work is pending; "Load one pad"
   still appears while unloaded assignments exist; Skip-for-today works from
   Today's Session and the Lab header.
4. The suggested bank is the eligible one practiced longest ago, with
   never-practiced banks first.
5. Legacy and hostile ledgers normalize with existing events preserved;
   `pad-played` survives read/write round-trips; the four-site whitelist and
   `sw.js` version change land in one commit.
6. Weekly Pulse unions practiced days and reports a Practiced count beside
   Prepare, Place, and Loaded, in both languages.
7. `practice=pads` deep links switch project, apply once per hash, and
   tolerate a deleted project or bank.
8. All ceilings hold unchanged (island 50,000, index.js 32,000, frozen wasm
   1,000,000 with byte-identical app.wasm); gate pins `M5_CHECK_TOTAL` and
   `M5_BROWSER_ASSERT_FLOOR` are raised with named new checks; the M17
   static-contract assertion is extended; browser regressions cover the walk
   phases, the two-button rule, and planner eligibility at root and nested
   paths.
9. The walk is run once against the physical SXC-1 with a real loaded bank
   and the result recorded in PLAN.md — also closing the M9 physical-device
   acceptance still open there.

## Explicitly out of scope

WebMIDI auto-confirmation of pad taps (wasm-only machinery; MIDI cannot name
the user bank or the sound, and bank C pads 1/2 share note 68 by the manual's
own erratum — a future wasm milestone may charter synthetic decks through the
content-agnostic engine with Device.Midi reused verbatim, gated on ledger
evidence that the manual walk is used). Any second `requestMIDIAccess` call
site. Drill-grammar or corpus changes, synthetic exercises in the wasm
runner, SM-2/streak credit, per-pad evidence, tempo/metronome or in-browser
performance audio, multi-bank sessions, coverage dashboards, activity export,
and `.sxc1lab` schema changes.
