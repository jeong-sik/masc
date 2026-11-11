# Tools 효율 증거: 11-11 재측정과 긴 턴의 모양 (2026-11)

[11-08 보고서](../../reports/2026-11-08-tool-efficiency-after-the-1107-deploy.md)의 「11-11 갱신」이 인용하는 값을 다시 낼 수 있게 스크립트와 결과를 둬요.
스크립트는 읽기만 해요. 장부(`<base>/.masc/tool_calls/<YYYY-MM>/*.jsonl`)와 Keeper 작업 저장소를 읽고 아무것도 쓰지 않아요.

## 스크립트와 결과

| 스크립트 | 세는 것 | 결과 | 창 (UTC) |
|---|---|---|---|
| `long_turn_shapes.py` (이 폴더) | 턴 하나가 언급한 서로 다른 PR 수, 같은 턴에서 같은 입력이 다시 돌아 앞 호출이 된 결과의 바이트 | `result-long-turn-shapes-2026-11-08T05-40_11-11T05-40.json` | 11-08T05:40Z ~ 11-11T05:40Z (72시간) |
| `../tool-efficiency-1110-2026-11/github_wait_shapes.py` | 60초 이상 Execute 중 GitHub 를 기다리는 호출의 모양과 감시 여부 (정의는 그 폴더 README) | `result-github-wait-shapes-2026-11-08T05-40_11-11T05-40.json` | 같아요 |
| `../tool-efficiency-before-after-2026-11/queue_wait_overlap.py` | 긴 Execute 와 같은 Keeper 의 채팅 작업 큐 대기가 겹친 시간 (정의는 그 스크립트 docstring) | `result-queue-wait-overlap-2026-11-08T05-40_11-11T05-40.json` | 같아요 |
| `../execute-waits-2026-11/measure_execute_waits.py` | Execute 시간, 긴 호출이 기다리는 것, 일정으로 깨우는 호출 (정의는 그 스크립트 docstring) | `result-execute-waits-2026-11-08_11-11T05-40.json` | 11-08T00:00Z ~ 11-11T05:40Z (77.67시간) |
| `../lane-time-2026-11/measure_lane_time.py` | 턴 시간이 어디로 가는지, 모델 요청의 승인 대기 (정의는 그 폴더 README) | `result-lane-time-2026-11-08_11-11T05-40.json` | 같아요 (77.67시간) |

뒤의 두 스크립트는 `--from-date` 의 자정(UTC)부터 읽어서 창이 5.67시간 길어요. 시작을 05:40Z 로 맞추는 인자가 없어요.
`long_turn_shapes.py` 는 `../tool-efficiency-1110-2026-11/ledger_window.py` 의 장부 읽기를 써요. 시험은 합성 장부로 돌리는 18개예요.

## 정의 (`long_turn_shapes.py`)

- 창은 `[SINCE, END)` 예요. 장부 행의 `ts` 는 결과를 받은 뒤 행을 만드는 시각이라 호출이 끝난 시각과 같거나 조금 늦어요(`../tool-efficiency-1110-2026-11/README.md` 의 「정의」).
- 턴은 `trace_id` 와 `keeper_turn_id` 가 같은 행의 묶음이에요. 긴 턴은 호출이 `--long-calls`(기본 100)개 이상인 턴이에요. 이 숫자는 보고서를 나누는 데만 쓰고 어떤 규칙도 읽지 않아요. 턴당 호출 수의 중앙값, p90, 최대를 같이 적어요.
- PR 언급은 도구 입력의 JSON 글자에서 `#12345`, `/pull/12345`, `/pulls/12345`, `/issues/12345`, `gh pr <동사> 12345` 꼴로 쓴 5자리 번호예요. 글자 세기라서 명령이 그 PR 로 무엇을 했는지, 턴이 그 PR 을 리뷰했는지는 몰라요. 이슈 번호도 같이 세요. 저장소가 다른 같은 번호는 하나로 세요.
- 낡은 결과는 한 턴에서 (`tool`, `input_fingerprint`)가 같은 호출들 중 마지막을 뺀 나머지예요. `result_bytes` 가 `--min-bytes`(2,048) 이상 `--max-bytes`(65,536) 이하일 때만 세요. 두 숫자는 끝난 턴의 마커 규칙(`Keeper_turn_driver_try_provider.aged_result_min_bytes`)과 Agent Core 인라인 상한(`Common.max_agent_core_inline_result_bytes`)에서 가져온 값이고, 이 스크립트가 고른 값이 아니에요. 같은 입력이 다시 돌았다는 사건이 기준이에요. 같은 입력이 다른 결과를 돌려준 경우도 세는데, 그 경우가 이 값이 보려는 것이에요.
- 중앙값은 개수가 짝수면 가운데 둘의 평균이에요(1~10이면 5.5). p90 은 정렬한 값의 `int(n × 0.9)` 번째(끝을 넘으면 마지막)예요.
- `result_bytes` 는 장부에 적힌 결과 크기예요. 모델이 마커로만 본 결과도 장부 크기로 세요.

