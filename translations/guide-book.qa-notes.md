# QA notes — SXC-1 Guide Book (English translation)

QA/merge pass performed 2026-08-06. Source chunks: `translations/work/guide-book/pages-*.md` (9 chunks, pages 1–71). Merged output: `translations/guide-book.md`.

## Verification summary

- All 9 expected chunk files were present; no gaps needed retranslation.
- Page markers `<!-- page 1 -->` … `<!-- page 71 -->` each appear exactly once, in order, in the merged file (verified programmatically).
- Spot-checked 12 pages against the original page images: 3, 4, 5, 6 (safety icons), 10 (names-of-parts table), 16 (bank diagram), 17 (BANK1 pad map), 21 (ONE SHOT/LOOP tables and timing diagrams), 38 (measure-count procedure with magnified screens), 55 (system settings), 65 (error message table), 66 (product specifications). Content was faithful and complete on all of them; discrepancies found and handled are listed below.
- Page 9 was additionally cross-checked against the extracted JA text (`manuals/text/guide-book/page-09.txt`).

## Fixes applied during merge

### Chunk seams and structure

1. **Running headers normalized.** The nine chunks used five different formats for page-top running headers and side tabs (bold + em-dash, `*(Page header: …)*`, `**…** | *…*`, etc.). All normalized to a single italic line, e.g. `*Finger drumming along with a looped sound — PART 1: Part: Pad play*`, `*Troubleshooting — Appendix*`.
2. **Section-title harmonization across chunks** (same Japanese running title, two English renderings):
   - "Finger drumming along with looped sounds" (pages 17–24) → **"Finger drumming along with a looped sound"** (form used on the p. 15 section opener and in pages 16/25).
   - "Create an original drum pattern" (pages 41–44) → **"Let's make an original drum pattern"** (form used on pages 36–40). Verified via the p. 38 image that both render the same JA header オリジナルのドラムパターンを作ろう.
   - Cross-references on pp. 15–16 to the p. 17 section changed from "Tap the pads to make sound" → **"Tap the pads to make sounds"** to match the actual p. 17 heading.
   - p. 49 page title "Let's process and edit samples (continued)" → **"Try processing and editing samples (continued)"** to match the p. 48 title it continues.
3. **Chapter openers unified** to one H1: `# PART 3 — Part: Sequencer` and `# PART 4 — Part: Leveling up` (were split double-H1s, unlike PART 0/1/2).
4. **Duplicated H1 removed at the p. 8/9 seam:** page 9 repeated `# Operating precautions` (first used on p. 7); changed to the italic continuation header used on p. 8.
5. **Heading levels repaired at seams:**
   - p. 49 `## ▶COLOR` / `## ▶BPM` → `###`, matching the `### ▶PITCH/VOLUME/GROUP` series that starts on p. 48; `# Waveform editing` → `##`.
   - p. 65 `## No sound is recorded` → `###`, matching the other symptom headings under "If these symptoms occur" (pp. 63–64). "Error message list" kept at `##` (it is a full section header in the source layout).
6. **Stray printed page-number lines** ("Page 33" … "Page 40") left in by the 33–40 chunk were removed.
7. **List numbering checked:** the step sequences that span page boundaries (pads-play steps 1–7 across pp. 15→19→20→23; sampling steps 1–7 across pp. 28→29→30→31) continue correctly; no renumbering was needed.
8. **Per-chunk translator-notes sections removed** from the merged document (collected here instead).
9. `"Connections" on p. 08` → `p. 8` (style consistency); the referenced section title matches the p. 8 heading.

### Safety-label consistency (pages 3–6, 9)

The source marks safety items with icons (red prohibition circle, blue filled "must do" circle, yellow warning triangle), not text labels. The chunk had assigned arbitrary `**Warning:**/**Important:**/**Caution:**` prefixes, including "Warning" items inside the ⚠ Caution section. After checking the page images for every item on pp. 3–6, all blockquote prefixes were relabeled by icon:

- prohibition circle → **Prohibited:**
- blue filled circle → **Required:**
- yellow triangle → **Caution:**

The symbol legend on p. 3 now states this mapping. The two composite blocks whose bulleted lists carry mixed per-bullet icons (p. 5 "Batteries" and p. 5 "USB cable" under ⚠ Caution) are left as unlabeled bold-lead blockquotes. The two boxed notes on p. 9 (no severity icon in the source) were relabeled **Note:** (Auto Power Off) and **Caution:** (battery explosion precautions).

### Glossary/terminology enforcement

