# keeper 도구 왕복 낭비 재측정 근거 기록 (r2)

## 공통 헤더

- 날짜: 2026-09-02T10:40:00+09:00
- 작성자: claude (vincent 세션)
- 결정 ID: tool-roundtrip-waste-2026-09-02
- 적용 대상: keeper 시스템 프롬프트(기다림 계약), 도구 설명 2건, `lib/tool_bridge.ml`
  실패 렌더, `keeper_tool_memory_runtime.ml` 실패 등급
- 결정 상태: 수정 PR 3건 Draft (#32472, #32476, #32480), 배포 후 재측정 대기

## 근거

| 항목 | 출처 | 확인일시 | 신뢰도 | 제한조건 | Delta |
|---|---|---|---|---|---|
| 연속 동일-인자 재호출 2,468쌍 중 `keeper_time_now` 1,389 | `tool_calls/2026-09/01.jsonl` 17,244행, 아래 집계 | 2026-09-02T09:20+09:00 | High | 같은 keeper 의 직전 호출과 (tool, input) 동일인 쌍만 셈. 턴 경계 무시 | r1 duplicate 292 → 시계 항목 추가로 5배 |
| edgar turn 1166: time_now 327회, 18:45:18Z→19:29:52Z, 실행 id 327, batch 1 | 같은 파일에서 `keeper=edgar.a.poe, keeper_turn_id=1166` 필터 | 2026-09-02 | High | — | 신규 |
| 지시문 "45분마다" | `<base-path>/.masc/config/keepers/edgar.a.poe.toml` `instructions` | 2026-09-02 | High | 런타임 데이터 | 신규 |
| 시각은 매 도구 실행 뒤 주입됨 | `lib/masc_context_injector.mli:39-47` (#32199) | 2026-09-02 | High | — | — |
| 기상 원시연산 완비 | `lib/keeper_runtime/keeper_event_queue.mli:91,250`, `lib/keeper/keeper_unified_prompt.ml:825` "### Scheduled Wake", `config/tools/masc_schedule_create.toml` `defer_loading = true` | 2026-09-02 | High | — | — |
| edgar 가 schedule 212건 생성(daily·cron 예약 중) | `<base-path>/.masc/schedules.json` | 2026-09-02 | High | — | "원시연산을 모른다" 가설 기각 |
| 반복 감지기는 입력+출력 지문 동일 조건 | `lib/keeper/keeper_agent_run.ml:156-216` 정독 | 2026-09-02 | High | — | — |
| 실패 등급 드롭 지점 | `lib/tool_bridge.ml:319-345`, `packages/agent_core/lib/agent/agent_tools.ml:654,660-663`, `llm_provider/types.mli:53-56` | 2026-09-02 | High | — | r1 이 "memory 140건" 으로 남긴 미확인 항목의 원인 |
| memory 실패 분포 | 같은 로그: write 92 (persistence_failed 58, content_too_long 9), search 79 전부 `Failure("…invalid current Memory OS snapshot…")` | 2026-09-02 | High | — | — |
| 묶음률 모델별 전후 | concurrent 호출을 #32327 병합 시각 1788259521 (10:45:21Z) 기준 분리 | 2026-09-02 | Medium | 배포 시각을 확인하지 않아 "후" 구간에 새 문구가 실렸는지는 미확정. codex/gemini 는 CLI 런타임 | 신규 |
| `[C;S;C]` 조각남 21/995 | `planned_index==0` 을 응답 경계로 재구성 | 2026-09-02 | Medium | 응답 경계 재구성이 근사 | 신규 |
| 라이브 표면의 `keeper_time_now` 설명은 TOML 문장 | `curl localhost:8935/api/v1/dashboard/tools?keeper=edgar.a.poe` (콜드 캐시 1회 warming 뒤) | 2026-09-02 | High | — | `keeper_tool_descriptor.ml:1895` 리터럴은 그림자 |
| 09-02 unchanged-recall 0 | `tool_calls/2026-09/02.jsonl` 1,078행 | 2026-09-02T10:30+09:00 | Medium | 부분 하루, tasks_list 23건 | #32322 라이브 확인 |

## 집계 방법 (재현)

```python
# 같은 keeper 의 직전 호출과 (tool, input) 이 같은 tool_call 행을 센다.
import json, collections
rows = [json.loads(l) for l in open("tool_calls/2026-09/01.jsonl")]
rows = [r for r in rows if r.get("record_kind") == "tool_call"]
last, dup, prev_unchanged = {}, collections.Counter(), 0
for r in rows:
    sig = (r["tool"], json.dumps(r.get("input"), sort_keys=True))
    prev = last.get(r["keeper"])
    if prev and prev[0] == sig:
        dup[r["tool"]] += 1
        prev_unchanged += "unchanged" in str(prev[1].get("output"))
    last[r["keeper"]] = (sig, r)
# 실패 뒤 인자변경 재시도: 직전 행이 success=False 이고 같은 tool, 다른 input
# 묶음률: execution_mode=concurrent 행 중 batch_size>=2 비율을 runtime_profile 별로
```

## 검증

- 1차: 위 집계로 09-01 전체를 셈 (09:20 KST).
- 2차: turn 1166 을 실행 id·batch·시각으로 풀어 "한 응답 배치가 아니라 순차 327라운드" 확인.
- 3차: 09-02 부분 하루로 #32322 라이브 확인 (unchanged-recall 0).
- 재현: 위 파이썬을 `<base-path>/.masc` 에서 실행. r1 의 `scripts/measure-tool-roundtrips.py` 는 턴 안 연속 쌍만 세므로 수치가 다르다(그 스크립트의 duplicate 는 292).

## 불확실성

- 미확인: #32472 가 glm-5.3 에 먹히는지. 묶기 문구는 glm-5.3 묶음률을 올리지 못했다(18→4%). 영향: 배포 24h 뒤 time_now 중복이 남으면 얇은 `keeper_wait_until`(Deferred → `Yield Durable_stimulus_waiting`) 을 RFC 와 함께 검토.
- 미확인: 배포 경계. 라이브 프로세스 시작 시각을 재지 않았다. 09-01 "후" 구간의 묶음률은 문구가 실리지 않은 채 잰 값일 수 있다.
- 미확인: `keeper_memory_search` 의 `Failure(...)` 가 어느 dispatcher 경로에서 문자열이 되는지는 정독하지 않았다(증상만 확인). #32480 은 예외를 던지지 않으므로 경로와 무관하게 사라진다.
