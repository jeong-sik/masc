(** Cascade_internal_error — the [masc_internal_error] ADT, its JSON codec,
    and the Prometheus accounting attached to construction.

    RFC-0142 Phase 2 PR-1: this module was extracted from
    [cascade_error_classify.ml] (lines 12-474 of the original file) without
    behavioural change.  The parser and CLI preflight stayed behind in
    {!Cascade_error_classify}.  That file now
    re-exports this surface via [include Cascade_internal_error] so callers
    that reference [Cascade_error_classify.masc_internal_error],
    [Cascade_error_classify.Cascade_exhausted], etc. continue to compile
    unchanged. *)

let cascade_name_to_string = Cascade_name.to_string

type provider_rejection = {
  provider_label : string;
  reason : string;
}

type capacity_backpressure_source =
  | Provider_capacity
  | Client_capacity
  | Tier_admission
  | Cascade_slot

let capacity_backpressure_source_to_string = function
  | Provider_capacity -> "provider_capacity"
  | Client_capacity -> "client_capacity"
  | Tier_admission -> "tier_admission"
  | Cascade_slot -> "cascade_slot"

let capacity_backpressure_source_of_string = function
  | "provider_capacity" -> Some Provider_capacity
  | "client_capacity" -> Some Client_capacity
  | "tier_admission" -> Some Tier_admission
  | "cascade_slot" -> Some Cascade_slot
  | _ -> None

