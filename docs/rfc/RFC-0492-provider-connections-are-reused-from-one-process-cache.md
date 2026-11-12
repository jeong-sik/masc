---
rfc: "0492"
title: "provider 연결은 프로세스 캐시 하나에서 다시 쓰고, 다시 쓸지는 닫힌 판정 하나로 정한다"
status: Active
created: 2026-11-05
updated: 2026-11-12
author: claude
supersedes: []
superseded_by: null
related: ["0095"]
---

# RFC-0492: provider 연결은 프로세스 캐시 하나에서 다시 쓴다

- 날짜는 UTC 다.
- §0 첫 문단과 §2 의 코드는 `origin/main` `ee4dd9d1118` 기준이다. 개정한 부분(§1.6, §3.3~§7)의 코드 좌표는 `2fa106d7ba3f` 기준이다.

## 0. 요약

Keeper 의 provider 요청은 매번 새 TCP·TLS 연결을 열고, 응답을 다 읽으면 닫는다. 요청 헤더에 `connection: close` 를 직접 넣는다. 연결을 다시 쓰는 캐시(`Http_client.create_cache`)는 있지만, 운영 코드에서 만드는 곳이 없다.

새 연결 한 번에 드는 시간은 host 마다 다르다(§1.1). opencode.ai 는 첫 바이트까지 591ms 가 걸리고, 같은 연결로 보낸 둘째 요청은 247ms 다. 2026-11-04 에 opencode 로 간 provider 요청은 9,604건이다.

결정은 셋이다.

1. 서버 프로세스가 연결 캐시 하나를 루트 switch 위에 만든다. provider transport 는 그 캐시를 쓴다(§3.1).
2. 연결을 캐시에 돌려놓을지 닫을지는 닫힌 합타입 `Reuse_verdict.t` 하나로 정한다. 지금은 세 곳이 서로 다른 규칙으로 정한다(§3.2).
3. 다시 쓴 연결에 요청을 다 쓰기 전에 끊기면, http_client 가 새로 연 연결로 같은 요청을 한 번 다시 보낸다. 요청이 서버에 닿았을 수 있는 끊김은 다시 보내지 않고 타입으로 위에 올린다(§3.3). 먼저 6·7층이 이 끊김을 세고, 재전송(8층)은 다시 쓴 연결의 끊김이 있을 때만 만든다(§6, §7).

## Implementation summary

2~5층이 2026-11-05 main 에 병합됐고, 2026-11-06 01:03Z 에 부팅한 서버에 들어갔다.

- #48898(2층): `Http_client_cache` 의 `Reuse_verdict` 와 `release` 가 연결을 돌려놓을지 응답과 본문 상태로 한 번에 정한다.
- #48919(3층): `Provider_connection_cache_ref` 를 설치하고 `Runtime_agent.transport_for_provider` 에 배선했다. `/health?full=1` 이 `provider_connection_cache` 를 낸다.
- #48936(4층): 꺼낸 연결의 출처와 연결 합타입을 두고, 다시 쓴 연결이 닫힌 수를 `closed_after_reuse` 로 나눠 센다.
- #48990(5층): TTL 을 단조 시계로 재고, 연결마다 owner switch 를 두고, 전송층 EOF 뒤 취소를 취소로 올린다.

시험은 `packages/agent_core/test/test_http_client_cache.ml`, `test_http_client_addresses.ml` 과 `test/test_provider_connection_cache_wiring.ml` 에 있다.

§6 의 배포 뒤 값은 2026-11-06 05:36Z 부팅부터 1시간 38분 동안의 `provider_connection_cache` 다.

- 연결을 다시 쓴 것이 565번, 새로 연 것이 61번이다. 재사용은 90.3% 다.
- 실패로 닫은 연결 6개(`request_failed`)는 모두 다시 쓴 연결이다. 다시 쓴 연결의 1.1%, 새 연결의 0% 다.
- 새 연결이 61번뿐이라, 두 비율의 차이가 다시 쓴 연결만의 실패인지는 이 수치로 가리지 못한다. 표본이 쌓이면 같은 필드로 다시 견준다.

## 1. 측정

### 1.1 새 연결과 다시 쓴 연결

2026-11-05 에 로컬 장비에서 host 마다 인증 없는 GET 두 번을 한 curl 프로세스로 보냈다. 둘째 요청은 첫 요청의 연결을 다시 쓴다(`num_connects=0`). 다섯 번 반복한 중앙값(최소~최대)이다. 단위는 ms 다.

| host | 첫 요청 연결 완료(`time_appconnect`) | 첫 요청 첫 바이트 | 다시 쓴 요청 첫 바이트 |
|---|---|---|---|
| opencode.ai | 337 (265~501) | 591 (486~771) | 247 (213~277) |
| ollama.com | 62 (25~95) | 307 (234~812) | 221 (215~762) |
| api.z.ai | 48 (24~112) | 116 (94~179) | 68 (66~71) |
| openrouter.ai | 28 (22~129) | 62 (43~163) | 22 (15~43) |

- 요청은 `https://opencode.ai/zen/v1/models`, `https://ollama.com/api/tags`, `https://api.z.ai/api/paas/v4/models`, `https://openrouter.ai/api/v1/models` 다. 측정 스크립트는 이 세션 scratchpad `probe/reuse_timing.sh` 다.
- 로컬 장비 한 대, 한 시점의 값이다. 서버 위치에 따라 달라진다.

### 1.2 서버가 놀고 있는 연결을 닫는 시간

같은 GET 하나를 보내고 응답을 다 읽은 뒤, 서버가 연결을 닫을 때까지 소켓을 지켜봤다(scratchpad `probe/idle_close.py`).

- api.z.ai: 25.0초에 닫았다. 네 번 재서 모두 24.8~25.0초다. 응답에 `Keep-Alive` 헤더는 없다.
- opencode.ai, ollama.com, openrouter.ai: 200초 안에 닫지 않았다.

### 1.3 요청 수

비용 원장 `<base-path>/.masc/costs/2026-11/04.jsonl` 의 `usage_scope = per_request` 행을 runtime 별로 셌다.

| runtime | 요청 수 | 요청 시간 중앙값 |
|---|---|---|
| opencode_go | 9,604 | 13.6초 |
| glm-coding | 4,768 | 56.5초 |
| ollama_cloud | 379 | 2.9초 |
| openrouter | 279 | 5.2초 |

