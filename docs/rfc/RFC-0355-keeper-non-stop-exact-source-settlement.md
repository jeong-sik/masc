---
rfc: 0355
title: Keeper non-stop exact-source settlement
status: Draft
created: 2026-07-27
authors: [yousleepwhen, codex]
issues: [25796]
relates: [RFC-0233, RFC-0338, RFC-0341, RFC-0349, RFC-0351, RFC-0353]
implementation_prs: []
evidence:
  - MASC main fbb61120d190d821ccd8b54dd43a6da84d4f3091
  - https://github.com/jeong-sik/masc/issues/25796
  - https://ocaml.org/releases/5.5.0
  - https://ocaml.org/manual/5.5/modtypes.html
  - https://ocaml-multicore.github.io/eio/eio/Eio/Switch/index.html
  - https://ocaml-multicore.github.io/eio/eio/Eio/Cancel/index.html
---

# RFC-0355 - Keeper non-stop exact-source settlement

## 0. Decision

Keeper의 최상위 liveness 계약은 처리 성공이 아니라 **non-stop lifecycle,
source 보존, 원인 보존**이다.

- 처리 가능한 work가 없어도 Keeper lifecycle은 살아 있어야 한다.
- `Blocked`는 정상적인 nonterminal source 상태다.
- attempt terminality는 source terminality를 암시하지 않는다.
- source consumption은 typed terminal-domain proof 또는 원자적으로 durable한
  successor 없이는 구성할 수 없다.
- 모든 blocked 상태는 durable typed reason을 가지며 Health, API, Dashboard가
  동일 SSOT에서 이를 투영한다.
- 무한 busy retry는 non-stop이 아니다. bounded work 뒤 blocked 상태로 쉬면서
  recovery stimulus와 operator action을 계속 관찰해야 한다.

이 RFC는 RFC-0351의 compaction sunset을 뒤집지 않는다. RFC-0351 S4 전환기 동안
남아 있는 compaction이 exact source를 비가역적으로 소비하지 못하도록 settlement
계약을 고정한다.

## 1. Confirmed defect

현재 exact execution은 다음 두 compaction terminal cause를 구분한다.

- `Compaction_produced_no_reduction`
- `Compaction_increased_checkpoint`

하지만 두 cause는 같은 `reject_terminal` 경로를 통과해 다음 하나의 settlement로
수렴한다.

```text
attempt terminal
  -> exact_source_outcome = Terminal
  -> exact_source_action = Consume_source
  -> successor = None
  -> terminal quarantine cannot be released
```

cause의 이름은 다르지만 recovery algebra가 없다. attempt replay를 금지하는 판단이
source의 모든 후속 recovery를 금지하는 판단으로 확대된다.

공유 admission gate 자체는 결함이 아니다. byte와 token evidence가 같은 critical
section에서 직렬화될 수 있다. 결함은 두 capacity 축이 failure streak, recovery,
terminal settlement, source consumption까지 공유하는 것이다.

## 2. Non-stop invariant

모든 Keeper exact-source transition은 다음 불변식을 만족해야 한다.

### N1. Lifecycle survives

Domain work가 `Blocked`, `Reset_required`, `Quarantined_attempt`가 되어도 Keeper
lifecycle fiber와 attention loop는 살아 있다. domain failure를 `Switch.fail`로
승격해 lifecycle switch 전체를 취소하지 않는다.

Eio cancellation은 fiber를 빠르게 종료시키는 control signal이다. cancellation
handler는 blocking recovery I/O를 수행하지 않고 원래 cancellation을 다시
전파한다. durable recovery는 cancellation 전에 기록된 journal을 다음 lifecycle이
재생한다.

### N2. Attempt and source are independent

Attempt quarantine은 동일 dispatch의 replay를 막을 수 있다. 그러나 source는 별도
transition 없이 소비되지 않는다.

```text
attempt_outcome x source_state -> source_transition
```

이 함수는 total하고 closed여야 한다. catch-all, string classifier, empty reason은
허용하지 않는다.

### N3. Consumption requires authority

다음 두 경우만 source consumption을 구성할 수 있다.

1. domain 자체가 끝났음을 증명하는 `terminal_domain_proof`
2. successor가 같은 durable transaction에 설치되었음을 증명하는
   `successor_commit_receipt`

OCaml public interface는 proof와 receipt를 abstract type으로 노출한다. consumer는
record literal, public variant constructor, string parse로 이를 위조할 수 없다.

`terminal_domain_proof`의 유일한 mint authority는 source domain을 exhaustive하게
판정하는 모듈이다. 이 모듈은 closed source-terminal judgment와 그 evidence를
입력으로 요구한다. attempt outcome, persistence module, settlement module은 proof를
mint할 수 없고, attempt-level `Terminal`만으로 source-terminal judgment를 만들 수
없다.

