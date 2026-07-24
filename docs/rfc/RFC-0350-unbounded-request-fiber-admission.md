# RFC-0350 — Unbounded request-fiber admission (durable queue + lifecycle-sibling worker + typed saturation)

- Status: Draft
- Author: MASC Agent (for vincent)
- Date: 2026-07-20
- Related: 레인 보고서 `reports/masc-nondeterministic-lane-analysis-2026-07-17.html` (2026-07-17, repo 외부), #24886 (07-17 429 폭풍 인시던트), #25045 (board attention durable worker), RFC-0000 §1.2 (Four Laws) / §3.7 (`cap ≠ backpressure`), RFC-0277 (fusion per_hour_budget 삭제), RFC-0153 (Withdrawn), RFC-0192 (Retired)

## 0. Summary

07-17 인시던트 총평(레인 보고서)이 지목한 무제한 fork 4개 레인 중 board attention judge는 durable candidate + lifecycle-sibling 직렬 worker + candidate당 singleton exact flow로 수리됐다. MASC는 입력과 durable callback만 소유하고, target admission·provider-attempt dispatch·advance는 OAS가 소유한다. provider max-concurrent dead knob도 OAS `Provider_admission.with_admission` 배선으로 수리됐다. **나머지 3개 — fusion run fork, keeper_msg 요청 fork, HTTP/MCP accept/request fiber — 는 2026-07-18 fresh grep 기준 여전히 무제한이다.**

본 RFC는 이 3개 갭에 같은 구조적 경계를 적용한다: **(1) backlog는 살아있는 fiber가 아니라 durable store에, (2) 실행은 owner lane의 직렬(또는 고정 소수 워커) drain이 독점, (3) 포화는 생산자에게 typed signal로 되돌린다.** RFC-0277이 문서화한 `cap ≠ backpressure` 교훈에 따라 임의 숫자 rate cap은 재도입하지 않는다. 숫자 상한이 불가피한 지점(HTTP 동시 연결)은 typed saturation signal + 명시적 거부 응답(503/Retry-After)으로 처리하고 silent drop을 금지한다.

## 1. Problem (evidence)

### 1.1 일반 실패 모드 (07-17 인시던트의 구조)

레인 보고서 총평을 인용한다:

> 현재 N=16이 살아있는 것은 설계 덕이 아니라 트래픽이 낮아서이며, 첫 붕괴 지점은 CPU도 fiber 수도 아니라 (a) 단일 Eio 도메인 수렴 + (b) 무제한 큐/원장으로의 생산 O(N·M) vs 고정 drain(keeper당 30초에 stimulus 1개)의 교차점이다. 07-17 인시던트는 이 일반 실패 모드의 board-attention 사례일 뿐이다.

board attention은 이 모드의 **첫 번째** 발현이었고 durable candidate를 lifecycle-sibling 직렬 worker가 candidate당 singleton exact flow로 drain하도록 수리됐다. 아래 3개 레인은 동일한 형태(생산 무제한 · 실행 무제한 fork · drain 부재 또는 고정)가 그대로 남아 있다.

### 1.2 Gap A — fusion run fork

