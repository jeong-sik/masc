---
rfc: "dated-stores-take-retention-from-one-list"
title: "날짜별 store 는 보존 규칙을 한 목록에서 받는다"
status: Implemented
created: 2026-10-13
updated: 2026-10-14
author: claude
supersedes: []
superseded_by: null
related: ["0103", "every-durable-store-has-one-boot-policy", "tool-librarian-action-absorption"]
---

# RFC: 날짜별 store 는 보존 규칙을 한 목록에서 받는다

- 상태: 구현됨. Native Stack #42853 으로 2026-10-13 에 main 에 들어갔다. 구현과 이 문서의 차이는 §11 에 적었다.
- 이슈: #42785. 운영자가 2026-10-13 에 "RFC 먼저"를 골랐다.
- 구현: Native Stack #42853(#42847 → #42848 → #42849 → #42850 → #42878 → #42880 → #42884).
- 근거: §2 의 크기와 날짜는 2026-10-13 라이브 base path 에서 파일 이름과 크기만 읽어 쟀다. tool events 는 하루치(2026-10-12)의 줄 수와 바이트만 셌다. §3 은 `origin/main` `0a7538661e` 의 코드다.
- 앞선 문서: RFC-0103(보존 기간을 기본으로 끈다), RFC "모든 영속 store 가 부팅 정책을 한 목록에서 받는다"(같은 틀을 부팅 정책에 썼다).
- 같이 볼 PR: #42625(병합). 운영자 창을 `runtime.toml` 의 `[maintenance].jsonl_retention_days` 에서도 읽게 한다.

## 0. 요약

masc 는 기록을 `<폴더>/YYYY-MM/DD.jsonl` 로 하루에 파일 하나씩 쌓는다. 이 글에서는 이런 폴더를 날짜별 store 라고 부른다. 서버는 시작할 때와 24시간마다 오래된 날짜 파일을 지운다. 이 일을 정리라고 부른다.

정리는 폴더 이름을 손으로 적은 목록을 따른다. store 를 새로 만드는 코드는 그 목록을 몰라도 컴파일된다. 그래서 새 store 는 목록에 없는 채로 생기고, 누가 크기를 재서 알아챌 때까지 쌓인다.

- 지금 목록에 없는 폴더가 6개다. 가장 큰 것이 2.9GB 다.
- 그중 하나(`continuity-requests`)는 2026-10-13 에 생겼고, 생긴 날부터 빠져 있다.
- 정리 코드의 주석에는 "뒤늦게 목록에 넣었다"는 기록이 10번 있다. 이름이 나온 store 가 15개다.

이름 6개를 목록에 더하면 같은 수정이 한 번 더 늘 뿐이다. 이 RFC 는 store 를 여는 문을 하나로 줄인다. store 는 닫힌 목록에 있어야 열 수 있고, 목록의 항목은 보존 규칙을 답해야 컴파일된다. 정리는 그 목록을 돈다.

보존 규칙은 쓰는 양을 줄이지 못한다. 2.9GB 짜리 store 가 왜 그렇게 큰지는 §2.2 에 적고, 어떻게 할지는 §9 Q1 로 남긴다.

날짜별 store 는 디스크의 일부일 뿐이다. #42625 본문이 잰 값으로 `.masc` 는 150GB 를 넘고 그중 날짜 파일은 21GB 쯤이다. 나머지(official-clients 80GB 등)는 이 RFC 가 다루지 않는다.

## 1. 결정

- D1. 날짜별 store 는 닫힌 타입에 모두 있다. 항목마다 폴더 자리와 보존 규칙을 exhaustive match 로 답한다.
- D2. store 는 그 타입의 값으로만 연다. 경로 문자열로 날짜 경로를 여는 문은 라이브러리 밖에서 부를 수 없다(§4.2).
- D3. 날짜로 지우는 일은 정리 한 곳이 목록 전체를 돌며 한다. handle 이 append 때 따로 지우던 `?retention_days` 는 없앤다. store 하나에 규칙이 하나만 남는다.
- D4. 보존 규칙은 네 가지다: 운영자 창, 정해진 날수, 그 store 의 환경 변수, 안 지움. 환경 변수를 따로 갖는 store 는 `wire-capture` 하나만 남긴다.
- D5. 지금 빠진 6개에 규칙을 준다(§4.5). 값은 운영자가 정한다(§9).
- D6. 목록에 있지만 지울 것이 없는 두 줄(`voice_sessions`, `resilience_audit`)을 지운다.

## 2. 무슨 일이 났나

### 2.1 정리가 닿지 않는 폴더 6개

