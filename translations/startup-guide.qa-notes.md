# QA notes — SXC-1 Startup Guide (English translation)

QA pass date: August 6, 2026
Merged document: `translations/startup-guide.md`
Source chunks: `translations/work/startup-guide/pages-01-08.md`, `pages-09-15.md`

## Chunk coverage and structure

- Both expected chunks were present; together they cover pages 1–15 with no gaps or overlaps. No gap translation was needed.
- Page markers `<!-- page 1 -->` … `<!-- page 15 -->` verified: each appears exactly once and in order in the merged file.
- No sentences or sections were split across the page 8/9 chunk boundary (page 8 ends a complete procedure; page 9 starts a new banner section), so no seam-stitching of prose was needed.

## Fixes applied during merge

1. **Heading-level normalization across the chunk seam.** Chunk 1 used `##` for the gray banner page titles and `###` for underlined subheads; chunk 2 used `#` and `##` for the same visual levels. Chunk 2's headings were demoted one level throughout (banner titles → `##`, underlined subheads → `###`, "About FX1"/"About FX2" → `####`) so the whole document uses one hierarchy under the new document H1.
2. **Cover-page headings demoted.** The two `#` headings on page 1 ("Portable Standalone Sampler SXC-1", "Startup Guide") were demoted to `##` so the added document title is the only H1.
3. **Front matter added.** H1 title, provenance note (English translation of SXC-1_SUG_WB_JA.pdf, Japanese original by Casio, not reviewed by CASIO), and translation date (from `date`).
4. **"When you want to initialize (return to the factory default state)"** was `##` in chunk 2 (peer of the Troubleshooting banner); in the original (page 13 image) it is an underlined subhead on the Troubleshooting page, so it was placed at `###` under "Troubleshooting".
5. **Per-chunk `<!-- translator notes -->` sections removed** from the merged document; their content is resolved or carried forward below.
6. No duplicated headers and no inconsistent list numbering were found; ordered procedures (pages 6, 8, 9, 11, 12, 13) restart at 1 per procedure, matching the original.

## Terminology / glossary check

Checked the merged document against `translations/glossary.md`. No violations found; the chunks already agreed with the glossary and with each other. Points verified:

- On-device and on-screen labels kept verbatim (`INPUT VOL`, `MAIN VOL`, `SELECT BANK`, `SEQUENCE SLCT`, `SOUND EDIT`, `AUTO TRIGGER`, `Beat Sync`, `APO Time`, `Initialize`, `DELETE SELECT PAD`, etc.), including the abbreviated on-screen spelling `SEQUENCE SLCT` (page 9), which is what the device displays.
- 登録する rendered "assign"/"save", never "register" (pages 4, 5, 7, 8, 11, 12).
- 十字ボタン = "directional buttons"; バンク選択ボタン = "bank select buttons"; パッド部 = "pads section"; 〜端子 split correctly as "jack" (PHONE/LINE OUT/AUDIO IN) vs "port" (DATA/POWER/DATA, USB) per glossary.
- ループ音源 / ワンショット音源 = "looped sound" / "one-shot sound" (page 7), paired with the `LOOP` / `ONE SHOT` buttons.
- Mode names: Performance mode, Sequence mode, REC mode, DEL mode, EDIT mode, Sampling mode, system settings, sequence settings — consistent between the page 5 overview table and pages 9–12.
- "USB AC adaptor" (Casio spelling), "eneloop", "AAA rechargeable nickel-metal hydride batteries", "included USB Type-C cable", "separately available" — all per glossary.
- Cross-references rendered "p. 9" / "(see …)" style per glossary rule 4's spacing convention.
- Headings are sentence case except on-device labels (rule 3).

No glossary changes are proposed.

## Spot-checks against page images (8 pages)

