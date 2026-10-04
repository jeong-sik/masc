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
| Login results | Small terminal loses summary and cannot reach every result | Implemented; local fixture verified | #40924 integrated parent: 43 native workflow tests and the changed 80×16 scroll PTY passed; earlier browser replay is historical, not current browser or installed-runtime evidence |
| Usage Keepers | Text-only tokens/cost; comparison and measurement coverage hard to scan | Implemented; candidate verified | #40930; separate metric scales, reported/missing evidence and generated UTC time; real HTTP snapshot found all costs unreported |
| Keeper coverage | Unread turn rows and malformed rows both make totals incomplete | Implemented; local fixture verified | #40936 integrated source: 3 native decoder cases, 9 Usage Studio PTY journeys and the usage-row resize/scroll PTY passed; both counts remain visible and partial bars stay suppressed. Historical #40931/browser/live evidence remains separate; current browser and installed behavior are unverified |
| Recent sidebar | Distinguish no events, disconnected observer and current inactivity | Source inspected; historical geometry fixture; state audit pending | Earlier content-floor PTY passed; not rerun for this integration. `masc_tui_acting_pane.ml` separately labels feed opening/closed and no observed events; live/closed/no-record cases pending |
| Dashboard | Health/work summaries already distinguish some missing/partial states | Partially inspected | Audit source timestamps, denominator and navigation to details |
| Work | Narrow summary clips counters; wrapped rollup hides the selected Goal at 40×16 | Implemented; local fixture verified | #40965: full counters at 60/80 columns and selected Goal row, identity and footer through 40×16 navigation passed in color/no-color surface PTY. Earlier snapshot replay is historical, not current browser or installed-runtime evidence. Broader Work audit pending |
| Work baseline time | Server snapshot age labeled as time since first TUI reading | Implemented; local fixture verified | #40972: integrated surface PTY passed in color/no-color; refresh retained baseline and advanced current timestamp with +2/+3/+1 deltas. Historical browser replay remains separate; installed runtime unverified |
| Keepers | Lane state, run progress and failure visibility | Pending audit | Inspect list/detail/chat and runtime observation views |
| Board | Unread, relevance and thread navigation | Historical narrow hint fixture; broader audit pending | Earlier 80-column up/down vote hint PTY passed; not rerun for this integration. List/detail, unavailable data and relevance remain pending |
| Workspace | Repositories, memory, files and diffs | Repository fixture cases verified; broader audit pending | Surface studio selected paths/errors/refresh/PageDown at narrow/short/wide dimensions PASS. Memory/files/diffs still pending |
| System | Clients, runtime/configuration, logs and verification | Parameter fixture cases verified; broader audit pending | Surface studio current/default values, selected doc/long value paging PASS; clients/logs/runtime/harness still pending |

For each pending row, record a concrete symptom before implementing a change.
Verify the resulting behavior with relevant interactions and actual terminal
frames. Do not turn unavailable data into zero or a historical quota into a
current blocking verdict. Finish the audit before declaring the whole goal done.