| store | 자리 (`<base>/.masc/` 아래) | 파일 | 크기 | 가장 오래된 날 | 읽는 코드 |
|---|---|---|---|---|---|
| tool events | `tool-events` | 173 | 2.9GB | 2026-04-23 | 없다 |
| keeper wake payload | `keeper-wake-payload` | 49 | 55MB | 2026-08-26 | 대시보드. 최근 500줄 |
| verdicts | `verdicts` | 143 | 5.1MB | 2026-04-01 | 최근 500줄, 1,000줄, 5,000줄 |
| schedule signals | `schedules/signals` | 49 | 34MB | 2026-08-26 | 대시보드. 최근 줄만 |
| telemetry coverage gaps | `telemetry-coverage-gaps` | 14 | 112KB | 2026-08-23 | 최근 32줄, 50줄 |
| continuity requests | `keepers/<keeper>/continuity-requests` | 22 | 8MB | 2026-10-13 | 없다 |

같은 날 정리가 닿는 store 들(`tool_calls`, `agent-core-events`, `costs` 등)은 날짜 파일이 9개씩만 남아 있었다. 가장 오래된 날이 2026-10-05 다. 라이브에서는 기본 30일이 아니라 일주일쯤의 창이 듣고 있다. 그 값이 어디서 오는지는 확인하지 않았다.

위 셋은 #42789 가 `<base>/data/` 에서 `.masc` 아래로 옮겼다. 코드는 옛 자리를 읽지 않는다. 옛 자리의 파일은 운영자가 손으로 옮겨야 새 자리에 온다. 표의 크기는 옛 자리에서 쟀다.

라이브에서는 2026-10-13 20:49 에 새 빌드가 떴다. 21:10 에 운영자 답을 받아 지난 달 폴더와 전날까지의 날짜 파일을 새 자리로 옮겼다. 파일 수는 옮기기 전후가 같다(174, 50, 144). 옛 자리에는 그날 날짜 파일이 store 마다 하나씩 남아 있다. 새 서버가 같은 이름의 파일을 쓰고 있어서, 서버를 멈출 때 합친다.

schedule signals 는 배포 preflight 도 읽는다. 남아 있는 줄을 모두 읽어 형식을 검사한다. 옛 줄이 있어야 하는 읽기는 아니다.

`continuity-requests` 는 #42602 가 2026-10-13 에 만들었다. PR 본문은 이것을 진단용 store 라고 적고 "No new retention policy" 라고 밝혔다. 그날 20:25 KST 에 쟀을 때 Keeper 22명이 8MB 를 써 둔 상태였다.

### 2.2 tool events 는 왜 큰가

2026-10-12 하루 파일(21MB)을 줄 종류별로 셌다.

| 줄 종류 | 줄 수 | 바이트 비중 | 한 줄 평균 |
|---|---|---|---|
| `Assigned` | 16,005 | 99.6% | 1,374B |
| `Called` | 213 | 0.2% | 252B |
| `Completed` | 213 | 0.2% | 202B |

- `Assigned` 줄은 그때 agent 에게 보인 도구 이름 목록 전체를 담는다.
- 그날 `Assigned` 를 받은 agent 는 28명이고 서로 다른 `config_hash` 는 181개였다. 한 agent 의 `config_hash` 가 바로 앞 줄과 달라진 줄은 276줄이다. 나머지 15,729줄은 앞 줄과 같은 목록을 다시 쓴 것이다.
- 이 store 를 읽는 코드가 `lib` 와 `bin` 에 없다. `read_recent` 와 `warm_up` 을 부르는 곳은 테스트뿐이다. 초안 RFC `tool-librarian-action-absorption` 이 `Assigned` 줄을 읽을 계획이지만 구현 PR 은 없다.
- 최근 30일치는 586MB 다. 전체 2.9GB 의 20% 다.

보존 규칙을 30일로 줘도 586MB 가 남고 하루 21MB 씩 계속 쓴다. RFC-0103 이 2026-05 에 한 말과 같다: 지우기는 쓰는 양을 줄이지 않는다.

### 2.3 같은 수정이 되풀이됐다

`lib/server/server_runtime_startup_maintenance.ml` 의 주석이 적어 둔 것이다.

| store | 주석이 적은 일 |
|---|---|
| metrics, crash-events | 24시간 정리가 execution-receipts 만 지워서 재시작 때까지 쌓였다 |
| turn-records | 2026-07-31 에 생겼고 몇 달 동안 목록에 없었다. 하루 약 4MB |
| tool_calls, transition-audit, resilience_audit | 시작 때 목록과 24시간 목록이 서로 달랐다 |
| agent-core-events | 2026-07-31 에 넣었다. 434MB 가 쌓여 있었다 |
| costs, audit-approvals | 2026-08-05 에 넣었다. 74MB, 22MB |
| raw-traces, runtime-manifests | 생긴 뒤로 보존 규칙이 없었다 |
| reaction-ledger | 폴더가 한 겹 더 깊어서 정리가 닿지 않았다 |
| decision_audit | 23MB 가 쌓여 있었다 |
| logs | 406MB 가 쌓여 있었다 |
| messages | 목록에 있었지만 모양이 달라서 하나도 지워지지 않았다. 파일 2,587개 |

