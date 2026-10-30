---
rfc: "0477"
title: "키퍼 목록 화면은 폴링하지 않고, 바뀐 것만 타입이 있는 이벤트로 받는다"
status: Draft
created: 2026-10-28
updated: 2026-10-28
author: dancer + claude
supersedes: []
superseded_by: null
related: ["0204", "0461", "0474", "keeper-async-fleet-continuity"]
---

# RFC-0477 — 키퍼 목록 화면은 폴링하지 않고, 바뀐 것만 받는다

## 0. 요약

TUI 키퍼 목록 화면은 2초마다 `GET /health?full=1` 을 받는다. 본문은 키퍼 40개일 때 134,894 B 이고, 화면이 쓰는 것은 그 안의 `keeper_fleet_safety` 구간(15,759 B, 11.7%)에서 읽는 필드 약 20개다. 키퍼가 300개면 같은 문서는 0.8~1.0 MB 가 된다(선형 추정).

화면이 흔들리는 이유는 크기가 아니라 두 가지 상태가 요청 결과로 정해지기 때문이다.

1. 헤더 배지 `HTTP [connected]` 뒤에 `· reading …` 같은 진행 문구가 붙었다 사라진다.
2. `fleet reading: stale · measured … ago` 줄이 생겼다 사라진다. 서버 캐시는 키퍼 상태가 한 번이라도 바뀌면 다음 스캔이 끝날 때까지 `stale` 이다. 15번 읽는 동안 3번(20%)이 `stale · invalidated` 였다.

이 RFC 는 이 화면에서 폴링을 없앤다. 결정은 다섯 가지다.

1. 서버와 TUI 가 같은 모듈의 타입과 엄격한 코덱을 쓴다(§3.1). 새 모듈 `Fleet_stream`(`lib/fleet_stream/`)이다.
2. 연결하면 현재 상태(`Snapshot` 또는 `Unavailable_snapshot`)를 한 번 받고, 그 뒤로는 바뀐 것만 받는다. 이벤트마다 번호(`revision`)가 있고, 번호가 건너뛰면 다시 연결해서 현재 상태를 받는다. 이어받기용 재생 버퍼는 만들지 않는다(§3.2).
3. 만드는 쪽은 새 스캔을 만들지 않는다. 기존 `full_health_snapshot` 갱신 루프의 결과를 이전 값과 비교해서 달라진 것만 내보낸다(§3.3).
4. 전송은 SSE 다. gRPC 도 같은 하네스로 재 봤지만 고르지 않았다(§2, 부록 B).
5. TUI 는 이 화면의 읽기를 지운다. 폴링으로 되돌아가는 길을 남기지 않는다. 연결이 끊기면 끊겼다고 보이고, 돌아오면 현재 상태를 받는다(§3.5).

이 RFC 가 고치지 않는 것: 서버가 간헐적으로 3~10초 멈추는 문제(RFC-0474), 스캔 한 번이 87 ms~5.7초 걸리는 것(§1.4), 다른 화면의 폴링. 범위는 §3.6 에 적는다.

## 1. 지금 상태 (2026-10-28 측정)

환경: 서버 빌드 `2532ad1de9e`(`/health` 의 `build.commit`, 같은 시각 main 과 같다), 키퍼 40개(running 23/29), TUI 로그 `masc-tui-37970.log` 12:33~13:15, 같은 서버에 직접 curl. 재현 명령은 부록에 있다.

### 1.1 TUI 가 읽는 것

| 사실 | 값 | 위치 |
|---|---|---|
| 읽기 주기 | 2초(`--refresh`, 기본 2.0) | `bin/masc_tui.ml:523`, 루프 `:34223` |
| 키퍼 목록이 새로고침마다 읽는 것 | `GET /health?full=1` 한 번을 `fleet_safety` 로 | `bin/masc_tui_types.ml` `Keepers Keeper_list` → `needs_fleet_safety`, `bin/masc_tui_loader.ml:1636`, `bin/masc_tui_http.ml:3314` |
| 압축 | TUI 코드에서 압축을 요청하는 헤더를 찾지 못했다 | `bin/masc_tui_http.ml`, `lib/masc_http_client/` |
| 본문 크기 | 134,894 B(압축 없이). `Accept-Encoding: zstd` 를 보내면 19,932 B | curl |
| 화면이 쓰는 구간 | `keeper_fleet_safety` 15,759 B(11.7%)의 필드 약 20개와 `full_health_snapshot` 상태 | `lib/tui_decode.ml:413~456`, `:6856~7020` |
| 키퍼 수에 비례하는 구간 | `keeper_reaction_ledger` 42,750 B, `keeper_event_queue` 34,064 B, `keeper_fleet_safety` 15,759 B, `keeper_owner` 11,156 B. 합 103,729 B(77%), 키퍼당 약 2.6 KB | jq |
| JSON 읽기 비용 | 134,894 B 에 1.48 ms(Yojson 3.0.0, 500회 평균, 이 Mac) | 부록 |
| 같은 값을 `Snapshot` 으로 인코딩하면 | 2,203 B(§3.1 의 코덱으로, 15개 스냅샷 모두 같은 크기). 134,894 B 의 1.6% | `lib/fleet_stream` 시험 밖 확인(부록) |

### 1.2 화면이 흔들리는 두 경로

**배지 문구.** `connection_badge`(`bin/masc_tui_render_prim.ml:1536`)가 `refresh_progress_badge`(`:1480`)를 이어 붙인다. 이 문구는 지금 새로고침이 어디까지 갔는지(`reading keepers +2`, `partial: … failed`)를 그대로 보여 준다. 새로고침이 2초마다 도니 문구도 2초마다 바뀐다.

**`stale` 줄.** `bin/masc_tui_render_keepers.ml` 의 fleet 구간이 `Masc_tui_fleet_line.freshness_text` 를 줄 하나로 그린다. `Fleet_current` 이면 줄이 없고 `Fleet_last_good` 이면 줄이 생긴다. 이 값은 서버의 `full_health_snapshot.status`(`lib/tui_decode.ml:6985`)에서 온다.

서버 쪽 규칙(`lib/server/server_routes_http_runtime.ml:651~668`): `stale_since_ts` 는 키퍼 상태가 처음 무효화된 시각이고, 그 뒤 스캔이 현재 세대를 확인할 때까지 유지된다. 무효화 신호는 네 곳이다(`Keeper_registry`, `Keeper_owner`, `Keeper_reaction_ledger`, `Keeper_event_queue_persistence`, 모두 `lib/server/server_runtime_bootstrap.ml:532~538` 에서 `invalidate_full_health_snapshot` 으로 이어진다).

