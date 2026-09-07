(** Inference_utils — inference utility functions.

    Usage helpers, UTF-8 sanitization, and concurrency diagnostics.

    @since 2.125.0 — extracted from Runtime *)

(** Compute total tokens from AGENT_CORE api_usage. *)
val total_tokens : Agent_core.Types.api_usage -> int

(** Zero usage marker. *)
val zero_usage : Agent_core.Types.api_usage

(** Extract usage from an api_response, defaulting to {!zero_usage}. *)
val usage_of_response : Agent_core.Types.api_response -> Agent_core.Types.api_usage

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
val sanitize_message_utf8 : Agent_core.Types.message -> Agent_core.Types.message

(** Maximum concurrent model calls (from [MASC_MAX_CONCURRENT_MODELS], default 8). *)
val max_concurrent_models : int
