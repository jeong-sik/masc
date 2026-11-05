# 모델 요청이 싣는 컨텍스트 측정 (2026-11)

`measure_request_context.py` 는 Keeper 가 모델에 보낸 요청의 크기와, 그 요청에 실린 도구 스키마·시스템 프롬프트·스킬 목록을 재요.
`.masc` 아래의 네 저장소를 읽기만 해요.

| 저장소 | 쓰는 곳 |
|---|---|
| `keeper_turn_events/<keeper>/<trace_id>-<absolute_turn>-<hash>.jsonl` | 파일 하나가 턴 하나예요. `agent_core_stream_message_delta` 이벤트의 `usage` 가 모델 요청 하나의 토큰 수예요 |
| `keepers/<keeper>/provider-inputs/YYYY-MM/DD.jsonl` | 턴마다 요청 하나를 저장한 기록이에요. `wire.body_bytes` 가 HTTP 본문 크기고 `messages[].media` 가 담긴 이미지예요. `tool_schemas[]` 는 도구마다 스키마 바이트와 blob 참조를, `system_prompt.bytes` 는 시스템 프롬프트 크기를 담아요 |
| `tool_blobs/<sha 앞 두 글자>/<sha>` | 도구 스키마를 저장한 JSON 이에요. blob 참조(`content_ref`)의 `sha256=` 로 찾아요. `keeper_skill` 스키마의 설명 끝에 스킬 목록이 있어요 |
| `tool_calls/YYYY-MM/DD[.NNN].jsonl` | 도구 호출 원장이에요. `tool` 이 `keeper_skill` 인 행을 세요 |

## 다시 재기

```bash
docs/evidence/request-context-2026-11/measure_request_context.py --base-path ~/me \
    --from-date 2026-11-01 --to-date 2026-11-04 --until 2026-11-04T19:10:00Z --json-out after.json
```

이 폴더의 `result-2026-11-01_11-04.json` 이 위 명령의 결과예요. 시험은 `python3 -m unittest discover -s docs/evidence/request-context-2026-11` 로 돌려요.

## 센 방법

- 모델 요청: 창 안(`--from-date` 자정 UTC 부터 `--until` 까지)의 `usage` 이벤트 하나예요. `input_tokens` 는 프롬프트 전체이고 `cache_read_input_tokens`(제공자 캐시에서 읽은 부분)를 포함해요.
- 저장된 요청: provider-inputs 한 줄이에요. 턴마다 하나라서 모델 요청의 일부예요. 턴의 어느 요청을 저장하는지는 확인하지 못했어요.
- 답을 받은 턴: 턴 trace 에 `usage` 이벤트가 하나 이상 있는 턴이에요. 저장된 요청은 (`trace_id`, `absolute_turn`) 으로 그 턴의 trace 파일과 짝지어요.
  - 짝이 되는 trace 가 있고 `usage` 가 없으면 답을 못 받은 요청(`unanswered_requests`)이에요.
  - 짝이 되는 trace 파일이 없으면 가리지 못한 요청(`untraced_requests`)이에요.
