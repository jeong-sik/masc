---
rfc: "exact-lane-walks-one-slot-list"
title: "An exact lane walks one slot list in the order it is written"
status: Draft
created: 2026-09-28
updated: 2026-09-28
author: claude
supersedes: []
superseded_by: null
related: ["cli-runtimes-as-lane-slots", "fusion-seat-routes", "every-lane-is-one-row-in-one-registry", "one-slot-fault-judgment-for-every-walk"]
---

# exact lane 은 슬롯 목록 하나를 적힌 순서대로 걷는다

## 1. 문제

standalone exact lane 은 슬롯을 두 목록에 나눠 적는다.

```toml
[runtime.exact_output_lanes.hitl_auto_judge]
slots = ["glm-coding.glm-5.3-flash"]          # HTTP
cli_slots = ["claude_code.claude-sonnet-5"]   # 공식 클라이언트
```

그리고 코드는 언제나 `slots` 를 다 쓴 다음에만 `cli_slots` 로 간다.
운영자가 "이 lane 은 Claude Code 로 먼저 판단하고, 안 되면 GLM" 이라고 정할 방법이 없다.

이 구별은 설정 한 곳에 머물지 않고 퍼져 있다 (2026-09-28 조사, 파일 수).

| 층 | 파일 |
|---|---|
| 설정 형식·로드 검사 | 5 |
| 쓰기(routing API, 첫 설정, install) | 약 10 |
| registry·lane 실행 | 약 14 |
| 서버 projection·endpoint | 5 |
| TUI | 8 |
| 대시보드 | 7 |
| 테스트 | 38 |
| 문서 | 약 14 |

퍼진 모양도 한결같지 않다. "HTTP 다음 CLI" 를 lane 다섯 곳이 각자 조립했고, 조립이 서로 다르다.

