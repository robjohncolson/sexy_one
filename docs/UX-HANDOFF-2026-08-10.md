# UX handoff — 2026-08-10

This note records the product decisions behind the current SXC-1 trainer so a
future revision does not accidentally restore the problems removed in this
round of work.

## Current production state

- Production: <https://sexy-one-gray.vercel.app/>
- Vercel deployment: `dpl_66kAbncHPkcb6wsMRoUK38yygVfq`
- Immutable deployment URL: <https://sexy-e3rn2q3ns-roberts-projects-19fe2013.vercel.app/>
- Course: 50 decks, 352 exercises, 467 prompts; no page-lookup exercises.
- Last complete local gate: 136/136 checks, with 240/240 browser assertions at
  both the origin root and a nested deployment path.
- Last production quick gate: 75/75 assertions.

## Product decisions to preserve

1. The home page is a guided entry point. Keep the phone QR visible and centered,
   keep Today's Session as the dominant green path, and keep the course/manual table
   of contents behind the alternate disclosure instead of making the learner
   choose among many equal-looking links.
2. Test operation of the SXC-1, not memory of the documentation. Do not add cards
   asking for page numbers, section locations, or where a fact appears in the
   guide. Navigation is the application's responsibility.
3. Use multiple choice when the learner can make a genuinely gradable selection.
   `ch0-06/q-0-08` (MAIN VOL outputs) is the canonical example: it presents four
   plausible options and grades the choice before showing its explanation.
4. Every quiz requires an actual answer. Do not ship “answer in your own words,”
   “show answer,” or “did you know it?” as the assessment. The 128 former open-recall
   cards now carry one authored English/Japanese distractor beside the correct model
   answer and compile to stable binary Choice prompts.
5. Keep one two-action decision surface. Before feedback it is `Check answer` /
   `I’m not sure`; checking replaces that pair with `Good` / `Easy` after a correct
   answer or `Again` / `Hard` after a miss. Never append the grade controls below the
   old actions, and never add a separate Next button: rating itself continues.
   All four grades move forward; `Again` schedules the prompt back sooner rather
   than immediately repeating it. A grade that finishes the card opens the next
   session/course item directly; do not reintroduce a completion screen asking
   whether to repeat it.
6. Review grades are real scheduler input, not decorative labels. Checking alone
   creates no progress event. Persist the exact chosen grade (`again`, `hard`, `good`,
   or `easy`) and keep the native radio/checkbox answer controls distinct from the
   two action buttons.
7. A prompt referring to a numbered control, panel callout, diagram, or other
   visual context must show that source image beside the question. The
   `visual-source` tag drives this behavior. A citation link alone is not enough.
8. Every learner-visible change must remain bilingual. Update the English and
   Japanese variants together.
9. Today's Session at `#/x/today` is the primary action surface. Preserve its
   five-card due/continue/new balance, exercise-kind diversity, tab/day-stable
   snapshot, explicit rebuild action, real-completion tracking, and body-level
   next-card coach. Reconcile completed rows from persisted `masteryDone` on every
   render; the tab-local plan is ordering state, never the completion authority.
   The plan may use prerequisites to choose useful new work but
   must never lock a lesson. See `docs/TODAYS-SESSION.md`.
10. The mastery journey at `#/x/map` is a progress explanation and browse surface,
   not a gate. Keep Today's Session dominant, keep prerequisite
   links advisory, and derive all mastery evidence from the existing saved
   progress schema. Preserve the due-first action queue, one-chapter-at-a-time
   trail, and complete linked deck list. Do not restore a GPU graph: the useful
   product is the dependency-aware decision, not spatial navigation. See
   `docs/MASTERY-MAP.md` for the tier and layout contracts.
11. Mobile boot is a product contract. Keep the GHC suggested heap at 16 MiB
    unless measured evidence requires more, retain the pre-download SIMD probe
    and its iOS recovery message, and keep `__SXC1_BOOT_METRICS` covered by the
    24 MiB browser ceiling.
12. Offline mode is an executable-shell fallback, not a bulk-download feature.
    Keep service-worker registration after first interactivity, keep core loads
    network-first, require a complete versioned cache before activation, and
    leave the 108 manual scans out of precache. Preserve relative manifest,
    worker, start, and scope URLs so GitHub Pages-style subpaths remain valid.