## 결과

### 긴 Execute 의 GitHub 기다림 (`github_wait_shapes.py`)

앞 창은 11-07T10:20Z ~ 11-10T10:20Z, 뒤 창은 11-08T05:40Z ~ 11-11T05:40Z 로 둘 다 72시간이에요.

| | 앞 창 | 뒤 창 |
|---|---:|---:|
| Execute 호출 | 61,128 | 89,771 |
| `run_in_background` 호출 | 77 (0.13%) | 124 (0.14%) |
| 60초 이상 호출 | 675 | 1,181 |
| 그중 `run_in_background` | 0 | 0 |
| GitHub 를 기다리는 호출 | 517건, 30.839 h | 926건, 61.342 h |
| `single_run` (run 하나) | 159건, 11.858 h | 340건, 24.880 h |
| `api_other` (그 밖의 `gh api`) | 167건, 9.670 h | 272건, 17.172 h |
| `commit_checks` (커밋의 check) | 72건, 3.962 h | 140건, 10.331 h |
| `pr_checks` (PR 하나) | 112건, 4.963 h | 168건, 8.615 h |
| `other` + `run_list` | 7건, 0.387 h | 6건, 0.344 h |
| `commit_checks` + `pr_checks` | 184건, 8.925 h | 308건, 18.946 h |
| `single_run` 중 같은 Keeper 가 그 run 에 감시를 걸어 둔 호출 | 10건, 1.021 h | 16건, 1.326 h |
| `single_run` 중 걸지 않은 호출 | 149건, 10.837 h | 324건, 23.554 h |
| 호출 시작 15분 안에 같은 Keeper 가 `masc_schedule_create` 를 낸 `single_run` 호출 | 12건 (`until_github_run` 이 든 것 10, 시각 없음 거절 2) | 24건 (19, 2) |

- Execute 호출은 1.47배, GitHub 기다림 시간은 1.99배예요. 뒤 창의 기다림 시간은 `single_run` 40.6%, `api_other` 28.0%, `commit_checks` 16.8%, `pr_checks` 14.0%예요.
- 뒤 창에서 감시를 걸지 않은 `single_run` 324건은 rondo 187건, masc-productor-owner 64건, wkbl-data 25건, wkbl-front 14건 순이에요.
- 두 창의 Keeper 와 일이 달라서 늘어난 몫을 어떤 변경의 효과로 읽지 않아요.

### 큐 대기와 겹침 (`queue_wait_overlap.py`, `--hold-s 60`)

