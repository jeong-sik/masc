# Tools 효율 증거: 11-10 배포 뒤 값 (2026-11)

[11-08 보고서](../../reports/2026-11-08-tool-efficiency-after-the-1107-deploy.md)의 「11-10 갱신」이 인용하는 값을 다시 낼 수 있게 스크립트와 결과를 둬요.
스크립트는 읽기만 해요. 장부(`<base>/.masc/tool_calls/<YYYY-MM>/*.jsonl`)와 Keeper 작업 저장소를 읽고 아무것도 쓰지 않아요.

## 스크립트와 결과

| 스크립트 | 세는 것 | 결과 (창, UTC) |
|---|---|---|
| `artifact_read_refusals.py` | `keeper_artifact_read` 의 `artifact does not exist` 거절, 거절된 `sha256` 이 답 지문인지, 거절 뒤 300초 안의 다음 읽기 | `result-artifact-read-refusals-2026-11-07T09-30_11-10T09-30.json` |
| `schedule_until_run.py` | `until_github_run` 을 담은 `masc_schedule_create` 중 시각이 없어 거절된 호출과 180초 안의 다음 호출 | `result-schedule-until-run-2026-11-07T10-20_11-10T10-20.json` |
| `github_wait_shapes.py` | 60초 이상 Execute 중 GitHub 를 기다리는 호출의 모양, 그 호출이 `run_in_background` 였는지, 같은 Keeper 가 그 run 에 `until_github_run` 을 걸었는지 | `result-github-wait-shapes-2026-11-07T10-20_11-10T10-20.json` |
| `ts_position.py` | 같은 턴에서 이어진 Execute 쌍(앞 호출 60초 이상, 뒤 호출 20초 이하)에서 두 행의 `ts` 간격이 앞 호출 시간보다 짧은 쌍과 뒤 호출 시간보다 짧은 쌍 | `result-ts-position-2026-11-07T10-20_11-10T10-20.json` |
| `../tool-efficiency-before-after-2026-11/queue_wait_overlap.py` | 같은 창에서 긴 Execute 와 같은 Keeper 의 채팅 작업 큐 대기가 겹친 시간 | `result-queue-wait-overlap-2026-11-07T10-20_11-10T10-20.json` |

`ledger_window.py` 는 넷이 같이 쓰는 장부 읽기예요. `test_tool_efficiency_1110.py` 는 합성 장부로 돌리는 시험 41개예요.
11-10 배포 뒤 대시보드 집계와 장부를 견준 결과는 `../tool-metrics-refused-calls-2026-11/store-vs-ledger-after-2026-11-10T08-01_10-10.json` 이에요.

## 정의

- 창은 `[SINCE, END)` 예요. 장부 행의 `ts` 는 결과를 받은 뒤 행을 만드는 시계(`lib/keeper_tool_call_log.ml` 의 `Time_compat.now ()`, 이때 `duration_ms` 는 이미 정해져 있어요)라서 호출이 끝난 시각과 같거나 조금 늦어요. 창은 그 안에서 행이 만들어진 호출을 담고, 호출이 시작한 때는 `ts - duration_ms / 1000` 으로 어림해요(`queue_wait_overlap.py` 가 같은 약속을 써요). 이 읽기를 받치는 값은 아래 「결과」의 `ts_position.py` 예요.
- 거절 뒤 후속 호출(`artifact_read_refusals.py` 300초, `schedule_until_run.py` 180초)은 창 끝을 넘어서도 읽어요. 세는 대상은 창 안의 호출뿐이에요. 창 끝 직전 거절의 후속 호출이 창 밖에 있어도 `none` 으로 치지 않아요.
- 긴 Execute 는 `duration_ms` 가 60초 이상인 행이에요. GitHub 를 기다리는 호출은 명령 글자가 `gh run watch|view`, `gh pr checks|view|status`, `gh api`, `--watch` 중 하나와 맞는 호출이에요. 글자 맞춤이라 명령 안의 `gh` 가 무엇을 하는지는 몰라요.
- 모양은 위에서부터 처음 맞는 하나예요: `single_run`(run 번호가 글자로 있음, `until_github_run` 이 받을 수 있어 보이는 기다림), `commit_checks`, `pr_checks`, `run_list`, `api_other`, `watch_other`, `other`(run 번호가 셸 변수에 있는 경우 등).
- `watched_by_same_keeper` 는 같은 Keeper 가 그 run 번호로 `until_github_run` 을 담아 `completed` 가 된 `masc_schedule_create` 를 호출이 끝나기 전에 낸 경우예요. 감시는 창 시작 6시간 전부터 읽어요.
- `schedule_create_in_prior_15_min` 은 호출이 시작하기 전 15분 안에(그 호출의 시작 이하) 같은 Keeper 가 시작한 `masc_schedule_create` 가 있었던 호출 수예요. create 의 시작도 `ts - duration_ms / 1000` 으로 잡아요.

