# Today's session

`#/x/today` is the app's primary training path. It turns the existing course,
saved completion state, and spaced-repetition records into a stable five-card
plan intended to take about 5–10 minutes.

## Planning contract

The planner works in course order and never duplicates an exercise. It selects:

1. up to two exercises with prompts due today, with the most due prompts first;
2. up to two unfinished exercises that already have recall evidence;
3. at least one unseen exercise whose suggested prerequisite decks are complete;
4. remaining ready or incomplete work until the plan contains five cards;
5. maintenance cards only when the course has no incomplete alternative.

Within each group it prefers an exercise kind not already represented, so a
session mixes quizzes and hands-on drills when the eligible work allows it.
Prerequisites remain advisory: they improve the new-card choice but never lock a
lesson.

The selected plan is a snapshot, not a live feed. It is stored in
`sessionStorage` for the current tab and day, with an in-memory fallback when
storage is refused. Completing a card updates its status but does not reshuffle
the remaining cards. “Build a new plan” is the explicit refresh action.

The tab-local plan owns ordering, not completion truth. Every render reconciles
its five exercise ids against the Haskell progress payload's persisted
`masteryDone` list. Work completed after the plan was built, from another course
entry point, or immediately before a hard refresh therefore updates the meter
and rows; wiping progress clears those completion marks again.

## Rendering and navigation

The Haskell route renders a deliberately tiny `#sxc1-session` shell. The static
DOM layer reads the already-validated course bundle and `#sxc1-progress`; it adds
no corpus parser, graph dependency, canvas, or WebGL context to `app.wasm`.

Opening a planned exercise shows `#sxc1-session-coach` as a body-level bar. It
lives outside Miso's managed tree so exercise state updates cannot corrupt it.
The bar links back to the plan and reports the current card and completion count.
When a forward flashcard grade completes the exercise, the DOM bridge consumes the
engine's transient `#ex-summary`, marks the card complete, and opens the next planned
card before the redundant repeat decision can be shown. Every review grade moves
forward; `Again` changes the schedule so the card returns sooner. Hands-on cards
offer only `Skip for now` and `Yes — done`; Skip records unfinished prompts and
continues without claiming success. Safe-area insets and the 320 px layout are
part of its CSS contract.

All session-owned strings have complete English and Japanese records. Exercise
and deck titles continue to come from the fetched language bundle.

## Regression contract

The full browser stages prove that:

- the Home primary action and training index reach `#/x/today`;
- a fresh plan has five unique exercise links, a 5–10 minute estimate, mixed
  exercise kinds, stable ids across route changes, and no canvas;
- synthetic due and in-progress evidence produces a due-first plan containing
  due, continue, and new work;
- the coach is visible, mobile-safe, and outside `#app`;
- completing one real planned quiz marks its plan row and automatically advances to
  a different planned card with no summary/repeat controls exposed;
- deleting the tab-local completion marker after that real completion still
  reconstructs the correct count and row from persisted `masteryDone`;
- a real hands-on card exposes Confirm/Skip, and Skip records all remaining prompts
  as due skipped work before continuing;
- both 360×640 and 320×568 mobile sweeps include the session route.

The pure route self-test separately pins `RSession` parsing and round-tripping.