- `lib/fusion/fusion_tool.ml:156`: 호출당 `Eio.Fiber.fork ~sw`. 세마포어·admission gate 없음. HTTP 진입점(`lib/server/server_dashboard_http_keeper_api_post.ml:112`)도 동일 경로.
- `lib/fusion_core/fusion_policy.ml:301-311` (`decide`): admission 판정은 `enabled`/`preset 존재`/`depth(Nested 거부)`뿐 — 동시 실행 수·대기·부하에 대한 판정이 구조적으로 없다.
- 단, `per_hour_budget` 삭제는 **문서화된 설계 결정**이다 (RFC-0277 §3, RFC-0000 §3.7 (Fusion 경계 계약), #22051): "cap은 적절한 backpressure가 아니다". 따라서 단순 숫자 cap 재도입은 본 RFC의 범위 밖이며 기각 사유다.
- durable 기반은 이미 존재한다: `lib/fusion_core/fusion_run_registry.ml:8-9` — "optional append-only JSONL backing under `<base-path>/.masc/fusion-runs.jsonl`" (`:76-83` append). 그러나 이 registry는 실행 경계가 아니라 가시성 전용 기록이고, 실행은 여전히 fork-per-call이다.

### 1.3 Gap B — keeper_msg 요청 fork

- `lib/keeper/keeper_msg_async.ml:2320` 부근: 제출 요청당 `Eio.Fiber.fork_daemon ~sw:background_sw`. submit 경로 어디에도 세마포어/max_fibers가 없다.
- 각 워커는 `Keeper_turn_admission.run_serialized` (`lib/keeper/keeper_turn.ml:1054`)로 keeper의 turn slot에 park하는데, 대기열 `waiting_entries`는 무상한 리스트다: `lib/keeper/keeper_turn_admission.ml:96` (`mutable waiting_entries : (int * float) list`), `:293` (무조건 cons).
- 부분 경화는 되어 있다: 요청은 durable 영속화되고 fork 실패는 typed `Background_fork_failed` (`keeper_msg_async.ml:156`)로 반환된다. 남은 갭은 **backlog가 살아있는 daemon fiber + mutex waiter로 표현된다**는 점이다 — wedged keeper 하나에 대기 fiber가 무제한으로 쌓인다.

### 1.4 Gap C — HTTP/MCP accept + request fiber

- accept loop 3종: `lib/server/server_bootstrap_http.ml:157` (h1), `:225` (h2), `:294` (auto) — accept된 TCP 커넥션당 `Eio.Fiber.fork ~sw`, 세마포어 없음. 유일한 한도는 kernel listen backlog 128 (`server_bootstrap_http.ml:35`, `MASC_TCP_LISTEN_BACKLOG`).
- MCP 요청 fiber: `lib/server/server_mcp_transport_http.ml:375` — JSON-RPC POST당 두 번째 무제한 fork. `masc_done`의 inline 완료리뷰 LLM 호출이 이 fiber 위에서 동기 실행된다 (cross_verifier, provider 예산 최대 600s) — N개 동시 완료 = N개 동시 LLM 호출이 열린 HTTP 응답을 단일 도메인에 고정한다.
- `MASC_HTTP_MAX_CONNECTIONS`는 dead knob + 오용: `lib/http_server_eio.ml:14,24`에서 선언(기본 512)되지만 h1/auto accept 경로에서 읽는 곳이 없고, `lib/http_server_h2.ml:283`에서는 `~backlog:config.max_connections`로 **kernel listen backlog 값으로 오용**된다(h2 자체 기본값은 128, `:13,19`). 파싱되지만 바인딩되지 않는 knob은 운영자 기만이다 (보고서 §3-②).
- kernel backlog 초과분은 연결을 **silent drop**한다 — LAW 3 위반이 내장된 유일한 "한도"다.

### 1.5 repo가 이미 받아들인 경계 패턴 (선례)

1. **board attention judge** (#25045 계열): 생산자는 durable candidate 기록 + typed wake 요청만 하고, Keeper lifecycle의 sibling worker가 candidate를 하나씩 직렬 drain한다. 각 candidate는 singleton exact flow이며 MASC는 immutable 입력과 before-dispatch/before-advance durable callback만 소유한다. target admission·provider-attempt dispatch·advance는 OAS가 소유하고, MASC에는 batch/TTL 또는 provider 재시도 정책이 없다. record 경로는 모델 호출을 fork하지 않는다.
2. **provider max-concurrent**: dead knob을 OAS `Provider_admission.with_admission` (`oas/lib/llm_provider/provider_admission.mli:26-33`)에 배선 — 초과분은 drop이 아니라 slot 대기.
3. **HITL Gate Auto Judge**: atomic claim-set + durable queue + chained drain (`keeper_gate.ml:304` `claim_auto_judge`, claim-set 타입 :283-294) — 보고서가 "구조적으로 올바르게 bounded된 유일한 LLM 레인"으로 확인한 exemplar.

본 RFC는 새 패턴을 발명하지 않고 이 세 선례를 3개 갭에 이식한다.

## 2. Non-goals

- `per_hour_budget` 또는 어떤 시간당/분당 숫자 rate cap의 재도입 (RFC-0277 문서화 결정, §1.2).
- RFC-0192가 retire한 MASC 소유 **provider-attempt** admission queue의 부활 — 레이어가 다르다 (§6).
- OAS 강제 의미론 변경. provider-attempt 동시성은 OAS 소유로 유지 (RFC-0000 §2 Boundary Law).
- 단일 Eio 도메인 수렴 자체의 해소 (별도 프로그램; 본 RFC는 무제한 fiber **생성**이 그 수렴을 증폭시키는 것만 차단한다).
- SSE/세션 플레인 한도 (이미 bounded: max_clients 200, per-client 256 버퍼 등).
- board attention·librarian·supervisor backoff 등 보고서의 다른 갭 — 각자의 RFC/PR이 소유.

## 3. 설계 제약 (헌법 정합성)

- **LAW 1 Activity First**: 거부는 요청 단위 typed 응답이며 keeper를 terminal로 만들지 않는다. Saturated를 받은 생산자는 재시도 가능하고 keeper는 Active/Awaiting/Recovering을 유지한다.
- **LAW 2 Decision Boundary**: admission/거부/대기 배정은 전부 결정론(큐 위치, typed FSM 상태, slot 점유)이다. LLM 판단·문자열·점수·연속 횟수는 admission 권한이 없다.
- **LAW 3 Everything Observed**: admission·saturation·거부·대기 전부 typed 이벤트 + counter + causal ID(run_id/request_id/connection id)로 관측된다. **Silent drop 금지** — kernel backlog에 의한 현재의 조용한 연결 유실도 이 원칙의 위반으로 간주하고 제거 대상에 포함한다.
- **LAW 4 Hard Cut**: 새 경계 검증 후 fork-per-request 경로를 즉시 삭제한다. compatibility dual-path·장기 feature flag를 두지 않는다. LAW 4의 "Fiber ≠ Durable job"(Eio Switch는 lexical lifetime scope, 장기 생존성은 store+dispatcher+receipt)이 이 RFC의 직접적 근거다 — 3개 갭 전부가 이 원칙을 위반 중이다.
- **RFC-0277 교훈 (`cap ≠ backpressure`)**: 경계는 숫자가 아니라 구조여야 한다 — (a) 실행 소유권(누가 실행하는가), (b) durability(backlog가 어디 사는가), (c) signal(포화가 생산자에게 typed로 되돌아가는가). 숫자 상한이 불가피한 지점(소켓 동시 연결 수)에서는 그 숫자가 typed saturation signal + 명시적 거부 응답과 결합해야 하며, 값 자체는 본 RFC가 결정하지 않는다 (§7 NEEDS_DECISION).

## 4. To-Be 설계

### 4.A fusion run — durable run queue + owner-lane drain

- **생산자 (submit)**: `Fusion_policy.decide` (변경 없음) 통과 후, fork 대신 registry의 JSONL backing에 `Queued { run_id; request; enqueued_at }`를 영속화하고 호출자에게 즉시 typed receipt `Accepted { run_id; queue_position }`를 반환한다. keeper 턴은 차단되지 않는다 (현재와 동일한 out-of-band 계약, RFC-0000 §3.7 "Async by design — keeper turn 비차단" 유지).
- **실행 (owner lane)**: base_path당 **1개의 drain fiber**가 `Queued`를 FIFO로 claim해 `run_orchestrator`를 자기 위에서 실행하고 `Queued → Running → Completed`를 같은 durable registry에 전이한다. fusion 동시성 = drain 워커 수(시작은 1) — config knob이 아니라 워커 토폴로지의 typed 속성.
- **Backpressure**: 생산자는 항상 durable receipt를 받는다 (silent drop 없음). 대기가 선언된 포화 정책을 넘으면 submit이 typed `Saturated { retryable = true }`를 반환한다. 포화 정책의 구체 값은 NEEDS_DECISION (§7-1) — 구조적 요구는 신호가 typed·재시도 가능·관측 가능하다는 것뿐이다.
- **Orphan recovery**: 부팅 시 live 워커 없이 남은 `Queued`/`Running` 행은 drain이 재큐한다 (registry가 이미 persisted 행을 로드; RFC-0000 §3.7 line 288의 "orphan Running drop"은 "orphan-Queued 재큐"로 대체).
- **마이그레이션 순서**: (1) registry event에 `Queued` variant + drain 워커 추가, submit을 queue 경로로 전환, (2) hard cut — `fusion_tool.ml:156`의 `Eio.Fiber.fork`와 out-of-band background 경로 삭제. dashboard HTTP fusion POST도 같은 큐를 통과.
- **실패 의미론 불변**: `Denied`/`Sink_failed` → `append_chat_failure`, Cancelled → `mark_completed (cancelled)` + route discard (기존 typed terminal 유지).

### 4.B keeper_msg — typed bounded 대기열 → durable receipt 경계

2단계로 나누되 각 단계는 독립 PR로 hard cut한다.

- **Phase 1 (최소 침습, 즉시 경계)**: `waiting_entries`를 typed bounded queue로 만든다. `run_serialized` 진입 admission이 `Waiting { waiter_id; position }` | `Rejected (Saturated { retryable = true; queue_depth })`를 반환하고, Saturated는 submit 경로가 typed MCP/HTTP 에러로 매핑해 생산자가 재시도할 수 있다. keeper lane 상태에는 무관 (LAW 1). bound 값은 NEEDS_DECISION (§7-2) — 구조적 성질은 "처리량이 아니라 **대기자 수**를 bound한다"는 것이다.
- **Phase 2 (root fix)**: operator 메시지를 chat이 이미 가진 durable receipt 경계로 옮긴다 — persist-then-lease + keeper당 single-flight dispatch fiber가 FIFO로 lease (`Keeper_chat_queue` 패턴). "대기"는 live daemon + blocked fiber가 아니라 durable `Pending` receipt가 된다. 요청당 fork_daemon과 무제한 mutex waiter list가 **타입 수준에서** 소거된다 (backlog의 live-fiber 표현이 존재하지 않음).
- **Hard cut**: Phase 2 검증 후 요청당 `fork_daemon` submit 경로 삭제. `Background_fork_failed`는 단일 supervised dispatch fiber 기동 실패에만 남긴다.
- **순서 근거**: Phase 1은 작은 typed 변경으로 blast radius를 즉시 bound하고, Phase 2는 구조적 root fix로 후속 train에서 완결한다.

### 4.C HTTP/MCP — accept admission + typed 503/Retry-After

- **Accept admission**: 프로세스 전역 연결 slot registry(atomic counter + typed admitted set)를 accept 지점에서 **fork 이전에** 동기 검사한다. 초과 시 수락된 소켓에 typed 503 + `Retry-After`를 쓰고 닫는다 (h1/auto) / h2는 연결 거부를 typed로 — kernel drop이 아니라 **명시적 거부 응답**이다.
- **MCP 요청 admission**: `server_mcp_transport_http.ml:375`의 per-POST fork에 같은(또는 request-class 별도) slot을 적용, 포화 시 typed 503 JSON-RPC 에러 + `Retry-After` — 클라이언트가 재시도 가능.
- **h2 backlog 오용 정정**: `lib/http_server_h2.ml:283`의 `~backlog:config.max_connections`를 분리한다 — kernel backlog는 `MASC_TCP_LISTEN_BACKLOG`(기본 128)로 일원화하고, 연결 admission은 자체 typed knob을 갖는다. `MASC_HTTP_MAX_CONNECTIONS`는 (a) 실제 admission slot의 소스로 배선하거나 (b) 삭제한다 — dead knob도 오용 knob도 운영자 기만이므로 제3의 현상 유지는 없다. 선택은 NEEDS_DECISION (§7-3).
- **숫자 상한의 위치**: 값은 NEEDS_DECISION. 구조적 계약은 상한 도달이 반드시 typed saturation signal(counter + 이벤트) + 명시적 거부 응답으로 표면화된다는 것, silent drop은 어떤 경로에도 남기지 않는다는 것이다.
- **마이그레이션**: 단일 PR train — 3개 accept loop + MCP transport에 admission 배선, h2 backlog 정정, knob 배선 또는 삭제를 같은 train에서 완료 (LAW 4; 장기 enforce flag 없음). 완료 후 이전 무제한 fork 경로는 코드에 남지 않는다.
- streaming-vs-unary 연결 클래스 구분은 본 RFC 범위 밖 (후속으로 기록).

## 5. Acceptance criteria (기계 판정)

**A. fusion**

- `git grep -n "Eio.Fiber.fork" lib/fusion/fusion_tool.ml` → hard cut 후 0건.
- `git grep -n "Queued" lib/fusion_core/fusion_run_registry_event.ml` → ≥ 1건.
- 신규 테스트 `test_fusion_run_drain_serial`: 2개 run을 연속 제출하고 실행 구간(start/end 타임스탬프)이 겹치지 않음을 assert + 두 run 모두 durable registry에서 `Completed` terminal 도달.

**B. keeper_msg**

- Phase 1: `git grep -n "Saturated" lib/keeper/keeper_turn_admission.ml` → ≥ 1건. 신규 테스트 `test_turn_admission_saturated_typed`: bound+1번째 waiter가 typed `Rejected (Saturated _)`를 받고 keeper lane FSM 상태가 Active를 유지함을 assert (LAW 1).
- Phase 2: `git grep -n "fork_daemon" lib/keeper/keeper_msg_async.ml` → hard cut 후 0건(dispatch fiber 기동 제외 시 주석으로 명시).

**C. HTTP/MCP**

- `git grep -n "backlog:config.max_connections" lib/http_server_h2.ml` → 0건.
- `git grep -rn "MASC_HTTP_MAX_CONNECTIONS" lib/` → 선언만 있고 읽는 곳이 없는 상태(현재)가 해소됨: admission 모듈에서의 실제 참조가 존재하거나 선언 자체가 삭제됨.
- 통합 테스트 `test_http_accept_admission_503`: bound+1개 연결을 열어 초과분이 typed 503 + `Retry-After` 헤더를 받음을 assert하고, `Transport_metrics` saturation counter가 정확히 거부 건수만큼 증가함을 assert (LAW 3 — silent drop 없음).

**공통 런타임 관측**

- saturation/거부/대기 이벤트가 dashboard/OTel에 causal ID(run_id/request_id/연결 id)와 함께 표면화된다.
- 2× 상한 부하 테스트에서 프로세스 fiber 수가 (bound + drain 워커 수 + 기존 상주 fiber)를 초과 성장하지 않음을 기존 transport/fiber 메트릭으로 확인.

## 6. 기존 RFC와의 관계

- **RFC-0000 §1.2 (Four Laws)**: §3이 정합성 근거. 특히 LAW 4 "Fiber ≠ Durable job"이 이 3개 갭의 공통 위반 지점이다.
- **RFC-0277 / RFC-0000 §3.7 (Fusion 경계 계약) (#22051)**: `per_hour_budget` 삭제 결정을 유지한다. 본 RFC는 rate cap을 재도입하지 않는다 — fusion의 경계는 "허용 run 수"가 아니라 "실행 소유권(단일 drain)"이다. §4.A의 Saturated 신호는 cap이 아니라 대기 상태의 typed 표면화다.
- **RFC-0153 (Withdrawn)**: MASC↔OAS **runtime-attempt** 레이어를 다뤘다 (saturation은 측정·표시하되 provider call의 pre-dispatch 거부는 안 함). 본 RFC는 그 한 층 위 — 요청 진입 경계(도구 호출, keeper_msg submit, TCP accept) — 에서 동작하며 OAS 측 attempt 의미론은 건드리지 않는다. dead scaffold `OllamaSaturationSkip` (`lib/keeper_metrics/keeper_metrics.ml:104,322`)는 현상 유지; 배선/삭제는 본 RFC 범위 밖.
- **RFC-0192 (Retired)**: MASC 소유 **provider-attempt** admission queue + 누적 대기 예산을 retire했다. 본 RFC는 이를 되살리지 않는다 — keeper와 provider 사이에 어떤 큐도 삽입하지 않고, provider 용량 소유는 OAS에 남는다. 여기서의 큐는 masc 자신의 요청 경계에 대한 것으로, RFC-0192가 규정한 계약("provider-attempt timeout/progress는 provider/runtime 경계 소유")과 충돌하지 않는다.
- **레인 보고서 (2026-07-17)**: 갭 인벤토리와 일반 실패 모드의 출처. 보고서 정오표가 확인한 2개 후속 RFC(masc#25055 Draft)와의 중첩 여부는 리뷰 시점에 대조한다 — 본 RFC는 보고서의 무제한 fork 3개 레인만을 스코프로 하며, 다른 후속 RFC가 같은 레인을 다루면 본 RFC가 그쪽에 양보하거나 병합한다.

## 7. NEEDS_DECISION (본 RFC는 값을 결정하지 않는다)

1. **fusion 포화 정책**: Saturated를 반환하는 조건(큐 depth? 최장 대기 연령? 아니면 항상 durable 수용하고 거부 없음?). 구조(typed·retryable·observed)만 여기서 고정한다.
2. **keeper_msg waiter bound 값** (Phase 1) 및 Phase 2 도래 시 그 bound의 존폐.
3. **HTTP 연결 admission knob**: `MASC_HTTP_MAX_CONNECTIONS`를 실제 slot 소스로 배선할지, 삭제하고 신규 named knob(per-listener vs 프로세스 전역, streaming/unary 클래스)을 둘지. 값 자체 포함.
4. **fusion drain 워커 수**: 시작은 1. >1이 필요해지는 조건은 운영 결정이며 본 RFC가 선결하지 않는다.

이 네 지점에 운영자/RFC 결정 없이 임의 값을 박는 것은 RFC-0277이 기각한 안티패턴의 재도입이므로, 본 RFC는 구조만 합의 대상으로 올린다.

## 8. Blast radius

- **A**: `lib/fusion/fusion_tool.ml`, `lib/fusion_core/fusion_run_registry.ml` / `fusion_run_registry_event.ml`, `lib/server/server_dashboard_http_keeper_api_post.ml` (HTTP fusion 진입), dashboard run-status projection (`Queued` 신규 상태 표면화).
- **B**: `lib/keeper/keeper_turn_admission.ml`, `lib/keeper/keeper_msg_async.ml`, `lib/keeper/keeper_turn.ml:1054` 호출부, Saturated의 MCP/HTTP 에러 매핑.
- **C**: `lib/server/server_bootstrap_http.ml` (accept loop 3종), `lib/server/server_mcp_transport_http.ml`, `lib/http_server_h2.ml`, `lib/http_server_eio.ml`, `Transport_metrics`.
- **행동 변화**: 포화 시 생산자가 무제한 큐잉 대신 typed 거부를 받는다 — 의도된 변화이며 CHANGELOG에 명시. 기존 클라이언트는 `Retry-After`를 존중하는 재시도가 필요하다 (대시보드/MCP 클라이언트 확인 항목).

## 9. Workaround-rejection self-check (CLAUDE.md)

- Telemetry-as-fix 아님: 경계가 실제로 fork를 막고, 메트릭은 부가다.
- cap/cooldown 류 증상 억제 아님: rate cap 재도입 없음. 경계는 소유권 + durability + typed signal (§3).
- 문자열/부분일치 분류기·N-of-M·catch-all 아님: admission 결과는 전부 typed variant로 exhaustive match.
- silent drop 제거(kernel backlog → typed 503)는 부수 효과가 아니라 수정의 일부다.
- Phase 분할(4.B)은 hard cut 회피 수단이 아니라 각 Phase가 독립 hard cut을 갖는 시퀀싱이다.

## 10. Implementation note (post-approval)

- 3개의 독립 PR train (A/B/C). blast radius 순서 권장: C (front door) → B Phase 1 → A → B Phase 2. §5의 테스트는 해당 메커니즘과 같은 PR에 동착한다.
- 각 train은 자체 hard cut으로 완결한다; train 간 의존 없음 (공유 admission primitive를 도입하고 싶어지면 — 보고서 §3-②의 "HITL claim-set 추출" 제안 — 그것은 본 RFC 수용 후 별도 RFC로).
