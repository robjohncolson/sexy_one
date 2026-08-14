# M15 Phone Bridge contract

Phone Bridge closes the local workflow between the computer planner and CASIO
Sampler App. It does not write to the SXC-1 or imitate CASIO's private transfer
protocol. SEXY ONE carries one complete project to the phone, keeps the exact
bank/pad destination visible, and records what the user confirms happened in
the official app.

## Computer to phone

1. `Send project to phone` builds the existing `.sxc1lab` schema-1 envelope,
   including every referenced audio blob exactly once.
2. If the browser can share that file, SEXY ONE opens the operating system's
   native share sheet. Otherwise it saves the same named file for AirDrop,
   Nearby Share, cloud drive, cable transfer, or another user-chosen path.
3. Choosing that `.sxc1lab` file through SEXY ONE's project importer on the
   phone opens the handoff review directly. Blocking missing-audio findings stop
   the flow; non-blocking naming, format, bank, and Inbox findings remain an
   explicit two-way decision.

No account, upload endpoint, tracking request, or SEXY ONE server is introduced.

## Resumable pad state machine

Each assigned pad moves through a small explicit state machine:

```text
Pending --Share/save--> Shared --Loaded---> Loaded
   |                       |
   |                       +----Problem---> Problem
   |
   +--Skip for now-------------------------> Skipped
```

- `Share this file / Skip for now` is the only initial decision pair.
- A successful share or save replaces that pair with `Loaded / Problem`; it
  never appends more buttons and never assumes the official app succeeded.
- Loaded, Problem, and Skip each advance automatically to the next unresolved
  destination. There is no redundant Next button.
- Reloading, closing the browser, or switching to CASIO Sampler App preserves
  the exact current destination. A planner action becomes Resume while work is
  open and Review receipt after every destination has an outcome.
- The receipt lists every bank/pad as Loaded, Problem, or Skipped. Retry
  unresolved preserves Loaded rows, resets only Problem/Skipped rows, and
  returns to the first of them.
- Escape backs out to the planner without erasing the session.

## Storage and compatibility

- `sxc1.sample-handoffs.v1` stores at most 32 project sessions and 64 pad rows
  per session. It contains only project/blob identifiers, destinations, names,
  statuses, and timestamps; audio remains in IndexedDB.
- A row identity includes project slot, physical bank, pad number, and blob id.
  Editing a plan therefore preserves outcomes for truly unchanged rows while a
  moved or replaced sound returns to Pending.
- The handoff key is parsed independently from the M14 workspace and Library
  keys. Corrupt handoff data repairs to an empty ledger without replacing a
  valid project or catalog.
- `.sxc1lab` remains `SXC1LAB1` / manifest schema 1. Handoff progress is local
  operational state rather than portable project content, so every M12-M14
  project continues to import without conversion.

## Permanent regressions

The full browser workflow starts a four-pad handoff, saves the first file,
reloads while its Loaded/Problem decision is pending, and proves the same
destination and decision pair return. It then records Loaded, Skipped, Problem,
and Loaded outcomes with automatic advancement, checks the persisted receipt at
320 px, reloads and reviews it, retries only the unresolved rows, corrupts only
the handoff key, and proves the valid M14 workspace and Library survive. A
portable project imported through the phone-facing option must land in handoff
review. The offline gate pins the current cache at root and nested paths; M16's
cache also carries the on-demand Sound Check worker.
