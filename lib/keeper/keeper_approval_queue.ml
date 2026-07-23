(** Durable, nonblocking HITL requests for Keeper external effects. *)

include Keeper_approval_queue_rules

type storage_error =
  { path : string
  ; reason : string
  }

type summary_transition_rejection =
  | Summary_exact_attempt_bound of exact_attempt_binding
  | Summary_legacy_execution_uncertain of string

type summary_transition_error =
  | Summary_transition_storage_error of storage_error
  | Summary_transition_rejected of summary_transition_rejection

type exact_attempt_rejection =
  | Exact_attempt_not_found of string
  | Exact_attempt_key_mismatch of
      { approval_id : string
      ; input_hash : string
      ; sequence : int
      }
  | Exact_attempt_invalid_identity of string
  | Exact_attempt_summary_not_pending of string
  | Exact_attempt_unbound_state of string
  | Exact_attempt_legacy_execution_uncertain of string
  | Exact_attempt_identity_conflict of exact_attempt_binding
  | Exact_attempt_status_conflict of exact_attempt_binding
  | Exact_attempt_provenance_mismatch of
      { approval_id : string
      ; expected_call_id : string
      ; actual_model_run_id : string
      }
  | Exact_attempt_content_conflict of string

type exact_attempt_error =
  | Exact_attempt_storage_error of storage_error
  | Exact_attempt_rejected of exact_attempt_rejection

type approved_resolution_request =
  { keeper_name : string
  ; tool_name : string
  ; input : Yojson.Safe.t
  }

type grant_error =
  | Grant_store_unavailable of storage_error
  | Grant_workspace_mismatch of
      { approval_id : string
      ; requested_base_path : string
      ; stored_base_path : string
      }
  | Grant_still_pending of string
  | Grant_resolution_not_approved of string
  | Grant_resolution_missing of string

type approved_resolution_state =
  | Resolution_unconsumed
  | Resolution_consumed

type grant_consumption =
  | Consumption_committed
  | Consumption_already_committed
  | Consumption_not_matching

type delivery_replay_failure =
  { approval_id : string
  ; reason : string
  }

type install_report =
  { loaded_pending : int
  ; replayed_deliveries : int
  ; delivery_replay_failures : delivery_replay_failure list
  }

type install_error = Install_storage_failed of storage_error

type persisted_delivery =
  { entry : pending_approval
  ; decision : decision
  ; source : decision_source
  ; remember_rule : bool
  ; rule_expires_at : float option
  ; created_by : string option
  ; grant_consumed : bool
  }

let storage_error_to_string error =
  Printf.sprintf "%s: %s" error.path error.reason
;;

let exact_attempt_binding_to_string binding =
  let status =
    match binding.status with
    | Exact_quarantined cause ->
      Printf.sprintf
        "quarantined:%s"
        (exact_attempt_quarantine_cause_to_string cause)
    | Exact_dispatch_uncertain
    | Exact_released_before_dispatch
    | Exact_completed ->
      exact_attempt_status_to_string binding.status
  in
  Printf.sprintf
    "approval=%s input_hash=%s sequence=%d slot=%s call=%s plan=%s request=%s status=%s"
    binding.approval_id
    binding.input_hash
    binding.sequence
    binding.slot_id
    binding.call_id
    binding.plan_fingerprint
    binding.request_body_sha256
    status
;;

let summary_transition_error_to_string = function
  | Summary_transition_storage_error error -> storage_error_to_string error
  | Summary_transition_rejected (Summary_exact_attempt_bound binding) ->
    "legacy summary transition rejected for exact attempt: "
    ^ exact_attempt_binding_to_string binding
  | Summary_transition_rejected (Summary_legacy_execution_uncertain approval_id) ->
    Printf.sprintf
      "legacy summary transition rejected for execution-uncertain approval %s"
      approval_id
;;

let exact_attempt_error_to_string = function
  | Exact_attempt_storage_error error -> storage_error_to_string error
  | Exact_attempt_rejected (Exact_attempt_not_found approval_id) ->
    Printf.sprintf "exact attempt approval %s was not found" approval_id
  | Exact_attempt_rejected
      (Exact_attempt_key_mismatch { approval_id; input_hash; sequence }) ->
    Printf.sprintf
      "exact attempt key mismatch approval=%s input_hash=%s sequence=%d"
      approval_id
      input_hash
      sequence
  | Exact_attempt_rejected (Exact_attempt_invalid_identity field) ->
    Printf.sprintf "exact attempt identity field %s is invalid" field
  | Exact_attempt_rejected (Exact_attempt_summary_not_pending approval_id) ->
    Printf.sprintf "exact attempt approval %s summary is not pending" approval_id
  | Exact_attempt_rejected (Exact_attempt_unbound_state approval_id) ->
    Printf.sprintf "exact attempt approval %s has no bound identity" approval_id
  | Exact_attempt_rejected (Exact_attempt_legacy_execution_uncertain approval_id) ->
    Printf.sprintf
      "exact attempt approval %s is quarantined as legacy execution-uncertain"
      approval_id
  | Exact_attempt_rejected (Exact_attempt_identity_conflict binding) ->
    "exact attempt identity conflicts with durable binding: "
    ^ exact_attempt_binding_to_string binding
  | Exact_attempt_rejected (Exact_attempt_status_conflict binding) ->
    "exact attempt status rejects this transition: "
    ^ exact_attempt_binding_to_string binding
  | Exact_attempt_rejected
      (Exact_attempt_provenance_mismatch
        { approval_id; expected_call_id; actual_model_run_id }) ->
    Printf.sprintf
      "exact attempt approval %s summary provenance mismatch: expected call_id=%s, \
       actual model_run_id=%s"
      approval_id
      expected_call_id
      actual_model_run_id
  | Exact_attempt_rejected (Exact_attempt_content_conflict approval_id) ->
    Printf.sprintf
      "exact attempt approval %s already completed with different content"
      approval_id
;;

let grant_error_to_string = function
  | Grant_store_unavailable error -> storage_error_to_string error
  | Grant_workspace_mismatch
      { approval_id; requested_base_path; stored_base_path } ->
    Printf.sprintf
      "approval %s belongs to workspace %s, not %s"
      approval_id
      stored_base_path
      requested_base_path
  | Grant_still_pending approval_id ->
    Printf.sprintf "approval %s has not been resolved" approval_id
  | Grant_resolution_not_approved approval_id ->
    Printf.sprintf "approval %s was not approved" approval_id
  | Grant_resolution_missing approval_id ->
    Printf.sprintf "approval %s has no durable resolution journal" approval_id
;;

let install_error_to_string = function
  | Install_storage_failed error -> storage_error_to_string error
;;

let legacy_pending_store_version = 3
let pending_store_version = 4
let pending_store_surface = "keeper_gate_pending"
let pending_store_mutex = Cross_context_mutex.create ()
let deliveries : persisted_delivery SMap.t Atomic.t = Atomic.make SMap.empty
let unavailable_stores : storage_error SMap.t Atomic.t = Atomic.make SMap.empty
(** Process projection of the next value persisted in each workspace snapshot. *)
let next_sequences : int SMap.t Atomic.t = Atomic.make SMap.empty
let first_sequence = 1

(** Serialize one durable pending/delivery snapshot transition across both Eio
    fibers and non-Eio callers.  A plain [Stdlib.Mutex.protect] is invalid here:
    snapshot publication uses [Eio.Path] and may suspend while the lock is held,
    letting another fiber on the same domain re-enter the OS mutex and raise
    [Sys_error "Mutex.lock: Resource deadlock avoided"].

    The shared cross-context authority keeps acquisition cancellable and defers
    cancellation only after both gates are held, so a published snapshot is not
    reported as an ambiguous cancelled operation. *)
let with_pending_store_lock f =
  Cross_context_mutex.with_durable_lock pending_store_mutex f
;;

let mark_store_unavailable_unlocked ~base_path error =
  Atomic.set
    unavailable_stores
    (SMap.add base_path error (Atomic.get unavailable_stores))
;;

let clear_store_unavailable_unlocked ~base_path =
  Atomic.set
    unavailable_stores
    (SMap.remove base_path (Atomic.get unavailable_stores))
;;

let pending_store_path ~base_path =
  Keeper_gate_path.pending ~base_path
;;

let report_pending_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_persistence_read_drops
        ~labels:[ "surface", pending_store_surface; "reason", reason ]
        ())
    ~surface:pending_store_surface
    ~reason
    ~path
    ~detail
;;

let exact_request_context_version = 1

let pending_entry_to_yojson (entry : pending_approval) =
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
      , match entry.request_context with
        | Some context -> context
        | None -> `Null )
    ; ( "request_context_version"
      , match entry.request_context with
        | Some _ -> `Int exact_request_context_version
        | None -> `Null )
    ; "task_id", Json_util.string_opt_to_json entry.task_id
    ; "goal_id", Json_util.string_opt_to_json entry.goal_id
    ; "goal_ids", Json_util.json_string_list entry.goal_ids
      ; "continuation_channel", Keeper_continuation_channel.to_yojson entry.continuation_channel
      ; "summary_status", summary_status_to_yojson entry.summary_status
      ; "exact_attempt", exact_attempt_state_to_yojson entry.exact_attempt
      ]
;;

let approval_decision_to_yojson = function
  | Decision.Approve -> `Assoc [ "kind", `String "approve" ]
  | Decision.Reject reason ->
    `Assoc [ "kind", `String "reject"; "reason", `String reason ]
  | Decision.Edit input ->
    `Assoc [ "kind", `String "edit"; "input", input ]
;;

let persisted_delivery_to_yojson delivery =
  `Assoc
    [ "entry", pending_entry_to_yojson delivery.entry
    ; "decision", approval_decision_to_yojson delivery.decision
    ; "source", `String (decision_source_to_string delivery.source)
    ; "remember_rule", `Bool delivery.remember_rule
    ; "rule_expires_at", Json_util.float_opt_to_json delivery.rule_expires_at
    ; "created_by", Json_util.string_opt_to_json delivery.created_by
    ; "grant_consumed", `Bool delivery.grant_consumed
    ]
;;

let map_values_for_base ~base_path map project =
  SMap.bindings map
  |> List.filter_map (fun (_id, value) ->
    if String.equal (project value).audit_base_path base_path then Some value else None)
;;

