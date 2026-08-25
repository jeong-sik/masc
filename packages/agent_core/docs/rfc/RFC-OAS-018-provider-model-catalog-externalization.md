# RFC-OAS-018: Provider/Model Catalog Externalization

| | |
|---|---|
| Status | Draft |
| Author | jeong-sik (with Claude analysis) |
| Created | 2026-05-12 |
| Target | `agent_sdk` (oas) |
| Supersedes | PR #1536 (`refactor/ollama-endpoint-constant`, closed as antipattern reinforcement) |
| Sibling | RFC-OAS-015 (mutable cleanup), RFC-OAS-016 (mcp optional), RFC-OAS-017 (coordinator-shape leak) |

## 0. Summary

OAS 의 `lib/` 안에 *vendor*, *model name*, *endpoint port*, *capability dispatcher*, *pricing table* 이 source-level 로 박혀 있다. 같은 SDK 가 "MASC 를 모른다" 와 자매 약속인 "Ollama / Qwen / Gemma / Kimi 를 모른다" 가 깨져 있고, *추가 vendor* 마다 core 변이가 강제되는 *closed-sum dispatch* 가 누적 중이다.

본 RFC 는 이 leak 을 *4-phase* 로 외부 catalog 화한다. 한 PR 로 240 사이트 rewrite 는 *명시적 비목표* (CLAUDE.md §Workaround Rejection Bar #3 N-of-M).

## 1. Inventory (line-pinned, 2026-05-12 main `8d8402f6`)

| Surface | Site count | 진단 |
|---|---|---|
| Model-name literals in `lib/` | **240** in 25 files | catalog data leak |
| Hardcoded local-LLM ports (`:11434`, `:8085-8090`) | **85** | endpoint assumption leak |
| `starts_with` model-string dispatchers in `capabilities.ml` | **35** | CLAUDE.md §Workaround Sig #2 (string classifier) |
| `Provider_kind.t` closed-sum variants | **11** | extension-by-core-mutation |

Model literal regex: `"(qwen[^"]*|llama-?[0-9][^"]*|gemma-?[0-9][^"]*|claude-[a-z]+-[0-9][^"]*|gpt-[0-9][^"]*|deepseek[^"]*|kimi-[^"]*)"`.

Top-leak files (count per file):
- `lib/llm_provider/pricing.ml` — 46 literals
- `lib/llm_provider/discovery.ml` — 28 literals + `:11434` hot path
- `lib/llm_provider/capabilities.ml` — 23 literals + 35 `starts_with` (1238 LOC, candidate for split)
- `lib/llm_provider/backend_ollama.ml` — 20 literals
- `lib/llm_provider/model_meta.ml` — 19 literals (incl. `"qwen3.5-35b"` × 6, `"llama-4-maverick"` × 2)
- `lib/llm_provider/transport_kimi_cli.ml` — 15 literals
- `lib/provider.ml` — 13 literals
- `lib/agent/agent_config.ml` — 2 literals (file removed 2026-07-21, test-only surface cut)
- `lib/completion_contract.ml` — 2 literals (`"claude-haiku-4-5-20251001"` × 2)

11 `Provider_kind.t` variants (`lib/llm_provider/provider_kind.ml:9-23`):
`Anthropic | OpenAI_compat | Ollama | Kimi | Gemini | Glm | DashScope | Claude_code | Gemini_cli | Kimi_cli | Codex_cli`.

### 1.1 Concrete leak examples

```ocaml
(* lib/llm_provider/model_meta.ml:82  — test embeds vendor+size *)
let%test "qwen3.5-35b inferred as cloud" =
  let m = for_model_id "qwen3.5-35b" in
  ...

(* lib/llm_provider/capabilities.ml:434+  — 35 starts_with branches *)
else if starts_with "qwen3"   ...
else if starts_with "llama-4" || starts_with "llama4" ...
else if starts_with "gemma-4" ...

(* lib/llm_provider/capabilities.ml:590  — size token list *)
[ "27b"; "31b" ] |> List.exists (fun sz -> String.equal token sz)

(* lib/llm_provider/discovery.ml:73, :633  — port assumption *)
| None -> "http://127.0.0.1:11434"
let default_scan_ports = [ 8085; 8086; 8087; 8088; 8089; 8090; 11434 ]

(* lib/llm_provider/discovery.ml:455-463  — Ollama recognition by port *)
let url_is_ollama url = match port url with Some 11434 -> true | _ -> ...
```

## 2. Non-goals (명시적 거부)

- 한 PR 로 240 사이트 fix — N-of-M 함정.
- `starts_with` 분류기를 더 정교하게 만드는 보강 — string 분류기 #2.
- Provider_kind 에 새 variant 추가 (`XAI`, `Mistral` 등) — 동일 패턴 누적. 본 RFC 합의 전 PR 거부.
- compile-time embedded JSON (`[%blob "models.json"]`) — 결과적으로 lib 안에 다시 박힘. 거부.
- prefix dispatcher 에 hex/glob lint 추가하는 "guard" PR — 본 RFC 는 *데이터
  자체* 를 옮기는 것이지 *문자열 검사 를 강화* 하는 것이 아님.

## 3. Goal — typed catalog interface

```ocaml
(* lib/llm_provider/catalog_intf.mli — Phase 0 *)
module type CATALOG = sig
  type t

  type entry =
    { provider_tag : string  (* opaque — e.g. "anthropic", "ollama-local-1" *)
    ; capabilities : Capabilities.capabilities
    ; pricing : Pricing.pricing
    ; locality : [ `Local | `Remote ]
    ; max_context_tokens : int
    ; max_output_tokens : int
    ; params_millions : int option  (* "27b" -> 27_000 *)
    }

  val lookup : t -> model_id:string -> entry option
  val provider_endpoints : t -> tag:string -> string list
end
```

SDK 핵심 가정:
- Catalog 채우는 책임은 *SDK 밖*: user config TOML (production), in-memory fixture (test), example asset (demo).
- `lookup` 결과 `None` → typed `Unknown_model of string` 에러 fail-closed. PR #1539 의 `unpriced_model : string option` 은 본 RFC 의 *partial path* — Phase 2 에서 typed error 로 승급.
- `Provider.t` 는 abstract; *closed sum 제거*. 호출자는 capability flags 와 transport 종류로 판단, vendor name 으로 분기하지 않음.

## 4. Phases (each = own PR, own gate)

### Phase 0 — Foundations
- 본 RFC 머지.
- `lib/llm_provider/catalog_intf.mli` (interface only, 구현 0). 본 RFC 머지 직후 stub PR.
- `docs/rfc/oas-018/inventory.md` 에 240 사이트 file:line 고정 (drift 감지 baseline).
- **G0**: `catalog_intf.mli` 추가, lib 동작 0 변경.

### Phase 1 — Catalog provider parallel, prefix dispatch survives
- `lib/llm_provider/catalog_toml.ml` (TOML 로더), `lib/llm_provider/catalog_default.ml` (in-memory minimal default).
- `Capabilities.for_model_id` / `Pricing.pricing_for_model` 는 *Catalog lookup 우선, miss 시 기존 prefix dispatch fallback*.
- **G1**: 기존 240 사이트 *그대로*. 새 catalog path 가 read-side 에 옵션적으로 합류. 모든 기존 test green.

### Phase 2 — Catalog primary, prefix dispatch deprecated
- `Capabilities.for_model_id` 의 prefix 갈래를 `[@@deprecated "RFC-OAS-018 Phase 2"]`.
- 새 `Catalog_only.for_model_id` 가 production primary.
- 기존 `pricing_for_model` zero-default 제거 (PR #1539 의 `unpriced_model` 길과 통합 → `result` 반환).
- **G2**: Phase 1 fallback path 가 *read-only*. 새 코드는 catalog 만 사용 (lint).

### Phase 3 — Prefix dispatch removal + Provider_kind narrowing
- `capabilities.ml:434-590` (35 starts_with) 삭제. `model_meta.ml:82-200` test 도 catalog fixture 로 교체.
- `Provider_kind.t` narrow:
  ```ocaml
  type t =
    | Anthropic                       (* native protocol *)
    | OpenAI_compat of { vendor : string }   (* opaque tag — replaces Ollama/Kimi/Gemini/Glm/DashScope/OpenAI_compat *)
    | Gemini_native                   (* protocol family, not vendor *)
    | Cli_subprocess of { kind : string }    (* replaces Claude_code/Gemini_cli/Kimi_cli/Codex_cli *)
  ```
  11 → 4 variants. capability 차이는 catalog 에 위임.
- **G3 lint**: lib/ 에서 `qwen|llama-|gemma-|gpt-|claude-[a-z]+-[0-9]|deepseek|kimi-` 검색 0건 (RFC artifacts 와 catalog loader 제외).

### Phase 4 — Endpoint discovery decoupling
- endpoint owner가 `endpoint_protocol`과 catalog capability를 명시한다. Discovery는 URL, port, model id, response prose, chat template에서 protocol/capability를 추론하지 않는다.
- `/api/tags`는 이미 `Ollama_native`로 선언된 endpoint의 model inventory probe일 뿐 provider classifier가 아니다. schema 불일치는 endpoint-local typed failure로 반환한다.
- legacy `url_is_ollama`/port classifier, `scan_local_endpoints`, `OAS_DISCOVERY_PORTS`, `/api/show` template inference는 호환 fallback 없이 삭제한다.
- **G4 lint**: discovery production path에서 `url_is_ollama|template_has_tool_support|/api/show` 0건. protocol별 probe는 closed variant match로만 선택한다.

## 5. Drift guards (CI lint)

`scripts/check-sdk-vocabulary.sh` 신설 (SDK independence regression gate):

```bash
# Phase 별 staged enforcement
PHASE_GATE="${OAS_VOCAB_PHASE:-0}"
case "$PHASE_GATE" in
  0) MODE=warn ;;
  1) MODE=warn ;;
  2) MODE=warn ;;
  3) MODE=error  # G3
     PATTERN_MODEL='qwen|llama-|gemma-|gpt-[0-9]|claude-[a-z]+-[0-9]|deepseek|kimi-'
     ;;
  4) MODE=error  # G4 includes G3
     PATTERN_DISCOVERY='url_is_ollama|template_has_tool_support|scan_local_endpoints|/api/show'
     ;;
esac
# Allow-list: lib/llm_provider/catalog_*, docs/, assets/
```

이 가드는 *데이터 가 옮겨갔는지* 검사하는 것이지 *문자열 검사로 fix 한다* 가 아니다 (CLAUDE.md feedback: lint with hardcoded phrase list ≠ structural — 본 가드의 structural 부분은 *데이터 분리 가 끝났는가* 의 *증거* 로만 동작).

## 6. Backward compatibility

- Phase 1 동안 catalog 미설정 사용자 → fallback (기존 동작 유지).
- Phase 3 cutover 직전 minor release 에 README + CHANGELOG 명시.
- Phase 4 discovery classifier와 port scan은 compatibility fallback 없이 삭제한다.
- `assets/catalog_defaults.toml` 을 example 로 추가 (compiled-in 아닌 *문서 자산*).
- `Provider_kind_legacy.t` alias 를 한 minor (`0.200.x`) 동안 유지 후 제거.

## 7. Open questions

- Catalog 파일 위치: `$XDG_CONFIG_HOME/oas/catalog.toml` 우선, fallback `./oas-catalog.toml`. RFC-OAS-016 (MCP optional config) 와 같은 convention 채택.
- Size token (`27b`, `31b`) → `params_millions : int option` 으로 일반화. 모델별 사이즈 variant 는 catalog entry id 로 표현.
- Multi-generation drift (같은 `claude-haiku-4-5` 가 시점에 따라 capability 변경) → 본 RFC scope 밖, RFC-OAS-019 후보.
- Catalog hot-reload (server 재기동 없이 reload) → Phase 4 후 별도 RFC.

## 8. Non-blocking dependencies

- PR #1539 (`max_cost_usd` unpriced model fail-closed) — Phase 2 에서 typed `Unknown_model` 로 흡수, 그 전까지는 호환.
- RFC-OAS-016 (mcp optional) — 외부화 패턴 동일, coherent.
- RFC-OAS-017 (coordinator-shape) — 직접 의존성 없음.
- RFC-OAS-015 (mutable cleanup) — 직접 의존성 없음.

## 9. Verification / Exit criteria

| Phase | Exit gate |
|---|---|
| 0 | `catalog_intf.mli` 머지, inventory.md 머지, lib 동작 byte-for-byte 동일 |
| 1 | catalog loader + fallback, 기존 test 100% green, 새 catalog 테스트 alcotest suite 1개 |
| 2 | prefix dispatch `[@@deprecated]`, 모든 lib 호출 catalog 경유 (call-site lint) |
| 3 | lib/ 에 모델 family literal 0건, Provider_kind 4 variants |
| 4 | URL/port/template classifier 0건, endpoint protocol + capabilities declaration-driven, malformed probe가 endpoint-local failure로 관측됨 |

## 10. References

- CLAUDE.md §Workaround Rejection Bar — signatures #2 (string classifier) + #3 (N-of-M)
- `lib/agent/agent_tools.mli` — exact registered-name lookup contract
- RFC-OAS-015 — mutable cleanup phased precedent
- RFC-OAS-016 — mcp optional dependency (외부화 패턴 자매)
- 측정 명령: `rg '"(qwen[^"]*|llama-?[0-9][^"]*|gemma-?[0-9][^"]*|claude-[a-z]+-[0-9][^"]*|gpt-[0-9][^"]*|deepseek[^"]*|kimi-[^"]*)"' lib/ | wc -l` → 240 (2026-05-12 main `8d8402f6`)
