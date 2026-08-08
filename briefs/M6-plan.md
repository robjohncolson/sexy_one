# M6 — Japanese localization (coordinator plan, 2026-08-08)

Owner directive: "It's important that the course is available in Japanese too."
The manuals are already first-class in Japanese (original page images, JA-first
reading mode). M6 makes the APP and the COURSE Japanese: UI strings and all 435
exercises, selectable at runtime, with progress shared across languages.

## Architecture rulings (coordinator; gate-reviewable)

1. **Corpus externalization (the enabling change).** The exercise corpus is
   TH-embedded in app.wasm (site/app/Exercises/Embed.hs; 287,941 raw bytes).
   Doubling it with Japanese breaks the frozen 1,000,000 ceiling
   (933,305 today). Ruling: exercises move OUT of the wasm into per-language
   bundles under site/public/content/ (built by build-site.sh from
   content/exercises/), fetched at boot with the same JS-side-guard discipline
   as the storage bridge (a fetch failure must degrade visibly, never
   kill boot). The wasm keeps the structural Reader and parses the fetched
   text exactly as it parsed the embedded text. The M3 Size ruling's rejected
   "stop embedding corpus" alternative is hereby adopted — the condition that
   rejected it ("while a smaller-than-today option existed") no longer holds.
   MANUAL translations stay embedded (unchanged scope). Expected wasm effect:
   roughly −100K gzip, restoring ceiling headroom before JA UI strings add a
   little back.
2. **Bilingual content model: inline `ja:` fields in the SAME .ex.md files.**
   Every learner-visible field (prompt, options, answers, rationale/why,
   drill step text + check, lookup question) gains a parallel `ja:`-prefixed
   variant in the same exercise block. One file, one id, one registry —
   prompt ids and counts are identical across languages BY CONSTRUCTION, so a
   learner's progress applies regardless of UI language, and the id-registry
   contract is untouched. The build emits content.en.txt.gz and
   content.ja.txt.gz bundles by selecting the field variant. exercise-check
   gains JA-completeness enforcement (a live exercise missing any ja: variant
   is an issue, not a warning, once wave 3 lands; during wave 1-2 the check
   runs in report-only mode gated on a manifest flag — never silently).
   verify:/cite: lines are language-invariant (specs and page numbers).
3. **UI strings: a Lang-indexed table in Haskell** (tiny, stays embedded).
   Every learner-visible literal in site/app/View/** and Main.hs moves to the
   table (EN + JA). describeSpec gains a JA renderer. ARIA labels and
   aria-live text localize too (a11y parity is part of the gate). DOM ids,
   classes, wire formats, storage keys: NEVER localized.
4. **Language selection: `uiLang` joins the prefs blob** (SXC1PREFS — the
   regenerable codec; bump its schema per its own migration rules). Visible
   JA/EN toggle in the header (styled like the JA-first toggle). Defaults:
   uiLang=en; switching uiLang to ja ALSO flips jaFirst reading default on
   first switch only (a suggestion, not a lock — the two prefs stay
   independently settable). The browser fixture mirrors the toggle.
5. **Translation direction and ground truth.** Course text was authored in
   English citing the EN translations; the DEVICE facts originate in the
   Japanese manuals. JA course text is authored EN→JA but TERMINOLOGY is
   grounded in the ORIGINAL Japanese manual pages (manuals/text/<slug>/,
   local OCR of the source PDFs) and translations/glossary.md (the EN↔JA
   term map from Phase 1). QA verifies every deck's JA terminology against
   the original pages its exercises cite. On-device labels (BANK, EDIT, FX1,
   REC...) stay in Latin caps as the hardware prints them.
6. **Size budget.** The frozen WASM_GZIP_CEILING_BYTES=1000000 is untouched
   and keeps applying to app.wasm. Content bundles get their OWN ledger line
   and ceiling: 300,000 gzip bytes combined (en+ja), asserted by check-site.
   A new briefs/M6-budget.json records the externalization re-baseline with
   pinned constants in check-site.sh (the M5-R1-2 pattern).
7. **Floors carried into M6:** check-site 99/99 result=complete (grows with
   new checks; TOTAL pin updated per addition); browser stages ≥175; sweep
   37 exact + additions; exercise-check 382/382 + JA groups; content-check
   412/412; progress/registry unchanged. Every new check red-first. The
   D-suite and progress machinery must pass UNDER BOTH LANGUAGES where they
   assert learner-visible text (assertions parameterize by language rather
   than duplicating).

## Waves

- **W1 — externalization + bilingual format.** Reader accepts ja: fields
  (ignores them for EN bundle emission); build-site emits both bundles
  (ja bundle empty-falls-back-to-EN per field until wave 3 fills it); app
  fetches the bundle for the active language, boot-guarded; Embed.hs
  retires; harness/check-site sync (bundle ledger, fetch-failure check,
  D2-class absent-scenario parity). Size re-baseline + M6-budget.json.
- **W2 — UI localization.** String table (en/ja), uiLang pref + toggle,
  describeSpec-ja, ARIA/live-region localization, browser assertions for the
  toggle + a JA-rendered quiz/drill/device flow, fixture mirror.
- **W3 — course translation.** Workflow fan-out: per-deck EN→JA translation
  agents (glossary + cited original pages in context) piped into per-deck QA
  verifiers (terminology vs original manual pages; field completeness;
  device-label preservation; no id/count/verify/cite drift), loop-until-dry
  on QA rejects. Output: ja: fields written into the 52 deck files.
  JA-completeness enforcement flips from report-only to hard.
- **W4 — integration + docs.** Full-suite runs in both languages; README
  (bilingual landing paragraph; JA section for the friend); protocol doc
  note; PLAN.md status.
- **Gate:** Codex rounds (round 1 scoped to W1-W4 + whole-tree JA claims),
  then tag m6, deploy both hosts, live-verify EN+JA flows, ping owner.
