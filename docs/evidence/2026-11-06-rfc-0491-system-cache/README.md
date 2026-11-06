# RFC-0491 첫 요청 캐시 미적중 측정

RFC-0491 §1.2 의 표를 만드는 스크립트와 그 기준값이에요. 배포 뒤 같은 스크립트를 다시 돌려 §6 의 검증을 해요.

## 돌리는 법

```
python3 -I measure_first_request_miss.py <base-path>/.masc <YYYY-MM/DD> [--start <ISO>] [--end <ISO>]
```

- 턴 기록 `keepers/<name>/turn-records/<YYYY-MM/DD>.jsonl` 에서 같은 Keeper 의 연속한 두 턴을 쌍으로 묶어요.
- 블록 digest 가 다르면 그 블록이 바뀐 것으로 봐요. 대상 블록은 `keeper_instructions`, `active_goals`, `completion_authority`, `constitution_amendments` 예요.
- `model_input_front`(kind, digest)가 다르면 앞부분이 움직인 것으로 봐요.
- 비용 원장 `costs/<YYYY-MM/DD>.jsonl` 의 `per_request` 행 중 (agent, trace_id, keeper_turn_id) 마다 가장 이른 행을 뒤 턴의 첫 요청으로 봐요.
- official client Keeper 는 `per_request` 행이 없어서 쌍으로는 세지만 토큰에는 들어가지 않아요.
- `--start`·`--end` 를 주면 턴 기록과 비용 원장 모두 그 사이(`start <= 시각 < end`)의 행만 세요.
- 원장 파일은 읽기만 해요.

## 기준값 (배포 전)

`python3 -I measure_first_request_miss.py ~/me/.masc 2026-11/05 --end 2026-11-05T11:00:00Z` (2026-11-06 실행). RFC-0491 §1.2 의 11-05 표와 같은 값이에요.

| 바뀐 System 블록 | 앞부분 움직임 | 쌍 | 이어진 쌍 | 첫 요청 미적중 토큰 | 몫 | 미적중률 |
|---|---|---|---|---|---|---|
| keeper_instructions | no | 42 | 35 | 14,523,399 | 13.8% | 96.5% |
| completion_authority | no | 31 | 14 | 8,089,197 | 7.7% | 74.4% |
| active_goals | no | 14 | 7 | 2,761,337 | 2.6% | 96.9% |
| keeper_instructions | yes | 7 | 3 | 293,705 | 0.3% | 87.9% |
| keeper_instructions + completion_authority | no | 2 | 1 | 723,499 | 0.7% | 98.6% |
| active_goals | yes | 1 | 0 | 0 | 0.0% | - |
| keeper_instructions + active_goals | yes | 1 | 0 | 0 | 0.0% | - |
| completion_authority | yes | 1 | 0 | 0 | 0.0% | - |
| none | no | 1274 | 379 | 72,931,741 | 69.3% | 33.0% |
| none | yes | 159 | 40 | 5,957,923 | 5.7% | 82.8% |

쌍 1,532개, 이어진 쌍 479개, 첫 요청 미적중 토큰 105,280,801개예요.

## 배포 뒤 볼 것

