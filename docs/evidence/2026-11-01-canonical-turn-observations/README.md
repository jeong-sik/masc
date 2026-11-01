# Durable turn and inference bus observations

This is a bounded repair for [#27890](https://github.com/jeong-sik/masc/issues/27890),
on Native Stack #47016, PR #47027. It does not complete the issue's checkpoint,
Raw_trace, lifecycle-event, or retention hard cut.

The original durable pipeline allocated fresh bus envelopes for TurnStarted,
TurnReady, TurnCompleted and InferenceTelemetry. Those event identities could
not be found in the committed execution journal. The repair uses one read-only
projector for live delivery and public cursor catch-up:

| Bus observation | Canonical source |
| --- | --- |
| TurnStarted | Agent_turn opened |
| TurnReady | Typed Turn_ready update with the exact prepared tool names |
| InferenceTelemetry | Provider_response_snapshot with a known provider kind |
| TurnCompleted | That Agent_turn closed Succeeded |

Durable completion now follows tool/output settlement. A separate post-checkpoint
collection marker was rejected during independent review: a crash between the
checkpoint and marker would leave an observation that existing recovery could
not reconstruct. No such marker remains. Store-free execution retains transient
assistant-collection delivery, as documented in Event_bus.mli.

The live coordinator reuses a cursor only for scopes sharing the exact same
writer authority. Independent stores opened from a hook receive independent
observers. Shared recursive runs retain explicit per-run audiences and the
existing post-tool-observer settlement gate. An ordinary publication failure
retains its unacknowledged source cursor; retry uses the same event identity and
does not reissue the provider or tool effect. Queue acceptance is not subscriber
acknowledgement. A new live subscription starts at the current prefix; explicit
cursor catch-up handles older committed observations.

Explicit checkpoint sinks remain mandatory persistence authorities. Their Error
or exception still refuses continuation, and their checkpoints are not duplicated
into the journal. An unsuccessful turn does not produce durable TurnCompleted.
The pre-existing Active terminal response resume path without ToolUse remains
outside this repair; no broader recovery success is claimed.

## Executions

Every row names the Test workflow, exact executed SHA and branch. Full regression,
OS process crashes/restarts, deployment and real provider HTTP were not run.
External coding-agent sessions did not run local Dune builds.

| Test run | Head / ref | Actual observation |
| --- | --- | --- |
| [41260927530](https://github.com/jeong-sik/masc/actions/runs/41260927530) | 15597edb51a7ef7ec34198d4f518a689d9d3a052 / fix/canonical-turn-observations-20261101 | Failure: pipeline 82 PASS / 2 FAIL. Both new identity regressions reached “durable turn observation has no committed source event.” |
| [41261604985](https://github.com/jeong-sik/masc/actions/runs/41261604985) | ebb7a30bafdaa7f4a5ac7fd17ec85a97ccd2679b / fix/canonical-turn-observations-20261101 | Failure overall: pipeline 86, journal 21, projection 9 and codec 11 PASS. Telemetry pipeline 8 PASS / 1 FAIL. The requested test/test_agent_event_bridge selector resolved to no suite and was not executed. |
| [41261750963](https://github.com/jeong-sik/masc/actions/runs/41261750963) | a5ef905a7db9733f6ac237c30470fd09242620be / fix/canonical-turn-observations-20261101 | Failure: pipeline 86 PASS / 1 FAIL. The new separate-store fixture failed directory initialization before reaching observation assertions; this is not red proof of the writer-ownership defect. |
| [41261826065](https://github.com/jeong-sik/masc/actions/runs/41261826065) | 5c86eb8c9d09b9d6aa25d4dab4be82baef0d32ce / fix/provider-binding-identity-20261101 | Failure: telemetry pipeline 8 PASS / 1 FAIL, the same missing streaming telemetry event on the parent head. This change does not repair that separate path. |
| [41261888709](https://github.com/jeong-sik/masc/actions/runs/41261888709) | 98220fc8ee4c48e0c64be69df96c49d20dd238f0 / fix/canonical-turn-observations-20261101 | Failure: pipeline 86 PASS / 1 FAIL from the same missing fixture directory; journal 21, projection 9, codec 11 and Keeper execution join 30 PASS. The writer fix was present, but this fixture failure still did not exercise its new assertions. |
| [41262022423](https://github.com/jeong-sik/masc/actions/runs/41262022423) | 233f57232ef4690488adb5c7a3564dcc662d03e3 / fix/canonical-turn-observations-20261101 | Success: **158 actual PASS**, pipeline 87 + journal 21 + projection 9 + codec 11 + Keeper execution join 30. Both independent-store journals retained four observations and delivered their exact canonical envelopes to their respective live audiences. |

The directory setup is corrected in executed candidate
233f57232ef4690488adb5c7a3564dcc662d03e3. Earlier passes are not added to the final
158-case result. Independent source review found no unresolved P0-P2 at this
head; it is separate from the executed result and is not a formal non-author
approval. This is a targeted Test success, not a full-regression success. The
pre-existing streaming telemetry failure was reproduced on the parent and is
not among the five final suites.

The automatic Changelog fragments check rejected the initial issue-number
fragment because it lacked its own PR citation. The final fragment is
changelog.d/47027.md, cites #47027, and passes the repository-relative
`python3 scripts/changelog-fragments.py check-files changelog.d/47027.md` check.

The live tests cover publication after acceptance but before acknowledgement,
reopened cursor catch-up, failed mandatory checkpoints, shared/distinct/absent
recursive audiences, concurrent child runs, and settled provider/turn resume
windows. Reopening the same-process reader is not an OS restart.

## Capture provenance

[manifest.json](manifest.json) records source hashes and exact decoded-log and
retained-derivative hashes separately. Complete decoded logs remain in ignored
artifacts/issues-oldest-20261101 in the primary checkout. Retained selected text
strips ANSI and selects checkout, suite, assertion result and summary lines, with
one final newline. Such a derivative does not replace the original capture hash.
Subsequent evidence-only commits do not retroactively become executed heads.
