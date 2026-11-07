# 블록으로 온 도구 결과를 마커로 바꾸면 줄어드는 바이트, 이번 턴의 시작 (2026-11-06)

RFC-0363 §3.1.2 와 Librarian RFC §4.10 의 7·8 을 저장된 기록에 재생해요. 스크립트는 `.masc` 를 읽기만 해요.

명령은 넷이에요.

- `measure`: checkpoint 하나의 한 범위에서, `tool_result` 의 글 본문을 마커로 바꾸기 전과 뒤의 바이트를 세요. 글 본문은 문자열 `content`, 블록 안의 `text` 하나하나, 그 평문 사본(`text_content`)이에요. 이미지·문서·오디오 블록은 그대로 둬요. 마커가 본문보다 길면 그 본문은 남겨요. 길이는 JSON 한 겹으로 견줘요(스크립트의 `shrinks_its_body`). 코드는 레인의 인코더로 견줘요(RFC-0363 §3.1.2). `--min-result-bytes` 를 주면 결과 하나에 문턱을 걸어요(`result_text_bytes`).
- `floor-hole`: traces 폴더의 모든 checkpoint 에서, 2,048 바이트 문턱을 결과 하나에 걸 때와 `text` 블록마다 걸 때 갈리는 결과를 세요.
- `turn-starts`: Keeper 하나의 `turn-boundaries.jsonl` 에서, 어느 시각 앞의 마지막 끝난 턴의 끝(B)과, 끝 줄이 말하는 턴마다의 시작을 읽어요. 앞 줄의 끝보다 뒤에서 시작한 턴(끝 줄 없이 끝난 턴이 사이에 있던 턴)을 모아요.
- `rule-seven`: 하루 system log 에서 Librarian 지점 뒤로 연 요청마다, 그 턴이 읽은 B 와 그 턴이 자기 끝 줄에 쓴 시작(S)을 견줘요. 7 의 상한을 모든 시작점에 `max(B, S)` 로 넓혔다면 시작이 달라질 수 있는 요청을 세요. 이 스택은 그 안을 택하지 않았어요. 넓힌 상한은 8 이 이번 턴에 잡은 앞머리에만 걸어요(Librarian RFC §4.10 의 7).

바이트는 넷으로 세요.

- 측정기: 저장 JSON 전체예요. 블록과 평문 사본을 함께 세요(`message_to_json`).
- 블록: 평문 사본을 뺀 저장 JSON 이에요. Anthropic 이 보내는 모양이에요.
- 사본: 평문 사본 문자열만이에요. Gemini 는 이것을 보내요. OpenAI chat 은 블록에 이미지가 있으면 이것도 보내요.
- OpenAI chat: OpenAI chat 이 보내는 결과 본문이에요. 이미지가 없으면 블록 전체를 JSON 문자열 하나로 보내서 `text` 본문이 두 번 이스케이프돼요. 이미지가 있으면 사본을 tool 메시지로, `text` 블록을 따라 붙는 user 메시지로 보내요. 이미지 바이트는 빼요.

바이트는 토큰이 아니에요. 토큰으로 바꾼 값은 RFC 에 추정으로 적었어요.

## 다시 돌리는 법

```
D=docs/evidence/mcp-result-demotion-2026-11
python3 -I $D/measure_mcp_result_demotion.py measure ~/me/.masc/traces/trace-1788882319100-00000 \
    --first-atom 5197 --end-atom 5263 --blobs-dir ~/me/.masc/tool_blobs --json-out <파일>
python3 -I $D/measure_mcp_result_demotion.py measure ~/me/.masc/traces/trace-1788882319100-00000 \
    --first-atom 5197 --end-atom 5263 --min-result-bytes 2048 --blobs-dir ~/me/.masc/tool_blobs --json-out <파일>
python3 -I $D/measure_mcp_result_demotion.py measure ~/me/.masc/traces/trace-1790137685250-00000 \
    --first-atom 8014 --end-atom 8265 --blobs-dir ~/me/.masc/tool_blobs --json-out <파일>
python3 -I $D/measure_mcp_result_demotion.py floor-hole ~/me/.masc/traces --json-out <파일>
python3 -I $D/measure_mcp_result_demotion.py turn-starts ~/me/.masc/keepers/msx-retro-mania/turn-boundaries.jsonl \
    --trace-id trace-1788882319100-00000 --at 2026-11-06T13:18:57Z --json-out <파일>
python3 -I $D/measure_mcp_result_demotion.py turn-starts ~/me/.masc/keepers/code-reviewer/turn-boundaries.jsonl \
    --trace-id trace-1790137685250-00000 --at 2026-11-06T12:12:10Z --json-out <파일>
python3 -I $D/measure_mcp_result_demotion.py rule-seven ~/me/.masc/keepers/code-reviewer/turn-boundaries.jsonl \
    ~/me/.masc/logs/system_log_2026-11-06.jsonl --keeper code-reviewer --trace-id trace-1790137685250-00000 --json-out <파일>
python3 -I $D/measure_mcp_result_demotion.py rule-seven ~/me/.masc/keepers/msx-retro-mania/turn-boundaries.jsonl \
    ~/me/.masc/logs/system_log_2026-11-06.jsonl --keeper msx-retro-mania --trace-id trace-1788882319100-00000 --json-out <파일>
python3 -m unittest discover -s $D
pyright --outputjson $D/measure_mcp_result_demotion.py $D/test_measure_mcp_result_demotion.py
ruff check $D/measure_mcp_result_demotion.py $D/test_measure_mcp_result_demotion.py
```

