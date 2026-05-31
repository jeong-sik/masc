(** Keeper_internal_error — the [masc_internal_error] ADT, its JSON codec, the
    Prometheus accounting attached to construction, and the reverse-direction
    SDK envelope parser.

    This is the structured *typed envelope* carried across the
    [Agent_sdk.Error.Internal _] boundary for keeper turn failures.  It is the
    re-homed successor of the deleted [cascade_internal_error] /
    [cascade_error_from_sdk] / [cascade_error_classify] modules (RFC-0206
    cascade purge): the dispatch engine that constructed many of these variants
    is gone, but the envelope itself outlives it — provider/turn failures still
    need structured carrying.

    The originating-runtime field is now a plain [string] (the former
    [Cascade_name.t] type is deleted).  JSON keys and the per-kind label
    strings are preserved verbatim because the operator dashboard
    ([dashboard/src]) parses [kind] / [cascade_name] off the wire. *)

(* The originating runtime id is a plain string post-cascade.  Kept as a named
   identity helper so the JSON codec below reads identically to its pre-purge
   form (each variant serialises the id under the historical ["cascade_name"]
   key the dashboard still parses). *)
let cascade_name_to_string (s : string) = s

type provider_rejection = {
  provider_label : string;
  reason : string;
}

type capacity_backpressure_source =
  | Provider_capacity
  | Client_capacity
  | Cascade_slot

let capacity_backpressure_source_to_string = function
  | Provider_capacity -> "provider_capacity"
  | Client_capacity -> "client_capacity"
  | Cascade_slot -> "cascade_slot"

let capacity_backpressure_source_of_string = function
  | "provider_capacity" -> Some Provider_capacity
  | "client_capacity" -> Some Client_capacity
  | "cascade_slot" -> Some Cascade_slot
  | _ -> None

(* RFC-0158: typed denial reason carried by {!Retry_admission_denied}. *)
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

