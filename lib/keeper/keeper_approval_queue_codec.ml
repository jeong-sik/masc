open Keeper_approval_queue_rules_types
open Keeper_approval_queue_result

module SMap = Set_util.StringMap

(* 12: deliveries persist the exact rule mutation intent for replay. *)
let pending_store_version = 12
let replay_results_store_version = 1

type persisted_delivery =
  { entry : pending_approval
  ; decision : decision
  ; source : decision_source
  ; remember_rule : bool
  ; rule_expires_at : float option
  ; rule_intent : Keeper_rule_revision.intent option
  ; created_by : string option
  ; grant_consumed : bool
  ; replay_outcome : resolution_replay_outcome option
  }
let exact_request_context_version = 1

let pending_entry_to_yojson
      ?(include_request_context = true)
      (entry : pending_approval)
  =
  let request_context =
    if include_request_context then entry.request_context else None
  in
  `Assoc
    [ "id", `String entry.id
    ; "keeper_name", `String entry.keeper_name
    ; "tool_name", `String entry.tool_name
    ; "input_hash", `String entry.input_hash
    ; "input", entry.input
    ; "sequence", `Int entry.sequence
    ; "requested_at", `Float entry.requested_at
    ; "turn_id", Json_util.int_opt_to_json entry.turn_id
    ; ( "request_context"
      , match request_context with
        | Some context -> context
        | None -> `Null )
    ; ( "request_context_version"
      , match request_context with
        | Some _ -> `Int exact_request_context_version
        | None -> `Null )
    ; ( "observation"
      , match entry.observation with
        | Some refusal -> observed_refusal_to_yojson refusal
        | None -> `Null )
    ; "task_id", Json_util.string_opt_to_json entry.task_id
    ; "goal_id", Json_util.string_opt_to_json entry.goal_id
      ; "continuation_channel", Keeper_continuation_channel.to_yojson entry.continuation_channel
      ; "summary_status", summary_status_to_yojson entry.summary_status
      ; "exact_attempt", exact_attempt_state_to_yojson entry.exact_attempt
      ; ( "summary_attempt_disposition"
        , summary_attempt_disposition_to_yojson
            entry.summary_attempt_disposition )
      ]
;;

let approval_decision_to_yojson = function
  | Decision.Approve -> `Assoc [ "kind", `String "approve" ]
  | Decision.Reject reason ->
    `Assoc [ "kind", `String "reject"; "reason", `String reason ]
;;

let resolution_replay_outcome_to_yojson = function
  | Replay_applied output_ref ->
    `Assoc
      [ "kind", `String "applied"
      ; "output_ref", Tool_output.normalized_artifact_ref_to_json output_ref
      ]
  | Replay_applied_with_warning detail_ref ->
    `Assoc
      [ "kind", `String "applied_with_warning"
      ; "detail_ref", Tool_output.normalized_artifact_ref_to_json detail_ref
      ]
  | Replay_failed detail_ref ->
    `Assoc
      [ "kind", `String "failed"
      ; "detail_ref", Tool_output.normalized_artifact_ref_to_json detail_ref
      ]
  | Replay_indeterminate detail_ref ->
    `Assoc
      [ "kind", `String "indeterminate"
      ; "detail_ref", Tool_output.normalized_artifact_ref_to_json detail_ref
      ]
;;

(* [request_context] is the Auto Judge / HITL summary input: request-local
   causal evidence (bounded history lead-up, the triggering user message,
   current dynamic context, and completed tool calls) captured at request time.
   It is not the whole Keeper turn or its system prompts. Its only reader is
   Hitl_summary_worker, which runs while the entry is still pending. A delivery
   is already resolved, so the context is dead weight there — and it dominated
   the store: 71 deliveries held ~30MB of duplicated context against 19 bytes
   of decision each.

   Dropping it on the delivery wire shape stays decode-compatible: the reader
   treats [request_context] as optional and keys the version field off its
   presence, so existing snapshots still load and re-save smaller. *)
