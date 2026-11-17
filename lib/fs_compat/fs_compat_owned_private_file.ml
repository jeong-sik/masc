open Fs_compat_base_io
open Fs_compat_owned_file
open Fs_compat_durable_append
open Fs_compat_private_jsonl_transaction
open Fs_compat_private_jsonl_write

type 'error owned_file_update_error =
  | Owned_observation_failed of owned_regular_file_read_error
  | Underlying_update_failed of 'error

(* The two existing private-file APIs have different setup/missing outcomes.
   Keep those differences typed while sharing the borrowed-descriptor path. *)
type (_, _, _) access =
  | Creating : ('a, 'a, durable_append_error) access
  | Existing : ('a, 'a option, private_jsonl_transaction_error) access

type 'a opened = Opened of Unix.file_descr | Completed of 'a

let capture : type a value error returned.
    (a, value, error) access -> private_jsonl_transaction_operation ->
    (unit -> returned) -> (returned, error) result =
  fun access operation f ->
    match access with
    | Creating -> Ok (f ())
    | Existing ->
      private_jsonl_capture operation f
      |> Result.map_error (fun failure -> Private_jsonl_operation_failed failure)

let require_binding : type a value error.
    (a, value, error) access -> path:string -> Unix.file_descr -> (unit, error) result =
  fun access ~path fd ->
    match private_jsonl_validate_open_binding ~operation:Inspect_transaction_path ~path fd with
    | Ok () -> Ok ()
    | Error error ->
      match access with
      | Existing -> Error error
      | Creating ->
        match error with
        | Private_jsonl_operation_failed failure ->
          Printexc.raise_with_backtrace failure.exception_ failure.backtrace
        | Stable_lock_contended _ | Unexpected_stable_lock_permissions _
        | Invalid_stable_lock_state _ | Cursor_mismatch _
        | Unexpected_transaction_file_kind _ | Ambiguous_transaction_file_identity _
        | Transaction_path_binding_changed _ | Transaction_content_changed _
        | Incomplete_transaction_tail _ | Invalid_transaction_suffix
        | Rewrite_stage_failed _ | Rewrite_published_durability_unknown _
        | Transaction_settlement_failed _ | Transaction_append_failed _ ->
          raise (Sys_error (private_jsonl_transaction_error_to_string error))

let open_data : type a value error.
    (a, value, error) access -> io:private_jsonl_transaction_io_for_testing ->
    missing:bool -> string -> (value opened, error) result =
  fun access ~io ~missing path ->
    match access with
    | Creating ->
      let flags = [Unix.O_RDWR; Unix.O_APPEND; Unix.O_CLOEXEC; Unix.O_NONBLOCK] in
      let fd = if not missing then Unix.openfile path flags 0 else
        (* A raced symlink must not create its target before admission. On
           EEXIST only open an existing leaf, then bind it before any chmod. *)
        match Unix.openfile path (Unix.O_CREAT :: Unix.O_EXCL :: flags) 0o600 with
        | fd -> fd
        | exception Unix.Unix_error (Unix.EEXIST, _, _) -> Unix.openfile path flags 0 in
      Ok (Opened fd)
    | Existing when missing -> Ok (Completed None)
    | Existing ->
      Result.map (function None -> Completed None | Some fd -> Opened fd)
        (private_jsonl_open_existing ~close_fd:io.close_fd path [Unix.O_RDWR; Unix.O_APPEND])

let completed : type a value error. (a, value, error) access -> a -> value =
  fun access value -> match access with Creating -> value | Existing -> Some value

let append_error : type a value error.
    (a, value, error) access -> durable_append_error -> error =
  fun access error -> match access with Creating -> error | Existing -> Transaction_append_failed error

let map_owned result = Result.map_error (fun error -> Owned_observation_failed error) result
let map_underlying result = Result.map_error (fun error -> Underlying_update_failed error) result

