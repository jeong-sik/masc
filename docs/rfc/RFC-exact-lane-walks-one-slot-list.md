---
rfc: "exact-lane-walks-one-slot-list"
title: "An exact lane walks one slot list in the order it is written"
status: Draft
created: 2026-09-28
updated: 2026-11-21
author: claude
supersedes: []
superseded_by: null
related: ["cli-runtimes-as-lane-slots", "fusion-seat-routes", "every-lane-is-one-row-in-one-registry", "one-slot-fault-judgment-for-every-walk", "exact-lane-waits-for-a-stated-reset", "exact-request-waits-only-for-a-seat", "librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line"]
---

# exact lane 은 슬롯 목록 하나를 적힌 순서대로 걷는다

## 1. 문제

exact lane 은 슬롯을 두 목록에 나눠 적는다. 표준 lane(`[runtime.exact_output_lanes.*]`)과 Add-on lane(`[runtime.addon_exact_lanes.*]`)이 같다.

```toml
[runtime.exact_output_lanes.librarian_exact]
slots = ["glm-coding.glm-5.3-flash", "openai-responses.gpt-5-6-luna"]   # HTTP
cli_slots = ["claude_code_a.claude-haiku-5-5"]                           # 공식 클라이언트
```

코드는 언제나 `slots` 를 다 쓴 뒤에만 `cli_slots` 로 간다.
운영자는 「Claude Code 로 먼저, 안 되면 GLM」을 적을 수 없다.
「구독 CLI 를 토큰 과금 API 보다 먼저」도 적을 수 없다.
Keeper 레인(`[runtime.lanes.*] candidates`)은 이미 HTTP 와 CLI 를 한 목록에 섞어 적는다.

### 1.1 운영에서 생긴 일 (2026-11-20 KST)

`<base-path>/.masc/exact-lane-runs-v7.jsonl` 의 `complete` 줄을 셌다.
lane 은 `librarian_exact`(working-context pass)이고, 센 값은 `completion.selected_slot` 이다.
이 lane 에는 HTTP slot 아홉과 Claude Code slot 둘이 있다.

| 답한 slot | 과금 | 성공 |
|---|---|---|
| `openai-responses.gpt-5-6-luna` | 토큰 과금 | 872 |
| `glm-coding.glm-5.3-flash` | 구독 | 779 |
| Claude API 계정 하나의 haiku | 토큰 과금 | 400 |
| `cli_slots` 의 Claude Code 둘 | 구독 | 0 |

- 성공 2,051건 가운데 1,272건(62%)을 토큰 과금 slot 이 받았다.
- Claude Code slot 은 HTTP slot 아홉이 모두 실패한 뒤에만 불린다. 이날 답한 적이 없다.
- Claude Code 를 앞에 두었다면 성공했을지는 이 기록으로 알 수 없다. Claude Code 에는 주간 한도가 있다.

### 1.2 구별이 퍼진 곳 (main `93894461a2911`)

| 층 | 곳 |
|---|---|
| 설정·로드 | `Runtime_schema.exact_output_lane_decl` 의 `slot_ids`·`cli_slot_ids`, `runtime_toml`, `runtime.ml` 의 `runtime_slot_references`·`validate_exact_lane_cli_slots`, `Runtime_lane_edit.exact_slot_list`(`Catalog_slots \| Cli_slots`) |
| registry | `Runtime_exact_output_registry.resolved_lane = { selected_slots; cli_slots }` |
| 걷기 | 일곱 곳이 「HTTP 다음 CLI」를 따로 조립한다. 아래 표 |
| 쉼 순서 | `Runtime_candidate_standing.order_exact` 를 종류마다 따로 부른다. HTTP 는 `Runtime_exact_lane_backpressure.order`, CLI 는 `Keeper_lane_cli_oneshot.order_slots_at` 이다 |
| 자리 | HTTP 만 센다. agent_core 의 `seat_for_candidate` 는 그 flow 의 뒤 HTTP 후보만 본다. CLI one-shot 은 자리 없이 프로세스를 띄운다(`RFC-exact-request-waits-only-for-a-seat` §1.5) |
| 걷기 영수증 | `Keeper_exact_walk_receipt` 가 http 칸과 cli 칸을 따로 저장한다 |
| 화면 | standalone lane projection, `tui_decode`, `bin/` 9개 파일, `dashboard/src` 16개 파일 |
| 시험·문서 | `test/` 28개 파일, `docs/` 16개 파일 |

