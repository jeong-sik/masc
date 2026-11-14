# Tools 효율 증거: 11-12 영수증 대기 배포 전 값 (2026-11)

`docs/rfc/RFC-keeper-waits-for-its-own-github-run-in-the-same-turn.md` 가 인용하는 값을 다시 낼 수 있게 스크립트와 결과를 둬요.
스크립트는 읽기만 해요. 장부(`<base>/.masc/tool_calls/<YYYY-MM>/*.jsonl`)를 `../tool-efficiency-1110-2026-11/ledger_window.py` 로 읽고 아무것도 쓰지 않아요.

## 스크립트와 결과

| 명령 | 세는 것 | 결과 (창, UTC) |
|---|---|---|
| `sleep_waits.py share <since> <end> [base]` | Execute 호출 수, `run_in_background` 호출 수와 비율, 앞에서 60초 이상 기다린 호출과 시간, background 를 쓴 Keeper | `result-share-2026-11-09T07-40-23Z_11-12T07-40-23Z.json` |
| `sleep_waits.py shapes <since> <end> [base]` | 앞에서 60초 이상 기다린 호출의 모양(`sleep`+`gh`, `sleep` 만, 자기 background 작업 등)과 `sleep`+`gh` 가 읽은 것(Actions run, check, 리뷰, PR 상태) | `result-shapes-2026-11-09T07-40-23Z_11-12T07-40-23Z.json` |
| `sleep_waits.py turns <since> <end> [base]` | Keeper 별 `sleep`+`gh` 호출을 `keeper_turn_id` 로 묶은 턴 수, 같은 턴에서 push 뒤의 호출, 2번 이상인 턴, 한 턴 최대, `until_github_*` 일정 수. 호출 하나의 리터럴 `sleep` 합의 p10·p50·p90(`literal_sleep_s`). 호출이 가장 많은 턴의 id, 첫 호출이 시작한 때부터 마지막 호출이 끝난 때까지의 시간, 호출 시간의 합(`busiest_turn`) | `result-turns-2026-11-09T07-40-23Z_11-12T07-40-23Z.json` (`literal_sleep_s`·`busiest_turn` 이 든 결과는 아직 커밋되지 않았어요) |
| `sleep_waits.py kinds <since> <end> [base]` | `turn_kind` 별 Execute 호출, `sleep`+`gh` 호출, 반복 조회(반복문 안에서 GitHub 를 읽는 호출)와 그 시간, Keeper 별 GitHub 대기. 반복 조회가 읽은 것(`loop_sleep_gh_calls_by_what_gh_reads`). `turn_kind` 별 `masc_schedule_create` 호출과 그중 `until_github_*` 를 쓴 호출(`schedule_create_calls_by_turn_kind`, `until_github_schedule_create_calls_by_turn_kind`) | `result-kinds-2026-11-09T07-40-23Z_11-12T07-40-23Z.json` (뒤의 세 필드가 든 결과는 아직 커밋되지 않았어요) |

`test_sleep_waits.py` 는 메모리에서 만든 행으로 돌리는 시험이에요. 실행: `python3 docs/evidence/tool-efficiency-1112-2026-11/test_sleep_waits.py`.

## 다시 내는 명령

장부가 있는 기계의 저장소 루트에서 돌려요. 결과 파일 하나에 명령 하나예요.

```sh
python3 -I docs/evidence/tool-efficiency-1112-2026-11/sleep_waits.py share 2026-11-09T07:40:23Z 2026-11-12T07:40:23Z ~/me > docs/evidence/tool-efficiency-1112-2026-11/result-share-2026-11-09T07-40-23Z_11-12T07-40-23Z.json
python3 -I docs/evidence/tool-efficiency-1112-2026-11/sleep_waits.py shapes 2026-11-09T07:40:23Z 2026-11-12T07:40:23Z ~/me > docs/evidence/tool-efficiency-1112-2026-11/result-shapes-2026-11-09T07-40-23Z_11-12T07-40-23Z.json
python3 -I docs/evidence/tool-efficiency-1112-2026-11/sleep_waits.py turns 2026-11-09T07:40:23Z 2026-11-12T07:40:23Z ~/me > docs/evidence/tool-efficiency-1112-2026-11/result-turns-2026-11-09T07-40-23Z_11-12T07-40-23Z.json
python3 -I docs/evidence/tool-efficiency-1112-2026-11/sleep_waits.py kinds 2026-11-09T07:40:23Z 2026-11-12T07:40:23Z ~/me > docs/evidence/tool-efficiency-1112-2026-11/result-kinds-2026-11-09T07-40-23Z_11-12T07-40-23Z.json
python3 -I docs/evidence/tool-efficiency-1112-2026-11/sleep_waits.py kinds 2026-11-13T00:48:28Z 2026-11-13T05:27:07Z ~/me > docs/evidence/tool-efficiency-1112-2026-11/result-kinds-2026-11-13T00-48-28Z_11-13T05-27-07Z.json
```

마지막 줄은 RFC 5.3 의 배포 뒤 4.64시간이에요.

## 한계

- 모양은 명령 글자로 가르는 정규식이에요. `sleep <숫자>` 의 리터럴 합이 호출 시간의 절반 이상일 때만 `sleep` 호출로 세요. `shapes` 에서 반복문 안의 `sleep` 은 `sleep` 그룹에 들어요. `kinds` 는 그중 GitHub 를 읽는 호출을 반복 조회로 따로 세요.
- p10·p50·p90 은 가장 가까운 순위(nearest rank)로 골라요. 그래서 늘 어떤 호출이 가진 값이고, 호출 수가 짝수면 p50 은 가운데 두 값 중 작은 쪽이에요.
- 행의 `ts` 는 호출이 끝난 때라서 호출의 시작은 `ts - duration_ms / 1000` 으로 어림해요(`../tool-efficiency-1110-2026-11/ts_position.py`). `busiest_turn` 의 시간이 이 어림을 써요.
- `keeper_turn_id` 가 없는 행은 그 Keeper 의 `None` 이라는 한 턴으로 묶여요.
- 세는 데만 쓰고 제품 규칙이 아니에요. `Execute` 는 명령을 해석하지 않아요.
- 창이 영수증 대기 스택 배포(11-12 16:40 KST) 전이에요. 배포 뒤 값은 같은 명령에 새 창을 넣어 읽어요.
