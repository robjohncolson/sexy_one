# Weekly Pulse

M10 adds `#/x/week`: a phone-first reflection over the learner's existing
review schedule and a new bounded recent-history ledger. It answers four
questions without creating an account or analytics stream:

1. How steady has practice felt over the last seven UTC days?
2. How much review is coming over the next seven days?
3. Which skills have fresh positive evidence, and which deserve another pass?
4. What is the single most useful next action?

The route is linked from Home's library, the training index, Today's Session
completion, and the Mastery journey. It is a progressively hydrated semantic
DOM surface: no canvas, WebGL context, animation loop, or visualization
dependency.

## Durable data contract

Progress schema v3 adds a `W` record to the existing line-oriented
`SXC1PROGRESS` payload:

```text
W <TAB> day <TAB> deckId <TAB> exerciseId <TAB> promptId-or-- <TAB> grade
```

Grades are the scheduler's stable integer alphabet: Again=0, Hard=1, Good=2,
Easy=3. A `-` prompt marks exercise completion. The record intentionally omits
elapsed time, answer content, hints, MIDI messages, and device information.

Only the latest 200 marks survive. The same cap is enforced while folding live
events and while decoding imported text, so a large or hostile passport cannot
silently produce an unbounded in-memory ledger. The ledger stays inside the
existing `sxc1.progress` key and therefore moves through the existing validated
export/import passport; no second store, codec, or transfer path exists.

Schema v1 and v2 files migrate forward without losing scheduler records,
completion counts, streaks, or the last-prompt pointer. Their weekly ledger
starts empty because historic outcomes cannot be reconstructed truthfully. In
that state the UI says detailed tracking begins with the next answer, while its
forecast and recent-practice fallback already use the saved scheduler records.

## Projection rules

- The rhythm counts distinct active days in `[today-6, today]`. It uses ledger
  days first and falls back to prompt `lastSeen` days for migrated profiles.
- Answers and steady answers use prompt-bearing ledger marks only; completion
  marks do not inflate either count. Good/Easy are steady evidence.
- The forecast buckets every known prompt due in `[today, today+6]`. Anything
  overdue joins Today's bar instead of disappearing into the past.
- Skills in motion rank decks by recent Good/Easy marks. Before v3 has new
  history, recently seen prompts with positive repetitions provide a clearly
  labelled fallback.
- Friction ranks recent Again/Hard marks first, then lifetime lapses and a low
  ease factor. It is guidance only: it never locks or penalizes a lesson.
- The focus is due review first, then the highest-friction exercise, then the
  next unfinished deck, and finally a mixed maintenance session.

All day arithmetic matches the scheduler's UTC `DayNum`; browser-local weekday
labels are display-only.

## Mobile, language, and privacy contract

The seven forecast bars are ordinary list items and remain visible at 320 px.
Both insight columns collapse to one column, controls remain at least 44 px,
and the route participates in both small-phone overflow sweeps. Every string is
complete in English and Japanese; the shipped Japanese flow asserts the title,
forecast, both insight headings, action, and seven bars.

`window.__SXC1_WEEKLY` exposes bounded diagnostic values for regression tests.
Nothing is transmitted. The footer states that the data stays on the device
and that only the latest 200 coarse marks are included in the progress
passport.

## Regression anchors

- `exe:progress-check --self-test` pins v1/v2 migrations, exact v3 wire bytes,
  ordered event-to-mark projection, completion marks, codec round trips,
  malformed-row isolation, and the 200-entry cap.
- `exe:exercise-check --self-test` pins `RWeekly` parsing, generic-route
  precedence, and route round-tripping.
- `scripts/browser-check.mjs` injects an independently specified three-day
  week and requires the exact outlook `[1,0,1,0,0,0,1]`, the recent evidence
  counts, friction, due-first focus, training-index discovery, Mastery link,
  zero canvases, Japanese rendering, and both 360/320 px route sweeps.
