# PR #41178 parent integration — 2026-10-05

Candidate: original head `805b2a47ded80e9f076a5dcdda7a5ccb3a047be2` with a real, clean pending merge of published parent #41172 `599bcfd939f2f0039d2d93181aa95999a5a2383c`. The live REST response omitted the stack key; membership is unknown. This does not retarget or modify Native Stack membership.

The Curator availability-wake implementation and its seven new regression cases remain intact. Integration required no product or test edits. The changelog fragment now includes the required PR citation.

## Executed checks

- Focused wrapper build: PASS (handle 70400), only the two test targets listed in [checks.json](checks.json).
- Curator suite: 13 tests PASS (handle 44989), including seven new availability/resume cases. Executed from `test/` for the prompt fixture path.
- Exact-output registry/catalog suite: 15 tests PASS (handle 91933), including publication availability notifications.

The [build log](focused-build.log), [Curator log](curator-native.log), and [registry log](registry-native.log) retain their exact captured bytes. Binary SHA-256 values and commands are in [checks.json](checks.json). All handles completed before evidence preparation; production and test sources were unchanged during execution.

These are 28 focused native tests, not a full suite, live provider run, PTY/browser run, deployment, or release-candidate proof. Earlier evidence under `2026-10-04-curator-activity-resume` remains historical and is not relabeled as current execution. Raw logs may contain trailing blank lines reported by whitespace checks.
