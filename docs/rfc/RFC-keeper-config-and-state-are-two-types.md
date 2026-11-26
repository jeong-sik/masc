---
rfc: "keeper-config-and-state-are-two-types"
title: "Keeper 설정과 실행 상태를 두 타입으로 나눈다 — 설정은 TOML 에서만 읽고 상태 파일은 설정을 담지 않는다"
status: Draft
created: 2026-11-26
updated: 2026-11-26
author: claude
supersedes: []
superseded_by: null
related: ["keeper-row-facts-are-kept-in-memory-by-their-writers", "a-persons-keeper-runs-on-the-engine", "every-durable-store-has-one-boot-policy", "0405"]
---

# RFC keeper-config-and-state-are-two-types: Keeper 설정과 실행 상태를 두 타입으로 나눈다

- 이슈: #27357
- 코드 좌표는 `origin/main` `a26795cff182c` 에서 읽었다.
- 운영자 결정(2026-11-26): 코드보다 이 RFC 를 먼저 쓴다.
- 이 문서는 설계만 담는다. 코드는 §5.3 의 층에서 쓴다.

## 0. 요약

Keeper 하나의 값은 레코드 하나(`keeper_meta`)에 들어 있다.
이 레코드는 두 가지를 섞어 든다.
하나는 운영자가 Keeper TOML 에 적은 설정이다.
다른 하나는 Keeper Owner 가 쓰는 실행 상태다.
상태 파일은 설정을 저장하지 않는다.
그래서 파일을 읽으면 설정 칸 열다섯이 자리 채움 값으로 찬다.
타입은 그 값이 진짜인지 말해 주지 않는다.

같은 뿌리의 결함을 부르는 자리마다 일곱 번 고쳤다(§1.2).
저장소 규칙은 두 번째 수리부터 경계를 고치라고 한다.
이 RFC 가 그 경계를 고친다.

결정은 넷이다.

1. 설정은 새 타입 `Keeper_declaration.t` 만 든다. Keeper TOML 을 읽어서만 만든다. sandbox 는 닫힌 합이고, 갈래마다 필요한 값을 꼭 든다.
2. `keeper_meta` 는 Owner 가 쓰는 실행 상태만 든다. 저장 JSON 과 필드가 하나씩 맞는다. decoder 는 아무 칸도 지어 채우지 않는다.
3. 둘 다 필요한 쪽은 둘을 따로 받는다. 턴은 시작할 때 선언을 한 번 읽는다. 턴 도중 Owner 값을 다시 받으면 상태만 바뀐다.
4. 저장 JSON 에서 설정 사본 둘(`instructions`, `agent_core_env`)을 뺀다. schema 는 v3 이 된다. 옛 파일을 읽는 코드는 만들지 않는다. changelog 에 Fresh state required 를 적는다.

지우는 것은 §3 D5 에 모았다.
덮기와 덮은 값 읽기, `Update_profile`, 왕복 재현, 드리프트 지표, `id`, 자리 채움 시험이다.

## 1. 증상

### 1.1 숫자

`origin/main` `a26795cff182c` 에서 셌다.
다시 세는 명령은 §11 에 있다.

| 무엇 | 값 |
|---|---|
| `keeper_meta` 의 최상위 필드 | 26 |
| 저장 JSON 의 key(`schema` 포함) | 32 |
| decode 때 리터럴로 채우는 최상위 필드 | 16 (설정 15, `id` 1) |
| decode 때 리터럴로 채우는 안쪽 필드 | 1 (`runtime.usage.last_usage_reported_at`) |
| TOML 에도 있고 JSON 에 사본도 있는 설정 | 2 (`instructions`, `agent_core_env`) |
| 덮기(overlay)를 부르는 줄 | 47파일 64줄 |
| 파일이나 Owner 값을 그대로 읽는 줄 | 145줄 |
| 레코드에서 설정 칸을 읽는 파일(근삿값) | lib·bin 76, test 26 |

decoder 주석은 아직 "eleven" 이라고 적는다(`keeper_meta_json_parse.ml:244`).
11-17 의 RFC 는 열넷이라고 적었다.
지금은 열다섯이다.
자리 채움 칸이 늘어도 아무것도 알려 주지 않았다.

운영 base path 의 파일도 같은 말을 한다(2026-11-26 확인).

- Keeper TOML 31개가 모두 `sandbox_profile` 과 `sandbox_image` 를 적는다.
- 상태 JSON 31개는 어느 것도 그 둘을 담지 않는다.
- 상태 JSON 31개의 `agent_core_env` 는 모두 비어 있다.
- `agent_core_env` 를 적은 TOML 은 0개다.

### 1.2 같은 뿌리로 고친 자리 일곱

모두 같은 모양이다.
파일에서 읽은 meta 의 설정 칸을 진짜 값으로 읽었다.

