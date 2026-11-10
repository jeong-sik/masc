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
    with_private_jsonl_stable_lock ~io:guard_io
      ~success:(fun _ -> Snapshot_succeeded expected) requested_path
      (fun ~dir:_ ~path ->
        let* actual = Fs_compat_private_jsonl_write.read_private_jsonl_snapshot_locked ~io path ~after:None in
        let* () =
          if Private_jsonl_cursor.equal expected.cursor actual.cursor then Ok ()
          else Error (Cursor_mismatch { expected = expected.cursor; actual = actual.cursor }) in
        let* () =
          if String.equal expected.bytes actual.bytes then Ok ()
          else Error (Transaction_content_changed { path }) in
        Ok (f ())) in
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
  with_guard ~io:private_jsonl_transaction_unix_io path ~expected ~f

let with_private_jsonl_snapshot_guard_with_io_for_testing ~io path ~expected ~f =
  with_guard ~io path ~expected ~f
