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

(* A dependency that is the target must come back as a value. Before the
   identity check the same thread re-locked the target's path mutex, so the
   alarm turns a wait that never ends into a failed run. *)
let dependency_deadline_seconds = 30

let append_with_dependency target ~expected ~dependency_path ~dependency suffix =
  ignore (Unix.alarm dependency_deadline_seconds);
  Fun.protect ~finally:(fun () -> ignore (Unix.alarm 0)) (fun () ->
    Fs.append_private_jsonl_durable_locked_at_snapshot_with_dependency_result
      target ~expected ~dependency_path ~dependency suffix)

let policy_row = "{\"policy\":\"open\"}\n"
let post_row = "{\"post\":1}\n"

let seed_policy root =
  let policy = Filename.concat root "sub_boards.jsonl" in
  ignore (require_write (Fs.append_private_jsonl_durable_stable_result policy policy_row));
  policy

let require_distinct_append target policy =
  match append_with_dependency target ~expected:(snapshot target)
          ~dependency_path:policy ~dependency:(snapshot policy) post_row with
  | Fs.Guard_executed { value = Fs.Dependency_guarded (Fs.Guard_executed {
      value; cleanup_failures = [] }); cleanup_failures = [] } -> ignore (require_write value)
  | Fs.Guard_executed { value = Fs.Dependency_guarded (Fs.Guard_executed _); _ } ->
    fail "distinct dependency append left guard cleanup failures"
  | Fs.Guard_executed { value = Fs.Dependency_guarded (Fs.Guard_refused failure); _ }
  | Fs.Guard_refused failure ->
    fail (Fs.private_jsonl_transaction_error_to_string failure.guard_error)
  | Fs.Guard_executed { value = Fs.Dependency_is_target _; _ } ->
    fail "distinct dependency was judged to be the target"

(* The refusal must leave the target unwritten and both of its locks free:
   the following append through a distinct dependency has to succeed. *)
let require_same_file_refusal root target ~dependency_path =
  let policy = seed_policy root in
  let expected = snapshot target in
  (match append_with_dependency target ~expected ~dependency_path ~dependency:expected post_row with
   | Fs.Guard_executed { value = Fs.Dependency_is_target { target_path; dependency_path = reported };
       cleanup_failures = [] } ->
     check string "refusal names the canonical target" target target_path;
     check string "refusal names the dependency as given" dependency_path reported
   | Fs.Guard_executed { value = Fs.Dependency_is_target _; _ } ->
     fail "same-file refusal left target guard cleanup failures"
   | Fs.Guard_executed { value = Fs.Dependency_guarded _; _ } ->
     fail "dependency guard started on the target file"
   | Fs.Guard_refused failure ->
     fail (Fs.private_jsonl_transaction_error_to_string failure.guard_error));
  check string "refused append wrote nothing" expected.bytes
    (if Sys.file_exists target then read target else "");
  require_distinct_append target policy;
  check string "target accepts the next append" (expected.bytes ^ post_row) (read target)

let test_dependency_same_spelling root =
  let target, _, _ = seed root in
  require_same_file_refusal root target ~dependency_path:target

let test_dependency_dot_spelling root =
  let target, _, _ = seed root in
  require_same_file_refusal root target
    ~dependency_path:(Filename.concat (Filename.concat root ".") "posts.jsonl")

let test_dependency_through_symlinked_directory root =
  let target, _, _ = seed root in
  let alias = Filename.concat root "alias" in
  Unix.symlink root alias;
  require_same_file_refusal root target ~dependency_path:(Filename.concat alias "posts.jsonl")

let test_dependency_trailing_separator_on_missing_target root =
  let target = Filename.concat root "posts.jsonl" in
  require_same_file_refusal root target ~dependency_path:(target ^ Filename.dir_sep)

let test_dependency_distinct_file_appends root =
  let target, expected, _ = seed root in
  require_distinct_append target (seed_policy root);
  check string "append landed after both guards" (expected.bytes ^ post_row) (read target)