let snapshot_to_yojson ~base_path ~next_sequence ~pending_map ~delivery_map =
  let pending_entries =
    map_values_for_base ~base_path pending_map Fun.id
    |> List.map pending_entry_to_yojson
  in
  let delivery_entries =
    map_values_for_base ~base_path delivery_map (fun delivery -> delivery.entry)
    |> List.map persisted_delivery_to_yojson
  in
  `Assoc
    [ "version", `Int pending_store_version
    ; "next_sequence", `Int next_sequence
    ; "pending", `List pending_entries
    ; "deliveries", `List delivery_entries
    ]
;;

let save_snapshot_file_unlocked
      ~base_path
      ~next_sequence
      ~pending_map
      ~delivery_map
    =
    let path = pending_store_path ~base_path in
    try
      Fs_compat.mkdir_p (Filename.dirname path);
      let body =
        snapshot_to_yojson ~base_path ~next_sequence ~pending_map ~delivery_map
        |> Yojson.Safe.pretty_to_string
      in
      (match Fs_compat.save_file_atomic path body with
       | Ok () -> Ok ()
       | Error reason -> Error { path; reason })
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error { path; reason = Printexc.to_string exn }
;;

let persist_snapshot_with_sequence_unlocked
      ~base_path
      ~next_sequence
      ~pending_map
      ~delivery_map
  =
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some error -> Error error
  | None ->
    save_snapshot_file_unlocked
      ~base_path
      ~next_sequence
      ~pending_map
      ~delivery_map
;;

type store_lifecycle =
  | Uninstalled
  | Ready of int
  | Unavailable of storage_error

let next_sequence_lifecycle ~base_path =
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some error -> Unavailable error
  | None ->
    (match SMap.find_opt base_path (Atomic.get next_sequences) with
     | Some sequence -> Ready sequence
     | None -> Uninstalled)
;;

let persist_snapshot_unlocked ~base_path ~pending_map ~delivery_map =
  match next_sequence_lifecycle ~base_path with
  | Ready next_sequence ->
    persist_snapshot_with_sequence_unlocked
      ~base_path
      ~next_sequence
      ~pending_map
      ~delivery_map
  | Uninstalled ->
    Error
      { path = pending_store_path ~base_path
      ; reason =
          "gate_pending store is not installed; install_persistence must \
           complete before publishing"
      }
  | Unavailable error -> Error error
;;

let reject_unknown_fields ~surface ~allowed fields =
  let rec duplicate seen = function
    | [] -> None
    | (key, _) :: rest ->
      if List.mem key seen then Some key else duplicate (key :: seen) rest
  in
  match duplicate [] fields with
  | Some field -> Error (Printf.sprintf "%s contains duplicate field %s" surface field)
  | None ->
    (match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
     | None -> Ok ()
     | Some (field, _) ->
       Error (Printf.sprintf "%s contains unsupported field %s" surface field))
;;

let required_string ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | Some (`String _) -> Error (Printf.sprintf "%s.%s must be non-blank" surface field)
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
;;

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

let required_positive_int ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`Int value) when value > 0 -> Ok value
  | Some _ -> Error (Printf.sprintf "%s.%s must be a positive integer" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
;;

let required_float ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`Float value) -> Ok value
  | Some (`Int value) -> Ok (Float.of_int value)
  | Some _ -> Error (Printf.sprintf "%s.%s must be a number" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
;;

let required_string_list ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`List values) ->
    let rec parse index acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> parse (index + 1) (value :: acc) rest
      | _ :: _ ->
        Error (Printf.sprintf "%s.%s[%d] must be a string" surface field index)
    in
    parse 0 [] values
  | Some _ -> Error (Printf.sprintf "%s.%s must be an array" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
;;

let exact_attempt_identity_matches left right =
  String.equal left.approval_id right.approval_id
  && String.equal left.input_hash right.input_hash
  && Int.equal left.sequence right.sequence
  && String.equal left.slot_id right.slot_id
  && String.equal left.call_id right.call_id
  && String.equal left.plan_fingerprint right.plan_fingerprint
  && String.equal left.request_body_sha256 right.request_body_sha256
;;

let validate_entry_exact_attempt
      ~id
      ~input_hash
      ~sequence
      ~summary_status
      exact_attempt
  =
  match exact_attempt, summary_status with
  | Exact_unbound, _ -> Ok ()
  | Legacy_execution_uncertain, Summary_pending -> Ok ()
  | Legacy_execution_uncertain, _ ->
    Error "legacy execution-uncertain quarantine requires a pending summary"
  | Exact_bound binding, _
    when not
           (String.equal binding.approval_id id
            && String.equal binding.input_hash input_hash
            && Int.equal binding.sequence sequence) ->
    Error "exact attempt binding key does not match its approval entry"
  | Exact_bound { status = Exact_completed; _ }, Summary_available _ -> Ok ()
  | Exact_bound
      { status =
          (Exact_dispatch_uncertain | Exact_quarantined _)
      ; _
      },
    Summary_pending ->
    Ok ()
  | Exact_bound { status = Exact_released_before_dispatch; _ },
    (Summary_pending | Summary_failed _) ->
    Ok ()
  | Exact_bound { status = Exact_completed; _ }, _ ->
    Error "completed exact attempt requires an available summary"
  | Exact_bound _, _ ->
    Error "non-completed exact attempt requires a pending summary"
;;

let pending_entry_of_yojson ~base_path ~snapshot_version json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "gate_pending.entry" in
    let* () =
      reject_unknown_fields
        ~surface
          ~allowed:
            ([ "id"
             ; "keeper_name"
             ; "tool_name"
             ; "input_hash"
             ; "input"
             ; "sequence"
             ; "requested_at"
             ; "turn_id"
             ; "request_context"
             ; "request_context_version"
             ; "task_id"
             ; "goal_id"
             ; "goal_ids"
             ; "continuation_channel"
             ; "summary_status"
             ]
             @
             if snapshot_version = pending_store_version
             then [ "exact_attempt" ]
             else [])
          fields
    in
    let* id = required_string ~surface "id" fields in
    let* keeper_name = required_string ~surface "keeper_name" fields in
    let* tool_name = required_string ~surface "tool_name" fields in
    let* input_hash = required_string ~surface "input_hash" fields in
    let* input = required_member ~surface "input" fields in
    let expected_hash = request_fingerprint input in
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
        (* Pre-version records contain the retired projection format. It is
           intentionally not inspected or migrated: there is no exact causal
           evidence to recover from a digest projection. *)
        Ok None
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
    let* task_id = optional_string ~surface "task_id" fields in
    let* goal_id = optional_string ~surface "goal_id" fields in
    let* goal_ids = required_string_list ~surface "goal_ids" fields in
    let* continuation_json = required_member ~surface "continuation_channel" fields in
    let* continuation_channel = Keeper_continuation_channel.of_yojson continuation_json in
      let* summary_json = required_member ~surface "summary_status" fields in
      let* summary_status = summary_status_of_yojson_with_error summary_json in
      let* exact_attempt =
        if snapshot_version = legacy_pending_store_version
        then
          Ok
            (match summary_status with
             | Summary_pending -> Legacy_execution_uncertain
             | Summary_not_requested | Summary_available _ | Summary_failed _ ->
               Exact_unbound)
        else
          let* exact_attempt_json = required_member ~surface "exact_attempt" fields in
          exact_attempt_state_of_yojson_with_error exact_attempt_json
      in
      let* () =
        validate_entry_exact_attempt
          ~id
          ~input_hash
          ~sequence
          ~summary_status
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
      ; task_id
      ; goal_id
      ; goal_ids
      ; continuation_channel
        ; audit_base_path = base_path
        ; summary_status
        ; exact_attempt
        }
  | _ -> Error "gate_pending.entry must be a JSON object"
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
     | "edit" ->
       let* () =
         reject_unknown_fields
           ~surface:"gate_pending.decision"
           ~allowed:[ "kind"; "input" ]
           fields
       in
       let* input = required_member ~surface:"gate_pending.decision" "input" fields in
       Ok (Decision.Edit input)
     | other -> Error (Printf.sprintf "gate_pending.decision kind %S is unknown" other))
  | _ -> Error "gate_pending.decision must be a JSON object"
;;

