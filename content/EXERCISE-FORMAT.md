# The `.ex.md` exercise format — an authoring guide

This is the complete guide to writing SXC-1 Trainer exercises. It assumes no Haskell
knowledge and no access to the validator's source code. Everything you need to write,
check, and fix exercise content is in this document, plus the two files it points you
at: `content/exercise-inventory.md` (the master list of ids you are allowed to use) and
`content/terminology-rules.tsv` (the house style rules).

If anything here and the validator's own output ever disagree, the validator wins —
run it, as described in "How to check your work" below, before you trust your memory of
this document.

## 1. What an exercise is, what a deck is, where files go

A **deck** is a small, ordered group of exercises drawn from one part of one chapter of
the SXC-1 Guide Book — for example, "the handful of flashcards and drills about
choosing a bank." One deck is one file.

An **exercise** is one learner-facing task inside a deck: a quiz question, a
hands-on drill, or a timed lookup. A deck usually holds a few exercises, not just one —
group exercises that belong together so a learner working through the deck builds one
skill at a time.

Deck files live flat in `content/exercises/`, named `NN-slug.ex.md` or
`NNN-slug.ex.md`, where the two- or three-digit number only controls reading
order (it is not otherwise meaningful; the M3 course uses three digits spaced
by 2 so decks can be inserted without renumbering) and
`slug` is a short, lowercase, hyphenated description, e.g. `02-pad-play-banks.ex.md`.

The order decks appear in is **not** just "sorted by filename" — it is controlled by
`content/exercises/INDEX`, a plain text file with one filename per line (`#` starts a
comment, blank lines are ignored). Every `.ex.md` file in `content/exercises/` must be
listed in `INDEX`, and every file `INDEX` lists must exist — the validator checks both
directions (`E-INDEX-ORPHAN`, `E-INDEX-DANGLING`).

## 2. The shape of a file, and why it's shaped that way

Here is the skeleton of a deck file. Field lines (`key: value`) always come immediately
after a `#`/`##`/`###` heading — blank lines are allowed *before* the field block, never
*inside* it.

```text
# <deck title>                    <- exactly one '#' heading, first thing in the file

deck: <slug>
chapter: <one of six fixed chapter titles -- "Front matter" plus five "Part: X" titles>
tier: intro | core | stretch
requires: <deck-slug>[, <deck-slug>...]   <- optional
summary: <one line, learner-facing>
cite: <slug> <page> "<anchor phrase>"

<intro prose for the whole deck, optional>

## <exercise title>                <- one '##' heading per exercise

type: quiz | drill | lookup
id: <an id from content/exercise-inventory.md>
cite: <slug> <page> "<anchor phrase>"

<exercise body prose, and/or a choice list, and/or ### role blocks>
```

A few design decisions are worth explaining, because they are easy to fight if you
don't know why they're there:

* **Unknown field names are errors (`E-FIELD-UNKNOWN`), never silently ignored.** If
  you misspell `summary:` as `summry:`, or add a field the format doesn't know about,
  the validator stops you immediately instead of quietly losing your content. This is
  deliberate: a silently-dropped field is much harder to notice than a validator error.
* **Citations carry a quoted anchor phrase, not just a page number.** `cite: guide-book
  15 "press the \`A\` button"` is checked against the *actual text* of page 15 of
  `translations/guide-book.md` (after collapsing whitespace), at least 12 characters,
  and must be an exact (case-sensitive) substring. This exists so that citations stay
  correct as the manual translation is revised — if page 15's wording changes and no
  longer contains your anchor, the validator tells you, instead of leaving a citation
  that silently points at the wrong sentence. Renumbering the manual is caught the same
  way, for free.
* **Chapter titles are a fixed, closed set, not free text**, because they come from
  `content/exercise-inventory.md`'s own course map (its `### Chapter N — <title>`
  headings), cross-checked against the Guide Book's own part titles and the glossary.
  Three independent sources have to agree. This means a chapter title can never quietly
  drift out of sync with the manual's own terminology — and it means you cannot invent
  a SEVENTH chapter by typing a new string into `chapter:`.
  **There are SIX chapters, not five** — the course map runs `Chapter 0` through
  `Chapter 5`: `Chapter 0` is `Front matter` (the unnumbered pp. 1–11 material — panel
  and connector identification, safety precautions, the mode-map overview — that
  precedes the Guide Book's own numbered PARTs), then `Chapter 1`–`Chapter 5` are the
  five `"Part: X"` chapters (`Part: Preparation` … `Part: Leveling up`). `chapter: Front
  matter` is authorable TODAY, exactly like any other chapter — verified by running
  `exercise-check` against a deck declaring `chapter: Front matter` with a real
  `guide-book` p. 10 anchor: `0 issue(s)` (see §7's `E-CHAPTER-UNKNOWN` row and §11 for
  a worked example). An earlier version of this document said "five" and "cannot invent
  a sixth chapter" here; that was wrong and blocked every Chapter-0 exercise (64 of
  them, per `content/exercise-inventory.md`) from ever being authored — `resolveChapter`
  has always accepted the inventory-derived map, which includes `0 -> "Front matter"`.