| | 앞 창 (11-07T10:20Z ~ 11-10T10:20Z) | 뒤 창 (11-08T05:40Z ~ 11-11T05:40Z) |
|---|---:|---:|
| 60초 이상 Execute | 676호출, Keeper 23명, 38.690 h | 1,183호출, Keeper 24명, 74.214 h |
| 그 시간 중 같은 Keeper 의 채팅 작업이 하나라도 기다린 시간 (Keeper 경과 시간, 중복 없음) | 6.473 h (16.7%) | 15.519 h (20.9%) |
| 큐 대기 (모든 Keeper) | 820작업, 110.367 h | 1,466작업, 196.340 h |
| 큐 대기 중 같은 Keeper 의 긴 Execute 안에 든 몫 (작업별 합) | 12.383 h (11.2%) | 42.457 h (21.6%) |

- 작업별 합은 같은 Keeper 의 두 작업이 함께 기다리면 그 시간이 두 번 들어가서 Keeper 경과 시간이 아니에요. Keeper 경과 시간은 위 둘째 줄이에요.
- 뒤 창에서 작업별 합이 큰 Keeper 는 rondo 29.759 h(70.1%, 긴 Execute 330호출 21.164 h, 그중 기다리는 작업이 있던 시간 9.105 h), code-reviewer-father 4.233 h(35호출 2.053 h, 0.979 h), wkbl-data 3.078 h(164호출 7.927 h, 1.694 h)예요.
- 두 값 모두 관측된 겹침이고 비동기로 바꿨을 때 줄어드는 시간이 아니에요. 긴 Execute 가 끝난 뒤에 도착해 밀린 큐를 같이 기다린 작업은 더해질 것이고, 명령 뒤에 이어 가는 턴의 모델 시간은 뺄 것이에요.

### 턴 시간 (`measure_lane_time.py`)

| | 11-01 ~ 11-04T19:10Z (91.17시간, 기존 결과) | 11-08 ~ 11-11T05:40Z (77.67시간) |
|---|---:|---:|
| 턴 (trace 파일이 있는 Keeper 28명) | 9,872 | 8,131 |
| 도구가 실행된 시간 (턴 시간 대비) | 11.2% | 14.0% |
| 호출 사이 시간 | 57.0% | 53.8% |
| 나머지 | 31.9% | 32.1% |
| 그중 Execute | 10.4% | 12.9% |
| 그중 60초 이상 Execute | 5.1% | 6.8% |
| 그중 폴링(명령에 `sleep`, `for ... in`, `while`, `until`) | 4.0% | 6.2% |
| 같은 결과 재조회 | 2.7% | 2.5% |
| 모델 요청의 승인 대기 | 23,943번, 중앙값 35.9초, p90 194.8초, 합 479.6 h | 17,572번, 중앙값 9.9초, p90 126.3초, 합 204.6 h |
| 턴이 취소된 작업 | 106 | 2 |

- 몫은 모두 턴 안에서 센 시간을 턴이 도는 시간으로 나눈 값이에요(정의는 `../lane-time-2026-11/README.md` 의 「센 방법」). 창이 다르고 활동이 달라서 변경의 효과로 읽지 않아요.

### Execute 기다림 (`measure_execute_waits.py`)

11-08T00:00Z ~ 11-11T05:40Z (77.67시간):

- Execute 91,143호출 140.56 h 중 60초 이상이 1,184호출 74.37 h 이고, 그중 명령에 `sleep` 이 든 호출이 61.12 h, `gh` 를 부르거나 run 번호를 담은 호출(github call)이 948호출 62.31 h 예요.
- run 번호를 담은 `sleep` 호출(poll)이 한 Keeper 안에서 같은 run 을 기다린 묶음(run wait)은 268개이고, poll 호출 386번이 붙든 시간은 24.69 h(Execute 시간의 17.6%)예요. 한 묶음의 poll 은 중앙값 1번, p90 3번이에요.
- 성공한 `masc_schedule_create` 는 464건이에요. 그중 Keeper 가 자기 자신을 깨우는 일정이 459건이고, 메시지에 run 번호가 든 일정이 238건이에요. 그 238건의 `due_in_sec` 은 중앙값 2,700초(p10 900초, p90 5,700초)예요.

### 긴 턴의 모양 (`long_turn_shapes.py`)

