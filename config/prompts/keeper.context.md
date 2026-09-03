---
description: Keeper 턴 컨텍스트 조각 — 체크아웃 현황(checkouts.*)과 승인 권한 안내(approval_authority.*)
category: keeper
operator_surface: fragment
---

### checkouts.row (vars: path, branch, dirty, standing)
- {{path}}{{branch}}{{dirty}} — {{standing}}

### checkouts.section (vars: count, rows)
### Repository Checkouts ({{count}})
Where each checkout stands against its upstream default branch.

{{rows}}

### checkouts.unmeasured (vars: count)
- {{count}} checkout(s) not measurable this turn — the keeper_status tool carries each reason

### checkouts.standing.current (vars: target)
current with {{target}}

### checkouts.standing.ahead (vars: target, ahead)
ahead of {{target}} by {{ahead}}

### checkouts.standing.behind (vars: target, behind)
behind {{target}} by {{behind}}

### checkouts.standing.diverged (vars: target, behind, ahead)
diverged from {{target}}: behind {{behind}}, ahead {{ahead}}

### checkouts.standing.unavailable (vars: reason)
freshness unavailable: {{reason}}

### approval_authority.heading
### Current Approval Authority

### approval_authority.footer
- Gate state does not prove effect application.

### approval_authority.state.complete (vars: revision, pending_count)
- revision={{revision}} state=complete pending_count={{pending_count}}
- Only listed IDs are pending; absent historical IDs are stale.

### approval_authority.state.partial (vars: revision, pending_count, read_error_count)
- revision={{revision}} state=partial known_pending_count={{pending_count}} read_error_count={{read_error_count}}
- Missing IDs are unknown, not resolved; re-read Gate before changing conditional constraints.

### approval_authority.state.unavailable (vars: revision)
- revision={{revision}} state=unavailable
- No pending/resolved inference is valid.
