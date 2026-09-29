# Candle 을 켜기 전 keeper 행동의 기준선 (2026-09-29)

`docs/rfc/RFC-goal-candle-ledger.md` 3.11 이 쓰는 증거예요. Candle 이 keeper 행동을 바꾸는지는
알 수 없어서, 켜기 전에 잰 값을 남겨 두고 켠 뒤에 같은 방법으로 다시 재서 비교해요.

## 다시 재는 법

```
python3 collect.py --base <MASC_BASE_PATH> > baseline-<날짜>.json
```

`<base>/.masc` 의 `goals.json`, `goal_events.jsonl`, `tasks/backlog.json`, `tasks/goal_task_links.json`
을 읽기만 해요. 제목, 설명, 본문은 내지 않고 개수와 시간만 내요.

## 무엇을 재나요

| 항목 | 왜 보나요 |
|---|---|
| Goal 수, phase 별 수, 기한이 있는 Goal 수 | Goal 을 늘리거나 기한을 안 적는 움직임 |
| drop 한 주체별 수 | Goal 을 버리고 갈아타는 움직임 |
| 검증 통과부터 사람의 확정까지 걸린 시간 | 감액 시계를 검증 통과로 잡은 이유 |
| 끝난 Task 중 만든 사람이 곧 담당자인 비율 | 자기가 만들고 자기가 끝내는 움직임 |
| 만든 사람별로 다른 keeper 가 끝낸 Task 수 | 맡기는 대신 직접 하는 움직임 |
| Goal 에 연결된 Task 수 | 연결이 돈이 될 때 늘어나는 움직임 |

## 읽는 법

- `baseline.json` 은 2026-09-29T05:35Z 의 라이브 값이에요. 표본이 Goal 18개와 완료 3건이라 작아요.
  변화가 보여도 원인이 Candle 인지는 이 값만으로 말할 수 없어요. 모델, persona, 난수 같은 다른 변수가
  같이 움직여요(`docs/rfc/RFC-0435-world-preset-comparison-validity.md` 2절).
- 비교는 운영자가 표를 보고 판단해요. 자동으로 무언가를 막거나 조절하는 기준은 만들지 않아요.
