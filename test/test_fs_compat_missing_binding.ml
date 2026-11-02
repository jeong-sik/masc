(** Stable transactions must distinguish genuine absence from a dangling leaf.
    Every conditional-write fixture obtains its Missing snapshot from a real
    stable read before installing the actual symlink. *)

open Alcotest
module Fs = Fs_compat

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_root operation () =
  let root = Unix.realpath (Filename.temp_dir "fs-missing-binding-" "") in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> operation root)

let absent path =
  match Unix.lstat path with
  | _ -> false
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true

let read path = In_channel.with_open_bin path In_channel.input_all

let entries path = Sys.readdir path |> Array.to_list |> List.sort String.compare

let require_snapshot result =
  match Fs.private_jsonl_snapshot_success_receipt result with
  | Ok { value; settlement_error = None } -> value
  | Ok { settlement_error = Some error; _ } | Error error ->
    fail (Fs.private_jsonl_transaction_error_to_string error)

let snapshot path =
  Fs.read_private_jsonl_durable_locked_result path ~after:None |> require_snapshot

let require_missing (observed : Fs.private_jsonl_snapshot) =
  check bool "actual snapshot says Missing" true
    (Fs.Private_jsonl_cursor.is_missing observed.cursor);
  check string "actual Missing has no bytes" "" observed.bytes

let lock_state path =
  let lock = Fs.private_jsonl_lock_path path in
  let stat = Unix.lstat lock in
  stat.Unix.st_dev, stat.Unix.st_ino, stat.Unix.st_nlink,
  stat.Unix.st_perm, stat.Unix.st_size, read lock

let link_state path =
  let stat = Unix.lstat path in
  stat.Unix.st_dev, stat.Unix.st_ino, stat.Unix.st_kind,
  stat.Unix.st_nlink, stat.Unix.st_perm, Unix.readlink path

type dangling_fixture = {
  root : string;
  path : string;
  target : string;
  expected : Fs.private_jsonl_snapshot;
  original_link : int * int * Unix.file_kind * int * int * string;
  original_lock : int * int * int * int * int * string;
  original_entries : string list;
}

let install_dangling root =
  let path = Filename.concat root "posts.jsonl" in
  let expected = snapshot path in
  require_missing expected;
  check bool "stable Missing observation created no payload" true (absent path);
  let target = Filename.concat root "external-target.jsonl" in
  Unix.symlink target path;
  { root; path; target; expected;
    original_link = link_state path;
    original_lock = lock_state path;
    original_entries = entries root }

let check_preserved fixture =
  check bool "dangling link inode, kind, mode and destination survive" true
    (fixture.original_link = link_state fixture.path);
  check bool "external target remains actually absent" true (absent fixture.target);
  check bool "ready stable lock identity, mode and bytes survive" true
    (fixture.original_lock = lock_state fixture.path);
  check (list string) "no stage or additional file is left behind"
    fixture.original_entries (entries fixture.root)

let require_alias_refusal = function
  | Error (Fs.Unexpected_transaction_file_kind Unix.S_LNK) -> ()
  | Error error -> fail (Fs.private_jsonl_transaction_error_to_string error)
  | Ok _ -> fail "dangling leaf was accepted as Missing or a writable regular file"