- `--first-atom` 은 그 Keeper 가 실제로 보낸 범위의 첫 atom 이에요. 서버 로그의 `model input carried range ... first_atom=` 에서 읽었어요.
- `--end-atom` 은 범위의 끝(포함하지 않음)이에요. checkpoint 는 살아 있는 파일이라, 끝을 정해야 같은 범위를 다시 잴 수 있어요.
- 정의는 스크립트 머리말에 있어요. 스크립트와 시험은 pyright strict 이고 `Any` 를 쓰지 않아요.

## 결과

측정 시각 2026-11-06T14:50Z 예요. 파일 이름의 `1450Z` 가 그 시각이에요.

시험 17개가 통과하고, pyright 오류 0, ruff 경고 0 이에요(14:50Z).

### msx-retro-mania (`result-msx-retro-mania-2026-11-06T1450Z.json`)

범위는 atom 5197~5262 예요. 09:22Z~13:18Z 에 이 범위로 dispatch 전 크기 거절이 났어요.

| 측정 | 값 |
|---|---:|
| 실린 메시지 | 132 |
| 도구 결과 | 138 (텍스트만 87, 이미지+텍스트 51) |
| 마커로 바뀐 안쪽 텍스트 블록 | 138 |
| 마커로 바뀐 평문 사본 | 88 (나머지 50개는 만들 때 이미 마커) |
| 마커보다 짧아 남은 본문 | 0 |
| 이미지 블록 | 51, 모두 640×480 PNG, 미디어 참조로 저장(8,057 B) |
| 측정기 바이트 | 2,306,538 → 526,634 |
| 블록 바이트 | 1,209,154 → 467,428 (741,726 줄어요) |
| 사본 바이트 | 1,034,288 → 48,442 (985,846 줄어요) |
| OpenAI chat 결과 본문 바이트 | 881,315 → 94,105 |

문턱 2,048 을 결과 하나에 걸어도(`result-msx-retro-mania-floor-2048-2026-11-06T1450Z.json`) 값이 같아요. 이 범위의 결과는 모두 문턱을 넘어요.

이미지+텍스트 결과 51개 중 50개는 평문 사본이 이미 마커예요. 결과를 만들 때 `content` 만 마커가 된 것으로 보여요(어느 코드가 바꿨는지는 확인 필요). 안쪽 텍스트 블록은 그대로 남아 Anthropic 요청에 실렸어요.

### code-reviewer (`result-code-reviewer-2026-11-06T1450Z.json`)

범위는 atom 8014~8264 예요.

| 측정 | 값 |
|---|---:|
| 도구 결과 | 298, 모두 문자열 본문(`content_blocks = None`) |
| 마커로 바뀐 본문 | 189 (지금 규칙으로도 강등 대상) |
| 마커보다 짧아 남은 본문 | 109 |
| 블록 바이트 | 6,068,341 → 5,615,026 |
| 그중 `system:text` | 4,641,758 (76.5%) |

