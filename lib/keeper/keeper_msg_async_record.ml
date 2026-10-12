open Keeper_msg_async_types

let ( let* ) = Result.bind
let record_schema_version = 4

let status_to_string = function
  | Queued -> "queued"
  | Running -> "running"
  | Cancelling _ -> "cancelling"
  | Lost _ -> "lost"
  | Cancelled _ -> "cancelled"
  | Persistence_failed _ -> "persistence_failed"
  | Done { ok = true; _ } -> "done"
  | Done { ok = false; _ } -> "error"
;;

let is_terminal_status = function
  | Done _ | Lost _ | Cancelled _ | Persistence_failed _ -> true
  | Queued | Running | Cancelling _ -> false
;;

let access_rejection_to_json = function
  | Invalid_base_path { reason } ->
    `Assoc
      [ "error", `String "invalid_base_path"
      ; "message", `String reason
      ]
  | Invalid_caller ->
    `Assoc
      [ "error", `String "invalid_caller"
      ; ( "message"
        , `String "caller identity must be non-empty and free of surrounding whitespace" )
      ]
  | Invalid_request_id ->
    `Assoc
      [ "error", `String "invalid_request_id"
      ; "message", `String "request_id contains invalid characters or length"
      ]
  | Caller_mismatch ->
    `Assoc
      [ "error", `String "request_caller_mismatch"
      ; "message", `String "request does not belong to the authenticated caller"
      ]
;;

let canonical_terminal_error_to_string = function
  | Canonical_terminal_absent -> "canonical terminal request record is absent"
  | Canonical_terminal_unreadable reason ->
    "canonical terminal request record is unreadable: " ^ reason
  | Canonical_terminal_access_rejected rejection ->
    "canonical terminal request access rejected: "
    ^ Yojson.Safe.to_string (access_rejection_to_json rejection)
  | Canonical_terminal_runtime_active status ->
    Printf.sprintf
      "canonical terminal proof rejected process-local status=%s"
      (status_to_string status)
  | Canonical_terminal_publication_ambiguous status ->
    Printf.sprintf
      "canonical terminal publication is visible but durability is ambiguous status=%s"
      (status_to_string status)
  | Canonical_terminal_nonterminal status ->
    Printf.sprintf
      "canonical request record is nonterminal status=%s"
      (status_to_string status)
  | Canonical_terminal_noncanonical_location status ->
    Printf.sprintf
      "terminal request record is outside the canonical terminal partition status=%s"
      (status_to_string status)
;;

let durable_terminal_entry proof = proof.terminal_entry

let submit_error_to_json = function
  | Submit_lane_unavailable { lane; wait_budget_sec } ->
    `Assoc
      [ "error", `String "lane_unavailable"
      ; "lane", `String lane
      ; "wait_budget_sec", `Float wait_budget_sec
      ; ( "message"
        , `String
            (Printf.sprintf
               "keeper_msg %s lane admission exceeded the %.3fs budget; a prior durable write is still in progress or hung"
               lane
               wait_budget_sec) )
      ]
  | Submit_rejected rejection -> access_rejection_to_json rejection
  | Submit_invalid_keeper_name { reason } ->
    `Assoc
      [ "error", `String "invalid_keeper_name"
      ; "message", `String reason
      ]
  | Submit_invalid_request_context { reason } ->
    `Assoc
      [ "error", `String "invalid_request_context"
      ; "message", `String reason
      ]
  | Initial_persistence_failed { reason } ->
    `Assoc
      [ "error", `String "request_persistence_failed"
      ; "message", `String reason
      ]
  | Acceptance_persistence_failed { request_id; reason } ->
    `Assoc
      [ "error", `String "acceptance_persistence_failed"
      ; "request_id", `String request_id
      ; "message", `String reason
      ]
  | Background_switch_unavailable { reason } ->
    `Assoc
      [ "error", `String "background_switch_unavailable"
      ; "message", `String reason
      ]
  | Background_fork_failed { request_id; reason } ->
    `Assoc
      [ "error", `String "request_background_start_failed"
      ; "request_id", `String request_id
      ; "status", `String "lost"
      ; "message", `String reason
      ]
;;

let submit_outcome_to_json outcome =
  match outcome.acceptance with
  | Durably_accepted ->
    `Assoc
      [ "request_id", `String outcome.request_id
      ; "status", `String "queued"
      ; "durability", `String "durable"
      ]
  | Reconciliation_required { reason } ->
    `Assoc
      [ "error", `String "request_acceptance_uncertain"
      ; "request_id", `String outcome.request_id
      ; "status", `String "acceptance_uncertain"
      ; "reconciliation_required", `Bool true
      ; "reason", `String reason
      ]
;;

