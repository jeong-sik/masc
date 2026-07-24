module Candidate = Keeper_board_attention_candidate
module Partition = Keeper_board_attention_partition
module Wake = Keeper_board_attention_worker_wake

let request_schema = "keeper.board_attention.quarantine.recovery.request.v1"
let tool_command_schema = "keeper.board_attention.quarantine.recovery.command.v1"
let result_schema = "keeper.board_attention.quarantine.recovery.result.v1"

type decision = Acknowledge_and_requeue

type request =
  { candidate_id : string
  ; expected_quarantine_id : string
  ; decision : decision
  }

type t =
  { keeper_name : string
  ; partition_id : string
  ; request : request
  }

type input_error =
  | Object_required
  | Duplicate_fields of string list
  | Unsupported_fields of string list
  | Missing_fields of string list
  | Invalid_field of string
  | Unsupported_schema of string
  | Unsupported_decision of string
  | Invalid_keeper_name of string

type execution_error =
  | Candidate_state_conflict of string
  | Partition_state_conflict of string
  | Durability_unconfirmed of string
  | Wake_request_failed of string

type report =
  { candidate : Candidate.candidate
  ; partition : Partition.t
  ; wake : Wake.wake_result
  }

let ( let* ) = Result.bind

let sorted_unique values =
  values |> List.sort_uniq String.compare
;;

let validate_exact_object ~expected = function
  | `Assoc fields ->
    let keys = List.map fst fields in
    let duplicates =
      keys
      |> List.filter (fun key ->
        List.length (List.filter (String.equal key) keys) > 1)
      |> sorted_unique
    in
    if duplicates <> []
    then Error (Duplicate_fields duplicates)
    else
      let unsupported =
        keys
        |> List.filter (fun key -> not (List.mem key expected))
        |> sorted_unique
      in
      if unsupported <> []
      then Error (Unsupported_fields unsupported)
      else
        let missing =
          expected
          |> List.filter (fun key -> not (List.mem_assoc key fields))
        in
        if missing <> [] then Error (Missing_fields missing) else Ok fields
  | _ -> Error Object_required
;;

let nonblank field = function
  | `String value when not (String.equal (String.trim value) "") -> Ok value
  | _ -> Error (Invalid_field field)
;;

let schema expected fields =
  match List.assoc "schema" fields with
  | `String observed when String.equal observed expected -> Ok ()
  | `String observed -> Error (Unsupported_schema observed)
  | _ -> Error (Invalid_field "schema")
;;

let parse_decision = function
  | `String "acknowledge_and_requeue" -> Ok Acknowledge_and_requeue
  | `String value -> Error (Unsupported_decision value)
  | _ -> Error (Invalid_field "decision")
;;

let request_of_fields fields =
  let* candidate_id = nonblank "candidate_id" (List.assoc "candidate_id" fields) in
  let* expected_quarantine_id =
    nonblank
      "expected_quarantine_id"
      (List.assoc "expected_quarantine_id" fields)
  in
  let* decision = parse_decision (List.assoc "decision" fields) in
  Ok { candidate_id; expected_quarantine_id; decision }
;;

let parse_request json =
  let* fields =
    validate_exact_object
      ~expected:
        [ "schema"
        ; "candidate_id"
        ; "expected_quarantine_id"
        ; "decision"
        ]
      json
  in
  let* () = schema request_schema fields in
  request_of_fields fields
;;

let make ~keeper_name ~raw_partition_id request =
  if not (Keeper_config.validate_name keeper_name)
  then Error (Invalid_keeper_name keeper_name)
  else if String.equal (String.trim raw_partition_id) ""
  then Error (Invalid_field "partition_id")
  else Ok { keeper_name; partition_id = raw_partition_id; request }
;;

let parse_tool_command json =
  let* fields =
    validate_exact_object
      ~expected:
        [ "schema"
        ; "keeper_name"
        ; "partition_id"
        ; "candidate_id"
        ; "expected_quarantine_id"
        ; "decision"
        ]
      json
  in
  let* () = schema tool_command_schema fields in
  let* keeper_name = nonblank "keeper_name" (List.assoc "keeper_name" fields) in
  let* partition_id = nonblank "partition_id" (List.assoc "partition_id" fields) in
  let* request = request_of_fields fields in
  make ~keeper_name ~raw_partition_id:partition_id request
;;

