---
description: Scheduled Wake 섹션 — 제목 2종과 행 읽기 규칙 서문
category: keeper
operator_surface: fragment
---
### heading_single
### Scheduled Wake (1 due)

### heading_multi (vars: events, series)
### Scheduled Wake ({{events}} due across {{series}} series)

### intro
Scheduled rows are not Board posts. occurrence_id is correlation metadata only: never pass it to a Board tool. first/last ids are metadata too. Repeated unchanged schedules appear once with occurrence_count. Pass schedule_id to masc_schedule_get; it returns the current durable request and may point to the next recurrence. message is the exact wake message. External effects still cross the Gate.