Keeper 별 store 를 닫힌 타입(`Common.keeper_runtime_store`)에서 뽑게 고친 자리에는 이런 주석이 있다: "a new store cannot reach disk without someone saying which pass owns it". `continuity-requests` 는 그 타입에 생성자를 더하지 않고 `"continuity-requests"` 문자열로 열렸다. 타입이 있어도, 타입을 거치지 않고 여는 문이 열려 있으면 막지 못한다.

### 2.4 한 폴더에 규칙이 둘이다

- `tool_usage`: 세 곳이 서로 다르게 말한다. `.ml` 주석은 "unset keeps everything" 이고 자기 환경 변수의 기본값이 "안 지움"이다. `.mli` 는 "default is 30 days" 라고 적는다. 실제로는 같은 폴더가 정리 목록에 있어서, 자기 변수를 안 주면 운영자 창(기본 30일)에 지워진다. 자기 변수는 창보다 짧게 줄 때만 듣는다.
- `telemetry`, `tool_calls`, `agent-core-events`: 자기 환경 변수(기본 30일)가 있고 정리 목록에도 있다. 자기 값을 90일로 올려도 정리가 30일에 지운다. 자기 값은 줄일 때만 듣는다. 자기 값 0 은 "끔"이라고 적혀 있지만 정리가 지운다.
- RFC-0103(2026-05-17)은 `tool_calls`, `tool_usage`, `agent-core-events` 의 보존 기간을 기본으로 끄기로 했다. 지금 코드에서 그 결정이 남은 곳은 `tool_usage` 의 기본값 하나이고, 위에 적은 대로 그것도 듣지 않는다.

### 2.5 목록에 있지만 지울 것이 없는 줄

- `voice_sessions`: 실제 파일은 `<agent_id>.json` 하나를 덮어쓰는 모양이다. 달 폴더가 없어서 날짜 정리는 늘 0개를 지운다. 라이브 폴더에는 파일이 없다.
- `resilience_audit`: `lib` 와 `bin` 에 이 폴더에 쓰는 코드가 없다. 라이브에 폴더가 없다. 이 모양으로 쓰는 모듈(`Shared_audit`)은 테스트만 부른다.

## 3. 지금 구조

**여는 쪽.** `Dated_jsonl.create ~base_dir ?retention_days ?max_bytes ()` 가 handle 을 만든다. `base_dir` 는 아무 문자열이나 된다. `lib` 에서 43곳이 부른다. 그중 14곳은 읽기만 하는 handle 이다. 테스트에서는 22개 파일 123곳이 부른다(11곳은 `module D = Dated_jsonl` 별칭으로 부른다).

문자열로 날짜 경로를 만드는 문이 셋 더 있다.

- `Jsonl_writer.dated_path*`: `lib` 의 8개 파일이 부른다. `events`, `activity-events`, `audit-approvals`, `memory-recall-artifacts` 가 이 길로 쓴다.
- `Jsonl_writer.append_dated_jsonl ~base_dir`: `lib` 와 `bin` 에서 부르는 곳이 없다. 테스트만 부른다.
- `Shared_audit.Store.create ~base_dir`: 위와 같다.

**지우는 쪽은 길이 셋이다.**

1. handle 이 append 할 때. `?retention_days` 가 양수면 handle 마다 하루에 한 번 지운다. `?max_bytes` 가 양수면 append 마다 오래된 날부터 지우고 오늘 파일은 남긴다. 43곳 중 8곳이 이 인자를 넘긴다.
2. 정리. `Server_runtime_startup_maintenance.prune_shared_jsonl_stores` 가 서버 시작 때와 24시간마다 돈다. 날수는 `MASC_JSONL_RETENTION_DAYS` 이고 기본 30, 0 이하면 아무것도 지우지 않는다. 이 글은 이 날수를 운영자 창이라고 부른다. 대상은 세 묶음이다.
   - 이름 목록 `top_level_dated_stores` 11개.
   - Keeper 별 store. `Common.keeper_runtime_store` 의 placement 에서 뽑는다.
   - 손으로 적은 줄들: `logs`, `trajectories`, `keeper_chat_events`, `keeper_turn_events`, `messages`, `resilience_audit`, `decision_audit`.
3. `wire-capture` 만 서버 시작 때 자기 날수로 한 번 지운다.

