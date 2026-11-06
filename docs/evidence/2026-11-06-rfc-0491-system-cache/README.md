# RFC-0491 첫 요청 캐시 미적중 측정

RFC-0491 §1.2 의 표를 만드는 스크립트와 그 기준값이에요. 배포 뒤 같은 스크립트를 다시 돌려 §6 의 검증을 해요.

## 돌리는 법

```
python3 -I measure_first_request_miss.py <base-path>/.masc <YYYY-MM/DD> [<끝 시각 ISO>]
```

- 턴 기록 `keepers/<name>/turn-records/<YYYY-MM/DD>.jsonl` 에서 같은 Keeper 의 연속한 두 턴을 쌍으로 묶어요.
- 블록 digest 가 다르면 그 블록이 바뀐 것으로 봐요. 대상 블록은 `keeper_instructions`, `active_goals`, `completion_authority`, `constitution_amendments` 예요.
- `model_input_front`(kind, digest)가 다르면 앞부분이 움직인 것으로 봐요.
- 비용 원장 `costs/<YYYY-MM/DD>.jsonl` 의 `per_request` 행 중 (agent, trace_id, keeper_turn_id) 마다 가장 이른 행을 뒤 턴의 첫 요청으로 봐요.
- official client Keeper 는 `per_request` 행이 없어서 쌍으로는 세지만 토큰에는 들어가지 않아요.
- 원장 파일은 읽기만 해요.

## 기준값 (배포 전)

`python3 -I measure_first_request_miss.py ~/me/.masc 2026-11/05 2026-11-05T11:00:00Z` (2026-11-06 실행). RFC-0491 §1.2 의 11-05 표와 같은 값이에요.

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

RFC-0491 2층(#48786)과 3층(#49004)이 배포된 날을 같은 방법으로 돌려요.

- 조항이 바뀐 날, 앞부분이 그대로인 쌍에서 `keeper_instructions` 가 바뀐 행이 줄고 `constitution_amendments` 행이 생겨야 해요. 3층은 조항 변경을 System 이 아니라 끝 문맥 블록으로 보내요.
- `constitution_amendments` 만 바뀌고 앞부분이 그대로인 쌍의 미적중률이 `none / no` 행(배포 전 33.0%)에 가까우면 3층이 의도대로 동작한 거예요. 배포 전 같은 경우(`keeper_instructions / no`)는 96.5% 였어요.
- `completion_authority / no` 행의 미적중률(배포 전 74.4%)도 `none / no` 쪽으로 내려가야 해요. 2층이 이 블록을 System 밖으로 옮겨요.
- 남는 `keeper_instructions / no` 행은 instructions 나 `keeper.md` 가 바뀐 경우예요. 3층은 이 경우를 다루지 않아요.

## 한계

- 미적중률은 provider 가 돌려준 `cache_miss_input_tokens` 를 그대로 써요. provider 의 캐시 정책이 바뀌면 같은 코드에서도 값이 달라져요.
- 턴 쌍은 같은 날 파일 안에서만 묶어요. 자정을 넘는 쌍은 빠져요.
- 같은 날 안에서도 쌍마다 기록 길이가 달라서, 행끼리 미적중률을 견줄 때는 쌍 수가 적은 행(이어진 쌍 10개 미만)을 결론에 쓰지 않아요.
