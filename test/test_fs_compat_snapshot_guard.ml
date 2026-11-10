(** Exact parent admission spans a child write and excludes another process's
    cooperative parent writer. Child outcome and later guard cleanup differ. *)
open Alcotest
module Fs = Fs_compat

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = (Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK); _ } ->
    Unix.unlink path

let with_root run () =
  let root = Unix.realpath (Filename.temp_dir "fs-snapshot-guard-" "") in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let read path = In_channel.with_open_bin path In_channel.input_all
let snapshot path = match Fs.private_jsonl_snapshot_success_receipt
    (Fs.read_private_jsonl_durable_locked_result path ~after:None) with
  | Ok { value; settlement_error = None } -> value
  | Ok { settlement_error = Some error; _ } | Error error ->
    fail (Fs.private_jsonl_transaction_error_to_string error)

let require_write result = match Fs.private_jsonl_cursor_success_receipt result with
  | Ok { value; settlement_error = None } -> value
  | Ok { settlement_error = Some error; _ } | Error error ->
    fail (Fs.private_jsonl_transaction_error_to_string error)

let seed root =
  let parent = Filename.concat root "posts.jsonl" in
  ignore (require_write (Fs.append_private_jsonl_durable_stable_result parent "{\"owner\":\"alice\"}\n"));
  parent, snapshot parent, Filename.concat root "decision.jsonl"

let record child () = Fs.append_private_jsonl_durable_stable_result child "{\"delete\":true}\n"

let require_guard_refusal parent accept = function
  | Fs.Guard_refused failure ->
    check string "refusal retains actual parent path" parent failure.guard_path;
    accept failure.guard_error
  | Fs.Guard_executed _ -> fail "refused parent ran the child write"

let require_cursor_mismatch = function
  | Fs.Cursor_mismatch _ -> ()
  | (Fs.Stable_lock_contended _
    | Fs.Unexpected_stable_lock_permissions _
    | Fs.Invalid_stable_lock_state _
    | Fs.Unexpected_transaction_file_kind _
    | Fs.Ambiguous_transaction_file_identity _
    | Fs.Transaction_path_binding_changed _
    | Fs.Transaction_content_changed _
    | Fs.Incomplete_transaction_tail _
    | Fs.Invalid_transaction_suffix
    | Fs.Private_jsonl_operation_failed _
    | Fs.Rewrite_stage_failed _
    | Fs.Rewrite_published_durability_unknown _
    | Fs.Transaction_settlement_failed _
    | Fs.Transaction_append_failed _) as error -> fail (Fs.private_jsonl_transaction_error_to_string error)

let require_content_mismatch = function
  | Fs.Transaction_content_changed _ -> ()
  | (Fs.Stable_lock_contended _
    | Fs.Unexpected_stable_lock_permissions _
    | Fs.Invalid_stable_lock_state _
    | Fs.Cursor_mismatch _
    | Fs.Unexpected_transaction_file_kind _
    | Fs.Ambiguous_transaction_file_identity _
    | Fs.Transaction_path_binding_changed _
    | Fs.Incomplete_transaction_tail _
    | Fs.Invalid_transaction_suffix
    | Fs.Private_jsonl_operation_failed _
    | Fs.Rewrite_stage_failed _
    | Fs.Rewrite_published_durability_unknown _
    | Fs.Transaction_settlement_failed _
    | Fs.Transaction_append_failed _) as error -> fail (Fs.private_jsonl_transaction_error_to_string error)

let require_published_unknown = function
  | Error error ->
    (match error with
     | Fs.Rewrite_published_durability_unknown _ -> ()
     | (Fs.Stable_lock_contended _
       | Fs.Unexpected_stable_lock_permissions _
       | Fs.Invalid_stable_lock_state _
       | Fs.Cursor_mismatch _
       | Fs.Unexpected_transaction_file_kind _
       | Fs.Ambiguous_transaction_file_identity _
       | Fs.Transaction_path_binding_changed _
       | Fs.Transaction_content_changed _
       | Fs.Incomplete_transaction_tail _
       | Fs.Invalid_transaction_suffix
       | Fs.Private_jsonl_operation_failed _
       | Fs.Rewrite_stage_failed _
       | Fs.Transaction_settlement_failed _
       | Fs.Transaction_append_failed _) -> fail "child uncertainty changed during guard settlement")
  | Ok _ -> fail "unknown child became known success"