(** Provenance-preserving retry-after hint for capacity backpressure.
    [Synthetic_default] is kept distinct from [Explicit] at the type level so a
    fabricated default can never be laundered into the explicit path (audit
    2026-05-29, PR #19329). *)
type capacity_retry_after =
  | Explicit of float
  | Synthetic_default of float
  | No_retry_hint

type masc_internal_error =
  | Cascade_exhausted of {
      cascade_name : string;
      reason : Keeper_meta_contract.cascade_exhaustion_reason;
    }
  | Capacity_backpressure of {
      cascade_name : string;
      source : capacity_backpressure_source;
      detail : string;
      retry_after : capacity_retry_after;
    }
  | Resumable_cli_session of {
      cascade_name : string;
      detail : string;
      exit_code : int option;
    }
  (* [No_tool_capable_provider] reclassified into [Cascade_exhausted
     { reason = No_tool_capable _ }] — see keeper_meta_contract.ml. *)
  | Accept_rejected of {
      scope : string;
      model : string option;
      reason : string;
    }
  | Admission_queue_timeout of {
      keeper_name : string;
      cascade_name : string;
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
      cascade_name : string;
      requested_max_tokens : int;
      provider_ceiling : int;
      reason : string;
    }
  | Ambiguous_post_commit of {
      is_timeout : bool;
      tools : string list;
      original_error : string;
    }
  | Retry_admission_denied of {
      denial_reason : retry_admission_denial;
      is_retry : bool;
    }
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
        ("reason", Keeper_meta_contract.cascade_exhaustion_reason_to_json reason);
      ]
  | Capacity_backpressure { cascade_name; source; detail; retry_after } ->
    let cascade_name = cascade_name_to_string cascade_name in
    let retry_after_fields =
      match retry_after with
      | Explicit s ->
        [ ("retry_after_sec", `Float s); ("retry_after_synthetic", `Bool false) ]
      | Synthetic_default s ->
        [ ("retry_after_sec", `Float s); ("retry_after_synthetic", `Bool true) ]
      | No_retry_hint -> [ ("retry_after_sec", `Null) ]
    in
    `Assoc
      ([
         ("kind", `String "capacity_backpressure");
         ("cascade_name", `String cascade_name);
         ("source", `String (capacity_backpressure_source_to_string source));
         ("detail", `String detail);
       ]
      @ retry_after_fields)
  | Resumable_cli_session { cascade_name; detail; exit_code } ->
    let cascade_name = cascade_name_to_string cascade_name in
    `Assoc
      [
        ("kind", `String "resumable_cli_session");
        ("cascade_name", `String cascade_name);
        ("detail", `String detail);
        ("exit_code", Json_util.int_opt_to_json exit_code);
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

let summary_of_masc_internal_error = function
  | Capacity_backpressure { cascade_name; source; detail; retry_after } ->
      let retry_after_suffix =
        match retry_after with
        | Explicit value -> Printf.sprintf "; retry_after=%.1fs" value
        | Synthetic_default value ->
          Printf.sprintf "; retry_after=%.1fs (synthetic)" value
        | No_retry_hint -> ""
      in
      Some
        (Printf.sprintf
           "Capacity backpressure blocked cascade %s; source=%s; detail=%s%s"
           (cascade_name_to_string cascade_name)
           (capacity_backpressure_source_to_string source)
           detail
           retry_after_suffix)
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
  | Retry_admission_denied { denial_reason; is_retry } ->
      Some
        (Printf.sprintf
           "Pre-dispatch admission denied; is_retry=%b; reason=%s"
           is_retry
           (retry_admission_denial_to_yojson denial_reason
            |> Yojson.Safe.to_string))
  | Cascade_exhausted { cascade_name; reason = Keeper_meta_contract.No_tool_capable (Some detail) } ->
    let cascade_name = cascade_name_to_string cascade_name in
    Some
      (Printf.sprintf
         "No tool-capable provider for cascade %s; required_tools=[%s]; rejected_candidate_count=%d; configured_candidate_count=%d"
         cascade_name
         (summarize_list detail.required_tool_names)
         (List.length detail.provider_rejections)
         (List.length detail.configured_labels))
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

(* Per-kind classification counter so dashboards/Grafana can watch the
   fleet-wide rate per error class.  Emitted at construction so every
   [sdk_error_of_masc_internal_error] call site is covered. *)
let masc_oas_error_total_metric = "masc_oas_error_total"

let () =
  Prometheus.register_counter
    ~name:masc_oas_error_total_metric
    ~help:
      "Total MASC-internal errors emitted as Agent_sdk.Error.Internal \
       payloads, classified by structured error kind. Labels: kind, \
       cascade_name (originating runtime id or \"unknown\")."
    ()

let kind_of_masc_internal_error = function
  | Cascade_exhausted _ -> "cascade_exhausted"
  | Capacity_backpressure _ -> "capacity_backpressure"
  | Resumable_cli_session _ -> "resumable_cli_session"
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

let cascade_name_of_masc_internal_error = function
  | Cascade_exhausted { cascade_name; _ }
  | Capacity_backpressure { cascade_name; _ }
  | Resumable_cli_session { cascade_name; _ }
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

(* ------------------------------------------------------------------ *)
(* Reverse direction: SDK envelope -> typed variant.                  *)
(* ------------------------------------------------------------------ *)

let parse_masc_internal_error_json (json : Yojson.Safe.t) :
    masc_internal_error option =
  let int_opt_of_assoc key = function
    | `Assoc fields -> (
        match List.assoc_opt key fields with
        | Some (`Int value) -> Some value
        | Some (`Intlit value) -> int_of_string_opt value
        | _ -> None)
    | _ -> None
  in
  let float_opt_of_assoc key = function
    | `Assoc fields -> (
        match List.assoc_opt key fields with
        | Some (`Float value) -> Some value
        | Some (`Int value) -> Some (float_of_int value)
        | Some (`Intlit value) ->
            Option.map float_of_int (int_of_string_opt value)
        | _ -> None)
    | _ -> None
  in
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "kind" fields with
      | Some (`String "cascade_exhausted") -> (
          match string_opt_of_assoc "cascade_name" json with
          | Some cascade_name ->
            let reason_opt =
              match List.assoc_opt "reason"
                      (match json with `Assoc fields -> fields | _ -> []) with
              | Some json_val ->
                  Keeper_meta_contract.cascade_exhaustion_reason_of_json json_val
              | None -> None
            in
            (match reason_opt with
             | Some reason ->
               Some (Cascade_exhausted { cascade_name; reason })
             | None -> None)
          | None -> None)
      | Some (`String "capacity_backpressure") -> (
          match
            string_opt_of_assoc "cascade_name" json,
            string_opt_of_assoc "source" json,
            string_opt_of_assoc "detail" json
          with
          | Some cascade_name, Some source, Some detail ->
            (match capacity_backpressure_source_of_string source with
             | Some source ->
               let retry_after_synthetic =
                 match json with
                 | `Assoc fields -> (
                     match List.assoc_opt "retry_after_synthetic" fields with
                     | Some (`Bool b) -> b
                     | _ -> false)
                 | _ -> false
               in
               let retry_after =
                 match float_opt_of_assoc "retry_after_sec" json with
                 | None -> No_retry_hint
                 | Some s when retry_after_synthetic -> Synthetic_default s
                 | Some s -> Explicit s
               in
               Some
                 (Capacity_backpressure
                    { cascade_name; source; detail; retry_after })
             | None -> None)
          | _ -> None)
      | Some (`String "resumable_cli_session") -> (
          match string_opt_of_assoc "cascade_name" json, string_opt_of_assoc "detail" json with
          | Some cascade_name, Some detail ->
            Some
              (Resumable_cli_session
                 {
                   cascade_name;
                   detail;
                   exit_code = int_opt_of_assoc "exit_code" json;
                 })
          | _ -> None)
      | Some (`String "no_tool_capable_provider") -> (
          match string_opt_of_assoc "cascade_name" json with
          | Some cascade_name ->
            let configured_labels =
              string_list_of_assoc "configured_labels" json
            in
            let required_tool_names =
              string_list_of_assoc "required_tool_names" json
            in
            let rejections =
              match
                provider_rejections_of_assoc "provider_rejections" json
              with
              | [] ->
                provider_rejection_reasons_of_assoc
                  "rejection_reasons" json
              | provider_rejections -> provider_rejections
            in
            let detail : Keeper_meta_contract.no_tool_capable_detail =
              { configured_labels
              ; required_tool_names
              ; provider_rejections =
                  List.map (fun r -> (r.provider_label, r.reason)) rejections
              }
            in
            Some
              (Cascade_exhausted
                 {
                   cascade_name;
                   reason = Keeper_meta_contract.No_tool_capable (Some detail);
                 })
          | None -> None)
      | Some (`String "accept_rejected") -> (
          match string_opt_of_assoc "scope" json, string_opt_of_assoc "reason" json with
          | Some scope, Some reason ->
            Some
              (Accept_rejected
                 {
                   scope;
                   model = string_opt_of_assoc "model" json;
                   reason;
                 })
          | _ -> None)
      | Some (`String "admission_queue_timeout") -> (
          match string_opt_of_assoc "keeper_name" json,
                string_opt_of_assoc "cascade_name" json
          with
          | Some keeper_name, Some cascade_name ->
            let wait_sec =
              match json with
              | `Assoc fields -> (
                  match List.assoc_opt "wait_sec" fields with
                  | Some (`Float v) -> v
                  | _ -> 0.0)
              | _ -> 0.0
            in
            Some
              (Admission_queue_timeout { keeper_name; cascade_name; wait_sec })
          | _ -> None)
      | Some (`String "admission_queue_rejected") -> (
          match string_opt_of_assoc "keeper_name" json,
                string_opt_of_assoc "reason" json
          with
          | Some keeper_name, Some reason ->
            Some (Admission_queue_rejected { keeper_name; reason })
          | _ -> None)
      | Some (`String "turn_timeout") -> (
          match json with
          | `Assoc fields -> (
              match List.assoc_opt "elapsed_sec" fields with
              | Some (`Float v) ->
                Some (Turn_timeout { elapsed_sec = v })
              | _ -> None)
          | _ -> None)
      | Some (`String "provider_timeout") -> (
          match json with
          | `Assoc fields -> (
              match
                List.assoc_opt "budget_sec" fields,
                List.assoc_opt "keeper_turn_timeout_sec" fields,
                List.assoc_opt "estimated_input_tokens" fields,
                List.assoc_opt "source" fields
              with
              | Some (`Float budget_sec),
                Some (`Float keeper_turn_timeout_sec),
                Some (`Int estimated_input_tokens),
                Some (`String source) ->
                  Some
                    (Provider_timeout
                       {
                         budget_sec;
                         keeper_turn_timeout_sec;
                         estimated_input_tokens;
                         source;
                         remaining_turn_budget_sec =
                           float_opt_of_assoc
                             "remaining_turn_budget_sec" json;
                         min_required_sec =
                           Option.value ~default:0.0
                             (float_opt_of_assoc "min_required_sec" json);
                         phase =
                           Option.value ~default:"unknown"
                             (string_opt_of_assoc "phase" json);
                       })
              | _ -> None)
          | _ -> None)
      | Some (`String "max_tokens_ceiling_violation") -> (
          match
            string_opt_of_assoc "cascade_name" json,
            int_opt_of_assoc "requested_max_tokens" json,
            int_opt_of_assoc "provider_ceiling" json
          with
          | Some cascade_name, Some requested_max_tokens, Some provider_ceiling ->
            Some
              (Max_tokens_ceiling_violation
                 {
                   cascade_name;
                   requested_max_tokens;
                   provider_ceiling;
                   reason =
                     Option.value ~default:"unknown"
                       (string_opt_of_assoc "reason" json);
                 })
          | _ -> None)
      | Some (`String "ambiguous_post_commit") -> (
          match string_opt_of_assoc "original_error" json with
          | Some original_error ->
            let is_timeout =
              match json with
              | `Assoc fields -> (
                  match List.assoc_opt "is_timeout" fields with
                  | Some (`Bool b) -> b
                  | _ -> false)
              | _ -> false
            in
            let tools =
              match json with
              | `Assoc fields -> (
                  match List.assoc_opt "tools" fields with
                  | Some (`List values) ->
                    values
                    |> List.filter_map (function
                         | `String value -> Some value
                         | _ -> None)
                  | _ -> [])
              | _ -> []
            in
            Some (Ambiguous_post_commit { is_timeout; tools; original_error })
          | _ -> None)
      | Some (`String "internal_unhandled_exception") -> (
          match string_opt_of_assoc "site" json,
                string_opt_of_assoc "exn_repr" json
          with
          | Some site, Some exn_repr ->
            Some (Internal_unhandled_exception { site; exn_repr })
          | _ -> None)
      | Some (`String "internal_bridge_exception") -> (
          match string_opt_of_assoc "caller" json,
                string_opt_of_assoc "exn_repr" json
          with
          | Some caller, Some exn_repr ->
            Some (Internal_bridge_exception { caller; exn_repr })
          | _ -> None)
      | Some (`String "internal_contract_rejected") -> (
          match string_opt_of_assoc "reason" json with
          | Some reason -> Some (Internal_contract_rejected { reason })
          | _ -> None)
      | _ -> None)
  | _ -> None

let classify_masc_internal_error_of_string (raw : string) :
    masc_internal_error option =
  let prefix = masc_internal_error_prefix in
  let prefix_len = String.length prefix in
  let raw_len = String.length raw in
  let rec find_prefix start =
    if start + prefix_len > raw_len then None
    else if String.sub raw start prefix_len = prefix then Some start
    else find_prefix (start + 1)
  in
  match find_prefix 0 with
  | None -> None
  | Some prefix_start ->
    let payload_start = prefix_start + prefix_len in
    let payload = String.sub raw payload_start (raw_len - payload_start) in
    (try parse_masc_internal_error_json (Yojson.Safe.from_string payload)
     with Yojson.Json_error _ -> None)

let classify_masc_internal_error (err : Agent_sdk.Error.sdk_error) :
    masc_internal_error option =
  match err with
  | Agent_sdk.Error.Internal msg -> classify_masc_internal_error_of_string msg
  | _ -> None
