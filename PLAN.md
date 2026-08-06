# SXC-1 Trainer — Master Plan

Interactive web training course for the Casio SXC-1 portable standalone sampler
(Japan-market device; all official docs are Japanese). Two deliverables:

1. **Full English translations** of all four official manuals, published on the site.
2. **A training program** — exercises that take an owner from unboxing to fluency,
   mirroring the guide book's own progression.

Working title: **SXC-1 Trainer** (rename freely).

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

## Open questions for the owner

1. Site title — "SXC-1 Trainer" is a placeholder ("SEXY ONE" is a natural
   candidate given the repo name; owner to confirm).

Resolved:
- Codex model slug = `gpt-5.6-sol`, reasoning `xhigh` (2026-08-06).
- GitHub repo (2026-08-06, owner-confirmed): **public**, `robjohncolson/sexy_one`.
  Pages via Actions workflow; `ENABLE_PAGES=true` repo variable set. Site will
  live at https://robjohncolson.github.io/sexy_one/ — the sub-path the M0
  checker validates against.
