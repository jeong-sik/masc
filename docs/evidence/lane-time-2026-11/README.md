# 턴 시간과 대기 측정 (2026-11)

`measure_lane_time.py` 는 Keeper 가 턴을 도는 시간이 어디로 가는지와, 위임·채팅 작업이 시작 전에 무엇을 기다리는지를 재요.
`.masc` 아래의 세 저장소를 읽기만 해요. 작업 DB 는 읽기 전용으로 열어요.

| 저장소 | 쓰는 곳 |
|---|---|
| `tool_calls/YYYY-MM/DD[.NNN].jsonl` | 도구 호출. `ts` 는 호출이 끝난 시각이에요 |
| `keeper_turn_events/<keeper>/*.jsonl` | trace 파일. 코드로는 `Keeper_autonomous_stream.create` 가 `autonomous` 턴마다 하나 열고, `direct` 턴을 도는 `Keeper_turn.run_direct_turn_with_fsm` 은 열지 않아요. 원장과 맞춰 보면 예외가 있어요("결과" 절). 그 파일의 첫 줄과 마지막 줄의 `ts` 가 턴의 시작과 끝이에요 |
| `keepers/<keeper>/chat-operations.sqlite3` | 위임·채팅 작업. Keeper 하나가 한 번에 하나만 돌려요 |
| `agent-core-events/YYYY-MM/DD.jsonl` | 이벤트 중 `provider_admission:waited` 만 읽어요. 모델 요청이 계정의 허용 수가 모두 찬 상태를 만나 줄을 선 경우예요 |

## 다시 재기

```bash
docs/evidence/lane-time-2026-11/measure_lane_time.py --base-path ~/me \
    --from-date 2026-11-01 --to-date 2026-11-04 --until 2026-11-04T19:10:00Z --json-out after.json
```

이 폴더의 `result-2026-11-01_11-04.json` 이 위 명령의 결과예요. `result-2026-11-01_11-05.json` 은 `--to-date 2026-11-05 --until 2026-11-05T05:00:00Z` 로 같은 명령을 돌린 결과이고, `docs/evidence/execute-waits-2026-11` 과 같은 창이에요. 시험은 `python3 -m unittest discover -s docs/evidence/lane-time-2026-11` 로 돌려요.

서버는 마지막으로 수정한 지 N일이 지난 trace 파일을 시작할 때와 24시간마다 지워요(`prune_shared_jsonl_stores`). N 은 `runtime.toml` 의 `[maintenance].jsonl_retention_days` 이고, 환경 변수 `MASC_JSONL_RETENTION_DAYS` 가 있으면 그 값이 먼저예요. 저장소 기본값은 30일이에요. 이 기기의 `runtime.toml` 에는 `[maintenance]` 가 없고 셸 설정 파일에도 그 환경 변수가 없어요. 서버 로그도 같아요. 10-29 부터 11-05 까지 `system_log` 8개 파일에 `startup prune: pruned N old JSONL day-files (retention=30d from default)` 가 25줄 있고 다른 값은 없어요. 마지막 줄은 11-05T11:35:24Z 예요. 이 줄은 서버가 시작하면서 지운 파일이 있을 때만 찍혀서 모든 시작의 값은 아니에요. 2026-11-05 에 가장 오래된 trace 파일의 수정 시각은 10-07 이었어요. 지운 뒤에 다시 돌리면 그 파일의 턴이 trace 파일이 없는 턴으로 읽혀서 위 JSON 과 값이 달라져요. 이 창의 파일은 12-01 쯤부터 지워지기 시작할 수 있어요.

## 센 방법