11-08T05:40Z ~ 11-11T05:40Z. 턴 8,017개, 호출 141,353개예요. 턴당 호출 수는 중앙값 6, p90 43, 최대 833이에요. 호출이 100개 이상인 턴 164개가 호출의 23.3%(32,899개)를 차지해요.

| Keeper | 턴 | 호출 | 긴 턴 | 긴 턴의 호출 (몫) | 긴 턴당 서로 다른 PR 수 (중앙값 / p90 / 최대) | 짧은 턴당 PR 수 (중앙값) |
|---|---:|---:|---:|---:|---|---:|
| rondo | 121 | 9,702 | 24 | 5,702 (58.8%) | 10 / 28 / 176 | 4 |
| context-reviewer | 376 | 12,926 | 23 | 4,853 (37.5%) | 24 / 54 / 69 | 3 |
| wkbl-data | 182 | 7,680 | 22 | 4,421 (57.6%) | 0 / 0 / 0 | 0 |
| masc-productor-owner | 148 | 7,562 | 15 | 3,899 (51.6%) | 13 / 25 / 32 | 3 |
| wkbl-front | 212 | 8,573 | 15 | 3,003 (35.0%) | 0 / 0 / 0 | 0 |
| wkbl-web-leader | 225 | 5,587 | 8 | 2,125 (38.0%) | 0 / 0 / 0 | 0 |
| code-reviewer-uncle | 585 | 12,723 | 13 | 1,994 (15.7%) | 5 / 16 / 20 | 1 |
| msx-retro-mania | 214 | 6,307 | 8 | 1,350 (21.4%) | 0 / 0 / 0 | 0 |

- 위 여덟 Keeper 가 긴 턴 호출의 83.1%(27,347개)예요.
- PR 번호가 입력에 나오는 네 Keeper(rondo, context-reviewer, masc-productor-owner, code-reviewer-uncle)의 긴 턴이 긴 턴 호출의 50.0%(16,448개)예요. 이 Keeper 들은 긴 턴 하나에서 PR 을 여러 개 다뤄요. `context-reviewer` 는 중앙값 24개, 최대 69개예요.
- wkbl-data, wkbl-front, wkbl-web-leader, msx-retro-mania 의 긴 턴에는 PR 번호가 거의 없어요. 이 턴들이 무엇을 단위로 도는지는 이 값으로 알 수 없어요.

낡은 결과(`result_bytes` 2,048 ~ 65,536 바이트인 호출):

| | 값 |
|---|---:|
| 범위 안의 결과 바이트 | 346,298,022 |
| 같은 턴에서 같은 입력이 다시 돌아 앞 호출이 된 몫 | 34,686,650 (10.0%), 3,085호출 |
| 도구별 | `masc_dos_press` 21,360,685, `masc_dos_step` 3,835,748, `masc_dos_screen` 2,944,629, `keeper_artifact_read` 1,887,311, `BrowserRead` 1,180,536, `masc_board_post_get` 1,010,215 |
| Keeper 별 | msx-retro-mania 28,326,116 (81.7%), code-reviewer-uncle 1,668,068, wkbl-front 748,081, ocaml-agent-ic 612,294, kidsnote-slack-reader 564,197, code-reviewer-sister 410,814 |

- `masc_dos_*` 세 도구가 낡은 결과 바이트의 81.1%예요. 한 Keeper(msx-retro-mania)가 대부분이라서 다른 Keeper 의 일에는 옮겨지지 않아요.
- 이 도구들이 바이트를 만드는 이유는 확인하지 못했어요. 이전 보고서의 측정(11-06 ~ 11-09)은 이 도구의 blob 을 읽은 호출이 0번이라고 적었어요.

## 스크립트 밖에서 센 값

`keeper_skill` 도구의 description 크기예요. 저장소에 스크립트를 두지 않았어요.