### N4. Blocked preserves the source

Recoverable attempt failure는 source를 다음 durable 상태로 이동한다.

```text
Blocked {
  reason;
  recovery;
  source_ref;
  attempt_ref;
  observation_generation;
  transition_receipt_ref;
  recovery_precondition;
  observed_at;
}
```

`reason`과 `recovery`는 closed variants다. `source_ref`는 원본 source authority를
유지한다. `observation_generation`과 `transition_receipt_ref`는 blocked transition과
같은 durable authority에 기록되어 reload 후 다른 mutable source에서 재구성하지
않는다. `recovery_precondition`은 rearm에 필요한 typed evidence identity를 고정한다.
`observed_at`은 ordering evidence일 뿐 TTL이나 가격 정책에 사용하지 않는다.

### N5. Reason survives every projection

Durable state에 기록된 reason code가 queue reload, fleet Health, API, SSE,
Dashboard decoder, copy, icon을 통과해도 바뀌지 않아야 한다.

다음은 silent failure로 간주한다.

- blocked row를 `Ready`, `Pending`, `missing`, `not_registered`로 default-fill
- closed producer reason을 string으로 serialize한 뒤 불완전한 decoder로 재분류
- `Unknown`, 빈 raw error, generic exception으로 구체 cause 소실
- stale last-good snapshot으로 current blocked state 은폐
- source lease를 소비했지만 successor 또는 terminal proof가 없음

## 3. Ownership boundary

### MASC

- source identity와 durable source state
- attempt/source transition의 domain validation
- HEAD/CAS, journal, settlement atomicity
- typed blocked reason과 operator-visible projection
- Keeper lifecycle, attention, recovery stimulus observation

### OAS

- provider/model/catalog/credential/wire admission
- opaque runtime slot 내부 candidate와 failover
- serialized request byte evidence와 provider response evidence
- 한 outer execution call 안의 candidate settlement

MASC는 provider/model을 알지 않는다. runtime은 스펙이 부착된 opaque slot이며,
MASC의 recovery variant는 provider 이름이나 model ID를 담지 않는다.

Pricing은 measurement telemetry일 뿐 capacity, admission, retry budget, routing,
limit 기능의 입력이 아니다.

## 4. Capacity evidence

Byte capacity와 token capacity는 같은 숫자여도 다른 evidence다.

```text
Request_body_over_capacity of {
  serialized_bytes;
  accepted_bytes;
  evidence_ref;
}

Context_window_over_capacity of {
  input_tokens;
  accepted_tokens;
  evidence_ref;
}
```

둘은 동일 source를 block할 수 있지만 recovery strategy는 다르다.

- request bytes: OAS가 wire evidence를 보존하고 opaque slot failover 가능성을
  판단한다.
- context tokens: caller assembly/compaction 정책이 더 작은 immutable input을
  만들 수 있는지 판단한다.

숫자 equality, provider name, 오류 문자열로 두 축을 합치지 않는다.

## 5. Settlement algebra

목표 interface는 representation을 감춘다. 아래 이름은 계약 예시이며 구현 이름을
강제하지 않는다.

```ocaml
type terminal_domain_proof
type successor_commit_receipt
type blocked_source
type consumed_source

val block_source :
  source ->
  reason:blocked_reason ->
  recovery:recovery_plan ->
  (blocked_source, transition_error) result

val consume_terminal :
  source ->
  terminal_domain_proof ->
  (consumed_source, transition_error) result

val install_successor_and_consume :
  source ->
  successor ->
  (successor_commit_receipt * consumed_source, transition_error) result
```

다음 함수는 존재하면 안 된다.

```ocaml
val consume_source : source -> consumed_source
```

Persistence commit은 immutable prepared transition을 입력으로 받는다. commit 후
call-site가 transition 내용을 바꾸거나 successor를 별도로 덧붙이지 않는다.

## 6. Recovery semantics

### Compaction produced no reduction

- attempt evidence를 terminal로 보존한다.
- source는 consumed가 아니라 typed blocked/recovery state가 된다.
- 같은 immutable attempt replay는 금지한다.
- 현재 contract에서는 reduction 판정이 OAS outer call 성공과 `plan_of_json` 이후에
  일어나므로 candidate advancement가 이미 끝났다. 두 번째 outer call을 failover로
  위장하지 않는다.
- operator-visible `Compaction_ineffective`로 block한다.
- 향후 OAS가 caller-supplied in-call domain validation을 명시적으로 제공할 때만
  동일 outer call 안의 opaque slot advancement를 별도 versioned contract로 검토한다.

### Compaction increased checkpoint

