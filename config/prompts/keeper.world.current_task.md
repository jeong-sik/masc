---
description: Current Task 섹션 — 제목 3종, 상태 문구 6종, task 행, handoff 행과 귀속 4종
category: keeper
operator_surface: fragment
---
### heading.held
Current Task (held by you)

### heading.submitted
Current Task (submitted for verification; it does not hold your claim)

### heading.recovery
Current Task (recovery observation; non-authoritative)

### status.claimed (vars: assignee, claimed_at)
claimed by {{assignee}} at {{claimed_at}}

### status.in_progress (vars: assignee, started_at)
in progress ({{assignee}}) since {{started_at}}

### status.awaiting_verification (vars: submitted_at)
awaiting verification (submitted {{submitted_at}})

### status.todo
todo

### status.done
done

### status.cancelled
cancelled

### row (vars: task_id, title, status)
- {{task_id}} — {{title}} [{{status}}]

### handoff (vars: attribution, summary)
- Prior handoff{{attribution}}: {{summary}}

### handoff_next_step (vars: step)
- Suggested next step: {{step}}

### handoff_evidence (vars: refs)
- Handoff evidence: {{refs}}

### attribution.full (vars: who, at)
({{who}}, {{at}})

### attribution.who (vars: who)
({{who}})

### attribution.at (vars: at)
(unattributed, {{at}})

### attribution.none
(unattributed)
