# RFC-0357 — chat lease는 turn 슬롯을 얻은 뒤에

- Status: Draft
- Author: MASC Agent (for vincent)
- Date: 2026-07-29
- Related: #26283 (closed, 재설계 필요 판정), #26307 (경합 테스트), #26308 (main 결함 2건), #26004, #24404, #23850, #24865, RFC-0350 (§9)

## 0. Summary

keeper 하나에 turn 슬롯은 하나다. proactive 턴(heartbeat)과 chat 턴이 그 슬롯을 두고 경합한다. 두 레인의 요구가 다르므로(proactive는 건너뛰고, chat은 기다린다) 앞지르기를 막을 장치가 하나는 필요하다. 지금은 그 장치가 **큐 스냅샷을 훔쳐보는 게이트**이고, 이 RFC는 그것을 **mutex 대기열**로 옮긴다.

핵심 변경은 한 줄로 말할 수 있다: **queue consumer가 receipt를 lease하기 전에 turn 슬롯을 먼저 얻는다.**

이 코드베이스는 이미 같은 원칙을 다른 durable write에 적용하고 있다. transcript user row는 `on_admitted` 안에서, 즉 슬롯을 얻은 뒤에 쓴다(`server_routes_http_keeper_stream.ml:1740`). lease만 그 원칙 밖에 있다.

## 1. 근거

### 1.1 게이트는 이미 없어진 문제를 막고 있다

게이트의 정당화 주석은 `#23850`(2026-07-09)에서 작성됐고, 그 PR 본문이 `the consumer polling drain is unchanged`라고 적고 있다 — **폴링하는 consumer** 전제다.

`#24404`(2026-07-14)가 `set_slot_transition_observer`를 배선했다. 그전까지 이 훅은 프로덕션 호출자가 0개였다(`keeper_turn_admission.ml:255-260` → `server_bootstrap_loops.ml:1650-1659`). 이후 consumer는 `Turn_released` 시점에 edge-wake 된다.

주석의 인과 설명이 코드보다 5일 낡았다.

### 1.2 실측 — 게이트가 chat에게 사주는 것은 없다

프로덕션 `Keeper_chat_consumer.run` 루프와 proactive 드라이버를 같은 슬롯에 붙여 돌렸다. provider 호출만 고정 sleep으로 대체했다. 3회 반복 모두 동일하다. 하네스는 `#26307`.

| 코드 상태 | 연속(back-to-back) | heartbeat 형태 | 대기 |
|---|---|---|---|
| 현재 main (게이트) | 3/3 | 3/3 | 0.09 · 0.19 · 0.09s |
| `#26283` 두 커밋 (게이트 제거 + 대기열 등록) | 3/3 | 3/3 | 0.10 · 0.20 · 0.10s |
| 게이트만 제거 (대기열 등록 없음) | **0/3** | 3/3 | — |

세 번째 줄이 이 RFC의 전제다. **둘 중 하나는 반드시 있어야 한다.** 그리고 첫째와 둘째의 처리율이 같으므로, 게이트가 하는 일은 대기열 등록으로 대체 가능하다.

### 1.3 Eio.Mutex가 대기자를 앞지르기로부터 보호한다

`~/.opam/5.5.0/lib/eio/eio_mutex.ml:36-49`:

```ocaml
| Locked ->
  begin match Waiters.wake_one t.waiters `Take with
    | `Ok -> ()                          (* 대기자에게 직접 인계, state는 Locked 유지 *)
    | `Queue_empty -> t.state <- Unlocked
  end;
