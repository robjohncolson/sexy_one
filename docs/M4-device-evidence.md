# M4 physical-device evidence (in progress)

Owner-run protocol session, 2026-08-07, local serve of the M4 build
(unoptimized copy, functionally identical), desktop Chrome, Linux.

## First contact (protocol §2) — PASS

- **Port name as presented over USB: `SXC-1 MIDI 1`** — the single fact
  no one in this project had. It case-foldedly contains "sxc-1", so
  `selectPorts`' FIRST tier matches; the casio/all fallback chain was
  never needed on this hardware.
- Enable flow: permission prompt appeared on click, granted;
  "Bound MIDI input: SXC-1 MIDI 1" rendered.

## Drill d-2-01 (protocol §3) — PASS

- Step 1 (press A): auto-confirmed — "Confirmed by the device:
  CC 80 = 127." on the real device.
- Remaining steps hand-confirmed (no hooks — by design); exercise
  completed; Restart offered.
- Owner also reports the display "bank A:1" on the unit, consistent
  with the drill's goal state.

## Drill d-2-02 (protocol §4) — PASS

- Pad 1 bank A and pad 13 bank A both auto-confirmed on the real
  device; state dump: confirms = d-2-02#1 device, d-2-02#2 device,
  d-2-02#3 learner (the hookless step, by design).
- **Decoy-port validation**: allPorts = ["Midi Through Port-0",
  "SXC-1 MIDI 1"] (ALSA's through port present); bound ports =
  ["SXC-1 MIDI 1"] only — selectPorts' name tier discriminated
  correctly against a real decoy.

## Byte capture (protocol §5) — PARTIAL (note-off captured)

- lastMessage after a tap-and-release: **[128,36,64]** — a 0x80
  Note OFF, channel 1, note 36, release velocity 64 (the MIDI
  "no velocity information" convention value). Confirms the device
  transmits note-offs and that never-match-0x80 was the right rule.
- Note-ON velocity captured while holding pad 13: **[144,48,64]** —
  the SXC-1 transmits a FIXED velocity of 64 on note-on (and 64 on
  release). The manual's "velocity x / unsupported" claim is confirmed
  in both directions, and the velocity-agnostic matchSpec decision is
  validated as load-bearing: a 127-required design would have made
  every pad hook dead on the real device.

## Drill d-2-09 (protocol §6) — DEVICE LAYER PASS; TWO MANUAL ERRATA FOUND

- Step 1 (verify: cc 16 0,127; predicted UNREACHABLE per M4-F1):
  **AUTO-CONFIRMED** after turning the FX1 dial up then fully back
  down — the dial's range endpoint emits value 0. M4-F1's
  "no realistic dial value" claim is WRONG at the extremes; the hook
  is reachable by a full sweep. M5 item 10 revised accordingly.
- Step 2 (verify: cc 108 127, FX1 button): did NOT auto-confirm on
  first press, DID auto-confirm on the second — TOGGLE THEORY
  CONFIRMED: the FX buttons transmit 127/0 as ON/OFF edges, and step
  1's dial motion had left FX1 on. Final state dump shows all three
  d-2-09 confirms with source "device".
- Step 3 (verify: cc 109 127, FX2 button): auto-confirmed on the
  FIRST press ("as soon as I turned on the fx2 button"), i.e. the ON
  edge of an off-state toggle transmitted 127 — supporting the toggle
  theory.
- The trainer matched exactly what the hooks specify in every case —
  these are content/manual-calibration findings (M5), not device-layer
  defects.

- Additional note-off capture: [128,48,64] (pad 13 release) — release
  velocity again exactly 64, consistent with fixed no-velocity
  convention values.

## Pending

- Note-on velocity byte (optional — design already validated as
  velocity-agnostic either way), channel-mismatch check (§7), final
  PASS/FAIL block (§9).