13. The progress passport moves the existing Haskell-generated export envelope;
    it does not define a second wire format. File selection must remain an
    uncommitted preview until the learner presses Import and the Haskell codec
    accepts it. Keep DOM-owned Save/Share and file-picker controls inside the
    empty `#sxc1-progress-passport` and `#sxc1-import-file-shell` ownership
    seams. See `docs/PHONE-READY.md`.
14. Weekly Pulse at `#/x/week` is a reflection and decision surface, not a
    scorecard. Keep its UTC seven-day rhythm/outlook, due-first focus, non-locking
    difficulty language, 200-mark local cap, schema migration, and progress-passport
    inclusion. Do not turn it into remote analytics or restore a graph renderer.
    See `docs/WEEKLY-PULSE.md`.
15. Progressive disclosure applies beyond quizzes. Hints are native details, the
    progress-data panel separates Export, Import, and Wipe into their own details,
    Export is replaced by Save/Share after generation, and Wipe is replaced by its
    confirmation. A MIDI channel repair replaces enable/disable while the mismatch
    is active, so the drill still exposes at most that repair plus manual Confirm.
16. Hands-on cards must remain usable away from the SXC-1. The active step exposes
    exactly `Skip for now` / `Yes — done`; Skip records all remaining prompts as
    skipped and due, then continues. Do not make absence from the device look like
    mastery, and do not strand the learner on a repeat-card summary.

## Regression anchors

- `scripts/browser-check.mjs` contains the assertion named `flashcards quiz an
  actual choice, replace each two-action decision with Again/Hard or Good/Easy,
  and persist the chosen grade`. It proves selection is required, checking writes
  nothing, both replacement pairs have exactly two actions, Easy advances, Again
  returns fresh, and the emitted events carry the chosen reviews.
- The live flashcard regression uses `ch0-06/q-0-09`; MAIN VOL (`q-0-08`) remains
  a larger explicit-choice question. The real-corpus self-test independently pins
  all 128 authored bilingual distractors and zero live Recall prompts.
- The panel-image regression uses `ch0-06/q-0-04` and verifies the cited scan is
  decoded and displayed with the expected crop.
- The mastery regression requires all 50 linked skills and 49 authored
  dependencies, a three-item recommendation queue, native chapter tabs, one
  progressively disclosed trail, prerequisite explanations, and zero canvases.
- The two session regressions pin five unique stable cards, due/continue/new
  adaptation, mixed kinds, a 5–10 minute estimate, the out-of-tree coach, and a
  real completion advancing to the next planned card. Both small-phone sweeps
  include `#/x/today`.
- The mobile boot regressions cap initial WASM memory at 24 MiB and impersonate
  an older iPhone engine to prove it receives recovery guidance without an
  `app.wasm` request.
- The phone-ready regressions require a registered `m14-v1` worker, relative
  standalone manifest, real network-disabled WASM boot at root and nested scope,
  the visible offline live region, byte-identical `.sxc1` download/file load,
  no pre-commit storage mutation, and a 320 px passport layout.
- The Weekly Pulse regression pins a three-active-day fixture, four tracked
  answers, exact `[1,0,1,0,0,0,1]` review outlook, strengths, friction,
  due-first focus, Japanese chrome, zero canvases, and both small-phone sweeps.

## Build, verification, and deployment

Run from the repository root:

```sh
./scripts/build-site.sh --optimize
./scripts/check-site.sh
vercel deploy site/public --prod --yes \
  --scope roberts-projects-19fe2013 --project sexy-one --no-color
node scripts/browser-check.mjs \
  --url https://sexy-one-gray.vercel.app/ --quick --timeout 360000
```

The M11 shipping artifact measured 2,378,088 bytes raw / 865,232 bytes
gzipped for `app.wasm`, below the frozen 1,000,000-byte gzip ceiling with
134,768 bytes of headroom. The full local gate passed 135/135, both served
browser stages passed 235/235, and the production quick gate passed 73/73.

Prefer Vercel's normal file upload shown above. `--archive=tgz` repeatedly hit
transient archive-ingestion `fetch failed` / internal-server responses during this
round, while the normal deduplicated upload succeeded. Always verify the main alias
after deployment rather than relying only on the deployment command's exit status.
