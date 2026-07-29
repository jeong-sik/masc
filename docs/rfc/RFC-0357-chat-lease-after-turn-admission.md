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

### 3.4 검토했지만 택하지 않은 대안 — `already_admitted` 플래그

이 저장소에는 "호출자가 이미 슬롯을 쥐고 있다"를 표현하는 선례가 있다. `Keeper_manual_compaction.run_under_admission`(`keeper_manual_compaction.mli:83-92`): *Manual compaction while the caller already owns the Keeper turn token. No nested admission or release occurs.* 구현은 `~already_admitted:true`를 호출 그래프로 흘려 내부 admission을 건너뛰는 방식이다(`keeper_manual_compaction.ml:505-543, 674-693`), 호출자는 이미 admission 안에 있는 `keeper_heartbeat_loop_cycle.ml:348`이다.

이 패턴을 chat 경로에 이식하면: consumer가 admission을 직접 잡고, `handle_turn`에 `~already_admitted:true`를 넘겨 `handle_keeper_invocation`의 `run_serialized`를 건너뛴다.

택하지 않는 이유:

- `Keeper_turn_admission`에 already-admitted 진입점을 **새로 export**해야 한다. 현재 `run_locked` / `run_locked_with_token`은 `.mli`에 없고 private `slot` 타입을 받는다(`keeper_turn_admission.ml:238-272`). 진입점을 3개로 줄이려는 이 RFC의 목표와 반대 방향이다.
- 불리언 플래그를 13 hop에 걸쳐 흘려야 한다. 그 자체가 §4가 없애려는 종류의 파라미터다.
- `run_locked_with_token`은 shutdown 경로와 release 경로 양쪽에서 무조건 `Eio.Mutex.unlock`한다(`:252`, `:258`). 중첩 사용을 안전하게 만들려면 그 함수도 손봐야 한다.
- `on_admitted`는 **이미 존재하고, 이미 임계구역 안에서 돌고, 이미 queued turn 전용**이다. 새로 만들 것이 없다.

`keeper_turn_admission.mli:240-243`의 caller contract — *do not call this from within an admitted turn of the same keeper* — 는 두 안 모두에서 지켜진다. `on_admitted` 안은 admission 안이지만 `run_serialized`를 다시 부르지 않는다.

### 3.5 compaction 레인도 줄을 서야 한다

Phase 2가 만드는 부작용이 하나 있다. chat이 대기자로 등록되면 `Eio.Mutex`의 unlock이 슬롯을 그 대기자에게 직접 넘기므로(§1.3), **`run_compaction_if_free`의 `try_lock`은 이길 수 없다.**

지금은 consumer가 물러나서 대기자가 없으므로 compaction의 `try_lock`이 성공한다. Phase 2 이후에는 아니다. context-overflow 상태에서 이것이 문제가 되는 이유는 `keeper_turn_admission.mli:189-195`가 적어둔 그대로다 — 그 keeper의 chat 턴은 checkpoint가 고쳐지기 전까지 provider에서 실패한다. compaction이 계속 진다면 같은 queued turn이 계속 실패한다.

`Chat_backlog`를 지워도 이 의미 차이는 사라지지 않는다. 레인 구분의 근거가 backlog yield가 아니라 **"이 레인은 건너뛰어도 되는가"**이기 때문이다.

그래서 이 RFC의 규칙을 그 축으로 다시 세운다:

| 레인 | 반드시 실행되어야 하는가 | 연산 |
|---|---|---|
| proactive (heartbeat) | 아니오 — 오래된 tick은 버려도 된다 | `try_lock` |
| chat | 예 — 요청은 답해야 한다 | `lock` (park) |
| **manual compaction** | **예 — 수리다. 버리면 keeper가 고장난 채 남는다** | **`lock` (park)** |

compaction이 park하면 FIFO 안에 들어간다. 시각 T에 요청된 compaction은 T 이후에 도착한 어떤 chat보다 앞선다. `try_lock`으로 영원히 지는 것과 다르다.

**남는 구멍 하나, 그리고 Phase 2의 선행 조건.** compaction 요청보다 **먼저** park한 chat 턴은 여전히 앞선다. 그 턴은 provider에서 context overflow로 실패하고, 그 뒤에 compaction이 돌아 checkpoint를 고친다. 이것이 허용 가능한지는 **그 실패가 재시도 가능한가**에 달려 있다.

