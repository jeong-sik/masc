---
rfc: "0365"
title: handoff_context must survive the ownership boundary
status: Draft
author: Claude Opus 5 (1M context)
created: 2026-08-06
supersedes: []
related:
  - RFC-0315 (current-task rendering in the world state)
  - RFC-0351 (memory-first context management) — §2 principle 2 constrains the fix
---

# RFC-0365 — `handoff_context` must survive the ownership boundary

## 0. 한 줄 요약

`handoff_context` 는 모든 전이에서 보존되는데, **정확히 그것이 존재하는 이유인 전이 하나에서만 지워진다** — 다음 소유자의 claim. 재현은 MCP 호출 3 번이다.

## 1. 재현 (2026-08-06, 라이브 서버)

```
masc_transition {agent_name: keeper-rondo-agent,  task_id: task-188, action: claim}
  → task-188 todo → claimed

masc_transition {agent_name: keeper-rondo-agent,  task_id: task-188, action: release,
                 handoff_context: {summary: "HANDOFF-CANARY-K9T2: …",
                                   next_step: "…", evidence_refs: ["note:p1-probe"]}}
  → task-188 claimed → todo
  → backlog.json: handoff_context = {summary: "HANDOFF-CANARY-K9T2: …",
                                     updated_at: "…", updated_by: "admin"}   ✅ 보존

masc_transition {agent_name: keeper-sangsu-agent, task_id: task-188, action: claim}
  → task-188 todo → claimed
  → backlog.json: handoff_context = null                                      ❌ 소거
```

그리고 sangsu 의 실제 world state (`GET /api/v1/keepers/sangsu/config` 의 `assembled_system_prompt`):

```
Current Task rendered : False
Prior handoff present : False
HANDOFF-CANARY-K9T2   : False
```

이전 소유자가 남긴 인수인계는 다음 소유자의 어떤 턴에도 도달하지 않는다.

## 2. 원인 — 죽은 가드 하나와 무조건 교체

### 2.1 가드가 아무것도 가드하지 않는다

```ocaml
(* lib/workspace/workspace_task_transition_executor.ml:14-20 *)
let action_persists_handoff_context = function
  | Masc_domain.Release
  | Masc_domain.Done_action
  | Masc_domain.Submit_for_verification -> true
  | Masc_domain.Claim | Masc_domain.Start | Masc_domain.Cancel -> true
;;
```

**모든 arm 이 `true` 를 반환한다.** 이름과 형태는 정책을 표현하지만, 값은 상수다. 두 그룹으로 나눠 쓴 것이 의도를 드러내면서 동시에 그 의도를 구현하지 않는다.

### 2.2 그래서 필드는 인자로 무조건 교체된다

```ocaml
(* :55-57 *)
; handoff_context =
    (if action_persists_handoff_context action then handoff_context else None)
```

조건이 항상 참이므로 이 줄은 `handoff_context = <인자>` 와 같다. **기존 값은 읽히지 않는다.**

### 2.3 그리고 entry-class 에서 인자는 항상 `None` 이다

```ocaml
(* lib/task/tool_task_args.ml:96-103 *)
match Json_util.assoc_member_opt "handoff_context" args with
| None | Some `Null ->
  (* No handoff_context object provided. For entry-class actions this
     is the expected shape; … We do not fabricate an empty handoff_context here. *)
  Ok None
