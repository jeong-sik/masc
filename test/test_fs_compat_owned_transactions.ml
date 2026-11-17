open Alcotest
module Fs = Fs_compat

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = (Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK); _ } ->
    Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_root f () =
  let root = Unix.realpath (Filename.temp_dir "owned-transactions-" "") in
  Unix.chmod root 0o700;
  Fun.protect ~finally:(fun () -> Unix.chmod root 0o700; remove_tree root)
    (fun () -> f root (Filename.concat root "data"))

let write path bytes =
  Out_channel.with_open_bin path (fun channel -> output_string channel bytes);
  Unix.chmod path 0o600

let read path = In_channel.with_open_bin path In_channel.input_all
let entries root = Sys.readdir root |> Array.to_list |> List.sort String.compare
let available path = Fs.Owned_private_file_for_testing.path_mutex_available path
let owned_read root path =
  Fs.load_owned_regular_file_with_snapshot_locked ~owner_uid:(Unix.getuid ())
    ~ownership_root:root path

let require_present = function
  | Ok (Some value) -> value
  | Ok None -> fail "owned file unexpectedly absent"
  | Error error -> fail (Fs.owned_regular_file_read_error_to_string error)

let require_success = function
  | Fs.Private_file_succeeded value -> value
  | Fs.Private_file_succeeded_with_cleanup_failure _ -> fail "unexpected cleanup failure"
  | Fs.Private_file_failed _ | Fs.Private_file_failed_with_cleanup_failure _ ->
    fail "unexpected update failure"

let require_failure = function
  | Fs.Private_file_failed error -> error
  | Fs.Private_file_failed_with_cleanup_failure _ -> fail "unexpected cleanup failure"
  | Fs.Private_file_succeeded _ | Fs.Private_file_succeeded_with_cleanup_failure _ ->
    fail "expected update refusal"

let require_owned_error = function
  | Fs.Owned_observation_failed error -> error
  | Fs.Underlying_update_failed _ -> fail "expected owned observation refusal"

let require_read_error = function
  | Error error -> error
  | Ok _ -> fail "expected owned read refusal"

let unsafe_parent (error : Fs.owned_regular_file_read_error) =
  match error.failure with
  | Fs.Owned_path_writable_by_others _ -> true
  | Fs.Ownership_boundary_rejected _ | Fs.Path_is_not_regular_file _
  | Fs.Filesystem_identity_changed _ | Fs.Owned_path_owner_mismatch _
  | Fs.Owned_file_operation_failed _ -> false

(* The probe is a fresh exec, not a fork of an Eio worker domain. A separate
   process sees the real POSIX lock; try-locking in this process cannot. *)
let lock_probe_child path =
  let rec loop () =
    match input_char stdin with
    | 'q' -> ()
    | 'p' ->
      let fd = Unix.openfile path [Unix.O_RDWR; Unix.O_CLOEXEC] 0 in
      let state = Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
        match Unix.lockf fd Unix.F_TLOCK 0 with
        | () -> Unix.lockf fd Unix.F_ULOCK 0; 'a'
        | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> 'b') in
      output_char stdout state; flush stdout; loop ()
    | _ -> invalid_arg "lock probe command"
    | exception End_of_file -> () in
  loop ()

let rec wait_for_child pid =
  match Unix.waitpid [] pid with
  | status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_for_child pid

let with_probe path f =
  let child_input, parent_output = Unix.pipe ~cloexec:true () in
  let parent_input, child_output = Unix.pipe ~cloexec:true () in
  let pid = Unix.create_process Sys.executable_name
      [|Sys.executable_name; "--lock-probe"; path|] child_input child_output Unix.stderr in
  Unix.close child_input; Unix.close child_output;
  let input = Unix.in_channel_of_descr parent_input in
  let output = Unix.out_channel_of_descr parent_output in
  let probe () = output_char output 'p'; flush output; input_char input in
  Fun.protect ~finally:(fun () ->
    output_char output 'q'; flush output; close_out output; close_in input;
    match wait_for_child pid with
    | _, Unix.WEXITED 0 -> ()
    | _, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) ->
      fail "lock probe did not exit successfully") (fun () -> f probe)

