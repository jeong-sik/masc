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
| Keeper coverage | Unread turn rows and malformed rows both make totals incomplete | Implemented; source reviewed | #40936 requires both counts and suppresses comparison bars for partial rows; current native execution remains unverified; historical #40931 evidence is retained |
| Recent sidebar | Distinguish no events, disconnected observer and current inactivity | Source inspected; geometry fixture verified; state audit pending | Existing content-floor PTY PASS. `masc_tui_acting_pane.ml` separately labels feed opening/closed and no observed events; live/closed/no-record cases pending |
| Dashboard | Health/work summaries already distinguish some missing/partial states | Partially inspected | Audit source timestamps, denominator and navigation to details |
| Work | 80x24 summary clips done/cancelled counters and net changes | Implemented; candidate verified | #40947; full counters60/80columns, selected Goal at16rows, color/no-color; live snapshot replay passed. Broader Work audit pending |
| Work baseline time | Server snapshot age labeled as time since first TUI reading | Implemented; candidate verified | #40959; baseline/current server times shown separately; actual refresh retains baseline and updates timestamp/deltas; no process-age caption |
| Keepers | Lane state, run progress and failure visibility | Pending audit | Inspect list/detail/chat and runtime observation views |
| Board | Unread, relevance and thread navigation | Narrow hint fixture verified; broader audit pending | Existing80column up/down vote hint PTY PASS. List/detail, unavailable data and relevance remain pending |
| Workspace | Repositories, memory, files and diffs | Repository fixture cases verified; broader audit pending | Surface studio selected paths/errors/refresh/PageDown at narrow/short/wide dimensions PASS. Memory/files/diffs still pending |
| System | Clients, runtime/configuration, logs and verification | Parameter fixture cases verified; broader audit pending | Surface studio current/default values, selected doc/long value paging PASS; clients/logs/runtime/harness still pending |

For each pending row, record a concrete symptom before implementing a change.
Verify the resulting behavior with relevant interactions and actual terminal
frames. Do not turn unavailable data into zero or a historical quota into a
current blocking verdict. Finish the audit before declaring the whole goal done.