### 1.4 다시 쓸 연결이 있었을 비율

같은 runtime 의 다른 요청이 이번 요청 시작 전 20초 안에 끝났으면, 캐시에 놀고 있는 연결이 있었다고 본다. 끝난 연결 하나가 다음 요청 하나만 받는다는 점은 세지 않았으므로 상한이다.

| runtime | 20초 | 60초 |
|---|---|---|
| opencode_go | 99.3% | 99.6% |
| ollama_cloud | 98.7% | 98.9% |
| glm-coding | 90.9% | 93.9% |
| openrouter | 87.5% | 92.8% |

### 1.5 추정

§1.1 의 첫 바이트 차이에 §1.3 의 요청 수를 곱하면, 11-04 에 새 연결로 쓴 시간의 상한이 나온다. opencode 는 9,604 × 344ms ≈ 55분, GLM 은 4,768 × 48ms ≈ 4분이다. 요청 시간 중앙값에 견주면 opencode 2.5%, GLM 0.1% 다. 요청 하나의 첫 바이트가 그만큼 늦게 오고, 그 시간은 첫 토큰 시간(TTFT)에 그대로 더해진다.

### 1.6 요청을 쓰다가 끊긴 사이클

2026-11-11 의 서버 로그(`system_log_2026-11-11.jsonl`, 01:08Z~10:49Z 의 쓰기 실패)와 Keeper 11개의 runtime manifest 를 짝지었다. 입력, 명령, 결과 전체와 읽을 때의 한계는 [증거 묶음](../evidence/2026-11-11-provider-write-failures/README.md)에 있다.

