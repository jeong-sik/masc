---
rfc: "0107"
phase: D
status: Active
created: 2026-05-17
updated: 2026-05-18
supplement_of: RFC-0107
implementation_prs: [15950, 15965, 15985, 15990, 16017, 15993]
# Excluded (design-spec doc merge): #15941 Phase D.1
---

# RFC-0107 Phase D — Connection pool design (interface-first)

본 문서는 Phase D 의 *interface-first design* 단계 산출물이다. 구현은
Phase B (HTTP transport spike) 의 결정 후 이 interface 위에 transport
binding 을 채워 넣는다. Interface 자체는 transport-agnostic 으로
설계해서 `piaf` 와 `cohttp-eio + manual patch` 사이의 선택이 바뀌어도
callsite 변경이 없도록 한다.

## 1. Callsite inventory (masc 내부)

`Cohttp_eio.Client.*` 직접 호출 (5 callsites — *3 in masc_http_client 본
체, 2 in voice_bridge*):

| 파일:라인 | 호출 | 형태 |
|---|---|---|
| `lib/masc_http_client/masc_http_client.ml:70` | `Cohttp_eio.Client.make_generic connect` | factory (in module) |
| `lib/masc_http_client/masc_http_client.ml:118` | `Cohttp_eio.Client.post client ~sw uri ...` | per-call |
| `lib/masc_http_client/masc_http_client.ml:156` | `Cohttp_eio.Client.get client ~sw ~headers uri` | per-call |
| `lib/voice/voice_bridge.ml:461` | `Cohttp_eio.Client.post ~sw ~body ~headers client uri` | shared client |
| `lib/voice/voice_bridge.ml:701, 990` | `Cohttp_eio.Client.get ~sw:inner_sw client uri` | shared client |

`Masc_http_client.*` 간접 호출 (8 callsites):

| 파일:라인 | API |
|---|---|
| `lib/server/server_dashboard_http_link_preview.ml:350` | `get_response_sync` |
| `lib/local/worker_container_types.ml:184` | `post_sync` |
| `lib/voice/voice_bridge_core.ml:118` | `make_closing_client` |
| `lib/auto_responder.ml:226` | `post_sync` |
| `lib/runtime/runtime_http_probe.ml:154` | `get_sync` |
| `lib/graphql_client.ml:181` | `post_sync` |
| `lib/opentelemetry_client_cohttp_eio.ml:147` | `make_closing_client` |

**합계: 13 callsites** in masc. (OAS 별도 repo 는 본 Phase 범위 외.)

## 2. Current anti-pattern (per call, 모든 sync 호출자 동일)

```ocaml
Eio.Switch.run @@ fun sw ->
let client = make_closing_client ~sw ~net ~https in    (* (1) new client *)
let hdr = Cohttp.Header.of_list (("connection", "close") :: headers) in  (* (2) force close *)
let resp, resp_body = Cohttp_eio.Client.get client ~sw ~headers:hdr uri in
(* (3) manual flow tracking via on_release *)
(* (4) switch exit closes the socket — no reuse *)
```

문제:
- **(1)** 매 호출 새 TCP/TLS handshake → latency + FD spike
- **(2)** `connection: close` 강제 → keep-alive 0 건
- **(3)** `tracked_flows` ref + `on_release` callback — workaround
  for cohttp-eio 6.1.1 socket-not-closed bug (`masc_http_client.ml:13`
  주석)
- **(4)** Fresh switch per call — pool 자체가 attach 할 long-lived
  switch 없음

(3) 은 Phase C.1 의 turn-scoped switch 가 wiring 된 *이후*에도 여전히
필요한데 — Phase D 의 pool 이 자체 long-lived switch (server root_sw)
에 attach 하면 wrapper 의 (3) 은 사라진다 (pool 이 reuse 하므로
release 시 close 하지 않음).

## 3. Pool design (transport-agnostic interface)

핵심 결정: **opaque `Pool.t`** + scoped `request` API.
`acquire`/`release` 같은 명시적 lifetime API 는 노출하지 않는다.
근거: callsite 가 acquire 후 잊으면 leak. `request` 는 pool 내부에서
borrow/release 를 닫아 caller 가 release 를 잊을 수 없게 한다.

