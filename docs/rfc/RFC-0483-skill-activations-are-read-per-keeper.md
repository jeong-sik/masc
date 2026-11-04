---
rfc: "0483"
title: "Skill 활성화 기록은 Keeper 별로 읽는다"
status: Draft
created: 2026-11-04
updated: 2026-11-04
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0480", "0481"]
---

# RFC-0483 — Skill 활성화 기록은 Keeper 별로 읽는다

## 0. 요약

TUI Tools 화면은 2초마다 두 곳을 읽는다. 2026-11-04 운영 서버에서 `/api/v1/skills` 는 115KB 였고 237~545ms 걸렸다. Keeper 를 고른 `/api/v1/dashboard/tools?keeper=` 는 가장 큰 Keeper 에서 1,962KB 였고, 그중 1,440KB 가 활성화 기록(`skill_activations`)이었다. 어느 pane 을 열었든 둘 다 읽는다.

두 응답에는 skill 활성화 장부(ledger)에서 나온 값이 들어 있다. 이 장부는 skill 을 한 번 부를 때마다 2+k 번 쓰인다. 쓸 때마다 알리고 TUI 가 두 응답을 통째로 다시 읽으면, Keeper 가 바쁠 때는 지금 2초 주기보다 더 자주 읽게 된다.

이 RFC 는 활성화 기록을 skill 본문과 다른 읽기로 나눈다. 본문은 본문이 바뀌었다는 알림에 읽는다. 활성화 기록은 Keeper 이름이 붙은 알림에 그 Keeper 것만 읽는다.

사용자 결정(2026-11-04): 활성화 읽기를 나누는 RFC 를 먼저 쓰고, 그 뒤 Tools 의 2초 읽기를 지운다.

## 1. 지금 읽는 것

### 1.1 `/api/v1/skills`

`lib/server/server_routes_http_routes_activity.ml:1433` 이 답한다.

- 본문: config, sources, rejections, shadows, surface 목록, surface 별 `profile`.
- 사용량: surface 마다 Keeper 별 `usage[]`(TRIGGERED, DELIVERED, ACTIONS, LAST USED), 그리고 `usage_coverage`(읽은 장부 수, 못 읽은 장부).

사용량을 만들려고 요청마다 모든 Keeper 의 장부를 하나씩 차례로 읽는다(:1455-1482). Keeper 마다 `Keeper_meta_store.read_meta` 로 지금 trace 를 찾고, `Keeper_skill_activation_ledger.load` 로 그 trace 의 장부를 읽는다. `load` 는 checkpoint 저장과 같은 세션 잠금(`Keeper_checkpoint_store.with_session_lock`)을 잡는다. 응답 캐시는 없다.

### 1.2 `/api/v1/dashboard/tools?keeper=`

`lib/server/server_dashboard_http_runtime_info.ml` 이 답한다.

2026-11-04 운영 서버에서 Keeper 다섯을 세 번씩 읽었다.

| Keeper | 응답 | `skill_activations` | 시간(중앙값) |
|---|---|---|---|
| ocaml-agent-ic | 1,962KB | 1,440KB | 112ms |
| code-reviewer-brother | 1,678KB | 1,156KB | 122ms |
| msx-retro-mania | 1,614KB | 1,093KB | 124ms |
| pr-updater | 1,051KB | 529KB | 43ms |
| build-maniac | 587KB | 65KB | 112ms |

- 도구 목록과 `effective_keeper_surface`: 30초 `Dashboard_cache` 를 지난다.
- `skill_activations`: 캐시 밖에서 요청마다 계산한다(:2336-2343). `Keeper_skill_activation_projection.resolve` 가 그 Keeper 의 지금 trace 장부 전체를 돌려준다. 활성화, 거절, async 기록, `summary`, `scoped_summaries` 가 모두 들어 있다.

### 1.3 TUI 가 그리는 것

`bin/masc_tui_render_tools.ml` 의 pane 마다 읽기 하나에서 그린다.

