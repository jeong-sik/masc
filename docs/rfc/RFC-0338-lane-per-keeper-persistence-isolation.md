# RFC-0338: Lane-per-keeper durable persistence isolation

- Status: Draft
- Author: Claude (38-bug campaign, cluster C9 — bugs #17/#25/#29)
- Date: 2026-07-10
- Related: `keeper_event_queue_persistence.ml` 2026-06-29 audit note, RFC-0334 (board mailbox), `KeeperOASAdvanced.tla`
- Source baseline: `masc/main@817eb5e74786fd166f9d81a4a160e521d6fc37d3`

## 결정

durable event-queue의 락 단위를 프로세스에서 **스냅샷 쌍의 실제 자원 정체성**으로 줄인다. 자원 키는 `keeper_name` 단독이 아니라 `(canonical BasePath, keeper_name)`이다. 같은 자원 키의 pending/inflight read-modify-write는 직렬화하고, 다른 키는 독립적으로 진행한다.

락 레지스트리는 현재 보유자와 대기자가 있는 엔트리만 유지한다. Eio와 non-Eio 접근이 같은 키에서 겹치면 별도 락으로 진행하지 않고 명시적인 typed contract error로 거부한다. 콜백에서 나온 모든 예외는 락 콜백 안에서 값으로 포획한 뒤 락과 레지스트리 lease를 해제하고 원래 backtrace로 다시 발생시킨다.

## 현재 구현에서 확인한 사실

`lib/keeper_runtime/keeper_event_queue_persistence.ml:11`과 `lib/keeper_runtime/keeper_event_queue_persistence.ml:12`에는 하나가 아니라 실행 모드별 프로세스 전역 락 두 개가 있다.

```ocaml
let eio_write_mu = Eio.Mutex.create ()
let fallback_write_mu = Stdlib.Mutex.create ()
```

- Eio 호출끼리, non-Eio 호출끼리는 각각 모든 BasePath와 keeper를 직렬화한다.
- 두 락 사이에는 상호배제가 없다. 같은 스냅샷 쌍에 Eio와 non-Eio 호출이 동시에 들어오면 현재 계약은 직렬화를 보장하지 않는다.
- 현재 main에는 `with_write_lock` 정의(`lib/keeper_runtime/keeper_event_queue_persistence.ml:24`) 1곳과 호출 10곳(`lib/keeper_runtime/keeper_event_queue_persistence.ml:321`부터 `lib/keeper_runtime/keeper_event_queue_persistence.ml:701`까지)이 있다. 10개 호출 모두 `base_path`와 `keeper_name`을 이미 스코프에 갖는다.
- `Eio.Mutex.use_rw ~protect:true`의 콜백은 일반 예외만 값으로 포획하고 `Eio.Cancel.Cancelled`는 콜백 안(`lib/keeper_runtime/keeper_event_queue_persistence.ml:29`)에서 다시 발생시킨다. Eio 계약상 콜백에서 빠져나온 예외는 mutex를 disable/poison하므로 이 경로를 그대로 유지할 수 없다.
- 기존 poison 회귀 테스트는 디스크 예외 뒤의 재사용만 확인한다. 콜백에서 발생한 `Cancelled`, 락 대기 중 취소, 레지스트리 회수, 교차 실행모드는 검증하지 않는다.
- 이 모듈과 persistence 경로에는 검증된 per-keeper circuit breaker 연동이나 lock-wait metric이 없다. 본 RFC는 있다고 가정하지 않는다.

[근거] Eio `Mutex.use_rw`와 `protect` 계약: [Eio.Mutex 공식 문서](https://ocaml-multicore.github.io/eio/eio/Eio/Mutex/index.html), 확인일시 2026-07-10, 신뢰도 High.

[근거] 보호된 cancellation context와 promise-origin `Cancelled`: [Eio.Cancel 공식 문서](https://ocaml-multicore.github.io/eio/eio/Eio/Cancel/index.html), 확인일시 2026-07-10, 신뢰도 High.

## 문제

스냅샷 파일은 BasePath와 keeper별로 분리되지만 현재 Eio 락과 fallback 락은 각각 프로세스 전역이다. 따라서 한 keeper의 파일 I/O가 같은 실행 모드의 무관한 keeper 쓰기를 막는 head-of-line blocking이 구조적으로 가능하다. 반대로 실행 모드가 다르면 같은 파일에 대한 상호배제가 사라진다.

#23956 이후 durable enqueue가 HITL acknowledgment의 커밋 포인트이므로 persistence 대기는 승인 응답 지연으로 전파된다. 다만 현재 lock-wait 관측값은 없으므로 지연의 크기나 fleet 수를 수치로 추정하지 않는다.

## 설계

### 1. 자원 키와 BasePath SSOT

```ocaml
type snapshot_lock_key

val snapshot_lock_key :
  base_path:string ->
  keeper_name:string ->
  (snapshot_lock_key, lock_key_error) result
```

- 키는 `Common.keepers_runtime_dir_of_base ~base_path`가 만드는 실제 snapshot-pair 디렉터리 정체성에서 생성한다. 경로 생성과 별도의 디렉터리 규칙을 하드코딩하지 않는다.
- `Env_config_core.normalize_masc_base_path_input`은 lexical normalization이며 symlink alias까지 합치지 않는다. 구현 PR은 기존 subsystem-local `realpath existing prefix` 코드를 복사하지 않고, 하나의 shared path-identity SSOT를 세운 뒤 lock key와 기존 사용처가 이를 소비하게 한다.
- 경로 정체성을 만들 수 없으면 raw string으로 조용히 fallback하지 않고 `lock_key_error`를 반환한다.
- 같은 이름의 keeper라도 BasePath가 다르면 다른 키다. 같은 물리 BasePath의 lexical/symlink alias는 같은 키가 되어야 한다.

### 2. lease 기반 레지스트리

레지스트리는 immutable map 값을 짧은 `Stdlib.Mutex` 구간에서 교체한다. 이 구간에서는 lookup/update만 수행하고 파일 I/O, fiber yield, per-key lock 대기를 하지 않는다. `Stdlib.Mutex`는 Eio 공식 문서가 허용하는 짧고 non-yielding한 critical section에만 사용한다.

```ocaml
type backend =
  | Eio_lock of Eio.Mutex.t
  | Thread_lock of Stdlib.Mutex.t

type entry =
  { backend : backend
  ; leases : int
  }
```

- lease 수는 lock owner와 waiter를 모두 센다. 대기 전에 증가하고, 성공·예외·대기 중 취소 모든 경로에서 `Fun.protect` finalizer로 감소한다.
- `leases = 0`이면 엔트리를 제거한다. 따라서 레지스트리 크기는 과거 keeper 이름 수가 아니라 현재 owner/waiter 수로 제한된다.
- “keeper 수는 수십 개라 영구 보관” 같은 운영 규모 추정이나 TTL/GC 휴리스틱을 사용하지 않는다.
- 기존 엔트리와 요청 backend가 다르면 새 mutex를 만들지 않는다. `Backend_conflict` typed error와 관측 이벤트를 남기고 콜백을 실행하지 않는다. lease가 0이 되어 엔트리가 제거된 뒤의 순차적인 backend 전환은 허용한다.

### 3. 취소와 poison 경계

`Eio.Mutex.use_rw ~protect:true`에 전달하는 콜백은 **모든** 예외를 결과값으로 바꾸는 total callback이어야 한다.

```ocaml
type lock_contract_error =
  | Backend_conflict of { requested : backend_kind; active : backend_kind }
  | Reentrant_lock of snapshot_lock_key

exception Lock_contract_error of lock_contract_error
```

기존 `with_write_lock`의 callback 반환형과 callback 예외 전파 계약은 유지하고, lock 자체의 계약 위반만 닫힌 variant를 담은 typed exception으로 구분한다. 메시지 문자열 판별로 제어 흐름을 만들지 않는다.

```ocaml
let guarded token =
  match f token with
  | value -> Ok value
  | exception exn -> Error (exn, Printexc.get_raw_backtrace ())
```

- `Cancelled`도 `guarded` 안에서는 값으로 포획한다. `use_rw`와 lease finalizer가 끝난 다음 `Printexc.raise_with_backtrace`로 다시 발생시켜 cancellation 전파와 mutex 재사용을 동시에 보장한다.
- lock 획득을 기다리다 취소되면 `use_rw` 자체가 빠져나올 수 있다. 외부 `Fun.protect`가 lease를 반드시 반환한다.
- fallback backend에도 같은 total-callback/외부 재발생 규칙을 적용해 두 경로의 예외 계약을 하나로 유지한다.
- 중첩 획득 금지를 개발용 `assert`에 맡기지 않는다. critical-section helper는 추상 `lock_token`을 요구하고, 같은 실행 주체가 같은 키를 다시 얻으려 하면 production 경로에서 `Reentrant_lock` typed error를 반환한다. 오류는 로그·trace·metric에 드러나야 하며 무한 대기로 바뀌면 안 된다.

### 4. 불변식

1. 같은 `(canonical BasePath, keeper_name)`의 pending/inflight snapshot pair RMW는 상호배제된다.
2. 다른 키는 서로의 파일 I/O 완료를 기다리지 않는다.
3. Eio와 non-Eio가 같은 키에서 겹쳐도 두 콜백이 동시에 실행되지 않는다.
4. 콜백 예외와 `Cancelled`는 원래 backtrace로 호출자에게 전파되고 mutex를 poison하지 않는다.
5. 대기 취소를 포함한 모든 종료 경로에서 lease가 반환되며, 사용자가 없는 엔트리는 남지 않는다.
6. 재진입은 typed error로 종료되며 deadlock이나 disabled assertion에 의존하지 않는다.

### 5. 관측성

구현 PR은 lock wait, critical-section duration, active registry entry/lease 수, `Backend_conflict`, `Reentrant_lock`, poisoned-lock 관측을 metric catalog와 trace에 추가한다. 임의 threshold나 inline bucket을 만들지 않고 기존 metric catalog 정책을 따른다. filesystem 경로 전체는 metric label로 복제하지 않으며, BasePath/keeper 문맥은 접근 제어된 trace/log에서 확인 가능하게 한다.

### 6. TLA+

clean/buggy model pair는 최소 두 BasePath, 두 keeper, 두 backend를 모델링한다. registry lease/refcount, lock 대기 중 취소, 콜백 내부 예외·`Cancelled`, backend conflict, cross-key progress를 상태에 포함한다.

- Safety: 같은 키의 두 critical section이 동시에 active가 아님.
- Safety: lease가 음수가 되지 않고, active owner/waiter가 없으면 registry entry가 없음.
- Safety: callback exception이 lock을 영구 poison하지 않음.
- Liveness: 공정성 가정 아래 A 키의 지연·예외가 B 키의 진행을 막지 않음.
- buggy model은 전역 락 또는 취소 시 lease 누락 중 하나를 의도적으로 복원해 해당 속성을 위반해야 한다.

## 스코프 밖

- persistence 데이터 형식과 pending/inflight 전이 의미는 바꾸지 않는다.
- 확인되지 않은 per-keeper circuit breaker 연동을 본 RFC의 효과로 주장하지 않는다. 필요하면 실제 admission/persistence 연결 설계를 별도 RFC로 다룬다.
- `schedule_runner.ml dispatch_candidates`의 순차 dispatch는 순서 의미 결정이 선행돼야 하므로 포함하지 않는다.
- 락 획득 timeout, keeper 수 cap, TTL은 고정 수치로 장애를 가리는 휴리스틱이라 도입하지 않는다.

## 마이그레이션

1. shared path-identity SSOT와 opaque `snapshot_lock_key`를 마련한다.
2. 내부 lock registry를 lease 기반으로 구현하고 backend conflict/reentrancy typed errors를 추가한다.
3. `with_write_lock ~base_path ~keeper_name`과 추상 `lock_token`을 10개 호출부에 전파한다. pending/inflight를 만지는 unlocked helper는 token을 요구하게 한다.
4. 모든 예외를 lock callback 안에서 값으로 포획하고 lock/lease 해제 뒤 원래 backtrace로 재발생시킨다.
5. 관측성, 결정적 concurrency tests, TLA+ clean/buggy pair를 추가한다.

데이터 파일 migration은 없다. 롤백은 새 lock module과 호출 시그니처를 되돌리되, 기존의 교차-backend 비상호배제와 `Cancelled` poison 문제가 재도입된다는 점을 rollback evidence에 명시해야 한다.

## 결정적 테스트

sleep이나 실행 시간 비교 대신 Eio promise/barrier로 순서를 고정한다.

- 같은 키: 첫 콜백이 barrier를 잡은 동안 두 번째 콜백이 진입하지 않음.
- 다른 keeper, 같은 BasePath: A가 정지한 동안 B가 완료됨.
- 같은 keeper, 다른 BasePath: A가 정지한 동안 B가 완료됨.
- 같은 물리 BasePath의 alias: 같은 키로 직렬화됨.
- 일반 예외와 명시적 `Cancelled`: 호출자에게 전파된 뒤 같은 키를 다시 사용할 수 있음.
- lock 대기 중 취소: callback 미실행, lease 반환, registry baseline 복귀.
- 교차 backend overlap: 두 번째 callback 미실행, `Backend_conflict` 관측.
- 재진입: 대기하지 않고 `Reentrant_lock` 관측.
- 마지막 owner/waiter 종료: registry entry 제거.

## 검증 완료 기준

- [ ] 현재 main의 10개 호출부 전파 및 CI build/test green
- [ ] parser/format/정적 ratchet green
- [ ] 위 결정적 concurrency tests green
- [ ] TLA+ clean pass / buggy violate
- [ ] lock/lease/error 관측 항목이 metric catalog와 health/trace 경계에 연결됨
- [ ] 같은 키 직렬화와 cross-key progress가 CI evidence로 남음
