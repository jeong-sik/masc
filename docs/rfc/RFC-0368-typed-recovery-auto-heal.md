---
rfc: "0368"
status: Draft
---

# RFC-0368 — 판단 없는 recovery는 keeper의 다음 claim이 스스로 해제한다

**Status**: Draft — §설계 1의 `Transport_interrupted` 재분류는 **철회됨** (아래 정정)
**Author**: Claude Fable 5
**Date**: 2026-08-10

## 문제

official-client 세션이 `Recovery_required`에 들어가면, 원인이 무엇이든 **운영자가 dashboard resolve 엔드포인트를 호출할 때까지 그 keeper의 모든 턴이 `official_client_session.claim`에서 fail-closed** 된다.

2026-08-10 하루의 실측 (라이브, codex 3기):

| 원인 (typed failure) | 건수 | 운영자 해제 시 판단 내용 |
|---|---|---|
| unknown-notification cap (`protocol_failed`) | 2 | — 코드버그, #27954로 제거 |
| empty-delta 거부 (`protocol_failed`) | 2 | — 코드버그, #27969로 제거 |
| retry-cap (`provider_rejected`) | 2 | — 코드버그, #27990으로 제거 |
| 300s 턴 타임아웃 (`transport_interrupted`) | 4 | **0** — 전건 `retry_previous`, 전건 성공 |
| epoch 변경 (의도된 재시작) | 3 | **0** — 전건 기계 규칙으로 해제 |

해제 13회의 결정 규칙은 전부 동일했다: **`previous_settlement`가 있으면 `retry_previous`, 없으면 `restart_fresh`.** 사람이 넣은 판단이 0인데 각 건마다 keeper는 수 분~수십 분 정지했고, upstream 저하 창에서는 fleet 3기가 2시간에 두 번 동시 정지했다.

게이트가 가치 있었던 순간도 분명하다: `protocol_failed`를 멈춰 세운 것이 empty-delta·retry-cap 코드버그를 **드러냈다**. 문제는 게이트가 신호(park해서 보여주기)와 판단(사람이 결정하기)을 구분하지 않고, 판단이 없는 클래스까지 사람을 actuator로 소비하는 것이다.

## 설계

### 1. failure class → recovery policy, 닫힌 매핑

`Keeper_official_client_session_store`의 failure는 이미 typed다. 정책을 닫힌 함수로 붙인다:

```ocaml
type recovery_policy =
  | Auto_heal_at_claim   (* 다음 claim이 결정 규칙으로 해제하고 진행 *)
  | Park_for_operator    (* 지금과 동일: resolve 엔드포인트 대기 *)

let recovery_policy_of_failure = function
  | Epoch_changed -> Auto_heal_at_claim
  | Transport_interrupted -> Auto_heal_at_claim   (* 철회 — 아래 정정 참조 *)
  | Protocol_failed | Provider_rejected -> Park_for_operator
```

catch-all 없는 exhaustive match — failure 변형이 늘면 컴파일러가 정책 결정을 강제한다.

### 2. 해제는 데몬이 아니라 claim 시점의 lazy 결정

새 프로세스·타이머·재시도 카운터를 만들지 않는다. keeper의 **다음 예약 턴**이 claim할 때 `Auto_heal_at_claim` recovery를 만나면, 기존 결정 규칙을 그대로 실행하고 같은 claim 안에서 진행한다:

```ocaml
(* claim 내부, Recovery_required { recovery; _ } 분기 *)
match recovery_policy_of_failure recovery.failure with
| Park_for_operator -> (* 기존 경로 그대로 *)
| Auto_heal_at_claim ->
  let resolution =
    match recovery.previous_settlement with
    | Some _ -> Retry_previous
    | None -> Restart_fresh
  in
  resolve_and_continue ~resolution ~resolved_by:Claim_auto_heal recovery
```

- **pacing은 keeper 케이던스 그 자체다.** 시도당 1회, 스케줄러가 이미 상한 — cap/cooldown 신설 없음 (CLAUDE.md 워크어라운드 시그니처 회피가 아니라, 필요 자체가 없음).
- 해제는 기존 `resolve` 경로를 재사용하고 `resolved_by`만 typed로 구분한다 (`Operator of agent_name | Claim_auto_heal`). 감사 로그·`last_recovery_resolution` 계약 불변.

### 3. 재발은 정보다 — 같은 원인의 연속 auto-heal은 park로 승격

auto-heal로 시작한 턴이 **같은 failure class**로 다시 recovery에 들어가면, 그 recovery는 정책과 무관하게 `Park_for_operator`로 기록한다. 판정 재료는 `last_recovery_resolution`에 이미 있다 (직전 resolution이 `Claim_auto_heal`이고 failure class가 동일한가). 카운터가 아니라 **직전 1건과의 비교**라 상태 추가가 없고, "transient가 아니었다"는 사실이 증거와 함께 사람에게 도달한다.