- 확대된 checkpoint candidate를 commit authority로 승격하지 않는다.
- attempt를 quarantine한다.
- last accepted source/checkpoint authority를 유지한다.
- operator-visible `Compaction_increased_checkpoint`로 block한다.

두 경우 모두 source를 살리기 위해 무한 재시도하지 않는다. 하나의 typed recovery
transition을 durable하게 준비하고, 동일 generation에서 중복 실행되지 않도록
fence한다.

### Recovery rearm authority

Generation 증가는 그 자체로 recovery evidence가 아니다. blocked source를 다시
runnable로 만드는 transition은 저장된 `recovery_precondition`과 다른 다음 evidence
중 하나를 소비해야 한다.

- source HEAD 또는 immutable input digest의 변화
- OAS가 발행한 새로운 typed capacity evidence identity
- abstract operator rearm authority
- RFC가 별도로 허용한 closed domain recovery event

주기 wake, 동일 오류의 재전달, process restart, generation 번호 증가는 rearm
authority가 아니다. rearm transition은 소비한 evidence identity를 receipt에
기록하며 같은 evidence로 다음 generation을 다시 만들 수 없다.

## 7. Concurrency and crash contract

1. source HEAD와 attempt generation을 읽는다.
2. blocked reason, recovery precondition, successor를 포함한 immutable transition을
   준비한다.
3. recovery intent journal을 durable하게 기록한다.
4. attempt terminal과 source state를 같은 atomic authority로 commit한다. 저장소가
   이를 한 commit으로 지원하지 않으면 recovery journal이 먼저 durable해야 하며
   attempt terminal 뒤의 crash에서 반드시 재생 가능해야 한다.
5. transition receipt가 durable한 뒤 lease를 해제한다.
6. crash recovery는 receipt/journal을 재생하거나 current HEAD와 일치함을 증명한
   뒤에만 journal을 지운다.

다음 crash point를 각각 증명해야 한다.

- attempt terminal persistence 전후
- blocked/successor prepare 전후
- source HEAD CAS 전후
- receipt fsync 전후
- lease release 전후

어떤 crash point에서도 source가 `Consumed`인데 terminal proof와 successor가 모두
없는 상태는 도달 불능이어야 한다. attempt가 terminal인데 blocked/successor
transition과 recovery journal이 모두 없는 상태도 도달 불능이어야 한다.

## 8. Required projections

Health, API, SSE, Dashboard는 동일 typed observation에서 다음을 투영한다.

- lifecycle: `running`
- source: `blocked`
- reason code
- recovery class
- observation generation
- last transition receipt reference

UI는 block을 crash나 success로 표현하지 않는다. 색상, 아이콘, 문구는 별도
분류기를 갖지 않고 server의 closed status/reason code에 대한 exhaustive mapping만
사용한다.

## 9. Proof matrix

| Scenario | Required result |
|---|---|
| no-reduction | attempt terminal, source blocked, lifecycle running |
| increased checkpoint | candidate quarantined, accepted source retained |
| repeated incompressible input | bounded work, durable blocked, no busy loop |
| crash at every settlement boundary | source retained or successor durable |
| queue/server reload | exact reason code retained |
| Health/API/SSE/Dashboard | same generation, status, reason, receipt |
| recovery stimulus | one fenced transition back to runnable |
| unchanged recovery evidence | cannot advance to another generation |
| attempt terminal only | cannot mint terminal-domain proof |
| empty queue / all sources blocked | lifecycle and attention loop remain running until explicit stop |
| old pre-1.0 row | explicit reset-required; no migration/default decoder |

Full Cycle acceptance is fresh-state only:

```text
source
-> attempt
-> typed capacity evidence
-> blocked
-> Health/API/SSE/Dashboard observation
-> recovery stimulus
-> runnable successor
-> successful output
```

## 10. Implementation sequence

1. Introduce abstract settlement proof/receipt types and split attempt outcome
   from source disposition.
2. Persist blocked reason or successor atomically before lease consumption.
3. Route compaction terminal causes to distinct recovery semantics.
4. Remove string reparsing and default projection from queue/Health/Dashboard.
5. Add crash/restart, non-sharing, bounded-retry, and projection conformance
   proofs.
6. Run fresh-state live Full Cycle and record runtime plus Dashboard evidence.
7. RFC-0351 S4 removes the remaining compaction surface once assembly-based
   context management satisfies its gate.

## 11. Non-goals

- provider/model-aware MASC routing
- pricing-based capacity or retry policy
- old runtime JSON migration, backfill, compatibility decoder, reconciliation
- compaction summarizer quality heuristics
- infinite retry as a substitute for durable blocked state
- Dashboard-only inference of backend state
