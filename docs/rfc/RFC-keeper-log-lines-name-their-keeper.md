---
rfc: "keeper-log-lines-name-their-keeper"
title: "Keeper 로그 줄은 누구의 일인지 타입으로 고른다"
status: Draft
created: 2026-11-27
updated: 2026-11-27
author: claude
supersedes: []
superseded_by: null
related: []
---

# RFC keeper-log-lines-name-their-keeper: Keeper 로그 줄은 누구의 일인지 타입으로 고른다

- 이슈: #38416
- 코드 좌표는 `origin/main` `a8a00684072d1` 에서 읽었다.
- 운영자 결정(2026-11-27): 코드보다 이 RFC 를 먼저 쓴다.
- 이 문서는 설계만 담는다. 코드는 §4 의 층에서 쓴다.

## 0. 요약

`Log.Keeper.*` 는 Keeper 이름을 선택 인자로 받는다.
빠뜨리면 그 줄의 `keeper_name` 은 조용히 `"system"` 이 된다.
7일 동안 `module=Keeper` 줄의 48.4% 가 `"system"` 이었다.
그중 91.7% 는 본문에 Keeper 이름을 적고 있었다.

결정은 넷이다.

1. `Log.Keeper` 는 줄마다 `keeper_scope` 를 필수 인자로 받는다. 값은 `Of_keeper of string` 과 `Of_server` 둘뿐이다(§2).
2. 어느 Keeper 의 일도 아닌 줄은 `Of_server` 를 고른다. wire 에는 `"keeper_name": null` 로 적고, `"system"` 표지는 지운다(§3).
3. 호출 1,508곳은 native stack 하나로 바꾼다. 타입 층, 파일 묶음 층, 임시 생성자를 지우는 층 순서다(§4).
4. 새로 쓰는 호출은 타입이 막는다. lint 와 새 PR 검사는 만들지 않는다(§5).

## 1. 지금

### 1.1 코드

- `Log.Keeper` 는 다른 logger 와 같은 `LOGGER` 다(`lib/masc_log/log.mli:342`, `log.ml:1436`).
- `debug`·`info`·`warn`·`error` 는 `?keeper_name:string` 을 받는다(`log.mli:317-320`). `emit`·`routine` 도 같다.
- 이름이 없으면 ring 에 `None` 이 들어간다.
- wire 인코더 둘이 `None` 을 `"system"` 으로 적는다(`log.ml:487-489`, `:1164-1167`).
- 인코더 주석이 스스로 말한다. `"system"` 은 올바른 Keeper 이름이기도 하다(`log.ml:483-486`). wire 로는 둘을 가를 수 없다.
- `"system"` 을 쓰는 까닭은 대시보드 schema 가 빈칸 없는 문자열을 요구해서다(`dashboard/src/api/schemas/logs.ts:41`).
- 예: 턴 성공 줄은 이름을 본문에만 적는다(`lib/keeper/keeper_unified_turn_success.ml:336-345`).
- 예: 도구 오류 줄은 이름을 빠뜨린다(`lib/keeper/keeper_tools_agent_core_handler_exec.ml:299-301`). 네 줄 아래 호출은 같은 `meta.name` 을 넘긴다(`:305`).

### 1.2 호출 자리

`rg` 와 정규식으로 셌다. 여러 줄에 걸친 호출이 있어 어림이다.
정확한 목록은 §4 의 1층에서 컴파일러가 만든다.

| 셈 | 수 |
|---|---|
| `.ml` 의 `Log.Keeper.*` 호출 | 1,508 (`lib` 1,504, `test` 4), 315개 파일 |
| `~keeper_name` 을 넘기는 호출 | 580 |
| 넘기지 않는 호출 | 928, 226개 파일 |
| 그중 형식 문자열이 `"%s: "` 로 시작 | 96, 25개 파일 |

- 넘기지 않는 호출은 `lib/keeper` 733, `lib/server` 142, 나머지 53 이다.
- 전체 호출을 함수별로 보면 `warn` 807, `info` 318, `error` 283, `debug` 52, `emit` 41, `routine` 11 이다. `emit_lazy`·`routine_lazy` 는 쓰지 않는다.
- 함수를 값으로 골라 부르는 자리가 있다(`keeper_heartbeat_stimulus_intake.ml:387-388`, `keeper_unified_turn.ml:1101-1103`).
- 이름을 넘기는 꼴은 `~keeper_name:meta.name` 이 419곳으로 가장 많다.

### 1.3 운영 로그