- 실패한 Keeper 사이클 380건 중 49건이 `Broken pipe, "writev"` 로 끝났다. `glm-coding` 47건, `ollama_cloud` 2건이다.
- 49건 모두 그 턴에서 도구 결과를 주입한 뒤의 요청이었다. 같은 Keeper 들의 턴 중 도구 결과 주입이 있던 비율은 성공한 턴 45%(190/426), 실패한 턴 전체 42%(88/210)다. 기준선은 턴 단위이고 실패는 요청 단위다. 도구를 쓴 턴의 요청은 대부분 주입 뒤라서 이 값이 말하는 것은 적다. 49건 중 3건은 사이클 줄의 runtime 이 아니라 같은 턴의 다음 attempt 의 `runtime_failed` 에 짝지어졌다. `glm-coding`·`ollama_cloud` 의 쓰기 실패로 확실한 것은 46건이다.
- 재연결 이벤트(`provider_connection_reconnect`, #50357)가 같은 turn id 에 있던 것은 49건 중 2건이다. 둘 다 재연결한 run 이 취소로 끝나고(05:58Z) 새 run 이 06:02Z 에 시작됐으며, 실패는 그 새 run 에서 07:18:33Z 와 07:18:34Z 에 났다. 재연결로 캐시를 끄는 binding 은 fiber 안에 있어서(`Provider_connection_cache_ref.with_fresh_connections`) 새 run 에 닿지 않는다. 그래서 49건 모두 실패한 run 에는 재연결이 없었고, 연결의 출처는 49건 모두 모른다. run 경계를 `turn_started` 로 본 것은 이 두 턴의 이벤트 순서로만 확인했다.
- 마지막 도구 결과 주입부터 `runtime_failed` 까지 중앙값이 112초이고 49건 중 36건이 60초 이상이다. `runtime_failed` 는 attempt 가 끝날 때 찍힌다. 이 간격은 요청을 쓴 시각까지의 간격이 아니라서, 놀다 닫힌 연결이 쓰자마자 실패하는 모양인지 아닌지를 가르지 못한다. permit 대기와 다른 요청이 간격에 섞였는지도 가르지 못했다. 다른 Keeper 의 쓰기 실패가 120초 안에 있던 쓰기 실패는 32건이다. 실패가 구간에 고르게 퍼졌다면 28%(14건쯤)다. 몰림은 공통 원인의 단서일 뿐 원인은 아니다.
- 캐시는 부팅(약 10:46Z)부터 3시간 7분 동안 608번 다시 쓰고 43번 새로 열었다. 실패로 닫은 연결(`request_failed`) 3개가 모두 다시 쓴 연결이다. 쓰기 실패 49건 중 48건이 이 부팅 전이라서 이 통계는 그 48건에 대해 말하지 않는다. `request_failed` 는 쓰기 실패 말고 읽기 실패와 타임아웃도 센다. Implementation summary 의 11-06 값(565번 중 6개, 새 연결 61번 중 0개)과 합치면 다시 쓴 연결은 1,173번 중 9개, 새 연결은 104번 중 0개다. 두 값은 부팅과 빌드가 다르고, 같은 코드와 같은 workload 라는 전제는 확인하지 않았다. 새 연결이 104번뿐이라 같은 실패율이어도 0개가 나올 수 있어서, 이 수치로 새 연결의 실패를 배제하지 못한다.
- 49건의 원인이 놀다 닫힌 재사용 연결인지는 이 측정으로 맞는지 틀린지 가르지 못한다. 연결의 출처가 49건 모두 로그에 없다. 확인된 것은 다른 Keeper 의 쓰기 실패와 가까이 몰리는 경향 하나다. 그래서 재전송은 이 측정이 아니라 §3.3 의 안전한 구조와 §6 의 사전 측정으로 정한다.
- Keeper 의 run 단위 재연결(`connection_recovery_sequence`)은 `not !stream_started`, `same_run_retry_allowed`, `native_retry_allowed` 가 모두 참이고 `Agent_core` 로 도는 run 일 때만 돈다. `same_run_retry_allowed` 는 run 이 체크포인트 단계에 닿으면 거짓이다(`keeper_turn_driver_try_provider.ml`). 다시 도는 `attempt ()` 는 요청 하나가 아니라 run 전체다. 도구를 실행한 run 의 뒤쪽 요청이 끊기면 그 요청 하나만 새 연결로 다시 보낼 길이 없다. 49건에서 재연결을 막은 조건이 이것인지는 건별로 확인하지 않았다.
- `Candidate_fault` 의 주석이 같은 빈칸을 적는다. `Retry.NetworkError` 에는 "보냈다가 잃은 것"과 "모든 후보가 공유하는 배선 문제"를 가를 dispatch 사실이 없다(`candidate_fault.ml`).

## 2. 지금 코드

- `lib/runtime/runtime_agent.ml` `observed_http_transport` 가 `Llm_provider.Complete.make_http_transport ~sw ~net` 을 부른다. `make_http_transport` 는 `?connection_cache` 를 받지만 넘기는 곳이 없다.
- `packages/agent_core/lib/llm_provider/http_client.ml` `create_cache`(1617행)는 운영 코드에 부르는 곳이 없다. 캐시가 없으면 `maybe_add_connection_close`(1534행)가 요청 헤더에 `connection: close` 를 넣는다.
- 캐시가 있을 때 연결을 돌려놓을지 정하는 곳이 셋이고, 규칙이 다르다.

| 함수 | 돌려놓는 조건 |
|---|---|
| `with_client`(1911행, `get_sync`·`post_sync`·`delete_sync`) | `f` 가 `Ok` 를 돌려주면. 응답 헤더와 본문을 다 읽었는지 보지 않는다 |
| `dispatch_sync_request`(2391행, 동기 완성) | `response_connection_is_reusable`(1286행)가 참이고 본문을 받았으면 |
| `with_post_stream`(2592행, 스트림 완성) | `response_connection_is_reusable` 가 참이고, 본문 reader 가 EOF 를 봤고, 전송층 EOF 가 없었으면 |

- 첫 줄은 응답이 `connection: close` 를 보냈거나 본문을 덜 읽었어도 연결을 돌려놓는다. 다음 요청은 그 연결에서 남은 바이트나 닫힌 소켓을 만난다. 지금은 캐시를 넘기는 운영 경로가 없어서 드러나지 않았다.
- #48633(열림)은 캐시를 `http_client_cache.ml` 로 옮기고, 연결을 꺼내는 세 곳을 `Http_client_cache.checkout` 하나로 합친다. 돌려놓는 판정은 그대로 세 곳에 남는다. 이 RFC 는 그 모듈 위에 쌓는다.

## 3. 결정

### 3.1 캐시는 서버 프로세스에 하나다

- 서버가 시작할 때 루트 switch 와 단조 시계(`Eio.Stdenv.mono_clock`)로 `Http_client_cache.create` 를 한 번 부른다. 자리는 `lib/server/server_runtime_bootstrap.ml` 이 `Fd_accountant.install_observers` 를 부르는 곳 옆이다.
  - 연결이 논 시간은 넣은 때부터 단조 시계로 잰다. Eio 는 `clock` 을 "the system clock (used to get the current time and date)", `mono_clock` 을 "a monotonic clock (used for measuring intervals)" 라고 적었다(`eio.mli:261`, `:264`, Eio 1.3). 시스템 시계로 재면 시계가 뒤로 갈 때 서버가 이미 닫은 연결을 내준다. 11-06 감사가 이것을 찾았고 5층이 고친다.
- 캐시는 `Provider_connection_cache_ref` 에 두고, 설치한 domain 을 같이 적는다. `Runtime_agent.transport_for_provider` 는 그 domain 에서만 캐시를 받아 `make_http_transport ~connection_cache` 로 넘긴다. 설치되지 않았거나 다른 domain 이면 `None` 이고 지금처럼 요청마다 닫는다.
- 키는 지금처럼 scheme·host·port 다. 여러 Keeper 가 같은 origin 의 연결을 나눠 쓴다. 꺼낸 연결은 돌려놓기 전까지 그 요청만 쓴다.
- `idle_ttl_seconds` 는 20초다. §1.2 에서 가장 먼저 닫은 api.z.ai(25초)보다 짧다. §1.4 에서 60초로 늘려도 얻는 비율은 0.2~5.3%p 다.
  - 요청은 20초 넘게 논 연결을 받지 않는다. 꺼낼 때(`Http_client_cache.checkout`) 나이를 보고, 넘었으면 닫는다.
  - eviction fiber 는 TTL 의 절반마다 돈다. 그것만으로는 30초까지 논 연결이 요청에 나간다. 3층 리뷰가 이것을 찾았다.
- `max_idle_per_host` 는 기본값 8 을 둔다. 배포 뒤 `Http_client_cache.stats` 의 origin 별 idle 수로 다시 본다.
- 연결마다 owner switch 를 따로 둔다. 캐시의 switch 위 daemon 하나가 그 owner switch 를 연결이 닫힐 때까지 돌린다. 연결을 여는 함수(`create`)는 요청 fiber 에서 owner switch 를 받아 돈다.
  - `Tcp_address_race` 는 소켓을 넘긴 뒤에도 그 switch 에 fiber 를 남긴다. Eio 는 fiber 가 예외를 내면 "[Switch.fail sw] is called" 라고 적었다(`eio__core.mli` `Fiber.fork`). 캐시의 switch 는 서버의 switch 라서, owner switch 가 없으면 연결 하나의 늦은 실패가 서버 switch 를 실패시킨다.
  - owner switch 가 실패하면 daemon 이 그 예외를 `Diag.warn` 으로 남기고 끝난다. 캐시는 그 연결을 다시 내주지도 넣지도 않고 닫는다. 캐시의 switch 를 취소하면 owner switch 도 모두 취소된다.
- owner switch 를 돌리는 daemon 은 캐시의 switch 에 붙는다. Eio 는 다른 domain 에서 switch 를 쓰면 `Invalid_argument "Switch accessed from wrong domain!"` 을 던진다(`eio/core/switch.ml` 의 `check_our_domain`, Eio 1.3).
  - 그래서 캐시는 설치한 domain 의 요청만 쓴다. 다른 domain 에 캐시를 넘기면 그 요청은 provider 오류로 끝난다. 3층 시험이 이것을 재현했다.
  - 지금 캐시를 쓰는 provider 요청(Keeper owner 턴, 자율 턴, 리뷰어, Fusion)은 모두 main domain 에서 돈다. serving domain 모드의 handler 는 Keeper owner mailbox 로 넘긴다.
  - 통계는 어느 domain 에서든 읽는다. 캐시 상태는 `Eio.Mutex` 와 `Atomic` 이 지키고, Eio 는 둘 다 여러 domain 에서 써도 된다고 적었다(Eio README "Mutexes and Semaphores").
  - 한 연결을 동시에 둘이 쓰지 않는 것은 checkout 이 지킨다.

### 3.2 돌려놓을지는 `Reuse_verdict.t` 하나로 정한다

```ocaml
type close_reason =
  | Request_failed          (* 요청이나 본문 읽기가 Error 또는 예외로 끝났다 *)
  | Request_not_delivered   (* 요청을 다 쓰기 전에 끊겼다(§3.3) *)
  | Not_persistent          (* HTTP/1.0 without keep-alive, connection: close, upgrade, framing 없음 *)
  | Body_not_drained        (* 응답 본문을 끝까지 읽지 않았다 *)
  | Transport_ended         (* 전송층이 EOF 를 냈다 *)

type t = Park | Close of close_reason

val decide :
  request_headers:Http.Header.t -> response:Http.Response.t ->
  body:[ `Drained | `Not_drained | `Transport_ended | `Failed ] -> t
```

- `Http_client_cache` 의 `return` 은 `release` 로 바뀐다. `Park` 이면 돌려놓고, `Close _` 면 닫는다. 연결을 끝내는 길은 이 함수 하나다. 2층은 `t -> Key.t -> connection -> Reuse_verdict.t -> unit` 이고, 4층에서 `lease -> Reuse_verdict.t -> unit` 가 된다. 같은 lease 를 두 번 끝내면 `Invalid_argument` 다. 두 번 돌려놓으면 소켓 하나를 두 요청이 나눠 쓰기 때문이다(`Eio.Promise.resolve` 와 같은 방식).
- 세 함수는 각자 응답과 본문 상태를 `decide` 에 넘긴다. `with_client` 는 `f` 가 응답 헤더와 본문 상태를 같이 돌려주게 바뀐다. 그래야 응답을 보지 않고 돌려놓는 일이 없다.
- `response_connection_is_reusable` 는 `decide` 의 `Not_persistent` 판정이 된다. 규칙은 RFC 9112 §9.3 대로다. 요청이나 응답이 `close` 를 보냈으면 그 연결로 더 보내지 않는다(§9.6).
- `close_reason` 은 `Http_client_cache.stats` 에 이유별 닫은 수로 남긴다. 저장하지 않는다.
- 꺼낸 연결은 출처를 같이 든다(4층). `checkout` 은 `lease`(연결과 `Reused | Created`)를 돌려주고, `release` 는 그 `lease` 를 받는다. `stats` 는 다시 쓴 연결의 이유별 닫은 수를 한 벌 더 센다(`closed_after_reuse`). §6 은 다시 쓴 연결의 실패를 이것으로 센다.
- `http_client` 는 요청의 연결을 닫힌 합타입 하나로 든다. 요청 하나만 쓰는 연결(`One_shot`)과 캐시에서 빌린 연결(`Leased`)이다. 요청 하나만 쓰는 연결을 캐시에 돌려놓는 코드는 타입이 받지 않는다. 빌린 연결은 `end_connection` 이 `release` 로 끝낸다. 빌린 연결의 소켓을 `Eio.Resource.close` 로 직접 닫는 것은 타입이 막지 못하고, 그러면 이유별 수에서 빠진다.

### 3.3 요청을 다 쓰기 전에 끊긴 재사용 연결은 새 연결로 한 번 다시 보낸다

- 서버는 놀고 있는 연결을 언제든 닫을 수 있다. 캐시에서 꺼낸 순간과 서버가 닫는 순간이 겹칠 수 있다(RFC 9112 §9.5). 클라이언트는 이 비동기 닫힘에서 회복할 준비를 하고, 다시 보내도 되는 조건은 RFC 9110 §9.2.2 가 정한다(RFC 9112 §9.3.1).
- 완성 요청은 POST 다. §9.2.2 는 "A client SHOULD NOT automatically retry a request with a non-idempotent method unless it has some means to know that the request semantics are actually idempotent, regardless of the method, or some means to detect that the original request was never applied." 라고 적는다. 같은 절은 응답을 한 바이트도 받기 전에 연결이 닫혔다는 이유만으로 POST 를 다시 보내는 것을 "a riskier approach" 라고 적는다. 이 RFC 는 그 방법을 쓰지 않는다. 요청이 서버에 다 닿지 못했다는 사실을 구조로 아는 경우만 다시 보낸다. "원래 요청이 적용되지 않았다"는 근거는 요청이 불완전하다는 사실이다. RFC 9112 §6.3 은 본문 길이를 채우기 전에 연결이 닫히면 수신자가 그 메시지를 불완전한 것으로 본다고 정한다. 불완전한 요청을 적용하지 않는다는 규정은 RFC 에 없고 서버 구현에 기댄다.
- 그 사실은 닫힌 합타입 하나로 든다.

```ocaml
type delivery =
  | Not_delivered       (* 요청을 다 쓰기 전에 실패했다. 연결을 여는 데 실패한 경우를 포함한다 *)
  | Possibly_delivered  (* 그 밖의 모든 실패. 요청이 서버에 닿았을 수 있다 *)
```

  - 연결을 연 뒤의 `Not_delivered` 는 셋이 모두 참일 때다. (1) 추적 래퍼가 그 연결의 쓰기 호출(`single_write`, `copy`)에서 예외를 직접 봤다. (2) 그 예외를 `classify_network_exn` 이 `Connection_reset` 이나 `End_of_file` 로 분류한다. Unix 오류는 `classify_unix_error` 가 `ECONNRESET` 과 `EPIPE` 를 이 둘로 보내고, `Eio.Net.Connection_reset` 은 `classify_eio_error` 가 backend 오류를 분류하되 못 하면 `End_of_file` 로 둔다(tls-eio 의 `Tls_socket_closed` 가 지금 이 경우다). 이 기본값은 쓰기 예외를 `Not_delivered` 쪽으로 기울이므로 (2)에 쓰지 않는다. `Tls_socket_closed` 는 `tls_eio.mli` 가 내보내지 않아 코드에서 이름으로 부를 수 없다. 그래서 (2)는 backend 오류가 `ECONNRESET`·`EPIPE` 인 경우에만 참이다. `Tls_socket_closed` 를 포함해 이름 없이 기본값으로 떨어진 오류는 `Possibly_delivered` 다. https 연결에서는 tls-eio 가 아래 소켓의 쓰기 오류를 `Eio.Net.Connection_reset (Unix_error (EPIPE | ECONNRESET))` 로 그대로 올려서 (2)를 채운다. 2026-11-12 에 loopback TLS 서버로 쟀다. 새 연결과 다시 쓴 연결에서 큰 요청이 reset 으로 끊길 때, 그리고 서버가 `close_notify` 를 보내고 닫을 때 모두 5번 중 5번 `Not_delivered` 였다. 이 전제는 시험이 지킨다(#51528 의 `tls passes a failed write's errno through`). 실제 provider 의 TLS 종단이 다른 순서로 닫는 경우는 재지 않았다. (3) 이 요청의 첫 쓰기 이후 이 연결에서 읽은 응답 바이트가 한 바이트도 없다. 다시 쓴 연결은 앞 요청의 응답을 이미 읽었으므로 연결에서 누적한 바이트로 세지 않고 요청마다 새로 센다(`eof_seen` 이 `with_client` 호출마다 새 `ref` 인 것과 같은 단위다). 요청을 다 쓴 뒤 응답을 기다리다 끊긴 경우는 쓰기가 성공했으므로 `Possibly_delivered` 다.
  - 근거는 문구가 아니라 구조다. `track_connection_eof`(6층에서 `track_connection` 으로 이름이 바뀐다)는 지금 읽기를 `single_read` 하나로 지나게 해서 전송층 EOF 를 `eof_seen` 으로 세운다. 쓰기(`single_write`, `copy`)는 추적하지 않는다. 이 RFC 는 같은 래퍼가 쓰기 호출의 예외와 요청마다 읽은 응답 바이트 수도 `Request_wire` 에 세우도록 넓힌다(§7 6층). 오류 메시지 문구(`Broken pipe, "writev"`)는 읽지 않는다.
  - https 연결은 tls-eio 위에 있다. tls-eio 는 한쪽에서 난 예외를 연결 상태에 저장하고 반대쪽 호출에서 다시 던진다(`tls_eio.ml` 의 `write_t`, `read_react`). 호출자가 마지막에 받은 예외만으로는 쓰기에서 난 것인지 읽기에서 난 것인지 가르지 못한다. (1)은 래퍼가 쓰기 호출에서 직접 본 예외만 센다. 읽기 호출이 저장된 쓰기 예외를 다시 던진 경우는 (1)을 채우지 못해 `Possibly_delivered` 로 남는다. 재전송이 일어나지 않는 쪽으로 어긋난다. 쓰기 호출이 저장된 읽기 예외를 다시 던지는 경우(`tls_eio.ml` 의 `writev`)는 (1)을 채운다. 요청이 덜 쓰였으니 판정은 맞다. (3)의 바이트는 tls-eio 가 푼 응답 바이트다.
  - 서버가 요청을 적용한 뒤에 클라이언트의 쓰기 호출이 실패할 수 있는가. 쓰기 호출이 `EPIPE` 나 `ECONNRESET` 으로 실패하면, 그 호출이 넘기려던 바이트를 로컬 커널이 받지 않았다고 기대한다. 소켓이 이미 오류 상태일 때 나는 오류이기 때문이다. 그러면 서버는 요청의 마지막 바이트를 받지 못했고 본문을 다 받지 못했다. 그 앞의 쓰기가 성공했다면 서버는 요청의 앞부분은 받았다. 남는 전제는 서버나 게이트웨이가 본문을 다 받기 전에는 요청을 처리하지 않는다는 것이다. 이 전제는 provider 마다 다를 수 있고 이 서버에서 재지 않았다. 그래서 8층은 6·7층의 측정만으로 만들지 않는다. 요청의 앞부분만 보내고 연결을 닫았을 때 provider 가 응답이나 사용량을 만들지 않는지 확인한 뒤에 만든다(§6 시험 5).
  - 8층은 `Http_client.http_error`, `Retry.api_error`, `Error.t` 의 `NetworkError` 가 `delivery` 를 들게 한다. 만드는 곳은 값을 반드시 정한다. 정하지 못하면 `Possibly_delivered` 다. 6층은 이 필드를 만들지 않는다. 6층의 `delivery` 는 `Request_wire` 안에서 닫는 이유(`Request_not_delivered`)를 정하는 데만 쓴다. 필드를 읽는 쪽은 다시 보내는 8층이 처음이다.
- 다시 보내는 규칙은 하나다. `with_client`, 동기 완성, 스트림 완성이 빌린 연결(`Leased`)의 출처가 `Reused` 이고 실패가 `Not_delivered` 이면, 그 연결을 `Close Request_not_delivered` 로 닫고 새로 연 연결(`Created`)로 같은 요청을 한 번 다시 보낸다.
  - 횟수를 세지 않는다. 새로 연 연결의 실패는 출처가 `Created` 라서 다시 보내지 않는다. 방금 연 연결은 서버가 놀다가 닫은 연결일 수 없다. §9.2.2 의 "A client SHOULD NOT automatically retry a failed automatic retry." 와 http_client 안에서는 같다.
  - 새 연결을 받으려면 `Http_client_cache.checkout` 에 놀고 있는 연결을 건너뛰고 `create` 를 부르는 경로가 필요하다. 받은 연결은 다른 연결처럼 판정(§3.2)으로 돌려놓는다.
  - 요청 본문은 문자열(`Cohttp_eio.Body.of_string body`)이라 다시 쓸 수 있다.
  - 이 규칙이 고치는 것은 여러 번의 쓰기로 나가는 큰 요청이다. 닫힌 소켓의 첫 쓰기는 커널이 받고 상대의 reset 은 다음 쓰기나 읽기에서 보인다고 예상한다. 그러면 한 번의 쓰기로 끝나는 작은 요청은 읽기에서 실패해 `Possibly_delivered` 가 된다. 이 예상과 큰 요청의 기준(소켓 송신 버퍼 크기)은 이 서버에서 재지 않았다. 시험 1 이 정한다(§6).
- `Possibly_delivered` 는 지금처럼 `NetworkError` 로 올린다. http_client 는 다시 보내지 않는다. 다시 보낼지는 provider 재시도·cascade 정책이 정한다. Keeper 의 run 단위 재연결(#50357)과 `Candidate_fault` 의 판정은 이 RFC 가 바꾸지 않는다. `delivery` 로 `Retry.NetworkError` 의 판정(`Unknown_after_dispatch`)을 가를지는 따로 정한다.
- 재전송이 `End_of_file` 이나 `Connection_reset` 으로 실패하면 run 단위 재연결(#50357)이 조건이 맞을 때 run 을 다시 돈다. `connection_recovery_sequence` 는 오류의 kind 만 보고 `delivery` 를 보지 않는다. run 의 첫 요청이면 같은 요청을 세 번까지 보낸다(재사용 연결, 재전송, 재연결 뒤 첫 요청). 서버가 두 번 적용하지 않았다고 말할 수 있는 것은 첫 전송뿐이다. 재전송이 요청을 다 쓴 뒤 `Connection_reset` 으로 끝나면 `Possibly_delivered` 인데도 재연결이 돈다. 이 재연결은 지금도 그렇게 돈다. http_client 안에서는 §9.2.2 의 "failed automatic retry" 규칙을 지키고, run 과 겹친 부분이 그 규칙과 어긋난다. 도구를 실행한 run 의 뒤쪽 요청은 `same_run_retry_allowed` 가 거짓이라 겹치지 않고 재전송만 돈다. 재전송이 타임아웃이나 HTTP 오류로 끝나면 그 오류가 그대로 올라오고 재연결 조건에 들지 않는다. 재전송까지 실패한 오류를 run 단위 재연결이 받을지는 열린 결정이다(§5).
- 서버가 요청을 다 받기 전에 거절 응답을 보내고 닫을 수 있다. `cohttp-eio`(v6.2.1)의 `call_on_socket` 은 `Eio.Buf_write.with_flow` 안에서 요청을 버퍼에 직렬화하는 fiber 를 `~sw` 에 fork 하고, 같은 `with_flow` 안에서 응답을 읽는다. 소켓에 쓰는 fiber 는 `with_flow` 가 자기 switch 에 띄운 `copy` 다(eio `buf_write.ml`). 그 fiber 의 `EPIPE` 가 switch 를 실패시키면 읽고 있던 응답이 취소될 수 있다. 응답을 한 바이트라도 읽었으면 `Possibly_delivered` 이고 다시 보내지 않는다. 읽기 전에 취소됐다면 `Not_delivered` 라서 같은 요청이 새 연결에서 한 번 더 거절된다. 응답을 읽은 뒤에 쓰기 fiber 가 실패해도 `with_flow` 가 그 예외를 올릴 수 있다. 어느 쪽이 이기는지는 시험으로 정한다(§6).
- TTL(20초)은 api.z.ai 가 닫는 시간(25초)보다 짧다(§3.1). 서버는 응답을 읽은 25초 뒤에 닫고 캐시는 넣은 때부터 20초를 센다. 응답을 읽은 때부터 캐시에 넣기까지의 지연과 다음 요청이 서버에 닿기까지의 시간을 더해 5초를 넘으면 닫힌 연결을 만난다. 서버가 25초보다 일찍 닫아도 만난다(`server_runtime_bootstrap.ml` 의 `provider_connection_idle_ttl_s` 주석). §1.2 는 11-05 로컬 장비에서 GET 하나로 네 번 잰 값이라, 서버의 유휴 종료 시간이 지금도 같은지 가르지 못한다. 이 RFC 는 TTL 을 바꾸지 않는다.

## 4. 검토한 대안

- **Keeper 마다 캐시를 둔다.** 하지 않는다. Keeper 하나의 요청 사이 간격은 도구 실행 시간만큼 길다. origin 을 공유하면 다른 Keeper 가 막 끝낸 연결을 쓴다(§1.4).
- **`Runtime_agent.config` 에 캐시 필드를 더해 위에서 넘긴다.** 하지 않는다. `Runtime_agent.default_config`·`build`·`run` 을 부르는 곳이 lib 안에 네 파일 여덟 곳이고, 모두 같은 프로세스 캐시를 넘겨야 한다. 프로세스 범위 자원은 `Domain_pool_ref` 처럼 한 곳에서 설치한다. 단점은 의존이 시그니처에 드러나지 않는 것이다. 설치가 없으면 지금 동작이라 시험은 바뀌지 않는다.
- **domain 마다 캐시를 둔다(`Domain.DLS`).** 지금은 하지 않는다. 캐시를 쓰는 요청이 main domain 하나에서만 돈다(§3.1). domain 마다 두면 health 응답이 어느 캐시를 보여 줄지 정해야 한다.
- **host 마다 TTL 을 다르게 둔다.** 지금은 하지 않는다. 20초와 60초의 차이가 작다(§1.4). 설정 키가 하나 늘어난다.
- **꺼낼 때 소켓이 닫혔는지 먼저 본다.** 하지 않는다. Eio flow 에는 읽지 않고 닫힘을 보는 연산이 없다. 보고 난 뒤 보내기 전에 닫힐 수도 있어서 §3.3 의 실패를 없애지 못한다.
- **다시 보내는 일을 run 단위 재연결에만 맡긴다.** 8층을 만들 때는 하지 않는다. `same_run_retry_allowed` 는 run 이 체크포인트 단계에 닿으면 거짓이라, 도구를 실행한 run 의 뒤쪽 요청을 막는다. §1.6 의 49건 모두 실패한 run 에 재연결이 없었다. 요청 하나가 끊긴 일을 run 전체가 다시 도는 조건에 묶게 된다.
- **놀고 있는 연결의 닫힘 신호를 계속 읽는다(RFC 9112 §9.5).** 지금은 하지 않는다. 놀고 있는 연결마다 읽는 fiber 를 두면 서버가 닫는 순간 캐시에서 빠진다. 꺼내는 순간과 닫히는 순간이 겹치는 경합은 남아서 §3.3 의 재전송이 어차피 필요하다. 재전송의 비용은 새 연결 한 번이다(api.z.ai 는 48ms, §1.1).
- **TTL 을 더 줄인다.** 지금은 하지 않는다. 줄이면 다시 쓸 수 있는 연결이 줄어든다(§1.4 는 20초와 60초만 견줬다). 서버의 유휴 종료 시간을 다시 재는 것이 먼저다.
- **`delivery` 를 오류 문구에서 읽는다.** 하지 않는다. 문구로 가르면 분류가 추측이 되고, 같은 syscall 이어도 flow 래퍼가 바뀌면 깨진다. 상태와 판정은 닫힌 합타입이고 문자열을 비교해서 분기하지 않는다(constitution `closed_sum_over_string`, `string_matching`).
- **HTTP/2 로 바꾼다.** 해당 없다. `cohttp-eio` 는 HTTP/1.1 만 쓴다.

## 5. 영향

- 캐시가 설치된 서버에서 provider 요청은 놀고 있는 연결을 다시 쓴다. 그 요청의 첫 바이트가 §1.1 의 차이만큼 빨라진다.
- 요청 헤더에 `connection: close` 가 빠진다.
- 놀고 있는 연결이 origin 마다 최대 8개, 20초까지 열려 있다.
- 8층이 들어가면, 다시 쓴 연결이 서버 쪽에서 닫혀 있어서 요청을 쓰다가 끊길 때 http_client 가 새로 연 연결로 같은 요청을 한 번 다시 보낸다. 그 요청의 지연은 새 연결을 여는 시간(api.z.ai 는 48ms, §1.1)과 요청 본문을 다시 쓰는 시간이다. 한 번의 쓰기로 끝나는 작은 요청은 이 경우에 들지 않는다고 예상한다(§3.3).
- 요청이 서버에 닿았을 수 있는 끊김은 지금처럼 `NetworkError` 로 끝난다.
- `NetworkError` 의 모양이 바뀐다. 참조는 `lib` 와 `packages/agent_core/lib` 에 237곳, 53개 파일이고 시험까지 합치면 345곳, 97개 파일이다. `NetworkError _` 는 `lib` 와 `packages/agent_core/lib` 에 115줄이다. 이 패턴과 레코드 패턴 끝의 `; _ }` 는 필드가 늘어도 그대로 컴파일돼서, 컴파일러가 모든 읽는 곳을 짚지는 않는다. `delivery` 를 만드는 곳은 레코드 리터럴이라 짚는다(2026-11-11 `origin/main` `2fa106d7ba3f`).
- 열린 결정: 재전송까지 실패한 오류를 run 단위 재연결이 다시 받을지. 정석(RFC 9110 §9.2.2)은 받지 않는 쪽이다. 그러려면 "새 연결에서 한 번 실패했다"는 사실을 오류가 하나 더 들어야 한다. 받는 쪽이면 코드는 줄지만 run 의 첫 요청에서 같은 요청을 세 번까지 보낸다.

## 6. 검증

- 시험: `decide` 의 모든 입력 조합. `with_client`·`dispatch_sync_request`·`with_post_stream` 이 `connection: close` 응답, 본문을 덜 읽은 응답, 전송층 EOF 에서 연결을 돌려놓지 않는다. 같은 origin 의 연속 요청이 연결 하나를 다시 쓴다(`stats.reuse_count_total`).
- 시험(요청을 쓰다가 끊기는 경우): 상대 서버를 넷으로 둔다. 서버가 받은 요청 수를 센다. 1(가), 2, 4 는 6층에 두고(재전송 없이 분류와 수를 확인), 1(나)와 3 은 8층에 둔다. 5 는 실제 provider 로 하고 8층 전에 한다.
  1. 놀던 연결을 닫아 둔 서버. (가) 본문이 작아 한 번의 쓰기로 끝나는 요청은 읽기에서 reset 이 나서 `Possibly_delivered` 이고 다시 보내지 않는다고 예상한다. (나) 본문이 소켓 송신 버퍼보다 커서 여러 번 쓰는 요청은 쓰다가 끊긴다. 연결은 앞 요청의 응답을 이미 읽은 다시 쓴 연결로 둔다. 6층에서는 `Not_delivered` 로 올라오고(조건 (3)이 요청 단위인지 이 시험이 잡는다) `closed_after_reuse.request_not_delivered` 가 1 늘어난다. 8층에서는 같은 요청이 새 연결에서 한 번 성공하고, 서버가 받은 요청은 1건이며 `created_total` 이 1 늘어난다. 어느 쪽이 되는지는 시험이 정한다(§3.3). (나)는 TLS 서버에서도 한다. tls-eio 가 쓰기 예외를 상태에 저장했다가 읽기에서 다시 던지기 때문이다.
  2. 요청을 읽은 뒤 응답 전에 연결을 리셋하는 서버. `Possibly_delivered` 로 올라오고 다시 보내지 않는다. 서버가 받은 요청은 1건이다.
  3. 본문 중간에 거절 응답(413)을 보내고 닫는 서버. 결과는 셋 중 하나다. 거절 본문을 읽어 `HttpError` 가 된다. 읽기 전에 취소돼 `Not_delivered` 가 되고 새 연결에서 한 번 더 거절된다. 응답을 읽은 뒤 쓰기 fiber 의 실패가 올라와 `Possibly_delivered` 가 된다. 어느 쪽인지 이 시험이 정한다(§3.3).
  4. 요청 줄을 읽고 reset 하는 서버. 본문은 소켓 버퍼보다 크다. 새로 연 연결의 쓰기 실패는 다시 보내지 않고 `Not_delivered` 로 올라온다. 서버가 받은 연결은 1개다. 요청 줄을 읽기 전에 reset 하면 클라이언트의 `connect` 가 먼저 실패해 `Before_dispatch_error` 가 되고 닫을 연결도 없으니 이 시험이 아니다(#51528 의 첫 시험은 200번 중 53번 그렇게 갈렸다).
  5. 요청의 앞부분만 받고 닫는 provider. `glm-coding` 과 `ollama_cloud` 에 요청 헤더와 본문 앞부분만 보내고 연결을 닫는다. 응답이나 사용량이 생기지 않아야 한다. 생기면 provider 가 불완전한 요청을 처리하는 것이라 그 provider 의 8층은 만들지 않는다(§3.3). 외부 provider 를 부르는 시험이라 운영자 승인을 받고 하고, 8층 PR 이 이 결과를 증거로 든다.
     - 결과(2026-11-12, [기록](../evidence/2026-11-12-provider-partial-request/README.md)): `glm-coding` 과 `openrouter` 는 본문을 절반 또는 한 바이트 모자라게만 보내고 연결을 닫지 않은 채 기다렸을 때 응답하지 않았다(glm 60초 뒤 FIN, openrouter 15초 뒤 RST). 정상 요청은 같은 조건에서 2.2초와 0.5초에 200 으로 답했다. FIN 으로 닫는 방식은 쓸 수 없다. 요청을 모두 보낸 뒤 FIN 만 보내도 glm 은 응답 없이 닫았다.
     - 한계: 클라이언트가 멈춘 경우이고 연결이 끊기는 경우가 아니다. 사용량이 생기는지는 재지 못했다(glm 의 창은 정수 퍼센트, openrouter 는 무료 모델). 처리하고 응답만 버린 경우는 배제하지 못한다. `ollama_cloud` 는 한도에 막혀 시험하지 않았고 그 provider 의 8층은 시험 전에 만들지 않는다.
- 배포 뒤: 캐시 `stats` 의 재사용 수와 새로 연 수, 이유별 닫은 수를 본다. 3층이 이 값을 `/health?full=1` 의 snapshot 필드 `provider_connection_cache` 로 낸다.
  - `/health` 는 인증 없이 열린 집계 화면이다. 그래서 origin 이름은 내지 않는다(RFC-0132). `max_idle_per_host` 를 다시 볼 값으로 origin 하나의 최대 idle 수만 낸다.
  - 다시 쓴 연결의 실패는 `closed_after_reuse` 의 `request_failed`·`transport_ended` 로 센다. `closed_total` 의 같은 이유 수에서 빼면 새 연결의 수다(#48933).
  - `request_failed` 는 응답 전과 후를 나누지 않는다. 타임아웃도 `request_failed` 에 든다. 요청을 다 쓰기 전의 끊김은 `request_not_delivered` 가 따로 센다.
  - 6·7층을 먼저 배포한다(§7). 그때는 재전송 없이 `Not_delivered` 만 센다. 카운터는 서버 메모리라 재시작마다 0 이 된다. 기간은 사이클 쓰기 실패(§1.6 의 방법)가 난 uptime 들을 합친 시간으로 센다. 판정은 두 출처의 발생률 비교다. 다시 쓴 연결은 `closed_after_reuse.request_not_delivered` 를 `reused_total` 로, 새 연결은 `closed_total` 에서 뺀 `request_not_delivered` 를 `created_total` 로 나눈다. 다시 쓴 연결의 발생이 0 이면 8층을 만들지 않는다. 0 의 뜻은 같은 기간의 `closed_after_reuse.request_failed`(이미 있는 값)로 가른다. 그 값이 0 이 아니면 다시 쓴 연결의 끊김은 있었고 `Not_delivered` 가 아니었다는 뜻이다. 8층을 만들지 않는 근거는 `request_not_delivered` 를 `request_not_delivered` 와 `request_failed` 의 합으로 나눈 비율로 적는다. 한 연결은 이유 하나로만 닫혀서 두 카운터는 겹치지 않고, 합이 요청 실패로 닫힌 연결 수다. 다시 쓴 연결의 발생률이 새 연결보다 높지 않으면 재전송이 새 연결에서 성공할 근거가 약하다. 그때는 8층 전에 이 RFC 를 다시 연다. 새 연결의 표본이 작으면(같은 발생률이어도 0 이 나온다, §1.6) 판정하지 않고 기간을 늘린다. 같은 기간의 사이클 쓰기 실패 수는 규모를 보는 참고값이다. cascade 가 요청 실패를 사이클 성공으로 바꿀 수 있어서 연결 수와 직접 견주지 않는다.
  - 8층을 배포한 뒤에는 재전송 수가 `closed_after_reuse.request_not_delivered` 다. 새 연결의 `request_not_delivered`(`closed_total` 에서 뺀 값)는 재전송의 실패와 처음부터 새 연결이던 요청의 실패를 합친 수다. 재전송 수에서 이 수를 빼면 새 연결에서 요청을 다 쓴 재전송 수의 하한이다. 다 쓴 뒤에도 재전송은 응답 단계에서 실패할 수 있다(`request_failed`). 재전송이 있는데 사이클의 쓰기 실패가 그대로면 §3.3 의 전제가 틀린 것이다.
  - 캐시를 쓰지 않는 요청(`One_shot`)의 쓰기 실패는 `stats` 에 없다. 사이클 수에는 그 실패도 든다.
- 비용 원장 `per_request` 행에는 `request_latency_ms` 만 있고 첫 바이트 시간이 없다. 그래서 첫 바이트가 얼마나 빨라졌는지는 원장으로 직접 재지 못한다. 요청 시간이 짧은 ollama_cloud(중앙값 2.9초)의 `request_latency_ms` 를 배포 전 같은 시간대와 견주는 것이 간접 확인이다.

## 7. 층

1. 이 문서.
2. #48633 병합 뒤: `Reuse_verdict` 와 `Http_client_cache.release`, 세 함수의 판정 교체와 시험(agent_core).
3. `Provider_connection_cache_ref` 설치와 `Runtime_agent.transport_for_provider` 배선, runtime health 응답의 캐시 `stats`(masc).
4. 꺼낸 연결의 출처(`lease`), `http_client` 의 연결 합타입, 다시 쓴 연결의 이유별 닫은 수와 health 응답의 `closed_after_reuse`(agent_core·masc, #48933).
5. 단조 시계로 재는 TTL, 연결마다 owner switch, 전송층 EOF 뒤 취소를 취소로 올리기(agent_core·masc, #48990).
6. `Request_wire` 와 그 안의 `delivery` 합타입, `track_connection` 이 쓰기 호출의 예외와 요청마다 읽은 응답 바이트 수를 `Request_wire` 에 세우기, `close_reason` 의 `Request_not_delivered` 와 `close_counts` 의 `request_not_delivered`(agent_core, #51528). 시험 1(가), 2, 4 가 이 층에 든다. 이 층은 다시 보내지 않고 `Not_delivered` 로 닫은 연결을 센다. `NetworkError` 의 `delivery` 필드는 만들지 않는다.
7. health 응답의 `closed_after_reuse` 와 `closed_total` 에 `request_not_delivered` 추가(masc, #51529). 6층과 같이 배포한다.
8. 6·7층을 배포해 `request_not_delivered` 의 상한을 잰 뒤, 상한이 0 이 아니고 시험 5 가 통과하면: `NetworkError` 의 `delivery` 필드와 연결을 여는 데 실패한 경우의 `Not_delivered`, `Http_client_cache.checkout` 의 새 연결 경로와 세 함수의 한 번 다시 보내기, §6 의 시험 1(나)와 3, 지난 §3.3 을 가리키는 주석 고치기(`http_client.ml` 의 `eof_error` 근처 주석, `test_http_client_cache.ml` 의 `RFC-0492 §3.3` 주석 둘)(agent_core).
