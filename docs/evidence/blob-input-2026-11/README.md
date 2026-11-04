# `_blob` 인자 호출 측정 (2026-11)

`measure_blob_inputs.py` 는 Keeper 가 도구 인자를 `{"_blob": ...}` 모양으로 보낸 호출을 세고, 모델에 보낸 요청에서 지난 호출의 인자가 그 모양으로 바뀌어 있는지를 재요(이슈 #47642).
`.masc` 아래의 세 저장소를 읽기만 해요.

| 저장소 | 쓰는 곳 |
|---|---|
| `tool_calls/YYYY-MM/DD[.NNN].jsonl` | 도구 호출 원장이에요. `input` 은 도구 계층이 받은 인자 객체예요 |
| `keepers/<keeper>/provider-inputs/YYYY-MM/DD.jsonl` | 턴마다 요청 하나를 저장한 기록이에요. 메시지마다 `content_ref` 가 있고, `wire.model` 이 모델 이름이에요. 같은 턴의 다른 요청은 저장하지 않아요 |
| `tool_blobs/<sha 앞 두 글자>/<sha>` | `content_ref` 가 가리키는 메시지 JSON 과, 강등된 호출의 원본 인자예요 |

## 다시 재기

```bash
docs/evidence/blob-input-2026-11/measure_blob_inputs.py --base-path ~/me \
    --from-date 2026-10-19 --to-date 2026-11-04 --until 2026-11-04T19:10:00Z --json-out after.json
```

이 폴더의 `result-2026-10-19_11-04.json` 이 위 명령의 결과예요. 원장 17일치를 읽어서 90초쯤 걸려요. 시험은 `python3 -m unittest discover -s docs/evidence/blob-input-2026-11` 로 돌려요.

## 센 방법

- `_blob` 호출: 창 안(`--from-date` 자정 UTC 부터 `--until` 까지)의 원장 행 중 `record_kind` 가 `tool_call` 이고 `input` 이 `_blob` 키를 가진 객체인 행이에요.
  - `alone`: `_blob` 이 `input` 의 유일한 키예요. `mixed`: 다른 키가 같이 있어요.
- 결과: `refused_before_run` 은 `disposition` 이 없고 `wire_outcome` 이 `error` 인 행(도구가 실행되기 전에 거절된 호출)이에요. `completed` 는 `disposition` 이 `completed` 인 행이고, 나머지는 `other` 예요.
- 봉투: `bytes`(0 이상의 정수), `mime`(공백이 없는 글), `preview`(글), `sha256`(소문자 16진수 64자) 네 필드만 있는 객체예요. OCaml 쪽 `Tool_output.normalized_artifact_ref_of_json` 이 받아들이는 모양과 같아요.
  - `_blob` 값이 봉투면 `complete_envelope`, 다른 객체면 `wrapped_arguments`(진짜 인자를 `_blob` 아래에 넣은 호출), 객체가 아니면 `not_an_object` 예요.
- 해시가 저장소에 있다: 봉투의 `sha256` 이름으로 `tool_blobs/<sha 앞 두 글자>/<sha>` 파일이 있어요. `Keeper_model_input_demotion` 이 만든 강등은 이 blob 을 항상 써요.
- 강등된 인자: 저장된 요청의 메시지에서 assistant 의 `tool_use` 블록 중 `input` 이 `_blob` 키 하나뿐이고 그 값이 봉투인 것이에요. 줄인 바이트는 봉투의 `bytes` 에서 그 객체의 압축 JSON 크기를 뺀 값이에요.
- 강등된 결과: `tool_result` 블록 중 `content` 가 `[masc:blob` 로 시작하는 것이에요. 줄인 바이트는 마커의 `bytes=` 값에서 마커 길이를 뺀 값이에요.
- 같은 크기로 저장됨: 강등된 인자의 서로 다른 해시 중 blob 파일이 있고 크기가 봉투의 `bytes` 와 같은 것이에요.
- 몫과 중앙값은 강등된 인자가 있는 요청끼리 센 값이에요. 줄인 바이트의 본문 몫은 요청마다 `줄인 바이트 ÷ wire.body_bytes` 를 구해 중앙값을 냈어요.

## 결과(10-19 ~ 11-04T19:10Z)

도구 호출 원장에서 `_blob` 호출은 2,816건이에요.

| | 호출 | 실행 전 거절 | 실행됨 | 그 밖 |
|---|---:|---:|---:|---:|
| `_blob` 하나뿐(`alone`) | 2,464 | 2,463 | 1 | 0 |
| 다른 키와 섞임(`mixed`) | 352 | 89 | 257 | 6 |

`alone` 2,464건의 `_blob` 값이에요.

| 모양 | 호출 |
|---|---:|
| 봉투(`complete_envelope`) | 1,344 |
| 진짜 인자를 `_blob` 아래에 넣음(`wrapped_arguments`) | 784 |
| 객체가 아님(`not_an_object`) | 336 |

봉투 1,344건 가운데 해시가 저장소에 있는 것은 7건이고 1,337건은 없어요.

날짜별 `alone` / `mixed` 예요(UTC, 없는 날은 0건).

| 날짜 | alone | mixed |
|---|---:|---:|
| 10-19 | 529 | 12 |
| 10-20 | 41 | 4 |
| 10-21 | 67 | 0 |
| 10-23 | 0 | 17 |
| 10-26 | 413 | 21 |
| 10-27 | 405 | 9 |
| 10-28 | 32 | 6 |
| 10-30 | 19 | 27 |
| 10-31 | 4 | 0 |
| 11-02 | 610 | 251 |
| 11-03 | 339 | 5 |
| 11-04 | 5 | 0 |

`alone` 호출이 많은 Keeper 는 `masc-productor-owner` 520, `wkbl-front` 457, `code-reviewer` 372, `context-reviewer` 270, `code-reviewer-sister` 217, `msx-retro-mania` 204, `tui-developer` 89, `code-reviewer-mother` 64건이에요. 모두 실행 전에 거절됐어요.
JSON 의 `blob_calls.alone_by_keeper` 에는 Keeper 23명 모두의 `alone` 호출 수가 있고, 없는 Keeper 는 0건이에요. 아래 표에서 GLM 으로 요청을 보낸 다섯은 `ocaml-agent-ic` 2, `wkbl-data` 61, `wkbl-web-leader` 23, `e-masc-the-leader` 0, `code-reviewer-father` 0건이에요.
도구는 `masc_board_comment` 1,221, `Write` 478, `Execute` 305, `keeper_memory_write` 154, `masc_board_post` 102, `Edit` 47, `masc_schedule_create` 31, `masc_ask` 16건이에요.

저장된 요청 5,244개 가운데 4,400개(83.9%)에 강등된 인자가 있어요. 읽지 못한 메시지는 0이에요.
강등된 인자의 서로 다른 해시는 12,855개이고, 그중 12,313개(95.8%)는 blob 이 같은 크기로 있어요.

| Keeper | 모델 | 저장된 요청 | 강등된 인자가 있는 요청 | 강등된 결과가 있는 요청 | 본문 중앙값(바이트) | 요청당 강등된 인자 중앙값 | 인자로 줄인 바이트 중앙값(본문 몫 중앙값) |
|---|---|---:|---:|---:|---:|---:|---:|
| `masc-productor-owner` | deepseek-v4.1-flash | 409 | 390 (95.4%) | 96.1% | 1,120,634 | 334 | 366,414 (29.9%) |
| `ocaml-agent-ic` | glm-5.3-flash | 373 | 355 (95.2%) | 98.7% | 1,036,594 | 231 | 88,128 (4.7%) |
| `code-reviewer` | deepseek/deepseek-v4.1-flash-1017 | 342 | 336 (98.2%) | 99.7% | 1,930,096 | 136 | 118,422 (6.1%) |
| `wkbl-front` | deepseek-v4.1-flash | 337 | 315 (93.5%) | 93.8% | 1,255,569 | 307 | 335,098 (26.2%) |
| `wkbl-data` | glm-5.3 | 344 | 302 (87.8%) | 89.0% | 1,074,235 | 290 | 159,642 (14.9%) |
| `wkbl-web-leader` | glm-5.3 | 348 | 295 (84.8%) | 98.9% | 1,409,582 | 401 | 232,355 (16.0%) |
| `e-masc-the-leader` | glm-5.3 | 265 | 262 (98.9%) | 98.9% | 1,103,284 | 267 | 110,584 (9.8%) |
| `code-reviewer-father` | glm-5.3 | 245 | 230 (93.9%) | 94.3% | 1,071,729 | 273 | 154,299 (13.0%) |
| `msx-retro-mania` | deepseek-v4.1-flash | 237 | 219 (92.4%) | 95.8% | 11,842,861 | 12 | 16,065 (0.1%) |
| `wkbl-front` | glm-5.3-flash | 220 | 209 (95.0%) | 95.9% | 797,292 | 59 | 52,529 (6.0%) |

JSON 의 `history_arguments.by_keeper_and_model` 은 강등된 인자가 있는 요청이 많은 순서의 열 줄이에요.

## 조심할 것

- 저장된 요청은 턴마다 하나라서 모델 요청의 일부예요. 어느 요청을 저장하는지는 확인하지 못했어요.
- 해시가 저장소에 없는 봉투는 모델이 지어낸 값일 수 있고, 지워진 blob 일 수도 있어요. 강등이 만든 해시의 95.8%가 같은 창에서 저장소에 있어서, 지워진 몫은 많아야 4.2%예요(저장된 요청에서 본 해시만 센 값이에요).
- 원장 행으로는 호출을 모델별로 나눌 수 없어요. 표의 모델은 저장된 요청의 `wire.model` 이에요. 같은 Keeper 가 날짜에 따라 모델을 바꿀 수 있어서 `wkbl-front` 는 두 줄이에요.
- 강등된 인자가 요청의 84%에 있는 이유는 이 측정이 가르지 않아요. 크기 거절 뒤의 재전송과 Official client host 의 턴 경계 인자 강등이 둘 다 같은 값을 만들어요(`docs/rfc/RFC-0363-historical-tool-result-demotion.md` §3.4.1).
- 시험 89개가 통과하고, 계산을 틀리게 바꾼 변형 102개를 모두 잡았어요.
