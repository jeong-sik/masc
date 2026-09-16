---
rfc: "0455"
title: "Task 는 모든 상태에서 나갈 수 있어야 한다 — 남은 상태마다 그 상태를 벗어나게 할 행위자가 있다"
status: Draft
created: 2026-09-15
updated: 2026-09-15
author: claude
supersedes: []
superseded_by: null
related: ["0445", "0417", "0416", "0221", "0446", "0361"]
implementation_prs: ["36461", "36500", "36513", "36529", "36552", "36555", "36560", "36567"]
---

# RFC-0455 — Task 는 모든 상태에서 나갈 수 있어야 한다

## 0. 요약

Task 상태 기계는 "이 상태에서 나가게 할 수 있는 사람은 X 뿐" 이라는 규칙을 갖고 있다.
그런데 **X 가 존재하고 움직인다는 보장이 없다.** 그 결과 지금 backlog 에는
빠져나갈 수 없는 Task 가 71건 쌓여 있고, 그중 9건은 하루 12,960줄의 ERROR 를 만든다.

이 RFC 는 하나의 불변식을 둔다.

> 끝나지 않은 Task 상태마다, 그 상태를 벗어나게 할 행위자가 **그 자리에서 확인되는 값**이거나,
> 그 Task 가 **운영자 작업 목록에 투영**된다. 시간으로 닫는 장치(타이머·자동 확정·재시도 상한)는 두지 않는다.

여기서 나오는 변경은 세 가지다. 새 Task 상태를 만들지 않는다.

1. 제출자가 Keeper 인지 여부는 저장하지 않고 **쓰는 자리에서 Keeper 저장소에 물어본다** (RFC-0445 §2.2 U1 수정).
2. 받을 Keeper 가 없다고 전달 단계가 확정하면, 사유를 남기고 Task 를 `Todo` 로 되돌린다.
3. 운영자만 풀 수 있는 Task(포기 청구·주인 없는 점유)는 운영자가 보는 화면에 목록으로 나온다.

어휘는 RFC-0445 의 `next_actor` 합을 그대로 쓴다. 두 번째 어휘를 만들지 않는다.

## 1. 실측 (2026-09-15 05:30 UTC, `<base-path>/.masc`)

### 1.1 나갈 수 없는 Task

| 상태 | 나가는 길 | 그 행위자 | 지금 |
|---|---|---|---|
| `todo` | claim | 아무 에이전트 | 666 |
| `claimed` / `in_progress` | 제출·release·포기 — **담당자 이름과 정확히 같은 행위자만** (`workspace_task_classify.ml:78` `String.equal`) | Keeper 면 있음, MCP 세션이면 없음 | 13, 이 중 **9건이 `codex-mcp-client` 점유** |
| 〃 | 운영자 복구 `masc_operator_task_recovery_resolve` → `todo` | 운영자 | 부를 때만 |
| `awaiting_verification` (완료 제출) | 판정 → `done` / 거절 → `in_progress` | 시스템 LLM 판정자 (오늘 판정 3건, 거절 전달 6건 — 돌고 있다) | 0 |
| `awaiting_verification` (포기 제출) | 운영자 승인 → `cancelled` (RFC-0417) | 운영자 | **62, 가장 오래된 것 11일** |
| `done` / `cancelled` | 끝 | — | 295 / 51 |

포기 청구 62건의 담당 Keeper: goo-yang-bong 36, edgar.a.poe 6, rondo 5, sangsu 3, jazz-developer 3,
polisher 3, code-reviewer 2, analyst 1, lane-smith 1, pr-updater 1, codex-mcp-client 1.

### 1.2 나가지 못한 값이 만든 로그

`codex-mcp-client` 가 제출한 9건이 09-12 03:36 에 전부 거절됐다. 거절은 제출자 Keeper 큐로 전달돼야
하는데 그 이름의 Keeper 가 없다. 전달 코드는 이것을 일시적 실패와 같게 보고 60초마다 다시 시도했다.

| 날짜 | `completion repair remains pending` 줄 수 |
|---|---|
| 09-11 이전 | 0 |
| 09-12 | 10,322 |
| 09-13 | 12,960 |
| 09-14 | 12,807 |
| 09-15 04:46 까지 | 2,511 |

