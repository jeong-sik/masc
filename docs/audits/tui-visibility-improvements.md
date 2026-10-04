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
| Keeper coverage | Unread turn rows and malformed rows both make totals incomplete | Implemented; retained integration execution | [#40936 integration logs](../evidence/2026-10-04-pr40936-integration/README.md): 3 native decoder cases, 9 Usage Studio PTY journeys and the usage-row resize/scroll PTY passed; both counts remain visible and partial bars stay suppressed. The Studio executable hash is recorded; complete exact-source build provenance is not. Historical #40931/browser/live evidence remains separate; current browser and installed behavior are unverified |
| Recent sidebar | Distinguish no events, disconnected observer and current inactivity | Source inspected; historical geometry fixture; state audit pending | Earlier content-floor PTY passed; not rerun for this integration. `masc_tui_acting_pane.ml` separately labels feed opening/closed and no observed events; live/closed/no-record cases pending |
| Dashboard | Unread source labels repeated/clipped; startup authority barrier affected fixtures | Label improved; local fixtures verified; broader audit incomplete | #40996: [integrated fixture evidence](../evidence/tui-dashboard-reading-status/integration-20261004/2026-10-04-integration-evidence-record.md) records seven affected source/receipt scenarios and Dashboard first-use frames PASS, plus the final four Health-barrier variants. Executed in the local integrated worktree; no execution-time binary hash was captured, so this is not exact-artifact proof. Fixtures refresh after the initial workspace authority is applied and assert the exact held-call workspace. #40989 remains tracked; #40984 still has 63 preexisting type diagnostics. Historical overview/browser evidence is separate |
| Work | Narrow summary clips counters; wrapped rollup hides the selected Goal at 40×16; optional trend can bypass an unfitted backlog | Implemented; retained-binary fixture passed, native closure blocked | [#40965 response evidence](../evidence/2026-10-05-pr40965-review-response/README.md): full counters at 60/80 columns, selected Goal/identity/footer at 40×16, and summary priority at 44–46×19 passed with declared Python dependencies and the recorded retained binary. Copy-sandbox native build failed before PTY (#41188); no fresh build-closure or current browser/installed-runtime claim. Historical captures remain separate. Broader Work audit pending |
| Work baseline time | Server snapshot age labeled as time since first TUI reading | Implemented; local fixture verified | #40972: integrated surface PTY passed in color/no-color; refresh retained baseline and advanced current timestamp with +2/+3/+1 deltas. Historical browser replay remains separate; installed runtime unverified |
| Keepers | Lane state, run progress and failure visibility | Historical roster/navigation fixture audit; runtime/detail audit pending | Earlier roster group3 passed selection identity, unreliable roster/missing target, approvals identity and planning navigation. Not rerun for this integration; runtime/run detail and measurements remain pending |
| Board | Unread, relevance and thread navigation | Historical narrow hint fixture; broader audit pending | Earlier 80-column up/down vote hint PTY passed; not rerun for this integration. List/detail, unavailable data and relevance remain pending |
| Workspace | Repositories, memory, files and diffs | Repository fixture cases verified; broader audit pending | Surface studio selected paths/errors/refresh/PageDown at narrow/short/wide dimensions PASS. Memory/files/diffs still pending |
| System | Clients, runtime/configuration, logs and verification | Parameter fixture cases verified; broader audit pending | Surface studio current/default values, selected doc/long value paging PASS; clients/logs/runtime/harness still pending |

For each pending row, record a concrete symptom before implementing a change.
Verify the resulting behavior with relevant interactions and actual terminal
frames. Do not turn unavailable data into zero or a historical quota into a
current blocking verdict. Finish the audit before declaring the whole goal done.
