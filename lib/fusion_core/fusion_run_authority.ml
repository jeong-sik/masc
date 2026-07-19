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
let state_of_content expected content =
  let ( let* ) = Result.bind in
  let* events = parse_events content in
  match events with
  | [] -> Ok Empty
  | [ Run_registered registration ] ->
    let* () = check_identity expected registration.identity in
    Ok (Running registration)
  | [ Run_registered registration; Terminal_committed terminal_record ] ->
    let* () = check_identity expected registration.identity in
    let* () = check_identity expected terminal_record.identity in
    let* () = validate_terminal terminal_record.terminal in
    Ok (Settled (registration, terminal_record.terminal))
  | [ Terminal_committed terminal_record ] ->
    let* () = check_identity expected terminal_record.identity in
    Error Orphan_terminal
  | [ Terminal_committed terminal_record; Run_registered registration ] ->
    let* () = check_identity expected terminal_record.identity in
    let* () = check_identity expected registration.identity in
    Error Reversed_records
  | events -> Error (Unexpected_sequence (List.length events))
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