#36461 (병합됨) 이 이 재시도를 끝냈다. 다만 거기서 Task 는 `InProgress` 로 남는다 — 아래 §3.2 가
그 자리를 마저 고친다.

### 1.3 증거는 대부분 안 읽히지만, Task 를 막는 것은 그게 아니다

검증 기록 1,368건에서:

| 항목 | 수 |
|---|---|
| 읽힌 `artifact` 를 가진 기록 | 718 |
| **읽지 못한 참조를 가진 기록** | **757** |
| 증거가 `note` 뿐인 기록 | 220 |

읽지 못한 참조 2,150건의 이유: `missing` 1,477, `invalid_reference` 583, `read_error` 84,
`invalid_utf8` 4, `not_regular_file` 2. **참조 2,150건 전부 상대 경로다.**

**그런데 이것이 Task 를 막는 원인은 아니다.** `verification-runs.jsonl` 의 완료된 판정 129건 중
**128건이 `operator_routed`** — 포기 청구라 리뷰 없이 운영자에게 넘어간 것이고, 실제로 리뷰가 돈 건
1건이다. 그 1건은 lookup 도구를 11번 불렀다: sandbox 검색 2회가 빈손으로 끝나자 Board 글로,
다시 `web_fetch` 로 PR 페이지 · `.diff` · 브랜치의 raw 파일 · 커밋 status · check-runs 까지 읽고
거절했다.

판정자는 sandbox 밖을 읽는다. 참조가 안 열리면 다른 경로로 옮겨 간다. 그러니 위 757건은 판정이
막힌 이유가 아니라, **생산자가 뿌리를 몰라 같은 파일을 여러 경로에 뿌린 낭비**다 — `artifact:`
3,239건 중 적어 낸 경로에서 열리는 것은 1,440건이고, 생산자가 찍어 보는 뿌리는 12가지가 넘는다
(`repos/` 707, `artifacts/` 693, 뿌리 없음 572, `evidence/` 208 …).