| 걷는 곳 | 쓰는 lane |
|---|---|
| `server_lane_addon_exact.ml` 의 `call` | Add-on lane 전부(keeper-librarian admission·durable, workspace-curator, candle-appraiser, operator-quiz) |
| `librarian_ask.ml` 의 `walk_lane` | `librarian_memory` |
| `keeper_librarian_runtime.ml` 의 `try_cli_slots` | `librarian_exact`(working-context pass) |
| `server_workspace_memory_curator.ml` | Curator 원본 |
| `keeper_board_attention_exact_flow.ml` 의 `walk_cli_slots` | `board_attention_exact` |
| `hitl_summary_worker.ml`, `hitl_summary_cli_walk.ml` | `hitl_auto_judge` |
| `runtime.ml` 의 `verifier_exact_lane_slots` | `verifier_exact` |

조립도 서로 다르다.
- HITL 은 CLI 방문 전에도 approval queue 를 bind 한다. CLI bind 가 실패하면 그 slot 만 건너뛴다. HTTP bind 실패는 걷기를 멈춘다.
- Board 는 HTTP 방문에만 bind 한다. partition 진행 기록에 CLI 방문을 적을 모양이 없다(3.8).

## 2. 지난 시도

- CLI 슬롯을 들인 RFC(2026-08-29)는 목록을 나누지 않았다.
  - §3 은 슬롯 목록 하나에 runtime id 를 HTTP target 과 나란히 적는다.
  - §5 는 구독 한도 때문에 「CLI 슬롯 뒤에 HTTP fallback 을 두라」고 권한다. CLI 가 앞에 올 수 있다는 전제다.
