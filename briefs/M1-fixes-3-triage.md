# M1 — Codex gate round 1 triage

**From:** Opus 5 sign-off reviewer · **Date:** 2026-08-06
**Reviewing:** `briefs/M1-codex-part1.json` (PART1-BLOCKED) + `briefs/M1-codex-part2.json` (GATE-BLOCKED)
**Reviewed HEAD:** `c575ae6`
**Companion:** `briefs/M1-fixes-3-manifest.json` (5 tasks, 2 waves)

## Verdict

**I concur with all 17 items. Zero disputes.** Every blocker and every minor reproduced. Three
are **broader than filed**; four more I converted from a described scenario into a *live
reproduction* on the built artifact. One recommendation I am deliberately **refining** rather
than adopting (NEW4 — see below); that is a simplification, not a dispute.

| id | sev | verdict | how I confirmed it | fix task |
|---|---|---|---|---|
| A1 | blocker | CONCUR — **broader than filed** | `Unparsed` never constructed; misconception codified in 3 comment blocks | T1 |
| NEW1 | blocker | CONCUR — **broader than filed** | TOC *and* breadcrumb wrong; midi + oss affected too | T1 (+T2 view) |
| NEW2 | blocker | CONCUR | every `DocStats` field is raw-derived; `anchorChecks` vacuous on `[]` | T1 |
| NEW5 | blocker | CONCUR | `Page.navigate` called once with `opts.url`; `goto()` is a hash assignment | T4 |
| NEW6 | blocker | CONCUR — reproduced | corrupt payload → PIL cannot decode → **gate exits 0, all OK** | T3 + T4 |
| NEW7 | blocker | CONCUR — **broader than filed** | `SXC1_SKIP_CONTENT=1` → `result=complete`; defeats a documented M0 guarantee | T3 |
| A2 | major | CONCUR | `stTables = countLooseTableLines raw`; subsumed by NEW2's census | T1 |
| A6 | major | CONCUR (mine) | sabotage passes 247/247 — pin cannot observe tail consumption | T1 |
| A3 | minor | CONCUR both layers | breadcrumb repeats PART title on pp. 12/27 | T1 + T2 |
| A4 | minor | CONCUR — defer to M5 | Index cells are bare numbers; plan §4.6 rule 7 needs `p.`/`pp.` | deferred, tracked |
| A5 | advisory | CONCUR — tripwire now | 3 742 777 raw / 823 588 gzip; no budget enforced anywhere | T3 |
| A7 | minor | CONCUR — M5 as ruled | 29/43 ordered lists fragment; guard added now | T1 (guard only) |
| NEW3 | minor | CONCUR | `dedupeSlugs` keys on the original base only | T1 |
| NEW4 | minor | CONCUR — **refined fix** | fingerprint is structural; exact-byte dump beats a digest | T1 + T3 |
| NEW8 | minor | CONCUR — reproduced live | `p/4294967297` **renders page 1 of 71** | T1 |
| NEW9 | minor | CONCUR — reproduced | `{"docs":[]}` → "ok" and **25/25 assertions passed** | T4 |
| NEW10 | minor | CONCUR — reproduced | `--slug no-such-doc` → `TOTAL 0`, `EXIT=0` | T5 |

The pattern across this gate is one I should name, because it is the same one that cost M0 its
round-2 gate and the same one my own sign-off half-caught: **we kept writing checks whose failing
case was never constructed.** A1, A2, A6, NEW2, NEW6, NEW7 and NEW9 are all the same defect
wearing different clothes — an assertion that is green because it cannot be red. My sign-off
flagged two of them (A1, A6) and still granted; Codex was right to block, and the round-3 house
rule ("every new check needs its failing case demonstrated") is the correct response.

---

## A1 — CONCUR, and broader than filed

Codex's **reachability qualification is correct and I adopt it.** At `c575ae6` no finite input can
hang: reaching the final branch means the line failed all six guards, and `isParaLine`
(Markdown.hs:394-400) is exactly the conjunction of those six negations, so `span` must consume at
least that line. My >10-minute probe necessarily changed that relationship — I reverted round-1's
recognition guard while leaving round-1's `isParaLine` edit in place, which is precisely the
one-sided classifier edit Codex describes. I should have said "a one-sided edit hangs it" rather
than leaving the impression that data could.

**Where it is broader than filed:** the fix is not just "add the branch". The false claim is
*codified as documentation in three places*, and each will actively mislead the next maintainer:

* `Stats.hs:74-79` — "`Unparsed` is provably unreachable in this grammar … exe:content-check
  independently confirms this by forcing the real parser over the whole corpus and asserting zero
  `Unparsed` blocks — **that is the actual gate**." The second half is false: the producer cannot
  emit, so the gate cannot fire.
