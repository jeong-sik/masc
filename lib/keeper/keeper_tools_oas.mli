(** Keeper_tools_oas — Wrap keeper tools as [Agent_sdk.Tool.t] for [Agent.run].

    Bridges [Keeper_tool_dispatch_runtime.execute_keeper_tool_call] dispatch
    to [Agent_sdk.Tool.t list] via [Tool_bridge.oas_tool_of_masc]. Tool
    execution reads the current context from [ctx_snapshot]
    (immutable), enabling [Agent.run] to manage messages while
    keeper tools access the working context for status/metrics.

    @since Phase 4 — Keeper → Agent.run() migration *)

(** Bundle returned by [make_tool_bundle]: the [Agent_sdk.Tool.t list]
    plus a [cleanup] thunk that releases the per-turn sandbox
    runtimes. *)
type tool_bundle =
  { tools : Agent_sdk.Tool.t list
  ; cleanup : unit -> unit
  }

(** Per-keeper tool usage view from [Keeper_registry]. *)
val tool_usage_for_keeper : string -> (string * Keeper_types.tool_call_entry) list

(** Project [tool_usage_for_keeper] to a JSON array. *)
val tool_usage_json : string -> Yojson.Safe.t

(** Most-recently-used tool names for a keeper, capped to [limit]
    (default 5). *)
val recent_tools_for_keeper : ?limit:int -> string -> string list

(** Record an internal keeper tool call in the telemetry registry. *)
val record_keeper_internal_tool_call
  :  tool_name:string
  -> success:bool
  -> duration_ms:int
  -> unit

(** Repeated-failure guardrail threshold sourced from
    [Env_config.KeeperToolExec.max_consecutive_tool_failures].
    A tool is blocked after this many consecutive failures with the
    same (tool_name, args_hash) key; resets on success. *)
val max_consecutive_failures : int

(** Thread-safe per-tool consecutive-failure counters shared by the
    handler closures in one tool bundle. *)
type workflow_rejection_info = Keeper_tools_oas_workflow.workflow_rejection_info

type failure_counts

val create_failure_counts : unit -> failure_counts

val failure_count_get : failure_counts -> string -> int

val failure_count_record_failure : failure_counts -> string -> int

val failure_count_reset : failure_counts -> string -> unit

val failure_count_jump_to : failure_counts -> string -> target:int -> int

val workflow_rejection_count_record : failure_counts -> string -> int

val workflow_rejection_count_reset : failure_counts -> unit

(** Test-only: inject a failure counter with [blocked_at] set to
    [failure_count_ttl_seconds + 60] seconds in the past.
    The next [failure_count_get] call for [key] will treat it as
    expired and return 0. *)
val inject_stale_failure_count_for_test : failure_counts -> string -> int -> unit

(** Reset process-global retry-log dedupe state. Test-only entry point
    for suites that assert the first occurrence of a tool failure emits
    at ERROR. *)
val reset_tool_retry_dedupe_for_testing : unit -> unit

type structured_error_payload_parse_error =
  | Structured_error_payload_json_decode_error of string
  | Structured_error_payload_non_object of { received : string }

val structured_error_payload_parse_error_to_string :
  structured_error_payload_parse_error -> string

val structured_error_payload_fields_result :
  string -> ((string * Yojson.Safe.t) list, structured_error_payload_parse_error) result
(** Parse the nested JSON object sometimes carried in a failed tool result's
    [error] string. Malformed JSON and non-object JSON are distinct typed
    errors; callers that only need the legacy normalization fallback can ignore
    those errors explicitly. *)

(** Normalize a raw tool result string into the canonical JSON
    envelope. Success → [{"ok":true,"result":...}]; failure →
    [{"ok":false,"error":...,"detail":...}], preserving structured
    [failure_class]/[recoverable]/[error_class] fields when present.
    Plain text is wrapped as a string under [result] / [error]. *)
val normalize_tool_result
  :  ?workflow_rejection_recovery_fields:(string * Yojson.Safe.t) list
  -> success:bool
  -> string
  -> string

(** Build top-level recovery hints for workflow rejections.
    These fields are intentionally outside [detail] so the LLM sees the
    required self-correction without parsing nested tool-specific payloads. *)

(** Promote a tool-specific [recovery_plan] out of a deterministic
    failure payload so the next call can route without scraping nested
    detail text. *)

(** Error-class string for transient mutex contention failures. *)
val transient_mutex_contention_error_class : string

(** Record a deterministic tool failure metric with telemetry labels. *)
val record_deterministic_tool_failure_metric
  :  tool_name:string
  -> Keeper_tool_deterministic_error.deterministic_reason
  -> unit

(** Build the structured, recoverable envelope used when a keeper tool
    raises mutex EDEADLK / "Resource deadlock avoided". *)
val transient_mutex_contention_tool_error
  :  tool_name:string
  -> error_text:string
  -> ?backtrace:string
  -> unit
  -> string

(* Handlers moved to [Keeper_tools_oas_handler] — see
   keeper_tools_oas_handler.mli for [make_keeper_tool_handler],
   [make_tool_bundle], and [make_tools]. *)


(** Build the per-tool handler closure used by both internal and
    alias tool entries. The closure dispatches via
    [execute_keeper_tool_call_with_outcome] using [~name] as the
    INTERNAL tool name (telemetry SSOT). [~input_schema] is the
    internal tool schema used for pre-execution validation. Public aliases
    validate their LLM-facing payload before translation to the internal
    payload. *)

(** Build the keeper's full [tool_bundle]: internal tools +
    alias-registered (public name) tools that translate input to
    internal payloads. The cleanup thunk releases per-turn sandbox
    runtimes (Docker case). *)

(** Convenience over [make_tool_bundle] returning only [.tools]. *)