| 병합 | PR (이슈) | 자리 | 보인 증상 |
|---|---|---|---|
| 08-27 | #31067 (#30982) | 하트비트 턴 입구 | docker 선언 Keeper 의 실행 2,465번 가운데 15번만 컨테이너 |
| 08-27 | #31187 (#31178) | unified turn 이 Owner 값을 다시 받는 곳 | 턴 도중 profile 이 자리 채움 값으로 돌아감 |
| 08-29 | #31789 (#31782) | `masc_keeper_up` 의 필드만 바꾸는 갱신 | microvm 선언 Keeper 의 갱신이 Local 로 떨어져 거절됨 |
| 09-01 | #32362, #32377 | 도구 뒤 observer 가 Owner 값을 받는 곳 | microvm Keeper 의 Execute 가 호스트 docker 데몬으로 감 |
| 09-22 | #37652 | Board 신호 라우팅 | `board_interests` 가 늘 `[]` 라 attention 후보가 함대 전체에서 0 |
| 10-23 | #45146 | volume sweep | 서버가 뜬 뒤 볼륨을 하나도 못 찾음 |
| 11-20 | #54002 (#53007) | operator snapshot, trust snapshot | `activation_mode` 가 TOML 과 상관없이 늘 `autonomous` |

이슈 댓글이 든 #31782, #31178, #53007 은 이 가운데 셋이다.

### 1.3 자리마다 고쳐서는 끝나지 않는 까닭

- 덮기는 읽는 쪽이 기억해서 불러야 한다. 부르는 줄은 64줄이다. 그대로 읽는 줄은 145줄이다.
- 덮기가 실패하면 받은 meta 를 그대로 쓰는 자리가 있다. #54002 의 두 함수가 그렇다(`operator_control_snapshot.ml:123-130`, `keeper_runtime_trust_snapshot.ml:810-814`). TOML 을 못 읽으면 자리 채움 값이 화면에 나간다.
- 덮기는 TOML 이 적지 않은 key 에 받은 값을 남긴다(`keeper_meta_contract.ml:285-350`). 받은 값이 파일에서 왔으면 자리 채움 값이다. Owner 메모리에서 왔으면 마지막 `Update_profile` 때의 옛 TOML 값이다.
- `masc_keeper_up` 갱신은 아직 `old.<설정>` 을 12곳에서 기본값으로 쓴다(`keeper_turn_up_update.ml:540-643`). `old` 는 파일을 읽은 meta 다(`keeper_turn_up.ml:73`).
- 요청과 TOML 이 둘 다 `sandbox_profile` 을 빼면 자리 채움 값 `Docker` 가 새 TOML 에 써진다(`keeper_turn_up_config_persistence.ml:332-338`). 코드로만 읽었고 돌려 보지는 않았다.

## 2. 지금 모양

### 2.1 필드마다 사는 곳

"읽는 곳"은 대표 파일과 파일 수다.
파일 수는 이름이 같은 다른 레코드의 칸도 섞인 근삿값이다.
전체 목록은 §11 의 명령으로 뽑는다.

| 필드 | 저장 JSON | decode 가 채우는 값(`keeper_meta_json_parse.ml`) | 진짜 출처 | 읽는 곳 |
|---|---|---|---|---|
| `id` | 없음 | `None` (:264) | 없음. 아무도 `Some` 을 넣지 않는다 | 없음 |
| `sandbox_profile` | 없음 | `Docker` (:262) | TOML `sandbox_profile` | `keeper_tool_execute_runtime.ml`, `dashboard_http_keeper_trust.ml` 등 50 |
| `sandbox_image` | 없음 | `None` (:268) | TOML `sandbox_image` | `keeper_sandbox_control.ml`, `keeper_turn_sandbox_runtime_apple.ml` 등 8 |
| `network_mode` | 없음 | `Network_inherit` (:273) | TOML `network_mode`. 없으면 profile 기본 | `keeper_runtime_contract.ml`, `mcp_server_eio_call_tool.ml` 등 22 |
| `microvm_backend` | 없음 | `None` (:279) | TOML `microvm_backend`. 없으면 host 기본(RFC-0405) | `keeper_turn_sandbox_runtime_container.ml` 등 15 |
| `microvm_memory` | 없음 | `None` (:282) | TOML `microvm_memory` | `keeper_turn_sandbox_runtime_apple.ml` 등 5 |
| `microvm_cpus` | 없음 | `None` (:283) | TOML `microvm_cpus` | 같은 5 |
| `mention_targets` | 없음 | `[]` (:284) | TOML `mention_targets` | `keeper_board_audience.ml`, `keeper_board_address.ml` 등 10 |
| `board_interests` | 없음 | `[]` (:285) | TOML `board_interests` | `keeper_board_audience.ml`, `keeper_status_bridge.ml` 등 5 |
| `always_allow` | 없음 | `None` (:286) | TOML `always_allow` | `keeper_tool_execute_runtime.ml`, `keeper_identity_gate.ml` 등 8 |
| `voice_always_allow` | 없음 | `None` (:287) | TOML `voice_always_allow` | `keeper_tool_voice_runtime.ml` 등 3 |
| `masc_tools_enabled` | 없음 | `None` (:288) | TOML `tools.masc_enabled` | `keeper_runtime.ml`, `effective_masc_tools_enabled` |
| `activation_mode` | 없음 | `Keeper_activation_mode.default` (:293) | TOML `activation_mode` | `operator_control_snapshot.ml`, `keeper_activation_readiness.ml`, `keeper_meta_store.ml:564-575` 등 13 |
| `max_context_override` | 없음 | `None` (:295) | TOML `max_context_override` | `keeper_unified_turn_pre_dispatch.ml`, `keeper_status_detail.ml` 등 5 |
| `telemetry_feedback_enabled` | 없음 | `None` (:296) | TOML 같은 이름 | `keeper_turn.ml`, `keeper_runtime.ml` |
| `telemetry_feedback_window_hours` | 없음 | `None` (:297) | TOML 같은 이름 | 같은 2 |
| `instructions` | 사본 | 저장 값 | TOML `instructions`. 없거나 비면 TOML load 가 거절한다(`keeper_types_profile.ml:136-163`) | `keeper_working_context_pass.ml`, `keeper_memory_select.ml`, `keeper_status_detail.ml` 등 9 |
| `agent_core_env` | 사본 | 저장 값 | TOML `keeper.agent_core_env.*` | `keeper_runtime.ml` |
| `runtime.usage.last_usage_reported_at` | 없음 | `None` (:220) | Owner 메모리(`Commit_turn_runtime`). 재시작하면 사라진다 | `keeper_context_observation_projection.ml:346`, `keeper_heartbeat_loop_presence.ml:39-53` |
| `name`, `created_at`, `updated_at`, `paused`, `latched_reason`, `current_task_id`, `keeper_id`, `runtime` 의 나머지 | 있음 | 저장 값 | Owner | 여러 곳 |