- 턴 시간: Keeper 별로 턴 구간을 합쳐서 겹친 시간을 한 번만 세요. 그 합이 "턴이 도는 시간"이에요.
- 도구 시간(원장 전체): 모든 호출의 `duration_ms` 합이에요.
- 호출 사이 시간: 한 턴(`trace_id`, `keeper_turn_id`) 안에서 첫 호출 뒤의 호출마다 "앞 호출이 끝난 뒤 이 호출이 시작되기까지"를 더해요. 호출 시작은 `ts` 에서 `duration_ms` 를 뺀 값이에요. 겹치는 호출은 0으로 잡아요.
- 턴 안의 시간: 호출 구간과 호출 사이 구간 중에서 그 Keeper 의 턴 구간과 겹친 초만 세요. 턴 시간에 대한 몫은 모두 이 값으로 구해요. 원장 전체를 그대로 턴 시간으로 나누면 턴 구간 밖의 시간이 섞여서 몫이 부풀어요.
- 나머지: 턴 시간에서 턴 안의 도구 시간과 턴 안의 호출 사이 시간을 뺀 값이에요.
- trace 파일이 없는 턴: 호출의 `trace_id`, `keeper_turn_id` 와 맞는 trace 파일이 없는 턴이에요. 파일 이름이 `<trace_id>-<keeper_turn_id>-<해시>.jsonl` 형식이라서 이름만 보고 맞춰요(`keeper_turn_id` 는 코드의 `Turn_ref.absolute_turn` 이에요). 이런 턴의 호출이 Keeper 의 턴 구간에 얼마나 드는지는 `turn_time.calls_without_trace_file.tool_time_inside_turns_s` 에 적어요. trace 파일이 하나도 없는 Keeper 는 턴 구간이 없어서 안의 시간이 정의상 0이에요. 그런 Keeper 의 호출은 `keepers_without_any_trace_file` 에 따로 적어요. 측정 시점의 코드에서 trace 파일을 여는 곳은 `Keeper_autonomous_stream.create`(`lib/keeper/keeper_autonomous_stream.ml`) 하나예요. `masc_keeper_msg` 에 답하는 `direct` 턴(`Keeper_turn.run_direct_turn_with_fsm`)은 파일을 쓰지 않아요.
- trace 파일이 있는 턴인데 구간 밖에 놓인 호출: 호출의 턴에 trace 파일이 있고, 호출 시간 중 계산 오차(1e-6초)를 넘는 부분이 그 Keeper 의 턴 구간 밖에 있는 호출이에요. `turn_time.traced_calls_outside_turns` 가 호출 수, 턴 수, 구간 밖 도구 시간을 `turn_kind` 별로 적어요. `calls_partly_inside_turn_time` 은 그중 구간 안의 초도 있는 호출 수이고, `turns_that_also_have_autonomous_calls` 는 그 턴 중 `autonomous` 호출도 같이 가진 턴 수예요.
- 호출 종류 묶음: 한 턴 키의 호출이 가진 `turn_kind` 값을 `+` 로 이은 이름이에요(`direct`, `autonomous`, `autonomous+direct`). 원장은 `turn_kind` 를 호출마다 적어서 한 턴 키가 두 종류를 다 가질 수 있어요. `turn_time.calls_without_trace_file.turns_by_kind_set` 이 창 안의 모든 턴을 묶음 하나에 한 번씩 세고, 묶음마다 trace 파일이 없는 턴 수를 적어요.
- 같은 결과 재조회: 같은 Keeper 가 같은 도구에 같은 입력(`input_fingerprint`)을 보내 1시간 안에 같은 결과(`output_fingerprint`)를 받은 호출이에요. `scripts/measure-tool-efficiency.py` 와 같은 규칙인데, 이 스크립트는 자정을 넘어서도 1시간을 이어서 세요.
- 긴 Execute: 60초 이상 걸린 Execute 예요. 명령에 `sleep`, `for ... in`, `while`, `until` 이 있으면 폴링으로 세요. 명령 문장은 이 판정에만 써요.
- 큐 대기: 작업의 `started_at` 에서 `created_at` 을 뺀 값이에요. 작업의 `source.sender_keeper` 가 있으면 위임이에요.
- 승인 대기: `provider_admission:waited` 이벤트의 `waited_ms` 예요. 허용을 바로 받은 요청은 기록되지 않아서, 이 이벤트는 줄을 선 요청만 세요.
- 도구 쌍: 한 턴에서 연이은 두 호출의 사이 시간(위 호출 사이 시간과 같은 값)을 (앞 호출의 도구, 다음 호출의 도구) 쌍에 더해요. 도구가 같은 쌍과 다른 쌍을 따로 합치고, 각각 사이 시간이 큰 쌍 10개를 `turn_time.tool_transitions` 에 적어요.
- 일정 깨움: Keeper 의 reaction 원장(`keepers/<이름>/reaction-ledger/v7/YYYY-MM/DD.jsonl`)에서 `stimulus` 행은 이벤트가 Keeper 의 큐에 들어온 일이고, 들어온 시각은 `stimulus.arrived_at_unix` 예요. 같은 `stimulus_id` 의 첫 `turn_started` 반응이 기다림의 끝이에요. 반응이 `event_queue_cancelled` 뿐이면 턴이 시작되지 않은 거예요. `--to-date` 다음 날 파일까지 읽어서, 창 바로 뒤에 시작한 이벤트가 시작 안 한 것으로 잡히지 않게 해요. 기다림이 같은 Keeper 의 60초 이상 Execute 나 턴과 겹친 시간은 위임·채팅 작업과 같은 식으로 세요.
- 한 응답의 호출 수: 원장의 `batch_size` 예요. 모델이 한 응답에 담아 요청한 도구 호출 수고, 호출마다 그 값을 세요.
- 실행 방식: 원장의 `execution_mode`(`serial` 또는 `concurrent`)예요. 도구 descriptor 가 정해요(`packages/agent_core/lib/base/tool.mli`).
- 턴이 취소된 때 돌던 Execute: `failure_kind` 가 `Turn_cancelled` 인 작업의 `completed_at` 이 같은 Keeper 의 Execute 호출 구간(시작 3초 전부터 끝 3초 뒤까지) 안에 있으면 세요. 원장은 호출이 끝날 때 행을 쓰기 때문이에요. 잃은 Execute 시간은 `completed_at` 까지 돈 부분이에요.

