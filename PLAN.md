# SXC-1 Trainer — Master Plan

Interactive web training course for the Casio SXC-1 portable standalone sampler
(Japan-market device; all official docs are Japanese). Two deliverables:

1. **Full English translations** of all four official manuals, published on the site.
2. **A training program** — exercises that take an owner from unboxing to fluency,
   mirroring the guide book's own progression.

Site name: **SEXY ONE** (owner-confirmed 2026-08-08; "SXC-1 Trainer" stays
alongside it as the descriptive subtitle — see Resolved).

## Locked decisions (owner interview, 2026-08-06)

| Question | Decision |
|---|---|
| Architecture | **Miso + GHC WASM** — entire app in Haskell, compiled to WebAssembly, shipped as static files |
| Hosting | GitHub Pages (free, link-shareable, zero servers) |
| Translations | **Published on the site** alongside the course (owner accepts the copyright exposure of hosting a translated Casio manual) |
| Exercise types | All four: concept quizzes/flashcards, hands-on device drills, WebMIDI live-device checks, spaced repetition + progress |
| Progress storage | Browser localStorage (no backend) |
| External review | Codex as **adversarial reviewer** per milestone via `../Agent/runner/cross-agent.py`; never writes to this repo |

## Roles and pipeline

Chain of authority for every code milestone:

1. **Fable (this session)** — planning only. Owns this document, milestone briefs,
   task routing, and content workflows. Does not write application code.
2. **Opus 5 design agent** — receives a milestone brief; full latitude to produce its
   own implementation plan; must decompose it into an explicit task manifest
   (task → files owned → acceptance checks) suitable for parallel implementation.
3. **Sonnet 5 implementation swarm** — one agent per manifest task, disjoint file
   ownership, run in parallel. Subagents cannot spawn subagents, so Fable
   mechanically fans the Opus manifest out to the swarm — Fable adds nothing.
4. **Opus 5 sign-off** — the same design context reviews the swarm's output against
   its own manifest; iterates with the swarm until it signs off.
5. **Codex adversarial review** — signed-off milestone is dispatched through the
   cross-agent runner in `~/repos/Agent`. Findings return to Fable, which routes
   fixes back through steps 2–4. Model: `gpt-5.6-sol` at `xhigh` reasoning
   (owner-confirmed 2026-08-06). Verified invocation (dry-run tested):

   ```bash
   cd ~/repos/Agent && python3 runner/cross-agent.py \
     --direction cc-to-codex --task-type review --read-only \
     --working-dir /home/mrcolson/repos/casio-sxc1 \
     --codex-bin 'codex -m gpt-5.6-sol -c model_reasoning_effort=xhigh' \
     --prompt "…"
   ```

   Dispatch artifacts land in `state/cross-agent/` (gitignored).

Content work (translation, exercise authoring) does not use the Opus→Sonnet chain —
it's not code. Fable runs dedicated content workflows with QA stages instead.

## Content pipeline

```
manuals/*.pdf
  └─ scripts/extract-pages.sh        → manuals/pages/<slug>/page-NN.png  (150 dpi, gitignored)
                                     → manuals/text/<slug>/page-NN{,.layout}.txt (gitignored)
       └─ translation workflow       → translations/glossary.md
                                     → translations/<slug>.md            (EN, page markers)
                                     → translations/<slug>.qa-notes.md
            └─ exercise authoring    → content/  (format defined in M2 by Opus;
                                        exercises reference manual pages by marker)
```

Document slugs: `guide-book` (71 pp), `startup-guide` (15 pp), `midi` (6 pp), `oss` (16 pp).
The guide book's chapters are the course spine: **Preparation → Pad Play → Sampling →
Sequencer → Skill-Up**.

## Milestones

Each milestone ends with: Opus sign-off → Codex adversarial review → fixes → tag.

- **M0 — Toolchain spike.** Miso hello-world compiled with the GHC WASM backend,
  reproducible build script, static output servable from GitHub Pages, README with
  build instructions. De-risks the exotic toolchain before anything depends on it.
  *Done when: a fresh clone builds and produces a working page in a browser.*
- **M1 — Manual reader.** Pipeline from `translations/*.md` into the app; all four
  manuals browsable with chapter navigation and a toggle to view the original JA
  page image beside the translation. *Done when: every page of all four documents is
  reachable and legible on desktop and phone.* **CLOSED 2026-08-06** (tag `m1`):
  three sign-off rounds + two Codex gates; 55-check suite; minors NEW9-partial/
  NEW11/NEW12 tracked into M2's harness tasks.
- **M2 — Exercise engine.** Haskell exercise engine with three exercise types
  (quiz/flashcard, multi-step guided device drill with self-check, reference lookup),
  a stable content format, and authored content for Preparation + Pad Play chapters.
