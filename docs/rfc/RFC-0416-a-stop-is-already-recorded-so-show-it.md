---
rfc: "0416"
title: 중단 요청은 이미 기록된다 — 새 상태 대신 그 기록을 배포하고 보여준다
status: Draft
created: 2026-09-04
author: Claude Opus 5
supersedes: []
superseded_by: null
related: ["0401", "0406", "0407"]
---

## 0. 한 줄 요약

이슈 #32863 은 키퍼가 태스크 취소를 청원할 수 있는 새 상태 `cancel_requested`
를 요구한다. 이 문서는 **새 상태를 기각한다**. 새 상태가 보존할 사실이 하나도
남아 있지 않다.

청원 기능 자체는 옳고 이미 main 에 있다 — 새 생성자가 아니라 기존
`AwaitingVerification` 에 `intent` 를 붙이는 방식으로 2026-09-03 에 들어왔다
(#32960, #32974). 라이브에서 키퍼 둘이 그 도구를 네 번 불렀다.

그러나 이 메커니즘은 **끝까지 한 번도 돌아본 적이 없다.** 중단 청원 3건 전부가
판정 단계에서 죽었고, 라이브에서 `cancelled` 로 간 태스크 3건은 모두 청원을
거치지 않은 직접 취소다(§3.3). 원인은 초안이 적은 "조회 결함"이 아니라
**기록이 쓰이지 않은 것**이고, 트리에서는 #33046 이 이미 고쳤다. 남은 일은
배포와 재측정이다.

살아남은 설계는 하나다 — **대시보드가 이미 기록된 `intent` 를 읽는다.**
새 상태 0, 새 필드 0, 새 Gate 0.

그리고 초안이 "판정이 유일한 장치"라고 쓴 자리는 **이미 열려 있다** — 키퍼는
`Cancel, Todo` arm 으로 판정 없이 terminal 에 닿는다(§2.3). 이 RFC 는 그것을
기록하되, 막을지는 소유자에게 남긴다.

### 0.1 이슈가 말하는 "RFC-0402" 는 다른 문서다

#32863 본문 제목은 `## 제안 사항 (RFC-0402)` 이다. main 의 `RFC-0402` 는
`RFC-0402-memory-os-board-provenance.md` 로 관련이 없다. 이슈를 따라온 사람이
엉뚱한 문서에 도착하지 않도록 적어 둔다 — **이 청원에 답하는 문서는
RFC-0416, 이 문서다.**

---

## 1. 문제 — 키퍼가 오늘 기록하지 못하는 것은 무엇인가

### 1.1 이슈의 전제는 2026-09-04 기준 거짓이다

#32863(2026-09-03T12:04:28Z 작성) 본문:

> 현재 MASC 거버넌스에서 키퍼는 태스크 완료(`keeper_task_done`) 또는
> 포기/반납(`keeper_task_release`)만 수행할 수 있으며, 취소
> 전이(`action=cancel`)는 `not_model_invocable`로 차단되어 있습니다.

이슈가 열린 다섯 시간 뒤 두 PR 이 그 문장을 지웠다
(`git log origin/main --format='%h %ad %s' --date=iso-strict`):

| PR | 병합(UTC) | 제목 |
|---|---|---|
| #32960 | 2026-09-03T17:13:56Z | `feat(task): a producer submits its stop the way it submits its work` |
| #32974 | 2026-09-03T17:26:06Z | `feat(keeper): a Keeper can ask for a task to be cancelled` |

`keeper_task_cancel` 은 지금 모델이 부를 수 있는 도구다. **모델 표면에 싣는 것은
`keeper_model_projection` 이다** — `task_descriptor`
(`lib/keeper/keeper_tool_descriptor.ml:1538`)가
`~keeper_model_projection:Internal_name` 을 고정으로 넘기고(`:1542`), 도구를
숨기는 값은 같은 타입의 `Operator_only` 다(파일 안 30곳). 초안은 이 자리를
`capability_identity` 로 적었는데, 그건 `Internal_name_identity |
Named_capability of string`(`:391-393`)이라는 별개 축이고 표면 노출과 무관하다.
`Operator_only`/`Transport_alias` 는 `keeper_model_projection`
생성자(`:20-24`)이지 `capability_identity` 의 대안이 아니다.

핸들러는 사유를 필수로 받는다 —
`lib/keeper/keeper_tool_task_runtime.ml:998-1000` 의 거부 메시지가 이슈의
사례를 그대로 예시로 든다:

```
reason is required. Say why this task should stop existing rather than move to
someone else. Example: reason='the defect was fixed in #32078; what this task
describes no longer occurs'.
```

`#32078` 은 #32863 이 task-704 를 이미 고쳤다고 지목한 그 PR 이다.

**라이브 호출 실측** — 4건, 전부 `outcome=ok`. 키퍼 이름은 `keeper_name` 필드가
아니라 메시지 본문 접두사에 있다(`keeper_name` 은 네 줄 모두 `"system"`):

```
$ rg -N 'tool_call tool=keeper_task_cancel' ~/me/.masc/logs/system_log_2026-09-0*.jsonl
2026-09-03T18:12:15Z  keeper:rondo         tool_call tool=keeper_task_cancel … outcome=ok
2026-09-03T18:38:17Z  keeper:edgar.a.poe   tool_call tool=keeper_task_cancel … outcome=ok
2026-09-03T19:16:43Z  keeper:edgar.a.poe   tool_call tool=keeper_task_cancel … outcome=ok
2026-09-04T02:13:29Z  keeper:edgar.a.poe   tool_call tool=keeper_task_cancel … outcome=ok
```

네 건 중 18:12:15Z(rondo)는 실무가 아니라 **스키마 probe** 다 — 같은 키퍼가 8초
전에 만든 `task-1295` 를 즉시 닫았고 사유가 그렇게 적혀 있다(§6).

### 1.2 그리고 그것은 새 상태 없이 만들어졌다

`lib/types/types_core.ml:242-264` 의 `task_status` 는 여전히 여섯 개다 —
`Todo | Claimed | InProgress | AwaitingVerification | Done | Cancelled`.
`CancelRequested` 는 없고, 필요하지도 않았다. 중단 청원은 기존
`AwaitingVerification` 이 `intent` 를 실어서 표현한다(`:208`, `:233`):

```ocaml
type verification_intent = Complete_task | Cancel_task

type verification_claim =
  | Completion_evidence of { evidence_refs : string list }
  | Cancellation_reason of { reason : string }
```

`intent=Cancel_task` 를 만드는 arm 은 **두 곳**이다 —
`Claimed`/`InProgress` 에서 오는 `workspace_task_lifecycle.ml:119-133` 과,
대기 중인 제출을 갈아치우는 `:139-150`. 승인은 `:265-271` 에서 `intent` 를 읽어
종착을 고른다:

```ocaml
| Masc_domain.Verdict_approved ->
  let new_status =
    match intent with
    | Masc_domain.Complete_task -> done_status ~assignee ~now ~notes
    | Masc_domain.Cancel_task ->
      cancelled_status ~agent_name:assignee ~now ~reason:notes
```

`intent` 는 기본값 없이 디코딩되고(`types_core.ml:470`), 와이어로도 나간다
(`:433`).

### 1.3 오늘 기록되지 못하는 사실 — 새 상태가 담을 것은 없다

`cancel_requested` 가 담겠다는 것을 하나씩 대보면 **새 생성자가 보존할 사실이
없다.** 초안이 이 표를 "전부 있다"로 닫은 것은 맞았지만, 근거로 든 자리가
한 칸 틀렸다.

| 담으려던 것 | 오늘 어디에 있나 | 상태 |
|---|---|---|
| 누가 청원했나 | `AwaitingVerification.assignee` | 있다 |
| 언제 청원했나 | `AwaitingVerification.submitted_at` | 있다 |
| 왜 | 시스템 로그 `task_transition` 행의 `reason` | 있다 |
| 왜 (판정자가 읽는 자리) | `Cancellation_reason { reason }` | **배포본이 쓰지 않았다.** 트리는 #33046 이 고침 (§3.3) |
| 무엇을 물었나 | `AwaitingVerification.intent` | 있다 — 부른 도구가 정하고 그대로 기록된다 |
| 승인 뒤 누가·언제 닫혔나 | `Cancelled { cancelled_by; cancelled_at }` | 있다 |
| 승인 뒤 왜 닫혔나 | `Cancelled.reason` = **판정자 노트** | 청원자 문장은 판정 기록에 남고 join 으로 닿는다. 이 경로는 아직 한 번도 실행된 적이 없다 (§7.3) |

**"왜" 는 로그에 있다.** task-1303 의 취소 전이 행이 사유를 573자 담고 있다:

```
$ rg -N '"transition":"cancel"' ~/me/.masc/logs/system_log_2026-09-03.jsonl
2026-09-03T18:38:16Z  agent_id=edgar.a.poe  task-1303  in_progress -> awaiting_verification
  → details.reason 길이 573자
```

**판정자가 읽는 자리에는 없었다.** `~/me/.masc/verifications/` 1027개 파일 중
중단 청원 세 건의 파일이 없고, 필드 자체가 한 번도 등장하지 않는다:

```
$ ls ~/me/.masc/verifications | wc -l                                   → 1027
$ ls ~/me/.masc/verifications/vrf-4854621135b0e10bf7bb8e01a9561f53.json → 없음
$ ls ~/me/.masc/verifications/vrf-2ddc81ed2e088ec79f92894d7b2d9284.json → 없음
$ ls ~/me/.masc/verifications/vrf-3b7e90068d9c42fca3ced7030ad28aa6.json → 없음
$ rg -l -i 'cancellation_reason' ~/me/.masc/verifications | wc -l       → 0
```

요청 레코드 스키마에는 `intent` 나 `reason` 칸이 아예 없다 — 완료 청원 하나를
열어 보면 키가 `created_at, criteria, id, output, task_id, worker` 뿐이고,
"왜" 는 `output` 안에 실려 간다.

**"무엇을 물었나"는 재제출이 덮지 않는다.** 적대 리뷰 한 건이 반대로 진단했고,
그 지적은 반려한다. `Submit_for_verification` 이 `AwaitingVerification` 에서
올 때 `intent = Complete_task` 를 쓰는 것은(`:205`) 덮어쓰기가 아니라
**부른 문을 그대로 적는 것**이다. 같은 파일에서 `Claimed`(`:168`)과
`InProgress`(`:181`)에서 오는 제출도 똑같이 `Complete_task` 를 쓰고, 중단 문
(`Cancel`)으로 들어오면 `:130`·`:147` 이 `Cancel_task` 를 쓴다. 즉 intent 는
언제나 caller 가 정하고 전이는 그것을 기록한다.

task-1303 이 그 경로를 실제로 지났다(시스템 로그 전수):

| 시각(UTC) | 부른 문 | 기록된 intent | 결과 |
|---|---|---|---|
| 18:38:16 | cancel (사유 573자) | cancel | `vrf-4854621135…` → 기록 없어 판정 죽음 ×2 |
| 19:11:09 | submit_for_verification | complete | `vrf-6be298f4…` → **rejected** |
| 19:16:43 | cancel | cancel | `vrf-3b7e9006…` → 기록 없어 판정 죽음 ×14 |

19:12:53Z 판정문 원문:

> 작업이 수행되지 않았음을 제출자가 명시적으로 선언했습니다("무코드", "이
> 태스크는 완료가 아니라 소멸이 정답") … **완료로 인정할 검증 가능한 증거가
> 없습니다.**

제출자는 "소멸이 정답"이라고 적고 **완료 문을 두드렸다.** 판정자는 완료를
물어 기각했다 — 부른 문에 맞는 판정이다. 앞선 질문도 사라지지 않았다:
18:38:16 의 취소 전이 행이 사유와 함께 로그에 남아 있다. **거짓이 기록된 자리는
없다.** 이 사건의 원인은 intent 가 아니라 §3.3 이다 — 첫 청원의 판정이 기록
부재로 죽자 키퍼가 다른 문을 두드린 것이다. 기록이 쓰였다면 첫 청원이 판정을
받았다.

**`Cancelled.reason` 은 비어 있지 않다.** 라이브 취소 35건 **전부** 비어 있지
않은 사유를 갖고 있고, 그중 "다른 곳에서 이미 닫혔다"를 이슈·PR·커밋 번호로
대는 건이 **16건**이다. 판별식은 `reason` 이 `#\d{4,6}` 또는 9자 이상 커밋
sha 를 포함하는 것(18건)에서 클레임 실패로 닫힌 2건(task-553, task-1259)을 뺀
값이다. 초안의 "12건"은 판별식이 없었고 재현되지 않는다. 실례:

- `task-552` — "main 에 이미 고쳐져 있습니다. 남겨두면 다음 사람이 없는 버그를
  찾게 됩니다."
- `task-723` — "PR #30207 이 08-24 에 이미 해결했습니다. …"
- `task-1210` — "Superseded: the work landed as PR #32367 (a0d072f28c) …"

이슈가 새 상태로 담고 싶어 한 문장은 이미 이 필드에 있다.

### 1.4 측정된 피해 — "550+" 는 재현되지 않는다

`backlog.json` 전수 census(`version=3547`, `last_updated=2026-09-04T08:16:02Z`):

```
총 822건 — todo 577 · done 203 · cancelled 35 · in_progress 6 · awaiting_verification 2
```

`577 ≈ 550+` 는 맞다. 그러나 그것은 **todo 총계**이지 오염 건수가 아니다.
같은 파일에서 `cycle_count`(반납 횟수)를 갈라보면:

| todo 577건 | 건수 | 비율 |
|---|---|---|
| 한 번도 클레임된 적 없음 (`cycle_count` 없음) | **503** | 87.2% |
| 반납 1–2회 | 52 | 9.0% |
| 반납 3회 이상 | 22 | 3.8% |

`cycle_count` 는 `Release` 에서만 증가한다
(`lib/workspace/workspace_task_transition_executor.ml:67-79`). 즉
`cycle_count` 없음 = 아무도 집은 적이 없음이다. **577건 중 503건은 유령이
아니라 미착수 일감이다.** 새 취소 상태를 만들어도 이 503건은 한 건도 줄지
않는다.

반납 상위 4건도 이슈의 그림과 다르다 (`handoff_context.next_step` 원문):

| 태스크 | cycle | 반납 원인 | 취소로 닫히나 |
|---|---|---|---|
| task-371 | 23 | "분해(11개 단일 issue) 후 각 keeper 배정 또는 cycle_count≥8 auto-claim 제외 가드 적용" | 아니오 — 범위 문제 |
| task-551 | 17 | "운영자가 keeper repositories catalog 에 … 등록·마운트" | 아니오 — 프로비저닝 |
| task-650 | 10 | "underlying issue is already resolved" | **예 — 유령** |
| task-770 | 9 | "운영자가 Dune lock holder … 정리한 뒤" | 아니오 — 환경 |

"무한 루프"도 성립하지 않는다. 상한은 23회이고, 이슈가 지목한 두 태스크는 이미
멈춰 있다 — task-569 는 2026-09-02T19:16:01Z, task-704 는
2026-09-03T11:51:10Z 이후 재클레임이 없다.

---

## 2. 이 규칙을 먼저 통과해야 한다

`~/me/instructions/projects.md`, MASC autonomy and evidence:

> 새 상태·필드·Gate 는 없을 때 durable truth 가 손상되는 경우에만 추가한다.
> 행동을 유도하거나 강제하는 장치는 기본적으로 추가하지 않는다.

> Interrupted, Ambiguous, acknowledgement, dependency 등 과거 evidence 를
> scheduling Gate 로 사용하지 않는다.

세 갈래로 답한다.

### 2.1 `cancel_requested` 없이 손상되는 durable truth 가 있는가 — 없다

§1.3 의 표가 답이다. 청원자·시각·사유·질문 종류·종결자가 전부 기존 필드 또는
로그에 있다. **새 생성자가 보존할 사실이 남아 있지 않다.** 오히려 지금 추가하면
하나의 의무가 두 상태로 쪼개져, `AwaitingVerification{intent=Cancel_task}` 와
`CancelRequested` 가 같은 사실을 두 자리에 적게 된다 — SSOT 손상이지 보강이
아니다.

§1.3 이 찾아낸 진짜 결함 하나도 새 상태를 정당화하지 않는다. **판정자가 읽는
자리에 기록이 쓰이지 않은 것**이고, 답은 새 상태가 아니라 쓰기다. 그 쓰기는
트리에 이미 있다(#33046, §3.3). 규칙이 요구하는 "없을 때 durable truth 가
손상되는" 조건을 충족한 것은 **그 쓰기**였고, 새 생성자가 아니었다.

이 판정은 "지금 코드가 그러니까"가 아니다. #32960 의 설계 근거가 코드 주석에
남아 있다(`workspace_task_lifecycle.ml:115-118`):

> A producer stops its own work the same way it finishes it: by submitting the
> claim and waiting for a verdict.

하나의 판정, 두 개의 종착. 상태를 늘리는 대신 **무엇을 물었는지를 의무가
기억하게** 한 것이고, 그게 더 작은 답이다.

### 2.2 주장된 피해는 스케줄링 불만이다

이슈가 든 피해는 "백로그 오염"과 "무한 헛바퀴 클레임 루프" 두 가지다. 둘 다
사실의 손실이 아니라 **일이 배정되는 순서에 대한 불만**이다. 규칙 두 번째
문장이 정확히 이 자리를 막는다.

이건 추상적 걱정이 아니다. 반납 최다 태스크 task-371 의 `next_step` 이 스스로
그 처방을 적어 놓았다:

> cycle_count≥8 auto-claim 제외 가드 적용해 루프 방지 후 재클레임.

즉 "과거 반납 횟수라는 evidence 로 앞으로의 클레임을 막는 Gate". 규칙이 이름을
붙여 금지한 바로 그 형태다. 이 RFC 는 그것을 제안하지 않으며, 제안되면
반대한다. task-371 의 실제 결함은 "11개 이슈를 하나의 태스크로 묶은 것"이고,
답은 가드가 아니라 분해다.

### 2.3 Part 2(조건부 자율 취소)는 기각한다 — 그리고 비대칭은 이미 열려 있다

#32863 은 "결함 원인이 이미 main 브랜치 커밋에 포함되어 있음을 … verifier
버그로 명시된 이슈와 결합된 경우 자동 취소 승인"을 제안한다. 이는 행동을
강제하는 장치이자, 생산자가 자기 의무를 스스로 닫는 경로다.

코드가 그 비대칭을 이렇게 설명한다(`workspace_task_lifecycle.ml:114-118`,
`Done_action` 거부 arm 은 `:99-104`):

> Cancelling outright would give a Keeper one terminal state it can reach alone
> while `Done_action` refuses every lane that is not a submission — "I could not
> do this" would settle itself and "I did this" would not.

**초안은 "이를 막는 장치는 오늘 하나뿐이고 — 판정이다"라고 적었다. 그건
틀렸다.** 그 문이 이미 열려 있다:

```ocaml
(* workspace_task_lifecycle.ml:112-113 — 소유자 검사 없음 *)
| Masc_domain.Cancel, Masc_domain.Todo ->
  ok (cancelled_status ~agent_name ~now ~reason)

(* :152-154 — 반납은 소유자 검사가 있고, 결과는 Todo *)
| ( Masc_domain.Release
  , (Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _}) ) ->
  if same_agent assignee then ok Masc_domain.Todo else Error Invalid_transition
```

`keeper_task_cancel` 핸들러는 소유자도 권한도 검사하지 않고 `action=cancel` 을
그대로 전이에 넘긴다(`keeper_tool_task_runtime.ml:1002-1016`). 그래서 키퍼는
**자기가 쥔 태스크를 release 한 뒤 cancel 하면 판정 없이 terminal 에 닿고, 남의
`Todo` 태스크도 한 호출로 닫을 수 있다.** 주석이 경고한 상태가 이미 성립해
있다.

이 사실은 Part 2 기각을 흔들지 않고 **강화한다.** 이미 새는 구멍을 조건부 자동
승인으로 넓히는 것은 반대 방향이다. 다만 기각 근거를 정직하게 적어야 한다 —
"판정이 막고 있다"가 아니라 "판정이 막아야 하는데 한 arm 이 새고 있고, 그
arm 을 넓히는 제안이다".

실측이 우려를 뒷받침한다. task-1303 의 제출 노트에서 키퍼가 스스로 적었다:

> 설립 근거였던 "도구 호출 원문이 대시보드에 표시된다"는 항은 코드·실측
> 어디로도 검증 불가한 제 **추정**이었음을 인정
> (`~/me/.masc/logs/system_log_2026-09-03.jsonl`, seq 20630590)

자기 추정으로 세운 태스크를 자기가 닫겠다는 청원이다. 정직한 청원이고 아마
승인되어야 하지만, **정직함은 자율 승인의 근거가 아니다.** §3.2 가 그 이유를
숫자로 보여준다 — 생산자가 "유령이다"라고 선언한 3건 중 판정자가 동의한 것은
1건이다.

**결론: Part 2 는 채택하지 않는다.** 안전하게 만드는 장치가 없기 때문이다.
장치를 만들려면 "자동 승인해도 되는 증거"의 판별기를 새로 세워야 하는데, 그건
판정자를 하나 더 만드는 일이지 판정을 없애는 일이 아니다.

---

## 3. 대안 먼저 — 판정기 수리는 몇 건을 닫는가

`cancel_requested` 를 요구한 두 번째 근거는 "판정 불가"였다 — #32569,
`verifier_exact` 가 microvm 게스트 아티팩트를 못 읽는다는 것. 이게 사실이면
답은 상태 신설이 아니라 **판정기 수리**다. 그 질문에 답하는 문서는 이미 둘
있다 — **RFC-0406**(검증자는 떠 있는 게스트에 붙는다)과
**RFC-0407**(판정자의 읽기 경로는 스냅샷이 정본이다). 이 절은 그 둘을 다시
논하지 않고, 남은 기각이 무엇을 요구하는지만 센다.

### 3.1 트리 읽기 경로는 고쳐졌다. 기각률은 그것으로 설명되지 않는다

이슈가 인용한 두 실패 문자열은 트리에 없다:

```
$ rg -n 'microvm_read_requires_turn_sandbox_factory|microvm_read_failed' --type ml lib/
(0 hits, exit 1)
```

`lib/keeper/keeper_sandbox_read_backend.ml:226` 이 `Micro_vm` 을
`Attached_guest` 로 보낸다. 수리 이력:

| 커밋 | 병합(UTC) | 내용 |
|---|---|---|
| `cde711a382` (#32641) | 2026-09-02T13:14:24Z | 실행 중 guest 에 attach |
| `3e6bbbee2f` (#32646) | 2026-09-02T14:04:39Z | 남은 거절문 제거 |
| `e8e736629c` (#32933) | 2026-09-03T18:26:09Z | 선언된 microVM 런타임이 부팅에 닿게 |

측정 대상은 `~/me/.masc/verification-runs.jsonl`. 초안은 "65 run" 이라고
적었는데 재현되지 않는다. 재측정(2026-09-04T08:11Z): 132줄 = register 66 +
complete 66, **고유 id 64개**. register 가 2회인 id 가 둘이고, 둘 다 중단
청원이다(07:41:17Z 재등록). 창은 2026-08-31T21:03:13Z ~ 2026-09-04T07:41:17Z,
판정자는 전부 `verifier_exact`. #32641 병합 시각으로 갈랐다:

| | 이전 | 이후 |
|---|---|---|
| 고유 run | 38 | 26 |
| approved | 14 | 11 |
| rejected | **22 (57.9%)** | **12 (46.2%)** |
| `commit_failed` | 1 | 0 |
| `not_reviewed` | 1 | 0 |
| `infrastructure_unavailable` | 0 | 3 |
| 합 | 38 | 26 |

초안의 이전 열은 `39 / 15 / 22 / 0` 이었고 합이 37 로 맞지 않았다. 빠진 두
칸이 `commit_failed` 1 과 `not_reviewed` 1 이다.

**그리고 초안이 이 표에서 끌어낸 인과 결론은 철회한다.** 초안은 "기각률이
거의 그대로이므로 읽기가 지배적 원인이 아니었다"고 적었다. 이 표본은 그 결론을
지탱하지 못한다 — Fisher 양측 검정으로 `p = 0.447`(전체 run), 판정이 난
것만으로는 `p = 0.592` 다. "효과 없음"과 "중간 정도 효과"를 구별할 수 없는
표본이다. 서술로는 "거의 그대로"가 맞지만, 거기서 원인을 배제할 수는 없다.

### 3.2 수리 후 기각 12건 — 10건이 읽기·증거 접근 실패를 낀다

초안은 이 12건을 "읽기 막힘 2 / 읽기 성공·증거 부재 7 / 유령 3" 으로 갈랐다.
**그 분할은 판정기 몫을 과소평가했다.** 12건의 complete 레코드를 실패 토큰으로
전수 스캔했다:

| 어디에 나타나나 | 건수/12 | 태스크 |
|---|---|---|
| 판정문 본문이 읽기·증거 접근 실패를 인용 | **8** | task-1245 ×2, task-569, task-1250, task-577, task-563, task-704, task-1282 |
| 판정문에는 없고 도구 흔적에만 (판정자가 시도·실패 후 우회) | **2** | task-1257, task-1313 |
| 어느 쪽에도 없음 | **2** | task-1303, task-1311 |

토큰별(레코드 전체 기준): `artifact_unreadable` 8, `microvm_remote_read_failed`
8, `microvm_guest_not_running` 1, `path_outside_sandbox` 1,
`microvm_read_requires_turn_sandbox_factory` 1.

즉 **12건 중 10건이 읽기 또는 증거 접근 실패를 낀다.** 초안이 "읽기는 성공,
증거를 만든 적 없음"으로 분류한 7건 중 6건의 판정문이
`artifact_unreadable(missing)` 을 이름으로 부른다. 초안이 그 분류의 근거로
인용한 task-1282 판정문 자신이 그렇다:

> 핵심 artifact … 가 제출 스냅샷에서 **artifact_unreadable(missing)** 로
> 기록되어 증거로 사용 불가하며 … lookup이 안내한 masc/ 체크아웃 읽기 시도는
> **microvm_remote_read_failed** 'No such file or directory'…

`artifact_unreadable(missing)` 은 트리 읽기 실패가 아니라 **제출 스냅샷에 파일이
없다**는 뜻이고, 스냅샷에 없는 파일은 판정자가 열 방법이 없다. 그 절반을 다루는
문서가 RFC-0407 이다. 이 RFC 의 범위가 아니다.

**새 상태가 닿는 건수는 여전히 0 이다.** 다만 근거가 초안과 다르다. 초안은
"유령 3건에만 닿고 그 3건은 기존 도구로 된다"고 했는데, 판정문을 다시 읽으면
유령으로 **확정**되는 것은 1건뿐이다:

- **task-569** — 확정. 판정문: "이슈 #26795는 라이브에서 Closed이나 … worker
  (rondo)가 연 병합 PR은 없음" (`vrf-2ce230f0813420954d7cfdc5f1eee760`).
- **task-563** — 아니다. 판정문은 "지금 GitHub 를 직접 열어 확인: state=Open …
  닫지 않았고 'owner 손 close 요망'으로 남겼다"고 적었다
  (`vrf-fb2f17a5e1d039…`). 전제가 사라진 게 아니라 남은 일을 판정자가 짚었다.
- **task-1303** — 아니다. 판정문은 "완료로 인정할 검증 가능한 증거가 없습니다"
  일 뿐, "유령"이라는 주장을 인정하지 않았다.

이 정정은 이 RFC 의 결론에 **불리한 방향이 아니다.** 반대다. 생산자가 "유령이다"
라고 선언한 3건 중 판정자가 동의한 것이 1건이라는 사실은, 자율 취소를 열면
무엇이 통과할지를 보여준다(§2.3).

task-569 의 판정문이 부족했던 것을 정확히 말한다:

> 제출 노트 자체가 "구조적으로 불이행 불가, 취소가 정답"이라고 진술한 불이행
> 자백 제출물임.

판정자는 "취소가 정답"이라는 주장을 읽고도 `rejected` 말고 낼 게 없었다.
부족했던 것은 상태가 아니라 **질문의 종류**였고, 그 입구는 #32960 이 만들었다.

### 3.3 진짜 남은 결함 — 청원한 판정이 죽는다. 기록이 없어서다

**초안은 이 자리를 "조회 결함"이라고 진단했다. 인과가 반대다.**

이 문구로 죽은 판정을 전수로 세면 **25건**이고, verification id 는 셋뿐이며
셋 다 중단 청원이다:

```
$ rg -N 'authority deferred' ~/me/.masc/logs/system_log_2026-09-0*.jsonl \
  | rg -N 'reason=Verification .* not found' | rg -o 'verification_id=vrf-[0-9a-f]{8}' \
  | sort | uniq -c
   2 vrf-48546211    (task-1303, 첫 청원)
   9 vrf-2ddc81ed    (task-1282)
  14 vrf-3b7e9006    (task-1303, 재청원)
→ 25건, 2026-09-03T18:38:17Z ~ 2026-09-04T07:41:17Z
```

`verification-runs.jsonl` 에서는 이것이 `infrastructure_unavailable`
complete 이벤트 **5건 / 고유 run 3건**으로 잡힌다. 초안의 "3건"은 고유 run
기준이며, 그 계수 단위가 §3.1 표의 다른 칸과 다르다는 말이 없었다.

**왜 못 찾았나 — 파일이 없기 때문이다.** §1.3 에서 측정했다: 세 id 의 파일이
`~/me/.masc/verifications/`(1027개) 어디에도 없다. 같은 창의 완료 청원 23건은
기록이 **있고**, 다른 사유로 죽은 판정(`vrf-b2fcbcd8` 76건, `vrf-230eabfb`
39건 — 런타임 레인 미설정)도 기록이 **있다.** 갈라지는 축은 정확히 `intent` 다.

그리고 main 의 주석이 그 이유를 그대로 적어 놓았다
(`workspace_task_transitions.ml:291-297`):

> Keyed on the produced state so every path into `AwaitingVerification`
> writes the record the authority reads. **Keyed on the action, the cancel path
> wrote none**, and the authority deferred the Task on "verification not found"
> until an operator noticed (task-1303, 2026-09-03).

즉 배포본은 취소 경로에서 기록을 **쓰지 않았다.** 조회가 못 찾은 게 아니라
없는 것을 못 찾은 것이다. 초안은 타입(`Cancellation_reason`)의 존재를 지속성의
증거로 읽었다.

**트리는 이미 고쳐져 있다.** `pending_verification` 이 `new_status` 로 키를
바꾸면서 `Cancel_task` arm 이 `Cancellation_reason` 을 쓴다
(`workspace_task_transitions.ml:311-333`). 수리 PR:

| PR | 병합(UTC) | 제목 |
|---|---|---|
| #33046 | 2026-09-04T04:04:42Z | `fix(task): a stop waits on a record the authority can read` |
| #33059 | 2026-09-04T04:54:23Z | `feat(verification): a stop is judged on its reason, not on what it did not build` |
| #33080 | 2026-09-04T06:27:03Z | `fix(verification): the cancellation lookup slot describes tools, it does not order a rejection` |

**그래서 이 메커니즘은 끝까지 한 번도 돌아본 적이 없다.** 창 안에서
`cancelled` 로 간 태스크 3건은 모두 청원을 거치지 않았다:

```
$ rg -N '"to_status":"cancelled"' ~/me/.masc/logs/system_log_2026-09-0*.jsonl
2026-09-01T14:09:44Z  codex-mcp-client  task-1210  todo -> cancelled
2026-09-03T10:34:13Z  codex-mcp-client  task-1259  todo -> cancelled
2026-09-03T18:12:15Z  rondo             task-1295  todo -> cancelled   (스키마 probe)
```

승인된 중단 청원은 **0건**이다. 남은 일은 배포와 재측정이고, 07:41:17Z 재등록
두 건이 여전히 기록을 만들지 못했다는 것이 §7.1 의 미해결 항목이다.

---

## 4. 설계 — 살아남은 것

§2 를 통과하지 못한 것은 채택하지 않는다. 남는 것은 **projection 하나**다.

> 가시성은 authority 가 아닌 projection 으로 제공한다.
> (`~/me/instructions/projects.md`)

§3.3 의 기록 쓰기는 이미 트리에 있으므로 이 RFC 가 제안할 것이 아니다. §1.3 과
§2.3 이 찾아낸 나머지 두 자리는 **아직 한 번도 실행되지 않은 경로**이거나
**피해 사례가 없는 구조적 개방**이므로, 규칙에 따라 설계가 아니라 미해결로
남긴다(§7.3, §6). Gate 없이 기능이 올바르게 도는지 먼저 보는 것이 순서다.

### 4.1 대시보드가 `intent` 를 읽는다

`intent` 는 이미 서버가 태스크 JSON 으로 내보낸다(`types_core.ml:433`).
대시보드의 검증 표면은 그 필드를 읽지 않는다. 초안은 이것을
`rg -n 'intent' dashboard/src` 매치 0건으로 적었는데 **거짓이다** — 그 명령은
88줄을 내고, `intentional` 을 뺀 뒤에도 35줄이 남는다.
`dashboard/src/api/keeper-lifecycle.ts` 에는 도메인 식별자 `intent` 가
요청 본문으로 실려 나가고(`PendingResumeIntent`, `resumeIntent()`, `:454`),
`connector-setup-guides.ts` 에는 Discord Gateway Intents 가 있다. 둘 다 태스크
검증과 무관하다.

측정 가능한 형태로 좁히면 이렇다:

```
$ rg -n "\.intent\b|'intent'|\"intent\"" \
    dashboard/src/components/verification/ \
    dashboard/src/api/dashboard-verification-runs.ts \
    dashboard/src/api/dashboard-verification-verdict.ts
(0 hits, exit 1)
```

넓게 봐도 같다. `awaiting_verification` 또는 `verification_id` 를 만지는 파일이
34개인데, 그중 `intent` 를 읽는 파일은 **0개**다.

결과: 운영자 화면에서 `awaiting_verification` 두 건이 똑같이 보인다. 하나는
"이 일을 끝냈으니 봐 달라"이고 다른 하나는 "이 일이 없어져야 한다"인데
구별되지 않는다. #32863 의 part 1 중 운영자 쪽 절반 — "대시보드에서 검토 후
1-클릭 승인/거절" — 이 실제로 비어 있는 부분이 여기다.

**누가 전이하나**: 아무도. **무엇을 기록하나**: 아무것도. 이미 기록된 필드를
읽기만 한다. **누가 승인하나**: 오늘과 같다.
`POST /api/v1/verification/verdict` 가 `Human_operator { operator_id }` 를
만들어 `commit_verdict_r` 를 부른다
(`lib/server/server_routes_http_routes_verification.ml:118`). 판정 권한은
`Human_operator | System_llm_agent` 둘뿐이고(`types_core.ml:179-181`), 키퍼는
approve/reject 를 문자열 단계에서 거부당한다 — `task_action_of_string` 이
남기는 문구 그대로, "A Keeper is not a verifier."(`types_core.ml:157`)

**운영자가 보는 것**: 대기 목록의 각 행이 완료 심사인지 중단 심사인지, 그리고
중단이면 청원 사유가 무엇인지. 승인 버튼은 이미 있는 것을 쓴다.

새 상태 0, 새 필드 0, 새 Gate 0.

### 4.2 하지 않는 것으로 결정한 것

- **`cancel_requested` 생성자** — §2.1. 기존 필드가 담고 있고, 추가하면 한
  사실이 두 자리에 적힌다.
- **`keeper_task_cancel_request` 도구** — 같은 자리를 `keeper_task_cancel` 이
  이미 차지한다(#32974).
- **조건부 자율 취소** — §2.3. 안전하게 만드는 장치가 없고, 새는 arm 을 넓힌다.
- **`cycle_count` 임계 기반 클레임 가드** — §2.2. 규칙이 이름 붙여 금지한
  scheduling Gate 다.
- **`Cancel` 에 `cycle_count` 증가시키기** — "청원→기각→재청원" 루프를 세지
  못하는 것은 사실이다(`workspace_task_transition_executor.ml:67-79` 는
  `Release` 에서만 증가시킨다). 그러나 그 루프는 `verification-runs.jsonl` 과
  시스템 로그에 run id 단위로 이미 전부 남는다(§3.3 이 그 둘만으로 25건을
  짚었다). 카운터를 더 얹는 것은 관측이 아니라 **미래에 Gate 가 될 숫자를
  만드는 일**이다.
- **재제출 arm 의 `intent` 대입 변경** — §1.3. 덮어쓰기가 아니라 부른 문을
  기록하는 것이므로 고칠 결함이 없다.

---

## 5. 성공을 무엇으로 재는가

이 목표의 이전 지표 `rfc_draft_and_governance_consensus` 는 판정에서 거부됐다 —
"측정값이 기록된 파일·명령 출력·URL 등 관측 가능한 대상을 하나도 가리키지 않는
서술형 레이블". 아래는 전부 실행 가능한 명령이며, 현재값은 모두
2026-09-04T08:11Z ~ 08:16Z 에 실측했다.

초안의 기준 1·2 는 폐기했다. 기준 1 은 지정한 파일에 **없는 필드**(`intent`)를
읽으라고 했고 — `grep -c '"intent"' ~/me/.masc/verification-runs.jsonl` → `0`,
레코드 키는 `task_id, producer, authority_kind, authority_actor` /
`outcome, elapsed_s, tools, stage, detail, reason, gate, evaluator_runtime` 뿐이다 —
기준 2 는 오늘 이미 0 이 아니어서 아무 작업 없이 충족된 것으로 읽혔다. 같은 벽에
두 번 걸린 것이다.

| # | 기준 | 측정 명령 | 현재값 | 목표 |
|---|---|---|---|---|
| 1 | 중단 청원 판정이 기록 부재로 죽지 않는다 | `rg -N 'authority deferred' ~/me/.masc/logs/system_log_*.jsonl \| rg -c 'reason=Verification .* not found'` | **25** | 재배포 시각 이후 발생 **0** |
| 2 | 청원 사유가 판정 기록에 쓰인다 | `rg -l 'cancellation_reason' ~/me/.masc/verifications/ \| wc -l` | **0** (전체 1027개) | ≥1 |
| 3 | 중단 청원이 결판난다 | `~/me/.masc/tasks/backlog.json` 에서 `intent=cancel` 로 `awaiting_verification` 인 태스크 | **2** (task-1282, task-1303, 각각 9·14회 판정 실패) | 0 — `cancelled` 또는 `in_progress` 로 결판 |
| 4 | 대시보드 검증 표면이 `intent` 를 읽는다 | `rg -c "\.intent\b\|'intent'" dashboard/src/components/verification/ dashboard/src/api/dashboard-verification-*.ts` | **0** (exit 1) | ≥1, 그리고 대기 목록 행에 완료/중단 구별 표시 |
| 5 | `task_status` 생성자 수가 늘지 않는다 | `lib/types/types_core.ml:242-264` | 6 | 6 |
| 6 | 유령 태스크가 실제로 닫힌다 | `backlog.json` 에서 task-569 · task-650 의 `status` | 2건 `todo` (cycle 3 · 10) | `cancelled` 또는 `done` |
| 7 | 백로그 총계가 아니라 유령이 준다 | `backlog.json` todo 중 `cycle_count ≥ 3` | **22** | 감소. `cycle_count` 없는 503건은 이 지표의 대상이 아니다 |

기준 6 에서 **task-704 를 뺐다.** 초안은 이것을 성공 조건에 넣으면서 §6 에서는
"microVM 게스트 수명 문제는 이 RFC 밖"이라고 선언했다. 두 문장이 동시에 성립할
수 없다. task-704 의 기각문은 `microvm_guest_not_running` 과
`path_outside_sandbox` 를 인용하고 이는 RFC-0406 의 소관이다.

기준 7 에 단서가 붙는 이유: 이슈가 "550+" 를 성공 지표로 쓰면 미착수 503건을
치우는 것이 성공으로 읽힌다. 그건 이 RFC 가 다루는 문제가 아니다.

출처: `backlog.json`(`version=3547`, `last_updated=2026-09-04T08:16:02Z`),
`verification-runs.jsonl`(고유 run 64, 2026-08-31T21:03:13Z ~
2026-09-04T07:41:17Z), `~/me/.masc/logs/system_log_2026-09-0*.jsonl`.

---

## 6. 하지 않는 것

- #32863 의 두 제안 모두 구현하지 않는다. 이슈는 **"이미 해결됨(다른 방식으로),
  잔여는 별건"** 으로 닫는 것을 제안한다.
- 판정 권한 구조를 건드리지 않는다. 키퍼는 판정자가 아니다.
- 트리 읽기 경로와 스냅샷 증거 경로를 다루지 않는다. RFC-0406 · RFC-0407 이
  그 둘을 소유한다. §3.2 의 10/12 는 대부분 그쪽에서 닫힌다.
- microVM 게스트 수명 문제(task-704 의 `microvm_guest_not_running`)를 다루지
  않는다. 별개의 샌드박스 결함이다.
- **`Cancel, Todo` arm(`:112-113`)에 소유자·권한 검사를 붙이는 것은 이 RFC 가
  결정하지 않는다.** §2.3 이 밝힌 대로 그 arm 은 키퍼에게 열려 있다. 다만
  라이브 사용 3건 중 키퍼가 부른 것은 1건이고, 그것은 자기가 8초 전에 만든
  스키마 probe 다:

  ```
  task-1295  created_by=rondo  created_at=2026-09-03T18:12:06Z
             cancelled_by=rondo cancelled_at=2026-09-03T18:12:14Z
             reason="schema probe task canceled immediately"
  ```

  나머지 2건(task-1210, task-1259)은 `codex-mcp-client`, 즉 운영자 경로다.
  초안은 task-1295 를 "키퍼가 실제로 쓴 사례"로 인용하면서 probe 라는 사실을
  적지 않았다. **피해 사례는 아직 없다.** 구조적으로 열려 있다는 것은 §2.3 에
  기록했고, 막을지는 소유자가 정한다 — 운영자의 정상 취소 경로가 같은 arm 을
  쓰므로 `same_agent` 를 붙이는 것은 답이 아니고, 키퍼 호출만 청원 경로로
  보내는 것이 후보다.

---

## 7. 미해결

1. **재배포가 되었는지 확정하지 못했다.** #33046/#33059/#33080 은 04:04Z /
   04:54Z / 06:27Z 에 병합됐는데, **07:41:17Z 재등록 두 건이 여전히 기록을
   남기지 못했다.** 초안은 "라이브가 낡은 빌드일 가능성이 높다"고만 적었다.
   방증은 `~/me/.masc/logs/system_log_2026-09-04.jsonl` 의
   `tool asset sync failed: … Embedded but unlisted: keeper_task_cancel` 이
   05:56:07Z 까지 반복되고 #33081(06:28:47Z)이 그것을 닫은 것이다. 그러나
   07:41Z 실패는 #33081 보다도 뒤다. **재배포 시각을 확인한 뒤 §5 기준 1·2·3 을
   다시 재야 한다.** 이 RFC 는 로컬 빌드를 돌리지 않았으므로 그 이상은 말하지
   않는다.
2. **#32569 가 아직 OPEN 이다.** 인용된 두 실패 문자열은 트리에서 사라졌는데
   이슈는 닫히지 않았다. RFC-0406 · RFC-0407 이 그 질문을 소유하므로 이슈
   정리는 그쪽에 붙는다.
3. **승인된 중단의 종결 사유는 누구 것이어야 하나.** `Verdict_approved` +
   `Cancel_task` 는 `cancelled_status ~reason:notes` 를 부르고(`:270`), 이
   `notes` 는 판정 호출자가 넘긴 값이다(`decide_verdict ~notes`, `:239`;
   호출부 `workspace_task_transitions.ml:823-830`). 즉 청원자가 쓴 문장은
   승인되어도 `Cancelled.reason` 에 도달하지 않고 판정 기록에 남는다. 지금
   같은 필드에 저자가 셋 섞여 있다 — 직접 취소는 호출자, 승인된 청원은 판정자,
   청원자는 없음. **다만 이 경로는 한 번도 실행된 적이 없다**(승인된 중단 청원
   0건, §3.3). 실제로 한 번 돌아본 뒤 판단하는 것이 순서라고 보고, 이 RFC 는
   변경을 제안하지 않는다.
4. **`verification-runs.jsonl` 은 회전한다.** 초안이 쓴 창
   (2026-08-31T20:33:26Z 시작, 65 run)은 재측정 시점에 이미
   2026-08-31T21:03:13Z / 고유 64 run 으로 밀려 있었다. §3.1 의 이전/이후
   비교는 이 창 안에서만 유효하고, 표본이 작아 인과를 말할 수 없다(p ≥ 0.45).
5. **라이브 Task 를 전이하지 않았다.** §5 의 현재값은 전부 스냅샷 읽기다.
   task-569 · task-650 의 상태를 라이브 전이로 확인하지 않았다.
6. **task-371(23회), task-551(17회), task-770(9회)의 답은 이 RFC 밖이다.**
   각각 태스크 분해, 운영자 프로비저닝, 샌드박스 빌드 락이다. 취소 메커니즘이
   무엇이 되든 이 셋은 닫히지 않는다.

---

## 8. 적대 리뷰가 바꾼 것

초안 이후 적대 리뷰 두 건을 받았다. 판정(새 `task_status` 생성자 기각)은
유지되지만, 그 판정을 뒷받침한 근거 여러 개가 틀렸고 아래를 정정했다.

| 초안이 적은 것 | 실측 | 어디 |
|---|---|---|
| §3.3 "조회 결함" | 기록이 쓰이지 않은 것. main 주석이 "the cancel path wrote none" | §3.3 |
| "durable truth 손상 없음" (근거 없이) | 손상은 실재했고, 그것을 닫은 것은 새 상태가 아니라 #33046 의 쓰기 | §2.1 |
| 기각 12건 중 읽기 문제 2건 | **10건**이 읽기·증거 접근 실패를 낀다 | §3.2 |
| 유령 3건 (task-569/563/1303) | 판정문으로 확정되는 것은 **1건**(task-569) | §3.2 |
| "판정이 유일한 장치" | `Cancel, Todo` arm 이 키퍼에게 열려 있다 | §2.3 |
| 이전 열 `39/15/22/0` (합 37) | `38/14/22/0` + `commit_failed` 1 + `not_reviewed` 1 | §3.1 |
| "기각률이 그대로 → 읽기는 원인이 아니다" | p ≥ 0.45. 인과 결론 철회 | §3.1 |
| 65 run | 고유 **64** run (register 66줄, 중복 2 = 중단 청원 재등록) | §3.1 |
| `capability_identity` 가 모델 표면을 정한다 | `keeper_model_projection` 이 정한다 | §1.1 |
| 대시보드 `intent` 매치 0건 | 88줄. 좁힌 명령으로 0 | §4.1 |
| 취소 사유 "12건" | 판별식 없음. 판별식 명시 후 **16건** | §1.3 |
| 성공 기준 1(없는 필드), 2(이미 충족), 3(범위 밖 task-704) | 전부 교체 | §5 |
| task-1295 = "키퍼가 실제로 쓴 사례" | 8초 전 만든 스키마 probe | §6 |
| `intent=Cancel_task` 전이 "한 곳" | 두 곳 (`:119-133`, `:139-150`) | §1.2 |
| 줄 인용 5곳 | `read_backend:226`, `runtime:998-1000`, `types_core:208`/`:233`, `lifecycle:99-104` | 전역 |
| `related: []`, RFC-0402 라벨 미해소 | `related: ["0401","0406","0407"]`, §0.1 추가 | frontmatter |

**반려한 지적 둘.**

1. 리뷰 A 는 "재제출이 intent 를 덮어써 durable truth 가 손상된다"며 이것을
   치명 등급으로 올렸다. 반려한다. `:205` 의 `Complete_task` 대입은 덮어쓰기가
   아니라 **부른 문을 기록하는 것**이다 — 같은 파일에서 `Claimed`(`:168`)·
   `InProgress`(`:181`)에서 오는 제출도 같은 값을 쓰고, 중단 문으로 들어오면
   `:130`·`:147` 이 `Cancel_task` 를 쓴다. task-1303 의 19:11 제출은 키퍼가
   실제로 완료 문을 두드린 사건이고, 앞선 취소 청원도 18:38:16 전이 행에 사유와
   함께 남아 있다. 거짓이 기록된 자리가 없으므로 고칠 결함이 없다. 그 사건의
   원인은 §3.3 — 첫 청원의 판정이 기록 부재로 죽어 키퍼가 다른 문으로 간
   것이다.
2. 리뷰 B 는 §1.1 의 키퍼 이름 귀속이 인용한 명령으로 나오지 않는다고 했다.
   나온다 — `keeper_name` 필드는 네 줄 모두 `"system"` 이지만 이름은 메시지
   본문 접두사(`keeper:edgar.a.poe tool_call …`)에 있다. §1.1 에 그 사실을
   명시했다.
