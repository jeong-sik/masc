open Alcotest
module Fs = Fs_compat

let with_root f =
  let root = Filename.temp_dir "owned-private-jsonl-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs.remove_tree root) (fun () -> f root)

let write path bytes =
  Out_channel.with_open_gen [Open_wronly; Open_creat; Open_trunc; Open_binary]
    0o600 path (fun output -> output_string output bytes)

let error_message = function
  | Fs.Owned_admission_failed {error; _} -> Fs.owned_regular_file_read_error_to_string error
  | Owned_private_permissions_required {actual; _} -> Printf.sprintf "nonprivate mode %o" actual
  | Owned_transaction_failed error -> Fs.private_jsonl_transaction_error_to_string error

let require = function Ok value -> value | Error error -> fail (error_message error)
let io = Fs.{before_sync_parent = ignore; close_fd = Unix.close}
let read root path = Fs.read_owned_private_jsonl_durable_locked_result
    ~owner_uid:(Unix.geteuid ()) ~ownership_root:root ~permissions:Fs.Owned_regular
    path ~after:None

let mutex_held path =
  check bool "canonical data mutex held at actual admission/transaction boundary"
    false (Fs.Owned_private_jsonl_for_testing.path_mutex_available path)

let test_admission_and_cold_reads () = with_root (fun root ->
  let path = Filename.concat root "record" in
  let spelling = Filename.concat root "./record" in
  let inspected = Atomic.make 0 and initialized = Atomic.make 0 in
  let parent_lstat parent =
    mutex_held path; mutex_held spelling;
    ignore (Atomic.fetch_and_add inspected 1 : int);
    Unix.lstat parent in
  let initial_io = Fs.{io with before_sync_parent = (fun _ ->
    mutex_held path;
    ignore (Atomic.fetch_and_add initialized 1 : int))} in
  let snapshot = Fs.Owned_private_jsonl_for_testing.read ~parent_lstat ~io:initial_io
    ~owner_uid:(Unix.geteuid ()) ~ownership_root:root ~permissions:Fs.Owned_regular
    spelling ~after:None |> require in
  check bool "cold read observes missing data" true (Fs.Private_jsonl_cursor.is_missing snapshot.cursor);
  check int "data and lock admission both entered" 2 (Atomic.get inspected);
  check int "actual lock initialization entered once" 1 (Atomic.get initialized);
  check bool "mutex released after settlement" true
    (Fs.Owned_private_jsonl_for_testing.path_mutex_available path);
  let cold = Filename.concat root "concurrent" in
  Eio.Fiber.both
    (fun () -> ignore (read root cold |> require : Fs.private_jsonl_snapshot))
    (fun () -> ignore (read root (Filename.concat root "./concurrent") |> require : Fs.private_jsonl_snapshot));
  check string "concurrent first reads retain one ready lock" "\xA5"
    (Fs.load_file (Fs.private_jsonl_lock_path cold)))

let test_refusal_before_effects () = with_root (fun root ->
  let unsafe = Filename.concat root "unsafe" in
  Unix.mkdir unsafe 0o777; Unix.chmod unsafe 0o777;
  let denied = Filename.concat unsafe "missing/record" in
  (match read root denied with
   | Error (Fs.Owned_admission_failed {role=Owned_data; error={failure=Owned_path_writable_by_others _;_}}) -> ()
   | Error error -> fail (error_message error)
   | Ok _ -> fail "unsafe parent accepted");
  check bool "refusal precedes mkdir" false (Sys.file_exists (Filename.dirname denied));
  Unix.chmod unsafe 0o700;
  let alias = Filename.concat root "alias" in
  Unix.symlink unsafe alias;
  (match read root (Filename.concat alias "missing/record") with
   | Error (Fs.Owned_admission_failed _) -> ()
   | Error error -> fail (error_message error)
   | Ok _ -> fail "parent alias accepted");
  check bool "alias refusal creates no target directory" false (Sys.file_exists (Filename.dirname denied));
  List.iter (fun role ->
    let path = Filename.concat root (match role with Fs.Owned_data -> "data" | Owned_stable_lock -> "lock") in
    let leaf = match role with Fs.Owned_data -> path | Owned_stable_lock -> Fs.private_jsonl_lock_path path in
    write leaf "unread admission bytes"; Unix.chmod leaf 0o640;
    (match Fs.read_owned_private_jsonl_durable_locked_result ~owner_uid:(Unix.geteuid ())
       ~ownership_root:root ~permissions:Fs.Private_0600 path ~after:None with
     | Error (Fs.Owned_private_permissions_required {role=actual_role; path=actual_path; actual}) ->
       check bool "correct permission role" true (role=actual_role);
       check string "correct permission leaf" leaf actual_path;
       check int "mode is not repaired" 0o640 actual
     | Error error -> fail (error_message error)
     | Ok _ -> fail "nonprivate leaf accepted");
    check string "rejected data/marker bytes unchanged" "unread admission bytes" (Fs.load_file leaf);
    if role=Fs.Owned_data then check bool "no lock creation before data permission check" false
      (Sys.file_exists (Fs.private_jsonl_lock_path path))) [Fs.Owned_data; Owned_stable_lock])