let persisted_delivery_of_yojson ~base_path ~snapshot_version json =
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
          ; "created_by"
          ; "grant_consumed"
          ]
        fields
    in
    let* entry_json = required_member ~surface "entry" fields in
      let* entry =
        pending_entry_of_yojson ~base_path ~snapshot_version entry_json
      in
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
    let* grant_consumed =
      match List.assoc_opt "grant_consumed" fields with
      | Some (`Bool value) -> Ok value
      | Some _ -> Error (surface ^ ".grant_consumed must be a boolean")
      | None -> Error (surface ^ ".grant_consumed is required")
    in
    let* () =
      match decision, grant_consumed with
      | Decision.Approve, _ -> Ok ()
      | (Decision.Reject _ | Decision.Edit _), false -> Ok ()
      | (Decision.Reject _ | Decision.Edit _), true ->
        Error (surface ^ ".grant_consumed is valid only for approve")
    in
    Ok
      { entry
      ; decision
      ; source
      ; remember_rule
      ; rule_expires_at
      ; created_by
      ; grant_consumed
      }
  | _ -> Error "gate_pending.delivery must be a JSON object"
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
        ~allowed:[ "version"; "next_sequence"; "pending"; "deliveries" ]
        fields
    in
      let* snapshot_version =
        match List.assoc_opt "version" fields with
        | Some (`Int version)
          when version = legacy_pending_store_version
               || version = pending_store_version ->
          Ok version
        | Some (`Int version) ->
          Error (Printf.sprintf "%s.version %d is unsupported" surface version)
      | Some _ -> Error (surface ^ ".version must be an integer")
      | None -> Error (surface ^ ".version is required")
    in
    let* next_sequence = required_positive_int ~surface "next_sequence" fields in
    let* pending_json = required_member ~surface "pending" fields in
      let* pending_entries =
        parse_list
          ~surface:"gate_pending.pending"
          (pending_entry_of_yojson ~base_path ~snapshot_version)
          pending_json
    in
    let* delivery_json = required_member ~surface "deliveries" fields in
    let* delivery_entries =
      parse_list
          ~surface:"gate_pending.deliveries"
          (persisted_delivery_of_yojson ~base_path ~snapshot_version)
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
      Ok (snapshot_version, pending_map, delivery_map, next_sequence)
  | _ -> Error "gate_pending snapshot must be a JSON object"
;;

let snapshot_version_of_yojson = function
  | `Assoc fields -> (
    match List.assoc_opt "version" fields with
    | Some (`Int version) -> Some version
    | Some _ | None -> None)
  | _ -> None
;;

let quarantine_restarted_entry (entry : pending_approval) =
  match entry.exact_attempt with
  | Exact_bound ({ status = Exact_dispatch_uncertain; _ } as binding) ->
    ( { entry with
        exact_attempt =
          Exact_bound
            { binding with
              status = Exact_quarantined Exact_restart_uncertainty
            }
      }
    , true )
  | Exact_unbound
  | Legacy_execution_uncertain
  | Exact_bound
      { status =
          ( Exact_released_before_dispatch
          | Exact_quarantined _
          | Exact_completed )
      ; _
      } ->
    entry, false
;;

let quarantine_restarted_pending map =
  SMap.fold
    (fun id entry (changed, quarantined) ->
       let entry, entry_changed = quarantine_restarted_entry entry in
       changed || entry_changed, SMap.add id entry quarantined)
    map
    (false, SMap.empty)
;;

let quarantine_restarted_deliveries map =
  SMap.fold
    (fun id delivery (changed, quarantined) ->
       let entry, entry_changed = quarantine_restarted_entry delivery.entry in
       ( changed || entry_changed
       , SMap.add id { delivery with entry } quarantined ))
    map
    (false, SMap.empty)
;;

let quarantine_path ~path ~version =
  let base = Printf.sprintf "%s.v%d.quarantine" path version in
  let rec find_free k =
    let candidate =
      if k = 0 then base else Printf.sprintf "%s.%d" base k
    in
    if Sys.file_exists candidate then find_free (k + 1) else candidate
  in
  find_free 0
;;

(* An unsupported snapshot version is a generational boundary, not
   corruption: the durable file is preserved verbatim at a visible
   quarantine path and the store starts a fresh generation. Only a rename
   failure keeps the old fail-closed behavior — starting fresh while the
   old file is still in place would let the next [put] overwrite the very
   evidence the quarantine exists to preserve. *)
let quarantine_snapshot_unlocked ~path ~version =
  let target = quarantine_path ~path ~version in
  try
    Sys.rename path target;
    Log.Server.error
      "gate_pending snapshot version %d is unsupported (current %d); \
       quarantined to %s and starting a fresh store generation"
      version pending_store_version target;
    Ok (SMap.empty, SMap.empty, first_sequence)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let reason =
      Printf.sprintf
        "gate_pending snapshot version %d is unsupported and quarantine \
         rename to %s failed: %s"
        version target (Printexc.to_string exn)
    in
    report_pending_read_drop
      ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
      ~path
      ~detail:reason;
    Error { path; reason }
;;

let load_snapshot_unlocked ~base_path =
  let path = pending_store_path ~base_path in
  try
    if not (Sys.file_exists path)
    then Ok (SMap.empty, SMap.empty, first_sequence)
    else (
      match Safe_ops.read_json_file_safe path with
      | Error reason ->
        report_pending_read_drop
          ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
          ~path
          ~detail:reason;
        Error { path; reason }
      | Ok json ->
        (match snapshot_version_of_yojson json with
           | Some version
             when version <> legacy_pending_store_version
                  && version <> pending_store_version ->
             quarantine_snapshot_unlocked ~path ~version
           | Some _ | None ->
             (match snapshot_of_yojson ~base_path json with
              | Ok
                  ( snapshot_version
                  , loaded_pending
                  , loaded_deliveries
                  , loaded_next_sequence ) ->
                let pending_changed, loaded_pending =
                  quarantine_restarted_pending loaded_pending
                in
                let deliveries_changed, loaded_deliveries =
                  quarantine_restarted_deliveries loaded_deliveries
                in
                if
                  snapshot_version = legacy_pending_store_version
                  || pending_changed
                  || deliveries_changed
                then
                  (match
                     save_snapshot_file_unlocked
                       ~base_path
                       ~next_sequence:loaded_next_sequence
                       ~pending_map:loaded_pending
                       ~delivery_map:loaded_deliveries
                   with
                   | Error _ as error -> error
                   | Ok () ->
                     Log.Server.warn
                       "gate_pending migrated workspace=%s version=%d->%d \
                        restart_quarantine=%b"
                       base_path
                       snapshot_version
                       pending_store_version
                       (pending_changed || deliveries_changed);
                     Ok
                       ( loaded_pending
                       , loaded_deliveries
                       , loaded_next_sequence ))
                else
                  Ok
                    ( loaded_pending
                    , loaded_deliveries
                    , loaded_next_sequence )
              | Error reason ->
              report_pending_read_drop
                ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                ~path
                ~detail:reason;
              Error { path; reason })))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let reason = Printexc.to_string exn in
    report_pending_read_drop
      ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
      ~path
      ~detail:reason;
    Error { path; reason }
;;

let remove_base_entries ~base_path map project =
  SMap.filter
    (fun _id value ->
       not (String.equal (project value).audit_base_path base_path))
    map
;;

let merge_loaded_map ~surface ~existing ~loaded =
  SMap.fold
    (fun id value result ->
       match result with
       | Error _ as error -> error
       | Ok map ->
         if SMap.mem id map
         then Error (Printf.sprintf "%s id %s collides with another workspace" surface id)
         else Ok (SMap.add id value map))
    loaded
    (Ok existing)
;;

(* ── Persistent audit log ────────────────────────────────── *)

(* Stdlib.Mutex: the store registry critical section only mutates an in-memory
   hashtable and creates a Dated_jsonl handle. It is also used by synchronous
   tests outside an Eio context, so an Eio mutex would either raise Get_context
   or poison the registry after a recoverable store-creation failure. *)
(** Dated JSONL audit trail for approval events.
    Stored at [<base_path>/.masc/audit-approvals/YYYY-MM/DD.jsonl].
    Dashboard and workspace-scoped keeper runs pass [base_path] explicitly so approval
    history stays with the workspace that made the decision. *)
let audit_stores_mu = Stdlib.Mutex.create ()

let audit_io_mutex = Cross_context_mutex.create ()
let audit_stores : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 4

(* Runtime trust asks for per-keeper latest audit state across the same global
   audit tail. Cache the raw tail briefly so a keeper snapshot does one shared
   JSONL read instead of N identical scans. *)
type recent_audit_cache_entry =
  { rows : Yojson.Safe.t list
  ; observed_at : float
  }
;;

let recent_audit_cache_mu = Stdlib.Mutex.create ()
let recent_audit_cache : (string, recent_audit_cache_entry) Hashtbl.t =
  Hashtbl.create 4
;;

let recent_audit_cache_ttl_sec = 1.0
let recent_resolved_history_limit = 20
let audit_wide_scan_min_rows = 500
let audit_wide_scan_multiplier = 64

let wide_audit_scan_window n =
  max audit_wide_scan_min_rows (max n 1 * audit_wide_scan_multiplier)
;;

let recent_audit_cache_key store limit =
  Printf.sprintf "%s:%d" (Dated_jsonl.base_dir store) limit
;;

let invalidate_recent_audit_cache_for_store store =
  let prefix = Dated_jsonl.base_dir store ^ ":" in
  Stdlib.Mutex.protect recent_audit_cache_mu (fun () ->
    Hashtbl.filter_map_inplace
      (fun key entry -> if String.starts_with ~prefix key then None else Some entry)
      recent_audit_cache)
;;

let read_recent_audit_raw store limit =
  let key = recent_audit_cache_key store limit in
  let now = Unix.gettimeofday () in
  let cached =
    Stdlib.Mutex.protect recent_audit_cache_mu (fun () ->
      match Hashtbl.find_opt recent_audit_cache key with
      | Some entry when now -. entry.observed_at <= recent_audit_cache_ttl_sec ->
        Some entry.rows
      | _ -> None)
  in
  match cached with
  | Some rows -> rows
  | None ->
    let rows = Dated_jsonl.read_recent store limit in
    Stdlib.Mutex.protect recent_audit_cache_mu (fun () ->
      Hashtbl.replace recent_audit_cache key { rows; observed_at = now });
    rows
;;

let approval_audit_pending_event = "pending"
let approval_audit_resolved_event = "resolved"
let approval_audit_summary_event = "summary_updated"
let approval_sse_pending_event = "approval:pending"
let approval_sse_resolved_event = "approval:resolved"
let approval_sse_summary_event = "approval:summary_updated"

let non_empty_reason reason =
  let reason = String.trim reason in
  if String.equal reason "" then None else Some reason
;;

let approval_decision_kind_and_reason = function
  | Decision.Approve -> "approve", None
  | Decision.Reject reason -> "reject", non_empty_reason reason
  | Decision.Edit _ -> "edit", None
;;

let keeper_audit_metric_label = function
  | Some keeper when String.trim keeper <> "" -> keeper
  | Some _ | None -> "aggregate"
;;

let audit_today_path base_dir =
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  let month = Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) in
  let day = Printf.sprintf "%02d.jsonl" tm.tm_mday in
  let dir = Filename.concat base_dir month in
  Fs_compat.mkdir_p dir;
  Filename.concat dir day
;;

let get_audit_store ~base_path () =
  let report_failure exn =
    Keeper_fd_pressure.note_exception ~site:"approval_audit.store_create" exn;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels:
        [ "keeper", "aggregate"
        ; "site", Keeper_approval_queue_failure_site.(to_label Audit_store_create)
        ]
      ();
    Log.Keeper.warn
      "approval_queue: audit store creation failed: %s"
      (Printexc.to_string exn);
    None
  in
  try
    match
      Stdlib.Mutex.protect audit_stores_mu (fun () ->
        try
          Ok
            (match Hashtbl.find_opt audit_stores base_path with
             | Some store -> Some store
             | None ->
               let dir =
                 Filename.concat
                   (Common.masc_dir_from_base_path ~base_path)
                   "audit-approvals"
               in
               let store = Dated_jsonl.create ~base_dir:dir () in
               Hashtbl.replace audit_stores base_path store;
               Some store)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn -> Error exn)
    with
    | Ok store -> store
    | Error exn -> report_failure exn
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> report_failure exn
;;

let audit_approval_event
      ~base_path
      ~event_type
      ~id
      ~keeper_name
      ~tool_name
      ?turn_id
      ?task_id
      ?goal_id
      ?(goal_ids = [])
      ?rule_match
      ?source_approval_id
      ?actor
      ?decision_source
      ?decision
      ()
  =
  let decision, decision_kind, decision_reason =
    match decision with
    | None -> "", None, None
    | Some decision ->
      let kind, reason = approval_decision_kind_and_reason decision in
      approval_decision_to_string decision, Some kind, reason
  in
  match get_audit_store ~base_path () with
  | None -> ()
  | Some store ->
    let json =
      `Assoc
        ([ "ts", `Float (Unix.gettimeofday ())
         ; "event", `String event_type
         ; "id", `String id
         ; "keeper", `String keeper_name
         ; "tool", `String tool_name
         ; "decision", `String decision
         ; "turn_id", Json_util.int_opt_to_json turn_id
         ; "task_id", Json_util.string_opt_to_json task_id
         ; "goal_id", Json_util.string_opt_to_json goal_id
         ; "goal_ids", `List (List.map (fun goal -> `String goal) goal_ids)
         ; "actor", Json_util.string_opt_to_json actor
         ; ( "decision_source"
           , match decision_source with
             | Some source -> `String (decision_source_to_string source)
             | None -> `Null )
         ]
         @ (match rule_match with
            | Some matched -> [ "rule_match", rule_match_to_yojson matched ]
            | None -> [])
         @ (match source_approval_id with
            | Some approval_id -> [ "source_approval_id", `String approval_id ]
            | None -> [])
         @ (match decision_kind with
            | Some kind -> [ "decision_kind", `String kind ]
            | None -> [])
         @ (match decision_reason with
            | Some reason -> [ "decision_reason", `String reason ]
            | None -> [])
         )
    in
    Cross_context_mutex.with_durable_lock audit_io_mutex (fun () ->
      try
        Fs_compat.append_jsonl (audit_today_path (Dated_jsonl.base_dir store)) json;
        invalidate_recent_audit_cache_for_store store
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> record_queue_failure ~keeper_name ~site:"audit_append" ~id ~event_type exn)
;;

let audit_rule_event ~base_path ~event_type (rule : approval_rule) =
  audit_approval_event
    ~base_path
    ~event_type
    ~id:rule.id
    ~keeper_name:rule.keeper_name
    ~tool_name:rule.tool_name
    ?source_approval_id:rule.source_approval_id
    ()
;;

let audit_scan_window ?keeper_name n =
  match keeper_name with
  | None -> max n 1
  | Some _ ->
    (* Approval audit is global, but runtime trust asks for per-keeper
         "latest" records. Scan a bounded wider window before filtering so a
         busy fleet cannot hide the target keeper behind unrelated events. *)
    wide_audit_scan_window n
;;

let resolved_audit_scan_window = wide_audit_scan_window

let record_audit_read_failure ?keeper_name ?(metric_site = Keeper_approval_queue_failure_site.Audit_read_recent) ~site exn =
  Keeper_fd_pressure.note_exception ~site exn;
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:
      [ "keeper",
        keeper_audit_metric_label keeper_name;
        "site",
        Keeper_approval_queue_failure_site.to_label metric_site
      ]
    ()
;;

let read_recent_audit ~base_path ?keeper_name ?(n = 20) () : Yojson.Safe.t list =
  if n <= 0
  then []
  else (
    match get_audit_store ~base_path () with
    | None -> []
    | Some store ->
      try
        let raw = read_recent_audit_raw store (audit_scan_window ?keeper_name n) in
        let filtered =
          match keeper_name with
          | None -> raw
          | Some name ->
            raw
            |> List.filter (fun json ->
              String.equal name (Safe_ops.json_string ~default:"" "keeper" json))
        in
        filtered |> List.rev |> List.filteri (fun idx _ -> idx < n)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        record_audit_read_failure ?keeper_name ~site:"approval_audit.read_recent" exn;
        [])
;;

let json_member_or_null key json =
  match Json_util.assoc_member_opt key json with
  | Some value -> value
  | None -> `Null
;;

let closed_decision_kind_of_string value =
  match String.trim value with
  | "approve" -> Some "approve"
  | "reject" -> Some "reject"
  | "edit" -> Some "edit"
  | _ -> None
;;

let resolved_approval_decision_kind json =
  Option.bind
    (Safe_ops.json_string_opt "decision_kind" json)
    closed_decision_kind_of_string
;;

let resolved_history_event json =
  match Safe_ops.json_string_opt "event" json with
  | Some event -> String.equal event approval_audit_resolved_event
  | None -> false
;;

let resolved_approval_json_of_audit_event json =
  let resolved_at = Safe_ops.json_float_opt "ts" json in
  `Assoc
    [ "id", `String (Safe_ops.json_string ~default:"" "id" json)
    ; "event", `String (Safe_ops.json_string ~default:"" "event" json)
    ; "keeper_name", `String (Safe_ops.json_string ~default:"" "keeper" json)
    ; "tool_name", `String (Safe_ops.json_string ~default:"" "tool" json)
    ; "decision", Json_util.string_opt_to_json_trimmed (Safe_ops.json_string_opt "decision" json)
    ; "decision_kind", Json_util.string_opt_to_json_trimmed (resolved_approval_decision_kind json)
    ; "decision_reason", json_member_or_null "decision_reason" json
    ; "resolved_at", Json_util.float_opt_to_json resolved_at
    ; "turn_id", json_member_or_null "turn_id" json
    ; "task_id", json_member_or_null "task_id" json
    ; "goal_id", json_member_or_null "goal_id" json
    ; "goal_ids", json_member_or_null "goal_ids" json
    ; "actor", json_member_or_null "actor" json
    ; "decision_source", json_member_or_null "decision_source" json
    ; "rule_match", json_member_or_null "rule_match" json
    ]
;;

let list_recent_resolved_json ~base_path ?(n = recent_resolved_history_limit) ()
  : Yojson.Safe.t list
  =
  if n <= 0
  then []
  else (
    match get_audit_store ~base_path () with
    | None -> []
    | Some store ->
      try
        read_recent_audit_raw store (resolved_audit_scan_window n)
        |> List.filter resolved_history_event
        |> List.rev
        |> List.filteri (fun idx _ -> idx < n)
        |> List.map resolved_approval_json_of_audit_event
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        record_audit_read_failure
          ~metric_site:Keeper_approval_queue_failure_site.Audit_list_recent_resolved
          ~site:"approval_audit.list_recent_resolved"
          exn;
        [])
;;

let generate_id () = make_generated_id "appr"

let default_continuation_channel () =
  Keeper_continuation_channel.unrouted "no originating connector"
;;

let normalized_input_hash = request_fingerprint

type approved_delivery_lookup =
  | Approved_delivery_unconsumed of persisted_delivery
  | Approved_delivery_consumed

type grant_consumption_commit =
  | Consumption_without_audit of grant_consumption
  | Consumption_with_audit of persisted_delivery

let grant_workspace_mismatch ~base_path approval_id stored_base_path =
  Grant_workspace_mismatch
    { approval_id
    ; requested_base_path = base_path
    ; stored_base_path
    }
;;

let approved_delivery_unlocked ~base_path ~id =
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some error -> Error (Grant_store_unavailable error)
  | None ->
    (match SMap.find_opt id (Atomic.get deliveries) with
     | Some delivery ->
       let stored_base_path = delivery.entry.audit_base_path in
       if not (String.equal stored_base_path base_path)
       then Error (grant_workspace_mismatch ~base_path id stored_base_path)
       else
         (match delivery.decision with
          | Decision.Approve ->
            if delivery.grant_consumed
            then Ok Approved_delivery_consumed
            else Ok (Approved_delivery_unconsumed delivery)
          | Decision.Reject _ | Decision.Edit _ ->
            Error (Grant_resolution_not_approved id))
     | None ->
       (match SMap.find_opt id (Atomic.get pending) with
        | Some entry ->
          if String.equal entry.audit_base_path base_path
          then Error (Grant_still_pending id)
          else
            Error
              (grant_workspace_mismatch
                 ~base_path
                 id
                 entry.audit_base_path)
        | None -> Error (Grant_resolution_missing id)))
;;

let approved_resolution_request ~base_path ~id =
  with_pending_store_lock (fun () ->
    match approved_delivery_unlocked ~base_path ~id with
    | Error _ as error -> error
    | Ok Approved_delivery_consumed -> Ok None
    | Ok (Approved_delivery_unconsumed delivery) ->
      Ok
        (Some
           { keeper_name = delivery.entry.keeper_name
           ; tool_name = delivery.entry.tool_name
           ; input = delivery.entry.input
           }))
;;

let approved_resolution_state ~base_path ~id =
  with_pending_store_lock (fun () ->
    match approved_delivery_unlocked ~base_path ~id with
    | Error _ as error -> error
    | Ok Approved_delivery_consumed -> Ok Resolution_consumed
    | Ok (Approved_delivery_unconsumed _) -> Ok Resolution_unconsumed)
;;

let consume_approved_resolution
      ~base_path
      ~id
      ~keeper_name
      ~tool_name
      ~input
  =
  let result =
    with_pending_store_lock (fun () ->
      match approved_delivery_unlocked ~base_path ~id with
      | Error error -> Error error
      | Ok Approved_delivery_consumed ->
        Ok (Consumption_without_audit Consumption_already_committed)
      | Ok (Approved_delivery_unconsumed delivery) ->
        let entry = delivery.entry in
        if
          not
            (String.equal entry.keeper_name keeper_name
             && String.equal entry.tool_name tool_name
             && String.equal entry.input_hash (normalized_input_hash input))
        then Ok (Consumption_without_audit Consumption_not_matching)
        else
          let consumed_delivery = { delivery with grant_consumed = true } in
          let updated_deliveries =
            SMap.add id consumed_delivery (Atomic.get deliveries)
          in
          (match
             persist_snapshot_unlocked
               ~base_path
               ~pending_map:(Atomic.get pending)
               ~delivery_map:updated_deliveries
           with
           | Error error -> Error (Grant_store_unavailable error)
           | Ok () ->
             Atomic.set deliveries updated_deliveries;
             Ok (Consumption_with_audit delivery)))
  in
  match result with
  | Error _ as error -> error
  | Ok (Consumption_without_audit consumption) -> Ok consumption
  | Ok (Consumption_with_audit delivery) ->
    let entry = delivery.entry in
    audit_approval_event
      ~base_path
      ~event_type:"grant_consumed"
      ~id
      ~keeper_name:entry.keeper_name
      ~tool_name:entry.tool_name
      ?turn_id:entry.turn_id
      ?task_id:entry.task_id
      ?goal_id:entry.goal_id
      ~goal_ids:entry.goal_ids
      ~source_approval_id:id
      ~decision_source:delivery.source
      ~decision:Decision.Approve
      ();
    Ok Consumption_committed
;;

let input_preview_of_json (json : Yojson.Safe.t) =
  (* Per-leaf marker-aware truncation: a naive [String.sub] on the
     serialized form would chop a [masc:blob ...] marker mid-field and
     leave sha256/bytes/mime malformed so the approval-queue viewer
     cannot round-trip the preview. *)
  let json = Observability_redact.preview_json_strings ~max_len:200 json in
  let raw = Yojson.Safe.to_string json in
  Observability_redact.redact_preview ~max_len:200 raw
;;

let create_entry
      ~id
      ~sequence
      ~keeper_name
      ~tool_name
      ~input
      ?turn_id
      ?request_context
      ?task_id
      ?goal_id
      ?(goal_ids = [])
      ~continuation_channel
      ~audit_base_path
      ()
  =
  let input_hash = normalized_input_hash input in
  { id
  ; keeper_name
  ; tool_name
  ; input_hash
  ; input
  ; sequence
  ; requested_at = Unix.gettimeofday ()
  ; turn_id
  ; request_context
  ; task_id
  ; goal_id
  ; goal_ids
    ; continuation_channel
    ; audit_base_path
    ; summary_status = Summary_not_requested
    ; exact_attempt = Exact_unbound
    }
;;

let pending_entry_json_fields
      ?(include_input = false)
      (entry : pending_approval)
  =
  [ "id", `String entry.id
  ; "keeper_name", `String entry.keeper_name
  ; "tool_name", `String entry.tool_name
  ; "sequence", `Int entry.sequence
  ; "requested_at", `Float entry.requested_at
  ; "waiting_s", `Float (Unix.gettimeofday () -. entry.requested_at)
  ; "turn_id", Json_util.int_opt_to_json entry.turn_id
  ; "task_id", Json_util.string_opt_to_json entry.task_id
  ; "goal_id", Json_util.string_opt_to_json entry.goal_id
  ; "goal_ids", `List (List.map (fun goal -> `String goal) entry.goal_ids)
  ]
  @ (if include_input
     then
       [ "input", entry.input
       ; "input_preview", `String (input_preview_of_json entry.input)
       ]
     else [])
    (* The [include_input] conditional stays parenthesized so the trailing
       canonical [summary_status] field is present in every wire shape. *)
    @ [ "summary_status", summary_status_to_yojson entry.summary_status
      ; "exact_attempt", exact_attempt_state_to_yojson entry.exact_attempt
      ]
;;

let broadcast_pending entry =
  try
    Sse.broadcast
      (`Assoc
          [ "type", `String approval_sse_pending_event
          ; ( "payload"
            , `Assoc
                (pending_entry_json_fields
                   ~include_input:true
                   entry) )
          ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    record_queue_failure
      ~keeper_name:entry.keeper_name
      ~site:"broadcast_pending"
      ~id:entry.id
      ~event_type:approval_audit_pending_event
      exn
;;

let record_pending (entry : pending_approval) =
  Log.Keeper.info
    "HITL_APPROVAL_PENDING: id=%s sequence=%d keeper=%s tool=%s"
    entry.id
    entry.sequence
    entry.keeper_name
    entry.tool_name;
  audit_approval_event
    ~base_path:entry.audit_base_path
    ~event_type:approval_audit_pending_event
    ~id:entry.id
    ~keeper_name:entry.keeper_name
    ~tool_name:entry.tool_name
    ?turn_id:entry.turn_id
    ?task_id:entry.task_id
    ?goal_id:entry.goal_id
    ~goal_ids:entry.goal_ids
    ();
  broadcast_pending entry
;;

let summary_audit_extras (entry : pending_approval) : (string * Yojson.Safe.t) list =
  match entry.summary_status with
  | Summary_available summary -> [ "model_run_id", `String summary.model_run_id ]
  | Summary_failed { reason; _ } -> [ "failure_reason", `String reason ]
  | Summary_not_requested | Summary_pending -> []
;;

let record_summary_updated ~now (entry : pending_approval) =
  let event_ts =
    match entry.summary_status with
    | Summary_available summary -> summary.generated_at
    | Summary_not_requested | Summary_pending | Summary_failed _ -> now
  in
  (try
     match get_audit_store ~base_path:entry.audit_base_path () with
     | None -> ()
     | Some store ->
       let json =
         `Assoc
           ([ "ts", `Float event_ts
            ; "event", `String approval_audit_summary_event
             ; "id", `String entry.id
             ; "summary_status", summary_status_to_yojson entry.summary_status
             ; "exact_attempt", exact_attempt_state_to_yojson entry.exact_attempt
             ]
            @ summary_audit_extras entry)
       in
       Cross_context_mutex.with_durable_lock audit_io_mutex (fun () ->
         Fs_compat.append_jsonl (audit_today_path (Dated_jsonl.base_dir store)) json;
         invalidate_recent_audit_cache_for_store store)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     record_queue_failure
       ~keeper_name:entry.keeper_name
       ~site:"audit_summary"
       ~id:entry.id
       ~event_type:approval_audit_summary_event
       exn);
  try
    Sse.broadcast
      (`Assoc
         [ "type", `String approval_sse_summary_event
         ; ( "payload"
           , `Assoc
               (pending_entry_json_fields
                  ~include_input:false
                  entry) )
         ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    record_queue_failure
      ~keeper_name:entry.keeper_name
      ~site:"broadcast_summary"
      ~id:entry.id
      ~event_type:approval_sse_summary_event
      exn
;;

(* ── Durable summary-state transitions ───────────────────── *)

(** Read a pending entry by id. Returns [None] if already resolved. *)
let get_pending_entry ~id : pending_approval option = SMap.find_opt id (Atomic.get pending)

let summary_transition_rejection (entry : pending_approval) =
  match entry.exact_attempt with
  | Exact_unbound -> None
  | Exact_bound binding -> Some (Summary_exact_attempt_bound binding)
  | Legacy_execution_uncertain ->
    Some (Summary_legacy_execution_uncertain entry.id)
;;

let persist_pending_entry_unlocked ~map ~(entry : pending_approval) updated_entry =
  let updated = SMap.add entry.id updated_entry map in
  match
    persist_snapshot_unlocked
      ~base_path:entry.audit_base_path
      ~pending_map:updated
      ~delivery_map:(Atomic.get deliveries)
  with
  | Error _ as error -> error
  | Ok () ->
    Atomic.set pending updated;
    Ok true
;;

(** Complete an unbound legacy judge exactly once. Exact attempts must use
    [complete_summary_exact_attempt], which commits content and identity
    together. *)
let complete_summary ~id summary_status =
  with_pending_store_lock (fun () ->
    let map = Atomic.get pending in
    match SMap.find_opt id map with
    | None -> Ok false
    | Some entry ->
      (match summary_transition_rejection entry with
       | Some rejection -> Error (Summary_transition_rejected rejection)
       | None ->
         (match entry.summary_status with
          | Summary_pending ->
            persist_pending_entry_unlocked
              ~map
              ~entry
              { entry with summary_status }
            |> Result.map_error (fun error ->
              Summary_transition_storage_error error)
          | Summary_not_requested
          | Summary_available _
          | Summary_failed _ ->
            Ok false)))
;;

let publish_summary_update ~id =
  let now = Time_compat.now () in
  match get_pending_entry ~id with
  | Some updated -> record_summary_updated ~now updated
  | None -> ()
;;

let publish_summary_transition ~id = function
  | Ok true ->
    publish_summary_update ~id;
    Ok true
  | Ok false -> Ok false
  | Error error -> Error error
;;

let publish_exact_attempt_transition ~id = function
  | Ok true ->
    publish_summary_update ~id;
    Ok true
  | Ok false -> Ok false
  | Error error -> Error error
;;

let validate_exact_attempt_candidate
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  let invalid field value =
    if String.trim value = ""
    then Error (Exact_attempt_rejected (Exact_attempt_invalid_identity field))
    else Ok ()
  in
  let ( let* ) = Result.bind in
  let* () = invalid "approval_id" id in
  let* () = invalid "input_hash" input_hash in
  let* () =
    if sequence > 0
    then Ok ()
    else Error (Exact_attempt_rejected (Exact_attempt_invalid_identity "sequence"))
  in
  let* () = invalid "slot_id" slot_id in
  let* () = invalid "call_id" call_id in
  let* () = invalid "plan_fingerprint" plan_fingerprint in
  let* () =
    if is_lowercase_sha256 request_body_sha256
    then Ok ()
    else
      Error
        (Exact_attempt_rejected
           (Exact_attempt_invalid_identity "request_body_sha256"))
  in
  Ok
    { approval_id = id
    ; input_hash
    ; sequence
    ; slot_id
    ; call_id
    ; plan_fingerprint
    ; request_body_sha256
    ; status = Exact_dispatch_uncertain
    }
;;

let exact_attempt_entry_unlocked map candidate =
  match SMap.find_opt candidate.approval_id map with
  | None ->
    Error
      (Exact_attempt_rejected
         (Exact_attempt_not_found candidate.approval_id))
  | Some entry
    when not
           (String.equal entry.input_hash candidate.input_hash
            && Int.equal entry.sequence candidate.sequence) ->
    Error
      (Exact_attempt_rejected
         (Exact_attempt_key_mismatch
            { approval_id = candidate.approval_id
            ; input_hash = candidate.input_hash
            ; sequence = candidate.sequence
            }))
  | Some entry -> Ok entry
;;

let persist_exact_attempt_entry_unlocked ~map ~entry updated_entry =
  persist_pending_entry_unlocked ~map ~entry updated_entry
  |> Result.map_error (fun error -> Exact_attempt_storage_error error)
;;

let bind_summary_exact_attempt
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match entry.summary_status with
           | Summary_not_requested
           | Summary_available _
           | Summary_failed _ ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_summary_not_pending entry.id))
           | Summary_pending ->
             (match entry.exact_attempt with
              | Exact_unbound ->
                persist_exact_attempt_entry_unlocked
                  ~map
                  ~entry
                  { entry with exact_attempt = Exact_bound candidate }
              | Legacy_execution_uncertain ->
                Error
                  (Exact_attempt_rejected
                     (Exact_attempt_legacy_execution_uncertain entry.id))
              | Exact_bound existing
                when exact_attempt_identity_matches existing candidate ->
                (match existing.status with
                 | Exact_dispatch_uncertain -> Ok false
                 | Exact_released_before_dispatch
                 | Exact_quarantined _
                 | Exact_completed ->
                   Error
                     (Exact_attempt_rejected
                        (Exact_attempt_status_conflict existing)))
              | Exact_bound
                  ({ status = Exact_released_before_dispatch; _ } as _existing) ->
                persist_exact_attempt_entry_unlocked
                  ~map
                  ~entry
                  { entry with exact_attempt = Exact_bound candidate }
              | Exact_bound existing ->
                Error
                  (Exact_attempt_rejected
                     (Exact_attempt_identity_conflict existing)))))
  in
  publish_exact_attempt_transition ~id result
;;

let release_summary_exact_attempt_before_dispatch
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match entry.exact_attempt with
           | Exact_unbound ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_unbound_state entry.id))
           | Legacy_execution_uncertain ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_legacy_execution_uncertain entry.id))
           | Exact_bound existing
             when not (exact_attempt_identity_matches existing candidate) ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_identity_conflict existing))
           | Exact_bound existing ->
             (match existing.status with
              | Exact_dispatch_uncertain ->
                let released =
                  { existing with status = Exact_released_before_dispatch }
                in
                persist_exact_attempt_entry_unlocked
                  ~map
                  ~entry
                  { entry with exact_attempt = Exact_bound released }
              | Exact_released_before_dispatch -> Ok false
              | Exact_quarantined _
              | Exact_completed ->
                Error
                  (Exact_attempt_rejected
                     (Exact_attempt_status_conflict existing)))))
  in
  publish_exact_attempt_transition ~id result
