# Librarian JEV preflight on the new evidence (2026-10-07)

Issue #41365. Aggregates only; the private reports with requests and Memory
content stay outside the repository.

## Population

Every recorded Librarian run in `~/me/.masc/exact-lane-run-payloads` whose
preflight reached JEV (`jev_preflight.status` = `judged` or `failed`):
297 runs between 2026-10-06 17:59 and 2026-10-07 00:48 KST, from the
deployed binary that sent the whole Memory-pass prompt.

## Request size

| | median | max |
|---|---|---|
| recorded request (whole prompt) of refused runs | 269 KB | 511 KB |
| `current_memory` of refused runs | 228 KB | 433 KB |
| new request (facts left out) | 30 KB | 50 KB |

JEV judged recorded requests up to 86 KB and refused them from 115 KB.
Claims are 75–80% of `current_memory`; leaving out only the per-fact metadata
would not bring the large Keepers under the limit.

## Replay (`masc_librarian_preflight_replay`, binary of commit 3e5512fc5d)

| recorded | replayed | runs |
|---|---|---|
| failed (`max_tokens_exceeded`) | needs_generation | 217 |
| failed (`max_tokens_exceeded`) | keep_current | 11 |
| needs_generation | needs_generation | 60 |
| keep_current | keep_current | 5 |
| keep_current | needs_generation | 3 |
| needs_generation | keep_current | 1 |

- Every replayed request was judged; JEV answered in 0.26 s at the median
  (0.49 s at most).
- `keep_current` rises from 8 to 17 runs. The skipped runs' whole prompts
  total about 0.55 MB recorded and 2.7 MB replayed.
- Of the 69 runs JEV had judged, 65 keep their decision.

## The 17 `keep_current` runs, read by hand

Every one carries no new content: `[no messages]`, a one-line keepalive
("no new signals"), or an autonomous wake whose turns are tool calls with
their results omitted from the prompt.

What the full lane did on the 12 of them it ran (recorded `before`/`after`):

- 10 changed nothing (0 added, 0 removed).
- 2 consolidated existing facts only: absorbed several memories into one
  claim and dropped a transient one. One of them is the run JEV had judged
  `needs_generation` with the whole prompt.

No run lost a new fact. Consolidation of existing facts waits for the next
pass that generates.

## Synthetic corpus (`masc-librarian-preflight-eval`, 12 cases)

| | whole prompt (main) | new request |
|---|---|---|
| false_no_change (of 10 must_generate) | 0 | 0 |
| must_generate confidence | 0.45–0.99 | 0.94–0.99 |
| exact-repeat control | keep_current | needs_generation |
| transient-acknowledgement control | keep_current | keep_current |

The exact-repeat control repeats a current memory; without the facts JEV
cannot see the repetition, so it goes to the full lane.

## Reproduce

```sh
_build/default/bin/masc_librarian_preflight_replay.exe \
  --payloads ~/me/.masc/exact-lane-run-payloads \
  --output <new private report> \
  --config ~/me/.masc/config/runtime.toml \
  --prompt-dir config/prompts
_build/default/bin/masc_librarian_preflight_eval.exe \
  --input test/fixtures/librarian_preflight_adversarial.json \
  --output <new private report> \
  --config ~/me/.masc/config/runtime.toml \
  --prompt-dir config/prompts \
  --keeper synthetic-librarian-preflight
```

Both read the runtime config and send requests to the configured JEV
destination only.
