open Fs_compat_private_jsonl_transaction
open Result.Syntax

type private_jsonl_guard_failure = {
  guard_path : string;
  guard_error : private_jsonl_transaction_error;
}

type 'a private_jsonl_guard_result =
  | Guard_refused of private_jsonl_guard_failure
  | Guard_executed of {
      value : 'a;
      cleanup_failures : private_jsonl_guard_failure list;
    }

type 'a private_jsonl_dependency_guard_result =
  | Dependency_is_target of {
      target_path : string;
      dependency_path : string;
    }
  | Dependency_guarded of 'a private_jsonl_guard_result

let with_guard ~io requested_path ~expected ~f =
  let cleanup = ref [] in
  (* Only the stable descriptor uses this close function. Data validation uses
     the original IO and must finish normally before the callback can run.
     Preserve even cancellation during settlement after a completed callback. *)
  let guard_io = { io with close_fd = (fun fd ->
    match io.close_fd fd with
    | () -> ()
    | exception exception_ ->
      let failure = { operation = Close_stable_lock; exception_;
        backtrace = Printexc.get_raw_backtrace () } in
      cleanup := failure :: !cleanup) } in
  let perform () =
    with_private_jsonl_identified_stable_lock ~io:guard_io
      ~success:(fun _ -> Snapshot_succeeded expected) requested_path
      (fun ~dir ~path ~lock_identity ->
        let* actual = Fs_compat_private_jsonl_write.read_private_jsonl_snapshot_locked ~io path ~after:None in
        let* () =
          if Private_jsonl_cursor.equal expected.cursor actual.cursor then Ok ()
          else Error (Cursor_mismatch { expected = expected.cursor; actual = actual.cursor }) in
        let* () =
          if String.equal expected.bytes actual.bytes then Ok ()
          else Error (Transaction_content_changed { path }) in
        Ok (f ~dir ~path ~lock_identity)) in
  match perform () with
  | Ok value ->
    Guard_executed { value; cleanup_failures = List.rev_map (fun failure ->
      { guard_path = requested_path; guard_error = Private_jsonl_operation_failed failure }) !cleanup }
  | Error error ->
    let error = List.fold_left private_jsonl_add_cleanup_failure error (List.rev !cleanup) in
    Guard_refused { guard_path = requested_path; guard_error = error }
  | exception exception_ ->
    let original = exception_, Printexc.get_raw_backtrace () in
    let exception_, backtrace = List.fold_left (fun cause failure ->
      Eio.Exn.combine cause (failure.exception_, failure.backtrace)) original (List.rev !cleanup) in
    Printexc.raise_with_backtrace exception_ backtrace

let with_private_jsonl_snapshot_guard_result path ~expected ~f =
  with_guard ~io:private_jsonl_transaction_unix_io path ~expected
    ~f:(fun ~dir:_ ~path:_ ~lock_identity:_ -> f ())

let with_private_jsonl_snapshot_guard_with_io_for_testing ~io path ~expected ~f =
  with_guard ~io path ~expected ~f:(fun ~dir:_ ~path:_ ~lock_identity:_ -> f ())

let append_with_dependency ~io ~dependency_io path ~expected
    ~dependency_path ~dependency suffix =
  with_guard ~io path ~expected ~f:(fun ~dir ~path ~lock_identity ->
    (* The dependency guard takes this process's path mutex and a second
       descriptor on its stable lock. When both names reach the lock held
       here, the mutex is re-locked by its owner, or closing the second
       descriptor drops the POSIX lock of the first. Compare the held
       descriptor with the entry the dependency would open, by [lstat]: opening
       it to [fstat] would itself be that second descriptor. A missing entry
       cannot be the held lock. *)
    match private_jsonl_capture Inspect_stable_lock (fun () ->
      match Unix.lstat (private_jsonl_requested_lock_path dependency_path) with
      | stats -> Some stats
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None)
    with
    | Error failure ->
      Dependency_guarded (Guard_refused { guard_path = dependency_path;
        guard_error = Private_jsonl_operation_failed failure })
    | Ok (Some stats) when private_jsonl_same_identity lock_identity stats ->
      Dependency_is_target { target_path = path; dependency_path }
    | Ok (Some _ | None) ->
      Dependency_guarded (
        with_guard ~io:dependency_io dependency_path ~expected:dependency
          ~f:(fun ~dir:_ ~path:_ ~lock_identity:_ ->
            (* Keep the target's original IO: guard_io only collects stable-lock
               cleanup and must never swallow data-descriptor failures. *)
            Fs_compat_private_jsonl_write.append_private_jsonl_snapshot_locked
              ~io ~dir path ~expected suffix)))

let append_private_jsonl_durable_locked_at_snapshot_with_dependency_result
    path ~expected ~dependency_path ~dependency suffix =
  append_with_dependency ~io:private_jsonl_transaction_unix_io
    ~dependency_io:private_jsonl_transaction_unix_io
    path ~expected ~dependency_path ~dependency suffix

let append_private_jsonl_durable_locked_at_snapshot_with_dependency_with_io_for_testing
    ?(io=private_jsonl_transaction_unix_io)
    ?(dependency_io=private_jsonl_transaction_unix_io)
    path ~expected ~dependency_path ~dependency suffix =
  append_with_dependency ~io ~dependency_io
    path ~expected ~dependency_path ~dependency suffix
