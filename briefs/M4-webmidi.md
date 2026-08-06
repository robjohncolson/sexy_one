# M4 Brief — WebMIDI live-device verification

**From:** Fable (planning tier) · **To:** Opus 5 design agent · **Status:** design
dispatched 2026-08-07 in parallel with M3's design; M4 *implementation* waits
for the M3 gate (M3's size-reduction outcome sets M4's code budget, and both
touch `site/app/Main.hs`).

## Goal

Drills verify themselves against the real SXC-1 over USB-MIDI: when the learner
performs the instructed action on the device, the step confirms automatically.
Everything M2 shipped keeps working unchanged everywhere WebMIDI is absent.

Read `PLAN.md`, `briefs/M2-plan.md` + `M2-plan-amendments.md` (the shapes you
are implementing were fixed there), and `translations/midi.md` (the SXC-1's
actual MIDI implementation — source of truth, including its recorded errata).

## The contract you inherit (implement, don't redesign)

- `VerifySpec` (`cc` / `note` / `pad…bank` / `any`) is parsed and validated in
  M2 (`SXC1.Exercise.Verify` against tables derived from `translations/midi.md`);
  the seed corpus carries 6 live `verify:` hooks today.
- `Main.hs` wires `noDeviceVerifier :: DeviceVerifier` (`dvAvailable`,
  `dvWatch spec onConfirm → IO (IO ())`); the engine already accepts
  `ConfirmStep i ByDevice`. M4 swaps ONE value. No content, engine, or
  validator changes.
- Manual confirmation REMAINS the default and must stay first-class: WebMIDI is
  progressive enhancement, Chromium-only, and the UI must degrade to exactly
  M2's behavior with no visual noise on unsupported browsers.

## Hard constraints

1. **FFI route**: M1's measured finding stands — raw `foreign import javascript`
   does not link on this toolchain. All Web MIDI access goes through Miso's JS
   DSL (`jsg`/`(!)`/`setProp`…) like `currentHash`/`Date.getTime` do. Verify
   feasibility with a compile probe BEFORE writing the manifest: the MIDI API
   is callback/promise-heavy (`requestMIDIAccess`, `onmidimessage`) — prove the
   DSL can subscribe to `onmidimessage` and read `data` bytes, or design the
   one minimal shim `index.js` may carry (index.js is static, CSP-clean, and
   already ours; a tiny bridge there may beat contorting the DSL — your call,
   with the probe result recorded either way).
2. **Permission UX**: `requestMIDIAccess` only ever fires from an explicit
   learner action (an "Enable device verification" control), never at boot; no
   sysex. State it clearly when the device is/isn't detected (the SXC-1
   identifies over USB-MIDI; match liberally on port name, and behave sanely
   with zero or multiple MIDI devices).
3. **Privacy**: MIDI data never leaves the browser; no logging beyond the
   existing in-memory event log.
4. **Size**: M4's budget is whatever headroom the M3 size task creates, minus
   a reserve you negotiate in your plan against the frozen 1,000,000 ceiling.
   Wait for M3's measured result before finalizing the manifest's budget line.
5. **Testability without a device**: CI has no SXC-1. The harness needs an
   injectable fake — browser-check pre-loads a script that replaces
   `navigator.requestMIDIAccess` with a synthetic source the assertions can
   drive (emit the CC/note bytes from `translations/midi.md`'s tables, wrong
   channel/wrong CC negative cases included). Every new check sabotage-proven
   per house rules.
6. **Real-device protocol**: the owner has the physical SXC-1. Deliver
   `docs/M4-device-test-protocol.md` — a short human checklist (plug in, enable,
   perform drill d-2-01 step by step, expected auto-confirms, troubleshooting) —
   for the one verification only they can run. Their pass/fail report is part
   of the M4 gate evidence.

## Manifest rules

House rules unchanged (disjoint ownership, dependency closure, negative
controls red-first). Mind the two M2-inherited LOWs if your tasks touch those
surfaces (StaticCode totality sweep; EXERCISE_FIXTURE_FIELDS declared-target
validation).

## Deliverables

`briefs/M4-plan.md` (with the FFI probe results) + `briefs/M4-manifest.json`.
Design only; probes in the scratchpad; write nothing else in the repo.