| pane | 그리는 값 | 읽기 |
|---|---|---|
| Usage | skill 별 Keeper 사용량, coverage, 못 읽은 장부 | `/api/v1/skills` |
| Activations | 고른 Keeper 의 요약, 세션 id, 장부 revision, 전달·행동 timeline, 활성화별 receipt | `/api/v1/dashboard/tools` 의 `skill_activations` |
| Surface, Catalog | 도구 목록, Keeper 의 유효 surface | `/api/v1/dashboard/tools` |

`launch_tools_load`(`bin/masc_tui.ml:3933`)가 두 읽기를 같이 띄운다. Tools 화면에서는 2초 tick 마다 부른다(:40713).

### 1.4 같은 장부를 읽는 다른 곳

- 웹 대시보드: `dashboard/src/components/skills-panel.ts`(`usage_coverage`), `dashboard/src/components/tools/skill-activation-panel.ts`·`tools-main.ts`·`dashboard/src/api/dashboard-tools-prompts.ts`(`skill_activations`).
- harness: `scripts/harness/workload/capture_keeper_skill_tui_proof.py` 가 `/api/v1/dashboard/tools` 의 `skill_activations` 를 읽는다.
- Keeper 채팅 기록: `attach_keeper_chat_skill_activations`(`lib/server/server_dashboard_http_keeper_api.ml:603`)가 채팅 행마다 그 Keeper 의 장부를 붙인다.

## 2. 장부를 쓰는 곳

추가 기록은 모두 `commit_event_locked`(`lib/keeper/keeper_skill_activation_ledger.ml:2412`) 하나를 지난다. 이 함수는 세션 잠금 안에서 한 줄을 붙이고 프로세스 안의 장부 캐시를 고친다. 이 함수를 부르는 공개 함수는 이렇다.

| 함수 | 기록 | 부르는 곳 |
|---|---|---|
| `record` | `Activation_recorded` | `keeper_skill_activation_recorder.ml:279` |
| `record_original_invocation` | `Activation_recorded` | 같은 파일 :245 |
| `observe_delivery` | `Deliveries_observed`. 전이를 거절하면 `Transition_rejected`(ledger.ml:2618) | recorder :345 |
| `observe_action` | `Action_observed`. 전이를 거절하면 `Transition_rejected`(ledger.ml:2761) | recorder :369, :386 |
| `observe_async_result_delivery` | `Async_result_delivered` | `keeper_composition_result_delivery.ml:375` |
| `observe_async_action` | `Async_action_observed` | `keeper_skill_async_action_observer.ml:65` |

skill 을 한 번 부르면 `Activation_recorded` 1번, 결과가 다음 요청에 실린 턴 끝에 `Deliveries_observed` 1번, 다음 모델 응답의 skill 아닌 도구 호출마다 `Action_observed` 1번이 쓰인다. 그래서 대략 2+k 번이다. 새로 볼 것이 없는 관찰은 쓰지 않는다.

장부는 Keeper 를 모른다. 장부의 `t` 와 header 에는 `workspace_key` 와 trace(`session_id`)만 있다. 공개 함수도 `~config ~trace_id` 만 받는다. Keeper 에서 trace 로는 `meta.runtime.trace_id` 로 가지만, trace 에서 Keeper 로 가는 표는 없다.

trace 는 Keeper 를 만들 때 한 번 정해진다. trace id 를 만드는 곳은 `Keeper_input_birth.generate` 하나다. 그래서 Keeper 가 살아 있는 동안 장부 파일은 하나다. 같은 이름의 Keeper 를 지우고 다시 만들면 새 trace 와 새 장부가 생긴다.

2026-11-04 운영 workspace 에서 비어 있지 않은 장부는 34개였고, 모두 지금 Keeper 의 trace 였다. 가장 큰 장부는 948KB(1,875줄, ocaml-agent-ic)였고, 10개가 327KB 를 넘었다.

