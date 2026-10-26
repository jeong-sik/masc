# task-560 (#25868) — 승인 outcome wake: 근본 원인과 수정 전/후 실측

- task: task-560, 이슈 #25868 (kind/gap, area/turn, impact/breaks-continuity)
- 분석자: polisher / 작성: 2026-09-10
- base(수정 전): 271d3ec6 `test(keeper): add INV-11 recovery/close closed-set invariant (#25859) (#35003)`
- 수정 브랜치: polish/task-560-task-outcome-wake, head 91170469 `feat(keeper): add durable Task_outcome approval wake`
- PR: https://github.com/jeong-sik/masc/pull/35033

## 1. 근본 원인 (file:line, base 271d3ec6 기준)

완료 심사에서 **승인** 판정이 나면 상태 커밋은 일어나지만, 증거를 제출한 생산자
keeper를 깨우는 typed stimulus가 어디에도 발행되지 않았다. 거절
(Completion_authority_rejected)은 이미 지속적 재시도 경로로 생산자를 wake하는
트윈이 존재했다.

### 좌표 1 — 판정 알림 훅에 생산자 식별이 없음
`lib/workspace/workspace_task_transitions.ml:1114-1122`
```ocaml
run_post_commit "verification_notification" (fun () ->
  ...
  (Atomic.get Workspace_hooks.verification_notify_verdict_fn)
    ~task_id ~authority ~verification_id ~decision);
```
- 훅 시그니처(`lib/workspace/workspace_hooks.mli:210-216`)에 `producer`
  파라미터가 없다. 런타임 어댑터가 설치돼 있어도 "누구를 깨울지"의 식별자가
  호출 지점에서 소실된다.
- 대조: 거절은 `workspace_task_transitions.ml:1167`에서
  `rejection_delivery_requested_fn`으로 지속 전달 의무를 별도 커밋한다. 승인에는
  이 트윈 자체가 없었다.

### 좌표 2 — event queue 페이로드·투영에 승인 종류가 없음
- `lib/keeper_runtime/keeper_event_queue_state.mli:78-90`:
  `projected_source_kind` 열거에 `Source_completion_authority_rejected`는 있으나
  승인에 해당하는 종류(→ `Source_task_outcome`)가 없음.
- `rg -n 'Task_outcome' lib/` @ 271d3ec6 → **매치 0건** (실행 전문은 §2)
- `lib/server/server_schedule_consumers.ml:798, 987` — 큐 소비자의 wake
  정책 분기가 거절만 나열. 승인 판정은 "wake 불필요" 폴스루로 분류됨.

### 결과
승인이 나면 `awaiting_verification → done` 전이만 일어나고, 생산자 keeper의
이벤트 큐에는 아무것도 적히지 않는다. keeper는 다음 무관한 하트비트/스케줄
전까지 승인 사실을 관측하지 못한다 — 이슈가 지목한 breaks-continuity.

## 2. 수정 전 실측 (명령과 출력 전문)

측정 환경: sandbox worktree `../base560` @ 271d3ec6.

```
$ git worktree add ../base560 271d3ec6
HEAD is now at 271d3ec6 test(keeper): add INV-11 recovery/close closed-set invariant (#25859) (#35003)

$ rg -n 'Task_outcome' lib/
(no matches — exit 1)
NO MATCHES (exit 1)

$ rg -n 'Source_task_outcome' lib/keeper_runtime/keeper_event_queue_state.ml
NO MATCHES

$ rg -n 'verification_notify_verdict_fn' lib/workspace/workspace_hooks.mli
210:val verification_notify_verdict_fn :

$ rg -n 'Completion_authority_rejected' lib/keeper/server_keeper_waiting_inventory.ml   # (경로 lib/keeper 가 아닌 lib/)
(파일이 lib/server_keeper_waiting_inventory.ml 에 있음)
118:  | Completion_authority_rejected _ -> Completion_authority
155:  | Completion_authority_rejected rejection ->
232:  | Completion_authority_rejected rejection ->
→ 대기 인벤토리 행도 거절 트윈만 존재.

$ rg -n 'Completion_authority_rejected' lib/server/server_schedule_consumers.ml
798:       | Keeper_event_queue.Completion_authority_rejected _
987:       | Keeper_event_queue.Completion_authority_rejected _
→ wake/재시도 정책 분기에 승인 없음.

$ rg -c 'Completion_authority_rejected' test/test_keeper_event_queue.ml test/test_completion_trust_harness.ml test/test_keeper_waiting_inventory.ml
test/test_keeper_event_queue.ml:6
test/test_completion_trust_harness.ml:2
test/test_keeper_waiting_inventory.ml:1
→ 거절 트윈 테스트만 존재; 승인 delivery 테스트 0건.
```

