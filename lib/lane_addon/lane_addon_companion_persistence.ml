open Result.Syntax

let blocking work =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> work ()
  | Fs_compat.Eio_fiber -> Eio_unix.run_in_systhread work

(* [None] is permitted only before admission, when the stable lock file has
   not been created yet. This file contains no payload and is never removed. *)
let owner_lock_identity ~unavailable path =
  blocking (fun () ->
    match Unix.lstat path with
    | stat
      when stat.Unix.st_kind = Unix.S_REG
           && stat.st_uid = Unix.getuid ()
           && stat.st_nlink = 1
           && stat.st_perm land 0o022 = 0 ->
      Ok (Some (stat.st_dev, stat.st_ino))
    | _ -> Error unavailable
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
    | exception (Unix.Unix_error _ | Sys_error _) -> Error unavailable)

let with_creation_owner ~path ~unavailable ~commit_unconfirmed work =
  (* Distinct from the private JSONL transaction's [.lock] inode: closing a
     second descriptor for that inode would release a process-wide lockf. *)
  let lock_path = File_lock_eio.lock_file_path (path ^ ".publication-owner") in
  let* prior = owner_lock_identity ~unavailable lock_path in
  match
    File_lock_eio.try_with_durable_lock_observed ~lock_path (fun () ->
      let* held = owner_lock_identity ~unavailable lock_path in
      let valid =
        match prior, held with
        | None, Some _ -> true
        | Some before, Some current -> before = current
        | None, None | Some _, None -> false
      in
      if not valid then Error unavailable
      else
        let value = work () in
        match owner_lock_identity ~unavailable lock_path with
        | Ok current when current = held -> value
        | Ok _ | Error _ -> Error commit_unconfirmed)
  with
  | File_lock_eio.Lock_held_elsewhere -> Error commit_unconfirmed
  | Lock_attempted (Lock_not_acquired _) -> Error unavailable
  | Lock_attempted (Body_completed { value; release_error = None }) -> value
  | Lock_attempted (Body_completed { release_error = Some _; _ }) ->
    Error commit_unconfirmed

let existing_leaf (error : Fs_compat.capability_write_error) =
  error.operation = Fs_compat.Create_exclusive_operation
  && error.target_effect = Fs_compat.Target_unchanged
  && error.cleanup_failures = []
  && match error.primary_failure with
     | Fs_compat.Write_primary_failure failure ->
       (match failure.cause with
        | Fs_compat.Target_already_exists ->
          failure.stage = Fs_compat.Inspect_target_entry
        | Fs_compat.Operation_failed operation_failure ->
          failure.stage = Fs_compat.Publish_exclusive
          && (match operation_failure.exception_ with
              | Unix.Unix_error (code, _, _) -> code = Unix.EEXIST
              | _ -> false)
        | Invalid_recovery_target _ | Mutation_contended
        | Posix_descriptor_unavailable | Unexpected_resource_kind _
        | Resource_identity_unavailable | Resource_identity_changed
        | Payload_write_failed _ -> false)
     | Recovery_primary_failure _ | Recovery_access_primary_failure _ -> false