* **Exercise ids are not yours to invent.** Every `id:` must already appear in
  `content/exercise-inventory.md` as `**<id>**`. See "Stability and ids" below for why
  this matters far more than it looks like it should.
* **Roles (`### Why`, `### Hint`, `### Step`, `### Answer`) are a closed, per-type set**,
  and an unrecognised role name is `E-ROLE-UNKNOWN` rather than being treated as
  ordinary body prose. This is what lets a role's content be pulled out and rendered
  specially (e.g. hints are hidden until tapped) instead of just appearing as another
  paragraph.

### Headings: what's structural, what's just text

Only `#`, `##` and `###` at the very start of a line (column 0, no leading spaces) are
structural (deck title / exercise title / role). A `####`–`######` heading, or *any*
heading-shaped line that is indented even by one space, is **not** structural — it is
ordinary Markdown inside your prose. In fact, an indented `#`-line in your exercise
prose is flagged outright (`E-BODY-INDENTED-HEADING`): whether it accidentally becomes a
real heading or renders as literal hash marks depends on very fiddly surrounding
indentation, and content must never depend on that. If you want a heading-like word
inside a paragraph, don't indent a line starting with `#` — rephrase it, or use `**bold**`.

### Body prose

Once past the field block, everything up to the next structural heading is your body:
ordinary Markdown blocks — paragraphs, `**bold**`, `*em*`, `` `code` ``, tables,
blockquotes, nested lists, and `*[Figure: ...]*` placeholders — the exact same prose
parser the manual reader uses. A bare page reference like `p. 15` in your own prose is
**not** turned into a link (unlike the manual text) — the format deliberately does not
support that, so every manual reference in your writing must go through an explicit
`cite:`/`find:` line with a slug. That's the only way to link unambiguously to one of
four different documents, and it's also what makes lookup exercises hard to accidentally
spoil (see `E-LOOKUP-SPOILER` below).

### Choice lists

Inside a quiz's body, a GFM task list —

```text
- [x] `A`
- [ ] `B`
- [ ] `EDIT`
```

— is lifted out of the prose and becomes the exercise's answer options; the rest of the
body stays as introductory prose above it. Mark every correct option `[x]`; two or more
`[x]` marks means the learner must select the *exact* set to be graded correct, not
merely "at least one". Option labels are ordinary inline Markdown (so `` `A` `` renders
as code), and no two option labels may read the same after trimming whitespace.

## 3. Field reference

### Deck fields (the field block right after the `#` title)

| Field | Required? | Notes |
|---|---|---|
| `deck` | **required** | `[a-z0-9-]+`, globally unique across all decks, **permanent** — see stability below |
| `chapter` | **required** | must exactly match one of the SIX course-map chapter titles (`Front matter` plus the five `Part: X` titles) |
| `tier` | **required** | one of `intro`, `core`, `stretch` — a closed set, like `type:`; used by the course map's navigation to group decks by depth (`E-DECK-TIER-UNKNOWN` for anything else) |
| `requires` | optional | comma-separated deck slugs (same `[a-z0-9-]+` shape as `tags`) — deck-level prerequisites for course-map ordering. Every named slug must be a real deck (`E-DECK-REQUIRES-UNKNOWN`), and the `requires:` graph as a whole must not contain a cycle (`E-DECK-REQUIRES-CYCLE`) — both checked across the WHOLE corpus, like `E-ID-DUPLICATE` |
| `summary` | **required** | one line, learner-facing (linted for terminology) |
| `cite` | **required**, repeatable | at least one `<slug> <page> "<anchor>"` |
| `tags` | optional | comma-separated `[a-z0-9-]+`; add `visual-source` when the deck's questions depend on their cited panel diagram or screen image — the runner will place each exercise's first cited page beside its prompt |

### Fields common to every exercise type (the field block right after a `##` title)

| Field | Required? | Notes |
|---|---|---|
| `type` | **required** | one of `quiz`, `drill`, `lookup` |
| `id` | **required** | must appear in `content/exercise-inventory.md`, **permanent** |
| `cite` | **required** for `quiz`/`drill`; optional for `lookup` | `lookup` already has `find:` |
| `tags` | optional | comma-separated; the inventory's `intro`/`core`/`stretch` tags are a good default; `visual-source` may also be set on one exercise instead of the whole deck |

