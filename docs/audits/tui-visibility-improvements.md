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
| Login results | Small terminal loses summary and cannot reach every result | In verification | `masc_tui_account_login.{ml,mli}`; result scrolling, wrapping and overflow position |
| Usage Keepers | Text-only tokens/cost; comparison and measurement coverage hard to scan | Source inspected; pending implementation | `masc_tui_render.ml:usage_lines`, `lib/tui_decode_usage.mli`; preserve missing values and generated time in any comparison bars |
| Recent sidebar | Distinguish no events, disconnected observer and current inactivity | Pending audit | `masc_tui_observer.{ml,mli}` and sidebar rendering; trace typed data before changing labels |
| Dashboard | Health/work summaries already distinguish some missing/partial states | Partially inspected | Audit source timestamps, denominator and navigation to details |
| Work | Task, Goal, schedule and verification state comprehension | Pending audit | Trace list/detail views and supported interactions |
| Keepers | Lane state, run progress and failure visibility | Pending audit | Inspect list/detail/chat and runtime observation views |
| Board | Unread, relevance and thread navigation | Pending audit | Inspect list/detail and unavailable-data states |
| Workspace | Repositories, memory, files and diffs | Pending audit | Inspect narrow layouts and source/error labels |
| System | Clients, runtime/configuration, logs and verification | Pending audit | Inspect state versus last report and actionable details |

For each pending row, record a concrete symptom before implementing a change.
Verify the resulting behavior with relevant interactions and actual terminal
frames. Do not turn unavailable data into zero or a historical quota into a
current blocking verdict. Finish the audit before declaring the whole goal done.