;;

let fail_summary_exact_attempt_before_dispatch
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ~reason
      ~retryable
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match entry.exact_attempt with
           | Exact_unbound ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_unbound_state entry.id))
           | Legacy_execution_uncertain ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_legacy_execution_uncertain entry.id))
           | Exact_bound existing
             when not (exact_attempt_identity_matches existing candidate) ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_identity_conflict existing))
           | Exact_bound existing ->
             (match existing.status, entry.summary_status with
              | Exact_dispatch_uncertain, Summary_pending ->
                let released =
                  { existing with status = Exact_released_before_dispatch }
                in
                persist_exact_attempt_entry_unlocked
                  ~map
                  ~entry
                  { entry with
                    summary_status = Summary_failed { reason; retryable }
                  ; exact_attempt = Exact_bound released
                  }
              | ( Exact_released_before_dispatch
                , Summary_failed
                    { reason = durable_reason
                    ; retryable = durable_retryable
                    } )
                when String.equal durable_reason reason
                     && Bool.equal durable_retryable retryable ->
                Ok false
              | Exact_dispatch_uncertain, _ ->
                Error
                  (Exact_attempt_rejected
                     (Exact_attempt_summary_not_pending entry.id))
              | ( Exact_released_before_dispatch
                | Exact_quarantined _
                | Exact_completed ),
                _ ->
                Error
                  (Exact_attempt_rejected
                     (Exact_attempt_status_conflict existing)))))
  in
  publish_exact_attempt_transition ~id result
