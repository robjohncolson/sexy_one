# Fable next-steps prompt

Use the following prompt to ask Fable for an independent product and UX assessment.

```text
Act as a senior product designer, UX strategist, and creative collaborator. I’d like an independent, opinionated assessment of what this application should become next.

Current product state

This is a mobile-friendly learning and sample-organization web app centered around the Casio SXC-1 workflow.

The learning side currently includes:

- Guided daily study sessions with accurate progress tracking.
- Multiple-choice flashcards instead of vague “did you know this?” prompts.
- Again / Hard / Good / Easy spaced-repetition grading.
- Automatic advancement after grading—no redundant “repeat card” confirmation.
- A Skip option for tasks that cannot be performed at the moment.
- A deliberately restrained interface: ideally no more than two primary choices at once. Each decision should replace the previous controls so the experience feels continuous.
- A lightweight mastery experience; an earlier WebGL DAG concept was removed because startup and mobile performance suffered.

The Sample Lab currently includes:

- A local sample library with metadata, provenance, waveform information where practical, and basic format validation.
- An SXC-1-inspired pad and bank mockup for planning which samples belong on which pads.
- Project files that can move between desktop and phone using the `.sxc1lab` format.
- A completed phone handoff workflow using native sharing or download.
- Persisted handoff position and receipts, retry handling, and protection against corrupt handoff data.
- Offline/local-first behavior without requiring a server-side account system.
- Responsive mobile support and English/Japanese localization.
- Audacity remains the intended audio editor; the browser app should organize and validate samples rather than become a heavyweight DAW.

The latest completed milestone was the Phone Bridge. It allows a desktop project to be transferred to a phone, resumed at the correct place, and walked through as an SXC-1 loading checklist.

The leading candidate for the next milestone is “Audacity Round Trip”:

1. Import a raw sample.
2. Run an on-demand readiness check for format, 48 kHz/16-bit PCM, clipping, silence, channels, duration, and size.
3. Generate a concise Audacity editing recipe.
4. Re-import the edited export as a new revision.
5. Preserve the original, provenance, metadata, and pad assignments.
6. Let the user choose Use Revision or Keep Current.
7. Ensure phone handoff uses the approved, verified revision.

Important constraints

- Mobile speed and initial load time are priorities.
- Expensive audio analysis should be deferred and performed locally.
- Avoid screens crowded with actions or controls.
- Prefer progressive decisions with no more than two primary buttons visible at once.
- Keep the workflow useful offline.
- Do not duplicate Audacity unnecessarily.
- Preserve user files and make revisions recoverable.
- The experience should feel like a focused instrument, not a generic file manager or administrative dashboard.

Please critique the proposed direction rather than simply agreeing with it. Then recommend the best next steps.

For your response:

1. Identify the most important unresolved user problem.
2. Evaluate whether Audacity Round Trip is truly the right next milestone.
3. Suggest three alternative or complementary directions.
4. Rank the options by user value, implementation complexity, mobile-performance risk, and strategic importance.
5. Select one recommended milestone and describe its ideal end-to-end experience.
6. Propose a small set of acceptance criteria that would define “complete.”
7. Highlight anything we may be overbuilding, overlooking, or sequencing incorrectly.

Please be imaginative but practical. I’m especially interested in ideas that make the learning system and Sample Lab feel like parts of one coherent creative practice rather than unrelated features.
```