let input_error_to_string = function
  | Object_required -> "request must be an object"
  | Duplicate_fields fields ->
    "duplicate fields: " ^ String.concat ", " fields
  | Unsupported_fields fields ->
    "unsupported fields: " ^ String.concat ", " fields
  | Missing_fields fields ->
    "missing fields: " ^ String.concat ", " fields
  | Invalid_field field -> "invalid field: " ^ field
  | Unsupported_schema schema -> "unsupported schema: " ^ schema
  | Unsupported_decision decision -> "unsupported decision: " ^ decision
  | Invalid_keeper_name name -> "invalid keeper name: " ^ name
;;

let input_error_to_json error =
  `Assoc
    [ "kind", `String "invalid_input"
    ; ( "detail"
      , `String
          (Observability_redact.redact_text (input_error_to_string error)) )
    ]
;;

let execution_error_label = function
  | Candidate_state_conflict _ -> "candidate_state_conflict"
  | Partition_state_conflict _ -> "partition_state_conflict"
  | Durability_unconfirmed _ -> "durability_unconfirmed"
  | Wake_request_failed _ -> "wake_request_failed"
;;

let execution_error_message = function
  | Candidate_state_conflict _ ->
    "The candidate no longer matches the observed quarantine generation."
  | Partition_state_conflict _ ->
    "The partition is not in a state allowed by this recovery generation."
  | Durability_unconfirmed _ ->
    "The exact partition transition could not be fsync-confirmed."
  | Wake_request_failed _ ->
    "The durable recovery committed, but its process-local wake could not be requested."
;;

let execution_error_to_json error =
  `Assoc
    [ "kind", `String (execution_error_label error)
    ; "message", `String (execution_error_message error)
    ]
;;

let find_candidate ~base_path command =
  match
    Candidate.load_candidates
      ~base_path
      ~keeper_name:command.keeper_name
  with
  | Error detail -> Error (Candidate_state_conflict detail)
  | Ok candidates ->
    (match
       List.find_opt
         (fun candidate ->
            String.equal
              candidate.Candidate.candidate_id
              command.request.candidate_id)
         candidates
     with
     | Some candidate -> Ok candidate
     | None ->
       Error
         (Candidate_state_conflict
            ("candidate not found: " ^ command.request.candidate_id)))
;;

let find_partition ~base_path command =
  match Partition.load ~base_path ~keeper_name:command.keeper_name with
  | Error detail -> Error (Partition_state_conflict detail)
  | Ok partitions ->
    (match
       List.find_opt
         (fun partition ->
            String.equal partition.Partition.partition_id command.partition_id)
         partitions
     with
     | Some partition
       when String.equal
              partition.candidate_id
              command.request.candidate_id ->
       Ok partition
     | Some _ ->
       Error
         (Partition_state_conflict
            "partition candidate identity differs from the command")
     | None ->
       Error
         (Partition_state_conflict
            ("partition not found: " ^ command.partition_id)))
;;

let matching_quarantine command candidate =
  match Candidate.quarantine_state candidate.Candidate.status with
  | Some state
    when String.equal state.quarantine.partition_id command.partition_id
         && String.equal
              state.quarantine.quarantine_id
              command.request.expected_quarantine_id ->
    Ok state
  | Some _ | None ->
    Error
      (Candidate_state_conflict
         "candidate quarantine generation differs from the command")
;;

let confirm_requeue ~base_path transition =
  match transition.Partition.write_outcome with
  | Partition.Fsync_completed -> Ok transition.partition
  | Partition.Visible_sync_unconfirmed _ ->
    (match
       Partition.requeue_blocked
         ~base_path
         ~partition:transition.partition
     with
     | Error detail -> Error (Durability_unconfirmed detail)
     | Ok confirmed ->
       (match confirmed.write_outcome with
        | Partition.Fsync_completed -> Ok confirmed.partition
        | Partition.Visible_sync_unconfirmed detail ->
          Error (Durability_unconfirmed detail)))
;;

let request_wake ~base_path command candidate partition =
  match Wake.request ~base_path ~keeper_name:command.keeper_name with
  | Ok wake -> Ok { candidate; partition; wake }
  | Error detail -> Error (Wake_request_failed detail)
;;

let commit_partition_ready ~base_path partition =
  match partition.Partition.state with
  | Partition.Blocked _ ->
    (match Partition.requeue_blocked ~base_path ~partition with
     | Error detail -> Error (Partition_state_conflict detail)
     | Ok transition -> confirm_requeue ~base_path transition)
  | Partition.Ready -> Ok partition
  | Partition.Running _ | Partition.Completed _ | Partition.Settled _ ->
    Error
      (Partition_state_conflict
         "partition advanced before candidate requeue authorization")
;;

let execute ~now ~base_path command =
  let* candidate = find_candidate ~base_path command in
  let* observed = matching_quarantine command candidate in
  let* partition = find_partition ~base_path command in
  match observed.phase, partition.state with
  | Candidate.Requeued _, Partition.Blocked { blocked_at; _ }
    when Float.equal blocked_at observed.quarantine.quarantined_at ->
    let* ready = commit_partition_ready ~base_path partition in
    request_wake ~base_path command candidate ready
  | Candidate.Requeued _, Partition.Blocked _ ->
    Error
      (Partition_state_conflict
         "a newer Blocked generation is awaiting candidate projection")
  | Candidate.Requeued _, Partition.Ready ->
    request_wake ~base_path command candidate partition
  | Candidate.Requeued _,
    (Partition.Running _ | Partition.Completed _ | Partition.Settled _) ->
    Error
      (Partition_state_conflict
         "partition advanced beyond the authorized Ready boundary")
  | (Candidate.Quarantined | Candidate.Requeue_requested _),
    Partition.Blocked _ ->
    let* requested =
      match
        Candidate.request_quarantine_requeue
          ~base_path
          ~candidate
          ~partition_id:command.partition_id
          ~expected_quarantine_id:command.request.expected_quarantine_id
          ~requested_at:now
      with
      | Ok candidate -> Ok candidate
      | Error detail -> Error (Candidate_state_conflict detail)
    in
    let* authorized =
      match
        Candidate.finish_quarantine_requeue
          ~base_path
          ~candidate:requested
          ~partition_id:command.partition_id
          ~expected_quarantine_id:command.request.expected_quarantine_id
          ~requeued_at:now
      with
      | Ok candidate -> Ok candidate
      | Error detail -> Error (Candidate_state_conflict detail)
    in
    let* ready = commit_partition_ready ~base_path partition in
    request_wake ~base_path command authorized ready
  | (Candidate.Quarantined | Candidate.Requeue_requested _),
    (Partition.Ready | Partition.Running _ | Partition.Completed _
    | Partition.Settled _) ->
    Error
      (Partition_state_conflict
         "partition became claimable before candidate requeue authorization")
;;

let audit config ~actor command ~outcome =
  try
    Audit_log.log_action
      config
      ~agent_id:actor
      ~action:(Audit_log.Custom "keeper_board_attention_quarantine_requeue")
      ~details:
        (`Assoc
          [ "keeper_name", `String command.keeper_name
          ; "partition_id", `String command.partition_id
          ; "candidate_id", `String command.request.candidate_id
          ; ( "expected_quarantine_id"
            , `String command.request.expected_quarantine_id )
          ; "decision", `String "acknowledge_and_requeue"
          ])
      ~outcome
      ();
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let audit_json = function
  | Ok () -> `Assoc [ "recorded", `Bool true ]
  | Error detail ->
    `Assoc
      [ "recorded", `Bool false
      ; "error", `String (Observability_redact.redact_text detail)
      ]
;;

let wake_to_string = function
  | Wake.Signaled -> "signaled"
  | Wake.Coalesced -> "coalesced"
  | Wake.Not_registered -> "not_registered"
;;

let success_json ~audit command report =
  let failure_category =
    match Candidate.quarantine_state report.candidate.status with
    | Some state ->
      Candidate.quarantine_failure_category_to_string
        state.quarantine.failure_category
    | None -> "unknown"
  in
  `Assoc
    [ "schema", `String result_schema
    ; "ok", `Bool true
    ; "keeper_name", `String command.keeper_name
    ; "partition_id", `String report.partition.partition_id
    ; "candidate_id", `String report.candidate.candidate_id
    ; ( "quarantine_id"
      , `String command.request.expected_quarantine_id )
    ; "failure_category", `String failure_category
    ; "decision", `String "acknowledge_and_requeue"
    ; "partition_state", `String (Partition.state_to_string report.partition.state)
    ; "wake", `String (wake_to_string report.wake)
    ; "audit", audit
    ]
