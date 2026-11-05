---
rfc: "0492"
title: "provider 연결은 프로세스 캐시 하나에서 다시 쓰고, 다시 쓸지는 닫힌 판정 하나로 정한다"
status: Draft
created: 2026-11-05
updated: 2026-11-05
author: claude
supersedes: []
superseded_by: null
related: ["0095"]
---

# RFC-0492: provider 연결은 프로세스 캐시 하나에서 다시 쓴다

- 날짜는 UTC 다.
- 코드는 `origin/main` `ee4dd9d1118` 기준이다.

## 0. 요약

Keeper 의 provider 요청은 매번 새 TCP·TLS 연결을 열고, 응답을 다 읽으면 닫는다. 요청 헤더에 `connection: close` 를 직접 넣는다. 연결을 다시 쓰는 캐시(`Http_client.create_cache`)는 있지만, 운영 코드에서 만드는 곳이 없다.

새 연결 한 번에 드는 시간은 host 마다 다르다(§1.1). opencode.ai 는 첫 바이트까지 591ms 가 걸리고, 같은 연결로 보낸 둘째 요청은 247ms 다. 2026-11-04 에 opencode 로 간 provider 요청은 9,604건이다.

결정은 셋이다.

1. 서버 프로세스가 연결 캐시 하나를 루트 switch 위에 만든다. provider transport 는 그 캐시를 쓴다(§3.1).
2. 연결을 캐시에 돌려놓을지 닫을지는 닫힌 합타입 `Reuse_verdict.t` 하나로 정한다. 지금은 세 곳이 서로 다른 규칙으로 정한다(§3.2).
3. 다시 쓴 연결이 응답 전에 끊겨도 http_client 안에서 다시 보내지 않는다. 그 실패는 타입으로 위에 올린다(§3.3).

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

- 서버가 시작할 때 루트 switch 와 서버 clock 으로 `Http_client_cache.create` 를 한 번 부른다. 자리는 `lib/server/server_runtime_bootstrap.ml` 이 `Fd_accountant.install_observers` 를 부르는 곳 옆이다.
- 캐시는 `Provider_connection_cache_ref` 에 두고, 설치한 domain 을 같이 적는다. `Runtime_agent.transport_for_provider` 는 그 domain 에서만 캐시를 받아 `make_http_transport ~connection_cache` 로 넘긴다. 설치되지 않았거나 다른 domain 이면 `None` 이고 지금처럼 요청마다 닫는다.
- 키는 지금처럼 scheme·host·port 다. 여러 Keeper 가 같은 origin 의 연결을 나눠 쓴다. 꺼낸 연결은 돌려놓기 전까지 그 요청만 쓴다.
- `idle_ttl_seconds` 는 20초다. §1.2 에서 가장 먼저 닫은 api.z.ai(25초)보다 짧다. §1.4 에서 60초로 늘려도 얻는 비율은 0.2~5.3%p 다.
  - 요청은 20초 넘게 논 연결을 받지 않는다. 꺼낼 때(`Http_client_cache.checkout`) 나이를 보고, 넘었으면 닫는다.
  - eviction fiber 는 TTL 의 절반마다 돈다. 그것만으로는 30초까지 논 연결이 요청에 나간다. 3층 리뷰가 이것을 찾았다.
- `max_idle_per_host` 는 기본값 8 을 둔다. 배포 뒤 `Http_client_cache.stats` 의 origin 별 idle 수로 다시 본다.
- 연결은 캐시의 switch 위에 열린다. 새 연결을 열 때 그 switch 에 fiber 를 붙인다. Eio 는 다른 domain 에서 switch 를 쓰면 `Invalid_argument "Switch accessed from wrong domain!"` 을 던진다(`eio/core/switch.ml` 의 `check_our_domain`, Eio 1.3).
  - 그래서 캐시는 설치한 domain 의 요청만 쓴다. 다른 domain 에 캐시를 넘기면 그 요청은 provider 오류로 끝난다. 3층 시험이 이것을 재현했다.
  - 지금 캐시를 쓰는 provider 요청(Keeper owner 턴, 자율 턴, 리뷰어, Fusion)은 모두 main domain 에서 돈다. serving domain 모드의 handler 는 Keeper owner mailbox 로 넘긴다.
  - 통계는 어느 domain 에서든 읽는다. 캐시 상태는 `Eio.Mutex` 와 `Atomic` 이 지키고, Eio 는 둘 다 여러 domain 에서 써도 된다고 적었다(Eio README "Mutexes and Semaphores").
  - 한 연결을 동시에 둘이 쓰지 않는 것은 checkout 이 지킨다.

