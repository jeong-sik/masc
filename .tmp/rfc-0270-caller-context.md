# RFC-0270 Caller Context

Source, 2026-06-20 세션 관측 (메모리
`reference-masc-conveyor-admin-merge-red-ci-main-build-breaks.md`):

- 같은 날 컨베이어가 main-RED 를 3연쇄로 만들었다. 각 incident 의 fix
  (#21739/#21753/#21758) 는 옳았으나, 같은 근본(컨베이어가 CI 완료 전
  admin-merge)이 7시간 만에 재현됐다.
- 측정: 4개 incident PR (#21714/#21721/#21722/#21753) 의 merge 시점
  required check `CI Gate` 가 전부 `cancelled` 또는 `failure` 였다
  (success 0건).

Owner direction, 2026-06-20:

- AskUserQuestion 에서 세 선택지(green HEAD 모니터링 / merge gate 근본
  수정 / in-flight fix 도움) 중 **"근본: merge gate RFC"** 를 선택.
- 즉 call-site 패치(whack-a-mole)를 멈추고, 우회 경로 자체를 닫는 설계를
  요구.

Design constraints:

- 결정론적 server-side enforcement (branch protection). 머저가
  operator/keeper-side(`lib/ide/ide_bridge.ml` gh_pr_merge 트리거)라
  워크플로 조건으론 강제 불가.
- 증상 억제(telemetry counter / advisory 강등 / flaky 재시도) 금지 —
  CLAUDE.md 워크어라운드 누적 기준에 따라 우회 경로를 닫는 root fix.
- throughput trade-off (컨베이어 cadence vs CI 대기)를 정직하게 기술하고,
  대안(merge queue)을 함께 제시.

Verification expectation:

- RFC numbering, ledger, §1 enforcer 통과.
- Replay: 4 incident PR 의 `CI Gate` 상태로 enforce_admins:true 가 전부
  차단함을 보인다 (§6.1).
- (선택) TLA+ bug model: clean spec 통과 + buggy spec(admit-while-not-green)
  invariant 위반.
- 머지 정책의 다른 축(RFC-0235 stale-base content revert)은 직교로 둔다.