let test_borrowed_lock ~create root path =
  write path "before\000\n";
  with_probe path (fun probe ->
    check char "probe can acquire unlocked file" 'a' (probe ());
    let decide (observed : Fs.owned_regular_file_contents) =
      check bool "callback holds canonical mutex" false (available path);
      check char "another process cannot take callback's lock" 'b' (probe ());
      check string "actual transaction bytes" "before\000\n" observed.content;
      let stat = Unix.stat path in
      check (pair int int) "snapshot belongs to actual descriptor"
        (stat.Unix.st_dev, stat.Unix.st_ino) (observed.snapshot.device, observed.snapshot.inode);
      check int "snapshot size matches borrowed bytes"
        (String.length observed.content) observed.snapshot.file_size;
      Some "after\n", 42 in
    let value = if create then
        Some (require_success (Fs.update_owned_private_file_durable_locked_result
          ~owner_uid:(Unix.getuid ()) ~ownership_root:root path decide))
      else require_success (Fs.update_existing_owned_private_file_durable_locked_result
          ~owner_uid:(Unix.getuid ()) ~ownership_root:root path decide) in
    check (option int) "callback result survives" (Some 42) value;
    check char "close releases process lock" 'a' (probe ()));
  check bool "mutex released" true (available path);
  check string "one suffix committed" "before\000\nafter\n" (read path);
  check (list string) "no sidecar" ["data"] (entries root)

let test_locked_read root path =
  write path "read-only\000bytes";
  Unix.chmod path 0o400;
  let checks = ref 0 in
  let parent_lstat parent =
    incr checks;
    check bool "every owned parent check is inside canonical mutex" false (available path);
    Unix.lstat parent in
  let observed = require_present (Fs.Owned_read_for_testing.load_with_snapshot_locked
      ~parent_lstat ~owner_uid:(Unix.getuid ()) ~ownership_root:root path) in
  check bool "parent checked before and after descriptor read" true (!checks > 1);
  check string "read exact bytes without write permission" "read-only\000bytes" observed.content;
  check int "read does not chmod" 0o400 (Unix.stat path).Unix.st_perm;
  check bool "read releases mutex" true (available path);
  check (list string) "read makes no sidecar" ["data"] (entries root)

let test_absence root path =
  let missing_parent = Filename.concat path "missing" in
  List.iter (fun candidate ->
    check bool "fresh missing observation" true (owned_read root candidate = Ok None);
    check (option int) "existing update does not invoke callback" None
      (require_success (Fs.update_existing_owned_private_file_durable_locked_result
        ~owner_uid:(Unix.getuid ()) ~ownership_root:root candidate
        (fun _ -> fail "missing file callback")))) [path; missing_parent];
  check (list string) "missing reads do not create parents or sidecars" [] (entries root);
  write path "";
  check string "present empty remains present" "" (require_present (owned_read root path)).content

let test_creation root path =
  check int "missing leaf gets an empty borrowed observation" 3
    (require_success (Fs.update_owned_private_file_durable_locked_result
      ~owner_uid:(Unix.getuid ()) ~ownership_root:root path (fun observed ->
        check string "new descriptor has no bytes" "" observed.content;
        check int "new descriptor is private" 0o600 observed.snapshot.permissions;
        check int "new descriptor snapshot is empty" 0 observed.snapshot.file_size;
        Some "created", 3)));
  check string "created content" "created" (read path);
  let missing_parent = Filename.concat (Filename.concat root "absent") "data" in
  let (_ : Fs.owned_regular_file_read_error) =
    Fs.update_owned_private_file_durable_locked_result ~owner_uid:(Unix.getuid ())
      ~ownership_root:root missing_parent (fun _ -> fail "missing parent callback")
    |> require_failure |> require_owned_error in
  check (list string) "creating API only creates its leaf in a prepared parent" ["data"] (entries root)

let test_policies root path =
  write path "original";
  let alias = Filename.concat root "alias" in
  Unix.link path alias;
  check string "omitted unique-link policy is unchanged" "original"
    (require_present (owned_read root path)).content;
  (match Fs.load_owned_regular_file_with_snapshot_locked ~single_link:true
      ~owner_uid:(Unix.getuid ()) ~ownership_root:root path with
   | Error _ -> () | Ok _ -> fail "explicit unique-link read accepted alias");
  let (_ : Fs.owned_regular_file_read_error) =
    Fs.update_owned_private_file_durable_locked_result
      ~owner_uid:(Unix.getuid ()) ~ownership_root:root path (fun _ -> Some "bad", ())
    |> require_failure |> require_owned_error in
  Unix.unlink alias;
  Unix.symlink path alias;
  check bool "symlink leaf refused" true
    ((require_read_error (owned_read root alias)).failure =
      Fs.Path_is_not_regular_file {path = alias; kind = Unix.S_LNK});
  Unix.chmod root 0o777;
  check bool "explicit UID rejects unsafe parent" true
    (unsafe_parent (require_read_error (owned_read root path)));
  check string "omitting UID does not add a parent-mode policy" "original"
    (require_present (Fs.load_owned_regular_file_with_snapshot_locked ~ownership_root:root path)).content;
  check (option int) "existing update also retains omitted UID policy" (Some 5)
    (require_success (Fs.update_existing_owned_private_file_durable_locked_result
      ~ownership_root:root path (fun _ -> None, 5)));
  Unix.chmod root 0o700

