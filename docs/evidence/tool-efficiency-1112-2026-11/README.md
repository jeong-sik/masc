# Tools 효율 증거: 11-12 영수증 대기 배포 전 값 (2026-11)

`docs/rfc/RFC-keeper-waits-for-its-own-github-run-in-the-same-turn.md` 가 인용하는 값을 다시 낼 수 있게 스크립트와 결과를 둬요.
스크립트는 읽기만 해요. 장부(`<base>/.masc/tool_calls/<YYYY-MM>/*.jsonl`)를 `../tool-efficiency-1110-2026-11/ledger_window.py` 로 읽고 아무것도 쓰지 않아요.

## 스크립트와 결과

| 명령 | 세는 것 | 결과 (창, UTC) |
|---|---|---|
| `sleep_waits.py share <since> <end> [base]` | Execute 호출 수, `run_in_background` 호출 수와 비율, 앞에서 60초 이상 기다린 호출과 시간, background 를 쓴 Keeper | `result-share-2026-11-09T07-40-23Z_11-12T07-40-23Z.json` |
| `sleep_waits.py shapes <since> <end> [base]` | 앞에서 60초 이상 기다린 호출의 모양(`sleep`+`gh`, `sleep` 만, 자기 background 작업 등)과 `sleep`+`gh` 가 읽은 것(Actions run, check, 리뷰, PR 상태) | `result-shapes-2026-11-09T07-40-23Z_11-12T07-40-23Z.json` |
| `sleep_waits.py turns <since> <end> [base]` | Keeper 별 `sleep`+`gh` 호출을 `keeper_turn_id` 로 묶은 턴 수, 같은 턴에서 push 뒤의 호출, 2번 이상인 턴, 한 턴 최대, `until_github_*` 일정 수 | `result-turns-2026-11-09T07-40-23Z_11-12T07-40-23Z.json` |

`test_sleep_waits.py` 는 메모리에서 만든 행으로 돌리는 시험 22개예요. 실행: `python3 docs/evidence/tool-efficiency-1112-2026-11/test_sleep_waits.py`.

## 한계

- 모양은 명령 글자로 가르는 정규식이에요. `sleep <숫자>` 의 리터럴 합이 호출 시간의 절반 이상일 때만 `sleep` 호출로 세요. 반복문 안의 `sleep` 은 `sleep` 그룹에 들고 `gh` 읽기와는 나누지 못해요.
- 세는 데만 쓰고 제품 규칙이 아니에요. `Execute` 는 명령을 해석하지 않아요.
- 창이 영수증 대기 스택 배포(11-12 16:40 KST) 전이에요. 배포 뒤 값은 같은 명령에 새 창을 넣어 읽어요.