Roles common to every type: `### Why` (0 or 1 — the "why this matters" explanation) and
`### Hint` (0 to 3, in order — escape hatches for a stuck learner).

### `type: quiz` — authored choices or flashcard shorthand

A quiz is either **choice mode** (a task list is present) or **flashcard shorthand**
(no task list; `### Answer` holds the correct answer and an authored `distractor:`
field) — never both at once (`E-QUIZ-MODE-AMBIGUOUS` if you leave both). The reader
turns the shorthand into a two-option, one-correct Choice prompt; the correct side is
stable per exercise id and varies across the corpus. Learners always answer an actual
question—live content must not ask them merely whether they knew something.

| Choice mode | Flashcard shorthand |
|---|---|
| 2–6 options, at least one `[x]` | no task list in the body |
| multiple `[x]` = multi-select, exact-set grading | `### Answer` role **required**, exactly once |
| option labels must be pairwise distinct | one non-empty `distractor:` plus the correct answer body |

For Japanese, place `ja: distractor:` immediately after `distractor:` just like other
learner-visible variant fields. A bare Answer without a distractor remains readable by
the backwards-compatible parser for old fixtures, but is not valid live-course
authoring practice and the corpus regression requires zero such recall prompts.

### `type: drill` — a "do this on your SXC-1 now" mission

The body (before any `### Step`) is the mission's goal, in one or a few sentences. Then
at least **two** `### Step` blocks, in order:

| Step field | Required? | Notes |
|---|---|---|
| `cite` | **required** | the manual page this step mirrors |
| `check` | **required** | one line: what the learner should observe to know they did it right |
| `verify` | optional | an M4 WebMIDI hook — see below |

Each step's own body (after its field block) is the instruction text — at least one
block.

### `type: lookup` — a timed find-the-answer task

| Field | Required? | Notes |
|---|---|---|
| `find` | **required**, exactly one | `<slug> <page> "<anchor>"` — the page the learner must locate; counts as this exercise's citation |
| `limit` | optional | integer seconds, 10–600 — a *target*, never a hard cutoff |

The body is the task description, and it **must not** give away the target page number
— no `p. N`, `p.N`, `page N` or `pages N` form naming that page anywhere in the body
(`E-LOOKUP-SPOILER`). A `### Hint` role is the intended escape hatch for a learner who's
stuck, since the body itself can't point at the page directly.

## 4. Citations

```text
cite: <slug> <page> "<anchor phrase>"
find: <slug> <page> "<anchor phrase>"     (lookup only, otherwise identical)
```

* `slug` is one of `guide-book`, `startup-guide`, `midi`, `oss` — anything else is
  `E-CITE-SLUG`.
* `page` must be within that document's real page count (guide-book 71,
  startup-guide 15, midi 6, oss 16) — otherwise `E-CITE-PAGE`.
* `anchor` must genuinely occur on that page, after collapsing runs of whitespace to a
  single space on both sides, and must be at least 12 characters — otherwise
  `E-CITE-ANCHOR`. This is a *content* check, not a format check: paraphrasing the
  manual, or citing the right page with the wrong quote, is caught the same way as
  citing a nonexistent page.

Every citation renders as a real, clickable link into the manual reader — the exact
page the learner just read about.

## 5. The `verify:` hook (device confirmation, checked now, used in M3)

A drill step may declare a WebMIDI hook that a later milestone uses to auto-confirm the
step from the real device instead of relying on the learner's word:

```text
verify: cc 104 127          # one Control Change number, one or more comma-separated values
verify: cc 80 0,127
verify: note 36              # one or more comma-separated MIDI note numbers
verify: pad 13 bank A        # sugar for a note in that pad/bank's slot; bank is A|B|C|D
verify: any                  # any MIDI activity from the unit at all
```

This document's milestone **validates** the hook (the CC number must appear in
`translations/midi.md`'s "4. Control Change list" table, note numbers must fall in
36–115, and `pad N bank X` must appear in its "5. Note mapping" table) but does not yet
execute it — that's a later milestone. Today, all a `verify:` hook does is add one muted
line under the step showing what it will eventually check; the step is still confirmed
by the learner tapping a button. Write it anyway wherever it's genuinely observable —
it costs you nothing now and saves rework later.

## 6. Terminology — house style, enforced

`content/terminology-rules.tsv` is six tab-separated columns (`#` starts a comment
line):

```text
rule_id <TAB> kind <TAB> phrases <TAB> replacement <TAB> glossary_anchor <TAB> message
```

Two kinds of rule:

* **`kind=forbid`** — none of the comma-separated `phrases` may appear anywhere in
  learner-facing text. Matching is case-insensitive and word-bounded (a match can't be
  glued to a surrounding letter, digit or hyphen), but it is *literal* phrase matching —
  there is no regex, so don't rely on any pattern beyond the exact phrases listed.
* **`kind=caseof`** — each phrase is the one correct on-device spelling. Any
  case-insensitive occurrence of it that is not byte-for-byte identical to the canonical
  spelling is an error. This is how `SELECT BANK`, `MASTER BPM`, the five `Part: X`
  chapter titles (note: this `caseof` rule covers only the five `"Part: X"`-prefixed
  titles, chapters 1–5 — it does not need to name `Front matter`, chapter 0, since that
  title has no on-device-style casing to get wrong; `chapter:`'s own SIX-way closed set,
  including `Front matter`, is `resolveChapter`'s job, not this rule's — see `E-CHAPTER-UNKNOWN`
  above and the chapter-count note in §1), and the device's own (real, printed)
  misspelling `LOW STRAGE SPACE` are enforced without the rules file having to enumerate
  every possible wrong spelling — say it in any other case and the validator catches it.

Every rule's `glossary_anchor` must be a literal substring of `translations/glossary.md`
— house style is never invented in the rules file, only *restated* from the binding
glossary. A rule whose anchor doesn't actually appear in the glossary is
`E-RULE-UNGROUNDED`.

**Learner-facing text** — the text that gets linted — is: deck title and summary,
exercise titles, all body prose (including inline `` `code spans` ``), option labels,
step `check:` sentences, and `### Answer`/`### Why`/`### Hint` blocks. It does **not**
include `id`, `deck`, `tags`, `verify:`, or the *quoted anchor* inside a `cite:`/`find:`
line — anchors are verbatim quotations of the manual (including the manual's own
misspellings), and linting them would punish you for correctly quoting the device.

Today's standing rules, in plain terms: write **"assign"**, not "register" (or "store"
when you mean saving into memory); write **"tap a pad"**, not "hit/strike/press the
pad"; call the device **"this unit"**, never "this machine" or "this product"; spell
**`SXC-1`** and **`CASIO`** exactly as shown, every time; and spell on-device screen
labels (`SELECT BANK`, `MASTER BPM`, `LOW STRAGE SPACE`, and so on) byte-for-byte as
they appear on the unit's own display.

## 7. Every issue code

This table is generated by reading `exercise-check --list-codes` — not from memory —
and adding the one-line fix a content author actually needs. `--list-codes` prints
`<CODE><TAB><file|dir|seam>`: a `file` code can be demonstrated by one malformed file, a
`dir` code needs a whole content root, and exactly one code (`E-BLOCK-UNPARSED`) is
`seam`-class — it is provably unreachable from any real file (see
`content/fixtures/README.md`) and is instead demonstrated by the validator's own
`--self-test`.