;;

let failure_json ~audit error =
  `Assoc
    [ "schema", `String result_schema
    ; "ok", `Bool false
    ; "error", execution_error_to_json error
    ; "audit", audit
    ]
;;


type inventory_phase =
  | Inventory_quarantined
  | Inventory_requeue_requested
  | Inventory_requeued

type inventory_item =
  { keeper_name : string
  ; partition_id : string
  ; candidate_id : string
  ; quarantine_id : string
  ; phase : inventory_phase
  ; failure_category : Candidate.quarantine_failure_category
  ; attempt_provenance : Candidate.attempt_provenance option
  ; quarantined_at : float
  ; requested_at : float option
  ; requeued_at : float option
  }

type inventory_error_kind =
  | Inventory_candidate_ledger_unavailable

type inventory_error =
  { keeper_name : string
  ; kind : inventory_error_kind
  }

type inventory =
  { items : inventory_item list
  ; errors : inventory_error list
  }

let inventory_phase_projection = function
  | Candidate.Quarantined -> Inventory_quarantined, None, None
  | Candidate.Requeue_requested { requested_at } ->
    Inventory_requeue_requested, Some requested_at, None
  | Candidate.Requeued { requeued_at } ->
    Inventory_requeued, None, Some requeued_at
;;

let inventory_item_of_candidate ~keeper_name (candidate : Candidate.candidate) =
  match candidate.status with
  | Candidate.Pending _ | Candidate.Judged _ | Candidate.Consumed _ -> None
  | Candidate.Quarantine { quarantine; phase } ->
    let phase, requested_at, requeued_at = inventory_phase_projection phase in
    Some
      { keeper_name
      ; partition_id = quarantine.partition_id
      ; candidate_id = candidate.candidate_id
      ; quarantine_id = quarantine.quarantine_id
      ; phase
      ; failure_category = quarantine.failure_category
      ; attempt_provenance = quarantine.attempt_provenance
      ; quarantined_at = quarantine.quarantined_at
      ; requested_at
      ; requeued_at
      }
;;

let compare_inventory_item (left : inventory_item) (right : inventory_item) =
  Stdlib.compare
    (left.keeper_name, left.partition_id, left.candidate_id, left.quarantine_id)
    (right.keeper_name, right.partition_id, right.candidate_id, right.quarantine_id)
;;

let inventory ~base_path ~keeper_names =
  let items, errors =
    keeper_names
    |> List.sort_uniq String.compare
    |> List.fold_left
         (fun (items, errors) keeper_name ->
           match Candidate.load_candidates ~base_path ~keeper_name with
           | Error _ ->
             ( items
             , ({ keeper_name; kind = Inventory_candidate_ledger_unavailable }
                : inventory_error)
               :: errors )
           | Ok candidates ->
             let keeper_items =
               List.filter_map (inventory_item_of_candidate ~keeper_name) candidates
             in
             List.rev_append keeper_items items, errors)
         ([], [])
  in
  { items = List.sort compare_inventory_item items
  ; errors = List.rev errors
  }
;;

let inventory_phase_to_string = function
  | Inventory_quarantined -> "quarantined"
  | Inventory_requeue_requested -> "requeue_requested"
  | Inventory_requeued -> "requeued"
;;

let inventory_error_kind_to_string = function
  | Inventory_candidate_ledger_unavailable -> "candidate_ledger_unavailable"
;;

let option_float_to_json = function
  | None -> `Null
  | Some value -> `Float value
;;

let attempt_provenance_to_json = function
  | None -> `Null
  | Some (attempt : Candidate.attempt_provenance) ->
    `Assoc
      [ "slot_id", `String attempt.slot_id
      ; "call_id", `String attempt.call_id
      ; "plan_fingerprint", `String attempt.plan_fingerprint
      ; "request_body_sha256", `String attempt.request_body_sha256
      ]
;;

let inventory_item_to_json (item : inventory_item) =
  `Assoc
    [ "keeper_name", `String item.keeper_name
    ; "partition_id", `String item.partition_id
    ; "candidate_id", `String item.candidate_id
    ; "quarantine_id", `String item.quarantine_id
    ; "phase", `String (inventory_phase_to_string item.phase)
    ; ( "failure_category"
      , `String
          (Candidate.quarantine_failure_category_to_string item.failure_category) )
    ; "attempt_provenance", attempt_provenance_to_json item.attempt_provenance
    ; "quarantined_at", `Float item.quarantined_at
    ; "requested_at", option_float_to_json item.requested_at
    ; "requeued_at", option_float_to_json item.requeued_at
    ]
;;

let inventory_to_json inventory =
  `Assoc
    [ "count", `Int (List.length inventory.items)
    ; "items", `List (List.map inventory_item_to_json inventory.items)
    ; ( "errors"
      , `List
          (List.map
             (fun (error : inventory_error) ->
               `Assoc
                 [ "keeper_name", `String error.keeper_name
                 ; "kind", `String (inventory_error_kind_to_string error.kind)
                 ])
             inventory.errors) )
    ]
;;

let inventory_json ~base_path ~keeper_names =
  inventory ~base_path ~keeper_names |> inventory_to_json
;;