let test_refused_cursor root =
  let parent, expected, child = seed root in
  ignore (require_write (Fs.append_private_jsonl_durable_stable_result parent "{\"foreign\":true}\n"));
  let before = read parent in
  require_guard_refusal parent require_cursor_mismatch
    (Fs.with_private_jsonl_snapshot_guard_result parent ~expected ~f:(record child));
  check bool "refused scope creates no child data" false (Sys.file_exists child);
  check string "foreign parent bytes survive" before (read parent)

let test_refused_bytes root =
  let parent, expected, child = seed root in
  let changed = "{\"owner\":\"bobby\"}\n" in
  check int "same-length edit retains end offset" (String.length expected.bytes) (String.length changed);
  Out_channel.with_open_gen [Open_wronly; Open_binary] 0o600 parent
    (fun output -> output_string output changed);
  check bool "real edit retains exact cursor" true
    (Fs.Private_jsonl_cursor.equal expected.cursor (snapshot parent).cursor);
  require_guard_refusal parent require_content_mismatch
    (Fs.with_private_jsonl_snapshot_guard_result parent ~expected ~f:(record child));
  check bool "content refusal creates no child data" false (Sys.file_exists child);
  check string "changed bytes survive exact validation" changed (read parent)

let competing_writer parent =
  match Fs.append_private_jsonl_durable_stable_result parent "{\"foreign\":true}\n" with
  | Error error ->
    (match error with
     | Fs.Stable_lock_contended _ -> 0
     | (Fs.Unexpected_stable_lock_permissions _
       | Fs.Invalid_stable_lock_state _
       | Fs.Cursor_mismatch _
       | Fs.Unexpected_transaction_file_kind _
       | Fs.Ambiguous_transaction_file_identity _
       | Fs.Transaction_path_binding_changed _
       | Fs.Transaction_content_changed _
       | Fs.Incomplete_transaction_tail _
       | Fs.Invalid_transaction_suffix
       | Fs.Private_jsonl_operation_failed _
       | Fs.Rewrite_stage_failed _
       | Fs.Rewrite_published_durability_unknown _
       | Fs.Transaction_settlement_failed _
       | Fs.Transaction_append_failed _) -> 2)
  | Ok _ -> 3

let test_separate_process_excluded root =
  let parent, expected, child = seed root in
  let f () =
    let written = record child () in
    (* Exec starts a new mutex registry. Forking with a held in-process mutex
       could only prove a deadlock in the inherited test process. *)
    let pid = Unix.create_process Sys.executable_name
        [| Sys.executable_name; "--compete-with-guard"; parent |]
        Unix.stdin Unix.stdout Unix.stderr in
    let _, status = Unix.waitpid [] pid in
    written, status in
  (match Fs.with_private_jsonl_snapshot_guard_result parent ~expected ~f with
   | Fs.Guard_executed { value = (written, status); cleanup_failures } ->
     ignore (require_write written);
     check bool "parent guard settled normally" true (cleanup_failures = []);
     (match status with
      | Unix.WEXITED code -> check int "competing writer reported actual lock contention" 0 code
      | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
        failf "competing writer did not finish: signal %d" signal)
   | Fs.Guard_refused failure -> fail (Fs.private_jsonl_transaction_error_to_string failure.guard_error));
  check string "only the child data changed" expected.bytes (read parent);
  check string "child write completed inside scope" "{\"delete\":true}\n" (read child);
  ignore (require_write (Fs.append_private_jsonl_durable_stable_result parent "{\"later\":true}\n"))

let cleanup_io parent captured : Fs.private_jsonl_transaction_io_for_testing = {
  before_sync_parent = (fun _ -> ());
  close_fd = (fun fd ->
    let stat = Unix.fstat fd and lock = Unix.lstat (Fs.private_jsonl_lock_path parent) in
    Unix.close fd;
    if stat.Unix.st_dev = lock.Unix.st_dev && stat.Unix.st_ino = lock.Unix.st_ino then
      try raise Eio.Time.Timeout with exception_ ->
        let backtrace = Printexc.get_raw_backtrace () in
        captured := Some backtrace;
        Printexc.raise_with_backtrace exception_ backtrace) }

