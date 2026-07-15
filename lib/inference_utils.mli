(** Inference_utils — inference utility functions.

    Usage helpers, UTF-8 sanitization, and concurrency diagnostics.

    @since 2.125.0 — extracted from Runtime *)

(** Parse an environment variable as int, clamped to [[min_v, max_v]].
    Returns [default] when unset or unparseable. *)
val int_of_env_default : string -> default:int -> min_v:int -> max_v:int -> int

(** Compute total tokens from OAS api_usage. *)
val total_tokens : Agent_sdk.Types.api_usage -> int

(** Zero usage marker. *)
val zero_usage : Agent_sdk.Types.api_usage

(** Extract usage from an api_response, defaulting to {!zero_usage}. *)
val usage_of_response : Agent_sdk_response.api_response -> Agent_sdk.Types.api_usage

(** Convert elapsed seconds to integer milliseconds for telemetry. Positive
    sub-1ms intervals are rounded up to 1; non-positive or non-finite
    intervals return 0. *)
val elapsed_duration_ms : float -> int

(** Measure wall-clock latency of a thunk in milliseconds. *)
val timed : (unit -> 'a) -> 'a * int

(** Replace invalid UTF-8 bytes with U+FFFD and replace disallowed ASCII
    control characters with spaces (except LF/CR/TAB). *)
val sanitize_text_utf8 : string -> string

(** Recursively scrub every {!Yojson.Safe.t} string node through
    {!sanitize_text_utf8}.  Used by telemetry writers before persisting or
    broadcasting JSON that may have absorbed invalid UTF-8 from tool output
    or LLM-provided text. *)
val sanitize_json_utf8 : Yojson.Safe.t -> Yojson.Safe.t

(** Sanitize text content blocks in a message. *)
val sanitize_message_utf8 : Agent_sdk.Types.message -> Agent_sdk.Types.message

(** Sanitize text content blocks in a list of messages. *)
val sanitize_messages_utf8 : Agent_sdk.Types.message list -> Agent_sdk.Types.message list

(** Maximum concurrent model calls (from [MASC_MAX_CONCURRENT_MODELS], default 8). *)
val max_concurrent_models : int
