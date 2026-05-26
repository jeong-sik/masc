(** Cascade_internal_error — the [masc_internal_error] ADT, its JSON codec,
    and the Prometheus accounting attached to construction.

    This module owns the *typed envelope* that the cascade layer uses to carry
    structured failures across the [Agent_sdk.Error.Internal _] boundary.  The
    sibling {!Cascade_error_classify} module owns the parser that turns SDK
    errors carrying the structured prefix back into this type.

    RFC-0142 Phase 2 PR-1 extraction: this module was carved out of
    [cascade_error_classify.ml] so that the parser and classifier no longer
    sit in the same translation unit as the ADT they target.  No behavioural
    change is intended — [Cascade_error_classify] re-exports the surface via
    [include Cascade_internal_error]. *)

(** {1 Cascade name} *)

val cascade_name_to_string : Cascade_name.t -> string

(** {1 Provider rejection payload}

    Carried inside {!No_tool_capable_provider} to record per-candidate rejection
    reasons.  The {!provider_rejection_reasons_of_assoc} and
    {!provider_rejections_of_assoc} JSON helpers are internal to this module
    and used by the parser in {!Cascade_error_classify}. *)

type provider_rejection = {
  provider_label : string;
  reason : string;
}

(** {1 Capacity backpressure source}

    Names the system component that issued the backpressure signal.  Used by
    operators and dashboards to attribute saturation to a specific tier. *)

type capacity_backpressure_source =
  | Provider_capacity
  | Client_capacity
  | Tier_admission
  | Cascade_slot

val capacity_backpressure_source_to_string :
  capacity_backpressure_source -> string

val capacity_backpressure_source_of_string :
  string -> capacity_backpressure_source option

(** {1 [masc_internal_error] ADT}

    Closed-sum type for every structured cascade-layer failure that crosses
    the [Agent_sdk.Error.Internal _] boundary.  New variants belong here;
    growing the {!Cascade_error_classify} substring catch-all is the
    anti-pattern this RFC is closing. *)

(** RFC-0158: typed denial reason carried by {!Retry_admission_denied}.
    Defined here (cascade layer) to avoid a dependency cycle with
    [Keeper_turn_cascade_budget].  The keeper layer re-exports via
    [type retry_admission_denial = Cascade_internal_error.retry_admission_denial]. *)

type retry_admission_denial =
  | Retry_budget_below_min of {
      projected_usable_budget_s : float;
      min_required_s : float;
      remaining_turn_budget_s : float;
      adaptive_timeout_s : float;
      allow_wall_clock_retry_budget : bool;
    }
  | First_attempt_budget_below_min of {
      projected_usable_budget_s : float;
      min_required_s : float;
      remaining_turn_budget_s : float;
    }

val retry_admission_denial_to_yojson :
  retry_admission_denial -> Yojson.Safe.t

type masc_internal_error =
  | Cascade_exhausted of {
      cascade_name : Cascade_name.t;
      reason : Keeper_types.cascade_exhaustion_reason;
    }
  | Capacity_backpressure of {
      cascade_name : Cascade_name.t;
      source : capacity_backpressure_source;
      detail : string;
      retry_after_sec : float option;
    }
  | Resumable_cli_session of {
      cascade_name : Cascade_name.t;
      detail : string;
      exit_code : int option;
    }
  | No_tool_capable_provider of {
      cascade_name : Cascade_name.t;
      configured_labels : string list;
      required_tool_names : string list;
      provider_rejections : provider_rejection list;
    }
  | Accept_rejected of {
      scope : string;
      model : string option;
      reason : string;
    }
  | Admission_queue_timeout of {
      keeper_name : string;
      cascade_name : Cascade_name.t;
      wait_sec : float;
    }
  | Admission_queue_rejected of {
      keeper_name : string;
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
  | Max_tokens_ceiling_violation of {
      cascade_name : Cascade_name.t;
      requested_max_tokens : int;
      provider_ceiling : int;
      reason : string;
    }
  | Ambiguous_post_commit of {
      is_timeout : bool;
      tools : string list;
      original_error : string;
    }
  (** RFC-0158: pre-dispatch admission denial.  The keeper decided not to
      attempt a provider call because the remaining turn budget was below the
      minimum required for a single attempt.  Semantically distinct from
      [Provider_timeout]: admission denial never reached the provider, so
      cascade rotation and supervisor pause-policy should treat it differently.

      [denial_reason] carries the typed budget breakdown from
      {!Keeper_turn_cascade_budget.retry_admission_denial}; [is_retry]
      distinguishes retry-path from first-attempt denials. *)
  | Retry_admission_denied of {
      denial_reason : retry_admission_denial;
      is_retry : bool;
    }
  (** RFC-0159 Phase A: typed substrate for raw [Agent_sdk.Error.Internal]
      construction sites.  Before Phase A, three sites built [Internal] with
      [Printexc.to_string exn] payloads that the classifier could not parse,
      so all of them fell through to the [Reason_internal_error] catch-all
      bucket.  These variants prefix the payload with the typed
      [[masc_oas_error]] envelope so {!Cascade_error_classify.classify_masc_internal_error}
      can route them to dedicated kinds. *)
  | Internal_unhandled_exception of { site : string; exn_repr : string }
  | Internal_bridge_exception of { caller : string; exn_repr : string }
  | Internal_contract_rejected of { reason : string }

(** {1 Codec} *)

val masc_internal_error_prefix : string
(** Envelope prefix used in [Agent_sdk.Error.Internal _] payloads built by
    {!sdk_error_of_masc_internal_error}.  The parser in
    {!Cascade_error_classify} matches on this prefix. *)

val masc_internal_error_to_json : masc_internal_error -> Yojson.Safe.t

(** {2 Per-field helpers used by the parser in {!Cascade_error_classify}} *)

val string_list_of_assoc : string -> Yojson.Safe.t -> string list
val provider_rejection_of_json : Yojson.Safe.t -> provider_rejection option
val provider_rejections_of_assoc :
  string -> Yojson.Safe.t -> provider_rejection list
val provider_rejection_reasons_of_assoc :
  string -> Yojson.Safe.t -> provider_rejection list
val provider_rejection_reasons : provider_rejection list -> string list
val string_opt_of_assoc : string -> Yojson.Safe.t -> string option

(** {1 Summaries and labels} *)

val summary_of_masc_internal_error : masc_internal_error -> string option
(** Operator-facing concise summary for structured errors where the raw JSON
    payload is too noisy for dashboard cards. *)

val kind_of_masc_internal_error : masc_internal_error -> string
(** Short label for each variant, used as the [kind] Prometheus label. *)

val cascade_name_of_masc_internal_error : masc_internal_error -> string
(** Cascade name from the error payload, or ["unknown"] for variants that
    fire outside cascade context. *)

(** {1 Prometheus accounting} *)

val masc_oas_error_total_metric : string
(** Prometheus counter metric name for structured MASC OAS errors.  Registered
    by this module at first load; do not register again. *)

val sdk_error_of_masc_internal_error :
  masc_internal_error -> Agent_sdk.Error.sdk_error
(** Convert a [masc_internal_error] to an SDK error, bumping the
    [masc_oas_error_total] Prometheus counter with [kind] and [cascade_name]
    labels. *)
