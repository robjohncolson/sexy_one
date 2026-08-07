# M5 Brief — Polish, debt, final review, ship

**From:** Fable (planning tier) · **Status:** debt registry maintained from
2026-08-07; manifested by the coordinator directly (no separate design round)
once M3 and M4 close. Items are added here as gates record them — this file is
the single place deferred debt lives.

## Debt registry (source ruling in parentheses)

Reader/UX:
1. Index pages (guide-book pp. 69–70) not linkified — table-cell-scoped rule
   needed, bare numbers don't match the p./pp. grammar (M1 A4, deferred with
   contract debt: plan §4.6 rule 7's claim is false until fixed).
2. Ordered/bullet lists fragment into N single-item elements when items have
   indented children — numbering always correct, semantics/a11y wrong; fix in
   `gatherChildren`/`collect` needs its own corpus-wide pinning round (M1 A7;
   M2's consecutive-numbering guard is the tripwire).
3. Breadcrumb on co-located-section pages names the last section — a TOC click
   on "Try applying an effect" lands on a page whose breadcrumb says "Try
   sampling" (M1 final sign-off advisory 1; startup-guide pp. 10/14, midi p.2,
   oss p.11).

Verification/maintenance:
4. StaticCode totality sweep — a new constructor with a forgotten pattern
   synonym/codeText arm isn't caught mechanically (M2 gate-3 LOW).
5. EXERCISE_FIXTURE_FIELDS validation lacks the declared-target fields
   (M2 gate-3 LOW).
6. `exercise-check` runs only from `site/` (`..`-relative inventory path) —
   authoring-UX wart (M2 advisory).
7. Inventory id-binding is a path-substring switch — brittle to content-root
   moves (M2 advisory; observable via inventoryChecked, but make it structural).

Content:
10. `d-2-09` step 1's `verify: cc 16 0,127` is unreachable — CC 16 is the
    continuous FX1 dial (±1 per detent, never 0/127), and the verify grammar
    has no "any value" form; fix needs a grammar extension or re-pointing the
    hook (M4 design finding M4-F1; the device protocol pre-warns the owner).
11. Hand-confirmed steps that carry a verify hook show the idle sentence
    ("Device verification is off — confirm manually, or turn it on above.")
    even while device verification is ON — misleading on M4-F1's step 1,
    where hand-confirming with the device enabled is the documented path
    (device-protocol walkthrough finding, 2026-08-07; cosmetic, the protocol
    tells the owner to ignore it).

Ops:
12. check-site's storage-refused stage leaks its python http.server child —
    the cleanup kills the subshell pid, not the python process (observed twice,
    2026-08-07: orphaned `http.server 8130`/`8307` after full runs; M4
    verification-task housekeeping note).
8. Revert to workflow Pages deploys when GitHub's deployment queue recovers —
   set ENABLE_PAGES=true, PUT build_type=workflow, retire the manual gh-pages
   procedure (PLAN.md deploy-path note).
9. Site title decision — "SXC-1 Trainer" vs "SEXY ONE" (owner).

Ship checklist (beyond debt):
- Full a11y pass (keyboard-only exercise completion, focus management on
  prompt advance, SR labels on pads/options) and mobile polish sweep.
- Content completeness audit against the manuals (inventory coverage report:
  what shipped vs the 440 candidates).
- README/landing polish for strangers arriving at the link.
- Final whole-project Codex review (all commits since m0; gpt-5.6-sol xhigh),
  followed by the closing deploy.
