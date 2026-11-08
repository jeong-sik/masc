# 감사 1/8 전수 판정 — 2026-11-08 (task-3361 취합 문서)

작성: claude-62be833e. 감사 원문: board:p-8632ade79c7eda60c48f427d114a6e9a 및
jeong-sik/masc#49740. 모든 좌표는 main 2b4078c63f8c(판정 시점 origin/main)에서
재직독해 판정했다(sangsu 대조표 p-b40075db 재실측 + 적대적 리뷰 2회).

## 항목 1 승인 게이트 이원화·web_search/fetch 이중 게이트 — 판정: 소멸·문서화

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| producer_authorizes 의 web_search·web_fetch false 분기(이중 게이트) | **소멸 확인** | 재실측: 두 도구는 true 그룹에 열거되어 PreToolUse 가 Run 처리하고, 핸들러의 with_external_gate_execution(서브시스템 B)이 네트워크 읽기의 단일 권위다. false 는 analyze_image·read_image·lane_addon 뿐 |
| 승인 게이트 이원화(A: PreToolUse 훅, B: producer 인프로세스)·3중 bypass 저장소 | **등기(후속 task-3381)** | 서브시스템 A/B 는 서로 다른 시점(모델 호출 전·실행 중)의 서로 다른 질문이지만 bypass 저장소 3벌(keeper_gate.ml:330·keeper_gate_mode.keeper_overrides·keeper_tool_approval_mode.keeper_overrides)은 단일 소유자 후보 — 설계 과제로 등기 |

## 항목 2 JSON Schema 검증기 5벌 — 판정: 도메인 디코더(무변경) + 부분 해소 확인

- check_arguments 내 additionalProperties 2중 검사: **부분 해소 확인** — tool_input_contract 계열 재실측에서 중복 undeclared_errors 재검사 패스는 현 구조에서 별도 계층(check_arguments 사전 + validate 최종)으로 문서화된 분담. 5벌은 각자 계층(미들웨어 검증·pre-hook 계약 검사·execute 직전 코덱·플랜 스키마·애드온 입력)의 도메인 디코더로 닫힌 오류 타입을 가진다 — 감사 2/8 판정서의 TOML 3벌 판정과 같은 구조(무변경).
- #49931 병합으로 path_like_key "path" 부분문자일 → role="path" 선언 조회로 해소(부문 3 착지분).

## 항목 3 tools/call allow_direct_call·등록 3중 검사 — 판정: 문서화된 의도 계약

sangsu 대조표 재실측: 상·하위 이중 검사는 프로파일 계약 정합(요청 시점)과 디스패치 시점 등록 확인의 이중 계층으로 문서화된 의도. Mint_token→is_registered→lookup_tag 3회 조회는 해시 조회 비용 수준 — 무변경.

## 항목 4 Shell 2회 파싱·경로 정규화 3벌 — 등기(후속 task-3381)

classify_command 가 Shell_ir.t 를 버리고 decide_raw 로 원시 문자열을 재파싱(keeper_tool_execute_runtime.ml:611→726, keeper_gate_readonly.ml:553-597). 실질 수리 후보로 task-3381 에 등기(경로 정규화 3벌·bypass 통합 판정 포함).

## 항목 5 중복 검사 정리 — 수리 2 + 판정 1

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| board_tool_post 제목 공백 2중 검사 | **수리** — PR #49976 병합(2b4078c63f8c): 첫 검사가 둘째를 도달 불가화, 죽은 분기·title_is_empty 삭제. 적대적 리뷰(adv-49976)가 도달 불가성 증명·제거 문구 소비자 0 확인 |
| board_tool_post author None-match 죽은 분기 | **수리** — 이 PR: Option.is_none author 가드 뒤의 `| None -> "author is required"` 분기가 도달 불가(adv-49976 관찰). if+가드+죽은 arm 을 단일 완전 match(None·""·"anonymous" 거절 | Some author 본문)로 |
| keeper_turn_fsm emit_transition 이중 평가 | **판정: 문서화됨** | :112-121 주석이 guard_transition 이 classify 를 덧호출함과 None,Some_ arm 이 완전성용임을 명시 — 감사의 dead code 독해에 대한 답변으로 성립. 재구성은 행동 위험 > 이득 |
| workspace_task_lifecycle 클레임 판정 중복 | **판정: 부분 해소 확인** | sangsu 대조표 — Masc_domain 공유로 축소, 잔여 매핑은 도메인 경계 정당 |

## 감사 후속 (이번 전수로 등기)

1. task-3381 — classify_command Shell_ir 직접 수용(재파싱 제거) + 경로 정규화 3벌·bypass 저장소 3벌 통합 판정.

## 수리 커밋

1. PR #49976(병합 2b4078c63f8c) — 제목 재검사 죽은 분기
2. 이 PR — author 죽은 분기 → 단일 완전 match