```

주석이 맞다 — claim 하는 쪽이 인수인계를 지어내면 안 된다. 문제는 그 `None` 이 **저장된 값을 덮어쓴다**는 것이다.

keeper 경로는 인자를 실을 여지조차 없다:

```ocaml
(* lib/keeper/keeper_tool_task_runtime.ml:634-641 *)
Task.Tool.handle_transition ~tool_name:"keeper_auto_start" …
  (`Assoc ["task_id", `String task_id; "action", `String "start"])
```

claim 직후 auto-start 가 같은 경로를 다시 타므로, 설령 claim 이 보존하더라도 start 가 지운다.

## 3. 읽는 쪽은 정상이다 — 이 RFC 의 범위를 좁히는 사실

초기 진단은 "reader 가 안 돈다" 였다. **틀렸다.** 태스크를 하나 주자 즉시 렌더된다 (2026-08-06 실측):

```
### Current Task (held by you)
- task-188 — p2-probe: … [awaiting verification (submitted …)]
- Prior handoff: Claimed task-188 (p2-probe). World state does NOT show a
  Current Task section. Posted one-line board note at p-b8655a19….
```

wire capture 1,047 요청에서 `Current Task` 가 0 회였던 것은 렌더러 결함이 아니라 **그 창 내내 백로그 todo 가 0 이어서 아무도 태스크를 들고 있지 않았기 때문**이다 (8.5 일간 182 태스크 = done 126 + cancelled 56).

즉 `handoff_context` 는 한 소유자 안에서는 살아서 렌더된다. 위 예시의 `Prior handoff` 는 그 keeper 자신의 `Submit_for_verification` 이 쓴 것이다. **소유권 경계에서만 죽는다.**

## 4. 두 불변식이 충돌한다 — 이 RFC 가 고르는 것

### 불변식 A (코드가 구현하는 쪽)
> 인수인계 노트는 *마지막 퇴장 시점의 상태*를 기술한다. 새 소유자가 시작하면 그것은 stale 하다.

### 불변식 B (렌더러와 필드 이름이 약속하는 쪽)
> `Prior handoff` 는 *이전* 소유자의 노트다. 새 소유자가 읽으라고 존재한다.

**B 를 고른다.** 근거:

1. **A 는 표현 가능한 것을 삭제로 처리한다.** `updated_by` 와 `updated_at` 은 이미 모든 레코드에 채워진다 (위 재현에서 `updated_by: "admin"`). staleness 는 *표시*하면 되지 *소거*할 필요가 없다. 렌더 라벨이 이미 "Prior" 다.
2. **A 를 따르면 필드가 무의미해진다.** exit-class 만 쓰고 entry-class 가 지우면, 저장된 값을 읽는 소비자가 구조적으로 존재할 수 없다. `release_counters` (`:35-40`) 는 release 시 handoff 로부터 `reclaim_policy` 를 파생시키므로, 시스템은 이미 이 필드를 의미 있는 상태로 취급한다.
3. **실측이 B 를 요구한다.** 카나리 실험에서 code-reviewer 는 rondo 가 획득한 지식을 필요로 했고, 보드는 124.5 초 늦게 그것을 실어 날랐으며 그 전에 태스크가 기각됐다. 인수인계는 그 지식이 제때 도달할 수 있는 유일한 typed 경로다.

## 5. 변경

```ocaml
let handoff_context_after ~action ~previous ~argument =
  match action with
  (* Exit-class: the closing owner states what it leaves behind. *)
  | Release | Done_action | Submit_for_verification | Cancel -> argument
  (* Entry-class: the incoming owner does not author a handoff, and its
     absent argument must not erase what the previous owner left. *)
  | Claim | Start -> previous
;;
```

- `action_persists_handoff_context` 는 삭제한다. 상수를 반환하는 술어는 정책을 표현하지 않는다.
- `Cancel` 은 exit-class 로 명시한다. 현재 인자를 받는데 (`:57`), 취소 사유를 남기는 것은 정당하다.
- 판단은 action variant 에 대한 exhaustive match 뿐이다 — 점수·문자열 분류·임계값 없음 (RFC-0351 §2 원칙 2).

`.mli` 에 계약을 적는다: **entry-class 전이는 `handoff_context` 를 읽지도 쓰지도 않는다.**

## 6. 열린 질문 — 언제 지워지는가

B 를 고르면 노트의 수명이 문제가 된다. 태스크가 A → B → C 로 돌면 C 는 B 의 노트만 본다 (B 의 exit 가 덮어쓰므로). 그것이 맞다 — "직전 소유자" 가 `Prior handoff` 의 의미다.

다만 B 가 exit 시 인수인계를 **남기지 않으면** (contract 가 요구하지 않는 경우) A 의 노트가 C 까지 흘러간다. `updated_by` 가 A 를 가리키므로 오도하지는 않지만, 이 RFC 는 그것을 허용으로 명시한다: 오래된 노트가 남는 것이 노트가 없는 것보다 낫고, 출처가 붙어 있다.

## 6.5 흐름을 따라간 결과 — 저장만 고치면 오도가 된다

노트가 경계를 넘게 만드는 것만으로는 부족하다. 넘어간 노트를 keeper 가 어떻게 읽는지까지 따라가야 한다.

### 6.5.1 렌더러가 출처를 지운다 (본 RFC 가 함께 고침)

`keeper_unified_prompt.ml:92-101` 는 이렇게만 출력했다:

```
- Prior handoff: <summary>
- Suggested next step: <next_step>
```

`updated_by`, `updated_at`, `evidence_refs` 는 나가지 않는다. 변경 이전에는 무해했다 — claim 이 교차 소유자 노트를 지웠으므로 남는 것은 **그 keeper 자신의 노트**뿐이었다. 본 RFC 가 남의 노트를 모델에게 보내는 순간, 모델은 다른 에이전트의 1 인칭 진술을 **자기 기억으로 읽는다**:

> `- Prior handoff: I already verified the spec; skip the read step.`

이것은 노트가 없는 것보다 나쁘다. 그래서 출처와 증거 참조를 함께 렌더한다:

```
- Prior handoff (keeper-a, 2026-08-05T13:34:46Z): …
- Suggested next step: …
- Handoff evidence: artifact:9f3c…, board:p-c0684d52…
```

출처는 현재 소유자 자신의 노트일 때도 표기한다. 어떤 줄은 붙고 어떤 줄은 안 붙으면 keeper 가 비교할 수 없다. 참조를 함께 내보내는 이유는 `keeper_artifact_read` / `keeper_board_post_get` 가 이미 모델에 노출돼 있어, 주소만 주면 회수가 성립하기 때문이다.

### 6.5.2 검증 증거 폴백 — keeper 경로는 안전, operator 경로는 좁게 열림

`workspace_task_verification.ml:29-41` 은 제출이 handoff 를 싣지 않았을 때 `task.handoff_context` 로 폴백해 그 `evidence_refs` 와 summary 를 **제출 증거로 쓴다**. 변경 이전에는 안전했다 — 그 노트는 제출자 자신의 것일 수밖에 없었다. 이후에는 A 의 증거가 B 의 제출 증거가 될 수 있다.

실제 도달 가능성:

- **keeper 경로는 닫혀 있다.** `keeper_tool_task_runtime.ml:820-829` 의 `keeper_task_done` 은 `handoff_context` 를 **무조건** 합성해 넘긴다 (`summary = result_text`, `evidence_refs` = 그 keeper 가 제출한 것). 폴백의 `None` 갈래에 도달하지 않는다.
- **operator 경로는 열려 있다.** raw `masc_transition {action: submit_for_verification}` 을 handoff 없이 호출하면 폴백이 발화한다.

본 RFC 는 폴백을 바꾸지 않는다. 폴백에 소유자 비교를 넣으려면 제출 에이전트 이름을 검증 경로까지 배선해야 하고, 그것은 완료 권한 경로의 변경이라 별도 근거가 필요하다. 여기서는 **도달 범위를 기록**하고 후속으로 남긴다: 그 폴백은 본래 "제출 증거는 제출에서 온다" 를 어기고 있으며, 본 RFC 는 그 위반을 만들지 않고 관측 가능하게 만들 뿐이다.

### 6.5.3 그 외 소비자

| 소비자 | 변경 후 동작 | 판정 |
|---|---|---|
| `workspace_task_transitions.ml:53` (broadcast) | `persisted_handoff_context` 가 entry-class 에서 `None` — claim 이 물려받은 노트를 자기가 쓴 것처럼 방송하지 않는다 | 의도대로 |
| `keeper_task_cancellation_wake.ml:106` | Cancel 은 exit-class 라 필드가 인자로 대체된다. 사유 없이 취소하면 필드도 비므로 `stated_reason` 은 `None` | 변화 없음 |
| `dashboard_goals_types_timeline.ml:69` | B 가 든 태스크의 timeline 에 A 의 summary 가 표시될 수 있다 | 대시보드 표시. 운영자는 전체 기록을 보므로 허용 |

## 7. 검증

| 지표 | 현재 | 목표 |
|---|---|---|
| release→claim 쌍에서 handoff 생존 | **0%** (§1 재현) | 100% |
| 다른 에이전트가 claim 한 뒤 `Prior handoff` 렌더 | **0** | 렌더됨 |

필수 회귀 테스트:

1. **경계 생존** — release(handoff) → 다른 agent claim → auto-start → 저장된 값이 §1 의 문자열과 동일.
2. **entry 가 쓰지 않음** — claim 에 `handoff_context` 인자를 실어도 저장 값이 바뀌지 않는다.
3. **exit 가 덮어씀** — B 의 release 가 A 의 노트를 교체하고 `updated_by` 가 B 다.
4. **exhaustive** — `action` variant 추가 시 컴파일 실패한다 (catch-all 금지).

실측 근거로 남길 것: 이 RFC 이전 데이터에서 handoff 를 실은 release 64 건 중 61 건이 handoff 없는 start 로 이어졌고 그중 26 건은 다른 에이전트였다 (survey 측정, 본 RFC 가 재검증하지 않음). §1 의 3 단계 재현이 1 차 증거다.

## 8. 비목표

- 새 cross-keeper 채널. 이 RFC 는 **이미 있는 슬롯을 잇는다**.
- keeper 메모리 공유. per-keeper 격리는 RFC-0244 가 sandbox-containment 속성으로 명시 거부했다.
- `keeper_task_done` 스키마에 `handoff_context` 를 추가하는 것 (별건이며, 그것 없이도 §5 는 유효하다).
- 검증자 계약 변경.
