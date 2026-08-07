# M5 Content Audit — SXC-1 Trainer

Audit date: 2026-08-06. Ground truth: `translations/guide-book.md`, `translations/startup-guide.md`, `translations/midi.md` (+ `midi.qa-notes.md`); `oss.md` verified as license-text-only. Corpus: 52 decks in `content/exercises/`, 435 live exercises, `content/id-registry.tsv`, `content/exercises/INDEX`, `content/exercise-inventory.md`.

## 1. Coverage table

| Chapter | Manual topics | Covered | Major gaps | Minor gaps | Optional gaps |
|---|---|---|---|---|---|
| Front matter (ch0) | 67 | 57 | 0 | 5 | 5 |
| Preparation (ch1) | 15 | 14 | 0 | 1 | 0 |
| Pad play (ch2) | 45 | 42 | 0 | 1* | 2 |
| Sampling (ch3) | 29 | 29 | 0 | 0 | 0 |
| Sequencer (ch4) | 32 | 32 | 0 | 0 | 0 |
| Leveling up (ch5) | 47 | 46 | 0 | 0 | 1 |
| **Total** | **235** | **220** | **0** | **7 → 6 after re-rank** | **8 → 9 after re-rank** |

\* The ch2 minor gap (FX1 MASTER PAN) is downgraded to optional in section 2; the corpus-wide totals above reflect the sweeps as submitted, the re-ranked totals follow.

## 2. Consolidated gaps (re-ranked)

**No chapter sweep produced a major gap.** After skeptical re-ranking, the retained minor gaps are below, ordered by priority. Downgrade applied: the FX1 MASTER PAN gap — an owner turning the FX1 dial sees the fifth effect within seconds, so the *gap* is optional (the stale q-2-48 assertion remains a defect, section 3).

### Minor (fix soon; none block ship on their own — but see verdict on G1)

- **G1. Connect USB only with power off (ch1).** The chapter's core procedure omits the manual's mandated safety step. Ref: guide-book p.8 "When connecting a USB cable to this unit, always connect it with the unit's power turned off." Fix: add a quiz to prep-02 or a preliminary step to drill d-1-01 confirming the switch is at [OFF] before connecting. *Paired with defect D2 — fix together.*
- **G2. Copyright precaution (ch0).** Preset content usable as material but not redistributable as-is; sampling copyrighted works limited to personal/household use. Ref: guide-book p.68 (also startup-guide p.14). Directly relevant to a sampler user and not discoverable by poking. Fix: one quiz on permitted vs. prohibited uses.
- **G3. Sampling spec: 48 kHz / 16-bit WAV stereo, 15-minute max (~173 MB) (ch0).** Ref: guide-book p.66. The 15-minute ceiling is a real usage limit; also corrects defect D5's rationale. Fix: one quiz off the spec table.
- **G4. Max polyphony: 16 notes; 4/8 with Beat Sync; 10 with an effect ON (ch0).** Ref: guide-book p.66. Affects real playing and is hard to diagnose by ear. Fix: one quiz ("Beat Sync ON — how many stretched notes?").
- **G5. Caution-level USB-cable handling rules (ch0).** Ref: guide-book p.5. Safety text never surfaced; distinguish from the Warning-level rules in l-0-05. Fix: one lookup.
- **G6. eneloop charging rules and battery-drain factors (ch0).** Ref: guide-book p.9. Cannot charge in-unit; drain factors; shutoff without REPLACE THE BATTERY warning. Fix: one quiz + one lookup.

Note: the p.66 Product specifications table is the one systematic hole — no exercise in the entire course touches it (verified by grep). G3 and G4 close the two consequential rows; the rest of the table stays optional.

### Optional (post-ship backlog)

FX1 MASTER PAN firmware note (midi.md v1.2/FW 1.3.0 — downgraded from minor; owner-discoverable); included accessories; QR-code companion resources; remaining Caution groups (connector/headphones/gaps); 64 GB storage size; physical/electrical spec row; pad tap-technique tip (p.23); finger-drumming CREATIVE NOTE (p.26); post-resampling REC-unlit/ONE-SHOT-lit state (p.51 — pairs with defect D8); quizzing the MIDI chart negatives (no Clock/velocity/Program Change — currently lookup-only, l-5-15).

