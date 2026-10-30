open Alcotest
module Pending = Masc_tui_artifact_share_pending
module Share = Masc.Published_artifact_share
let require = function Ok value -> value | Error detail -> fail detail
let rec remove path =
  if Sys.is_directory path then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path
let fixture run =
  let base = Filename.temp_file "tui-artifact-share" ".fixture" in
  Sys.remove base; Unix.mkdir base 0o700;
  let root = Filename.concat base ".masc" in
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove base) (fun () -> run base root (Filename.concat root "pending.jsonl"))
let entry base root : Pending.entry =
  let request : Share.request = {
    operation_id="01890e2a-4c8e-7b21-9f3c-000000000031"; expected_version=5;
    requested=true; expected_artifact_revision=3; expected_artifact_sha256=String.make 64 'a' } in
  {base_path=base;masc_root=root;artifact_id="artifact-0123456789abcdef0123456789abcdef";request}

let restart_and_exact_retirement () = fixture (fun base root path ->
  let original = entry base root in
  (match Unix.fork () with
   | 0 -> (match Pending.prepare ~path original with Ok () -> exit 0 | Error _ -> exit 1)
   | child -> let _, status = Unix.waitpid [] child in
     check bool "original process recorded intent before exit" true (status = Unix.WEXITED 0));
  check bool "new process recovers the full original tuple" true (require (Pending.read ~path ()) = [original]);
  check bool "recovery confirms the original tuple durably" true (require (Pending.confirm ~path original));
  let replacement = {original with request={original.request with
    operation_id="01890e2a-4c8e-7b21-9f3c-000000000032"}} in
  check bool "another operation for this artifact is refused" true
    (Result.is_error (Pending.prepare ~path replacement));
  check bool "a different tuple cannot retire the original" false (require (Pending.settle ~path replacement));
  check bool "exact original acknowledgement retires it" true (require (Pending.settle ~path original));
  require (Pending.prepare ~path replacement);
  check bool "late original acknowledgement preserves the new operation" false (require (Pending.settle ~path original));
  check bool "new operation remains intact" true (require (Pending.read ~path ()) = [replacement]))

let restore_missing_intent () = fixture (fun base root path ->
  let original = entry base root in
  require (Pending.prepare ~path original);
  Sys.remove path;
  require (Pending.restore ~path original);
  check bool "missing journal restores the exact original request" true (require (Pending.read ~path ()) = [original]);
  require (Pending.restore ~path original);
  check bool "confirming an existing request does not duplicate it" true (require (Pending.read ~path ()) = [original]);
  let other = {original with request={original.request with
    operation_id="01890e2a-4c8e-7b21-9f3c-000000000032"}} in
  let observed = Atomic.make [] in
  (match require (Pending.prepare_checked ~on_observed:(Atomic.set observed) ~path other) with
   | Pending.Already_pending existing -> check bool "the actual blocking operation is returned" true (existing = original)
   | Pending.Prepared | Pending.Not_prepared _ | Pending.Already_pending_with_storage_failure _ ->
     fail "a second request was incorrectly prepared or failed unexpectedly");
  check bool "the blocking request was witnessed inside the transaction" true (Atomic.get observed = [original]);
  check bool "a different pending request blocks recovery dispatch" true
    (Result.is_error (Pending.restore ~path other));
  check bool "refused recovery leaves the original pending" true (require (Pending.read ~path ()) = [original]))

let corruption_and_validation () = fixture (fun base root path ->
  let original = entry base root in
  let invalid = {original with request={original.request with expected_artifact_sha256="bad"}} in
  check bool "invalid intent cannot be published" true (Result.is_error (Pending.prepare ~path invalid));
  require (Pending.prepare ~path original);
  Out_channel.with_open_gen [Open_wronly; Open_append; Open_binary] 0o600 path
    (fun out -> output_string out "{torn");
  check bool "a torn tail preserves the complete original pending entry" true
    (require (Pending.read ~path ()) = [original]);
  check bool "recovered original still prevents a replacement" true (Result.is_error (Pending.prepare ~path original));
  Out_channel.with_open_gen [Open_wronly; Open_append; Open_binary] 0o600 path
    (fun out -> output_string out "{malformed}\n{torn");
  check bool "a malformed complete event fails closed" true (Result.is_error (Pending.read ~path ()));
  check bool "corruption cannot authorize another mutation" true (Result.is_error (Pending.prepare ~path original)))

let distinct_resources () = fixture (fun base root path ->
  let original = entry base root in
  let other = {original with artifact_id="artifact-ffffffffffffffffffffffffffffffff"} in
  require (Pending.prepare ~path original);
  require (Pending.prepare ~path other);
  check int "another artifact has its own recovery entry" 2 (List.length (require (Pending.read ~path ())));
  check bool "retiring one leaves the other" true (require (Pending.settle ~path original));
  check bool "other entry survives" true (require (Pending.read ~path ()) = [other]))

let overlap_marker () = fixture (fun base root path ->
  let original = entry base root in
  let before, empty = require (Pending.observe ~path ()) in
  check bool "no operation initially" true (empty = []);
  require (Pending.prepare ~path original);
  check bool "the prepared operation settles" true (require (Pending.settle ~path original));
  let after, empty_again = require (Pending.observe ~path ()) in
  check bool "a completed overlapping operation leaves an observable change" false (Pending.same_cursor after before);
  check bool "the later pending list is empty" true (empty_again = []))