let check_cleanup parent captured = function
  | [{ Fs.guard_path; guard_error }] ->
    let failure = match guard_error with
      | Fs.Private_jsonl_operation_failed failure -> failure
      | (Fs.Stable_lock_contended _
        | Fs.Unexpected_stable_lock_permissions _
        | Fs.Invalid_stable_lock_state _
        | Fs.Cursor_mismatch _
        | Fs.Unexpected_transaction_file_kind _
        | Fs.Ambiguous_transaction_file_identity _
        | Fs.Transaction_path_binding_changed _
        | Fs.Transaction_content_changed _
        | Fs.Incomplete_transaction_tail _
        | Fs.Invalid_transaction_suffix
        | Fs.Rewrite_stage_failed _
        | Fs.Rewrite_published_durability_unknown _
        | Fs.Transaction_settlement_failed _
        | Fs.Transaction_append_failed _) -> fail "guard cleanup lost typed close failure" in
    check string "cleanup identifies guarded parent" parent guard_path;
    check bool "cleanup identifies stable descriptor close" true (failure.operation = Fs.Close_stable_lock);
    check bool "original reserved cleanup cause remains attached" true (failure.exception_ == Eio.Time.Timeout);
    let origin = match !captured with Some origin -> origin | None -> fail "actual close did not fail" in
    let length = Printexc.raw_backtrace_length origin in
    check bool "raising origin has frames" true (length > 0);
    check bool "original frames retained" true (Printexc.raw_backtrace_length failure.backtrace >= length);
    for index = 0 to length - 1 do
      check bool "cleanup preserves each original frame" true
        (Printexc.get_raw_backtrace_slot origin index = Printexc.get_raw_backtrace_slot failure.backtrace index)
    done
  | _ -> fail "guard cleanup lost its original typed cause"

let test_known_child_cleanup root =
  let parent, expected, child = seed root in
  let captured = ref None in
  let io = cleanup_io parent captured in
  (match Fs.with_private_jsonl_snapshot_guard_with_io_for_testing ~io parent ~expected ~f:(record child) with
   | Fs.Guard_executed { value; cleanup_failures } ->
     ignore (require_write value);
     check_cleanup parent captured cleanup_failures
   | Fs.Guard_refused _ -> fail "later guard cleanup erased known child outcome");
  check string "known child remains after guard cleanup failure" "{\"delete\":true}\n" (read child);
  ignore (snapshot parent)

let test_unknown_child_cleanup root =
  let parent, expected, child = seed root in
  let child_before = snapshot child and captured = ref None in
  let io = cleanup_io parent captured in
  let child_io : Fs.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> if Sys.file_exists child then raise (Sys_error "child parent sync failed"));
    close_fd = Unix.close } in
  let f () = Fs.rewrite_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
      ~io:child_io ~before_sync_rewrite_parent:child_io.before_sync_parent child
      ~expected:child_before "{\"delete\":true}\n" in
  (match Fs.with_private_jsonl_snapshot_guard_with_io_for_testing ~io parent ~expected ~f with
   | Fs.Guard_executed { value; cleanup_failures } ->
     require_published_unknown value;
     check_cleanup parent captured cleanup_failures
   | Fs.Guard_refused _ -> fail "later guard cleanup erased executed unknown child");
  check string "published bytes do not imply durable child success" "{\"delete\":true}\n" (read child);
  ignore (snapshot parent)

let () =
  Printexc.record_backtrace true;
  match Array.to_list Sys.argv with
  | [_; "--compete-with-guard"; parent] -> exit (competing_writer parent)
  | _ ->
    let case name run = test_case name `Quick (with_root run) in
    run "fs_compat_snapshot_guard" ["exact parent through child IO", [
      case "stale cursor refuses before child write" test_refused_cursor;
      case "same cursor changed bytes refuses before child write" test_refused_bytes;
      case "separate process writer excluded through child write" test_separate_process_excluded;
      case "known child survives reserved guard cleanup" test_known_child_cleanup;
      case "unknown child and reserved guard cleanup both survive" test_unknown_child_cleanup
    ]]
