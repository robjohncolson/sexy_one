# Sound Check

Sound Check is the preparation step between the local Sample Library and the M15
phone handoff. It never edits audio. It reads one file only after **Check readiness**
and tells the owner exactly what to do in Audacity.

## Verdicts

The required SXC-1 target comes from the Guide Book product specification on page
66: stereo WAV, 48 kHz, 16-bit linear PCM, up to 15 minutes (approximately 173 MB).
CASIO Sampler App also accepts WAV, MP3, FLAC, and `.cswp` for file assignment, so
non-native files remain supported project data; they simply do not receive the
native-ready verdict.

Clipping and leading/trailing silence are advisory. They never block a handoff and
never change audio. For WAV PCM data up to 48 MB, a deferred worker scans the WAV's
own samples. Larger WAVs receive authoritative header checks and a clearly labeled
header-only result. Other formats are directed to Audacity without invented sample
rate, bit-depth, or PCM findings.

## Audacity round trip

The recipe is derived only from failed or advisory criteria. Its menu names and
export choices were verified against Audacity 3.7.8 on 2026-08-15 JST. Use
**File → Export Audio** and choose WAV, Stereo, a 48,000 Hz output sample rate,
and Signed 16-bit PCM encoding. Edge trimming uses **Edit → Remove Special → Trim Audio**.
Clipping guidance recommends inspecting **View → Show Clipping** and preserving the
original because normalization cannot recreate clipped detail.

After an edited export is imported, the Library records one backward `replacesId`
link and copies the original's name, source, tags, rights, notes, BPM, colour,
playback intent, and mute group. Nothing moves until the owner chooses:

- **Use this version** repoints every pad and Inbox placement using the original
  blob across all local projects.
- **Keep current** changes no placements; both Library files remain available.

The `.sxc1lab` format stays at schema 1. Because M15 handoff rows include `blobId`,
using an edited version makes only changed pads pending while Loaded receipts for
unchanged pads survive.

## Storage keys

- Library metadata: `sxc1.sample-library.v1`
- Projects and placements: `sxc1.sample-workspace.v1`
- Independent handoff receipts: `sxc1.sample-handoffs.v1`
- Audio bytes: IndexedDB database `sxc1-sample-lab`, store `audio`

All analysis and persistence remain local and offline-capable.