let persisted_delivery_to_yojson delivery =
  `Assoc
    [ "entry", pending_entry_to_yojson ~include_request_context:false delivery.entry
    ; "decision", approval_decision_to_yojson delivery.decision
    ; "source", `String (decision_source_to_string delivery.source)
    ; "remember_rule", `Bool delivery.remember_rule
    ; "rule_expires_at", Json_util.float_opt_to_json delivery.rule_expires_at
    ; "rule_intent", (match delivery.rule_intent with
        | None -> `Null | Some intent -> Keeper_rule_revision.intent_to_yojson intent)
    ; "created_by", Json_util.string_opt_to_json delivery.created_by
    ; "grant_consumed", `Bool delivery.grant_consumed
    ]
;;

let map_values_for_base ~base_path map project =
  SMap.bindings map
  |> List.filter_map (fun (_id, value) ->
    if String.equal (project value).audit_base_path base_path then Some value else None)
;;

let snapshot_to_yojson ~base_path ~next_sequence ~generation ~pending_map ~delivery_map =
  let pending_entries =
    map_values_for_base ~base_path pending_map Fun.id
    (* Wrapped rather than passed bare: [pending_entry_to_yojson] now leads with
       an optional argument, which OCaml only erases at application. *)
    |> List.map (fun entry -> pending_entry_to_yojson entry)
  in
  let delivery_entries =
    map_values_for_base ~base_path delivery_map (fun delivery -> delivery.entry)
    |> List.map persisted_delivery_to_yojson
  in
  `Assoc
    [ "version", `Int pending_store_version
    ; "generation", `Int generation
    ; "next_sequence", `Int next_sequence
    ; "pending", `List pending_entries
    ; "deliveries", `List delivery_entries
    ]
;;

let replay_results_to_yojson ~base_path ~delivery_map =
  let outcomes =
    map_values_for_base
      ~base_path
      delivery_map
      (fun delivery -> delivery.entry)
    |> List.filter_map (fun delivery ->
      Option.map
        (fun outcome ->
           `Assoc
             [ "approval_id", `String delivery.entry.id
             ; "outcome", resolution_replay_outcome_to_yojson outcome
             ])
        delivery.replay_outcome)
  in
  `Assoc
    [ "version", `Int replay_results_store_version
    ; "outcomes", `List outcomes
    ]
;;
type log_row =
  | Pending_upsert of pending_approval
  | Pending_remove of string
  | Delivery_upsert of persisted_delivery
  | Delivery_remove of string

let log_row_to_yojson ~generation ~next_sequence row =
  let base kind =
    [ "kind", `String kind
    ; "generation", `Int generation
    ; "next_sequence", `Int next_sequence
    ]
  in
  match row with
  | Pending_upsert entry ->
    `Assoc (base "pending_upsert" @ [ "entry", pending_entry_to_yojson entry ])
  | Pending_remove id -> `Assoc (base "pending_remove" @ [ "id", `String id ])
  | Delivery_upsert delivery ->
    `Assoc (base "delivery_upsert" @ [ "delivery", persisted_delivery_to_yojson delivery ])
  | Delivery_remove id -> `Assoc (base "delivery_remove" @ [ "id", `String id ])
;;
let reject_unknown_fields = Json_util.reject_unknown_fields
let required_string = Json_util.require_field_string
let required_float = Json_util.require_field_float
let required_positive_int = Json_util.require_field_positive_int
let required_member ~surface field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
;;

let optional_string ~surface field fields =
  match List.assoc_opt field fields with
  | None | Some `Null -> Ok None
  | Some (`String value) when String.trim value <> "" -> Ok (Some value)
  | Some (`String _) -> Error (Printf.sprintf "%s.%s must be non-blank" surface field)
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string or null" surface field)
;;

let optional_nonnegative_int ~surface field fields =
  match List.assoc_opt field fields with
  | None | Some `Null -> Ok None
  | Some (`Int value) when value >= 0 -> Ok (Some value)
  | Some _ ->
    Error (Printf.sprintf "%s.%s must be a non-negative integer or null" surface field)
;;

let optional_float ~surface field fields =
  match List.assoc_opt field fields with
  | None | Some `Null -> Ok None
  | Some (`Float value) -> Ok (Some value)
  | Some (`Int value) -> Ok (Some (Float.of_int value))
  | Some _ -> Error (Printf.sprintf "%s.%s must be a number or null" surface field)
;;

let exact_attempt_quarantine_summary_status cause =
  Summary_failed
    { reason =
        Printf.sprintf
          "Auto Judge exact attempt quarantined: %s"
          (exact_attempt_quarantine_cause_to_string cause)
    }
;;

let validate_entry_exact_attempt
      ~id
      ~input_hash
      ~sequence
      ~summary_status
      ~summary_attempt_disposition
      exact_attempt
  =
  match summary_attempt_disposition, exact_attempt, summary_status with
  | Summary_attempt_ready, Exact_unbound,
    (Summary_not_requested | Summary_pending) ->
    Ok ()
  | Summary_attempt_identity_unbound, Exact_unbound, Summary_pending ->
    Ok ()
  | Summary_attempt_persistence_uncertain, Exact_unbound, Summary_pending ->
    Ok ()
  | Summary_attempt_pre_worker_unavailable blocked, Exact_unbound,
    (Summary_not_requested | Summary_pending)
    when
      let detail = String.trim blocked.operator_detail in
      not (String.equal detail "")
      && String.equal detail blocked.operator_detail ->
    Ok ()
  | _, Exact_bound binding, _
    when not
           (String.equal binding.approval_id id
            && String.equal binding.input_hash input_hash
            && Int.equal binding.sequence sequence) ->
    Error "exact attempt binding key does not match its approval entry"
  | (Summary_attempt_settled | Summary_attempt_persistence_uncertain),
    Exact_bound { status = Exact_completed; _ }, Summary_available _ ->
    Ok ()
  | (Summary_attempt_settled | Summary_attempt_persistence_uncertain),
    Exact_bound { status = Exact_quarantined cause; _ }, summary_status
    when summary_status = exact_attempt_quarantine_summary_status cause ->
    Ok ()
  | Summary_attempt_in_flight,
    Exact_bound
      { status =
          ( Exact_dispatch_uncertain
          | Exact_released_before_dispatch )
      ; _
      },
    Summary_pending ->
    Ok ()
  | Summary_attempt_persistence_uncertain,
    Exact_bound
      { status =
          ( Exact_dispatch_uncertain
          | Exact_released_before_dispatch
          | Exact_released_recovery_required
          | Exact_restart_quarantined )
      ; _
      },
    Summary_pending ->
    Ok ()
  | _, Exact_bound { status = Exact_completed; _ }, _ ->
    Error "completed exact attempt requires an available summary"
  | _ ->
    Error "exact attempt and summary status are not a valid current-schema pair"
;;

let pending_entry_of_yojson ~base_path json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "gate_pending.entry" in
    let* () =
      reject_unknown_fields
        ~surface
        ~allowed:
          [ "id"
          ; "keeper_name"
          ; "tool_name"
          ; "input_hash"
          ; "input"
          ; "sequence"
          ; "requested_at"
          ; "turn_id"
          ; "request_context"
          ; "request_context_version"
          ; "observation"
          ; "task_id"
          ; "goal_id"
          ; "continuation_channel"
          ; "summary_status"
          ; "exact_attempt"
          ; "summary_attempt_disposition"
          ]
        fields
    in
    let* id = required_string ~surface "id" fields in
    let* keeper_name = required_string ~surface "keeper_name" fields in
    let* tool_name = required_string ~surface "tool_name" fields in
    let* input_hash = required_string ~surface "input_hash" fields in
    let* input = required_member ~surface "input" fields in
    let expected_hash =
      Keeper_approval_request_fingerprint.request_fingerprint input
    in
    let* () =
      if String.equal input_hash expected_hash
      then Ok ()
      else Error (Printf.sprintf "%s.input_hash does not match input" surface)
    in
    let* sequence = required_positive_int ~surface "sequence" fields in
    let* requested_at = required_float ~surface "requested_at" fields in
    let* turn_id = optional_nonnegative_int ~surface "turn_id" fields in
    let* request_context =
      match
        List.assoc_opt "request_context" fields,
        List.assoc_opt "request_context_version" fields
      with
      | (None | Some `Null), (None | Some `Null) -> Ok None
      | Some context, Some (`Int version)
        when Int.equal version exact_request_context_version ->
        Ok (Some context)
      | Some _, (None | Some `Null) ->
        Error (surface ^ ".request_context requires request_context_version")
      | (None | Some `Null), Some (`Int version) ->
        Error
          (Printf.sprintf
             "%s.request_context_version=%d requires request_context"
             surface
             version)
      | Some _, Some (`Int version) ->
        Error
          (Printf.sprintf
             "%s.request_context_version=%d is unsupported"
             surface
             version)
      | _, Some _ ->
        Error
          (Printf.sprintf
             "%s.request_context_version must be an integer or null"
             surface)
    in
    let* observation =
      match List.assoc_opt "observation" fields with
      | None | Some `Null -> Ok None
      | Some json ->
        (match observed_refusal_of_yojson json with
         | Ok refusal -> Ok (Some refusal)
         | Error detail -> Error (Printf.sprintf "%s.%s" surface detail))
    in
    let* task_id = optional_string ~surface "task_id" fields in
    let* goal_id = optional_string ~surface "goal_id" fields in
    let* continuation_json = required_member ~surface "continuation_channel" fields in
    let* continuation_channel = Keeper_continuation_channel.of_yojson continuation_json in
      let* summary_json = required_member ~surface "summary_status" fields in
      let* summary_status = summary_status_of_yojson_with_error summary_json in
      let* exact_attempt_json = required_member ~surface "exact_attempt" fields in
      let* exact_attempt = exact_attempt_state_of_yojson_with_error exact_attempt_json in
      let* summary_attempt_disposition_json =
        required_member ~surface "summary_attempt_disposition" fields
      in
      let* summary_attempt_disposition =
        summary_attempt_disposition_of_yojson_with_error
          summary_attempt_disposition_json
      in
      let* () =
        validate_entry_exact_attempt
          ~id
          ~input_hash
          ~sequence
          ~summary_status
          ~summary_attempt_disposition
          exact_attempt
      in
      Ok
        { id
      ; keeper_name
      ; tool_name
      ; input_hash
      ; input
      ; sequence
      ; requested_at
      ; turn_id
      ; request_context
      ; observation
      ; task_id
      ; goal_id
      ; continuation_channel
        ; audit_base_path = base_path
        ; summary_status
        ; exact_attempt
        ; summary_attempt_disposition
        }
  | _ -> Error "gate_pending.entry must be a JSON object"
;;

let pending_entry_invariant_error json =
  match json with
  | `Assoc fields ->
    (match
       List.assoc_opt "id" fields,
       List.assoc_opt "input_hash" fields,
       List.assoc_opt "sequence" fields,
       List.assoc_opt "summary_status" fields,
       List.assoc_opt "exact_attempt" fields,
       List.assoc_opt "summary_attempt_disposition" fields
     with
     | Some (`String id),
       Some (`String input_hash),
       Some (`Int sequence),
       Some summary_json,
       Some exact_attempt_json,
       Some summary_attempt_disposition_json ->
       (match
          summary_status_of_yojson_with_error summary_json,
          exact_attempt_state_of_yojson_with_error exact_attempt_json,
          summary_attempt_disposition_of_yojson_with_error
            summary_attempt_disposition_json
        with
        | Ok summary_status, Ok exact_attempt, Ok summary_attempt_disposition ->
          (match
             validate_entry_exact_attempt
               ~id
               ~input_hash
               ~sequence
               ~summary_status
               ~summary_attempt_disposition
               exact_attempt
           with
           | Ok () -> None
           | Error reason -> Some reason)
        | Error _, _, _
        | _, Error _, _
        | _, _, Error _ -> None)
     | _ -> None)
  | _ -> None
;;

let approval_decision_of_yojson json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* kind = required_string ~surface:"gate_pending.decision" "kind" fields in
    (match kind with
     | "approve" ->
       let* () =
         reject_unknown_fields
           ~surface:"gate_pending.decision"
           ~allowed:[ "kind" ]
           fields
       in
       Ok Decision.Approve
     | "reject" ->
       let* () =
         reject_unknown_fields
           ~surface:"gate_pending.decision"
           ~allowed:[ "kind"; "reason" ]
           fields
       in
       let* reason = required_string ~surface:"gate_pending.decision" "reason" fields in
       Ok (Decision.Reject reason)
     | other -> Error (Printf.sprintf "gate_pending.decision kind %S is unknown" other))
  | _ -> Error "gate_pending.decision must be a JSON object"
;;

let replay_artifact_ref_of_yojson ~surface field fields =
  match List.assoc_opt field fields with
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
  | Some json ->
    (match Tool_output.normalized_artifact_ref_of_json json with
     | Tool_output.Decoded_normalized_artifact_ref artifact_ref ->
       Ok artifact_ref
     | Tool_output.Not_normalized_artifact_ref ->
       Error
         (Printf.sprintf
            "%s.%s must be a normalized artifact reference"
            surface
            field)
     | Tool_output.Invalid_normalized_artifact_ref { detail } ->
       Error (Printf.sprintf "%s.%s: %s" surface field detail))
;;

let resolution_replay_outcome_of_yojson ~surface = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* kind = required_string ~surface "kind" fields in
    (match kind with
     | "applied" ->
       let* () =
         reject_unknown_fields
           ~surface
           ~allowed:[ "kind"; "output_ref" ]
           fields
       in
       let* output_ref =
         replay_artifact_ref_of_yojson ~surface "output_ref" fields
       in
       Ok (Replay_applied output_ref)
     | "applied_with_warning" ->
       let* () =
         reject_unknown_fields
           ~surface
           ~allowed:[ "kind"; "detail_ref" ]
           fields
       in
       let* detail_ref =
         replay_artifact_ref_of_yojson ~surface "detail_ref" fields
       in
       Ok (Replay_applied_with_warning detail_ref)
     | "failed" ->
       let* () =
         reject_unknown_fields
           ~surface
           ~allowed:[ "kind"; "detail_ref" ]
           fields
       in
       let* detail_ref =
         replay_artifact_ref_of_yojson ~surface "detail_ref" fields
       in
       Ok (Replay_failed detail_ref)
     | "indeterminate" ->
       let* () =
         reject_unknown_fields
           ~surface
           ~allowed:[ "kind"; "detail_ref" ]
           fields
       in
       let* detail_ref =
         replay_artifact_ref_of_yojson ~surface "detail_ref" fields
       in
       Ok (Replay_indeterminate detail_ref)
     | other ->
       Error
         (Printf.sprintf
            "%s.kind %S is unknown"
            surface
            other))
  | _ -> Error (surface ^ " must be a JSON object")
;;

let persisted_delivery_of_yojson ~base_path json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "gate_pending.delivery" in
    let* () =
      reject_unknown_fields
        ~surface
        ~allowed:
          [ "entry"
          ; "decision"
          ; "source"
          ; "remember_rule"
          ; "rule_expires_at"
          ; "rule_intent"
          ; "created_by"
          ; "grant_consumed"
          ]
        fields
    in
    let* entry_json = required_member ~surface "entry" fields in
    let* entry = pending_entry_of_yojson ~base_path entry_json in
    let* decision_json = required_member ~surface "decision" fields in
    let* decision = approval_decision_of_yojson decision_json in
    let* source_raw = required_string ~surface "source" fields in
    let* source =
      match decision_source_of_string source_raw with
      | Some source -> Ok source
      | None -> Error (Printf.sprintf "%s.source %S is unknown" surface source_raw)
    in
    let* remember_rule =
      match List.assoc_opt "remember_rule" fields with
      | Some (`Bool value) -> Ok value
      | Some _ -> Error (surface ^ ".remember_rule must be a boolean")
      | None -> Error (surface ^ ".remember_rule is required")
    in
    let* rule_expires_at = optional_float ~surface "rule_expires_at" fields in
    let* created_by = optional_string ~surface "created_by" fields in
    let* intent_json = required_member ~surface "rule_intent" fields in
    let* rule_intent = match decision, remember_rule, intent_json with
      | Decision.Approve, true, (`Assoc _ as json) ->
          let* intent = Keeper_rule_revision.intent_of_yojson json in
          let rule = intent.next.rule in
          if intent.next.presence = Keeper_rule_revision.Active
             && String.equal intent.next.operation_id entry.id
             && rule.source_approval_id = Some entry.id
             && String.equal rule.keeper_name entry.keeper_name
             && String.equal rule.tool_name entry.tool_name
             && String.equal rule.request_fingerprint (Keeper_approval_request_fingerprint.request_fingerprint entry.input)
             && rule.expires_at = rule_expires_at && rule.created_by = created_by
          then Ok (Some intent)
          else Error (surface ^ ".rule_intent does not match approval authority")
      | (Decision.Approve | Decision.Reject _), false, `Null -> Ok None
      | _ -> Error (surface ^ ".rule_intent must match remembered approval") in
    let* grant_consumed =
      match List.assoc_opt "grant_consumed" fields with
      | Some (`Bool value) -> Ok value
      | Some _ -> Error (surface ^ ".grant_consumed must be a boolean")
      | None -> Error (surface ^ ".grant_consumed is required")
    in
    let* () =
      match decision, grant_consumed with
      | Decision.Approve, (true | false) -> Ok ()
      | Decision.Reject _, false -> Ok ()
      | Decision.Reject _, true ->
        Error (surface ^ ".grant_consumed is valid only for approve")
    in
    Ok
      { entry
      ; decision
      ; source
      ; remember_rule
      ; rule_expires_at
      ; rule_intent
      ; created_by
      ; grant_consumed
      ; replay_outcome = None
      }
  | _ -> Error "gate_pending.delivery must be a JSON object"
;;

(* Version 11 had no captured rule-mutation intent. Preserve its explicit
   delivery and grant as one-shot state, never infer a new remembered rule.
   The versionless append log used this same exact delivery shape. *)
let persisted_delivery_v11_of_yojson ~base_path = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "gate_pending.delivery.v11" in
    let* () = reject_unknown_fields ~surface
      ~allowed:["entry"; "decision"; "source"; "remember_rule";
        "rule_expires_at"; "created_by"; "grant_consumed"] fields in
    let* () = match List.assoc_opt "remember_rule" fields with
      | Some (`Bool _) -> Ok ()
      | Some _ -> Error (surface ^ ".remember_rule must be a boolean")
      | None -> Error (surface ^ ".remember_rule is required") in
    persisted_delivery_of_yojson ~base_path
      (`Assoc (("remember_rule", `Bool false) :: ("rule_intent", `Null)
        :: List.remove_assoc "remember_rule" fields))
  | _ -> Error "gate_pending.delivery.v11 must be a JSON object"
;;

let persisted_log_delivery_of_yojson ~base_path = function
  | `Assoc fields as json when not (List.mem_assoc "rule_intent" fields) ->
      persisted_delivery_v11_of_yojson ~base_path json
  | json -> persisted_delivery_of_yojson ~base_path json
;;

let map_of_unique_entries ~surface ~id_of entries =
  let rec build map = function
    | [] -> Ok map
    | entry :: rest ->
      let id = id_of entry in
      if SMap.mem id map
      then Error (Printf.sprintf "%s contains duplicate id %s" surface id)
      else build (SMap.add id entry map) rest
  in
  build SMap.empty entries
;;

let first_shared_id left right =
  SMap.fold
    (fun id _ found ->
       match found with
       | Some _ -> found
       | None -> if SMap.mem id right then Some id else None)
    left
    None
;;

let parse_list ~surface parse = function
  | `List values ->
    let rec loop index acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        (match parse value with
         | Ok parsed -> loop (index + 1) (parsed :: acc) rest
         | Error reason -> Error (Printf.sprintf "%s[%d]: %s" surface index reason))
    in
    loop 0 [] values
  | _ -> Error (surface ^ " must be an array")
;;

let parse_list_with_entry_errors ~surface ?(fatal_error = fun _ -> None) parse = function
  | `List values ->
    let rec loop index acc errors = function
      | [] -> Ok (List.rev acc, List.rev errors)
      | value :: rest ->
        (match parse value with
         | Ok parsed -> loop (index + 1) (parsed :: acc) errors rest
         | Error reason ->
           (match fatal_error value with
            | Some fatal -> Error fatal
            | None ->
              loop
                (index + 1)
                acc
                (Printf.sprintf "%s[%d]: %s" surface index reason :: errors)
                rest))
    in
    loop 0 [] [] values
  | _ -> Error (surface ^ " must be an array")
;;

let replay_result_row_of_yojson json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "gate_replay_results.outcomes[]" in
    let* () =
      reject_unknown_fields
        ~surface
        ~allowed:[ "approval_id"; "outcome" ]
        fields
    in
    let* approval_id = required_string ~surface "approval_id" fields in
    let* outcome_json = required_member ~surface "outcome" fields in
    let* outcome =
      resolution_replay_outcome_of_yojson
        ~surface:(surface ^ ".outcome")
        outcome_json
    in
    Ok (approval_id, outcome)
  | _ -> Error "gate_replay_results.outcomes[] must be a JSON object"
;;

let replay_results_of_yojson json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "gate_replay_results" in
    let* () =
      reject_unknown_fields
        ~surface
        ~allowed:[ "version"; "outcomes" ]
        fields
    in
    let* () =
      match List.assoc_opt "version" fields with
      | Some (`Int version) when version = replay_results_store_version ->
        Ok ()
      | Some (`Int version) ->
        Error
          (Printf.sprintf
             "%s.version %d is unsupported (current %d)"
             surface
             version
             replay_results_store_version)
      | Some _ -> Error (surface ^ ".version must be an integer")
      | None -> Error (surface ^ ".version is required")
    in
    let* outcomes_json = required_member ~surface "outcomes" fields in
    let* outcomes =
      parse_list
        ~surface:"gate_replay_results.outcomes"
        replay_result_row_of_yojson
        outcomes_json
    in
    map_of_unique_entries
      ~surface:"gate_replay_results.outcomes"
      ~id_of:fst
      outcomes
    |> Result.map (SMap.map snd)
  | _ -> Error "gate_replay_results must be a JSON object"
;;

let validate_snapshot_sequences ~next_sequence pending_entries delivery_entries =
  let sequences =
    List.map (fun (entry : pending_approval) -> entry.sequence) pending_entries
    @ List.map
        (fun (delivery : persisted_delivery) -> delivery.entry.sequence)
        delivery_entries
    |> List.sort Int.compare
  in
  let rec check previous = function
    | [] -> Ok ()
    | sequence :: _ when sequence >= next_sequence ->
      Error
        (Printf.sprintf
           "gate_pending sequence %d must precede next_sequence %d"
           sequence
           next_sequence)
    | sequence :: _ when previous = Some sequence ->
      Error (Printf.sprintf "gate_pending contains duplicate sequence %d" sequence)
    | sequence :: rest -> check (Some sequence) rest
  in
  check None sequences
;;

let snapshot_of_yojson ~base_path json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "gate_pending" in
    let* () =
      reject_unknown_fields
        ~surface
        ~allowed:[ "version"; "generation"; "next_sequence"; "pending"; "deliveries" ]
        fields
    in
    let* version =
        match List.assoc_opt "version" fields with
        | Some (`Int version) when version = pending_store_version || version = 11 -> Ok version
        | Some (`Int version) ->
          Error
            (Printf.sprintf
               "%s.version %d is unsupported (current %d); preserve the store and use a reader supporting its version"
               surface
               version
               pending_store_version)
      | Some _ -> Error (surface ^ ".version must be an integer")
      | None -> Error (surface ^ ".version is required")
    in
    let* generation = required_positive_int ~surface "generation" fields in
    let* next_sequence = required_positive_int ~surface "next_sequence" fields in
    let* pending_json = required_member ~surface "pending" fields in
    let* delivery_json = required_member ~surface "deliveries" fields in
    let* pending_entries, pending_entry_errors =
      parse_list_with_entry_errors
        ~surface:"gate_pending.pending"
        ~fatal_error:pending_entry_invariant_error
        (pending_entry_of_yojson ~base_path)
        pending_json
    in
    let* delivery_entries =
      parse_list
          ~surface:"gate_pending.deliveries"
          ((if version = 11 then persisted_delivery_v11_of_yojson
            else persisted_delivery_of_yojson) ~base_path)
          delivery_json
    in
    let* pending_map =
      map_of_unique_entries
        ~surface:"gate_pending.pending"
        ~id_of:(fun (entry : pending_approval) -> entry.id)
        pending_entries
    in
    let* delivery_map =
      map_of_unique_entries
        ~surface:"gate_pending.deliveries"
        ~id_of:(fun (delivery : persisted_delivery) -> delivery.entry.id)
        delivery_entries
    in
    let* () =
      match first_shared_id pending_map delivery_map with
      | None -> Ok ()
      | Some id -> Error (Printf.sprintf "gate_pending id %s exists in both states" id)
    in
    let* () =
      validate_snapshot_sequences ~next_sequence pending_entries delivery_entries
    in
    Ok (pending_map, delivery_map, next_sequence, generation, pending_entry_errors)
  | _ -> Error "gate_pending snapshot must be a JSON object"
;;

(* The snapshot decode the loader runs, version check first, for a caller that
   must judge a store before the server opens it (deployment preflight). An
   entry the loader would drop counts as a refusal here too. *)
let validate_pending_snapshot ~base_path json =
  match snapshot_of_yojson ~base_path json with
  | Error reason -> Error reason
  | Ok (_, _, _, _, []) -> Ok ()
  | Ok (_, _, _, _, first :: _) -> Error first
;;

type decoded_log_row =
  { row : log_row
  ; row_generation : int
  ; row_next_sequence : int
  }

let log_row_of_yojson ~base_path json =
  let ( let* ) = Result.bind in
  let surface = "gate_pending.log" in
  match json with
  | `Assoc fields ->
    let* () =
      reject_unknown_fields
        ~surface
        ~allowed:[ "kind"; "generation"; "next_sequence"; "entry"; "delivery"; "id" ]
        fields
    in
    let* kind =
      match List.assoc_opt "kind" fields with
      | Some (`String kind) -> Ok kind
      | Some _ -> Error (surface ^ ".kind must be a string")
      | None -> Error (surface ^ ".kind is required")
    in
    let* row_generation = required_positive_int ~surface "generation" fields in
    let* row_next_sequence = required_positive_int ~surface "next_sequence" fields in
    let id () =
      match List.assoc_opt "id" fields with
      | Some (`String id) when not (String.equal id "") -> Ok id
      | Some _ -> Error (surface ^ ".id must be a non-empty string")
      | None -> Error (surface ^ ".id is required")
    in
    let* row =
      match kind with
      | "pending_upsert" ->
        let* json = required_member ~surface "entry" fields in
        Result.map (fun entry -> Pending_upsert entry) (pending_entry_of_yojson ~base_path json)
      | "pending_remove" -> Result.map (fun id -> Pending_remove id) (id ())
      | "delivery_upsert" ->
        let* json = required_member ~surface "delivery" fields in
        Result.map
          (fun delivery -> Delivery_upsert delivery)
          (persisted_log_delivery_of_yojson ~base_path json)
      | "delivery_remove" -> Result.map (fun id -> Delivery_remove id) (id ())
      | other -> Error (Printf.sprintf "%s.kind %S is unknown" surface other)
    in
    Ok { row; row_generation; row_next_sequence }
  | _ -> Error (surface ^ " row must be a JSON object")
;;

let apply_log_row (pending_map, delivery_map) = function
  | Pending_upsert entry -> SMap.add entry.id entry pending_map, delivery_map
  | Pending_remove id -> SMap.remove id pending_map, delivery_map
  | Delivery_upsert delivery ->
    pending_map, SMap.add delivery.entry.id delivery delivery_map
  | Delivery_remove id -> pending_map, SMap.remove id delivery_map
;;