- **M3 — Full course + memory.** Content for Sampling, Sequencer, Skill-Up;
  localStorage progress, spaced-repetition resurfacing, streaks/completion UI.
- **M4 — WebMIDI.** JS FFI bridge from WASM; SXC-1 detection over USB-MIDI; drills
  that verify completion by listening for the CCs documented in the MIDI
  implementation doc. Chromium-only; must degrade gracefully elsewhere.
- **M5 — Ship.** Mobile/a11y polish, content completeness audit against the manuals,
  whole-project Codex review, GitHub Pages publish, shareable link.
- **M6 — Japanese.** Owner directive: "It's important that the course is available
  in Japanese too." UI strings and all 435 exercises in Japanese, selectable at
  runtime, with progress shared across languages. *Done when: a learner can take
  the whole course in Japanese and their history follows them between languages.*
  **IMPLEMENTATION COMPLETE 2026-08-08** (waves 1-4; gate pending): the corpus
  moved out of `app.wasm` into fetched per-language bundles (plan ruling 1, which
  is what made a second language fit under the frozen 1,000,000-byte ceiling —
  879,161 gzip at ship, 120,839 of headroom; bundles 167,732 of their own 300,000
  ceiling); inline `ja:` variants in the same `.ex.md` files keep one id and one
  registry per exercise, so progress is shared by construction; a `Lang`-indexed
  UI string table plus a `uiLang` pref (prefs schema v2) and a header toggle; all
  52 decks translated against the original Japanese manual pages and
  QA-verified deck by deck. JA completeness is enforced hard (`E-JA-MISSING`),
  and both full browser stages complete a real Japanese quiz out of the shipped
  `ja` bundle. Gate: `check-site` **109/109 result=complete**, **238** assertions
  per browser stage, `exercise-check` **454/454** self-test / **56/56** fixtures /
  0 issues, `browser-check` **198/198** self-test and **42/42** sabotage passes,
  `content-check` 412/412, `progress-check` 91/91, `registry-check` 8/8 + 16/16.
  Remaining: Codex adversarial review, tag `m6`, deploy both hosts, live-verify
  EN+JA flows.
- **M7 — Japanese manual text.** Owner report, 2026-08-08: on `#/m/guide-book/p/2/ja`
  the chrome was Japanese but the page body was English — `/ja` showed Casio's
  original page as an IMAGE beside the English translation TEXT, so a Japanese reader
  got a picture they could not select, search, copy or reflow. *Done when: a learner
  reading in Japanese gets Japanese TEXT on every manual page, with the original scan
  still one click away.* **IMPLEMENTATION COMPLETE 2026-08-09** (waves 1-3; gate
  pending): the manual text moved out of `app.wasm` into fetched per-language bundles
  under M6's manifest/fingerprint discipline (plan ruling 1 — the wasm *shed* 48,984
  gzip bytes, 838,748 at ship with 161,252 of headroom under the frozen ceiling, and
  the four manual bundles cost 118,033 of a new 250,000 ceiling; all four fetched
  bundles 285,765 of 550,000); all **108 pages** of all four documents were
  TRANSCRIBED from the page images into `translations/<slug>.ja.md` (ruling 3 — never
  a back-translation, on-device labels left in Latin caps) and QA-accepted page by
  page; EN/JA structural parity is enforced by `exercise-check
  --manual-structural-diff`, which parses both bundles with the reader's own
  `mkDoc` and compares page markers, block sequences, heading levels, list/table
  shapes and figure-callout positions (**109/109**, three negative controls); and the
  per-document EN-fallback note of ruling 4 — unchanged in the app, and still red-
  tested against a rebuilt EN-fallback bundle — is now asserted by its ABSENCE, with
  four ID-pinned `ja manual:` assertions (JAM1-JAM4) reading real Japanese off real
  routes in both browser stages, the original page image still reachable on `/ja`.
  Gate: `check-site` **129/129 result=complete**, **242** assertions per browser
  stage, `exercise-check` **454/454** self-test / **56/56** fixtures / 0 issues /
  **53/53** + **109/109** structural diffs, `browser-check` **198/198** self-test and
  **42/42** sabotage passes, `content-check` 412/412, `progress-check` 91/91,
  `registry-check` 8/8 + 16/16. Remaining: Codex adversarial review, tag `m7`, deploy
  both hosts, live-verify the Japanese manual text.
