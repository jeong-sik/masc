# 실패한 도구 호출을 도구별·실패 문구별로 세기 (2026-11)

도구 호출 원장(`~/me/.masc/tool_calls`)에서 `disposition` 이 `failed` 인 호출을 세요. 도구별 실패 수와, 같은 문구로 실패한 호출이 몇 명의 Keeper·몇 턴에서 나왔는지를 같이 내요.

## 왜 재나요

도구가 실패하면 실패 문구 한 줄이 Keeper 맥락에 남아요. 같은 문구가 한 Keeper 에서만 되풀이되면 그 Keeper 의 맥락 문제이고, 여러 Keeper 에서 나오면 도구 설명이나 서버 응답을 고쳐야 해요. 어느 쪽인지 가르려면 문구별로 Keeper 와 턴을 세어야 해요.

## 결과 (2026-11-06T09:52Z ~ 11-07T09:52Z, UTC)

호출 20,399건 중 193건(0.95%)이 실패했어요. JSON 이 아니거나 `ts`·`tool` 이 없어서 읽지 못한 줄은 0줄이에요. 아래 표는 실패가 많은 도구 8개예요.

| 도구 | 호출 | 실패 | 실패율 |
|---|---|---|---|
| `masc_board_post_get` | 1,383 | 49 | 3.5% |
| `Grep` | 753 | 29 | 3.9% |
| `Execute` | 8,959 | 24 | 0.3% |
| `keeper_artifact_read` | 176 | 13 | 7.4% |
| `Edit` | 290 | 12 | 4.1% |
| `BrowserRead` | 1,074 | 10 | 0.9% |
| `masc_schedule_get` | 43 | 8 | 18.6% |
| `Read` | 289 | 6 | 2.1% |

같은 문구(첫 줄에서 에코한 명령 `,"cmd":"` 뒤는 떼고, 숫자는 `N`, 8자리 이상 16진수는 `<hex>`)로 묶으면 이래요.

| 도구 | 문구 | 실패 | Keeper | 턴 |
|---|---|---|---|---|
| `masc_board_post_get` | `comment_offset N names no comment of p-<hex>: the thread now has N comments …` | 42 | 1 | 27 |
| `Edit` | `old_string not found in file. Patch did not match anything …` | 12 | 2 | 10 |
| `keeper_artifact_read` | `artifact does not exist` | 10 | 7 | 8 |
| `BrowserRead` | `selected_client_disconnected` | 8 | 1 | 7 |
| `Execute` | `remote_ssh_disk_low: endpoint apple-review-pangyo …` | 8 | 2 | 3 |
| `masc_schedule_get` | `schedule not found` | 8 | 2 | 5 |
| `Execute` | `remote_ssh_disk_low: endpoint apple-review-be …` | 6 | 2 | 5 |
| `masc_board_post_get` | `Post not found: p-<hex>. Use an id masc_board_list or masc_board_search returns …` | 4 | 3 | 4 |

- `comment_offset` 실패는 한 Keeper(`e-masc-the-leader`)가 글 두 개에서 글 끝을 넘은 `comment_offset` 으로 읽은 것이에요. 이 Keeper 의 실패는 문구 모양이 둘이라 43건이에요. 글 하나(`p-65ada8108fe3`)에서 29건·16턴·298분, 다른 글(`p-d8f423a22489`)에서 14건·12턴·126분이에요. 서버 응답은 "the thread now has 17 comments, at offsets 0-16. Start again from comment_offset=0" 처럼 다시 시작할 자리를 알려 줘요. 왜 끝을 넘은 자리를 계속 물었는지는 보지 않았어요.
- `Execute` 의 `remote_ssh_disk_low` 는 리뷰 서버 셋(`apple-review-pangyo` 8건, `apple-review-anyang` 3건, `apple-review-be` 6건)에서 17건이에요. `Execute` 실패 24건 중 17건이에요.
- `keeper_artifact_read` 의 `artifact does not exist` 는 이슈 #49396 이 다루는 것이에요. 원본 기록과 맞춘 값은 `artifact-read-misses-2026-11` 에 있어요.
- `Grep` 은 29건이 거의 다 다른 문구로 나와요. 오류가 경로와 패턴을 담은 한 줄 JSON 이라서 가장 큰 묶음이 2건이에요. 원격(`via":"remote_ssh`) 경로의 `rg` 실패는 #49714 에 따로 적었어요.
- 위 표에서 `masc_board_post_get` 의 `comment_offset` 문구와 `BrowserRead` 문구는 Keeper 한 명에서만 나왔고, `Edit`·`keeper_artifact_read`·`Execute` 문구는 둘 이상에서 나왔어요. 원인은 확인하지 않았어요.

## 못 잰 것

- 실패한 뒤의 비용(같은 호출을 다시 한 횟수, 걸린 시간)은 세지 않았어요.
- 첫 줄이 경로와 패턴을 담은 JSON 인 도구(`Grep`)는 문구가 잘게 쪼개져요. 실패 수는 도구 표가 맞아요.
- `disposition` 이 없는 줄은 실패로 세지 않아요. 이 창에서 `disposition` 이 없는 줄이 몇 줄인지는 세지 않았어요.
- 모델이 실패 문구를 보고 다음에 무엇을 했는지는 보지 않았어요.

## 문구로 따로 훑은 값

같은 읽기 함수로 `disposition` 을 보지 않고 `names no comment` 가 든 줄만 따로 훑었어요. 창 안에서 44줄이고, `comment_offset N … the thread now has N comments` 42줄, `the thread has no comments` 1줄(둘 다 `e-masc-the-leader`), `after_comment_id … names no comment` 1줄(`github-pr-checker`)이에요. 위 표의 42건과 Keeper 한 명의 43건이 모두 이 줄들에서 나와요.

## 다시 만들기

```bash
python3 docs/evidence/failed-calls-2026-11/measure_failed_calls.py \
  --base-path ~/me --since 2026-11-06T09:52:00 --until 2026-11-07T09:52:00 \
  --json-out docs/evidence/failed-calls-2026-11/result-2026-11-06_11-07.json
```

## 시험

```bash
python3 -m unittest discover -s docs/evidence/failed-calls-2026-11
```

합성 원장으로 세는 법을 확인하는 시험 11개예요. 실패 여부는 `disposition`, 창은 `ts`, 묶음은 도구와 첫 줄이에요.
