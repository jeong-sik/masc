(** ZhipuAI Glm native backend.

    Uses OpenAI-compatible wire format with Glm-specific extensions:
    - [thinking] parameter: [{"type":"enabled","clear_thinking":true}]
    - [reasoning_content] in response and streaming delta
    - String error codes (e.g., ["1305"])

    Auth: Bearer token from API key directly, or JWT generated from
    [{id}.{secret}] format keys (JWT requires [digestif], not yet added).

    Ref: docs.z.ai/api-reference/llm/chat-completion

    @since 0.83.0

    @stability Internal
    @since 0.93.1 *)

open Types

(** Semantic classification of a Glm API error from its documented code. *)
type glm_error_class =
  | Glm_quota_exceeded
  | Glm_rate_limited
  | Glm_auth_error
  | Glm_server_error
  | Glm_invalid_request
  | Glm_context_overflow
  (** oas#2947: code 1261 "Prompt exceeds max length" — the request
        exceeded the model context window. Not retryable at the transport:
        only the consumer's context recovery can make progress. *)

type glm_error_origin =
  | Provider_response
  | Response_parse

type glm_error =
  { code : string option
  ; message : string
  ; error_class : glm_error_class
  ; is_retryable : bool
  ; origin : glm_error_origin
  }

exception Glm_api_error of glm_error

type request_artifact

val request_payload : request_artifact -> string
val request_output_token_receipt : request_artifact -> Types.output_token_receipt

(** Classify a Glm error code + message into a semantic class.
    Code-based classification takes priority; message keywords are fallback. *)
val classify_glm_error : code:string -> glm_error_class * bool

(** Map a Glm error class to the equivalent HTTP status code.
    Used by complete.ml to normalize provider-specific codes
    into the shared HTTP error path. *)
val http_code_of_glm_error_class : glm_error_class -> int

(** Parse glm's structured error envelope from a raw response body.
    [None] when the body is not JSON or carries no error object. Used by the
    streaming path to classify a non-200 rejection by its documented [code]
    field before provider identity is erased (oas#2947). *)
val check_glm_error : string -> glm_error option

(** Build a Glm chat completion request body.
    Delegates to {!Backend_openai.build_request} and injects
    Glm-specific [thinking] parameter when [enable_thinking] is set. *)
val build_request
  :  ?stream:bool
  -> config:Provider_config.t
  -> messages:message list
  -> ?tools:Yojson.Safe.t list
  -> unit
  -> string

val build_request_artifact
  :  ?stream:bool
  -> config:Provider_config.t
  -> messages:message list
  -> ?tools:Yojson.Safe.t list
  -> unit
  -> request_artifact

(** Parse a Glm chat completion response into the typed parse outcome.
    Handles Glm-specific string error codes and extracts [reasoning_content]
    as a {!Types.Thinking} content block.

    Malformed JSON and GLM provider errors (documented string codes) raise
    {!Glm_api_error}. A blank-content 200 is returned as
    [Error (Backend_openai_parse.Empty_completion _)] carrying the typed
    [stop_reason], so the caller can route an overflow empty turn to the
    shared empty-completion overflow classifier rather than dropping the
    stop_reason (oas#2621). *)
val parse_response_result
  :  string
  -> (api_response, Backend_openai_parse.parse_error) result

(** Raising variant of {!parse_response_result} for raise-style callers and the
    coverage tests: returns the parsed [api_response] on success and raises
    {!Glm_api_error} on any parse/provider error (an empty completion raises
    rather than surfacing its typed [stop_reason]). Production paths use
    {!parse_response_result} so an overflow empty turn's [stop_reason] reaches
    the overflow classifier (oas#2621). *)
val parse_response : string -> api_response

(** Extract [reasoning_content] from Glm response body and prepend
    as a {!Types.Thinking} content block to the parsed response. *)
val extract_reasoning_content : api_response -> string -> api_response

(** Parse a GLM SSE streaming chunk using the resolved typed reasoning
    dialect. Delegates to {!Streaming.parse_openai_sse_chunk}. *)
val parse_stream_chunk
  :  streaming_reasoning:Reasoning_dialect.streaming_reasoning
  -> string
  -> Streaming.openai_sse_parse_result