- **M8 — Mastery guidance + mobile boot.** Replace the experimental GPU DAG
  with a DOM-only, dependency-aware action queue and chapter trail; add a stable
  five-card Today's Session coach; start the dominant WASM request earlier,
  reduce the suggested heap to 16 MiB, and fail unsupported mobile engines
  before the WASM download. **IMPLEMENTATION COMPLETE 2026-08-10.** Contracts:
  `docs/MASTERY-MAP.md` and `docs/TODAYS-SESSION.md`.
- **M9 — Phone-ready release.** Make the trainer installable and available after
  a connection disappears, preserve coherent updates at both root and nested
  paths, expose local field-performance evidence, and wrap the existing
  validated progress envelope in file save/share/load controls. **IMPLEMENTATION
  COMPLETE 2026-08-11; physical-device acceptance pending.** Contract:
  `docs/PHONE-READY.md`.
- **M10 — Weekly Pulse.** Turn recent practice and the saved review schedule into
  a calm seven-day reflection: rhythm, review outlook, skills in motion,
  difficulty signals, and one next focus. Progress schema v3 retains only the
  latest 200 coarse local learning marks and carries them through the existing
  passport; v1/v2 files migrate without scheduler loss. The route stays DOM-only,
  bilingual, offline, and phone-safe. **IMPLEMENTATION COMPLETE 2026-08-11.**
  Contract: `docs/WEEKLY-PULSE.md`.
- **M11 — Flashcard continuity + two-action UX.** Replace all 128 live
  self-assessed recall prompts with authored bilingual binary flashcards; separate
  evaluation from an explicit `Again` / `Hard` / `Good` / `Easy` scheduler grade;
  make every rating continue while its interval determines when the prompt returns;
  give hands-on drills a schedule-preserving Skip action; and apply the same
  replace-don't-append discipline to hints, progress backup/reset, and device
  mismatch repair. Session completion reconciles from persisted progress.
  **COMPLETE AND DEPLOYED 2026-08-11.** The optimized artifact passed the full
  135/135 release gate (235/235 browser assertions at both root and nested paths),
  then passed 73/73 against production. Contract: `docs/FLASHCARD-FLOW.md`.
- **M12 — Sample Lab.** Add the second local-first SEXY ONE workflow: import
  Audacity exports, arrange a four-slot A-D plan across SXC-1 user banks 15-80,
  preview and annotate a 4×4 pad layout, package the original audio plus metadata
  as one portable `.sxc1lab` file, and walk the phone through one CASIO Sampler
  App assignment at a time. Audio never reaches a SEXY ONE server and the
  planner is deferred until after trainer interactivity, so it adds no weight to
  the critical boot graph. **COMPLETE AND DEPLOYED 2026-08-13.** The optimized
  artifact passed the full 136/136 release gate with 236/236 browser assertions
  at both the origin root and nested-path deployment, then passed 74/74 against
  production. Contract:
  `docs/SAMPLE-LAB.md`.
- **M13 — Sample Inbox.** Turn Sample Lab into a fluid bulk-organizing surface:
  import an Audacity batch into an unassigned tray, preview and tap/drag sounds
  onto pads, move or swap assignments across A-D banks without losing audio,
  fill empty pads in import order, carry unassigned sounds inside the existing
  portable project format, and review project readiness before phone handoff.
  Old M12 browser state and `.sxc1lab` files migrate without conversion.
  **COMPLETE AND DEPLOYED 2026-08-13.** The optimized artifact passed the
  full 136/136 release gate with 238/238 browser assertions at both the origin
  root and nested-path deployment, then passed 75/75 against production.
  Contract: `docs/SAMPLE-INBOX.md`.
- **M14 — Sample Library + named projects.** Add one searchable, staged local
  catalog shared across projects; deduplicate identical imports without adding
  startup work; retain source, tags, edit notes, permission/credit, BPM, and
  format facts; and reuse one stored sound in multiple named project Inboxes.
  Existing M12/M13 state migrates automatically, the active project remains
  mirrored for rollback, and `.sxc1lab` stays a bounded one-project phone
  transfer. **COMPLETE AND DEPLOYED 2026-08-14.** The optimized artifact passed
  136/136 checks with 240/240 browser assertions at both root and nested
  deployment paths, then passed 76/76 against production.
  Contract: `docs/SAMPLE-LIBRARY.md`.

## Non-negotiable constraints (Opus latitude ends here)

- Language: Haskell via Miso + GHC WASM. No SPA frameworks, no server component.
- Output must be fully static and hostable on GitHub Pages.
- Exercise content lives in data files with a documented schema, not hardcoded in UI code.
- Translated manual text is the single source of truth; exercises cite manual pages.
- Every milestone lands with tests runnable in CI and a build that works from a fresh clone.

## Risks

- **GHC WASM toolchain** — youngest part of the stack; hence M0 first. Fallback if the
  spike fails: the jsaddle route, or (owner approval required) downgrade to Hakyll+JS.
