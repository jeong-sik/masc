# TUI visibility improvement audit

Goal: 반복해서 이와 비슷한 개선이 되는 지점 모두 작업.

This inventory keeps unfinished surfaces visible. Candidate fixture execution,
live HTTP snapshot replay and installed production behavior are separate evidence.
No row below implies a production rollout.

| Surface | Finding or audit question | State | Evidence / next action |
|---|---|---|---|
| Login model selection | Bound models looked absent; retained connections looked like a failed recheck | Implemented | #40863; login workflow and fixture PTY |
| Usage Plan | Reported quota looked like current availability; remaining share hard to compare | Implemented | #40906; reported/remaining bars, source/time, candidate fixture and live snapshot replay |
| Usage Trend | Daily values and missing samples hard to distinguish | Implemented | #40906; fixed-scale daily plots, UTC labels, zero versus missing, responsive paired charts |
| Login results | Small terminal loses summary and cannot reach every result | Implemented | #40924; 32 workflow tests, 11 PTY scenarios, exact browser frame replay |
| Usage Keepers | Text-only tokens/cost; comparison and measurement coverage hard to scan | Implemented; candidate verified | #40930; separate metric scales, reported/missing evidence and generated UTC time; real HTTP snapshot found all costs unreported |
| Keeper coverage | Decoder omits `metrics_read.unread_turn_rows` from partial coverage | Implemented; candidate verified | #40931; both counts retained, partial lower-bound label, before FAIL/after seven PTY journeys PASS; live affected row absent |
| Recent sidebar | Distinguish no events, disconnected observer and current inactivity | Source inspected; runtime audit pending | `masc_tui_acting_pane.ml` separately labels feed opening/closed and no observed events; audit live/closed/no-record cases |
| Dashboard | Health/work summaries already distinguish some missing/partial states | Partially inspected | Audit source timestamps, denominator and navigation to details |
| Work | 80x24 summary clips done/cancelled counters and net changes | Measured defect; pending fix | #40947; surface studio work-narrow FAIL, wide/medium retain counts; resume broader Work audit after fix |
| Keepers | Lane state, run progress and failure visibility | Pending audit | Inspect list/detail/chat and runtime observation views |
| Board | Unread, relevance and thread navigation | Pending audit | Inspect list/detail and unavailable-data states |
| Workspace | Repositories, memory, files and diffs | Pending audit | Inspect narrow layouts and source/error labels |
| System | Clients, runtime/configuration, logs and verification | Pending audit | Inspect state versus last report and actionable details |

For each pending row, record a concrete symptom before implementing a change.
Verify the resulting behavior with relevant interactions and actual terminal
frames. Do not turn unavailable data into zero or a historical quota into a
current blocking verdict. Finish the audit before declaring the whole goal done.
