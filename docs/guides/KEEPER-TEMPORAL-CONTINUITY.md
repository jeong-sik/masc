# Observe a Keeper across turns

`scripts/harness/workload/keeper_temporal_continuity.py` records a real Keeper's
constraints, corrections, interruptions and continuation. It writes a private
JSON report, a readable Markdown view and original API responses under a new
output directory. It does not add a runtime gate or decide when Librarian runs.

The checked-in scenario has twelve ordinary message turns and one Keeper
shutdown/restart. Expectations are held outside the Keeper prompts. The scenario
changes a hypothesis twice, leaves an investigation unfinished, changes topic,
and asks the Keeper to resume without repeating the original constraints. Two
steps request an actual read of the Keeper's own context. The harness does not
restart the server or touch another Keeper.

## Run a fresh scenario

Use the configured runtime's exact ID and an image promoted in Docker's own
catalog. This first runner supports Docker; it does not provision Apple guests.
The server may be an isolated campaign server, using the ports in
[the benchmark runbook](../BENCHMARK-RUNBOOK.md#isolated-server-ports).

```bash
python3 scripts/harness/workload/keeper_temporal_continuity.py run \
  --mcp-url http://127.0.0.1:9400/mcp \
  --token-file /path/to/operator.token \
  --expected-base-path /path/to/campaign \
  --expected-binary-commit '<verified-source-commit>' \
  --expected-executable-sha256 '<verified-server-sha256>' \
  --keeper continuity-campaign-unique-name \
  --runtime-id '<configured-runtime-id>' --sandbox-image base \
  --scenario scripts/fixtures/keeper-temporal-continuity/scenario.json \
  --request-timeout 60 --wait-timeout 300 --poll-interval 1 \
  --output artifacts/temporal-continuity/run-unique
```

The three durations are caller-selected observation/HTTP waits. They do not
limit the Keeper's turns or tokens. If an operation does not settle, the report
retains its operation ID; the harness neither submits that message again nor
cancels an unsettled turn. Observe the existing operation with `capture`.

Creation uses `create_only=true`; an existing Keeper is refused. This run's
Keeper uses `on_demand`, no Board interests or mention targets, and no sandbox
network. Stop/restart preserves its metadata and session. After all scenario
operations settle, shutdown is observed and evidence is retained. A failed or
interrupted run leaves its observed state and does not pretend cleanup finished.

The base path is checked against `/health?full=1` before Keeper writes. The
expected candidate commit and executable digest are also required by `run` and
must match that health response before MCP initialization or Keeper creation.
The report retains the running binary's build identity separately from the exact
harness source bytes and digest. A run against an installed main binary does
not test a pending PR's binary. Existing output directories are refused. Output
directories are private (0700) and files are private (0600). Bearer values and
HTTP authorization headers are not written into reports.

## Capture existing operations without replay

```bash
python3 scripts/harness/workload/keeper_temporal_continuity.py capture \
  --mcp-url http://127.0.0.1:9400/mcp \
  --token-file /path/to/operator.token \
  --expected-base-path /path/to/campaign --keeper continuity-campaign-unique-name \
  --operation-id '<original-operation-id>' \
  --request-timeout 60 --wait-timeout 300 --poll-interval 1 \
  --output artifacts/temporal-continuity/operation-unique
```

`--operation-id` may be repeated. This mode initializes an MCP session, reads
operation status and reads owner API exports. It does not create a Keeper or
send a new chat message.

## Measure meaning separately

After a complete scenario capture, semantic assessment can run independently of
the server and without a MASC token. The source capture remains unchanged. A
fresh output retains its source digest and original scenario observations.
Keep the original capture directory together: assessment verifies the harness
snapshot and raw-event digests, then rejoins the completed reply, canonical
input, W, turn record, tool calls and transcript to their exact owner responses.
A report containing only claimed status labels or edited replies is refused
before a judge request. This checks retained-record consistency; it is not a
server signature or proof of remote authenticity. Use an original `run` report,
not an earlier assessment report.

```bash
python3 scripts/harness/workload/keeper_temporal_continuity.py assess \
  --keeper continuity-campaign-unique-name \
  --capture-report artifacts/temporal-continuity/run-unique/report.json \
  --runtime-config /path/to/campaign/.masc/config/runtime.toml \
  --judge-endpoint https://api.typesafe.ai/v1/systemone \
  --judge-model jev-latest --request-timeout 60 \
  --output artifacts/temporal-continuity/assessment-unique
```

The judge uses `TYPESAFEAI_API_KEY` and honors `typesafeai.excluded_keepers` in
the supplied configuration. `run` also accepts these three judge options to
assess immediately after capture. Do not send another Keeper's private capture
to a judge without authorization.

Each proposition names its evidence scope: `reply`, `working_state` or
`tool_calls`. The judge receives only reference steps up to that checkpoint,
the scoped observed evidence and the proposition. Future corrections and
expectations never enter a Keeper prompt. Requests are frozen before sending;
the report retains their SHA, actual response model and raw probability. A
missing W message remains unavailable for W assessment. An observed empty tool
invocation list can still be assessed as empty; it is not an unavailable read.

[Noul](https://docs.typesafe.ai/primitives/noul) returns the probability that a
proposition is true. It is not a memory-retention percentage. The harness has
no keyword success test or probability threshold. Exit zero means the requested
observations/assessment were recorded, not that continuity passed. Failed or
missing evidence is explicit; `continuity_pass` remains null.

## Evidence joins and limits

| Observation | Exact source | What it establishes |
|---|---|---|
| Chat operation | `masc_keeper_delegate_status`, exact target and operation ID | Admission and terminal operation state |
| Original answer | `outcome_ref` + `completed_reply.turn_ref`, full `replies` | Original assistant reply for that operation; a success receipt alone is not an answer |
| Last prepared input | `/provider-input?turn_ref=...`, then listed parts | Canonical prepared messages/system/tools; each part's UTF-8 length and SHA match its manifest |
| Working state in that input | Message origin and `masc.librarian_working_state.v1` metadata | Structurally tagged W; prose claiming to be W does not qualify |
| Recorded actions | Exact turn record's execution IDs → exact `/tool-calls` reads | Recorded invocation/outcome; external domain effects need their own evidence |
| Transcript | Exact `/turn-transcript?turn_ref=...`, `found=true` | The owner retained that turn's transcript |

Canonical provider-input snapshots contain the last prepared request of a turn.
Typed response range evidence does not contain a wire body hash. The report therefore leaves body-level input/response binding
`not_established`; it does not promote preparation to remote receipt.

A correct late answer may still use raw history or Recall. W's presence and a
correct answer do not establish Librarian's causal contribution. The report
leaves that attribution `not_established`. A full comparison across runtimes,
long-running server restarts and isolated Memory/W treatments needs
additional experiments.

## The compact view

Each save also writes a compact `view.json`, identifying the authoritative
`report.json` by path and SHA-256. It carries the binary and harness identity,
timeline, W counts, Memory readiness, replies and raw semantic probabilities with the actual judge model. Missing W remains unknown;
recorded capture, successful operation and semantic judgment are distinct.

`report.md` is a readable file view. Neither view is a scheduling or
history-retirement authority.

## Prior-art boundaries

[Letta's context architecture](https://www.letta.com/constitution/#context-architecture)
separates the active window from persisted, retrievable message history and
describes recursive summaries replacing evicted messages.

[LangGraph checkpointers](https://docs.langchain.com/oss/python/langgraph/checkpointers)
identify historical graph states by thread/checkpoint and distinguish inspecting
state from replay, which re-executes later model/API steps. Here `assess` reads
retained observations; it does not replay the Keeper. Keeper/turn/generation and
body identities are checked separately from semantic probabilities.

[근거] Both official documents checked 2026-10-30T19:09:09+09:00; confidence
High for the documented mechanisms. Neither source establishes MASC's measured
continuity or equivalence between these products.

[Evidence] Owner provider-input, delegate reply and turn-record contracts at the
implementation source; official Noul request/response documentation checked
2026-10-30. Confidence High for the API boundaries; semantic continuity requires
the actual run's retained observations and judgments.