## 결과(11-01 ~ 11-04T19:10Z, 91.17시간)

| 구간 | 원장 전체 | 턴 안 | 턴 시간 대비 |
|---|---:|---:|---:|
| 턴이 도는 시간(trace 파일이 있는 Keeper 28명) | | 709.8시간 | 100% |
| 도구가 실행된 시간 | 101.3시간 | 79.4시간 | 11.2% |
| 호출 사이 시간(134,311개 호출, 평균 13.7초, 중앙값 1.1초, p90 21.9초) | 510.1시간 | 404.3시간 | 57.0% |
| 나머지(첫 호출 전, 호출 없는 턴, 턴 끝) | | 226.1시간 | 31.9% |

- 원장 전체와 턴 안의 차이는 도구 시간 21.9시간, 호출 사이 시간 105.8시간이에요.
- 도구 시간 21.9시간은 세 덩어리예요. 값은 JSON 의 `turn_time` 아래에 있어요.

| 덩어리 | 호출 | 도구 시간 | 턴 안 | 값이 있는 곳 |
|---|---:|---:|---|---|
| trace 파일이 없는 턴. 그 Keeper 에는 trace 파일이 있어요 | 21,458개, 모두 `direct` | 16.0시간 | 0초(잰 값) | `calls_without_trace_file.keepers_with_a_trace_file` |
| trace 파일이 하나도 없는 Keeper 2명의 호출 | 1,657개 | 4.4시간 | 0초(턴 구간이 없어서 0) | `calls_without_trace_file.keepers_without_any_trace_file` |
| trace 파일이 있는 턴인데 호출이 턴 구간 밖에 통째로 놓임 | 1,097개, 모두 `direct` | 1.5시간 | 0초(잰 값) | `traced_calls_outside_turns` |

- 둘째 덩어리의 Keeper 는 `ocaml-refactor-woman` 과 `native-image-goal-20261101-0340` 이에요.
- 셋째 덩어리의 호출은 trace 파일이 있는 턴의 키(`trace_id`, `keeper_turn_id`)를 달고 있어요. 그런 턴 68개 중 62개는 `autonomous` 호출도 같이 가져요. 턴 구간 안에 든 초가 있는 호출은 없어요(`calls_partly_inside_turn_time` 이 0).
- 호출이 있는 턴 9,872개를 호출 종류로 나누면 `direct` 만 가진 턴이 1,009개, `autonomous` 만 가진 턴이 8,797개, 둘 다 가진 턴이 66개예요(`turns_by_kind_set`). `direct` 만 가진 턴 1,009개 중 1,003개(99.4%)에 trace 파일이 없어요. 그래서 이 표의 턴 시간에는 `direct` 턴이 거의 들어 있지 않아요. `autonomous` 만 가진 턴 8,797개 중에서는 98개(1.1%)에 없고, 둘 다 가진 턴 66개에는 모두 있어요.
- 코드와 원장이 어긋나는 곳이 둘 있어요.
  - 하나는 trace 파일이 없는 `autonomous` 턴 98개예요. 파일이 없는 `autonomous` 호출 1,564개는 모두 `ocaml-refactor-woman` 의 것이에요. 둘째 덩어리의 다른 Keeper `native-image-goal-20261101-0340` 은 `direct` 호출 5개뿐이라 코드와 맞아요.
  - `ocaml-refactor-woman` 은 `keeper_turn_events`, `keepers`, `keeper_chat_events` 에 폴더가 없고 `config/keepers` 에 설정 파일(`ocaml-refactor-woman.toml`)도 없어요(2026-11-05 확인). 지워진 Keeper 로 보이지만 지운 기록은 못 찾았어요.
  - 폴더를 열지 못했다면 `Keeper_chat_event_log` 가 `journal directory creation failed` 를, `Keeper_autonomous_stream` 이 `autonomous stream journal unavailable` 을 서버 로그에 남겨요. 10-29 부터 11-05 까지의 `system_log` 에 두 메시지는 한 줄도 없어요. 폴더가 처음부터 없었는지 지워졌는지는 확인하지 못했어요.
  - 다른 하나는 trace 파일이 있는 `direct` 만 가진 턴이에요. 11-04T19:10Z 까지 창은 1,009개 중 6개, 11-05T05:00Z 까지 창은 1,143개 중 8개예요. 두 창 모두 이 턴들은 셋째 덩어리의 턴 중 `autonomous` 호출이 없는 턴과 같은 집합이에요. "읽을 때 주의"에 적은 대로 `direct` 호출이 `autonomous` 턴의 키를 다는 경로를 따라가지 못해서 이유는 몰라요.