let test_missing_and_empty root =
  let path = Filename.concat root "posts.jsonl" in
  let missing = snapshot path in
  require_missing missing;
  check bool "stable read does not create the missing payload" true (absent path);
  let recovered = Fs.recover_private_jsonl_durable_locked_result path |> require_snapshot in
  require_missing recovered;
  let created =
    match Fs.rewrite_private_jsonl_durable_locked_at_snapshot_result path ~expected:missing ""
          |> Fs.private_jsonl_cursor_success_receipt with
    | Ok { value; settlement_error = None } -> value
    | Ok { settlement_error = Some error; _ } | Error error ->
      fail (Fs.private_jsonl_transaction_error_to_string error) in
  check bool "genuine Missing CAS creates a real Present cursor" false
    (Fs.Private_jsonl_cursor.is_missing created);
  Unix.chmod path 0o640;
  let before = Unix.lstat path in
  let empty = snapshot path in
  check bool "present empty is not Missing" false
    (Fs.Private_jsonl_cursor.is_missing empty.cursor);
  check bool "Missing and present empty have distinct actual cursors" false
    (Fs.Private_jsonl_cursor.equal missing.cursor empty.cursor);
  check bool "created receipt matches the actual empty payload" true
    (Fs.Private_jsonl_cursor.equal created empty.cursor);
  check string "present empty has no rows" "" empty.bytes;
  let after = Unix.lstat path in
  check (pair int int) "empty payload inode remains in place"
    (before.Unix.st_dev, before.Unix.st_ino) (after.Unix.st_dev, after.Unix.st_ino);
  check int "empty payload mode is not repaired by reading" 0o640 after.Unix.st_perm;
  check (list string) "only payload and stable sibling exist"
    (List.sort String.compare [Filename.basename path; Filename.basename (Fs.private_jsonl_lock_path path)])
    (entries root)

let test_read root =
  let fixture = install_dangling root in
  require_alias_refusal
    (Fs.read_private_jsonl_durable_locked_result fixture.path ~after:None);
  require_alias_refusal
    (Fs.read_private_jsonl_durable_locked_result fixture.path ~after:(Some fixture.expected.cursor));
  check_preserved fixture

let test_recover root =
  let fixture = install_dangling root in
  require_alias_refusal (Fs.recover_private_jsonl_durable_locked_result fixture.path);
  check_preserved fixture

type mutation =
  | Stable_append
  | Observed_append
  | Cursor_append
  | Snapshot_append
  | Cursor_rewrite
  | Snapshot_rewrite
  | Purge
  | Snapshot_purge

let mutate kind fixture =
  let suffix = "{\"row\":1}\n" in
  match kind with
  | Stable_append -> Fs.append_private_jsonl_durable_stable_result fixture.path suffix
  | Observed_append ->
    Fs.append_private_jsonl_durable_observed_result fixture.path suffix |> Result.map fst
  | Cursor_append -> Fs.append_private_jsonl_durable_locked_at_cursor_result
      fixture.path ~expected:fixture.expected.cursor suffix
  | Snapshot_append -> Fs.append_private_jsonl_durable_locked_at_snapshot_result
      fixture.path ~expected:fixture.expected suffix
  | Cursor_rewrite -> Fs.rewrite_private_jsonl_durable_locked_at_cursor_result
      fixture.path ~expected:fixture.expected.cursor suffix
  | Snapshot_rewrite -> Fs.rewrite_private_jsonl_durable_locked_at_snapshot_result
      fixture.path ~expected:fixture.expected suffix
  | Purge -> Fs.purge_private_jsonl_durable_locked_result fixture.path
  | Snapshot_purge -> Fs.purge_private_jsonl_durable_locked_at_snapshot_result
      fixture.path ~expected:fixture.expected

let test_mutation kind root =
  let fixture = install_dangling root in
  require_alias_refusal (mutate kind fixture);
  check_preserved fixture

type close_failure = Ordinary | Timeout | Nested_timeout

let failure_exception = function
  | Ordinary -> Failure "ordinary stable-lock close"
  | Timeout -> Eio.Time.Timeout
  | Nested_timeout ->
    let backtrace = Printexc.get_callstack 16 in
    fst (Eio.Exn.combine
      (Failure "ordinary close member", backtrace) (Eio.Time.Timeout, backtrace))

let check_backtrace_origin captured actual =
  let expected = match !captured with
    | Some backtrace -> backtrace
    | None -> fail "actual close never captured its raising backtrace" in
  let length = Printexc.raw_backtrace_length expected in
  check bool "actual raising origin has frames" true (length > 0);
  check bool "cleanup retains all original raising frames" true
    (Printexc.raw_backtrace_length actual >= length);
  for index = 0 to length - 1 do
    check bool "cleanup retains the original frame prefix" true
      (Printexc.get_raw_backtrace_slot expected index
       = Printexc.get_raw_backtrace_slot actual index)
  done

