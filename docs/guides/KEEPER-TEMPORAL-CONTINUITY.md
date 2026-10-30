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
report retains the running binary's build identity separately from the exact
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

Provider-input snapshots contain the last prepared request of a turn, not every
tool-loop or failover attempt. Typed response range evidence does not contain a
wire body hash. The report therefore leaves body-level input/response binding
`not_established`; it does not promote preparation to remote receipt.

A correct late answer may still use raw history or Recall. W's presence and a
correct answer do not establish Librarian's causal contribution. The report
leaves that attribution `not_established`. A full comparison across runtimes,
long-running server restarts and isolated raw-history/Memory/W treatments needs
additional experiments.

`report.json` is the common observation input for future TUI presentation;
`report.md` provides an immediate human-readable view. This schema is not the
older `/measurement` report schema and is not yet a new TUI screen. Neither view
becomes scheduling or history-retirement authority.

## Validate the harness boundary

```bash
python3 -m unittest discover -s scripts/tests -p test_keeper_temporal_continuity.py -v
pyright --outputjson scripts/harness/workload/keeper_temporal_continuity.py scripts/tests/test_keeper_temporal_continuity.py
ruff check scripts/harness/workload/keeper_temporal_continuity.py scripts/tests/test_keeper_temporal_continuity.py
```

These are HTTP/MCP fixture tests of the collector and judge protocol. They do not
execute real models. Retain real-run output separately under `artifacts/` and
select private-data-free evidence intentionally before publication.

[Evidence] Owner provider-input, delegate reply and turn-record contracts at the
implementation source; official Noul request/response documentation checked
2026-10-30. Confidence High for the API boundaries; semantic continuity requires
the actual run's retained observations and judgments.