## 3. Overreach and citation defects (all require correction)

Ordered worst-first. D1–D8 assert things the manuals contradict or plainly fail to support; D9–D12 are milder unsupported embellishments and one citation-scope miss.

| # | Exercise (file) | Defect | Fix |
|---|---|---|---|
| D1 | q-5-62 (`content/exercises/094-lvl-11.ex.md`) | Why text says POWER/DATA "is for power"; guide-book p.10 defines it as power **and** smartphone data/MIDI/audio, and p.13 allows smartphone communication via it. "Most common reason the app sees nothing" also unsupported. | Rewrite rationale to match p.10 definition; drop the frequency claim. |
| D2 | d-1-01 (`content/exercises/018-prep-02.ex.md`) | Step check "the display stays dark: connecting cables alone does not turn this unit on" is unsupported and conditionally false (switch left at [ON] boots the unit); step never verifies switch is OFF (p.8 precaution). | Add confirm-OFF step; reword the check. Closes gap G1. |
| D3 | q-3-21 (`content/exercises/048-smp-04.ex.md`) | Why text: "Nothing stops it automatically" — contradicted by the 15-minute recording cap (p.66) and storage-error interrupts (p.65). | Rewrite rationale; optionally cross-cite the 15-minute limit (gap G3). |
| D4 | q-3-24 (`content/exercises/048-smp-04.ex.md`) | Why text implies direct re-record onto an assigned pad; Sampling mode flashes only empty pads (p.29) and deletion (p.32) is the documented path. | Rewrite rationale around delete-then-resample. |
| D5 | q-5-28 (`content/exercises/084-lvl-06.ex.md`) | Why text: "the copy loops again on the destination pad" — p.51 figure shows ONE SHOT lit / REC unlit at resampling end, implying a ONE SHOT result. | Correct rationale; optionally add the backlog quiz on post-resampling button state. |
| D6 | q-2-48 (`content/exercises/036-pad-07.ex.md` area) | "Which four effect types does FX1 provide?" — true per guide-book p.25, false on FW 1.3.0+ (midi.md documents MASTER PAN as a fifth FX1 selection). | Soften to "the four effects listed in the guide book" or add the firmware note. |
| D7 | l-0-05 (`content/exercises/002-ch0-02.ex.md`) | Lists the lightning item among the **Required** items of the USB-cable Warning group; guide-book p.3 marks it with the electric-shock glyph, not the Required symbol. | Correct the glyph classification in the prompt. |
| D8 | d-4-06 (`content/exercises/066-seq-06.ex.md`) | Check asserts "sounds like a four-on-the-floor dance beat"; the p.41 chart is an untranslated figure captioned only "8-beat dance pattern" — kick placement unverifiable. | Reword check to the caption's level of detail. |
| D9 | q-2-54 (`content/exercises/036-pad-07.ex.md` area) | Why text quantifies ROLL steps as "each step down doubles the hit rate"; p.25 says only "even finer / still finer". | Drop the doubling claim. |
| D10 | q-0-27 (`content/exercises/014-ch0-08.ex.md`) | Citation-scope mismatch: answer's Auto-Power-Off recovery claim is true (p.12, p.57) but not on the cited p.10. | Add a second cite to p.12 or trim the answer. |
| D11 | q-5-56 (`content/exercises/090-lvl-09.ex.md`) | Why text invents a purpose for BATTERY Type ("so the remaining-charge display reads correctly"); pp.9/55 state no purpose. | Hedge or remove the purpose claim. |
| D12 | d-5-16 (`content/exercises/098-lvl-13.ex.md`) | "Losslessly" fidelity claim for app cross-bank assignment has no manual support. | Remove "losslessly". |

All 12 are text edits to prompts/rationales/checks — no structural or deck-level rework needed.

