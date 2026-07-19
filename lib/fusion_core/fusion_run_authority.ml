type identity =
  { keeper : string
  ; run_id : string
  }
[@@deriving yojson, show, eq]
type replay =
  { topology : Fusion_types.fusion_topology
  ; request : Fusion_types.fusion_request
  }
[@@deriving yojson, show, eq]
type registration =
  { replay : replay
  ; started_at : float
  }
[@@deriving yojson, show, eq]
type uncommitted_stop =
  | Denied of Fusion_types.deny_reason
  | Cancelled of string
  | Aborted of string
  | Interrupted_without_computation_restart
[@@deriving yojson, show, eq]
type phase =
  | Computation_committed of Fusion_types.deliberation_evidence
  | Stopped_without_computation of uncommitted_stop
[@@deriving yojson, show, eq]
type state_kind = Empty_state | Registered_state | Phase_committed_state [@@deriving show]
type event_kind = Registration_event | Computation_event | Uncommitted_stop_event [@@deriving show]
type error =
  | Empty_keeper
  | Empty_run_id
  | Invalid_started_at of float
  | Empty_abort_detail
  | Empty_cancellation_detail
  | Partial_tail
  | Unsupported_schema_version of { line : int; found : int }
  | Invalid_record of
      { line : int
      ; detail : string
      }
  | Empty_authority_record
  | Evidence_question_mismatch of { expected : string; found : string }
  | Invalid_transition of
      { event_index : int
      ; state : state_kind
      ; event : event_kind
      }
  | Identity_mismatch of identity
  | Registration_conflict of registration
  | Durable_append_failed of Fs_compat.durable_append_error

let error_to_string = function
  | Empty_keeper -> "keeper identity is empty"
  | Empty_run_id -> "run identity is empty"
  | Invalid_started_at value -> Printf.sprintf "started_at is not finite: %g" value
  | Empty_abort_detail -> "abort detail is empty"
  | Empty_cancellation_detail -> "cancellation detail is empty"
  | Partial_tail -> "authority journal has a partial tail"
  | Unsupported_schema_version { line; found } ->
    Printf.sprintf "authority journal line %d has unsupported schema version %d" line found
  | Invalid_record { line; detail } ->
    Printf.sprintf "authority journal line %d is invalid: %s" line detail
  | Empty_authority_record -> "authority journal is empty"
  | Evidence_question_mismatch { expected; found } ->
    Printf.sprintf "authority evidence question mismatch: expected=%S found=%S" expected found
  | Invalid_transition { event_index; state; event } ->
    Printf.sprintf "authority event %d cannot apply %s to %s"
      event_index (show_event_kind event) (show_state_kind state)
  | Identity_mismatch identity ->
    Printf.sprintf "authority identity mismatch: %s" (show_identity identity)
  | Registration_conflict registration ->
    Printf.sprintf "authority registration conflict: %s" (show_registration registration)
  | Durable_append_failed error -> Fs_compat.durable_append_error_to_string error
;;

type register_outcome =
  | Registered
  | Already_registered of recovered_run
and recovered_run =
  | Registered_run of registration
  | Computation_committed_run of registration * Fusion_types.deliberation_evidence
  | Stopped_without_computation_run of registration * uncommitted_stop
type claim_outcome = First_committed | Already_same | Conflict of phase
type scan_entry_error =
  | Invalid_entry_name of string
  | Entry_disappeared
  | Entry_read_failed of Fs_compat.owned_regular_file_read_error
  | Entry_record_failed of error
type scan_entry =
  { entry_name : string
  ; outcome : (recovered_run, scan_entry_error) result
  }
type scan_outcome =
  | Store_missing
  | Store_scanned of scan_entry list
type directory_io_failure =
  | Directory_unix_error of
      { error : Unix.error
      ; function_name : string
      ; argument : string
      }
  | Directory_sys_error of string
type scan_error =
  | Directory_boundary_rejected of Fs_compat.owned_directory_chain_rejection
  | Directory_inspection_failed of directory_io_failure
  | Directory_inventory_failed of directory_io_failure
  | Directory_identity_changed
type phase_record =
  { identity : identity
  ; phase : phase
  }
[@@deriving yojson]
type persisted_event =
  | Run_registered of registration
  | Phase_committed of phase_record
[@@deriving yojson]
type persisted_record =
  { schema_version : int
  ; event : persisted_event
  }
[@@deriving yojson]
type persisted_state =
  | Empty
  | Registered_state_value of registration
  | Phase_committed_state_value of registration * phase
type t = { root : string }
let create ~directory = { root = directory }
let identity_key identity =
  Printf.sprintf
    "%d:%s%d:%s"
    (String.length identity.keeper)
    identity.keeper
    (String.length identity.run_id)
    identity.run_id
;;
let run_file t ~keeper ~run_id =
  let identity = { keeper; run_id } in
  let digest = Digestif.SHA256.(digest_string (identity_key identity) |> to_hex) in
  Filename.concat t.root (digest ^ ".jsonl")
