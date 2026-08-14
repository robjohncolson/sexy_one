# Mastery journey

The mastery journey is the learner-facing progress surface at `#/x/map`.
The URL is retained for saved links, but the product is no longer a zoomable
DAG. It turns the course’s authored dependency graph into decisions a learner
can use quickly on a phone: what to review, what to continue, and which
foundation to build next.

It is linked from the red Browse path on Home and from the training index. It
does not replace the dominant green Start/Continue action.

## Product contract

- The 51 decks and their 50 authored `requires:` relationships remain the
  source of truth. There is no second hand-maintained curriculum.
- Prerequisites are advisory. They affect readiness and explanatory context;
  every deck remains a normal link and is never disabled.
- The primary recommendation is the first deck with a due prompt in course
  order, otherwise the first incomplete deck.
- The three-item action queue puts that recommendation first, then other due
  work, ready incomplete work, and finally remaining course-order work.
- Progress is projected from the existing schema. `psDone` supplies exercise
  completion and `psRecs` supplies recall evidence, so the journey needs no
  migration and shares progress across English and Japanese.

## Mastery evidence

Prompt maturity stays deliberately small and inspectable:

| Prompt evidence | Tier |
|---|---|
| No saved record | Unseen |
| `reps <= 0` | Fragile |
| `reps == 1` or `interval < 5` | Building |
| Otherwise | Durable |

A deck is Unseen when it has no completion or prompt evidence; Learning until
all exercises are complete; Practiced when complete but recall is not all
Durable; Review due when complete and durable with at least one due prompt; and
Strong when complete, durable, and nothing is due. Due work is not
misrepresented as weak work.

Every action and trail row exposes completed exercises, durable prompts, total
prompts, prompts due today, and prerequisite context. Color is a summary, never
the only explanation.

## Information design

The route has four progressively disclosed layers:

1. an overall Strong count and five evidence totals;
2. a three-item, due-first “Your next moves” queue;
3. one chapter trail at a time, selected with native keyboard-operable tabs;
4. a collapsed complete list of every linked skill.

The chapter trail preserves dependency intelligence without rendering a spatial
graph. Each row says which authored skills it builds on and whether those
suggested foundations are complete. Chapter and overall native `<progress>`
elements make completion scannable without simulating mastery.

## Rendering and mobile boot

`SXC1.Mastery.buildMasteryGraph` remains the pure executable specification in
the 465-check exercise self-test. The shipping projection in
`site/static/index.js` reads only the already accepted content bundle and the
current model’s `masteryToday`, `masteryRecs`, and `masteryDone` fields.

The journey is DOM-only. It creates no canvas or WebGL context and has no shader,
camera, drag loop, animation frame, graph layout, or rendering dependency. Only
the selected chapter’s rich trail is mounted; the complete list stays compact
until the learner opens it.

The same revision hardens the app’s actual mobile boot path:

- the WASM request begins before the content corpora;
- a 31-byte feature probe rejects engines without the SIMD baseline before
  `app.wasm` is requested and gives iPhone/iPad recovery guidance;
- the GHC suggested startup heap is 16 MiB rather than 64 MiB, reducing measured
  post-boot WebAssembly memory from 68,157,440 to 21,037,056 bytes;
- `window.__SXC1_BOOT_METRICS` exposes compile/content/total timing and memory
  for regression diagnostics.

The SIMD requirement comes from the pinned GHC wasm toolchain, not the mastery
surface. WebKit added WebAssembly SIMD in Safari/iOS 16.4.

## Regression contract

The exercise self-test pins prompt/deck tiers, authored edge direction,
topological depth, deterministic coordinates, due-first recommendation, and the
advisory prerequisite rule.

The live journey assertion requires 51 linked skills, 50 authored dependencies,
one recommendation, a three-item action queue, native chapter tabs, a rich trail
smaller than the full course, prerequisite context, native progress meters, and
zero canvases. A separate mobile negative-path assertion impersonates an older
iPhone engine and proves the recovery message appears without any
`app.wasm` request. Another assertion caps boot-time WASM memory at 24 MiB.
Both 360×640 and 320×568 route sweeps include `#/x/map`.
