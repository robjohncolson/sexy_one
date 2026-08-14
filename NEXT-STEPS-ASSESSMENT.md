# One Practice Loop

**Independent product assessment · SEXY ONE (SXC-1 Trainer) · 2026-08-15 JST**

A critique of the "Audacity Round Trip" candidate and a recommendation for M16, grounded in a full read of the shipped code, docs, and milestone history. Response to `docs/FABLE-NEXT-STEPS-PROMPT.md`.

---

## Verdict

**Audacity Round Trip is half right.** Its front half — a per-sample readiness check and a derived Audacity recipe — completes a contract the Sample Lab already half-ships: the verdict is computed at import but invisible until handoff, where it surfaces only as an anonymous count. Its back half — revision lineage, approval states, approval-aware handoff — is overbuilt for this product, and its final step already works for free: handoff row identity is `[slot, bank, pad, blobId]`, so swapping in an edited file re-queues exactly the affected pads today.

The most important unresolved problem is different from either half: **the app is authored as a fork, not a loop**. The home screen literally styles training as `wizard-yes` (green) and the Sample Lab as `wizard-no` (red). The two halves share zero data and zero cross-references; the course never teaches the 48kHz/16-bit spec the Lab enforces; loading a real pad — the strongest device evidence the app ever collects — counts for nothing in practice tracking.

**Recommendation: ship "Sound Check" as M16** — the trimmed round trip (check → recipe → linked re-import → one Use/Keep decision) plus a "Learn why" specification deck closing the G2 content debt. Keep the cross-storage Today's Session, Weekly Pulse, and fully sequenced-home integration together as M17 One Practice Home rather than hiding a partial bridge inside M16.

---

## Q1 — The most important unresolved user problem

The moment "make this sound ready for the device" belongs to neither half of the app. Concretely, for the practicing owner:

- **You learn a sound isn't ready at the worst possible moment.** Format facts are captured at import (`parseWav`, `analyzeAudio`), but the only validation the user ever sees is a non-blocking *count* of non-48/16 files, shown only on the handoff path — when you're standing next to the SXC-1 trying to load pads. No per-sample verdict exists anywhere.
- **Nothing tells you what to do about it.** The entire corrective guidance is one static string: "export 48 kHz / 16-bit PCM WAV from Audacity" — identical whether the file is 44.1kHz, 24-bit, clipped, or MP3.
- **Nothing teaches you why.** The 352-exercise course never mentions the 48kHz/16-bit sampling spec the Lab enforces. That content (G2–G6) was deferred in M5 and never picked up. A user who finishes the whole course has never learned why the Lab calls their file "raw".
- **Fixing it never counts as practice.** Marking a pad Loaded in the Phone Bridge — a verified real-device act — writes only to the handoff key. Weekly Pulse and the streak see nothing, while drill self-reports feed the scheduler.

In one line: *the app coaches you to study the sampler and helps you organize sounds, but abandons you at the exact junction where the two become one practice.* The `wizard-yes`/`wizard-no` home screen is that abandonment authored into the primary surface.

**The practice loop the whole app should serve:**

> **Learn → Prepare → Load → Play → Reflect ⟲**

Learn an operation → prepare your own sounds for it → load them onto the SXC-1 → play → reflect weekly on all of it as one practice. Every recommendation below is judged against this loop. Today, **Prepare** is silent and **Load** is uncounted.

## Q2 — Is Audacity Round Trip the right next milestone?

Right target, wrong scope. Scored step by step against what's actually shipped:

