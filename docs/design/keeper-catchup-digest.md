# Keeper Catch-up Digest (since-last-seen)

운영자가 자리를 비운 사이 특정 keeper에게 무슨 일이 있었는지를, keeper 채팅 진입 시점에 결정론적으로 집계해 보여준다. LLM 요약 없음, 휴리스틱 없음 — 기존 durable 저장소의 since-필터 집계만 수행한다.

발단: 2026-07-02 garnet 재시작-유실 리뷰 중, "지난 방문 이후" catch-up 수단이 1급 기능으로 부재함을 확인 (backlog task-1641).

## Wire contract (v1)

```
GET /api/v1/keepers/:name/digest?since_unix=<float>
```

- `since_unix` (required, unix seconds float): 운영자의 per-keeper last-seen 커서. 누락/비수치이면 400.
- 응답 (`Content-Type: application/json`, 기존 keeper GET subroute 체인과 동일한 public-read 게이트):

```json
{
  "keeper": "garnet",
  "since_unix": 1782976498.87,
  "generated_at_unix": 1783003000.1,
  "chat": { "new_messages": 12, "first_new_ts": 1782976500.2, "transport_failures": 2 },
  "turns": { "completed": 34, "failed": 3, "crashes": 1 },
  "tasks": {
    "claimed": 2, "done": 1, "released": 1, "cancelled": 0,
    "items": [ { "task_id": "task-1635", "transition": "done", "ts": 1782980000.0 } ]
  },
  "board": { "posted": 3, "commented": 11, "voted": 4 },
  "lifecycle": {
    "paused_now": true,
    "pause_events": 1, "resume_events": 0,
    "items": [ { "kind": "operator_pause", "ts": 1782990000.0 } ]
  },
  "read_errors": []
}
```

- 모든 timestamp는 unix seconds float로 정규화한다 (소스는 ISO/unix 혼재 — digest 계층에서 통일).
- `items` 배열은 상수 cap (`digest_items_cap`, 최신순)로 제한하고, 카운트 필드는 cap과 무관한 전체 수를 담는다.
- `read_errors`: 소스 저장소별 읽기 실패를 문자열 목록으로 노출한다 (silent skip 금지, fail-visible).

## Source mapping (전부 기존 저장소)

| 카테고리 | 소스 | 필터 |
|---|---|---|
| chat | `Keeper_chat_store` (`.masc/keeper_chat/<name>.jsonl`, ts append-ordered) | `ts > since`; `Row_kind.Transport_failure`는 별도 카운트 |
| turns.completed | keeper-local `turn-records/YYYY-MM/DD.jsonl` (day-partitioned) | day 파일 >= since 날짜만 open 후 `ts > since` |
| turns.failed | activity-events `keeper.turn_failed` (actor/keeper_name match) | `ts_ms > since*1000` |
| turns.crashes | keeper-local `crash-events/YYYY-MM/DD.jsonl` | `ts > since` |
| tasks | `.masc/audit/YYYY-MM/DD.jsonl` (`event_family:"task_transition"`, agent_id) | `timestamp > since` + keeper identity |
| board | activity-events `board.posted/commented/voted` (actor = author) | `ts_ms > since*1000` + identity |
| lifecycle | `Keeper_transition_audit` durable store (`.masc/transition-audit`, Operator_pause/Operator_resume) + 현재 meta.paused | `ts > since` |

keeper identity 매칭은 `Tool_agent_timeline.identity_matches`의 3-형태 규칙(name / `keeper-<name>-agent` / `keeper:<name>`)을 재사용한다.

## v1에서 뺀 것 (근거와 함께)

- **tool-call 카테고리**: keeper 내부 tool call의 typed per-keeper 로그가 디스크에 없다 (activity-events `tool.called`는 external_mcp 전용; runtime-manifests의 `links.tool_call_log_path`는 전부 null). metrics heartbeat의 `continuity_state.progress` 문자열("Used: ...")을 파싱하는 안은 워크어라운드 시그니처 2(string 분류기)라 기각. 근본 해결 = tool_call_log_path 배선 후 v2에서 추가.
- **LLM 한 줄 요약**: 선택 기능으로도 v1 제외. 결정론 집계가 먼저 자리 잡아야 한다.
- **global feed 기반 turn 카운트**: activity-events `keeper.turn_completed`는 dashboard-chat 주도 턴에서 emission 갭이 실측됨 (garnet 07-02: turn-records엔 턴 존재, feed엔 1건). turn 카운트는 keeper-local 저장소가 진실.

## Dashboard (v1)

- **last-seen 커서**: `localStorage` 키 `masc_keeper_chat_last_seen_v1`, per-keeper `Record<string, number>` (값 = 그 keeper 채팅에서 관측한 최신 entry ts — 벽시계가 아니라 entry ts라 clock skew 무관). `keeper-chat-pending.ts`의 storage wrapper 패턴을 복제 (try/catch, normalize-on-read, `_clear...ForTests`).
- **갱신 시점**: (a) KeeperConversationPanel mount/keeper 전환, (b) ChatTranscript가 bottom-pinned 상태로 스크롤/도착, (c) `visibilitychange`로 다시 보일 때 pinned면.
- **digest 카드**: 커서가 존재하고 fetch 결과에 신규 활동이 있으면 transcript 스크롤러 **바깥**, ChatTranscript 호출부 바로 위에 카드 렌더 (autoscroll effect 불간섭). 카드에는 카테고리별 카운트 + "이후 N개 메시지" + paused 상태.
- **unread divider**: transcript 내부에 `kw-daydiv` 패턴을 복제한 divider를 첫 unread entry 앞에 렌더. anchor entry가 200-cap으로 잘려나간 경우 "가장 오래된 표시 행 위 + 카드가 실제 카운트 담당"으로 폴백. null timestamp entry (live placeholder/checkpoint) 방어.
- **fetch 스택**: 기존 operator digest 스택 패턴 복제 — `fetchKeeperCatchupDigest` (api/keeper.ts) + per-keeper signal + inflight-dedup.

## 테스트

- OCaml: digest 빌더 단위 테스트 — 임시 base_dir에 fixture JSONL을 쓰고 since 경계/카테고리별 집계/read_errors fail-visible/identity 3-형태 매칭을 assert.
- TS(vitest): last-seen 모듈 (hydrate/persist/clear), digest fetch+signal, divider 위치 계산 (null-ts/cap-trim 케이스).

## 유의

- H2 게이트웨이(`MASC_USE_H2`)가 라우트를 수동 미러링하므로 신규 경로의 이중 등록 필요 여부를 확인한다.
- 모든 저장소는 `MASC_JSONL_RETENTION_DAYS`(30d) 프루닝 대상 — since가 보존 창보다 오래되면 카운트는 하한값이며, 응답의 `since_unix` 에코가 그 사실 판정을 클라이언트에 위임한다.