let durability_json_fields = function
  | Durably_committed -> [ "durability", `String "durable" ]
  | Published_unconfirmed { reason } ->
    [ "durability", `String "volatile"; "warning", `String reason ]
;;

let cancel_result_to_json ~request_id = function
  | Cancellation_requested durability ->
    `Assoc
      ([ "request_id", `String request_id
       ; "status", `String "cancelling"
       ; ( "message"
         , `String
             "Keeper cancellation was accepted; poll the request for its actual terminal result."
         )
       ]
       @ durability_json_fields durability)
  | Cancel_not_found ->
    `Assoc
      [ "error", `String "request_id_not_found"
      ; "request_id", `String request_id
      ]
  | Cancel_unreadable reason ->
    `Assoc
      [ "error", `String "request_record_unreadable"
      ; "request_id", `String request_id
      ; "message", `String reason
      ]
  | Cancel_rejected rejection ->
    `Assoc
      [ "error", `String "request_access_rejected"
      ; "request_id", `String request_id
      ; "reason", access_rejection_to_json rejection
      ]
  | Cancel_worker_ownership_unknown status ->
    `Assoc
      [ "error", `String "request_worker_ownership_unknown"
      ; "request_id", `String request_id
      ; "status", `String (status_to_string status)
      ; ( "message"
        , `String
            "The request is non-terminal on disk but has no worker in this process; cancellation is refused because another runtime may own it."
        )
      ]
  | Cancel_already_terminal status ->
    `Assoc
      [ "error", `String "request_already_terminal"
      ; "request_id", `String request_id
      ; "status", `String (status_to_string status)
      ]
  | Cancel_persistence_failed { reason } ->
    `Assoc
      [ "error", `String "cancellation_persistence_failed"
      ; "request_id", `String request_id
      ; "message", `String reason
      ]
  | Cancel_worker_signal_failed { durability; reason } ->
    `Assoc
      ([ "error", `String "cancellation_worker_signal_failed"
       ; "request_id", `String request_id
       ; "status", `String "cancelling"
       ; "message", `String reason
       ]
       @ durability_json_fields durability)
  | Cancel_state_invariant_failed { reason } ->
    `Assoc
      [ "error", `String "cancellation_state_invariant_failed"
      ; "request_id", `String request_id
      ; "message", `String reason
      ]
;;

let entry_record_to_json (e : entry) : Yojson.Safe.t =
  let fields =
    [ "schema_version", `Int record_schema_version
    ; "request_id", `String e.request_id
    ; "keeper_name", `String e.keeper_name
    ; "base_path", `String e.base_path
    ; "submitted_by", `String e.submitted_by
    ; ( "request_context"
      , Option.fold ~none:`Null ~some:(fun fields -> `Assoc fields)
          e.request_context )
    ; "status", `String (status_to_string e.status)
    ; "submitted_at", `Float e.submitted_at
    ]
  in
  let fields =
    match e.completed_at with
    | Some t -> fields @ [ "completed_at", `Float t ]
    | None -> fields
  in
  let fields =
    match e.status with
    | Done { ok; body; data } ->
      fields
      @ [ "ok", `Bool ok; "body", `String body ]
      @ (match data with Some value -> [ "data", value ] | None -> [])
    | Lost { reason } -> fields @ [ "reason", `String reason ]
    | Cancelled { reason; cancelled_by } ->
      fields @ [ "reason", `String reason; "cancelled_by", `String cancelled_by ]
    | Cancelling { reason; cancelled_by } ->
      fields @ [ "reason", `String reason; "cancelled_by", `String cancelled_by ]
    | Persistence_failed { attempted_status; reason } ->
      fields
      @ [ "attempted_status", `String attempted_status; "reason", `String reason ]
    | Queued | Running -> fields
  in
  `Assoc fields
;;

(* Whole-record equality, next to [same_request_identity]'s immutable identity
   fields. The terminal-conflict check used to ask this by serializing both
   entries and comparing the JSON. That agreed with the record only because
   [entry_record_to_json] happens to emit every field, in a fixed order, on a
   single code path — so adding a field to the wire, making one conditional,
   or reordering the assoc would have quietly changed what counts as an
   integrity conflict on a durable store. The predicate belongs to the record,
   not to its rendering. *)
let same_entry_record (left : entry) (right : entry) = left = right

let normalize_request_context request_context =
  let rec normalize_json path = function
    | `Assoc fields ->
      let rec normalize_fields seen normalized = function
        | [] ->
          Ok
            (`Assoc
               (List.sort
                  (fun (left, _) (right, _) -> String.compare left right)
                  normalized))
        | (name, value) :: rest ->
          if List.mem name seen
          then
            Error
              (Printf.sprintf
                 "request_context contains duplicate field %S at %s"
                 name
                 (String.concat "." (List.rev path)))
          else
            let* value = normalize_json (name :: path) value in
            normalize_fields (name :: seen) ((name, value) :: normalized) rest
      in
      normalize_fields [] [] fields
    | `List values ->
      let rec normalize_values index normalized = function
        | [] -> Ok (`List (List.rev normalized))
        | value :: rest ->
          let* value = normalize_json (string_of_int index :: path) value in
          normalize_values (index + 1) (value :: normalized) rest
      in
      normalize_values 0 [] values
    | `Intlit literal ->
      (match Yojson.Safe.from_string literal with
       | (`Int _ | `Intlit _) as value -> Ok value
       | _ -> Error "request_context Intlit must contain a JSON integer"
       | exception Yojson.Json_error _ ->
         Error "request_context Intlit must contain a JSON integer")
    | `Float value when Float.is_finite value -> Ok (`Float value)
    | `Float _ -> Error "request_context float must be finite"
    | (`Null | `Bool _ | `Int _ | `String _) as value ->
      Ok value
    | `Tuple _ | `Variant _ ->
      Error "request_context must contain JSON-compatible values"
  in
  match request_context with
  | None -> Ok None
  | Some fields ->
    let* normalized = normalize_json [ "request_context" ] (`Assoc fields) in
    (match normalized with
     | `Assoc fields -> Ok (Some fields)
     | _ -> assert false)
;;

let same_request_identity (left : entry) (right : entry) =
  String.equal left.request_id right.request_id
  && String.equal left.keeper_name right.keeper_name
  && String.equal left.base_path right.base_path
  && String.equal left.submitted_by right.submitted_by
  && left.request_context = right.request_context
  && Float.equal left.submitted_at right.submitted_at
;;

let string_member name json =
  match Json_util.assoc_member_opt name json with
  | Some (`String value) -> Some value
  | _ -> None
