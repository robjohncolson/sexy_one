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

## Known defect this corpus could not route around: `E-FILE-BAD-NAME` contamination

**This is a defect in the already-committed `exercise-core` deliverable
(`site/src/SXC1/Exercise/Parse.hs`'s `validFileName`, called unconditionally from
`fileNameIssues` for every file `resolveDeckIssues` is asked to check), not something
this task introduced, and not something this task's `owned_paths` permit fixing.** It is
recorded here, precisely, because it makes `exercise-check --fixtures
content/fixtures` exit non-zero on this corpus even though every individual fixture's
*content* is exactly what its filename claims.

**The bug.** `validFileName` requires a file's basename to match `^[0-9]{2}-[a-z0-9-]+
\.ex\.md$` — two digits, then a lowercase/digit/hyphen slug. `runFixtures`'s
`expectedCodeOf` (same file) derives a fixture's expected code as the literal text
before the first `--` in its filename — which, for any real issue code (`OK`,
`E-CITE-PAGE`, `E-TERM.term-register`, ...), is uppercase and is never two ASCII digits.
**No filename can satisfy both functions at once** unless the expected code itself is
`E-FILE-BAD-NAME`. Concretely: `content/fixtures/files/OK--quiz-choice.ex.md` — a file
with zero genuine defects — is reported by the real, currently-built `exercise-check`
binary as carrying exactly one issue, `E-FILE-BAD-NAME`, solely because of its own
filename. Reproduced directly against the real binary:

```
$ exercise-check --fixtures <a dir containing only OK--quiz-choice.ex.md as above>
FAIL OK--quiz-choice.ex.md: want=OK got=["E-FILE-BAD-NAME"]
```

The same happens to every `files/` fixture in this corpus except the one deliberately
named `E-FILE-BAD-NAME--anything.ex.md` (whose intended defect *is* the filename, so the
contamination is not a contamination there — it is the fixture working correctly). A
full run against this corpus (`content/fixtures/files/` + `content/fixtures/dirs/`)
shows the exact, exhaustive shape of the problem: **all 9 `dirs/` fixtures pass; the one
`E-FILE-BAD-NAME--*` file fixture passes; every other one of the 41 `files/` fixtures
fails with exactly its intended code *plus* a spurious `E-FILE-BAD-NAME`.** This is not
a construction mistake in any individual fixture — every one of the 41 was independently
confirmed, by temporarily copying it alone into a scratch `--content-dir` (not
`--fixtures`) sandbox with a compliant `NN-slug.ex.md` name, to carry *only* its
intended code.

**Why `content/fixtures/dirs/` fixtures don't have this problem.** `runFixtures`'s
directory branch loads a whole content root via `collectFromDirs`, which reads each
deck's *own* filename from `exercises/INDEX` (e.g. `00-a.ex.md`) — a name we control
independently of the outer `<CODE>--<slug>/` directory name that `expectedCodeOf` reads.
So a `dirs/` fixture's inner deck file can satisfy `validFileName` while the outer
directory name still satisfies `expectedCodeOf`. There is no equivalent decoupling for a
bare file directly under `files/`, because there the *one* filename has to serve both
roles at once.

**Why this could not be fixed by choosing different fixture filenames.** `expectedCodeOf`
takes the filename text *verbatim* (case-sensitive) up to the first `--`; `validFileName`
requires the *entire* stem after its two-digit prefix to be lowercase/digit/hyphen only.
Since every real issue code contains an uppercase letter (or, for `E-TERM.<rule_id>`, a
literal `.`), and `validFileName` has no exemption for paths under `content/fixtures/`,
no filename can satisfy both checks unless the code itself is `E-FILE-BAD-NAME`. This was
verified exhaustively, not assumed — see the format-guide task's final report for the
full derivation and the direct binary reproductions (also copied above).

**What this means for `content/fixtures/`'s own verification.**
`exercise-check --fixtures content/fixtures` (as run by `briefs/M2-manifest.json`'s
`format-guide` verify command) currently exits non-zero, reporting 41 spurious
`E-FILE-BAD-NAME` co-occurrences, none of which are wrong about what they report — every
one of those 41 files genuinely is misnamed by `validFileName`'s rule, exactly as
reported. The fixtures are not incorrect; the coverage they demonstrate (one clean
defect per fixture, confirmed via a sandbox `--content-dir` run) is real; only the
single-binary, single-command `--fixtures files/` invocation cannot currently show it
cleanly.

**Suggested minimal fix (for whoever owns `site/`, in a follow-up wave), not applied
here:** in `site/test/CheckExercises.hs`'s `runFixtures`, when computing a `files/`
fixture's `got` set, drop `"E-FILE-BAD-NAME"` from it unless `expected ==
"E-FILE-BAD-NAME"` — symmetric to how the four inventory-binding checks are already
scoped by `isRealContentPath` rather than applied unconditionally. That is a two-line,
narrowly-scoped change that does not touch real-content validation at all (default mode
is unaffected; only the fixture *comparison* changes).
