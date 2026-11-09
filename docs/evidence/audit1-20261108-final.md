# 감사 1/8 전수 판정 — 2026-11-08 (task-3361 취합 문서)

작성: claude-62be833e. 감사 원문: board:p-8632ade79c7eda60c48f427d114a6e9a 및
jeong-sik/masc#49740. 모든 좌표는 main 2b4078c63f8c(판정 시점 origin/main)에서
재직독해 판정했다(sangsu 대조표 p-b40075db 재실측 + 적대적 리뷰 2회).

## 항목 1 승인 게이트 이원화·web_search/fetch 이중 게이트 — 판정: 수리 1 + 경계 문서화 1

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| producer_authorizes 의 web_search·web_fetch false 분기(이중 게이트) | **수리(PR #49967)** | `lib/keeper/keeper_tool_approval_policy.ml` `producer_authorizes`에서 `Tool_web_search \| Tool_web_fetch`를 `true` 그룹으로 이동(핸들러의 `with_external_gate_execution` 서브시스템 B가 네트워크 읽기의 단일 권위). `false`는 `analyze_image`·`read_image`·`lane_addon`뿐 |
| 승인 게이트 이원화(A: PreToolUse 훅, B: producer 인프로세스)·3중 bypass 저장소 | **판정: 계층·합타입·결합 규칙 분리(무변경·문서화)** | 서브시스템 A(모델 호출 전 PreToolUse 대화형 훅)와 B(실행 중 외부 부작용 Gate)는 서로 다른 시점의 서로 다른 질문이며, 3개 저장소 역시 (1) `meta.always_allow`(`keeper_gate.ml:330`, 정적 프로필 불리언), (2) `Keeper_gate_mode.keeper_overrides`(`keeper-gate-modes.json`, `Manual \| Auto_judge \| Always_allow`, 워크스페이스 모드보다 엄격한 방향 `stricter workspace o.mode`로만 결합, `keeper_gate_mode.ml:230`), (3) `Keeper_tool_approval_mode.keeper_overrides`(`tool-approval-modes.json`, `Auto \| Yolo` 대화형 훅 오버라이드)로 닫힌 합타입과 결합 방향이 서로 다르다. 단일 저장소로 합치면 서브시스템 A/B 권한 격리 불변식이 깨지므로 무변경 유지 |

## 항목 2 JSON Schema 검증기 5벌 — 판정: 도메인 디코더(무변경) + 부분 해소 확인

- check_arguments 내 additionalProperties 2중 검사: **부분 해소 확인** — tool_input_contract 계열 재실측에서 중복 undeclared_errors 재검사 패스는 현 구조에서 별도 계층(check_arguments 사전 + validate 최종)으로 문서화된 분담. 5벌은 각자 계층(미들웨어 검증·pre-hook 계약 검사·execute 직전 코덱·플랜 스키마·애드온 입력)의 도메인 디코더로 닫힌 오류 타입을 가진다 — 감사 2/8 판정서의 TOML 3벌 판정과 같은 구조(무변경).
- #49931 병합으로 path_like_key "path" 부분문자열 → role="path" 선언 조회로 해소(부문 3 착지분).

## 항목 3 tools/call allow_direct_call·등록 3중 검사 — 판정: 문서화된 의도 계약

sangsu 대조표 재실측: 상·하위 이중 검사는 프로파일 계약 정합(요청 시점)과 디스패치 시점 등록 확인의 이중 계층으로 문서화된 의도. Mint_token→is_registered→lookup_tag 3회 조회는 해시 조회 비용 수준 — 무변경.

## 항목 4 Shell 2회 파싱·경로 정규화 3벌 — 판정: RFC 경계 및 호스트/원격 분리 계약(무변경·문서화)

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| `keeper_tool_execute_runtime.ml:629`(`to_shell_ir`) vs `keeper_gate_readonly.ml:553`(`classify_script`) vs `hidden_script_findings:926` | **판정: RFC `execute-boundary-is-the-sandbox` §4.1(#32662) 경계 분리(무변경)** | `Keeper_tool_execute_typed_input.to_shell_ir`(`keeper_tool_execute_typed_input.ml:338-365`)는 `#32662` 이후 스크립트를 AST로 파싱하지 않고 단일 `Shell_ir.Simple [shell; "-c"; text]`로 낮춘다(따라서 `to_shell_ir` 결과인 `Shell_ir.t`를 `classify_ir`에 그대로 넘기면 파이프·시퀀스 스테이지가 단일 `sh -c` 노드로 가려져 정적 관찰 판정이 깨진다). 또한 `Keeper_gate`(`keeper_gate.mli:3-5`)는 불투명 JSON 요청(`Keeper_gate.request`)만 받는 비계층적 승인 경계이므로 `Auto_judge` 모드에서만 `Keeper_gate_readonly.classify_script`가 `host_sandbox` 기준으로 파싱하며, Gate 승인 후 실제 unboxed 실행되는 호출만 `hidden_script_findings`(`keeper_tool_execute_runtime.ml:926`)가 `dispatch_sandbox` 기준으로 `escaped_shell` 권고 필드를 산출한다 |
| 경로 정규화 3벌(`Keeper_alerting_path.normalize_path_for_check` vs `Keeper_remote_path.normalize_remote` vs `Env_config_core.normalize_path_lexically`) | **판정: 호스트 symlink 해석 vs 원격/컨테이너 어휘 정규화 분리(무변경)** | `Keeper_alerting_path.normalize_path_for_check`(`Fs_compat.realpath_lenient`)는 호스트 파일시스템의 심볼릭 링크를 실제 경로로 해석하는 반면, 원격 SSH 게스트 경로(`Keeper_remote_path.normalize_remote` → `Masc_exec.Path_scope.lexical_normalize_abs`)와 컨테이너/설정 경로(`Env_config_core.normalize_path_lexically`)는 호스트 커널 `realpath`를 호출할 수 없어 순수 어휘 정규화를 수행한다 |

## 항목 5 중복 검사 정리 — 수리 4

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| board_tool_post 제목 공백 2중 검사 | **수리** — PR #49976 병합(2b4078c63f8c): 첫 검사가 둘째를 도달 불가화, 죽은 분기·title_is_empty 삭제. 적대적 리뷰(adv-49976)가 도달 불가성 증명·제거 문구 소비자 0 확인 |
| board_tool_post author None-match 죽은 분기 2곳 | **수리** — PR #49982 병합: `handle_post_create`와 `handle_comment_add`(:561-578) 모두에서 `Option.is_none author` 가드 뒤의 `\| None -> "author is required"` 죽은 분기를 단일 완전 match로 통합 |
| keeper_turn_fsm emit_transition 이중 평가 | **수리(PR #49967)** | `guard_transition`이 `Turn_fsm.assert_transition_allowed`가 산출한 `Turn_fsm.transition_action`을 직접 반환하게 하여 `emit_transition`의 2차 `classify_transition` 호출 제거 |
| workspace_task_lifecycle 클레임 판정 중복 | **수리(PR #49967)** | `resolve_claim_status` 헬퍼를 추출해 `resolve_claim`과 `decide`(`Masc_domain.Claim`)가 `Masc_domain.task_claim_decision_for_status` 매칭을 단일 경로로 공유 |

## `docs/constitution.xml` 불변식 정합성 매핑

감사 원문(`board:p-8632ade79c7eda60c48f427d114a6e9a`)이 약칭으로 인용한 `<inv single_owner_per_concern>` 및 `<inv parse_at_boundary>`는 `docs/constitution.xml`의 정식 불변식 ID인 `<inv id="single_source_of_truth">`, `<inv id="parse_dont_validate">`, `<inv id="closed_sum_over_string">`, `<inv id="no_ambient_authority">`에 대응하며, 위 수리(PR #49976, #49982, #49967) 및 경계 분리 판정이 해당 불변식을 준수함을 확인했다.

## 수리 커밋

1. PR #49976(병합 2b4078c63f8c) — `board_tool_post` 제목 재검사 죽은 분기 제거
2. PR #49982(병합) — `board_tool_post` author 죽은 분기 → 단일 완전 match
3. PR #49967 — `workspace_task_lifecycle` claim 판정 통합, `keeper_turn_fsm` `guard_transition` 액션 반환, `keeper_tool_approval_policy` 웹 도구 `producer_authorizes` 단일화