- 낡은 이미지: 저장된 요청에서 메시지 순서대로 센 이미지 중 가장 최근 N장(1장과 3장)이 아닌 것이에요. 몫은 낡은 이미지의 base64 크기(바이트 ÷ 3 올림 × 4)를 본문 바이트로 나눈 값이에요. `stale_image_share_keep_latest_N` 은 Keeper 의 모든 요청을 합쳐 나눈 값이고, `stale_image_share_median_keep_latest_N` 은 요청마다 구한 몫의 중앙값이에요. 이미지를 지우는 규칙이 지금은 없어서(이미지를 못 받는 런타임만 빼고) 이 값은 만약의 크기예요.
- 같은 크기 요청: 한 Keeper 의 저장된 요청 중 `body_bytes` 가 같은 것의 최대 개수(`same_size_requests_max`)와 그 크기(`same_size_bytes`)예요. 크기가 같은 개수가 같으면 큰 쪽을 적어요.
- 도구 스키마 바이트: 저장된 요청의 `tool_schemas[].artifact.bytes` 를 더한 값이에요. 도구 하나의 이름·설명·입력 스키마 JSON 이에요. 도구별 합계는 그 도구가 실린 저장된 요청의 바이트를 더한 값이고, 몫은 모든 도구 스키마 바이트에서 그 도구의 합계가 차지하는 비율이에요. 시스템 프롬프트는 `system_prompt.bytes` 예요. 도구 스키마나 시스템 프롬프트가 없는 저장된 요청은 이 값들의 중앙값에서 빼요.
- 스킬 목록: `keeper_skill` 스키마의 설명 끝에 있는 `Available:` 블록이에요. 한 행은 스킬의 identity(JSON 객체 하나), `: `, 스킬 설명이에요. 행의 identity 바이트는 JSON 객체의 크기이고 설명 바이트는 `: ` 뒤부터 다음 행 앞까지의 글이에요. blob 이 없거나 이 모양의 목록이 없으면 읽지 못한 요청(`lists_unreadable`)이에요. 중앙값은 저장된 요청마다 하나씩 센 값이에요.
- 스킬 호출: 창 안의 원장 행 중 `tool` 이 `keeper_skill` 인 행이에요. `keeper_compose_<이름>` 도구는 스키마가 따로 있어서 세지 않아요. 저장된 요청 하나라도 `keeper_skill` 스키마가 실렸으면 그 Keeper 는 목록을 실은 Keeper(`carrying_keepers`)예요.
- 100요청당 호출: `usage` 이벤트가 있는 Keeper 의 호출 수를 전체 모델 요청 수로 나눠 100을 곱한 값이에요. `usage` 이벤트가 하나도 없는 Keeper 의 호출은 빼고 따로 적어요(`calls_by_keepers_without_usage_events`). 한 응답에 호출이 여럿이면 호출 수가 요청 수보다 많을 수 있어서 Keeper 별 값은 100을 넘을 수 있어요.
- 메시지 글이나 이미지 바이트는 읽지 않아요. 크기와 개수만 세요. 스킬 목록은 blob 을 열어 identity 와 설명의 길이를 세고, 글 자체는 결과에 쓰지 않아요.

## 결과(11-01 ~ 11-04T19:10Z)

| | 모델 요청 | 입력 토큰 | 캐시에서 읽은 토큰 | 출력 토큰 | 요청당 평균 입력 토큰 |
|---|---:|---:|---:|---:|---:|
| 전체(Keeper 24명) | 35,684 | 12,739,319,193 | 11,502,869,601 (90.3%) | 23,058,703 | 357,004 |
| `masc-productor-owner` | 7,139 | 2,683,324,101 | 2,417,440,332 | 4,155,701 | 375,868 |
| `msx-retro-mania` | 4,463 | 2,193,578,908 | 1,994,228,174 | 1,266,646 | 491,503 |
| `wkbl-front` | 6,123 | 2,002,137,548 | 1,802,227,708 | 3,480,534 | 326,986 |

저장된 요청 3,217개(Keeper 25명)는 본문 합계 8,784,768,632바이트예요. 중앙값 1,167,137, p99 22,271,153, 최대 118,446,911바이트예요.
답을 못 받은 요청은 131개(본문 합계 2,915,441,193바이트)이고, 가리지 못한 요청은 232개예요.

| | 저장된 요청 | 본문 합계(바이트) | 본문 중앙값 | 본문 p90 | 이미지 중앙값(최대) | 같은 크기 요청 | 답을 못 받은 요청(본문 합계) |
|---|---:|---:|---:|---:|---:|---:|---:|
| `msx-retro-mania` | 255 | 5,347,569,105 | 11,551,143 | 24,392,374 | 113 (1,186) | 14개, 118,446,821 | 37 (2,786,260,898) |
| `masc-productor-owner` | 523 | 648,076,293 | 1,033,779 | 2,605,419 | 0 (0) | 1개 | 1 (691,375) |
| `wkbl-front` | 435 | 552,983,183 | 1,093,387 | 2,508,638 | 0 (8) | 5개, 3,095,522 | 25 (56,033,165) |