;;

let float_member name json =
  match Json_util.assoc_member_opt name json with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | _ -> None
;;

let bool_member name json =
  match Json_util.assoc_member_opt name json with
  | Some (`Bool value) -> Some value
  | _ -> None
;;

let int_member name json =
  match Json_util.assoc_member_opt name json with
  | Some (`Int value) -> Some value
  | _ -> None
;;

let required_string name json =
  match string_member name json with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "record is missing required string field %S" name)
;;

let required_float name json =
  match float_member name json with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "record is missing required numeric field %S" name)
;;

let required_bool name json =
  match bool_member name json with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "record is missing required boolean field %S" name)
;;

let required_completed_at json =
  match float_member "completed_at" json with
  | Some value -> Ok (Some value)
  | None -> Error "terminal record is missing required numeric field \"completed_at\""
;;

let validate_record_fields ~status_fields json =
  let common_fields =
    [ "schema_version"
    ; "request_id"
    ; "keeper_name"
    ; "base_path"
    ; "submitted_by"
    ; "request_context"
    ; "status"
    ; "submitted_at"
    ]
  in
  let allowed = common_fields @ status_fields in
  match json with
  | `Assoc fields ->
    let rec loop seen = function
      | [] -> Ok ()
      | (name, _) :: rest ->
        if List.mem name seen
        then Error (Printf.sprintf "record contains duplicate field %S" name)
        else if not (List.mem name allowed)
        then Error (Printf.sprintf "record contains unsupported field %S" name)
        else loop (name :: seen) rest
    in
    loop [] fields
  | _ -> Error "record must be a JSON object"
;;

let decode_status ~tag json =
  match tag with
  | "queued" -> Ok (Queued, None)
  | "running" -> Ok (Running, None)
  | "cancelling" ->
    let* reason = required_string "reason" json in
    let* cancelled_by = required_string "cancelled_by" json in
    Ok (Cancelling { reason; cancelled_by }, None)
  | "lost" ->
    let* reason = required_string "reason" json in
    let* completed_at = required_completed_at json in
    Ok (Lost { reason }, completed_at)
  | "cancelled" ->
    let* reason = required_string "reason" json in
    let* cancelled_by = required_string "cancelled_by" json in
    let* completed_at = required_completed_at json in
    Ok (Cancelled { reason; cancelled_by }, completed_at)
  | "persistence_failed" ->
    let* attempted_status = required_string "attempted_status" json in
    let* reason = required_string "reason" json in
    let* completed_at = required_completed_at json in
    Ok (Persistence_failed { attempted_status; reason }, completed_at)
  | ("done" | "error") as terminal_tag ->
    let* ok = required_bool "ok" json in
    let* body = required_string "body" json in
    let data = Json_util.assoc_member_opt "data" json in
    let* completed_at = required_completed_at json in
    if Bool.equal ok (String.equal terminal_tag "done")
    then Ok (Done { ok; body; data }, completed_at)
    else
      Error
        (Printf.sprintf
           "record status %S disagrees with required ok=%b"
           terminal_tag
           ok)
  | other -> Error (Printf.sprintf "unknown status %S in record" other)
;;

let entry_of_record_json ~base_path ~request_id:expected_request_id json :
    (entry, string) result =
  let* schema_version =
    match int_member "schema_version" json with
    | Some version -> Ok version
    | None -> Error "record is missing required integer field \"schema_version\""
  in
  let* () =
    if Int.equal schema_version record_schema_version
    then Ok ()
    else
      Error
        (Printf.sprintf
           "unsupported keeper_msg request schema_version=%d (expected: %d)"
           schema_version
           record_schema_version)
  in
  let* request_id = required_string "request_id" json in
  let* () =
    if String.equal request_id expected_request_id
    then Ok ()
    else
      Error
        (Printf.sprintf
           "record request_id %S does not match filename request_id %S"
           request_id
           expected_request_id)
  in
  let* keeper_name = required_string "keeper_name" json in
  let* keeper_name =
    Keeper_id.Keeper_name.of_string keeper_name
    |> Result.map Keeper_id.Keeper_name.to_string
  in
  let* persisted_base_path = required_string "base_path" json in
  let* submitted_by = required_string "submitted_by" json in
  let* request_context =
    match Json_util.assoc_member_opt "request_context" json with
    | Some `Null -> Ok None
    | Some (`Assoc fields) -> normalize_request_context (Some fields)
    | Some _ -> Error "record request_context must be an object or null"
    | None -> Error "record is missing required field \"request_context\""
  in
  let* () =
    let trimmed = String.trim submitted_by in
    if String.equal trimmed "" || not (String.equal submitted_by trimmed)
    then Error "record submitted_by is not a canonical caller identity"
    else Ok ()
  in
  let* () =
    if String.equal persisted_base_path base_path
    then Ok ()
    else
      Error "record base_path identity does not match request store root"
  in
  let* status_tag = required_string "status" json in
  let* submitted_at = required_float "submitted_at" json in
  let* status, completed_at = decode_status ~tag:status_tag json in
  let status_fields =
    match status with
    | Queued | Running -> []
    | Cancelling _ -> [ "reason"; "cancelled_by" ]
    | Lost _ -> [ "completed_at"; "reason" ]
    | Cancelled _ -> [ "completed_at"; "reason"; "cancelled_by" ]
    | Persistence_failed _ -> [ "completed_at"; "attempted_status"; "reason" ]
    | Done _ -> [ "completed_at"; "ok"; "body"; "data" ]
  in
  let* () = validate_record_fields ~status_fields json in
  Ok
    { request_id
    ; keeper_name
    ; base_path = persisted_base_path
    ; submitted_by
    ; request_context
    ; status
    ; submitted_at
    ; completed_at
    }
;;

let entry_to_json ~now (e : entry) : Yojson.Safe.t =
  let fields =
    [ "request_id", `String e.request_id
    ; "keeper_name", `String e.keeper_name
    ; "submitted_by", `String e.submitted_by
    ; ( "request_context"
      , Option.fold ~none:`Null ~some:(fun fields -> `Assoc fields)
          e.request_context )
    ; "status", `String (status_to_string e.status)
    ; "submitted_at", `Float e.submitted_at
    ]
  in
  let fields =
    match e.completed_at with
    | Some t -> fields @ [ "completed_at", `Float t ]
    | None ->
      let elapsed = now -. e.submitted_at in
      fields @ [ "elapsed_sec", `Float elapsed ]
  in
  let fields =
    match e.status with
    | Done { ok; body; data } ->
      fields
      @ [ "ok", `Bool ok
        ; ( "result"
          , Option.value ~default:(`String body) data )
        ]
    | Lost { reason } ->
      fields
      @ [ "ok", `Bool false
        ; "result", `Assoc [ "error", `String "request_lost"; "reason", `String reason ]
        ]
    | Cancelled { reason; cancelled_by } ->
      fields
      @ [ "ok", `Bool false
        ; ( "result"
          , `Assoc
              [ "cancelled", `Bool true
              ; "reason", `String reason
              ; "cancelled_by", `String cancelled_by
              ] )
        ]
    | Cancelling { reason; cancelled_by } ->
      fields
      @ [ "ok", `Bool false
        ; ( "result"
          , `Assoc
              [ "cancellation_requested", `Bool true
              ; "reason", `String reason
              ; "cancelled_by", `String cancelled_by
              ] )
        ]
    | Persistence_failed { attempted_status; reason } ->
      fields
      @ [ "ok", `Bool false
        ; ( "result"
          , `Assoc
              [ "error", `String "request_persistence_failed"
              ; "attempted_status", `String attempted_status
              ; "reason", `String reason
              ] )
        ]
    | _ -> fields
  in
  `Assoc fields
;;