let test_pre_side_effect_refusal root path =
  write path "original";
  Unix.chmod path 0o644;
  let missing = Filename.concat root "missing" in
  let calls = ref 0 in
  let refuse candidate owner_uid =
    let (_ : Fs.owned_regular_file_read_error) =
      Fs.update_owned_private_file_durable_locked_result ~owner_uid ~ownership_root:root
        candidate (fun _ -> incr calls; Some "bad", ())
      |> require_failure |> require_owned_error in () in
  refuse path (Unix.getuid () + 1);
  refuse missing (Unix.getuid () + 1);
  Unix.chmod root 0o777;
  refuse path (Unix.getuid ()); refuse missing (Unix.getuid ());
  Unix.chmod root 0o700;
  check int "refused callback never ran" 0 !calls;
  check int "refusal precedes chmod" 0o644 (Unix.stat path).Unix.st_perm;
  check string "refusal precedes write" "original" (read path);
  check (list string) "refusal precedes creation" ["data"] (entries root)

let test_callback_replacement root path =
  write path "original";
  let retired = Filename.concat root "retired" in
  let result = Fs.update_existing_owned_private_file_durable_locked_result
      ~owner_uid:(Unix.getuid ()) ~ownership_root:root path (fun _ ->
        Unix.rename path retired; write path "replacement"; Some "bad", ()) in
  check bool "callback replacement refused" true
    ((require_owned_error (require_failure result)).failure =
       Fs.Filesystem_identity_changed {path});
  check string "replacement unchanged" "replacement" (read path);
  check string "retired transaction unchanged" "original" (read retired);
  check bool "replacement refusal releases mutex" true (available path)

exception Injected_close_failure

let test_settlement root path =
  write path "original";
  let closes = ref 0 in
  let io : Fs.private_jsonl_transaction_io_for_testing =
    {before_sync_parent = (fun _ -> ()); close_fd = (fun fd ->
      incr closes; Unix.close fd; raise Injected_close_failure)} in
  (match Fs.Owned_private_file_for_testing.create ~io ~owner_uid:(Unix.getuid ())
      ~ownership_root:root path (fun _ -> Some " committed", 7) with
   | Fs.Private_file_succeeded_with_cleanup_failure {value; cleanup_failure} ->
     check int "committed callback receipt" 7 value;
     check bool "cleanup stage retained" true (cleanup_failure.operation = Fs.Close_transaction_data);
     check bool "close failure retained" true (cleanup_failure.exception_ = Injected_close_failure)
   | Fs.Private_file_succeeded _ | Fs.Private_file_failed _
   | Fs.Private_file_failed_with_cleanup_failure _ ->
     fail "committed receipt or close failure lost");
  (match Fs.Owned_private_file_for_testing.existing ~io ~owner_uid:(Unix.getuid ())
      ~ownership_root:root path (fun _ -> Unix.chmod root 0o777; Some "bad", ()) with
   | Fs.Private_file_failed_with_cleanup_failure {error; cleanup_failure} ->
     check bool "primary parent refusal retained" true (unsafe_parent (require_owned_error error));
     check bool "secondary close failure retained" true (cleanup_failure.exception_ = Injected_close_failure)
   | Fs.Private_file_succeeded _ | Fs.Private_file_succeeded_with_cleanup_failure _
   | Fs.Private_file_failed _ -> fail "primary owner refusal or cleanup failure lost");
  Unix.chmod root 0o700;
  check int "each opened transaction settled once" 2 !closes;
  check string "refused suffix not committed" "original committed" (read path);
  check bool "cleanup failure releases mutex" true (available path)

