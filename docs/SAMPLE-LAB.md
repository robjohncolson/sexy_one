# Sample Lab contract

Sample Lab is the second half of SEXY ONE: a local-first workspace for preparing
audio on a computer, arranging it as an SXC-1 pad bank, carrying that plan to a
phone, and then assigning the files with CASIO's official Sampler App.

It deliberately does **not** imitate or reverse-engineer CASIO's private device
transfer. The official app remains the final authority for writing a sound to the
hardware.

## Workflow

1. Export a trimmed sample from Audacity. WAV at 48 kHz, 16-bit PCM is the safest
   match for the SXC-1's own recording format. The planner accepts the official
   app's documented file choices: WAV, MP3, FLAC, and `.cswp`.
2. Open `#/samples` and add an Audacity batch to Sample Library. Search or
   audition a sound, send it to the active project's Inbox, then tap or drag it
   onto the 4×4 pad mockup; `Fill empty pads` places the Inbox in order without
   overwriting anything. Bank numbers are limited to the SXC-1 user-bank range,
   15-80. Direct pad and Inbox imports also join the Library automatically.
3. Add the human context the file cannot carry: pad name, where it came from,
   tags, colour, one-shot/loop intent, BPM, and mute group.
4. Save/share one `.sxc1lab` project file. Import that file on the phone; all
   audio and pad notes travel together without an account or server.
5. Enter Phone handoff. SEXY ONE presents one filled pad at a time with its exact
   bank/pad destination and lets the phone share or download the corresponding
   audio file. In CASIO Sampler App use Assign Sound -> Select from file, then
   continue to the next pad.

## Local-data boundary

- Project metadata is stored in `localStorage`.
- Audio blobs are stored in IndexedDB because they are too large for
  `localStorage`.
- Audio is never fetched from, or uploaded to, a SEXY ONE server. The shipped
  site remains static and works offline after the normal app shell is cached.
- If browser storage is unavailable, the current tab still works in a clearly
  labelled temporary mode. Export the project before closing it.
- Source notes are descriptive only. Users must only import audio they have
  permission to use; Sample Lab does not download or extract audio from video
  services or games.

## Portable project format

`.sxc1lab` is a small binary container designed to avoid base64 expansion:

```text
bytes 0..7    ASCII "SXC1LAB1"
bytes 8..11   unsigned little-endian JSON manifest length
next N bytes  UTF-8 JSON manifest
remainder     concatenated audio blobs
```

The manifest declares `schema: 1`, the normalized project, and a file table.
Each file table row has a blob id, original file name, MIME type, byte offset
relative to the start of the blob payload, and byte length. Import rejects an
unknown magic value, unsupported schema, oversized manifest, invalid range, or
pad reference to a missing blob before replacing the current project.

The format is a transfer envelope, not an audio conversion format. Original file
bytes are retained exactly.

## Interaction contract

- Home still presents exactly two primary directions: learn the SXC-1 or build a
  sample bank. Course/manual/progress tools remain in a quieter disclosure.
- The 16 pads and A-D bank selectors are the instrument being modelled, not a
  wall of unrelated calls to action.
- A selected filled pad has two immediate organization decisions: Move / swap
  and Return to Inbox. The Inbox likewise replaces its two actions when a sound
  is selected; project import is progressively disclosed.
- Phone handoff first presents a readiness review. Missing assigned audio is a
  blocker; destination, Inbox, naming, and recommended-WAV findings remain
  explicit decisions rather than silently changing the project.
- Metadata edits auto-save. Pressing an assigned pad previews it; changing a
  field never creates another confirmation button.
- Phone handoff replaces the planner and advances one pad at a time. It does not
  append a second workflow below the first.

## Delivery architecture

`sample-lab.js` is dynamically imported only after the Haskell trainer becomes
interactive. Only the compact native Home link lives in `app.wasm`; the planner
engine does not join the critical module graph used by the first useful lesson
render. The Sample Lab route is a static, semantic DOM surface whose state and
audio stay in browser APIs; leaving `#/samples` restores the existing Miso app
unchanged.

The bulk-organizing and validation extension is specified in
[`SAMPLE-INBOX.md`](SAMPLE-INBOX.md); the shared catalog, deduplication, and
named-project layer is specified in [`SAMPLE-LIBRARY.md`](SAMPLE-LIBRARY.md).