56초 동안 4초 간격으로 15번 읽은 결과:

| | 값 |
|---|---|
| `full_health_snapshot.status = stale`(`invalidated`) | 3/15 번(20%) |
| `invalidation_generation` | 1014 → 1023(9번) |
| 스캔 `duration_ms` | 87, 109, 188, 803, 5,668 ms |

화면에서 보이는 줄이 "5번 읽을 때 한 번꼴로" 생기는 이유가 이것이다. 화면 값이 키퍼 상태가 아니라 서버 캐시의 무효화 상태로 정해진다.

### 1.3 실제로 바뀐 것은 적다

같은 15개 스냅샷에서 키퍼별 항목 121개(`keeper_event_queue` 40, `keeper_owner` 40, `keeper_reaction_ledger` 41)와 fleet 구간 1개, 합 122개를 이웃한 스냅샷끼리 비교했다(`*_age_seconds` 는 읽는 순간 서버가 계산하는 값이라 제외했다. 제외하지 않으면 모든 항목이 매번 바뀐 것으로 보인다).

- 14번 비교 중 10번은 달라진 항목이 0개였다. 나머지 4번에 합계 7개(0.125개/초)가 달라졌다.
- fleet 구간은 한 번도 달라지지 않았다. 그런데 `stale` 줄이 뜨는 상태는 3번이었다. 화면의 `stale` 줄은 fleet 값이 달라져서가 아니라 무효화 때문에 떴다.
- 무효화는 9번이었고 값이 달라진 간격은 4번이었다(한 간격에 무효화가 여러 번 일어났을 수 있어서, 값이 같은 무효화가 있었는지는 이 측정으로 확정하지 못한다). 무효화 신호에는 값이 없고, 값은 스캔이 끝나야 나온다.

한 번의 1분 측정이다. 신뢰도는 낮다.

### 1.4 느린 읽기는 이 RFC 밖이다

TUI 읽기 1,191번(40분)의 분포: 중앙값 59 ms, p90 208 ms, p99 4.7초, 최대 10.0초. 1초 넘는 읽기는 43번(3.6%)이고 약 70~80초 간격이다. 같은 순간에 `keepers/turns` 와 `gate/keepers` 가 둘 다 5.7~5.9초씩 걸렸다. 인증 없는 `/health` 도 160초 중 두 구간에서 0.3~1.6초로 느려졌다.

