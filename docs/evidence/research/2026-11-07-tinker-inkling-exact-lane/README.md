# Tinker·Inkling 2 Small exact 레인 실측 기록, 2026-11-07

[연구 문서](../../../research/2026-11-07-tinker-inkling-exact-lane-feasibility.md)가 이 기록을 해석한다.
여기에는 요청 원문과 모델 답 원문을 넣지 않았다.
상태 코드, 응답 모양, 사용량, 채점 결과만 남겼다.

## 환경

| 항목 | 값 |
| --- | --- |
| 호스트 | macOS, 한 대 |
| 클라이언트 | Python 3.14.4, `openai` 3.46.0, `tinker` 0.39.0 |
| 엔드포인트 | `https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1` (OpenAI 호환 Beta) |
| 모델 ID | `thinkingmachines/Inkling-2-Small`, 창 측정만 `thinkingmachines/Inkling-2-Small:peft:262144` |
| 인증 | `TINKER_API_KEY` 환경 변수. 어떤 파일에도 키를 쓰지 않았다 |
| 코드 대조 기준 | `cd3b9cb38c8` (#49616 병합 뒤 main). 측정 자체는 MASC 코드를 쓰지 않는다 |

공식 OpenAI SDK만 썼다.
같은 요청을 Python `urllib` 기본 User-Agent로 보내면 Cloudflare가 HTTP 403(`error code: 1010`)으로 막는다.
MASC의 cohttp 기본 User-Agent(`ocaml-cohttp/v6.2.1`)로 보낸 `GET /models`는 200이었다.

## 무엇을 돌렸나

| 기록 | 시각 (UTC) | 명령 | 내용 |
| --- | --- | --- | --- |
| W | 2026-11-07 06:49:24 시작 | `wire_probe.py --out <dir>` | effort 사다리, 스트림 모양, reasoning 되보내기, 병렬 tool call, prefix cache, 창 크기, 넘침 오류, 동시 8건, `tinker://` 경로 |
| P | 2026-11-07 07:15:36 | `replay_tinker.py` 시작 시 사전 점검 | 작은 스키마를 `json_schema` strict, `json_object`, 지정 없음으로 각각 보냄 |
| R | 2026-11-07 07:15:54 ~ 07:20:22 | `replay_tinker.py --out <dir>` | 2026-09 데이터셋 librarian 17건, board 20건을 effort none·low·medium으로 재생 (111건) |
| O | 2026-11-07 09:02:44 ~ 09:04:11 | `replay_masc_off.py --out <dir> --efforts low --lanes librarian,board --budget 0.5` | R의 low를 MASC exact 요청 모양으로 다시 재생 (37건) |
| L | 2026-11-07 09:06:45 ~ 09:07:46 | `replay_masc_off.py --out <dir> --efforts low --lanes librarian --budget 0.3 --max-tokens 8192 --no-temperature` | O의 librarian을 라이브 바인딩 후보 값으로 다시 재생 (17건) |

R의 입력과 채점기는 `~/me/.masc/benchmarks/local-llm-2026-09/`에서 읽기만 했다.
`datasets/librarian.jsonl`, `datasets/board.jsonl`, `replay_exact.py`의 `parse_json`·`score_librarian`·`score_board`·`LANE_MAX_TOKENS`다.
데이터셋 행위자는 개인·시험용 Keeper뿐이다.
`kidsnote`, `키즈노트`, `slack-reader`, `familynote`, `smartorder` 문자열은 0건이었다.

R의 요청은 `response_format`에 `{"type":"json_schema","json_schema":{"name":…,"schema":…,"strict":true}}`을 실었다.
MASC가 native schema를 선언한 모델에 보내는 모양이다(`packages/agent_core/lib/llm_provider/backend_openai_request.ml:149`).
MASC exact 레인은 `Json_syntax`를 요청하므로 실제로는 `json_schema`를 보내지 않는다.
대신 스키마 지시를 마지막 사용자 메시지로 덧붙인다(`exact_output_ready_admission.ml`). R에는 그 지시가 없다.
`temperature`는 0.0이고, `max_tokens`는 레인 답 예산에 effort별 여유를 더한 값이다.
여유는 none 0, low 4,096, medium 12,288 토큰이다.
board는 8건씩 동시에 보냈다. 8은 관측된 가장 큰 board 묶음이다(`LIVE-WIRING-ROLLBACK.md`).
librarian은 4건씩 동시에 보냈다.

O와 L은 MASC exact 레인이 이 카탈로그 행(JSON mode·native schema 모두 `false`)에 보내는 모양을 따른다.
`response_format`을 싣지 않고, 스키마 지시를 마지막 사용자 메시지로 덧붙인다.
지시 문장은 `domain_schema_instruction_text`에서 그대로 옮겼다(`packages/agent_core/lib/llm_provider/exact_output_ready_admission.ml:241`).
스키마는 키를 정렬한 한 줄 JSON이다.
O는 나머지를 모두 R에서 가져왔다. effort `low`, temperature 0.0, 답 예산(librarian 7,168·board 4,864), 묶음 크기가 같다.
L은 두 가지를 MASC 요청처럼 바꿨다. temperature를 싣지 않고, `max_tokens`를 8,192로 고정했다.
MASC exact 요청은 temperature를 비운다(`exact_config`, 같은 파일 277행).
keeper-librarian Add-on의 두 출력은 레인 `max_output_tokens`를 적지 않는다.
그래서 요청의 `max_tokens`는 바인딩의 `max-tokens`다(`lib/runtime/runtime_exact_output_registry.ml:685`).
8,192는 라이브 설정 후보의 `max-tokens` 값이다.
L은 O가 끝나고 약 3분 뒤에 같은 librarian 프롬프트를 다시 보냈다.
O·L의 요청 모양은 `f8dbd356759`의 코드와 대조했다.

통과선은 요청을 보내기 전에 `replay_tinker.py`의 `PASS`에 적었다.

- librarian: 17건 모두 유효. 모든 현재 기억 ID를 정확히 한 번 처분해야 유효하다.
- board: 클라우드가 기록한 판정과 일치율 0.9 이상. 오류와 계약 위반은 불일치로 센다.
- board 몰림 지연: 5건 이상 묶음의 요청별 지연 p50이 42초 이하.

## 파일

| 파일 | 원본 | 원본 sha256 | 비고 |
| --- | --- | --- | --- |
| `wire-probe.jsonl` | `artifacts/tinker/probe-20261107T064924Z/probe.jsonl` | `1e1133581e2a399396f3153446a83cd172ebd5ee92d96522248932e4e2608c6e` | 그대로. 프롬프트는 모두 합성이다 |
| `wire-sse-low.txt` | 같은 폴더 `sse-low.txt` | `b83119a674442cb63ca988db9f0f257f84019f96f1859cdf162cd334d42c3ce9` | 그대로 |
| `structured-output-preflight.json` | `artifacts/tinker/replay-20261107T071501Z/preflight.json` | `7dac6ce3335fceccf24ba7a6e73fe9aff22fbeff457ca74c006364b29390255b` | 그대로 |
| `replay-rows.jsonl` | 같은 폴더 `rows.jsonl` | `db38ab88d2ac3c4d1acebbfae562280ebdcca0db0c6acb9ec62d7b6dd4e5a48f` | 파생본. 행마다 `content_head`(모델 답 앞 400자)를 지웠다. 나머지 칸은 같다. 올린 파생본의 sha256은 `468483f2e6a363b2ba08a580eddaba9665e0770a5cdcf47cb8fb7bfc4041caba`이다 |
| `replay-summary.json` | 같은 폴더 `summary.json` | `8984fccbaf184751fb17db900cde5927c6c5ea19ff7c1d1b1fb545e05cdd5b06` | 그대로 |
| `wire_probe.py`, `replay_tinker.py` | `artifacts/tinker/` | — | 재현용 사본. 출력은 `--out`으로 준 새 폴더에만 쓴다 |
| `replay-masc-off-rows.jsonl` | `artifacts/tinker/replay-masc-off-20261107T090244Z/rows.jsonl` | `65296518866b8132eee13225d72ae0d45d6b14d715e4dca4b56914df22a32b3d` | 그대로. 스크립트가 모델 답을 행에 쓰지 않는다 |
| `replay-masc-off-summary.json` | 같은 폴더 `summary.json` | `2b8b5d92754eaabcf29d44b0cde1971e51912d0c0b9dc33f0ba19b2be3e6e724` | 그대로 |
| `replay-masc-live-rows.jsonl` | `artifacts/tinker/replay-masc-live-shape-20261107T090645Z/rows.jsonl` | `0f08f9bc8eccf00709e134b9c4ca6e98fdcd7c3bed50e09c763582e33de33930` | 그대로 |
| `replay-masc-live-summary.json` | 같은 폴더 `summary.json` | `3696dcfc7f83008832e3b36506076b7fda26c1d96b2f2e34fb33c6a119bae659` | 그대로 |
| `replay_masc_off.py` | `artifacts/tinker/replay_masc_off.py` | `0aabe27949b3d429f38f6158edb18daf6c80e0b784753f6614cb9dae3b173e48` | 재현용 사본. 두 군데가 다르다. 1단계 스크립트를 같은 폴더의 `replay_tinker.py`에서 읽고, docstring에 두 옵션 설명을 더했다. 실행한 원본은 `artifacts/tinker/replay_tinker.py`를 읽었고, 그 파일과 이 폴더의 사본은 sha256이 같다. 올린 사본의 sha256은 `45d3ef5061933baba4d81a1a5888c4b9e5e5ef2c5545d8c77c7bb2d01129b661`이다 |

`artifacts/` 원본은 이 저장소에 넣지 않은 로컬 작업 출력이다.

## 관찰한 것

W와 P:

- effort `none`·`minimal`·`low`·`medium`·`high`·`xhigh`·`0.5`·`"max"` 모두 200이었다.
  짧은 질문에서 `none`의 reasoning은 0자였다. reasoning 토큰은 `completion_tokens`에 들어간다.
- 스트림 delta는 `role`·`content`·`reasoning_content`·`tool_calls` 키를 늘 싣고, 쓰지 않는 키는 `null`이다.
  값이 차는 순서는 `role` → `reasoning_content` → `content` → `finish_reason=stop` → usage 조각 → `[DONE]`이다.
- `reasoning_content`를 실은 assistant 턴을 되보내도 200이었다. tool_calls가 있어도 같다.
- `tool_choice="required"`에 tool_calls 2개가 한 응답에 왔다.
- 같은 앞부분 6,329 토큰을 두 번 보내자 두 번째에 `cached_tokens` 6,272가 보고됐다.
- 기본 ID의 창은 65,536 토큰이다. 넘치면 HTTP 400과
  `{"detail":"Prompt length plus max_tokens exceeds the model's context window: 140020 prompt tokens + 16 max_tokens > 65536."}`이 온다.
  `:peft:262144` ID는 140,020 토큰을 받았고 540,020 토큰은 같은 모양의 400으로 거절했다(한도 262,144).
- 8건 동시 요청은 모두 200, 0.78~1.36초였다. 429와 rate-limit 헤더는 없었다.
- `tinker://` sampler 경로를 모델 이름으로 넣어도 답했다(5.41초).
- P: `json_schema` strict, `json_object`, 지정 없음 세 요청이 모두 200이었다.
  세 답 모두 스키마를 무시한 같은 영어 문장이었고, prompt 토큰도 27로 같았다.

R (`replay-summary.json`):

| effort | librarian 유효 | librarian 지연 p50 | board 일치 | board 몰림 p50 | 비용 |
| --- | --- | --- | --- | --- | --- |
| none | 7/17 (잘림 10) | 11.66초 | 11/20 = 0.55 (잘림 9) | 3.85초 | $0.161 |
| low | **17/17** | 6.62초 | 16/20 = 0.80 | 3.47초 | $0.141 |
| medium | **17/17** | 17.6초 | 14/20 = 0.70 | 8.73초 | $0.215 |

- 같은 기록에서 클라우드 슬롯이 남긴 지연(`gt_elapsed_s`) p50은 librarian 150.3초, board 37.5초다.
- 판정 비교 대상은 진실이 아니라 2026-09 당시 클라우드 슬롯의 답이다.
- 비용은 usage에 2026-10-19자 공시 단가를 곱해 계산했다. 청구서와 맞춰 보지 않았다.
- 서버가 `json_schema`를 400으로 거절한 경우는 0건이었다.

O와 L (`replay-masc-off-summary.json`, `replay-masc-live-summary.json`), effort는 모두 `low`:

| 기록 | librarian 유효 | librarian 지연 p50 | librarian 출력 최대 | librarian 비용 | board 일치 | board 몰림 p50 |
| --- | --- | --- | --- | --- | --- | --- |
| R low (비교) | 17/17 | 6.62초 | 2,602 토큰 | $0.115 | 16/20 = 0.80 | 3.47초 |
| O | **17/17** | 6.34초 | 2,879 토큰 | $0.119 | 15/20 = 0.75 | 3.13초 |
| L | **17/17** | 5.75초 | 3,172 토큰 | $0.034 | — | — |

- 54건 모두 200, `finish_reason=stop`이었다. 답은 모두 앞뒤 공백만 빼면 JSON 하나였다(`json_form=bare`).
  코드 펜스나 설명이 붙은 답은 없었다.
- 스키마 지시는 기록마다 prompt를 librarian 417 토큰, board 188 토큰 늘렸다.
- 출력 토큰에는 reasoning이 들어간다. L의 최대 3,172 토큰은 답 예산 8,192 안에 들어간다.
- board 일치는 R보다 1건 적다. 클래스별로 relevant 6/10, not_relevant 9/10이다. 통과선 0.9 아래다.
- librarian 결정이 클라우드와 같은 정도는 세 기록이 비슷하다.
  retained Jaccard 평균은 R 0.944, O 0.936, L 0.932다. dropped 완전 일치는 9·8·8건, no-op 일치는 11·11·12건이다.
- L에서는 prompt 토큰의 99.7%가 캐시로 보고됐다. O와 같은 프롬프트를 3분 뒤에 보냈기 때문이다.
  그래서 L의 비용은 대표값이 아니다.

## 확인하지 않은 범위

- 설정마다 한 번만 돌렸다. temperature 0에서 같은 답이 다시 나오는지는 보지 않았다. O와 L도 한 번씩이다.
- 표본이 작다(librarian 17, board 20). 일치율 차이 0.1은 board 2건이다.
- 데이터셋은 2026-09 모양이다. librarian 프롬프트 p50이 64KB인데,
  2026-11-07 라이브 librarian 입력 p50은 12.9KB였다. 지금 프롬프트로는 다시 재지 않았다.
- MASC 런타임으로 보낸 요청은 없다. R의 요청 모양은 MASC exact 레인과 다르다. O·L은 그 모양을 스크립트로 따라 했다.
  슬롯·폴백·검증 경로는 돌리지 않았다.
- Beta 엔드포인트의 한도는 문서에 숫자가 없다. 동시 8건 넘는 부하는 재지 않았다.
- `:peft:262144` ID는 창 크기만 쟀다.
