# M14 Sample Library contract

Sample Library is the reusable catalog above Sample Inbox and the SXC-1 pad
planner. It keeps the fast, static, local-only architecture: Audacity remains
the audio editor, SEXY ONE organizes the resulting files, and CASIO Sampler App
still performs the final hardware assignment.

## Workflow

1. Add up to 64 WAV, MP3, FLAC, or `.cswp` files in one batch. Each accepted
   sound is retained once in IndexedDB and receives a local catalog record.
2. Search across name, original filename, source, tags, notes, permission/credit,
   stage, BPM, duration, and format. The stage filter separates Raw, Edited, and
   Ready sounds without replacing free-text search.
3. Select a sound to audition it. The one `Add to library` action is replaced by
   `Add to Inbox` / `Edit details`; editing replaces those with `Done` / `Remove
   from Library`.
4. Record provenance, edit notes, permission or credit, BPM, and production
   stage. Metadata auto-saves locally. Audio shaping stays in Audacity.
5. Create or switch named projects, then add the same catalog sound to any
   project's Inbox. Project Inbox and pad records reference the shared audio;
   they do not copy its bytes.
6. Arrange the active project's banks exactly as in M13, save its portable
   `.sxc1lab` file, move that file to the phone, and use the existing one-pad-at-
   a-time CASIO handoff.

## Interaction rules

- Action rows expose at most two current decisions. A choice replaces the prior
  pair instead of appending a new control row.
- Sound cards, pad controls, project fields, search, and filters are collection
  or form controls rather than calls to action. Every operation has a touch and
  keyboard path; horizontal trays are contained scroll regions on small phones.
- `Escape` cancels pending placement or backs out of library editing, library
  selection, and new-project creation.
- Project deletion is explicit and confirmed. It never deletes the shared
  library. Removing a catalog record is also confirmed and never breaks an
  existing project's Inbox or pad assignment.

## Storage, identity, and deduplication

- `sxc1.sample-workspace.v1` stores up to 32 normalized projects and the active
  project id. `sxc1.sample-library.v1` stores up to 2,048 catalog records.
- Audio remains in the existing `sxc1-sample-lab` IndexedDB store. New imports
  receive a SHA-256 content fingerprint when Web Crypto is available, with a
  deterministic FNV-1a fallback for older local WebViews. Reuse requires both
  fingerprint and byte size.
- M12/M13 records did not carry fingerprints. They are not all hashed during
  startup. On a later import, only same-size legacy candidates are fingerprinted
  until an identical file is found. This keeps migration and mobile startup
  light while preventing duplicate audio storage.
- Every import entry point uses one shared single-flight queue, so simultaneous
  Library, Inbox, pad, and portable-project imports cannot pass the duplicate
  check before either has committed its catalog record.
- A blob is deleted only when neither the library nor any project's Inbox or
  assigned pad references it. Library removal and project deletion therefore
  preserve every still-referenced sound.
- The previous `sxc1.sample-lab.v1` key remains a mirror of the active project.
  If the workspace/library keys do not exist, M14 migrates that M13 project and
  seeds one catalog item per unique referenced blob automatically.
- The three localStorage records are parsed independently. A malformed Library
  record can be repaired from project references without replacing a valid
  multi-project workspace; a malformed workspace can still fall back to the
  legacy active-project mirror. An Inbox is capped consistently at 256 items
  both when adding and when normalizing, so reload never silently truncates it.

## Portability boundary

The `SXC1LAB1` container and manifest schema remain version 1. A `.sxc1lab`
continues to represent one project, including its assigned pads, Inbox, and each
referenced audio blob exactly once. The global library and other projects stay on
the source device; importing the file on another device adds or replaces that
project and seeds its sounds into the destination device's library.

This boundary is deliberate: project transfer remains understandable and
bounded, while a potentially large working library is never uploaded or silently
bundled into every phone handoff.

## Permanent regressions

The real-browser workflow removes only the M14 keys after completing M13, reloads
from the mirrored legacy project, and proves automatic lossless migration. It
then re-imports identical audio without growing the library, searches and edits
provenance, races two identical imports through different entry points, reuses
the sound in two named projects, switches back without state loss, deletes the
temporary project without deleting catalog audio, corrupts only the Library key
and proves the workspace survives and repairs it, searches by permission text,
and checks the 320 px layout and 44 px controls.

The full Japanese course sweep independently pins Sample Library's catalog,
filter, import, and project decisions as `JAC9`. The offline gate pins the
`m14-v1` cache and boots the same deferred Sample Lab module at both root and
nested deployment paths.
