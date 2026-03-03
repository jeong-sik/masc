# Team Session (1h Team Play + Meta Report)

`Team Session`은 장시간(기본 1시간) 에이전트 협업을 하나의 세션으로 묶어 관리합니다.

- 세션 시작: `masc_team_session_start`
- 진행 조회: `masc_team_session_status`
- 종료 요청: `masc_team_session_stop`
- 보고서 생성: `masc_team_session_report`
- 세션 목록: `masc_team_session_list`
- 세션 비교: `masc_team_session_compare`
- 턴 기록/조작: `masc_team_session_turn`
- 이벤트 타임라인 조회: `masc_team_session_events`
- 증명 산출: `masc_team_session_prove`

핵심 동작:

1. 세션 시작 시 `session.json` 저장 + 이벤트 로그 생성
2. 주기적으로 체크포인트 저장 (`checkpoints/*.json`)
3. 종료 시 Markdown + JSON 보고서 생성
4. 프로세스 재시작 후 `running + auto_resume=true` 세션 자동 재개

## Tool Contracts

### `masc_team_session_start`

입력:

- `goal` (required)
- `duration_seconds` (default `3600`)
- `execution_scope` (`observe_only` | `limited_code_change`, default `observe_only`)
- `checkpoint_interval_sec` (default `60`)
- `min_agents` (default `2`)
- `auto_resume` (default `true`)
- `report_formats` (default `markdown,json`)
- `agents` (optional explicit participants)

출력:

- `session_id`
- `status` (`running`)
- `started_at`
- `planned_end_at`
- `artifacts_dir`

### `masc_team_session_status`

입력: `session_id`

출력:

- 세션 원본 상태(`session`)
- 런타임 상태(`runtime_running`)
- 진행 요약(`summary`): elapsed, remaining, progress, done delta
- 보고서 경로(`report_paths`)

### `masc_team_session_stop`

입력:

- `session_id` (required)
- `reason` (default `manual_stop`)
- `generate_report` (default `true`)

출력:

- stop 요청 수락 상태 또는 최종 상태 JSON

### `masc_team_session_report`

입력:

- `session_id` (required)
- `force_regenerate` (default `false`)

출력:

- 요약 프리뷰
- `markdown_path`
- `json_path`

### `masc_team_session_turn`

입력:

- `session_id` (required)
- `turn_kind` (`note` | `broadcast` | `portal` | `task` | `checkpoint`, default `note`)
- `message` (broadcast/portal/note에서 사용)
- `target_agent` (portal에서 사용)
- `task_title`/`task_description`/`task_priority` (task에서 사용)

출력:

- `turn_no`
- `kind`
- 액션 결과(`result`, `broadcast`, `target_agent` 등)

### `masc_team_session_events`

입력:

- `session_id` (required)
- `event_types` (optional array)
- `after_ts` (optional unix timestamp)
- `limit` (default `200`)

출력:

- `count`
- `events` (필터링된 이벤트 배열)

### `masc_team_session_prove`

입력:

- `session_id` (required)
- `generate_report_if_missing` (default `true`)

출력:

- `proof` (`verdict`, `score_pct`, `criteria`, `evidence`)
- `proof_json_path`
- `proof_md_path`

## Artifact Layout

기본 경로: `.masc/team-sessions/<session_id>/`

- `session.json`
- `events.jsonl`
- `checkpoints/<timestamp>.json`
- `report.md`
- `report.json`
- `proof.md`
- `proof.json`

## Report Structure

`report.md` 고정 섹션:

1. Session Overview
2. Goal vs Outcome
3. Team Activity Timeline
4. Agent Contribution
5. Risks/Failures
6. MCP Improvement Findings
7. Next Actions

`report.json` 핵심 키:

- `session`
- `goal`
- `duration`
- `summary`
- `outcomes`
- `agent_metrics`
- `goal_metrics`
- `incidents`
- `mcp_improvements`
- `evidence`

## 운영 메모

- `start/stop`는 join-required 도구로 동작합니다.
- `status/report/list/compare`는 read-only 도구로 동작합니다.
- `status/stop/report/compare`는 세션 참여자(`created_by` 또는 `agent_names`)만 접근할 수 있습니다.
- `turn/events/prove`도 세션 참여자만 접근할 수 있습니다.
- `list`는 호출자 기준 접근 가능한 세션만 반환합니다.
- 종료 직후에도 `force_regenerate=true`로 보고서를 다시 생성할 수 있습니다.
- `prove`는 보고서가 없을 때 자동 생성 옵션(`generate_report_if_missing`)으로 증명 산출의 일관성을 보장합니다.
