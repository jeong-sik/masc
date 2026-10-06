# 판정 레인 계정 허가 측정 (2026-10-06)

`docs/rfc/RFC-judgment-lanes-take-account-admission-before-keeper-turns.md` §1 의 숫자를 만든 스크립트와 결과다.
두 스크립트 모두 운영 데이터를 읽기만 하고 아무것도 쓰지 않는다. 결과 JSON 에는 집계값만 있다.

| 파일 | 읽는 것 | 보여 주는 것 |
|---|---|---|
| `verifier_steps.py` → `verifier_steps.json` | `<base>/.masc/verification-runs.jsonl` | verifier 한 건의 도구 시간, 첫 도구까지 시간, 모델 단계 수와 단계 간격 |
| `account_admission.py` → `account_admission.json` | `<base>/.masc/agent-core-events/2026-10/06.jsonl` | 한 계정의 요청이 다른 호출이 끝나는 순간에 나간 비율, 4칸이 다 찬 시간 비율(하한) |

재현:

```sh
python3 verifier_steps.py ~/me/.masc/verification-runs.jsonl --hours 24 --until 1791262800
python3 account_admission.py ~/me/.masc/agent-core-events/2026-10/06.jsonl --provider glm
```

`--until 1791262800` 은 2026-10-06 14:00 KST 다. 이 시각까지 24시간을 셌다.
`account_admission.json` 은 그 파일이 15시(KST)대까지 쌓였을 때 돌린 결과다.

읽을 때 주의할 점:

- `requested_at` 은 허가를 받은 뒤 찍힌다. `Complete.complete_stream` 의 dispatch 가 `Provider_admission` 안에서 돌기 때문이다.
- 스트리밍 호출만 보인다. exact 레인 호출 일부는 이 파일에 없어서 "4칸이 다 찬 비율"은 실제보다 낮게 나온다.
- verifier 호출은 임시 base path 에서 돌아서 `agent-core-events` 에서 Keeper 이름으로 골라낼 수 없다. 그래서 verifier 한 단계 안의 대기 시간은 직접 재지 못했고, 단계 간격과 계정 전체의 호출 시간을 비교해 추정했다.