| Step | Status | Assessment |
|---|---|---|
| 1. Import raw sample | **shipped** | Dedup pipeline, single-flight queue, three entry points. Done since M14. |
| 2. Readiness check | **half-built** | Facts already captured at import; the missing part is a per-sample, on-demand *verdict*. Clipping/silence are net-new — do them as an exact PCM scan of WAV bytes only (no `decodeAudioData`, which resamples), advisory-only. |
| 3. Audacity recipe | **one string** | Exists as a single static hint. Deriving ordered steps from failing checks is hours of work with outsized value. |
| 4. Re-import as revision | **net-new** | Today an edited export re-imports as a stranger: new fingerprint, no link, pad assignments redone by hand. But the fix is one `replacesId` field plus metadata carry-over — not a lineage model. |
| 5. Preserve original | **mostly free** | Dedup already keeps both files; GC never collects referenced blobs. The original's record and metadata survive untouched. |
| 6. Use Revision / Keep Current | **worth building** | Keep it: one two-button decision that repoints pads is the app's signature grammar, and it's cheap. |
| 7. Handoff uses approved revision | **already works** | Row identity is `[slot, bank, pad, blobId]`: a blob swap resets exactly the changed pads to pending and preserves Loaded receipts — the correct semantics, shipped in M15. Verify with a regression; build nothing. |

Two structural objections stand even against the trimmed version. First, as scoped all seven steps live inside `sample-lab.js` and none touches the trainer — shipped as-is, the milestone deepens the disconnected half and widens the gap the owner named as the real problem. Second, a revision *approval state machine* is version control for an audience of one (the owner plus one named friend); this project's own history — the WebGL DAG cut in M8, 81 lookups cut in M11 — says that machinery gets deleted later. Both objections dissolve if the milestone is shaped as Q5 describes.

## Q3 — Three alternative and complementary directions

### 1. One Practice Home

Today's Session becomes the single front door. The planner's existing fill slot may draw one *lab card* from real Sample Lab state ("file three inbox sounds", "fix the flagged WAV in Bank B", "resume handoff at pad 7"); completing lab work writes a Weekly Pulse mark; the home fork becomes a sequenced loop. All plain-DOM work across seams that already exist (the planner and pulse projections are JS reading localStorage the Lab sits next to). The purest answer to the coherence ask.

### 2. Pad Practice

Drill templates bind to the active project's real layout: "Load Bank A, trigger pad 3 (rain-loop)" — generated from actual pad assignments, run in the existing drill runner with its Confirm/Skip contract, auto-verified over WebMIDI where hooks apply, scheduled by the same SM-2 fold. Practice ends on the physical device playing your own sounds — the deepest possible fusion, but it wants the Lab→trainer bridge that One Practice Home establishes first.

### 3. Phone Field Inbox

The phone becomes a capture device: record via `getUserMedia` straight into the Sample Inbox with provenance tagged at the moment of capture, then share the project back to desktop through the existing `.sxc1lab` path — the M15 bridge run in reverse. Honest about raw output (webm/opus, auto-staged "raw"), feeding directly into Sound Check. Real value, but browser-variance risk and no dependency pressure yet.

A fourth candidate — a "Device Truth" spec deck closing the deferred G2–G6 content — shouldn't stand alone; it ships *inside* M16 as the "Learn why" target.

## Q4 — Ranking

| Direction | User value | Complexity | Perf risk | Strategic |
|---|---|---|---|---|
| **Sound Check** (trimmed round trip + spec deck) | 5 | 3 | 2 | 5 |
| **One Practice Home** | 4 | 2 | 1 | 5 |
| **Pad Practice** | 4 | 4 | 2 | 5 |
| **Phone Field Inbox** | 3 | 3 | 3 | 3 |
| **Audacity Round Trip** (full, as written) | 3 | 5 | 3 | 2 |

Sequence: **M16 Sound Check → M17 One Practice Home (full) → M18 Pad Practice**. Sound Check first because it's the highest value-per-complexity item with no dependencies and its specification deck connects a real Lab finding to the course; One Practice Home then owns the complete cross-storage loop framing; Pad Practice is the payoff that needs both predecessors. Phone Field Inbox waits until the loop exists to feed. The full seven-step Round Trip is last on the board: everything unique to it beyond Sound Check is the part most likely to be cut later.

## Q5 — Recommended milestone: M16 "Sound Check"

The ideal end-to-end experience, under the two-button discipline throughout:

