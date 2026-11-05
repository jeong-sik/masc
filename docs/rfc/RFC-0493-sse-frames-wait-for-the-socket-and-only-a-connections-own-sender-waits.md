---
rfc: "0493"
title: "SSE frame 은 앞 frame 이 소켓에 닿은 뒤에 보내고, 느린 클라이언트를 기다리는 일은 그 연결의 송신 fiber 만 한다"
status: Draft
created: 2026-11-05
updated: 2026-11-05
author: claude
supersedes: []
superseded_by: null
related: ["0412", "0477"]
---

# RFC-0493: SSE frame 은 소켓에 닿은 뒤에 다음 frame 을 보낸다

- 날짜는 UTC 다.
- 코드는 `origin/main` `ee4dd9d1118` 기준이다.
- 라이브러리 소스는 opam switch `5.5.1` 의 httpun 0.2.0, faraday, gluten-eio, eio 1.3 이다.

## 0. 요약

서버에서 HTTP/1.1 SSE 응답에 frame 을 쓰는 함수는 일곱 개다. 그중 넷은 frame 을 쓰고 `Httpun.Body.Writer.flush` 의 결과를 버린다(`fun _ -> ()`). 이 넷은 클라이언트가 읽지 않아도 바로 성공을 돌려준다. 쓴 바이트는 httpun 쓰기 버퍼에 쌓이고, 그 버퍼에는 상한이 없다(§1.2).

나머지 셋은 flush 를 기다리지만, 같은 코드를 각자 갖고 있다. 그중 artifact draft 스트림은 취소를 막은 채로 기다린다. 그래서 클라이언트가 읽기를 멈추면 그 연결은 끝나지 않는다(§2.3).

결정은 셋이다.

1. SSE 응답은 추상 타입 `Server_sse_response.t` 로만 쓴다. frame 을 쓰는 연산은 `send` 하나다. `send` 는 frame 이 소켓에 닿거나, 연결이 닫히거나, 정한 시간이 지날 때까지 기다린다(§3.1).
2. 느린 클라이언트를 기다리는 것은 그 연결의 송신 fiber 다. 이벤트를 만드는 쪽(producer)은 길이 상한이 있는 queue 에 넣고 바로 돌아간다. queue 가 차면 연결을 닫는다(§3.2).
3. 한 frame 이 `stalled_after_s` 안에 소켓에 닿지 않으면 그 응답을 닫는다. 값은 ping 간격의 세 배인 90초다(§3.3).

## 1. 근거

### 1.1 SSE 쓰기 함수와 부르는 쪽

| 쓰기 함수 | 스트림 | 누가 부르나 | flush 를 기다리나 |
|---|---|---|---|
| `send_raw` `server_mcp_transport_http_conn.ml:252` | MCP GET, AG-UI, presence | 연결마다 drain·ping fiber(`run_sse_pumps` `:287`), 처리 함수의 prime·replay | 아니요 `:260` |
| 같은 `send_raw` | MCP `tools/call` POST | 처리 함수, keepalive fiber(`server_mcp_transport_http.ml:157`) | 아니요 |
| 같은 `send_raw` | MCP `subscriptions/listen` POST | 알림을 내는 쪽. `Mcp_subscriptions.deliver`(`mcp_subscriptions.ml:97`)가 구독마다 차례로 부른다 | 아니요 |
| `keeper_stream_send_raw` `server_routes_http_keeper_stream.ml:1311` | Keeper chat | Keeper 턴의 이벤트를 내는 쪽. `Server_keeper_stream_handoff.publish` 에서 송신 권한을 잡은 producer 가 queue 를 비운다 | 아니요 `:1319` |
| 같은 함수 | Ask follow-up(`:4254`) | 처리 함수 | 아니요 |
| `github_login_stream_send` `server_dashboard_http_keeper_api_post.ml:58` | GitHub 로그인 | 처리 함수 | 아니요 `:61` |
| `send` `server_setup_account_login.ml:94` | 계정 로그인 | 처리 함수 | 아니요 `:98` |
| `send` `server_routes_http_routes_fleet_stream.ml:32` | fleet | 연결마다 pump fiber 하나 | 예 |
| `send` `server_routes_http_routes_artifact_draft_live.ml:31` | artifact draft | 연결마다 draft fiber·ping fiber | 예, 취소를 막은 mutex 안에서 |
| `write_string` `server_routes_http_routes_dashboard.ml:190` | Keeper 실행 출력 | 연결마다 fiber 하나 | 예 |

