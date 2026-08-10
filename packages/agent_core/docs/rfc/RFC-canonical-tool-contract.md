# RFC-OAS-024: Canonical Tool-Call Contract (WP8)

| | |
|---|---|
| Status | Draft — needs owner sign-off on 2 decisions (see §0) |
| Author | jeong-sik (with Claude Opus analysis) |
| Created | 2026-06-03 |
| Verified against | `origin/main` head `0c2aef991` + issue #2528 identity invariant (2026-07-11) |
| Target | `agent_sdk` (oas) — `lib/llm_provider` only |
| Supersedes | None |
| Related | RFC-OAS-016 (mcp optional dependency), RFC-OAS-023 (capability axis reshape); WP1/WP2/WP4 (already in `origin/main`) |
| Boundary | OAS = Provider Canonicalization only. Zero references to masc-mcp, Shell IR, keeper, sandbox, descriptor execution, or any execution-policy concept. |

---

## 0. 결정 상태 요약 (RESOLVED vs SIGN-OFF)

이 RFC는 7개 설계 결정을 다룬다. 그 중 5개는 `origin/main` 코드 증거로 **확정(RESOLVED)** 되었고, 2개는 사람 오너의 **승인(SIGN-OFF)** 이 필요하다. 승인 항목은 코드를 머지하기 전에 반드시 닫아야 한다.

| # | 항목 | 상태 | 근거 / 필요한 결정 |
|---|---|---|---|
| **K** | **Keystone: `id_origin` 유지 vs 제거** | **SIGN-OFF** | `id_origin`은 순수 사후-파싱 projection에서 도출 불가(Ollama mixed-origin, §3.3). correlation은 origin과 무관하게 occurrence-unique `call_id` 동등성으로 동작 → 소비자 분기가 없으면 unconsumed. **권고: 제거.** §6 D2/D4. |
| **M** | **`canonical_tool.ml` 모듈을 실제로 머지할지** | **SIGN-OFF** | in-repo 소비자(handoff serializer)가 없으면 fan-in==0 dead code. **권고: 소비자 커밋 전까지 spec-level 유지.** §7. |
| D1 | SSOT vs side projection | RESOLVED | side projection (content_block이 in-memory SSOT). Keystone 제거 시 "zero blast radius" 주장 성립. §6 D1. |
| D3 | parallel call `order_index` | RESOLVED | tool-call들만의 인덱스(filter+mapi), `next_block_index` 아님. §3.3, §6 D3, §8.2. |
| D5 | `Provider_kind` 식별 | RESOLVED | 필수 인자로 thread. 타입은 `OpenAI_compat`(family, vendor 아님). §6 D5. |
| D6 | reasoning 링크 | RESOLVED | 3-way `reasoning_link` variant (option 아님). §6 D6. |
| D7 | `output_schema` 경계 | RESOLVED | `provider_config.t`(request-level)에 유지, `tool_schema`로 이동 안 함. §6 D7. |

확정 항목(D3/D5/D6/D7 + §3.3 Ollama 정정 + 헤더 SHA)은 본문에 직접 반영되어 있다. 두 SIGN-OFF 항목은 §6 D2/D4와 §7에서 두 갈래(lane)를 모두 제시하고 권고안을 표시한다.

---

## 1. Context & Boundary

OAS는 provider wire format을 하나의 in-memory 표현(`lib/llm_provider/types.ml`)으로 canonicalize 하고, provider별로 다시 serialize 한다. 오늘날 이 canonicalization의 **tool-call 차원**은 암묵적이다. tool call은 `{ id; name; input }`을 담은 `ToolUse` content block이고(`types.ml:209-213`), tool result는 `ToolResult` block이다(`types.ml:214-243`). *어느 provider가* call을 emit했는지, parallel call이 *어떤 순서로* 도착했는지, *native wire id인지 OAS-allocated id인지*, *어떤 reasoning이* 특정 call에 붙었는지에 대한 일급 개념이 없다.

WP8은 **typed canonical tool-call contract**를 도입한다. OAS가 downstream coordinator(MASC)에게 넘기는 surface로, 그 coordinator가 call↔result를 correlate 하고, reasoning을 replay 하고, 결정론적으로 reorder/dedup 할 수 있게 한다 — **OAS가 그 call들이 어떻게 실행되는지는 전혀 모르는 상태로**.