- 같은 결과 재조회 32,545개(첫 호출 뒤의 호출만)가 쓴 시간은 원장 전체로 20.8시간이고, 턴 안에서는 19.3시간(2.7%)이에요. 이 호출들은 앞 호출 바로 뒤에 이어져서 호출 사이 시간이 짧아요.
- 한 턴(9,872개)의 호출 수는 평균 14.6, 중앙값 5, p90 31, p99 152, 최대 1,388이에요.
- 한 응답에 호출 하나만 담은 경우가 141,419호출(98.1%)이고, 둘 이상 담은 호출은 2,764호출(1.9%)이에요. 크기별로 2가 1,500, 3이 453, 4가 152, 5가 70, 6이 24, 7이 539, 8이 16, 10이 10호출이에요.
- 실행 방식은 serial 85,098호출(99.2시간)과 concurrent 59,085호출(2.2시간)이에요. 호출이 대부분 응답당 하나라서 concurrent 로 분류돼도 겹쳐 도는 호출은 드물어요(호출 사이 시간이 겹친 쌍 3,174개).
- 60초 이상 Execute 562호출은 원장 전체로 42.0시간이고, 턴 안에서는 36.2시간(5.1%)이에요. 그중 폴링 331호출은 원장 전체로 29.3시간이고, 턴 안에서는 28.1시간(4.0%)이에요.

원장 전체의 호출 사이 시간 510.1시간을 도구 쌍으로 나누면(`turn_time.tool_transitions`):

| 쌍 | 쌍 수 | 사이 시간 | 몫 |
|---|---:|---:|---:|
| 같은 도구가 이어진 쌍 | 88,548 | 259.5시간 | 50.9% |
| 그중 `Execute` → `Execute` | 51,631 | 207.7시간(평균 14.5초) | 40.7% |
| 다른 도구로 넘어간 쌍 | 45,763 | 250.6시간 | 49.1% |
| 그중 `Execute` → `masc_board_comment` | 1,883 | 14.1시간(평균 26.9초) | 2.8% |
| 그중 `masc_dos_screen` ↔ `masc_dos_press` | 2,459 | 19.4시간 | 3.8% |

폴링을 많이 한 Keeper(턴 안의 시간만 세요, `turn_time.inside_turns.polling_by_keeper`):

| Keeper | 폴링 | 턴 시간 | 몫 |
|---|---:|---:|---:|
| `wkbl-data` | 8.3시간 | 53.0시간 | 15.7% |
| `masc-productor-owner` | 7.3시간 | 66.5시간 | 11.0% |
| `wkbl-front` | 5.0시간 | 41.5시간 | 12.0% |
| `goo-yang-bong` | 3.2시간 | 59.0시간 | 5.4% |
| `github-pr-checker` | 2.5시간 | 11.1시간 | 22.4% |

제공자 승인 대기(줄을 선 요청만 기록돼요):

| | 값 |
|---|---:|
| 이벤트 | 23,943건 |
| 대기 합계 | 479.6시간(평균 72.1초, 중앙값 35.9초, p90 194.8초) |
| GLM coding 계정 | 463.8시간(96.7%) |
| 등급별 | standard 313.5시간, priority 123.6시간, background 42.5시간 |
| 시계 1시간당 대기 | 중앙값 3.84시간, 대기가 있었던 87시간대 중 36시간대가 5시간 초과 |

위임·채팅 작업(1,220건, 시작한 1,217건):