;;
let validate_identity = function
  | { keeper = ""; _ } -> Error Empty_keeper
  | { run_id = ""; _ } -> Error Empty_run_id
  | _ -> Ok ()
;;
let validate_registration (registration : registration) =
  let request = registration.replay.request in
  match validate_identity { keeper = request.keeper; run_id = request.run_id } with
  | Error _ as error -> error
  | Ok () ->
    if Float.is_finite registration.started_at
    then Ok ()
    else Error (Invalid_started_at registration.started_at)
;;
let validate_stop = function
  | Cancelled "" -> Error Empty_cancellation_detail
  | Aborted "" -> Error Empty_abort_detail
  | Cancelled _ | Aborted _ -> Ok ()
  | Denied _ | Interrupted_without_computation_restart -> Ok ()
;;
let identity_of_registration registration =
  let request = registration.replay.request in
  { keeper = request.keeper; run_id = request.run_id }
;;
let validate_phase registration = function
  | Computation_committed evidence ->
    let expected = registration.replay.request.prompt in
    if String.equal expected evidence.Fusion_types.question
    then Ok ()
    else Error (Evidence_question_mismatch { expected; found = evidence.question })
  | Stopped_without_computation stop -> validate_stop stop
;;
let schema_version = 3
let event_line event =
  Yojson.Safe.to_string (persisted_record_to_yojson { schema_version; event }) ^ "\n"
;;
let parse_events content =
  if String.equal content ""
  then Ok []
  else if not (Char.equal content.[String.length content - 1] '\n')
  then Error Partial_tail
  else
    let body = String.sub content 0 (String.length content - 1) in
    let lines = String.split_on_char '\n' body in
    let rec parse line_number acc = function
      | [] -> Ok (List.rev acc)
      | line :: rest ->
        let parsed =
          try
            let record_result =
              Yojson.Safe.from_string line
              |> persisted_record_of_yojson
              |> Result.map_error (fun detail ->
                Invalid_record { line = line_number; detail })
            in
            Result.bind record_result (fun record ->
              if Int.equal record.schema_version schema_version
              then Ok record.event
              else
                Error
                  (Unsupported_schema_version
                     { line = line_number; found = record.schema_version }))
          with
          | Yojson.Json_error detail -> Error (Invalid_record { line = line_number; detail })
        in
        Result.bind parsed (fun event -> parse (line_number + 1) (event :: acc) rest)
    in
    parse 1 [] lines
;;
let check_identity expected actual =
  if equal_identity expected actual then Ok () else Error (Identity_mismatch actual)
;;
let event_kind = function
  | Run_registered _ -> Registration_event
  | Phase_committed { phase = Computation_committed _; _ } -> Computation_event
  | Phase_committed { phase = Stopped_without_computation _; _ } ->
    Uncommitted_stop_event
;;
let state_kind = function
  | Empty -> Empty_state
  | Registered_state_value _ -> Registered_state
  | Phase_committed_state_value _ -> Phase_committed_state
;;
let identity_of_event = function
  | Run_registered registration -> identity_of_registration registration
  | Phase_committed record -> record.identity
;;
let apply_event expected event_index state event =
  let ( let* ) = Result.bind in
  let* () = check_identity expected (identity_of_event event) in
  match state, event with
  | Empty, Run_registered registration ->
    let* () = validate_registration registration in
    Ok (Registered_state_value registration)
  | Registered_state_value registration, Phase_committed record ->
    let* () = validate_phase registration record.phase in
    Ok (Phase_committed_state_value (registration, record.phase))
  | _ ->
    Error
      (Invalid_transition
         { event_index; state = state_kind state; event = event_kind event })
;;
let state_of_events expected events =
  let rec loop index state = function
    | [] -> Ok state
    | event :: rest ->
      Result.bind (apply_event expected index state event) (fun state ->
        loop (index + 1) state rest)
  in
  loop 1 Empty events
;;
let state_of_content expected content =
  Result.bind (parse_events content) (state_of_events expected)
;;

let recovered_run_of_content content =
  let ( let* ) = Result.bind in
  let* events = parse_events content in
  match events with
  | [] -> Error Empty_authority_record
  | first :: _ ->
    let identity = identity_of_event first in
    let* state = state_of_events identity events in
    (match state with
     | Empty -> Error Empty_authority_record
     | Registered_state_value registration -> Ok (identity, Registered_run registration)
     | Phase_committed_state_value (registration, Computation_committed evidence) ->
       Ok (identity, Computation_committed_run (registration, evidence))
     | Phase_committed_state_value (registration, Stopped_without_computation stop) ->
       Ok (identity, Stopped_without_computation_run (registration, stop)))
;;

let directory_io_failure_of_unix error function_name argument =
  Directory_unix_error { error; function_name; argument }
;;