`msx-retro-mania` 의 낡은 이미지 몫은 가장 최근 1장만 남길 때 합계 0.820, 요청별 중앙값 0.812이고, 3장을 남길 때 합계 0.812, 중앙값 0.799예요. `wkbl-front` 는 합계 0.028과 0.015, 중앙값 0이에요. JSON 의 `captured_request_bodies.by_keeper`(본문 합계 상위 8명)에서 나머지 여섯은 이미지가 없어서 0이에요.

### 도구 스키마와 시스템 프롬프트

JSON 의 `captured_request_bodies.tool_schemas` 예요. 저장된 요청 3,217개 모두에 도구 스키마가 있어요.

| 요청 하나가 싣는 것 | 중앙값 | 평균 | 최대 |
|---|---:|---:|---:|
| 도구 스키마 합(바이트) | 93,177 | 99,781 | 171,592 |
| 도구 수 | 45 | | 60 |
| 시스템 프롬프트(바이트) | 121,419 | | |

도구 스키마와 시스템 프롬프트가 본문에서 차지하는 몫은 요청별 중앙값이 17.6%예요.

도구별 합계가 큰 열 개예요.

| 도구 | 스키마 중앙값(바이트) | 실린 요청 | 모든 도구 스키마 바이트 중 몫 |
|---|---:|---:|---:|
| `keeper_skill` | 22,093 | 3,213 (99.9%) | 22.5% |
| `BrowserSession` | 4,725 | 3,217 (100%) | 4.7% |
| `BrowserTabs` | 4,423 | 3,217 (100%) | 4.4% |
| `BrowserInteract` | 25,659 | 498 (15.5%) | 3.9% |
| `keeper_tool_search` | 3,629 | 3,217 (100%) | 3.9% |
| `keeper_tasks_list` | 3,185 | 3,217 (100%) | 3.2% |
| `masc_board_post` | 2,914 | 3,217 (100%) | 2.9% |
| `masc_schedule_create` | 5,433 | 1,703 (52.9%) | 2.9% |
| `keeper_memory_search` | 2,755 | 3,217 (100%) | 2.8% |
| `keeper_memory_write` | 3,645 | 2,325 (72.3%) | 2.6% |

### 스킬 목록과 호출

JSON 의 `skill_catalog` 와 `skill_calls` 예요.

| 스킬 목록 | |
|---|---:|
| 목록을 읽은 요청 / 못 읽은 요청 | 3,213 / 0 |
| 서로 다른 목록 | 20 |
| 행 수 중앙값(최대) | 50 (56) |
| `Available:` 블록 중앙값(최대, 바이트) | 19,425 (23,201) |
| 행당 평균 identity / 설명(바이트) | 103 / 287 |
| 블록 중 identity / 설명의 몫 | 26.1% / 73.1% |

블록의 나머지 0.8%는 행마다 붙는 `: ` 와 줄바꿈이에요.

| 스킬 호출 | |
|---|---:|
| `keeper_skill` 호출 | 1,235 (Keeper 27명, 스킬 40종, 스킬 이름이 없는 호출 1) |
| `usage` 이벤트가 없는 Keeper 4명의 호출 | 183 |
| 나머지 1,052호출 ÷ 모델 요청 35,684 | 100요청당 2.95 |
| 목록을 실은 Keeper 23명 중 한 번도 안 부른 Keeper | 0 |

호출이 많은 Keeper 와 스킬이에요.

| Keeper | 호출 | 호출 몫 | 모델 요청 | 100요청당 호출 |
|---|---:|---:|---:|---:|
| `code-reviewer` | 221 | 17.9% | 1,563 | 14.14 |
| `code-reviewer-mother` | 180 | 14.6% | 211 | 85.31 |
| `code-reviewer-brother` | 178 | 14.4% | 179 | 99.44 |
| `you-never-change` | 165 | 13.4% | 0 | |
| `code-reviewer-sister` | 121 | 9.8% | 42 | 288.1 |
| `context-reviewer` | 91 | 7.4% | 1,050 | 8.67 |
| `code-reviewer-uncle` | 86 | 7.0% | 1,054 | 8.16 |
| `msx-retro-mania` | 31 | 2.5% | 4,463 | 0.69 |

