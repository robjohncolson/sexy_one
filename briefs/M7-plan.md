# M7 — Japanese manual text (coordinator plan, 2026-08-09)

Owner report, 2026-08-08: on `#/m/guide-book/p/2/ja` the chrome is Japanese but
the page body is English. Correct diagnosis: `/ja` renders Casio's original page
as an IMAGE beside the English translation TEXT (View/Pages.hs `jaPanelEl` /
`pageBodyEl`). A Japanese reader therefore gets a picture they cannot select,
search, copy or reflow, with English as the only real text. M7 ships the
manuals' Japanese TEXT so the reader is first-class in both languages.

## Ground truth we already hold

- `manuals/text/<slug>/page-NN.txt` and `.layout.txt` — OCR of every page of all
  four documents, extracted in Phase 1 (guide-book 71pp/231KB, startup-guide
  15pp/59KB, midi 6pp/17KB, oss 16pp/88KB = 108 pages, 396KB raw). Gitignored,
  never shipped. Spot-checked clean and well-formed; `.layout.txt` preserves
  spatial layout (columns, table shape), which is what makes structural
  reconstruction possible.
- `site/static/pages/<slug>/page-NN.webp` — the authoritative page images, all
  108 present and shipped. Converted to PNG in the session scratchpad so
  authoring/QA agents can read them directly.
- `translations/<slug>.md` — the EN translation, one `<!-- page N -->` marker per
  page (71/15/6/16, exact), already the reader's block structure.

## Architecture rulings (gate-reviewable)

1. **Manual text externalizes, exactly as the course did in M6.** The four EN
   translations are TH-embedded (`SXC1.Content.Corpus`, 193,460 raw bytes).
   Adding ~396KB of Japanese would add roughly 137K gzip against 112,268 bytes
   of headroom — it does not fit. Manual text therefore moves OUT of the wasm
   into per-language fetched bundles (`manuals.en.txt` / `manuals.ja.txt`)
   under the SAME acceptance discipline M6's gate forced for the course: a
   manifest COMPILED INTO THE WASM (doc slugs in order, per-doc page counts,
   per-language whole-bundle fingerprint), header-language match, every
   document must parse, all-or-nothing acceptance, visible degraded state on
   any failure. Reuse `Exercises/Manifest.hs`'s generator and `Bundle.hs`'s
   validation rather than writing a second mechanism. Expected: the wasm SHEDS
   ~67K gzip, so Japanese manual text costs the binary nothing.
2. **`translations/<slug>.ja.md`: one parallel file per document, page-for-page.**
   Identical `<!-- page N -->` markers and the same block structure as the EN
   file (heading levels, list shapes, table shapes, figure callouts) so the
   existing Blocks renderer renders either language with no per-language
   branches. Only the text differs. This makes structural equality a checkable
   invariant, not a hope.
3. **The Japanese text is TRANSCRIBED, not translated.** Ground truth is the
   page IMAGE; the OCR is a draft to be corrected against it. Authors reproduce
   what Casio printed — including on-device labels in Latin caps, the
   documented on-screen misspelling `LOW STRAGE SPACE`, and figure callouts
   rendered in the EN file's `*[Figure: ...]*` convention but describing the
   figure in Japanese. Never re-translate the English back into Japanese: the
   original wording exists and is authoritative.
4. **Reader behaviour.** With `uiLang=ja` the manual body renders the Japanese
   text; the original page image stays available exactly as today (the `/ja`
   route and the JA-first ordering preference are unchanged in meaning — the
   image is still the scan, the body is now Japanese text). With `uiLang=en`
   nothing changes. A missing JA page must degrade to the EN text with a
   visible, localized note — never a blank page.
5. **Enforcement.** A checker mode compares EN and JA documents structurally:
   same page markers in the same order, same per-page block-type sequence,
   same heading levels, same table shapes. A JA page whose structure diverges,
   or is missing while its EN page exists, is a hard issue (the `E-JA-MISSING`
   precedent, one milestone on). Plus a browser assertion pinning real Japanese
   manual text on a real route in both stages, red-tested against an EN-fallback
   bundle.
6. **Budget.** Frozen `WASM_GZIP_CEILING_BYTES=1000000` untouched. The content
   bundle ceiling (currently `M6_BUNDLE_CEILING=300000`, holding 167,732) must
   rise to cover manual bundles — a visible check-site.sh edit with recorded
   arithmetic in `briefs/M7-budget.json`, pinned constants, and the file
   required to MATCH the pins (the M5-R1-2 / M6 pattern).

## Status (2026-08-09)

**W1 COMPLETE** (commit 078d294) — **W2 COMPLETE** (commit 05c2061, all 108 pages
transcribed and QA-accepted) — **W3 COMPLETE**: enforcement, browser assertions,
ledgers and docs landed; gate pending. Measured at W3's close: `check-site`
**129/129 result=complete**, zero skips; **242/242** assertions in each full browser
stage; `exercise-check --manual-structural-diff` **109/109** with three negative
controls; the manual-language-of-record stage **5/5** (MF1-MF5) now asserting the
EN-fallback note's ABSENCE; four ID-pinned `ja manual:` assertions (JAM1-JAM4) in both
stages; `app.wasm` 838,748 gzip of 1,000,000; manual bundles 118,033 of 250,000 and
all four fetched bundles 285,765 of 550,000. Remaining: gate → tag `m7` → deploy →
live-verify.

## Waves

- **W1 — externalize manual text** (code): manuals move to fetched per-language
  bundles under M6's manifest/fingerprint discipline; JA falls back to EN
  per-document until W2 lands; reader wiring per ruling 4; budget re-baseline.
- **W2 — author the Japanese text** (content, 108 pages): per-page agents
  reconstruct `translations/<slug>.ja.md` from the page IMAGE + both OCR
  variants + the EN page as structural template; per-page independent QA
  against the image (transcription fidelity, structural equality, device-label
  and on-screen-string fidelity, no back-translation). Loop until every page
  is ACCEPTED — a null verdict counts as UNVERIFIED, never as a pass.
- **W3 — enforcement + integration**: structural EN/JA document diff as a hard
  check, browser assertions in both stages, docs, both-language floors.
- **Gate** → tag `m7` → deploy both hosts → live-verify Japanese manual text.

## Discipline carried forward (hard-won)

Enumerate work lists from the filesystem, never by hand. A null agent result is
UNVERIFIED, never accepted. Every new check red-first. All verification
foreground with bounded timeouts. Ownership boundaries per wave, disjoint.