;;

let quarantine_summary_exact_attempt
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ~cause
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match entry.exact_attempt with
           | Exact_unbound ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_unbound_state entry.id))
           | Legacy_execution_uncertain ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_legacy_execution_uncertain entry.id))
           | Exact_bound existing
             when not (exact_attempt_identity_matches existing candidate) ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_identity_conflict existing))
           | Exact_bound existing ->
             (match existing.status with
              | Exact_dispatch_uncertain ->
                let quarantined =
                  { existing with status = Exact_quarantined cause }
                in
                persist_exact_attempt_entry_unlocked
                  ~map
                  ~entry
                  { entry with exact_attempt = Exact_bound quarantined }
              | Exact_quarantined durable_cause
                when durable_cause = cause ->
                Ok false
              | Exact_quarantined _
              | Exact_released_before_dispatch
              | Exact_completed ->
                Error
                  (Exact_attempt_rejected
                     (Exact_attempt_status_conflict existing)))))
  in
  publish_exact_attempt_transition ~id result
;;

let complete_summary_exact_attempt
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ~summary
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match entry.exact_attempt with
           | Exact_unbound ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_unbound_state entry.id))
           | Legacy_execution_uncertain ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_legacy_execution_uncertain entry.id))
           | Exact_bound existing
             when not (exact_attempt_identity_matches existing candidate) ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_identity_conflict existing))
           | Exact_bound existing
             when not (String.equal summary.model_run_id existing.call_id) ->
             Error
               (Exact_attempt_rejected
                  (Exact_attempt_provenance_mismatch
                     { approval_id = entry.id
                     ; expected_call_id = existing.call_id
                     ; actual_model_run_id = summary.model_run_id
                     }))
           | Exact_bound existing ->
             (match existing.status, entry.summary_status with
              | Exact_dispatch_uncertain, Summary_pending ->
                let completed = { existing with status = Exact_completed } in
                persist_exact_attempt_entry_unlocked
                  ~map
                  ~entry
                  { entry with
                    summary_status = Summary_available summary
                  ; exact_attempt = Exact_bound completed
                  }
              | Exact_completed, Summary_available durable_summary ->
                if
                  Yojson.Safe.equal
                    (hitl_context_summary_to_yojson durable_summary)
                    (hitl_context_summary_to_yojson summary)
                then Ok false
                else
                  Error
                    (Exact_attempt_rejected
                       (Exact_attempt_content_conflict entry.id))
              | ( Exact_released_before_dispatch
                | Exact_quarantined _
                | Exact_completed ),
                _ ->
                Error
                  (Exact_attempt_rejected
                     (Exact_attempt_status_conflict existing))
              | Exact_dispatch_uncertain, _ ->
                Error
                  (Exact_attempt_rejected
                     (Exact_attempt_summary_not_pending entry.id)))))
  in
  publish_exact_attempt_transition ~id result