서버는 RFC-0474 L1~L4a 가 들어간 main 과 같은 빌드다. 그래도 남아 있으니, 이 멈춤은 RFC-0474 의 남은 일(L4b, #46544)이 다룬다. 이 RFC 는 멈춤을 고치지 않는다. 멈춰도 화면이 "요청 실패"가 아니라 "마지막 상태, 몇 시 기준"으로 남게 할 뿐이다.

### 1.5 이미 있는 것

| 무엇 | 사실 | 위치 |
|---|---|---|
| 변화 신호 | 위 네 곳 | `server_runtime_bootstrap.ml:532~538` |
| 백그라운드 갱신 | 깨움 신호는 0.1초 안에 합쳐진다. 간격은 `max 30 (timeout+5)`, 유효 시간은 `max 60 (간격×2)`. 스캔은 worker domain 에서 돈다 | `server_routes_http_runtime.ml:723~728`, `:1393~1425` |
| SSE 버스 | 클라이언트당 256칸, 재생 버퍼 1000건(모든 이벤트 종류가 함께 쓴다), 재생이 이어졌는지 알려 주는 `Continuous \| After_gap`, 클라이언트 상한 200 | `lib/sse.ml:124`, `:141`, `:307`, `:406~426` |
| 읽기 모델 규칙 | "SSE 는 신선도를 전하는 길이지 권위 있는 읽기 모델이 아니다" | `docs/SYSTEM-EVENT-AND-SNAPSHOT-INVENTORY.md` §Read Model Rules |
| 규모 목표 | 10/100/300 키퍼 묶음. 인수 기준 A17: 300 키퍼 묶음이 전체를 막는 대기 없이 같은 작업을 마친다 | `docs/rfc/RFC-keeper-async-fleet-continuity.md:180`, `:244` |

## 2. 고르지 않은 길

| 안 | 이유 |
|---|---|
| 폴링 주기를 늘린다 | 반영이 늦어지고, 배지와 `stale` 줄이 요청 결과로 정해지는 구조는 그대로다 |
| `stale` 줄을 숨긴다 | 증상만 가린다. 서버가 정말 못 읽은 때도 안 보이게 된다 |
| 신호만 보내고 클라이언트가 다시 읽게 한다(`keeper_composite_changed` 방식) | 300개에서 변화가 초당 약 0.9건이면, 변화마다 클라이언트 수만큼 약 1 MB 문서를 다시 읽는다(추정) |
| 무효화 신호를 그대로 이벤트로 내보낸다 | §1.3. 신호에는 값이 없고, 무효화 9번에 값이 달라진 간격은 4번이었다 |
| 기존 observer SSE 의 스냅샷 이벤트를 쓴다 | 주석(`bin/masc_tui_observer.mli`)대로 한 이벤트가 수 MB 까지 간다. 재생 버퍼 1000건도 다른 종류와 같이 쓴다 |
| 전송을 gRPC 로 한다 | 가장 싼 gRPC 길에서 p99 가 하나씩 쓸 때 1.4 ms, 연달아 쓸 때 11 ms 낮았다. 반면 스트리밍 RPC 를 인증할 길이 없고, 끊긴 연결을 서버가 모르고, gRPC 서버는 기본이 꺼져 있고, 원격 TUI 때문에 SSE 는 남아서 길이 둘이 된다(부록 B) |

## 3. 설계

### 3.1 타입과 코덱 — `lib/fleet_stream`

서버와 TUI 가 같은 정의를 쓰는 순수 모듈이다. `lib/` 는 `(include_subdirs unqualified)` 로 `masc` 라이브러리 하나라서(`lib/dune`), `Keeper_fleet_grade` 와 `Keeper_fleet_blocker`(둘 다 `lib/keeper/`)를 쓰려면 같은 라이브러리 안에 있어야 한다. 이 모듈은 그 둘과 Yojson 만 쓰고, 서버나 TUI 모듈을 부르지 않는다. 서버(`lib/server/`)와 TUI(`bin/`, `Masc.Fleet_stream`)와 테스트가 이 모듈에 의존한다.

```ocaml
(* 시그니처 요약. 전체는 lib/fleet_stream/fleet_stream.mli *)
val schema_version : int

module Revision : sig
  type t
  val first : t
  val next : t -> t
  val is_next : after:t -> t -> bool  (* 번호가 건너뛰었는지 알아보는 함수 *)
  val of_int : int -> t option        (* 1 미만은 None *)
  val to_int : t -> int
end

module Names : sig                    (* 정렬되고 중복 없는 키퍼 이름 *)
  type t
  val of_list : string list -> t                    (* 만드는 쪽: 정렬하고 중복을 없앤다 *)
  val of_canonical_list : string list -> t option   (* 읽는 쪽: 이미 정렬된 목록만 받는다 *)
  val to_list : t -> string list
end

type fleet = {
  fs_status : Keeper_fleet_grade.t;
  fs_blocker : Keeper_fleet_blocker.t option;
  fs_operator_action_required : bool;
  fs_bootable_count : int;
  (* … 지금의 Tui_decode.fleet_safety 필드 21개를 같은 이름으로 옮긴다 *)
  fs_bootable_names : Names.t;
}

type degraded_reason = Scan_timed_out | Scan_failed
type degradation = { since : float; reason : degraded_reason }

type event =
  | Unavailable_snapshot of { revision : Revision.t; degradation : degradation }
  | Snapshot of { revision : Revision.t; measured_at : float; fleet : fleet; degraded : degradation option }
  | Changed of { revision : Revision.t; measured_at : float; fleet : fleet }
  | Degraded of { revision : Revision.t; degradation : degradation }

val encode : event -> Yojson.Safe.t
val decode : Yojson.Safe.t -> (event, decode_error) result
```

규칙:

- 정확히 읽는다. 모르는 이벤트 이름, 빠진 필드, 모르는 필드, 범위 밖 값은 `decode_error` 다. 기본값으로 채우지 않는다(constitution 의 `strict_parse_no_default`).
- 나이를 싣지 않는다. `measured_at`(epoch 초)만 싣고 화면이 나이를 계산한다. 나이를 싣는 값은 읽을 때마다 달라져서 §1.3 의 비교를 못 하게 된다.
- `schema` 는 상수 `schema_version` 이고 최초 상태인 `Snapshot` 또는 `Unavailable_snapshot` 에 실린다. 값이 다르면 다른 필드를 읽기 전에 `Schema_mismatch` 로 멈춘다. 화면은 "서버 버전이 다르다"를 띄운다(화면에 이미 있는 빌드 비교와 같은 자리).
- `Changed` 는 fleet 값 전체를 바꿔 끼운다. 필드 단위 차이는 보내지 않는다. fleet 값은 크기가 작고(키퍼 40개에서 `Snapshot` 이 2,203 B) 바뀌는 횟수가 적다.
- `Snapshot` 은 읽기 한 번이 말해 주는 상태 전부다. 스캔이 실패한 중이면 `degraded`(시작 시각과 이유)도 싣는다. 별도 `Degraded` 이벤트로 보내면 `Snapshot` 과 번호가 겹치거나 건너뛰기 때문이다.
- 첫 읽기 전에 스캔이 실패하면 실제 fleet 값을 만들지 않고 `Unavailable_snapshot` 으로 첫 실패의 시각과 이유를 보낸다. 재연결에도 같은 상태를 보내고, 첫 유효 읽기는 다음 번호의 `Changed` 로 복구한다. 준비 중(`warming`)은 실패가 아니다.
- 이름 목록은 `Names.t` 라서 정렬되고 중복이 없는 채로만 만들어진다. 같은 값이 다른 순서로 와서 다른 이벤트가 되는 일이 없다. 읽을 때 정렬되지 않은 목록은 `Not_canonical` 이다.
- 필드 이름은 지금 TUI 가 쓰는 `fs_*` 를 그대로 둔다. L4 에서 TUI 가 바꾸는 것은 타입의 출처뿐이다. 선로 위의 이름은 `fs_` 를 뗀 이름이다(`bootable_count`, `running_names`). 이름을 고정하는 시험이 있다.

`Tui_decode` 의 `fleet_safety` 와 관련 타입(`lib/tui_decode.ml:413~456`), `decode_fleet_safety*`, `decode_fleet_reading_freshness`(`:6856~7020`)는 이 모듈로 옮기고, `Tui_decode` 에서는 지운다. `Unrecognised_fleet_status` 같은 "모르는 값을 문자열로 보관하는" 갈래는 옮기지 않는다.

### 3.2 번호와 이어짐

- 허브는 이벤트마다 `revision` 을 1씩 올리고, `Snapshot` 과 `Unavailable_snapshot` 은 현재 `revision` 을 싣는다. 클라이언트는 첫 상태를 받을 때마다 자기 번호를 그 값으로 다시 시작한다. 서버를 다시 켜서 번호가 처음부터 시작해도 새 연결은 새 상태로 시작하므로 섞이지 않는다.
- 클라이언트는 `revision` 이 `last + 1` 이 아니면 연결을 닫고 다시 연다. 그러면 새로운 현재 상태를 받는다. 이벤트가 하나라도 빠지면 번호가 건너뛰어서 알 수 있다.
- 이어받기용 재생 버퍼를 만들지 않는다. 최신 `Snapshot` 또는 `Unavailable_snapshot` 이 곧 이어받기다. `Last-Event-Id` 와 `since_seq` 를 쓰지 않는다.
- 연결할 때 첫 상태를 보내는 일과 구독자 등록은 한 번에 일어나야 한다. 사이에 이벤트가 끼면 번호가 건너뛴 것처럼 보인다.

### 3.3 만드는 쪽

`Fleet_stream_hub`(서버, `lib/server/`)가 현재 값 하나(`revision`, `measured_at`, `fleet`)를 들고 있다.

- 입력은 기존 `full_health_snapshot` 갱신 루프가 결과를 저장하는 두 함수다. 성공은 `store_successful_full_health_snapshot_locked`, 실패와 시간 초과는 `mark_full_health_snapshot_failure_locked` 이고, 동기 갱신·worker·기다리는 쪽의 시간 초과가 모두 이 둘을 지난다(`lib/server/server_routes_http_runtime.ml:958`, `:965`). 허브는 자기 락만 잡고 서버 락을 부르지 않으므로 서버 락 안에서 불러도 순서가 뒤집히지 않는다. 새 스캔, 새 타이머, 새 무효화 신호를 만들지 않는다.
- 새 값이 지금 값과 같으면(`measured_at` 제외) 이벤트를 내지 않는다. 무효화가 9번이어도 값이 같으면 0건이다.
- 갱신이 시간 안에 끝나지 않거나 실패하면 첫 읽기 전에는 `Unavailable_snapshot`, 읽은 뒤에는 `Degraded` 를 한 번만 낸다(처음 실패한 순간, `since` 는 그 시각으로 고정). 다음에 성공하면 값이 같아도 `Changed` 가 나가면서 풀린다. 그 뒤에 연결하는 구독자는 읽은 값이 있으면 `Snapshot` 의 `degraded` 로, 없으면 `Unavailable_snapshot` 으로 안다.
- 값이 `fleet_safety` 로 만들어지지 못했을 때 준비 중이면 기다린다. section 의 오류·시간 초과나 읽을 수 없는 결과는 실패로 전달하고, 처음 실패하면 `Unavailable_snapshot` 을 보낸다.
- 지금 스캔은 JSON 으로 값을 내므로, 서버가 그 JSON 구간을 `Fleet_stream_health_section.fleet_of_health_fields`(코덱과 다른 모듈, 한 함수)로 읽어서 허브에 넘긴다. 이 함수는 스캔의 필드 이름과 스트림의 필드 이름을 둘 다 아는 유일한 곳이다. 스캔이 타입 있는 값을 직접 내게 바꾸는 일은 이 RFC 밖이고, 바뀌면 이 함수가 사라진다.

읽기 모델 규칙과의 관계: 스트림이 싣는 값은 서버 저장소에서 계산한 `full_health_snapshot` 의 투영이다. 권위는 저장소와 HTTP 읽기에 있고 스트림은 그 값을 전하는 길이다. `Snapshot` 한 번이 HTTP 읽기 한 번과 같은 값을 준다.

### 3.4 전송은 SSE 다

허브는 구독 함수 하나만 낸다. 전송은 이 함수 위에 얹는다.

```ocaml
val subscribe : on_event:(Fleet_stream.event -> unit) -> (unit -> unit) (* 구독 취소 *)
```

SSE 어댑터는 이벤트를 받아 공용 코덱으로 인코딩해서 쓴다. 어댑터에 상태 판단을 넣지 않는다.

- 경로는 `GET /api/v1/stream/fleet`(상수 `Fleet_stream.stream_path`)이다. 프레임 `data:` 에 `encode` 한 JSON, `id:` 에 `revision` 을 싣는다.
- 인증은 다른 운영자 읽기와 같은 `with_public_read` 다. 기본 설정에서는 열려 있고 엄격 설정에서는 읽기 인증이 필요하다.
- 서버 SSE 쓰기 코드와 TUI 의 `Sse_wire` 를 쓴다. 이미 열려 있는 HTTP 포트를 쓰므로 새 포트도 새 설정 값도 없고, 터널로 붙는 다른 기계의 TUI 도 읽는다.

연결 하나가 받는 것은 `Server_fleet_stream_pump`(소켓과 분리된 모듈, 시험이 있다)가 정하고, 경로 파일은 인증과 소켓 쓰기만 맡는다.

- 연결마다 크기가 64인 큐를 두고, 허브는 큐에 넣기만 한다(허브의 락을 쥔 채 불리므로 기다리지 않는다). 큐가 가득 찬 연결은 이벤트를 건너뛰지 않고 닫는다. 건너뛰고 두면 클라이언트는 다음 이벤트의 번호가 빠진 걸 보고 어차피 다시 연결해야 한다.
- 가득 찬 것을 알아채는 때는 쓰고 있던 `send` 가 돌아온 뒤이고, 그 뒤에는 그 연결에 아무것도 더 쓰지 않는다. 다시 읽기 시작한 클라이언트는 이미 보낸 것까지 읽고 응답의 끝을 만나 다시 연결하며, 새 `Snapshot` 으로 바로잡힌다(§5 의 실제 소켓 시험).
- 소켓 쓰기는 flush 가 끝나길 기다린다. 읽지 않는 클라이언트는 여기서 멈추고 큐 상한이 막는다. 기다리지 않으면 쓰기 버퍼가 상한 없이 자란다.
- `send` 하나가 90초(`stalled_after_s`, keepalive 간격의 세 배) 안에 돌아오지 않으면 pump 가 `Stalled` 로 끝난다. 큐를 버리고 구독을 풀고 응답을 닫으므로, 읽지 않는 클라이언트 때문에 서버가 큐(64개)와 프레임 하나를 잡고 있는 시간은 최대 이 시간이다. 그 연결의 소켓은 쓰던 바이트가 나가야 닫히는데, 상대가 계속 읽지 않을 때 언제 닫히는지는 확인하지 못했다. 서버 전체의 연결 수 상한은 이 RFC 밖이다.
- 이벤트 없이 30초(`sse_ping_interval_s`)가 지나면 `: keepalive` 주석 줄을 쓴다. 간격은 마지막 프레임부터 센다. 이벤트와 keepalive 시한이 같은 순간에 오면 이벤트를 보낸다(`Watched_work.run`. `Eio.Fiber.first` 는 먼저 끝난 쪽만 쓰고 다른 쪽 결과를 버린다).

### 3.5 TUI

- 연결은 job 하나가 소유한다(`launch_fleet_stream`, `bin/masc_tui.ml`). 관찰자 피드와 같은 방식으로 `fork_workspace_job ~observation:true` 로 띄우고 메일박스로 보고한다. 서버가 한 번 답하고 workspace 를 확인한 뒤(`Workspace_identity_match`) 시작하고, 끝나면 이름 붙은 상수 `fleet_stream_reconnect_s`(2초, 기본 새로고침과 같다) 뒤에 다시 연결한다. workspace 가 걸어 내리기 전에는 끝나지 않는다. 요청에 `expected_base_path`·`expected_masc_root` 를 붙여서, 같은 포트에 다른 workspace 가 답하면 서버가 409 로 거절한다. 옛 `/health?full=1` 읽기가 `Health_identity` 로 하던 일을 이어받는 것이고, 관찰자 피드와 달리 workspace 가 맞지 않는 동안에는 시작하지 않는다.
- 받은 바이트를 화면용 상태로 바꾸는 일은 순수 모듈 `Masc_tui_fleet_stream`(`bin/`)이 한다. 값(`view`)은 닫힌 타입이다: `Awaiting_first_reading`, 상태를 받기 전에 연결이 끊긴 시각을 담는 `Unreachable`, 첫 읽기 없는 실패와 연결 종료 시각을 담는 `Unavailable`, `Reading { reading; trouble }`(`trouble` 은 없음, `Scans_failing`, `Disconnected { since }`), `Cannot_read`(`Refused`, `Schema_mismatch`, `Frame_rejected`). 시도 횟수 같은 숫자로 동작을 바꾸지 않는다. 화면이 그리는 `view` 는 job 이 따르는 동안에만 있다(`Fleet_stream_following of view`). job 이 내려가면 값도 같이 없어지므로 다른 workspace 의 값이 화면에 남지 않는다.
- `Snapshot` 과 `Unavailable_snapshot` 은 번호와 상관없이 받는다(서버를 다시 켜면 번호가 1부터다). 그 밖의 이벤트는 바로 앞 번호 다음이어야 받고, 아니면 연결을 닫고 다시 연다. 읽을 수 없는 프레임과 다른 `schema` 도 같다. 거절하고 나면 첫 상태가 올 때까지 아무것도 따르지 않는다.
- 키퍼 화면, Metrics 의 fleet 읽기(`needs_fleet_safety`, `load_fleet_safety`, `fetch_fleet_safety`, `Dataset_fleet_safety`)와 `Tui_decode` 의 fleet 타입·디코더를 지웠다. 이 화면들은 더 이상 `/health?full=1` 을 읽지 않는다. 그래서 헤더 배지의 `· reading …` 에서도 fleet 읽기가 사라진다.
- `fleet reading: stale …` 줄은 서버 스캔이 실패하는 중이거나 연결이 끊긴 동안만 그린다. 값이 있는 동안 줄이 없다. 서버는 답하는데 스트림만 끊긴 동안은 마지막 값을 끊긴 뒤 지난 시간과 함께 그린다. 값을 못 읽는 이유(HTTP 거절, 다른 `schema`)는 `fleet:` 줄에 한 줄로 쓴다. 상태를 한 번도 받기 전에 연결이 끊기면 `fleet:` 줄에 `not observed · stream lost <지난 시간> ago` 를 쓰고, 이유는 TUI 로그(`tui_fleet_stream_lost`)에 남긴다.
- 서버를 읽는 새로고침이 실패하면 workspace 확인이 풀려서 job 이 내려가고 fleet 줄도 사라진다. 연결이 끊겼다는 것은 헤더 배지가 말한다. 서버가 돌아와 workspace 가 다시 확인되면 새 job 이 연결해서 `Snapshot` 으로 다시 그린다. workspace 가 바뀌어 job 이 내려갈 때도 같다.
- 조용해진 연결은 `get_stream` 의 idle 감시가 끝낸다. 감시는 구간(keepalive 간격의 세 배, 90초)이 끝날 때만 마지막 청크를 비교하므로, 연결이 조용해지고 90초에서 180초 사이에 끊긴 것으로 처리된다.
- 연결되지 않는 동안 HTTP 로 읽는 길을 두지 않는다(hard cut).
- 표시 문구와 줄 배치를 확인하는 테스트는 만들지 않는다(constitution). TUI 시험은 상태 전이(번호 건너뜀 → 재연결, 다른 `schema` → `Cannot_read`)만 본다.
- `Masc_tui_workspace_read` 의 `Health_identity` 증명은 이 읽기가 쓰는 유일한 곳이 사라져서 운영 코드에서는 쓰이지 않는다(시험 하나만 쓴다). 이 RFC 는 건드리지 않았고, 지우는 일은 따로 한다.

### 3.6 범위

이 RFC 의 첫 주제는 fleet 이다. 키퍼 행(`GET /api/v1/gate/keepers?detailed=true`)은 같은 틀(주제 하나를 같은 스트림에 더하고, `revision` 은 스트림 하나가 공유)로 다음 층에서 더한다. 승인(`keepers/tool-approvals`)과 ask 도 같다.

건드리지 않는 것: `/health?full=1` 의 모양과 스캔 로직, 다른 화면의 폴링, observer 피드, 웹 대시보드, RFC-0461 의 닫힌 SSE 종류(이 스트림은 자기 `event` 타입을 가지므로 영향이 없다), 서버 멈춤(RFC-0474).

## 4. 규모 (키퍼 300개)

| | 지금(40, 실측) | 300(추정) |
|---|---|---|
| 폴링 1회 본문 | 134,894 B | 0.8~1.0 MB |
| 폴링 대역폭(클라이언트 1개) | 약 68 KB/s | 0.4~0.5 MB/s |
| 값이 달라지는 횟수 | 0.125개/초 | 약 0.9개/초 |
| 이벤트 본문(fleet 값 전체) | 2,203 B(실측) | 13,242 B(합성 이름 11자로 실측. 전송하면 프레임이 붙어 13,261 B) |
| 연결할 때 `Snapshot` | 2,203 B(실측) | 같은 크기 |

폴링 쪽의 300 값은 40 의 값에 7.5 를 곱한 선형 추정이고 검증하지 않았다. 스캔 시간이 키퍼 수에 어떻게 늘어나는지는 재지 못했다. 이벤트 크기는 하네스(부록 B)가 합성 이름으로 쟀다. 실제 이름이 11자보다 길면 더 크다.

fleet 이벤트는 키퍼 이름 목록 세 개가 크기를 정한다(`bootable`, `running`, `executable`). 키퍼 행 주제는 키퍼마다 따로 보내므로 이 문제가 없다.

### 4.1 SSE 로 300개가 충분한가

전송은 충분하다. 키퍼 수는 연결 수가 아니라 이벤트 크기를 키운다. 연결은 TUI 하나에 하나다.

| | 300개에서 |
|---|---|
| 이벤트 크기 | 13.2 KB(합성 이름 11자). 이름 목록 세 개가 크기를 정하고 이름 하나는 JSON 에서 (글자 수 + 3) B 이므로, 세 목록에 300개가 다 있고 이름이 24자면 약 24 KB, 32자면 약 32 KB 다 |
| 대역폭(구독자 1개) | 0.9개/초(추정) × 13~32 KB = 약 12~29 KB/s. 폴링은 0.4~0.5 MB/s(추정) |
| 반영 시간(부록 B, 하나씩 쓸 때) | p99 중앙값 구독자 1명 2.20 ms, 5명 4.42 ms |
| 서버 CPU | 구독자마다 이벤트당 인코딩 38 µs(쓰기 제외). 1개/초에 구독자 3명이면 초당 약 0.1 ms |
| TUI CPU | 이벤트당 디코딩 133 µs |
| 연결마다 메모리 | 큐 상한 64개 × 13~32 KB = 약 0.8~2 MB(읽기가 멈춘 연결이 최대치이고, `send` 가 90초 안에 돌아오지 않으면 풀린다) |
| 읽다 멈춘 구독자 1명 | 다른 구독자의 p50 은 같고 p99 중앙값은 5.94 대 4.42 ms |

연달아 16개를 5명에게 쓰는 시험은 p99 35.6 ms 가 나왔지만 실제로 나올 수 있는 부하가 아니다. 이벤트는 스캔이 한 번 끝날 때마다 최대 한 번 나가고, 스캔은 40개에서도 87 ms 이상 걸렸다.

재지 못한 것: 300개일 때 스캔 시간(값은 스캔이 끝나야 나온다. RFC-0474 쪽), 실제 키퍼 300개를 띄운 서버(하네스는 합성 이름과 합성 변경을 쓰고 서버·클라이언트·구동기가 한 프로세스에서 돈다), 300개에서 값이 달라지는 빈도(40개 1분 측정의 7.5배 추정), TUI 가 키퍼 300행을 그리는 시간.

## 5. 검증

하네스를 먼저 만든다.

- **코덱.** 왕복(`decode (encode e) = e`), 엄격 거절(빠진 필드, 모르는 필드, 모르는 이벤트 이름, 다른 `schema`, 범위 밖 값, 정렬 안 된 목록).
- **허브.** 같은 값이면 이벤트 0, 다른 값이면 `revision` +1, 구독 직후 `Snapshot` 과 이후 이벤트 사이에 번호가 건너뛰지 않는다, 한 구독자가 막혀도 다른 구독자에게 영향이 없다, 갱신이 실패하면 `Degraded` 한 번.
- **서버 경로와 클라이언트(실제 소켓).** `test_fleet_stream_loopback`: 서버의 accept 루프와 경로의 `serve`, TUI 의 HTTP 클라이언트와 `Masc_tui_fleet_stream` 을 loopback 에 올려서 확인한다. 읽는 쪽이 허브를 따라가고(스냅샷, 변경, 장애, 복구), 첫 읽기 전에 연결한 쪽이 그 읽기를 `Snapshot` 으로 받고, keepalive 주석이 이벤트가 되지 않고, 서버를 같은 포트에 다시 띄우면 새 서버의 `Snapshot`(번호 1)로 복구하고, 읽다 멈춘 구독자가 큐 상한을 넘긴 뒤 다시 읽으면 새 연결의 `Snapshot` 으로 바로잡히고 서버가 옛 연결을 놓는다. 다시 읽지 않는 구독자는 정지 한도가 지나면 읽지 않은 채로 서버가 구독을 푼다. 경로를 일부러 망가뜨린 변형(응답 상태를 404 로, 프레임을 안 쓰기, 응답을 바로 닫기)과 pump 를 망가뜨린 변형(넘친 뒤에도 계속 쓰기, 넘친 이벤트를 조용히 건너뛰기)을 모두 잡았다.
- **전송 벤치.** 부록 B 의 `bench_fleet_stream`: SSE 와 gRPC(가장 싼 길), 구독자 수, 연달아 쓰는 변경, 읽다 멈춘 구독자(SSE), 키퍼 수 40/300 합성.
- **실제 화면 증거.** 같은 서버에서 전과 후로 56초 동안 `stale` 줄이 나타난 횟수와 배지 문구가 바뀐 횟수를 로그로 센다. 전: 15번 중 3번. 목표는 `Degraded` 가 아닌 동안 0번이다. 화면 캡처와 TUI 로그를 같이 남긴다.

## 6. 작업 나눔

스택 PR 로 올린다. 각 층은 20k token 안쪽이다.

| 층 | 내용 | 확인 |
|---|---|---|
| L0 | 이 RFC | 리뷰 |
| L1 | `lib/fleet_stream` 타입·코덱·시험 | 코덱 시험 |
| L2a | `Fleet_stream_hub`(상태, 번호, 구독)와 건강 스냅샷 구간 변환(`Fleet_stream_health_section`). 서버에 연결하지 않는다 | 허브 시험(여러 domain 동시 호출 포함), 변환 시험 |
| L2b | 갱신 루프의 저장 두 함수에서 허브를 부른다 | 연결 시험(저장 두 함수에서 `Snapshot`·`Changed`·`Degraded` 가 나가는지). 실제 서버에서 이벤트 관찰은 L3a 가 배포된 뒤 |
| L3a | SSE 경로 `GET /api/v1/stream/fleet`, 연결 하나를 맡는 `Server_fleet_stream_pump` | pump 시험(큐 상한, 정지 한도, keepalive, 구독 해제) |
| L3b | TUI 쪽 순수 클라이언트 `Masc_tui_fleet_stream` | 클라이언트 시험(번호 건너뜀, 거절, 무작위 허브 조작) |
| L3c | 서버 경로와 클라이언트를 loopback 에서 잇는 시험, 반영 시간 벤치(`bench_fleet_stream`, SSE 와 gRPC) | loopback 시험 5건, 벤치 측정값(§3.4) |
| L4 | TUI 구독(`launch_fleet_stream`), `/health?full=1` 읽기와 옛 디코더 삭제 | 실제 화면 증거(§5) |
| L5 | 키퍼 행 주제 | L4 와 같은 방식 |

## 7. 트레이드오프와 한계

- 스트림은 스캔보다 빨라지지 않는다. 값이 늦게 나오는 만큼(87 ms~5.7초) 늦게 전해진다. 줄어드는 것은 읽는 쪽의 요청 대기, 시간 초과, 화면 상태의 흔들림이다.
- 서버가 값 하나를 메모리에 들고 있다. 작다.
- 한 화면만 옮기므로 TUI 안에 읽기 길이 둘 있게 된다(스트림과 다른 화면의 폴링). 다른 화면은 이 RFC 가 약속하지 않는다.
- 서버와 TUI 의 빌드가 다르면 `schema` 가 다를 수 있다. 이때 화면은 값을 못 그리고 `Schema_mismatch` 를 보인다. 지금처럼 일부 필드를 못 읽고 넘어가는 동작이 없어진다.
- 이 경로가 없는 옛 서버에 새 TUI 를 붙이면 서버가 404 로 답하고, 화면은 `fleet: fleet stream refused with 404` 한 줄을 보이며 2초마다 다시 시도한다(예전 폴링과 같은 빈도다). 폴링으로 되돌아가는 길은 없다(hard cut). 인증이 거절하는 401 과 workspace 가 달라서 거절하는 409 도 같은 줄과 같은 재시도다.
- 값이 같은 무효화를 걸러 내므로, "무언가 바뀌었는데 아직 값이 안 나왔다"는 짧은 구간(스캔 시간)이 화면에 보이지 않는다. `measured_at` 은 마지막 이벤트를 만든 스캔의 시각이다. 같은 값을 읽은 스캔은 이벤트가 없어서, 계속 구독한 클라이언트의 시각은 서버가 가진 가장 최근 스캔 시각보다 오래될 수 있다(새로 연결한 클라이언트가 받는 `Snapshot` 은 서버가 가진 최근 시각이다). 그래서 화면은 이 시각을 쓰지 않고, `Degraded` 의 시작 시각과 끊긴 시각만 보인다.

## 8. 사용자 결정이 필요한 것

1. fleet 다음 주제를 키퍼 행으로 할지, 승인과 ask 로 할지.

타입 정본은 OCaml 모듈이다. proto 를 정본으로 할 이유였던 gRPC 를 고르지 않아서 이 결정은 닫았다. 바꾸려면 알려 달라.

## 부록 A. 재현 명령

```bash
# 크기와 구간
curl -s 'http://127.0.0.1:8935/health?full=1' -o health_full.json
wc -c health_full.json
jq -c 'to_entries | map({k:.key, b:(.value|tojson|length)}) | sort_by(-.b) | .[0:6]' health_full.json

# 캐시 상태 (4초 간격 15번)
curl -s 'http://127.0.0.1:8935/health?full=1' | jq -c '.full_health_snapshot | {status, stale_reason, invalidation_generation, duration_ms}'

# 달라진 항목 수: 구간별 키퍼 배열에서 *_age_seconds 를 뺀 JSON 을 이웃한 스냅샷끼리 비교한다

# JSON 읽기 비용
ocamlfind ocamlopt -package yojson,unix -linkpkg bench_decode.ml -o bench_decode && ./bench_decode health_full.json

# 같은 값을 Snapshot 으로 인코딩한 크기
# lib/fleet_stream 의 세 모듈을 컴파일하고, health 본문(top-level 필드)에 fleet_of_health_fields 를 부른 뒤
# Fleet_stream.encode 한 JSON 문자열의 길이를 잰다. 2026-10-28 15개 스냅샷에서 모두 2,203 B

# TUI 읽기 분포
rg -o 'tui_surface_read_applied request=[0-9]+ started_ns=([0-9]+) applied_ns=([0-9]+)' -r '$1 $2' masc-tui-<pid>.log
```

## 부록 B. SSE 와 gRPC 반영 시간 측정

§2 에서 gRPC 를 고르지 않은 근거다. 재기 전에 적은 규칙, 하네스, 측정, 판정 순서다.

고르는 규칙(재기 전에 적는다). gRPC 를 고르려면 아래를 모두 만족해야 한다. 하나라도 못 하면 SSE 다.

1. 같은 하네스에서 "서버 상태 변경 → TUI 모델 반영" 시간의 p99 가 SSE 이하다(측정 오차 안은 같은 것으로 본다).
2. 느린 구독자(읽기를 30초 멈춘다) 시험에서 번호 건너뜀을 감지해 `Snapshot` 으로 복구한다.
3. 서버 재시작 시험에서 모든 구독자가 `Snapshot` 으로 복구한다.
4. 운영자가 gRPC 서버 경로를 기본으로 켜는 것을 받아들인다. `grpc-direct` 가 README 에서 "Experimental" 로 밝히고 있다는 점도 같이 본다.

하네스는 `test/bench_fleet_stream.ml` 이다(손으로 돌린다). 허브가 바뀐 때부터 읽는 쪽이 그 변경을 반영할 때까지를 잰다. 어느 쪽이든 §3.1~3.3 은 같다.

- SSE: 서버의 accept 루프와 경로의 `serve`(인증만 빼고 서버가 하는 일 전부)를 loopback 에 띄우고, TUI 의 HTTP 클라이언트와 `Masc_tui_fleet_stream` 이 읽는다.
- gRPC: grpc-direct 의 서버 스트리밍 메서드 하나다. 메시지는 필드 1 에 같은 JSON 을 담은 프로토버프 봉투이고(`proto/masc_workspace.proto` 의 `payload_json` 과 같은 모양), 읽는 쪽은 봉투를 벗겨 같은 엄격한 코덱으로 디코딩한다. 코드 생성이 없고, 인증, 연결마다의 상한, keepalive 도 없다. 그래서 가장 싼 gRPC 길이고, 비교가 gRPC 에 유리하게만 틀릴 수 있다.

측정(2026-10-28, 이 Mac, loopback). 서버와 읽는 쪽과 구동기가 한 프로세스, 한 domain 에서 돌아서 읽는 쪽의 파싱이 서버의 쓰기와 같은 CPU 를 쓴다. 이 Mac 은 측정하는 동안 다른 세션의 빌드로 부하 평균이 24~37(16코어)이었다. 한 번 잰 값은 부하에 따라 p99 가 10~30배로 흔들려서(부하 35~55 에서 SSE 300개·5명의 p99 중앙값이 107 ms 였다) 쓰지 않았다. 같은 벤치를 10번 돌리고, 시나리오마다 두 방식을 번갈아 돌렸고, 행마다 최소값(방해가 가장 적었던 한 번)과 중앙값을 적는다. 키퍼 이름은 합성(`keeper-0000`, 11자)이고 변경마다 running 수가 달라진다. p99 는 한 번에 200개(5명이면 1,000개)에서 읽은 값이다.

| 키퍼 | 구독자 | 방식 | 전송 | p50 ms 최소/중앙 | p99 ms 최소/중앙/최대 | 이벤트당 바이트 | 이벤트당 CPU ms(중앙) |
|---|---|---|---|---|---|---|---|
| 40 | 1 | 하나씩 | SSE | 0.19 / 0.21 | 1.46 / 1.73 / 12.2 | 2,338 | 0.17 |
| 40 | 1 | 하나씩 | gRPC | 0.17 / 0.21 | 0.83 / 1.08 / 7.9 | 2,325 | 0.17 |
| 40 | 5 | 하나씩 | SSE | 0.34 / 0.40 | 1.57 / 1.81 / 12.3 | 2,338 | 0.49 |
| 40 | 5 | 하나씩 | gRPC | 0.34 / 0.43 | 1.55 / 1.86 / 6.4 | 2,325 | 0.53 |
| 300 | 1 | 하나씩 | SSE | 0.37 / 0.46 | 1.62 / 2.20 / 7.4 | 13,261 | 0.47 |
| 300 | 1 | 하나씩 | gRPC | 0.33 / 0.41 | 1.72 / 2.53 / 5.2 | 13,248 | 0.48 |
| 300 | 5 | 하나씩 | SSE | 1.11 / 1.35 | 3.34 / 4.42 / 9.6 | 13,261 | 2.13 |
| 300 | 5 | 하나씩 | gRPC | 1.00 / 1.19 | 2.46 / 3.07 / 5.9 | 13,248 | 1.66 |
| 300 | 5 | 16개씩 연달아 | SSE | 13.6 / 17.2 | 26.7 / 35.6 / 63.1 | 13,261 | 2.04 |
| 300 | 5 | 16개씩 연달아 | gRPC | 12.0 / 15.1 | 18.8 / 24.9 / 53.0 | 13,248 | 1.49 |
| 300 | 5(+읽다 멈춘 1) | 하나씩, 2,000개 | SSE | 1.06 / 1.32 | 3.84 / 5.94 / 9.0 | 13,265 | 2.10 |

- 구독자 1명에서는 차이에 일정한 방향이 없다(p50 중앙값 0.21 대 0.21, 0.46 대 0.41 ms. p99 중앙값은 40개에서 1.73 대 1.08, 300개에서 2.20 대 2.53 ms). 5명·키퍼 300개에서는 gRPC 가 낮다(p99 중앙값 3.07 대 4.42 ms, 이벤트당 CPU 1.66 대 2.13 ms). 가장 큰 후보는 읽는 쪽이다. SSE 읽는 쪽은 프레임을 `Sse_wire` 로 한 번 더 읽는다. 이 벤치는 원인을 나누어 재지 않았다.
- 하나씩 쓰는 행에서 두 방식의 p99 중앙값 차이는 1.4 ms 안쪽이다. 연달아 16개를 쓰는 행은 gRPC 가 11 ms 낮다(35.6 대 24.9). 둘 다 스캔이 값을 내는 데 걸리는 87 ms~5.7초(§1.3)보다 작다.
- 읽다 멈춘 구독자가 하나 있어도(26 MB 를 쓰는 동안 커널 버퍼가 찬다) 다른 구독자의 p50 은 같고(중앙값 1.32 대 1.35 ms) p99 는 조금 높다(중앙값 5.94 대 4.42 ms, 최소값 3.84 대 3.34 ms). 최대값은 같은 범위다(9.0 대 9.6 ms). 그 멈춘 연결이 닫히고 읽는 쪽이 복구하는 것은 이 벤치가 아니라 loopback 시험(§5)이 본다. gRPC 에는 이 행이 없다(상한과 닫기를 가진 어댑터가 없다).
- 연달아 16개를 쓰면 뒤쪽 변경이 앞쪽 프레임 뒤에 줄을 서서 p50 이 12~14 ms 가 된다. 1 MB(13 KB × 16 × 5)를 한 프로세스가 인코딩하고 쓰고 읽는 시간이다.
- 구독자당 CPU 는 구독자 수에 비례한다. 서버가 구독자마다 인코딩하는 비용은 300개에서 이벤트당 38 µs, 읽는 쪽의 파싱과 디코딩은 133 µs 다(코덱만 따로 잰 값). 한 번만 인코딩하도록 바꾸면 줄어드는 것은 구독자당 38 µs 이고, 구독자당 약 400 µs 의 10% 쯤이라서 하지 않았다.
- 재현: `dune build ./test/bench_fleet_stream.exe` 뒤 `_build/default/test` 에서 `./bench_fleet_stream.exe` 를 여러 번 돌리고 `uptime` 을 같이 적는다.

### 판정

SSE 로 정했다(2026-10-28).

- 규칙 1: 만족했다. 가장 싼 gRPC 길에서 p99 가 SSE 와 같거나 낮았다. 구독자 1명은 오차 안이고, 5명·300개에서는 3.07 대 4.42 ms 였다. 이득은 하나씩 쓰는 경우 p99 1.4 ms 안쪽, 연달아 쓰는 경우 11 ms 였고, 둘 다 스캔이 값을 내는 데 걸리는 87 ms~5.7초(§1.3)보다 작다.
- 규칙 2·3: SSE 는 만족한다(§5 의 실제 소켓 시험). gRPC 는 큐 상한과 닫기를 가진 어댑터를 만들지 않아서 재지 못했다.
- 규칙 4: 사용자가 gRPC 로 가려고 했고, 어댑터를 설계하며 읽은 아래 사실을 보고 SSE 로 정했다.

gRPC 를 고르지 않은 이유는 코드로 확인한 것이다(grpc-direct 0.2.6, masc 가 고정한 커밋 `d7269eb`).

1. 스트리밍 RPC 를 인증할 길이 없다. grpc-direct 서버의 interceptor 는 단일 호출에만 걸린다. 스트리밍·양방향 호출은 interceptor 도 메타데이터도 받지 않는다(`lib/grpc_eio/server.ml`, 핸들러 타입은 `service.mli`).
2. 연결이 끊겨도 핸들러가 모른다. 서버 스트리밍은 RPC 가 끝나도 핸들러가 돌려준 응답 스트림을 닫지 않는다(`lib/grpc_eio/http2_handler.ml` 의 `handle_server_streaming`).
3. masc 의 gRPC 서버는 2026-08-25 부터 기본이 꺼져 있다(구독자 0·전달 0 이어서). 켜면 127.0.0.1:8936 에 열리고 interceptor 는 로깅 하나이며, `ToolCall` 이 도구를 이름으로 실행한다. 부르는 곳은 키퍼 heartbeat(`call_bidi`) 하나다. 지금 있는 `Subscribe` 는 SSE 버스를 감싼 것이고 구독자 버퍼가 48칸 차면 이벤트를 버린다(`lib/server/masc_grpc_service.ml`).
4. 터널로 붙는 원격 TUI 가 있어서 SSE 는 어차피 남는다. gRPC 를 더하면 한 스트림에 길이 둘이다.

다시 여는 조건: 스트리밍 RPC 의 인증 경로(라이브러리 수정, 또는 masc 리스너의 경로·헤더 판정), 연결 수명을 알려 주는 신호, `ToolCall` 정리가 먼저 있어야 하고, SSE 로 못 하는 소비자가 생겨야 한다.