1. **Check.** On any pad or library card, one button — *Check readiness*. It runs locally, on demand, offline, and replaces itself in place with a verdict card: pass/fail per criterion (format, 48kHz, 16-bit, channels, duration and size against device limits, plus advisory clipping and leading/trailing silence). WAV header values are authoritative; clipping and silence come from an exact scan of the WAV's own PCM bytes — never from `decodeAudioData`, which resamples. Non-WAV formats get an honest "convert to WAV in Audacity first" instead of fabricated verdicts.
2. **Recipe.** If anything failed: *Copy Audacity recipe / Done*. The recipe lists only the failing checks as ordered, named Audacity 3.7.8 operations ("File → Export Audio", then WAV, Stereo, 48000 Hz, and Signed 16-bit PCM), localized EN/JA, copyable as plain text. Each finding carries a quiet "Learn why" link into a new spec deck — the deferred G2 content, authored in this milestone — citing the same manual pages the course cites. The check becomes the course's knowledge applied to your own sound.
3. **Round trip.** After editing in Audacity, *Import edited version* on the original ingests the export through the existing dedup pipeline, carries over name, source, tags, rights, notes, and BPM, and records a `replacesId` link. The check re-runs on the new file, then one decision — *Use this version / Keep current*. Use repoints every pad referencing the original across all projects; Keep changes nothing; the original is always recoverable.
4. **Handoff, already correct.** An existing handoff session now shows exactly the swapped pads as pending while untouched pads keep their Loaded receipts — behavior M15 already ships via blobId row identity. The milestone verifies this with regressions rather than building an approval layer.
5. **Prepare the loop.** The Learn why link and neutral Lab entry establish the vocabulary and route into the course without inventing a second progress model. M17 owns the complete loop: at most one Lab card in Today's Session, Weekly Pulse marks for Lab outcomes, and a sequenced home surface.

Explicitly cut: batch readiness sweeps, readiness scores or dashboards, in-browser auto-fix (duplicates Audacity), waveform diff views, revision approval states beyond the single Use/Keep decision, deep MP3/FLAC verdicts, any `.sxc1lab` schema change, and any wasm-side work.

## Q6 — Acceptance criteria

- **A1.** Analysis runs only on explicit *Check readiness* — no new eager work at import, no decode on library or pad open. It completes offline and never blocks the UI.
- **A2.** The verdict is per-criterion pass/fail. WAV headers are authoritative for format, rate, and depth; clipping/silence come from direct PCM scan of the WAV `data` chunk only; MP3/FLAC yield "convert to WAV" with no fabricated bit depth; `.cswp` and WAVs whose PCM `data` chunk exceeds 48 MB degrade honestly to header-only results.
- **A3.** The recipe contains only failing checks, as ordered Audacity operations, EN/JA, copyable; a ready sample produces no recipe. Every finding links to its spec-deck card, and the G2 spec deck ships in this milestone within existing bundle ceilings.
- **A4.** *Import edited version* ingests via the existing dedup pipeline, records `replacesId`, and carries the original's metadata; the original record and blob remain reachable from the new version's detail.
- **A5.** *Use this version* repoints every pad referencing the original across all projects in one action; *Keep current* changes nothing; no screen in the flow ever shows more than two primary buttons.
- **A6.** After Use, an existing handoff session marks exactly the affected pads pending, preserves Loaded elsewhere, and both the handoff share and `.sxc1lab` export carry the approved bytes under unchanged schema 1. Blob GC never collects any member of a `replacesId` chain still referenced.
- **A7.** The Sound Check's Learn why action opens the bilingual specification deck, and the home Lab entry has neutral forward-action framing rather than `wizard-no`. M17 owns Today's Session Lab cards, Weekly Pulse Lab marks, and the fully sequenced home loop.
- **A8.** `app.wasm` is byte-identical; `sample-lab.js` stays out of the first-load module graph and gains a gzip ceiling in `check-site.sh`; the full gate passes with new browser regressions covering check, recipe, re-import, Use/Keep, and handoff re-queue.

## Q7 — Overbuilding, overlooking, mis-sequencing

### Overbuilt in the proposal

