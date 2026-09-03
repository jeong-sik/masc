---
description: 관찰 조각 — 현재 과제 상태, 이전 턴 정지 사유, 거부 요약 틀
category: keeper
operator_surface: fragment
---
### current_task_absent (vars: task_id)
### Current Task
- Keeper metadata references {{task_id}}, but that task is absent from the authoritative backlog. Do not infer or invent task details.

### current_task_absent_in_recovery (vars: task_id)
### Current Task
- Keeper metadata references {{task_id}}, but it was not found in the recovery snapshot. The primary backlog is unavailable, so absence is not authoritative.

### current_task_unobservable (vars: task_id)
### Current Task
- Task {{task_id}} could not be observed because the backlog is unavailable. This does not mean the task is absent; preserve its ownership state.

### recovered_current_task
- The primary backlog is unavailable. Do not use this recovery observation as mutation authority.

### previous_turn_stop.repeated_tool_call (vars: tool_name, repeated_count)
- Previous turn: the runtime ended it after `{{tool_name}}` was called {{repeated_count}} times with the same input and returned the same result. That result is already in your history; another identical call returns the same bytes. If you are waiting for it to change, end this turn — the scheduler wakes you again.

### previous_turn_stop.repeated_assistant_text (vars: repeated_count)
- Previous turn: the runtime ended it after you wrote the same message {{repeated_count}} times without a tool call in between.

### rejected_digest_heading
Rejected already — do not repeat these calls unchanged:

### rejected_digest_row (vars: tool, input, count, last_turn, detail_suffix)
- {{tool}} {{input}} ×{{count}} (last turn {{last_turn}}){{detail_suffix}}