## 4. Registry, index, and spread findings

- **Registry (`content/id-registry.tsv`): fully consistent.** 440 rows = 435 live (16 m2 + 419 m3) + 5 tombstones (q-1-14/15/16, q-3-05/06; all m2, promptCount 0). Sorted, no duplicate ids; live ids set-equal to the 435 ids on disk; all 440 rows set-equal to the inventory's 440 candidates; `briefs/M5-ship.md` "440 candidates" arithmetically exact. Total live promptCount 550. Wording nit only: the header's "first-shipped=m2 (16 rows)" counts live rows; 21 total rows carry m2 including tombstones.
- **INDEX: fully consistent** both directions (52/52 files, header counts match recount). No action.
- **Chapter 0 has zero drills** (39 quiz / 25 lookup). Documented as intentional (`content/exercise-inventory.md` line 135: front matter has no hands-on procedures); shipped spread matches the inventory candidate spread exactly. No action.
- **Zero flashcards corpus-wide** (0 of 435). The inventory's taxonomy names quiz/flashcard/drill/lookup but merges flashcards into the `q` prefix; every shipped q-id is `type: quiz`. Decide: either drop "flashcard" from the taxonomy docs or implement it post-ship. Tooling note: exercise files use `type:`, not `kind:` (grep `kind:` = 0 hits).
- **Type mix:** 69% quiz / 19% lookup / 13% drill overall; per-chapter quiz share 53–73% with no chapter deviating from its planned spread. Thinnest cells (ch3 lookup 6/55, ch1 total 30) match the inventory by design.
- **Sampling-design note:** the specified every-11th sampling scheme covers only 40 of 52 decks; the cross-checker supplemented with 12 deck-coverage fill-ins (52 exercises audited, all decks touched). Future audit specs should stratify by deck.

## 5. Verdict

**The course is shippable for M5 after a single small correction pass; no content gap blocks ship.** Coverage is 220/235 manual topics (94%) with zero major gaps; three of six chapters are at 100%, and every core operation across all five device parts has at least one exercise. Citation discipline is strong: 52 sampled exercises verified verbatim against their cited pages with zero broken cites and one scope mismatch, and the registry/index/inventory triangle reconciles exactly. What stands between the corpus and ship is the defect list in section 3, not the gap list in section 2: D1–D8 have shipped text asserting things the manuals contradict, and a trainer that teaches falsehoods about its own device fails its purpose regardless of coverage. All twelve are localized text edits — an hour or two of work — and I recommend gating M5 on D1–D8 (D9–D12 can ride along or follow). Of the gaps, only G1 is ship-adjacent, because the chapter's own drill (D2) currently walks a learner through the exact procedure the manual's safety precaution qualifies; fixing D2 closes it. G2–G6 and everything in the optional list belong in a post-ship backlog, with the p.66 spec table and the FW 1.3.0 MASTER PAN note as the first two backlog items.

**What this audit did NOT check (stated honestly):**

- **No physical device and no original-language manuals.** Ground truth is the English translations; translation fidelity, figure-only content (e.g., the p.41 pattern charts), and actual firmware behavior (including whether MASTER PAN really appears on the FX1 dial — inferred from midi.md, never observed) are unverified.
- **Citation verification was sampled, not exhaustive.** 52 of 435 exercises had cites checked verbatim (plus per-sweep spot-checks of out-of-chapter cites); roughly 380 exercises' cites rest on the sweeps' page-level review only.
- **Pedagogy was out of scope.** Difficulty progression, prompt clarity, distractor quality, cross-deck redundancy (noted but not deduplicated), and spaced-repetition sequencing were not evaluated — only topic coverage and factual grounding.
- **Answer-key correctness was not independently re-derived for every quiz**; only flagged or sampled items were checked against the manuals.
- **The runtime was not touched:** exercise schema validity against the app's parser, rendering, the Miso/WASM build, and GitHub Pages deployment are entirely unaudited here.
- **oss.md was classified as irrelevant license text** without verifying it matches the OSS actually bundled in the product or app.