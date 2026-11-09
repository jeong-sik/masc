# 목록 도구가 행마다 상세를 돌려준 크기 (2026-11-09)

`masc_run_list`와 `masc_goal_list`가 호출마다 돌려준 크기와, 행에서 필드를 덜어 냈을 때의 크기예요.
수리는 PR #50476(`masc_run_list`)과 #50490(`masc_goal_list`)이에요.
16,384 B(`Common.max_tool_result_wire_bytes`)를 넘는 결과는 blob으로 저장되고, 모델은 `[masc:blob sha256=… preview="…"]` 한 줄과 200자 미리보기만 받아요.

## 다시 재는 명령

```
python3 docs/evidence/list-tool-rows-2026-11/measure_list_tool_rows.py calls masc_run_list
python3 docs/evidence/list-tool-rows-2026-11/measure_list_tool_rows.py calls masc_goal_list
python3 docs/evidence/list-tool-rows-2026-11/measure_list_tool_rows.py goal-list
python3 docs/evidence/list-tool-rows-2026-11/measure_list_tool_rows.py run-list
```

`~/me/.masc`의 장부와 blob, `runs/*/run.json`을 읽기만 해요(`--base-path`, `--month`로 바꿔요).
장부 줄이 JSON이 아니면 세어서 알려 줘요. 값은 재는 순간의 기록이라 run이 늘거나 계획이 바뀌면 몇 B씩 움직여요.

## masc_run_list

11월 장부에 8건이 있어요. 호출마다 948,609~958,907 B이고 입력은 전부 `{}`예요.

| 시각(UTC) | Keeper | 바이트 |
|---|---|---|
| 11-01 06:10 | build-maniac | 948,609 |
| 11-01 10:59 | kidsnote-incoming-dd-manager | 948,743 |
| 11-07 02:17 | wkbl-front | 950,539 |
| 11-07 23:15 | wkbl-front | 958,229 |
| 11-08 05:13 | wkbl-front | 957,968 |
| 11-08 09:05 | wkbl-growth | 958,161 |
| 11-08 21:30 | wkbl-front | 958,734 |
| 11-09 01:53 | wkbl-data | 958,907 |

8건 모두 blob이고, 미리보기 200자에는 `count`와 첫 행(`task-1906`)의 앞부분만 있어요. 행은 디렉터리 순서였어요.
blob을 sha 앞 16자로 다시 읽은 호출은 장부에 없어요.

`run-list`로 잰 값(run 787개, 11-09 16:30 KST)이에요.

| 모양 | 바이트 |
|---|---|
| 행 하나 | 평균 139.8, 최대 161 |
| 최근 50개 | 7,256 |
| 최근 100개 | 14,373 |
| 787개 전부 | 110,853 |
| 계획 전문이 든 예전 모양 | 963,059 |

계획 길이는 중앙값 996 B, 최대 7,991 B이고 787개 중 613개가 비어 있지 않아요.
PR #50476의 본문과 코드 주석은 조금 앞서 잰 값(7,255 / 14,372 / 110,852 / 962,022)이에요. 앞의 세 값은 1 B, 옛 모양은 1,037 B 차이예요. 같은 날 06:58Z와 07:05Z에 run 두 개(`task-3268`, `task-3200`)가 갱신됐어요. 그 사이에 값이 움직였을 수 있고, 차이의 원인은 가려내지 않았어요.

## masc_goal_list

11월 장부에 152건, 합 10,513,440 B예요(`calls masc_goal_list`의 입력별 표).

| 입력 | 호출 | 바이트 |
|---|---|---|
| `{}` | 23 | 6,472,038 |
| `{"phase": "executing"}` | 17 | 2,305,431 |
| `{"phase": "verifying"}` | 109 | 1,679,391 |
| `{"phase": "completed"}` | 1 | 56,136 |
| `{"phase": "awaiting_confirmation"}` | 2 | 444 |

필터 없는 목록은 11-02~11-08에 22건이 242,321~264,822 B였어요. #50341(기준 검토, 11-09 03:29Z 병합)이 두 라이브 빌드(11-09 04:57:31Z, 05:43:36Z 부팅)에 들어간 뒤 첫 호출(11-09 06:16Z, goal 62개)은 941,529 B예요.

`goal-list`는 그 호출의 blob을 열어요.

| goal 필드(값만) | 바이트 | 몫 |
|---|---|---|
| `criterion_review` | 677,674 | 73.0% |
| `verification` | 120,729 | 13.0% |
| `measurement` | 36,718 | 4.0% |
| `metric` | 35,729 | 3.9% |
| `last_review_note` | 27,913 | 3.0% |

`criterion_review` 안에서는 `tools`(reviewer가 부른 도구 336건의 입력과 출력 발췌) 418,117 B, `review` 98,918 B, `reason`과 `detail` 각 76,250 B, `authority` 1,716 B예요.
검토된 33개 goal 모두 `reason`과 `detail`이 같은 글이에요.

| phase | goal | 행 바이트 | `criterion_review` 바이트 |
|---|---|---|---|
| completed | 13 | 55,293 | 273 |
| dropped | 16 | 57,616 | 336 |
| executing | 31 | 763,383 | 633,506 |
| verifying | 2 | 64,950 | 43,559 |

`criterion_review`를 `state`, `request_id`, `criterion_revision`, `reason`, `detail`, `authority`만 남기면(#50490):

| 호출 | 지금 | 바뀐 뒤 | 덜어 내는 바이트 |
|---|---|---|---|
| 필터 없음 | 941,529 | 423,867 | 517,662 (55.0%) |
| `phase=executing` | 763,639 | 278,746 | 484,893 (63.5%) |
| `phase=verifying` | 65,176 | 32,407 | 32,769 (50.3%) |

PR #50490의 본문과 커밋 메시지는 `generated_at` 자리에 임시 값을 넣고 계산해서 위보다 7 B 커요(941,536 / 423,874 등). 위 표가 장부의 941,529 B와 정확히 맞아요.

실제 호출로 계산을 확인했어요. 11-09 07:16Z에 `masc-productor-owner`가 `{"phase": "verifying"}`을 불렀고 결과는 65,173 B이며 inline으로 갔어요(blob이 아니에요). 계산값 65,176 B와 3 B 차이예요. 재시작 전 verifying 호출의 최대는 21,574 B였어요.

## 못 본 것

- 두 수리가 배포된 뒤의 호출 크기. 배포되지 않았어요.
- `masc_run_list`를 부른 Keeper가 무엇을 찾으려 했는지.
- Dashboard의 Goal 트리·상세 응답 크기. 같은 `criterion_review` 전체를 싣지만 재지 않았어요.
- 바뀐 뒤에도 필터 없는 `masc_goal_list`(423,867 B)는 16,384 B를 넘어요. 이슈 #49818의 선택지가 남아 있어요.
