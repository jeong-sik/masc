---
rfc: "0416"
title: 중단 요청은 이미 기록된다 — 새 상태 대신 그 기록을 보여준다
status: Draft
created: 2026-09-04
author: Claude Opus 5
supersedes: []
superseded_by: null
related: []
---

## 0. 한 줄 요약

이슈 #32863 은 키퍼가 태스크를 취소해 달라고 청원할 수 있는 새 상태
`cancel_requested` 를 요구한다. 이 문서는 그 요구를 **기각한다**.

청원 기능 자체는 옳고, 이미 main 에 있다 — 다만 새 생성자가 아니라 기존
`AwaitingVerification` 에 `intent` 필드를 붙이는 방식으로 2026-09-03/04 에
들어왔다(#32960, #32974). 오늘 라이브에서 키퍼 둘이 그 도구를 네 번 불렀고,
이슈가 만들라고 요구한 그 태스크(task-1282) 자신이 지금 그 메커니즘으로 취소
심사를 받고 있다.

이슈가 든 피해 수치("550개 이상의 백로그 오염", "무한 헛바퀴 클레임 루프")는
재현되지 않는다. 그리고 재현되는 만큼의 피해는 durable truth 손상이 아니라
스케줄링 불만이며, masc 규칙이 정면으로 금지하는 종류다.

실제로 남은 결함은 상태가 아니라 두 가지다 — (1) 중단 의도로 올라간 판정이
라이브에서 세 번 다 `infrastructure_unavailable` 로 죽었고, (2) 대시보드가
`intent` 필드를 한 번도 읽지 않아 운영자가 "완료 심사"와 "중단 심사"를 구별하지
못한다. 둘 다 새 상태 없이, 새 Gate 없이 고칠 수 있다.

---

## 1. 문제 — 키퍼가 오늘 기록하지 못하는 것은 무엇인가

### 1.1 이슈의 전제는 2026-09-04 기준 거짓이다

#32863(2026-09-03T12:04:28Z 작성) 본문:

> 현재 MASC 거버넌스에서 키퍼는 태스크 완료(`keeper_task_done`) 또는
> 포기/반납(`keeper_task_release`)만 수행할 수 있으며, 취소
> 전이(`action=cancel`)는 `not_model_invocable`로 차단되어 있습니다.

이슈가 열린 **다섯 시간 뒤** 두 PR 이 그 문장을 지웠다
(`git log origin/main --format='%h %ad %s' --date=iso-strict`):

| PR | 병합(UTC) | 제목 |
|---|---|---|
| #32960 | 2026-09-03T17:13:56Z | `feat(task): a producer submits its stop the way it submits its work` |
| #32974 | 2026-09-03T17:26:06Z | `feat(keeper): a Keeper can ask for a task to be cancelled` |

`keeper_task_cancel` 은 지금 모델이 부를 수 있는 도구다
(`lib/keeper/keeper_tool_descriptor.ml:2181-2189`, `capability_identity`
가 `Internal_name_identity` 이므로 `Operator_only`/`Transport_alias` 와 달리
모델 표면에 실린다). 핸들러는 사유를 필수로 받는다 —
`lib/keeper/keeper_tool_task_runtime.ml:997-999` 의 거부 메시지가 이슈의
사례를 그대로 예시로 든다:

```
reason is required. Say why this task should stop existing rather than move to
someone else. Example: reason='the defect was fixed in #32078; what this task
describes no longer occurs'.
```

`#32078` 은 #32863 이 task-704 를 이미 고쳤다고 지목한 그 PR 이다.

**라이브 호출 실측** (`rg 'tool_call tool=keeper_task_cancel'
~/me/.masc/logs/system_log_2026-09-0*.jsonl`, 4건, 전부 `outcome=ok`):

```
2026-09-03T18:12:15Z  keeper:rondo
2026-09-03T18:38:17Z  keeper:edgar.a.poe
2026-09-03T19:16:43Z  keeper:edgar.a.poe
2026-09-04T02:13:29Z  keeper:edgar.a.poe
```

### 1.2 그리고 그것은 새 상태 없이 만들어졌다

`lib/types/types_core.ml:242-264` 의 `task_status` 는 여전히 여섯 개다 —
`Todo | Claimed | InProgress | AwaitingVerification | Done | Cancelled`.
`CancelRequested` 는 없고, 필요하지도 않았다. 중단 청원은 기존
`AwaitingVerification` 이 `intent` 를 실어서 표현한다
(`types_core.ml:206-241`):

```ocaml
type verification_intent = Complete_task | Cancel_task

type verification_claim =
  | Completion_evidence of { evidence_refs : string list }
  | Cancellation_reason of { reason : string }
```

전이는 `lib/workspace/workspace_task_lifecycle.ml:120-131` 한 곳에서 일어나고,
승인은 `:265-271` 에서 `intent` 를 읽어 종착을 고른다:

```ocaml
| Masc_domain.Verdict_approved ->
  let new_status =
    match intent with
    | Masc_domain.Complete_task -> done_status ~assignee ~now ~notes
    | Masc_domain.Cancel_task ->
      cancelled_status ~agent_name:assignee ~now ~reason:notes
```

`intent` 는 기본값 없이 디코딩되고(`types_core.ml:470`), 와이어로도 나간다
(`types_core.ml:433`).

### 1.3 그래서 오늘 기록되지 못하는 사실은 무엇인가 — 없다

`cancel_requested` 가 담겠다는 네 가지를 하나씩 대보면:

| 담으려던 것 | 오늘 어디에 있나 |
|---|---|
| 누가 중단을 청원했나 | `AwaitingVerification.assignee` |
| 언제 청원했나 | `AwaitingVerification.submitted_at` |
| 왜 | `Cancellation_reason { reason }`, 판정 기록에 join |
| 무엇을 물었나(완료냐 중단이냐) | `AwaitingVerification.intent` |
| 승인 뒤 누가·언제·왜 닫혔나 | `Cancelled { cancelled_by; cancelled_at; reason }` |

`Cancelled.reason` 이 이슈가 말하는 문장을 이미 담고 있다는 것도 실측된다.
라이브 취소 35건 중 "다른 곳에서 이미 고쳐졌다" 부류가 12건 이미 닫혀 있다
(`~/me/.masc/tasks/backlog.json`, `last_updated=2026-09-04T07:19:09Z`,
`version=3541`):

- `task-552` — "main 에 이미 고쳐져 있습니다. 남겨두면 다음 사람이 없는 버그를
  찾게 됩니다."
- `task-723` — "PR #30207 이 08-24 에 이미 해결했습니다. …"
- `task-1210` — "Superseded: the work landed as PR #32367 (a0d072f28c) …"
- `task-565/566/574/614/621/623/633/787/799` — 컴팩션 제거로 대상 소멸(#31582 외)

남는 후보는 "청원과 승인 사이의 대기 자체"뿐이다. 그것은 사실이 아니라
**대기열**이고, 대기열은 durable truth 가 아니다. 그리고 그 대기조차 이미
`AwaitingVerification` 이 표현하고 있다.

### 1.4 측정된 피해 — "550+" 는 재현되지 않는다

`backlog.json` 전수 census(`status` 카운트):

```
총 822건 — todo 577 · done 203 · cancelled 35 · in_progress 5 · awaiting_verification 2
```

`577 ≈ 550+` 는 맞다. 그러나 그것은 **todo 총계**이지 오염 건수가 아니다.
같은 파일에서 `cycle_count`(반납 횟수) 를 갈라보면:

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

"무한 루프"도 성립하지 않는다. 상한은 23회이고, 이슈가 지목한 두 태스크는
이미 멈춰 있다 — task-569 는 2026-09-02T19:16:01Z, task-704 는
2026-09-03T11:51:10Z 이후 재클레임이 없다(각각 backlog 스냅샷 기준 1.5일,
0.8일 정지).

---

## 2. 이 규칙을 먼저 통과해야 한다

`~/me/instructions/projects.md`, MASC autonomy and evidence:

> 새 상태·필드·Gate 는 없을 때 durable truth 가 손상되는 경우에만 추가한다.
> 행동을 유도하거나 강제하는 장치는 기본적으로 추가하지 않는다.

> Interrupted, Ambiguous, acknowledgement, dependency 등 과거 evidence 를
> scheduling Gate 로 사용하지 않는다.

세 갈래로 답한다.

### 2.1 `cancel_requested` 없이 손상되는 durable truth 가 있는가 — 없다

§1.3 의 표가 답이다. 청원자·시각·사유·질문 종류·종결자가 전부 기존 필드에
있다. 새 생성자가 보존할 사실이 남아 있지 않다. 오히려 지금 추가하면 하나의
의무가 두 상태로 쪼개져, `AwaitingVerification{intent=Cancel_task}` 와
`CancelRequested` 가 같은 사실을 두 자리에 적게 된다 — SSOT 손상이지 보강이
아니다.

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

### 2.3 Part 2(조건부 자율 취소)는 규칙 첫 문장의 두 번째 절에 걸린다

#32863 은 "결함 원인이 이미 main 커밋에 있음을 검증 가능한 형태로 제출하거나,
verifier 버그 이슈와 결합된 경우 **자동 취소 승인**"을 제안한다. 이는 행동을
강제하는 장치이자, 생산자가 자기 의무를 스스로 닫는 경로다.

무엇이 그것을 막고 있는가는 코드에 정확히 적혀 있다. 같은 lifecycle 에서
`Done_action` 은 `Claimed`/`InProgress` 에서 **반드시 거부된다**
(`workspace_task_lifecycle.ml:100-104`):

```ocaml
| ( Masc_domain.Done_action
  , ( Masc_domain.Claimed { assignee; _ } | Masc_domain.InProgress { assignee; _ } ) ) ->
  if not (same_agent assignee)
  then Error Invalid_transition
  else Error Verification_submission_required
```

주석(`:114-118`)이 대칭의 이유를 말한다:

> Cancelling outright would give a Keeper one terminal state it can reach alone
> while `Done_action` refuses every lane that is not a submission — "I could not
> do this" would settle itself and "I did this" would not.

**자율 취소를 넣는 순간 "못 했다"는 혼자 확정되고 "했다"는 판정을 받는다.**
그리고 "못 했다"의 판단 근거를 고르는 것도 키퍼 자신이다. 이 비대칭이 열리면
키퍼가 자기 의무를 닫는 데 필요한 것은 "이미 고쳐졌다고 볼 만한 커밋 하나"뿐이
된다. 이를 막는 장치는 오늘 하나뿐이고 — 판정이다.

실측이 이 우려를 뒷받침한다. 판정 창(§3.1) 안 중단 청원 3건 중 1건은
`task-1303` 이고, 그 제출 노트는 키퍼가 스스로 이렇게 적었다:

> 설립 근거였던 "도구 호출 원문이 대시보드에 표시된다"는 항은 코드·실측
> 어디로도 검증 불가한 제 **추정**이었음을 인정
> (`~/me/.masc/logs/system_log_2026-09-03.jsonl`, seq 20630590)

자기 추정으로 세운 태스크를 자기가 닫겠다는 청원이다. 정직한 청원이고 아마
승인되어야 하지만, **정직함은 자율 승인의 근거가 아니다.** 이 판단은 판정자
자리에 있어야 한다.

**결론: Part 2 는 채택하지 않는다.** 근본 처방이 있어서가 아니라, 이것을
안전하게 만드는 장치가 존재하지 않기 때문이다. 안전장치를 만들려면 결국
"자동 승인해도 되는 증거"의 판별기를 새로 세워야 하는데, 그건 판정자를 하나 더
만드는 일이지 판정을 없애는 일이 아니다.

---

## 3. 대안 먼저 — 판정기 수리는 몇 건을 닫는가

`cancel_requested` 를 요구한 두 번째 근거는 "판정 불가"였다 — #32569,
`verifier_exact` 가 microvm 게스트 아티팩트를 못 읽는다는 것. 이게 사실이면
답은 상태 신설이 아니라 **판정기 수리**이고, 그러면 태스크들은 평소의 경로로
닫힌다.

### 3.1 읽기 경로는 이미 고쳐졌고, 실측된다

이슈가 인용한 두 실패 문자열은 트리에 존재하지 않는다:

```
$ rg -n 'microvm_read_requires_turn_sandbox_factory|microvm_read_failed' --type ml lib/
(0 hits, exit 1)
```

`lib/keeper/keeper_sandbox_read_backend.ml:216-223` 이 이제 `Micro_vm` 을
`Attached_guest` 로 보낸다. 수리 이력:

| 커밋 | 병합(UTC) | 내용 |
|---|---|---|
| `cde711a382` (#32641) | 2026-09-02T13:14:24Z | 실행 중 guest 에 attach |
| `3e6bbbee2f` (#32646) | 2026-09-02T14:04:39Z | 남은 거절문 제거 |
| `e8e736629c` (#32933) | 2026-09-03T18:26:09Z | 선언된 microVM 런타임이 부팅에 닿게 |

측정 대상은 `~/me/.masc/verification-runs.jsonl` — 65 run, 창은
2026-08-31T20:33:26Z ~ 2026-09-04T07:15:32Z, 판정자는 전부 `verifier_exact`.
#32641 병합 시각으로 갈랐다:

| | 이전 | 이후 |
|---|---|---|
| run | 39 | 26 |
| approved | 15 | 11 |
| rejected | **22 (56.4%)** | **12 (46.2%)** |
| infrastructure_unavailable | 0 | 3 |

읽기 경로는 고쳐졌는데 **기각률은 56.4% → 46.2%, 거의 그대로다.** 읽기가 막혀
있던 게 기각의 지배적 원인이 아니었다는 뜻이다.

### 3.2 수리 후 기각 12건 — 상태 신설이 닿는 건 0건이다

수리 이후 기각 12건을 전수로 읽었다. 분류 근거는 각 run 의 판정문 원문이며,
run id 로 `verification-runs.jsonl` 에서 다시 열 수 있다.

| 분류 | 건수 | 태스크 |
|---|---|---|
| A. 읽기 경로가 아직 막힘 | 2 | task-1245@13:50(배포 지연분), task-704 |
| B. 읽기는 성공, 요구한 증거를 생산자가 만든 적 없음 | 7 | task-1245@15:29, task-577, task-1250, task-1257, task-1282, task-1311, task-1313 |
| C. 전제가 사라졌거나 타인이 고침(유령) | 3 | task-569, task-563, task-1303 |

A 와 B 의 구별은 판정문이 직접 말한다. task-704(A)는
`microvm_guest_not_running` 과 `path_outside_sandbox` 로 읽기 자체가 실패했다
— "확인 실패는 확인이 아니므로 이 주장들은 미검증"
(`vrf-46ae84e50f8d63829a31d107fe4e5ff7`). 반면 task-1282(B)는 읽기가
성공했고 파일이 없었다 — "부재는 성공한 전체 트리 스캔으로 확정했습니다"
(`vrf-69374a8aab06367ea699dce7122c2783`).

**C 가 `cancel_requested` 의 유일한 모집단이다. 그리고 그 3건에 새 상태가
필요하지 않다는 것을 그중 하나가 이미 증명하고 있다** — task-1303 은
`status=awaiting_verification`, `intent=cancel`,
`verification_id=vrf-3b7e90068d9c42fca3ced7030ad28aa6` 로 지금 청원 중이다
(`backlog.json`). task-569 와 task-563 은 같은 도구를 부르면 된다. 새 상태가
닿는 추가 건수는 **0** 이다.

task-569 의 판정문이 부족했던 것이 무엇이었는지 정확히 말한다
(`vrf-2ce230f0813420954d7cfdc5f1eee760`):

> 제출 노트 자체가 "구조적으로 불이행 불가, 취소가 정답"이라고 진술한 불이행
> 자백 제출물임.

판정자는 "취소가 정답"이라는 주장을 읽고도 `rejected` 말고 낼 게 없었다.
부족했던 것은 상태가 아니라 **질문의 종류**였고, 그 입구는 #32960 이 만들었다.

### 3.3 그래서 진짜 남은 결함 — 청원한 판정이 죽는다

수리 이후 `infrastructure_unavailable` 3건이 새로 생겼다. 세 건 다 사유가
같다:

```
2026-09-03T18:48:29Z  task-1303  vrf-4854621135…  Verification vrf-4854621135… not found
2026-09-04T07:14:22Z  task-1282  vrf-2ddc81ed…    Verification vrf-2ddc81ed… not found
2026-09-04T07:14:22Z  task-1303  vrf-3b7e9006…    Verification vrf-3b7e9006… not found
```

세 건 다 **중단 의도 청원**이다. 판별 방법: 뒤의 두 id 는 `backlog.json` 에서
`intent=cancel` 로 대기 중인 두 태스크의 `verification_id` 와 같고, 첫 id 는
시스템 로그가 이름을 부른다 — "이전 턴에서 `keeper_task_cancel` 을 통해 cancel
청원을 이미 접수했고 verification_id `vrf-4854621135…` 로 대기 중입니다"
(`system_log_2026-09-03.jsonl`, seq 20630590).

창 안에서 판별되는 `intent=cancel` 판정은 3건이고, **3건 다 실패했다.**
청원은 기록되는데 판정자가 그 기록을 못 읽는다. 이건 상태 부재가 아니라 조회 결함이고, durable truth 가
실제로 위태로운 유일한 자리다 — 청원이 영원히 `awaiting_verification` 에 갇히면
그 태스크는 완료도 취소도 불가능해진다.

이미 세 PR 이 이 자리를 두드리고 있다:

| PR | 병합(UTC) | 제목 |
|---|---|---|
| #33046 | 2026-09-04T04:04:42Z | `fix(task): a stop waits on a record the authority can read` |
| #33059 | 2026-09-04T04:54:23Z | `feat(verification): a stop is judged on its reason, not on what it did not build` |
| #33080 | 2026-09-04T06:27:03Z | `fix(verification): the cancellation lookup slot describes tools, it does not order a rejection` |

07:14:22Z 실패 두 건은 셋 다보다 **뒤**다. 다만 그 시각 라이브에서 돌던
바이너리가 이 병합들을 담고 있었는지는 확정하지 못했다 — §7 참조.

---

## 4. 설계 — 살아남은 것

§2 를 통과하지 못한 것은 채택하지 않는다. 남는 것은 **projection 하나**다.

> 가시성은 authority 가 아닌 projection 으로 제공한다.
> (`~/me/instructions/projects.md`)

### 4.1 대시보드가 `intent` 를 읽는다

`intent` 는 이미 서버가 태스크 JSON 으로 내보낸다
(`lib/types/types_core.ml:433`). 대시보드는 그 필드를 **한 번도 읽지 않는다**:

```
$ rg -n 'intent' dashboard/src -g '*.ts' -g '*.tsx'
(도메인 의미의 intent 매치 0건 — 전부 "intentional/intentionally" 주석)
```

결과: 운영자 화면에서 `awaiting_verification` 두 건이 똑같이 보인다. 하나는
"이 일을 끝냈으니 봐 달라"이고 다른 하나는 "이 일이 없어져야 한다"인데
구별되지 않는다. #32863 의 part 1 중 운영자 쪽 절반 — "대시보드에서 검토 후
1-클릭 승인/거절" — 이 실제로 비어 있는 유일한 부분이 여기다.

**누가 전이하나**: 아무도. 이 변경은 전이를 만들지 않는다.
**무엇을 기록하나**: 아무것도. 이미 기록된 필드를 읽기만 한다.
**누가 승인하나**: 오늘과 같다. `POST /api/v1/verification/verdict` 가
`Human_operator { operator_id }` 를 만들어 `commit_verdict_r` 를 부른다
(`lib/server/server_routes_http_routes_verification.ml:118`). 판정 권한은
`Human_operator | System_llm_agent` 둘뿐이고(`types_core.ml:179-181`), 키퍼는
approve/reject 를 문자열 단계에서 거부당한다 — `task_action_of_string` 이
남기는 문구 그대로, "A Keeper is not a verifier."
**운영자가 보는 것**: 대기 목록의 각 행이 완료 심사인지 중단 심사인지, 그리고
중단이면 청원 사유가 무엇인지. 승인 버튼은 이미 있는 것을 쓴다.

새 상태 0, 새 필드 0, 새 Gate 0.

### 4.2 하지 않는 것으로 결정한 것

- **`cancel_requested` 생성자** — §2.1. 기존 필드가 담고 있고, 추가하면 한
  사실이 두 자리에 적힌다.
- **`keeper_task_cancel_request` 도구** — 같은 자리를 `keeper_task_cancel` 이
  이미 차지한다(#32974).
- **조건부 자율 취소** — §2.3. 이걸 안전하게 만드는 장치가 없다.
- **`cycle_count` 임계 기반 클레임 가드** — §2.2. 규칙이 이름 붙여 금지한
  scheduling Gate 다.
- **`Cancel` 에 `cycle_count` 증가시키기** — "청원→기각→재청원" 루프를 세지
  못하는 것은 사실이다(`workspace_task_transition_executor.ml:67-79` 는
  `Release` 에서만 증가시킨다). 그러나 그 루프는 `verification-runs.jsonl` 에
  run id 단위로 이미 전부 남는다(§3.3 이 그 파일만으로 3건을 짚었다). 카운터를
  더 얹는 것은 관측이 아니라 **미래에 Gate 가 될 숫자를 만드는 일**이다.

---

## 5. 성공을 무엇으로 재는가

이 목표의 이전 지표 `rfc_draft_and_governance_consensus` 는 판정에서 거부됐다 —
"측정값이 기록된 파일·명령 출력·URL 등 관측 가능한 대상을 하나도 가리키지 않는
서술형 레이블". 아래는 전부 파일 또는 명령이다.

| # | 기준 | 측정 명령 | 현재값 | 목표 |
|---|---|---|---|---|
| 1 | 중단 청원 판정이 인프라 사유로 죽지 않는다 | `~/me/.masc/verification-runs.jsonl` 에서 `intent=cancel` 태스크의 `complete.outcome` | **0/3 결판** (3건 전부 `infrastructure_unavailable`, §3.3) | 새 청원 5건 연속 `approved` 또는 `rejected` |
| 2 | 대시보드가 `intent` 를 읽는다 | `rg -n "intent" dashboard/src -g '*.ts' -g '*.tsx'` 에서 도메인 매치 | **0** | ≥1, 그리고 대기 목록 행에 완료/중단 구별 표시 |
| 3 | 유령 태스크가 실제로 닫힌다 | `backlog.json` 에서 task-569 · task-704 · task-650 의 `status` | 3건 전부 `todo` | 3건이 `cancelled` 또는 `done` |
| 4 | `task_status` 생성자 수가 늘지 않는다 | `lib/types/types_core.ml:242-264` | 6 | 6 |
| 5 | 백로그 총계가 아니라 유령이 준다 | `backlog.json` todo 중 `cycle_count ≥ 3` | **22** | 감소. `cycle_count` 없는 503건은 이 지표의 대상이 아니다 |

기준 5 에 단서가 붙는 이유: 이슈가 "550+" 를 성공 지표로 쓰면 미착수 503건을
치우는 것이 성공으로 읽힌다. 그건 이 RFC 가 다루는 문제가 아니다.

모든 현재값의 출처는 `backlog.json`(`last_updated=2026-09-04T07:19:09Z`,
`version=3541`)과 `verification-runs.jsonl`(65 run, 2026-08-31T20:33:26Z ~
2026-09-04T07:15:32Z)이다.

---

## 6. 하지 않는 것

- #32863 의 두 제안 모두 구현하지 않는다. 이슈는 **"이미 해결됨(다른 방식으로),
  잔여는 별건"** 으로 닫는 것을 제안한다.
- 판정 권한 구조를 건드리지 않는다. 키퍼는 판정자가 아니다.
- `Cancel, Todo` 즉시취소 arm(`workspace_task_lifecycle.ml:112-113`)에 소유자
  검사를 붙이지 않는다. 이 arm 은 실제로 키퍼가 쓴 적이 있다 — task-1295,
  `cancelled_by=rondo`, `cancelled_at=2026-09-03T18:12:14Z`, 판정 없이
  `todo → cancelled`. 이것이 §2.3 이 말한 비대칭의 유일한 실존 통로지만,
  운영자의 정상 취소 경로이기도 하다. Gate 를 세우기 전에 이 arm 이 실제로
  피해를 낸 사례가 필요하고, 지금은 없다(§7).
- microVM 게스트 수명 문제(task-704 의 `microvm_guest_not_running`)를 다루지
  않는다. 별개의 샌드박스 결함이다.

---

## 7. 미해결

1. **07:14:22Z 실패가 어느 바이너리에서 났는지 확정 못 함.** #33046/#33059/
   #33080 은 모두 그 이전(04:04Z / 04:54Z / 06:27Z)에 병합됐지만, 라이브가 그
   빌드를 싣고 있었는지 확인하지 못했다. 방증은 있다 —
   `~/me/.masc/logs/system_log_2026-09-04.jsonl` 에 05:56:07Z 까지
   `tool asset sync failed: … Embedded but unlisted: keeper_task_cancel` 가
   반복된다. 그 불일치는 #33081(06:28:47Z, `fix(tools): the cancel tool joins
   the manifest`)이 닫았다. 즉 그 시각 라이브는 최신 빌드가 아니었을 가능성이
   높다. **재배포 뒤 §5 기준 1 을 다시 재야 한다.** 이 RFC 는 로컬 빌드를
   돌리지 않았으므로 그 이상은 말하지 않는다.
2. **#32569 가 아직 OPEN 이다.** 인용된 두 실패 문자열은 트리에서 사라졌는데
   이슈는 닫히지 않았다. 이슈 상태가 코드보다 뒤처져 있다.
3. **`verification-runs.jsonl` 은 65 run 상한이 있다.** 창이
   2026-08-31T20:33Z 부터라, #32569 본문의 전 기간 집계는 회전으로 사라졌다.
   §3.1 의 이전/이후 비교는 이 창 안에서만 유효하다.
4. **task-569 / task-704 의 현재 상태를 라이브 전이로 확인하지 않았다.**
   이 RFC 작성 중 라이브 Task 를 생성·취소·전이하지 않았다. §5 기준 3 의
   현재값은 backlog 스냅샷 읽기다.
5. **task-371(23회), task-551(17회), task-770(9회)의 답은 이 RFC 밖이다.**
   각각 태스크 분해, 운영자 프로비저닝, 샌드박스 빌드 락이다. 취소 메커니즘이
   무엇이 되든 이 셋은 닫히지 않는다.
