# Actual GLM Goal and Task Dashboard observation

The isolated ordinary HTTP backend on port 51535 reports embedded source
`32805eb764eab2710262446e925b0ea5c3a44c08`, executable SHA256
`98cd486335f7a40d2d49cc05501a52e1b4aee958732453405db8ded17e4de8b7`,
and base `/tmp/masc-goal-canary-32805eb7-glm53`. The model runtime is
`glm-coding.glm-5-3`, with a Docker sandbox. This evidence does not cover
microVM, a fixed vendor System session, installation, or native test results.

The separate Vite frontend served clean Root16 source
`2bc6ae8fa1904d8232c8ea0738e0b14bab824945` on port 53888. The checkout and
installed dependency lock bytes match, SHA256
`5d3c9f77d5f1bb316ee7a78b0798fe727c0513d885b21c525198e0fbeff49cd8`.
`runtime-binding.json` records source file hashes, PID, URL, backend identity,
and the private proxy config hash. The proxy validates incoming Origin.host
against Host before translating both MCP headers to its fixed backend.
The private operator token was used only in local API reads; it was not
printed, entered in the browser, or copied into these artifacts. The ordinary
Dashboard authenticated itself as `Verified @dashboard · admin`.

## Current UI, API and persisted values

Both screenshots were captured from the actual application and directly
viewed. No DOM, fixture data, product source or backend state was edited.

- `goal-task-status.png` shows Goal verifying, Task001 completed, and Task002
  awaiting verification.
- `goal-measurement-proof-pending.png` shows the current criterion, recorded
  observation **3/3**, separate declared target, evidence reference, and the
  warning that an observation record is separate from the final verification.
  It also shows Goal lifecycle **verifying** and verification pending.
- The actual Goals API and saved stores agree on criterion revision
  `cfc96c4817084cd5b0bfd0f66af42e1b`, measurement
  `ff7a4f86482a94260ba642d65c5ae6b2`, and completion state `proof_pending`
  with request `cd97da098881f0de109d028d3de5b57e`.
- Task002 remains `awaiting_verification`, verification
  `vrf-6206a9fbd9d587cba81331282b0e2ee5`. Task001's earlier controlled
  operator-proxy approval is not an independent LLM verdict or Goal acceptance.

`goals-api.json` is the actual tree response. `goal-detail-projection.json`
keeps the actual detail's Goal and Task fields and the full response hash;
nested Keeper response previews and traces are omitted. `persisted-values.json`
records the underlying store file hashes and relevant values; submitted Board
prose is omitted with its existing hash preserved. `cross-layer-check.json`
records 12 comparisons of these facts with the actual rendered DOM.

## Historical measurement observations

`measurement-tool-observations.json` extracts only the actual
`tool_execution_started`/`tool_execution_finished` pairs for
`masc_goal_measure`, with raw trace hashes and sequence locations. They show
1/3 before the first Task approval, 1/3 immediately after approval, and 3/3 after
the second Task's file edit. Each tool result says `reported_only`.

Those earlier values are historical tool evidence, not reconstructed UI
screenshots. The current API/store keeps the latest measurement. The observer
did not independently execute the file metric, approve Task002, run a Goal
verifier, or confirm Goal completion. The visible 3/3 report does not establish
final external acceptance.

## Browser and process lifecycle

TaskSpace32 was created once; finished TaskSpace31 was untouched. Initial
navigation and one subsequent CDP read timed out during the cold Vite load;
observed module requests took 10–25s. A reload in the same Page succeeded.
The initial unsupported `#planning` route normalized to Overview; subsequent
navigation used the application's actual Work and Plans & Goals links.
The Vite log also reports that the `/private/tmp` worker URL was outside its
`/tmp` serving allow list. These screenshots and comparisons prove HTTP-loaded
Goal/Task state; they do not establish Dashboard WebSocket worker delivery.

`browser-completion.json` records the single resolved `finish({keep:[]})`.
`frontend-stop.json` records exact PID/command/cwd verification before SIGTERM
of observer Vite68316. Root's backend and model proxy remain under Root
management. No Keeper message, model call, Task/Goal mutation or approval was
issued by this observer.