(* RFC-0158: typed denial reason carried by {!Retry_admission_denied}.
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

let retry_admission_denial_to_yojson = function
  | Retry_budget_below_min
      { projected_usable_budget_s; min_required_s; remaining_turn_budget_s;
        adaptive_timeout_s; allow_wall_clock_retry_budget } ->
    `Assoc
      [
        ("kind", `String "retry_budget_below_min");
        ("projected_usable_budget_s", `Float projected_usable_budget_s);
        ("min_required_s", `Float min_required_s);
        ("remaining_turn_budget_s", `Float remaining_turn_budget_s);
        ("adaptive_timeout_s", `Float adaptive_timeout_s);
        ("allow_wall_clock_retry_budget", `Bool allow_wall_clock_retry_budget);
      ]
  | First_attempt_budget_below_min
      { projected_usable_budget_s; min_required_s; remaining_turn_budget_s } ->
    `Assoc
      [
        ("kind", `String "first_attempt_budget_below_min");
        ("projected_usable_budget_s", `Float projected_usable_budget_s);
        ("min_required_s", `Float min_required_s);
        ("remaining_turn_budget_s", `Float remaining_turn_budget_s);
      ]

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
  | Turn_timeout of {
      elapsed_sec : float;
    }
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
  (* RFC-0158: pre-dispatch admission denial — the keeper decided not to
     attempt a provider call because the remaining turn budget was below
     the minimum required for a single attempt.  Distinct from
     [Provider_timeout] (case 1: provider tried and timed out) because
     admission denial never reached the provider; cascade rotation and
     supervisor pause-policy should treat it differently. *)
  | Retry_admission_denied of {
      denial_reason : retry_admission_denial;
      is_retry : bool;
    }
  (* RFC-0159 Phase A: typed substrate for the three raw exception
     construction sites previously emitting [Agent_sdk.Error.Internal
     (Printexc.to_string exn)] payloads that the classifier could not
     parse, falling through to the [Reason_internal_error] catch-all. *)
  | Internal_unhandled_exception of {
      site : string;
      exn_repr : string;
    }
  | Internal_bridge_exception of {
      caller : string;
      exn_repr : string;
    }
  | Internal_contract_rejected of {
      reason : string;
    }

let masc_internal_error_prefix = "[masc_oas_error] "

let string_list_of_assoc key json =
  match Json_field.list json key |> Json_field.to_option with
  | None -> []
  | Some values ->
    values
    |> List.filter_map (function
         | `String value -> Some value
         | _ -> None)
;;

let provider_rejection_of_json json =
  let provider_label =
    Json_field.string json "provider_label" |> Json_field.to_option
    |> Option.value ~default:""
  in
  match Json_field.string json "reason" |> Json_field.to_option with
  | Some reason -> Some { provider_label; reason }
  | None -> None
;;

let provider_rejections_of_assoc key json =
  match Json_field.list json key |> Json_field.to_option with
  | None -> []
  | Some values -> List.filter_map provider_rejection_of_json values
;;

let provider_rejection_reasons_of_assoc key json =
  string_list_of_assoc key json
  |> List.map (fun reason -> { provider_label = ""; reason })

let provider_rejection_reasons rejections =
  rejections
  |> List.map (fun r -> String.trim r.reason)
  |> List.filter (fun reason -> reason <> "")
  |> Json_util.dedupe_keep_order

let provider_rejections_json rejections =
  `List
    (List.map
       (fun r ->
         `Assoc
           [
             ("provider_label", `String r.provider_label);
             ("reason", `String r.reason);
           ])
       rejections)

let string_opt_of_assoc key json =
  Json_field.string json key |> Json_field.to_option
;;

let masc_internal_error_to_json = function
  | Cascade_exhausted { cascade_name; reason } ->
    let cascade_name = cascade_name_to_string cascade_name in
    `Assoc
      [
        ("kind", `String "cascade_exhausted");
        ("cascade_name", `String cascade_name);
        ("reason", Keeper_types.cascade_exhaustion_reason_to_json reason);
      ]
  | Capacity_backpressure { cascade_name; source; detail; retry_after_sec } ->
    let cascade_name = cascade_name_to_string cascade_name in
    `Assoc
      [
        ("kind", `String "capacity_backpressure");
        ("cascade_name", `String cascade_name);
        ("source", `String (capacity_backpressure_source_to_string source));
        ("detail", `String detail);
        ("retry_after_sec", Json_util.float_opt_to_json retry_after_sec);
      ]
  | Resumable_cli_session { cascade_name; detail; exit_code } ->
    let cascade_name = cascade_name_to_string cascade_name in
    `Assoc
      [
        ("kind", `String "resumable_cli_session");
        ("cascade_name", `String cascade_name);
        ("detail", `String detail);
        ("exit_code", Json_util.int_opt_to_json exit_code);
      ]
  | No_tool_capable_provider
      {
        cascade_name;
        configured_labels;
        required_tool_names;
        provider_rejections;
      } ->
    let cascade_name = cascade_name_to_string cascade_name in
    let rejection_reasons = provider_rejection_reasons provider_rejections in
    `Assoc
      [
        ("kind", `String "no_tool_capable_provider");
        ("cascade_name", `String cascade_name);
        ("configured_candidate_count", `Int (List.length configured_labels));
        ("required_tool_names", Json_util.json_string_list required_tool_names);
        ("rejected_candidate_count", `Int (List.length provider_rejections));
        ("provider_rejections", provider_rejections_json provider_rejections);
        ("rejection_reasons", Json_util.json_string_list rejection_reasons);
      ]
  | Accept_rejected { scope; model; reason } ->
    `Assoc
      [
        ("kind", `String "accept_rejected");
        ("scope", `String scope);
        ("model", Json_util.string_opt_to_json model);
        ("reason", `String reason);
      ]
  | Admission_queue_timeout { keeper_name; cascade_name; wait_sec } ->
    let cascade_name = cascade_name_to_string cascade_name in
    `Assoc
      [
        ("kind", `String "admission_queue_timeout");
        ("keeper_name", `String keeper_name);
        ("cascade_name", `String cascade_name);
        ("wait_sec", `Float wait_sec);
      ]
  | Admission_queue_rejected { keeper_name; reason } ->
    `Assoc
      [
        ("kind", `String "admission_queue_rejected");
        ("keeper_name", `String keeper_name);
        ("reason", `String reason);
      ]
  | Turn_timeout { elapsed_sec } ->
    `Assoc
      [
        ("kind", `String "turn_timeout");
        ("elapsed_sec", `Float elapsed_sec);
      ]
  | Provider_timeout
      {
        budget_sec;
        keeper_turn_timeout_sec;
        estimated_input_tokens;
        source;
        remaining_turn_budget_sec;
        min_required_sec;
        phase;
      } ->
    `Assoc
      [
        ("kind", `String "provider_timeout");
        ("budget_sec", `Float budget_sec);
        ("keeper_turn_timeout_sec", `Float keeper_turn_timeout_sec);
        ("estimated_input_tokens", `Int estimated_input_tokens);
        ("source", `String source);
        ( "remaining_turn_budget_sec",
          Json_util.float_opt_to_json remaining_turn_budget_sec );
        ("min_required_sec", `Float min_required_sec);
        ("phase", `String phase);
      ]
  | Max_tokens_ceiling_violation
      { cascade_name; requested_max_tokens; provider_ceiling; reason } ->
    let cascade_name = cascade_name_to_string cascade_name in
    `Assoc
      [
        ("kind", `String "max_tokens_ceiling_violation");
        ("cascade_name", `String cascade_name);
        ("requested_max_tokens", `Int requested_max_tokens);
        ("provider_ceiling", `Int provider_ceiling);
        ("reason", `String reason);
      ]
  | Ambiguous_post_commit { is_timeout; tools; original_error } ->
    `Assoc
      [
        ("kind", `String "ambiguous_post_commit");
        ("is_timeout", `Bool is_timeout);
        ("tools", Json_util.json_string_list tools);
        ("original_error", `String original_error);
      ]
  | Retry_admission_denied { denial_reason; is_retry } ->
    `Assoc
      [
        ("kind", `String "retry_admission_denied");
        ("denial_reason", retry_admission_denial_to_yojson denial_reason);
        ("is_retry", `Bool is_retry);
      ]
  | Internal_unhandled_exception { site; exn_repr } ->
    `Assoc
      [
        ("kind", `String "internal_unhandled_exception");
        ("site", `String site);
        ("exn_repr", `String exn_repr);
      ]
  | Internal_bridge_exception { caller; exn_repr } ->
    `Assoc
      [
        ("kind", `String "internal_bridge_exception");
        ("caller", `String caller);
        ("exn_repr", `String exn_repr);
      ]
  | Internal_contract_rejected { reason } ->
    `Assoc
      [
        ("kind", `String "internal_contract_rejected");
        ("reason", `String reason);
      ]

let summarize_list ?(empty = "none") values =
  match values with
  | [] -> empty
  | _ -> String.concat ", " values

let summarize_provider_rejections rejections =
  match provider_rejection_reasons rejections with
  | [] -> "none"
  | reasons -> String.concat "; " reasons

let summary_of_masc_internal_error = function
  | Capacity_backpressure { cascade_name; source; detail; retry_after_sec } ->
      let retry_after =
        match retry_after_sec with
        | Some value -> Printf.sprintf "; retry_after=%.1fs" value
        | None -> ""
      in
      Some
        (Printf.sprintf
           "Capacity backpressure blocked cascade %s; source=%s; detail=%s%s"
           (cascade_name_to_string cascade_name)
           (capacity_backpressure_source_to_string source)
           detail
           retry_after)
  | No_tool_capable_provider
      {
        cascade_name;
        configured_labels;
        required_tool_names;
        provider_rejections;
      } ->
      let cascade_name = cascade_name_to_string cascade_name in
      Some
        (Printf.sprintf
           "No tool-capable provider for cascade %s; required_tools=[%s]; rejected_candidate_count=%d; rejection_reasons=[%s]; configured_candidate_count=%d"
           cascade_name
           (summarize_list required_tool_names)
           (List.length provider_rejections)
           (summarize_provider_rejections provider_rejections)
           (List.length configured_labels))
  | Provider_timeout
      {
        budget_sec;
        keeper_turn_timeout_sec;
        estimated_input_tokens;
        source;
        remaining_turn_budget_sec;
        min_required_sec;
        phase;
      } ->
      let remaining =
        match remaining_turn_budget_sec with
        | Some value -> Printf.sprintf "%.1fs" value
        | None -> "unknown"
      in
      Some
        (Printf.sprintf
           "Provider timeout exhausted; phase=%s; source=%s; budget=%.1fs; remaining=%s; min_required=%.1fs; estimated_input_tokens=%d; keeper_turn_timeout=%.1fs"
           phase source budget_sec remaining min_required_sec
           estimated_input_tokens keeper_turn_timeout_sec)
  | Max_tokens_ceiling_violation
      { cascade_name; requested_max_tokens; provider_ceiling; reason } ->
    Some
      (Printf.sprintf
         "Invalid max_tokens budget for cascade %s; requested_max_tokens=%d; provider_ceiling=%d; reason=%s"
         (cascade_name_to_string cascade_name)
         requested_max_tokens
         provider_ceiling
         reason)
  (* Variants without a custom long-form summary: callers fall back to
     [kind_of_masc_internal_error] / the JSON payload.  Enumerated
     explicitly so adding a new [masc_internal_error] variant forces
     a decision on whether it deserves a long-form summary string. *)
  | Retry_admission_denied { denial_reason; is_retry } ->
      Some
        (Printf.sprintf
           "Pre-dispatch admission denied; is_retry=%b; reason=%s"
           is_retry
           (retry_admission_denial_to_yojson denial_reason
            |> Yojson.Safe.to_string))
  | Cascade_exhausted _
  | Resumable_cli_session _
  | Accept_rejected _
  | Admission_queue_timeout _
  | Admission_queue_rejected _
  | Turn_timeout _
  | Ambiguous_post_commit _
  | Internal_unhandled_exception _
  | Internal_bridge_exception _
  | Internal_contract_rejected _ -> None

(* #9933: classify emitted [masc_oas_error] payloads by kind so
   dashboards and Grafana alerts can watch the fleet-wide rate per
   error class (cascade_exhausted vs provider_timeout vs
   ambiguous_post_commit, etc.) rather than reading the free-form
   BDI blocker string.  Historical provider-timeout events accumulated across 9 keepers in 24h
   without an aggregate signal — this counter is the per-kind surface.

   Emit point is this constructor so all 14 call sites of
   [sdk_error_of_masc_internal_error] are covered automatically,
   without changing their signatures or threading [keeper_name]
   through callers that do not have it readily.  A follow-up PR
   can add a [keeper] label once every construction site has the
   name in scope. *)
let masc_oas_error_total_metric = "masc_oas_error_total"

let () =
  Prometheus.register_counter
    ~name:masc_oas_error_total_metric
    ~help:
      "Total MASC-internal errors emitted as Agent_sdk.Error.Internal \
       payloads, classified by structured error kind. Labels: \
       kind (cascade_exhausted | capacity_backpressure | resumable_cli_session | \
       no_tool_capable_provider | accept_rejected | \
       admission_queue_timeout | admission_queue_rejected | \
       turn_timeout | provider_timeout | retry_admission_denied | \
       max_tokens_ceiling_violation | \
       ambiguous_post_commit | internal_unhandled_exception | \
       internal_bridge_exception | internal_contract_rejected), \
       cascade_name (originating cascade or \"unknown\" for \
       cascade-less variants)."
    ()

let kind_of_masc_internal_error = function
  | Cascade_exhausted _ -> "cascade_exhausted"
  | Capacity_backpressure _ -> "capacity_backpressure"
  | Resumable_cli_session _ -> "resumable_cli_session"
  | No_tool_capable_provider _ -> "no_tool_capable_provider"
  | Accept_rejected _ -> "accept_rejected"
  | Admission_queue_timeout _ -> "admission_queue_timeout"
  | Admission_queue_rejected _ -> "admission_queue_rejected"
  | Turn_timeout _ -> "turn_timeout"
  | Provider_timeout _ -> "provider_timeout"
  | Max_tokens_ceiling_violation _ -> "max_tokens_ceiling_violation"
  | Ambiguous_post_commit _ -> "ambiguous_post_commit"
  | Retry_admission_denied _ -> "retry_admission_denied"
  | Internal_unhandled_exception _ -> "internal_unhandled_exception"
  | Internal_bridge_exception _ -> "internal_bridge_exception"
  | Internal_contract_rejected _ -> "internal_contract_rejected"

(* #10285: which cascade emitted this error.  See sibling docstring
   in cascade_error_classify.ml history for the rationale — operators
   could not attribute cascade-level error rates without this label. *)
let cascade_name_of_masc_internal_error = function
  | Cascade_exhausted { cascade_name; _ }
  | Capacity_backpressure { cascade_name; _ }
  | Resumable_cli_session { cascade_name; _ }
  | No_tool_capable_provider { cascade_name; _ }
  | Admission_queue_timeout { cascade_name; _ }
  | Max_tokens_ceiling_violation { cascade_name; _ } ->
      let cascade_name = cascade_name_to_string cascade_name in
      if String.equal (String.trim cascade_name) "" then "unknown"
      else cascade_name
  | Accept_rejected _
  | Admission_queue_rejected _
  | Turn_timeout _
  | Provider_timeout _
  | Retry_admission_denied _
  | Ambiguous_post_commit _
  | Internal_unhandled_exception _
  | Internal_bridge_exception _
  | Internal_contract_rejected _ -> "unknown"

let sdk_error_of_masc_internal_error err =
  Prometheus.inc_counter masc_oas_error_total_metric
    ~labels:
      [
        ("kind", kind_of_masc_internal_error err);
        ("cascade_name", cascade_name_of_masc_internal_error err);
      ]
    ();
  Agent_sdk.Error.Internal
    (masc_internal_error_prefix ^ Yojson.Safe.to_string (masc_internal_error_to_json err))