- 나눈 것은 Fusion 자리 RFC §2.1 이다. 까닭은 「HTTP 요청 본문을 만드는 경로와 CLI 경로가 달라서」였다. 실행 경로의 차이가 설정 형식으로 새어 나왔다.
- 이 RFC(2026-09-28)는 1단계(#39718, #39740)만 그날 들어갔다. 2단계부터는 PR 이 없다.
- 이슈 #37138(2026-09-19)은 「구독 HTTP → 구독 CLI → 유료 HTTP」 순서를 요청했다. 2026-11-13 에 「원하는 lane 이 없다」며 NOT_PLANNED 로 닫혔다. 1.1 의 기록은 그 판단과 반대다.
- `RFC-any-runtime-serves-an-exact-lane`(#43057)은 목록 합치기를 이 RFC 로 미뤘다.
- `RFC-exact-request-waits-only-for-a-seat`(#52986)는 HTTP 걷기에 자리를 넣었다(#52995, #53014). Exact lane 의 CLI binding 에는 `max-concurrent` 선언을 요구했다(#53025). 그리고 두 목록을 전제로 「CLI 는 HTTP 가 모두 실패하거나 쉴 때만」을 정했다. CLI 자리를 세는 일은 아직 없다.
- 그사이 두 목록을 전제하는 곳이 늘었다. Add-on host, `librarian_memory`, 걷기 영수증이다.

## 3. 결정

### 3.1 슬롯은 runtime 을 가리키는 id 하나다

lane 은 `slots` 하나만 적는다. 적힌 순서가 시도 순서다.

```toml
[runtime.exact_output_lanes.librarian_exact]
slots = [
  "glm-coding.glm-5.3-flash",
  "claude_code_a.claude-haiku-5-5",
  "openai-responses.gpt-5-6-luna",
]
```

`cli_slots` 키는 hard cut 이다. 새 binary 는 이 키를 모르는 키로 보고 로드를 거절한다.

### 3.2 종류는 id 가 가리키는 runtime 에서 나온다

로드 검사는 id 를 runtime 표에서 찾는다. target 목록에서 찾지 않는다.
- target 목록은 로드 뒤 registry 를 publish 할 때 만들어진다.
- 기한 설정이 빠진 슬롯은 target 에서 빠지지만 boot 에서 degraded 로 남는다.

종류는 지금의 입장 판정(`Runtime_lane_edit.exact_slot_list_admitting`)이 api format 으로 정한다. 바뀌는 것은 결과가 목록 이름이 아니라 종류라는 점이다.

| id 가 가리키는 것 | 처리 |
|---|---|
| 출력 스키마를 받는 공식 클라이언트 runtime(Claude Code, Codex, Antigravity CLI) | CLI slot |
| Agent Core runtime(Messages, Chat Completions, Ollama, Gemini, Vertex) | HTTP slot. 기한 설정이 빠졌으면 지금처럼 degraded 로 보인다 |
| 출력 스키마 경로가 없는 runtime(ACP driver: Muse Code, Mistral Vibe, Kimi Code, Antigravity) | 로드 오류 |
| 선언은 됐지만 꺼진 binding·provider | 받지 않고 `dropped` 로 보인다. 사유는 "disabled" (Q5) |
| 아무것도 가리키지 않음, 기본 catalog | 로드 오류 (Q4) |
| 아무것도 가리키지 않음, `AGENT_CORE_MODEL_CATALOG` 교체 catalog | HTTP target 으로 본다. publish 때 registry 가 받거나 `dropped` 로 뺀다 |

마지막 줄이 Q4 의 한계다. 로드는 교체 catalog 파일을 읽지 않는다. 그래서 그 배포에서는 오타가 publish 진단으로 드러난다.

### 3.3 walker 하나, 걸음 하나에 slot 하나

verifier 를 뺀 여섯 곳의 조립을 `Exact_lane_walk` 하나로 바꾼다. verifier 는 3.10 에서 다룬다.

한 걸음은 slot 하나다.
- HTTP slot 은 후보 하나짜리 agent_core flow 를 walker 가 잡은 자리로 돌린다.
- CLI slot 은 one-shot 하나를 walker 가 잡은 자리로 돌린다.

09-28 판은 이어진 HTTP slot 을 flow 하나로 묶었다. 이 개정은 묶지 않는다(Q9).
- 자리를 종류와 상관없이 고르려면(3.6) 고르는 쪽이 남은 목록 전체를 봐야 한다.
- agent_core 의 자리 고르기는 그 flow 의 뒤 HTTP 후보만 본다. 꽉 찬 HTTP slot 뒤에 빈 CLI slot 이 있어도 flow 는 HTTP 줄에 선다.
- 묶음을 남기려면 자리가 flow 와 walker 사이를 양쪽으로 오가야 한다. walker 가 잡은 자리를 flow 의 k 번째 후보에 넘기고, flow 밖의 slot 이 자리를 주면 flow 가 그 자리를 walker 에 돌려준다. agent_core 가 자기가 모르는 slot 의 자리를 다루게 된다.
- 대가: flow 단위로 남던 기록이 walker 의 방문 목록으로 올라온다. 넘김 기록, 검증된 evidence, Board 의 replay guard, 걷기 영수증이 그렇다.

```ocaml
type visit =
  | Http_visit of Exact_output.candidate_visit
  | Cli_visit of { runtime_id : string; call_id : string; prompt_sha256 : string }
```

CLI 방문의 모양은 HITL 이 이미 쓰는 것을 옮긴다(`hitl_summary_cli_walk.ml`).

**멈추는 경우는 둘뿐이다** (Q1).
- masc 자기 일이 실패했다. 방문 전 bind, 넘김 기록, 측정 callback 이 실패했거나 flow 에 id 를 주지 못한 경우다.
- 취소.

나머지 실패는 HTTP 든 CLI 든 다음 slot 으로 넘어간다. 도메인 검증 거절도 넘어간다.
- flow 안의 판정은 1단계(#39718, #39740)가 이미 이렇게 바꿨다. walker 는 걸음마다 `Exact_output.flow_execution_terminal_kind` 로 넘길지 정한다.
- HITL 의 CLI bind 실패도 이 규칙을 따른다. bind 실패는 masc 자기 기록 실패이니 HTTP 와 CLI 모두 멈춘다.
- 설정 오류로 시작할 수 없는 slot 은 멈추지 않는다. 빈 candidate id·중복 candidate id 로 flow 를 시작하지 못한 경우는 그 slot 하나의 선언 오류라 그 slot 을 실패 방문으로 적고 다음 slot 으로 넘어간다. flow 에 id 를 주지 못한 경우는 masc 자기 실패라 멈춘다.

### 3.4 lane 이 walker 에 넘기는 것

lane 마다 다른 것은 callback 몇 개로 끝나지 않는다. HITL 의 approval queue 와 Board 의 partition 은 저장되고 다시 읽히는 상태 전이다. 그래서 walker 는 방문마다 lane 에 알리고, lane 은 자기 상태 전이로 답한다.

| 받는 것 | 하는 일 | 쓰는 lane |
|---|---|---|
| `validate` | 답을 도메인 값으로 읽는다. HTTP 답이면 provenance 도 본다 | 전부 |
| `cli_request` | 메시지를 `(system_prompt, prompt)` 로 바꾼다. 바꿀 수 없으면 `None` 이고 그 요청에서는 CLI slot 을 건너뛴다(`Cli_unfit`) | 전부. Add-on 의 assistant 턴이 든 요청이 `None` 이다 |
| `admit_http` | 보내기 전에 HTTP slot 을 거른다 | `librarian_memory`(크기 사실), Add-on(크기 거절 건너뛰기) |
| `before_visit visit` | 방문 직전 durable bind. 실패하면 걷기를 멈춘다 | HITL, Board, Add-on |
| `on_advance ~failed ~next` | 넘어갈 때 기록한다. `next` 는 어느 종류든 된다 | Board(`Advancing`), HITL(실행 실패일 때만 release) |
| `commit visit value` | 받아들인 답을 durable 하게 적용한다 | HITL(`complete_exact_attempt`), Board |
| `record` | run 기록을 남길지와 어떻게 남길지 | 전부 |

```ocaml
type 'a walk_result =
  | Answered of { visit : visit; value : 'a; visits : visit_outcome list }
  | Exhausted of { visits : visit_outcome list; standing : standing }
  | Stopped of { visit : visit; cause : stop_cause; visits : visit_outcome list }
```

`visits` 에는 slot 마다 무슨 일이 있었는지가 걸은 순서대로 남는다. lane 마다 다른 실패 해석은 이 목록을 읽는다.
- HTTP 방문의 결과는 agent_core 의 값을 그대로 담는다. 성공이면 usage 와 입력 측정이 들어 있다. Librarian 의 측정 카운터가 이 값을 읽는다.
- HITL 의 마지막 정리(`quarantine_candidate`, `handle_flow_error`, `handle_semantic_exhaustion`)는 지금 마지막 bind 가 HTTP 였는지로 갈린다. 새 모양에서는 마지막 방문의 종류를 `visits` 에서 읽는다.
- working-context pass 의 입력 용량 판정(`input_capacity_of_failure`)은 실패 evidence 를 읽는다. 그 evidence 를 `visits` 에서 만든다.
- Board 의 Jev 사전 판정은 walker 밖에 그대로 둔다. lane 에 HTTP slot 이 하나라도 있으면 걷기 전에 돈다. 목록에서 HTTP slot 이 어디에 있든 같다.

### 3.5 순서

**쉬는 slot.**

```text
resting slot =
     quota window 가 그 slot 의 scope 를 다 썼다고 한다
  || backpressure 칸에 path_rest_sec 안의 429 가 있다
```

- scope 는 `Runtime_instance.quota_scope_of_runtime` 가 종류마다 알려 준다. HTTP 는 credential, Claude·Codex 는 client home, Antigravity 는 credential 파일이다.
- CLI 도 429 칸에 써야 판정이 정직하다. 지금 one-shot 경로는 quota window 에만 쓰고 이 칸에는 쓰지 않는다. 이 칸에 쓰는 곳은 Keeper 턴 드라이버와 Add-on sampling 뿐이다.
- 그래서 walker 는 CLI 방문이 속도 제한으로 거절되면(`Keeper_lane_cli_oneshot.refused_for_binding_rest`) 그 runtime 의 칸에 쓴다. HTTP 는 지금처럼 `observe` 가 쓴다.

**정렬.**
1. 적힌 순서에서 시작한다.
2. Keeper 선호 순서를 입힌다. 선호 저장소는 id 로 읽으므로 CLI id 도 받는다.
3. provider 가 말한 시각(quota scope 의 리셋, 그 slot 이 받은 Retry-After) 전의 slot 은 이번 걸음에서 부르지 않는다. 목록에는 남는다(`RFC-exact-lane-waits-for-a-stated-reset`).
4. masc 가 정한 쉼은 안정 분할(stable partition)로 뒤로 보낸다. 쉬지 않는 slot 이 적힌 순서대로 먼저, 쉬는 slot 이 적힌 순서대로 뒤에 온다.
5. 걸음마다 남은 slot 을 다시 정렬한다.

LiteLLM 은 cooldown 중인 deployment 를 후보에서 잠시 뺀다. masc 는 빼지 않고 뒤로 보낸다. 시간이 지났다는 이유로 후보를 죽이지 않는다(constitution `no_wall_clock_death`).

**섞인 목록에서 달라지는 것.**
- 적힌 순서가 `[h1, c1]` 이고 h1 이 masc 가 정한 쉼이면 `[c1, h1]` 로 걷는다. 지금은 h1 을 먼저 불러 429 를 한 번 더 받고 c1 로 간다.
- h1 의 쉼이 provider 가 말한 시각이면 그 시각 전에는 `[c1]` 만 걷는다.
- 쉬지 않는 slot 이 앞에 있으면 CLI 는 그 slot 이 실패하거나 꽉 찼을 때만 불린다(3.6).

**hard cut 전까지는 종류마다 정렬한다.** registry 가 두 목록을 주는 동안(5장 4층 전) walker 는 HTTP 무리와 CLI 무리를 따로 정렬하고 HTTP 무리를 앞에 둔다. 지금 동작과 같다. 하나의 정렬은 hard cut 에서 켠다.

### 3.6 자리

모든 slot 이 자리를 가진다.
- HTTP slot: endpoint identity(종류, base URL, API key)의 `max-concurrent`. 선언하지 않았으면 늘 빈 것으로 본다. 지금과 같다.
- CLI slot: 공식 클라이언트 binding 의 `max-concurrent`. Exact lane 에 든 binding 은 선언이 필수다(#53025). 계정(provider)마다 센다. 한 계정의 binding 들이 서로 다른 수를 적으면 로드 오류다. HTTP 의 `allowances_of_configs` 와 같은 규칙이다.

고르는 규칙은 종류를 보지 않는다(Q7).
1. 정렬한 목록의 앞에서부터, 기다리지 않고 자리를 받을 수 있는 첫 slot 을 부른다. 「기다리지 않고」는 빈 자리가 있고 그 줄에 앞선 요청이 없다는 뜻이다.
2. 그 앞의 slot 은 `Seats_full` 방문으로 적고 이 요청에서 다시 보지 않는다.
3. 모두 꽉 찼으면 남은 모든 slot 의 줄에 같이 선다. 각 줄에는 그 요청의 admission class 로 선다. 처음 자리를 받은 slot 을 부른다.
4. 받은 자리는 그 걸음이 끝날 때 돌려준다. 걷기가 그 slot 에 닿기 전에 끝나면 walker 가 돌려준다.

`RFC-exact-request-waits-only-for-a-seat` §2 의 「CLI 는 HTTP 가 모두 실패하거나 쉬거나 지나쳐졌을 때만」은 이 규칙으로 바뀐다. 그 RFC 의 §3.1 걷기가 종류를 가리지 않고 목록 전체에 걸린다. 같은 PR 에서 그 RFC 의 문장도 고친다.

hard cut 전에 달라지는 것은 하나다. registry 는 아직 HTTP 다음 CLI 를 준다. 그래서 HTTP slot 이 모두 꽉 찼고 CLI slot 에 빈 자리가 있으면 CLI 를 부른다. 지금은 HTTP 줄에서 기다린다.

구현은 이렇다.
- agent_core 의 `Provider_admission.take_first_seat` 는 endpoint config 만 받는다. 자리의 근원을 둘로 넓힌다. endpoint config(HTTP)와, 호출자가 준 `Slot_scheduler`(CLI)다. agent_core 는 CLI 를 모른다.
- agent_core 에 후보 하나짜리 flow 를 이미 잡은 자리로 돌리는 입구를 둔다. 재기와 생성은 지금처럼 그 자리 하나로 한다.
- masc 는 공식 클라이언트 계정마다 `Slot_scheduler` 하나를 둔다.
- 여러 줄에 같이 서는 일은 지금 경주(`wait_for_first_seat`)를 그대로 쓴다. 늦게 받은 자리는 바로 돌려준다.
- 5장 5층 전에는 CLI 계정의 자리를 Exact CLI 호출만 센다. Keeper 턴은 세지 않는다. 지금은 아무것도 세지 않으므로 그보다 좁다.

### 3.7 run 기록과 걷기 영수증

- 호출 한 번에 run 기록 하나다. 지금과 같다.
- `selected_slot` 은 답한 slot 이다. 끝까지 답이 없으면 마지막으로 부른 slot 이다. 종류는 따지지 않는다.
- lane 이 「쉬는 중」이라고 말하려면 걸은 slot 이 모두 자기 계정 사정으로 거절했어야 한다. provider 가 말한 시각 전이라 부르지 않은 slot 도 거기 센다. 이 규칙은 지금 Board worker 에 있다. walker 로 옮긴다.
- 걷기 영수증은 http 칸과 cli 칸 대신 방문 목록 하나를 담는다. 새 모양은 walker 와 같이 들어간다(5장 2층).
- 영수증은 지금 flow 하나의 방문 순번을 검사한다. 걸음마다 flow 가 따로 서므로 이 검사는 방문 목록의 검사로 바뀐다.
- 영수증을 저장하는 lane 은 옮기는 PR 에서 새 모양으로 바꾼다. 마지막 lane 을 옮기면 옛 영수증 모듈은 지운다.

### 3.8 Board partition 의 진행 기록

Board 는 판단 대상 partition 마다 진행 상태를 저장한다. 지금 그 모양은 HTTP 방문만 담는다.
- `candidate_visit` 은 `flow_id`, 순번, catalog 지문, target 지문을 모두 요구한다. CLI 방문에는 이 값들이 없다. 그래서 `Advancing { next = CLI }` 를 쓸 수 없다.
- `bind_before_dispatch` 는 `Bound a → Bound b` 를 거절한다. `Advancing { next }` 에서 `next` 가 아닌 slot 의 bind 도 거절한다. HTTP 실패 뒤 CLI bind 가 여기서 막힌다.
- `legal_transition` 과 `complete_after_advancing` 은 CLI 가 HTTP 걷기 뒤에만 돈다고 가정한다.
- 진행 상태는 저장되고, Blocked 행에도 남는다.

그래서 Board 의 진행 기록을 3.3 의 `visit` 합타입으로 바꾼다. 전이 표는 `_ -> false` 없이 모든 쌍을 적는다. 저장된 행의 모양이 바뀌므로 4장의 hard cut 대상이다(Q6).

### 3.9 서버·TUI·대시보드

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
- `dropped_slots` 는 남긴다. CLI slot 도 들어갈 수 있다(꺼진 binding).
- `selected_slots`(slot 별 run 수)와 `runs_without_slot` 은 slot id 로 세므로 그대로 둔다.
- `/api/v1/runtime/resolved` 의 `exact_slot_group`(`"slots" | "cli_slots" | null`)은 `exact_slot_kind`(`"http" | "cli" | null`)로 바꾼다. `null` 은 출력 스키마 경로가 없는 runtime 이다.

TUI 와 대시보드는 목록 하나를 그린다.
- 줄마다 `[HTTP]` 또는 `[CLI]` 를 붙인다.
- `J`/`K`(대시보드는 ↑/↓)는 종류와 상관없이 순서를 바꾼다. 「Reorder within a group」 거절은 지운다.
- slot 을 더할 때 고르는 「HTTP tail」·「CLI tail」은 「목록 끝」 하나가 된다.

TUI 디코더와 대시보드는 wire 필드를 엄격하게 읽는다. 그래서 서버, TUI, 대시보드는 같은 PR 에 들어가 함께 배포된다.

쓰기 쪽(`append`/`drop`/`move`/`set_exact_output_lane_slots`, routing API)은 목록 하나를 다룬다. `exact_slot_list` 타입은 지운다.

### 3.10 verifier

verifier 는 agent_core flow 가 아니라 도구 호출(`report_review_verdict`)로 판정을 받는다. 그래서 3.3 의 walker 를 쓰지 않는다.
- 선언은 3.1 의 `slots` 하나다. 슬롯마다 하는 입장 검사(`verifier_runtime_admission`)는 그대로다.
- `verifier_exact_lane_slots` 는 지금 HTTP id 뒤에 CLI id 를 붙인다. 적힌 순서 하나를 돌려주게 바꾼다.
- 순서는 3.5 의 규칙을 쓴다. 지금 verifier 는 선호 순서도 쉬는 slot 규칙도 쓰지 않는다.
- 3.6 의 자리 규칙은 verifier 에 걸지 않는다(7장).

### 3.11 Librarian

- `Librarian_memory_lane.t` 의 `http`·`cli` 두 목록은 `slot_key` 목록 하나가 된다. 순서가 다르면 다른 값이라는 성질은 그대로다.
- `RFC-librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line` §7.1 의 4번을 이 규칙으로 고친다. 이 개정과 같은 PR 이다.
- 바닥 판정(`Librarian_bottom.fold`)은 선언한 모든 slot 을 보므로 그대로다.
- Add-on host 의 keeper-librarian 갈래(`Background` 를 고르는 곳)는 Librarian 컷이 지운다. walker 로 옮길 때 그 동작은 바꾸지 않는다.

## 4. 이미 저장된 데이터 (hard cut)

- **운영 `runtime.toml`**: 2026-11-21 파일에서 `cli_slots` 를 적은 표는 열한 개다. 둘은 빈 목록이다.
  - 배포는 서버를 멈춘 사이에 한다. 서버 정지 → 파일 편집 → 새 binary 설치·시작 순서다. 옛 binary 를 바뀐 파일로 띄우지 않는다.
  - 편집은 `cli_slots` 항목을 `slots` 끝에 붙이고 `cli_slots` 키를 지운다. 그러면 지금 순서가 그대로다. 원하는 순서는 그다음 TUI 에서 바꾼다.
- **preset**: `<base-path>/.masc/presets/*/runtime.json` 은 `"cli_slots"` 를 들고 있다(2026-11-21 운영 둘). 읽는 코드(`Prompt_preset`)는 이 필드를 요구한다. 호환 reader 는 만들지 않는다. 운영자가 배포 때 한 번 다시 쓴다(Q2).
- **걷기 영수증**: Add-on Exact 요청 기록(`lane-addons/exact-requests/`)과 keeper-librarian admission 기록이 영수증을 저장하고 다시 읽는다. 호환 reader 는 만들지 않는다. Add-on host 를 옮기는 PR 의 changelog 에 `Fresh state required` 로 적는다. Librarian 컷이 먼저 들어가면 뒤의 것은 없다.
- **Board partition 진행 기록**(3.8): Q6 을 따른다.

## 5. 나눠 올리는 순서

각 층은 PR 하나다. 한 native stack 으로 쌓거나, 앞 층이 main 에 들어간 뒤에 올린다.

0. **넘김 판정** — 끝남(#39718, #39740).
1. **자리의 근원을 넓힌다**(3.6). agent_core 의 자리 고르기가 endpoint config 와 호출자가 준 scheduler 를 함께 받는다. 후보 하나짜리 flow 를 이미 잡은 자리로 돌리는 입구를 둔다. masc 는 공식 클라이언트 계정마다 scheduler 를 둔다.
2. **walker 와 새 걷기 영수증을 만든다**(3.3~3.7). 가짜 HTTP runner 와 가짜 CLI runner 로 시험한다. CLI 의 429 를 칸에 쓴다. 정렬은 3.5 의 「hard cut 전」 규칙을 따른다.
3. **lane 을 하나씩 옮긴다.** lane 하나가 PR 하나다.
   - 순서는 Add-on host, `librarian_memory`, working-context pass, Curator, HITL, Board 다. Board 는 진행 기록 합타입(3.8)을 같은 PR 에 넣는다.
   - 옮긴 lane 의 기존 시험은 Q7·Q1 이 바꾸는 단언 말고는 고치지 않은 채 초록이어야 한다. 이것이 하네스다.
   - 옮긴 lane 에서 달라지는 것은 둘이다. HTTP 가 모두 꽉 차면 CLI 로 간다(Q7). HITL 의 CLI bind 실패가 걷기를 멈춘다(Q1).
4. **`slots` 하나로 hard cut 하고 정렬을 하나로 켠다.**
   - 설정 형식·로드 검사(3.2), registry, 쓰기, routing API, projection v3, `exact_slot_kind`, TUI, 대시보드, 첫 설정·install, preset reader, 문서, fixture 를 바꾼다.
   - verifier 의 선언과 순서(3.10)도 이 층이다.
   - 서버·TUI·대시보드가 함께 가야 해서 한 PR 이다. 크면 시험 fixture 정리만 앞선 PR 로 뺀다.
5. **Keeper 턴도 공식 클라이언트 자리를 같이 센다**(`RFC-exact-request-waits-only-for-a-seat` §3.2 의 나머지).

3층에서 lane 을 하나씩 옮기는 것은 N-of-M 패치가 아니다. 공통 부분은 walker 한 곳에 먼저 생기고, 각 PR 은 lane 하나가 그것을 쓰게 바꾼다. 마지막 lane 이 옮겨지면 「HTTP 다음 CLI」를 조립하는 곳은 남지 않는다.

## 6. 정한 것

- **Q1. 어떤 실패에서 멈추나?** — 정함(운영자, 2026-09-28).
  - masc 자기 기록 실패와 취소에서만 멈춘다. 나머지는 HTTP·CLI 모두 다음 slot 으로 넘긴다.
  - 대가: 결과를 모르는 요청이 실제로는 provider 에서 처리됐다면 한 번 더 과금된다.
- **Q2. preset 은?** — 정함(운영자, 2026-09-28). 배포 때 운영자가 한 번 다시 쓴다. `cli_slots` 항목을 `slots` 끝에 붙여 지금 순서를 지킨다. 변환 코드는 넣지 않는다.
- **Q3. 첫 설정이 쓰는 기본 순서는?** — 정함(운영자, 2026-09-28). HTTP 를 앞에, CLI 를 뒤에 쓴다. CLI 한 번은 프로세스를 띄우느라 몇 초 걸리고 구독 한도도 쓴다. 파일에 적히는 기본값일 뿐이다.
- **Q4. `slots` 의 모르는 id 도 로드를 막는가?** — 정함(운영자, 2026-09-28).
  - 막는다. 막지 않으면 CLI id 오타가 조용히 사라진다.
  - 대가: 기본 catalog 에서 옛 id 가 남으면 부팅이 멈춘다. 로드 오류는 id 를 이름으로 적는다.
- **Q5. 꺼진 binding·provider 를 가리키는 slot 은?** — 정함(운영자, 2026-09-28).
  - 받지 않고 `dropped` 로 보인다. 종류와 상관없다. 꺼짐은 오타가 아니라 운영자가 정한 상태다.
  - 바뀌는 것: 지금은 `cli_slots` 의 꺼진 runtime 이 로드를 막는다. 그대로 두면 provider 하나를 끄는 순간 파일 전체가 로드되지 않는다.
- **Q6. Board partition 의 저장된 진행 기록은?** — 정함(운영자, 2026-09-28).
  - Board 를 옮기는 PR 의 배포 전에 진행 중인 partition 이 비기를 기다린다.
  - 남은 Running·Blocked 행은 운영자 복구(requeue)로 처음부터 다시 판단한다. 판단 대상 후보는 partition 과 따로 durable 하게 남는다.
  - requeue 가 옛 모양의 진행 기록을 읽지 않고도 되는지는 그 PR 에서 확인한다.
- **Q7. 꽉 찬 slot 은?** — 정함(운영자, 2026-11-21).
  - 종류와 상관없이 지나간다. 모두 꽉 차면 먼저 비는 자리를 기다린다.
  - CLI 도 binding `max-concurrent` 로 자리를 센다. 이 층은 hard cut 전에 들어간다.
  - `RFC-exact-request-waits-only-for-a-seat` §2 의 CLI 규칙을 바꾼다.
- **Q8. 어디까지 바꾸나?** — 정함(운영자, 2026-11-21). 표준 lane 과 Add-on lane 을 모두 `slots` 하나로 hard cut 한다. walker 를 lane 마다 옮긴 뒤 마지막 PR 에서 형식을 바꾼다.
- **Q9. HTTP slot 을 flow 하나로 묶는가?** — 이 개정의 제안. 리뷰에서 정한다.
  - 묶지 않는다. slot 하나가 걸음 하나다(3.3). Q7 을 지키려면 자리를 고르는 쪽이 남은 목록 전체를 봐야 한다.
  - 대가: 걷기 영수증과 Board 진행 기록이 flow 대신 방문 목록을 담는다. 영수증을 저장하는 Add-on 요청 기록은 3층에서 새로 시작한다.

## 7. 다루지 않는 것

- HTTP·CLI 한 번 호출에 걸리는 시간 한도는 그대로다. HTTP 는 `exact_body_timeout_s`, CLI 는 모델의 `turn_timeout_s` 또는 300초다. lane 전체의 시간 한도는 지금도 없고, 이 RFC 도 만들지 않는다.
- Antigravity 실패는 quota window 에 아무것도 쓰지 않는다. 그래서 Antigravity slot 은 쉬는 slot 으로 잡히지 않는다. 이 RFC 는 고치지 않는다(#39696).
- verifier 의 자리. verifier 의 HTTP 호출은 Keeper 턴처럼 자기 endpoint 의 자리를 기다린다. 꽉 찬 slot 을 지나가게 하려면 도구 호출 경로에 자리 고르기를 넣어야 한다. 따로 다룬다.
- Add-on host 가 세는 수(`max_exact_in_flight`)를 지우는 일은 `RFC-exact-request-waits-only-for-a-seat` §3.3 이 맡는다.

## 8. 검증

- **walker 단위 시험**(가짜 HTTP runner, 가짜 CLI runner)
  - hard cut 뒤: `[cli, http]` 로 적은 lane 은 CLI 를 먼저 부른다. `[http, cli, http]` 는 그 순서로 부른다.
  - 꽉 찬 HTTP slot 은 뒤의 빈 CLI slot 에 차례를 넘기고 `Seats_full` 방문으로 남는다. 꽉 찬 CLI slot 도 같다.
  - 모두 꽉 차면 남은 slot 의 줄에 같이 서고, 처음 자리를 준 slot 을 부른다. 늦게 받은 자리는 돌려준다. 걷기가 끝나면 쥔 자리가 없다.
  - provider 가 말한 시각 전의 slot 은 부르지 않는다. masc 가 정한 쉼은 안정 분할로 뒤로 가고 사라지지 않는다.
  - hard cut 전: 쉬는 HTTP slot 이 CLI slot 보다 먼저 불린다.
  - masc 자기 기록 실패와 취소에서만 멈춘다.
  - `cli_request = None` 이면 CLI slot 을 건너뛰고 사유를 남긴다.
  - run 기록은 하나이고 `selected_slot` 이 맞다.
- **3층 하네스**: 옮기는 lane 의 기존 시험이 Q7·Q1 이 바꾸는 단언 말고는 그대로 초록이다.
- **Board partition 전이**: `visit` 합타입의 모든 쌍을 전이 표 시험으로 적는다. HTTP 실패 → CLI bind → CLI 실패 → 다음 HTTP bind 가 모두 지나야 한다.
- **로드 검사**: 3.2 표의 줄마다 시험 하나다. `cli_slots` 키는 거절된다. 한 계정의 CLI binding 이 서로 다른 `max-concurrent` 를 적으면 거절된다.
- **TUI**: CLI slot 을 HTTP slot 위로 옮기면 그 순서의 `move` 요청이 간다.
- **운영 canary**: 운영자가 `librarian_exact` 에서 구독 CLI slot 을 토큰 과금 slot 앞에 둔다. 하루 동안 `selected_slot` 분포를 1.1 과 견준다.

## 9. 참고한 것

- LiteLLM Router: 서로 다른 provider 의 deployment 를 `order` 하나로 줄 세운다. cooldown 중인 deployment 는 잠시 후보에서 빠진다(https://docs.litellm.ai/docs/routing, 2026-09-28 확인).
- OpenRouter provider routing: `provider.order` 로 순서를 적고, `allow_fallbacks` 로 목록 밖으로 넘어갈지 정한다(https://openrouter.ai/docs/guides/routing/model-fallbacks).
- masc Keeper 레인과 Fusion 자리: HTTP 와 CLI runtime 을 한 후보 목록에 섞어 적는다.
- `RFC-one-slot-fault-judgment-for-every-walk.md`: 실패가 누구의 사정인지 판정 하나. exact 걸음은 「결과 모름」을 넘김으로 바꾼다(Q1).
- `RFC-exact-request-waits-only-for-a-seat.md`: 자리 걷기. 이 개정이 그 CLI 규칙(§2)을 바꾼다(Q7).
- 이슈 #37138, #37676, PR #39718, #39740, #43057, #52995, #53014, #53025.