`system:text` 는 System 역할로 저장된 지난 context carrier 예요. 이 개정의 범위 밖이에요(#49192).

### 문턱을 어디에 거는가 (`result-floor-hole-2026-11-06T1450Z.json`)

| 측정 | 값 |
|---|---:|
| checkpoint | 38 |
| 블록 결과(`content_blocks = Some`) | 4,759 |
| 결과 하나로 2,048 B 이상 | 4,664 |
| 어느 `text` 블록 하나가 2,048 B 이상 | 4,664 |
| 두 기준이 가르는 결과 | 0 |

지금 자료로는 두 기준이 같은 결과를 골라요. RFC-0363 §3.1.2 는 문자열 결과와 같은 결과 기준을 써요.

### 이번 턴의 시작 (`result-turn-starts-*`, `result-rule-seven-*`)

msx-retro-mania, 13:18:57Z 기준이에요.

- 마지막으로 끝난 턴의 끝 B 는 5197 이에요. 그 뒤로 끝 줄이 없어요.
- 이번 턴의 시작 S 는 5263 이에요. 끝 줄이 없으니 checkpoint 에서 읽었어요. #8670 이 저장한 뒤로 checkpoint 는 5263 atom 이고, 요청 로그는 `atoms=67/5264` 예요(wake atom 하나를 더한 수).
- 지금 규칙: B 부터 보낸 요청이 거절되고, 1 은 걸음이 없어요(5197 > 5197 이 아님). 6 은 바꿀 것이 없어요(블록 결과 138개).
- 이 스택 뒤: 6 이 블록 바이트를 741,726 B 줄여요(위 표). 그래도 넘치면 8 이 5263 부터 보내요. 그 요청은 wake atom 하나와 매 턴 붙는 부분이에요. 13:18:57Z 의 요청(2,424,443 B)에서 범위의 측정기 바이트(2,306,538)를 빼면 117,905 B 예요.
- 13:50Z 부터 msx 는 `claude.claude-haiku-5-5` 레인의 사용 한도 거절로 끝나요(`You have reached your specified API usage limits ... 2026-12-01`). 크기 거절이 아니라서 6·8 은 움직이지 않아요. 배포 뒤 크기 거절이 멈췄는지는 이 한도가 풀리거나 레인이 바뀐 뒤에 볼 수 있어요.

code-reviewer, 12:12:10Z 의 크기 거절이에요.

- 거절된 요청: atom 8014 부터 244개, 5,681,919 B, 375,978 토큰.
- B 는 8257(#14312 의 끝)이고, S 도 8257(#14313 의 시작)이에요. 끝 줄 없이 끝난 턴이 사이에 없어요.
- 지금 규칙과 이 스택 뒤가 같아요. 1 이 8257 부터 다시 보내고(1 atom, 90,329 B) 받아들여져요. 8 까지 가지 않아요.

하루 재생(`rule-seven`)이에요. 7 의 상한을 모든 시작점에 `max(B, S)` 로 넓혔다면 시작이 달라질 수 있는 요청은 로그의 `first_atom == B < S` 뿐이에요. 이 스택의 7 은 모든 시작점의 상한을 B 로 두므로, 아래 요청의 시작은 지금과 같아요.

| | code-reviewer | msx-retro-mania |
|---|---:|---:|
| Librarian 지점 뒤로 연 요청 | 128 | 175 |
| B 보다 앞에서 시작 | 94 | 158 |
| B 에서 시작, S = B | 1 | 0 |
| B 에서 시작, S > B | 1 | 0 |
| B 보다 뒤에서 시작 | 0 | 0 |
| 그 턴이 아직 끝 줄을 쓰지 않음 | 32 | 17 |
| 그중 B 이상에서 시작 | 16 | 14 |

- code-reviewer 의 `B 에서 시작, S > B` 하나는 09:44:14Z 의 1 재전송이에요(`turn_start_after_librarian_refusal`, atom 8014, S 8040). 그 시작점은 B 그대로라 7 이 옮기지 않아요.
- 그래서 끝 줄이 있는 요청 중 이 스택으로 시작이 뒤로 가는 code-reviewer 요청은 0 이에요.
- 끝 줄을 아직 쓰지 않은 턴의 요청(code-reviewer 32, msx 17)은 S 를 이 기록으로 알 수 없어 판정하지 않았어요. 그중 B 이상에서 시작한 요청이 code-reviewer 16, msx 14 예요. 이들의 S 가 B 보다 뒤인지는 확인 필요예요.

## 재지 않은 것

- 실제 요청의 바이트. 여기 바이트는 저장 JSON 기준이에요. OpenAI chat 은 두 겹 JSON 을 셌지만 Responses·Ollama·GLM·Kimi 의 모양은 따로 세지 않았어요.
- 레인 판정. 스크립트는 본문을 JSON 한 겹으로 견줘요. 코드는 본문마다 그 레인의 인코더로 재서 줄 때만 마커로 바꿔요(`Keeper_model_input_wire_bytes`). 두 겹 레인(OpenAI chat·Responses·GLM·Ollama)에서 남는 본문이 있으면, 그 레인의 감소는 표보다 작아요. msx 는 한 겹인 Anthropic 레인이에요.
- 토큰 수. 거절 메시지의 413,067 은 Anthropic `count_tokens` 가 센 값이고, 이 스크립트는 토큰을 세지 않아요.
- 이미지가 요청에서 차지하는 토큰. PNG 크기만 읽었어요.
- `plan` 의 메시지별 비교. 스크립트는 본문별 길이 비교와 결과 문턱만 재생해요.
- 마커의 sha256 자리는 같은 폭의 고정 문자열이에요. 실제 해시는 계산하지 않았어요.