H2 응답은 이미 flush 를 기다리므로 이 RFC 범위 밖이다. `server_mcp_transport_http.ml:81` 의 `safe_respond_with_string` 은 SSE 가 아니라 한 번에 쓰는 본문이므로 범위 밖이다. 열린 PR #48650 의 로그 스트림은 flush 를 기다리는 넷째 사본(`send_within`)을 더한다.

### 1.2 라이브러리 동작

- `Httpun.Body.Writer.write_string` 은 body 의 Faraday 버퍼에 바이트를 복사하고 바로 돌아온다.
- `Httpun.Body.Writer.flush t k` 는 쓰기 루프가 그때까지 쓴 바이트를 소켓에 넘긴 뒤 `` k `Written `` 를 부른다. 연결이 먼저 닫히면 `` k `Closed `` 를 부른다(`httpun/body.ml:171-178`, `httpun/serialize.ml:160-167`). 콜백은 `writev` 결과를 보고하는 `Faraday.shift` 에서 불린다(`faraday.ml:418`).
- Faraday 는 빈 자리가 모자라면 지금 버퍼를 보낼 목록에 넘기고 새 버퍼를 만든다(`faraday.ml:231-237`). 목록 길이에는 상한이 없다. 그래서 flush 를 기다리지 않는 쓰기는 클라이언트가 읽지 않는 동안 계속 성공하고, 쓴 바이트는 모두 메모리에 남는다.
- 클라이언트가 떠난 것은 그 연결에 쓰기가 실패할 때 드러난다. eio_posix 는 `EPIPE`·`ECONNRESET` 을 `Connection_reset` 예외로 올린다(`eio_posix/err.ml:24`). gluten-eio `writev` 는 `End_of_file` 만 `` `Closed `` 로 바꾸고, 다른 예외는 `report_exn` 으로 보낸다(`gluten_eio.ml:47`, `:169-170`). 읽기 루프가 EOF 를 볼 때도 같은 `report_exn` 을 부른다(`gluten_eio.ml:133-145`).
- httpun 은 스트리밍 중인 응답의 body 를 `force_close` 로 닫고 비우지 않는다(`httpun/reqd.ml:228-230`). 그래서 기다리던 flush 콜백은 불리지 않는다. 그 뒤로 `Body.Writer.is_closed` 는 `true` 다.
- `Body.Writer.close` 도 body 를 비우지 않는다(`httpun/body.ml:189-193`). 서버가 응답을 닫아도 기다리던 flush 콜백은 불리지 않는다.
- gluten-eio 는 연결마다 읽기 루프와 쓰기 루프를 `Fiber.both` 로 따로 돌린다(`gluten_eio.ml:90-171`). 처리 함수는 읽기 루프 안에서 불린다. 처리 함수가 flush 를 기다리는 동안에도 쓰기 루프는 돈다. 그래서 처리 함수 안에서 기다려도 서로 막히지 않는다.
- `Eio.Mutex.use_rw ~protect:true` 는 임계 구역을 `Cancel.protect` 로 감싼다(`eio_mutex.mli:24-30`). 그 안에서 기다리는 fiber 는 취소되지 않는다.

### 1.3 라이브 로그

남아 있는 시스템 로그(2026-10-29~11-05, 8일, `~/me/.masc/logs/system_log_*.jsonl`)를 셌다.

| 로그 문장 | 건수 | 날짜 |
|---|---|---|
| `Fleet stream closed: the client accepted no frame for 90 seconds` | 3 | 11-01, 11-02, 11-03 하루 1건 |
| `Fleet stream closed: the client was … events behind` | 0 | |
| MCP `stream full (… ) — disconnecting` | 0 | |

flush 를 기다리는 fleet 스트림은 읽지 않는 클라이언트를 8일 동안 세 번 닫았다. 같은 기간 MCP 스트림에서는 queue 가 찬 일이 없다. MCP drain fiber 는 쓰기가 바로 끝나므로 queue 에서 바로 다음 이벤트를 꺼낸다. 그래서 클라이언트가 읽지 않아도 queue 는 차지 않는다(§2.1). 이 0건이 MCP 클라이언트가 늘 읽었다는 뜻인지, 바이트가 Faraday 에 쌓였다는 뜻인지는 지금 로그로 가를 수 없다. 이 RFC 는 그 차이를 세지 않았다.

### 1.4 Keeper chat 이벤트 빈도

`~/me/.masc/keeper_chat_events/` 에서 2026-10-29 뒤에 바뀐 journal 2,274개(operation 하나에 파일 하나)를 읽었다. 각 operation 에서 같은 시간 창 안에 들어온 이벤트 수의 최댓값을 journal 행의 `ts` 로 셌다(2026-11-05 측정).

| 창 | p50 | p99 | p99.9 | 최대 |
|---|---|---|---|---|
| 1초 | 292 | 1,480 | 2,162 | 2,616 |
| 5초 | 416 | 1,891 | 2,845 | 3,190 |
| 30초 | 503 | 4,454 | 5,939 | 6,496 |
| 90초 | 607 | 8,447 | 12,712 | 14,162 |

## 2. 지금 코드

### 2.1 MCP 스트림의 queue 상한이 일하지 않는다

`Sse` 는 클라이언트마다 상한이 있는 queue(`stream_capacity`, 기본 256)를 둔다. queue 가 차면 그 세션을 끊는다(`sse.ml:1064`). 끊긴 클라이언트는 `Last-Event-Id` 로 다시 붙는다. 이 규칙은 느린 클라이언트를 잡으려고 있다.

drain fiber 는 `send_raw` 로 frame 을 쓴다. `send_raw` 는 flush 를 기다리지 않으므로 바로 돌아온다. 그러면 drain fiber 는 queue 에서 다음 이벤트를 바로 꺼낸다. 읽지 않는 클라이언트의 이벤트는 queue 대신 Faraday 에 쌓인다. 그래서 queue 상한은 이 경우에 일하지 않는다.

### 2.2 producer 가 직접 보내는 스트림 둘

Keeper chat 스트림에서는 Keeper 턴의 이벤트를 낸 쪽이 직접 보낸다. `Server_keeper_stream_handoff.publish` 에서 송신 권한을 잡은 producer 가 handoff queue 를 비운다. 다른 producer 는 그 queue 에 넣고 돌아간다. handoff queue 에는 상한이 없다.

MCP `subscriptions/listen` 에서는 `Mcp_subscriptions.deliver` 가 알림을 구독마다 차례로 보낸다. 구독마다 `send_mutex` 를 잡은 채로 `send` 를 부른다.

이 두 곳의 `send` 가 flush 를 기다리면, 느린 클라이언트 하나가 Keeper 턴이나 다른 구독의 알림을 막는다. 그래서 이 둘은 쓰기 함수만 바꿔서는 안 되고, 송신을 연결 전용 fiber 로 옮겨야 한다.

Keeper chat 의 live sink 는 Keeper 턴의 adapter fiber 가 부른다(`server_routes_http_keeper_stream.ml:3229-3262`). `MASC_SERVING_DOMAIN_ENABLED=true` 면 HTTP 연결은 따로 둔 domain 에서 돈다(`server_runtime_bootstrap.ml:2157-2174`). 그러면 이 fiber 는 연결과 다른 domain 에서 httpun writer 에 쓴다. httpun writer 는 domain 사이에서 안전하지 않다. 송신을 연결 전용 fiber 로 옮기면 이 쓰기도 없어진다.

### 2.3 artifact draft 스트림은 끝나지 않을 수 있다

`server_routes_http_routes_artifact_draft_live.ml:31` 의 `send` 는 `Eio.Mutex.use_rw ~protect:true` 안에서 flush 를 기다린다. 클라이언트가 읽기를 멈추면 draft fiber 는 그 안에서 멈춘다. 취소도 닿지 않는다(§1.2). ping fiber 는 같은 mutex 를 기다린다. 연결을 닫는 `request_close` 는 `send` 가 돌아와야 불린다. 그래서 이 연결은 끝나지 않고, `Live.leave` 도 불리지 않는다.

### 2.4 같은 기다림이 세 벌이다

fleet, artifact draft, Keeper 실행 출력은 같은 일을 각자 쓴다. `write_string` 을 하고, promise 를 만들고, `flush` 콜백에서 그 promise 를 풀고, 기다린다. 세 벌은 mutex 위치와 닫는 방법이 서로 다르다. #48650 이 넷째 벌을 더한다.

## 3. 결정

### 3.1 SSE 응답은 `Server_sse_response.t` 로만 쓴다

`lib/server/server_sse_response.ml` 이 HTTP/1.1 SSE 응답 하나를 맡는다.

```ocaml
type t

