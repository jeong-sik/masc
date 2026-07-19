type identity =
  { keeper : string
  ; run_id : string
  }
[@@deriving yojson, show, eq]
type registration =
  { identity : identity
  ; preset : string
  ; started_at : float
  }
[@@deriving yojson, show, eq]
type terminal =
  | Deliberated of Fusion_types.deliberation_evidence
  | Aborted of string
  | Cancelled of string
  | Interrupted_after_restart
[@@deriving yojson, show, eq]
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
  | Orphan_terminal
  | Reversed_records
  | Unexpected_sequence of int
  | Identity_mismatch of identity
  | Registration_conflict of registration
  | Durable_append_failed of Fs_compat.durable_append_error
type register_outcome =
  | Registered
  | Already_running
  | Already_settled of terminal
type claim_outcome =
  | First_committed
  | Already_same
  | Conflict of terminal
type recovered_run =
  | Running_run of registration
  | Settled_run of
      { registration : registration
      ; terminal : terminal
      }
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
type terminal_record =
  { identity : identity
  ; terminal : terminal
  }
[@@deriving yojson]
type persisted_event =
  | Run_registered of registration
  | Terminal_committed of terminal_record
[@@deriving yojson]
type persisted_record =
  { schema_version : int
  ; event : persisted_event
  }
[@@deriving yojson]
type persisted_state =
  | Empty
  | Running of registration
  | Settled of registration * terminal
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
  match validate_identity registration.identity with
  | Error _ as error -> error
  | Ok () ->
    if Float.is_finite registration.started_at
    then Ok ()
    else Error (Invalid_started_at registration.started_at)
;;
let validate_terminal = function
  | Deliberated _ -> Ok ()
  | Aborted "" -> Error Empty_abort_detail
  | Aborted _ -> Ok ()
  | Cancelled "" -> Error Empty_cancellation_detail
  | Cancelled _ -> Ok ()
  | Interrupted_after_restart -> Ok ()
;;
let schema_version = 2
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
let state_of_events expected events =
  let ( let* ) = Result.bind in
  match events with
  | [] -> Ok Empty
  | [ Run_registered registration ] ->
    let* () = validate_registration registration in
    let* () = check_identity expected registration.identity in
    Ok (Running registration)
  | [ Run_registered registration; Terminal_committed terminal_record ] ->
    let* () = validate_registration registration in
    let* () = check_identity expected registration.identity in
    let* () = check_identity expected terminal_record.identity in
    let* () = validate_terminal terminal_record.terminal in
    Ok (Settled (registration, terminal_record.terminal))
  | [ Terminal_committed terminal_record ] ->
    let* () = check_identity expected terminal_record.identity in
    Error Orphan_terminal
  | [ Terminal_committed terminal_record; Run_registered registration ] ->
    let* () = check_identity expected terminal_record.identity in
    let* () = validate_registration registration in
    let* () = check_identity expected registration.identity in
    Error Reversed_records
  | events -> Error (Unexpected_sequence (List.length events))
;;
let state_of_content expected content =
  Result.bind (parse_events content) (state_of_events expected)
;;

let identity_of_event = function
  | Run_registered registration -> registration.identity
  | Terminal_committed terminal_record -> terminal_record.identity
;;

let recovered_run_of_content content =
  let ( let* ) = Result.bind in
  let* events = parse_events content in
  match events with
  | [] -> Error (Unexpected_sequence 0)
  | first :: _ ->
    let identity = identity_of_event first in
    let* state = state_of_events identity events in
    (match state with
     | Empty -> Error (Unexpected_sequence 0)
     | Running registration -> Ok (identity, Running_run registration)
     | Settled (registration, terminal) ->
       Ok (identity, Settled_run { registration; terminal }))
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
let register t ~keeper ~run_id ~preset ~started_at =
  if not (Float.is_finite started_at)
  then Error (Invalid_started_at started_at)
  else
    let identity = { keeper; run_id } in
    let requested = { identity; preset; started_at } in
    match validate_identity identity with
    | Error error -> Error error
    | Ok () ->
      transact (run_file t ~keeper ~run_id) (fun content ->
        match state_of_content identity content with
        | Error error -> None, Error error
        | Ok Empty -> Some (event_line (Run_registered requested)), Ok Registered
        | Ok (Running existing) ->
          if equal_registration existing requested
          then None, Ok Already_running
          else None, Error (Registration_conflict existing)
        | Ok (Settled (existing, terminal)) ->
          if equal_registration existing requested
          then None, Ok (Already_settled terminal)
          else None, Error (Registration_conflict existing))
;;
let claim_terminal t ~keeper ~run_id terminal =
  match validate_terminal terminal with
  | Error error -> Error error
  | Ok () ->
    let identity = { keeper; run_id } in
    (match validate_identity identity with
     | Error error -> Error error
     | Ok () ->
       transact (run_file t ~keeper ~run_id) (fun content ->
         match state_of_content identity content with
         | Error error -> None, Error error
         | Ok Empty -> None, Error Orphan_terminal
         | Ok (Running _) ->
           let record = { identity; terminal } in
           Some (event_line (Terminal_committed record)), Ok First_committed
         | Ok (Settled (_, winner)) ->
           if equal_terminal winner terminal
           then None, Ok Already_same
           else None, Ok (Conflict winner)))
;;
