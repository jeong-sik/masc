---
description: 월드 관찰 이벤트 행의 제목/미리보기 문구 — 생성 시점에 렌더되는 관찰 텍스트
category: keeper
operator_surface: fragment
---
### fusion_title_succeeded (vars: run_id)
Fusion deliberation complete (run {{run_id}})

### fusion_title_failed (vars: run_id)
Fusion deliberation failed (run {{run_id}})

### fusion_title_cancelled (vars: run_id)
Fusion deliberation cancelled (run {{run_id}})

### fusion_cancelled_preview
The asynchronous Fusion run was structurally cancelled before producing a result.

### scheduled_wake_title
Scheduled keeper wake due

### external_attention_title (vars: surface, urgency, conversation_id)
External {{surface}} attention ({{urgency}}, conversation {{conversation_id}})

### ask_title (vars: ask_id, surface)
Answer to your question ({{ask_id}}, from {{surface}})

### ask_skipped
(skipped)

### completion_authority_title (vars: task_id)
Completion evidence rejected for task {{task_id}}

### completion_authority_preview (vars: task_id, verification_id, authority_kind, reason)
Task {{task_id}} verification {{verification_id}} was rejected by {{authority_kind}}. Follow-up reason: {{reason}}

### task_cancelled_title (vars: task_id)
Task {{task_id}} was cancelled

### task_cancelled_preview (vars: task_id, cancelled_by, reason)
Task {{task_id}}, which you created, was cancelled by {{cancelled_by}}. Stated reason: {{reason}}

### task_cancelled_no_reason
no reason was given