### 3.2 돌려놓을지는 `Reuse_verdict.t` 하나로 정한다

```ocaml
type close_reason =
  | Request_failed          (* 요청이나 본문 읽기가 Error 또는 예외로 끝났다 *)
  | Not_persistent          (* HTTP/1.0 without keep-alive, connection: close, upgrade, framing 없음 *)
  | Body_not_drained        (* 응답 본문을 끝까지 읽지 않았다 *)
  | Transport_ended         (* 전송층이 EOF 를 냈다 *)

type t = Park | Close of close_reason

val decide :
  request_headers:Http.Header.t -> response:Http.Response.t ->
  body:[ `Drained | `Not_drained | `Transport_ended | `Failed ] -> t
```

- `Http_client_cache` 의 `return` 은 `release : t -> Key.t -> connection -> Reuse_verdict.t -> unit` 로 바뀐다. `Park` 이면 돌려놓고, `Close _` 면 닫는다. 연결을 끝내는 길은 이 함수 하나다.
- 세 함수는 각자 응답과 본문 상태를 `decide` 에 넘긴다. `with_client` 는 `f` 가 응답 헤더와 본문 상태를 같이 돌려주게 바뀐다. 그래야 응답을 보지 않고 돌려놓는 일이 없다.
- `response_connection_is_reusable` 는 `decide` 의 `Not_persistent` 판정이 된다. 규칙은 RFC 9112 §9.3 대로다. 요청이나 응답이 `close` 를 보냈으면 그 연결로 더 보내지 않는다(§9.6).
- `close_reason` 은 `Http_client_cache.stats` 에 이유별 닫은 수로 남긴다. 저장하지 않는다.
- 꺼낸 연결은 출처를 같이 든다(4층). `checkout` 은 `lease`(연결과 `Reused | Created`)를 돌려주고, `release` 는 그 `lease` 를 받는다. `stats` 는 다시 쓴 연결의 이유별 닫은 수를 한 벌 더 센다(`closed_after_reuse`). §6 은 다시 쓴 연결의 실패를 이것으로 센다.
- `http_client` 는 요청의 연결을 닫힌 합타입 하나로 든다. 요청 하나만 쓰는 연결(`One_shot`)과 캐시에서 빌린 연결(`Leased`)이다. 요청 하나만 쓰는 연결을 캐시에 돌려놓거나, 빌린 연결을 캐시 모르게 닫는 코드는 타입이 받지 않는다.

### 3.3 다시 쓴 연결이 끊겨도 http_client 는 다시 보내지 않는다

- 서버는 놀고 있는 연결을 언제든 닫을 수 있다(RFC 9112 §9.5). 캐시에서 꺼낸 순간과 서버가 닫는 순간이 겹칠 수 있다.
- 완성 요청은 POST 다. RFC 9110 §9.2.2 는 "A client SHOULD NOT automatically retry a request with a non-idempotent method unless it has some means to know that the request semantics are actually idempotent, regardless of the method, or some means to detect that the original request was never applied." 라고 적는다. http_client 는 원래 요청이 적용되지 않았다는 것을 알 수단이 없다.
- 그래서 http_client 는 다시 보내지 않는다. 다시 쓴 연결이 응답 첫 바이트 전에 끊긴 실패는 지금과 같은 `NetworkError` 로 올린다. 다시 보낼지는 지금 provider 재시도·cascade 정책이 정한다.
- TTL 을 서버가 닫는 시간보다 짧게 두는 것(§3.1)이 이 실패를 드물게 만든다. 배포 뒤 이 실패가 얼마나 나는지 §6 대로 센다.

## 4. 검토한 대안