**Boundary (non-negotiable):**
- OAS가 소유: provider block ordering, streaming delta reconstruction, call-id derivation, strict-schema lowering, reasoning replay, provider-identity tagging at the boundary.
- OAS가 소유하지 **않음**: policy, effect classification, Shell IR, descriptor dispatch, sandbox, approval. 이들은 소비자 측(예: MASC keeper / `agent_tools`)에 있고 본 RFC 범위 밖이다. 본 RFC는 **오직** `lib/llm_provider/` 아래 파일만 인용한다.

MASC는 본 문서에서 **이름이 붙은 소비자(named consumer)** 로만 등장한다 — 코드 의존성 0.

## 2. Goals / Non-Goals

### Goals
1. **typed, closed** canonical tool-call core (string/carrier blob 없음). 이것은 *provider boundary에서의 projection*이지, 두 번째 in-memory SSOT가 아니다.
2. coordinator가 parallel call을 **stream reconstruction을 가로질러 안정적으로** correlate/order 할 수 있게 하는 일급 `order_index`.
3. provider가 id를 주면 byte-for-byte 보존하고, id-less call은 name/arguments와 무관한 occurrence-unique opaque id를 block start 전에 한 번만 발급한다.
4. *reasoning 없음* 과 *config에 의해 reasoning suppressed* 를 구분하는 reasoning 링크.
5. tool call에서 provider identity 도달 가능 — 기존 `inference_telemetry.provider_kind` 필드를 duplicate 하지 않고.

### Non-Goals
- `output_schema`를 `tool_schema`로 relocate 하지 않음 (D7).
- tool-name → OAS builtin variant migration 없음. 본 RFC는 consumer-등록 `tool_schema.name : string`을 정확히 보존.
- execution, policy, effect 개념 없음.
- MCP `tools/call` 구현 없음. OpenAI Responses API canonicalization은 현재 구현되어 있으므로 Chat Completions와 같은 identity 불변식을 적용한다.
- telemetry-only 필드 없음: 추가되는 모든 필드는 이름 붙은 소비자를 가진다.

## 3. Current State (`origin/main` `9598bc99`, verified reads)

아래 인용은 working tree가 아니라 `origin/main`(`9598bc99`)에서 직접 읽은 것이다.

### 3.1 in-memory tool 표현
`lib/llm_provider/types.ml`:
- `ToolUse of { id : string; name : string; input : Yojson.Safe.t }` (`types.ml:209-213`).
- `ToolResult of { tool_use_id : string; content : string; is_error : bool; json : Yojson.Safe.t option; content_blocks : content_block list option }` (`types.ml:214-243`). **`json`**(WP4)이 이미 parsed structured payload를, **`content_blocks`**가 이미 multi-block result를 담는다. 5개 필드 모두 origin/main에 존재 확인.
- `api_response = { id; model; stop_reason; content : content_block list; usage; telemetry : inference_telemetry option }`. **`api_response` 자체에는 provider identity가 없다.**
- `inference_telemetry = { …; provider_kind : Provider_kind.t option; … }`. provider identity는 *존재* 한다 — `api_response.telemetry >>= fun t -> t.provider_kind`로 도달 가능하나, 이중 optional이고 의미상 "inference timing"에 속한다.
- `tool_schema = { name : string; description; parameters; strict : bool option }` (WP2 `strict`).

### 3.2 id 도출 (확장할 기존 인프라)
`api_common.ml`:
```ocaml
let fresh_tool_use_id () =
  let sequence = Atomic.fetch_and_add tool_use_id_sequence 1 in
  Printf.sprintf "call_oas_%s_%x_%x" process_scope (Unix.getpid ()) sequence
```
프로세스 namespace와 OCaml 5 `Atomic.fetch_and_add` sequence로 발급한다. name/arguments를 읽지 않으므로 동일 입력의 반복 call도 서로 다른 occurrence로 남고, 스트림 start에서 발급한 동일 id가 final `ToolUse`까지 유지된다.

### 3.3 provider별 call 구성 (오늘 id/order가 비롯되는 곳)
| Provider | Parse 지점 (verified) | id 출처 | 비고 |
|---|---|---|---|
| **Anthropic** | `api_common.ml:145-149` (`content_block_of_json`, `Some "tool_use"` arm) | native `"id"` | real wire id. parts 순서 = 등장 순서 |
| **OpenAI Chat Completions** | `backend_openai_parse.ml:283-284` (`tc \|> member "id" \|> to_string`) | native `"id"` | array index = 등장 순서 |
| **Gemini** | `backend_gemini.ml` | native-first, OAS allocation fallback | `FunctionCall.id`는 optional |
| **Ollama** | `backend_ollama.ml` | **native-first, OAS allocation fallback** | 아래 정정 참조 |
| **Streaming (전부)** | `streaming.ml` | native-first, OAS allocation fallback | start와 final identity가 동일 |