위 일곱 Keeper 가 호출의 84.4%를 불렀어요. 많이 열린 스킬은 `masc-pr-adversarial-read` 371(30.0%), `masc-pr-review-grades` 233(18.9%), `masc-guard-approval` 120(9.7%), `verify-before-claiming-done` 67(5.4%), `root-cause-first` 47(3.8%)이에요. 위 셋이 호출의 58.6%예요.

## 읽을 때 주의

- 바이트와 토큰은 달라요. 이미지는 크기(가로·세로)로 토큰을 세는 제공자가 많아서, 이미지가 본문 바이트의 80% 를 차지해도 입력 토큰의 80% 를 차지하지는 않아요. 이 폴더의 값은 이미지 한 장의 토큰 수를 알려주지 않아요. 도구 스키마와 스킬 목록도 바이트예요. 이 목록이 제공자 캐시에서 읽히는 토큰인지 이 스크립트는 가리지 못해요.
- 저장된 요청의 평균은 크기가 같은 요청이 이어진 구간에 끌려가요. `msx-retro-mania` 는 평균 20,970,859바이트인데 중앙값은 11,551,143바이트예요. 11-03 07:17Z ~ 11-04 00:00Z 의 23개 요청은 본문이 118.4 MB 안팎(113.0 MiB)이고 그중 14개는 바이트까지 같아요. 이 요청들의 턴은 모두 답을 못 받았어요.
- "답을 못 받은 요청"은 그 턴의 trace 에 `usage` 가 없다는 뜻이에요. 요청이 실패했는지, 응답 전에 턴이 끝났는지는 이 스크립트가 가리지 못해요. 위 23개 중 한 턴(8350번)의 trace 는 `agent_core_stream_protocol_error`(`sse_stream_incomplete`)와 `event_error` 로 끝났어요. 이 확인은 스크립트가 세는 값이 아니에요.
- trace 파일 이름의 `<absolute_turn>` 과 저장된 요청의 `absolute_turn` 이 같다고 보고 짝지어요. 이름이 이 모양이 아닌 파일은 토큰만 세고 짝에 쓰지 않아요. 가리지 못한 요청 232개 중 102개가 `code-reviewer-father` 예요.
- 도구 스키마와 스킬 목록의 크기는 저장된 요청 3,217개(모델 요청의 9.0%)에서 읽은 값이에요. 서로 다른 목록이 20개라서 목록은 Keeper 와 시점에 따라 달라요.
- 100요청당 호출은 호출 수를 `usage` 이벤트 수로 나눈 값이에요. `code-reviewer-sister` 의 호출(121)이 모델 요청(42)보다 많은 것은 한 응답에 `keeper_skill` 호출이 여럿이라서인지, 이 Keeper 의 `usage` 가 일부 턴에 없어서인지 가리지 못했어요. `you-never-change` 는 trace 파일이 있고 창 안에 `usage` 이벤트가 없어서 비율을 적지 않았어요.
- 한 Keeper 가 목록을 실었다는 판정은 저장된 요청에서 가져와요. 저장된 요청이 없는 Keeper 는 `carrying_keepers` 에 없어요. 호출은 했지만 저장된 요청이 없는 Keeper 가 넷 있고(`keepers_with_calls` 27 대 `carrying_keepers` 23), 이 넷은 `usage` 이벤트도 없는 같은 Keeper 예요(`build-maniac`, `gayo-yoga-leader`, `native-image-guidance-codex-20261101-141032`, `you-never-change`).

## 시험

시험 97개가 통과하고, 계산을 일부러 틀리게 바꾼 변형 153개를 모두 잡았어요. 변형은 복사본에서 `-B -I` 로 `__pycache__` 없이 돌렸어요. 같은 크기의 변형을 이어서 돌리면 파이썬이 앞 변형의 바이트코드를 다시 읽을 수 있어서요. 시험에는 합성한 저장소 네 곳을 두 날짜에 걸쳐 읽는 명령 전체 실행(`MainTest`)이 들어 있어요.
