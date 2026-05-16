(** Keeper_hooks_oas_types — pure type definitions and helpers extracted
    from Keeper_hooks_oas (2762 LoC godfile).

    Holds the cost_status verdict ADT + its pure label/reason converters.
    State-touching keeper_hooks_oas operations remain in Keeper_hooks_oas.
    Re-included by Keeper_hooks_oas so existing callers continue to use
    [Keeper_hooks_oas.cost_status] etc. unchanged. *)

type cost_status =
  | Cost_reported         (** Cost trusted because OAS reported it. *)
  | Cost_known_free       (** Runtime is structurally unmetered. *)
  | Cost_no_tokens        (** Usage carried zero tokens and no positive cost. *)
  | Cost_usage_missing    (** OAS returned no usage record. *)
  | Cost_usage_untrusted  (** Usage failed [classify_usage_trust]. *)
  | Cost_runtime_unknown  (** Runtime owner could not be classified. *)
  | Cost_oas_cost_unreported
      (** OAS returned trusted billable usage but did not report cost. *)
(** Per-event cost-ledger verdict. *)

val cost_status_to_string : cost_status -> string
(** Stable wire string for [cost_status]. *)

val cost_status_reason : cost_status -> string
(** Human-readable explanation for an operator log. *)

val cost_status_for_event :
  runtime_unknown:bool ->
  runtime_unmetered:bool ->
  usage_missing:bool ->
  usage_trusted:bool ->
  input_tokens:int -> output_tokens:int -> cost_usd:float -> cost_status
(** Pure decision: which [cost_status] applies given the inputs above? *)

(** Internal: cost-status wire labels exposed for keeper_hooks_oas's
    [classify_cost_usd_source] which composes a string verdict separately
    from [cost_status_to_string]. *)
val cost_label_usage_missing : string
val cost_label_usage_untrusted : string
val cost_label_oas_cost_unreported : string

val redact_inference_telemetry_json : Yojson.Safe.t -> Yojson.Safe.t
(** Redact provider/model identity fields from OAS inference telemetry while
    preserving non-identifying runtime counters and timings. *)

val inference_telemetry_to_runtime_json :
  Agent_sdk.Types.inference_telemetry -> Yojson.Safe.t
(** JSON projection for keeper-facing persistence/API surfaces.  Concrete
    provider/model identity is collapsed before leaving the OAS boundary. *)

val context_max_of_telemetry :
  Agent_sdk.Types.inference_telemetry option -> int
(** Provider-reported context window max, or [0] when telemetry omits it. *)

type thinking_log_summary =
  { thinking_present : bool
  ; thinking_blocks : int
  ; thinking_chars : int
  ; redacted_thinking_blocks : int
  ; thinking_kind : string
  }
(** Redacted metadata for provider thinking blocks.  [thinking_chars] counts
    only non-redacted [Thinking.content] bytes; raw content is never included
    in this summary. *)

val summarize_thinking_blocks :
  Agent_sdk.Types.content_block list -> thinking_log_summary
(** Summarize thinking block presence for logs/metrics without exposing raw
    thinking content. *)

type pr_review_action_metric_event = {
  action : string;
  pr_number : int option;
  comment_id : int option;
  success : bool;
  route_via : string option;
  credential : Yojson.Safe.t option;
  identity_attestation : Yojson.Safe.t option;
}
(** Parsed PR-review action telemetry derived from keeper tool I/O. *)

type pr_work_action_metric_event = {
  work_action : string;
  work_source : string;
  work_ref : string option;
  pr_url : string option;
  command : string option;
  success : bool;
  route_via : string option;
}
(** Parsed PR create/push/commit/add telemetry derived from keeper tool I/O. *)

val normalize_pr_review_action : string -> string option
(** Internal: PR-review action label canonicalizer (COMMENT / APPROVE /
    REQUEST_CHANGES / REPLY). Exposed for keeper_hooks_oas.ml's parsers. *)

val runtime_lane_label : string
(** The neutral runtime lane label used by keeper telemetry where concrete
    provider/model identity should not surface (consumed by many call sites
    in keeper_hooks_oas.ml). *)

type tool_execution_summary = {
  tool_name : string;
  provider : string;
  outcome : string;
  duration_ms : float;
}
(** Per-tool-call record persisted in the keeper's trajectory. *)

val tool_execution_summary :
  tool_name:string ->
  model:string -> success:bool -> duration_ms:float -> tool_execution_summary
(** Build a [tool_execution_summary] from raw turn fields. *)

val usage_has_tokens : Agent_sdk.Types.api_usage -> bool
(** [true] when the usage record carries a non-zero token count. *)

val is_keeper_board_write_tool_name : string -> bool
(** [true] when the tool writes to the shared MASC board; subject to
    extra guard rules. *)

val current_keeper_model : Keeper_types.keeper_meta -> string
(** Neutral runtime lane used for keeper-facing tool-call telemetry.
    Concrete provider/model identity is OAS-owned. *)

(** Internal: stop-reason string labels exposed for keeper_hooks_oas.ml
    consumers that emit them across multiple call sites. *)
val stop_reason_label_end_turn : string
val stop_reason_label_tool_use : string
val stop_reason_label_max_tokens : string
val stop_reason_label_stop_sequence : string
val stop_reason_label_unknown : string

val zero_usage : Agent_sdk.Types.api_usage
(** Internal: zero-token api_usage sentinel used by classify_usage_trust
    when telemetry is missing. *)