let update : type a value error.
    (a, value, error) access -> io:private_jsonl_transaction_io_for_testing ->
    ?owner_uid:int -> ownership_root:string -> string ->
    (owned_regular_file_contents -> string option * a) ->
    (value, error owned_file_update_error) private_file_transaction_outcome =
  fun access ~io ?owner_uid ~ownership_root path decide ->
    test_exec_home_guard ~op:"update_owned_private_file_durable_locked" path;
    let open Result.Syntax in
    let transaction () : (value, error owned_file_update_error) private_file_transaction_outcome =
      (* This probe opens nothing: no creating open or chmod may precede
         parent/leaf admission. Callers prepare an owned parent separately. *)
      match observe_owned_file_path ?owner_uid ~single_link:true ~ownership_root path with
      | Error error -> Private_file_failed (Owned_observation_failed error)
      | Ok None ->
        (match access with
         | Existing -> Private_file_succeeded None
         | Creating ->
           let error = { failure = Owned_file_operation_failed
             { path; operation = Inspect_parent
             ; cause = Unix.Unix_error (Unix.ENOENT, "owned parent", Filename.dirname path) }
             ; close_failure = None } in
           Private_file_failed (Owned_observation_failed error))
      | Ok (Some admitted_path) ->
        let creation_owner =
          match access, owner_uid with
          | Creating, Some expected_uid when owned_file_leaf_is_missing admitted_path
              && expected_uid <> Unix.geteuid () ->
            owned_file_error (Owned_path_owner_mismatch
              { path; expected_uid; actual_uid = Unix.geteuid () })
          | Creating, (None | Some _) | Existing, (None | Some _) -> Ok () in
        match creation_owner with
        | Error error -> Private_file_failed (Owned_observation_failed error)
        | Ok () ->
          evict_inactive_cached_writer_for_path path;
          match open_data access ~io ~missing:(owned_file_leaf_is_missing admitted_path) path with
          | Error error -> Private_file_failed (Underlying_update_failed error)
          | Ok (Completed value) -> Private_file_succeeded value
          | Ok (Opened fd) ->
            private_jsonl_with_fd_outcome ~close_operation:Close_transaction_data
              ~close_fd:io.close_fd fd (fun () ->
                let* _ = admit_owned_file_descriptor admitted_path fd |> map_owned in
                let* () = require_binding access ~path fd |> map_underlying in
                let* () = match access with
                  | Existing -> Ok ()
                  | Creating ->
                    capture access Set_transaction_data_permissions (fun () -> Unix.fchmod fd 0o600)
                    |> map_underlying in
                let* () = match access with
                  | Existing -> Ok ()
                  | Creating ->
                    capture access Sync_rewrite_parent (fun () ->
                      let dir = Filename.dirname path in
                      io.before_sync_parent dir; fsync_parent_directory dir)
                    |> map_underlying in
                let* () = capture access Read_transaction_data (fun () ->
                  ignore (Unix.lseek fd 0 Unix.SEEK_SET : int); lock_whole_file fd)
                  |> map_underlying in
                let* () = require_binding access ~path fd |> map_underlying in
                let* observed = admit_owned_file_descriptor admitted_path fd |> map_owned in
                let snapshot = owned_file_descriptor_snapshot observed in
                let* content = read_exact_file_descriptor ~path fd snapshot.file_size |> map_owned in
                let* () = revalidate_owned_file_descriptor observed fd |> map_owned in
                let suffix, value = decide { content; snapshot } in
                (* Observe the same descriptor after the callback, without
                   reopening it or dropping this process's record lock. *)
                let* () = revalidate_owned_file_descriptor observed fd |> map_owned in
                let* () = require_binding access ~path fd |> map_underlying in
                match suffix with
                | None -> Ok (completed access value)
                | Some suffix ->
                  let* original_length = capture access Read_transaction_data (fun () ->
                    Unix.lseek fd 0 Unix.SEEK_END) |> map_underlying in
                  append_fd_durable ~io:durable_append_unix_io ~fd ~original_length suffix
                  |> Result.map_error (fun error -> Underlying_update_failed (append_error access error))
                  |> Result.map (fun () -> completed access value)) in
    run_blocking_private_file_transaction
        ~label:"fs-compat-owned-private-file-update" ~path
        (fun () -> with_append_path_mutex path transaction)

let update_owned_private_file_durable_locked_result ?owner_uid ~ownership_root path decide =
  update Creating ~io:private_jsonl_transaction_unix_io ?owner_uid ~ownership_root path decide

let update_existing_owned_private_file_durable_locked_result ?owner_uid ~ownership_root path decide =
  update Existing ~io:private_jsonl_transaction_unix_io ?owner_uid ~ownership_root path decide

module Owned_private_file_for_testing = struct
  let create ~io ?owner_uid ~ownership_root path decide =
    update Creating ~io ?owner_uid ~ownership_root path decide
  let existing ~io ?owner_uid ~ownership_root path decide =
    update Existing ~io ?owner_uid ~ownership_root path decide
  let path_mutex_available path = Option.is_some (try_with_append_path_mutex path (fun () -> ()))
end
