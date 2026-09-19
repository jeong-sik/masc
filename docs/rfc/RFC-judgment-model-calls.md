---
rfc: "judgment-model-calls"
title: "판단 모델 호출 — 글을 쓰지 않고 물음에 값으로 답하는 모델을 부르는 길"
status: Draft
created: 2026-09-19
updated: 2026-09-19
author: vincent + claude
related: ["0456"]
---

# RFC — 판단 모델 호출

## 0. 요약

masc 의 모델 호출은 전부 한 모양이다. **메시지를 주고 글을 받는다.** 구조화된 답이 필요한 자리(exact-output 레인)도
글을 받아서 그 안의 JSON 을 꺼낸다.

글을 아예 쓰지 않는 모델이 있다. 대상(`state`) 하나와 물음 여러 개를 받아, 물음마다 **값**으로만 답한다 —
0~1 사이 수, 선택지 하나, 등급 하나. 이런 모델은 chat/completions 로 부르면 거절당하고 자기 전용 주소만 받는다.
masc 에는 이 모델을 부를 길이 없다.

이 RFC 는 그 길을 **가장 작게** 만든다.

- 호출·타입·실패 분류를 `lib/judgment/` 에 새로 둔다. 기존 완성(completion) 계층에 끼워 넣지 않는다. 그 계층의 모든 갈래가
  "메시지가 들어가고 글 조각이 나온다"를 전제하기 때문이다.