| Page | Content type | Result |
|---|---|---|
| 1 | Cover (title lockup, QR codes, barcode) | OK. "Portable Standalone Sampler" + SXC-1 logo, JA language box, three QR blocks and M001JP010 barcode all represented. |
| 4 | Names-of-parts table (10 rows), connection figure | OK. All rows, sub-bullets, and jack/port distinctions match the JA table; connection-example labels complete. |
| 5 | Operation overview mode map, function table, bank/sequence info box | OK. All nine screens in the mode map, all 10 table rows with page references (p. 9/10/11/12), and the bank/sequence definitions (80 banks, 50 sequences) match. |
| 7 | ONE SHOT/LOOP table, looped/one-shot definitions | OK. Table ON/OFF cells match JA exactly; pad-color mapping (orange/purple = looped, yellow/blue = one-shot) correct. |
| 9 | Dense sequencer procedures with 4 figure strips | OK. Long-press flow, cell fill (A) / delete (B), REC real-time entry, and ▶/■ + bank-button playback all faithful; BPM values in screen mock-ups (120 on creation, 95 elsewhere) match the image. |
| 11 | Two recording procedures (6 steps + 3 steps) | OK. INPUT SELECT positions (MIC / ♪ / USB), BANK 15 or later, auto-start on input, and both stop methods match. |
| 14 | Operating precautions, battery warning box, Auto Power Off, copyright, trademarks | OK and complete. Two-column layout linearized in a sensible order; both ⚠ boxes, backup note, and all four trademark bullets present. |
| 15 | Back cover | OK. Company name, date line (2026年5月作成 → "Created: May 2026"), MA2605-B, © line present. |

## Translator notes from chunks — resolutions

- **Page 2, "use of, or malfunction of, this manual or this unit"**: checked against JA; the compression is in the original (本書および本機の使用や故障により). The English pairing is acceptable and no more ambiguous than the JA. Resolved — kept.
- **Page 4, ONE SHOT "全音再生" → "full-sound playback"**: consistent with the page 7 behavior table ("plays the sound to the end"). Resolved — kept.
- **Page 5 mode-map arrows**: verified against the page 5 image; the transcribed transitions (A confirms sequence selection → Sequence mode; long-press A–D while selected toggles back; EDIT ↔ sequence settings; long-press EDIT ↔ system settings; REC/DEL/EDIT from Performance mode) match the printed arrows. Resolved.
- **Page 5, ● ▲ ■ bank symbols**: confirmed these are printed placeholders in the JA figure. Resolved — kept as printed.
- **Page 5, missing period after 取り込みます in the REC-mode row**: confirmed in the image; normalizing with a period in English is correct. Resolved.
- **Page 1, "JA" boxed marker**: confirmed on the cover image. Resolved — kept as printed.
- **Page 9, `SEQUENCE SLCT`**: confirmed on-screen spelling in the image. Resolved — kept verbatim per glossary rule 2.
- **Page 11, AUDIO IN jack vs USB port**: confirmed against image and glossary 〜端子 rule. Resolved.
- **Page 12, "speed" with no on-screen label**: confirmed; the JA intro lists スピードやピッチ（音の高さ）、音量 while the EDIT screen shows only `PITCH`/`VOLUME`/`GROUP`/`COLOR` (start/end editing via FX1/FX2 dials covers the "speed"/length aspect). Rendering "speed" as plain text is correct. Resolved.
- **Page 14, first ⚠ box rendered as "Warning:"**: confirmed the box uses the ⚠ icon in the image; keeping **Warning:** matches the icon. Resolved — kept.

## Open questions (carried forward)

1. **Page 15 company address**: the JA page prints only the Japanese address (〒151-8543 東京都渋谷区本町1-6-2). The English "1-6-2, Hon-machi, Shibuya-ku, Tokyo 151-8543, Japan" follows CASIO's usual English back-cover convention but does not appear in the source. Confirm the preferred form (or whether to keep the Japanese address verbatim) before publication.
2. **"Created: May 2026" (2026年5月作成)**: some CASIO English manuals use "Issued". Exact CASIO English convention for this line is unverified; confirm house style.
3. **Cover QR-code URLs** (`…/10917ja/`, `…/10924ja/`) are the Japanese-audience links from the original. If an English edition of the User's Guide / tutorial videos exists, consider whether the translation should point to the English URLs instead; left as printed for fidelity.
4. **Page 13, step 3 "Select the A button."**: JA reads「A ボタンを選びます」(literally "select"), although the parallel dialog on page 12 says 押します ("press"). Kept the literal "Select"; confirm whether to normalize to "Press the A button." for consistency.
