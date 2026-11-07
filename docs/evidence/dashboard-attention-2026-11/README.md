# `masc_dashboard` 결과가 레인의 inline 상한을 넘는 문제 (2026-11)

Keeper 가 부른 `masc_dashboard` 결과의 크기를 재고, Attention Required 에서 이웃한 항목이 같은 권장 행동(`-> …` 줄)을 가지면 그 행동을 한 번만 적을 때 같은 호출이 얼마나 작아졌을지 같은 원장으로 다시 계산해요.

## 왜 재나요

대시보드 텍스트는 구역으로 나뉘어요(Attention Required, Agents, Keepers, Tasks, Recent Messages). Attention Required 는 항목마다 두 줄이에요. `  [!] …` 줄 하나와, 그 항목의 권장 행동을 적은 `      -> …` 줄 하나예요. 항목은 심각도 순으로 정렬돼서 이웃한 항목이 같은 행동을 가져요.

아래 창에서 attention 항목은 호출마다 23~29개이고 run(이웃한 같은 행동의 묶음)은 2개예요. 한 run 은 stuck 에이전트(`masc_agent_timeline`) 2개이고, 다른 run 은 `held by <소유자>, which has no Keeper queue` 항목 21~27개예요. 후자는 항목마다 `inspect the task owner before choosing recovery` 줄을 되풀이해요(`lib/operator_task_attention.ml` 의 `next_step`).

결과가 레인의 inline 상한을 넘으면 모델은 `[masc:blob sha256=… preview="…"]` 표식과 200자 미리보기만 받아요(`lib/tool_blob_store/tool_output.ml`). 상한은 레인마다 달라요(`lib/runtime/runtime_execution.ml` 의 `tool_result_inline_ceiling_bytes`): codex·antigravity·muse 16,384 B(`Common.max_tool_result_wire_bytes`), claude_code 32,768 B, agent_core 65,536 B(`Common.max_agent_core_inline_result_bytes`).

## 결과 (2026-11-03T00:00Z ~ 11-07T14:00Z, UTC)

`masc_dashboard` 호출은 33건이에요(wkbl-front 25, wkbl-growth 5, wkbl-data 3). 세 Keeper 의 `official-client-runtime/session.json` 에서 `client_kind` 는 모두 antigravity 라서 inline 상한은 16,384 B 예요. 결과 크기의 합은 586,312 B 이고, 그 창의 도구 결과 532,524,855 B 의 0.11% 예요.

33건 모두 원장에 blob 으로 남아서 전체 텍스트를 읽었어요(`unreadable` 0, `not_split` 0). 원장의 `result_bytes` 는 33건 모두 16,384 B 를 넘고 32,768 B 를 넘는 호출은 0건이에요. 같은 텍스트에 이웃한 항목의 행동을 한 번만 적는 규칙을 옮겨 다시 계산했어요.

| | 최소 | p50 | 최대 | 합 |
|---|---|---|---|---|
| 지금 | 16,789 | 17,654 | 18,719 | 586,312 |
| 고친 뒤 | 15,596 | 16,441 | 17,451 | 544,264 |

| inline 상한 | 지금: 호출 | 고친 뒤: 호출 |
|---|---|---|
| 16,384 B | 33 | 18 |
| 32,768 B | 0 | 0 |
| 65,536 B | 0 | 0 |

- 줄어드는 양은 합 42,048 B(7.2%)이고 호출당 평균 1,274 B 예요. 16,384 B 아래로 내려오는 호출은 15건이고 18건은 여전히 넘어요. 가장 큰 호출은 17,451 B 로 상한보다 1,067 B 커요.
- 5개 검사가 33건 모두 통과했어요: 구역을 자른 뒤 다시 붙이면 원래 텍스트, 항목 줄이 모두 같은 순서로 남음, 행동 줄이 run 마다 하나이고 그 항목들이 제안한 행동이며 항목이 둘 이상일 때만 `(N items above)` 를 적고 이웃한 run 은 행동이 다름, 구역 밖의 줄이 그대로, 텍스트가 길어지지 않음.
- 대시보드 호출 33건의 합은 그 창 도구 결과의 0.11% 예요. 이 변경으로 줄어드는 총량보다 중요한 것은 호출 33건 중 15건이 표식 대신 텍스트를 직접 받는다는 점이에요.