- **부르는 방식.** Librarian, Board attention, Stagehand, workspace curator 는 `Keeper_lane_cli_oneshot.walk` 를 부른다. HITL 은 `order_slots` 와 `run` 으로 자기 루프를 짰다.
- **HTTP 가 `Non_advanceable_terminal` 로 끝날 때.** Librarian, Board, HITL 은 멈춘다. Stagehand 와 curator 는 CLI 로 넘어간다 (`browser_stagehand_model.ml:670-672`, curator 는 #39622 부터).
- **CLI 호출 전 기록.** HITL 은 CLI 호출 전에도 queue 를 bind 한다. Board 는 HTTP 에만 bind 한다. 그래서 Board 는 CLI 까지 다 실패한 run 에 마지막 HTTP 슬롯을 기록한다 (`keeper_board_attention_exact_flow.ml:716-724`).
- **쉬는 슬롯 규칙이 세 벌이다.** HTTP 는 `Runtime_exact_lane_backpressure.order`, CLI 는 `Keeper_lane_cli_oneshot.order_slots` 이고, Stagehand 의 HTTP 슬롯은 규칙이 없다 (`browser_stagehand_model.ml:223-233`). Keeper 선호 순서(`Keeper_exact_lane_preference`)는 HTTP 슬롯만 안다.
- **로드 검사.** `cli_slots` 의 id 와 `verifier_exact` 의 `slots` id 는 모르면 로드를 막는다 (`runtime.ml:1282-1308`). 다른 lane 의 `slots` id 는 registry 가 받지 않으면 `dropped` 로 빠지고 진단이 붙는다 (`runtime_exact_output_registry.ml:60-78`, `185-191`).

## 2. 왜 두 목록이 되었나

CLI 슬롯을 들인 RFC(`RFC-cli-runtimes-as-lane-slots.md`, 2026-08-29)는 목록을 나누자고 하지 않았다.

- §3: 슬롯 목록 하나에 runtime id 를 HTTP target 과 **나란히** 적는다.
- §5: 구독 한도 때문에 "CLI 슬롯 **뒤에** HTTP fallback 을 두라" 고 권한다. CLI 가 앞에 올 수 있다는 전제다.

`RFC-fusion-seat-routes.md` §2.1 이 나눈 까닭을 적었다. "exact lane 은 HTTP 요청 본문을 만드는 경로와 CLI 경로가 달라서 나눴다." 실행 경로가 다르다는 사실이 설정 형식으로 새어 나온 것이다. 같은 저장소의 Fusion 은 HTTP 와 CLI runtime 을 한 후보 목록에 섞어 적고, 자리마다 같은 방식으로 실행한다.

verifier 도 실행할 때는 이미 목록 하나를 쓴다. HTTP id 뒤에 CLI id 를 붙인 목록을 슬롯마다 차례로 부른다 (`runtime.ml:2510-2523`, `anti_rationalization.ml:617-735`).

## 3. 결정

### 3.1 슬롯은 runtime 을 가리키는 id 하나다

lane 은 `slots` 하나만 적는다. 적힌 순서가 시도 순서다.

```toml
[runtime.exact_output_lanes.hitl_auto_judge]
slots = [
  "claude_code.claude-sonnet-5",
  "glm-coding.glm-5.3-flash",
]
```

`cli_slots` 키는 hard cut 이다. 새 binary 는 이 키를 모르는 키로 보고 로드를 거절한다.

### 3.2 종류는 id 가 가리키는 runtime 의 실행 방식에서 나온다

로드 검사는 id 를 runtime 표에서 찾는다. target 목록에서 찾지 않는다. target 목록은 로드 뒤 registry 를 publish 할 때 만들어지고 (`exact_output_resolver_snapshot`, `server_runtime_bootstrap.ml:235-243`), 기한 설정이 빠진 슬롯처럼 target 에서는 빠지지만 boot 에서 "degraded" 로 남는 슬롯도 있기 때문이다 (`runtime.ml:2062-2090`).

| id 가 가리키는 것 | 종류 | 처리 |
|---|---|---|
| 공식 클라이언트 runtime (출력 스키마 경로 있음) | CLI | 받는다 |
| Agent Core runtime | HTTP | 받는다. 기한 설정이 빠졌으면 지금처럼 degraded 로 보인다 |
| 출력 스키마 경로가 없는 클라이언트 (Muse Code) | — | 로드 오류 |
| 선언은 됐지만 꺼진 binding·provider | 그 binding 의 종류 | 받지 않고 `dropped` 로 보인다. 사유는 "disabled" (6장 Q5) |
| 아무것도 가리키지 않음, 기본 catalog | — | 로드 오류 (6장 Q4) |
| 아무것도 가리키지 않음, `AGENT_CORE_MODEL_CATALOG` 교체 catalog | HTTP target 으로 본다 | publish 때 registry 가 받거나 `dropped` 로 뺀다. 지금과 같다 |

마지막 줄이 Q4 의 한계다. 로드는 교체 catalog 파일을 읽지 않는다. 그래서 교체 catalog 를 쓰는 배포에서는 오타가 로드가 아니라 publish 진단으로 드러난다.

### 3.3 walker 는 하나다

lane 다섯 곳의 조립을 `Exact_lane_walk` 하나로 바꾼다. verifier 는 3.9 에서 따로 다룬다.

**걷는 단위.** 정렬(3.5)을 마친 목록에서 이어진 HTTP 슬롯을 한 묶음으로 보고, 묶음마다 agent_core flow 하나(`snapshot_flow ~first ~rest`)를 돌린다. CLI 슬롯은 하나씩 one-shot 으로 돌린다.

HTTP 슬롯마다 flow 를 따로 만들지 않는다. advance 기록, binding standing, 검증된 evidence transcript, Board 의 replay guard 가 flow 단위이기 때문이다. 묶음 안에서는 agent_core 의 의미가 그대로 남는다.

**방문 정체성.** HTTP 방문은 agent_core 의 visit(`flow_id`, 순번, catalog 지문, target 지문)을 그대로 쓴다. CLI 방문은 HITL 이 이미 만들어 쓰는 모양을 walker 로 옮겨 모든 lane 이 같이 쓴다 (`hitl_summary_worker.ml:1343-1385`).

```ocaml
type visit =
  | Http_visit of Exact_output.candidate_visit
  | Cli_visit of { runtime_id : string; call_id : string; prompt_sha256 : string }
```

**멈추는 경우는 둘뿐이다** (6장 Q1).

- masc 자기 기록이 실패했다. 방문 전 bind, 넘김 기록, 측정 callback 이 실패한 경우다.
- 취소.

나머지 실패는 HTTP 든 CLI 든 다음 슬롯으로 넘어간다. 도메인 검증 거절도 넘어간다.

지금은 이보다 많이 멈춘다. agent_core 는 아래 경우를 `Non_advanceable_terminal` 로 끝낸다 (`exact_output.ml:1911-2088`).

| 경우 | 예 | 지금 | 바뀐 뒤 |
|---|---|---|---|
| 보냈는데 결과를 모른다 | 응답 전에 연결이 끊김, stream 단계 timeout | 멈춤 | 넘김 |
| 답이 이상한 모양이다 | `Incomplete_output`, `Ambiguous_output`, `Unexpected_output_content` | 멈춤 | 넘김 |
| 크기를 재는 요청을 보낸 뒤 보내기 전 거절 | count-tokens 를 보낸 뒤의 거절 | 멈춤 | 넘김 |
| masc 자기 기록 실패 | `Flow_before_dispatch_callback_failed` 등 | 멈춤 | 멈춤 |

첫 줄은 `RFC-one-slot-fault-judgment-for-every-walk.md` §2.2 가 "exact 걸음은 멈춤, 지금 규칙 그대로" 로 남긴 부분이다. exact 요청은 도구가 없어서 넘겨도 효과가 겹치지 않는다. 같은 파일의 주석도 여러 번 그렇게 적는다. CLI 쪽은 이미 대부분의 실패에서 넘어간다.

이 변경은 agent_core 의 flow 안 판정(`execution_failure_may_advance`, `flow_execution_terminal_kind`)에서 한다. walker 가 묶음 사이에서만 넘기면, 같은 묶음의 남은 HTTP 슬롯은 건너뛰고 뒤의 CLI 슬롯만 부르는 모양이 된다. Keeper 걸음의 "결과 모름" 처리(`allow_retry`)는 바꾸지 않는다. Keeper 턴은 도구를 쓴다.

HITL 의 CLI bind 실패도 이 규칙을 따른다. 지금은 HTTP bind 실패는 걷기를 멈추고, CLI bind 실패는 그 슬롯만 건너뛴다 (`hitl_summary_worker.ml:655-663`, `1377-1385`). bind 실패는 masc 자기 기록 실패이니 둘 다 멈춘다.

### 3.4 lane 이 walker 에 넘기는 것

lane 마다 다른 것은 callback 몇 개로 끝나지 않는다. HITL 의 approval queue 와 Board 의 partition 은 저장되고 다시 읽히는 상태 전이다. 그래서 walker 는 방문 하나하나를 lane 에 알리고, lane 은 자기 상태 전이로 답한다.

| 받는 것 | 하는 일 | 쓰는 lane |
|---|---|---|
| `validate` | 답을 도메인 값으로 읽는다. HTTP 답이면 provenance 도 본다 | 전부 |
| `cli_request` | 메시지를 `(system_prompt, prompt)` 로 바꾼다. 바꿀 수 없으면 `None` 이고, 그 요청에서는 CLI 슬롯을 건너뛴다 (`Cli_unfit`) | 전부. Librarian·Stagehand 는 `None` 이 나올 수 있다 |
| `admit_http` | 보내기 전에 HTTP 슬롯을 거른다 | Librarian(요청 크기 사전 검사), Stagehand(system prompt 가능 여부) |
| `before_visit visit` | 방문 직전 durable bind. 실패하면 걷기를 멈춘다 | HITL, Board |
| `on_advance ~failed ~next` | 넘어갈 때 기록한다. `next` 는 HTTP 방문일 수도, CLI 방문일 수도 있다 | Board(`Advancing`), HITL(실행 실패일 때만 release) |
| `commit visit value` | 받아들인 답을 durable 하게 적용한다. 결과가 "여기서 끝" 이나 격리일 수 있다 | HITL(`complete_exact_attempt`), Board |
| `record` | run 기록을 남길지와 어떻게 남길지. Stagehand 는 남기지 않는다 | 전부 |

걷기가 끝나면 lane 은 닫힌 결과를 읽어 자기 말로 옮긴다.

```ocaml
type 'a walk_result =
  | Answered of { visit : visit; value : 'a; visits : visit_outcome list }
  | Exhausted of { visits : visit_outcome list; standing : standing }
  | Stopped of { visit : visit; cause : stop_cause; visits : visit_outcome list }
```

`visits` 에는 슬롯마다 무슨 일이 있었는지가 순서대로 남는다. 지금 lane 마다 다른 실패 타입(`extraction_error`, `execution_error`, `Generation_failed`, 문자열)은 이 목록을 읽는다.

- HITL 의 마지막 정리(`quarantine_candidate`, `handle_flow_error`, `handle_semantic_exhaustion`)는 지금 "마지막으로 bind 된 것이 HTTP 였나" 에 따라 갈린다. 새 모양에서는 마지막 방문의 종류를 `visits` 에서 읽는다.
- Librarian 의 입력 한도 재시도는 지금 마지막 CLI 실패의 입력 용량을 읽는다 (`keeper_librarian_runtime.ml:632-641`). 새 모양에서는 `visits` 전체에서 가장 작은 입력 용량을 읽고, 줄인 입력으로 목록 전체를 다시 걷는다.
- Board 의 Jev 사전 판정은 walker 밖에 그대로 둔다. 지금처럼 lane 에 HTTP 슬롯이 하나라도 있으면 걷기 전에 돈다. 목록에서 HTTP 슬롯이 어디에 있든 같다.

### 3.5 쉬는 슬롯 규칙은 하나다

**판정.**

```
resting slot =
     quota window 가 그 슬롯의 scope 를 다 썼다고 한다
  || backpressure 칸에 path_rest_sec 안의 429 가 있다
```

scope 는 `Runtime.quota_scope_of_runtime`(`runtime.ml:2813`, 본문은 `quota_scope_of_materialized` `301-337`)가 종류마다 알려 준다. HTTP 는 credential, Claude·Codex 는 client home, Antigravity 는 credential 파일이다.

**CLI 도 429 칸에 써야 판정이 정직해진다.** 공식 클라이언트 runtime 에도 backpressure 칸이 있다 (`runtime.ml:383-395`). 그런데 one-shot 경로는 quota window 에만 쓰고 이 칸에는 쓰지 않는다 (`fusion_official_client.ml:333-360`). 이 칸에 쓰는 곳은 Keeper 턴 드라이버뿐이다 (`keeper_turn_driver.ml:855-912`). 그래서 walker 는 CLI 방문이 속도 제한으로 거절되면(`Keeper_lane_cli_oneshot.refused_for_binding_rest`) 그 runtime 의 칸에 쓴다. HTTP 묶음은 지금처럼 `observe` 가 쓴다.

**순서.**

1. 적힌 순서에서 시작한다.
2. Keeper 선호 순서를 입힌다. 선호 저장소는 id 로 읽으므로 CLI id 도 받는다.
3. 안정 분할(stable partition)을 한다. 쉬지 않는 슬롯이 적힌 순서대로 먼저, 쉬는 슬롯이 적힌 순서대로 뒤에 온다.
4. 어느 슬롯도 목록에서 지우지 않는다. 쉬는 슬롯도 차례가 오면 부른다.

LiteLLM 은 cooldown 중인 deployment 를 후보에서 잠시 뺀다. masc 는 빼지 않고 뒤로 보낸다. 시간이 지났다는 이유로 후보를 죽이지 않는다는 원칙(constitution `no_wall_clock_death`)을 따른다. 지금 두 규칙도 이미 이렇게 한다.

**정렬한 뒤에 묶음을 나눈다.** 반대로 하면 뒤로 간 HTTP 슬롯이 CLI 슬롯을 건너뛰어 묶음 경계가 바뀐다. 묶음이나 CLI 슬롯 하나를 마칠 때마다 남은 슬롯을 다시 정렬한다.

**섞인 목록에서 달라지는 것.** 적힌 순서가 `[h1, c1]` 이고 h1 이 쉬는 중이면 `[c1, h1]` 로 걷는다. 지금은 h1 을 먼저 불러 429 를 한 번 더 받고 c1 로 간다. 어느 쪽이든 c1 이 그 판단을 받는다. 달라지는 것은 이미 쉬는 줄 아는 h1 을 한 번 덜 부르는 것이다. 쉬지 않는 슬롯이 앞에 있으면 CLI 는 그 슬롯이 실패한 뒤에만 불린다.

**단계마다 다르게 적용한다.** 두 목록이 남아 있는 동안(5장 4단계까지)은 종류별로 정렬하고 HTTP 묶음을 앞에 둔다. 지금 동작과 같다. Stagehand 의 HTTP 슬롯도 그때까지는 정렬하지 않는다. 하나의 정렬은 hard cut(5장 5단계)에서 켠다.

### 3.6 run 기록

- 호출 한 번에 run 기록 하나다 (지금과 같다). Stagehand 는 지금처럼 남기지 않는다.
- `selected_slot` 은 답한 슬롯이다. 끝까지 답이 없으면 마지막으로 부른 슬롯이다. 종류는 따지지 않는다.
- lane 이 "쉬는 중" 이라고 말하려면 걸은 슬롯이 모두 자기 계정 사정으로 거절했어야 한다 (`keeper_board_attention_worker.ml:1060-1091` 의 규칙을 walker 로 옮긴다).

### 3.7 Board partition 의 진행 기록

Board 는 판단 대상 partition 마다 진행 상태를 저장한다. 지금 그 모양은 HTTP 방문만 담을 수 있다.

- `candidate_visit` 은 `flow_id`, 순번, catalog 지문, target 지문을 모두 요구한다 (`keeper_board_attention_partition.mli:35-42`). CLI 방문에는 이 값들이 없다. 그래서 `Advancing { next = CLI }` 를 쓸 수 없다.
- `bind_before_dispatch` 는 `Bound a → Bound b` 를 거절하고, `Advancing { next }` 에서 `next` 가 아닌 슬롯의 bind 도 거절한다 (`keeper_board_attention_partition.ml:1612-1630`). HTTP 실패 뒤 CLI bind 가 여기서 막힌다.
- `legal_transition` 과 `complete_after_advancing` 은 CLI 가 HTTP 걷기가 끝난 뒤에만 돈다고 가정한다 (`keeper_board_attention_partition.ml:886-891`, `1715-1731`).
- 진행 상태는 저장되고, Blocked 행에도 남는다 (`keeper_board_attention_partition.ml:436-455`, `545-615`).

그래서 Board 의 진행 기록을 3.3 의 `visit` 합타입으로 바꾼다. 전이 표는 `_ -> false` 없이 모든 쌍을 적는다 (`software-development.md` 의 FSM 규칙). 저장된 행의 모양이 바뀌므로 4장의 hard cut 대상이다 (6장 Q6).

### 3.8 서버·TUI·대시보드

registry 는 슬롯을 종류가 붙은 목록 하나로 넘긴다.

```ocaml
type lane_slot =
  | Http of selected_slot
  | Cli of { runtime_id : string }

type resolved_lane = { slots : lane_slot list }
```

standalone lane projection 은 schema 를 `masc.standalone_llm_lanes.v3` 로 올린다.

- `admitted_slots`, `cli_slots`, `declared_cli_slots` 를 지운다.
- `declared_slots` 를 `{ id, kind: "http" | "cli", admitted }` 의 목록으로 바꾼다.
- `dropped_slots` 는 남긴다. CLI 슬롯도 들어갈 수 있다 (꺼진 binding).
- `selected_slots`(슬롯별 run 수)와 `runs_without_slot` 은 슬롯 id 로 세므로 그대로 둔다.
- `/api/v1/runtime/resolved` 의 `exact_slot_group`(`"slots" | "cli_slots" | null`)은 `exact_slot_kind`(`"http" | "cli" | null`)로 바꾼다. `null` 은 출력 스키마가 없는 클라이언트다.

TUI 와 대시보드는 목록 하나를 그린다.

- 줄마다 `[HTTP]` 또는 `[CLI]` 표시를 붙인다.
- `J`/`K`(대시보드는 ↑/↓)는 종류와 상관없이 순서를 바꾼다. "HTTP slots run first; … Reorder within a group" 거절(`masc_tui_types.ml:10183`)은 지운다.
- 목록 고르기에서 `HTTP tail`/`CLI tail` 대신 종류만 적는다.

TUI 디코더(`tui_decode.ml:7439-7475`)와 대시보드(`dashboard-standalone-lanes.ts:165-170`)는 wire 필드를 엄격하게 읽는다. 그래서 서버, TUI, 대시보드는 같은 PR 에 들어가 함께 배포된다.

쓰기 쪽(`append`/`drop`/`move`/`set_exact_output_lane_slots`, routing API)은 목록 하나를 다룬다. `exact_slot_list`(`Catalog_slots | Cli_slots`) 타입은 지운다.

### 3.9 verifier

verifier 는 agent_core flow 가 아니라 도구 호출(`report_review_verdict`)로 판정을 받는다. 그래서 3.3 의 walker 를 쓰지 않는다. 대신 두 가지를 맞춘다.

- 선언은 3.1 의 `slots` 하나다. 슬롯마다 하는 verifier 입장 검사(`verifier_runtime_admission`)는 그대로다.
- 순서는 3.5 의 규칙을 쓴다. 지금 verifier 는 선호 순서도 쉬는 슬롯 규칙도 쓰지 않는다.

## 4. 이미 저장된 데이터 (hard cut)

- **라이브 `runtime.toml`**: 네 lane 모두 `cli_slots = []` 이다 (2026-09-28). 배포할 때 그 줄만 지우면 된다. 지금 binary 에서 `cli_slots` 는 없어도 되는 키다. 그러니 **줄을 먼저 지우고, 그다음 새 binary 를 설치한다.** 순서를 바꾸면 새 binary 가 모르는 키로 로드를 거절한다. 편집은 admin raw endpoint 로 한다.
- **preset**: `<base-path>/.masc/presets/*/runtime.json` 아래에서 조사한 14개가 모두 `"cli_slots"` 를 들고 있다. 저장 위치는 `Prompt_preset.presets_dir`가 `Config_dir_resolver.masc_root ~base_path`에서 정한다. 읽는 코드(`prompt_preset.ml:327-328`)는 이 필드를 필수로 요구한다. 새 형식을 읽는 호환 reader 는 만들지 않는다 (projects.md). 운영자가 배포 때 한 번 다시 쓴다 (6장 Q2). changelog 에는 `Fresh state required` 로 적는다.
- **Board partition 진행 기록** (3.7): 모양이 바뀐다. 호환 reader 는 만들지 않는다 (6장 Q6).
- **workspace curator 의 중복 판정 키**: `request_identity.configuration` 에 `cli_slots` 가 들어 있다 (`server_workspace_memory_curator.ml:175-179`, `203-207`). hard cut 뒤 첫 입력 하나는 이미 본 입력이어도 한 번 더 정리한다. 결과는 같은 proposal 이라 그대로 둔다.
- **benchmark config 생성기**(`benchmarks/terminal_bench/configs/render_configs.py:195-262`)도 목록 하나를 쓰도록 고친다.

## 5. 나눠 올리는 순서

각 단계는 앞 단계가 main 에 들어간 뒤에 올린다.

1. **넘김 판정을 바꾼다 (Q1).** agent_core 의 flow 안 판정에서 3.3 표의 앞 세 줄을 넘김으로 바꾼다. 이러면 지금 Stagehand·curator 만 하는 "HTTP 가 끝나면 CLI 로" 가 다섯 lane 모두에 맞는 규칙이 된다. walker 를 모으기 전에 해야 Stagehand·curator 의 동작이 한 번 멈춤으로 갔다가 돌아오지 않는다.
2. **CLI 도 429 칸에 쓴다** (3.5). 순서 규칙은 아직 바꾸지 않는다. CLI 순서가 이 칸을 읽는 것은 5단계부터다.
3. **Board 진행 기록을 `visit` 합타입으로 바꾼다** (3.7). Board 가 CLI 방문에도 bind 하고, CLI 까지 실패한 run 에 마지막 CLI 슬롯을 기록한다. 저장된 진행 기록 처리는 Q6 을 따른다.
4. **walker 를 만들고 lane 을 하나씩 옮긴다.** 정렬은 3.5 의 "단계마다" 규칙대로 종류별로 둔다. 옮기는 순서는 단순한 것부터 curator, Stagehand, Librarian, Board, HITL 이다. lane 하나가 PR 하나다. 옮긴 lane 의 기존 스위트가 고치지 않은 채로 초록이어야 한다. 이것이 하네스다.
5. **`slots` 하나로 hard cut 하고, 정렬을 하나로 켠다.** 설정 형식·로드 검사(3.2), registry, 쓰기, routing API, projection v3, `exact_slot_kind`, TUI, 대시보드, 첫 설정·install, preset reader, 문서, fixture 를 바꾼다. 서버·TUI·대시보드가 함께 가야 해서 한 PR 이다. 크면 테스트 fixture 정리만 앞선 PR 로 뺀다.
6. **verifier 를 3.9 대로 맞춘다.**

4단계에서 lane 을 하나씩 옮기는 것은 N-of-M 패치가 아니다. 공통 부분은 walker 한 곳에 먼저 생기고, 각 PR 은 lane 하나가 그것을 쓰게 바꾼다. 다섯 번째 PR 이 들어가면 "HTTP 다음 CLI" 를 조립하는 곳은 남지 않는다.

## 6. 정한 것과 정할 것

- **Q1. 어떤 실패에서 멈추나?** (3.3) — 정함 (운영자, 2026-09-28)
  - masc 자기 기록 실패와 취소에서만 멈춘다. 나머지는 HTTP·CLI 모두 다음 슬롯으로 넘긴다.
  - 바뀌는 것: `RFC-one-slot-fault-judgment-for-every-walk.md` §2.2 에서 "그대로" 로 둔 "보냈는데 결과를 모름 → 멈춤" 을 넘김으로 바꾼다.
  - 대가: 결과를 모르는 요청이 실제로는 provider 에서 처리됐다면 한 번 더 과금된다. constitution 은 비용을 지금 문제로 보지 않는다.
- **Q2. preset 14개는?** — 정함 (운영자, 2026-09-28)
  - 배포 때 운영자가 한 번 다시 쓴다. `cli_slots` 항목을 `slots` 끝에 붙여 지금 순서를 유지한다. 저장소에 변환 코드는 넣지 않는다.
- **Q3. 첫 설정이 쓰는 기본 순서는?** — 정함 (운영자, 2026-09-28)
  - HTTP 를 앞에, CLI 를 뒤에 쓴다. CLI 한 번은 프로세스를 띄우느라 몇 초 걸리고 구독 한도도 쓴다 (`RFC-cli-runtimes-as-lane-slots.md` §5).
  - 파일에 적히는 기본값일 뿐이다. 운영자는 TUI 나 파일에서 언제든 바꾼다.
- **Q4. `slots` 의 모르는 id 도 로드를 막는가?** (3.2) — 정함 (운영자, 2026-09-28)
  - 막는다. 막지 않으면 CLI id 오타가 조용히 사라진다.
  - 대가: 기본 catalog 에서 옛 id 가 남으면 부팅이 멈춘다. 로드 오류는 id 를 이름으로 적는다.
  - 한계: 교체 catalog(`AGENT_CORE_MODEL_CATALOG`)를 쓰면 로드가 그 파일을 읽지 않아서, 오타는 publish 진단으로 드러난다 (3.2 표의 마지막 줄).
- **Q5. 꺼진 binding·provider 를 가리키는 슬롯은?** (3.2) — 운영자 확인 대기
  - 권하는 답: 받지 않고 `dropped` 로 보인다. 종류와 상관없이 같다. 꺼짐은 오타가 아니라 운영자가 정한 상태다.
  - 바뀌는 것: 지금 `cli_slots` 의 꺼진 runtime 은 로드를 막는다 (`runtime.ml:1806-1808`). 이 규칙을 그대로 두면, provider 하나를 끄는 순간 그 provider 를 적은 lane 때문에 파일 전체가 로드되지 않는다.
- **Q6. Board partition 의 저장된 진행 기록은?** (3.7) — 운영자 확인 대기
  - 권하는 답: 3단계 배포 전에 진행 중인 partition 이 비기를 기다린다. 그래도 남은 Running·Blocked 행은 운영자 복구(requeue)로 처음부터 다시 판단하게 한다. 판단 대상 후보(candidate)는 partition 과 따로 durable 하게 남는다.
  - 확인할 것: requeue 가 옛 모양의 진행 기록을 읽지 않고도 되는지는 3단계 PR 에서 확인한다.

## 7. 다루지 않는 것

- HTTP·CLI 한 번 호출에 걸리는 시간 한도는 그대로다 (HTTP `exact_body_timeout_s`, CLI 는 모델의 `turn_timeout_s` 또는 300초). lane 전체의 시간 한도는 지금도 없고, 이 RFC 도 만들지 않는다.
- 조사 중 따로 찾은 것은 이 RFC 가 고치지 않고 issue 로 남긴다.
  - Antigravity 실패는 quota window 에 아무것도 쓰지 않는다 (`fusion_official_client.ml:447-455`). 그래서 Antigravity 슬롯은 쉬는 슬롯으로 잡히지 않는다.
  - `flow_execution_binding_standing` 은 "앞 슬롯은 답했지만 도메인에서 거절, 다음 슬롯은 429" 인 flow 를 "모두 쉬는 중" 으로 읽을 수 있다 (`exact_output.ml:2156-2176`). 확인이 더 필요하다.
  - `keeper_lane_cli_oneshot.ml:171` 과 `.mli:34` 가 이름이 바뀐 `validate_exact_lane_cli_slot_official_clients` 를 가리킨다. 지금 이름은 `validate_exact_lane_cli_slots` 다.

## 8. 검증

- **walker 단위 테스트** (가짜 HTTP 묶음 runner, 가짜 CLI runner):
  - 적힌 순서를 지킨다.
  - 쉬는 슬롯은 안정 분할로 뒤에 가고 사라지지 않는다.
  - 묶음 경계는 정렬 뒤에 정해진다.
  - masc 자기 기록 실패와 취소에서만 멈춘다. 결과를 모르는 전송 오류, 이상한 모양의 답은 다음 슬롯으로 넘어간다.
  - `cli_request = None` 이면 CLI 슬롯을 건너뛰고 사유를 남긴다.
  - run 기록은 하나이고 `selected_slot` 이 맞다.
- **4단계 하네스**: 옮기는 lane 의 기존 스위트가 고치지 않은 채로 초록이다. 지금 CLI runner 와 쉬는 슬롯을 함께 다루는 테스트는 CLI 끼리의 순서 하나뿐이다 (`test_hitl_summary_worker.ml:2880-2926`). 그래서 4단계 첫 PR 에서 "쉬는 HTTP 슬롯이 CLI 슬롯보다 먼저 불린다" 를 lane 마다 고정하는 테스트를 먼저 더한다. 5단계는 이 테스트를 새 규칙으로 바꾼다.
- **Board partition 전이**: `visit` 합타입의 모든 쌍을 전이 표 테스트로 적는다. HTTP 실패 → CLI bind → CLI 실패 → 다음 HTTP 묶음 bind 가 모두 통과해야 한다.
- **로드 검사**: 3.2 표의 줄마다 테스트 하나씩 둔다.
- **TUI PTY**: CLI 슬롯을 HTTP 슬롯 위로 옮기면 `move` 가 가고, 목록이 그 순서로 다시 그려진다.
- **라이브 canary**: `hitl_auto_judge` 에 `claude_code.claude-sonnet-5` 를 GLM 앞에 두고 하루 돌린다. run 기록의 `selected_slot` 분포와 걸린 시간을 HTTP 가 앞일 때와 비교한다.

## 9. 참고한 것

- LiteLLM Router: 서로 다른 provider 의 deployment 를 `order` 하나로 줄 세운다. cooldown 중인 deployment 는 잠시 후보에서 빠진다 (https://docs.litellm.ai/docs/routing, 2026-09-28 확인).
- OpenRouter provider routing: `provider.order` 로 순서를 적고, `allow_fallbacks` 로 목록 밖으로 넘어갈지 정한다 (https://openrouter.ai/docs/guides/routing/model-fallbacks).
- masc Fusion 자리 (`RFC-fusion-seat-routes.md` §2.1): HTTP 와 CLI runtime 을 한 후보 목록에 섞어 적는다.
- `RFC-one-slot-fault-judgment-for-every-walk.md`: 실패가 누구의 사정인지 판정 하나. 이 RFC 는 exact 걸음에서 "결과 모름" 을 넘김으로 바꾼다 (6장 Q1).
