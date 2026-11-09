# 감사 7/8 전수 판정 — 2026-11-08 (task-3367 취합 문서)

작성: claude-62be833e. 감사 원문: board:p-912c22895d030b92cce887d44346909b 및
jeong-sik/masc#49746. 모든 좌표는 main 08c901ec380c(판정 시점 origin/main)에서
재직독해 판정했다(재검증 에이전트 보고 + 수정 파일 전수 직독). 수리 커밋은 이
PR 에 실려 있다.

## 범주 1 Eio 취소 삼킴 — 수리 2 + 판정 4

| 좌표(감사 시점) | 판정 | 근거 |
| --- | --- | --- |
| `bin/masc_tui.ml:13658-13674` fork_daemon catch-all | **수리** | `launch_image_opener` 의 fork_daemon `with _ -> ()` 가 Cancelled 까지 삼켰다. 같은 파일의 표본(13913 원격 정리 fork)처럼 Cancelled 재발산 갈래를 둔다 |
| `bin/masc_tui.ml:25122-25130` fork_daemon catch-all | **수리** | 스폰 실패를 전부 오류로 보고하던 것을 취소는 `finish ()` 만, 나머지는 종료+오류 보고로 갈랐다 |
| `kill_and_reap with _ -> ()` 2곳(25174·25178) | **판정: 무변경** | `Thread.create` 몸통(plain systhread) 안이고 kill_and_reap 는 Unix.kill/waitpid 만 한다 — Cancelled 가 닿을 경로가 없다. 최선형 정리 |
| `keeper_efficiency.ml:620-634` | **판정: 감사 좌표가 성립하지 않음** | 재실측: 파일에 `with _` 자체가 없다. 유일한 catch-all(629, 순수 `Yojson.Safe.from_string` 래핑)에는 취소 지점이 없고 644 의 save 실패 삼킴은 646-649 주석이 캐시-재시도 의도를 문서화한다 |
| `keeper_late_approval.ml:447-469` | **판정: 이미 해소·안전** | 외부 match 가 469행에서 Cancelled 재발산. 내부 466 `exception _ -> None` 은 `Eio_guard.run_in_systhread` 클로저 안(순수 Unix I/O)인데, run_in_systhread 는 취소를 기다리는 Eio fiber 에만 전달하고 클로저로 주입하지 않는다 |
| #49876 계열(Safe_ops·executor_pool_ref 등) | **이전 해소 확인** | 취소 생태계는 Eio_guard 라벨 필수·run_in_systhread_cancel_checked 등으로 이미 구조화(sangsu 대조표) |

