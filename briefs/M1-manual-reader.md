# M1 Brief — Manual reader

**From:** Fable (planning tier) · **To:** Opus 5 design agent · **Status:** design
dispatched 2026-08-06 in parallel with M0's Codex review (M0 sign-off granted);
M1 *implementation* stays blocked until the M0 gate fully closes

## Goal

All four translated SXC-1 manuals browsable inside the Miso app: chapter/section
navigation, clean typography for procedures and tables, and a per-page toggle to
view the original Japanese page image beside (or instead of) the translation.

Read `PLAN.md` first, then `briefs/M0-plan.md` — M1 builds strictly on M0's
toolchain and build pipeline, which are proven and must not be re-architected.

## Inputs (all committed)

- `translations/{guide-book,startup-guide,midi,oss}.md` — English translations.
  Every source page is delimited by an HTML comment marker `<!-- page N -->`
  (verified 1..N exactly once per document). These markers are load-bearing:
  M2's exercises will cite manual pages through them, so whatever content model
  you design must preserve page identity as stable anchors.
- `translations/glossary.md` — binding terminology, including the five chapter
  titles for the guide book (Part: Preparation / Pad play / Sampling / Sequencer /
  Leveling up). UI labels and navigation must use these exact names.
- `manuals/pages/<slug>/page-NN.png` — 150 dpi renders of every original page
  (34 MB total, currently gitignored; regenerable via `scripts/extract-pages.sh`
  from the committed PDFs). How these reach `site/public/` is your design call:
  commit them, copy at build time, or render in CI (ubuntu runners can apt-get
  poppler-utils; the PDFs are in the repo). Weigh repo size against CI time and
  keep GitHub Pages' 1 GB site limit in mind.

## Constraints beyond PLAN.md's non-negotiables

1. Content is parsed from `translations/*.md` at build time — never hand-copied
   into Haskell source. A translation edit must flow to the site by rebuilding.
2. Manual pages carry a visible disclaimer: fan translation, not affiliated with
   Casio; original © CASIO COMPUTER CO., LTD.
3. The M0 verification harness stays green; extend `check-site.sh` and
   `browser-check.mjs` with M1 assertions (navigation works, a known guide-book
   page renders, JA image toggle functions).
4. Mobile layout matters: owners will read this next to the device with a phone.

## Lesson from M0 — manifest rules addendum

M0's `ci-workflow` task raced `site-verification-and-readme` because its
verify_commands referenced a file owned by a task absent from its `depends_on`.
Rule for your manifest: **every file a task's verify_commands or prompt reads
must be inside the task's own owned_paths, produced by its `depends_on` closure,
or already committed** — state this closure explicitly per task when in doubt.
Everything else about the M0 manifest format worked well; reuse it (same JSON
schema, disjoint owned_paths, self-contained prompts, falsifiable checks,
background-job warnings for slow builds).

## Deliverables

1. `briefs/M1-plan.md` — your implementation plan: content model, parser
   strategy (build-time Haskell? preprocessing script emitting data the app
   embeds? your call), routing/navigation design, page-image delivery decision.
2. `briefs/M1-manifest.json` — Sonnet swarm manifest, same schema as M0.

Design only: probe read-only, research freely, write nothing outside `briefs/`.

## Sign-off protocol

Unchanged from M0: you review the swarm's output against your acceptance checks,
then Codex (`gpt-5.6-sol`, xhigh) runs the adversarial pass; its findings route
back through you.
