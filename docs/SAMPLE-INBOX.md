# M13 Sample Inbox contract

Sample Inbox is the organizing layer between Audacity and the SXC-1 pad map. It
extends Sample Lab without changing the local-only boundary or CASIO handoff
described in [`SAMPLE-LAB.md`](SAMPLE-LAB.md).

## Workflow

1. Drop or choose as many as 64 supported files in one batch. Each valid WAV,
   MP3, FLAC, or `.cswp` file is analyzed and retained in import order.
2. Audition any Inbox card. Selecting it arms placement; the next pad press
   assigns it. On desktop the same operation works by dragging the card.
3. If the destination is occupied, its former sound returns to the Inbox. No
   placement operation discards audio.
4. `Fill empty pads` takes Inbox items in order and assigns only empty pads in
   the active bank. Extra items remain in the Inbox.
5. An assigned pad can be armed for move/swap and then placed on any pad in any
   A-D bank. An empty destination moves it; an occupied destination swaps the
   two assignments. Desktop drag performs the same operation.
6. `Return to Inbox` removes an assignment without deleting its audio. Removing
   an unassigned Inbox item requires confirmation; since M14, its shared Sample
   Library sound remains available unless separately removed there.
7. Phone handoff first checks the whole project. Missing audio blocks handoff;
   duplicate physical bank numbers, unassigned Inbox items, duplicate pad
   labels, and files that are supported but not 48 kHz / 16-bit WAV are clearly
   summarized. Non-blocking findings can be accepted explicitly.

## Interaction rules

- The Inbox action row always contains at most two decisions. With nothing
  selected they are `Add samples` and `Fill empty pads`; with an item selected
  they are replaced by `Assign next empty` and `Remove from Inbox`.
- Placement creates one temporary instruction with one Cancel action. It does
  not append another workflow below the page.
- Pads and Inbox cards are collection controls representing sounds and hardware,
  not a collection of unrelated calls to action.
- Mouse, touch, and keyboard all have a complete path. Drag-and-drop is an
  accelerator, never the only way to move audio.
- Escape cancels a pending placement. Bank switching keeps a pad move armed so
  cross-bank moves work.

## Data and migration

The portable container remains `SXC1LAB1` / manifest schema 1. M13 adds an
optional `project.inbox` array whose items use the same normalized audio
metadata as assigned pads plus a stable item id. Export includes the union of
all blob ids referenced by pads and Inbox items exactly once.

M12 browser state and project files have no `inbox` property. Normalization
migrates that absence to `[]`; no rewrite or one-way conversion is required.
Import validates Inbox references with the same range and missing-blob checks as
pad references before replacing the current project.

## Safety invariants

- Auto-fill never overwrites a pad.
- Placement on an occupied pad never deletes the displaced sample.
- Moving or swapping pads never duplicates a blob reference.
- A blob is deleted from IndexedDB only when it is no longer referenced by any
  library record, bank pad, or Inbox item in any project.
- Project validation never changes the project.
- Audio remains local and no new network path is introduced.
