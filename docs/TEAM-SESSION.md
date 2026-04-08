# Team Session (1h Team Play + Meta Report)

`Team Session`은 장시간(기본 1시간) 에이전트 협업을 하나의 세션으로 묶어 관리합니다.

주의:
- 현재 canonical write entrypoint는 `masc_team_session_step`입니다.
- 과거 문서에 보이던 `masc_team_session_turn` alias는 현재 tool inventory에서 제거되었습니다. plain turn 기록도 `masc_team_session_step(turn_kind="note", ...)`를 사용하세요.

- 세션 시작: `masc_team_session_start`
- 진행 조회: `masc_team_session_status`
- 종료 요청: `masc_team_session_stop`
- 보고서 생성: `masc_team_session_report`
- 세션 목록: `masc_team_session_list`
- 세션 비교: `masc_team_session_compare`
- canonical write entrypoint: `masc_team_session_step`
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
- `operation_id` (optional, managed operation attachment)
- `duration_seconds` (default `3600`)
- `execution_scope` (`observe_only` | `limited_code_change`, default `observe_only`)
- `checkpoint_interval_sec` (default `60`)
- `min_agents` (default `2`)
- `auto_resume` (default `true`)
- `report_formats` (default `markdown,json`)
- `agents` (optional explicit participants)

출력:

- `session_id`
- `operation_id` (if attached)
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
- inference 캐시 메트릭(`inference_cache_metrics`): hits/misses/writes/bypass/errors/hit_rate
- command-plane 링크(`command_plane`): attached operation id/path
- 보고서 경로(`report_paths`)
- linked autoresearch 상태(`linked_autoresearch`, optional): loop_id/status/current_cycle/best_score/last_decision/target_file

### Attached Session Mode

`masc_team_session_start(operation_id="op-...")`를 사용하면 team session이 managed operation에 연결됩니다.

- operation의 `detachment_session_id`가 session id로 갱신됩니다.
- `masc_team_session_status`의 `command_plane.operation_id` / `operation_path`로 연결 상태를 읽을 수 있습니다.
- 이미 다른 session이 연결된 operation에는 새 session을 attach할 수 없습니다.
- `operation_id` 없이 시작한 session은 기존처럼 projected session으로 해석됩니다.

### `masc_team_session_stop`

입력:

- `session_id` (required)
- `reason` (default `manual_stop`)
- `generate_report` (default `true`)

출력:

- stop 요청 수락 상태 또는 최종 상태 JSON

linked autoresearch가 연결된 session이면 stop 응답에 `linked_autoresearch` 요약이 추가되고, raw loop 상태도 함께 `stopped`로 저장됩니다.

### `masc_team_session_report`

입력:

- `session_id` (required)
- `force_regenerate` (default `false`)

출력:

- 요약 프리뷰
- `markdown_path`
- `json_path`

### `masc_team_session_step`

입력:

- `session_id` (required)
- `turn_kind` (`note` | `broadcast` | `portal` | `task` | `checkpoint`)
- `actor` (optional explicit turn actor; default caller)
- `message` (note/broadcast/portal에서 사용)
- `target_agent` (portal에서 사용)
- `delegate_prompt` (existing worker에 후속 턴을 줄 때 사용)
- `task_title`/`task_description`/`task_priority` (task에서 사용)
- `spawn_prompt`/`spawn_role`/`worker_class`/`worker_size` 또는 `spawn_batch`
- `vote_topic`/`vote_options`/`vote_choice`
- `run_task_id`/`run_note`/`run_deliverable`

출력:

- plain turn 기록 시 `turn_no`, `kind`, 액션 결과
- worker spawn 시 `spawn_result`
- vote/run evidence가 있으면 해당 evidence payload

운영 규칙:

- `masc_team_session_step`가 모든 신규 team-session write의 canonical entrypoint입니다.
- note-only logging도 `masc_team_session_step(turn_kind="note", message="...")`를 사용합니다.
- 현재 문서와 예시는 `masc_team_session_step`만 기준으로 유지합니다.

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

`proof.criteria` 필수 게이트(요약):

- `session_started_event`
- `checkpoint_recorded`
- `turn_or_communication_recorded`
- `multi_actor_turn_coverage` (고유 turn actor 수가 `min_agents` 기준 충족)
- `turn_actor_authorized` (turn actor가 세션 참여자/생성자 범위 내)
- `report_artifacts`

위 필수 게이트 중 하나라도 실패하면 `verdict=insufficient_evidence` 입니다.

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

- `schema_version` (`1.0.0`)
- `session`
- `goal`
- `duration`
- `summary`
- `outcomes`
- `agent_metrics`
- `goal_metrics`
- `incidents`
- `mcp_improvements`
- `inference_cache_metrics`
- `evidence`

`proof.json` 핵심 키:

- `schema_version` (`1.0.0`)
- `session_id`
- `verdict`
- `score_pct`
- `criteria`
- `evidence`
- `generated_at_iso`

## 운영 메모

- `start/stop`는 join-required 도구로 동작합니다.
- `status/report/list/compare`는 read-only 도구로 동작합니다.
- `status/stop/report/compare`는 세션 참여자(`created_by` 또는 `agent_names`)만 접근할 수 있습니다.
- `turn/events/prove`도 세션 참여자만 접근할 수 있습니다.
- `list`는 호출자 기준 접근 가능한 세션만 반환합니다.
- 종료 직후에도 `force_regenerate=true`로 보고서를 다시 생성할 수 있습니다.
- `prove`는 보고서가 없을 때 자동 생성 옵션(`generate_report_if_missing`)으로 증명 산출의 일관성을 보장합니다.

## Real Spawn Harness (4-Agent)

실제 `masc_spawn`으로 4개 독립 에이전트를 띄워 팀 세션 멀티턴 증거를 검증합니다.

```bash
scripts/harness_team_session_real_spawn.sh
```

주요 환경 변수:

- `MCP_URL` (default: `http://127.0.0.1:8935/mcp`)
- `SPAWN_RUNTIME_AGENT` (default: `codex`)
- `PARTICIPANTS_CSV` (default: `proof-a,proof-b,proof-c,proof-d`)
- `SESSION_DURATION_SEC` (default: `600`)
- `SPAWN_TIMEOUT_SEC` (default: `240`)
- `GOAL` (세션 목표 문자열)

PASS 기준:

- `team_turn` 이벤트의 고유 actor 수가 참여자 수 이상
- `masc_team_session_prove`의 `verdict=proved`
- `proof.evidence.unique_turn_actors_count >= required_turn_actors`

캐시 검증(선택):

```bash
ASSERT_CACHE_HIT=1 SPAWN_RUNTIME_AGENT=glm scripts/harness_team_session_real_spawn.sh
```
