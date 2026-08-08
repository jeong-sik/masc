(** Storage primitives and filesystem boundary for the durable Keeper chat queue. *)

let error ~operation db rc =
  Printf.sprintf
    "SQLite %s failed: rc=%s error=%s"
    operation
    (Sqlite3.Rc.to_string rc)
    (Sqlite3.errmsg db)

let exec db ~operation sql =
  let rc = Sqlite3.exec db sql in
  if Sqlite3.Rc.is_success rc then Ok () else Error (error ~operation db rc)

let bind db stmt ~operation index value =
  let rc = Sqlite3.bind stmt index value in
  if Sqlite3.Rc.is_success rc then Ok () else Error (error ~operation db rc)

let bind_text db stmt ~operation index value =
  let rc = Sqlite3.bind_text stmt index value in
  if Sqlite3.Rc.is_success rc then Ok () else Error (error ~operation db rc)

let bind_int64 db stmt ~operation index value =
  let rc = Sqlite3.bind_int64 stmt index value in
  if Sqlite3.Rc.is_success rc then Ok () else Error (error ~operation db rc)

let expect_done db stmt ~operation =
  match Sqlite3.step stmt with
  | Sqlite3.Rc.DONE -> Ok ()
  | rc -> Error (error ~operation db rc)

(* Sqlite3.finalize may raise SqliteError as well as returning an error rc.
   Keep statement cleanup total so it cannot erase a body error or replace
   Eio cancellation. The opaque identity also pins the wrapper across the C
   call, whose runtime-lock release otherwise opens a GC finalizer race. *)
let finalize db stmt =
  let result =
    match Sqlite3.finalize stmt with
    | rc ->
      if Sqlite3.Rc.is_success rc
      then Ok ()
      else Error (error ~operation:"statement finalize" db rc)
    | exception exn ->
      Error ("SQLite statement finalize raised: " ^ Printexc.to_string exn)
  in
  (* See the statement-liveness invariant above. *)
  ignore (Sys.opaque_identity stmt);
  result

let combine_cleanup_error primary cleanup =
  match primary, cleanup with
  | Ok value, Ok () -> Ok value
  | Error detail, Ok () -> Error detail
  | Ok _, Error detail -> Error detail
  | Error primary, Error cleanup ->
    Error (primary ^ "; cleanup also failed: " ^ cleanup)

let with_statement db sql body =
  match
    try Ok (Sqlite3.prepare db sql) with
    | exn -> Error ("SQLite statement prepare failed: " ^ Printexc.to_string exn)
  with
  | Error _ as error -> error
  | Ok stmt ->
    let body_result =
      try body stmt with
      | Eio.Cancel.Cancelled _ as exception_ ->
        (match finalize db stmt with
         | Ok () -> ()
         | Error detail ->
           Log.Keeper.error
             "chat queue statement finalize failed during cancellation: %s"
             detail);
        raise exception_
      | exn -> Error (Printexc.to_string exn)
    in
    combine_cleanup_error body_result (finalize db stmt)

let single_int64 db ~operation sql =
  with_statement db sql (fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let value = Sqlite3.column_int64 stmt 0 in
        (match Sqlite3.step stmt with
         | Sqlite3.Rc.DONE -> Ok value
         | rc -> Error (error ~operation db rc))
      | rc -> Error (error ~operation db rc))

let single_text db ~operation sql =
  with_statement db sql (fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let value = Sqlite3.column_text stmt 0 in
        (match Sqlite3.step stmt with
         | Sqlite3.Rc.DONE -> Ok value
         | rc -> Error (error ~operation db rc))
      | rc -> Error (error ~operation db rc))

let ( let* ) = Result.bind

let directory_chain_error_to_string = function
  | Keeper_fs_durable_directory.Non_directory_ancestor { path } ->
    Printf.sprintf "directory path is occupied by a non-directory: %s" path
  | Keeper_fs_durable_directory.Outside_ownership_root { ownership_root; path } ->
    Printf.sprintf
      "directory path %s is outside ownership root %s"
      path
      ownership_root
  | Keeper_fs_durable_directory.Missing_root { path } ->
    Printf.sprintf "cannot create filesystem root: %s" path
  | Keeper_fs_durable_directory.Creation_not_observed { path } ->
    Printf.sprintf
      "directory creation returned without a visible directory: %s"
      path
;;

let durable_directory_failure_to_string = function
  | Keeper_fs_durable_directory.Directory_chain_failed error ->
    directory_chain_error_to_string error
  | Keeper_fs_durable_directory.Operation_failed (exn, _) ->
    Printexc.to_string exn
;;

type regular_path_observation =
  | Path_absent
  | Regular_path of Unix.stats

let inspect_regular_or_absent path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Path_absent
  | exception exn ->
    Error
      (Printf.sprintf
         "failed to inspect owned chat queue path %s: %s"
         path
         (Printexc.to_string exn))
  | { Unix.st_kind = Unix.S_REG; _ } as stat -> Ok (Regular_path stat)
  | { Unix.st_kind; _ } ->
    Error
      (Printf.sprintf
         "owned chat queue path is not a regular file: path=%s kind=%s"
         path
         (Fs_compat.file_kind_to_string st_kind))
;;

let same_regular_identity left right =
  left.Unix.st_kind = Unix.S_REG
  && right.Unix.st_kind = Unix.S_REG
  && left.Unix.st_dev = right.Unix.st_dev
  && left.Unix.st_ino = right.Unix.st_ino
;;

let validate_owned_parent ~ownership_root path =
  let parent = Filename.dirname path in
  match Fs_compat.inspect_owned_directory_chain ~ownership_root parent with
  | Ok (Fs_compat.Owned_directory _) -> Ok ()
  | Ok Fs_compat.Owned_directory_missing ->
    Error (Printf.sprintf "owned chat queue parent directory is absent: %s" parent)
  | Error rejection ->
    Error (Fs_compat.owned_directory_chain_rejection_to_string rejection)
;;

let ensure_owned_parent ~ownership_root path =
  let parent = Filename.dirname path in
  match
    Keeper_fs_durable_directory.ensure
      ~before_prepare:(fun () -> ())
      ~before_directory_fsync:(fun _ -> ())
      ~ownership_root
      parent
  with
  | Ok _ -> validate_owned_parent ~ownership_root path
  | Error error -> Error (durable_directory_failure_to_string error)
;;

let prepare_database_parent ~ownership_root ~path ~create_if_missing =
  if create_if_missing
  then ensure_owned_parent ~ownership_root path
  else Ok ()
;;

let database_sidecars path = [ path ^ "-journal"; path ^ "-wal"; path ^ "-shm" ]

let validate_database_paths ~ownership_root path =
  let* () = validate_owned_parent ~ownership_root path in
  let* database = inspect_regular_or_absent path in
  let* () =
    List.fold_left
      (fun result sidecar ->
         let* () = result in
         let* _ = inspect_regular_or_absent sidecar in
         Ok ())
      (Ok ())
      (database_sidecars path)
  in
  Ok database
;;