창은 2026-11-20T00:00Z ≤ `ts` < 2026-11-27T04:00Z 다.
운영 workspace 의 `<base-path>/.masc/logs/system_log_2026-11-2*.jsonl` 를 읽기만 했다.
Keeper 이름은 그 workspace 의 `keepers/*.toml` 31개다. `system` 이라는 Keeper 는 없다.

| 셈 | 수 |
|---|---|
| `module=Keeper` 줄 | 1,330,488 |
| 그중 `keeper_name` 이 `"system"` | 644,405 (48.4%) |
| 그중 본문이 `<이름>: ` 로 시작하거나 `keeper=<이름>`·`keeper:<이름>` 을 담음 | 591,029 (91.7%) |
| 그중 본문 어디든 Keeper 이름이 낱말로 나옴 | 627,998 (97.5%) |
| `"system"` 이면서 본문에 Keeper 이름이 없음 | 16,407 (Keeper 줄의 1.2%) |
| `keeper cycle OK` 줄 | 17,846, 이름 있는 줄 0 |

- 하루 비율은 40.3% ~ 64.7% 다.
- `keeper_name` 이 `null` 인 줄은 없다.
- `Keeper` 밖 module 의 `"system"` 줄은 268,109 다. `Dashboard`·`Server`·`MCP` 는 줄 전부가 `"system"` 이다. 이 RFC 는 이 줄들의 이름을 다루지 않는다(§9).

### 1.4 지난 기록

- #38368 은 턴 성공 줄 다섯에만 이름을 넘겼다. N-of-M 패치라서 닫혔다.
- #38393 은 같은 증상이라 중복으로 닫혔다.
- 09-30 트리아지는 이슈를 유지했다. 필수 인자와 logger 모양은 완료 조건으로 강제하지 않았다. 이 RFC 가 그 모양을 정한다.
- 11-05 댓글이 두 길을 냈다. 필수 인자와 codemod, 또는 Eio fiber 문맥이다. 둘 다 RFC 로 먼저 정하자고 적었다.
- 09-24 goal audit 이 「#38416 codemod」를 운영자 결정으로 남겼다고 한다. 원문 미직독.
- 이슈의 1번(`runtime candidate terminal`)은 #45618 이 고쳤다. 7일 창의 `Telemetry` 줄 148,892 가운데 `"system"` 은 15줄이다.
- `docs/LOGGING.md` 에는 이 문제의 결정이 없다.

## 2. 결정: 줄마다 scope 를 고른다

`lib/masc_log/log.mli` 에 타입 하나와 시그니처 하나를 더한다.

```ocaml
type keeper_scope =
  | Of_keeper of string
      (** 이 줄은 이 Keeper 의 일이다. 부르는 쪽이 든 이름을 그대로 넣는다. *)
  | Of_server
      (** 이 줄은 어느 한 Keeper 의 일도 아니다. *)

module type KEEPER_LOGGER = sig
  val emit :
    level -> ?details:Yojson.Safe.t -> keeper_scope -> ?turn_id:int ->
    ?category:category -> ?diagnostic_kind:diagnostic_kind -> string -> unit
  val routine :
    ?details:Yojson.Safe.t -> keeper_scope -> ?turn_id:int ->
    ?category:category -> ('a, unit, string, unit) format4 -> 'a
  val debug :
    keeper_scope -> ?turn_id:int -> ?category:category ->
    ?diagnostic_kind:diagnostic_kind -> ('a, unit, string, unit) format4 -> 'a
  val info :
    keeper_scope -> ?turn_id:int -> ?category:category ->
    ?diagnostic_kind:diagnostic_kind -> ('a, unit, string, unit) format4 -> 'a
  val warn :
    keeper_scope -> ?turn_id:int -> ?category:category ->
    ?diagnostic_kind:diagnostic_kind -> ('a, unit, string, unit) format4 -> 'a
  val error :
    keeper_scope -> ?turn_id:int -> ?category:category ->
    ?diagnostic_kind:diagnostic_kind -> ('a, unit, string, unit) format4 -> 'a
end

module Keeper : KEEPER_LOGGER
```

부르는 모양은 이렇다.

```ocaml
Log.Keeper.warn (Log.Of_keeper meta.name) "turn %d stalled" turn
Log.Keeper.info Log.Of_server "board_attention_event_fanout candidates=%d" n
```

- scope 는 이름 없는 위치 인자다. 빠뜨리면 형식 문자열이 그 자리에 들어가 타입 오류가 난다.
- `Log.Keeper` 는 안에서 `Make` 로 만든 logger 를 부른다. `Of_keeper n` 은 `Some n`, `Of_server` 는 `None` 이다. ring 의 `keeper_name : string option` 은 그대로다.
- module 이름 `Keeper` 와 `MASC_LOG_KEEPER_LEVEL` 은 그대로다.
- `emit_lazy`·`routine_lazy` 는 `Keeper` 에서 뺀다. 부르는 곳이 없다.
- 다른 logger 는 `LOGGER` 와 `?keeper_name` 을 그대로 쓴다.