let test_dependency_lock_entry_not_inspectable root =
  let target, expected, _ = seed root in
  let dependency_path = Filename.concat target "sub_boards.jsonl" in
  (match append_with_dependency target ~expected ~dependency_path ~dependency:expected post_row with
   | Fs.Guard_executed { value = Fs.Dependency_guarded (Fs.Guard_refused {
       guard_path; guard_error = Fs.Private_jsonl_operation_failed {
         operation = Fs.Inspect_stable_lock; _ } }); cleanup_failures = [] } ->
     check string "inner refusal names the dependency" dependency_path guard_path
   | Fs.Guard_executed _ | Fs.Guard_refused _ ->
     fail "uninspectable dependency lock entry was not an inner refusal");
  check string "refused append wrote nothing" expected.bytes (read target)

(* Multi-chunk (>64 KiB, with unaligned non-multiple-of-8 length) streaming
   snapshot verification: exact match succeeds, and a single-byte edit at the
   start, across a chunk boundary in the middle, or in the final unaligned tail
   is refused with [Transaction_content_changed], as is a mismatched expected
   byte length. *)
let make_multichunk_payload () =
  (* 200_005 bytes: >3x 64 KiB chunks and 5-byte non-8-aligned tail. *)
  let row = "{\"pad\":\"" ^ String.make 92 'x' ^ "\"}\n" in
  let buf = Buffer.create 200_100 in
  while Buffer.length buf < 199_990 do
    Buffer.add_string buf row
  done;
  Buffer.add_string buf "{\"tail\":\"123\"}\n";
  let payload = Buffer.contents buf in
  (* Ensure non-multiple-of-8 length to exercise both 8-byte word and tail byte loops. *)
  if String.length payload land 7 = 0
  then payload ^ "{\"t\":1}\n"
  else payload

let write_in_place_same_length path content =
  Out_channel.with_open_gen [Open_wronly; Open_binary] 0o600 path
    (fun oc -> output_string oc content)

let flip_byte s idx =
  let b = Bytes.of_string s in
  let c = Bytes.get b idx in
  Bytes.set b idx (if Char.equal c 'Z' then 'Y' else 'Z');
  Bytes.unsafe_to_string b