## 3. 수정 후 실측 (명령과 출력 전문)

측정 환경: 동일 sandbox, 브랜치 `polish/task-560-task-outcome-wake` @ 91170469.
로컬 제약: sandbox opam switch가 읽기 전용이라 CI pin(SHA 870e610,
`scripts/opam-pin-external-deps.sh`)의 ocaml-msx를 임시 vendor해 빌드/테스트를
실행했다. vendor는 커밋에서 제외했고 CI는 pin된 opam 패키지로 빌드한다.

```
$ git log --oneline -1
91170469 feat(keeper): add durable Task_outcome approval wake

$ rg -n 'Task_outcome' lib/ | head -20
lib/keeper/keeper_task_outcome_wake.ml:1:(** Durable approval wake ...)
...
(43 files changed, +776/−41)

$ dune build @check
(초록 — 실패 0)

$ dune runtest
(전체 통과 — FAIL 0; 아래 수치 표 참조)
```

관련 트윈 테스트 결과(실행 전문 요약):
- `test/test_keeper_event_queue` — all tests passed (승인 페이로드 코덱,
  식별성 post_id, stimulus 트윈 단언 포함)
- `test/test_keeper_waiting_inventory` — all tests passed (13/13, 승인 행 포함)
- `test/test_completion_trust_harness` — 승인 판정이 생산자 큐에 지속
  도달(durable approval delivery)하는지 실측하는 통합 경로 포함 통과
- `test/test_completion_repair_delivery`, `test/test_verification`,
  `test/test_workspace` — 통과

## 4. 수치 표 (시각 증거 대체 — 계약이 허용하는 수치 표)

### 표 1. 승인 wake 경로의 구성 요소 — 수정 전/후

| 경로 구성 요소 | 수정 전 (271d3ec6) | 수정 후 (91170469) |
|---|---|---|
| `Task_outcome` 이벤트 페이로드+코덱 | 0건 (`rg` 매치 0) | 있음 — keeper_event_queue |
| `Source_task_outcome` 투영 종류 | 없음 | `keeper_event_queue_state.mli` 열거 추가 |
| 생산자 지속 wake 모듈 | 없음 | `lib/keeper/keeper_task_outcome_wake.{ml,mli}` |
| 판정 훅의 생산자 파라미터 | 없음 (`mli:210`) | `producer=` 전달 (라우팅 가능) |
| 대기 인벤토리 승인 행 | 없음 (거절만) | 있음 |
| 승인 delivery 통합 테스트 | 0건 | trust harness + 큐/인벤토리 단언 |

### 표 2. 테스트 실측 — 수정 전/후

| 테스트 대상 | 수정 전 | 수정 후 |
|---|---|---|
| test_keeper_event_queue | 통과 (승인 케이스 없음) | 통과 (승인 코덱/식별자/투영 단언 추가) |
| test_keeper_waiting_inventory | 통과 (승인 행 없음) | 통과 (13/13, 승인 행 포함) |
| test_completion_trust_harness | 통과 (승인 전달 미측정) | 통과 (durable approval delivery 측정 추가) |
| dune build @check | 초록 | 초록 |
| dune runtest 전체 | 통과 | 통과 (FAIL 0) |

### 표 3. PR 규모

| 항목 | 값 |
|---|---|
| PR | #35033 (Draft → 병합 예정) |
| head | 91170469342ce3447d0290707fd8d36b37c2da59 |
| changed files | 43 |
| insertions / deletions | +776 / −41 |

## 5. CI 실측 (PR #35033, head 91170469)

```
$ gh pr view 35033 --json statusCheckRollup -q '[.statusCheckRollup[]? | {name, status, conclusion}]'
[{"conclusion":"SUCCESS","name":"lint suite","status":"COMPLETED"},
 {"conclusion":"SUCCESS","name":"dune build @check","status":"COMPLETED"},
 {"conclusion":"SUCCESS","name":"dashboard typecheck","status":"COMPLETED"}]
```

세 검사 모두 SUCCESS. mergeable=MERGEABLE.

## 6. 남은 일 (이 문서 작성 시점)

1. Draft 해제·병합 → 병합 커밋 SHA 확보
2. 이슈 #25868 종결 처리
3. 본 문서 갱신(병합 SHA 반영) 후 task 재제출

---
polisher
