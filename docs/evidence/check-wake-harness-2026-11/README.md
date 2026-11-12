# 커밋의 check 가 끝났다는 깨움을 채점하는 하네스

`docs/rfc/RFC-keeper-wakes-when-a-pr-check-finishes.md` 5절의 하네스예요. 구현 PR 은 이 폴더의 정의를 바꾸지 않고, 구현이 낸 깨움을 이 정의로 채점해요.
깨움 줄의 모양은 구현 PR 이 정해요. 그 PR 이 같은 PR 안에서 서버 로그의 깨움 줄을 이 채점에 이어요.

## 정의

`check_wake_scoring.py` 가 순수 함수로 담아요. 입력은 GitHub 이 그 커밋에 대해 가진 Actions run 목록이에요.

- run 하나는 `created_at` 과, `status` 가 `completed` 일 때의 `updated_at`(끝)으로 읽어요. 도는 중이면 끝이 없어요. job 단위로는 읽지 않아요.
- **간격(gap)**: 앞의 run 이 모두 끝난 뒤에 만들어진 run. 그 사이가 "run 이 모두 끝난" 순간이에요.
- **체크 run**: `event` 가 `push`, `pull_request`, `workflow_run` 인 run. 라벨·승인·리뷰·손으로 돌린 것(`pull_request_target`, `pull_request_review`, `workflow_dispatch`)은 새 사건이 만든 run 이라 체크로 세지 않아요. 이 모음은 GitHub 이 문서에 적은 `event` 값을 하네스가 읽는 방식이고 제품 규칙이 아니에요.
- **체크 run 보다 앞선 간격**: 그 뒤에 체크 run 이 하나라도 더 만들어진 간격. "run 이 모두 끝나면 깨운다"는 감시가 이 순간에 깨우면 이른 깨움이에요.
- **거짓 깨움**: 깨운 시각 T 에, T 이전에 만들어진 run 중 아직 안 끝난 것이 있어요. **이른 깨움**: 모든 run 이 끝났는데 T 뒤에 체크 run 이 만들어졌어요.
- **늦은 깨움**: T 에서 T 이전에 만든 run 들의 마지막 끝 시각을 뺀 값(초).
- **놓친 깨움**: 감시가 due 에만 깨어났는데 그 시각까지 만들어진 run 이 모두 due 이전에 끝났어요.

## 시험

```
python3 -I docs/evidence/check-wake-harness-2026-11/test_check_wake_scoring.py
```

fixture 는 `jeong-sik/masc#51286` 의 head 의 실제 run 시각을 줄인 거예요. 승인 run 둘이 끝나고, 리뷰 run 이 만들어지고, 그 뒤에 체크 run 이 시작하고, 첫 `PR type-check` 가 취소된 뒤 22초 만에 둘째가 만들어져요.
변이 8개(`<` 와 `<=`, `max` 와 `min`, 체크 run 모음에 리뷰 이벤트를 넣기 등)를 하나씩 넣으면 시험이 실패해요. 변이는 첫 시도에서 4개가 잡히지 않아서 경계 fixture 를 더했어요.

## 지금 재는 값

`probe_head_shas.py` 는 최근 PR 의 head 마다 GitHub 에서 run 목록을 읽어 위 정의를 적용해요. 감시가 아직 없어도 돌아요.

```
python3 -I docs/evidence/check-wake-harness-2026-11/probe_head_shas.py \
  --repo jeong-sik/masc --limit 60 --json-out result.json
```

`result-head-gaps-2026-11-11.json` 이 위 명령의 결과예요(2026-11-11T09:55Z 에 읽음, 요청 61번).

| | 값 |
|---|---:|
| 읽은 head | 60 |
| run 이 안 끝난 head(뺌) | 0 |
| 센 head | 60 |
| "run 이 모두 끝난" 순간이 있었던 head | 47 (78.3%) |
| 그 순간 뒤에 체크 run 이 더 만들어진 head | 6 (10.0%) |
| 그 첫 간격의 길이(중앙값 / 최대) | 56초 / 98초 |
| 체크 run 끼리만 본 간격이 있는 head | 0 |

- 간격을 만든 run 112개 중 104개(92.9%)가 `Approval merge request` workflow 예요(`pull_request_target` 56, `pull_request_review` 48). 나머지는 `Test` 수동 실행 3, `PR type-check` 3, `Changelog fragments` 2예요. 승인 run 은 체크가 아니라서 "모든 run 이 끝났다"로 깨우는 감시는 이 run 들이 늦게 붙어도 이르지 않아요.
- 이른 깨움이 될 수 있는 건 6개 head 예요. 승인 run 이 먼저 끝난 뒤 체크 run 이 시작한 경우예요. "run 이 하나 이상이고 모두 끝났다"(RFC 4.1 의 끝 B)로 읽으면, 감시를 그 사이에 걸었을 때 체크가 시작하기 전에 깨워요.
- 체크 run 끼리는 60개 head 모두에서 끊김 없이 이어졌어요. 끝을 "체크 run 이 하나 이상이고 모두 끝났다"로 읽으면 이 표본에서 이른 깨움이 0이에요.
- `workflow_run` 이벤트로 이어 만들어진 run 은 이 표본에 하나도 없었어요. RFC 1.3 의 7이 적은 "끝난 뒤에도 같은 head 에 새 run 이 붙는다"는 이 표본에서는 승인·라벨 run 이에요.

## 한계

- 읽은 시각의 최종 상태예요. 도는 중인 run 이 있는 head 는 뺐고, 이번에는 0개였어요(처음 읽은 09:52Z 에는 3개였어요).
- run 단위로 읽어서, 앞 job 이 끝난 뒤에 만들어지는 이어진 job(RFC 1.3 의 6)은 안 보여요. 그 틈은 job 단위 채점이 필요하고 이 폴더에 없어요.
- 재시도한 run 의 `updated_at` 은 마지막 시도의 끝이에요.
- 최근 PR 60개는 한 저장소(`jeong-sik/masc`)의 한 시기예요. `wkbl` 같은 비공개 저장소와 다른 시기는 읽지 않았어요.
- 이 값은 감시가 없을 때의 이른 깨움 위험이에요. 감시를 만든 뒤의 효과가 아니에요.