type outcome =
  | Written  (** frame 이 소켓에 닿았다. *)
  | Closed   (** frame 이 소켓에 닿기 전에 응답이 닫혔다. *)
  | Stalled  (** [stalled_after_s] 안에 닿지 않아서 응답을 닫았다. *)

val respond :
  clock:_ Eio.Time.clock ->
  stalled_after_s:float ->
  ?flush_headers_immediately:bool ->
  Httpun.Reqd.t -> Httpun.Response.t -> t

val send : t -> string -> outcome
val finish : t -> string -> unit
val close : t -> unit
val is_closed : t -> bool
```

- `send` 는 frame 전체를 쓰고 flush 콜백을 건다. 그 사이에 멈추는 곳이 없어서, 같은 domain 의 다른 fiber 가 보낸 frame 이 끼어들지 않는다.
- 응답은 연결을 돌리는 domain 에서만 쓴다. httpun writer 는 domain 사이에서 안전하지 않고, 연결의 쓰기 루프는 이 모듈의 lock 없이 writer 를 쓴다. 그래서 mutex 를 두지 않는다.
- `send` 는 flush 콜백, 응답의 닫힘, 시간 끝 가운데 먼저 오는 것을 기다린다. httpun 의 `close` 는 기다리는 flush 에 답하지 않으므로(§1.2), 이 모듈의 `close` 가 기다리는 `send` 를 모두 `Closed` 로 깨운다. 기다리는 fiber 는 취소할 수 있다.
- `send` 는 `Watched_work.run` 으로 시간을 잰다. frame 이 닿는 것과 시간이 끝나는 것이 같은 scheduler 차례에 겹치면 닿은 쪽(`Written`)이 이긴다.
- `Written` 이 아닌 결과를 돌려주기 전에 응답을 닫는다. 그 뒤의 `send` 는 쓰지 않고 `Closed` 를 돌려주고, `is_closed` 는 `true` 다.
- 클라이언트가 떠난 뒤 기다리던 frame 은 flush 콜백을 받지 못하고 `Stalled` 로 끝난다(§1.2). 그 뒤의 `send` 는 `is_closed` 를 보고 바로 `Closed` 를 돌려주고, 같은 응답에서 기다리던 다른 `send` 도 깨운다.
- `Stalled` 는 요청 경로와 함께 경고 로그 한 줄을 남긴다. 스트림마다 따로 남기지 않는다. 배포 뒤 측정(§6)은 이 줄을 센다.
- 보내는 fiber 는 자기 frame 이 닿을 때까지 다음 frame 을 쓰지 않는다. 그래서 읽지 않는 클라이언트 하나에 서버가 쥐는 바이트는 보내는 fiber 마다 frame 하나다.
- `stalled_after_s` 값은 `Server_mcp_transport_http_headers.sse_stalled_after_s` 하나다. ping 간격 `sse_ping_interval_s` 와 같은 곳에 둔다. `observer_idle_timeout_ms` 도 이 값에서 얻는다.
- `?flush_headers_immediately` 는 fleet route 를 옮기는 3층에서, `finish` 는 MCP eviction 을 옮기는 5층에서 더한다. 2층에서 옮기는 다섯 곳은 둘 다 쓰지 않는다.
- `finish` 는 마지막 frame 을 쓰고 바로 닫는다. 기다리지 않는다. 닫은 뒤에는 더 쓸 수 없으므로, 쌓이는 양은 그 frame 하나다. MCP eviction frame(`server_mcp_transport_http_conn.ml` `stop_sse_session_evict`)처럼, 다른 세션의 처리 함수가 이 연결의 느린 클라이언트를 기다리면 안 되는 곳에 쓴다.
- `t` 는 추상 타입이다. 이 모듈 밖에서는 `Httpun.Body.Writer.t` 를 꺼낼 수 없다. 그래서 flush 를 기다리지 않고 쓰는 코드는 이 타입으로는 쓸 수 없다.

`Watched_work.run` 이 시간을 재는 곳은 이 모듈과 pump(§3.2) 둘이 아니라 이 모듈 하나다. pump 는 `send` 의 `outcome` 을 받아서 끝낼지 정한다.

### 3.2 느린 클라이언트를 기다리는 것은 연결의 송신 fiber 다

`Server_fleet_stream_pump` 를 이벤트 타입에 대해 일반화해 `Server_sse_pump` 로 바꾼다.

```ocaml
type ending = Client_gone | Fell_behind | Stalled | Finished

