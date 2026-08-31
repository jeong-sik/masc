# One-click dashboard Git probe 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T17:24:40+09:00`
- 작성자: `Codex`
- 결정 ID: `oneclick-dashboard-git-probe-linux-r1`
- 적용 대상: dashboard runtime rev-parse/upstream process capability
- 결정 상태: `추적 필요`

## 근거

- 항목: Git CLI가 배포되지 않은 runtime은 dashboard repo probe process를 spawn하지
  않고 commit/upstream projection을 `None`으로 유지해야 한다.
- 출처: exact Git-context Linux image, container `build-commit`,
  `/health?full=1`, binary hash, fresh/restart background refresh logs
- 확인일시: `2026-08-30T17:24:40+09:00`
- 신뢰도: `High`
- 제한조건: Git CLI와 source checkout이 없는 Linux/arm64 one-click image에서
  측정했다.
- Delta: rev-parse와 upstream probe가 하나의
  `Executable_path.command_available "git"` capability를 공유한다.

## 검증

- 1차: baseline r12 background refresh는 `git rev-parse` missing-executable
  ERROR를 기록했다.
- 2차: dashboard cache concurrency group 6/6이 통과해 기존 cache/argv 계약과 새
  capability=false 경계를 함께 고정했다.
- 3차: fixed r14 fresh/restart background refresh에서 Git spawn ERROR가 각각
  0건이었다.
- 재현 결과: 성공. process restart 뒤에도 missing command를 spawn하지 않았다.

## 불확실성

- 미확인 항목: Git CLI는 있지만 repository가 아닌 path, detached worktree,
  upstream 없는 repository.
- 영향: 이들은 capability를 통과해 기존 git exit status와 typed optional
  projection으로 처리된다.
- 추가 확인 필요: Git-enabled fixture에서 rev-parse와 upstream projection을 별도
  측정한다.

## 적용범위

- 영향 받는 영역: `Server_dashboard_http_runtime_info`의 rev-parse/upstream
  probes와 command capability test seam.
- 제약/배제: runtime image package set, embedded binary commit, network fetch,
  deployed `/Users/dancer/me/.masc`는 바꾸지 않았다.
- 롤백 조건: Git-enabled checkout probe가 건너뛰어지거나, missing Git이 다시
  spawn되거나, cached stale value가 사라지면 롤백한다.