### 3.1 interface shape

```ocaml
(* lib/masc_http_client/pool.mli — Phase D design draft *)

type t
(** Opaque per-process connection pool. Attaches to a long-lived
    Eio.Switch (typically server root_sw via Eio_context). Pool itself
    survives turn boundaries; *per-host* connection state evicts on
    idle_ttl. *)

type config = {
  max_idle_per_host : int;
  max_total_idle    : int;
  idle_ttl_seconds  : float;
  connect_timeout_seconds : float;
}

val default_config : config
(** Conservative defaults derived from RFC-0101 §2 nofile cap (10240):
    - max_idle_per_host = 8
    - max_total_idle    = 256   (= 10240 * 0.025, well under cap)
    - idle_ttl_seconds  = 60.0
    - connect_timeout_seconds = 5.0 *)

val create :
  sw:Eio.Switch.t ->
  net:[> `Generic ] Eio.Net.ty Eio.Resource.t ->
  ?https:(Uri.t ->
          [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t ->
          [ `Close | `Flow | `R | `Shutdown | `Tls | `W ] Eio.Resource.t) ->
  ?config:config ->
  unit ->
  t
(** Initialize the pool on a long-lived switch (server root_sw). The pool
    closes idle connections when [sw] closes; in-flight requests outlive
    pool cleanup via per-call sub-switches. *)

(* ── Request API ─────────────────────────────────────────────────────── *)

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}
(** Mirrors current [Masc_http_client.response]. *)

val request :
  t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?timeout_seconds:float ->
  method_:[ `GET | `POST | `PUT | `DELETE | `HEAD | `PATCH ] ->
  url:string ->
  ?headers:(string * string) list ->
  ?body:string ->
  unit ->
  (response, string) result
(** High-level scoped call. Acquires a connection from the per-host pool
    (or creates one if the pool is empty / under max_idle_per_host),
    issues the request, releases the connection back to the pool for
    keep-alive reuse, and returns the typed response. Pool semantics:

    - Same scheme+host+port → same pool slot, connection reused.
    - Connection acquired but no slot available within max_idle_per_host
      → creates a fresh transient connection that is *closed on release*
      instead of returned.
    - idle_ttl_seconds expired → connection evicted before reuse,
      replaced by a fresh handshake.
    - connection error during reuse → caller sees Error; pool drops
      that connection and surfaces the error (no silent retry — caller
      decides). *)

