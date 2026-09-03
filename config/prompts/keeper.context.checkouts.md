---
description: 체크아웃 현황 조각 — row/section 틀과 standing 상태별 문장
category: keeper
operator_surface: fragment
---
### row (vars: path, branch, dirty, standing)
- {{path}}{{branch}}{{dirty}} — {{standing}}

### section (vars: count, rows)
### Repository Checkouts ({{count}})
Where each checkout stands against its upstream default branch.

{{rows}}

### unmeasured (vars: count)
- {{count}} checkout(s) not measurable this turn — the keeper_status tool carries each reason

### standing.current (vars: target)
current with {{target}}

### standing.ahead (vars: target, ahead)
ahead of {{target}} by {{ahead}}

### standing.behind (vars: target, behind)
behind {{target}} by {{behind}}

### standing.diverged (vars: target, behind, ahead)
diverged from {{target}}: behind {{behind}}, ahead {{ahead}}

### standing.unavailable (vars: reason)
freshness unavailable: {{reason}}

