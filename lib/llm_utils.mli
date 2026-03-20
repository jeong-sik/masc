(** Llm_utils — LLM utility functions.

    Usage helpers, UTF-8 sanitization, token estimation, and
    concurrency diagnostics.

    @since 2.125.0 — extracted from Cascade *)

(** Parse an environment variable as int, clamped to [[min_v, max_v]].
    Returns [default] when unset or unparseable. *)
val int_of_env_default : string -> default:int -> min_v:int -> max_v:int -> int

(** Compute total tokens from OAS api_usage. *)
val total_tokens : Agent_sdk.Types.api_usage -> int

(** Zero usage sentinel. *)
val zero_usage : Agent_sdk.Types.api_usage

(** Extract usage from an api_response, defaulting to {!zero_usage}. *)
val usage_of_response : Llm_provider.Types.api_response -> Agent_sdk.Types.api_usage

(** Measure wall-clock latency of a thunk in milliseconds. *)
val timed : (unit -> 'a) -> 'a * int

(** Replace invalid UTF-8 bytes with U+FFFD. *)
val sanitize_text_utf8 : string -> string

(** Sanitize text content blocks in a message. *)
val sanitize_message_utf8 : Agent_sdk.Types.message -> Agent_sdk.Types.message

(** Sanitize text content blocks in a list of messages. *)
val sanitize_messages_utf8 : Agent_sdk.Types.message list -> Agent_sdk.Types.message list

(** Heuristic token estimate (~4 chars/token). *)
val estimate_tokens : Agent_sdk.Types.message list -> int

(** Maximum concurrent LLM calls (from [MASC_MAX_CONCURRENT_LLM], default 8). *)
val max_concurrent_llm : int

(** Atomic counter tracking in-flight LLM calls (observability only). *)
val inflight : int Atomic.t

(** Available LLM permits: [max_concurrent_llm - inflight]. *)
val llm_semaphore_available : unit -> int

(** LLM permits currently in use. *)
val llm_permits_in_use : unit -> int