- 읽은 것: 11-11 에 `<base>/.masc/keepers/<keeper>/provider-inputs/2026-11/11.jsonl` 이 있는 Keeper 의 마지막 요청 한 줄이에요. 그중 `tool_schemas` 에 `keeper_skill` 이 든 Keeper 가 18명이에요. 그 항목의 `artifact.content_ref` 에서 `sha256=` 값을 꺼내 `<base>/.masc/tool_blobs/<앞 두 자리>/<sha256>` 를 읽고, JSON 의 `description` 을 UTF-8 바이트로 셌어요.
- 값: description 은 최소 19,565 B, 중앙값과 최대 19,997 B 이고 서로 다른 설명이 두 종류예요. 큰 쪽은 머리말 1,013 B 와 스킬 48행이에요. 행 바이트는 중앙값 346, p90 623, 최대 841이고 행 18개가 행 바이트의 절반이에요. 행은 `{"source_id":…,"package_id":…,"name":…}: <설명>` 꼴이고 `}: ` 앞의 identity 부분이 48행 합 4,956 B(행 바이트의 26.2%)예요. 48행 모두 name 과 package_id 가 같고, 6행의 source_id 는 `lane-<64자리 16진수>` 예요.
- 한계: 11-11 의 마지막 요청만 봤어요. 파일이 사라지거나 바뀌면 같은 값을 다시 내지 못해요. 스킬 목록이 Keeper 마다 다를 수 있는데 이 요청들은 두 종류뿐이었어요. 이 설명이 요청마다 모델에게 실제로 몇 토큰이 되는지는 안 쟀어요.

## 다시 내는 법

```
python3 -I docs/evidence/tool-efficiency-1111-2026-11/long_turn_shapes.py --base-path ~/me --since 2026-11-08T05:40:00Z --end 2026-11-11T05:40:00Z --json-out <경로>
python3 -I docs/evidence/tool-efficiency-1110-2026-11/github_wait_shapes.py 2026-11-08T05:40:00Z 2026-11-11T05:40:00Z ~/me
python3 docs/evidence/tool-efficiency-before-after-2026-11/queue_wait_overlap.py --base-path ~/me --since 2026-11-08T05:40:00 --end 2026-11-11T05:40:00 --hold-s 60 --json-out <경로>
python3 -I docs/evidence/execute-waits-2026-11/measure_execute_waits.py --base-path ~/me --from-date 2026-11-08 --to-date 2026-11-11 --until 2026-11-11T05:40:00Z --json-out <경로>
python3 -I docs/evidence/lane-time-2026-11/measure_lane_time.py --base-path ~/me --from-date 2026-11-08 --to-date 2026-11-11 --until 2026-11-11T05:40:00Z --json-out <경로>
python3 -B -m unittest discover -s docs/evidence/tool-efficiency-1111-2026-11
```

`github_wait_shapes.py` 는 결과를 표준 출력에 찍어서 `> <경로>` 로 저장해요. `queue_wait_overlap.py` 는 같은 폴더의 `measure_before_after.py` 를 불러서 `-I` 로 못 돌려요.
장부는 오래된 날 파일을 지우므로 같은 창을 나중에 다시 재면 값이 달라질 수 있어요.

## 확인한 것