### 4. Board attention 배선 — 사람은 actuator가 아니라 observer

auto-heal 각 건은 manifest row(`recovery_auto_healed`)와 Board attention 항목을 남긴다. 오늘처럼 fleet-wide 웨이브가 오면 운영자는 **집계로** 본다 — 각 건을 손으로 풀면서가 아니라.

### TS 미러

dashboard의 session 스냅샷 디코더(`resolved_by` 소비처)가 새 variant를 읽어야 한다. RFC-0366이 경고한 대로 한쪽만 넓히면 turn-records/세션 패널이 조용히 어두워진다 — 같은 변경 단위에 포함한다.

## 하지 않는 것

- resolve 엔드포인트·수동 개입 경로는 그대로 남는다 (auto-heal 대상도 사람이 먼저 풀 수 있다).
- `Park_for_operator` 클래스의 자동화는 하지 않는다 — 오늘 그 클래스가 코드버그 3종을 드러냈다. 신호 기능은 보존한다.
- 재시도 카운터·cooldown·별도 recovery 데몬을 만들지 않는다.

## 검증

| 시나리오 | 기대 |
|---|---|
| epoch 변경 후 첫 claim | auto-heal, `resolved_by = Claim_auto_heal`, 턴 진행 |
| 타임아웃 후 settlement 있는 claim | `Retry_previous`로 auto-heal, 세션 연속성 유지 |
| 타임아웃 후 settlement 없는 claim | `Restart_fresh`로 auto-heal |
| `protocol_failed` | park 유지 (기존 테스트 불변) |
| auto-heal 턴이 같은 class로 재실패 | 두 번째 recovery는 park + 직전 resolution 증거 포함 |
| 운영자 선(先)해제 | auto-heal과 경합 없이 기존 conflict 가드(`recovery_id_changed`)로 정합 |

테스트는 기존 wired 파일(`test_keeper_official_client_host` 계열) 확장으로 넣고, 뮤테이션 방향은 "auto-heal 분기 제거 시 epoch 시나리오가 red"로 고정한다.

## 정정 (2026-08-10, 구현 시도 후)

`Transport_interrupted`를 transient로 옮기는 §설계 1을 구현하자 **#28013이 같은 날 착지시킨 대조 단언에 걸렸다**: `"unexplained transport interruption stays ambiguous"` — "모든 failure를 transient로 만들면 통과하는 테스트"를 막으려고 액터가 넣어둔 control이다. 그 control이 옳다.

이 스토어의 존재 이유는 `.mli` 첫 문단에 있다 — **"externally admitted turn을 조용히 중복시키지 않기 위해"**. transport가 끊겼다는 것은 반대편이 그 턴을 실행했는지 우리가 모른다는 뜻이고, 그것이 `Ambiguous`의 정의다. `Owner_stopped_turn`이 transient인 이유(#28012: 우리가 이유를 알고 스스로 멈췄다)가 여기엔 성립하지 않는다.

내 근거였던 "4/4 retry_previous 성공"이 무엇을 측정했는지 다시 보면: **내 해제 선택이 기계적이었다는 것**이지, 그 선택이 안전했다는 것이 아니다. 반대편에서 턴이 이미 실행됐는지는 한 번도 확인하지 않았다 — 관측하지 않은 축을 "성공"으로 셌다.

**대체 설계**: 모호함은 재분류로 없애는 게 아니라 **관측으로 붕괴시킨다.** codex app-server는 thread/turn 신원을 가지므로, recovery 시점에 "이 thread의 최신 turn id"를 조회해 `observed_turn_id`(이미 `recovery_required`에 있는 필드)와 대조하면 "실행됐다/안 됐다"가 사실이 된다. 사실이 확정되면 해제는 결정론이 되고, auto-heal은 모호함을 가정으로 지워서가 아니라 **모호함이 실제로 사라져서** 안전해진다.

따라서 이 RFC의 유효 범위는:
- 유지: 판단 없는 클래스의 문제 정의, 재발-승격(카운터 아닌 직전 1건 비교), Board attention 배선, `Park_for_operator`의 신호 기능 보존
- 철회: `Transport_interrupted → Transient` 재분류
- 후속: 반대편 turn 신원 조회 기반의 ambiguity 해소 (별도 설계, app-server 프로토콜 표면 확인 선행)

## Evidence

- 2026-08-10 라이브 해제 13건 전수: masc#27953 코멘트 스레드 + #27962 P0 코멘트 (recovery_id·원인·resolution·결과 기록)
- upstream 저하 웨이브: 14:5x·15:2x KST 두 차례, 각각 fleet 3기 동시 `Recovery_required`
- 타임아웃 `retry_previous` 성공률: 4/4 (스레드가 타임아웃을 살아남는다는 직접 증거)
