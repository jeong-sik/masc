# defer_loading 재생 측정 (2026-11)

항상 요청에 실리는데 거의 필요 없는 도구를 찾고, `defer_loading = true` 로 바꾸면 저장된 요청에서 몇 바이트가 빠지는지 같은 요청에 대고 다시 계산해요.

바이트는 토큰이 아니에요. 제공자 캐시에서 읽힌 몫은 재지 않았어요. 도구 스키마는 본문의 한 부분이라서(아래 "요청 전체에서 차지하는 몫") 이 변경이 요청 크기에 주는 영향은 작아요.

## 다시 돌리는 법

```
docs/evidence/defer-loading-2026-11/measure_defer_replay.py --base-path ~/me \
    --from-date 2026-10-29 --to-date 2026-11-04 \
    --tools BrowserSession,BrowserInstruct,keeper_candle_gift,keeper_candle_equip \
    --json-out docs/evidence/defer-loading-2026-11/result-2026-10-29_11-04.json
python3 -m unittest discover -s docs/evidence/defer-loading-2026-11
```

`--tools` 를 빼면 순위표만 나와요. 도구 이름은 Keeper 가 보는 이름이에요. 파일은 `config/tools/` 에 다른 이름으로 있을 수 있어요(`BrowserSession` 은 `masc_browser_session.toml`).

정의는 스크립트 머리말에 있어요. 줄여 쓰면 이래요.

- 저장된 요청: `keepers/*/provider-inputs` 에 남은, 턴당 하나의 요청. 같은 턴의 다른 요청은 저장되지 않아요.
- 표면: 저장된 요청 하나의 `tool_schemas[].artifact.bytes` 합.
- 필요했던 턴: 도구 호출 원장에서 그 도구를 부른 서로 다른 (`trace_id`, 턴) 쌍. 저장된 요청이 있는 Keeper 의 호출만 세요.
- 비율: (그 도구 스키마를 실은 요청들의 바이트 합) ÷ (필요했던 턴 수 × 표면 중앙값). masc #32062 가 지연을 가르는 기준이에요. 1보다 크면 싣는 쪽이 더 비싸요.
- 재생: 그 도구를 부른 적 없는 Keeper 의 요청에서 스키마를 빼고, 모든 요청에 `keeper_tool_search` 목록에 이름이 한 번 더 적히는 값(이름 길이 + 2)을 더해요.
  - `same-day`: Keeper 가 그날 한 번이라도 불렀으면 그날 요청에는 스키마가 남아요. 추정값이에요.
  - `from-first-call`: Keeper 의 첫 호출부터 기간 끝까지 스키마가 남아요. 하한이에요.

## 결과 (2026-10-29 ~ 11-04)

저장된 요청 5,479개, agent-core Keeper 28명, Keeper-일 106개, 표면 중앙값 91,483 B. 읽지 못한 줄은 0이에요.

| 도구 | 요청당 B | 호출 / 필요했던 턴 | 비율 | 제거 MB (same-day) | 제거 MB (from-first-call) |
|---|---:|---:|---:|---:|---:|
| `BrowserSession` | 4,611 | 44 / 24 | 11.6 | 22.5 | 13.3 |
| `BrowserInstruct` | 998 | 8 / 6 | 10.0 | 5.2 | 4.2 |
| `keeper_candle_gift` | 1,014 | 0 / 0 | - | 5.4 | 5.4 |
| `keeper_candle_equip` | 567 | 2 / 1 | 34.0 | 3.0 | 2.9 |
| 합계 | 7,190 | | | 36.1 (6.85%) | 25.9 (4.91%) |

- 표면 중앙값은 `same-day` 에서 91,483 → 84,380 B, `from-first-call` 에서 91,483 → 87,316 B 예요.
- 요청 합은 526.4 MB 예요.
- 기간을 둘로 나눠도(10-29 ~ 11-01, 11-02 ~ 11-04) 네 도구 모두 비율이 4 이상이거나 필요한 턴이 없어요. `BrowserSession` 9.4 와 24.3, `BrowserInstruct` 7.1 과 15.5, `keeper_candle_equip` 16.2 와 필요한 턴 없음, `keeper_candle_gift` 는 두 기간 모두 호출 없음이에요.

## 요청 전체에서 차지하는 몫

같은 5,479개 요청의 본문(`wire.body_bytes`, 합 11.53 GB)을 부위별로 나눈 값이에요. 메시지 부위는 저장된 크기(`messages[].artifact.bytes`)의 합이에요. 같은 스크립트가 출력하고 결과 JSON 의 `composition` 에 있어요.

