(** Consolidated constants for the llm_provider library.

    Centralises downstream handoff evidence, cache TTL, and endpoint defaults
    so they are defined once and referenced everywhere.

    @since 0.99.0 *)

(* ── HTTP handoff evidence ───────────────────────── *)

module Http = struct
  (** HTTP status codes that downstream coordinators may use when deciding
      whether to hand work to another provider. OAS exposes the codes;
      orchestration lives outside the SDK. 498 = Groq Flex tier capacity
      exceeded. *)
  let cascadable_codes = [ 401; 403; 429; 498; 500; 502; 503; 529 ]
end

(* The former unknown-model [max_tokens] fallback (16384, env
   OAS_MAX_TOKENS_DEFAULT) was removed: when neither the caller nor the
   capability catalog declares an output ceiling, request builders omit
   the field and the provider applies the model's real limit. An
   invented value is shared by thinking and answer and truncates long
   reasoning mid-thought on catalog-silent models. Anthropic (the one
   wire that requires the field) fails loudly via
   [Backend_anthropic.required_max_output_tokens]. *)

(* ── Cache ───────────────────────────────────────── *)

module Cache = struct
  let default_ttl_sec = 300
end

(* ── HTTP response body truncation ───────────────── *)

module Truncation = struct
  let max_error_body_length = 200
end

(* ── Endpoints ──────────────────────────────────── *)

(** Default endpoint URLs for local LLM servers.
    Single source of truth — all code should reference these
    constants instead of hardcoding URL literals.
    @since 0.105.0 *)
module Endpoints = struct
  (** Default port for llama.cpp servers.
      Ollama uses 11434 — configure via endpoint config or LLM_ENDPOINTS env. *)
  let default_llama_port = 8085

  let default_url = "http://127.0.0.1:" ^ string_of_int default_llama_port
  let default_url_localhost = "http://localhost:" ^ string_of_int default_llama_port
  let local_prefix = "http://127.0.0.1"
  let localhost_prefix = "http://localhost"
end
