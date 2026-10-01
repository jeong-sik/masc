# Candle 을 켜기 전 keeper 행동의 기준선 (2026-09-29)

`docs/rfc/RFC-goal-candle-ledger.md` 3.8 과 3.11 이 쓰는 증거예요. Candle 이 keeper 행동을 바꾸는지는
알 수 없어서, 켜기 전에 잰 값을 남겨 두고 켠 뒤에 같은 방법으로 다시 재서 비교해요.

## 다시 재는 법

```
python3 collect.py --base <MASC_BASE_PATH> > baseline-<날짜>.json
```

`<base>/.masc` 의 `goals.json`, `goal_events.jsonl`, `tasks/backlog.json`, `tasks-archive.json`,
`tasks/goal_task_links.json` 을 읽기만 해요. keeper 설정 폴더는 기본값이 `<base>/.masc/config/keepers`
이고, 다른 곳이면 `--keepers-dir` 로 줘요. 제목, 설명, 본문은 내지 않고 개수와 시간만 내요.

`tasks-archive.json` 은 GC 가 끝난 Task 를 옮겨 둔 파일이에요. 이 파일을 빼고 세면 Goal 에 연결된 Task
41개 중 12개가 빠져요. 파일이 없으면 옮긴 적이 없는 것으로 봐요.

## 무엇을 재나요

| 항목 | 왜 보나요 |
|---|---|
| Goal 수, phase 별 수, 기한이 있는 Goal 수 | Goal 을 늘리거나 기한을 안 적는 움직임 |
| 생성부터 기한까지 시간(기한은 그날 UTC 23:59:59) | 짧은 Goal 이 감액을 받기 쉬운 정도 |
| drop 한 주체별 수 | Goal 을 버리고 갈아타는 움직임 |
| 기록된 기한·priority 변경 횟수와 주체별 수 | 완료 기준 외의 조건을 바꾸는 움직임 |
| 검증 통과부터 사람의 확정까지 걸린 시간 | 감액 시계를 검증 통과로 잡은 이유 |
| Task 수(backlog, archive 로 나눔), 끝난 Task 중 만든 사람이 곧 담당자인 비율 | 자기가 만들고 자기가 끝내는 움직임 |
| 만든 사람별로 다른 keeper 가 끝낸 Task 수 | 맡기는 대신 직접 하는 움직임 |
| Goal 에 연결된 Task 수, 그중 archive 에 있는 수 | 연결이 돈이 될 때 늘어나는 움직임 |
| phase 별로 지급 후보가 있는 Goal 수 | RFC 3.4 의 후보 규칙이 실제 Goal 에 적용되는 정도 |

후보는 Goal 에 연결된 done Task 중 끝난 시각이 Goal 생성 시각보다 늦고 담당자에게 keeper 설정 파일이
있는 것의 담당자예요.

## 연결이 일어나는 방식

Task 와 Goal 의 연결에는 시각이 없어서 `collect_link_timing.py` 가 두 가지로 어림해요.

```
python3 collect_link_timing.py --base <MASC_BASE_PATH> > link-timing-<날짜>.json
```

| 항목 | 왜 보나요 |
|---|---|
| 연결된 Task 중 Goal 보다 먼저 만들어진 수와 그 상태 | 먼저 만들어진 Task 의 연결은 Task 를 만든 뒤에 한 일이에요 |
| keeper 가 `masc_task_set_goal` 을 부른 횟수 | 이미 있는 Task 를 나중에 붙이는 길은 이 도구 하나예요. 대시보드로 운영자가 붙인 횟수는 없어요 |

`link-timing.json` 은 2026-09-29T07:26Z 의 값이에요. `baseline.json` 보다 늦게 재서 Goal 과 연결 수가 달라요.

## 읽는 법

- 새 보고서는 공유 Goal 에 소유자를 집계하지 않아요. 보관된 `baseline.json` 은 당시 관측값이라
  `owner_known` 을 포함한 원본을 그대로 둬요.
- `goal_events.metadata_edits` 는 `goal_edited` 의 `actor` 와 각 필드의 `{from, to}` 를 세요.
  한 이벤트가 두 필드를 바꾸면 `recorded_events` 는 1이고 두 필드의 `changes` 는 각각 1이에요.
  주체나 변경 값이 잘못된 이벤트는 수집을 실패시켜요.
- 이 집계의 범위는 기록된 변경뿐이에요. 이벤트가 없으면 `coverage` 는 `not_observed` 이고,
  관측 횟수 0이 실제 수정 횟수 0을 뜻하지 않아요. 변경 이벤트 producer 는
  [#39951](https://github.com/jeong-sik/masc/pull/39951)에서 진행 중이며, 이 수집기 기반의
  공유 Goal head에는 아직 포함되지 않았어요. 이벤트가 있어도 기록 실패로 빠진 수정까지 알 수는 없어요.
- `goal_created`·`goal_updated` 는 변경 후 snapshot 이라 기한·priority 변경으로 추정하지 않아요.
  동시에 일어난 수정의 이벤트는 저장 순서와 다르게 붙을 수 있어요. 변경 이벤트와 snapshot 이
  함께 있어도 변경 횟수를 두 번 세지 않아요.
- `baseline.json` 은 2026-09-29T05:59Z 의 라이브 값이에요. 표본이 Goal 18개와 완료 3건이라 작아요.
  변화가 보여도 원인이 Candle 인지는 이 값만으로 말할 수 없어요. 모델, persona, 난수 같은 다른 변수가
  같이 움직여요(`docs/rfc/RFC-0435-world-preset-comparison-validity.md` 2절).
- 비교는 운영자가 표를 보고 판단해요. 자동으로 무언가를 막거나 조절하는 기준은 만들지 않아요.