- The revision approval state machine (steps 4–6 as written) — one link field and one two-button decision deliver the stated constraint ("preserve user files, make revisions recoverable") without a subsystem.
- Decode-based clipping/silence *verdicts* — post-resample analysis can't honestly verdict; exact PCM scan of WAVs or nothing.
- Step 7 in its entirety — already shipped; write a test, not a feature.

### Already overbuilt in the app

- The lookup exercise kind ships dead in `app.wasm` — engine, runner UI, i18n strings, zero live exercises — in a binary that only fits its frozen 1,000,000-byte ceiling via the wasm-opt pass the build script itself warns can miscompile (unoptimized builds: 1,098,157 gz, over ceiling). Excising it buys back real headroom and risk.
- Per-prompt timing is recorded in every event and surfaced nowhere.

### Overlooked

- **The JS island has no budget.** Every ceiling guards `app.wasm` and the bundles; `index.js` and `sample-lab.js` — where all M12–M16 growth lands — have no tripwire. One ledger line fixes this.
- The size-ledger projection model is stale: it still charges corpus growth against the wasm binary, but the corpus moved to external bundles in M6. Boot time is instrumented but ungated.
- Process debt: the design/adversarial-review pipeline and git tags stopped after M7; M9's physical-device acceptance is still open; PLAN.md still says 435 exercises/52 decks (reality: 352/50); the roadmap prompt was untracked until this assessment. Update PLAN.md, and — because Sound Check's risks are semantic (what is a replacement? what happens to receipts?) — run this milestone back through at least the Codex gate.

### Mis-sequenced

- Building revision machinery one milestone after M15 shipped the identity model it would collide with — settle the loop's semantics first, which Sound Check's trimmed shape does.
- Deepening the Sample Lab before wiring it to the course. Every Lab-only milestone from here widens the fork; Sound Check's specification deck is the smallest honest bridge, and M17 must complete the loop before another Lab-only milestone.

---

## Where the panel split, and the rulings

- The advocate wanted the full lean round trip; the skeptic wanted clipping/silence dropped entirely as "Audacity's home turf". **Ruling:** keep them for WAV via exact PCM scan — cheap, honest, and you otherwise discover clipping only through the device's speaker after loading — but advisory-only, never blocking.
- The skeptic argued the pad swap itself should be the Use/Keep decision. **Ruling:** keep the explicit two-button moment — it is the app's grammar, it costs almost nothing, and it is the difference between a file manager and an instrument.
- The coherence lens wanted a standalone connective-tissue milestone first. **Ruling:** M16 carries only the specification-deck link and neutral Lab framing; ship the cross-storage Today's Session/Weekly/home integration coherently as M17 One Practice Home.

## Key evidence

- Home fork: `site/app/View/Progress.hs:298` (`wizard-yes`), `site/app/View/Pages.hs:497` and `site/static/sample-lab.js:1410` (`wizard-no`)
- Handoff identity: `handoffRowKey = [slot, bank, pad, blobId]` (`site/static/sample-lab.js:1034`), `syncHandoffSession` (`:1071`)
- Aggregate-only validation: `validateProject` (`site/static/sample-lab.js:2475-2512`)
- Single static recipe: `strings.recommendWav` (`site/static/sample-lab.js:135/309/2076`)
- Analysis building blocks: `parseWav` (`:853`), `analyzeAudio` (`:884`, resample caveat)
- No revision concept: edited re-imports get a new fingerprint/blobId, no link
- Deferred spec content: `briefs/M5-ship.md:79-89` (G2–G6)
- Budgets: `state/size-ledger.tsv` (wasm 865,701 gz of the 1,000,000 ceiling; unoptimized 1,098,157), bundle ledgers ~150KB headroom; JS island unbudgeted
- Course counts: 50 decks, 352 exercises, 467 prompts; zero exercises reference `#/samples`; zero Lab links to course or manual pages

*Produced from an 8-agent review: four subsystem readers (learning system, Sample Lab, performance, product history) and a four-lens critique panel (advocate, skeptic, alternatives, coherence), with the headline claims re-verified directly against the working tree.*