let test_rogue_marker_change_stays_refused () = with_root (fun root ->
  let path = Filename.concat root "record" in
  let lock = Fs.private_jsonl_lock_path path in
  write lock "";
  let visits = ref 0 and injected = ref false in
  let parent_lstat parent =
    incr visits;
    if !visits=3 then (write lock "\xA5"; injected:=true);
    Unix.lstat parent in
  (match Fs.Owned_private_jsonl_for_testing.read ~parent_lstat ~io
     ~owner_uid:(Unix.geteuid ()) ~ownership_root:root ~permissions:Fs.Owned_regular
     path ~after:None with
   | Error (Fs.Owned_admission_failed {role=Owned_stable_lock;error={failure=Filesystem_identity_changed _;_}}) -> ()
   | Error error -> fail (error_message error)
   | Ok _ -> fail "uncoordinated mutation was silently accepted");
  check bool "marker really changed during observation" true !injected)

let lock_probe path =
  let fd = Unix.openfile path [Unix.O_RDWR; Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    match Unix.lockf fd Unix.F_TLOCK 0 with
    | () -> 0
    | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> 42)

let run_child_if_requested () =
  match Sys.argv with
  | [|_; "--owned-lock-probe"; path|] -> exit (lock_probe path)
  | _ -> ()

let rec wait_for_child pid =
  match Unix.waitpid [] pid with
  | status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_for_child pid

let contender path =
  let pid = Unix.create_process Sys.executable_name
      [|Sys.executable_name; "--owned-lock-probe"; path|]
      Unix.stdin Unix.stdout Unix.stderr in
  match wait_for_child pid with
  | _, Unix.WEXITED code -> code
  | _, (Unix.WSIGNALED signal | Unix.WSTOPPED signal) -> failf "lock probe signal %d" signal

let test_stable_lock_exclusion_and_settlement () = with_root (fun root ->
  let path = Filename.concat root "record" in
  write path "{}\n";
  let lock = Fs.private_jsonl_lock_path path in
  let initialized = Atomic.make 0 and settled = Atomic.make 0 in
  let checked_io = Fs.{
    before_sync_parent=(fun _ ->
      ignore (Atomic.fetch_and_add initialized 1 : int);
      mutex_held path;
      check int "real process excluded during initialization" 42 (contender lock));
    close_fd=(fun fd ->
      let stats = Unix.fstat fd and lock_stats = Unix.lstat lock in
      if stats.st_dev=lock_stats.st_dev && stats.st_ino=lock_stats.st_ino then (
        ignore (Atomic.fetch_and_add settled 1 : int);
        mutex_held path;
        check int "real process excluded until stable descriptor closes" 42 (contender lock));
      Unix.close fd)} in
  let snapshot = Fs.Owned_private_jsonl_for_testing.read ~parent_lstat:Unix.lstat ~io:checked_io
      ~owner_uid:(Unix.geteuid ()) ~ownership_root:root ~permissions:Fs.Owned_regular
      path ~after:None |> require in
  check string "authoritative bytes" "{}\n" snapshot.bytes;
  check int "initialization boundary entered" 1 (Atomic.get initialized);
  check int "stable close boundary entered" 1 (Atomic.get settled);
  check int "real process enters after settlement" 0 (contender lock))

let test_hardlinks_do_not_release_another_lock () = with_root (fun root ->
  let held = Filename.concat root "held.lock" in
  write held "\xA5";
  let fd = Unix.openfile held [Unix.O_RDWR; Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    Unix.lockf fd Unix.F_LOCK 0;
    List.iter (fun role ->
      let path = Filename.concat root "candidate" in
      let alias = match role with Fs.Owned_data -> path | Owned_stable_lock -> Fs.private_jsonl_lock_path path in
      Unix.link held alias;
      Fun.protect ~finally:(fun () -> Unix.unlink alias) (fun () ->
        check int "other path initially retains its lock" 42 (contender held);
        (match read root path with
         | Error (Fs.Owned_admission_failed {role=actual;
             error={failure=Owned_file_operation_failed
               {operation=Inspect_descriptor;cause=Sys_error _;_};_}}) ->
           check bool "aliased role refused before independent open" true (role=actual)
         | Error error -> fail (error_message error)
         | Ok _ -> fail "hardlinked lock alias accepted");
        check int "rejected alias did not close away another path's lock" 42 (contender held)))
      [Fs.Owned_data; Owned_stable_lock]))