### 2.2 설정 값 하나가 사는 곳이 넷이다

`sandbox_profile` 을 예로 든다.

1. TOML. 운영자와 `masc_keeper_up` 이 쓴다. `masc_keeper_up` 의 쓰기는 설정 journal 을 거친다(`lib/config_journal/keeper_config_journal.mli`).
2. Owner 메모리. 기동 때는 파일에서 만든다(`keeper_owner_registry.ml:114`). `Update_profile` 이 오면 TOML 값이 들어간다(`keeper_owner_reducer.ml:406-427`).
3. 파일을 읽은 meta. 늘 `Docker` 다.
4. 덮은 meta. 보통 TOML 값이다. TOML 을 못 읽으면 덮기를 부른 쪽마다 다르다.

2 는 `Update_profile` 이 왔는지에 따라 3 이기도 하고 1 이기도 하다.
2 와 3 은 같은 타입이다.
값만 보고 어느 쪽인지 알 수 없다.

기동 때 드리프트 지표(`masc_keeper_meta_overlay_drift_total`)는 3 과 1 의 차이를 센다(`keeper_runtime.ml:297-342`).
세기만 하고 고치지는 않는다.

### 2.3 쓰는 길과 받아 쓰는 길

- 상태 파일은 Owner 커밋 하나가 쓴다(`keeper_meta_store.ml` 의 `replace_snapshot`).
- 설정은 Owner 를 거쳐도 파일에 닿지 않는다. encoder 가 그 칸을 쓰지 않는다(`keeper_meta_json.ml:10-70`).
- 턴은 시작할 때 TOML 을 한 번 읽고 덮는다(`turn_profile_and_meta`, `keeper_unified_turn_pre_dispatch.ml:44-56`).
- 턴 도중 Owner 값을 다시 받는 자리는 둘이다. 둘 다 덮기를 다시 부른다(`keeper_unified_turn.ml:681-725`, `keeper_run_tools_hooks.ml:230-243`).
- 덮기가 실패하면 그 둘은 턴을 시작할 때의 meta 를 쓴다.

### 2.4 이미 나눈 선례

runtime 배정은 이미 이렇게 나뉘어 있다.
`keeper_meta` 에는 runtime 칸이 없다.
`runtime_id_of_meta` 는 이름만 보고 `runtime.toml` 에서 찾는다(`keeper_meta_contract.ml:368-396`).
이 RFC 는 같은 방법을 나머지 설정에 쓴다.

## 3. 결정

### D1. 설정은 `Keeper_declaration.t` 하나가 든다