Task 가 막히는 이유는 증거가 안 읽혀서가 아니라 **리뷰까지 가지를 못해서다.** 포기 청구 63건 중
46건이 "PR 로 main 에 이미 병합됐다" 는 취지인데 (예: task-361 → PR #30715, task-366 → PR #30633),
그 청구를 판정할 운영자가 움직이지 않는다. §3.3 이 여기를 겨눈다.

사유 자체는 63건 모두 남아 있다. 짧은 것이 131자, 중앙값 442자다. 다만 그 문장이 있는 곳이
Board 글 하나뿐이다 — 검증 기록은 사유 사본을 일부러 두지 않는다
(`verification_protocol.ml:36` "The record keeps no copy of that sentence"). Task 에도, 기록에도
없으니 운영자가 목록에서 볼 수 있는 값이 아니다.

## 2. 원칙

1. **나갈 수 있어야 한다.** 끝나지 않은 상태에는 (a) 그 자리에서 존재가 확인된 행위자가 있거나
   (b) 운영자 작업 목록에 투영이 있다. 둘 다 없으면 그 상태로 들어가는 전이를 설계하지 않는다.
2. **시간이 닫지 않는다.** 타이머·자동 취소·재시도 상한을 두지 않는다 (RFC-0417 §5 계승).
3. **가시성은 투영이다.** 운영자 목록은 기존 사실을 읽어 만든다. 새 상태·새 필드를 만들지 않는다
   (RFC-0416 §2 계승).
4. **행위자 종류는 이름 문자열로 분류하지 않는다.** Keeper 저장소가 답한다.

## 3. 설계

### 3.1 제출자가 Keeper 인지는 쓰는 자리에서 물어본다 — RFC-0445 §2.2 U1 수정

RFC-0445 는 `producer` 를 제출 시점에 `Keeper | Mcp_session` 으로 저장한다고 적었다. 이 RFC 는
**저장하지 않고 그 값을 쓰는 자리에서 계산한다**. 이유 세 가지다.

- 생명주기가 묻는 것은 "지금 이 이름으로 큐를 읽을 Keeper 가 있는가" 다. 제출 뒤 Keeper 가 지워지면
  저장된 값은 거짓이 된다.
- 저장하면 `backlog.json` 의 Task 1,087건에 필드가 생긴다. 이 저장소는 과거 데이터용 reader 를
  만들지 않기로 했으므로(hard cut), 필드 추가는 기존 Task 를 읽지 못하게 만든다.
- 계산은 이미 값으로 있다. #36461 이 `Keeper_producer_route.resolve` 를 만들었다:
  live registry → Keeper meta 파일 존재 순으로 보고 `Keeper of name | No_keeper` 를 돌려주며,
  meta 가 있는데 이 바이너리가 못 읽는 경우는 `Error`("지금은 아님") 로 나눈다.

호출 자리는 둘이다. 거절 전달을 조정하는 `Completion_authority_wakeup.reconcile_pending`(§3.2)과
운영자 목록을 만드는 투영(§3.3)이다. 둘 다 keeper 계층 위에 있어서 Keeper 저장소를 읽을 수 있다.
workspace 계층은 그대로 Keeper 를 모른다. 의존 방향을 지킨다.

RFC-0445 의 다른 결정(`next_actor` 합, `Nobody_will_retry {recipient}`, `Unroutable_producer` 삭제)은
그대로 따른다. 이 RFC 는 그 값을 **어디서 얻는지**만 바꾼다.

### 3.2 받을 Keeper 가 없다고 확정되면 Task 를 `Todo` 로 되돌린다

판정 함수(`decide_verdict`)는 바꾸지 않는다. 거절은 지금처럼 `InProgress { assignee }` 로 되돌리고
전달 의무를 기록한다. 바뀌는 곳은 **전달 단계**다.

전달을 조정하는 `Completion_authority_wakeup.reconcile_pending` 은 §3.1 의 계산으로 세 답 중 하나를
얻는다.

| 계산 결과 | 지금 (#36461) | 이 RFC |
|---|---|---|
| `Keeper name` | 그 Keeper 큐에 넣고 깨운다 | 같다 |
| `Error`(meta 를 못 읽음) | 남겨 두고 다음에 다시 | 같다 |
| `No_keeper` | 의무만 끝낸다. Task 는 `InProgress` 로 남는다 | **의무를 끝내고 Task 를 `Todo` 로 되돌린다** |

되돌림은 이미 있는 `Release` 전이를 쓴다(`workspace_task.ml:112 release_task_r`). Keeper 가 내려갈 때
자기 Task 를 놓는 것과 같은 길이다(`keeper_shutdown_finalize.ml:161`). 거절 사유는 같은 커밋이 쓴
`handoff_context`(`reason`, `evidence_refs = [verification_id]`) 에 그대로 남고, 되돌림은 그 위에
"받을 Keeper 가 없어 놓았다" 는 handoff 를 덧쓴다.

**되돌리는 행위자는 판정을 내린 authority 다.**
`release_task_r ~agent_name` 은 담당자 본인이 놓는 모양이라 사실과 다르다. 그 세션은 이미 없고,
없는 이름으로 기록하면 원장이 "그 에이전트가 스스로 놓았다" 는 거짓을 남긴다. 되돌림은
`workspace_task.ml:recover_owned_task_to_todo_r` 옆에 typed 함수로 두고, 행위자는 자유 문자열이 아니라
의무에 이미 실려 있는 `completion_authority` 에서 읽는다. `Human_operator` 면 `Operator`,
`System_llm_agent` 면 `System` — 판정을 기록할 때 쓰는 대응 그대로다
(`workspace_task_transitions.ml:903`). 원장에 남는 말은 "거절을 내린 쪽이, 돌려줄 사람이 없어 놓았다"
가 된다.

왜 판정이 아니라 전달에서 하는가:

- "받을 Keeper 가 있는가" 는 판정 시점이 아니라 **전달 시점의 사실**이다. 판정과 전달 사이에 Keeper 가
  지워질 수도 있고, 그 경우도 같은 답이 필요하다.
- `commit_verdict_r` 에 인자를 더하면 테스트 호출 자리 23곳(11파일)이 같이 바뀐다. 같은 결과를
  전달 단계 한 곳에서 얻을 수 있으면 그쪽이 맞다.
- 원장에는 사실이 둘로 남는다. "거절되어 제출자에게 돌아갔다", 그리고 "받을 사람이 없어 놓았다".
  두 번째를 첫 번째에 접으면 왜 `Todo` 인지가 사라진다.

승인(`Verdict_approved`) 은 바뀌지 않는다. `Done` 으로 끝나고 알림은 지금처럼 최선 노력이다.

### 3.3 운영자만 풀 수 있는 Task 를 목록으로 만든다

투영 하나를 둔다. 새 상태도, 새 저장도 없다. 파생값이다.

```
task_awaiting_operator =
  | Cancel_claim of { task_id; assignee; submitted_at; reason : string option }
  | Held_without_actor of { task_id; assignee; since }   (* route = No_keeper *)
```

- `Cancel_claim`: `AwaitingVerification { intent = Cancel_task }` 를 읽는다. 지금 62건.
- `Held_without_actor`: `Claimed | InProgress` 중 §3.1 계산이 `No_keeper` 인 것. 지금 9건.

표면:
- TUI — 지금 이 사실을 보여 주는 곳이 **하나도 없다** (`rg 'Cancel_task' bin/` = 0). 운영자가 보는
  화면이므로 여기가 먼저다.
- 웹 verify-queue — 서버는 카드에 `intent`(completion / cancellation)를 싣는데
  (`server_routes_http_routes_verification.ml:100-105`) 목록 컴포넌트가 그 값을 읽지 않는다.
  목록에서 두 종류를 구분한다.
- `masc_dashboard` 의 `Dashboard_attention` — 감지 규칙이 둘뿐이다(멈춘 에이전트, 쉬는 에이전트).
  위 두 생성자를 규칙으로 추가하고, 권하는 행동에 복구 도구 이름을 싣는다.

### 3.4 포기 청구의 사유를 운영자가 읽을 수 있는 자리에 둔다

이 초안은 처음에 "포기 청구에 사유를 요구한다" 를 제안했다. **틀렸다.** 그 요구는 이미 있다.
`transition_task_r` 이 사유 없는 포기 청구를 거절한다(`workspace_task_transitions.ml:360`,
2026-09-04 #33046). 실측해 보니 63건 전부가 사유를 갖고 있다. 앞선 초안의 "26건은 사유가 없다" 는
검증 기록의 `submitted_evidence` 를 센 값이고, 포기 청구의 사유는 거기 쓰이지 않는다.

남는 문제는 요구가 아니라 **자리**다. 사유는 `visibility: unlisted` 인 Board 글 본문 한 줄에만 있다.

- Task 레코드에 없다 — `handoff_context` 는 이 경로에서 안 쓰인다.
- 검증 기록에 없다 — 사본을 두지 않는 것이 명시된 설계다.
- 그래서 `backlog.json` 만 읽는 어떤 화면도 사유를 못 그린다.

§3.3 투영의 `Cancel_claim` 은 사유를 `string option` 으로 들고 있는데, 그 값을 채우려면 Board 글을
찾아 본문에서 잘라내야 한다 — 문자열 파싱이다. 그러지 말고 **제출 시점에 기록이 사유 사본을
갖게 한다.** `Cancellation_reason { reason }` 은 이미 typed 로 전달 단계까지 온다. 기록에 그 필드를
쓰고, 투영은 기록에서 읽는다. Board 글은 지금처럼 남는다 — 사람이 읽는 알림이지 조회 대상이 아니다.

기존 63건은 기록에 사유가 없다. 마이그레이션하지 않는다. 투영은 사유 없는 항목을 `None` 으로
그리고, 운영자는 Board 글을 본다. 새로 들어오는 청구부터 목록에서 읽힌다.

## 3.6 이 설계가 새로 만들 수 있는 막힘

새 규칙은 새 막힘을 만들 수 있다. 확인한 것과 답이다.

**(1) meta 를 못 읽는 Keeper 는 영원히 재시도된다.** §3.1 의 세 번째 답(`Error`)은 지금 "다음에 다시" 이고,
meta 가 계속 안 읽히면 60초마다 ERROR 한 줄이 무한히 나온다 — 이 RFC 가 없애려던 모양 그대로다.
답: 이것도 운영자 몫이다. §3.3 투영에 생성자를 하나 더 둔다.

```
| Producer_record_unreadable of { task_id; producer; detail }
```

RFC-0445 의 `Operator_must_act (Fix_keeper_record)` 와 같은 값이다. 재시도는 그대로 두되, 사람이
그 사실을 본다.

**(2) 되돌리려는데 Task 가 이미 움직였을 수 있다.** 판정과 전달 사이에 같은 이름의 세션이 다시 붙어
제출하면 상태는 `AwaitingVerification` 이다. `Release` 는 그 상태에서 `Invalid_transition` 이라,
그대로 두면 전달 의무가 실패로 남아 매번 재시도된다.
답: 되돌림은 상태를 보고 정한다. `Claimed | InProgress` 이고 담당자가 그 이름일 때만 되돌리고,
그 밖에는 되돌리지 않고 의무만 끝낸다. 새 제출이 이미 답을 대체했기 때문이다.

**(3) `Todo` 로 돌아간 Task 를 누가 집어 이미 끝난 일을 다시 할 수 있다.** 되돌림은 그 Task 를
누구나 집을 수 있게 만든다. 그게 목적이지만, 일이 이미 PR 로 끝난 경우에는 헛일이 된다.
답: 되돌림이 덧쓰는 handoff 에 거절 사유와 verification id 가 남는다. 집는 쪽이 그것을 읽고,
`Todo` 에서의 취소는 누구나 할 수 있으므로 닫는 비용이 낮다. 자동으로 집는 코드는 없다 —
`orchestrator.ml:43` 은 "중요한 todo 가 있는데 활동 중인 에이전트가 없다" 를 알릴 뿐이다.

**(4) 기록에 사유 사본을 두면 SSOT 가 둘이 되는가.** 사유의 출처는 제출 호출 하나다. 기록과 Board
글은 둘 다 그 한 번의 값을 받아 적는 사본이고, 둘 중 어느 쪽도 나중에 고쳐 쓰지 않는다. 지금은
사본이 하나뿐이라 조회가 안 되는 쪽에만 있다.

**(5) 되돌림 자체가 실패하면.** backlog 버전 충돌 같은 일시적 실패는 의무를 남긴다. 다음 회차에
다시 시도한다 — 지금 큐 쓰기 실패와 같은 취급이다.

## 3.7 더 그려 본 경우

| 경우 | 지금이면 | 이 RFC 의 답 |
|---|---|---|
| 의무가 남아 있는데 Task 가 지워졌다 (`task_deletion_receipts`) | 되돌림이 `NotFound` 로 실패 → 매 회차 재시도 | 되돌릴 Task 가 없으면 의무만 끝낸다 |
| 운영자가 먼저 복구해 이미 `Todo` | `Release` 가 `Invalid_transition` | 되돌림은 `Claimed`/`InProgress` 이고 담당자가 그 이름일 때만. 그 밖에는 의무만 끝낸다 |
| 되돌림은 됐는데 ack 전에 죽었다 | 다음 회차에 같은 일을 다시 | 위 규칙이 그대로 적용돼 두 번째는 의무만 끝낸다. 멱등하다 |
| 같은 Task 가 두 번 거절돼 의무가 둘 | 둘 다 재시도 | 첫 번째가 `Todo` 로 돌리고, 두 번째는 의무만 끝낸다 |
| 나중에 같은 이름의 Keeper 가 생긴다 | — | 그때부터 route 는 `Keeper` 다. 이미 되돌아간 Task 는 `Todo` 로 남고, 그 Keeper 가 집으면 된다 |
| 살아 있는 Keeper 를 `No_keeper` 로 잘못 보는가 | — | 확인되지 않았다. Keeper 는 `meta.name` 으로 claim 하고(`keeper_tool_shared_runtime.ml:284`), route 도 같은 이름의 meta 경로를 본다 |
| 전달에 성공한 직후 그 Keeper 가 지워진다 | 큐의 stimulus 를 아무도 읽지 않는다 | Keeper 삭제 경로가 자기 Task 를 `Release` 하므로 Task 는 살아난다. 잃는 것은 알림 한 건이고 사유는 Task 에 남아 있다 |
| RFC-0446(계약 없는 제출 거절, Draft)이 들어온다 | 판정이 그 제출을 건너뛰어 `AwaitingVerification` 에 남는다 | 같은 투영이 필요하다. 그 Task 의 다음 행위자는 제출자이고, 제출자가 없으면 운영자다. 지금은 미구현이라 해당 Task 0건 |
| 운영자 목록이 71건처럼 길다 | — | 표면은 개수와 상위 몇 건을 그린다. 목록 자체는 도구로 본다 |

## 4. 하지 않는 것

- 타이머, 자동 취소, 재시도 상한, "N일 지나면 회수".
- 새 Task 상태. `Todo`·`Claimed`·`InProgress`·`AwaitingVerification`·`Done`·`Cancelled` 그대로다.
- 이름 문자열로 Keeper 인지 판별하기 (`"codex-" 로 시작하면 …` 같은 것).
- 기존 71건을 코드로 옮기기. 배포 뒤 운영자가 목록에서 처리한다 (§5 마지막).
- `backlog.json` 스키마 변경.

## 5. 단계

| PR | 내용 | 판정 |
|---|---|---|
| PR-0 (#36461, 병합됨) | Keeper 없는 제출자의 전달 의무를 한 번에 끝냄. `Keeper_producer_route` 도입 | `completion repair remains pending` 새 줄 0 |
| PR-1 (#36500) | §3.2. `reconcile_pending` 의 `No_keeper` 분기가 의무를 끝내고 Task 를 `Todo` 로 되돌린다 + 판정 레인 행위자의 typed 되돌림 | fixture: No_keeper 거절 1건 → Task `todo`, outbox 0, `handoff_context.reason` 유지 |
| PR-2 (#36513) | §3.3 투영 + §3.4 기록의 사유 사본 + 첫 표면(TUI agenda) | fixture: 포기 청구 1 + 주인 없는 점유 1 + 안 읽히는 기록 1 → 세 생성자 exhaustive, 사유가 기록에서 읽힘 |
| PR-3 (#36529) | §3.3 나머지 두 표면 — 웹 verify-queue, `Dashboard_attention` | fixture: 같은 투영을 읽고 두 화면이 같은 개수를 그린다 |
| 운영 | 지금 쌓인 63 + 9건 처리 | 운영자 결정. 코드 없음 |

PR-1 은 PR-0 위에서만 의미가 있다. §3.4 는 §3.3 과 한 PR 로 묶었다 — 기록에 사유를 쓰는 변경은
그걸 읽는 목록과 같이 들어가야 한다. 따로 넣으면 #33218 이 "읽는 쪽이 없다" 며 지웠던 필드를
읽는 쪽 없이 되살리는 셈이 된다.

## 6. 판정 기준

- `Unroutable_producer` 는 남는다. RFC-0445 §3 은 이것을 0 으로 두었지만, 판정 뒤 전달 전에 Keeper 가
  지워지는 경우가 실제로 있다. 이 RFC 에서 그 생성자는 "전달 시점에 받을 사람이 없다" 는 사실이고,
  분기의 동작이 `Todo` 되돌림으로 바뀐다.
- `No_keeper` 제출자의 거절 1건을 만든 뒤: `backlog.json` 에 그 Task 가 `todo`, `handoff_context.reason`
  이 거절 사유, `pending_completion_rejections` 에 항목 0.
- `rg 'Cancel_task' bin/` > 0 (PR-2 뒤). 지금 0.
- 포기 청구의 사유가 검증 기록에서 읽힌다 (PR-3). 지금은 Board 글 본문에만 있다.
- 완료된 판정 중 `operator_routed` 비율이 내려간다. 지금 129건 중 128건이다 (§1.3). 같은 파일로 센다 (§8).
- 어느 단계에서도 새 Task 상태가 늘지 않는다: `task_status` 생성자 6개 유지.

## 7. 반론과 답

- **"거절인데 `Todo` 로 풀면 책임자가 사라진다."** — 지금도 책임자는 없다. `InProgress` 라는 글자만
  남아 있다. `Todo` 는 사실이고, 사유와 verification id 는 Task 에 남는다. 같은 세션이 돌아오면
  다시 claim 하면 된다.
- **"RFC-0445 와 충돌한다."** — §2.2 U1 한 항목만 수정한다. 타입(`next_actor`)·어휘·다른 자리는
  그대로 쓴다. 0445 가 먼저 들어가면 이 RFC 의 PR-1 이 그 위에 U1 을 고친다. 반대 순서면 0445 PR-3 이
  이 RFC 의 계산 결과를 읽는다.
- **"운영자 목록은 또 하나의 게이트다."** — 게이트가 아니다. 아무것도 막지 않고 기존 사실을 읽어
  보여 줄 뿐이다. 승인 권한은 RFC-0417 그대로 운영자에게 있다.
- **"사유 요구는 새 게이트다."** — 요구는 새로 넣지 않는다. 이미 있고 63건 전부가 지키고 있다.
  이 RFC 가 고치는 것은 그 문장이 조회되지 않는 자리에만 있다는 점이다.
- **"변경 증거는 GitHub 의존을 늘린다."** — 이미 keeper 들이 PR 을 만들고 GitHub App broker 가 있다.
  새 자격 증명을 만들지 않는다. 조회 실패는 typed 미열람으로 남아 판정자가 그 사실을 본다.
- **"71건을 코드로 정리하면 빠르다."** — 과거 데이터용 이관 코드를 만들지 않는다는 규칙이 있다.
  출구는 이미 있고, 운영자가 목록에서 누르면 된다. PR-2 가 그 목록을 만든다.

## 8. 근거

- 코드 (main `7c3954cbe1` 기준): `lib/workspace/workspace_task_lifecycle.ml:67-160` (행동별 소유 검사),
  `:224-300` (`decide_verdict`), `lib/workspace/workspace_task_classify.ml:78` (`same_task_actor`),
  `lib/workspace/workspace_task_transitions.ml:910-940` (거절 handoff + 전달 의무),
  `lib/workspace/workspace_task.ml:190-240` (운영자 복구), `lib/completion_authority_wakeup.ml`,
  `lib/keeper/keeper_producer_route.ml` (#36461), `lib/workspace/workspace_verification_store.ml:100-160`
  (증거 형식), `lib/dashboard/dashboard_attention.ml` (감지 규칙 2개),
  `lib/server/server_routes_http_routes_verification.ml:100-123` (카드의 intent),
  `lib/tool/tool_catalog.ml:321` (`masc_operator_task_recovery_resolve`),
  `lib/keeper/keeper_shutdown_finalize.ml:161` (Keeper 는 내려갈 때 자기 Task 를 release 한다).
- 포기 청구의 사유는 `<base-path>/.masc/board_posts.jsonl` 의 `Cancellation requested for task ...` 글에서
  센다. 검증 기록의 `submitted_evidence` 를 세면 안 된다 — 포기 경로는 거기 쓰지 않는다. 이 초안의
  첫 판이 그렇게 세어 "26건 무사유" 라는 틀린 값을 실었다.
- 실측: `<base-path>/.masc/tasks/backlog.json` (2026-09-15 05:30 UTC), `<base-path>/.masc/verifications/vrf-*.json`
  1,368건, `<base-path>/.masc/logs/system_log_2026-09-1{2,3,4,5}.jsonl`,
  `<base-path>/.masc/verification-runs.jsonl` (판정 129건 — 도구 호출은 `complete` 이벤트의
  `completion.tools` 에 있다. `register` 이벤트만 보면 기록이 없는 줄 안다).
- 관련 RFC: RFC-0445(next-actor 합, §2.2 U1 수정 대상), RFC-0417(취소 판정은 운영자),
  RFC-0416(새 상태 없이 보이게 한다), RFC-0221(원자적 검증 제출), RFC-0446(계약 없는 제출 거절),
  RFC-0361(검증 권한 관측).
- 앞선 PR: #36461 (PR-0, 병합됨), #34482 (전달 복구의 원래 구현).