### 2.1 이름을 `string` 으로 두는 까닭

- `masc_log` 는 바닥 라이브러리다. `masc_core` 가 `masc_log` 에 기댄다(`lib/core/dune:64`).
- `Keeper_name.t` 는 `masc_core` 위의 `keeper_registry` 에 있다(`lib/keeper_registry/dune:21`). `masc_log` 는 그 타입을 볼 수 없다.
- 부르는 쪽이 든 이름도 문자열이다. `Keeper_meta_contract.name : string` 이다(`lib/keeper/keeper_meta_contract.mli:108`).
- `masc_config`·`masc_trajectory` 의 호출 13곳은 `keeper_registry` 에 기대지 않는다(`lib/config/dune:42`, `lib/trajectory/dune:27`).
- 그래서 이 타입이 증명하는 것은 「누구의 일인지 골랐다」 하나다. 이름이 올바른지는 지금처럼 이름을 만드는 쪽이 맡는다.

### 2.2 이 결정이 바꾸는 문서

- `docs/LOGGING.md:20` 은 모든 `<Module>` 이 `Make` 로 만들어진다고 적는다. `:34` 는 새 component 를 `Make` 한 줄로 더한다고 적는다.
- 이 RFC 로 `Log.Keeper` 만 다른 시그니처를 가진다. 타입 층 PR 이 `LOGGING.md` 에 그 예외를 한 단락으로 적는다.

## 3. 서버 줄

- 줄이 한 Keeper 의 상태·행동·실패를 말하면 `Of_keeper` 다.
- 여러 Keeper 를 묶어 말하거나 어느 Keeper 도 말하지 않으면 `Of_server` 다.
- 예: `server_bootstrap_loops.ml:530-532` 의 「fleet projection failed keeper=…」 는 한 Keeper 의 실패라 `Of_keeper` 다.
- 예: 바로 아래 `:533-535` 의 「fleet projection … recipients=…」 는 여러 Keeper 의 합계라 `Of_server` 다.
- 그 밖의 `Of_server` 예: `keeper_board_attention_fanout.ml:126`, `keeper_microvm_shim_readiness.ml:398`·`:400`, `keeper_wire_capture.ml:105-106`.
- 이름이 그 자리에 없다는 까닭으로 `Of_server` 를 고르지 않는다. 한 Keeper 의 일이면 이름을 인자로 받아 온다.
- 서버 줄도 module 은 `Keeper` 로 남는다. 운영자의 module 거르기가 그대로 돈다.

wire 는 이렇게 바꾼다.

- 인코더 둘(`log.ml:487-489`, `:1164-1167`)은 `None` 을 `null` 로 적는다. `"system"` 과 그 주석(`:483-486`)은 지운다.
- 이 바뀜은 다른 module 의 이름 없는 줄에도 닿는다. 그 줄들도 Keeper 가 없으니 `null` 이 맞다.
- 대시보드 schema(`logs.ts:41`)는 `null` 을 받는다. 화면(`dashboard/src/workspaces/infra/logs-tab.ts:86`)은 이미 문자열이 아니면 `null` 로 둔다.
- decoder 는 이미 `null` 을 받는다(`log.ml:770-777`).
- 옛 로그 파일의 `"system"` 은 고치지 않는다. 옛 값을 바꿔 읽는 코드도 만들지 않는다.
- `docs/LOGGING.md:102-106` 은 본문에서 재지 않은 필드를 `-` 로 채우지 않고 뺀다. wire 에도 같은 원칙을 쓴다.

## 4. 나눠 싣기

한 native stack 으로 싣는다. 스택은 맨 위 PR 하나로 통째로 병합된다(`docs/constitution.xml:417-422`).
층마다 따로 컴파일되게 짠다.