type step =
  | Skip               (** 이 이벤트는 쓰지 않는다. *)
  | Send of string     (** frame 을 쓰고 이어 간다. *)
  | Send_last of string  (** frame 을 쓰고 끝낸다. *)
  | Stop               (** 쓰지 않고 끝낸다. *)

type idle =
  | Keepalive  (** keepalive 주석을 쓴다. *)
  | Quiet      (** 쓰지 않고 다음 간격을 기다린다. *)
  | Finish     (** 쓰지 않고 끝낸다. *)

module Queue : sig
  type 'event t
  val create : max_queued_events:int -> 'event t
  val push : 'event t -> 'event -> unit
end

val run :
  queue:'event Queue.t ->
  step:('event -> step) ->
  idle:(unit -> idle) ->
  clock:_ Eio.Time.clock ->
  ping_interval_s:float ->
  send:(string -> Server_sse_response.outcome) ->
  ending
```

- producer 는 `Queue.push` 로 넣고 바로 돌아간다. 자리는 `Atomic` 카운터로 예약한다. 그래서 여러 producer 가 여러 domain 에서 동시에 넣어도 `Eio.Stream.add` 가 기다리지 않는다. 자리가 없으면 뒤처짐만 표시한다.
- 송신 fiber 하나가 queue 에서 꺼내 `step` 에 따라 쓴다. ping 간격 동안 이벤트가 없으면 `idle` 에 따라 쓴다.
- `send` 가 `Closed` 면 `Client_gone`, `Stalled` 면 `Stalled` 로 끝난다. `Send_last` 를 쓰거나, `step` 이 `Stop` 이거나, `idle` 이 `Finish` 면 `Finished` 로 끝난다.
- `stalled_after_s` 는 `Server_sse_response.respond` 가 받는다. pump 는 `send` 의 시간을 재지 않는다.
- 구독은 route 가 맡는다. route 는 queue 를 만들고 `Queue.push` 로 구독한 뒤 구독 해제를 switch 에 건다. 그다음 앞서 보낼 frame 을 같은 fiber 에서 `send` 하고 `run` 을 부른다. 그동안 들어온 이벤트는 queue 에서 기다린다.
- fleet 과 MCP listen 의 `step` 은 늘 `Send`, `idle` 은 늘 `Keepalive` 다.

이 pump 를 쓰는 곳은 셋이다.

| 스트림 | `subscribe` | `Fell_behind` 뒤 클라이언트가 하는 일 |
|---|---|---|
| fleet | `Fleet_stream_hub.subscribe`(지금과 같다) | 다시 붙어서 `Snapshot` 을 받는다(RFC-0477) |
| Keeper chat | `register_operation_live_sink` | `since_seq` 로 다시 붙어서 journal replay 를 받는다(RFC-0412 §3.2) |
| MCP `subscriptions/listen` | `Mcp_subscriptions.register_after_ack` 의 `send` 가 `on_event` 다 | 다시 구독한다. `tools/list_changed` 와 `resources/updated` 는 바뀌었다는 신호만 싣고 내용은 싣지 않는다. 놓친 알림은 클라이언트가 목록과 resource 를 다시 읽어야 메워진다. 클라이언트가 다시 구독한 뒤 다시 읽는지는 확인 필요 |

Keeper chat 에서는 acceptance frame 과 replay frame 을 송신 fiber 가 `run` 을 부르기 전에 같은 fiber 에서 보낸다. 그동안 들어온 live 이벤트는 queue 에서 기다린다. `Server_keeper_stream_handoff` 는 이 순서를 지키려고 있었으므로 지운다. replay 가 이미 쓴 seq 의 live 이벤트는 `Skip`, `Run_finished`·`Run_error` 는 `Send_last` 다. replay 가 끝나면 송신 fiber 가 queue 에 두 가지를 넣는다. operation 기록에만 있는 terminal 은 `Send_last` 가 되고, operation 이 이미 끝났거나 replay 가 terminal 을 썼다는 표시는 `Stop` 이 된다. 둘 다 replay 동안 들어온 live 이벤트 뒤에 선다. 그래서 지금처럼 쌓인 live 이벤트를 먼저 보내고 끝낸다. queue 가 차서 닫힌 클라이언트는 `since_seq` 로 journal 에 있는 이벤트를 다시 받는다. journal 쓰기가 실패한 이벤트는 journal 에 없으므로 돌아오지 않는다. 지금은 queue 에 상한이 없어서 이런 이벤트도 남는다. 메모리 상한을 두는 대가로 이 손실을 받는다. `idle` 은 지금 heartbeat 처럼 operation 기록을 읽고 `Keepalive`(아직 도는 중), `Finish`(terminal 없이 끝남), `Quiet`(기록을 읽지 못함)를 고른다.

`Mcp_subscriptions` 는 `masc_transport_protocol` 라이브러리에 있다. 이 라이브러리는 바꾸지 않는다. transport 가 넘기는 `send` 는 queue 에 넣고 바로 돌아온다. pump 가 이미 끝났으면 `false` 를 돌려주고, `deliver` 는 그 구독을 지운다. 그래서 `deliver` 는 느린 구독을 기다리지 않는다.

MCP GET·AG-UI·presence 스트림은 이미 `Sse` 의 queue 와 drain fiber 를 갖고 있다. 이 셋은 pump 로 옮기지 않는다. drain fiber 와 ping fiber 의 `send_raw` 가 `Server_sse_response.send` 를 쓰면, `sse.ml:1064` 의 queue 상한이 일하기 시작한다.

### 3.3 한 frame 은 90초 안에 닿아야 한다

`stalled_after_s` 는 `sse_ping_interval_s`(30초)의 세 배인 90초다. fleet 스트림이 지금 쓰는 값이다(`server_routes_http_routes_fleet_stream.ml:7-8`). 읽는 클라이언트는 frame 을 바로 받는다. ping 세 번 동안 frame 하나를 받지 않은 클라이언트는 읽기를 멈췄거나, 연결이 반쯤 끊긴 것이다.

`Stalled` 로 응답을 닫아도 소켓은 커널의 TCP 시간 제한까지 남을 수 있다. 쓰기 루프가 `writev` 에서 기다리기 때문이다. 이때 남는 것은 그 응답에 이미 쓴 frame 하나와 커널 버퍼다. queue 와 구독은 바로 풀린다.

## 4. 검토한 대안

- **바이트 상한을 두고 넘으면 닫는다.** `Faraday.pending_bytes` 를 보고 끊는 방법이다. 쌓이는 양에 상한은 생기지만 쌓이는 것은 그대로다. producer 가 느린 클라이언트를 모르는 것도 그대로다. 받지 않는다.
- **producer 가 직접 flush 를 기다린다.** Keeper chat 에서 느린 TUI 하나가 Keeper 턴을 멈춘다. `subscriptions/listen` 에서는 느린 구독 하나가 뒤의 구독을 모두 멈춘다(§2.2). 받지 않는다.
- **송신 fiber 의 queue 에 상한을 두지 않는다.** 쌓이는 곳이 Faraday 에서 queue 로 옮겨질 뿐이다. 받지 않는다.
- **기다리는 동안 `is_closed` 를 주기적으로 읽는다.** 클라이언트가 떠난 것을 90초보다 빨리 알 수 있다. 하지만 httpun 이 닫힘을 알리지 않는 것을 폴링으로 메우는 일이다. 받지 않는다. 근본 해결은 httpun 이 실패한 연결의 스트리밍 body 를 비워서 기다리는 flush 에 `` `Closed `` 로 답하는 것이다(§1.2). httpun 을 고치는 일은 이 저장소 밖이라 이 RFC 에서 하지 않는다.
- **Keeper chat 이 자기 송신 루프를 따로 갖는다.** pump 에 `step`·`idle` 을 더하지 않아도 된다. 하지만 이벤트와 keepalive 가 같은 차례에 오면 이벤트를 쓰는 규칙과, 뒤처짐을 `send` 가 돌아온 뒤에만 보는 규칙을 두 곳에서 지켜야 한다. 받지 않는다.
- **route 마다 기다림을 각자 쓴다.** 지금 세 벌이 이미 서로 다르고, 그중 하나는 끝나지 않는다(§2.3). 받지 않는다.

## 5. 영향

- 읽지 않는 클라이언트 하나에 서버가 쥐는 메모리는 queue 상한과, 보내는 fiber 마다 frame 하나로 묶인다. 지금 flush 를 기다리지 않는 네 함수에서는 상한이 없다.
- MCP GET 스트림에서 읽지 않는 클라이언트는 queue 가 차면 끊기고 `Last-Event-Id` 로 다시 붙는다. 지금은 끊기지 않는다.
- Keeper chat 스트림에서 TUI 가 queue 상한만큼 뒤처지면 스트림이 닫히고, TUI 는 `since_seq` 로 다시 붙는다. Keeper 턴은 TUI 를 기다리지 않는다. 지금도 기다리지 않지만, 그 대가로 handoff queue 와 Faraday 가 상한 없이 자란다.
- 로그인 스트림과 Ask follow-up 은 처리 함수 안에서 기다린다. 브라우저가 90초 동안 읽지 않으면 스트림이 닫힌다. 로그인은 `is_closed` 로 그것을 보고 끝난다.
- artifact draft 스트림은 읽지 않는 클라이언트를 90초 뒤에 닫고 `Live.leave` 를 부른다.

## 6. 검증

- `Server_sse_response` 시험은 loopback 소켓으로 한다. 클라이언트가 읽지 않으면 `send` 가 돌아오지 않는다. 그동안 서버가 쥔 바이트가 frame 하나보다 많지 않다. `stalled_after_s` 가 지나면 `Stalled` 다. 클라이언트가 떠나면 기다리던 frame 은 `Stalled` 이고 응답은 닫힌다. `close` 는 기다리는 `send` 를 모두 `Closed` 로 끝낸다. 닿는 것과 시간이 같은 차례에 오면 `Written` 인 것은 메모리 위 httpun 연결로 쓰기 답을 손으로 줘서 본다.
- 지금 코드에 같은 시험을 돌리면, 읽지 않는 클라이언트에게 `send_raw` 가 계속 `true` 를 돌려주고 쥔 바이트가 frame 수에 비례해서 늘어야 한다. 이 시험이 지금 코드에서 실패하는 것을 PR 본문에 적는다.
- `Server_sse_pump` 시험은 지금 `test/test_fleet_stream_pump.ml` 의 경우를 이벤트 타입만 바꿔서 지킨다. `Skip`·`Send_last`·`Quiet`·`Finish` 를 더 잰다. 여러 domain 의 producer 가 동시에 넣어도 `push` 가 기다리지 않는다.
- Keeper chat 시험: 느린 송신 중에 producer 가 sink 를 부르면 바로 돌아온다. queue 가 차면 스트림이 닫힌다. acceptance, replay, live 순서가 지금과 같다.
- 배포 뒤 시스템 로그에서 MCP `stream full` 과 각 스트림의 `Stalled` 건수를 센다.

## 7. 층

1. 이 RFC.
2. `Server_sse_response` 를 만들고 artifact draft, Keeper 실행 출력, 로그인 둘, Ask follow-up 을 옮긴다.
3. `Server_fleet_stream_pump` 를 `Server_sse_pump` 로 일반화한다. fleet route 를 `Server_sse_response` 로 옮기고, pump 가 `send` 의 시간을 재던 `Watched_work` 를 지운다. 한 frame 의 시간을 두 곳에서 재지 않도록 fleet 은 이 층에서 한 번에 옮긴다.
4a. pump 가 `Queue.t` 를 받고 `step`·`idle` 로 쓰고 끝낼 것을 정하게 바꾼다. 구독은 fleet route 로 옮긴다. fleet 의 동작은 같다.
4b. Keeper chat 스트림을 pump 로 옮기고 `Server_keeper_stream_handoff` 를 지운다. queue 상한은 4,096 이다. 1초 창 최댓값 2,616(§1.4)을 담는 가장 작은 2의 거듭제곱이다. 읽는 클라이언트가 1초 동안 frame 을 받지 못해도 끊기지 않는다. 그보다 오래 멈춘 클라이언트는 `since_seq` 로 다시 붙어 journal replay 를 받는다.
5a. HTTP/1.1 MCP `subscriptions/listen` 을 pump 로 옮긴다. queue 상한은 MCP GET 스트림과 같은 `Sse.stream_capacity` 다.
5b. `send_raw` 와 eviction frame 을 `Server_sse_response` 로 바꾼다. eviction frame 은 HTTP 처리 함수가 쓴다(`server_mcp_transport_http.ml`, `server_mcp_transport_http_agui.ml`). 연결을 닫는 쪽은 다른 domain 에서도 온다. `Sse` queue 상한을 넘은 세션을 끊는 hook(`sse.ml:1064`), 유지보수 fiber(`server_bootstrap_maintenance.ml`), 서버 종료(`bin/main_eio.ml`)다. 지금은 `close_sse_conn` 이 `info.mutex` 를 잡고 writer 를 닫는다. 이 층은 그 닫기를 연결의 fiber 로 옮기는 설계를 먼저 적는다.

#48650 이 먼저 병합되면 2층에서 로그 스트림의 `send_within` 도 옮긴다. 이 RFC 가 먼저면 #48650 이 `Server_sse_response` 를 쓴다.