;;

let mark_summary_pending ~id =
  let result =
    with_pending_store_lock (fun () ->
      let map = Atomic.get pending in
      match SMap.find_opt id map with
      | None -> Ok false
      | Some entry ->
        (match summary_transition_rejection entry with
         | Some rejection -> Error (Summary_transition_rejected rejection)
         | None ->
           (match entry.summary_status with
            | Summary_not_requested ->
              persist_pending_entry_unlocked
                ~map
                ~entry
                { entry with summary_status = Summary_pending }
              |> Result.map_error (fun error ->
                Summary_transition_storage_error error)
            | Summary_pending
            | Summary_available _
            | Summary_failed _ ->
              Ok false)))
  in
  publish_summary_transition ~id result
;;

let attach_summary ~id summary =
  let updated = complete_summary ~id (Summary_available summary) in
  publish_summary_transition ~id updated
;;

let mark_summary_failed ~id ~reason ~retryable =
  let updated = complete_summary ~id (Summary_failed { reason; retryable }) in
  publish_summary_transition ~id updated
;;

let restart_failed_summary ~id =
  let updated =
    with_pending_store_lock (fun () ->
      let map = Atomic.get pending in
      match SMap.find_opt id map with
        | None -> Ok false
        | Some
            ({ summary_status = Summary_failed _
             ; exact_attempt =
                 Exact_bound { status = Exact_released_before_dispatch; _ }
             ; _
             } as entry) ->
          persist_pending_entry_unlocked
            ~map
            ~entry
            { entry with
              summary_status = Summary_pending
            ; exact_attempt = Exact_unbound
            }
          |> Result.map_error (fun error ->
            Summary_transition_storage_error error)
        | Some entry ->
          (match summary_transition_rejection entry with
           | Some rejection -> Error (Summary_transition_rejected rejection)
           | None ->
             (match entry.summary_status with
              | Summary_failed _ ->
                persist_pending_entry_unlocked
                  ~map
                  ~entry
                  { entry with summary_status = Summary_pending }
                |> Result.map_error (fun error ->
                  Summary_transition_storage_error error)
              | Summary_not_requested
              | Summary_pending
              | Summary_available _ ->
                Ok false)))
  in
  publish_summary_transition ~id updated
;;

let restart_failed_summaries ~base_path =
  let updated =
    with_pending_store_lock (fun () ->
      let map = Atomic.get pending in
        let reopened_ids, reopened, rejected =
          SMap.fold
            (fun id (entry : pending_approval) (ids, acc, rejected) ->
               if
                 String.equal entry.audit_base_path base_path
                 &&
                 match entry.summary_status with
                 | Summary_failed _ -> true
                 | Summary_not_requested
                 | Summary_pending
                 | Summary_available _ ->
                   false
               then
                 (match entry.exact_attempt with
                  | Exact_bound
                      { status = Exact_released_before_dispatch; _ } ->
                    ( id :: ids
                    , SMap.add
                        id
                        { entry with
                          summary_status = Summary_pending
                        ; exact_attempt = Exact_unbound
                        }
                        acc
                    , rejected )
                  | _ ->
                    (match summary_transition_rejection entry with
                     | Some rejection -> ids, acc, Some rejection
                     | None ->
                       ( id :: ids
                       , SMap.add
                           id
                           { entry with summary_status = Summary_not_requested }
                           acc
                       , rejected )))
               else ids, acc, rejected)
            map
            ([], map, None)
        in
        match rejected, reopened_ids with
        | Some rejection, _ ->
          Error (Summary_transition_rejected rejection)
        | None, [] -> Ok []
        | None, _ :: _ ->
          (match
             persist_snapshot_unlocked
             ~base_path
             ~pending_map:reopened
             ~delivery_map:(Atomic.get deliveries)
         with
         | Error error ->
           Error (Summary_transition_storage_error error)
         | Ok () ->
           Atomic.set pending reopened;
           Ok (List.rev reopened_ids)))
  in
  match updated with
  | Error _ as error -> error
  | Ok ids ->
    List.iter (fun id -> publish_summary_update ~id) ids;
    Ok ids
;;

let record_resolution_delivery_failure ~keeper_name ~approval_id reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:
      [ "keeper", keeper_name
      ; ( "site"
        , Keeper_approval_queue_failure_site.(to_label Resolution_delivery) )
      ]
    ();
  Log.Keeper.error
    ~keeper_name
    "hitl resolution delivery failed approval=%s: %s"
    approval_id
    reason
;;