| 층 | 하는 일 | 크기(어림) |
|---|---|---|
| 1. 타입 | §2 의 타입과 시그니처. 임시 생성자 `Not_yet_scoped` 를 같이 둔다. 스크립트로 모든 호출을 고친다. `~keeper_name:X` 는 `(Log.Of_keeper X)`, 이름 없는 호출은 `Log.Not_yet_scoped` 다. `LOGGING.md` 단락 | 315개 파일, 손으로 쓰는 곳은 `log.ml(i)` 와 몇 자리 |
| 2. `lib/server` | `Not_yet_scoped` 를 `Of_keeper`·`Of_server` 로 고른다 | 141곳, 23개 파일 |
| 3~4. Keeper 생애 | `keeper_keepalive*`·`keeper_heartbeat*`·`keeper_supervisor*`·`keeper_registry*`·`keeper_shutdown*` | 275곳, 28개 파일. 둘로 나눈다 |
| 5. 턴 경로 | `keeper_turn*`·`keeper_unified*`·`keeper_agent_run*` | 90곳, 29개 파일 |
| 6. 도구·채팅·기억·Board·sandbox | `keeper_tool*`·`keeper_hooks*`·`keeper_chat*`·`keeper_memory*`·`keeper_context*`·`keeper_board*`·`keeper_sandbox*`·`keeper_microvm*` 와 런타임 넷 | 157곳, 53개 파일 |
| 7~8. `lib/keeper` 나머지 | 파일 이름 순으로 반씩 | 204곳, 75개 파일 |
| 9. 다른 lib 와 `test` | `keeper_runtime`·`trajectory`·`dashboard`·`config` 등 | 53곳, 18개 파일 |
| 10. 끝 | `Not_yet_scoped` 를 타입에서 지운다. changelog 조각 | 남은 것이 있으면 컴파일되지 않는다 |

- 1층의 codemod 스크립트는 PR 본문에 싣는다. 저장소에 두지 않는다.
- 묶음 층의 크기는 코딩 에이전트 작업 단위(20k token, `docs/constitution.xml:317`)를 넘지 않게 다시 자른다. 표의 경계는 출발점이다.
- 묶음 층 PR 본문은 `Of_keeper`·`Of_server` 로 고른 수와, 이름을 받으려고 인자를 늘린 함수를 적는다.
- `Not_yet_scoped` 는 스택 안에만 있다. 스택이 통째로 병합되니 main 에 닿지 않는다.
- 스택이 도는 동안 main 에 새 `Log.Keeper` 호출이 들어오면, rebase 뒤 맨 위 PR 의 `type-check` 가 깨진다. 그 파일이 속한 층에서 고른다.
- wire 바꾸기(§3)는 스택과 따로 PR 하나다. `dashboard/` 를 건드려 `dashboard` 검사가 돈다. 스택과 순서를 가리지 않는다. 이 PR 도 changelog 조각을 낸다.

## 5. 새 이름 없는 호출 막기

- scope 가 필수 위치 인자라서 빠뜨린 호출은 컴파일되지 않는다.
- PR 마다 이미 도는 `type-check` 가 이것을 잡는다. lint 도, 새 검사도 필요 없다.
- `Of_server` 를 잘못 고르는 것은 타입이 막지 못한다. 대신 그 선택이 호출 자리에 글자로 남아 리뷰에서 보인다. §7 의 셈도 잡는다.
- `Make (struct let name = "Keeper" end)` 로 logger 를 하나 더 만들면 이 타입을 비켜 간다. 타입 층의 `LOGGING.md` 단락이 Keeper 줄은 `Log.Keeper` 로만 쓴다고 적는다.

## 6. 버린 방법

### 6.1 Eio fiber 문맥에 이름을 묶기

Keeper lane 이 시작할 때 `Eio.Fiber.with_binding` 으로 이름을 묶는다. `Log.Keeper` 는 이름이 안 오면 문맥에서 읽는다.

- 장점: 고칠 곳이 몇 자리뿐이다.
- 장점: 새 코드도 저절로 이름을 얻는다.
- 장점: 저장소에 선례가 있다(`lib/exact_lane_slot_capture.ml:5-10`, `lib/http_server_eio.ml:39-46`).
- 단점: 묶은 값은 fork 한 fiber 에만 따라간다(Eio 1.3 `eio__core.mli:359-363`, `:387-394`).
- 단점: executor pool 과 systhread 로 넘긴 일은 값을 받지 못한다. Keeper 코드도 그렇게 넘긴다(`keeper_microvm_shim_readiness.ml:390-394`, `keeper_context_digest.ml:24`, `keeper_memory_activity.ml:264`). 그 줄은 다시 조용히 이름을 잃는다.
- 단점: 거꾸로 틀릴 수도 있다. Keeper A 의 fiber 가 서버 일을 fork 하면 A 의 이름이 서버 일에 붙는다. 빠진 이름보다 틀린 이름이 더 나쁘다.
- 단점: `Fiber.get` 은 effect 로 문맥을 읽는다(`eio/core/fiber.ml:288`, `cancel.ml:226`). Eio 밖 OS thread 에서 부르면 받을 곳이 없다. `Log` 가 그것을 잡아 기본값으로 떨어져야 한다. 그 기본값이 지금의 `"system"` 이다.
- 단점: 호출 자리에서 「이 줄은 서버 일」 이라고 적을 길이 없다.
- 단점: Eio 문서도 되도록 인자로 넘기라고 적는다(`eio__core.mli:365-367`).

