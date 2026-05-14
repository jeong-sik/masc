# RFC 0034.d — release_stale_claims agent-side sync

- **Status**: Draft (loop-iter-5, 2026-05-07)
- **Author**: Vincent + Claude (auto-mode loop)
- **Sister RFC**: RFC-0034.v2 (cap-all-callers)
- **Resolves Board Issue**: "Tripartite Coordination Breakdown — task-037 stale claim spam, MASC claim_scope still lists task-037 as claimed" + "Fact 2: nick0cave runtime shows current_task_id=null"

## 1. Motivation

`Coord_task_schedule.release_stale_claims` (lib/coord/coord_task_schedule.ml:761~825) is the only path that auto-recovers stale claims. Currently it mutates *only* the backlog file:

```ocaml
match task.task_status with
| Claimed { ts; ... } when now-ts > ttl ->
    stale_tasks += (id, assignee);
    log_event "stale_claim_released";
    { task with task_status = Todo; worktree = None; }   (* ← only mutation *)
```

It does **NOT** update the assignee's agent file — the assignee's `current_task_id` field still points to the released task. Result: 4-surface mismatch reported by board:

- backlog: `task_status = Todo` ✓
- agent file `current_task_id`: still set to `task-037` ✗
- dashboard cache: stale until TTL expiry ✗ (out-of-scope)
- worktree HEAD: external cleanup (out-of-scope)

`Coord_task.update_local_agent_state config ~agent_name (fun agent -> { agent with current_task_id = None })` 가 이미 존재 — 호출만 추가하면 됨.

## 2. Design

`release_stale_claims` 본문에서 `stale_tasks`에 추가될 때마다 해당 assignee의 agent state도 정리.

```ocaml
(* Before *)
if now_f -. ts > ttl_seconds then begin
  stale_tasks := (task.id, assignee) :: !stale_tasks;
  log_event config (...);
  { task with task_status = Todo; worktree = None }
end else task

(* After *)
if now_f -. ts > ttl_seconds then begin
  stale_tasks := (task.id, assignee) :: !stale_tasks;
  log_event config (...);
  (* RFC-0034.d: clear assignee's current_task_id to keep
     agent state in sync with backlog release *)
  Coord_task.update_local_agent_state config ~agent_name:assignee (fun agent ->
    if agent.current_task_id = Some task.id then
      { agent with current_task_id = None }
    else agent);
  { task with task_status = Todo; worktree = None }
end else task
```

`InProgress` 분기에도 동일 호출 추가.

`Coord_task.update_local_agent_state`는 `if agent.current_task_id = Some task.id` 체크로 *이미 다른 task를 잡은 keeper의 state는 건드리지 않음*. 안전한 idempotent 정정.

## 3. Risks

- `update_local_agent_state`가 `with_file_lock`을 잡음 → release_stale_claims도 backlog file_lock 안에서 호출 중. 다른 file lock 잡음 → potential deadlock?
  - 검증 필요: agent file lock과 backlog lock이 다른 path → 다른 lock identity. 일반적으로 OK.
  - 안전 장치: agent state update가 실패해도 backlog mutation은 이미 성공한 상태. 둘 사이 atomicity는 *이미 부재* (현 시스템도 그러함). RFC는 best-effort sync.

## 4. Tests

`test/test_coord_task_schedule.ml` (or 기존 test)에 추가:
- `test_release_stale_claims_clears_agent_current_task` — task를 keeper A가 claim, ttl 초과 → release_stale_claims → keeper A의 agent file `current_task_id = None`.
- `test_release_stale_claims_preserves_other_agent_task` — 다른 keeper B가 다른 task 작업 중 → release_stale_claims → keeper B의 `current_task_id` 보존.

## 5. Implementation Plan

| 단계 | 산출물 | LOC |
|---|---|---|
| S1 | `release_stale_claims` 본문 두 분기에 호출 추가 | +6 |
| S2 | 회귀 테스트 2건 | +50 |
| S3 | dune build + test green | — |
| S4 | Draft PR | — |

총 ~+56 LOC, 단일 micro-PR.

## 6. Verification

- 기존 stale claim release 테스트 green
- 신규 2건 green
- `Prometheus.metric_keeper_slot_force_released` 등 기존 카운터 변경 없음 (count는 동일, agent state 동기화만 추가)

## 7. References

- iter-4 §2 ("release_stale_claims가 정정 못 하는 surface")
- iter-5 §1 (claim_scope 정체 분석)
- 코드: `lib/coord/coord_task_schedule.ml:761~825`, `lib/coord/coord_task_classify.ml:109` `update_local_agent_state`
