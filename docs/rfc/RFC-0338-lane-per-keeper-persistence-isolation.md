# RFC-0338: Lane-per-keeper durable persistence isolation

- Status: Draft
- Author: Claude (38-bug campaign, cluster C9 — bugs #17/#25/#29)
- Date: 2026-07-10
- Related: keeper_event_queue_persistence.ml 2026-06-29 audit note, RFC-0334 (board mailbox), KeeperOASAdvanced.tla (CancelledNeverAbsorbed)

## 문제

`lib/keeper_runtime/keeper_event_queue_persistence.ml`의 durable event-queue 스냅샷 I/O는 **프로세스 전역 단일 뮤텍스** 뒤에 있다:

```ocaml
let eio_write_mu = Eio.Mutex.create ()       (* :11 — process-global *)
let with_write_lock : type a. (unit -> a) -> a  (* :24, 호출 사이트 13곳 *)
```

스냅샷 파일은 keeper별로 분리돼 있는데(`.masc/keepers/<name>/…` pending/inflight 쌍) 락은 전역이라, 락의 실제 보호 대상(같은 keeper 스냅샷 쌍의 read-modify-write 원자성)보다 훨씬 넓게 직렬화한다.

관측된/구조적 결과:

1. **Head-of-line blocking (#29)**: 한 keeper의 느린 디스크 I/O(대형 스냅샷, 느린 볼륨, fsync 지연)가 무관한 keeper 전원의 durable 쓰기를 대기시킨다. 14-keeper fleet에서 wake/HITL(#23956 이후 durable enqueue가 승인 acknowledgment의 커밋 포인트) 지연으로 직접 전파된다.
2. **단일 장애점**: 파일 자체의 주석(:14-16)이 자인하듯 "a poisoned mutex blocks durable event-queue snapshots for EVERY keeper for the lifetime of the process". 현재는 예외를 critical section 안에서 포획해 우회 중이지만, 이 방어는 락 범위가 전역이라서 필요해진 것이다.
3. **격리 원칙 위반 (#17/#25 연관)**: keeper 장애 격리(서킷브레이커, per-keeper failure policy)의 단위는 keeper인데, 영속 계층의 경합 단위는 프로세스다. 브레이커가 keeper A를 열어도 A가 잡고 있는 전역 락이 B/C를 계속 물고 있을 수 있다.

부수 관찰(스코프 밖, 기록만): `schedule_runner.ml dispatch_candidates`의 순차 `List.map`도 tick 내 head-of-line 직렬화다. dispatch 순서 시맨틱 결정이 선행돼야 하므로 본 RFC에 포함하지 않는다.

## 설계

### 락 구조

전역 뮤텍스 1개 → **per-keeper 뮤텍스 테이블**:

```ocaml
(* keeper_name → mutex. 테이블 접근 자체는 짧은 전역 락(순수 Hashtbl 조작만,
   I/O 없음)으로 가드. 뮤텍스는 keeper당 lazy 생성 후 영구 유지 —
   keeper 수는 유한(수십)이라 GC 불필요. *)
val with_write_lock : keeper_name:string -> (unit -> 'a) -> 'a
```

- 시그니처에 `~keeper_name` 추가. 13개 호출 사이트 전부 이미 `keeper_name`을 스코프에 갖고 있다 (스냅샷 경로 계산에 사용 중) — 기계적 전파.
- poisoned-mutex 방어(critical section 내 예외 포획, Cancelled 재raise — CancelledNeverAbsorbed)는 **그대로 유지**하되, 이제 오염 반경이 keeper 1기로 준다.
- non-Eio fallback(`Stdlib.Mutex`)도 동일하게 per-keeper 테이블로.

### 불변식

1. 같은 keeper의 pending/inflight 스냅샷 쌍에 대한 read-modify-write는 여전히 상호배제 (기존과 동일).
2. 서로 다른 keeper의 스냅샷 I/O는 동시 진행 가능 (신규).
3. 락 순서: 한 critical section은 정확히 1개 keeper 락만 잡는다 — 교차-keeper 연산이 없음을 코드 리뷰로 확인했고, 새로 생기면 컴파일이 아니라 리뷰로 잡아야 하므로 `with_write_lock` 문서에 "nested acquisition 금지"를 명시하고 개발 빌드에서 재진입 감지 assert를 넣는다.

### TLA+ (기존 하네스 확장)

`KeeperOASAdvanced.tla`의 CancelledNeverAbsorbed 모델에 keeper 2기 + per-keeper 락을 추가하고, (a) 데드락 부재, (b) keeper A의 critical-section 예외가 B의 진행을 막지 않음(신규 invariant `IsolatedPoisoning`)을 검사한다. 기존 bug-model 패턴(clean cfg pass + buggy cfg violate)을 따른다.

### 서킷브레이커 정렬 (#17/#25)

영속 락이 keeper 단위가 되면 keeper failure circuit breaker의 "open = 해당 keeper의 durable 쓰기 차단"이 실제로 그 keeper에만 작용한다. 브레이커 로직 자체의 변경은 없고, 격리 보장이 사실이 되는 것이 이 RFC의 효과다. 브레이커 상태 전이 매트릭스의 sparse-match 여부 점검(별도 확인 항목)은 구현 PR에서 exhaustive match로 강제한다.

## 마이그레이션

단일 PR로 가능(내부 모듈 경계 안):

1. `with_write_lock ~keeper_name` 시그니처 변경 + 테이블 도입 — 13 사이트 기계 전파, 컴파일러가 누락을 강제.
2. 테스트: 기존 persistence 테스트 전부 + 신규 (a) 교차-keeper 동시 쓰기가 서로를 블록하지 않음(타이밍 아닌 순서-관찰 방식), (b) keeper A critical section 예외 후 A/B 모두 후속 쓰기 정상.
3. TLA+ clean/buggy cfg 쌍.

롤백: 시그니처만 되돌리면 됨 (데이터 형식 무변경).

## 트레이드오프

- **장점**: head-of-line 제거, 오염 반경 축소, 격리 단위 정렬.
- **단점/비용**: 뮤텍스 수 증가(keeper 수만큼 — 수십 개, 무시 가능), 테이블 조회 오버헤드(짧은 전역 락 1회 — 기존 전역 락보다 좁음), nested-acquisition 규율이 컴파일 강제가 아님(assert + 리뷰).
- **대안 검토**: (a) 락-프리(파일 rename 원자성에만 의존) — pending/inflight 쌍의 일관성이 깨질 수 있어 기각. (b) 단일 writer 액터(큐 직렬화) — 전역 직렬화를 형태만 바꿔 유지하는 것이라 기각. (c) 현상 유지 + 타임아웃 — cap/cooldown류 증상 억제라 기각.

## 검증 완료 기준

- [ ] 13 사이트 전파 + 컴파일 green
- [ ] 신규 격리 테스트 2건 green
- [ ] TLA+ clean pass / buggy violate
- [ ] 대시보드 persistence 지연 메트릭(기존)에서 fleet-wide 동시 wake 시나리오 회귀 없음
