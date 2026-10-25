# Native lifecycle fixture boundaries

The original remote run is `40116634161` at exact source
`32805eb764eab2710262446e925b0ea5c3a44c08`. See
`original-native-run.json`: six suites completed successfully, 245 tests total.
The Claude suite observed 53 passing cases and three explicit failures
(lifecycle 0, 8, 13), then its runner timed out after 600s, exit 124, during
lifecycle 48. Later cases have no completion result. The job log SHA256 is
`188f6c4fe588ab36098c9f14d29cc49ccc0cf2bda50e9d96215d7ec16d65b3b3`.
Alcotest did not reach its final failure summary before termination, so the
raw log contains assertion locations rather than full expected/received values.
This original failure evidence is separate from the following source diagnosis.

The bounded repair changes only the Claude test fixture, not product behavior:

- Start authority case 0 omitted the native frozen unread System message from
  its complete-packet expectation. It now supplies a known-empty immutable
  unread observation through the actual `librarian_front`, checks that exact
  additional Start System carrier, and checks the complete Resume System
  separately. Authority remains User-only; Goal stays System; subsequent
  present/absent/changed-event checks remain.
- Gate case 8 expected a new known-empty unread carrier despite the same
  observation already being held. The fixture now captures the actual seed
  frontier before Resume and checks its `Librarian_unread` digest before
  expecting owner-only Resume. It still checks
  no Gate respawn, typed session-full failure, exact continuation identity,
  unavailable replay and a fresh subsequent ordinary session.
- Checkpointless case 13 called the unified cycle directly outside an executing
  Owner child. It now crosses the actual `run_autonomous_if_idle` mailbox before
  requesting a canonical input writer. Two explicit provider terminals must
  complete, with no AGENT_CORE checkpoint, real ledger turn IDs [1, 1, 2], successful
  same-input/same-output reads, and shared-context serialization between cycles.
- The first unfinished case 48 waited for a repeat-count stop using a CLI
  fixture with no terminal frame. The current Host has no producer of that
  count stop; the constitution also rejects repetition counts as stop authority.
  The fixture now emits a real terminal result after its three acknowledged
  reads. It checks every read executed, `Completed`, the terminal's durable UUID
  and retained observed root context after child activity. The following hook
  failure fixture also emits a terminal and must retain the hook failure.
  No runtime count gate, timeout increase or fallback assertion was introduced.
- The observed passing auth-retry case 37 also used a fixture without a terminal
  and accepted every post-auth error. Its log shows a 300s stream-idle timeout
  before PASS. It now emits a valid assistant/result and requires the actual
  successful terminal after the first cut and second valid auth response.
  The original run's PASS observation remains recorded without relabeling it.

Executed locally without Dune:

```sh
python3 docs/evidence/2026-10-25-native-lifecycle-fixtures/probe_fixture_protocol.py
ocamlc -stop-after parsing -impl test/test_keeper_claude_code_runtime.ml
git diff --check
```

The protocol probe compiles the actual OCaml fixture generator definitions and
executes their generated shell/stdin/stdout protocol. Both variants acknowledge
the same three tool calls; the original emits no result, while the repaired
variant emits exactly one explicit terminal with the expected session and UUID.
An additional auth fixture execution checks the cut first document, valid
second document and subsequent explicit terminal.
`fixture-protocol-check.json` records source/generator/script hashes and results.
It closes stdin after handing over responses so the old script can exit; this
is not a reproduction of the full runtime's 600s wait. Parsing and this protocol
probe do not establish MASC typing, Owner execution or native suite success.

The necessary next native target is `test_keeper_claude_code_runtime`, including
the actual Start/Resume, Gate, Owner-cycle and explicit-terminal fixtures. No
local Dune, native rerun, vendor process or model-success result is claimed.

## Current-parent integration and scheduling callback control

The author fixture was integrated over frozen source47d9 (its parent is ab7639). Current-parent parse and actual generated-process protocol receipts are separate from the authored receipts. The original `compiled_generator_sha256` field hashes the extracted generator source, not its executable; the script and current-parent receipt use `generator_source_sha256`.

Independent review also reproduced an ineffective assertion inside the submission scheduling callback: production intentionally catches that callback exception. The integration fixture now collects `(verification_id, supplied_task, committed_task)` and checks count, identity and handoff equality after the callback returns. A missing callback or a captured stale Task fails outside the isolating guard. No production exception policy or Task behavior changes in this validation layer. Native execution of this integrated source remains a separate check.

The parent source review is bound to47d9/ab7639. Another session is restacking the existing Native Stack; neither that source review nor the older GLM328 runtime certifies a changed remote parent/head or the whole stack.