- 새 모듈 `lib/keeper/keeper_declaration.ml` 을 둔다.
- 만드는 함수는 하나다. `of_profile : keeper_name:string -> keeper_profile_defaults -> (t, error) result`.
- 입력은 지금의 TOML 해석 결과(`keeper_profile_defaults`)다. TOML parser 는 바꾸지 않는다.
- 지금 덮기가 하는 검사를 이 함수로 옮긴다. 검사 내용은 그대로다.
  - profile 이 없으면 거절한다(#32078).
  - container 인데 image 가 없거나 비면 거절한다(#37523).
  - microvm 인데 선언한 backend 도 host 기본도 없으면 거절한다(RFC-0405).
  - remote_ssh 인데 endpoint 가 없으면 거절한다.
- 읽는 함수는 둘이다. `read : base_path:string -> string -> (t, error) result` 과 `of_snapshot : keeper_profile_snapshot -> string -> (t, error) result` 이다.
- 둘 다 지금의 TOML 읽기와 내용 키 캐시를 쓴다(`keeper_types_profile.ml:684-730`, `keeper_types_profile_toml_io.ml:117-147`). 읽을 때마다 TOML 바이트를 읽고, 바이트가 같으면 해석을 다시 하지 않는다.
- `t` 는 어디에도 저장하지 않는다. 출처는 TOML 하나다.

```ocaml
type sandbox =
  | Docker of { image : Image_name.t; network : network_mode }
  | Micro_vm of
      { image : Image_name.t
      ; backend : Keeper_microvm_backend.t
      ; memory : Keeper_microvm_guest_size.memory option
      ; cpus : Keeper_microvm_guest_size.cpus option
      ; network : network_mode
      }
  | Remote_ssh of { endpoint : Endpoint_name.t; network : network_mode }

type t = private
  { instructions : Instructions.t
  ; activation_mode : Keeper_activation_mode.t
  ; sandbox : sandbox
  ; mention_targets : string list
  ; board_interests : string list
  ; max_context_override : int option
  ; telemetry_feedback_enabled : bool option
  ; telemetry_feedback_window_hours : int option
  ; always_allow : bool option
  ; voice_always_allow : bool option
  ; masc_tools_enabled : bool option
  ; agent_core_env : (string * string) list
  }
```

- `Image_name.t`, `Endpoint_name.t`, `Instructions.t` 는 비지 않은 글자만 받는 작은 타입이다. 이름과 자리는 L1 에서 정한다.
- `t` 는 `private` 다. `of_profile` 밖에서는 만들 수 없다. 읽는 쪽은 pattern match 로 읽는다.
- `network` 은 TOML 값이다. 없으면 `default_network_mode_for_profile` 의 값이다. 지금 덮기와 같다.
- `option` 칸은 자리 채움이 아니다. TOML 이 그 key 를 적지 않았다는 뜻이다. `None` 의 뜻은 지금과 같다.
- TOML 이 `activation_mode` 를 적지 않으면 `Keeper_activation_mode.default` 다. 이 기본값은 `of_profile` 한 곳에만 적는다.
- 지금은 decoder 의 자리 채움 값과 `effective_autoboot_enabled`(`keeper_meta_store.ml:564-575`)가 이 기본값을 따로 쓴다.
- `effective_masc_tools_enabled` 는 이 타입 위로 옮긴다. 다계정이면 `false` 인 규칙은 그대로다.

### D2. `keeper_meta` 는 Owner 가 쓰는 실행 상태만 든다

- 남는 필드: `name`, `created_at`, `updated_at`, `paused`, `latched_reason`, `current_task_id`, `keeper_id`, `runtime`.
- 지우는 필드: 설정 15개, `instructions`, `agent_core_env`, `id`.
- encoder 와 decoder 는 남는 필드를 하나씩 쓰고 읽는다.
- decoder 는 리터럴로 채우는 필드가 없다.
- 지킬 성질: 모든 `s` 에 대해 `meta_of_json (meta_to_json s) = Ok s`.
- `last_usage_reported_at` 은 이 성질에 걸린다. 저장할지는 §8-1 이 정한다.
- 레코드 이름은 그대로 둔다. 이름을 바꾸면 동작은 같고 diff 만 커진다(§8-4).

### D3. 둘 다 필요한 쪽은 둘을 따로 받는다

- 둘을 묶은 레코드 타입은 만들지 않는다. 묶은 타입이 있으면 그것을 파일에서 만드는 함수가 다시 생길 수 있다. 그 함수는 선언을 지어내야 한다.
- 턴: `turn_profile_and_meta` 가 `(declaration, meta)` 를 돌려준다. 턴은 선언을 한 번 읽고 끝까지 쓴다.
- 턴 도중 Owner 값을 다시 받는 두 자리는 `meta` 만 바꾼다. 덮기가 없으니 덮기 실패도 없다.
- 도구 실행(Execute, 파일, voice, sandbox 제어)은 `declaration.sandbox` 를 받는다.
- 화면 행은 선언 읽기의 결과와 상태를 따로 받는다. operator snapshot, trust, dashboard, fleet scan, `masc_keeper_list`, board address 가 여기에 든다.
- 선언을 못 읽으면 행은 그 오류를 싣는다. 자리 채움 값을 내보내지 않는다.
- Board 라우팅, volume sweep, 자동 기동 판정, keepalive 도 선언을 읽는다.

### D4. 쓰는 길도 따로다

- 상태는 Owner 만 쓴다. Owner 명령은 상태만 받는다.
- `Update_profile` 을 지운다. Owner 가 설정을 들지 않으니 넣을 곳이 없다.
- 기동 때의 드리프트 다시 쓰기를 지운다(`ensure_keeper_meta_and_defaults`, `keeper_runtime.ml:345-529`). 견줄 사본이 없다.
- 설정은 TOML 에만 쓴다. 지금처럼 `Keeper_turn_up_config_persistence` 와 설정 journal 을 거친다.
- `masc_keeper_up` 갱신은 요청 값과 TOML 선언에서 새 선언을 만든다. `old.<설정>` 기본값 12곳이 없어진다.
- 요청과 TOML 이 둘 다 필수 key 를 빼면 갱신을 거절한다.

### D5. 지우는 것

| 지우는 것 | 자리 | 까닭 |
|---|---|---|
| `effective_meta_of_profile_defaults`, `effective_meta_result` | `keeper_meta_contract.ml:220-366` | 덮을 칸이 없다. 검사는 D1 로 옮긴다 |
| `read_effective_meta`, `_resolved`, `_presence`, `_presence_named` | `keeper_meta_store.ml:715-766` | 상태 읽기와 선언 읽기로 나뉜다 |
| `snapshot_read_back`, `Keeper_stored_meta` 의 read-back map | `keeper_meta_store.ml:211`, `keeper_stored_meta.ml:1-68` | 자리 채움 값을 행에 똑같이 보이려고 있었다. 왕복이 항등이면 할 일이 없다 |
| `Update_profile`, `profile_update` | `keeper_owner_reducer.ml:40-59`, `:406-427` | D4 |
| 드리프트 지표 `KeeperMetaOverlayDrift` | `keeper_runtime.ml:281-342`, `keeper_metrics.ml:39` | 견줄 사본이 없다 |
| `keeper_meta.id` | `keeper_meta_contract.ml:94` | 넣는 곳도 읽는 곳도 없다 |
| decoder 의 자리 채움 주석 | `keeper_meta_json_parse.ml:244-262` | 채우는 일이 없다 |
| `test_keeper_meta_config_not_durable` | `test/` | §9.2 |

## 4. 틀린 상태를 만들 수 없게 한다

| 지금 만들 수 있는 틀린 상태 | 나눈 뒤 |
|---|---|
| 상태에 설정을 쓰고 저장한다. 컴파일되고 사라진다 | 상태 타입에 설정 칸이 없다. 컴파일이 실패한다 |
| 파일을 읽은 meta 의 `sandbox_profile` 을 믿는다 | 그 칸이 없다 |
| Owner 값을 받아 턴의 설정을 덮어쓴다 | Owner 값은 상태 타입이다. 선언을 바꿀 수 없다 |
| 덮기가 실패하면 자리 채움 값을 쓴다 | 선언 읽기는 `result` 다. 실패를 값으로 바꾸는 함수가 없다 |
| microvm 인데 backend 가 `None` 이다 | `Micro_vm` 갈래가 backend 를 꼭 든다 |
| docker 인데 image 가 `None` 이다 | `Docker` 갈래가 image 를 꼭 든다 |
| docker 인데 `microvm_memory` 가 있다 | 그 칸은 `Micro_vm` 갈래에만 있다 |
| remote_ssh 인데 endpoint 가 없다 | `Remote_ssh` 갈래가 endpoint 를 꼭 든다 |

## 5. 하드컷

### 5.1 저장 JSON 이 잃는 것

- `instructions`, `agent_core_env` 두 key 가 빠진다.
- `schema` 는 `masc.keeper_meta.v3` 이 된다.
- 설정 15칸은 지금도 저장하지 않는다. 그 부분의 바이트는 그대로다.
- `last_usage_reported_at` 을 저장하기로 하면 key 하나가 는다(§8-1).

잃는 정보는 없다.
`instructions` 는 TOML 에 꼭 있다(`keeper_types_profile.ml:136-163`).
TOML 이 읽히면 덮기는 늘 TOML 값을 고른다.
`agent_core_env` 는 운영 파일 31개가 모두 비어 있다.

### 5.2 옛 파일

- v2 파일을 읽는 reader, converter, migration 코드는 만들지 않는다.
- keeper meta 는 `Refuse_boot` 저장소다(`keeper_store_boot_reconcile.mli`). 이 정책은 그대로다.
- v2 파일이 남아 있으면 기동과 배포 preflight 가 `not_current_schema` 로 거절한다.
- L4 의 changelog 조각에 `### Fresh state required` 를 적는다. 문안은 아래와 같다. 형태는 §8-2 가 정한다.

```markdown
### Fresh state required

- Keeper metadata no longer carries `instructions` or `agent_core_env`; the Keeper TOML is their only source, and the metadata schema is `masc.keeper_meta.v3`. Stop the server, then in each `<base-path>/.masc/keepers/<keeper>.json` remove the two keys and set the schema (`jq 'del(.instructions, .agent_core_env) | .schema = "masc.keeper_meta.v3"'`), and run `validate-stores` before starting (#<L4 PR>).
```

### 5.3 층

경계마다 나눈다.
필드마다 나누면 한 레코드에 설정 일부만 남는 중간 상태가 생긴다(#27357 08-24 댓글).
층은 native stack 하나로 쌓는다.
헌법대로 맨 위 PR 하나로 스택 전체가 한 번에 병합된다.
그래서 중간 층이 main 에 따로 닿는 일은 없다.
저장 바이트를 바꾸는 층은 L4 하나다.

| 층 | 무엇 | 확인 |
|---|---|---|
| L1 | `Keeper_declaration` 을 만든다. 덮기가 `of_profile` 을 불러 검사하게 바꾼다. 다른 자리는 그대로다 | 선언 시험(§9.1). 같은 입력에서 덮기와 선언이 같은 설정 값을 낸다. 저장 바이트 그대로 |
| L2a | 턴 길. `turn_profile_and_meta` 가 선언을 돌려준다. 도구 실행이 선언을 읽는다. Owner 값을 받는 두 자리는 상태만 바꾼다 | `test_keeper_run_tools_hooks` 의 projection adoption 4건, `test_turn_profile_and_meta_applies_the_declared_profile` |
| L2b | 화면 길. operator snapshot, trust, dashboard, fleet scan, `masc_keeper_list`, board address 가 선언을 읽는다 | #54002 의 두 시험. 선언을 못 읽은 행 시험 |
| L2c | 나머지 읽는 곳. Board 라우팅, volume sweep, 자동 기동, keepalive, `masc_keeper_up` 갱신 | #37652 의 세 스위트, #45146 의 시험, #31789 의 회귀 시험 |
| L3 | `keeper_meta` 에서 설정 15칸과 `id` 를 지운다. D5 의 함수·지표·시험을 지운다. 컴파일러가 남은 자리를 짚는다. 저장 바이트 그대로 | `dune build @check`. 상태 왕복 성질 시험 |
| L4 | `instructions`, `agent_core_env` 를 상태에서 지운다. schema v3. Fresh state required. `docs/KEEPER-FILE-MODEL.md` 의 한 줄을 고친다 | v2 파일 거절 시험, v3 왕복 시험 |

L2 는 PR 하나에 20k token 을 넘지 않게 경계마다 셋으로 나눴다.
더 커지면 같은 경계 안에서 파일 묶음으로 더 나눈다.

## 6. 보이는 변화

- 화면 행: TOML 을 못 읽는 Keeper 는 설정 대신 오류를 보인다. 지금은 자리 채움 값을 보인다.
- `masc_keeper_up` 갱신: 요청과 TOML 이 필수 key 를 둘 다 빼면 거절한다. 지금은 `Docker` 를 써 넣는다.
- 상태의 `updated_at` 은 설정만 바뀐 갱신에는 움직이지 않는다. 설정이 바뀐 때는 TOML 과 설정 journal 이 안다.
- 서버가 도는 동안 TOML 에서 key 를 빼면 다음 읽기부터 key 가 없는 값을 본다. 지금은 Owner 메모리의 옛 값이 남을 수 있다.
- 지표 `masc_keeper_meta_overlay_drift_total` 이 없어진다.
- L4 를 배포할 때 Fresh state 단계가 한 번 있다.

## 7. 고르지 않은 길

1. **설정 칸을 `Declared of _ | Not_loaded` 로 둔다.**
   - 장점: diff 가 작다.
   - 단점: 읽는 곳마다 `Not_loaded` 를 다뤄야 한다. 상태에 설정을 쓰는 길도 남는다. 자리 채움 값이 이름만 바뀐다.
2. **설정 15칸도 JSON 에 저장한다.**
   - 장점: decoder 가 채울 칸이 없다. 레코드가 하나로 남는다.
   - 단점: TOML 과 JSON 이 둘 다 출처가 된다. TOML 은 서버 밖에서도 고친다. JSON 사본은 늦는다. 헌법은 파생 값을 권위로 다시 저장하지 말라고 한다. 지금의 `instructions` 사본이 이미 이 모양이다.
3. **`keeper_meta` 를 `private` 로 만든다(이슈 본문의 작은 안).**
   - 장점: 밖에서 설정 칸에 쓰는 `with` 가 막힌다.
   - 단점: 일곱 번의 결함은 모두 쓰기가 아니라 읽기였다. decoder 는 여전히 자리 채움 값을 만든다.
4. **날것 읽기를 덮기로 감싸도록 lint 나 AST 검사로 강제한다.**
   - 장점: 타입을 바꾸지 않는다.
   - 단점: 소스 모양 검사다. #31067 이 넣은 AST 개수 검사가 이 길이었다. 그 뒤에도 여섯 번 더 고쳤다.
5. **08-24 댓글의 네 단계.** 설정 레코드를 `keeper_meta` 안에 넣고 두 벌을 둔 뒤 읽는 쪽을 옮긴다.
   - 장점: 층마다 작다.
   - 단점: 한 레코드에 설정이 두 벌 있는 중간 상태가 생긴다. 09-30 판정이 이 네 단계는 고정 요구가 아니라고 적었다. 이 RFC 는 경계로 나누는 생각만 가져온다.
6. **Owner 가 설정을 든다.** TOML 은 기동과 갱신 때만 읽는다.
   - 장점: 읽는 쪽이 메모리만 본다.
   - 단점: 운영자는 서버 밖에서 TOML 을 고친다. Owner 값은 다음 갱신까지 늦다. 지금 섞인 상태(§2.2)가 이 모양이다. row-facts RFC 규칙 10 도 TOML 을 메모리 규칙 밖에 둔다.
7. **둘을 묶은 레코드 `{ config; state }` 를 만든다(이슈 본문의 안).**
   - 장점: 넘기는 인자가 하나다.
   - 단점: 묶은 값을 파일에서 만드는 함수가 다시 생길 수 있다. D3 이 따로 받는 길을 고른 까닭이다.

## 8. 정할 것

1. **`last_usage_reported_at`.**
   권장: 상태에 저장한다.
   `.mli` 는 세 token 값과 그 시각이 한 관측이라고 적는다(`keeper_meta_contract.mli:53-63`).
   지금은 재시작하면 세 값은 남고 시각만 사라진다.
   다른 길: 저장하지 않고 Owner 메모리의 관측으로 옮긴다. 그러면 상태 타입 밖으로 나간다.
2. **Fresh state 의 모양.**
   권장: 두 key 를 지우는 `jq` 한 줄(§5.2). #52852 가 같은 모양이었다.
   이 길은 `keeper_id`, `trace_id`, 누적 사용량을 남긴다.
   다른 길: `keepers/*.json` 을 지우고 선언에서 다시 만든다. 한 문장이지만 그 값들을 잃는다.
3. **선언이 드는 범위.**
   권장: 지금 `keeper_meta` 가 든 설정과 `remote_endpoint` 만 든다.
   `tools.*`, `skills.names`, `observation_run`, `group` 은 지금도 profile 에서 바로 읽는다. 자리 채움 결함이 없다.
   다른 길: 모두 선언에 넣는다. 읽는 곳이 하나로 모이지만 이 스택이 커진다.
4. **`keeper_meta` 이름.**
   권장: 이 스택에서는 바꾸지 않는다. 바꾸려면 L4 뒤에 따로 한다.
5. **선언을 못 읽은 행의 모양.**
   권장: 상태 칸은 그대로 싣고, 설정 칸 자리에 오류 하나를 싣는다.
   다른 길: 그 행을 빼고 오류 목록에만 올린다.

## 9. 검증

### 9.1 층마다 시험

- **선언 시험(L1, 새 스위트).** 입력은 `keeper_profile_defaults` 표다.
  - profile 없음, docker 에 image 없음, 빈 image, remote_ssh 에 endpoint 없음은 거절이다. 거절 문구가 고칠 key 를 말한다.
  - microvm 은 선언한 backend 로 본다. host 기본이 있는지는 공용 규칙을 직접 부른다(지금 시험과 같다).
  - remote_ssh 는 image 를 묻지 않는다.
  - `network_mode` 를 안 적으면 profile 기본이다. 적으면 그 값이다.
  - `activation_mode`, `board_interests`, `mention_targets` 를 안 적으면 `default`, `[]`, `[]` 다.
  - 같은 입력에서 `effective_meta_of_profile_defaults` 와 `of_profile` 이 같은 설정 값을 낸다. 이 비교는 L3 에서 덮기와 함께 지운다.
- **턴 길(L2a).** projection adoption 4건을 고쳐 쓴다.
  - Owner 값의 `paused = true` 와 사용량이 턴 상태로 들어간다.
  - Owner 값을 받아도 턴의 선언은 처음 읽은 그대로다.
  - `test_turn_profile_and_meta_applies_the_declared_profile`(#31067)은 턴이 TOML 의 profile 로 도는 것을 본다. 이제 돌려받은 선언을 본다.
- **화면 길(L2b).**
  - `test_operator_snapshot_projects_effective_toml_declaration_fields` 는 그대로 통과한다.
  - `test_trust_snapshot_overlays_toml_sandbox_and_network_without_receipt` 도 그대로 통과한다.
  - 새 시험: TOML 이 깨진 Keeper 의 행은 오류를 싣고 `autonomous`, `docker` 를 싣지 않는다.
- **나머지(L2c).**
  - #37652 의 세 스위트(`test_board_dispatch`, `test_keeper_board_discoverable_cursor`, `test_keeper_keepalive_helpers`)가 통과한다.
  - #45146 의 volume 시험과 #31789 의 회귀 시험이 통과한다.
  - 새 시험: 요청과 TOML 이 `sandbox_profile` 을 둘 다 빼면 `masc_keeper_up` 갱신이 거절된다. TOML 은 그대로다.
- **L3.** 상태 왕복 성질 시험. 모든 필드에 기본값이 아닌 값을 넣고 왕복한다. 결과가 넣은 값과 같다.
- **L4.**
  - v2 파일은 `validate_current_meta_file_result` 가 `Not_current` 로 거절한다.
  - 기동 검사는 그 파일 때문에 기동을 막는다.
  - v3 파일은 읽힌다.

`test_keeper_turn_sandbox_profile_gate` 에는 "profile 없음은 거절" 한 건만 남아 있다.
이 시험은 L1 에서 선언 시험으로 옮긴다.
스위트는 L3 에서 지운다.

상태 기계나 동시성 프로토콜은 바뀌지 않는다.
그래서 TLA+ spec 은 더하지 않는다.

### 9.2 `test_keeper_meta_config_not_durable` 의 끝

이 스위트는 L3 에서 지운다.
네 시험은 이렇게 된다.

| 시험 | 행방 |
|---|---|
| config writes are dropped | 지운다. 이 시험이 적은 쓰기는 L3 부터 컴파일되지 않는다 |
| state writes survive | 상태 왕복 성질 시험으로 넓힌다(L3) |
| board_interests survives an empty profile default | 지운다. 받은 값을 남기는 덮기가 없다. 선언 시험이 "안 적으면 `[]`" 를 본다 |
| a container profile must name its image | 선언 시험으로 옮긴다(L1) |

### 9.3 운영 확인

헌법 `<evidence>` 대로 배포 뒤 PR 본문에 로그와 화면을 붙인다.

- TOML 이 `activation_mode = "manual"` 인 Keeper 의 operator snapshot 행이 `manual` 이다.
- microvm Keeper 가 하트비트 턴에서도, 첫 도구 뒤에도 microvm 으로 dispatch 한다. 로그의 `sandbox=` 를 센다.
- TOML 을 일부러 깨뜨린 Keeper 의 행이 오류를 보인다.

## 10. 먼저 있는 결정

- **헌법.** `legacy_residue`(hard cut, 호환 reader 없음), `closed_sum_over_string`, `strict_parse_no_default`, `authoritative_read_only` 를 따른다. 새 필드는 `last_usage_reported_at` 하나만 후보다. 저장하지 않으면 한 관측이 재시작 때 반쪽이 된다(§8-1). 바꾸지 않는다.
- **#27357 의 09-30 판정.** "네 단계는 고정 요구가 아니다. writer 와 adoption 계약이 핵심이다." 이 RFC 는 두 계약을 타입으로 만든다(D3, D4). 바꾸지 않는다.
- **#32377 이 decoder 주석에 적은 계약.** "durable meta 를 턴에 받는 길은 모두 덮기를 거친다. 실패하면 처음 받은 meta 를 쓴다." 이 RFC 가 바꾼다. 받는 길은 상태만 바꾸고 덮기가 없다. 까닭: 받는 값의 타입에 설정 칸이 없으면 이 계약은 지킬 대상이 없다.
- **RFC `keeper-row-facts-are-kept-in-memory-by-their-writers`.**
  - 규칙("쓰는 곳이 메모리도 고치고, 읽는 쪽은 파일을 열지 않는다")은 그대로다.
  - §3.1 의 왕복(`snapshot_read_back`)은 이 RFC 가 지운다. 왕복은 자리 채움 값을 행에 똑같이 보이려고 있었다. 나눈 뒤에는 Owner 값과 파일 값이 타입으로 같다.
  - 규칙 10(TOML 은 내용 키 캐시로 읽는다)은 그대로 따른다.
  - §8-6 은 #53007 을 따로 고치라고 했다. #54002 가 덮기로 고쳤다. 이 RFC 는 그 덮기를 선언 읽기로 바꾼다. 보이는 값은 TOML 값 그대로다.
- **RFC `a-persons-keeper-runs-on-the-engine`.**
  - 정의는 TOML 과 실행 기록(`.masc/keepers/<이름>.json`)이다.
  - 설정 journal 은 엔진 첫 단계에서 되돌린다. 다계정 boot 는 로그에 없는 정의와 남은 journal 을 거절한다.
  - 이 RFC 는 TOML 위치, journal, boot 검사를 바꾸지 않는다. 실행 기록이 설정 사본 두 key 를 잃을 뿐이다. 그 RFC 는 그 두 key 에 기대지 않는다.
- **RFC `every-durable-store-has-one-boot-policy`.** keeper meta 는 `Refuse_boot` 다. 바꾸지 않는다. L4 는 이 정책 아래에서 Fresh state 를 요구한다.
- **RFC-0405.** microvm backend 는 TOML 값이다. 없으면 host 기본, 그것도 없으면 거절한다. 그대로 선언으로 옮긴다.
- **#37523, #32078.** container 는 image 를 이름으로 적어야 한다. profile 이 없는 Keeper 는 거절한다. 그대로 선언으로 옮긴다.
- **`docs/KEEPER-FILE-MODEL.md`.** `instructions` 는 TOML 에 꼭 있다. 상태 snapshot 은 설정 출처가 아니다. 이 RFC 는 그 말을 타입으로 맞춘다. "`keeper_meta.instructions` 로 읽는다"는 줄만 L4 에서 고친다.
- **열린 PR.** 2026-11-26 에 `gh pr list --state open --search "RFC keeper"` 로 10건을 봤다. 이 영역의 파일을 고치는 열린 PR 은 없었다.

## 11. 에이전트용: 다시 세는 명령

워크트리 루트에서 돌린다.

```sh
git rev-parse --short=13 HEAD                                   # a26795cff182c
sed -n 210,300p lib/keeper/keeper_meta_json_parse.ml            # 리터럴로 채우는 칸
sed -n 92,132p lib/keeper/keeper_meta_contract.ml               # keeper_meta 26 필드
sed -n 10,70p lib/keeper/keeper_meta_json.ml                    # 저장 key 32

# 덮기를 부르는 줄: 47파일 64줄
rg -c "effective_meta_of_profile_defaults|effective_meta_result|read_effective_meta" lib bin --type ocaml \
  -g '!*.mli' -g '!lib/keeper/keeper_meta_contract.ml' -g '!lib/keeper/keeper_meta_store.ml' \
  | awk -F: '{s+=$2; n++} END {print n" files, "s" lines"}'

# 그대로 읽는 줄: 145
rg -n "Keeper_meta_store\.read_meta\b|Keeper_stored_meta\.read\b|\bread_meta config|Keeper_registry\.get\b" \
  lib bin --type ocaml -g '!*.mli' | wc -l

# 설정 칸을 읽는 파일(근삿값): lib·bin 76, test 26
F='sandbox_profile|sandbox_image|network_mode|microvm_backend|microvm_memory|microvm_cpus|mention_targets|board_interests|max_context_override|activation_mode|telemetry_feedback_enabled|telemetry_feedback_window_hours|always_allow|voice_always_allow|masc_tools_enabled'
rg -l "(meta|m|effective|entry\.meta|keeper_meta|overlayed|admitted|selected|resolved)\.($F)\b" lib bin --type ocaml -g '!*.mli' \
  | rg -v "keeper_meta_contract.ml|keeper_meta_json|keeper_owner_reducer.ml|keeper_turn_up_create.ml" | wc -l
rg -l "(meta|m|effective|entry\.meta|keeper_meta|overlayed|admitted|selected|resolved)\.($F)\b" test --type ocaml | wc -l

# 갱신 길의 old.<설정> 기본값: 12
rg -n "old\.($F|instructions|agent_core_env)\b" lib/keeper/keeper_turn_up_update.ml
```

운영 파일은 `<base-path>/.masc/config/keepers/*.toml` 과 `<base-path>/.masc/keepers/*.json` 에서 key 이름을 셌다.
값은 `agent_core_env` 가 비었는지만 봤다.