| Code | Class | What it means | Usual fix |
|---|---|---|---|
| `E-FILE-TITLE` | file | the file doesn't start with exactly one `#` deck title | make the first non-blank line a single `#` heading; remove any extra `#` heading |
| `E-FILE-BAD-NAME` | file | the filename isn't `NN-slug.ex.md` / `NNN-slug.ex.md` | rename to two or three digits, a hyphen, then `[a-z0-9-]+`, ending `.ex.md` |
| `E-DECK-EMPTY` | file | the deck has no `##` exercises at all | add at least one exercise, or delete the deck |
| `E-FIELD-UNKNOWN` | file | a field key this context doesn't recognise | fix the spelling, or remove the field |
| `E-FIELD-MISSING` | file | a required field never appeared | add it |
| `E-FIELD-DUPLICATE` | file | a single-valued field (e.g. `deck:`, `chapter:`) appeared more than once | keep only one occurrence |
| `E-FIELD-EMPTY` | file | a known field's value is blank | give it a value, or remove the field if optional |
| `E-FIELD-SYNTAX` | file | a field's value doesn't match its expected shape (e.g. `tags:`, `limit:`) | fix the value's shape |
| `E-TYPE-UNKNOWN` | file | `type:` is not `quiz`, `drill` or `lookup` | fix the spelling |
| `E-ID-SYNTAX` | file | `deck:` or `id:` isn't `[a-z0-9-]+` | use only lowercase letters, digits, hyphens |
| `E-CITE-SYNTAX` | file | a `cite:`/`find:` line isn't `<slug> <page> "<anchor>"` | fix the shape — page must be a bare integer, anchor in double quotes |
| `E-CITE-SLUG` | file | the slug isn't one of the four known documents | use `guide-book`, `startup-guide`, `midi` or `oss` |
| `E-CITE-PAGE` | file | the page number is out of that document's range | check the real page count and fix the number |
| `E-CITE-ANCHOR` | file | the anchor doesn't occur on that page, or is under 12 characters | quote the page's actual text (whitespace differences are fine) |
| `E-CHAPTER-UNKNOWN` | file | `chapter:` isn't exactly one of the SIX course-map titles (`Front matter` plus five `Part: X` titles) | copy the title from `content/exercise-inventory.md`'s course map |
| `E-DECK-TIER-UNKNOWN` | file | `tier:` isn't `intro`, `core` or `stretch` | fix the value |
| `E-ROLE-UNKNOWN` | file | a `###` heading isn't a role this exercise type allows | fix the role name, or move the content into the body |
| `E-ROLE-MISSING` | file | a required role is absent (flashcard shorthand needs `### Answer`) | add it |
| `E-ROLE-REPEATED` | file | a role that may appear at most once (or, for `### Hint`, more than three times) appeared too often | merge into one block, or delete the extra |
| `E-CHOICE-COUNT` | file | a choice list has fewer than 2 or more than 6 options | add or remove options |
| `E-CHOICE-NO-CORRECT` | file | no option is marked `[x]` | mark at least one correct option |
| `E-CHOICE-DUPLICATE` | file | two option labels read the same | reword one so they're distinguishable |
| `E-QUIZ-MODE-AMBIGUOUS` | file | both a choice list and `### Answer` are present | pick one mode and remove the other |
| `E-DRILL-STEP-COUNT` | file | a drill has fewer than 2 `### Step` blocks | add another step, or reconsider whether this is really a drill |
| `E-DRILL-CHECK-MISSING` | file | a step has no `check:` field | add one — what should the learner see or hear? |
| `E-VERIFY-SYNTAX` | file | a `verify:` value doesn't match any known shape | use `cc N V[,V...]`, `note N[,N...]`, `pad N bank X`, or `any` |
| `E-VERIFY-CC-UNKNOWN` | file | the CC number (or `pad N bank X`) isn't in `midi.md`'s tables | check the real Control Change list / Note mapping table |
| `E-VERIFY-NOTE-RANGE` | file | a note number is outside 36–115 | check `midi.md`'s Note mapping table |
| `E-LOOKUP-SPOILER` | file | the body names the target page number | describe the setting or fact, not its page |
| `E-BODY-INDENTED-HEADING` | file | an indented line looks like a heading | remove the leading spaces, or don't start the line with `#` |
| `E-INDEX-MISSING` | dir | `content/exercises/INDEX` doesn't exist | create it, one filename per line |
| `E-INDEX-ORPHAN` | dir | a `.ex.md` file exists but isn't listed in `INDEX` | add it to `INDEX` |
| `E-INDEX-DANGLING` | dir | `INDEX` names a file that doesn't exist | fix the filename, or remove the line |
| `E-ID-DUPLICATE` | dir | the same exercise `id:` is used more than once | every id must be used by exactly one exercise, forever |
| `E-RULE-UNGROUNDED` | dir | a terminology rule's `glossary_anchor` doesn't occur in `translations/glossary.md`, or the row is malformed | fix the anchor text, or fix the row's six columns |
| `E-DECK-REQUIRES-UNKNOWN` | dir | a `requires:` entry names a deck slug that doesn't exist anywhere in the corpus | fix the slug, or add the missing deck |
| `E-DECK-REQUIRES-CYCLE` | dir | the `requires:` graph has a cycle (a deck that, via zero or more `requires:` edges, requires itself) | break the cycle -- restructure which deck depends on which |
| `E-ID-NOT-IN-INVENTORY` | dir | `id:` doesn't appear in `content/exercise-inventory.md` as `**<id>**` | use a real id from the inventory — never invent one |
| `E-ID-RETIRED` | dir | the id is tagged `(retired)` in the inventory | pick a different, non-retired id |
| `E-ID-TYPE-MISMATCH` | dir | the id's leading letter (`q`/`d`/`l`) doesn't match `type:` | use an id whose letter matches, or fix `type:` |
| `E-ID-CHAPTER-MISMATCH` | dir | the id's chapter digit doesn't match this deck's `chapter:` | use an id from the right chapter, or fix `chapter:` |
| `E-JA-MISSING` | dir | a learner-visible piece of a **live** deck has no `ja:` variant (section 12) | add a `ja:` replacement line directly below the line(s) the message names |
| `E-BLOCK-UNPARSED` | seam | unreachable from real content (see above) | not applicable to authors |
| `E-TERM.<rule_id>` | file | learner-facing text violates a `content/terminology-rules.tsv` rule | see section 6 — use the rule's `replacement`, or fix the spelling/case |

## 8. Stability: ids and step order are permanent