RFC-0491 2층(#48786)과 3층(#49004)이 배포된 날을 같은 방법으로 돌려요. 결과는 아래 「3층 배포 뒤」에 있어요.

- 조항이 바뀐 날, 앞부분이 그대로인 쌍에서 `keeper_instructions` 가 바뀐 행이 줄고 `constitution_amendments` 행이 생겨야 해요. 3층은 조항 변경을 System 이 아니라 끝 문맥 블록으로 보내요.
- `constitution_amendments` 만 바뀌고 앞부분이 그대로인 쌍의 미적중률이 `none / no` 행(배포 전 33.0%)에 가까우면 3층이 의도대로 동작한 거예요. 배포 전 같은 경우(`keeper_instructions / no`)는 96.5% 였어요.
- `completion_authority / no` 행의 미적중률(배포 전 74.4%)도 `none / no` 쪽으로 내려가야 해요. 2층이 이 블록을 System 밖으로 옮겨요.
- 남는 `keeper_instructions / no` 행은 instructions 나 `keeper.md` 가 바뀐 경우예요. 3층은 이 경우를 다루지 않아요.

## 3층 배포 뒤 (2026-11-06)

`python3 -I measure_first_request_miss.py ~/me/.masc 2026-11/06 --start 2026-11-06T03:10:41Z --end 2026-11-06T07:20:00Z` (2026-11-06 실행).

시작 시각은 3층(#49004)이 든 바이너리(`6ad837c7cac`)가 요청을 받기 시작한 부팅 시각이에요. `logs/system_log_2026-11-06.jsonl` 의 `listening_banner.end` 줄에서 읽었어요.

| 바뀐 System 블록 | 앞부분 움직임 | 쌍 | 이어진 쌍 | 첫 요청 미적중 토큰 | 몫 | 미적중률 |
|---|---|---|---|---|---|---|
| active_goals | no | 70 | 21 | 11,216,901 | 45.7% | 97.6% |
| completion_authority | no | 5 | 3 | 506,574 | 2.1% | 35.4% |
| active_goals | yes | 4 | 1 | 140,958 | 0.6% | 100.0% |
| keeper_instructions + active_goals | yes | 3 | 2 | 200,429 | 0.8% | 60.3% |
| completion_authority | yes | 3 | 0 | 0 | 0.0% | - |
| active_goals + completion_authority | yes | 1 | 0 | 0 | 0.0% | - |
| active_goals + completion_authority | no | 1 | 0 | 0 | 0.0% | - |
| none | no | 455 | 69 | 12,020,110 | 48.9% | 30.5% |
| none | yes | 30 | 8 | 472,384 | 1.9% | 45.6% |

쌍 572개, 이어진 쌍 104개, 첫 요청 미적중 토큰 24,557,356개예요.

- `active_goals` 만 바뀌고 앞부분이 그대로인 쌍이 첫 요청 미적중 토큰의 45.7% 예요. 미적중률은 97.6% 로, `none / no` 행(30.5%)보다 3배 넘게 높아요.
- 이 쌍들은 Goal 저장소가 바뀐 데서 나와요. 같은 시각에 여러 Keeper 가 같은 새 digest 로 옮겨 가요(한 번에 17명, 11명, 11명, 8명). 03:00Z 뒤 `goal_events.jsonl` 에는 `goal_phase` 12건, `goal_created` 6건, `goal_updated`·`goal_edited` 각 2건, `goal_proof_reopened` 2건이 있어요.
- 배포 전 42쌍이던 `keeper_instructions / no` 행은 없어요. 다만 조항 원장(`constitution/articles.jsonl`)의 마지막 변경이 2026-11-05 08:41Z 라서, 이 구간에는 조항이 바뀐 쌍도 `constitution_amendments` 행도 없어요. 3층이 의도대로 동작하는지는 조항이 바뀐 날 다시 봐요.
- `completion_authority / no` 의 미적중률은 35.4% 지만 이어진 쌍이 3개라서 결론에 쓰지 않아요.
- 그래서 RFC-0491 §7 의 4층(`Active_goals`)을 열어요.

## 한계

- 미적중률은 provider 가 돌려준 `cache_miss_input_tokens` 를 그대로 써요. provider 의 캐시 정책이 바뀌면 같은 코드에서도 값이 달라져요.
- 턴 쌍은 같은 날 파일 안에서만 묶어요. 자정을 넘는 쌍은 빠져요.
- 같은 날 안에서도 쌍마다 기록 길이가 달라서, 행끼리 미적중률을 견줄 때는 쌍 수가 적은 행(이어진 쌍 10개 미만)을 결론에 쓰지 않아요.