let signal_resolution_after_commit ~base_path ~keeper_name ~approval_id =
  try
    let outcome =
      Keeper_registry.wakeup_running
        ~intent:Keeper_registry.Hitl_resolution
        ~base_path
        keeper_name
    in
    let outcome_label, detail =
      match outcome with
      | Keeper_registry.Signaled -> "signaled", "running"
      | Keeper_registry.Deferred_unregistered ->
        "deferred_unregistered", "unregistered"
      | Keeper_registry.Deferred_not_running phase ->
        "deferred_not_running", Keeper_state_machine.phase_to_string phase
      | Keeper_registry.Deferred_lifecycle denial ->
        ( "deferred_lifecycle"
        , Keeper_lifecycle_admission.autonomous_denial_to_wire denial )
    in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalResolutionSignal)
      ~labels:[ "keeper", keeper_name; "outcome", outcome_label ]
      ();
    Log.Keeper.info
      ~keeper_name
      "hitl resolution committed approval=%s signal=%s phase=%s"
      approval_id
      outcome_label
      detail
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels:
        [ "keeper", keeper_name
        ; "site", Keeper_approval_queue_failure_site.(to_label Resolution_signal)
        ]
      ();
    Log.Keeper.error
      ~keeper_name
      "hitl resolution signal failed after durable commit approval=%s: %s"
      approval_id
      (Printexc.to_string exn)
;;

let commit_keeper_approval_resolution
    ~base_path ~keeper_name ~approval_id ~decision
    ~(channel : Keeper_continuation_channel.t) =
  match
    try
      Keeper_registry_event_queue.enqueue_hitl_resolution_durable_result
        ~base_path
        ~keeper_name
        ~approval_id
        ~decision
        ~channel
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  with
  | Ok () -> Ok ()
  | Error reason ->
    record_resolution_delivery_failure ~keeper_name ~approval_id reason;
    Error reason
;;

let hitl_resolution_decision_of_approval_decision = function
  | Decision.Approve -> Keeper_event_queue.Hitl_approved
  | Decision.Reject rationale -> Keeper_event_queue.Hitl_rejected rationale
  | Decision.Edit input -> Keeper_event_queue.Hitl_edited input
;;

let deliver_resolution ~base_path (entry : pending_approval) decision =
  commit_keeper_approval_resolution
    ~base_path
    ~keeper_name:entry.keeper_name
    ~approval_id:entry.id
    ~decision:(hitl_resolution_decision_of_approval_decision decision)
    ~channel:entry.continuation_channel
;;