**같은 틀이 이미 있다.** `Keeper_durable_store.Id` 는 store 21개를 닫힌 타입으로 두고 `[@@deriving enumerate]` 로 `all` 을 만든다. 부팅과 배포 preflight 가 그 목록을 읽는다. 다만 그 목록은 "부팅 때 읽히는가"만 답한다.

## 4. 설계

### 4.1 목록 (D1)

`lib/dated_jsonl` 안에 둔다. 이 라이브러리는 `Common` 과 `lib/config` 를 이미 볼 수 있다. `wire-capture` 의 환경 변수를 읽는 함수도 `lib/config` 에 있다. dune 에 `ppx_enumerate` 만 더하면 된다.

```ocaml
module Store : sig
  (** masc root 아래에 하나씩 있는 store. *)
  module Workspace : sig
    type t =
      | Audit | Telemetry | Events | Activity_events | Tool_calls | Tool_usage
      | Transition_audit | Agent_core_events | Costs | Audit_approvals
      | Provider_usage_history | Wire_capture
      | Tool_events | Keeper_wake_payload | Verdicts
      | Schedule_signals | Telemetry_coverage_gaps
    val all : t list
  end

  (** keepers/<keeper>/ 아래에 하나씩 있는 store. *)
  module Per_keeper : sig
    type t =
      | Metrics | Execution_receipts | Turn_records | Provider_inputs
      | Memory_recall_artifacts | Crash_events | Continuity_requests
    val all : t list
  end

  type t =
    | Workspace of Workspace.t
    | Per_keeper of Per_keeper.t
    | Reaction_ledger   (* keepers/<keeper>/reaction-ledger/<세대>/ *)
    | Decision_audit    (* decision_audit/<keeper 폴더 이름>/ *)
  val all : t list   (* [@@deriving enumerate] *)

  type root =
    | Base_root      (* <base>/.masc *)
    | Cluster_root   (* 클러스터별 root. 기본 클러스터에서는 위와 같다 *)

  val root : t -> root   (* exhaustive *)

  type retention =
    | Operator_window            (* 운영자 창 *)
    | Fixed_days of int          (* 읽는 쪽 창이 정한 날수 *)
    | Own_days of (unit -> int)  (* 그 store 의 환경 변수. wire-capture 뿐 *)
    | Kept                       (* 날짜로 지우지 않는다 *)

  val retention : t -> retention   (* exhaustive *)

  type roots      (* 두 root 를 함께 든다 *)
  val roots : base_root:string -> cluster_root:string -> roots

  type location   (* 폴더 하나. 이 모듈만 만든다 *)
  val workspace : roots -> Workspace.t -> location
  val per_keeper : roots -> keeper:string -> Per_keeper.t -> location
  val reaction_ledger : roots -> keeper:string -> generation:string -> location
  val decision_audit : roots -> keeper_dirname:string -> location

  val prune : roots -> now:float -> int
end
```

- 생성자를 더하면 root, 폴더 자리, 보존 규칙을 채울 때까지 컴파일되지 않는다.
- 항목은 어느 root 아래인지도 답한다. 지금은 호출자가 root 문자열을 넘긴다. 그래서 쓰는 root 와 정리가 보는 root 가 달라도 컴파일된다. 날짜별 store 가운데 적어도 7개가 그렇다(transition-audit, audit-approvals, tool-events, keeper-wake-payload, verdicts, reaction-ledger, decision_audit). 이들은 `<base>/.masc` 에 쓰는데 정리는 클러스터별 root 를 본다. `location` 을 만드는 함수가 두 root 를 든 값을 받고 항목이 답한 쪽을 쓰면 이 어긋남이 생기지 않는다. 기본 클러스터에서는 두 root 가 같아서 동작이 바뀌지 않는다. 라이브에는 `clusters` 폴더가 없다.
- `all` 은 derive 라서 손으로 적는 목록이 없다. 지금 `Common.keeper_runtime_stores` 는 손으로 적는 목록이라, 생성자를 더하고 목록에서 빠뜨려도 컴파일된다.
- 폴더 이름은 목록이 가진다. 위쪽 모듈이 따로 들고 있던 이름(`Audit_log.store_dirname` 등)은 목록의 것을 가리키게 한다.
- `Common.keeper_runtime_store` 에도 있는 7개(`Per_keeper` 의 앞 6개와 reaction-ledger)의 폴더 이름은 `Common` 의 함수를 불러서 얻는다. 이름을 두 번 적지 않는다.
- `Reaction_ledger` 와 `Decision_audit` 는 폴더 자리가 달라서 여는 함수가 따로 있다.
  - reaction-ledger 는 세대 폴더(지금 `v7`) 아래에 쓴다. 정리는 지금처럼 모든 세대 폴더를 돈다. 옛 세대의 파일도 정리된다.
  - decision_audit 는 호출자가 keeper 이름을 폴더 이름으로 바꿔서 넘긴다.
  - 세대 이름과 이름을 바꾸는 함수는 `lib/keeper` 에 있어서 이 라이브러리에서 보이지 않는다. 그래서 인자로 받는다.

