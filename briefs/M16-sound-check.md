# M16 brief — Sound Check

Date: 2026-08-15

## Product outcome

Join the trainer and Sample Lab at the moment a real sound becomes usable:

> Learn → Prepare → Load → Play → Reflect

M16 owns **Prepare**. It adds an honest local readiness verdict, a finding-specific
Audacity recipe, and one recoverable edited-version decision. The full unified home,
lab cards in Today's Session, and Pad Practice remain M17/M18 work.

## User flow

1. Select a Library sound, open its details, and choose **Check readiness**.
2. A deferred worker reads the original WAV header. For WAV data no larger than
   48 MB it also scans the file's own PCM bytes for full-scale clipping and edge
   silence; `decodeAudioData` is never evidence for a verdict.
3. The result lists format, sample rate, bit depth, channels, duration, size,
   clipping, and edge silence separately. Required checks target the documented
   SXC-1 format: stereo PCM WAV, 48 kHz, 16-bit, no more than 15 minutes and about
   173 MB. Clipping and silence are advisory.
4. Failed or advisory checks produce only their relevant Audacity operations.
   **Learn why** opens the bilingual `lvl-16` specification deck.
5. **Copy Audacity recipe** is replaced by **Import edited version**. The edited
   export is checked through the same worker and linked with one `replacesId`.
6. **Use this version / Keep current** is the only replacement decision. Use
   atomically repoints every matching pad and Inbox placement across projects;
   Keep changes no placements. The original stays in the Library.
7. Existing M15 handoff identity re-queues only changed pads and preserves receipts
   for unchanged pads. The portable project schema remains version 1.

## Persistence

- `sxc1.sample-library.v1` remains an additive schema-1 record. A Library item may
  carry `replacesId` and a bounded readiness summary (`checkedAt`, `ready`,
  `advisory`, and finding codes).
- Original and edited audio bytes remain separate IndexedDB blobs.
- An original with a newer linked version cannot be removed until the newer item
  is removed, keeping the backward link recoverable.
- Sound Check does not add a server, account, analytics, or network write path.

## Interaction and performance rules

- Analysis begins only after an explicit check and runs outside the UI thread.
- The worker is absent from the first-load module graph and works from the offline
  application cache.
- Each Sound Check state presents no more than two decision buttons. Copy is
  replaced by import; import is replaced by Use/Keep.
- Non-WAV, malformed WAV, unsupported PCM, missing bytes, and files above the scan
  limit degrade to explicit unknown/header-only results. No result is inferred from
  decoded or resampled browser audio.
- The deferred Sample Lab JavaScript island has a committed gzip ceiling.

## Explicit cuts

- No automatic audio conversion or in-browser waveform editor.
- No readiness score, dashboard, batch scan, waveform diff, or approval state
  machine.
- No MP3/FLAC bit-depth claims.
- No `.sxc1lab` schema change.
- No full Today's Session or Weekly Pulse integration; M17 owns that connection.

## Completion gate

- EN/JA readiness, recipe, replacement, and spec-deck content.
- Browser regression for exact PCM findings, sequential two-button flow,
  metadata/revision persistence, all-project repointing, selective handoff re-queue,
  reload, 320 px layout, offline worker availability, and unchanged schema 1.
- Worker and deferred JavaScript budgets enforced by `check-site.sh`.
- `app.wasm` remains below its frozen ceiling and the complete root/nested browser
  suites pass against the optimized shipping artifact.
