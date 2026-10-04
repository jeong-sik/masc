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
| Recent sidebar | Distinguish no events, disconnected observer and current inactivity | Source inspected; runtime audit pending | `masc_tui_acting_pane.ml` separately labels feed opening/closed and no observed events; audit live/closed/no-record cases |
| Dashboard | Health/work summaries already distinguish some missing/partial states | Partially inspected | Audit source timestamps, denominator and navigation to details |
| Work | Narrow summary clips counters; wrapped rollup hides the selected Goal at 40×16; optional trend can bypass an unfitted backlog | Implemented; retained-binary fixture passed, native closure blocked | [#40965 response evidence](../evidence/2026-10-05-pr40965-review-response/README.md): full counters at 60/80 columns, selected Goal/identity/footer at 40×16, and summary priority at 44–46×19 passed with declared Python dependencies and the recorded retained binary. Copy-sandbox native build failed before PTY (#41188); no fresh build-closure or current browser/installed-runtime claim. Historical captures remain separate. Broader Work audit pending |
| Work baseline time | Server snapshot age labeled as time since first TUI reading | Pending fix | #40959; fresh fixture displays42-day age; baseline stores server generated_at |
| Keepers | Lane state, run progress and failure visibility | Pending audit | Inspect list/detail/chat and runtime observation views |
| Board | Unread, relevance and thread navigation | Pending audit | Inspect list/detail and unavailable-data states |
| Workspace | Repositories, memory, files and diffs | Repository fixture cases verified; broader audit pending | Surface studio selected paths/errors/refresh/PageDown at narrow/short/wide dimensions PASS. Memory/files/diffs still pending |
| System | Clients, runtime/configuration, logs and verification | Parameter fixture cases verified; broader audit pending | Surface studio current/default values, selected doc/long value paging PASS; clients/logs/runtime/harness still pending |

For each pending row, record a concrete symptom before implementing a change.
Verify the resulting behavior with relevant interactions and actual terminal
frames. Do not turn unavailable data into zero or a historical quota into a
current blocking verdict. Finish the audit before declaring the whole goal done.
