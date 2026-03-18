(** Llm — Vendor-agnostic LLM client for the Perpetual Agent Runtime.

    Provides structured chat/completion calls to any LLM provider via
    OpenAI-compatible API format. Local llama.cpp runtimes and remote APIs
    (Claude, GLM, Gemini, OpenRouter) are supported through a unified
    interface.

    Re-exports {!Llm_types} and {!Llm_orchestration} for backward
    compatibility.

    @since 2.61.0 *)

(** {1 Provider Types}

    All types are re-exported from {!Llm_types} to ensure nominal
    equality across [Llm], [Llm_types], and [Llm_provider_oas]. *)

type provider = Llm_types.provider =
  | Llama
  | Claude
  | OpenAI
  | Gemini
  | Glm_cloud
  | OpenRouter
  | Custom of string

type model_spec = Llm_types.model_spec = {
  provider : provider;
  model_id : string;
  max_context : int;
  api_url : string;
  api_key_env : string option;
  cost_per_1k_input : float;
  cost_per_1k_output : float;
}

(** {1 Message Types} *)

type role = Llm_types.role = System | User | Assistant | Tool
type message = Llm_types.message

type tool_def = Llm_types.tool_def = {
  tool_name : string;
  tool_description : string;
  parameters : Yojson.Safe.t;
}

type tool_call = Llm_types.tool_call = {
  call_id : string;
  call_name : string;
  call_arguments : string;
}

type token_usage = Llm_types.token_usage

val total_tokens : token_usage -> int

(** {1 Request/Response} *)

type completion_request = Llm_types.completion_request = {
  model : model_spec;
  messages : message list;
  temperature : float;
  max_tokens : int;
  tools : tool_def list;
  response_format : [ `Text | `Json ];
}

type completion_response = Llm_types.completion_response = {
  content : Agent_sdk.Types.content_block list;
  tool_calls : tool_call list;
  usage : token_usage;
  model_used : string;
  latency_ms : int;
}

(** Extract text content from a completion response. *)
val text_of_response : completion_response -> string

(** {1 Core Functions} *)

(** Call LLM with structured request.
    Uses subprocess curl for HTTP — no Eio runtime dependency.
    Optional [timeout_sec] overrides provider HTTP timeout (seconds) for this call.
    @return Ok response on success, Error message on failure. *)
val complete :
  ?timeout_sec:int ->
  completion_request ->
  (completion_response, string) result

(** Cascade — try models in order until one succeeds.
    Each request targets a different model. First success wins.
    Optional [accept] can reject a syntactically successful response and force
    the cascade to continue with the next model.
    Optional [timeout_sec] sets an overall wall-clock budget (seconds) for the
    full cascade. Remaining budget is applied per-attempt.
    @return Ok response from first successful model, Error if all fail. *)
val cascade :
  ?accept:(completion_response -> bool) ->
  ?timeout_sec:int ->
  completion_request list ->
  (completion_response, string) result

(** Streaming completion for a single request.
    Invokes [on_event] for each SSE event from the LLM provider.
    Returns the assembled final response.
    Falls back to batch completion if streaming is unavailable.

    @since 2.110.0 *)
val call_provider_stream :
  ?timeout_sec:float ->
  completion_request ->
  on_event:(Llm_provider.Types.sse_event -> unit) ->
  (completion_response, string) result

(** {1 Concurrency Control} *)

(** Maximum concurrent cascade calls (from MASC_MAX_CONCURRENT_LLM env,
    default 2). *)
val max_concurrent_llm : int

(** Number of permits currently available (0 = all slots busy). *)
val llm_semaphore_available : unit -> int

(** Number of permits currently in use. *)
val llm_permits_in_use : unit -> int

(** {1 Helpers} *)

(** Built-in model specs for common configurations. *)
val llama_default : model_spec
val claude_opus : model_spec
val claude_sonnet : model_spec
val openai_default : model_spec
val glm_cloud : model_spec
val gemini_pro : model_spec

(** Resolve the canonical default local model through the provider registry.
    Falls back to the first available execution model or GLM if parsing fails. *)
val default_local_model_spec : unit -> model_spec

(** Preferred model labels for execution defaults, resolved from explicit env
    overrides first, then available remote provider credentials, then any
    explicitly configured local model. *)
val default_execution_model_labels : unit -> string list

(** Preferred model labels for verifier defaults. *)
val default_verifier_model_labels : unit -> string list

(** Resolve the first callable execution default.
    Returns [Error _] instead of silently forcing a local model. *)
val default_execution_model_spec : unit -> (model_spec, string) result

(** Resolve the first callable verifier default.
    Returns [Error _] instead of silently forcing a local model. *)
val default_verifier_model_spec : unit -> (model_spec, string) result

(** Create a message. *)
val system_msg : string -> message
val user_msg : string -> message
val assistant_msg : string -> message
val tool_msg : name:string -> call_id:string -> string -> message

(** Extract text content from a message. *)
val text_of_message : message -> string

(** Repair malformed UTF-8 in arbitrary text. *)
val sanitize_text_utf8 : string -> string

(** Repair malformed UTF-8 in a single message before request serialization. *)
val sanitize_message_utf8 : message -> message

(** Repair malformed UTF-8 across a message list before request serialization. *)
val sanitize_messages_utf8 : message list -> message list

(** Estimate token count for a message list (heuristic: ~4 chars per token). *)
val estimate_tokens : message list -> int

(** Parse model strings and keep only models that are callable in the current
    environment. Invalid specs and specs with missing API keys are skipped. *)
val available_model_specs_of_strings : string list -> model_spec list

(** Run a text-only single-prompt cascade over an ordered model list. *)
val run_prompt_cascade :
  ?temperature:float ->
  ?timeout_sec:int ->
  ?accept:(completion_response -> bool) ->
  ?system:string ->
  model_specs:model_spec list ->
  max_tokens:int ->
  prompt:string ->
  unit ->
  (completion_response, string) result

(** Stable cache key for a completion request. Useful for cache inspection and
    deterministic tests. *)
val cache_key_of_request : completion_request -> string

(** Parse model spec from string like "glm:glm-4.7",
    "claude:opus", "default", or "default:gemini-2.5-flash".
    Splits at the first ':' only, so model IDs may contain additional ':'. *)
val model_spec_of_string : string -> (model_spec, string) result

(** String representation of provider. *)
val string_of_provider : provider -> string

(** {1 OAS Type Adapters} *)

(** Map a masc-mcp model_spec to an OAS Provider.config.
    Returns None for Custom providers. *)
val to_oas_provider : model_spec -> Agent_sdk.Provider.config option

(** Convert a masc message to an OAS Types.message.
    System messages return None (they belong in system_prompt).
    Tool messages map to User with ToolResult content. *)
val to_oas_message : message -> Agent_sdk.Types.message option

(** Convert an OAS Types.message back to a masc message. *)
val of_oas_message : Agent_sdk.Types.message -> message

(** Convert OAS api_usage to masc token_usage. *)
val of_oas_usage : Agent_sdk.Types.api_usage -> token_usage

(** Convert masc token_usage to OAS api_usage. *)
val to_oas_usage : token_usage -> Agent_sdk.Types.api_usage