let test_callback_cancellation root path =
  write path "original";
  with_probe path (fun probe ->
    (match Fs.update_existing_owned_private_file_durable_locked_result
        ~owner_uid:(Unix.getuid ()) ~ownership_root:root path (fun _ ->
          check char "lock held before exception" 'b' (probe ());
          raise (Eio.Cancel.Cancelled Exit)) with
     | exception Eio.Cancel.Cancelled Exit -> ()
     | _ -> fail "callback cancellation was converted to a normal result");
    check char "exception closes locked descriptor" 'a' (probe ()));
  check bool "exception releases mutex" true (available path);
  check string "cancelled callback did not append" "original" (read path)

let test_joined_update_cancellation root path =
  write path "original";
  Eio_main.run @@ fun _env ->
  let entered, signal_entered = Eio.Promise.create () in
  let context, signal_context = Eio.Promise.create () in
  let release = Semaphore.Binary.make false in
  let closed = Atomic.make 0 in
  let completed = Atomic.make false in
  let io : Fs.private_jsonl_transaction_io_for_testing =
    {before_sync_parent = (fun _ -> ()); close_fd = (fun fd ->
      Eio.Promise.resolve signal_entered ();
      Semaphore.Binary.acquire release;
      Unix.close fd; ignore (Atomic.fetch_and_add closed 1 : int))} in
  Eio.Fiber.both
    (fun () -> Eio.Cancel.sub (fun cancel ->
      Eio.Promise.resolve signal_context cancel;
      check int "committed result survives waiting caller cancellation" 9
        (require_success (Fs.Owned_private_file_for_testing.create ~io
          ~owner_uid:(Unix.getuid ()) ~ownership_root:root path (fun _ -> Some " suffix", 9)));
      Atomic.set completed true))
    (fun () ->
      let cancel = Eio.Promise.await context in
      Eio.Promise.await entered;
      Fun.protect ~finally:(fun () -> Semaphore.Binary.release release) (fun () ->
        Eio.Cancel.cancel cancel Exit;
        Eio.Fiber.yield ();
        check bool "caller waits for descriptor settlement" false (Atomic.get completed)));
  check int "descriptor closed once" 1 (Atomic.get closed);
  check bool "settled cancellation releases mutex" true (available path);
  check string "one committed suffix" "original suffix" (read path)

let test_joined_read_cancellation root path =
  write path "original";
  Eio_main.run @@ fun _env ->
  let entered, signal_entered = Eio.Promise.create () in
  let context, signal_context = Eio.Promise.create () in
  let release = Semaphore.Binary.make false in
  let first = Atomic.make true in
  let completed = Atomic.make false in
  let cancelled = ref false in
  let parent_lstat parent =
    if Atomic.compare_and_set first true false then (
      Eio.Promise.resolve signal_entered (); Semaphore.Binary.acquire release);
    Unix.lstat parent in
  Eio.Fiber.both
    (fun () -> Eio.Cancel.sub (fun cancel ->
      Eio.Promise.resolve signal_context cancel;
      (match Fs.Owned_read_for_testing.load_with_snapshot_locked
          ~parent_lstat ~owner_uid:(Unix.getuid ()) ~ownership_root:root path with
       | exception Eio.Cancel.Cancelled Exit -> cancelled := true
       | _ -> fail "cancelled reader returned normally");
      Atomic.set completed true))
    (fun () ->
      let cancel = Eio.Promise.await context in
      Eio.Promise.await entered;
      Fun.protect ~finally:(fun () -> Semaphore.Binary.release release) (fun () ->
        Eio.Cancel.cancel cancel Exit; Eio.Fiber.yield ();
        check bool "read cancellation joins worker" false (Atomic.get completed)));
  check bool "reader propagates cancellation after settling" true !cancelled;
  check bool "cancelled reader releases mutex" true (available path)

let () =
  if Array.length Sys.argv = 3 && Sys.argv.(1) = "--lock-probe" then lock_probe_child Sys.argv.(2)
  else Alcotest.run "owned-file transactions"
    ["owned", List.map (fun (name, f) -> test_case name `Quick (with_root f))
      ["creating callback retains process lock", test_borrowed_lock ~create:true
      ;"existing callback retains process lock", test_borrowed_lock ~create:false
      ;"locked read and read-only file", test_locked_read
      ;"absence and present empty", test_absence
      ;"owned leaf creation", test_creation
      ;"owner, link and alias policies", test_policies
      ;"refusal precedes side effects", test_pre_side_effect_refusal
      ;"callback replacement refuses append", test_callback_replacement
      ;"primary and close settlement", test_settlement
      ;"callback cancellation settles", test_callback_cancellation
      ;"waiting update cancellation preserves receipt", test_joined_update_cancellation
      ;"waiting reader cancellation joins", test_joined_read_cancellation]]
