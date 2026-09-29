(* See .mli. *)

type confirm_outcome =
  | Appended
  | Unchanged

type partition_write =
  | Fsync_completed
  | Visible_sync_unconfirmed of string

type record =
  { partition_id : string
  ; generation : int
  ; keeper_name : string
  ; boot_identity : string
  ; observed_at : float
  ; confirm_outcome : confirm_outcome
  ; partition_write : partition_write
  }

let schema = "masc.board_attention.ready_confirmation.v1"

let confirm_outcome_to_string = function
  | Appended -> "appended"
  | Unchanged -> "unchanged"
;;

let confirm_outcome_of_string = function
  | "appended" -> Ok Appended
  | "unchanged" -> Ok Unchanged
  | other -> Error (Printf.sprintf "unknown confirm outcome: %S" other)
;;

let partition_write_to_yojson = function
  | Fsync_completed -> `String "fsync_completed"
  | Visible_sync_unconfirmed detail -> `Assoc [ "visible_sync_unconfirmed", `String detail ]
;;

let partition_write_of_yojson = function
  | `String "fsync_completed" -> Ok Fsync_completed
  | `Assoc [ ("visible_sync_unconfirmed", `String detail) ] ->
    Ok (Visible_sync_unconfirmed detail)
  | other ->
    Error
      (Printf.sprintf
         "unknown partition write outcome: %s"
         (Yojson.Safe.to_string other))
;;

let record_to_yojson record =
  `Assoc
    [ "schema", `String schema
    ; "partition_id", `String record.partition_id
    ; "generation", `Int record.generation
    ; "keeper_name", `String record.keeper_name
    ; "boot_identity", `String record.boot_identity
    ; "observed_at", `Float record.observed_at
    ; "confirm_outcome", `String (confirm_outcome_to_string record.confirm_outcome)
    ; "partition_write", partition_write_to_yojson record.partition_write
    ]
;;

let field fields name = List.assoc_opt name fields

let record_of_yojson = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* () =
      match field fields "schema" with
      | Some (`String value) when String.equal value schema -> Ok ()
      | Some (`String other) ->
        Error (Printf.sprintf "unexpected ready confirmation schema: %S" other)
      | _ -> Error "ready confirmation row has no schema"
    in
    let string_field name =
      match field fields name with
      | Some (`String value) -> Ok value
      | _ -> Error (Printf.sprintf "ready confirmation row has no %s" name)
    in
    let* partition_id = string_field "partition_id" in
    let* keeper_name = string_field "keeper_name" in
    let* boot_identity = string_field "boot_identity" in
    let* generation =
      match field fields "generation" with
      | Some (`Int value) -> Ok value
      | _ -> Error "ready confirmation row has no generation"
    in
    let* observed_at =
      match field fields "observed_at" with
      | Some (`Float value) -> Ok value
      | Some (`Int value) -> Ok (float_of_int value)
      | _ -> Error "ready confirmation row has no observed_at"
    in
    let* confirm_outcome =
      let* raw = string_field "confirm_outcome" in
      confirm_outcome_of_string raw
    in
    let* partition_write =
      match field fields "partition_write" with
      | Some value -> partition_write_of_yojson value
      | None -> Error "ready confirmation row has no partition_write"
    in
    Ok
      { partition_id
      ; generation
      ; keeper_name
      ; boot_identity
      ; observed_at
      ; confirm_outcome
      ; partition_write
      }
  | _ -> Error "ready confirmation row is not an object"
;;

let dir base_path =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    "board_attention_ready_confirmations"
;;

let path ~base_path ~keeper_name =
  Filename.concat
    (dir base_path)
    (Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name ^ ".jsonl")
;;

let append_error_to_string = function
  | Fs_compat.Private_file_failed error -> Fs_compat.private_jsonl_append_error_to_string error
  | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    Printf.sprintf
      "%s (cleanup: %s)"
      (Fs_compat.private_jsonl_append_error_to_string error)
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  | Fs_compat.Private_file_succeeded () -> "unexpected success"
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { cleanup_failure; _ } ->
    Printf.sprintf
      "append succeeded but descriptor cleanup failed: %s"
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
;;

let append
      ~base_path
      ~keeper_name
      ~partition_id
      ~generation
      ~observed_at
      ~confirm_outcome
      ~partition_write
  =
  let record =
    { partition_id
    ; generation
    ; keeper_name
    ; boot_identity = Build_identity.runtime_instance_id
    ; observed_at
    ; confirm_outcome
    ; partition_write
    }
  in
  let line = Yojson.Safe.to_string (record_to_yojson record) ^ "\n" in
  match Fs_compat.append_private_jsonl_durable_locked_result (path ~base_path ~keeper_name) line with
  | Fs_compat.Private_file_succeeded () -> Ok ()
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { cleanup_failure; _ } ->
    Error
      (Printf.sprintf
         "ready confirmation append succeeded but descriptor cleanup failed: %s"
         (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
  | (Fs_compat.Private_file_failed _ | Fs_compat.Private_file_failed_with_cleanup_failure _) as
    outcome ->
    Error (append_error_to_string outcome)
;;

let read ~base_path ~keeper_name =
  let file = path ~base_path ~keeper_name in
  if not (Sys.file_exists file) then Ok []
  else
    match Fs_compat.read_private_jsonl_durable_locked_result file ~after:None with
    | Error error -> Error (Fs_compat.private_jsonl_transaction_error_to_string error)
    | Ok snapshot ->
      let ( let* ) = Result.bind in
      let* records =
        String.split_on_char '\n' snapshot.Fs_compat.bytes
        |> List.fold_left
             (fun result line ->
                let* rows = result in
                let line = String.trim line in
                if String.equal line "" then Ok rows
                else
                  match Yojson.Safe.from_string line with
                  | json ->
                    let* record = record_of_yojson json in
                    Ok (record :: rows)
                  | exception Yojson.Json_error detail ->
                    Error (Printf.sprintf "ready confirmation row is not JSON: %s" detail))
             (Ok [])
      in
      Ok (List.rev records)
;;