**Deck ids, exercise ids, and the order of a drill's `### Step` blocks are permanent
once published.** A later milestone keys a learner's saved progress and
spaced-repetition schedule to `<exercise-id>#<step number>` — for a quiz or lookup,
`<id>#1`; for a drill, one key per step in source order, `<id>#1`, `<id>#2`, and so on.

Concretely, this means:

* **Never renumber or reuse an exercise id.** If content is retired,
  `content/exercise-inventory.md` keeps the id with a tombstone note rather than
  freeing it for reuse — do the same in spirit for anything you author.
* **Never reorder a drill's `### Step` blocks**, and never insert a new step in the
  middle of an existing drill — inserting shifts every following step's key and
  silently disconnects learners' saved progress on that drill from the step it used to
  refer to. Append new steps at the end, or add a new drill.
* **Never change `deck:`** once a deck has shipped, for the same reason.

If you're not sure whether an edit is safe, ask: "does this change what
`<exercise-id>#<step>` refers to?" If yes, don't make the edit as a revision — retire
the old content and add new content instead.

## 9. How to check your work

Build the validator once (it's already built for you if you're working in this
repository's normal toolchain):

```sh
. "$HOME/.ghc-wasm/env"
cd site && wasm32-wasi-cabal build -j2 exe:exercise-check
```

Then run it against the real content and translations:

```sh
"$HOME/.ghc-wasm/wasm-run/bin/wasm-run.mjs" \
  "$(wasm32-wasi-cabal list-bin exe:exercise-check | tail -1)" \
  --content-dir ../content --translations-dir ../translations
```

(Run from `site/`; both directory flags default to exactly this, so plain
`wasm-run.mjs <binary>` from `site/` also works.)

Output is one line per issue, `file:line: CODE  detail`, followed by a summary line and
an exit code — **0 only when there are no issues at all**. Fix issues from the top:
early issues (a bad deck title, a missing field) can cascade into later, misleading ones
further down the same file, so re-run after each batch of fixes rather than trying to
interpret every line from a single run.

Other useful flags:

* `--list-codes` — print every code this document's table (§7) was generated from,
  straight from the validator, so you can confirm the table hasn't drifted.
* `--json` — the same result as machine-readable JSON, if you're scripting something.

## 10. Writing *good* exercises, not merely valid ones

Passing the validator means your exercise is well-formed. It doesn't mean it's a good
exercise. A few habits that make the difference:

* **One idea per question.** A quiz that tests two facts at once is hard to grade
  honestly in the learner's head and harder to write a clean set of options for. If you
  find yourself writing "and" in a question stem, consider two exercises instead.
* **Distractors should be plausible, and drawn from the same page.** "Which button
  selects BANK 1" with distractors `B`, `EDIT`, and "the up directional button" is a
  real test of the material, because all four are real controls mentioned on the same
  page; a distractor like "the power switch" would be too easy to eliminate by pure
  common sense and wouldn't actually test whether the learner read page 15.
* **A drill step's `check:` must be something the learner can actually observe** on the
  device, in the moment — a light lighting up, a sound stopping, a number on the
  display — not an internal state they'd have to guess at. If you can't picture what
  the learner sees when they succeed, the step needs to change.
* **A lookup's task should be genuinely findable by navigating**, not by common sense or
  guesswork. Describe the setting or behavior precisely enough that scanning the manual
  (or the unit's own menus) leads somewhere specific — and remember the target page
  itself must never appear in the body (`E-LOOKUP-SPOILER`); if a hint is going to help
  a stuck learner, put the extra steer there instead, inside `### Hint`.
* **Prefer "why" over "what" in `### Why` blocks.** Restating the answer isn't as useful
  as one sentence on why it's true or what it prevents — it's what turns a fact into
  something a learner can reconstruct later, not just memorize.

## 11. Three complete worked examples

Every one of the three fenced blocks below is a real, complete deck file that the real
validator accepts as-is — this document's own verification runs each one through
`exercise-check`. They are drawn from real pages of `translations/guide-book.md`
(pages 15, 17 and 55).

### 11.1 An explicit choice quiz plus flashcard shorthand in the same deck

Two exercises in one deck, from Guide Book p. 15 ("First, select BANK 1"). The first
authors its full choice list; the second uses `### Answer` plus one plausible
`distractor:` to produce a compact binary flashcard. The forms can coexist in one deck
file, just never in the same exercise.

```exercise
# Choosing a bank

deck: pad-play-choosing-a-bank
chapter: Part: Pad play
tier: intro
summary: Choose BANK 1 in Performance mode and read the bank indicator.
cite: guide-book 15 "First, select BANK 1"

Before you start, turn the unit on and let the `SXC-1` logo disappear.

## Which button returns you to BANK 1

type: quiz
id: q-2-03
cite: guide-book 15 "press the `A` button"
tags: banks, intro

The display shows `D:4` and the `D` button is lit. Which single button do you press
to start selecting BANK 1?

- [x] `A`
- [ ] `B`
- [ ] `EDIT`
- [ ] The up directional button

### Why

Pressing `A` shows `SELECT BANK 1` on the display.

## What determines the lit bank button at power-on

type: quiz
id: q-2-04
cite: guide-book 15 "the state the unit was in when the power was last turned off"
tags: banks, core

Which statement correctly describes the lit `A`-`D` button and pad colors immediately
after power-on?

### Answer

distractor: The unit always starts on `A`, and every pad returns to its factory color.

Whichever state the unit was in when the power was last turned off: the same
`A`-`D` button stays lit and each pad keeps the color it had.
```

*Why these distractors:* `B`, `EDIT` and "the up directional button" are all real
controls discussed on the very same page — a learner has to actually remember which one
returns you to BANK 1, not just recognise the SXC-1's button names.

### 11.2 A drill, including a step with a `verify:` hook

From Guide Book p. 17 ("Tap the pads to make sounds"). The `verify: pad 1 bank A` hook
on the first step is validated now against `translations/midi.md`'s Note mapping table
(pad 1, bank A really is note 36) and will be executed by a later milestone; today it
just adds a muted confirmation line under the step.

```exercise
# Tap the pads

deck: pad-play-tap-pads
chapter: Part: Pad play
tier: intro
requires: pad-play-choosing-a-bank
summary: Tap BANK 1 pads and compare one-shot against looped playback.
cite: guide-book 17 "Tap the pads to make sounds"

## Tap pads and observe one-shot vs. looped playback

type: drill
id: d-2-02
cite: guide-book 17 "Tap the pads to make sounds"
tags: pad-play, intro

Tap pads in BANK 1 and compare a one-shot sound against a looped sound.

### Step

cite: guide-book 17 "A pad you tap lights up white"
check: The pad lights white while the bass drum plays, then returns to its original color once.
verify: pad 1 bank A

Tap pad `1` and listen to the bass drum. It is a one-shot sound: it plays once and
stops on its own.

### Step

cite: guide-book 17 "Tap the same pad again and it stops"
check: The rhythm loop repeats until you tap pad `13` again to stop it.

Tap pad `13` to start the drums-and-percussion loop, then tap it again to stop it.
```

### 11.3 A lookup

From Guide Book p. 55 (the system settings page). Notice the body never says "page 55"
anywhere — that would be `E-LOOKUP-SPOILER` — and the escape hatch for a stuck learner
lives in `### Hint` instead.

```exercise
# Finding Beat Sync

deck: leveling-up-lookup-beat-sync
chapter: Part: Leveling up
tier: stretch
summary: Locate where the system settings document the Beat Sync feature and its default.
cite: guide-book 55 "Sets the automatic beat matching described on p. 18 to ON/OFF"

## Locate the Beat Sync system setting

type: lookup
find: guide-book 55 "Sets the automatic beat matching described on p. 18 to ON/OFF"
id: l-5-04
limit: 60
tags: leveling-up, stretch

Find the system-settings entry that turns Beat Sync on or off, and read what its
default value is.

### Hint

Long-press the `EDIT` button in Performance mode to open the system settings, then
scroll to the Beat Sync line.
```

### 11.4 `chapter: Front matter` — chapter 0 is authorable today

The claim in §1 that there are SIX chapters, not five, and that `Front matter` (chapter
0) is authorable right now: here is the proof. This is a real, complete deck file too —
`exercise-check --content-dir <a scratch content root containing just this deck>
--translations-dir ../translations` reports `exercise-check: 0 issue(s)` for it, exactly
like the three examples above. From Guide Book p. 10 ("Names of parts").

```exercise
# The pads section

deck: front-matter-pads-section
chapter: Front matter
tier: intro
summary: Identify what the pads section is for, per the Names of parts table.
cite: guide-book 10 "A sound is assigned to each pad, and pressing a pad plays it."

## What the pads section is for

type: quiz
id: q-0-17
cite: guide-book 10 "A sound is assigned to each pad, and pressing a pad plays it."

A sound is assigned to each pad. What happens to it when you tap the pad?

### Answer

The assigned sound plays. The pads section is used to play, record, and edit sounds.
```

## 12. Japanese variants: `ja:` lines (M6) — **required**

The course is bilingual (briefs/M6-plan.md): every learner-visible piece of an
exercise carries a Japanese variant **in the same file**, on a line that starts
with `ja:` at column 0, placed **directly under** the English line(s) it
translates. One file, one id, one registry — prompt ids and counts are identical
across languages by construction, so a learner's saved progress applies
regardless of UI language.

> **These variants are REQUIRED, not optional.** Wave 3 of M6 translated all 52
> decks and wave 4 turned the check hard (plan ruling 2: "JA-completeness
> enforcement flips from report-only to hard"). Every learner-visible piece of
> every deck named by `content/exercises/INDEX` must carry one; a piece that
> does not is an **`E-JA-MISSING`** issue, `exercise-check` exits non-zero, and
> `check-site` goes red. Writing a new deck therefore means writing it in both
> languages. The rule the checker applies is one sentence: *the line directly
> below a learner-visible unit's last line must be a `ja:` line* — which is the
> emitter's own substitution rule read backwards, so "the checker is happy"
> and "the JA bundle really contains Japanese here" are the same statement.
> (`E-JA-MISSING` is a **dir**-class code: it is a property of the live corpus,
> so it is not applied to loose `content/fixtures/files/` decks. The `dirs/`
> fixture `E-JA-MISSING--untranslated-option` is the falsifying example.)

The variant's payload is everything after `ja:` (with at most one leading space
dropped, like any field value), and it is a **full replacement line** — it repeats
the marker of the line it replaces (`# `/`## `, `- [x] `, `summary: `, `check: `):

```text
## Which button returns you to BANK 1
ja: ## どのボタンで BANK 1 に戻りますか

summary: Choose BANK 1 in Performance mode.
ja: summary: パフォーマンスモードで BANK 1 を選ぶ。

- [x] `A`
ja: - [x] `A`

Which single button do you press to start selecting BANK 1?
ja: BANK 1 の選択を始めるには、どのボタンを押しますか。
```

**What must carry a `ja:` variant — the complete learner-visible list.** This
table is also exactly the list `exercise-check` enforces: one `E-JA-MISSING`
per row that is missing one, naming the row's kind ("deck title", "exercise
title", "summary: field", "choice option", "deck intro prose", "exercise body
prose", "### Why prose", "drill step prose", "check: field") and the line the
`ja:` line has to go under.

| Learner-visible piece | Where the `ja:` line goes | Payload shape |
|---|---|---|
| deck title (`# ...`) | directly under the `#` line | one `# ...` heading, same level |
| deck `summary:` | directly under the `summary:` line | one `summary: ...` field line |
| deck intro prose | directly under the paragraph's last line | one or more prose lines (they replace the whole contiguous block) |
| exercise title (`## ...`) | directly under the `##` line | one `## ...` heading, same level |
| exercise body prose — the quiz question, the drill's mission goal, the lookup question | directly under each paragraph/table/list block | one or more prose lines |
| choice-list option (`- [x] ...` / `- [ ] ...`) | directly under **each** option line | one option line with the **same** checked state |
| `### Why` / `### Hint` / `### Answer` block prose | directly under each block | one or more prose lines |
| drill step body prose | directly under each block | one or more prose lines |
| step `check:` | directly under the `check:` line | one `check: ...` field line |

**What may NOT carry a variant** (language-invariant by ruling — the build
refuses them loudly, and `exercise-check` never demands one for them): `cite:`,
`find:`, `verify:`, `type:`, `id:`, `deck:`, `chapter:`, `tier:`, `tags:`,
`requires:`, `limit:`, and the role headings themselves (`### Why` etc. — the
UI localizes those labels, not the content). These two lists are exhaustive and
structural: there is no per-file or per-line opt-out from the completeness
check, and the emitter's allowed-field set (`summary`, `check`) and the
checker's are the same set for exactly that reason.
On-device labels (`BANK`, `EDIT`, `SELECT BANK 1`, …) stay in Latin caps inside
the Japanese text, exactly as the hardware prints them.

**How it is processed.** The validator and the app's reader simply *skip* `ja:`
lines — a file with them parses to the exact same deck as the file with them
deleted, issue line numbers keep pointing at the original lines, and a `ja:`
line between two options does not split the choice list. At build time,
`scripts/build-site.sh` (via `scripts/emit-content-bundles.py`) emits two
content bundles the app loads at boot:

* `content.en.txt` — the deck text with every `ja:` line deleted;
* `content.ja.txt` — the same with each `ja:` run **substituted for** the
  line(s) directly above it; anything without a variant falls back to English.

Rules the emitter enforces (each violation is a named build failure): a `ja:`
run must sit directly under the text it translates (never after a blank line,
never first in the file); headings/options/fields take exactly one variant line
of the same shape (same heading level, same checked state, same field key);
prose payloads are non-blank and never structural headings; nothing may start
with the reserved bundle prefix `!SXC1-`; and only column-0 `ja:` counts — an
indented `ja:` is ordinary text, and a variant line is one physical line (field
continuation indentation does not extend it).