| 부위 | 본문 합계 몫 | 요청별 중앙값 |
|---|---:|---:|
| 도구 결과(`messages.tool`) | 34.6% | 34.8% |
| 모델 쪽 메시지(`messages.assistant`) | 24.3% | 35.5% |
| 사용자 메시지(`messages.user`) | 8.0% | 11.5% |
| 시스템 프롬프트 | 5.2% | 10.5% |
| 도구 스키마 | 4.6% | 9.3% |
| 그 밖(`unaccounted`) | 31.2% | 0.0% |

- 도구 스키마는 본문의 4.6%(합계)에서 9.3%(요청별 중앙값)예요. 이 PR 이 빼는 25.9 ~ 36.1 MB 는 본문 합계의 0.22 ~ 0.31% 예요.
- "그 밖"은 부위를 빼고 남은 바이트예요. 이미지가 든 요청 299개(`msx-retro-mania` 263개 포함)가 끌어올리고, 요청별 중앙값은 0이에요.
- 메시지 부위는 요청에 실리는 크기의 상한이에요. 타입이 있는 블록으로 오는 도구 결과(예: `masc_dos_*`)는 저장할 때 블록과 평문 사본(`text_content`)을 함께 쓰는데(`packages/agent_core/lib/base/history.ml` 의 `content_block_to_json`), 요청에는 블록만 실려요(`llm_provider/api_common.ml` 의 `tool_result_wire_fields_with`, `backend_openai_serialize.ml` 의 `tool_result_content_string`). 사본이 얼마인지는 이 스크립트가 재지 않아요.
- 이 스크립트는 메시지 안을 읽지 않아서 도구별로 나누지 못하고, 도구 호출 인자와 모델이 쓴 글도 나누지 못해요. 도구 스키마 몫은 이 영향을 받지 않아요(스키마 항목은 보낸 JSON 의 크기예요).

## 안 바꾼 도구

| 도구 | 비율 (전체 / 앞쪽 / 뒤쪽) | 안 바꾼 이유 |
|---|---|---|
| `keeper_candle_balance`, `keeper_candle_purchase`, `keeper_candle_catalog` | 4.1, 41.1, 15.6 / 2.0, 19.6, 7.4 / 호출 없음 | RFC-goal-candle-ledger §3.7 이 잔액 조회와 구매 도구를 계속 싣기로 했어요. 가격 조회인 catalog 는 구매 흐름의 앞 단계라 같이 둬요. |
| `WebSearch` | 2.7 / 2.2 / 3.3 | 두 기간 모두 4 미만이에요. |
| `keeper_compose_prior-art` | 2.5 / 1.6 / 5.3 | 앞쪽 기간이 4 미만이에요. |
| `keeper_skill` | 1.3 / 1.2 / 2.1 | 목록이 서술에 있어서 지연하면 목록이 가려져요(`test_tool_loading_declarations.ml`, RFC-0411). |
| `masc_goal_measure`, `keeper_tool_search`, `BrowserTabs`, `BrowserGoto` | 0.8, 0.8, 0.7, 0.46 | 1 아래예요. 싣는 쪽이 싸요. |

기준은 "두 기간 모두 비율 4 이상 또는 필요한 턴 없음"이에요. 4 는 이 측정에서 정한 값이에요. 앞서 지연한 `keeper_task_release`(1.7배)보다 엄격해서 지연을 적게 해요.

## 한계

- 저장된 요청은 턴당 하나예요. 한 턴은 요청을 여러 번 보내고(한 턴에서 83번을 잰 적이 있어요), 매 요청이 표면을 싣는데 이 측정은 턴당 하나만 세요. 싣는 비용은 낮게 잡혀요.
- 저장된 요청은 10-29 부터 있어요. 그 앞 날짜의 요청은 비교할 수 없어요.
- 지연된 도구를 부르면 그 턴의 도구 배열이 바뀌어 제공자 캐시 앞부분이 깨져요. 비율의 분모(필요했던 턴 × 표면)가 이 값을 표면 크기로 어림해요. 실제 깨지는 크기는 대화 길이에 따라 달라요.
- `same-day` 는 전날 호출한 긴 대화가 이어서 스키마를 싣는 경우를 놓쳐서 제거량을 크게 잡아요. `from-first-call` 이 그 반대 끝이에요. 실제는 둘 사이예요.
- 지연은 agent-core 레인에만 적용돼요. codex, claude_code 등 다른 레인은 도구 배열 전체를 받아요.

## 배포 뒤에 재는 법

배포한 서버가 요청을 저장하기 시작한 뒤, 같은 길이의 기간에 같은 명령을 `--tools` 없이 돌려요. 표면 중앙값과 네 도구의 `pres%` 가 줄어야 해요. `BrowserSession` 이 `pres%` 100 근처에 그대로 있으면 지연이 적용되지 않은 거예요.