- 재시도 가능(`nack` → `Pending` → 재드레인)하면 비용은 실패한 시도 1회다. 허용.
- 종결(`Failed`)이면 receipt가 영구히 죽는다. **허용 불가.**

`keeper_chat_consumer`의 `Failed` 분기는 terminal이다. context overflow가 어느 쪽으로 매핑되는지 이 RFC는 확인하지 않았다. **Phase 2를 시작하기 전에 이것부터 확정한다.** terminal이면 Phase 2는 다음 중 하나를 함께 가져가야 한다:

1. context overflow를 typed 재시도 가능 결과로 분리한다 (provider 실패 일반과 구분), 또는
2. admitted 구역 안에서 provider 진입 전에 같은 checkpoint의 compaction 필요 여부를 확정하고 필요하면 먼저 수행한다.

2번이 §7.2가 요구하는 불변식이다. 1번이 더 작다. 어느 쪽이든 Phase 2의 일부이며, 확인 없이 진행하면 안 된다.

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

`yield_to_chat_backlog`가 사라지면 세 진입점의 **본문**이 같아진다. 그렇다고 셋을 하나로 접을 수는 없다 — §3.5가 그 이유다.

- `run_compaction_if_free` → **`run_compaction_serialized`로 바꾼다.** compaction은 건너뛰면 안 되는 레인이므로 `try_lock`이 아니라 park해야 한다. 이름만 바꾸는 게 아니라 연산이 바뀐다.
- `run_admin_if_free` → **접기 전에 근거를 확인한다.** `.mli:203-209`는 이 레인이 backlog를 우회하는 이유를 적지 않았고, `0d6291253a`(#25978)에서 이미 false로 도입됐다. `run_compaction_if_free`와 달리 `#24865` 같은 근거가 없다. admin이 건너뛰어도 되는 레인이면 `run_if_free`로 접고, 아니면 compaction과 같이 park로 간다. **확인 없이 접지 않는다.**
- `run_if_free` → 유지 (proactive 전용).

앞 판(`c727ede`)은 세 개를 그냥 접었다. 그것이 P1이었다.

진입점은 8개 → 4개(`run_if_free`, `run_serialized`, `run_compaction_serialized`, `run_chat_if_free`)가 된다. admission **권한**은 5개 → 1개(mutex)로 줄고, 이쪽이 이 RFC의 실제 목표다. 진입점 수는 부산물이지 목표가 아니다 — §3.5가 보여주듯 레인마다 "건너뛰어도 되는가"가 다르면 진입점도 달라야 한다.

## 5. lease 실패의 타입 계약

`on_admitted : unit -> (unit, string) result`로는 부족하다. `lease_exact`는 5가지로 끝나는데(`Leased | Head_moved | Empty | Recovery_required | Error`) `Error of string`으로 뭉개면 `keeper_turn.ml:993-1008`이 이를 일반 tool 실패로 바꾸고, consumer의 `Failed`/`Deferred` 분기는 **이미 `lease_id`를 쥐고 있다고 전제한다**(`keeper_chat_consumer.ml:469-510`). lease가 없는 경우가 없었기 때문이다.

그대로 두면 head 교체·recovery 경쟁에서 **정상 receipt를 종결하거나 stale lease로 mutate하는 구현이 가능해진다.** 이건 미결정 사항이 아니라 필수 계약이다.

### 5.1 dispatch-local 결과 셀

`admit` 클로저는 dispatch 1건 스코프의 셀에 typed 결과를 쓰고, `on_admitted`에는 턴을 진행할지만 알려준다.

```ocaml
type attempt =
  | Leased of Keeper_chat_queue.lease
  | Not_leased of not_leased

and not_leased =
  | Head_moved                                    (* 운영자 조치 등으로 head 교체 *)
  | Empty                                         (* 대기 중 드레인됨 *)
  | Recovery_required of Keeper_chat_queue.recovery_evidence
  | Persistence of Keeper_chat_queue.mutation_error
```

`admit ()`는 셀을 채우고, `Leased _`면 `Ok ()`, 그 외에는 `Error` — 턴 본문은 실행되지 않고 슬롯은 즉시 반납된다.

셀이 sum type을 담아야 하므로, 앞 판(§5, `c727ede`)이 "ref 대 타입 일반화" 중 무엇을 고를지 미뤄둔 것은 잘못된 문제 설정이었다. **셀은 어차피 필요하다.** `on_admitted`의 타입을 일반화해도 `(attempt, string) result`를 반환할 뿐이고, 그러면 `keeper_turn.mli:134`·`keeper_tool_surface.mli:54`·dashboard-direct 2곳(`stream:740, 769`)이 소비자 하나뿐인 다형성을 떠안는다. 셀로 간다.

### 5.2 consumer의 처리

`handle_turn` 반환 후 셀을 읽는다. **lease가 없으면 finalize도 nack도 하지 않는다.**

| 결과 | 처리 |
|---|---|
| `Leased lease` | 기존 `settle_lease` 경로 (`keeper_chat_consumer.ml:294`) |
| `Not_leased Head_moved` | dispatch 해제 후 현재 snapshot 재관측. receipt는 건드리지 않음 |
| `Not_leased Empty` | dispatch 해제. 할 일 없음 |
| `Not_leased (Recovery_required e)` | 기존 recovery 경로 (`:648-655`, `:669-679`) |
| `Not_leased (Persistence e)` | 기존 `persistence_blocked` 규칙 (`:639`, `:690`) |

### 5.3 attempt identity — `lease_id`가 꼭 랜덤이어야 하는가

`finalize`/`nack`은 inflight의 exact `lease_id`만 매치한다(`keeper_chat_queue.ml:2669-2728`). 이 fence 자체는 필요하다 — 같은 `receipt_id`가 nack 뒤 재시도될 때 늦게 도착한 첫 시도의 finalize가 두 번째 시도를 건드리면 안 된다(`test_keeper_chat_consumer_delivery.ml:677-735`가 이 회귀를 고정한다).

문제는 그 identity를 `Random_id.prefixed "lease_"`로 **새로 만든다**는 점이다(`keeper_chat_queue.ml:2528`). `(receipt_id, lease-transition이 커밋한 revision)`은 queue SSOT에서 그대로 나오는 정확한 attempt identity이고, recovery는 이미 `receipt_id`와 revision을 따로 요구하면서 opaque `lease_id`를 한 번 더 요구한다.

**Phase 0으로 이 대조를 먼저 한다.** stale callback / retry / recovery 셋 중 revision 조합으로 구분되지 않는 구체적 반례를 찾지 못하면, 랜덤 `lease_id`와 그 위의 `lease` facade를 유지하지 않고 receipt-derived `delivery_attempt`로 축소한다. 반례를 찾으면 이 문서에 적는다.

이 절은 Phase 1보다 앞선다. 축소가 가능하면 §5.1의 `Leased of lease`가 `Leased of delivery_attempt`가 되고, Phase 2가 옮길 대상이 줄어든다.

## 6. 무엇이 실제로 좋아지는가

| 구간: proactive 턴 실행 중 메시지 도착 | 현재 main | 이 RFC |
|---|---|---|
| mutex가 대기 chat을 아는가 | **모름** (`waiting = 0`) | 안다 (`waiting = 1`) |
| receipt의 durable 상태 | `Pending` | `Pending` |
| 이 구간에 프로세스 재시작 | 자동 재드레인 | 자동 재드레인 |
| proactive를 막는 주체 | 큐 스냅샷 (파생상태) | mutex (SSOT) |

`#26283`이 첫째 줄만 고치고 둘째 줄을 `Inflight`로 만들어 셋째 줄을 운영자 개입으로 바꿨다. 이 RFC는 첫째 줄만 바꾸고 나머지를 그대로 둔다.

### 6.1 `Inflight`가 뜻하는 것 — 정정

앞 판(`c727ede`)은 *lease는 실행 직전에만 잡히므로 `Inflight`는 항상 "실행 중"을 뜻한다*고 적었다. **틀렸다.**

`lease_exact` 다음에 `append_queued_user_row_once`가 오고, 그 사이에 크래시가 나면 provider에 닿지 않은 턴이 여전히 `Recovery_required`가 된다. 창은 `#26283`의 "동시 턴 전체 길이"에서 "슬롯 획득 후 user row write까지"로 줄어들지만 0이 아니다.

정확한 표현은 **attempt-reserved**다: `Inflight`는 *이 attempt가 슬롯을 확보했다*를 뜻하고, 외부 효과 발생 여부는 별개다. `keeper_chat_queue.mli:5-13`의 근거 문장 — *its external effect is unproven* — 은 그래서 계속 참이다. 오히려 그 문장이 처음부터 "실행 중"이 아니라 "증명되지 않음"이라고 말하고 있었다.

이 창은 §7.2의 크래시 테스트로 고정한다. 순서를 뒤집어 user row를 먼저 쓰는 것은 답이 아니다 — 그러면 lease 없이 transcript에 행이 남는다.

## 7. 검증

### 7.1 기존

`#26307`의 `test/test_keeper_chat_admission_contention.ml`이 그대로 유효하다. 설계 중립으로 작성돼 있다 — receipt가 처리되는지만 보고 어떤 규칙이 처리했는지는 보지 않는다. 게이트 제거만 하고 대기열 등록이 없으면 back-to-back에서 0/3으로 실패한다(3회 확인).

### 7.2 추가할 것

1. **peek이 durable 상태를 바꾸지 않음**: `peek_next` 후 `snapshot`의 revision과 receipt state가 불변.
2. **대기 중 상태가 `Pending`**: proactive가 슬롯을 쥔 동안 consumer가 대기열에 등록되고(`chat_waiting = true`), 같은 시점에 receipt가 `Pending`.
3. **`lease_exact` CAS**: peek 이후 head가 바뀌면 `` `Head_moved ``이고 아무 상태도 변하지 않음.
4. **대기 중 재시작이 receipt를 stranded시키지 않음**: 대기 상태를 만들고 큐를 재구성했을 때 `Recovery_required`가 아니라 `Pending`.
5. **lease 없는 결과가 receipt를 종결하지 않음**: `Head_moved`/`Empty`에서 finalize·nack이 호출되지 않고 receipt state가 불변임을 §5.2 분기별로 확인.
6. **크래시 주입 두 지점** (§6.1):
   - 대기 중(`Pending`) 크래시 → 재시작 후 자동 재드레인
   - lease 직후·user row write 직전 크래시 → `Recovery_required`. 이 창의 존재를 문서가 아니라 테스트로 고정한다
   `test_keeper_chat_coalescing.ml:586,597`이 `resolve_recovery_required`를 이미 다루므로 그 주변에 둔다.
7. **compaction이 굶지 않음** (§3.5): overflowed checkpoint + `Pending` receipt + park한 chat 대기자 + compaction 요청 상태에서, **receipt가 terminal이 되기 전에 compaction이 실행됨**을 확인. Phase 2의 선행 조건 확정(재시도 가능 대 종결)이 이 테스트로 드러난다.

### 7.3 TLA+

`specs/` 131개 파일 중 이 admission을 모델링하는 것이 없다. `KeeperTurnSingleFlight.tla`는 `running[k] <= 1`만 제약하는데 모든 변형이 이를 만족한다.

이 저장소의 bug-model 관례(clean cfg + `-buggy.cfg`)를 따라 하나 추가한다:

- `BugAction`: proactive가 대기 중인 chat 대기자를 앞지른다
- `SafetyInvariant`: chat 대기자가 존재하면 proactive는 슬롯을 얻지 못한다
- clean cfg는 no error, `-buggy.cfg`는 invariant violated여야 한다

## 8. 리스크

**adapter fork 순서.** `server_bootstrap_loops.ml:1746-1810`이 Discord/Slack 배달 adapter를 `process_single_turn`(`:1820`) **이전에** fork한다. 대기가 그 이후에 발생하므로, adapter fiber와 `Keeper_chat_events.create ()`(`:1683`)가 대기 시간 내내 유휴로 살아있다. proactive 턴 관측치가 3s · 33s · 64s · 95s이므로 최대 100초 규모다. **`#26283`도 같은 성질을 갖는다** — 이 RFC가 새로 만드는 문제는 아니지만, 현재 main에는 없는 비용이다(main은 바쁘면 dispatch 자체를 안 한다). fork를 admission 이후로 미룰 수 있는지는 별도 검토가 필요하고 이 RFC의 범위 밖이다.

**진단 손실.** `Chat_backlog`는 `#24865` 진단에서 `holder info not yet published`가 오도했기 때문에 만들어졌다(`keeper_turn_admission.mli:52-56`). 제거하면 `pending_count`/`inflight_count` payload가 로그에서 사라진다. 대신 차단 사유가 `Turn_busy`가 되고 holder는 실제로 chat 턴이므로 로그가 사실과 일치한다 — `#24865`의 문제는 holder 정보의 부재였고 이 설계에서는 holder가 존재한다. 다만 `run_locked_with_token`이 `slot.info`를 설정하는 시점과 대기자가 관측하는 시점 사이의 창은 남는다.

**`run_admin_if_free`의 backlog 우회 근거 부재.** `.mli:203-209`가 이 우회를 설명하지 않는다. `0d6291253a`(#25978)에서 이미 false로 도입됐고 어떤 커밋도 정당화한 적이 없다. `run_compaction_if_free`와 달리 `#24865` 같은 근거가 없다. §4 Phase 3이 이를 확인 항목으로 둔다.

**대기자가 늘어난다.** compaction이 park하면(§3.5) keeper당 대기자가 최대 2가 된다(chat 1 + compaction 1). RFC-0350이 문제 삼는 무제한 대기와는 여전히 자릿수가 다르지만, §9의 "항상 1개 이하"는 이제 "2개 이하"다.

**측정하지 않은 것.** 단일 도메인 Eio만. provider 지연 변동 없음. 멀티 도메인 경합 미확인. context overflow가 재시도 가능한지 종결인지 미확인 — §3.5가 이를 Phase 2 선행 조건으로 둔다.

## 9. RFC-0350 과의 관계

RFC-0350 §1.3 Gap B가 같은 `run_serialized`를 다룬다: *backlog가 살아있는 daemon fiber + mutex waiter로 표현된다 — wedged keeper 하나에 대기 fiber가 무제한으로 쌓인다*. 그리고 `Rejected (Saturated _)` 변형을 `run_serialized`에 추가하는 것을 제안한다.

충돌하지 않는다. RFC-0350의 대상은 `keeper_msg_async.ml:2320`이 제출 요청당 daemon을 fork하는 경로이고, 거기서는 대기자가 N개가 된다. chat consumer는 dispatch gate(`keeper_chat_consumer.ml:133-181`)가 keeper당 하나만 보장하므로 **대기자가 항상 1개 이하**다. backlog는 계속 durable store(`Keeper_chat_queue`)에 있고, 살아있는 fiber는 head 하나뿐이다 — RFC-0350이 요구하는 형태 그대로다.

`Rejected (Saturated _)`가 추가되면 consumer는 그것을 `Deferred`로 매핑해 receipt를 `Pending`으로 남기면 된다. 이 RFC 이후에는 대기 중 receipt가 이미 `Pending`이므로 매핑이 no-op에 가깝다.

RFC-0350의 라인 인용 일부는 이미 stale하다(`keeper_turn.ml:1054` → 실제 `:989`, `keeper_turn_admission.ml:96`/`:293` → 실제 `:146`/`:398`). 그쪽 갱신은 이 RFC의 범위 밖이다.

## 10. 롤아웃

| Phase | 내용 | 선행 조건 |
|---|---|---|
| **0** | attempt identity 대조 (§5.3) — `(receipt_id, revision)`이 랜덤 `lease_id`를 대체할 수 있는가 | 없음. 문서 작업 |
| **1** | `peek_next` · `lease_exact` 추가 (§4) | Phase 0의 결론에 따라 반환 타입이 정해짐 |
| **2** | lease를 `on_admitted`로 이동 (§4), §5의 typed 결과 계약 | **context overflow가 재시도 가능한지 종결인지 확정** (§3.5). 종결이면 그 분리도 Phase 2에 포함 |
| **3** | 게이트 제거, compaction을 park로 전환 (§4) | Phase 2 머지 |

Phase 1은 순수 추가라 단독으로 안전하다. Phase 2가 동작을 바꾸고, Phase 3은 Phase 2 이후에만 유효하다 — **순서를 뒤집으면 §1.2의 세 번째 줄(0/3) 상태가 된다.**

각 PR은 `test/test_keeper_chat_admission_contention.ml`(`#26307`, `#26317`로 강화됨)을 통과해야 한다. Phase 2·3은 §7.2의 6·7번을 추가로 요구한다.

## 11. 앞 판(`c727ede`)에서 바뀐 것

리뷰에서 나온 지적을 반영한 결과다.

| | 앞 판 | 이 판 |
|---|---|---|
| compaction | Phase 3에서 `run_if_free`로 접음 | §3.5 — park로 전환. 접기가 P1이었다 |
| lease 실패 | §5 "미결정" (ref 대 타입 일반화) | §5 — typed 결과 계약. 미결정이 아니라 필수였다 |
| `Inflight`의 의미 | *항상 실행 중* | §6.1 — **attempt-reserved.** 앞 판의 서술은 틀렸다 |
| `lease_id` | 다루지 않음 | §5.3 — Phase 0에서 축소 가능성 대조 |
| 진입점 목표 | 8 → 3 | 8 → 4. 진입점 수는 목표가 아니라 부산물 |
