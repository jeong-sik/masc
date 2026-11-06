# `keeper_artifact_read` 가 못 찾는 해시 (2026-11)

`keeper_artifact_read` 가 `artifact does not exist` 로 실패한 호출을 세고, 실패한 해시가 마커의 `answer_sha256=` 값인지 원본 기록(raw trace)과 맞춰 봐요.

## 왜 재나요

저장된 도구 결과는 모델에게 이런 한 줄로 가요.

```
[masc:blob sha256=<산출물> bytes=2517 mime=application/vnd.masc.tool-result-manifest+json answer_sha256=<답의 지문> preview=""]
```

읽을 수 있는 것은 `sha256=` 하나예요. `answer_sha256=` 는 매니페스트 안 답을 정렬한 JSON의 sha256이라서, 이 값으로 저장된 산출물을 찾을 수 없어요. 코드는 `lib/tool_blob_store/tool_output.ml` 의 `encode_for_agent_core` 와 `lib/keeper/keeper_tool_answer.ml` 의 `verified_stored_answer` 예요. 지문은 `Keeper_tool_progress_identity` 가 같은 답의 반복 호출을 같은 정체성으로 묶는 데 써요. 모델이 보는 문자열에 하네스용 값이 같이 실려 있어요.

## 결과 (2026-11-01 ~ 11-06T13:30Z, UTC)

원장 읽기 17,299건 중 299건(1.73%)이 `artifact does not exist` 로 실패했어요. 날마다 읽기 수가 크게 달라서 날짜별로 봐요.

| 날(UTC) | 읽기 | 실패 | 원본 기록으로 `answer_sha256` 임을 확인 |
|---|---|---|---|
| 11-01 | 10,070 | 96 | 0 |
| 11-02 | 6,320 | 145 | 1 |
| 11-03 | 389 | 27 | 2 |
| 11-04 | 267 | 20 | 3 |
| 11-05 | 177 | 6 | 2 |
| 11-06 (13:30Z까지) | 76 | 5 | 5 |

- 실패한 해시는 294개예요. 원본 기록이 남은 것은 14개이고, 그중 13개가 직전 Execute 결과 마커의 `answer_sha256=` 값이에요. 1개(`goo-yang-bong` 의 `ac6f6c5a…`)는 마커에서 오지 않았고 어디서 왔는지 못 찾았어요. 해시가 원본 기록에 있다는 14개라는 수와 그 1개의 출처 확인은 스크립트가 아니라 손으로 했어요. 스크립트의 `not_traced` 는 원본 기록이 없는 해시와 지문이 아닌 해시를 구별하지 않아요.
- 나머지 280개는 원본 기록이 지워져서 확인하지 못했어요. 13개로 299건 전체를 말할 수는 없어요.
- 11-06 의 5건(01:13Z, 02:53Z, 11:07Z, 11:35Z, 12:19Z)은 모두 확인됐어요. 앞의 둘은 끝난 턴의 도구 결과를 마커로 보내는 규칙(#49185, 09:50:51Z 부팅부터) 이전이에요.
- 11-03~06 에는 읽기 909건 중 58건(6.4%)이에요.

실패한 뒤 같은 Keeper 의 다음 읽기(10분 안)는 이랬어요.

| 다음 읽기 | 건수 | 몫 |
|---|---|---|
| 다른 해시로 성공 | 182 | 61% (중앙값 4.5초 뒤, p90 150.5초 뒤) |
| 같은 해시로 성공 | 21 | 7% |
| 또 실패 | 45 | 15% |
| 다른 이유로 실패 | 3 | 1% |
| 10분 안에 읽기 없음 | 48 | 16% |

같은 해시로 성공한 21건은 모두 11-02 의 `context-reviewer` 이고, `offset` 을 단 페이지 읽기를 0~3.5초 뒤 다시 해서 성공했어요. `answer_sha256` 오용이 아니라 일시 실패이고 11-03 이후에는 없어요. 원인은 보지 않았어요.

## 못 잰 것

- 실패가 낸 비용은 요청 왕복 한 번이라고 보지만, 초나 토큰으로 바꾸지 않았어요.
- "10분 안에 읽기 없음"과 "또 실패"가 읽으려던 내용을 잃은 것인지, 다른 길로 얻은 것인지는 보지 않았어요.
- 읽기 수가 11-01 에 10,070건으로 많은 까닭은 보지 않았어요.
- 마커의 `answer_sha256=` 를 모델이 어떻게 해석했는지는 모델의 생각 기록으로 보지 않았어요.

## 다시 만들기

```bash
python3 docs/evidence/artifact-read-misses-2026-11/measure_artifact_read_misses.py \
  --base-path ~/me --from-date 2026-11-01 --to-date 2026-11-06 --until 2026-11-06T13:30:00 \
  --json-out docs/evidence/artifact-read-misses-2026-11/result-2026-11-01_11-06.json
```

원장 파일은 UTC 날짜로 잘려 있어요. `--since`·`--until` 은 `ts` 로 거르고, 옵션이 없으면 `--from-date` 0시부터 `--to-date` 24시까지예요. 원본 기록은 `~/me/.masc/keepers/*/raw-traces/*.jsonl` 에서 `answer_sha256=<64자리 16진수>` 를 모두 모아 대조해요(약 5초).

시험: `python3 -m unittest discover -s docs/evidence/artifact-read-misses-2026-11` (25개). 점검용 변형 24개 중 23개를 시험이 잡았어요. 살아남은 하나는 `answer_sha256=` 를 포함하는 파일만 정규식에 넘기는 사전 거름의 문자열을 바꾼 것이고 결과가 같아요.