Keeper 이름은 registry 에 있다. 서버의 `Keeper_registry` 항목마다 그 Keeper 의 지금 trace 가 `meta.runtime.trace_id` 로 들어 있다. recorder 의 context 는 JSON 으로 저장됐다가 tool execution journal 과 composition draft 에서 복원되므로, 쓰는 쪽에 이름을 들려 보내면 그 복원 경로까지 이름을 받아야 한다.

## 3. 문제

1. 쓸 때마다 알리고 두 응답을 통째로 다시 읽으면, Keeper 하나의 기록 한 줄 때문에 모든 Keeper 의 장부와 최대 2MB 응답을 다시 읽는다. 바쁠 때는 2초 주기보다 더 자주 읽는다.
2. 사용량은 모든 Keeper 의 장부를 한 응답에 모은다. 그래서 어느 Keeper 가 바뀌었는지 알아도 그 Keeper 것만 다시 읽을 수가 없다.
3. 활성화 기록이 도구 목록 응답 안에 있다. 장부가 바뀌면 바뀌지 않은 도구 목록까지 다시 받는다. 거꾸로 도구 목록이 바뀌어도 장부 전체를 다시 계산한다.

## 4. 고른 길

### 4.1 서버: 읽기를 나눈다

- **Keeper 별 읽기** 둘을 새로 둔다. 둘 다 그 Keeper 의 지금 trace 장부 하나만 읽는다.
  - `GET /api/v1/keepers/skill-activations?keeper=<name>`: 지금 `skill_activations` 의 내용.
  - `GET /api/v1/keepers/skill-usage?keeper=<name>`: 그 Keeper 의 skill 별 사용량 행. 지금 `/api/v1/skills` 의 `usage[]` 에서 그 Keeper 몫이다. `usage.state` 는 `ready`(행), `no_session`(지금 세션 없음), `unavailable`(메타데이터나 장부를 못 읽음, `reason`·`detail`), `no_catalog`(준비된 catalog 없음) 중 하나다. 지금 `usage_coverage.unavailable` 에 모으던 이유가 여기로 옮겨 간다.
  - 둘을 나눈 이유: Usage pane 은 모든 Keeper 의 사용량을 읽는다. 한 응답에 장부까지 실으면 Keeper 수만큼 장부 전체를 받는다(가장 큰 것이 1,440KB, 1.2). 사용량 행만 받으면 Keeper 하나에 surface 수만큼의 짧은 행이다.
- `/api/v1/skills` 는 본문만 돌려준다. `usage[]` 와 `usage_coverage` 를 뺀다. 그러면 이 응답은 장부를 읽지 않는다.
- `/api/v1/dashboard/tools` 는 `skill_activations` 를 뺀다.

### 4.2 서버: Keeper 이름을 붙여 알린다

- 장부의 쓰기는 모두 쓰기 잠금(`with_write_lock`)을 지난다. `commit_event_locked` 는 그 잠금이 만든 writer 를 받아야 부를 수 있고, 기록하면 writer 에 표시한다. 그래서 새 기록 종류가 생겨도 표시에서 빠지지 않는다(RFC-0480 §3.4).
- 한 줄이라도 붙이려 했으면 쓰기 잠금은 세션 잠금을 푼 뒤 commit observer 를 한 번 부른다. 붙이기가 실패하거나 쓰기가 예외로 끝나도 부른다. 행이 디스크에 남았을 수 있고, 알림은 다시 읽으라는 뜻뿐이라 한 번 더 읽는 것밖에 잃지 않는다. 장부는 trace 만 넘긴다. 장부 함수의 시그니처와 저장 형식은 그대로다.
- 서버는 시작할 때 observer 를 설치한다. observer 는 바뀐 trace 를 기록하고 fiber 를 깨운다. fiber 는 registry 에서 그 trace 의 Keeper 를 찾아 `keeper_skill_activations_changed {name, trace_id}` 를 보낸다. 기다리는 동안 들어온 기록은 Keeper 마다 한 번으로 묶인다.
- registry 에 없는 trace(턴 도중에 지워진 Keeper)는 보여 줄 곳이 없어 알리지 않고, `keeper_sse_broadcast_failures` 에 `unnamed_trace` 로 센다.
- 알리는 fiber 는 쓰기 하나보다 오래 산다. 이름 찾기나 보내기가 실패하면 `broadcast` 로 세고 로그를 남긴 뒤 다음 변경으로 넘어간다. fiber 의 switch 가 끝나면 자기가 설치한 observer 를 거둔다. 그 뒤에 다른 observer 가 설치돼 있으면 그대로 둔다.
- 쓰지 않은 관찰(새로 볼 것이 없음)은 알리지 않는다.