let test_close_failure kind root =
  let fixture = install_dangling root in
  let failure = failure_exception kind in
  let captured = ref None and closes = ref 0 and syncs = ref 0 in
  let io : Fs.private_jsonl_transaction_io_for_testing = {
    before_sync_parent = (fun _ -> incr syncs);
    close_fd = (fun descriptor ->
      incr closes;
      Unix.close descriptor;
      try raise failure with exception_ ->
        let backtrace = Printexc.get_raw_backtrace () in
        captured := Some backtrace;
        Printexc.raise_with_backtrace exception_ backtrace);
  } in
  (* Fs retains direct/nested reserved close failures as typed cleanup evidence.
     Its consumer decides when to propagate them; this fixture adds no finish
     shim or fabricated successful transaction. *)
  let result = Fs.rewrite_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
      ~io fixture.path ~expected:fixture.expected "{\"row\":1}\n" in
  (match result with
   | Error (Fs.Transaction_settlement_failed {
       primary = Fs.Transaction_failed (Fs.Unexpected_transaction_file_kind Unix.S_LNK);
       cleanup_failures = [diagnostic] }) ->
     check bool "cleanup belongs to the actual stable-lock descriptor" true
       (diagnostic.operation = Fs.Close_stable_lock);
     check bool "original ordinary or reserved exception remains attached" true
       (diagnostic.exception_ == failure);
     check_backtrace_origin captured diagnostic.backtrace
   | Error error -> fail (Fs.private_jsonl_transaction_error_to_string error)
   | Ok _ -> fail "alias refusal plus cleanup became a successful rewrite");
  (match Fs.private_jsonl_cursor_success_receipt result with
   | Error _ -> ()
   | Ok _ -> fail "alias refusal fabricated a Cursor_succeeded receipt");
  check int "only the owned stable-lock descriptor was closed" 1 !closes;
  check int "ready lock and refusal trigger no parent-sync hook" 0 !syncs;
  check_preserved fixture;
  (* The same path remains usable after the real descriptor was closed and its
     process mutex released, without retrying or clearing the failed write. *)
  require_alias_refusal (Fs.read_private_jsonl_durable_locked_result fixture.path ~after:None);
  check_preserved fixture;
  Unix.unlink fixture.path;
  require_missing (snapshot fixture.path);
  check bool "later genuine absence creates no payload" true (absent fixture.path);
  check bool "external target is still absent" true (absent fixture.target)

let () =
  Printexc.record_backtrace true;
  let case name test = test_case name `Quick (with_root test) in
  run "fs_compat_missing_binding" [
    "actual absence", [
      case "genuine Missing and present empty remain distinct" test_missing_and_empty;
      case "stable reads refuse a dangling leaf" test_read;
      case "recovery refuses a dangling leaf" test_recover ];
    "real Missing preconditions", [
      case "unchecked stable append preserves dangling leaf" (test_mutation Stable_append);
      case "observed stable append preserves dangling leaf" (test_mutation Observed_append);
      case "cursor append preserves dangling leaf" (test_mutation Cursor_append);
      case "snapshot append preserves dangling leaf" (test_mutation Snapshot_append);
      case "cursor rewrite refuses through current cursor" (test_mutation Cursor_rewrite);
      case "snapshot rewrite preserves dangling leaf" (test_mutation Snapshot_rewrite);
      case "purge preserves dangling leaf" (test_mutation Purge);
      case "snapshot purge preserves dangling leaf" (test_mutation Snapshot_purge) ];
    "actual stable-lock settlement", [
      case "ordinary close keeps alias refusal primary" (test_close_failure Ordinary);
      case "timeout close keeps typed primary and original frames" (test_close_failure Timeout);
      case "nested timeout close keeps original exception evidence" (test_close_failure Nested_timeout) ] ]
