# 감사 3/8 전수 판정 — 2026-11-08 (task-3342 / task-3363 / task-3378 취합 문서)

감사 원문: `board:p-a3a1028088cb37c865d4db69cab8cdf3` 및 `jeong-sik/masc#49742`.
관련 헌법 불변식(`docs/constitution.xml`): `<inv id="closed-sum-over-string">`, `<inv id="parse-then-validate-in-core">`, `<item id="string_matching">`.

## 범주 1 예외 / 에러 문자열 Needle 검색을 통한 제어 흐름 분기 — 수리 3 + 경계 파서 판정 6

| 좌표 | 판정 | 근거 및 수리 커밋 |
| --- | --- | --- |
| `lib/core/system_error_class.ml:19-66, 111-119` | **수리 (PR #49922, merge `a3b06d89`)** | `Eio.Exn.Io` / `Unix.Unix_error` 등 구조화된 예외에서 `Unix.error` errno를 직접 해체하여 분류하도록 구조화하고, 문자열 needle 매칭은 구조화된 에러 코드가 없는 `Sys_error` / `Failure` 경계 파싱으로만 한정 (`test_system_error_class.exe` 29/29 통과) |
| `lib/cancel_safe/cancel_safe.ml:17-23` (`is_internal_race_cancel`) | **수리 (PR #49922, merge `a3b06d89`)** | `Printexc.to_string` 접미사(`"Eio__core__Fiber.Not_first"`) 매칭을 제거하고 `Eio.Fiber.is_cancelled` 공개 API 및 구조적 판정으로 교체 (`test_cancel_safe.exe` 8/8 통과) |
| `lib/server/server_dashboard_http_runtime_info.ml:652-686` 로그 링버퍼 문자열 재분류 | **수리 (PR #49975, merge `376b6971`)** | `Log.Ring` 항목에 닫힌 합타입 `diagnostic_kind`를 도입하여 생산 5지점에서 직접 태깅하고 JSONL 복원 행은 적재 경계에서 1회 파싱하도록 변경. `runtime_diagnostics_json`은 문자열 검색 없이 타입 필터로 조회 |
| `lib/server/server_dashboard_http_runtime_info.ml:187-192` (`eio_switch_fork_unavailable`) | **경계 파서 확인 (`<inv id="parse-then-validate-in-core">`)** | Eio 표준 라이브러리가 `Invalid_argument "Switch accessed from wrong domain"` / `"Switch finished"` 문자열로만 던지는 외부 라이브러리 예외를 경계에서 1회 식별하는 함수로 내부 ADT 재파싱이 아님 |
| `lib/keeper_runtime/keeper_terminal_reason.ml` & `lib/keeper/keeper_provider_runtime_boundary.ml` | **경계 파서 확인 (RFC-0371 §6.1)** | 런타임 내부는 닫힌 합타입(`#29929`)을 우선 사용하며, 접두사 파서는 영속화된 구버전 문자열 레코드를 읽어 닫힌 합타입으로 복원하는 재수화(rehydration) 경계 파서임 |
| `lib/exec_policy/keeper_path_check_error.ml:55-62` (`parse_prefix`) | **수리 (PR #49807, merge `7bfef0ef`)** | 구조화된 `Keeper_path_check_error.t` 합타입을 보존하여 전달하고 손실 재파싱 제거 |
| `lib/http_server_eio.ml:54-63` (`lib/http_reqd.ml`) | **경계 파서 확인 (RFC-0512)** | `httpun`/`h2` 외부 라이브러리가 닫힌 상태 쓰기 시 `Failure` 문자열로만 보고하는 예외를 의존성 경계 한 곳에서 봉인 |
| `lib/fusion/fusion_agent_core.ml:199-215` & `lib/keeper_runtime/keeper_internal_error.ml:1258-1269` | **경계 파서 확인 (RFC-0371 B12)** | 타입 우선 경로(`#28852`)가 정본이며 문자열 마커(`[masc_agent_core_error]`)는 프로세스/바운더리 직렬화 복원용 폴백 |
| 샌드박스 CLI(`keeper_sandbox_exec_failure.ml` 등) 및 TLC 출력 파서 4곳 | **경계 파서 확인** | 외부 프로세스(`bwrap`, `docker`, `tlc`)의 비구조화 `stderr`/`stdout` 텍스트를 최초로 읽는 외부 입출력 경계 파서 |

## 범주 2 도구 이름 / JSON 키 / 설정 키 부분 문자열 휴리스틱 — 수리 3 + 경계/보안 판정 3

| 좌표 | 판정 | 근거 및 수리 커밋 |
| --- | --- | --- |
| `lib/keeper/keeper_runtime_contract.ml:117-136` (`path_like_key`) | **수리 (PR #49931, merge `b867966e`)** | 키 이름 `"path"` 부분 문자열 휴리스틱을 삭제하고 `config/tools/<name>.toml`의 명시적 `role = "path"` 스키마 선언 기반으로 전환 (`test_tool_definition_toml.exe` 6건 통과) |
| `lib/tool_telemetry.ml:24-48` (`tool_type_of_name`) | **수리 (PR #49960, merge `268ce94c`)** | `"read"`/`"write"`/`"edit"`/`"execute"` 접두사 추론을 삭제하고 도구 설명자(`policy.readonly_hint`, `executor = Shell_ir`) 및 카탈로그 선언 기반으로 교체 (`test_tool_type_label.exe` 통과) |
| `lib/tool/tool_dispatch.ml:127-135` (`surface_of_tool_name`) | **수리 (PR #49880, merge `7c6a1267`)** | 도구 이름 접두사 추론 대신 등록된 카탈로그 표면 메타데이터 조회로 전환 |
| `env_config_snapshot_core.ml`·`server_dashboard_http_keeper_api_types.ml`·`exec_policy_log_sanitize.ml` 마스킹 키 | **유지 (보수적 보안 스크러버)** | 외부/사용자 자유 형식 JSON·환경변수의 민감정보 유출 방지를 위한 방어적(fail-closed) 로그 마스킹 바닥으로, 선언된 민감 필드와 OR 결합되어 동작함 |
| `bin/masc_tui_types.ml:11568-11576` & `bin/masc_tui_loader.ml:1318-1323` (`lane_id`) | **유지 (네임스페이스 경계 소비)** | 애드온 `output_ports`가 인스턴스 네임스페이스 뒤에 붙이는 패키지 로컬 포트 식별자(`"<instance>/quiz/scorecard"`)의 경계 매칭 |
| `packages/agent_core/lib/agent/agent_tools.ml:133-243` (Levenshtein `<= 2`) | **유지/이관 (`task-3377`)** | 외부 LLM이 생성한 비정형 도구 호출명의 오타 복구 경계 계층으로, 제거 시 제품 동작이 변경되므로 운영자 정책 항목(`task-3377`)으로 분리 |

## 범주 3 자연어 / UI 문구 / 원시 Wire 문자열 분기 — 수리 4 + 경계 판정 3

| 좌표 | 판정 | 근거 및 수리 커밋 |
| --- | --- | --- |
| `packages/agent_core/lib/harness.ml:121-139, 528-542` (`Model_grader`) | **수리 (PR #49997, merge `7b43c5af`)** | 프롬프트가 명시적 `"Score: <number>"` 구조화 마커 줄을 요구하도록 규격화하고 파서가 마커 줄을 우선 파싱하도록 수리 (`test_harness.exe` 17 tests 통과) |
| `lib/keeper/keeper_status_detail.ml:532-557` & `lib/keeper/keeper_status_runtime.ml:161-168` | **수리 (PR #49969, merge `780a319e`)** | 프로바이더 상태 판정의 원시 문자열 비교를 제거하고 `Provider_registry.Resolve_error` 닫힌 합타입으로 직접 분기 (`test_keeper_terminal_reason_typed.exe` 통과) |
| `lib/audit_log.ml:198-207` | **수리 (PR #49969, merge `780a319e`)** | 감사 로그 결과 상태를 닫힌 합타입 `outcome = Success \| Failure of string` 및 경계 파서 `outcome_of_string`으로 구조화 (`test_audit_log.exe` 17 tests 통과) |
| `lib/keeper/keeper_librarian_absorb_gate.ml:6-110` | **판정: 비대상 (`task-3363`)** | `"다."` 및 20자 기준은 자연어 텍스트 문장 분절기(`cut_line`)이며, 실제 지식 흡수 판정은 닫힌 합타입(`Consolidation \| Coverage`)으로 수행됨 |
| `bin/masc_tui_types.ml:11785-11804` (`"Press enter again to answer "`) | **판정: 비대상 (`task-3378`)** | 실제 키 입력 라우팅은 타입화된 상태로 결정되며 해당 문자열 검사는 상태 표시줄 슬롯의 만료 문구 정리(housekeeping)용임 |
| `server_routes_http_runtime_fleet_scan.ml`·`error.ml`·`keeper_types_profile.ml` | **판정: 경계 직렬화/파서 (`task-3378`)** | 외부 프로바이더 에러 메시지 정규화 및 Wire JSON 투영 경계 |
