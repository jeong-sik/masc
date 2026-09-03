---
description: Namespace State 섹션 — 제목, backlog 가독성 문구, 카운트 행들
category: keeper
operator_surface: fragment
---
### heading
### Namespace State

### backlog_unreadable
- Task backlog: unavailable or recovery-only; task counts are non-authoritative and cannot drive task actions.

### backlog_empty
- Task backlog: readable; it holds 0 unclaimed tasks, 0 claimable tasks for this keeper, and 0 failed tasks.

### backlog_revision (vars: revision)
- Backlog revision: {{revision}}

### unclaimed (vars: count)
- Unclaimed tasks: {{count}}

### claimable (vars: count)
- Claimable tasks for this keeper: {{count}}

### claimable_more (vars: count)
- ({{count}} more — read them with keeper_tasks_list)

### unclaimed_not_offered (vars: count)
- Unclaimed but not offered to you (awaiting a verdict, or authored by you): {{count}}

### failed (vars: count)
- Failed tasks: {{count}}

### running_fibers (vars: count)
- Running keeper fibers: {{count}}
