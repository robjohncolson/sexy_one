# Pad Practice

M18 closes the Sample Lab loop with a bank-sized Play step:

> Learn → Prepare → Load → **Play** → Reflect

The walk lives entirely in the deferred Sample Lab island. It is an aid for
practicing a real SXC-1 bank, not a simulator and not a claim that the browser
can inspect the device.

## Walk contract

`practice=pads` opens one bank by project, slot, and user-bank number. The
intro shows that coordinate plus every assigned pad's number, name, and color.
The learner may walk the pads one at a time or go directly to the closing
decision. Pad steps are navigation only: they never create evidence and do not
ask for a per-pad confirmation.

The closing decision is `Mark practiced` / `Skip for today`. Mark writes one
event for the entire run. Skip, using the Lab header, returning to the planner,
changing route, or otherwise abandoning a walk writes nothing. The recorded
state guards against double activation. Each walk state renders no more than
two local action buttons and remains usable at 320 CSS pixels.

## Honest Loaded boundary

Any bank with at least one assigned pad can be opened on demand from its bank
view. Its current assignments qualify only when each has an exact matching
`loaded` handoff entry for project, slot, bank, pad, and blob. The UI calls
this **last loaded**: it is a saved receipt from the phone handoff, never proof
of what the SXC-1 currently holds. A bank without those receipts shows a
reminder and an entry into the existing handoff flow.

Today's Session suggests Pad Practice only after higher-priority prepare,
place, and load work is absent and all current assignments are Loaded. If any
assignment is not Loaded, the terminal fallback remains `Load one pad`.
Among eligible banks the planner chooses the least recently practiced bank;
never-practiced banks sort first. The plan stays metadata-only and contains at
most one Lab step, preserving the M17 contract.

## Activity and privacy

The bounded `sxc1.practice-loop.v1` ledger gains one kind:

- `pad-played`, with `projectId` and a coordinate `ref` such as `B:42`.

There is exactly one event per marked bank run. Its row retains the existing
`{seq, day, kind, projectId, ref}` schema and shared 200-row cap. Events contain
no sound or file names, per-pad taps, answers, notes, provenance, timing, or
MIDI. A plan captures the current sequence baseline, so a pre-plan event
cannot complete a newly planned step.

Weekly Pulse treats the event day as activity and adds `Practiced` / `練習済み`
to the existing Prepare, Place, and Loaded breakdown. Pad Practice does not
write course progress, SM-2 scheduling, streak credit, audio, or `.sxc1lab`
data.

## Runtime and compatibility boundary

The route tolerates a deleted project, changed bank number, or removed
assignments by showing an unavailable state and recording nothing. It applies
once per hash at both root and nested mounts, works from the offline core cache,
and adds no network or background work.

`app.wasm` remains byte-identical. Pad Practice adds no WebMIDI code:
`requestMIDIAccess` remains confined to `site/app/Device/Midi.hs`. Physical pad
verification, tempo tools, per-pad evidence, multi-bank sessions, and scheduler
changes remain outside M18.