### 4.3 TUI: pane 이 보이는 동안 그 pane 의 원천만 읽는다

| pane | 읽기 | 읽는 때 |
|---|---|---|
| Usage | `/api/v1/skills` 본문 | 본문 알림(skill catalog 발행 #48059 등). 본문 필드마다 원천은 L3 에서 확인한다 |
| Usage | `skill-usage`, 모든 Keeper | 화면을 열 때 한 번. 그 뒤로는 그 Keeper 의 `keeper_skill_activations_changed` 마다 그 Keeper 만 |
| Activations | 고른 Keeper 의 `skill-activations` | 고른 Keeper 가 바뀔 때, 그 Keeper 의 알림마다 |
| Surface, Catalog | `/api/v1/dashboard/tools` | skill catalog 발행, lane add-on export 변경(#48060), runtime config 변경(#48036) |

- Keeper 마다 `Masc_tui_owed_read` 하나를 둔다. 읽는 동안 온 알림은 다음 읽기 한 번으로 합쳐진다. 그래서 Keeper 하나당 진행 중인 읽기 하나와 밀린 읽기 하나를 넘지 않는다. 이건 횟수 제한이 아니라 읽기 빚 모델이 원래 하는 일이다.
- 바쁜 Keeper 가 계속 쓰면 그 Keeper 를 연달아 읽을 수 있다. 하지만 한 번 읽을 때 장부 하나만 읽고, 다른 Keeper 와 도구 목록은 읽지 않는다.
- Keeper 를 새로 만들거나 지우면 그 Keeper 의 활성화 읽기도 빚이 된다. 다시 만든 Keeper 는 새 trace 를 가지므로, 첫 기록 전에도 옛 장부를 보여 주지 않는다.
- observer 연결이 끊겼다가 다시 열리면, 지금처럼 보이는 pane 을 다시 읽는다(RFC-0480 §3.3).

### 4.4 고르지 않은 길

| 길 | 고르지 않은 이유 |
|---|---|
| Tools 2초 읽기 유지 | 바뀐 게 없어도 2초마다 모든 Keeper 장부와 최대 2MB 를 읽는다 |
| 쓸 때마다 알리고 두 응답을 통째로 다시 읽음 | 3장 문제 1 그대로다 |
| trace_id 만 알리고 TUI 가 trace 에서 Keeper 를 찾음 | TUI 에는 trace 에서 Keeper 로 가는 표가 없다. Keeper 가 새 trace 로 가면 TUI 는 처음 보는 trace 를 받는다. 서버는 registry 로 찾을 수 있어서 서버가 이름을 붙인다 |
| 장부 공개 함수에 `~keeper_name` 을 넘김 | recorder context 가 JSON 으로 저장됐다 복원되는 4곳까지 이름을 받아야 하고, 장부를 쓰는 시험 약 65곳과 `Recorder.make` 17곳이 바뀐다 |
| Keeper 이름을 장부 header 에 저장 | 알림에만 필요한 값인데 저장 형식이 바뀐다 |
| 턴이 끝날 때(`keeper_turn_complete`) 한 번 다시 읽음 | async 기록은 턴 뒤에 들어올 수 있다. 쓰는 곳 일부를 놓친다(RFC-0480 §3.4 조건 1) |

## 5. 층

| 층 | 내용 | 통과 조건 |
|---|---|---|
| L1 | 장부 쓰기 잠금과 commit observer. 서버가 registry 로 이름을 찾아 `keeper_skill_activations_changed` | 기록한 쓰기마다 observer 가 한 번 불리는지, 쓰지 않은 관찰은 부르지 않는지, trace 가 registry 의 Keeper 이름으로 바뀌는지 |
| L2 | Keeper 별 활성화 읽기 route | 한 Keeper 장부만 읽는지, 못 읽은 장부를 닫힌 상태로 돌려주는지 |
| L3a | Keeper 별 읽기를 `skill-activations` 와 `skill-usage` 로 나눈다 | 사용량 답에 장부가 실리지 않는지, 네 상태를 구분하는지, catalog skill 을 쓴 만큼 행이 나오는지 |
| L3b | TUI Activations pane 이 `skill-activations` 를 읽는다 | 다른 Keeper 의 답을 거절하는지, 읽기 실패를 pane 이 보여 주는지 |
| L3c | 웹 대시보드의 Tools 가 `skill-activations` 를, Skills 가 Keeper 마다 `skill-usage` 를 읽는다 | Tools 가 두 답이 같은 Keeper 인지 확인하는지, Skills 가 Keeper 별 행을 surface 에 붙이는지 |
| L3d | TUI Usage pane 이 Keeper 마다 `skill-usage` 를 읽고, 서버 `/api/v1/skills` 가 `usage[]`·`usage_coverage` 를 지운다 | `/api/v1/skills` 가 장부를 읽지 않는지, 이름이 lib/, bin/, dashboard/ 에 남지 않는지 |
| L3e | harness 스크립트가 `skill-activations` 를 읽고, 서버 `/api/v1/dashboard/tools` 가 `skill_activations` 를 지운다 | 이름이 lib/, bin/, dashboard/, scripts/ 에 남지 않는지 |
| L4 | TUI 가 4.3 표대로 읽고 Tools 화면의 `launch_tools_load` 2초 분기를 지운다 | 알림 하나에 그 Keeper 읽기 하나, 주기에는 읽지 않는지(PTY) |
| L5 | Keeper 채팅 기록이 그 Keeper 의 알림에 다시 읽는다 | 채팅을 연 Keeper 의 장부가 바뀌면 채팅 기록 읽기가 한 번 나가는지(PTY) |

서버 필드는 그 필드를 읽는 마지막 소비자와 같은 층에서 지운다. TUI 의 `/api/v1/skills` decoder 는 최상위 키를 닫혀 있게 읽어서, 필드를 먼저 지우면 TUI 가 읽지 못하고 나중에 지우면 TUI 가 모르는 키를 거절한다.

L4 는 L1~L3 과 #48059·#48060·#48036 뒤에만 들어간다. Tools 화면의 async task 와 async detail 읽기(`launch_tools_async_task`, `launch_tools_async_detail`)는 원천이 다르다. 이 RFC 에 들지 않는다.

## 6. 열린 질문

1. 활성화 읽기는 그 Keeper 장부 전체를 돌려준다. 장부는 Keeper 가 사는 동안 계속 자라고, 지금 가장 큰 것이 948KB 다(2장). 서버 응답으로는 1,440KB 다(1.2). 바쁜 Keeper 를 기록마다 다시 읽으면 매번 이 크기를 받는다. 장부 revision 은 장부 전체의 SHA-256 이라 순서가 없다. 그래서 "이 뒤의 기록만"을 받으려면 기록 순번 같은 순서 있는 값이 따로 필요하다. 활성화 하나에 나중 기록(전달, 행동)이 붙으므로, 돌려줄 단위가 줄인지 활성화인지도 정해야 한다.
2. `/api/v1/skills` 본문(config, sources, rejections, shadows, profile)이 skill catalog 발행 말고 다른 원천에서도 바뀌는지 L3 에서 필드마다 확인해야 한다.