- **WebMIDI from WASM** — needs hand-written JS FFI shims; isolated in M4 so it can't
  block the course.
- **Copyright** — owner chose to publish full translations. Revisit visibility
  (unlisted repo/site) if Casio objects; site should carry a "fan translation,
  not affiliated with Casio" notice.
- **Repo weight** — guide-book PDF is 75 MB (under GitHub's 100 MB hard limit, over
  its 50 MB warning). Page PNGs (34 MB) are gitignored but M1 will need them as site
  assets; decide at M1 whether to commit them or generate at deploy time.
- **Device is post-cutoff** — no model prior knowledge; manuals and Casio's linked
  tutorial videos are ground truth for all content.

## Notes and rulings

Deploy-path note (2026-08-06): GitHub's workflow Pages-deployment queue wedged
(4 consecutive `deployment_queued` timeouts, no posted incident). The m1 build
is deployed via the legacy branch path (`gh-pages` branch, `build_type=legacy`)
and `ENABLE_PAGES=false` keeps the workflow deploy job inert. To return to
workflow deploys: set `ENABLE_PAGES=true`, PUT `build_type=workflow`, push.
Branch deploys are manual: build + verify locally, copy `site/public` onto
`gh-pages`, push.

Vercel (2026-08-07, owner-requested): the same static build also deploys to
**https://sexy-one-gray.vercel.app/** (project `sexy-one`; the bare
sexy-one.vercel.app belongs to an unrelated third party — never share that
one). Deploy: copy `site/public` to a scratch dir named `sexy-one`, run
`vercel deploy --prod --yes` (CLI authenticated as the owner's account).
Initially verified 70/70 by browser-check against production. The current M14 release
(`dpl_29VThHSMWYUMdZ9TB4hicDhUZ2Ey`) was deployed 2026-08-14 and verified 76/76
against the main alias, with the
deployed files byte-identical to the locally gated artifact and the correct
`application/wasm` content type. First-visit CDN cold-decode latency on the
108-image sweep warms after one pass. Audience note: the site will be shared
with a Japanese speaker — M3 adds a persistent JA-first reading mode.

Size ruling (coordinator, 2026-08-07, for explicit Codex scrutiny at the M3
gate): **wasm-opt is adopted into the default build** (M3 design §5.2 lever 1).
Grounds: the full 435-id course cannot fit under the 1,000,000 ceiling
unoptimized (measured ~1,100K; corpus bytes are the binding constraint at
0.3456 gzip B/raw B); wasm-opt ships the full course at ~920K — smaller than
M2 today; the M0-era miscompile concern was attacked empirically (could not
be made to miscompile; byte-identical self-tests; six clean 70/70 browser
runs) and the behavioral suite runs against the OPTIMIZED artifact every
build, so any future binaryen defect hits the same net everything else does.
The 1,000,000 tripwire stays. The alternatives (raise ceiling / stop
embedding corpus) were rejected while a smaller-than-today option existed.

Size ruling amendment (coordinator, 2026-08-07, M4 wave 0): the wasm-opt
invocation moves from `-all -O2` to `--detect-features -Oz --converge`.
Grounds: `-O2` left the gate-cleared m3 artifact at 911,799 gzip — over the
895,000 line M4's wave-0 kill-switch requires for the 42,000-byte M4 budget
plus the 60,000-byte M5 reserve; `-Oz --converge` measures 890,713 gzip,
under the line with all budget arithmetic intact. `-all` is dropped because
at -Oz binaryen emitted an experimental heap-type encoding
(custom-descriptors "exact") that shipping V8 rejects at compile —
`--detect-features` pins binaryen to the module's own declared feature set.
The full 80/80 check-site suite (including every real-browser flow) ran
against the exact -Oz artifact before adoption; the behavioral-net argument
from the original ruling is unchanged.

Resolved:
- Site title (2026-08-08, owner-confirmed): **SEXY ONE** (M5 item 9 closed;
  rename executed in M5).
- Codex model slug = `gpt-5.6-sol`, reasoning `xhigh` (2026-08-06).
- GitHub repo (2026-08-06, owner-confirmed): **public**, `robjohncolson/sexy_one`.
  Site lives at https://robjohncolson.github.io/sexy_one/ — the sub-path the M0
  checker validates against. Pages was ORIGINALLY via Actions workflow with
  `ENABLE_PAGES=true`; since the queue wedged (deploy-path note above) the
  CURRENT state is legacy `gh-pages`-branch deploys with `ENABLE_PAGES=false` —
  the deploy-path note is authoritative; M5 debt item 8 probes the workflow
  path at ship time.