### 6.2 선택 인자를 두고 lint 를 더하기

- 장점: 시그니처가 그대로다. 이름을 넘기는 580곳은 손대지 않는다.
- 단점: 이미 빠진 928곳은 어차피 하나씩 고른다. 일의 양은 §4 와 같다.
- 단점: lint 는 글자를 본다. 여러 줄 호출과 함수를 값으로 고르는 호출(§1.2)을 놓친다.
- 단점: 「일부러 서버 일」 을 적으려면 무시 표지 주석이 필요하다. 그 표지가 다시 글자 분류기가 된다.
- 단점: lint 를 돌리려면 PR 검사가 하나 는다. 헌법은 운영자 요청 없이 PR 검사를 늘리지 않는다(`docs/constitution.xml:343`).
- 단점: 이미 도는 `type-check` 가 할 일을 다른 도구로 다시 한다.

## 7. 확인

스택과 wire PR 이 모두 운영 서버에 들어간 뒤 7일 창을 §1.3 과 같은 방법으로 센다.
읽는 것은 `<base-path>/.masc/logs/system_log_<UTC 날짜>.jsonl` 이고 읽기만 한다.
Keeper 이름은 그때의 `keepers/*.toml` 이다.

| 셈 | 배포 전(§1.3) | 배포 뒤 기준 |
|---|---|---|
| `module=Keeper` 중 이름 없는 줄(`"system"` 또는 `null`) | 644,405 (48.4%) | `Of_server` 를 고른 줄만 남는다. 배포 전 본문에 이름이 없던 줄은 1.2% 였다 |
| 이름 없는 줄 중 본문이 `<이름>: ` 로 시작하거나 `keeper=<이름>`·`keeper:<이름>` 을 담음 | 591,029 | 0 |
| `keeper cycle OK` 줄 중 이름 있는 줄 | 0 / 17,846 | 전부 |
| `module=Keeper` 의 `"system"` 줄 | 644,405 | 0 (`system` 이라는 Keeper 가 없을 때) |

- 이름 없는 줄의 본문 앞머리 상위 20개를 사람이 읽는다. 한 Keeper 의 일이 보이면 그 호출을 고친다.
- 결과는 그때의 PR 본문과 #38416 댓글에 적는다. 저장소에 두지 않는다.

## 8. 열린 질문

1. wire 의 `null`: 다른 module 의 이름 없는 줄(7일에 268,109줄)도 `"system"` 에서 `null` 이 된다. 이대로 가는가? 아니면 `"system"` 을 남기고 Keeper 이름으로 `system` 을 막는가?
2. `Of_keeper` 의 값을 `Keeper_name.t` 로 올리는 일은 `Keeper_meta_contract.name` 이 그 타입이 될 때 한다. 그 일을 따로 이슈로 둘까?
3. 가린 이름표: `keeper cycle OK` 17,846줄 모두 `runtime_lane=runtime` 이다(이슈 4번). `Boundary_redaction` 계약은 내부 관측이 그 모듈을 쓰지 말라고 적는다(`lib/types_boundary/boundary_redaction.mli:8-10`). 계약대로 고치는 PR 을 따로 낼까? 아니면 `public_label` 을 추상 타입으로 바꿔 컴파일러가 막게 할까?
4. 본문 앞의 `"%s: "` 이름: 이제 필드와 콘솔 머리(`[Keeper/<name>]`, `log.ml:1372-1378`)에 이름이 있다. 본문에서 지울까?
5. `module=Keeper` 의 서버 줄을 `Log.Server`·`Log.Config` 같은 다른 logger 로 옮길까? 옮기면 `MASC_LOG_KEEPER_LEVEL` 이 거르는 줄이 바뀐다.

## 9. 하지 않을 것

- 다른 logger 의 `?keeper_name` 은 그대로 둔다.
- 옛 로그 파일을 고치지 않는다. 옛 `"system"` 을 바꿔 읽는 코드도 만들지 않는다.
- lint, 새 PR 검사, fiber 문맥 이름을 만들지 않는다.
- 로그 본문 글자는 바꾸지 않는다(§8 의 4).
- `turn_id` 는 선택 인자로 둔다.
- 가린 이름표(§8 의 3)는 여기서 정하지 않는다.
- module 이름과 module 배치는 바꾸지 않는다(§8 의 5).