| | 값 |
|---|---:|
| 시작 전 기다린 시간 합계 | 6,271.3분 |
| 그중 같은 Keeper 의 60초 이상 Execute 와 겹친 시간 | 119.4분(1.9%) |
| 그중 같은 Keeper 의 턴과 겹친 시간 | 1,401.8분(22.4%) |
| Execute 가 도는 중에 만들어진 작업 | 17건, 대기 중앙값 223.2초, 합계 85.8분 |

일정 깨움(`schedule_wakes`, 이벤트 4,823건, 이 기간 reaction 원장의 `stimulus` 는 모두 `schedule_due` 예요):

| | 값 |
|---|---:|
| 턴이 시작된 것 | 3,241건 |
| 큐에서 취소된 것 | 1,567건 |
| 턴이 시작되지 않은 것 | 15건 |
| 큐에 들어와서 턴이 시작되기까지 | 중앙값 3.6초, p90 494.3초, 합계 458.6시간 |
| 그 기다림 중 같은 Keeper 가 60초 이상 Execute 를 돌던 시간과 겹친 것 | 17.6시간(3.8%) |
| 그 기다림 중 같은 Keeper 의 턴이 돌던 시간과 겹친 것 | 249.0시간(54.3%) |
| 30분 이상 기다린 이벤트 | 173건, 388.5시간(84.7%) |

30분 이상 기다린 시간이 큰 Keeper 는 `e-masc-the-leader` 121.8시간(26건), `sangsu` 91.5시간(22건), `masc-productor-owner` 42.1시간(33건), `wkbl-front` 37.3시간(24건), `wkbl-data` 21.8시간(14건)이에요.

턴이 취소돼 끝난 작업(`Turn_cancelled`)은 106건이에요. 그중 같은 Keeper 의 Execute 가 도는 중에 취소된 것은 3건이고, 잃은 Execute 시간은 합계 37.1초예요. 60초 이상 Execute 가 도는 중에 취소된 작업은 없어요.

위임(375건, 시작한 373건)은 305건이 성공하고 68건이 실패, 2건이 취소돼요. 실패 68건은 `Turn_cancelled` 36건, `Turn_exception` 32건이에요. 시작 전 대기는 중앙값 0.1초, p90 586.4초이고, 돌아간 시간은 중앙값 109.7초, p90 807.7초예요.

## 읽을 때 주의

- `ts` 가 끝난 시각이라는 것은 11-03 하루에서 확인했어요. 같은 턴에서 뒤 호출이 30초 이상 걸린 연이은 호출 270쌍 모두, 두 `ts` 의 차이가 뒤 호출의 길이 이상이었어요.
- 턴 길이는 trace 파일의 첫 줄과 마지막 줄 시각으로 어림한 값이에요. 마지막 줄이 턴이 끝난 뒤에 늦게 써졌다면 턴이 길게 잡혀요. 이 경우가 있는지는 확인하지 못했어요.
- `direct` 호출이 `autonomous` 턴과 같은 키(`trace_id`, `keeper_turn_id`)를 달게 되는 경로는 코드로 따라가지 못했어요. 원장의 `turn_kind` 와 trace 파일 이름만으로 센 결과예요.
- 표의 몫은 trace 파일이 있는 턴의 시간이 기준이에요. trace 파일이 없는 `direct` 턴의 호출과 호출 사이 시간은 표에 들어 있지 않아요. 이 시간을 턴 시간에 더하면 몫이 얼마나 달라지는지는 이 스크립트로 재지 않았어요.
- "호출 사이 시간"에는 모델 추론과 제공자 쪽 대기가 함께 들어 있어서 둘을 가르지 못했어요. 승인 대기 합계(479.6시간)가 호출 사이 시간(턴 안 404.3시간, 원장 전체 510.1시간)과 비슷한 크기라서 큰 몫이 승인 줄일 것으로 보지만, 같은 요청끼리 짝지어 확인하지는 않았어요. 승인 대기 이벤트는 턴 구간 안인지 가리지 않고 세서 두 값을 정확히 견주지는 못해요.
- 작업 DB 만 있고 trace 파일이 없는 Keeper 의 작업은 "같은 Keeper 의 턴과 겹친 시간"이 0으로 잡혀요.
- reaction 원장의 `stimulus` 가 이 기간 모두 `schedule_due` 라서 Board 멘션으로 깨운 턴의 대기는 못 쟀어요.
- 일정 깨움이 30분 넘게 기다린 이유는 가리지 못했어요. 같은 Keeper 가 그 사이 다른 턴을 돌았거나, 그 이벤트를 나중에 골랐을 수 있어요.
- 작업 DB 의 보존 기간은 확인하지 못했어요. 날짜가 지난 뒤에 다시 돌리면 같은 값이 안 나올 수 있어요.
