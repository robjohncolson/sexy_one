# QA notes — SXC-1 OSS License Notices (oss.md)

QA date: 2026-08-06. Source: /home/mrcolson/repos/casio-sxc1/translations/work/oss/pages-01-16.md (single chunk covering all 16 pages).

## Merge and structure

- All 16 pages were delivered in one chunk; no gaps, no missing page markers. Markers `<!-- page 1 -->` through `<!-- page 16 -->` each appear exactly once and in order in the merged document.
- Added the H1 title "SXC-1: About OSS (Open-Source Software)", a provenance blockquote, and the translation date, matching the style of midi.md.
- Removed the repeated per-page running header `# About OSS (Open-Source Software)` (it is the page-top banner in the PDF, repeated on every page). It survives once as the document title.
- Removed the per-chunk `<!-- translator notes -->` block from the merged document (resolved below).

## Verification performed

- Pages spot-checked directly against page images: 1, 2, 4, 11, 12, 15, 16 (seven pages, chosen for the software list, the repaired hyphenations, the numbered/lettered procedure lists, and the French-language sections).
- In addition, a word-level automated diff of the full merged document against the extracted source text (all 16 pages) was run. The only differences were (a) the translated Japanese intro sentence and running header, and (b) the extraction artifacts intentionally repaired by the translator (listed below). Content is otherwise verbatim and complete; no omissions found.
- List numbering across the BSD-3-Clause sections intentionally differs: tinycrypt and fsp use dash bullets while the NXP SDK section uses "1. 2. 3." — this matches the original PDF (pages 9–10) and was left as is.
- No sentences are split across chunk boundaries (single chunk); page-boundary continuations inside the chunk (e.g. Microsoft license list items 2.c.iii → iv across pages 12–13, section 13 continuing onto page 15) were checked and read correctly.

## Translator notes from the chunk — resolution

All four notes were checked against the page images and CONFIRMED; no action needed beyond keeping them on record:

1. Japanese framing translated (page header and the page-1 intro sentence). Confirmed correct against page 1; all other content is reproduced verbatim from the original.
2. Extraction-artifact repairs confirmed against images:
   - Drop-cap-style split letters in the Microsoft license ("G eneral" → "General", "C ontributions" → "Contributions", "H IGH RISK" → "HIGH RISK", "L e logiciel" → "Le logiciel", etc.) — the images show normal unspaced words.
   - "royaltyfree" → "royalty-free" (pages 2 and 6). Page 2 image confirms the hyphen: section 3 prints "royalty-free," mid-line; section 2 breaks as "royalty-/free" at a line end. Repair is correct.
   - "LICENSEDHARDWARE.txt" → "LICENSED-HARDWARE.txt" (page 12). Image shows "LICENSED-HARDWARE.txt" (first occurrence hyphenated at a line break, second occurrence printed intact mid-line). Repair is correct.
3. Source oddities preserved verbatim — all confirmed present in the printed original and correctly left untouched:
   - "Threadx,FileX,USBX,6.4.0" (no spaces; lowercase x in "Threadx") — page 11.
   - "For details,visit" (missing space) — page 11.
   - "You may (I) install" (capital I where "(i)" is expected) — page 11.
   - MIT license ends "...DEALINGS IN THE SOFTWARE" with no final period — page 11.
   - French "« tel quel." missing its closing guillemet, and "La ou elles sont permises par le droit locale" (Microsoft's own typos for "Là où" / "droit local") — page 15.
4. Curly quotes in the source were normalized to straight quotes in the Markdown edition; wording unchanged. Accepted as an editorial convention (consistent with the other translated manuals).

## Fixes applied during QA

- None to the translation text itself — the chunk survived all spot checks and the full-document diff. Changes were limited to structure: front matter added, running headers deduplicated, translator-notes block removed.

## Glossary

- No conflicts: this document is almost entirely verbatim English/French license text; the only translated Japanese (title/header and intro sentence) has no entries in the glossary, so nothing to enforce.
- Proposed glossary addition (glossary NOT edited, per instructions): add "OSS（オープンソースソフトウェア）について → About OSS (Open-Source Software)" so the Guide Book / Startup Guide translators render any cross-reference to this document identically.

## Open questions

- None blocking. One style question for the maintainer: the document title here follows midi.md ("SXC-1: About OSS (Open-Source Software)"); if a literal rendering of the distributed file name is preferred ("SXC-1 OSS License Notices"), only the H1 needs changing.