Gemini request lowering은 canonical `ToolUse.id`를 `functionCall.id`로, 대응하는
`ToolResult.tool_use_id`를 `functionResponse.id`로 그대로 내보낸다. name은 API의
필수 필드이므로 별도로 보존하되 correlation SSOT는 id다. 이 두 optional id
필드는 [Google Generative Language v1beta `content.proto`](https://github.com/googleapis/googleapis/blob/master/google/ai/generativelanguage/v1beta/content.proto)의
`FunctionCall.id`/`FunctionResponse.id` 계약을 따른다(확인 2026-07-11).

**정정 — Ollama는 native-only가 아니다.** 실제 코드는 provider id를 우선하고, 없으면 새 opaque id를 한 번 발급한다:
```ocaml
let id =
  match provider_id with
  | Some id -> id
  | None -> Api_common.fresh_tool_use_id ()
```
따라서 Ollama는 **per-call mixed-origin** 이다. OAS-allocated id도 opaque하고 사후-파싱 시점에 origin을 재계산할 수 없다 — 이것이 §6 Keystone의 근거다.

**정정 — `next_block_index`는 all-block-types 카운터다.** `streaming.ml`에서 이 카운터는 thinking(`:347,356`), text(`:383,392`), tool(`:405,414` 및 `:540,548`) 블록 모두에서 증가한다. 따라서 tool call들이 받는 인덱스는 text/thinking 블록과 interleave 되어 **non-contiguous** 하다. `order_index`를 이 카운터에 직접 묶으면 D3 stability test가 두 path의 블록-대-블록 정렬을 가정하게 된다(§6 D3, §8.2에서 정정).

### 3.4 구현 경계 (verified)
- `git grep 'provider_call_id\|order_index'` over `lib/` → **zero**. 두 개념 모두 신규.
- OpenAI **Responses API**는 `Streaming.responses_sse_to_events`가 `call_id`를 우선 보존하고, id-less output item에는 같은 OAS allocation invariant를 적용한다. `item_id`는 output-item routing identity이며 tool `call_id`로 재해석하지 않는다.
- `lib/llm_provider`에 **MCP `tools/call`** converter 없음. MCP transport/optional-dep는 RFC-OAS-016의 소비자 경계다.

### 3.5 request-level structured output (D7 boundary)
`provider_config.ml`이 structured-output을 **request** 관심사로 이미 보유:
`response_format = JsonSchema schema`로 표현하고
`validate_output_schema_request`로 검증한다. 올바르며 본 RFC는 이를
옮기지 않는다.

## 4. Proposed Canonical Types (typed, closed)

신규 모듈 `lib/llm_provider/canonical_tool.ml` / `.mli`. 의존성은 오직 `{Types; Provider_kind; Yojson}`. 이것은 **projection** layer다: 여기 어떤 타입도 `content_block`을 대체하지 않으며, provider boundary에서 `api_response.content`로부터 *도출* 된다.

아래 `.mli`는 Keystone 결정(K)에 따라 갈라지는 부분을 명시한다. K가 "제거"(권고)면 `id_origin` 필드/타입이 빠지고, K가 "유지"면 §6 D4 lane-B의 parse-site threading이 따라온다.

```ocaml
(* canonical_tool.mli — coordinator로의 WP8 handoff surface.
   Types.content_block의 tool call/result에 대한 projection이지, 두 번째 SSOT가 아니다. *)

(** Reasoning kind. closed variant — string carrier 없음. *)
type reasoning_kind =
  | Thinking          (** Anthropic [thinking] block. *)
  | Redacted_thinking (** Anthropic [redacted_thinking]. *)
  | Reasoning_content (** OpenAI_compat / GLM / DeepSeek [reasoning_content]. *)

type reasoning_state =
  { kind : reasoning_kind
  ; signature : string option
      (** Raw provider reasoning payload is not renderer-facing display data.
          Replay paths use Types.content_block directly. *)
  ; tokens : int option (** provider가 보고할 때 telemetry에서. *)
  }

(** per-call reasoning 링크. 부재가 모호하지 않도록 3-way (D6).
    [option]은 금지: "model이 안 냄"과 "config가 껐음"을 구분 못 함. *)
type reasoning_link =
  | No_reasoning (** provider가 reasoning 지원하나 이 call엔 안 냄. *)
  | Suppressed   (** request config로 비활성 (enable_thinking=false / clear_thinking). *)
  | Available of reasoning_state

(** provider boundary에서 projection된 단일 tool call. *)
type provider_tool_call =
  { call_id : string
      (** coordinator가 result↔call correlate에 쓰는 id.
          native wire id가 있으면 그것, 없으면 해당 call occurrence에 대해
          block start 전에 한 번 발급된 opaque OAS id. *)
  ; provider_kind : Provider_kind.t
      (** 이 call을 emit한 provider. projection 시점에 thread됨;
          optional telemetry 필드에서 읽지 않음 (D5). *)
  ; name : string (** consumer가 등록한 tool 이름; OAS는 의미를 분류하지 않음. *)
  ; arguments : Yojson.Safe.t
  ; order_index : int
      (** response 안에서 tool call들 사이의 등장 순서.
          ToolUse 블록만 필터한 뒤의 인덱스 — all-block next_block_index 아님 (D3).
          stream reconstruction을 가로질러 안정. *)
  ; reasoning : reasoning_link
  (* KEYSTONE lane-B (id_origin 유지) 채택 시에만 아래 필드 추가:
     ; id_origin : id_origin   (* Native | Synthesized; parse 지점에서 thread *) *)
  }

(** provider boundary에서 projection된 tool result. *)
type provider_tool_result =
  { call_id : string (** [provider_tool_call.call_id]와 correlate. *)
  ; content : string (** canonical string payload (ToolResult.content mirror). *)
  ; content_blocks : Types.content_block list option (** ToolResult.content_blocks mirror. *)
  ; structured_content : Yojson.Safe.t option
      (** [ToolResult.json] (WP4)의 projection. 새 parse 아님;
          request-level structured-output contract 아님 (D7). *)
  ; is_error : bool
  }

(** response에서 tool call들을 등장 순서로 projection. provider identity와
    reasoning을 태깅. 순수; 총(total). *)
val tool_calls_of_response
  :  provider_kind:Provider_kind.t
  -> reasoning_suppressed:bool
  -> Types.api_response
  -> provider_tool_call list

(** 단일 ToolResult 블록을 projection. non-ToolResult 블록엔 [None]. *)
val tool_result_of_block : Types.content_block -> provider_tool_result option
```

### 4.1 의도적으로 뺀 것 (anti-pattern bar를 우리 타입에도 적용)
- **`raw_provider_item : Yojson.Safe.t` 없음.** 연구 초안이 제안했으나 unconsumed blob carrier — telemetry-as-fix 시그니처 그 자체. round-trip 충실도는 이미 `content_block`(in-memory SSOT)이 provider별 재serialize로 제공한다. byte-exact replay가 미래에 필요하면 이름 붙은 소비자와 함께 별도 RFC로. 제거.
- **`canonical_call_id`를 `call_id`와 별도로 두지 않음.** id 필드는 하나. native-id provider는 native id, id-less provider는 occurrence-unique OAS allocation을 쓴다. 두 번째 "cross-provider stable" id는 correlation SSOT를 duplicate 한다.
- **tool *선언* 에 `namespace`/`portable_name`/`stable_id` 없음.** Tool identity는 consumer 등록 경계가 소유한다. WP8은 *call/result* 에 관한 것이지 *decl* 이 아니다.
- **tool decl에 `output_schema?` 생략** (D7). MCP per-tool `outputSchema` passthrough가 필요해지면 strict passthrough로 RFC-OAS-016 뒤에 gate, `tool_schema` 변경이 아니다.
- **`id_origin`은 Keystone(§6 K) 결정에 종속.** 권고는 제거. 유지 시 parse-site threading 필요(lane-B).

## 5. Per-Provider Conversion Design

`tool_calls_of_response`는 `response.content`를 list 순서로 walk 한다. 각 `ToolUse` 블록이 `provider_tool_call`이 되고, `order_index`는 **ToolUse 블록만 필터한 수열에서의 위치** 다(`content |> List.filter is_tool_use |> List.mapi`). provider identity와 reasoning-suppression은 parse를 소유하는 backend가 인자로 넘긴다(자기 `Provider_kind`와 자기 `enable_thinking` config를 안다) — optional telemetry에서 재도출하지 않는다.

| Provider | Parse 지점 (verified) | call_id 출처 | order_index | reasoning 출처 |
|---|---|---|---|---|
| **Anthropic** | `api_common.ml:145-149` | native `id` | tool-call 필터 후 위치 | 같은 `content`의 인접 `Thinking`/`RedactedThinking` 블록 |
| **OpenAI_compat (Chat Completions)** | `backend_openai_parse.ml:283-284` | native `id` | tool-call 필터 후 위치 | `reasoning_content` 필드 (있으면) |
| **Gemini** | `backend_gemini.ml` | native-first, OAS allocation fallback | tool-call 필터 후 위치 | `part.thought` 텍스트 블록 |
| **Ollama** | `backend_ollama.ml` | native-first, OAS allocation fallback | tool-call 필터 후 위치 | `reasoning` 필드 |
| **Streaming (전부)** | `streaming.ml` | native-first, OAS allocation fallback | tool-call 필터 후 위치 | stream state에 누적된 thinking delta |

> D5 표기 주의: `OpenAI_compat`은 **family(계열)이지 vendor가 아니다.** `Provider_kind.t = Anthropic \| Kimi \| OpenAI_compat \| Ollama \| Gemini \| Glm \| DashScope`이며 별도의 `OpenAI` variant는 없다(`provider_kind.mli` 확인). OpenAI와 일부 compat host가 이 variant를 공유하고, `Glm`/`Kimi`/`DashScope`는 별도다.

**구현/forward mapping:**
- **OpenAI Responses API**: `Streaming.responses_sse_to_events`가 `function_call.call_id`를 tool identity로 보존하고, `output_index`를 구조적 route로 사용한다. `item_id`는 call identity가 아니다. id-less item이면 block start 전에 OAS id를 발급한다.
- **MCP `tools/call`**: `lib/llm_provider`에 converter 없음. MCP는 소비자 측(RFC-OAS-016). *spec-level*: MCP `CallToolResult`가 `provider_tool_result`로 매핑(`content`→`content`, `structuredContent`→`structured_content`, `isError`→`is_error`). MCP per-tool `outputSchema`는 decl-level passthrough로 RFC-OAS-016에 deferred. MCP call의 id correlation은 coordinator의 관심사지 OAS의 것이 아니다.

이로써 N-of-M anti-pattern을 회피한다: **하나의** `tool_calls_of_response` 함수가 모든 provider의 projection을 하고, 각 backend가 canonical struct를 hand-roll 하지 않는다.

## 6. The 7 Decisions — Resolved / Sign-off

### D1 — SSOT vs side-representation → **RESOLVED (Keystone에 종속): Side projection. `content_block`이 in-memory SSOT.**
canonical 타입은 provider boundary에서 `tool_calls_of_response`로 계산되는 *read projection* 이다. SSOT로 만들면 모든 `ToolUse` 구성 지점(Anthropic, OpenAI_compat, Gemini, Ollama, streaming + 모든 `message_to_json` serialize)의 migration을 강제하는데, OAS는 여전히 `content_block`에서 provider wire format으로 재serialize 해야 하므로 이득이 없다. projection은 additive하고 risk가 가장 낮다. **고려한 반론:** SSOT canonical이면 `ToolUse`/`ToolResult` duplication을 지울 수 있다 — 그러나 그 블록들은 `Text`/`Thinking`/`Image` 같은 non-tool 블록과 하나의 ordered list에서 공존해야 하므로(`content_block list`의 역할) 거부. tool call을 평행 구조로 분리하면 ordering/correlation 문제를 *만들어내* 다시 풀어야 한다. projection 채택.

> **Keystone 의존성:** "zero construction-site change / zero blast radius"라는 D1의 표현은 **Keystone(K)이 `id_origin` 제거로 닫힐 때만 참** 이다. K를 유지(lane-B)하면 parse-site threading이 생기므로 D1의 그 문구는 거짓이 되어 lane-B와 함께 다시 쓰여야 한다. 두 주장을 동시에 유지하지 않는다.

### D2 / D4 — **SIGN-OFF (Keystone). `id_origin`은 순수 사후-파싱 projection에서 도출 불가.**

**문제 (검증됨):** `tool_calls_of_response : api_response -> _`는 parse *후* 에 돈다. 그 시점에 `ToolUse`는 `{ id; name; input }`(`types.ml:209-213`)이고 native-vs-OAS-allocated 구분은 **parse 지점에서만 알려졌다가 버려진** 상태다.
- Ollama는 native-id-first, OAS allocation fallback인 per-call mixed-origin이며 opaque allocation의 origin은 **재계산 불가** 다(§3.3).
- 문자열 모양(`call_..._...`)으로 origin을 역추정하는 것은 reparse / substring-classifier anti-pattern으로 금지.

따라서 `id_origin`을 채우려면 둘 중 하나다:
- **(A) 제거** — coordinator가 id를 opaque하게 다룬다.
- **(B) parse 지점에서 origin 기록** — 5개 site 변경(D1의 "zero blast radius" 주장을 폐기해야 함).

**판별 질문 (오너가 답해야 함):**
> `id_origin`으로 분기하는, `call_id` 동등성 dedup과 *구별되는* coordinator-side 소비자가 존재하는가?

추적: coordinator는 "같은 `call_id` → 같은 call occurrence"로 correlate 한다. native provider id와 OAS allocation 모두 occurrence-unique이므로 동일 name+args의 반복 call도 distinct하게 남는다. content equality를 identity/dedup으로 사용하지 않는다. **두 origin 모두 correlation 연산은 동일** — `id_origin`은 어떤 분기도 gate 하지 않는다. 행위를 바꾸지 않는 필드는 anti-pattern bar상 unconsumed.

| Lane | 내용 | 결과 | 권고 |
|---|---|---|---|
| **A (권고)** | `id_origin`/`native_id` 제거. coordinator는 `call_id` 동등성으로 dedup. | D1의 pure-projection / zero-blast-radius 주장이 **참이자 일관됨.** projection 아키텍처 보존. anti-pattern clean. | ✅ **채택 권고** |
| **B** | provenance 소비자(예: 감사 추적, origin-dependent retry)를 *명시* 하고 `native_id : string option`을 5개 parse site에 thread. | 일관됨. 단 D1의 "zero blast radius"를 폐기하고 cost를 인정해야 함. | 소비자 이름이 나오면 |

**D2/D4 모두 어느 lane이든 내부 일관성을 가진다. 동시에 두 속성(zero-blast-radius + consumed id_origin)을 주장하는 것만 금지.** 오너 결정 전까지 `id_origin`은 §4 `.mli`에서 주석 처리된 채로 둔다.

### D3 — `order_index` for parallel calls → **RESOLVED: tool-call들만의 등장 순서(filter+mapi), `next_block_index` 아님.**
Anthropic parallel tool use는 본질적 순서가 없으므로 등장 순서를 부여한다. 단 `next_block_index`(`streaming.ml:304`)는 thinking/text/tool **모든** 블록에서 증가하므로(§3.3) tool call이 받는 인덱스는 non-contiguous하고 다른 블록과 정렬을 가정하게 된다. 대신 `order_index`를 **tool call들만 필터한 수열의 인덱스** 로 정의한다(`content |> List.filter is_tool_use |> List.mapi`). batch path와 stream path에서 *동일하게* 계산하므로 contiguous하고, D3 stability invariant를 text/thinking 블록 정렬에서 분리한다. — **hash 아님**(identity지 order 아님). **alphabetical 아님**(model 의도 순서를 망침).

### D5 — `Provider_kind` 식별 → **RESOLVED: 필수 인자로 thread. `api_response`에 두 번째 필드 추가 안 함. `telemetry.provider_kind`에 의존 안 함.**
"api_response가 provider identity를 안 담는다"는 *거의* 참이다 — identity는 `api_response.telemetry >>= (.provider_kind)`로 도달 가능하나 이중 optional이고 의미상 "inference timing"에 속한다. parse를 하는 backend는 자기 `Provider_kind`를 **무조건** 알므로 `tool_calls_of_response ~provider_kind`가 필수 인자로 받아 각 call에 stamp 한다. 이로써 (a) `api_response`에 `telemetry.provider_kind`와 diverge 할 중복 필드 추가, (b) coordinator가 identity를 가장 필요로 할 때 `None`일 수 있는 optional 의존을 피한다. 명시적으로 회피한 duplication: **한 record에 두 `provider_kind` carrier.** `inference_telemetry.provider_kind`는 telemetry 출처로 남고, projection의 `provider_kind`는 call-correlation 출처다. 같은 backend가 공급하는 같은 값이며 독립적으로 mutate 되지 않는다. 타입은 `OpenAI_compat`이며 family를 식별한다(vendor 아님; §5 주).

### D6 — `reasoning_state` 링크 → **RESOLVED: 3-way `reasoning_link` variant, `option` 아님.**
`No_reasoning | Suppressed | Available of reasoning_state`. `option`은 "model이 안 냄"과 "config가 suppress"를 하나의 `None`으로 collapse 하는데, 그 구분이 요구사항 전부다. `Suppressed`는 request config(`enable_thinking = Some false` / `clear_thinking`)에서 도출되어 `~reasoning_suppressed`로 전달된다. `reasoning_state.kind`도 closed `reasoning_kind` variant(`Thinking | Redacted_thinking | Reasoning_content`)지 string이 아니다. `tokens`는 telemetry의 reasoning token을 재사용.

### D7 — `output_schema` 경계 → **RESOLVED: `provider_config.t`(request-level)에 유지. `tool_schema`로 옮기지 않음. `structured_content`는 `ToolResult.json`의 projection으로 다른 layer.**
`Provider_config.response_format = JsonSchema schema`는 **request** 관심사 —
"model 응답이 이 schema에 맞기를 원함" — 이며
`validate_output_schema_request`로 검증된다.
`provider_tool_result.structured_content`는 **response** 관심사 — tool이
*반환*한 parsed JSON으로, 이미 parsed된 `ToolResult.json`(WP4)에서
projection한다. 두 layer는 다르며 OAS 안에서 결합하면 안 된다: OAS는
반환된 `structured_content`를 request의 JSON Schema에 대해 검증하지
않는다 — 그 correlation은 소비자의 일이다. 새 parse 없음, relocation
없음, duplication 없음. 연구 초안의 `canonical_tool_decl.output_schema?`는
여기서 **제거** 되고, MCP per-tool `outputSchema` passthrough가 필요해지면
RFC-OAS-016(decl passthrough)으로 엄격히 scope, 절대 `tool_schema` 필드가
아니다 — `tool_schema`로 옮기는 것이 바로 D7이 금지하는 경계 위반이다.

## 7. Migration Plan (incremental, smallest-first) — 모듈 머지는 SIGN-OFF

전부 additive — 기존 타입 변경 없음 — 이므로 SSOT에 blast radius 0인 순수 추가로 ship 한다. **단, `canonical_tool.ml`을 실제로 머지할지는 SIGN-OFF(M).** in-repo 소비자(handoff serializer)가 없으면 fan-in==0 dead code이고, 이는 본 repo의 자체 측정 기준(컴파일러 unused-warning + fan-in==0)으로 dead, anti-pattern bar로 unconsumed surface다(모듈 입도에서의 "telemetry-as-fix" 시그니처). "ships first, smallest"가 unconsumed 모듈을 land 할 라이선스는 아니다.

| 항목 | 결정 | 권고 |
|---|---|---|
| **M** | 코드 모듈을 지금 머지 vs MASC ingestion 커밋 전까지 spec-level 유지 | **권고: spec-level 유지.** 실제 in-repo wiring point(handoff serializer + 그것을 exercise 하는 test)가 생길 때 code increment를 gate. test-only 참조는 약함. |

코드 머지가 승인되면 아래 순서로 ship 한다(각 increment는 Draft stacked PR; `types.ml`는 어느 것도 변경 안 함 → `origin/main`은 내내 green):

- **Increment 1 (smallest, 가장 먼저):** `canonical_tool.ml/.mli`에 타입 + `tool_result_of_block`(result projection — 기존 `ToolResult` 필드만 읽음, provider plumbing 없음). property test: `ToolResult → provider_tool_result` round-trip이 `content`/`is_error`/`structured_content` 보존. **backend 무변경.** 5개 `ToolResult` 필드(`tool_use_id`/`content`/`is_error`/`json`/`content_blocks`)는 origin/main에 존재 확인됨 → 진짜로 blast-radius 0인 유일한 increment. projection 타입이 컴파일되고 result path가 isolation에서 옳음을 증명.
- **Increment 2:** `tool_calls_of_response ~provider_kind ~reasoning_suppressed`. backend 하나 먼저 — OpenAI_compat Chat(native id, order = 필터 후 인덱스) — snapshot test. reasoning link = `No_reasoning`/`Available`만(config plumbing 없이는 `Suppressed` 불가; 둘 다 test). (Keystone lane-B 채택 시 여기서 parse-site threading 비용 발생.)
- **Increment 3:** Anthropic(native id + 인접 thinking → `Available`)과 Gemini(native-first/OAS fallback id, `part.thought` → reasoning) wiring.
- **Increment 4:** streaming reconstruction wiring — 같은 논리적 response에 대해 streaming-reconstructed `order_index` == non-streamed `order_index` 단언(D3 stability를 test로). 이때 `order_index`는 양쪽에서 **tool-call 필터 후 인덱스** 로 동일 계산하므로 all-block 정렬 가정이 없다.
- **Increment 5:** Ollama와 OpenAI Responses는 구현됨. MCP는 converter가 생길 때까지 spec-only.

## 8. Test Strategy

1. **Closedness / exhaustiveness:** `reasoning_kind`, `reasoning_link`(+lane-B의 `id_origin`)는 closed variant — projection의 `match`가 compile-time coverage를 강제. variant 추가 시 컴파일 깨짐(`Provider_kind.all`의 WP8 대응물).
2. **D3 stability (load-bearing):** 고정된 multi-tool response에 대해 batch parse path의 `order_index` == streaming-reconstructed path의 `order_index`. **양쪽 모두 ToolUse 필터 후 인덱스로 계산** — text/thinking 블록 정렬을 가정하지 않는다(§3.3 정정 반영). 1–4 call 생성 response에 대한 property test.
3. **D4 id correctness:** native-id provider → `call_id` == wire id; id-less provider → block start와 finalized `ToolUse`의 id가 같고 별도 stream/call occurrence끼리는 다름; 동일 name+args도 collapse하지 않음. Ollama → native가 있으면 그대로 보존. (lane-B 채택 시에만 `id_origin` 값 단언 추가.)
4. **D6 distinguishability:** suppressed-config response → `Suppressed`, no-reasoning response → `No_reasoning`, thinking response → `Available` — 세 distinct 값 단언(`option` 기반 설계는 이 test를 통과 못 함, 그것이 핵심).
5. **D7 non-coupling:** `structured_content`는 `ToolResult.json`이 `Some`일
   때만 채워짐; projection이 request-level structured-output contract를
   절대 읽지 않음을 단언(module boundary로 검증 — `canonical_tool`이
   `Provider_config`에 의존하지 않음).
6. **Boundary guard:** `canonical_tool.ml`의 의존 집합이 `{Types; Provider_kind; Yojson}` 임을 test/lint로 단언 — masc-mcp/policy/execution 모듈 없음. §1 boundary를 checkable invariant로 encode.

## 9. Open Risks

- **R1 — Reasoning↔call attribution은 content-block provider에서 heuristic.** Anthropic은 `thinking` 블록을 `tool_use` 블록 인접에 emit 하나 명시적 binding이 없다. 특정 call에 reasoning을 귀속하는 것은 positional inference지 wire 보장이 아니다. 완화: binding이 명백할 때만(단일 tool call, 또는 provider가 명시 link 제공) call에 reasoning 귀속; 아니면 call에 `No_reasoning`, reasoning은 response level에 둠. 3-way variant가 link를 날조하지 않고 정직하게 만든다.
- **R2 — Synthesized-id dedup collision은 의도적이나 surprising.** 동일 name+args의 두 Gemini call은 구성상 같은 `call_id`를 받는다. coordinator는 이를 instance-identity가 아니라 content-dedup으로 다뤄야 한다. (lane-A에서는 origin tag가 없으므로 이 의미를 문서로만 전달; lane-B에서는 `id_origin = Synthesized`로 표기.)
- **R3 — Forward mapping(Responses API, MCP)은 미검증.** §3.4상 spec-level. OAS가 Responses-API parse path를 얻으면 그 path의 D3/D4를 실제 wire shape에 대해 재도출해야 한다.
- **R4 — `order_index`의 cross-turn correlation 의미.** `order_index`는 intra-response 전용. turn을 가로지르는 correlation은 `call_id`를 써야 하며 `order_index`가 아니다.

---

**`origin/main`(`9598bc99`)에서 실제로 읽은 파일:** `lib/llm_provider/types.ml`, `api_common.ml`, `provider_kind.mli`, `provider_config.ml`, `backend_gemini.ml`, `backend_openai_parse.ml`, `backend_ollama.ml`, `streaming.ml`, `capabilities.ml`, `complete.ml`, `http_client.ml`, `discovery.ml`.

**Verified-absent (grep, zero hits):** `provider_call_id`, `order_index`, OpenAI Responses parse path, `lib/llm_provider` 내 MCP `tools/call` converter.

**검증된 정정 (초안 대비):** Ollama는 native-id-first + OAS allocation fallback이며; `next_block_index`는 all-block 카운터(`streaming.ml`)라 `order_index`는 tool-call 필터 후 인덱스여야 함; `Provider_kind.t`에 `OpenAI` variant 없음 — `OpenAI_compat`(family); OpenAI Responses path는 현재 구현됨; 헤더 SHA `0c2aef991`.