### 4.2 여는 문 (D2)

```ocaml
val create : Store.location -> ?mutex:Eio.Mutex.t -> ?max_bytes:int -> unit -> t
val dated_path_now : Store.location -> Jsonl_writer.dated_path
```

- `location` 은 `Store` 의 네 함수만 만든다. 목록에 없는 폴더는 열 수 없다.
- `Jsonl_writer` 는 별도 라이브러리다. `dated_path*` 와 `append_dated_jsonl` 을 `lib/dated_jsonl` 안으로 옮기고 `location` 을 받게 한다. 옮기지 않으면 밖에서 문자열로 계속 부를 수 있다.
- 날짜 경로를 직접 만들어 쓰는 파일들도 `location` 에서 경로를 받는다. 쓰는 방식은 바꾸지 않는다.
- `Shared_audit.Store.create ~base_dir` 는 테스트만 부른다. 지울지는 §9 Q8 이다.
- 테스트는 임시 root 아래에 목록의 store 를 연다. 임의 폴더를 여는 테스트용 문은 두지 않는다.
- 읽기만 하는 handle 도 같은 `location` 으로 연다. 보존 규칙이 handle 이 아니라 항목에 있으므로, 읽는 쪽과 쓰는 쪽이 다른 값을 적을 자리가 없다.

### 4.3 정리 (D3)

- 서버 시작과 24시간 정리가 `Store.prune` 을 부른다. `prune` 은 `Store.all` 을 돈다. Keeper 폴더는 지금처럼 디스크에서 찾는다(`keepers/*`, `decision_audit/*`). 그래서 없어진 Keeper 의 폴더도 정리된다.
- `top_level_dated_stores`, placement 로 뽑던 두 목록, `decision_audit` 줄, `wire-capture` 의 시작 정리를 지운다.
- `Dated_jsonl.create` 에서 `?retention_days` 를 지운다. append 마다 handle 을 새로 만드는 곳이 5곳 있는데, 거기에 이 인자를 넘기면 append 마다 정리가 돈다. 하루에 한 번이라는 표시가 handle 안에 있기 때문이다. 정리를 한 곳으로 모으면 이 문제가 생기지 않는다.
- 용량 한도(`?max_bytes`)는 `create` 의 인자로 그대로 둔다. append 하는 handle 만 쓰는 값이라 읽는 handle 과 어긋나지 않는다. 용량 정리 테스트도 지금처럼 작은 값을 넘긴다.
- `Keeper_observability_artifact_registry.retention_owner` 가 정리의 주인을 글자로 적는다. 날짜별 store 넷은 `Dated_jsonl_operator_window`(`"Dated_jsonl.Store"`), runtime manifest 는 `Startup_flat_file_mtime`(`"Server_runtime_startup_maintenance"`)이다. 정리의 자리가 바뀌면 이 함수의 글자도 같이 고친다.
- 날짜별이 아닌 폴더(`logs`, `trajectories`, `keeper_chat_events`, `keeper_turn_events`, `messages`, `raw-traces`, `runtime-manifests`)는 지금 줄 그대로 둔다(§6).

### 4.4 지금 있는 store 의 규칙 (D4)

지금 듣는 규칙을 가장 가깝게 옮긴다. 달라지는 곳은 오른쪽 칸에 적었다.

| store | 지금 듣는 규칙 | 옮긴 뒤 | 달라지는 것 |
|---|---|---|---|
| audit, events, activity-events, transition-audit, costs, audit-approvals | 운영자 창 | `Operator_window` | 없다 |
| Keeper 별 8개 (metrics, execution-receipts, turn-records, provider-inputs, memory-recall-artifacts, crash-events, reaction-ledger, decision_audit) | 운영자 창 | `Operator_window` | 없다 |
| telemetry, tool_calls, agent-core-events | 자기 변수(기본 30일)와 운영자 창 중 짧은 쪽 | `Operator_window`. 자기 변수 셋은 지운다 | 자기 변수로 창보다 짧게 줄여 둔 장비에서는 창까지 늘어난다 |
| tool_usage | 자기 변수(기본 "안 지움")와 운영자 창 중 짧은 쪽 | `Operator_window`. 자기 변수는 지운다 | 위와 같다 |
| provider_usage_history | handle 의 16일 | `Fixed_days 16` | 지우는 때가 append 에서 정리로 바뀐다 |
| wire-capture | 자기 변수(기본 3일, 1~30일) | `Own_days` | 위와 같다 |