- Swept the merged document for banned/off-glossary forms: no occurrences of "register" (for 登録する), "this machine", "adapter" (Casio spelling "adaptor" used throughout), or d-pad. On-device labels, screen text, and Part titles conform to the glossary.
- Error messages made verbatim per glossary, including fullwidth `！` (`SAMPLING ERROR！`, `SAMPLING ALERT！`) and the on-screen misspelling `LOW STRAGE SPACE` (kept; confirmed against the p. 65 image).
- "AAA alkaline batteries", "AAA rechargeable nickel-metal hydride batteries (eneloop)", "USB AC adaptor", "Auto Power Off", "Beat Sync", "CASIO Sampler App", "assign" — all conform.
- p. 9 "not included with this product": JA prints 商品に付属しておりません (商品, not 本機), so "this product" is correct here; left as is.

## Translator-note items resolved by image check

- **p. 9 unreadable page refs ("p.``")** — the chunk's readings (p. 55 for battery/APO settings, p. 60 for backup) are consistent with the actual p. 55 system-settings page (BATTERY Type, APO Time) and the p. 60 backup section. Accepted.
- **p. 19 starting at step 3** — steps 1–2 are on p. 15 as suspected; numbering is continuous. No action needed.
- **p. 66 "AD-XJ06J Type-C"** — confirmed against the page image: the printed spec table really says **AD-XJ06J**, while pp. 8/12 and the p. 70 index say **AD-XA06J** (the glossary's model). This is almost certainly an erratum in the Japanese original; both kept as printed, per translation policy.
- **p. 65 `LOW STRAGE SPACE`** — confirmed printed that way; kept verbatim.
- **Safety-icon mapping (pp. 3–6)** — resolved as described above.
- **p. 17 callout "Rhythm from 13/14 without the drums"** — confirmed against the image (「13・14からドラムを抜いたリズム」); rendering accurate.
- **p. 38 magnified-screen descriptions** — checked against the image; the described cursor/measure-marker operations match.
- **付録 = "Appendix"** — used only in the appendix chunk; consistent throughout the merged document.

## Open issues / judgment calls left in place

1. **CASIO Sampler App UI strings** (pp. 42, 56–60): labels such as "Assign Sound", "Select from file", "Duplicate to next measure", "Sequence Management", "Unit Settings", "Disable measure" are translated from the Japanese screenshots. If an English-localized release of the app exists, its official strings should be substituted.
2. **Source erratum:** p. 66 options list prints "AD-XJ06J Type-C" vs. "AD-XA06J Type-C" everywhere else. Kept as printed in both places; consider a translator's footnote if the document will be published.
3. **Onomatopoeia renderings** are judgment calls: voice-percussion syllables "Den-tak" / "Don" / "Chh" (デン・タク／ドン／チッ, pp. 30–31), metronome clicks rendered descriptively as "Ki, ko, ko, ko" (p. 39), and the p. 48 pitch-gag transliteration "Deh~so~ta~ku~".
4. **p. 26 finger-to-pad mapping** (kick = pad 1/thumb, etc.) is inferred from small numbered icons in the figure; could not be confirmed at available image resolution.
5. **p. 49 BPM setting**: "long-press the **left** button to set the BPM to ---" — the button icon in the source is small; "left directional button" is the best reading.
6. **p. 69 index entry** 機能一覧 → "Function list", pointing to p. 11, whose actual heading is "Operation overview" (操作一覧). Left as printed in the source index rather than harmonized.
7. **Index ordering** (pp. 69–70) follows the Japanese syllabary with kana-row group headings retained (noted inline in the document). An English edition might prefer re-sorting alphabetically.
8. **Cover taglines (p. 1)** are idiomatic marketing renderings and intentionally differ in wording from the chapter-opener taglines (e.g. p. 1 "Hot beats pour from your fingertips!" vs. p. 14 "Beats pour out of your fingers!"); the JA texts also differ slightly.

## Proposed glossary additions (glossary NOT edited)

- 登録済エリア → **preset area** (p. 16 bank diagram; pairs with the existing ユーザーエリア = "user area").
- 付録 → **Appendix** (recurring appendix side tab, pp. 62–70).
- 始点／終点 (waveform editing) → **start point / end point** (pp. 49, 53, 59).
- Consider noting in the glossary that on-screen error messages print a fullwidth ！ (already implied by the `SAMPLING ERROR！` example) and that the p. 66 spec table prints the adaptor model as "AD-XJ06J Type-C" (source erratum vs. AD-XA06J).
