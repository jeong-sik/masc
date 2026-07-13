(** Structured keeper-internal error envelopes carried through
    [Agent_sdk.Error.Internal]. *)

(** Canonical wire kind emitted for {!Capacity_backpressure}.  Receipt
    terminal projection and decoding consume this same value. *)
val capacity_backpressure_kind : string

type provider_rejection = {
  provider_label : string;
  reason : string;
}

type capacity_backpressure_source =
  | Provider_capacity
  | Client_capacity
  | Runtime_slot

val capacity_backpressure_source_to_string :
  capacity_backpressure_source -> string

val capacity_backpressure_source_of_string :
  string -> capacity_backpressure_source option

type capacity_retry_after =
  | Explicit of float
  | No_retry_hint

(** Legacy cause carried by persisted [Capacity_backpressure] envelopes. *)
type provider_cooldown_cause =
  | Cooldown_provider_capacity
  | Cooldown_soft_rate_limited
  | Cooldown_server_error
  | Cooldown_hard_quota
  | Cooldown_terminal_failure
  | Cooldown_provider_error
  | Cooldown_rejected

val provider_cooldown_cause_to_string : provider_cooldown_cause -> string
val provider_cooldown_cause_of_string : string -> provider_cooldown_cause option

(** [true] when waiting out the cooldown cannot resolve the cause (deterministic
    config/build/credential/quota/structural failure); [false] for transient
    causes expected to recover (capacity, HTTP 429, HTTP 5xx).  Drives whether a
    cooldown-block turn error is auto-recoverable or escalates.  #23438. *)
val provider_cooldown_cause_is_deterministic : provider_cooldown_cause -> bool

type runtime_exhaustion_reason =
  | Connection_refused
  | Dns_failure
  | No_providers_available
  | All_providers_failed
  | Candidates_filtered_after_cycles
  | Max_turns_exceeded
  | Session_conflict
  | Structural_attempt_timeout of { detail : string }
  | Capacity_exhausted
  | Other_detail of string

val runtime_exhaustion_reason_retryable : runtime_exhaustion_reason -> bool

val runtime_exhaustion_reason_to_label : runtime_exhaustion_reason -> string
(** Human-readable label carrying the [detail]/[message] payload inline,
    for {!summary_of_masc_internal_error} and log lines. Distinct from
    {!runtime_exhaustion_reason_to_json}'s bare wire tags. *)

val runtime_exhaustion_reason_to_json : runtime_exhaustion_reason -> Yojson.Safe.t
val runtime_exhaustion_reason_of_json : Yojson.Safe.t -> runtime_exhaustion_reason option

type accept_rejection_kind =
  | Accept_no_usable_progress
  | Accept_predicate_rejected

val accept_rejection_kind_to_string : accept_rejection_kind -> string
val accept_rejection_kind_of_string : string -> accept_rejection_kind option

type accept_response_shape =
  | Accept_response_empty
  | Accept_response_thinking_only
  | Accept_response_blank_text_only
  | Accept_response_tool_result_only
  | Accept_response_media_only
  | Accept_response_mixed_without_deliverable_content
  | Accept_response_has_deliverable_content

val accept_response_shape_to_string : accept_response_shape -> string
val accept_response_shape_of_string : string -> accept_response_shape option
val accept_response_shape_of_agent_sdk :
  Agent_sdk.Response_shape.content_shape -> accept_response_shape

type masc_internal_error =
  | Runtime_exhausted of {
      runtime_id : string;
      reason : runtime_exhaustion_reason;
    }
  | Capacity_backpressure of {
      runtime_id : string;
      source : capacity_backpressure_source;
      detail : string;
      retry_after : capacity_retry_after;
      cooldown_cause : provider_cooldown_cause option;
      (** [Some cause] iff this is a pre-dispatch provider-health cooldown block;
          [None] for genuine upstream capacity backpressure.  #23438. *)
    }
  | Resumable_cli_session of {
      runtime_id : string;
      detail : string;
      exit_code : int option;
    }
  | Accept_rejected of {
      scope : string;
      model : string option;
      reason_kind : accept_rejection_kind option;
      response_shape : accept_response_shape option;
      (* RFC-0271 §4.5: typed provider stop_reason for the rejected response.
         [MaxTokens] on an empty/thinking_only shape marks a truncation, distinct
         from a clean [EndTurn] no-progress terminal. Groundwork slice: threaded
         and serialized, not yet consumed by classification. *)
      stop_reason : Agent_sdk.Types.stop_reason option;
      reason : string;
    }
  | Turn_timeout of { elapsed_sec : float }
  | Provider_timeout of {
      budget_sec : float;
      keeper_turn_timeout_sec : float;
      estimated_input_tokens : int;
      source : string;
      remaining_turn_budget_sec : float option;
      min_required_sec : float;
      phase : string;
    }
  | Internal_unhandled_exception of {
      site : string;
      exn_repr : string;
      transport_error_kind : Llm_provider.Http_client.network_error_kind option;
    }
  | Internal_bridge_exception of {
      caller : string;
      exn_repr : string;
    }
  | Internal_contract_rejected of { reason : string }
  | Receipt_persistence_failed of { detail : string }

val masc_internal_error_prefix : string

val runtime_runner_execute_site : string

val blocker_detail_structured_max_chars : int
(** Upper bound (~2000) preserved for a [masc_oas_error] structured payload
    by {!cap_blocker_detail}. *)

val cap_blocker_detail : string -> string
(** [cap_blocker_detail s] bounds a keeper [blocker_info] detail string: a
    structured payload beginning with [masc_internal_error_prefix] (#9933) is
    preserved up to {!blocker_detail_structured_max_chars}; plain narrative
    text is truncated to the narrative budget (~200). Idempotent. *)

val masc_internal_error_to_json : masc_internal_error -> Yojson.Safe.t

val summary_of_masc_internal_error : masc_internal_error -> string option

val kind_of_masc_internal_error : masc_internal_error -> string

val runtime_id_of_masc_internal_error : masc_internal_error -> string

val accept_no_progress_retry_kind :
  masc_internal_error ->
  [ `Empty_no_progress | `Thinking_only_no_progress ] option

val accept_rejection_has_no_progress_retry_hint : masc_internal_error -> bool

val sdk_error_of_masc_internal_error :
  masc_internal_error -> Agent_sdk.Error.sdk_error

val parse_masc_internal_error_json :
  Yojson.Safe.t -> masc_internal_error option

val classify_masc_internal_error_of_string :
  string -> masc_internal_error option

val classify_masc_internal_error :
  Agent_sdk.Error.sdk_error -> masc_internal_error option