let test_authoritative_read_errors () = with_root (fun root ->
  let path = Filename.concat root "record" in
  write path "{}\n";
  let old = read root path |> require in
  let replacement = Filename.concat root "replacement" in
  write replacement "{\"new\":true}\n"; Unix.rename replacement path;
  (match Fs.read_owned_private_jsonl_durable_locked_result ~owner_uid:(Unix.geteuid ())
     ~ownership_root:root ~permissions:Fs.Owned_regular path ~after:(Some old.cursor) with
   | Error (Fs.Owned_transaction_failed (Cursor_mismatch _)) -> ()
   | Error error -> fail (error_message error)
   | Ok _ -> fail "replacement silently became a full read");
  write path "torn tail";
  (match read root path with
   | Error (Fs.Owned_transaction_failed (Incomplete_transaction_tail _)) -> ()
   | Error error -> fail (error_message error)
   | Ok _ -> fail "observation repaired incomplete tail");
  check string "torn source untouched" "torn tail" (Fs.load_file path))

exception Cancel_owned_read
type cancelled_read =
  | Read_cancelled
  | Read_returned of (Fs.private_jsonl_snapshot, Fs.owned_private_jsonl_read_error) result

let test_cancellation_settles_before_escape () = with_root (fun root ->
  let path = Filename.concat root "record" in
  write path "{}\n";
  let entered, resolve_entered = Eio.Promise.create () in
  let context, resolve_context = Eio.Promise.create () in
  let outcome, resolve_outcome = Eio.Promise.create () in
  let mutex = Stdlib.Mutex.create () and condition = Stdlib.Condition.create () in
  let released = ref false and visits = Atomic.make 0 and closes = Atomic.make 0 in
  let release () = Stdlib.Mutex.protect mutex (fun () ->
    released := true; Stdlib.Condition.broadcast condition) in
  let parent_lstat parent =
    if Atomic.fetch_and_add visits 1 = 1 then (
      Eio.Promise.resolve resolve_entered ();
      Stdlib.Mutex.protect mutex (fun () ->
        while not !released do Stdlib.Condition.wait condition mutex done));
    Unix.lstat parent in
  let checked_io = Fs.{io with close_fd=(fun fd ->
    Unix.close fd; ignore (Atomic.fetch_and_add closes 1 : int))} in
  Eio.Switch.run (fun sw ->
      Eio.Fiber.fork ~sw (fun () ->
        let result = try Eio.Cancel.sub (fun cancel ->
          Eio.Promise.resolve resolve_context cancel;
          Read_returned (Fs.Owned_private_jsonl_for_testing.read ~parent_lstat ~io:checked_io
            ~owner_uid:(Unix.geteuid ()) ~ownership_root:root ~permissions:Fs.Owned_regular
            path ~after:None)) with Eio.Cancel.Cancelled _ -> Read_cancelled in
        Eio.Promise.resolve resolve_outcome result);
      Fun.protect ~finally:release (fun () ->
        let cancel = Eio.Promise.await context in
        let did_enter = Eio.Fiber.first
          (fun () -> Eio.Promise.await entered; true)
          (fun () -> ignore (Eio.Promise.await outcome : cancelled_read); false) in
        check bool "worker entered the descriptor admission boundary" true did_enter;
        Eio.Cancel.cancel cancel Cancel_owned_read;
        release ();
        match Eio.Promise.await outcome with
        | Read_cancelled -> ()
        | Read_returned (Error error) -> fail (error_message error)
        | Read_returned (Ok _) -> fail "cancelled observation returned a result"));
  check int "worker settled both transaction descriptors before cancellation escaped" 2 (Atomic.get closes);
  check bool "cancelled observation released data mutex" true
    (Fs.Owned_private_jsonl_for_testing.path_mutex_available path);
  check int "cancelled observation released stable lock" 0 (contender (Fs.private_jsonl_lock_path path));
  check string "cancellation did not change data" "{}\n" (Fs.load_file path))

let cases = [
  test_case "admission owns the canonical mutex before cold initialization" `Quick test_admission_and_cold_reads;
  test_case "policy refusal precedes preparation and body reads" `Quick test_refusal_before_effects;
  test_case "uncoordinated marker mutation remains an identity error" `Quick test_rogue_marker_change_stays_refused;
  test_case "stable lock excludes real processes until settlement" `Quick test_stable_lock_exclusion_and_settlement;
  test_case "hardlinked admission cannot release another path lock" `Quick test_hardlinks_do_not_release_another_lock;
  test_case "cursor and torn-tail failures retain authoritative semantics" `Quick test_authoritative_read_errors;
  test_case "cancellation escapes only after worker settlement" `Quick test_cancellation_settles_before_escape;
]