- 주소와 자격증명은 `runtime.toml` 의 새 표 `[judgment.<id>]` 에 선언한다. 요청 시간 상한은 필수 칸이다.
- 첫 소비자는 **운영자가 부르는 읽기 전용 명령** 하나다. keeper 의 흡수 기록을 읽어, 묶은 claim 이 재료의 내용을 얼마나 전하는지 재서 출력한다(#37079).
- 이름은 벤더가 아니라 일의 모양으로 짓는다.

**만들지 않는 것이 더 많다.** 점수 저장소, Librarian 회차에 붙는 자동 채점, 레인과 슬롯 넘김, 기억 상태 화면의 새 값, keeper 별 스위치 —
전부 뺐다. 이유는 §5 에 하나씩 적었다. 첫 초안에는 있었고, 검토에서 "없어도 잃는 사실이 없다"는 것이 드러났다.

## 1. 실측

### 1.1 판단 모델이 받는 것과 돌려주는 것

공식 API 문서(`docs.typesafe.ai/api.md`, 2026-09-19 확인)와 같은 날 라이브 호출로 맞춰 본 모양이다.

```
POST https://api.typesafe.ai/v1/systemone          Authorization: Bearer <key>

{ "model": "jev-latest",
  "state": "<판단할 대상>",
  "questions": {
    "<id>": { "type": "noul",   "instructions": "...", "criteria": { "true": "...", "false": "..." } },
    "<id>": { "type": "choice", "instructions": "...", "criteria": { "<선택지>": "<설명>|null", ... } },
    "<id>": { "type": "score",  "instructions": "...", "criteria": ["<0등급>", "<1등급>", ...] } } }
```

| 물음 | 답 |
|---|---|
| `noul` | `{ "type":"noul", "noul": 0.95 }` — 0~1 |
| `choice` | `{ "type":"choice", "choice":"payments", "confidence":1.0, "probabilities":{...} }` |
| `score` | `{ "type":"score", "score":1.98, "confidence":0.97, "legend":{...}, "probabilities":{"0":0.0,"1":0.02,"2":0.98} }` — `score` 는 등급의 기댓값이라 소수다 |

응답에는 `model`(요청은 `jev-latest`, 응답은 `jev-1.13.0`)과 `usage { input_tokens, output_tokens }` 가 같이 온다.
문서에 적힌 오류는 401(키)·422(요청 모양)·429(rate limit)·529(과부하) 네 가지다.

이 모델은 한 요청에 물음을 여러 개 담아 쓰도록 만들어졌다. 문서는 "물음은 병렬로 평가되어 물음을 늘려도 지연이 늘지 않는다"고 적는다.
실측도 그랬다 — 물음 2~22개짜리 요청 81회가 48.87초, 요청당 0.603초였다.

같은 모델이 OpenRouter 에도 있다. `api/v1/chat/completions` 는 거절하고 `api/alpha/decisions` 만 받는다(2026-09-19 호출로 확인).
응답 모양이 같은지는 확인하지 않았다(§8). 이 RFC 는 주소 하나만 다룬다.

### 1.2 기존 길로는 못 부른다

exact-output 흐름의 입구는 메시지 목록만 받는다.

```ocaml
val snapshot_flow
  :  first:flow_candidate
  -> rest:flow_candidate list
  -> messages:Types.message list
  -> output_requirement
  -> (flow_snapshot, flow_snapshot_error) result
(* packages/agent_core/lib/llm_provider/exact_output.mli:400-405 *)
```

답은 글에서 꺼낸다.

```ocaml
(* Note the parse path never read a provider-side structured field:
   [Agent_core.Structured.response_json_extractor] extracts JSON from the
   response's visible text ... *)
(* lib/keeper/keeper_structured_output_schema.ml:206-209 *)
```

그 아래 wire 계층도 같다. `Provider_http_codec.t` 는 여섯 갈래(`Anthropic_messages | Openai_chat | Openai_responses |
Ollama_chat | Gemini_generate_content | Glm_chat`, `provider_http_codec.mli:6-12`)이고, 응답은 전부
`content_block list` 로 모인다(`types.mli:650-657`). provider 가 구현할 모듈 시그니처는 없고, 갈래마다 `match` 가 있다.

판단 모델을 일곱 번째 codec 으로 넣으면 **가짜 메시지**(`state` 를 user 메시지인 척)와 **가짜 글 조각**(점수를 Text 인 척)을 만들어야 한다.
타입이 거짓말을 하게 된다.

### 1.3 기존 판정 레인은 전부 글을 요구한다

"판정만 하는 레인을 판단 모델로 바꾸면 되지 않나"는 지금은 성립하지 않는다.

| 레인 | 답의 핵심 | 글이 필수인가 | 근거 |
|---|---|---|---|
| `board_attention_exact` | `Relevant \| Not_relevant` | 필수. 빈 `rationale` 은 decoder 가 거절 | `keeper_board_attention_judgment.ml:36-38` |
| `hitl_auto_judge` | `Approve \| Deny \| Require_human` | 필수. `context_summary`·`key_questions`·`rationale` | `keeper_structured_output_schema.ml:97-107` |
| `librarian_exact` | claim 본문 | 답 전체가 글 | 같은 파일 `:47-80` |
| `workspace_curator_exact` | claim 본문 | 답 전체가 글 | `server_workspace_memory_curator.ml:20-28` |
| `verifier_exact` | `APPROVE \| REJECT` | `REJECT` 는 이유 없이는 거절된다. 전송이 tool call | `anti_rationalization.mli:58-65` |

판단 모델은 근거를 **쓰지 못한다.** 이 레인들을 옮기려면 각 레인의 계약에서 글을 빼는 결정이 먼저이고, 그건 레인마다 따로 판단할 일이다.
이 RFC 의 범위가 아니다. 0~1 수를 답으로 받는 모델 호출은 지금 masc 에 하나도 없다.

### 1.4 이 모델이 실제로 무언가를 재는가 — 물음을 어떻게 짜느냐에 달렸다

Librarian 흡수(묶은 claim 과 그 재료)로 두 가지 물음을 써 봤다(#37079). 같은 모델인데 쓸모가 크게 달랐다.

| 물음 | 잃은 것이 없을 때 | 전부 잃었을 때 | 쓸 수 있는 폭 |
|---|---|---|---|
| 큰 물음 하나: "읽는 이가 이 재료의 내용을 놓치는가" | 0.56 | 0.78 | 0.22 |
| 작은 물음 여러 개: 재료를 문장으로 자르고 문장마다 "묶은 claim 이 이 문장을 전하는가" | 0.94 | 0.10 | 0.84 |

"잃은 것이 없을 때"는 재료 전부를 그대로 이어 붙인 것을 `state` 로, "전부 잃었을 때"는 다른 keeper 의 무관한 claim 을 `state` 로 준 값이다(큰 묶음 12~14개).

- **큰 물음은 못 쓴다.** 아무것도 안 잃어도 0.56 이 나온다. 이 물음은 모델에 보여 준 적 없는 값(재료에서 빠진 식별자 수)과
  Spearman +0.524(식별자가 있는 156쌍)로 같이 움직이기는 했다. 순위는 맞추는데 눈금이 없었고, 상관만 보고 쓰기 시작한 것이 잘못이었다.
- **작은 물음은 양 끝이 맞는다.** 벤더 문서가 권하는 쓰는 법("물음은 작게, 여러 개")과 같다. 이 RFC 의 점검은 이쪽을 쓴다.
- **물음은 쓰기 전에 양 끝으로 맞춰 본다.** 답을 아는 입력 둘(잃은 것 없음·전부 잃음)을 넣어 1 과 0 근처가 나오는지. 문구가 다른 점수는 섞지 않는다.
- **답은 매번 조금씩 다르다.** 같은 요청을 두 번 보내면 평균 0.018, 최대 0.09 움직인다(n=120). 0.05 보다 작은 차이는 읽지 않는다.
- **한 요청 안의 다른 물음은 답을 움직이지 않는다.** 혼자 물었을 때와 22개 묶음 안에서 물었을 때의 차이는 평균 0.022 로
  위 흔들림과 구분되지 않는다(n=48). 문서에는 없는 성질이라 직접 쟀다. (이 둘은 큰 물음으로 잰 값이다.)

사람이 매긴 정답과 맞춰 본 적은 없다. §8.

### 1.5 첫 소비자가 왜 흡수 점검인가

#37079 요약: Librarian 이 기억을 묶을 때(`absorbs`, RFC-0456 §4.2) 묶은 claim 이 재료의 내용을 덜 전한다.
작은 물음으로 잰 값은 큰 묶음 12개(49쌍)에서 **0.54** 다(잃은 것이 없으면 0.94). keeper 는 빠진 원문을 찾지 않는다(`source="absorbed"` 검색 0 / 1,178).
원인을 고치는 일은 이 RFC 와 별개로 간다.

흡수 점검은 판단 모델에 맞는 모양이다. 묶은 claim 하나가 `state`, 재료의 문장마다 물음 하나 — 그대로 한 요청이다.
그리고 지금은 저장소에 없는 Python 스크립트로만 잴 수 있다.

## 2. 결정

### 2.1 codec 이 아니라 별도 client

§1.2 의 이유로, 판단 호출은 `Provider_http_codec` 에 갈래를 더하지 않는다. `lib/judgment/` 에 작은 모듈로 둔다.
HTTP 는 모델이 아닌 호출들이 쓰는 `lib/masc_http_client` 의 `Pool.request` 를 쓴다.

### 2.2 주소는 `[judgment.<id>]` 에 선언한다

```toml
[judgment.typesafe]
endpoint = "https://api.typesafe.ai/v1/systemone"   # 요청을 보내는 주소 그대로. 뒤에 경로를 붙이지 않는다
request-timeout-s = 30.0                             # 필수

[judgment.typesafe.credentials]
type = "env"
key = "TYPESAFE_API_KEY"
```

`[providers.<id>]` 에 `protocol = "judgment-http"` 로 넣는 길도 있다. 고르지 않는다.

- `[providers]` 는 턴을 돌리는 provider 의 자리다. 거기 넣으려면 `Runtime_schema.api_format` 에 constructor 를 더해야 하고,
  그 타입을 빠짐없이 `match` 하는 열한 곳이 "해당 없음"을 하나씩 적어야 한다(`runtime_toml.ml:486`·`:2437-2446`,
  `runtime_adapter.ml:336`·`:352`·`:638`·`:965`, `server_dashboard_http_runtime_info.ml:762`·`:888`·`:1704`,
  `runtime_wizard_inventory.ml:69`, `server_runtime_setup_actions.ml:50`). 열한 곳이 전부 "아니다"라고 답해야 하는 타입은 그 자리의 것이 아니다.
- 컴파일러가 못 잡는 자리도 둘 있다. `runtime_adapter.ml:444-447` 은 `api_format` 을 `_ ->` 로 받고,
  `dashboard/src/components/runtime-setup-picker.ts:24` 는 프로토콜 이름을 문자열 목록으로 들고 있다.
- 같이 쓸 수 있는 것은 자격증명 읽기(`runtime_toml.ml` 의 `parse_credential`) 하나다. 이건 함수라서 새 표에서도 그대로 부른다.
  시간 상한 규칙은 같이 쓸 수 없다 — `Missing_deadline` 은 agent_core 의 exact-output 계획 안에 있고
  (`packages/agent_core/lib/llm_provider/exact_output_plan.ml:141-144`), `connect-timeout-s` 는 agent_core 의 HTTP client 만 읽는다.

새 표의 칸은 닫혀 있다(`endpoint`, `request-timeout-s`, `credentials`). 모르는 칸과 빠진 칸은 설정 로드 오류다.
선언 타입 `judgment_endpoint_decl` 은 `lib/runtime/runtime_schema` 에 둔다. `lib/runtime` 은 독립 라이브러리(`masc_runtime`)라서
`lib/judgment` 가 `lib/runtime` 에 기대는 한 방향만 생긴다.

### 2.3 타입 — 물은 대로 돌아오지 않으면 실패다

```ocaml
(* lib/judgment/judgment_question.mli *)
type noul_criteria = { when_true : string; when_false : string }
type option_ = { value : string; meaning : string option }

type t =
  | Noul of { instructions : string; criteria : noul_criteria option }
  | Choice of { instructions : string; first : option_; second : option_; rest : option_ list }
  | Score of { instructions : string; lowest : string; next : string; rest : string list }

(* lib/judgment/judgment_answer.mli *)
type t =
  | Noul of float                       (* 0.0 .. 1.0 *)
  | Choice of { choice : string; confidence : float; probabilities : (string * float) list }
  | Score of { score : float; confidence : float; probabilities : (int * float) list }
```

선택지와 등급은 둘 이상이어야 물음이 되므로 타입이 둘을 요구한다.

- 돌아온 답은 **물은 id 와 정확히 같은 집합**이어야 한다. 하나라도 빠지면 호출 전체가 `Error (Answer_missing id)`.
- 답의 종류가 물음의 종류와 다르면 `Error`. `noul` 이 0~1 밖이면 `Error`. `choice` 가 선택지에 없는 값이면 `Error`.
- 기본값으로 메우지 않는다. 절반만 온 답을 절반만 쓰는 길도 없다.
- `state` 는 문자열만 받는다. API 는 객체·배열도 받지만 쓸 소비자가 없다.

### 2.4 시간 상한은 빠뜨릴 수 없는 인자다

```ocaml
(* lib/judgment/judgment_client.mli *)
val ask
  :  pool:Masc_http_client.Pool.t
  -> clock:_ Eio.Time.clock
  -> endpoint:Judgment_endpoint.t        (* 주소, 자격증명, request_timeout_s *)
  -> model:string
  -> state:string
  -> first:Judgment_question_id.t * Judgment_question.t
  -> rest:(Judgment_question_id.t * Judgment_question.t) list
  -> ((Judgment_question_id.t * Judgment_answer.t) list * receipt, error) result
```

`Pool.request` 의 `?clock` 과 `?timeout_seconds` 는 둘 다 선택 인자라서, 안 주면 상한 없이 기다린다(`lib/masc_http_client/pool.mli:96-105`).
`ask` 는 둘을 **항상** 넘긴다. `clock` 은 `ask` 의 필수 인자이고 상한은 `endpoint` 에서 온다. 상한 없는 선언은 §2.2 에서 이미 거절됐다.

`receipt = { model; input_tokens; output_tokens; elapsed_s }`. `model` 은 응답이 말한 이름이다.

### 2.5 실패 분류

```ocaml
type error =
  | Timed_out
  | Transport of string
  | Unauthorized                 (* 401 *)
  | Invalid_request of string    (* 422. 본문을 그대로 싣는다 *)
  | Rate_limited                 (* 429 *)
  | Overloaded                   (* 529 *)
  | Unexpected_status of int     (* 위 넷과 2xx 가 아닌 전부 *)
  | Malformed_response of string (* JSON 이 아니거나 §2.3 의 규칙을 어김 *)
```

다시 부르지 않는다. 다른 주소로 넘어가지도 않는다(주소가 하나다). 호출한 쪽이 이 값을 보고 정한다.

### 2.6 첫 소비자 — 운영자가 부르는 흡수 점검 명령

`bin/masc_cli_*.ml` 의 기존 모양을 따른다(`masc_cli_inspect_file.mli`: "Emits JSON; does not ... change Task/Goal state").

```
masc absorption-coverage --keeper <이름> --judgment <id> --model <모델> [--since <ISO8601>] [--until <ISO8601>] [--limit <N>]
```

1. `<keeper>.memory-absorbed.jsonl` 에서 `recorded_at` 이 구간 안인 줄을 고른다. 이미 있는 읽기 함수(`Keeper_memory_absorbed.read`)를 쓴다.
2. 줄마다 묶은 claim 의 본문을 찾는다(§2.7).
3. 줄 하나당 요청 하나. `state` = 묶은 claim, 물음 = 재료를 자른 문장마다 "묶은 claim 이 이 문장을 전한다"(`noul`).
   문장 수는 상수로 끊고(넘으면 고르게 솎는다), 그 상수는 써 본 범위 안에 둔다 — 물음 22개까지 써 봤다.
4. 줄마다 JSON 한 줄을 바로 출력한다: `memory_id`, `into`, 흡수 시각, 문장별 값. 마지막에 요약 한 줄: 점검한 수, 평균,
   0.5 에 못 미치는 수, 본문을 못 찾은 수, 응답이 말한 모델 이름, 물음 문구의 digest.
5. **아무것도 쓰지 않는다.** keeper 파일도, 새 파일도.
6. 줄에 딸린 실패(`Invalid_request`)는 그 줄에 오류를 실어 출력하고 다음 줄로 간다. 그 밖의 실패(`Unauthorized`, `Rate_limited`, `Overloaded`,
   `Timed_out`, `Transport`, `Unexpected_status`, `Malformed_response`)는 **거기서 끝낸다.** 실패가 하나라도 있으면 종료 코드가 0 이 아니다.

문장을 자르는 규칙은 순수 함수이고, 예시 입력·출력을 고정한 테스트를 둔다. 물음 문구와 자르는 규칙은 OCaml 상수로 두고, 요약 줄의 digest 는
그 둘과 물음 종류·`criteria`·"무엇이 `state` 인가"를 합쳐 계산한다. digest 가 다른 출력끼리는 비교하지 않는다.

### 2.7 묶은 claim 의 본문은 항상 찾을 수 있다

기억의 id 는 본문의 해시다(`"sha256:" ^ hex(sha256(claim))`, `keeper_memory_os_types.ml:712-714`). 그래서 어디서 찾든 같은 본문이고,
아래 순서는 **값싼 곳부터 본다**는 뜻일 뿐이다.

1. 현재 스냅숏.
2. 흡수 기록 — 묶은 claim 이 나중에 다시 흡수된 경우. 같은 해석이 `keeper_tool_memory_runtime.ml:218-262` 에 이미 있다.
3. journal 의 `change.added` — 커밋된 claim 은 전부 여기 본문이 있다(`keeper_memory_os_current.mli:32-37`). keeper 당 5~13 MB 라서 1·2 에서 못 찾았을 때만 연다.

2026-09-19 라이브(keeper 14개, 흡수 기록 1,921줄): 스냅숏 1,754 · 흡수 기록 67 · journal 에서만 100 · **못 찾음 0.** 같은 `(memory_id, into)` 가 두 번 나온 줄도 0.
그래도 못 찾는 줄이 생기면(커밋되지 않은 회차의 줄, `keeper_memory_absorbed.mli:13-17`) 요약의 "본문을 못 찾은 수"에 센다.

### 2.8 나가는 데이터

이 명령은 keeper 기억의 claim 본문을 **지금까지 받은 적 없는 제3자**에게 보낸다. 보내는 것은 두 claim 의 본문뿐이고,
`origin`·`basis`·`trace_id`·keeper 이름은 보내지 않는다.

어느 keeper 의 기억을 보낼지는 **부를 때 운영자가 이름으로 정한다.** 그래서 keeper 별 스위치가 따로 필요 없다.
기본으로 배포되는 `config/runtime.toml` 에는 `[judgment.*]` 를 주석으로만 싣는다. 선언이 없으면 명령은 "판단 주소가 선언되지 않았다"로 끝난다.

## 3. 바꾸는 것

### 3.1 `lib/judgment/` (신규)

`judgment_question`, `judgment_answer`, `judgment_question_id`, `judgment_wire`(요청 만들기·응답 읽기, 순수), `judgment_endpoint`, `judgment_client`.
`lib/runtime`(선언 타입)과 `lib/masc_http_client` 에 기댄다.

### 3.2 `lib/runtime/`

- `runtime_schema.ml/.mli` — `judgment_endpoint_decl = { id; endpoint; request_timeout_s; credentials }`.
- `runtime_toml.ml` — `[judgment.<id>]` 파싱. 칸은 닫혀 있고, `request-timeout-s` 가 없거나 0 이하면 오류.
- `api_format`, `protocol_declarations`, `runtime_adapter.ml` 은 건드리지 않는다.

### 3.3 `lib/keeper/keeper_absorption_coverage.ml/.mli` (신규)

순수 부분: 구간으로 줄 고르기 · 본문 찾기(§2.7) · 문장 자르기 · 물음 만들기 · 요약 계산. 효과는 파일 읽기와 `Judgment_client.ask` 호출뿐이다.

### 3.4 `bin/masc_cli_absorption_coverage.ml/.mli` (신규)와 명령 등록

### 3.5 기본으로 배포되는 `config/runtime.toml` — 주석으로 된 `[judgment.typesafe]` 예시

### 3.6 테스트

- `judgment_wire`: 세 종류 답 읽기 · 빠진 id · 종류 불일치 · 0~1 밖 `noul` · 선택지에 없는 `choice` · 모르는 `type`.
- `judgment_client`: 가짜 HTTP 응답으로 §2.5 의 여덟 갈래를 하나씩. 시간 상한이 실제로 걸리는지(가짜 clock).
- `runtime_toml`: 모르는 칸 · 빠진 `request-timeout-s` · 0 이하 상한.
- `keeper_absorption_coverage` 순수 부분: 구간 경계 · 문장 자르기 고정 예시 · 문장 수 끊기 · 본문을 세 곳 어디서 찾아도 같은 결과 · 못 찾은 줄 세기.

## 4. 안 바꾸는 것

- `Agent_core.Exact_output`, `Provider_http_codec`, `api_format`, exact-output 레인 다섯 개와 그 소비자.
- Librarian 의 프롬프트, 출력 스키마, 회차, 그 회차가 도는 keeper 별 memory lane.
- `<keeper>.memory-absorbed.jsonl`, 스냅숏, journal 의 형식과 내용. 이 RFC 는 keeper 파일에 **쓰는 코드를 더하지 않는다.**
- 턴 경로. `scripts/turn-path-provider-agnostic-gate.sh` 가 보는 파일에는 손대지 않는다.

## 5. 하지 않는 것

- **점수 저장소를 만들지 않는다.** 점수는 이미 있는 파일(흡수 기록·스냅숏·journal)에서 언제든 다시 계산된다. 없어도 잃는 사실이 없다.
  RFC-0456 §8 도 "새 계측을 만들지 않는다"고 했다. 저장소가 필요해지는 때는 #37079 를 고친 뒤에도 점수를 읽고 무언가를 정하는 자리가 생길 때이고,
  그때는 흡수 시각·모델 이름을 열쇠에 넣고 어떤 통계를 볼지부터 정해야 한다.
- **Librarian 회차에 자동 채점을 붙이지 않는다.** 회차는 keeper 별 memory lane 안에서 돌고, keeper 를 멈출 때 그 lane 을 30초 기다린다
  (`keeper_memory_lane.ml:519`). 흡수 줄이 1,500개인 keeper 는 채점만 15분이다. 실패한 줄을 다음 회차마다 다시 시도하는 구조는 끝이 없다.
  그리고 `run_best_effort`(`keeper_librarian_runtime.ml:743-1038`)에는 "회차가 끝났다"는 한 지점이 없다.
- **레인과 슬롯 넘김을 만들지 않는다.** 확인된 주소가 하나다. 둘째 주소(OpenRouter)는 응답 모양을 확인하지 못했고, 운영자 명령은 실패하면 다시 부르면 된다.
- **기억 상태 화면에 값을 더하지 않는다.** 그 응답은 `keeper.memory_os.current_health.v4` 이고 TUI(`lib/tui_decode.ml`)와 dashboard
  (`dashboard/src/api/dashboard-misc.ts` 의 `exactKeys`)가 칸을 정확히 맞춰 읽는다. 값 셋을 더하려면 세 곳과 스키마 번호를 같이 올려야 한다.
- **keeper 별 스위치를 만들지 않는다.** §2.8.
- **흡수를 점수로 막지 않는다.** 원인을 그대로 두고 결과만 거르는 일이다.
- **기존 판정 레인에 판단 모델을 넣지 않는다.** §1.3.
- **판정을 두 층으로 쌓지 않는다.** 판단 모델은 이유를 남기지 못하므로, 그 점수로 Librarian 을 다시 판정하면 근거 없는 판정이 하나 더 쌓인다.
- **턴 FSM·Task 전이 같은 결정론 부분에 쓰지 않는다.** 답이 매번 0.02 씩 움직이는 값이다.

## 6. 검증

| 항목 | 기대 |
|---|---|
| 답을 아는 입력 둘 — 재료 전부를 이어 붙인 것 / 무관한 claim | 0.9 이상 / 0.2 이하. 이 범위를 벗어나면 물음이 망가진 것이다 |
| 거의 같은 메모 1,481개를 묶은 회차(#37079 덧붙임 1) | 높다. 낮으면 물음이 "길이가 줄었다"를 "내용이 빠졌다"로 읽고 있는 것이다 |
| 같은 구간을 두 번 점검 | 요약 평균의 차이가 0.05 안쪽 |
| 시간 상한 | 응답을 안 주는 가짜 서버에서 `Timed_out` 이 상한 안에 나온다 |
| keeper 파일 | 명령 전후로 바이트가 같다 |

#37079 를 고친 효과는 이 명령으로 **보지만 증명하지는 않는다.** 고치기 전 구간과 후 구간은 서로 다른 흡수들이다.
원인을 가르는 비교는 같은 재료를 옛 프롬프트와 새 프롬프트로 다시 묶어 둘 다 채점하는 실험이고, 그건 #37079 쪽에서 한다.

## 7. 결정이 필요한 것

1. **서버 코드 없이 갈 것인가.** 측정 스크립트(Python)를 `scripts/` 에 넣고 결과를 #37079 의 PR 에 붙이는 길이 있다(선례: `scripts/measure-rfc-0427-judge-share.py`).
   비용이 가장 낮다. 이 RFC 는 OCaml client 와 명령을 권한다 — masc 안에 판단 호출의 길을 두는 것이 목적이고, 타입 있는 client 는 다음 소비자가 그대로 쓴다.
   다만 다음 소비자는 지금 없다(§1.3).
2. **이름.** `lib/` 에서 `judge` 가 231개 파일, `judgment` 가 90개 파일에 이미 나온다 — 전부 글로 답하는 LLM 판정이다
   (`Operator_judgment`, `Keeper_board_attention_judgment`, `fusion_judge`, `config/prompts/judge.md`). §1.3 이 "이것과 다르다"고 한 바로 그것과 이름이 겹친다.
   안 겹치는 후보: `appraisal`(0개 파일).
3. **`[judgment.<id>]` 와 `[providers.<id>]`.** §2.2 는 앞을 권한다.
4. **먼저 사람이 기준을 확인할 것인가.** 전해진 정도가 낮게 나온 쌍 20개쯤을 사람이 읽고 점수와 맞는지 본다. 구현보다 싸고, 틀렸으면 구현할 이유가 줄어든다. 권함: 먼저 한다.

## 8. 확인 못 한 것

- **사람이 매긴 정답이 없다.** 양 끝은 맞지만 그 사이의 눈금이 사람의 판단과 맞는지 모른다. keeper 가 직접 쓴 메모에서 교훈이 통째로 빠지는 손실(#37079 본문)에 특히 그렇다. §7-4.
- **문장을 자르는 규칙이 거칠다.** 재료의 중앙값이 문장 2개로 잘린다. 한국어 claim 은 쉼표로 이어진 긴 한 문장이 많아서다.
  한 문장 안에 사실이 셋이면 물음 하나가 셋을 같이 묻는다.
- **한 요청의 물음 수 상한.** 문서에 없다. 22개까지 써 봤다.
- **rate limit 수치와 가격.** 문서에 없다. 2026-09-18 실측은 요청당 약 1.4k 토큰에 $0.00006 이었다.
- **OpenRouter `alpha/decisions` 의 응답 모양.** 요청이 받아들여지는 것만 확인했다.
- **모델이 바뀔 때 값이 얼마나 달라지나.** `jev-latest` 는 움직이는 이름이다. 그래서 요약 줄에 응답의 `model` 을 싣는다.
- **API 사양의 출처.** 벤더 문서 한 번 읽은 것과 라이브 호출 한 번이다. 세 종류 답의 모양은 호출로 확인했고, 오류 코드 넷은 문서로만 확인했다.
- **preflight 검사기의 빈틈(#37019).** 이 RFC 는 저장소를 더하지 않으므로 걸리지 않는다. 저장소를 더하는 날에는 #37019 를 먼저 닫아야 한다 —
  형제인 `keeper_memory_absorbed` 도 `durable_stores`(`bin/deployment_preflight_helper.ml:1070-1079`)에 빠져 있다.

## 9. 순서

0. §7-4 — 사람이 낮은 쌍 20개를 읽는다. 여기서 기준이 틀렸다고 나오면 1~3 은 물음을 다시 짠 뒤로 미룬다.
1. `lib/judgment/` 의 타입과 `judgment_wire` + 테스트. 효과 없음.
2. `[judgment.<id>]` 파싱 + `judgment_client`(시간 상한 포함) + 테스트.
3. `keeper_absorption_coverage` + `masc absorption-coverage` 명령 + 테스트.

§7 의 1~3 이 정해져야 1번부터 나갈 수 있다.
