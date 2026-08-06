# QA notes — SXC-1 MIDI implementation (English translation)

QA pass date: 2026-08-06. Source: SXC-1_MIDI_JA.pdf (6 pages). Merged document: `translations/midi.md`.

## Coverage and structure

- A single chunk (`work/midi/pages-01-06.md`) covered all 6 pages; no gaps needed retranslation.
- Page markers 1–6 verified present exactly once each, in order.
- All 6 pages spot-checked against the page images (`manuals/pages/midi/page-01.png`–`page-06.png`) and the extracted JA text. Tables on pages 2, 3, 4, and 5 were checked cell by cell.

## Edits made during QA (merge and consistency fixes)

1. **Title block**: The chunk opened with two H1s ("SXC-1" and "About the MIDI implementation"). Merged into a single H1 "SXC-1: About the MIDI implementation" with the provenance note, to avoid duplicated headers. The document's own version line ("Version 1.2", "2026.7.29") is retained under the page-1 marker.
2. **Glossary enforcement — 送信/受信 column headers**: The chunk used the MIDI-industry chart headings "Transmitted"/"Recognized" for 送信/受信 in the section 3 and section 4 tables. The binding glossary specifies 送信 = "transmit", 受信 = "receive" (explicitly noted for the MIDI chart context), so the headers were changed to "Transmit"/"Receive". See "Proposed glossary changes" below.
3. **MIDI chart, Basic channel row**: 設定可能 was rendered "Changes" in the chunk; changed to "Changed", the standard label used in MIDI 1.0 implementation charts (paired with "Default").
4. Removed the per-chunk translator-notes section from the merged document (resolved items summarized here).

## Translator notes resolved by checking the images

All of the following source oddities were verified against the page images and are reproduced as printed (they are in the Japanese original, not translation errors):

- **Page 3, Bank Select C, Transmit column**: printed "0.127" (period) where sibling rows print "0,127" (comma). Confirmed in the image. Kept as printed; likely a typo in the original.
- **Page 3, Directional Left**: CC No. printed as 89, skipping 88. Confirmed in the image. Kept as printed; possibly a typo for 88.
- **Page 4, Pad 2 / Bank C**: printed 68, duplicating Pad 1's Bank C value (the sequence suggests 69). Confirmed in the image. Kept as printed.
- **Page 2, Unit firmware version**: printed with irregular spacing ("Ver.1.３.0", full-width 3). Normalization to "Ver.1.3.0" confirmed correct.
- **Page 3, rows ▶/■ through EDIT**: confirmed the source leaves the function-group cell blank for these rows (they form their own unlabeled block after "Directional"); the empty group cell in the translation mirrors the source layout. Note these are the buttons the glossary calls "function buttons" (機能ボタン), but the source itself prints no label here, so none was added.
- **Page 3, INPUT SWITCH row**: likewise has no group label in the source; empty group cell mirrors the layout.

## Open questions

- **Page 3, footnote \*1, FILTER**: 「2 目盛ずつ変化するイメージ」 is rendered "(imagine it changing in steps of 2 marks)". 目盛 is taken as the tick marks of the FILTER scale (received values 0–100 map to -100…+100, i.e. 2 units of the parameter scale per received step). The phrasing of this informal aside is interpretive; a reviewer with device access may want to confirm.
- **Page 4, note under the note-mapping table**: 「現在パッドを押した時と同じ動作をします」 is slightly irregular Japanese; rendered "these behave the same as pressing the current pad". The intended meaning appears to be that receiving notes 100–115 acts like physically pressing the corresponding pad in the current bank/mode (example given: 100 → Pad 1).
- The source typos listed above (0.127; CC 89 for Left; Pad 2/Bank C = 68) were reproduced faithfully. If the translation is ever meant to correct obvious source errata, these three are the candidates.

## Proposed glossary changes (glossary NOT edited)

- **送受信 entry**: The glossary mandates 送信 = "transmit", 受信 = "receive" for the MIDI chart. However, the canonical English column headings in MIDI 1.0 implementation charts (as standardized by the MMA/AMEI) are "Transmitted" and "Recognized". Consider changing the glossary note to allow "Transmitted"/"Recognized" for the chart column headers of sections 3 and 4, keeping "transmit/receive" for running text (e.g. "transmit/receive channels").
