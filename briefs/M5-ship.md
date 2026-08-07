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
4. StaticCode totality sweep — CLOSED in M3/M4: CheckExercises.hs carries the
   sweep (stLabel 19, WHNF + non-empty codeText over every allIssueCodes
   member); recorded closed in briefs/M4-budget.json contract
   (low_staticcode_totality_closed=true).
5. EXERCISE_FIXTURE_FIELDS declared targets — CLOSED in M3: browser-check
   requires citeSlug/citePage (quiz, drill) and targetPage/targetSlug
   (lookup); recorded closed in briefs/M4-budget.json contract
   (low_fixture_declared_targets_closed=true).
6. `exercise-check` runs only from `site/` (`..`-relative inventory path) —
   authoring-UX wart (M2 advisory).
7. Inventory id-binding is a path-substring switch — brittle to content-root
   moves (M2 advisory; observable via inventoryChecked, but make it structural).

Content:
10. `d-2-09` FX hooks need real-device recalibration (owner evidence,
    2026-08-07, docs/M4-device-evidence.md): (a) step 1's `cc 16 0,127` is
    NOT unreachable as M4-F1 predicted — the dial's endpoints emit 0/127, so
    a full sweep confirms; the instruction text should say "turn fully down"
    (or the grammar gains an any-value form). (b) step 2's `cc 108 127`
    misses the first press when step 1's dial motion left FX1 toggled on —
    the FX buttons transmit 127/0 as ON/OFF edges; hook should accept
    `0,127` or the step order/wording should guarantee the off state.
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
9. Site title decision — RESOLVED 2026-08-08: owner chose **SEXY ONE**; rename the header, <title>, README landing, and any view/string mentions (keep "SXC-1 trainer" as descriptive prose where it aids search).

Ship checklist (beyond debt):
- Full a11y pass (keyboard-only exercise completion, focus management on
  prompt advance, SR labels on pads/options) and mobile polish sweep.
- Content completeness audit against the manuals (inventory coverage report:
  what shipped vs the 440 candidates).
- README/landing polish for strangers arriving at the link.
- Final whole-project Codex review (all commits since m0; gpt-5.6-sol xhigh),
  followed by the closing deploy.
