---
rfc: "exact-lane-walks-one-slot-list"
title: "An exact lane walks one slot list in the order it is written"
status: Draft
created: 2026-09-28
updated: 2026-09-28
author: claude
supersedes: []
superseded_by: null
related: ["cli-runtimes-as-lane-slots", "fusion-seat-routes", "every-lane-is-one-row-in-one-registry"]
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

- Librarian, Board attention, Stagehand 는 `Keeper_lane_cli_oneshot.walk` 를 부른다. HITL 은 `order_slots` 와 `run` 으로 자기 루프를 짰다.
- HTTP 가 되살릴 수 없는 오류(`Non_advanceable_terminal`)로 끝나면 넷은 멈추는데 Stagehand 만 CLI 로 넘어간다 (`browser_stagehand_model.ml:670-672`).
- HITL 은 CLI 호출 전에도 queue 를 bind 하는데 Board 는 HTTP 에만 bind 한다. 그래서 Board 는 CLI 까지 다 실패한 run 에 마지막 HTTP 슬롯을 기록한다 (`keeper_board_attention_exact_flow.ml:716-724`).
- 쉬는 슬롯을 뒤로 보내는 규칙이 두 벌이다. HTTP 는 `Runtime_exact_lane_backpressure.order`, CLI 는 `Keeper_lane_cli_oneshot.order_slots` 이다. Keeper 선호 순서(`Keeper_exact_lane_preference`)는 HTTP 슬롯만 안다.
- workspace curator 는 CLI 슬롯을 아예 거절했다 (#39622 에서 없앴다).

## 2. 왜 두 목록이 되었나

CLI 슬롯을 들인 RFC(`RFC-cli-runtimes-as-lane-slots.md`, 2026-08-29)는 목록을 나누자고 하지 않았다.

- §3: 슬롯 목록 하나에 runtime id 를 HTTP target 과 **나란히** 적는다.
- §5: 구독 한도 때문에 "CLI 슬롯 **뒤에** HTTP fallback 을 두라" 고 권한다. CLI 가 앞에 올 수 있다는 전제다.

`RFC-fusion-seat-routes.md` §2.1 이 나눈 까닭을 적었다. "exact lane 은 HTTP 요청 본문을 만드는 경로와 CLI 경로가 달라서 나눴다." 실행 경로가 다르다는 사실이 설정 형식으로 새어 나온 것이다. 같은 저장소의 Fusion 은 HTTP 와 CLI runtime 을 한 후보 목록에 섞어 적고, 자리마다 같은 방식으로 실행한다.

verifier 도 실행할 때는 이미 목록 하나를 쓴다. HTTP id 뒤에 CLI id 를 붙인 목록을 슬롯마다 차례로 부른다 (`runtime.ml:2510-2523`, `anti_rationalization.ml:617-735`).

## 3. 결정

### 3.1 슬롯은 runtime 을 가리키는 id 하나다 (확정)

lane 은 `slots` 하나만 적는다. 적힌 순서가 시도 순서다.

```toml
[runtime.exact_output_lanes.hitl_auto_judge]
slots = [
  "claude_code.claude-sonnet-5",
  "glm-coding.glm-5.3-flash",
]
```

HTTP 로 답할지 CLI 로 답할지는 id 가 가리키는 runtime 이 이미 안다 (`exact_slot_list_of_api_format`). lane 은 그 구별을 몰라도 된다. `cli_slots` 키는 hard cut 이다. 새 binary 는 이 키를 모르는 키로 보고 로드를 거절한다.

### 3.2 로드할 때 id 마다 종류를 정한다

로드 검사가 id 하나하나를 셋 중 하나로 읽는다.

- **HTTP slot**: exact-output target 이름이다. 기본 설정에서는 Agent Core runtime id 다 (`runtime.ml:2007-2051`). `AGENT_CORE_MODEL_CATALOG` 로 catalog 를 바꾸면 그 파일의 `[[targets]]` 이름이다.
- **CLI slot**: 출력 스키마를 받을 수 있는 공식 클라이언트 runtime id 다.
- **그 밖**: 로드 오류다.

오타 방어가 지금보다 넓어진다. 지금은 `cli_slots` 의 모르는 id 만 로드를 막는다 (2026-09-24 의 192건 실패 뒤에 생긴 규칙, `runtime.ml:1300-1308`). `slots` 의 모르는 id 는 `dropped` 로 조용히 빠진다 (`runtime_exact_output_registry.ml:185-191`). 한 목록에서는 두 종류를 같이 막는다.

한 가지는 그대로 둔다. 이름은 맞지만 binding 이 빠져 catalog 가 받지 않은 target 은 지금처럼 `dropped` 로 보인다. 오타가 아니라 그때의 설정 상태이기 때문이다.

같은 id 가 두 종류로 다 읽히면 로드 오류다. 기본 설정에서는 생길 수 없다. `exact_output_targets` 가 공식 클라이언트를 target 에서 뺀다. catalog 를 바꾼 경우에만 생길 수 있다. Muse Code 처럼 출력 스키마 경로가 없는 클라이언트는 지금처럼 어느 lane 에도 적을 수 없다.

### 3.3 walker 는 하나다

lane 다섯 곳의 조립을 `Exact_lane_walk` 하나로 바꾼다. verifier 는 3.7 에서 따로 다룬다.

**걷는 단위.** 정렬(3.4)을 마친 목록에서 이어진 HTTP 슬롯을 한 묶음으로 보고, 묶음마다 agent_core flow 하나(`snapshot_flow ~first ~rest`)를 돌린다. CLI 슬롯은 하나씩 one-shot 으로 돌린다.

HTTP 슬롯마다 flow 를 따로 만들지 않는 이유가 있다.

- Board attention 은 진행 상태 `Advancing{last_from; next}` 를 `(flow_id, 순번)` 으로 저장한다 (`keeper_board_attention_partition.ml:1216-1289`).
- advance 기록, binding standing, 검증된 evidence transcript 가 flow 단위다.
- 슬롯마다 flow 를 만들면 이것들을 caller 가 다시 이어 붙여야 한다.

묶음 안에서는 agent_core 의 의미가 그대로 남는다.

**lane 마다 다른 것만 인자로 받는다.** 조사에서 lane 마다 정말 다른 것은 다섯 가지였다.

| 인자 | 하는 일 | 지금 쓰는 lane |
|---|---|---|
| `validate` | 답을 도메인 값으로 읽는다. HTTP 답이면 provenance 도 본다 | 전부 |
| `cli_request` | 메시지를 `(system_prompt, prompt)` 로 바꾼다. 바꿀 수 없으면 `None` | 전부. Librarian 과 Stagehand 는 `None` 이 나올 수 있다 |
| `admit_http` | 보내기 전에 HTTP 슬롯을 거른다 | Librarian(요청 크기 사전 검사), Stagehand(system prompt 가능 여부) |
| `before_dispatch` | 슬롯을 부르기 직전에 durable 기록을 남긴다 | HITL(queue bind), Board(partition bind) |
| `after_failure` | 실패한 슬롯의 기록을 푼다 | HITL(release) |

`cli_request` 가 `None` 인 요청에서는 CLI 슬롯을 건너뛴다. 건너뛴 사실은 typed 사유(`Cli_unfit`)로 남는다.

CLI 슬롯에도 `before_dispatch` 를 부른다. 그러려면 CLI 호출에도 정체성이 있어야 한다. HITL 이 이미 만들어 쓰는 모양(`call_id "cli-…"`, `plan_fingerprint "cli-oneshot:" ^ sha`, 프롬프트 sha, `hitl_summary_worker.ml:1343-1385`)을 walker 로 옮겨 모든 lane 이 같이 쓴다. Board 의 기록 착오(1장)가 이것으로 풀린다.

**다음 슬롯으로 넘어가는 규칙은 walker 한 곳이 정한다.**

멈추는 경우는 둘뿐이다. 나머지 실패는 HTTP 든 CLI 든 다음 슬롯으로 넘어간다.

- **masc 자기 기록이 실패했다.** `before_dispatch`·`before_advance`·측정 callback 이 실패한 경우다 (`Flow_*_callback_failed`). HITL 의 durable bind 가 실패했는데 다음 슬롯을 부르면 기록 없는 호출이 된다.
- **취소.**

지금은 이보다 많이 멈춘다. agent_core 는 아래 경우를 `Non_advanceable_terminal` 로 끝내고, 다섯 lane 중 넷이 여기서 걷기를 멈춘다 (`exact_output.ml:1911-2088`). Stagehand 만 CLI 로 넘어간다.

| 경우 | 예 | 지금 |
|---|---|---|
| 보냈는데 결과를 모른다 | 응답 전에 연결이 끊김, stream 단계 timeout, 원인 모를 전송 오류 | 멈춤 |
| 답이 이상한 모양이다 | `Incomplete_output`, `Ambiguous_output`, `Unexpected_output_content` | 멈춤 |
| 크기를 재는 요청을 보낸 뒤 보내기 전 거절 | count-tokens 를 보낸 뒤의 거절 | 멈춤 |
| masc 자기 기록 실패 | `Flow_before_dispatch_callback_failed` 등 | 멈춤 |

첫 줄은 `RFC-one-slot-fault-judgment-for-every-walk.md` §2.2 가 "exact 걸음은 멈춤, 지금 규칙 그대로" 로 남긴 부분이다. 그 RFC 는 이것을 "걸음의 효과 규칙" 이라 부르고 바꾸지 않았다. 그런데 exact 요청은 도구가 없다. 같은 파일의 주석도 여러 번 "exact 요청은 도구가 없어서 넘겨도 효과가 겹치지 않는다" 고 적는다 (`exact_output.ml:1911-2065`). CLI 쪽은 이미 모든 실패에서 넘어간다 (`keeper_lane_cli_oneshot.ml:223-240`).

그래서 위 표의 앞 세 줄을 넘김으로 바꾼다 (6장 Q1, 5장 1단계). 이 변경은 agent_core 의 flow 안 판정(`execution_failure_may_advance`, `flow_execution_terminal_kind`)에서 한다. walker 가 묶음 사이에서만 넘기면, 같은 묶음의 남은 HTTP 슬롯은 건너뛰고 뒤의 CLI 슬롯만 부르는 모양이 된다.

도메인 검증 거절은 지금처럼 두 종류 모두 넘어간다.

**결과는 닫힌 합타입이다.**

```ocaml
type 'a walk_result =
  | Answered of { slot : slot_id; value : 'a; visits : visit list }
  | Exhausted of { visits : visit list; standing : standing }
  | Stopped of { slot : slot_id; cause : stop_cause; visits : visit list }
```

`visits` 에 슬롯마다 무슨 일이 있었는지가 순서대로 남는다. 지금 lane 마다 다른 실패 타입(`extraction_error`, `execution_error`, `Generation_failed`, 문자열)은 이 목록을 읽어 자기 말로 옮긴다. Librarian 의 크기 증거와 CLI 입력 한도, Board 의 defer/block 판정도 여기서 읽는다.

### 3.4 쉬는 슬롯 규칙은 하나다

두 규칙은 이미 같은 저장소(`Runtime_quota_window`)를 읽는다. HTTP 쪽만 `Runtime_candidate_backpressure` 의 429 기록도 함께 본다. 이 기록은 공식 클라이언트 runtime 에도 칸이 있다. 그래서 판정 하나로 합친다.

```
resting slot =
     quota window 가 그 슬롯의 scope 를 다 썼다고 한다
  || backpressure 칸에 path_rest_sec 안의 429 가 있다
```

scope 는 `Runtime.quota_scope_of_runtime_id`(`runtime.ml:2817`)가 이미 종류마다 알려 준다. HTTP 는 credential, Claude·Codex 는 client home, Antigravity 는 credential 파일이다 (`quota_scope_of_runtime`, `runtime.ml:305-337`).

순서는 이렇게 정한다.

1. 적힌 순서에서 시작한다.
2. Keeper 선호 순서를 입힌다. 선호 저장소는 id 로 읽으므로 CLI id 도 그대로 받는다.
3. 안정 분할(stable partition)을 한다. 쉬지 않는 슬롯이 적힌 순서대로 먼저, 쉬는 슬롯이 적힌 순서대로 뒤에 온다.
4. 어느 슬롯도 목록에서 지우지 않는다. 쉬는 슬롯도 차례가 오면 부른다.

LiteLLM 은 cooldown 중인 deployment 를 후보에서 잠시 뺀다. masc 는 빼지 않고 뒤로 보낸다. 시간이 지났다는 이유로 후보를 죽이지 않는다는 원칙(constitution `no_wall_clock_death`)을 따른 것이다. 지금 두 규칙도 이미 이렇게 한다.

**언제 정렬하나.** 정렬을 마친 뒤에 묶음을 나눈다. 반대로 하면 뒤로 간 HTTP 슬롯이 CLI 슬롯을 건너뛰어 묶음 경계가 바뀐다. 묶음이나 CLI 슬롯 하나를 마칠 때마다 남은 슬롯을 다시 정렬한다. 지금 CLI walk 는 슬롯마다 다시 정렬하고, HTTP flow 는 flow 안에서 순서를 고정한다. 새 규칙은 두 방식의 경계에 맞춘다.

### 3.5 run 기록

- 호출 한 번에 run 기록 하나다 (지금과 같다).
- `selected_slot` 은 답한 슬롯이다. 끝까지 답이 없으면 마지막으로 부른 슬롯이다. 종류는 따지지 않는다.
- lane 이 "쉬는 중" 이라고 말하려면 걸은 슬롯이 모두 자기 계정 사정으로 거절했어야 한다 (`keeper_board_attention_worker.ml:1060-1091` 의 규칙을 walker 로 옮긴다).

### 3.6 서버·TUI·대시보드

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
- `/api/v1/runtime/resolved` 의 `exact_slot_group`(`"slots" | "cli_slots" | null`)은 `exact_slot_kind`(`"http" | "cli" | null`)로 바꾼다. `null` 은 출력 스키마가 없는 클라이언트다.

TUI 와 대시보드는 목록 하나를 그린다.

- 줄마다 `[HTTP]` 또는 `[CLI]` 표시를 붙인다.
- `J`/`K`(대시보드는 ↑/↓)는 종류와 상관없이 순서를 바꾼다. "HTTP slots run first; … Reorder within a group" 거절(`masc_tui_types.ml:10178-10183`)은 지운다.
- 목록 고르기에서 `HTTP tail`/`CLI tail` 대신 종류만 적는다.

TUI 디코더(`tui_decode.ml:7439-7475`)와 대시보드(`dashboard-standalone-lanes.ts:165-170`)는 wire 필드를 엄격하게 읽는다. 그래서 서버, TUI, 대시보드는 같은 PR 에 들어가 함께 배포된다.

쓰기 쪽(`append`/`drop`/`move`/`set_exact_output_lane_slots`, routing API)은 목록 하나를 다룬다. `exact_slot_list`(`Catalog_slots | Cli_slots`) 타입은 지운다. 남는 거절은 두 가지다. 모르는 id, 그리고 출력 스키마가 없는 클라이언트다.

### 3.7 verifier

verifier 는 agent_core flow 가 아니라 도구 호출(`report_review_verdict`)로 판정을 받는다. 그래서 3.3 의 walker 를 쓰지 않는다. 대신 두 가지를 맞춘다.

- 선언은 3.1 의 `slots` 하나다. 슬롯마다 하는 verifier 입장 검사(`verifier_runtime_admission`)는 그대로다.
- 순서는 3.4 의 규칙을 쓴다. 지금 verifier 는 선호 순서도 쉬는 슬롯 규칙도 쓰지 않는다.

## 4. 이미 저장된 데이터 (hard cut)

- **라이브 `runtime.toml`**: 네 lane 모두 `cli_slots = []` 이다 (2026-09-28). 배포할 때 그 줄만 지우면 된다. 지금 binary 에서 `cli_slots` 는 없어도 되는 키다. 그러니 **줄을 먼저 지우고, 그다음 새 binary 를 설치한다.** 순서를 바꾸면 새 binary 가 모르는 키로 로드를 거절한다. 편집은 admin raw endpoint 로 한다.
- **preset**: `<base-path>/.masc/presets/*/runtime.json` 아래에서 조사한 14개가 모두 `"cli_slots"` 를 들고 있다. 저장 위치는 `Prompt_preset.presets_dir`가 `Config_dir_resolver.masc_root ~base_path`에서 정한다. 읽는 코드(`prompt_preset.ml:327-328`)는 이 필드를 필수로 요구한다. 새 형식을 읽는 호환 reader 는 만들지 않는다 (projects.md). 운영자가 배포 때 한 번 다시 쓴다 (6장 Q2). changelog 에는 `Fresh state required` 로 적는다.
- **benchmark config 생성기**(`benchmarks/terminal_bench/configs/render_configs.py:195-262`)도 목록 하나를 쓰도록 고친다.

## 5. 나눠 올리는 순서

1. **넘김 판정을 바꾼다 (Q1).**
   - agent_core 의 flow 안 판정에서 3.3 표의 앞 세 줄을 넘김으로 바꾼다.
   - 이러면 지금 Stagehand 만 하는 "HTTP 가 끝나면 CLI 로" 가 네 lane 에도 맞는 규칙이 된다. walker 를 모으기 전에 해야 Stagehand 의 동작이 한 번 멈춤으로 갔다가 돌아오지 않는다.
2. **walker 와 정렬 규칙만 모은다. 설정은 그대로 둔다.**
   - `Exact_lane_walk` 와 3.4 의 정렬 규칙을 만든다.
   - lane 다섯 곳이 `slots @ cli_slots` 를 넘겨 이것을 부르게 한다. 순서가 지금과 같으니 결과도 같아야 한다.
   - 이 단계에서 달라지는 것은 1장의 어긋남 두 가지뿐이다 (Board 의 CLI bind 와 기록, 선호 순서의 CLI id).
   - 각 lane 의 기존 테스트가 그대로 초록이어야 한다. 이것이 하네스다.
3. **`slots` 하나로 hard cut 한다.**
   - 설정 형식·로드 검사, registry, 쓰기, routing API, projection v3, `exact_slot_kind`, TUI, 대시보드, 첫 설정·install, preset reader, 문서, fixture 를 바꾼다.
   - 서버·TUI·대시보드가 함께 가야 해서 한 PR 이다. 크면 테스트 fixture 정리만 앞선 PR 로 뺀다.
4. **verifier 를 3.7 대로 맞춘다.**

## 6. 정한 것

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
  - 대가: catalog 를 바꾼 뒤 남은 옛 id 가 있으면 부팅이 멈춘다. 로드 오류는 id 를 이름으로 적는다.

## 7. 다루지 않는 것

- HTTP·CLI 한 번 호출에 걸리는 시간 한도는 그대로다 (HTTP `exact_body_timeout_s`, CLI 는 모델의 `turn_timeout_s` 또는 300초). lane 전체의 시간 한도는 지금도 없고, 이 RFC 도 만들지 않는다.
- 조사 중 따로 찾은 것은 이 RFC 가 고치지 않고 issue 로 남긴다.
  - Antigravity 실패는 quota window 에 아무것도 쓰지 않는다 (`fusion_official_client.ml:447-455`). 그래서 Antigravity 슬롯은 쉬는 슬롯으로 잡히지 않는다.
  - `flow_execution_binding_standing` 은 "앞 슬롯은 답했지만 도메인에서 거절, 다음 슬롯은 429" 인 flow 를 "모두 쉬는 중" 으로 읽을 수 있다 (`exact_output.ml:2156-2176`). 확인이 더 필요하다.

## 8. 검증

- **walker 단위 테스트** (가짜 HTTP 묶음 runner, 가짜 CLI runner):
  - 적힌 순서를 지킨다.
  - 쉬는 슬롯은 안정 분할로 뒤에 가고 사라지지 않는다.
  - 묶음 경계는 정렬 뒤에 정해진다.
  - masc 자기 기록 실패와 취소에서만 멈춘다. 결과를 모르는 전송 오류, 이상한 모양의 답은 다음 슬롯으로 넘어간다.
  - `cli_request = None` 이면 CLI 슬롯을 건너뛰고 사유를 남긴다.
  - run 기록은 하나이고 `selected_slot` 이 맞다.
- **1단계 하네스**: lane 다섯 곳의 기존 스위트가 고치지 않은 채로 초록이다.
- **로드 검사**: 모르는 id, 두 종류로 읽히는 id, 출력 스키마가 없는 클라이언트가 각각 이름을 적은 로드 오류가 된다.
- **TUI PTY**: CLI 슬롯을 HTTP 슬롯 위로 옮기면 `move` 가 가고, 목록이 그 순서로 다시 그려진다.
- **라이브 canary**: `hitl_auto_judge` 에 `claude_code.claude-sonnet-5` 를 GLM 앞에 두고 하루 돌린다. run 기록의 `selected_slot` 분포와 걸린 시간을 HTTP 가 앞일 때와 비교한다.

## 9. 참고한 것

- LiteLLM Router: 서로 다른 provider 의 deployment 를 `order` 하나로 줄 세운다. cooldown 중인 deployment 는 잠시 후보에서 빠진다 (https://docs.litellm.ai/docs/routing, 2026-09-28 확인).
- OpenRouter provider routing: `provider.order` 로 순서를 적고, `allow_fallbacks` 로 목록 밖으로 넘어갈지 정한다 (https://openrouter.ai/docs/guides/routing/model-fallbacks).
- masc Fusion 자리 (`RFC-fusion-seat-routes.md` §2.1): HTTP 와 CLI runtime 을 한 후보 목록에 섞어 적는다.