## 결과

`keeper_artifact_read` (11-07 09:30Z ~ 11-10 09:30Z, 72시간): 4,342건 중 108건(2.49%)이 `artifact does not exist` 로 거절됐어요. 그중 102건은 넘긴 `sha256` 이 같은 Keeper 의 앞선 행의 `output_fingerprint` 와 같았어요. 거절 뒤 300초 안에 다른 `sha256` 로 성공한 읽기가 66건(중앙값 5.5초, p90 64.6초), 같은 값 반복이 9건, 다른 오류가 24건, 읽기가 없는 경우가 9건이에요. (#51082 의 기준선이에요.)

`masc_schedule_create` (11-07 10:20Z ~ 11-10 10:20Z, 72시간): `until_github_run` 을 담은 226건 중 188건이 성공했고 24건(10.62%)이 시각 없음으로 거절됐어요. 24건 모두 `due_in_sec`, `due_at_iso`, `due_at_unix` 가 입력에 없었어요. 같은 Keeper 의 다음 `masc_schedule_create` 가 180초 안에 성공한 경우가 18건, 실패가 2건, 호출이 없는 경우가 4건이에요. (#51107 의 기준선이에요.)

Execute 의 긴 대기 (같은 창):

- Execute 61,128건 중 `run_in_background` 가 77건(0.13%)이고, 60초 이상 675건 중에는 0건이에요.
- 60초 이상 중 GitHub 를 기다리는 호출이 517건, 30.839 h 예요. 모양별로 `single_run` 159건 11.858 h(38.5%), `api_other` 159건 9.487 h(30.8%), `pr_checks` 120건 5.145 h(16.7%), `commit_checks` 72건 3.962 h(12.9%), 나머지 `other` 4건과 `run_list` 3건이 0.387 h 예요.
- `single_run` 159건 중 같은 Keeper 가 그 run 에 `until_github_run` 을 걸어 둔 호출은 10건(1.021 h)이고 149건(10.837 h)은 걸지 않았어요. 걸지 않은 호출은 rondo 78건, masc-productor-owner 23건, github-pr-checker 18건, wkbl-data 8건이에요. 호출 시작 15분 안에 같은 Keeper 가 `masc_schedule_create` 를 낸 호출은 159건 중 12건(`until_github_run` 이 든 것 10건, 시각 없음 거절 2건)이에요.
- 긴 Execute(≥60초) 676호출·38.69 h 중 같은 Keeper 의 채팅 작업이 기다리고 있던 시간이 6.473 h(16.7%)예요. 큐 대기 820작업·110.367 h(모든 Keeper) 중 같은 Keeper 의 긴 Execute 안에 든 몫이 12.383 h(11.2%)예요. 가장 큰 Keeper 는 rondo(겹침 5.808 h, 긴 Execute 166호출 10.194 h)와 code-reviewer-father(겹침 3.584 h, 30호출 1.785 h)예요. 11-05 ~ 11-08 87.5시간 창의 같은 몫은 큐 대기 122.10 h 중 3.53 h(2.9%)였어요.

`ts` 의 위치 (같은 창): 같은 턴에서 이어진 Execute 쌍(앞 호출 60초 이상, 뒤 호출 20초 이하) 173쌍 중 116쌍은 두 행의 간격이 앞 호출 시간보다 짧았어요. `ts` 가 호출의 시작이라면 일어날 수 없는 일이에요. 간격이 뒤 호출 시간보다 짧은 쌍은 0쌍이라 `ts` 가 끝(또는 끝 직후)이라는 읽기와는 맞아요. 나머지 57쌍은 간격이 앞 호출 시간 이상이라 두 읽기를 가르지 못해요.

## 다시 내는 법

```
python3 -I docs/evidence/tool-efficiency-1110-2026-11/artifact_read_refusals.py 2026-11-07T09:30:00Z 2026-11-10T09:30:00Z ~/me
python3 -I docs/evidence/tool-efficiency-1110-2026-11/schedule_until_run.py 2026-11-07T10:20:00Z 2026-11-10T10:20:00Z ~/me
python3 -I docs/evidence/tool-efficiency-1110-2026-11/github_wait_shapes.py 2026-11-07T10:20:00Z 2026-11-10T10:20:00Z ~/me
python3 -I docs/evidence/tool-efficiency-1110-2026-11/ts_position.py 2026-11-07T10:20:00Z 2026-11-10T10:20:00Z ~/me
python3 docs/evidence/tool-efficiency-before-after-2026-11/queue_wait_overlap.py --base-path ~/me --since 2026-11-07T10:20:00 --end 2026-11-10T10:20:00 --json-out <경로>
python3 -I docs/evidence/tool-efficiency-1110-2026-11/test_tool_efficiency_1110.py
```

배포 뒤 확인은 같은 명령에 배포 뒤 창을 넣어요. 호출이 적은 두 값은 최소 하루, 가능하면 3일을 둬요.

- #51082 가 배포되면 `artifact_read_refusals.py` 의 `refusal_rate` 가 2.49% 보다, `cause.answer_fingerprint` 몫(102/108)이 94% 보다 낮아야 해요.
- #51107 이 배포되면 `schedule_until_run.py` 의 `missing_due_rate` 가 10.62% 보다 낮아야 해요.

## 확인한 것

- 시험 41개가 합성 장부에서 통과했어요. 창의 경계(끝은 안 포함), 오래된 파일 건너뛰기, 지문이 같은 Keeper 의 앞선 행일 때만 원인으로 세기, 300초와 180초 경계, 창 끝 뒤의 후속 호출 읽기(스크립트를 실제로 실행해서도 확인해요), 감시가 호출 뒤에 걸렸거나 실패했거나 다른 Keeper 의 것일 때, 정확히 60초인 호출, create 시작 시각 기준의 15분 경계 양쪽, `ts_position.py` 의 쌍 고르기와 경계를 담아요.
- 변이 50개(비교 방향, 경계 상수, 조건 빼기, 키 바꾸기)를 하나씩 넣어서 모두 시험이 잡았어요. 처음에 살아남은 7개는 시험을 더해서 잡았어요(완료로 적힌 거절 행, 같은 지문이 두 번 나오는 행, create 시작 시각 비교 둘, 같은 trace 와 turn 을 쓰는 다른 Keeper, id 가 하나만 빠진 행, 두 Execute 사이에 낀 다른 도구 행).
- 기준선 세 값은 #51082 와 #51107 본문에 적은 값과 같은 창에서 같은 수가 나와요(4,342 / 108 / 102, 226 / 24).

## 못 한 것과 모르는 것

- `ts_position.py` 는 한 턴의 Execute 가 차례로만 돈다는 가정에 기대요(11-08 보고서의 `batch_size` 1 결과). 행을 만드는 시계와 호출이 실제로 끝난 시각의 차이(로깅 지연)는 안 쟀어요.
- 큐 대기 값은 창이 같아도 다시 재면 달라져요. Keeper 작업 저장소에서 아직 시작 안 한 작업이 나중에 시작하면 그 대기가 더해져요. 같은 창을 11-10 19:3x KST 와 19:51 KST 에 쟀더니 겹침이 12.228 h 와 12.383 h 였고, 이 폴더의 결과 파일은 뒤 값이에요.
- 긴 Execute 수가 두 스크립트에서 달라요(675 와 676). 창 가장자리 호출을 다루는 방식이 달라서일 것으로 보지만 어느 호출인지는 안 가렸어요.
- GitHub 기다림의 모양은 명령 글자로만 갈랐어요. 같은 글자가 다른 일을 할 수 있고, `gh` 를 거치지 않는 기다림(파이썬 스크립트 안의 HTTP 호출 등)은 세지 않아요.
- `watched_by_same_keeper` 는 장부의 `masc_schedule_create` 입력만 봐요. 서버가 그 감시를 실제로 돌렸는지, GitHub 읽기 계정이 그 run 을 볼 수 있었는지는 안 봤어요.
- 호출 시작 15분 안의 `masc_schedule_create` 수는 두 호출 사이에 관계가 있다는 증거가 아니에요. 같은 Keeper 가 같은 시간대에 둘 다 했다는 것만 말해요.
- 긴 대기를 비동기로 바꾸면 줄어드는 시간은 이 값으로 못 정해요. 겹침 12.383 h 는 상한에 가깝고, 명령이 끝난 뒤 이어 가는 턴의 모델 시간이 더해져요.
- 모델 입력에서 `answer_sha256=` 문자열을 직접 찾은 표본은 없어요.
- `Test` 워크플로는 안 돌렸어요. 스크립트 시험은 로컬에서 `python3 -I` 로 돌렸어요.