### 이 변경이 건드리지 않는 것

attention 의 `held by …` 줄은 `task-N · <제목>: held by <소유자>, which has no Keeper queue` 이고(`Operator_task_attention.summary`), 같은 제목을 `== Tasks` 구역이 `[P2] <제목> (@소유자)` 로 다시 적어요. 호출마다 held 항목 21~27개(p50 23)의 제목이 Tasks 구역에 또 있고, 그 제목의 크기는 2,771~3,405 B(p50 2,938 B)예요.

- 고친 뒤 최대 크기(17,451 B)에서 반복된 제목 크기의 최솟값(2,771 B)만 빼도 14,680 B 이하라서 33건 모두 16,384 B 아래가 돼요. 이 계산은 호출별로 짝지은 값이 아니라 두 구간의 끝값을 쓴 거예요.
- `Operator_task_attention.summary` 는 TUI 의 agenda 줄(`bin/masc_tui_loader.ml`)도 써요. Tasks 구역의 줄에는 task id 가 없어서 attention 줄에서 제목을 빼면 id 와 제목을 이을 수 없어요. 그래서 이 폴더의 변경은 제목을 건드리지 않아요.

## 고친 것

- `Dashboard_attention.format_items`: 이웃한 항목이 같은 `suggested_tool` 이면 항목 줄을 모두 적고 행동 줄을 뒤에 한 번만 적어요. 항목이 둘 이상이면 `-> <행동> (N items above)` 로 적어요. 항목의 순서와 내용은 그대로예요.
- 행동이 떨어져서 두 번 나오면 두 번 적어요. 합치는 것은 이웃한 항목뿐이에요.

## 못 잰 것

- 모델이 새 모양을 받은 뒤 무엇을 하는지는 안 봤어요. `(N items above)` 가 붙은 행동 줄이 위쪽 항목 전체를 가리킨다고 모델이 읽는지는 배포 뒤에 봐야 해요.
- 원장에는 wkbl 세 Keeper 의 33건뿐이에요. 다른 Keeper 나 운영자의 대시보드 호출, claude_code·agent_core 레인의 호출은 없어요.
- 이 창에서 attention 항목은 모두 stuck 에이전트와 held 항목이었어요(run 이 호출마다 2개). `[i]` 항목이 있는 텍스트에서의 크기는 합성 텍스트로만 시험했어요.
- OCaml 시험(`test/test_dashboard_labels.ml` 의 새 시험)은 로컬에서 실행하지 않았어요. 타입 검사만 했고, `format_items` 의 순수 함수를 `ocaml` toplevel 에서 따로 돌려 시험의 기대 줄과 같은 출력을 확인했어요(이 폴더에 없어요).
- 스크립트의 `regroup` 과 OCaml `format_items` 가 저장된 텍스트에서 같은 결과를 내는지는 기계로 맞춰 보지 않았어요.

## 다시 만들기

```bash
python3 docs/evidence/dashboard-attention-2026-11/measure_dashboard_attention.py \
  --base-path ~/me --since 2026-11-03T00:00:00 --until 2026-11-07T14:00:00 \
  --json-out docs/evidence/dashboard-attention-2026-11/result-2026-11-03_11-07.json
```

원장 파일은 UTC 날짜로 잘려 있어요. 시험:

```bash
python3 -m unittest discover -s docs/evidence/dashboard-attention-2026-11
```

`regroup` 은 `Dashboard_attention.format_items` 의 접기를 저장된 텍스트의 Attention 구역에 옮긴 것이에요. 시험 36개는 합성 텍스트로 구역 자르기와 거절 이유, 접기 결과(손으로 센 바이트 수 포함), 검사 5개가 위반을 잡는지, 원장 읽기(blob 없음, 잘린 호출, 창 거르기, 불리언 시각), 상한과 같은 크기, 제목 반복 계산을 확인해요.
