# Evidence Record — MASC Performance Diagnosis Reality Check

## 공통 헤더

- 날짜(ISO8601): `2026-05-06T01:38:19+09:00`
- 작성자: Codex
- 결정 ID: `masc-performance-diagnosis-reality-check-2026-05-06`
- 적용 대상: `/Users/dancer/Downloads/MASC_실전_성능_진단.md`, `docs/audit/2026-05-06-masc-performance-diagnosis-reality-check.md`, dashboard keeper summary snapshot path
- 결정 상태: 확정 (current-code reality check and one server-side hot-path reduction)

## 근거 (Evidence)

- 항목: MASC performance diagnosis report currency check and dashboard keeper-summary hot-path reduction
- 출처: local report `/Users/dancer/Downloads/MASC_실전_성능_진단.md`, current source files listed in the evidence table, and focused build/test commands
- 확인일시: `2026-05-06T01:38:19+09:00`
- 신뢰도: High for current source inspection; Medium for user-pasted runtime timing before patched live replay
- 제한조건: local macOS workspace, `masc-mcp` current main `2e04c82c60a1`, no browser live replay yet

| 항목 | 출처 (파일:줄 또는 명령) | 확인일시 | 신뢰도 | 비고 |
|---|---|---|---|---|
| Source report is dated against older code | `/Users/dancer/Downloads/MASC_실전_성능_진단.md:11` says target commit `58ed9c82`; current worktree `git rev-parse --short=12 HEAD` returned `2e04c82c60a1` | 2026-05-06T01:38:19+09:00 | High | Direct local file + git command |
| WS-only mode is already default | `dashboard/src/dashboard-ws-cutover.ts:11-31` | 2026-05-06T01:38:19+09:00 | High | Current source inspection |
| Lightweight shell prime already exists | `dashboard/src/app.ts:114-121` | 2026-05-06T01:38:19+09:00 | High | Current source inspection |
| Server summary already asks lightweight keeper rows | `lib/server/server_dashboard_http_core.ml:304-310` | 2026-05-06T01:38:19+09:00 | High | Current source inspection |
| WS parser Worker path already exists | `dashboard/src/dashboard-ws.ts:56-83` and `dashboard/src/dashboard-ws.ts:409-424` | 2026-05-06T01:38:19+09:00 | High | Current source inspection |
| Compact keeper row now uses runtime-trust summary | `lib/operator/operator_control_snapshot.ml:516-535` | 2026-05-06T01:38:19+09:00 | High | Patched source inspection |
| New summary avoids full causal timeline reads | `lib/keeper/keeper_runtime_trust_snapshot.ml:824-887` versus full timeline/read path at `lib/keeper/keeper_runtime_trust_snapshot.ml:889-1019` | 2026-05-06T01:38:19+09:00 | High | Patched source inspection |
| Future live proof can attribute trust cost | `lib/operator/operator_control_snapshot.ml:580-595` logs `trust=...ms` | 2026-05-06T01:38:19+09:00 | High | Patched source inspection |
| User log still shows dashboard keeper summary latency | User-provided MASC startup log: `keepers_json` sub-op totals around 1.8s-3.0s and `snapshot_json total` around 2.5s-3.1s | 2026-05-06T01:38:19+09:00 | Medium | Runtime log was pasted by operator, not re-run after patch |

## 검증 (Verification)

- 1차: local source and report inspection with `nl -ba`, `rg`, and `git rev-parse`.
- 2차: focused OCaml target build: `scripts/dune-local.sh build test/test_operator_control.exe`.
- 3차: focused executable run: `./_build/default/test/test_operator_control.exe`.
- 재현 결과: pending at record creation; final PR verification must update the command result in the PR summary if either command fails.

## 불확실성 (Uncertainty)

- 미확인 항목: patched binary has not yet been measured against a live browser/dashboard session.
- 영향: if `trust=...ms` drops but total `keepers_json` remains high, the next bottleneck is likely another sub-op (`meta`, `profile`, `agent`, or filesystem contention), not this runtime-trust slice.
- 추가 확인 필요: run the patched server, load the dashboard, and compare `keepers_json:* trust=...ms` plus total `snapshot_json` timing against the pasted log.

## 적용범위 (Scope)

- 영향 받는 영역: dashboard operator summary snapshot, keeper runtime-trust compact row, related focused OCaml build target.
- 제약/배제: no browser protocol change, no gRPC-Web/protobuf migration, no Redis/Saturn/io_uring adoption, no provider pricing/catalog update.
- 롤백 조건: if compact dashboard rows lose required operator fields or tests fail, revert `summary_json` call site to full `snapshot_json` and keep only the timing log until a safer summary contract is added.