(* No low-level streaming borrow API is exposed until the concrete handle
   type is specified. A public callback with [unit -> 'a] cannot support
   streaming and must not ship as a stub. *)

(* ── Telemetry ──────────────────────────────────────────────────────── *)

type stats = {
  idle_per_host : (string * int) list;   (* host -> idle count *)
  total_idle : int;
  total_inflight : int;
  reuse_count_total : int;
  evict_count_total : int;
  create_count_total : int;
}

val stats : t -> stats
(** Non-mutating snapshot for legacy metrics backend exporter / dashboard. *)
```

### 3.2 Migration shim — Masc_http_client unchanged

`Masc_http_client.{post_sync,get_sync,get_response_sync}` 는
*signature 그대로* 유지하되 내부적으로 process-wide singleton
`Pool.t` 를 lazy 생성하여 `Pool.request` 로 위임. 13 callsites 코드
변경 0. 점진적으로 callsite 가 `Pool.request` 로 직접 마이그레이션
가능.

```ocaml
let pool : Pool.t Lazy.t = lazy (
  let sw = Eio_context.get_switch_opt ()  (* server root_sw 가져오기 *)
           |> Option.get_exn_or "Masc_http_client: Eio_context not initialized" in
  let net = Eio_context.get_net_opt () |> Option.get_exn_or "net not init" in
  let https = Eio_context.get_https_connector_result () |> Result.get_or in
  Pool.create ~sw ~net ~https ()
)

let post_sync ?clock ?timeout_sec ~net:_ ?(https=None)
              ~url ~headers ~body () =
  let _ = https in  (* connector now lives in pool *)
  Pool.request (Lazy.force pool)
    ?clock ?timeout_seconds:timeout_sec
    ~method_:`POST ~url ~headers ~body ()
  |> Result.map (fun {Pool.status; body; _} -> (status, body))
```

cohttp-eio 의 socket-not-closed bug 는 pool 안에서 *reuse* 되므로 무관
해진다. release 시 close 안 함. 만약 connection 이 error 상태면 그때
명시적 close (drop from pool).

### 3.3 Switch hierarchy — Phase C.1 와의 결합

Phase C.1 이 wiring 한 `with_turn_switch` 와의 관계:

- **Pool 자체**: `Pool.create ~sw:root_sw` — 서버 lifetime. idle
  connection 이 turn boundary 를 가로질러 살아남는다.
- **Per-request fiber**: `Pool.request` 내부에서 short-lived sub-switch
  를 열어 fiber spawn 한다. sub-switch 가 turn_sw (있으면) 또는
  root_sw (없으면) 의 child. 자동.
- **In-flight cancellation**: turn_sw 가 닫히면 (turn end /
  cancellation) sub-switch 도 닫혀 in-flight request 가 취소된다.
  Connection 자체는 pool 의 root_sw 에 attach 되어 idle 로 돌아간다.
- **idle_ttl eviction**: pool 의 background fiber 가 idle 통계 모니터.
  pool 의 root_sw 에 attach.

### 3.4 4-axis 측정 (Phase B spike 결과와 연결)

본 interface 위에 piaf 와 cohttp-eio-patched 두 구현을 plug-in 가능.
Phase B 의 4-axis bench (fd-peak, RPS, TLS handshake count, switch-clean
exit) 가 *동일 interface* 위에서 비교 → 결과를 RFC §3.1 에 인용 →
Phase D step 2 가 그 결정 위에 구현.

## 4. Phase D 단계

| Step | Scope | Dependencies | LoC estimate |
|---|---|---|---|
| **D.1 (이 PR)** | interface design + skeleton mli + design 노트 | Phase C.1 머지 | ~150 (mli + 노트) |
| **D.2** | piaf wrapper or cohttp patched 구현 + 13 callsite migration (shim 유지) | D.1 + Phase B 결과 | ~400 |
| **D.3** | stream callsite migration (voice_bridge 2개) | D.2 | ~80 |
| **D.4** | legacy metrics backend export + dashboard tile | D.2 | ~120 |
| **D.5** | runtime-storm reproducer (16 keepers × 5 turn) — fd 평탄 검증 | D.2 + D.4 | ~150 |

## 5. Trade-offs & open questions

| 항목 | 결정 또는 open |
|---|---|
| acquire/release vs scoped API | **scoped `request` only** — leak resistant; streaming borrow API requires a concrete handle type before exposure |
| Pool lifetime | **server root_sw** — pool 자체는 process-lifetime |
| connection error 시 retry | **caller 결정** (pool 은 connection drop 만 함) — silent retry 는 N-of-M anti-pattern 위험 |
| per-host TLS context cache | piaf 가 이미 함 (Phase B 확인) — cohttp 직접 구현 시 우리가 더해야 함 |
| HTTP/2 지원 | **out-of-scope** (RFC §2 non-goal). piaf 는 무료로 받지만 callsite 가 h1 가정 |
| max_idle_per_host = 8 정당화 | RFC-0101 §2 nofile=10240 cap, 256 server slots × 8 idle = 2048, safe |
| OAS repo 마이그레이션 | **out-of-scope of Phase D**. masc 13 callsites 만. OAS 는 동등 interface 후속 PR |

## 6. 검증

- D.2 의 runtime-storm reproducer: 16 keepers × 5 turn, `lsof -p <pid>`
  peak measurement. RFC-0101 throttle 비활성화 상태에서 < 256 FD peak
  목표.
- D.3 voice_bridge stream callsite: 기존 streaming behavior 유지
  (수동 read_chunks loop) + connection 재사용 확인.
- D.5 30-day production sample (Phase F retirement gate 의 입력).

## 7. Anti-patterns 명시적 거부

본 design 은 RFC-0107 §"Anti-prior-art" 와 정합:
- **자체 connection pool 재구현 (X)** — piaf 가 이미 구현. cohttp
  fork 경로 시에도 piaf 의 pool 모듈 reference.
- **자체 Switch 추상화 wrapper (X)** — Phase C.1 의 `with_turn_switch`
  로 충분. pool 은 그 위에 binding 안 들고 직접 Eio.Switch 사용.
- **자체 FD 회계 시스템 (X)** — RFC-0101 의 `Fd_accountant` 와 별개.
  pool 의 stats 는 reuse/evict/create counter 만, throttle 없음. Phase
  F retirement gate 의 measurement.

## 8. Phase B Prior Art findings — design 정정 (2026-05-17 후속)

Phase B 의 `knowledge/research/2026-05-17-piaf-ocsigen-eio-fd-prior-art.md`
가 본 design 의 두 가지 가정을 정정한다.

### 8.1 정정 — piaf 는 multi-host pool *이 아니다*

본 design §3 가 "piaf 가 이미 구현" 으로 기술한 부분은 *부정확*:

> From `piaf.mli`: "A client instance represents a connection to a
> **single remote endpoint**, and the remaining functions in this module
> will issue requests to that endpoint only."

piaf `Client.t` 는 *per-endpoint persistent client* — single-host
keep-alive + redirect-aware reconnect. `Host → Pool[Connection]` 자료
구조는 piaf 가 **제공하지 않는다**. 다음 항목들도 piaf 에 없음:
- `idle_ttl_seconds` (idle eviction)
- `max_idle_per_host`, `max_total_idle`
- per-host TLS context cache

### 8.2 정정 — cohttp upstream patch 후보 reject

ocaml-cohttp issue #85 는 **2014 closed** 됐고 resolution 은
`cohttp-lwt` + `cohttp-async` 한정. `cohttp-eio` 는 inherit 받지 않았으며
별도의 open FD-hygiene 이슈 (#965 / #1121 / #676) 가 진행 중. 따라서
RFC-0107 §3.1 의 후보 (b) "cohttp-eio + 자체 upstream patch" 는
실현 가능 path 가 없다. **piaf 직진이 유일한 합리적 후보**.

### 8.3 D.1 → D.2 sizing 재조정

위 두 finding 의 결과로 D.2 작업량이 *증가* 한다:

| 항목 | D.1 가정 | B 후 정정 |
|---|---|---|
| pool 자료구조 | piaf 가 제공 → thin wrapper | 자체 구현 (`Host_key → piaf Client.t queue`) |
| idle eviction fiber | piaf 가 제공 | 자체 구현 (Eio fiber on pool's root_sw) |
| per-host TLS context | piaf 가 캐싱 | 자체 캐시 (Eio_context 의 `_https_connector_cache` 확장 또는 pool 내장) |
| pool 의 unit type | raw FD | `piaf Client.t` (FD ownership 은 piaf+Eio.Switch 에 위임) |

**D.2 LoC re-estimate**: 400 → **600** (host map + eviction fiber +
TLS cache 추가). 13 callsite 마이그레이션은 동일.

§7 의 "Anti-prior-art — 자체 connection pool 재구현 (X)" 도 정정:
*"piaf 가 single-host keep-alive 를 제공하므로 그 위에 multi-host pool
layer (host map + eviction) 만 build. 자체 single-host 재구현은 여전히
거부."* — 즉 **single-host keep-alive 는 piaf 에 위임, multi-host pool
은 자체 build** 가 정확한 경계.

### 8.4 Eio #244 인용 추가 (TLA+ motivation)

B finding §"Eio #244 — exactly-one-owner 원칙" 이 우리 design 에
직접 인용 가능:

> Talex5 본인이 `Unix.close` 이중 close 패닉을 만나 `accept_fork` API
> shape 을 바꿔서 해결. 우리 masc 의 `connection: close` 강제
> 워크어라운드와 cohttp-eio #965 가 같은 버그 class.

D.2 에서 추가할 TLA+ spec `Pool_no_double_close.tla` 의 motivation
으로 차용. 본 spec 은 `Pool.release` 가 connection 을 *idle queue 로
반환* 하는 경로와 *close 하는* 경로 사이의 exclusive choice 를
모델링하여 같은 connection 의 release+release 또는 release+close 가
불가능함을 증명한다.
