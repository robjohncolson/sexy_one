# The falsifiability fixture corpus

This directory is the proof that `exercise-check` can actually fail on each thing it
claims to check — see `content/EXERCISE-FORMAT.md` and `briefs/M2-manifest.json` (task
`format-guide`) for the full brief. Layout:

```
files/<CODE>--<slug>.ex.md    single-file fixtures
dirs/<CODE>--<slug>/          whole content roots (exercises/INDEX + decks + a copy of
                               content/terminology-rules.tsv), for directory-level codes
```

`OK--*.ex.md` fixtures carry **no** defect and must be accepted — the control that
proves the validator has not degenerated into rejecting everything. Every other
fixture's filename declares the exact one issue code it is supposed to trip; run

```sh
. "$HOME/.ghc-wasm/env"
cd site
"$HOME/.ghc-wasm/wasm-run/bin/wasm-run.mjs" \
  "$(wasm32-wasi-cabal list-bin exe:exercise-check | tail -1)" \
  --fixtures /home/mrcolson/repos/casio-sxc1/content/fixtures
```

to check the whole corpus. Every citation and terminology phrase used in these fixtures
is real (drawn from `translations/guide-book.md` pages 15, 17, 55 and
`translations/midi.md`) so that in every fixture, the *only* defect present is the one
its filename names.

## The four inventory-binding `dirs/` fixtures are named to end in `content`

`E-ID-NOT-IN-INVENTORY`, `E-ID-RETIRED`, `E-ID-TYPE-MISMATCH` and
`E-ID-CHAPTER-MISMATCH` are properties of a content root checked against
`content/exercise-inventory.md` — but per `site/test/CheckExercises.hs`'s
`isRealContentPath`, that binding only activates for a deck file whose *path* contains
the literal substring `content/exercises/`. No path under `content/fixtures/dirs/<name>/`
can contain that substring unless `<name>` itself ends in `content` (so that appending
`/exercises` reconstructs it) — there is no other way to reach a genuine, on-disk
`content/exercises/`-shaped path from inside `content/fixtures/dirs/`. This is not a
trick that hides anything: it is a real, on-disk content root, validated by the same
`resolveInventoryId` call a real content run would use, exercising the checker's own
documented contract for what counts as a "real" content path. Verified empirically
(each of the four passes with exactly its intended code and no other).

## `E-JA-MISSING--untranslated-option` (M6 W4)

`E-JA-MISSING` is a `dirs/` fixture for the same reason the four above are: JA
completeness (`content/EXERCISE-FORMAT.md` section 12) is a property of the
**live corpus** — the decks `INDEX` ships are the decks the bundle emitter
translates — not of a single file. `site/test/CheckExercises.hs` scopes it
structurally, per run (`jaScopedCodes`/`BindScope`), which is what keeps the
other fifty-odd fixtures (none of which carries a single `ja:` line) reporting
exactly the one code their own filename declares.

This fixture's deck is fully translated **except one `- [ ] \`B\`` option**, so
it reports exactly one `E-JA-MISSING` and nothing else — and it is also a
standing demonstration that the check can fail at all. (The per-unit-kind
demonstrations — one for each of the nine learner-visible kinds — live in
`exercise-check --self-test` group 22.)

Note also that the `isRealContentPath` mechanism the section above describes was
replaced in M5 by a structural, per-run scope (`inventoryScopedCodes`): a
`dirs/` fixture now opts into the inventory-binding checks by the code its own
name declares, not by how its path is spelled. The four fixtures keep their
`...-content` names for continuity; the naming is no longer load-bearing.

## Historical: the `E-FILE-BAD-NAME` contamination defect (fixed)

Between the `format-guide` task and the M2 gate-fix round, `exercise-check --fixtures
content/fixtures` exited non-zero even though every individual fixture's *content* was
exactly what its filename claimed. `validFileName` requires a file's basename to match
`^[0-9]{2}-[a-z0-9-]+\.ex\.md$`, while `runFixtures`' `expectedCodeOf` reads a fixture's
expected code as the literal text before the first `--` in its filename — and since every
real issue code (`OK`, `E-CITE-PAGE`, `E-TERM.term-register`, ...) is uppercase (or, for
`E-TERM.<rule_id>`, contains a literal `.`), no filename could satisfy both functions at
once unless the expected code itself was `E-FILE-BAD-NAME`. Every other `files/` fixture
carried its intended code *plus* a spurious `E-FILE-BAD-NAME`.

**This is fixed.** `site/test/CheckExercises.hs`'s `runFixtures` now drops
`"E-FILE-BAD-NAME"` from a `files/` fixture's comparison set unless that fixture's own
expected code *is* `E-FILE-BAD-NAME` — symmetric to how the four inventory-binding checks
are already scoped by `isRealContentPath` rather than applied unconditionally. This only
changes what the fixture *comparison* considers relevant; `validFileName` and real
`content/exercises/` validation (default mode, `--json`, `--browser-fixture`) are both
untouched. `exercise-check --fixtures content/fixtures` now passes cleanly, and this
corpus is what `--fixtures`' own regression guard runs against on every change.