let replaced_empty_journal_changes_cursor () = fixture (fun base root path ->
  let before, empty = require (Pending.observe ~path ()) in
  check bool "new journal begins empty" true (empty = []);
  require (Pending.prepare ~path (entry base root));
  Unix.rename path (path ^ ".displaced");
  let after, empty_again = require (Pending.observe ~path ()) in
  check bool "replacement journal is empty" true (empty_again = []);
  check bool "a replaced empty journal has a different identity" false (Pending.same_cursor before after);
  let stable, _ = require (Pending.observe ~path ()) in
  check bool "reading the same empty journal leaves its cursor stable" true (Pending.same_cursor after stable))

let observation_survives_path_replacement () = fixture (fun base root path ->
  let original = entry base root in
  require (Pending.prepare ~path original);
  let observed = Atomic.make [] and replaced = ref false in
  let on_observed entries =
    Atomic.set observed entries;
    if not !replaced then begin
      replaced := true;
      Unix.rename path (path ^ ".displaced");
      let fd = Unix.openfile path [Unix.O_CREAT; Unix.O_WRONLY; Unix.O_EXCL] 0o600 in
      Unix.close fd
    end in
  check bool "a replaced pathname fails the read" true
    (Result.is_error (Pending.observe ~on_observed ~path ()));
  check bool "the observed request survives the failed read" true (Atomic.get observed = [original]))

let concurrent_prepare () = fixture (fun base root path ->
  let first = entry base root in
  let second = {first with request={first.request with
    operation_id="01890e2a-4c8e-7b21-9f3c-000000000032"}} in
  let read_gate, write_gate = Unix.pipe () in
  let spawn candidate = match Unix.fork () with
    | 0 ->
      Unix.close write_gate;
      let byte = Bytes.create 1 in
      ignore (Unix.read read_gate byte 0 1);
      (match Pending.prepare ~path candidate with Ok () -> exit 0 | Error _ -> exit 2)
    | child -> child in
  let a = spawn first and b = spawn second in
  Unix.close read_gate;
  ignore (Unix.write write_gate (Bytes.of_string "xx") 0 2);
  Unix.close write_gate;
  let _, a_status = Unix.waitpid [] a and _, b_status = Unix.waitpid [] b in
  check bool "exactly one process owns the artifact operation" true
    ((a_status = Unix.WEXITED 0 && b_status = Unix.WEXITED 2)
     || (a_status = Unix.WEXITED 2 && b_status = Unix.WEXITED 0));
  let entries = require (Pending.read ~path ()) in
  check bool "the surviving complete tuple belongs to a contender" true
    (entries = [first] || entries = [second]))

let locked_journal_fails_closed () = fixture (fun _base _root path ->
  let fd = Unix.openfile path [Unix.O_RDWR; Unix.O_CREAT] 0o600 in
  Unix.close fd;
  let ready_r, ready_w = Unix.pipe () and release_r, release_w = Unix.pipe () in
  let signal fd = ignore (Unix.write fd (Bytes.of_string "x") 0 1) in
  let await fd = let bytes = Bytes.create 1 in ignore (Unix.read fd bytes 0 1) in
  let child = match Unix.fork () with
    | 0 ->
      Unix.close ready_r; Unix.close release_w;
      let fd = Unix.openfile path [Unix.O_RDWR] 0o600 in
      Unix.lockf fd Unix.F_LOCK 0;
      signal ready_w;
      let readable, _, _ = Unix.select [release_r] [] [] 5. in
      if readable = [] then exit 2;
      await release_r; Unix.lockf fd Unix.F_ULOCK 0; Unix.close fd; exit 0
    | pid -> pid in
  Unix.close ready_w; Unix.close release_r; await ready_r; Unix.close ready_r;
  let rec reap () =
    match Unix.waitpid [] child with
    | result -> result
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap () in
  Fun.protect ~finally:(fun () ->
    Unix.close release_w;
    ignore (reap ())) (fun () ->
    Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
    let finished, finish = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve finish (Pending.observe ~path ()));
    let observed = Eio.Fiber.first
      (fun () -> `Finished (Eio.Promise.await finished))
      (fun () -> Eio.Time.sleep env#clock 1.; `Timed_out) in
    check bool "a busy journal fails closed without waiting for the lock" true
      (match observed with `Finished (Error _) -> true | `Finished (Ok _) | `Timed_out -> false);
    signal release_w;
    ()))

let () = run "TUI durable artifact sharing intent" ["journal", [
  test_case "process restart and exact retirement" `Quick restart_and_exact_retirement;
  test_case "restore a missing original intent" `Quick restore_missing_intent;
  test_case "corruption and validation fail closed" `Quick corruption_and_validation;
  test_case "distinct artifacts" `Quick distinct_resources;
  test_case "a completed overlap changes the marker" `Quick overlap_marker;
  test_case "replacing an empty journal changes its cursor" `Quick replaced_empty_journal_changes_cursor;
  test_case "failed read retains its observed request" `Quick observation_survives_path_replacement;
  test_case "competing processes admit one intent" `Quick concurrent_prepare;
  test_case "a locked journal fails closed without waiting" `Quick locked_journal_fails_closed
]]