let inspect_directory t =
  try
    match Fs_compat.inspect_owned_directory_chain ~ownership_root:t.root t.root with
    | Ok observation -> Ok observation
    | Error rejection -> Error (Directory_boundary_rejected rejection)
  with
  | Unix.Unix_error (error, function_name, argument) ->
    Error
      (Directory_inspection_failed
         (directory_io_failure_of_unix error function_name argument))
  | Sys_error detail ->
    Error (Directory_inspection_failed (Directory_sys_error detail))
;;

let same_directory_identity (before : Unix.stats) (after : Unix.stats) =
  before.st_dev = after.st_dev && before.st_ino = after.st_ino
;;

let scan_entry t entry_name =
  let outcome =
    if not (Fs_compat.is_capability_leaf entry_name)
    then Error (Invalid_entry_name entry_name)
    else
      let path = Filename.concat t.root entry_name in
      match Fs_compat.load_owned_regular_file ~ownership_root:t.root path with
      | Error error -> Error (Entry_read_failed error)
      | Ok None -> Error Entry_disappeared
      | Ok (Some content) ->
        (match recovered_run_of_content content with
         | Error error -> Error (Entry_record_failed error)
         | Ok (identity, recovered) ->
           let expected_path =
             run_file t ~keeper:identity.keeper ~run_id:identity.run_id
           in
           if String.equal path expected_path
           then Ok recovered
           else Error (Entry_record_failed (Identity_mismatch identity)))
  in
  { entry_name; outcome }
;;

let scan t =
  match inspect_directory t with
  | Error _ as error -> error
  | Ok Fs_compat.Owned_directory_missing -> Ok Store_missing
  | Ok (Fs_compat.Owned_directory before) ->
    let inventory =
      try Ok (Fs_compat.read_dir t.root) with
      | Unix.Unix_error (error, function_name, argument) ->
        Error
          (Directory_inventory_failed
             (directory_io_failure_of_unix error function_name argument))
      | Sys_error detail ->
        Error (Directory_inventory_failed (Directory_sys_error detail))
    in
    (match inventory with
     | Error _ as error -> error
     | Ok entry_names ->
       let entries = List.map (scan_entry t) entry_names in
       (match inspect_directory t with
        | Error _ as error -> error
        | Ok Fs_compat.Owned_directory_missing -> Error Directory_identity_changed
        | Ok (Fs_compat.Owned_directory after) ->
          if same_directory_identity before after
          then Ok (Store_scanned entries)
          else Error Directory_identity_changed))
;;
let transact path decide =
  match Fs_compat.update_private_file_durable_locked_result path decide with
  | Ok result -> result
  | Error error -> Error (Durable_append_failed error)
;;
let register t ~topology ~request ~started_at =
  if not (Float.is_finite started_at)
  then Error (Invalid_started_at started_at)
  else
    let identity = { keeper = request.Fusion_types.keeper; run_id = request.run_id } in
    let requested = { replay = { topology; request }; started_at } in
    match validate_identity identity with
    | Error error -> Error error
    | Ok () ->
      transact (run_file t ~keeper:identity.keeper ~run_id:identity.run_id) (fun content ->
        let retry existing recovered =
          if equal_replay existing.replay requested.replay
          then None, Ok (Already_registered recovered)
          else None, Error (Registration_conflict existing)
        in
        match state_of_content identity content with
        | Error error -> None, Error error
        | Ok Empty -> Some (event_line (Run_registered requested)), Ok Registered
        | Ok (Registered_state_value registration) -> retry registration (Registered_run registration)
        | Ok (Phase_committed_state_value (registration, Computation_committed evidence)) ->
          retry registration (Computation_committed_run (registration, evidence))
        | Ok (Phase_committed_state_value (registration, Stopped_without_computation stop)) ->
          retry registration (Stopped_without_computation_run (registration, stop)))
;;
let commit_phase t ~keeper ~run_id phase =
  let identity = { keeper; run_id } in
  let phase_validation =
    match phase with
    | Computation_committed _ -> Ok ()
    | Stopped_without_computation stop -> validate_stop stop
  in
  match Result.bind (validate_identity identity) (fun () -> phase_validation) with
  | Error error -> Error error
  | Ok () ->
    transact (run_file t ~keeper ~run_id) (fun content ->
      match state_of_content identity content with
      | Error error -> None, Error error
      | Ok Empty ->
        ( None
        , Error
            (Invalid_transition
               { event_index = 1; state = Empty_state; event = event_kind (Phase_committed { identity; phase }) }) )
      | Ok (Registered_state_value registration) ->
        (match validate_phase registration phase with
         | Error error -> None, Error error
         | Ok () ->
           Some (event_line (Phase_committed { identity; phase })), Ok First_committed)
      | Ok (Phase_committed_state_value (registration, winner)) ->
        (match validate_phase registration phase with
         | Error error -> None, Error error
         | Ok () ->
           if equal_phase winner phase
           then None, Ok Already_same
           else None, Ok (Conflict winner)))
;;
