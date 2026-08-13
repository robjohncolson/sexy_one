# Flashcard and review flow

M11 replaces every live self-assessed recall prompt with a real quiz while keeping
the interface calm on a phone. The course has 128 compact flashcards authored as a
correct `### Answer` plus one plausible `distractor:` in both English and Japanese.
At bundle-read time they become ordinary two-option, one-correct Choice prompts. The
correct side is deterministic per exercise id and varies across the corpus.

## Interaction contract

One stage owns at most two action buttons:

1. The learner selects native radio/checkbox options. The action pair is `Check
   answer` and `I’m not sure`; Check stays disabled until something is selected.
2. Checking locks and marks the options, shows correctness/rationale, removes the
   first pair, and renders exactly one review pair:
   - correct: `Good` / `Easy`
   - incorrect or unsure: `Again` / `Hard`
3. Rating is also navigation. Again, Hard, Good, and Easy all record their exact
   grade and advance. On the final prompt they open the next planned session card
   directly, or the next authored course card outside a session; they never stop at
   a second repeat decision. `Again` schedules an earlier return instead of looping.

There is no extra Next or Restart decision after a forward grade. Hints are a native
`details` disclosure rather than a competing action. The ordinary completion summary
remains a fallback for non-rated exercises such as multi-step device drills.

## Persistence contract

`Check` evaluates in the pure exercise engine but emits no `ProgressEvent`. `Rate`
emits exactly one idempotent event whose `review` field is `again`, `hard`, `good`, or
`easy`. The scheduler maps that value directly to its corresponding grade; it does
not infer a different grade from correctness when an explicit review is present.
Legacy events without `review` continue to use the old inference rules, preserving
existing progress files.

An `Again` batch persists its Rate event before advancing, exactly like the other
grades; the scheduler's zero-day interval is what brings the prompt back.

## Progressive-disclosure contract

- Answer options are native inputs inside labels, not buttons.
- Each visible `.wizard-actions` group has exactly two choices.
- Export, Import, and Wipe are separate progress-data disclosures. Export is replaced
  by Save/Share after bytes exist; Wipe is replaced by its confirmation.
- A MIDI channel-mismatch repair replaces device enable/disable until resolved, so it
  coexists with manual Confirm without creating a third drill action.
- The active step of a hands-on drill exposes `Skip for now` / `Yes — done`. Skip
  advances across every remaining unanswered prompt, recording `Skipped` (the
  scheduler's Again grade) and then continuing to the next card.

## Regression anchors

- `exercise-check --self-test` group 24 proves all 128 live Answer cards have authored
  EN/JA distractors, compile to binary Choice prompts, use both correct-side orders,
  and leave zero live Recall prompts.
- `progress-check --self-test` proves the four exact review mappings and explicit
  grade precedence.
- The normal browser suite’s named flashcard assertion walks correct, unsure, Easy,
  and Again paths, verifies the two-action replacements, proves a forward rating
  opens another card without exposing completion/repeat controls, checks no event
  appears at Check time, and reads the exact reviews back from the event log.
- The progress-passport browser regression pins its staged action replacement and
  320 px layout; the mobile route sweeps retain the no-horizontal-overflow guard.