`Operator_window` 는 지금처럼 0 이하면 아무것도 지우지 않는다.

`provider_usage_history` 에 쓰는 프로세스는 서버뿐이다. 쓰는 observer 를 서버 bootstrap 만 건다. 그래서 지우는 때가 정리로 옮겨 가도 16일이 지켜진다.

자기 변수 넷을 지우는 까닭은 셋이다.

- 지금도 늘리는 쪽으로는 듣지 않는다. 창보다 긴 값과 0 은 정리가 덮는다(§2.4).
- 운영자가 창을 7일로 줄이면(#42625) 이 store 들도 7일을 따라야 한다. 자기 변수를 규칙으로 삼으면 `tool_calls`(라이브 9일치 1.8GB)와 `agent-core-events`(771MB)가 자기 기본값 30일에 남는다.
- 헌법의 `env_var_sprawl` 항목이 묻는 그대로다: TOML 로 값을 쓰는데 환경 변수를 따로 둘 까닭이 있는가.

`wire-capture` 는 남긴다. 기본 3일이 창보다 짧다. 2026-10-13 에 쟀을 때 그날 반나절 치가 239MB 였으니, 창을 따르게 하면 디스크가 늘어난다.

자기 변수를 남기는 쪽은 §9 Q7 에 적었다.

### 4.5 빠진 6개 (D5)

| store | 권고 | 까닭 |
|---|---|---|
| tool events | `Operator_window` | 읽는 코드가 없다. 30일이면 586MB, 7일이면 129MB 가 남는다. 쓰는 양은 Q1 |
| keeper wake payload | `Operator_window` | 대시보드가 최근 500줄만 읽는다 |
| verdicts | `Kept` | 6개월 반 동안 5.1MB 다. 통계가 최근 5,000줄을 읽는데, 지금 속도(하루 약 29줄)로 173일치다. 30일로 자르면 870줄쯤 남는다. 사람이 붙인 label 은 다시 만들 수 없다 |
| schedule signals | `Operator_window` | 대시보드가 최근 줄만 읽는다. 같은 신호를 두 번 쏘지 않게 막는 일은 다른 파일(`schedules/signal_keys.json`)이 맡는다. 이 store 를 지워도 다시 쏘지 않는다 |
| telemetry coverage gaps | `Operator_window` | 최근 50줄까지만 읽는다 |
| continuity requests | `Operator_window` | 생긴 날에 8MB 가 쌓였다. 사람이 진단할 때 읽는 store 이고 읽는 코드는 없다(Q5) |

### 4.6 지우는 줄 (D6)

`voice_sessions` 는 날짜별 store 가 아니므로 목록에 넣지 않는다. `resilience_audit` 는 쓰는 코드가 없으므로 넣지 않는다. 두 줄은 손으로 적은 목록과 함께 사라진다.

## 5. 다른 방법과 버린 까닭

| 방법 | 좋은 점 | 버린 까닭 |
|---|---|---|
| 이름 6개를 목록에 더한다 | 열 줄쯤 고치면 끝난다 | §2.3 의 수정을 한 번 더 하는 것이다. 다음 store 를 막지 못한다. `continuity-requests` 가 그 예다 |
| `create` 에 `~retention` 을 꼭 넘기게 한다 | 새 store 가 컴파일 때 걸린다 | 읽기만 하는 handle 14곳도 규칙을 적어야 하고, 같은 폴더의 두 handle 이 다른 값을 적을 수 있다. 쓰는 프로세스가 돌지 않으면 지워지지 않는다(없어진 Keeper 의 폴더). 정리 목록이 그대로 남아 §2.4 가 남는다 |
| `.masc` 를 훑어 `YYYY-MM/DD.jsonl` 모양이면 지운다 | 새 store 가 저절로 걸린다 | 모르는 폴더를 모양만 보고 지운다. `verdicts` 처럼 남길 것이 30일 뒤 말없이 사라진다. 빠뜨렸을 때 잃는 것이 디스크에서 기록으로 바뀐다 |

고른 방법에 드는 품: `lib` 의 `create` 43곳과 날짜 경로를 직접 만드는 8개 파일, 테스트 123곳을 고친다. 테스트는 임의 폴더 대신 목록의 store 를 임시 root 아래에 열어야 해서, 경로가 한 겹 깊어진다.

## 6. 하지 않는 것

- 쓰는 양 줄이기. tool events 의 `Assigned` 줄을 어떻게 할지는 Q1 의 답을 받고 따로 한다.
- 날짜별이 아닌 폴더의 문 닫기. `Fs_compat.append_*` 로 쓰는 곳이 40여 개 파일에 50곳쯤 있는데, 어디에 쓰는지와 지워지는지를 조사하지 않았다. 따로 이슈를 낸다.
- `logs` 는 시작 때 파일 이름으로 7일, 정리 때 수정 시각으로 운영자 창, 이렇게 규칙이 둘이다. 날짜별 store 가 아니라서 이 RFC 는 건드리지 않는다.
- 용량 한도의 값과 동작.
- `Keeper_durable_store` 와 합치기. 두 목록에 같이 나오는 store 는 둘(`Provider_inputs`, `Turn_records`)이고 나머지는 한쪽 질문에만 해당한다. 합치면 대부분의 항목이 "해당 없음"을 답해야 한다.
- `Common.keeper_runtime_store` 나누기. 그 타입에는 날짜별이 아닌 store 가 셋 있어서 그대로 쓰면 날짜별이 아닌 것을 날짜별로 여는 코드가 컴파일된다. 그래서 날짜별 것만 담은 타입을 따로 둔다. 같은 store 를 가리키는 줄이 두 타입에 7개 생긴다. 이것을 없애려면 그 타입을 읽는 Python manifest 까지 바꿔야 한다.
- 옛 자리나 지운 환경 변수를 서버가 시작 때 살피는 코드. 넣으면 코드가 그 이름을 다시 갖게 된다. 헌법의 `legacy_residue` 항목대로, 옮기는 일과 지운 변수는 changelog 의 Upgrade notes 와 §10 의 선행 조건이 맡는다.

## 7. 검증

- 빌드가 증명하는 것. 생성자를 더하고 규칙을 안 채우면 컴파일되지 않는다. 경로 문자열로 `create` 를 부르면 타입이 맞지 않는다.
- 테스트. 임시 root 아래에 `Store.all` 의 모든 항목을 연다. 항목마다 창보다 오래된 날짜 파일 하나와 오늘 파일 하나를 쓰고 `Store.prune` 을 한 번 부른다.
  - `Operator_window`, `Own_days`, `Fixed_days` 항목은 오래된 파일만 사라진다.
  - `Kept` 항목은 둘 다 남는다.
  - 운영자 창이 0 이면 `Operator_window` 항목에서 아무것도 사라지지 않는다.
  - 등록되지 않은 Keeper 폴더도 정리된다.
  - reaction-ledger 의 옛 세대 폴더도 정리된다.
- 변형. 항목 하나의 규칙을 `Kept` 로 바꾸면 위 테스트가 실패해야 한다. `Fixed_days 16` 을 17 로 바꾸면 16일 된 파일을 둔 케이스가 실패해야 한다.
- 라이브. 배포 뒤 첫 시작 로그의 `startup prune: pruned N` 줄과, §2.1 여섯 폴더의 가장 오래된 날짜를 다시 잰다. 옛 자리 세 폴더(`<base>/data/tool-events`, `keeper-wake-payload`, `verdicts`)도 같이 잰다. 거기에는 파일이 없어야 한다.

## 8. 확신도

- 높다: §2.1 의 크기와 날짜, §2.2 의 하루치 숫자, verdicts 가 읽는 줄 수, schedule 의 중복 방지 파일, §2.4, §2.3 의 주석 내용, §2.5. §2.3~§6 의 코드 사실은 이 문서를 쓰지 않은 리뷰 에이전트가 따로 대조했고, 거기서 틀린 곳 셋(`tool_usage` 변수가 듣는 조건, handle 을 새로 만드는 곳 수, 테스트 호출 수)을 고쳤다.
- 중간: `create` 43곳의 분류는 조사 에이전트가 읽은 표다. `masc_root` 를 인자로 받는 12곳이 실제로 어느 root 를 받는지는 끝까지 따라가지 않았다. 항목마다 `root` 를 답하려면 구현 전에 이 12곳을 따라가야 한다. `Assigned` 줄이 언제 쓰이는지(턴마다, `tools/list` 마다)는 호출 자리만 보았다.
- 모른다: 테스트 123곳을 옮기는 데 드는 품. 날짜 경로를 직접 만드는 파일들이 `Dated_jsonl` 을 거치지 않는 까닭. 빌드와 테스트는 아무것도 돌리지 않았다. 이 문서는 설계뿐이다.

## 9. 운영자가 정한 것

2026-10-13 에 운영자가 답했다.

- Q1. tool events 는 지금처럼 쓰고 운영자 창으로 지운다.
- Q2. verdicts 는 `Kept` 다.
- Q3. 운영자 창의 기본값은 30일 그대로 둔다. 장비마다 `runtime.toml` 로 줄인다.
- Q4. `tool_usage` 는 운영자 창을 따른다(Q7 의 결과).
- Q5. `continuity-requests` 는 운영자 창을 따른다.
- Q6. 기본이 아닌 클러스터는 쓰지 않는다. root 를 하나로 줄이는 일은 이 RFC 밖에서 한다(#42837).
- Q7. telemetry, tool_calls, agent-core-events, tool_usage 의 자기 변수 넷을 지운다.
- Q8. `Shared_audit` 모듈을 지운다.

## 10. 구현 순서

Native Stack 하나로 올린다.

1. `Store` 목록과 `location` 을 더한다. `location` 을 받는 `create` 를 옛 `create` 옆에 둔다. 규칙은 §4.4 대로 적는다. 빠진 6개는 `Kept` 로 시작한다. #42625 가 먼저 병합되면 운영자 창은 그 PR 의 함수로 읽는다.
2. `lib` 의 `create` 43곳과 날짜 경로를 직접 만드는 8개 파일, 테스트 123곳을 영역별로 나눠 옮긴다.
3. 옛 `create` 와 `?retention_days` 를 지운다. `Jsonl_writer.dated_path*` 와 `append_dated_jsonl` 을 `lib/dated_jsonl` 안으로 옮긴다. 스택은 통째로 병합하므로 main 에는 문이 하나만 남는다.
4. 정리가 `Store.prune` 을 부르게 하고 §4.3 의 목록들과 자기 변수 넷을 지운다. 여기서 §4.4 의 "달라지는 것"이 생긴다. 지운 변수 넷과 달라지는 것을 changelog 의 Upgrade notes 에 적는다.
5. 빠진 6개의 규칙을 운영자가 정한 값으로 바꾼다. 첫 시작 때 지워지는 양을 PR 본문에 적는다.
   - 선행 조건: 옛 자리 세 폴더에 파일이 없다. `find <base>/data/tool-events <base>/data/keeper-wake-payload <base>/data/verdicts -type f` 가 아무것도 내지 않는 것을 PR 본문에 적는다.
   - 이 조건이 빠지면 옛 자리의 파일은 어느 정리도 맡지 않는다. `Kept` 로 두려는 verdicts 는 읽히지 않는 자리에 남는다.

Q1 의 답이 (나)나 (다)면 그 일은 이 스택과 따로 한다.

## 11. 구현 결과

Native Stack #42853 의 일곱 층이 2026-10-13 에 한 번에 main 에 들어갔다.

| PR | 한 일 | §10 의 단계 |
|---|---|---|
| #42847 | `Dated_jsonl.Store` 목록과 `location` 을 더했다 | 1 |
| #42848, #42849, #42850 | base root, 클러스터 root, Keeper 별 호출처를 목록으로 옮겼다 | 2 |
| #42878 | 정리가 목록의 규칙대로 지운다. `?retention_days` 와 자기 변수 넷, §4.3 의 손으로 적은 목록을 지웠다 | 4, 3 의 일부 |
| #42880 | 빠진 6개 중 다섯을 `Operator_window` 로, verdicts 를 `Kept` 로 두었다 | 5 |
| #42884 | `open_store` 만 남기고 옛 `create` 를 지웠다. `Jsonl_writer.dated_path*` 를 `Dated_jsonl.Store` 로 옮겼다. `Shared_audit` 를 지웠다(Q8) | 3 |

이 문서와 다른 곳은 셋이다.

- 순서. §10 은 3단계(옛 문 지우기)를 정리보다 먼저 두었다. 실제로는 `?retention_days` 만 정리 층(#42878)에서 지우고, 옛 `create` 와 `dated_path*` 는 맨 위 층(#42884)에서 지웠다. 스택이 한 번에 들어갔으므로 main 에서 보이는 결과는 같다.
- `wire-capture` 는 서버가 뜰 때 한 번 지우던 코드를 지웠다. 이제 다른 store 와 함께 정리가 서버가 뜰 때와 24시간마다 자기 날수(`Own_days`)로 지운다.
- 5단계의 선행 조건은 채우지 못했다. 병합 때 옛 자리 `<base>/data/{tool-events,keeper-wake-payload,verdicts}/2026-10/13.jsonl` 세 파일이 남아 있었다. 서버가 그 이름으로 새 자리에 쓰고 있어서, 서버를 멈춘 사이에 옛 파일을 새 파일 앞에 붙이고 지운다. 이 일은 #42880 이 든 빌드를 띄우기 전에 한다.

이 RFC 밖에 남은 일:

- #42891: 정리가 폴더 하나의 `Sys_error` 로 그날 정리를 멈춘다. 지우지 못한 파일도 지운 수에 센다. 둘 다 이 스택 전부터 있던 모양이다.
- #42837: root 를 하나로 줄인다(Q6).
