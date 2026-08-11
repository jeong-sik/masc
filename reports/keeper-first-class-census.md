# Keeper 1급화 census — .mli 레코드 필드

생성 2026-08-07 · base `c70a3aaf60`

## 상태

```
keeper_name : string   .mli 레코드 필드   83   (57 모듈)
keeper_name : string   .mli 전체 선언     599  (200 파일)
Keeper_id.Keeper_name.t 를 .mli 타입으로    2
```

`Keeper_id.Keeper_name` (lib/keeper_registry/keeper_id.mli) 은 이미 올바른 파싱 타입이다.
`type t = private string`, `of_string : string -> (t, string) result`.
헤더가 스스로 "Implements Parse, Don't Validate" 라고 적고 있다. 문제는 부재가 아니라 채택률이다.

형제 비교: `trace_id` 는 19곳이 `Trace_id.t`, `task_id` 는 5곳이 `Task_id.t`.
이행이 진행 중이고 keeper 만 2곳에서 멈춰 있다.

## 판정

14 에이전트 (측정 7 + 적대적 검증 7), 실측 76분. 판정된 레코드 53.
검증 단계가 **24건을 정정**했다 (확인 59).

```
EASY    10
MEDIUM  26
HARD    17
```

### EASY (10)

- `completion_authority_wakeup.mli:12` — `delivery`
- `fusion/fusion_delivery_obligation.mli:11` — `accepted_payload`
- `keeper/keeper_board_attention_worker.mli:8` — `contention`
- `keeper/keeper_dashboard_purge.mli:11` — `target`
- `keeper/keeper_event_queue_recovery.mli:36` — `owner_failure`
- `keeper/keeper_event_queue_recovery.mli:45` — `owner_projection`
- `keeper/keeper_identity.mli:78` — `name_bundle`
- `keeper/keeper_runtime.mli:58` — `boot_meta_failure`
- `keeper_metrics/keeper_measurement.mli:49` — `measurement_snapshot`
- `server/discord_presence_bridge.mli:8` — `keeper_presence`

### MEDIUM (26)

- `gate/channel_gate_binding_store.mli:6` — `binding`
- `gate/channel_gate_binding_store.mli:19` — `audit_event`
- `gate/channel_gate_slack_state.mli:15` — `keeper_binding_resolution`
- `gate/gate_protocol.mli:77` — `outbound_message`
- `keeper/keeper_approval_queue.mli:72` — `approved_resolution_request`
- `keeper/keeper_compact_audit.mli:34` — `start_record`
- `keeper/keeper_compact_audit.mli:43` — `complete_record`
- `keeper/keeper_composite_observer.mli:235` — `snapshot`
- `keeper/keeper_execution_receipt.mli:123` — `t`
- `keeper/keeper_execution_receipt_types.mli:50` — `t`
- `keeper/keeper_external_attention.mli:60` — `item`
- `keeper/keeper_gate.mli:15` — `request`
- `keeper/keeper_publication_recovery_availability.mli:26` — `turn_context`
- `keeper/keeper_publication_recovery_scope.mli:7` — `failure`
- `keeper/keeper_reaction_ledger.mli:81` — `event_queue_reaction_evidence`
- `keeper/keeper_runtime.mli:99` — `autoboot_exclusion`
- `keeper/keeper_shutdown_runtime.mli:23` — `corrupt_owner_fence`
- `keeper/keeper_shutdown_store.mli:33` — `corrupt_record`
- `keeper_contract/keeper_approval_queue_rules_types.mli:143` — `approval_rule`
- `mcp_server_eio_call_tool.mli:64` — `keeper_runtime_mcp_log_context`
- `server/server_dashboard_http_keeper_api_types.mli:65` — `keeper_chat_recovery_route`
- `server/server_dashboard_http_keeper_api_types.mli:70` — `keeper_board_attention_quarantine_route`
- `server/server_routes_http_runtime_fleet_scan.mli:102` — `keeper_execution_owner`
- `server/server_schedule_consumers.mli:29` — `dispatch_receipt`
- `trajectory/trajectory.mli:48` — `trajectory`
- `trajectory/trajectory.mli:174` — `accumulator`

### HARD (17)

- `dashboard/dashboard_harness_health.mli:56` — `pre_compact_event`
- `dashboard/dashboard_harness_health.mli:72` — `wake_payload_event`
- `gate/channel_gate_binding_store.mli:35` — `binding_decode_error`
- `gate/gate_protocol.mli:22` — `inbound_message`
- `keeper/keeper_board_attention_candidate.mli:100` — `candidate`
- `keeper/keeper_board_attention_partition.mli:94` — `t`
- `keeper/keeper_compact_policy.mli:77` — `pre_compact_event`
- `keeper/keeper_gate.mli:149` — `auto_judge_owner_failure`
- `keeper/keeper_identity.mli:67` — `parsed_identity`
- `keeper/keeper_registry.mli:33` — `registration_error`
- `keeper/keeper_registry.mli:57` — `register_restarting_error`
- `keeper/keeper_runtime_manifest_housekeeping.mli:33` — `t`
- `keeper/keeper_shutdown_types.mli:158` — `t`
- `keeper/keeper_turn_driver_try_provider.mli:8` — `try_provider_ctx`
- `keeper_contract/keeper_approval_queue_rules_types.mli:100` — `pending_approval`
- `operator/operator_judgment.mli:35` — `record`
- `runtime/runtime.mli:58` — `dropped_runtime_assignment`

## 적용 전에 확인된 두 가지

### 1. dune 경계 (차단)

`Keeper_id` 는 `masc_keeper_registry` 가 제공한다. EASY 10 중 9는 이미 의존하지만
`lib/keeper_metrics` 는 의존하지 않는다. 의존을 추가하는 것은 타입 이행이 아니라
**라이브러리 경계 재배치**이므로 범위 밖으로 둔다. HARD 17 중 상당수가 같은 성격일
가능성이 있고, 그렇다면 이 작업의 실제 비용은 타입이 아니라 경계에 있다.

### 2. 쓰기 전용 필드

`server/discord_presence_bridge.mli:8 keeper_presence.keeper_name` 은 **읽히지 않는다**.
쓰기 2곳(`.ml:42`, 테스트 헬퍼), 소비자 `keeper_has_active_binding` 은 `running` 과
`bound_channels` 만 본다. 읽지 않는 필드를 파싱 타입으로 올리면 Error 분기만 늘어난다.
이런 필드는 변환이 아니라 삭제가 맞다.

**주의**: 전수 스캔은 하지 못했다. `.keeper_name` 점 접근만 세는 방식은 구조분해
(`{ keeper_name; _ }`) 를 놓치고, 모듈 basename 으로 파일을 좁히면 재-export 를 통한
소비자를 놓친다. 실제로 `keeper_approval_queue_rules_types` 는 그 방식으로 0 이 나왔지만
검증 에이전트는 `entry.keeper_name` 44건을 보고했다. 손으로 확인한 것은
`discord_presence_bridge` 하나뿐이며, 나머지는 후보일 뿐이다.

## 다음

1. 각 레코드에 대해 **읽히는가**를 먼저 판정 (변환 대상에서 쓰기 전용 제외)
2. EASY 중 dune 의존이 이미 있는 것부터 적용
3. HARD 17 은 경계 재배치가 필요한지 먼저 분류