```

대기자가 있으면 락이 관측 가능하게 비지 않는다. 따라서 **chat이 실제로 줄을 서 있는 한 `try_lock`은 실패한다.** §1.2의 두 번째 줄이 이것의 측정값이다.

### 1.4 지금의 게이트는 파생상태 위에 서 있다

`Chat_backlog`는 `Keeper_chat_queue.snapshot`의 pending/inflight 개수다. `pending`이 줄지 않는 상태(예: 운영자 개입 대기)에서는 빠져나올 경로가 없다. 그리고 `keeper_turn_admission.ml:316`이 이 peek을 `a lock-only, non-suspending peek`이라고 서술하는데, `Keeper_chat_queue.snapshot`은 `with_entry_lock`으로 `Eio.Mutex`를 취득하며(`keeper_chat_queue.ml:2175-2184`) 경합 시 suspend한다 — 게이트가 `waiting_count` 검사와 `try_lock` 사이에 suspension point를 삽입한다(#26308).

## 2. Non-goals

- proactive 레인이 슬롯을 기다리게 만드는 것. proactive는 주기적 tick이고 오래된 사이클이 쌓이면 안 된다. `try_lock` 유지.
- `Keeper_chat_queue`의 receipt lifecycle 변경. `Pending → Inflight → Delivered | Failed`와 restart 시 `Recovery_required`는 그대로 둔다. 이 RFC는 **언제 `Inflight`로 넘어가는지**만 바꾼다.
- 마이그레이션 코드. 기존 디스크 상태를 읽기 위한 분기를 만들지 않는다.
- `run_chat_if_free`(dashboard-direct HTTP 경로)의 fail-fast 정책. 요청이 블록되면 안 되는 별개 요구다.
- RFC-0350이 소유한 무제한 fiber 생성 문제 (§9).

## 3. 설계

### 3.1 현재 순서

```
consumer wake
  → snapshot_in_flight 확인 → 바쁘면 물러남          (keeper_chat_consumer.ml:659-668)
  → lease_next                                      (:670)   ← 디스크에 Inflight 기록
  → dispatch_lease → snapshot_in_flight 재확인 → 바쁘면 nack (:596-604)
  → fork → run_leased_turn → handle_turn            (:496-500, :471)
  → ... 13 hop ...
  → run_serialized → Eio.Mutex.lock                 (keeper_turn.ml:989, keeper_turn_admission.ml:419)
  → on_admitted () = append_queued_user_row_once ()  (keeper_turn.ml:993, stream:1740)
  → 턴 실행
```

`lease_next`와 `Eio.Mutex.lock` 사이에 13 hop이 있다. 그 구간 내내 receipt는 `Inflight`인데 아무것도 실행되고 있지 않다.

### 3.2 바꿀 순서

```
consumer wake
  → peek_next                                       ← 디스크 변경 없음. receipt는 Pending
  → fork → handle_turn (peek한 receipt_id + message로)
  → ... 13 hop ...
  → run_serialized → Eio.Mutex.lock                 ← 여기서 줄을 선다. 여전히 Pending
  → on_admitted () = lease_exact ∘ append_queued_user_row_once
  → 턴 실행
```

`delivery_key`는 `item.receipt_id`만으로 만들어지고(`keeper_chat_consumer.ml:589-594`), `queued_message`는 `item.message`다(`:587`). `active_receipt`가 둘 다 들고 있으므로(`keeper_chat_queue.mli:175-179`) peek으로 `handle_turn`의 인자를 전부 구성할 수 있다. **`handle_turn`의 시그니처는 lease를 강제하지 않는다.**

### 3.3 왜 consumer를 `run_serialized`로 감싸지 않는가

감싸면 self-deadlock이다. `Eio.Mutex`는 소유자를 추적하지 않고(`eio_mutex.ml:8-13`) `lock`에 self-check가 없다(`:54-75`). 같은 fiber가 두 번 잡으면 자기 대기열에 자기를 넣고 영원히 멈춘다 — 슬롯을 쥔 채로. 타임아웃도 진단도 없다.

`run_locked_with_token`(`keeper_turn_admission.ml:238-268`)도 중첩에 재사용할 수 없다. shutdown 경로(`:252`)와 release 경로(`:258`) 양쪽에서 무조건 `Eio.Mutex.unlock`하므로, 중첩 사용은 바깥 락을 풀고 바깥의 unlock이 `eio_mutex.ml:38-42`에 걸려 슬롯을 `Poisoned`로 만든다.

그래서 새 진입점을 만들지 않고 **이미 임계구역 안에서 실행되는 `on_admitted`를 쓴다.** `on_admitted`는 이미 queued turn 전용으로 배선돼 있다:

```ocaml
(* server_routes_http_keeper_stream.ml:1964 *)
let on_admitted = if queued_turn then Some on_queue_turn_admitted else None in
```

## 4. 구현 지점

### Phase 1 — 큐 API 두 개 추가 (동작 변화 없음)

`lib/keeper/keeper_chat_queue.mli` / `.ml`

```ocaml
(** FIFO head를 읽는다. 어떤 durable 상태도 바꾸지 않는다. *)
val peek_next :
  keeper_name:string ->
  [ `Head of active_receipt
  | `Empty
  | `Recovery_required of recovery_evidence
  | `Error of mutation_error
  ]