- **Keeper 마다 캐시를 둔다.** 하지 않는다. Keeper 하나의 요청 사이 간격은 도구 실행 시간만큼 길다. origin 을 공유하면 다른 Keeper 가 막 끝낸 연결을 쓴다(§1.4).
- **`Runtime_agent.config` 에 캐시 필드를 더해 위에서 넘긴다.** 하지 않는다. `Runtime_agent.default_config`·`build`·`run` 을 부르는 곳이 lib 안에 네 파일 여덟 곳이고, 모두 같은 프로세스 캐시를 넘겨야 한다. 프로세스 범위 자원은 `Domain_pool_ref` 처럼 한 곳에서 설치한다. 단점은 의존이 시그니처에 드러나지 않는 것이다. 설치가 없으면 지금 동작이라 시험은 바뀌지 않는다.
- **domain 마다 캐시를 둔다(`Domain.DLS`).** 지금은 하지 않는다. 캐시를 쓰는 요청이 main domain 하나에서만 돈다(§3.1). domain 마다 두면 health 응답이 어느 캐시를 보여 줄지 정해야 한다.
- **host 마다 TTL 을 다르게 둔다.** 지금은 하지 않는다. 20초와 60초의 차이가 작다(§1.4). 설정 키가 하나 늘어난다.
- **꺼낼 때 소켓이 닫혔는지 먼저 본다.** 하지 않는다. Eio flow 에는 읽지 않고 닫힘을 보는 연산이 없다. 보고 난 뒤 보내기 전에 닫힐 수도 있어서 §3.3 의 실패를 없애지 못한다.
- **HTTP/2 로 바꾼다.** 해당 없다. `cohttp-eio` 는 HTTP/1.1 만 쓴다.

## 5. 영향

- 캐시가 설치된 서버에서 provider 요청은 놀고 있는 연결을 다시 쓴다. 그 요청의 첫 바이트가 §1.1 의 차이만큼 빨라진다.
- 요청 헤더에 `connection: close` 가 빠진다.
- 놀고 있는 연결이 origin 마다 최대 8개, 20초까지 열려 있다.
- 다시 쓴 연결이 서버 쪽에서 닫혀 있으면 그 요청은 `NetworkError` 로 끝난다(§3.3).

## 6. 검증

- 시험: `decide` 의 모든 입력 조합. `with_client`·`dispatch_sync_request`·`with_post_stream` 이 `connection: close` 응답, 본문을 덜 읽은 응답, 전송층 EOF 에서 연결을 돌려놓지 않는다. 같은 origin 의 연속 요청이 연결 하나를 다시 쓴다(`stats.reuse_count_total`).
- 배포 뒤: 캐시 `stats` 의 재사용 수와 새로 연 수, 이유별 닫은 수를 본다. 3층이 이 값을 `/health?full=1` 의 snapshot 필드 `provider_connection_cache` 로 낸다.
  - `/health` 는 인증 없이 열린 집계 화면이다. 그래서 origin 이름은 내지 않는다(RFC-0132). `max_idle_per_host` 를 다시 볼 값으로 origin 하나의 최대 idle 수만 낸다.
  - 다시 쓴 연결의 실패는 `closed_after_reuse` 의 `request_failed`·`transport_ended` 로 센다. `closed_total` 의 같은 이유 수에서 빼면 새 연결의 수다(#48933).
  - 이유별 수는 응답 전과 후를 나누지 않는다. 타임아웃도 `request_failed` 에 든다. 그래서 다시 쓴 연결과 새 연결의 실패율을 견준 차이로 다시 쓴 연결만의 실패를 본다.
- 비용 원장 `per_request` 행에는 `request_latency_ms` 만 있고 첫 바이트 시간이 없다. 그래서 첫 바이트가 얼마나 빨라졌는지는 원장으로 직접 재지 못한다. 요청 시간이 짧은 ollama_cloud(중앙값 2.9초)의 `request_latency_ms` 를 배포 전 같은 시간대와 견주는 것이 간접 확인이다.

## 7. 층

1. 이 문서.
2. #48633 병합 뒤: `Reuse_verdict` 와 `Http_client_cache.release`, 세 함수의 판정 교체와 시험(agent_core).
3. `Provider_connection_cache_ref` 설치와 `Runtime_agent.transport_for_provider` 배선, runtime health 응답의 캐시 `stats`(masc).
4. 꺼낸 연결의 출처(`lease`), `http_client` 의 연결 합타입, 다시 쓴 연결의 이유별 닫은 수와 health 응답의 `closed_after_reuse`(agent_core·masc, #48933).