- 시험 18개가 합성 장부에서 통과했어요. 창의 경계, PR 언급이 되는 글자 꼴과 안 되는 꼴(4자리, 6자리 이상, 접두어 없는 번호), 낡은 결과의 바이트 경계(2,047 / 2,048 / 65,536 / 65,537), 마지막 호출을 시각으로 고르기, 지문이 없는 호출, 같은 지문의 다른 도구, 같은 `keeper_turn_id` 의 다른 `trace_id`, Keeper 순서와 동점 처리, `--top`, 중앙값·p90·최대를 담아요.
- 변이 35개(정규식 자릿수와 접두어, 바이트 경계, 마지막·처음 고르기, 정렬 키, 집계 키 바꾸기, 분모 바꾸기 등)를 로컬에서 하나씩 넣어 돌렸고 모두 시험이 잡았어요. 처음에는 5개가 살아남았고 시험을 더해 잡았어요. 변이를 넣는 스크립트는 저장소에 없어서 이 문장은 저자 보고예요.
- 이 과정에서 `quantiles` 가 중앙값을 정수로 잘라 짝수 개수에서 0.5 낮게 적던 것을 고쳤어요. 영향은 `masc-productor-owner` 의 턴당 호출 수 중앙값(27에서 27.5)과 `msx-retro-mania` 의 것(17에서 17.5) 둘뿐이고 위 표의 값은 그대로예요.
- `measure_lane_time.py` 의 `--until` 은 시간대 없는 값을 기기의 지역 시간(이 기기는 KST)으로 읽었어요. `measure_execute_waits.py` 는 UTC 로 읽어서 두 스크립트가 같은 인자에 다른 창을 줬어요. UTC 로 읽도록 고치고, `TZ=Asia/Seoul` 로 고정한 시험을 더했어요. 기존 결과 두 개(`result-2026-11-01_11-04.json`, `result-2026-11-01_11-05.json`)는 `Z` 를 붙여 돌려서 창이 맞아요(91.17시간, 101.0시간). 이번 결과도 `Z` 를 붙여 다시 냈어요. 처음 낸 값은 창이 68.67시간이어서 버렸어요.
- `lane-time-2026-11` 의 시험 96개와 이 폴더의 시험 18개가 통과했어요.

## 못 한 것과 모르는 것

- 긴 Execute 수가 세 스크립트에서 달라요(1,181 / 1,183 / 1,184). `github_wait_shapes.py` 는 행의 `ts` 가 창 안인 호출, `queue_wait_overlap.py` 는 호출 구간(`ts - duration_ms / 1000` 에서 `ts`)이 창과 닿는 호출, `measure_execute_waits.py` 는 5.67시간 긴 창의 호출을 세요.
- 큐 대기 값은 같은 창을 다시 재면 달라져요. Keeper 작업 저장소에서 아직 시작 안 한 작업이 나중에 시작하면 그 대기가 더해져요. 같은 창에서 기다리는 작업이 있던 시간이 15.087 h 였다가 다시 쟀을 때 15.519 h 였고, 이 폴더의 결과 파일은 뒤 값이에요. 읽지 못한 큐 저장소가 하나 있어요(결과의 `unreadable_stores` 에 든 `tool_usage`).
- PR 언급은 5자리 번호만 세요. masc 의 PR 은 5자리라서 맞지만 다른 저장소의 4자리 번호는 빠지고, 5자리 이슈 번호는 PR 처럼 들어가요.
- 긴 턴에서 PR 을 여럿 다루는 것과 PR 마다 리뷰를 끝낸 것은 달라요. 서로 다른 PR 수는 그 턴이 입력에 적은 번호의 수예요.
- wkbl-*, msx-retro-mania 의 긴 턴이 무엇을 단위로 도는지는 몰라요.
- 낡은 결과 바이트가 모델의 요청에 실제로 실린 크기인지는 안 쟀어요. 장부 크기예요. 같은 입력이 다른 결과를 줬는지(`output_fingerprint`)도 가르지 않았어요.
- `masc_dos_*` 의 `screen_text` 같은 큰 결과를 줄이면 모델 요청이나 시간이 얼마나 줄어드는지는 안 쟀어요.
- 승인 대기가 줄고(합 479.6 h 에서 204.6 h) 취소된 작업이 줄어든(106에서 2) 이유는 이 값들로 가르지 못해요. 창의 길이와 Keeper 의 일이 달라요.
- GitHub 기다림의 모양은 명령 글자로만 갈랐어요. `gh` 를 거치지 않는 기다림은 세지 않아요(`../tool-efficiency-1110-2026-11/README.md` 의 「못 한 것과 모르는 것」과 같아요).
- 이 값들만으로 비동기 Execute 가 줄이는 Keeper 시간은 정할 수 없어요.
- `Test` 워크플로는 안 돌렸어요. 스크립트 시험은 로컬에서 돌렸어요.
