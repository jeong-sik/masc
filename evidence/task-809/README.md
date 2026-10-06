# task-809 evidence — [#26656] masc_status backlog 밖 관측 실패 노출

- clone: masc/ (jeong-sik/masc, base main 4f7400f1)
- branch: polish/task-809-status-observation-failures
- commit: 06507a6e80c4a83ce510211135c6f7a7ab126352 (실측 `git rev-parse HEAD` / GitHub PR head 와 일치; 이전 기재 06507a6e0318c94...는 오기 — 8자 접두는 동일)
- PR: https://github.com/jeong-sik/masc/pull/41252 (Draft, base main)

## 소스 좌표

- lib/tool_workspace.ml
  - safe_resolve_agent_name — failure 병행 반환 (커밋 후 대략 :100-121)
  - safe_current_task — failure 병행 반환 (대략 :123-140)
  - status_summary_string 내 session_bound 경계 — failure 병행 반환 (대략 :215-233)
  - observation_failures 합산 fold (대략 :246-252)
  - 배너 문구 일반화 "status below" (대략 :401-413)
  - inspect_state — (agent_state, string) result (대략 :489-521)
  - handle_check — Internal_error 매핑 (대략 :546-559)
- test/test_tool_workspace_coverage.ml
  - break_agents_dir 픽스처 (대략 :225-236)
  - dispatch_status_names_non_backlog_observation_failures (대략 :238-274)
  - dispatch_check_refuses_when_state_reads_fail (대략 :276-300)

(줄 번호는 커밋 시점 근사 — 정확 좌표는 `git show 06507a6e` 로 확인)

## 검증 요약 (상세: test-output.txt)

- dune build lib/ → exit 0
- dune build test/test_tool_workspace_coverage.exe → exit 0 (vendor/qrc 미커밋 우회 필요)
- ./_build/default/test/test_tool_workspace_coverage.exe → 39/39 OK, exit 0
  - test-output.txt 참조
- dune build bin/masc_tui.exe → exit 0
- dune build @check → packages/agent_core/test 2건 실패는 main 4f7400f1 에서도
  동일(내 변경 전 동일 오류 확인, 본 PR 범위 밖)

## 증거-계약 1:1 대조 (required_evidence 3항목)

| # | 계약 항목 | 증거 파일 | 확인 방법 |
|---|-----------|-----------|-----------|
| 1 | degraded 가 보이는 status 화면 (스크린샷) | `status-degraded.png` + `status-degraded.html` | PNG 서명·이미지 검증(keeper_analyze_image), 본문은 contract-after.txt 의 `[broken] is_success` .. `Credential:` 마커 구간 원문 그대로 (degraded=true, Observation incomplete 배너, observation_failures 1건 포함) |
| 2 | 수정 전 같은 응답 출력 (before) | `contract-before.txt` (2,454B / 67줄) | lib 을 HEAD~1 로 되돌리고 같은 러너 실행. `[healthy] degraded=false` / `observation_failures=[]` / `[check] passed=false` — 읽기 실패를 숨김 (수정 전 동작 재현) |
| 3 | 신규 2테스트 [OK] + before 비교 | `test-ok-lines.txt` (green, 3,833B) + `test-red-lib-at-parent.txt` (red, 8,354B) | green: 신규 2건 [OK] + Test Successful 39 tests run. red: lib@HEAD~1 동일 스위트 → 동일 2테스트만 failures, 총 39 tests run |
- 텍스트 출력은 dune 리다이렉션 환경 특성상 ANSI 이스케이프가 섞여 있다
  (원문 보존). 해시·줄 인덱스는 `evidence/sha-correction.txt` 규칙대로
  `sha256sum`/`wc` 실측값을 그대로 적는다.
- 스크린샷 본문은 커밋에 포함된 contract-after.txt 원문 블록을 브라우저로
  렌더한 캡처다. 사용자 폰트/테마 차이에 관계없이 원문과 1:1 대조 가능.