* `CheckContent.hs:147` group-3 header, same premise.
* `briefs/M1-plan.md:262` ("must be zero corpus-wide") and §8.2 ("the strongest single parser
  check") and §8.4's promised negative control, which **cannot be demonstrated as specified**.

So T1 must correct the prose as well as the code, or the next reviewer re-derives the same false
confidence from the comments.

**Fix design.** Two independent properties, because they fail independently:

1. **Structural progress.** The final branch becomes: if `span isParaLine` consumes nothing, emit
   `Unparsed l` and recurse on `ls`. Termination then holds for every finite input *regardless of
   any future predicate drift* — the hazard is removed, not merely guarded.
2. **Single source of truth.** Derive the guard chain and `isParaLine` from one exported
   line classifier so they cannot drift apart in the first place. Defence in depth: (1) makes
   drift survivable, (2) makes drift unlikely.

**Reachability is the hard part and must be engineered deliberately.** In this grammar the
paragraph rule is a genuine catch-all, so no *corpus* line can reach the fallback — which is why
plan §8.4's "introduce a line the block grammar cannot classify" was never demonstrable. T1 must
therefore expose a test seam (a classifier-injecting variant of the engine, production passing the
real classifier) so a fixture can construct a real `Unparsed` block and assert both that it is
produced and that the engine terminates. An unreachable branch is not a fallback; it is dead code
with a comment.

**Laziness constraint I am imposing on the fix (§4.4 must survive).** `stUnparsed` must stop being
a literal, but the boot path must not start forcing all 108 pages' blocks. Resolution: the stats
JSON schema does not change; the *content-check* producer computes `unparsed` from the parsed
model, while the browser keeps the cheap raw-scan value, documented as such. A real `Unparsed`
then makes content-check's `--json` disagree with the DOM, and the existing three-way agreement
turns it into a red check. This is the "matching cheap classifier if boot laziness must be
preserved" half of Codex's own required direction.

## NEW1 — CONCUR, and materially broader than filed

Reproduced against the built app. Codex filed the TOC misattribution on Startup Guide p. 10. It is
worse in two directions.

**Direction 1 — a second user-visible layer, the breadcrumb.** `attachSubs` (Outline.hs:95-101)
ends each section at `nextSectionPage - 1`, so an earlier co-located section gets
`secEndPage < secPage` and owns *no page at all*. The page view resolves the current section from
those spans, so the sticky header names the wrong section:

```
startup-guide p.10 breadcrumb: … / Try sampling / page 10 of 15      (page opens with "Try applying an effect")
startup-guide p.14 breadcrumb: … / Trademarks   / page 14 of 15      (page opens with "Operating precautions")
```

**Direction 2 — three documents, not one.** Pages carrying more than one section-level heading:

```
startup-guide  pp. 1, 2, 3, 4, 10, 14
midi           p. 2   ("2. Product information" + "3. MIDI implementation chart")
oss            p. 11  ("MIT" + "MICROSOFT AZURE RTOS")
guide-book     none   — which is why every guide-book golden stayed green
```

The rendered Startup Guide TOC, verbatim:

```
Try applying an effect      p.10      (no subsections at all)
Try sampling                p.10
    Applying an effect                 <- belongs to "Try applying an effect"
    How to use the FX1/FX2 buttons     <- belongs to "Try applying an effect"
    Sampling
    Try recording with the built-in microphone
    Try recording an external sound
```

Aggregate counts stay green because the ranges still partition the pages: every subsection lands
in exactly one non-empty range, so `sections`/`subsections` totals (21/27) are unchanged while
*ownership* is wrong. That is exactly why golden-count assertions did not catch it, and it is the
NEW2 lesson in miniature.

**Fix design.** Carry a monotonic source-order index on every heading event; attach each
subsection to the last section event preceding it *in source order*, not to a page range. Set
`secEndPage` to the next section's page minus one only when that next section is on a later page,
otherwise to this section's own page — which makes `secEndPage >= secPage` an invariant rather
than an accident. Assert that invariant, plus exact representative ownership for
startup-guide p. 10/p. 14, midi p. 2 and oss p. 11, and confirm the 29/78, 21/27, 6/1, 5/0 golden
totals are unmoved.

## NEW2 — CONCUR

Verified field by field: `stChars/stLines/stPages` are `Text` operations on raw source,
`stHeadings/stFigures/stTables` are raw regex-shaped scans, and `stSections/stSubsections/stParts`
come from `buildOutline raw`, which is itself a raw line scan. **No `DocStats` field inspects a
parsed block.** So "Haskell vs Python" is two raw scanners and the DOM is a third copy of the
first — the parsed model is never on any side of the three-way agreement. Codex's worked example
(delete the `Para [Placeholder] -> Figure` promotion and everything stays green) is correct, and
`anchorChecks` (CheckContent.hs:273-282) is vacuous on an empty slug list because `all` and `nub`
both accept `[]`.

**Fix design.** Add a **model census** to content-check as new assertion groups — top-level
`Heading`s, `Figure`s, `Table`s, `Numbered`/`Bullets` blocks and their items, `PageRef` and
`Placeholder` inlines — each with a pinned, **nonzero-where-applicable** golden, and each with its
failing case demonstrated. Raw goldens must not shift; the census is *additional*, and is compared
against a raw golden only where the two definitions genuinely coincide.

One caution for the implementer, from my own attempt to pre-compute these: **do not trust plan §3's
"… of which block-level 186/35/4/0" row.** My independent scan of whole-line placeholders yields
174/34/4/0 and total placeholder occurrences 191 against a golden `figures` of 190 — so the
design-time block-level row is either differently defined or wrong. The census values must be
*derived from the model, printed, and justified*, not copied from the plan. Where the derived
number contradicts §3, correct §3 and say why. Table blocks are the one clean case: separator rows
and `Table` blocks genuinely coincide, so 20/5/7/0 is a legitimate hard target and A2 dies with it.

## NEW5 — CONCUR

`Page.navigate` is issued exactly once (browser-check.mjs:709) with `opts.url`, the origin root.
`goto()` (line 760) is `window.location.hash = …` inside the already-booted app. So assertion 6's
"cold load" is a warm in-session hash change, executed immediately after assertion 5 has already
loaded and decoded the very same `page-17.webp` — the `imgOk` check is satisfied from cache.
Codex's counterfactual is exact: an app that ignored the initial hash but kept the `hashchange`
subscription would pass all 25 assertions while every shared deep link opened at Home.

**Fix design.** A genuinely fresh target whose *initial* URL already carries
`#/m/guide-book/p/17/ja`, with boot and image decode awaited independently, asserting hash, page
id, `ja-visible`, panel presence and image `src` + decode. Negative control: make `main` ignore the
startup hash — the new assertion must fail while the old suite would have passed.

## NEW6 — CONCUR, reproduced end to end

The gate reads 12 bytes and accepts anything starting `RIFF` with `WEBP` at offset 8. I corrupted a
copy of `midi/page-03.webp` from byte 12 onward while preserving that prefix (and the RIFF length
field), then ran check-site's **exact** image-gate script against the corrupted tree:

```
PIL: FAILS TO DECODE -> UnidentifiedImageError
OK magic midi all 6 files begin RIFF..WEBP
OK maxsize / OK totalsize / GATE EXIT=0
```

An undecodable image passes cleanly. Only `guide-book/page-17.webp` is ever really decoded, by the
JA-toggle assertion; the 108-route sweep never enables JA.

**Fix design, two layers, neither adding a dependency:**

1. **Host side (T3).** Deepen the pure-python check for all 108: validate the RIFF length field
   against actual file size, require the first chunk after `WEBP` to be `VP8 `/`VP8L`/`VP8X`, and
   parse and sanity-check the dimensions. This catches my corruption (the chunk tag becomes
   `AAAA`) with no Pillow requirement, so CI stays dependency-free.
2. **Browser side (T4).** The sweep visits all 108 `/ja` routes and `await`s a real decode
   (`img.decode()` or `complete && naturalWidth > 0`) against the expected `src`, with network
   failure listeners armed. Chrome is already a hard requirement, so this is the authoritative
   decoder.

## NEW7 — CONCUR, and broader than filed: this is an M0 regression

Demonstrated:

```
$ SXC1_SKIP_CONTENT=1 ./scripts/check-site.sh
check-site: 30/35 checks passed (5 skipped)
check-site: result=complete            <- CI greps exactly this and passes
```

Broader than filed because of what the code says about itself. check-site.sh:1015-1020 carries the
M0 **m2 fix** comment: the marker exists so "a caller that only records this one line (as CI does)
[can] tell a full gate from a structural-only run apart". M1 added a second skippable axis and did
not widen the marker, so a documented M0 guarantee — won in the M0 round-2 gate — is now false.
This is not a new-feature gap; it is a regression of hardening we already paid for.

**Fix design (mirror the M0 pattern exactly).** `result=complete` only when `SKIPPED -eq 0`;
otherwise `result=structural-only`. CI asserts the full marker **and** that zero checks were
skipped, so a future third axis cannot repeat this.

## NEW4 — CONCUR, with a refined fix

The scenario holds: the stale-build detector is a *structural fingerprint*, so an equal-length,
line-count-preserving prose edit leaves every metric identical and the stale artifact passes.

I am **not** adopting the recommended cryptographic digest. Implementing SHA-256 in the library is
~80 lines of hand-rolled crypto under a boot-libraries-only constraint, to protect a minor. The
exact-bytes variant Codex offers as its own alternative is simpler *and strictly stronger*:
`content-check --dump-source <slug>` writes the embedded UTF-8 bytes to stdout, and check-site
diffs that against `translations/<slug>.md` for all five documents. No crypto, no new dependency,
and it compares the actual bytes rather than a summary of them. `addDependentFile` and the CI
content hash stay as the preventive layers.

## NEW8 — CONCUR, reproduced live on the built app

Not theoretical. Against the served site:

```
#/m/guide-book/p/4294967297  -> RENDERS id="page-1"  ("page 1 of 71")
#/m/guide-book/p/4294967296  -> not-found panel (correct)
#/m/guide-book/p/9999        -> not-found panel (correct)
```

`Int` is 32-bit on wasm32 exactly as Codex predicted, and `parseDigits`' unchecked
`acc * 10 + digit` fold wraps. **Fix:** reject before the accumulator would exceed `maxBound`, and
assert *classifications* — not merely non-throwing totality — for zero, oversized, overflow-width,
malformed-suffix and unknown-slug routes.

## NEW9 — CONCUR, reproduced

```
--expect-json {"docs":[]}                        -> ok - #sxc1-content-stats matches …   25/25 passed
--expect-json {"docs":[{"slug":"guide-book"}]}   -> ok - #sxc1-content-stats matches …   25/25 passed
```

The comparison loops over *expected* documents and over `Object.keys(edoc)`, so an empty
expectation is a vacuous pass and the summary line still reads 25/25 — the vacuity is invisible
even to a careful reader of the output. **Fix:** validate the exact four-document schema and
required field set, compare document sets in both directions, and reject duplicate slugs before
comparing.

## NEW3, NEW10 — CONCUR

`dedupeSlugs` (Markdown.hs:254-261) counts occurrences per *original base* and never reserves what
it emits, so `["x","x","x-2"]` yields `["x","x-2","x-2"]`. The corpus does not hit it and the
corpus-only uniqueness test therefore passes. **Fix:** track emitted names and advance the suffix
until unused; add adversarial unit cases for natural numeric-suffix collisions.

`render-page-images.sh --slug no-such-doc` prints `TOTAL 0` and exits 0 — every PDF is filtered out
by an unvalidated filter. Staleness is decided purely by mtime, so a changed PDF with a preserved
timestamp leaves stale WebPs in place. **Fix:** reject unknown slugs (exit non-zero), and record
and compare source-PDF digests instead of trusting mtimes.

---

## Accepted without a fix task

* **A4 (Index not linkified)** — deferral to M5 accepted by both sides, with the contract debt
  recorded: plan §4.6 rule 7's claim that the rule "makes the guide book's Index navigable" is
  **false today** and must stay an explicit M5 item, not a footnote.
* **A7 (list fragmentation)** — M5 as I ruled at sign-off, and Codex concurs it is minor with
  visual numbering currently correct. But I am pulling one piece forward into T1: a **source-level
  assertion that every ordered list's numbers are consecutive-ascending**. That is the trigger that
  converts A7 from cosmetic to visibly wrong, it costs ~10 lines, and it touches no parser code. T1
  also pins the current fragment census so an M5 grouping fix is a deliberate, visible change
  rather than a silent one.
* **A5 (bundle size)** — Codex asks for a budget "before M2 lands". T3 is already opening
  check-site.sh and site.yml, so the tripwire goes in now at a deliberately generous ceiling: a
  recorded current value plus a hard gzip ceiling that today's 823 588 bytes clears comfortably.
  A tripwire nobody trips is the point; a budget added after M2 has already grown is worthless.

## Scope discipline

Five tasks, two waves, disjoint `owned_paths`, no new features and no restructuring beyond what
the blockers force. T1 is deliberately large because A1, NEW1, NEW2, NEW3, NEW8, A2, A6 and the
A7 guard all meet in one build and one checker (`content-check`), and splitting them across agents
would put three of them in a merge fight over `CheckContent.hs` and the goldens. Everything that
can be independent is: the browser driver, the shell harness, the CI workflow, the image
regenerator and the view layer are five separate owners.

Every task carries sabotage-proven negative controls, and per the round-3 house rule **every new
assertion must have its failing case demonstrated and pasted into the report** — for the census
checks that means one sabotage per census dimension, because that is exactly the class of check
this gate was lost to.