let resolve_entry
      ?(before_terminal_publish = fun () -> ())
      ~base_path
      (entry : pending_approval)
      ~(source : decision_source)
      (decision : decision)
  =
  let decision_str = approval_decision_to_string decision in
  Log.Keeper.info
    "HITL_APPROVAL_RESOLVED: id=%s keeper=%s tool=%s decision=%s"
    entry.id
    entry.keeper_name
    entry.tool_name
    decision_str;
  audit_approval_event
    ~base_path:base_path
    ~event_type:approval_audit_resolved_event
    ~id:entry.id
    ~keeper_name:entry.keeper_name
    ~tool_name:entry.tool_name
    ?turn_id:entry.turn_id
    ?task_id:entry.task_id
    ?goal_id:entry.goal_id
    ~goal_ids:entry.goal_ids
    ~decision_source:source
    ~decision
    ();
  before_terminal_publish ();
  try
    Sse.broadcast
      (`Assoc
          [ "type", `String approval_sse_resolved_event
          ; ( "payload"
            , `Assoc
                [ "id", `String entry.id
                ; "keeper_name", `String entry.keeper_name
                ; "tool_name", `String entry.tool_name
                ; "decision", `String decision_str
                ] )
          ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    record_queue_failure
      ~keeper_name:entry.keeper_name
      ~site:"broadcast_resolved"
      ~id:entry.id
      ~event_type:approval_audit_resolved_event
      exn
;;

let pending_entry_matches
      (entry : pending_approval)
      ~base_path
      ~keeper_name
      ~tool_name
      ~input_hash
      ~turn_id
      ~task_id
      ~goal_id
      ~goal_ids
      ~continuation_channel
  =
  String.equal entry.audit_base_path base_path
  && String.equal entry.keeper_name keeper_name
  && String.equal entry.tool_name tool_name
  && String.equal entry.input_hash input_hash
  && entry.turn_id = turn_id
  && entry.task_id = task_id
  && entry.goal_id = goal_id
  && entry.goal_ids = goal_ids
  && Yojson.Safe.equal
       (Keeper_continuation_channel.to_yojson entry.continuation_channel)
       (Keeper_continuation_channel.to_yojson continuation_channel)
;;

let find_pending_id_in_map
      (map : pending_approval SMap.t)
      ~base_path
      ~keeper_name
      ~tool_name
      ~input_hash
      ~turn_id
      ~task_id
      ~goal_id
      ~goal_ids
      ~continuation_channel
  =
  SMap.fold
    (fun id (entry : pending_approval) acc ->
       match acc with
       | Some _ -> acc
       | None ->
         if
           pending_entry_matches
             entry
             ~base_path
             ~keeper_name
             ~tool_name
             ~input_hash
             ~turn_id
             ~task_id
             ~goal_id
             ~goal_ids
             ~continuation_channel
         then Some id
         else None)
    map
    None
;;

(* ── Nonblocking submission ───────────────────────────────── *)

let submit_pending
      ~keeper_name
      ~tool_name
      ~input
      ~base_path
      ?turn_id
      ?request_context
      ?task_id
      ?goal_id
      ?(goal_ids = [])
      ?continuation_channel
      ()
  : (string, storage_error) result
  =
  let input_hash = normalized_input_hash input in
  let continuation_channel =
    Option.value continuation_channel ~default:(default_continuation_channel ())
  in
  let stored =
    with_pending_store_lock (fun () ->
      let map = Atomic.get pending in
      match
        find_pending_id_in_map
          map
          ~base_path
          ~keeper_name
          ~tool_name
          ~input_hash
          ~turn_id
          ~task_id
          ~goal_id
          ~goal_ids
          ~continuation_channel
      with
      | Some id -> Ok (id, None)
      | None ->
        let id = generate_id () in
        (match next_sequence_lifecycle ~base_path with
         | Uninstalled ->
           Error
             { path = pending_store_path ~base_path
             ; reason =
                 "gate_pending store is not installed; submit requires a completed install"
             }
         | Unavailable error -> Error error
         | Ready sequence ->
           if sequence = max_int
           then
             Error
               { path = pending_store_path ~base_path
               ; reason = "approval sequence exhausted its integer representation"
               }
           else
             let entry =
               create_entry
                 ~id
                 ~sequence
                 ~keeper_name
                 ~tool_name
                 ~input
                 ?turn_id
              ?request_context
              ?task_id
              ?goal_id
              ~goal_ids
              ~continuation_channel
              ~audit_base_path:base_path
              ()
          in
          let updated = SMap.add id entry map in
          let following_sequence = sequence + 1 in
          (match
             persist_snapshot_with_sequence_unlocked
               ~base_path
               ~next_sequence:following_sequence
               ~pending_map:updated
               ~delivery_map:(Atomic.get deliveries)
           with
           | Error error -> Error error
           | Ok () ->
             Atomic.set pending updated;
             Atomic.set
               next_sequences
               (SMap.add base_path following_sequence (Atomic.get next_sequences));
             Ok (id, Some entry))))
  in
  match stored with
  | Error _ as error -> error
  | Ok (id, None) -> Ok id
  | Ok (id, Some entry) ->
    record_pending entry;
    Ok id
;;

(* ── Resolve (operator action) ────────────────────────────── *)

type resolve_error =
  | Not_found of string
  | Already_resolved of string
  | Delivery_failed of
      { approval_id : string
      ; reason : string
      }
  | Persistence_failed of
      { approval_id : string
      ; storage_error : storage_error
      }

let resolve_error_to_string = function
  | Not_found id -> Printf.sprintf "approval %s not found" id
  | Already_resolved id -> Printf.sprintf "approval %s already resolved" id
  | Delivery_failed { approval_id; reason } ->
    Printf.sprintf "approval %s resolution delivery failed: %s" approval_id reason
  | Persistence_failed { approval_id; storage_error } ->
    Printf.sprintf
      "approval %s queue persistence failed: %s"
      approval_id
      (storage_error_to_string storage_error)
;;

module Resolution_claims = Set_util.StringSet

let resolution_claims : Resolution_claims.t Atomic.t =
  Atomic.make Resolution_claims.empty
;;

let rec claim_resolution id =
  let claims = Atomic.get resolution_claims in
  if Resolution_claims.mem id claims
  then false
  else
    let claimed = Resolution_claims.add id claims in
    if Atomic.compare_and_set resolution_claims claims claimed
    then true
    else claim_resolution id
;;

let release_resolution_claim id =
  atomic_update resolution_claims (fun claims -> Resolution_claims.remove id claims)
;;

type journal_error =
  | Journal_not_found
  | Journal_storage of storage_error

let journal_resolution ~id ~decision ~source ~remember_rule ~rule_expires_at ~created_by =
  with_pending_store_lock (fun () ->
    let pending_map = Atomic.get pending in
    match SMap.find_opt id pending_map with
    | None -> Error Journal_not_found
    | Some entry ->
      let delivery =
        { entry
        ; decision
        ; source
        ; remember_rule
        ; rule_expires_at
        ; created_by
        ; grant_consumed = false
        }
      in
      let updated_pending = SMap.remove id pending_map in
      let updated_deliveries = SMap.add id delivery (Atomic.get deliveries) in
      (match
         persist_snapshot_unlocked
           ~base_path:entry.audit_base_path
           ~pending_map:updated_pending
           ~delivery_map:updated_deliveries
       with
       | Error storage_error -> Error (Journal_storage storage_error)
       | Ok () ->
         Atomic.set pending updated_pending;
         Atomic.set deliveries updated_deliveries;
         Ok delivery))
;;

let remove_delivery_from_store delivery =
  with_pending_store_lock (fun () ->
    let delivery_map = Atomic.get deliveries in
    let updated_deliveries = SMap.remove delivery.entry.id delivery_map in
    match
      persist_snapshot_unlocked
        ~base_path:delivery.entry.audit_base_path
        ~pending_map:(Atomic.get pending)
        ~delivery_map:updated_deliveries
    with
    | Error _ as error -> error
    | Ok () ->
      Atomic.set deliveries updated_deliveries;
      Ok ())
;;

let approval_decision_equal left right =
  match left, right with
  | Decision.Approve, Decision.Approve -> true
  | Decision.Reject left, Decision.Reject right -> String.equal left right
  | Decision.Edit left, Decision.Edit right -> Yojson.Safe.equal left right
  | (Decision.Approve | Decision.Reject _ | Decision.Edit _),
    (Decision.Approve | Decision.Reject _ | Decision.Edit _) ->
    false
;;

let remember_rule_for_entry ~base_path ?created_by ?rule_expires_at (entry : pending_approval) =
  try
    match
      upsert_rule
        ~base_path
        ~keeper_name:entry.keeper_name
        ~tool_name:entry.tool_name
        ~input:entry.input
        ?created_by
        ~source_approval_id:entry.id
        ?expires_at:rule_expires_at
        ()
    with
    | Ok (rule, created) ->
      if created then audit_rule_event ~base_path ~event_type:"rule_created" rule;
      Ok rule
    | Error reason -> Error reason
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let reason = Printexc.to_string exn in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels:
        [ "keeper", entry.keeper_name
        ; "site", Keeper_approval_queue_failure_site.(to_label Remember_rule)
        ]
      ();
    Log.Keeper.warn
      "approval_queue: remember rule failed id=%s err=%s"
      entry.id
      reason;
    Error
      ({ path = rules_path ~base_path ()
       ; reason
       }
       : rule_store_error)
;;

let remember_rule_for_delivery delivery =
  match delivery.decision, delivery.remember_rule with
  | Decision.Approve, true ->
    (match
       remember_rule_for_entry
         ~base_path:delivery.entry.audit_base_path
         ?created_by:delivery.created_by
         ?rule_expires_at:delivery.rule_expires_at
         delivery.entry
     with
     | Ok rule -> Ok (Some rule)
     | Error rule_error ->
       Error
         { path = rule_error.path
         ; reason = rule_error.reason
         })
  | (Decision.Approve | Decision.Reject _ | Decision.Edit _),
    false ->
    Ok None
  | (Decision.Reject _ | Decision.Edit _), true -> Ok None
;;

let complete_delivery delivery =
  let id = delivery.entry.id in
  let base_path = delivery.entry.audit_base_path in
  if delivery.grant_consumed
  then Ok { remembered_rule = None }
  else
  match deliver_resolution ~base_path delivery.entry delivery.decision with
  | Error reason -> Error (Delivery_failed { approval_id = id; reason })
  | Ok () ->
    (match remember_rule_for_delivery delivery with
     | Error storage_error ->
       Error (Persistence_failed { approval_id = id; storage_error })
     | Ok remembered_rule ->
       let finish () =
         resolve_entry
           ~base_path
           delivery.entry
           ~source:delivery.source
           delivery.decision;
         signal_resolution_after_commit
           ~base_path
           ~keeper_name:delivery.entry.keeper_name
           ~approval_id:id;
         Ok { remembered_rule }
       in
       (match delivery.decision with
        | Decision.Approve ->
          (* Keep the resolved journal entry until the exact Gate request
             consumes it. The wake event is only a correlation message and
             cannot become a second authorization SSOT. *)
          finish ()
        | Decision.Reject _ | Decision.Edit _ ->
          (match remove_delivery_from_store delivery with
           | Error storage_error ->
             Error (Persistence_failed { approval_id = id; storage_error })
           | Ok () -> finish ())))
;;

let compare_pending_order left right =
  match String.compare left.audit_base_path right.audit_base_path with
  | 0 ->
    let sequence_order = Int.compare left.sequence right.sequence in
    if sequence_order = 0 then String.compare left.id right.id else sequence_order
  | workspace_order -> workspace_order
;;

let install_persistence_internal ~after_load ~base_path =
  (* Snapshot read and installation are one transition. The hybrid pending
     store lock serializes Eio and non-Eio callers, cooperatively gates Eio
     waiters, and protects cancellation across the durable transition. Keeping
     the load inside this boundary prevents a same-workspace mutation from
     being published between the read and the replacement below. *)
  let installed =
    with_pending_store_lock (fun () ->
      let loaded_snapshot = load_snapshot_unlocked ~base_path in
      after_load ();
      match loaded_snapshot with
      | Error storage_error ->
        mark_store_unavailable_unlocked ~base_path storage_error;
        Error storage_error
      | Ok (loaded_pending, loaded_deliveries, loaded_next_sequence) ->
        let current_pending =
          remove_base_entries ~base_path (Atomic.get pending) Fun.id
        in
        let current_deliveries =
          remove_base_entries
            ~base_path
            (Atomic.get deliveries)
            (fun delivery -> delivery.entry)
        in
        (match
           merge_loaded_map
             ~surface:"gate_pending.pending"
             ~existing:current_pending
             ~loaded:loaded_pending,
           merge_loaded_map
             ~surface:"gate_pending.deliveries"
             ~existing:current_deliveries
             ~loaded:loaded_deliveries
         with
         | Error reason, _ | _, Error reason ->
           let path = pending_store_path ~base_path in
           report_pending_read_drop
             ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
             ~path
             ~detail:reason;
           let error = { path; reason } in
           mark_store_unavailable_unlocked ~base_path error;
           Error error
         | Ok pending_map, Ok delivery_map ->
           (match first_shared_id pending_map delivery_map with
            | Some id ->
              let path = pending_store_path ~base_path in
              let reason =
                Printf.sprintf
                  "gate_pending id %s collides across pending and delivery states"
                  id
              in
              report_pending_read_drop
                ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                ~path
                ~detail:reason;
              let error = { path; reason } in
              mark_store_unavailable_unlocked ~base_path error;
              Error error
            | None ->
              clear_store_unavailable_unlocked ~base_path;
              Atomic.set pending pending_map;
              Atomic.set deliveries delivery_map;
              Atomic.set
                next_sequences
                (SMap.add
                   base_path
                   loaded_next_sequence
                   (Atomic.get next_sequences));
              Ok
                ( SMap.cardinal loaded_pending
                , SMap.bindings loaded_deliveries
                  |> List.map snd
                  |> List.sort (fun left right ->
                    compare_pending_order left.entry right.entry) ))))
  in
  match installed with
  | Error storage_error -> Error (Install_storage_failed storage_error)
  | Ok (loaded_pending, loaded_deliveries) ->
    let rec replay count failures = function
      | [] ->
        Ok
          { loaded_pending
          ; replayed_deliveries = count
          ; delivery_replay_failures = List.rev failures
          }
      | delivery :: rest ->
        if delivery.grant_consumed
        then replay count failures rest
        else
          (match complete_delivery delivery with
           | Ok _ -> replay (count + 1) failures rest
           | Error error ->
             let failure =
               { approval_id = delivery.entry.id
               ; reason = resolve_error_to_string error
               }
             in
             replay count (failure :: failures) rest)
    in
    replay 0 [] loaded_deliveries
;;

let install_persistence ~base_path =
  install_persistence_internal ~after_load:(fun () -> ()) ~base_path
;;

module For_testing = struct
  let reset_audit_store () =
    Stdlib.Mutex.protect audit_stores_mu (fun () -> Hashtbl.clear audit_stores);
    Stdlib.Mutex.protect recent_audit_cache_mu (fun () ->
      Hashtbl.clear recent_audit_cache)
  ;;

  let with_pending_store_lock = with_pending_store_lock

  let reset_runtime_state () =
    with_pending_store_lock (fun () ->
      Atomic.set pending SMap.empty;
      Atomic.set deliveries SMap.empty;
      Atomic.set unavailable_stores SMap.empty;
      Atomic.set next_sequences SMap.empty)
  ;;

  let install_persistence_with_after_load_hook ~base_path ~after_load =
    install_persistence_internal ~after_load ~base_path
  ;;

  let pending_store_path = pending_store_path
  let always_allowed_store_path ~base_path = rules_path ~base_path ()
end

let resolve_with_policy
      ~base_path
      ~id
      ~(decision : decision)
      ?(source = Human_operator)
      ?(remember_rule = false)
      ?rule_expires_at
      ?created_by
      ()
  : (resolution_result, resolve_error) result
  =
  let belongs_to_workspace () =
    match SMap.find_opt id (Atomic.get pending) with
    | Some entry -> String.equal entry.audit_base_path base_path
    | None ->
      (match SMap.find_opt id (Atomic.get deliveries) with
       | Some delivery -> String.equal delivery.entry.audit_base_path base_path
       | None -> false)
  in
  if not (belongs_to_workspace ())
  then Error (Not_found id)
  else if not (claim_resolution id)
  then Error (Already_resolved id)
  else
    Fun.protect
      ~finally:(fun () -> release_resolution_claim id)
      (fun () ->
         if not (belongs_to_workspace ())
         then Error (Not_found id)
         else match SMap.find_opt id (Atomic.get pending) with
         | Some _ ->
           let remember_rule =
             match decision with
             | Decision.Approve -> remember_rule
             | Decision.Reject _ | Decision.Edit _ -> false
           in
           let rule_expires_at =
             if remember_rule then rule_expires_at else None
           in
           (match
              journal_resolution
                ~id
                ~decision
                ~source
                ~remember_rule
                ~rule_expires_at
                ~created_by
            with
            | Error Journal_not_found -> Error (Not_found id)
            | Error (Journal_storage storage_error) ->
              Error (Persistence_failed { approval_id = id; storage_error })
            | Ok delivery -> complete_delivery delivery)
         | None ->
           (match SMap.find_opt id (Atomic.get deliveries) with
            | None -> Error (Not_found id)
            | Some delivery ->
              let same_request =
                approval_decision_equal decision delivery.decision
                && source = delivery.source
                && remember_rule = delivery.remember_rule
                && rule_expires_at = delivery.rule_expires_at
                && created_by = delivery.created_by
              in
              if same_request
              then complete_delivery delivery
              else Error (Already_resolved id)))
;;

(* ── Query ────────────────────────────────────────────────── *)

(** List all pending approvals as JSON. *)
let pending_entries_in_sequence_order () =
  SMap.fold (fun _id entry acc -> entry :: acc) (Atomic.get pending) []
  |> List.sort compare_pending_order
;;

let list_pending_json () : Yojson.Safe.t =
  pending_entries_in_sequence_order ()
  |> List.map (fun entry -> `Assoc (pending_entry_json_fields entry))
  |> fun entries -> `List entries
;;

let list_pending_dashboard_json () : Yojson.Safe.t =
  pending_entries_in_sequence_order ()
  |> List.map (fun entry ->
    `Assoc (pending_entry_json_fields ~include_input:true entry))
  |> fun entries -> `List entries
;;

let list_pending_entries () : pending_approval list =
  pending_entries_in_sequence_order ()
;;

let pending_count_for_keeper ~keeper_name : int =
  SMap.fold
    (fun _ (entry : pending_approval) count ->
       if String.equal entry.keeper_name keeper_name then count + 1 else count)
    (Atomic.get pending)
    0
;;