## 범주 2 Boolean Blindness — 수리 1

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| `llm_provider/types.ml:1656-1689` validate_tool_result_shape | **수리** | 두 불리언을 닫힌 합타입 `tool_result_shape`(Expect_any·Expect_object·Expect_array·Expect_object_or_array)으로 바꾼다. 둘 다 참이 원시값(`` `Int 42 ``)을 통과시키던 구멍이 사라지고, 합집합 실패용 `Expected_object_or_array` 변형을 더한다. 프로덕션 호출처 0(전 호출처 = test_types.ml)이어서 시험과 함께 갱신했다 |

## 범주 3 어거지 매칭·죽은 분기 — 수리 2 + 판정 3

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| `keeper_execution_receipt.ml:159-247` classify_disposition | **판정: 구조적 의도** | `provider_runtime_failure` bool(149-160)을 받는 guard 4개(225-246)가 한 생성자(Provider_runtime_failure)를 영수증 필드값으로 4분류한다 — 단일 생성자 arm 으로는 표현 불가. 249행 나열 arm 은 "열거를 와일드카드 없이 완전하게 유지"한다는 253-260 주석으로 문서화돼 있다. 감사의 dead code 독해는 이미 응답됨 |
| `keeper_owner.ml:1784-1793` start_child_if_needed | **수리** | 값을 쓰지 않는 `Some _ when` 가드 6연발을 이름 붙인 `gates_closed` 술어 하나로 합친다(|| 단락 평가 순서는 arm 순서와 같다) |
| `keeper_unified_metrics_support.ml:225-235` | **이전 해소 확인** | 225-234 가 네 쌍 match 로 고쳐졌고 227-228 주석이 수정 사실을 직접 문서화한다 |
| `slack_rest_client.ml:411-431` | **수리** | `List.find_opt Result.is_error` / `Some (Ok _)` / `List.map Result.get_ok` 짝을 `List.partition Result.is_ok` 로 바꾼다(순서 보존 — 첫 실패가 그대로 밝혀진다). 정정: 옛 `Some (Ok _)` 분기는 도달 불가가 아니라 타입 체커가 요구하는 분기였다 — 재검토 리뷰(adv-49973 F2·F3)가 바로잡았고, partition 은 그 요구를 `([] | Ok _ :: _)` or-패턴 하나로 흡수한다 |
| `keeper_github_identity.ml:524-566` 6단 피라미드 | **판정: 무변경** | 각 단의 조기 탈출이 `Ok None`(성공)이라 `let*` 로는 펴지지 않는다 — 삼분 step result(Absent·Present·Error) 재설계가 필요하고 현재 코드는 각 단에 근거가 붙어 있다 |

## 범주 4 option 튜플 + invalid_arg — 수리 2

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| `keeper_chat_slack.ml:526-569` 4-튜플 + invalid_arg | **수리** | 네 스트리밍 콜백(`post_stream`·`edit_stream`·`edit_blocks`·`delete_stream`)을 닫힌 레코드 타입 `streaming_transport`로 묶어 단일 `?streaming_transport` 인자로 전달한다. 부분 전달 상태 자체가 타입으로 불가능해져 `invalid_arg "Slack streaming transport must be supplied as one closed set"` 런타임 검사가 제거되었고, `For_testing.adapter_loop` 및 `test/test_keeper_chat_slack.ml` 호출처 전수를 함께 갱신했다 |
| `keeper_tools_agent_core_handler.ml:47-105` | **수리** | 상호배타적인 세 optional 인자(`?prepared_read`, `?prepared_edit`, `?prepared_write`)와 3중 상호배타 `invalid_arg` 검사를 닫힌 합타입 `?prepared_file:Keeper_prepared_inline_files.operation`(`Read \| Edit \| Write`) 단일 인자로 통합했다. `keeper_tool_plan_executor.ml`의 불필요한 3-튜플 분해·재조립도 함께 제거됐다 |

## 범주 5 bool 매칭·피라미드·항등 매칭·Call-by-Value·부분 함수 — 수리 4 + 판정 4

| 좌표 | 판정 | 근거 |
| --- | --- | --- |
| `match !natural_completion with true -> … \| false -> []` 3벌(claude_code:1698·antigravity:1297·muse:1912) | **수리** | `if !natural_completion then … else []` 로 |
| `keeper_tool_filesystem_runtime_owned_read.ml:66-74` | **수리** | `match Sys.is_directory p with true -> not (…) \| _ -> false` → `Sys.is_directory p && not (…)` |
| `keeper_claude_code_runtime.ml:181-194` 9-튜플 전-None match | **수리** | 서로 다른 함수 타입 9개라 튜플이 불가피하다 — 완전-None 검사만 구조적 `None` 비교 if 로 |
| `keeper_owner.ml:1695-1715` 5단 계단식 | **수리** | payload 를 버리는 탐침 클로저 리스트 + `first_present` 재귀로. direct_* 다섯 함수의 성공 타입이 제각각이라 `Result.map (fun _ -> ())` 로 균일화한다 |
| 항등 매칭 5곳(observability:23·markdown:153·otel_tracer:194·complete_stream:631·masc_cost:375) | **수리** | 전부 scrutinee 직접 사용으로 한 줄 해소 |
| `bin/masc_tui.ml:306-315` eager default | **이전 해소 확인(#49776)** — 단 316행 `List.hd (List.rev rows)` 는 **수리**(접기로) |
| `tool_usage_log.ml:69` | **이전 해소 확인(#49776)** | fold 관용구+주석 |
| `bin/masc_tui.ml:39718-39721` List.nth | **판정: 무변경** | index 가 `cursor mod List.length commands` 로 항상 범위 내 — 구조적으로 안전 |
| `runtime_wizard_inventory.ml:278-286` List.hd | **수리** | `[binding]` 분해로(가드 `List.length bindings = 1` 제거) |
| `lib/goal/reliable_change_g1.ml:6-10, 334, 551-554, 897-900` `last`(`invalid_arg`)·`List.hd` | **수리** | 부분 함수 `last`(`invalid_arg`)와 `List.hd sorted_attempts`를 완전 함수 `last_opt : 'a list -> 'a option`과 비공집합 패턴 매칭(`(first_attempt, _) :: _, Some (final_attempt, final_scenario)`) 및 `List.filter_map`으로 전면 교체했다 |
| Result.get_ok 3곳(skill_activation_ledger_model:100·artifact_draft:74·keeper_artifact_draft:76) | **판정: 무변경** | 전부 사적으로 구성한 값의 불변식 위 사용 — artifact_draft:73 이 불변식을 주석으로 명시하고 같은 구조다 |

## 수리 커밋

1. PR #49973(병합 516d72b9f3b0) — `validate_tool_result_shape` 합타입화 + `Expected_object_or_array` + 취소 재발산 2·`slack_rest` partition·항등 매칭 5·bool 관용구 4·`keeper_owner` 2·부분 함수 2
2. PR #49971 — `keeper_execution_receipt` `Provider_runtime_failure` 직접 매칭, `slack_rest_client` tail-recursive fold, `keeper_late_approval` 예외 좁힘
3. 후속 완결 PR — `keeper_chat_slack` `streaming_transport` 레코드화, `keeper_tools_agent_core_handler` `?prepared_file` 합타입 인자화, `reliable_change_g1` 부분 함수(`last`·`List.hd`) 완전 함수화