(** [receipt_id]가 여전히 FIFO head일 때만 lease한다. head가 바뀌었으면
    [`Head_moved]로 실패하고 아무것도 변경하지 않는다. *)
val lease_exact :
  keeper_name:string ->
  receipt_id:Receipt_id.t ->
  [ `Leased of lease
  | `Head_moved
  | `Empty
  | `Already_leased of string
  | `Recovery_required of recovery_evidence
  | `Error of mutation_error
  ]
```

`lease_exact`는 `lease_next`(`keeper_chat_queue.ml:2596-2620`)와 같은 `Lease_transition` 트랜잭션을 쓰되 head 일치를 조건으로 건다. `` `Head_moved ``는 운영자 recovery 조치가 head를 바꾼 경우에 발생한다 — silent하게 다른 receipt를 집지 않기 위한 CAS다.

`lease_next`는 Phase 3에서 호출자가 없어지면 제거한다.

### Phase 2 — lease를 `on_admitted`로 이동

**(a) `handle_turn` 시그니처에 admit thunk 추가** — `lib/keeper/keeper_chat_consumer.mli:99`

```ocaml
handle_turn:
  (sw:Eio.Switch.t ->
   keeper_name:string ->
   delivery_key:Keeper_chat_delivery_identity.delivery_key ->
   queued_message:Keeper_chat_queue.queued_message ->
   admit:(unit -> (Keeper_chat_queue.lease, string) result) ->   (* 추가 *)
   turn_outcome) ->
```

**(b) consumer가 peek으로 전환** — `lib/keeper/keeper_chat_consumer.ml`

| 라인 | 현재 | 변경 |
|---|---|---|
| `:659-668` | `snapshot_in_flight`가 `Some`이면 `release` | 삭제. 바쁨은 더 이상 dispatch 여부를 결정하지 않는다 |
| `:670` | `lease_next` | `peek_next` |
| `:585-594` | `dispatch_lease`가 `lease`를 받아 `item.receipt_id`/`item.message` 사용 | `active_receipt`를 받도록 변경. 필드 접근은 동일 |
| `:596-604` | 두 번째 `snapshot_in_flight` 검사 → `nack_or_warn` | 삭제 |
| `:469-500` | `run_leased_turn` / `dispatch_queued_turn` | `admit` thunk를 만들어 `handle_turn`에 전달 |

**(c) 서버 쪽 배선** — `lib/server/server_bootstrap_loops.ml:1668-1670`, `lib/server/server_routes_http_keeper_stream.ml:1740`

```ocaml
(* stream:1740 — 현재 *)
let on_queue_turn_admitted () = append_queued_user_row_once ()

(* 변경: lease를 먼저, 그다음 user row *)
let on_queue_turn_admitted () =
  match admit () with
  | Error detail -> Error detail
  | Ok _lease -> append_queued_user_row_once ()
```

`admit`은 `process_single_turn`의 새 인자로 `server_bootstrap_loops.ml`의 consumer 클로저에서 내려온다. 이미 `~queued_turn:true`와 `~delivery_key`를 같은 경로로 넘기고 있다(`:1824-1826`).

### Phase 3 — 게이트 제거

`lib/keeper/keeper_turn_admission.ml` / `.mli`

| 대상 | 라인 |
|---|---|
| `Chat_backlog` variant | `.ml:24-28`, `.mli:41-57` |
| 인코더 3곳 | `.ml:85`, `:96-101`, `:119-124` |
| `yield_to_chat_backlog` 파라미터 + 큐 peek | `.ml:305-347` |
| `waiting_count > 0` 사전검사 | `.ml:333` |
| `run_compaction_if_free` · `run_admin_if_free` | `.ml:380-386`, `.mli:172-209` |

`lib/keeper/keeper_heartbeat_loop_cycle.ml:230-236` — `Chat_backlog` 로깅 분기 제거.

`yield_to_chat_backlog`가 사라지면 `run_if_free` / `run_compaction_if_free` / `run_admin_if_free`가 동일해진다. 세 이름을 `run_if_free` 하나로 접는다. **이 접기는 `Chat_backlog`가 완전히 제거될 때만 유효하다** — peek을 남긴 채 접으면 `#24865`의 우선순위 역전이 되살아난다(`keeper_turn_admission.mli:189-195`).

진입점 8개 → 3개(`run_if_free`, `run_serialized`, `run_chat_if_free`), admission 권한 5개 → 1개(mutex).

## 5. 남는 미결정 하나 — lease를 consumer에게 어떻게 돌려주는가

`on_admitted : unit -> (unit, string) result`는 payload를 반환하지 않는데, consumer는 finalize에 `lease_id`가 필요하다(`keeper_chat_consumer.ml settle_lease :294`).

**안 A — dispatch-local ref.** `admit` 클로저가 dispatch 스코프의 `lease option ref`를 채우고, `handle_turn` 반환 후 consumer가 읽는다. `on_admitted`는 같은 fiber에서 턴 본문보다 먼저 실행되므로 순서는 보장된다. ref는 dispatch 1건에 국한되고 전역 상태가 아니다. 4개 파일의 타입을 건드리지 않는다.

**안 B — `on_admitted` 타입 변경.** `(unit, string) result` → `('a, string) result`로 일반화. 타입은 정직해지지만 `keeper_turn.mli:134`, `keeper_tool_surface.mli:54`, 그리고 dashboard-direct 호출 2곳(`stream:740, 769`)까지 파급된다.

**추천: 안 A로 시작.** 안 B는 `on_admitted`에 다른 payload가 필요해지는 두 번째 사례가 생기면 그때 한다. 지금 일반화하면 소비자가 하나뿐인 다형성이다.

이 선택은 이 RFC가 확정하지 않는다. 구현자가 정하고 PR body에 근거를 남긴다.

## 6. 무엇이 실제로 좋아지는가

| 구간: proactive 턴 실행 중 메시지 도착 | 현재 main | 이 RFC |
|---|---|---|
| mutex가 대기 chat을 아는가 | **모름** (`waiting = 0`) | 안다 (`waiting = 1`) |
| receipt의 durable 상태 | `Pending` | `Pending` |
| 이 구간에 프로세스 재시작 | 자동 재드레인 | 자동 재드레인 |
| proactive를 막는 주체 | 큐 스냅샷 (파생상태) | mutex (SSOT) |

`#26283`이 첫째 줄만 고치고 둘째 줄을 `Inflight`로 만들어 셋째 줄을 운영자 개입으로 바꿨다. 이 RFC는 첫째 줄만 바꾸고 나머지를 그대로 둔다.

`Inflight`의 의미도 보존된다 — `keeper_chat_queue.mli:5-13`이 근거로 드는 *A crashed lease is never automatically redispatched because its external effect is unproven*가 계속 참이다. lease는 실행 직전에만 잡히므로 `Inflight`는 항상 "실행 중"을 뜻한다.

## 7. 검증

### 7.1 기존

`#26307`의 `test/test_keeper_chat_admission_contention.ml`이 그대로 유효하다. 설계 중립으로 작성돼 있다 — receipt가 처리되는지만 보고 어떤 규칙이 처리했는지는 보지 않는다. 게이트 제거만 하고 대기열 등록이 없으면 back-to-back에서 0/3으로 실패한다(3회 확인).

### 7.2 추가할 것

1. **peek이 durable 상태를 바꾸지 않음**: `peek_next` 후 `snapshot`의 revision과 receipt state가 불변.
2. **대기 중 상태가 `Pending`**: proactive가 슬롯을 쥔 동안 consumer가 대기열에 등록되고(`chat_waiting = true`), 같은 시점에 receipt가 `Pending`.
3. **`lease_exact` CAS**: peek 이후 head가 바뀌면 `` `Head_moved ``이고 아무 상태도 변하지 않음.
4. **대기 중 재시작이 receipt를 stranded시키지 않음**: 대기 상태를 만들고 큐를 재구성했을 때 `Recovery_required`가 아니라 `Pending`.
5. **크래시 주입**: 대기 중 프로세스를 죽이고 재시작해 자동 재드레인 확인. `test_keeper_chat_coalescing.ml:586,597`이 `resolve_recovery_required`를 이미 다루므로 그 주변에 둔다.

### 7.3 TLA+

`specs/` 131개 파일 중 이 admission을 모델링하는 것이 없다. `KeeperTurnSingleFlight.tla`는 `running[k] <= 1`만 제약하는데 모든 변형이 이를 만족한다.

이 저장소의 bug-model 관례(clean cfg + `-buggy.cfg`)를 따라 하나 추가한다:

- `BugAction`: proactive가 대기 중인 chat 대기자를 앞지른다
- `SafetyInvariant`: chat 대기자가 존재하면 proactive는 슬롯을 얻지 못한다
- clean cfg는 no error, `-buggy.cfg`는 invariant violated여야 한다

## 8. 리스크

**adapter fork 순서.** `server_bootstrap_loops.ml:1746-1810`이 Discord/Slack 배달 adapter를 `process_single_turn`(`:1820`) **이전에** fork한다. 대기가 그 이후에 발생하므로, adapter fiber와 `Keeper_chat_events.create ()`(`:1683`)가 대기 시간 내내 유휴로 살아있다. proactive 턴 관측치가 3s · 33s · 64s · 95s이므로 최대 100초 규모다. **`#26283`도 같은 성질을 갖는다** — 이 RFC가 새로 만드는 문제는 아니지만, 현재 main에는 없는 비용이다(main은 바쁘면 dispatch 자체를 안 한다). fork를 admission 이후로 미룰 수 있는지는 별도 검토가 필요하고 이 RFC의 범위 밖이다.

**진단 손실.** `Chat_backlog`는 `#24865` 진단에서 `holder info not yet published`가 오도했기 때문에 만들어졌다(`keeper_turn_admission.mli:52-56`). 제거하면 `pending_count`/`inflight_count` payload가 로그에서 사라진다. 대신 차단 사유가 `Turn_busy`가 되고 holder는 실제로 chat 턴이므로 로그가 사실과 일치한다 — `#24865`의 문제는 holder 정보의 부재였고 이 설계에서는 holder가 존재한다. 다만 `run_locked_with_token`이 `slot.info`를 설정하는 시점과 대기자가 관측하는 시점 사이의 창은 남는다.

**`run_admin_if_free`의 backlog 우회 근거 부재.** `.mli:203-209`가 이 우회를 설명하지 않는다. `0d6291253a`(#25978)에서 이미 false로 도입됐고 어떤 커밋도 정당화한 적이 없다. `run_compaction_if_free`와 달리 `#24865` 같은 근거가 없다. 접기 전에 의도적인지 확인해야 한다.

**측정하지 않은 것.** 단일 도메인 Eio만. provider 지연 변동 없음. 멀티 도메인 경합 미확인.

## 9. RFC-0350 과의 관계

RFC-0350 §1.3 Gap B가 같은 `run_serialized`를 다룬다: *backlog가 살아있는 daemon fiber + mutex waiter로 표현된다 — wedged keeper 하나에 대기 fiber가 무제한으로 쌓인다*. 그리고 `Rejected (Saturated _)` 변형을 `run_serialized`에 추가하는 것을 제안한다.

충돌하지 않는다. RFC-0350의 대상은 `keeper_msg_async.ml:2320`이 제출 요청당 daemon을 fork하는 경로이고, 거기서는 대기자가 N개가 된다. chat consumer는 dispatch gate(`keeper_chat_consumer.ml:133-181`)가 keeper당 하나만 보장하므로 **대기자가 항상 1개 이하**다. backlog는 계속 durable store(`Keeper_chat_queue`)에 있고, 살아있는 fiber는 head 하나뿐이다 — RFC-0350이 요구하는 형태 그대로다.

`Rejected (Saturated _)`가 추가되면 consumer는 그것을 `Deferred`로 매핑해 receipt를 `Pending`으로 남기면 된다. 이 RFC 이후에는 대기 중 receipt가 이미 `Pending`이므로 매핑이 no-op에 가깝다.

RFC-0350의 라인 인용 일부는 이미 stale하다(`keeper_turn.ml:1054` → 실제 `:989`, `keeper_turn_admission.ml:96`/`:293` → 실제 `:146`/`:398`). 그쪽 갱신은 이 RFC의 범위 밖이다.

## 10. 롤아웃

Phase 1 · 2 · 3을 별도 PR로 낸다. Phase 1은 순수 추가라 단독으로 안전하다. Phase 2가 동작을 바꾸고, Phase 3은 Phase 2가 머지된 뒤에만 유효하다 — **순서를 뒤집으면 §1.2의 세 번째 줄(0/3) 상태가 된다.**

각 PR은 `#26307`의 경합 테스트를 통과해야 한다.