let test_multichunk_streaming_verify_match_and_mismatches root =
  let payload = make_multichunk_payload () in
  let len = String.length payload in
  check bool "payload spans multiple 64 KiB chunks" true (len > 196_608);
  check bool "payload has non-zero 8-byte remainder" true (len land 7 <> 0);
  let target = Filename.concat root "multichunk.jsonl" in
  let child = Filename.concat root "child.jsonl" in
  ignore (require_write (Fs.append_private_jsonl_durable_stable_result target payload));
  let expected = snapshot target in
  check int "snapshot length matches payload" len (String.length expected.bytes);
  (* 1. Exact match passes guard *)
  (match Fs.with_private_jsonl_snapshot_guard_result target ~expected ~f:(fun () -> 42) with
   | Fs.Guard_executed { value = 42; cleanup_failures = [] } -> ()
   | Fs.Guard_executed _ -> fail "multichunk exact match had unexpected result or cleanup"
   | Fs.Guard_refused failure ->
     fail (Fs.private_jsonl_transaction_error_to_string failure.guard_error));
  (* 2. Length mismatch in expected.bytes fails closed in O(1) *)
  let short_expected = { expected with bytes = String.sub expected.bytes 0 (len - 1) } in
  require_guard_refusal target require_content_mismatch
    (Fs.with_private_jsonl_snapshot_guard_result target ~expected:short_expected ~f:(record child));
  check bool "length mismatch ran no child" false (Sys.file_exists child);
  (match Fs.append_private_jsonl_durable_locked_at_snapshot_result
           target ~expected:short_expected "{\"next\":1}\n" with
   | Error err -> require_content_mismatch err
   | Ok _ -> fail "length mismatch appended unexpectedly");
  (* 3. Single-byte mutations at start (0), middle (>64 KiB), and end (unaligned tail) *)
  let mismatch_offsets = [ ("start", 0); ("middle-chunk", 70_003); ("tail-end", len - 2) ] in
  List.iter (fun (label, offset) ->
    let mutated = flip_byte payload offset in
    write_in_place_same_length target mutated;
    check bool (label ^ ": cursor unchanged after same-length edit") true
      (Fs.Private_jsonl_cursor.equal expected.cursor (snapshot target).cursor);
    require_guard_refusal target require_content_mismatch
      (Fs.with_private_jsonl_snapshot_guard_result target ~expected ~f:(record child));
    check bool (label ^ ": guard refusal ran no child") false (Sys.file_exists child);
    (match Fs.append_private_jsonl_durable_locked_at_snapshot_result
             target ~expected "{\"next\":1}\n" with
     | Error err -> require_content_mismatch err
     | Ok _ -> fail (label ^ ": snapshot append accepted mutated bytes"));
    (match Fs.rewrite_private_jsonl_durable_locked_at_snapshot_result
             target ~expected "{\"rewritten\":1}\n" with
     | Error err -> require_content_mismatch err
     | Ok _ -> fail (label ^ ": snapshot rewrite accepted mutated bytes"));
    (match Fs.purge_private_jsonl_durable_locked_at_snapshot_result target ~expected with
     | Error err -> require_content_mismatch err
     | Ok _ -> fail (label ^ ": snapshot purge accepted mutated bytes"));
    (* Restore original payload for next offset *)
    write_in_place_same_length target payload
  ) mismatch_offsets;
  (* 4. Exact match succeeds for append, rewrite, and purge at snapshot *)
  let appended_row = "{\"appended\":true}\n" in
  let cursor_after_append =
    require_write
      (Fs.append_private_jsonl_durable_locked_at_snapshot_result target ~expected appended_row)
  in
  let snap_after_append = { Fs.bytes = payload ^ appended_row; cursor = cursor_after_append } in
  let rewritten = "{\"rewritten\":true}\n" in
  let cursor_after_rewrite =
    require_write
      (Fs.rewrite_private_jsonl_durable_locked_at_snapshot_result
         target ~expected:snap_after_append rewritten)
  in
  let snap_after_rewrite = { Fs.bytes = rewritten; cursor = cursor_after_rewrite } in
  let cursor_after_purge =
    require_write
      (Fs.purge_private_jsonl_durable_locked_at_snapshot_result target ~expected:snap_after_rewrite)
  in
  check bool "purge at snapshot removes target" false (Sys.file_exists target);
  check bool "purge returns Missing cursor" true
    (Fs.Private_jsonl_cursor.is_missing cursor_after_purge)

let () =
  Printexc.record_backtrace true;
  match Array.to_list Sys.argv with
  | [_; "--compete-with-guard"; parent] -> exit (competing_writer parent)
  | _ ->
    let case name run = test_case name `Quick (with_root run) in
    run "fs_compat_snapshot_guard" ["exact parent through child IO", [
      case "stale cursor refuses before child write" test_refused_cursor;
      case "same cursor changed bytes refuses before child write" test_refused_bytes;
      case "multichunk (>64KiB) streaming verify match, start/mid/end & length mismatch"
        test_multichunk_streaming_verify_match_and_mismatches;
      case "separate process writer excluded through child write" test_separate_process_excluded;
      case "known child survives reserved guard cleanup" test_known_child_cleanup;
      case "unknown child and reserved guard cleanup both survive" test_unknown_child_cleanup
    ]; "dependency append", [
      case "dependency with the target's spelling is refused" test_dependency_same_spelling;
      case "dependency spelled through ./ is refused" test_dependency_dot_spelling;
      case "dependency through a symlinked directory is refused"
        test_dependency_through_symlinked_directory;
      case "trailing separator on a missing target is refused"
        test_dependency_trailing_separator_on_missing_target;
      case "distinct dependency appends" test_dependency_distinct_file_appends;
      case "uninspectable dependency lock entry refuses inside"
        test_dependency_lock_entry_not_inspectable
    ]]
