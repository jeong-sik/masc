# task-809 evidence — [#26656] masc_status backlog 밖 관측 실패 노출

- clone: masc/ (jeong-sik/masc, base main 4f7400f1)
- branch: polish/task-809-status-observation-failures
- commit: 06507a6e80c4a83ce510211135c6f7a7ab126352 (실측 `git rev-parse HEAD` / GitHub PR head 와 일치; 이전 기재 06507a6e0318c94...는 오기 — 8자 접두는 동일)
- PR: https://github.com/jeong-sik/masc/pull/41252 (Draft, base main)

## 소스 좌표

- lib/tool_workspace.ml
  - safe_resolve_agent_name — failure 병행 반환 (:105)
  - safe_current_task — failure 병행 반환 (:121)
  - status_summary_string 내 session_bound 경계 — failure 병행 반환 (:230-233)
  - dispatch 수집 합산 (:234-252, observation_failures fold :243)
  - 배너 문구 일반화 "status below" (:407-413)
  - inspect_state — (agent_state, string) result (:489-521)
  - handle_check — Internal_error 매핑 (:545-559)
- test/test_tool_workspace_coverage.ml
  - break_agents_dir 픽스처 (:233-236)
  - dispatch_status_names_non_backlog_observation_failures (:401-434)
  - dispatch_check_refuses_when_state_reads_fail (:435-467)

(줄 번호는 head 06507a6e 실측 `grep -n` 값)

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
| 1 | degraded 가 보이는 status 화면 (스크린샷) | `status-degraded.png` (130,860B, 3536×840) + `status-degraded.html` + `render_screenshot.py` | PNG 생성: 커밋된 `render_screenshot.py`(Pillow+DejaVu mono)가 status-degraded.html 원문 블록을 래스터화 — 재현 가능. 판독 검증: keeper_analyze_image 로 degraded=true 줄, ⚠ Observation incomplete 배너, observation_failures 1건(Sys_error … Not a directory), Credential: required=yes 확인 |
| 2 | 수정 전 같은 응답 출력 (before) | `contract-before.txt` (2,454B / 67줄) | lib 을 HEAD~1 로 되돌리고 같은 러너 실행. `[healthy] degraded=false` / `observation_failures=[]` / `[check] passed=false` — 읽기 실패를 숨김 (수정 전 동작 재현) |
| 3 | 신규 2테스트 [OK] + before 비교 | `test-ok-lines.txt` (green, 3,833B) + `test-red-lib-at-parent.txt` (red, 8,354B) | green: 신규 2건 [OK] + Test Successful 39 tests run. red: lib@HEAD~1 동일 스위트 → 동일 2테스트만 failures, 총 39 tests run |
- 텍스트 출력은 dune 리다이렉션 환경 특성상 ANSI 이스케이프가 섞여 있다
  (원문 보존). 해시·줄 인덱스는 `evidence/sha-correction.txt` 규칙대로
  `sha256sum`/`wc` 실측값을 그대로 적는다.
- 스크린샷은 커밋에 포함된 `render_screenshot.py`가 status-degraded.html 의
  원문 블록을 그대로 래스터화한 것으로, 브라우저 캡처와 같은 원문 1:1 대조가
  가능하며 폰트/테마 차이에 관계없이 재현된다(래스터화 명령은 README 저장 시점
  기준 `PYTHONPATH=<pillow> python3 render_screenshot.py`).

