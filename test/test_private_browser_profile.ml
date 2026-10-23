module P = Private_browser_profile

let lock_name = ".parentlock"

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_root work =
  let root = Filename.temp_dir "masc-private-profile-" "" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> work root)

let profile_in root name =
  let profile = Filename.concat root name in
  Unix.mkdir profile 0o700;
  profile

let write path text =
  let channel = open_out path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel text)

let profile_with_lock root name =
  let profile = profile_in root name in
  write (Filename.concat profile lock_name) "";
  profile

let opened ~profile = match P.open_lock ~profile ~name:lock_name with
  | Ok (P.Lock_file lock_file) -> lock_file
  | Ok P.No_lock_file -> Alcotest.fail "the lock file was not found"
  | Error detail -> Alcotest.fail detail

(* A child that holds the write lock until a signal ends it. *)
let holding_child ~term path =
  let ready_read, ready_write = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
    Unix.close ready_read;
    Sys.set_signal Sys.sigterm term;
    let fd = Unix.openfile path [Unix.O_RDWR] 0o600 in
    Unix.lockf fd Unix.F_LOCK 0;
    ignore (Unix.write_substring ready_write "r" 0 1);
    while true do Unix.pause () done;
    Unix._exit 0
  | child ->
    Unix.close ready_write;
    let ready = Bytes.create 1 in
    ignore (Unix.read ready_read ready 0 1);
    Unix.close ready_read;
    child

(* Exit status 0 when a fresh process can take the write lock, 1 when it is held. *)
let lock_taken_by_another_process path =
  match Unix.fork () with
  | 0 ->
    let fd = Unix.openfile path [Unix.O_RDWR] 0o600 in
    (match Unix.lockf fd Unix.F_TLOCK 0 with
     | () -> Unix._exit 0
     | exception Unix.Unix_error _ -> Unix._exit 1)
  | child ->
    (match Unix.waitpid [] child with
     | _, Unix.WEXITED 0 -> true
     | _, Unix.WEXITED 1 -> false
     | _, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) -> Alcotest.fail "the lock probe failed")

let reap child = ignore (Unix.waitpid [] child)
let stop child = (try Unix.kill child Sys.sigkill with Unix.Unix_error _ -> ()); reap child

let held lock_file = match P.inspect lock_file with
  | P.Held_by holder -> holder
  | P.Unlocked -> Alcotest.fail "the held lock was reported unlocked"
  | P.Changing -> Alcotest.fail "the held lock was reported changing"
  | P.Unreadable detail -> Alcotest.fail detail

let signal_error = Alcotest.testable (fun format error -> Format.pp_print_string format (match error with
    | P.Holder_changed -> "Holder_changed" | P.Other_lock_file -> "Other_lock_file"
    | P.Lock_file_closed -> "Lock_file_closed" | P.Released -> "Released"
    | P.Unsupported -> "Unsupported" | P.Failed -> "Failed")) ( = )
let sent = Alcotest.(result unit signal_error)

let refused_lock_files () = with_root (fun root ->
  let missing = profile_in root "missing" in
  (match P.open_lock ~profile:missing ~name:lock_name with
   | Ok P.No_lock_file -> () | Ok (P.Lock_file _) | Error _ -> Alcotest.fail "a missing lock file was not reported");
  let target = Filename.concat root "target" in
  write target "";
  let linked = profile_in root "linked" in
  Unix.symlink target (Filename.concat linked lock_name);
  (match P.open_lock ~profile:linked ~name:lock_name with
   | Error _ -> () | Ok _ -> Alcotest.fail "a symbolic link was opened as a lock file");
  let hard = profile_in root "hard" in
  Unix.link target (Filename.concat hard lock_name);
  (match P.open_lock ~profile:hard ~name:lock_name with
   | Error _ -> () | Ok _ -> Alcotest.fail "a lock file with two links was opened");
  let profile_link = Filename.concat root "profile-link" in
  Unix.symlink (profile_with_lock root "real") profile_link;
  (match P.open_lock ~profile:profile_link ~name:lock_name with
   | Error _ -> () | Ok _ -> Alcotest.fail "a symbolic link was opened as a profile"))

let holder_ends_on_termination () = with_root (fun root ->
  let profile = profile_with_lock root "term" in
  let lock_file = opened ~profile in
  Fun.protect ~finally:(fun () -> P.close_lock lock_file) (fun () ->
    (match P.inspect lock_file with
     | P.Unlocked -> () | P.Held_by _ | P.Changing | P.Unreadable _ -> Alcotest.fail "a free lock was reported held");
    let child = holding_child ~term:Sys.Signal_default (Filename.concat profile lock_name) in
    let holder = held lock_file in
    Alcotest.(check int) "the kernel reports the child" child (P.pid holder);
    Alcotest.(check bool) "two captures name one process" true (P.same_process holder (held lock_file));
    Alcotest.check sent "TERM is sent" (Ok ()) (P.request_termination holder lock_file);
    let _, status = Unix.waitpid [] child in
    Alcotest.(check bool) "the child ended on TERM" true (status = Unix.WSIGNALED Sys.sigterm);
    Alcotest.check sent "an ended holder is not signalled again" (Error P.Holder_changed)
      (P.request_termination holder lock_file);
    (match P.inspect lock_file with
     | P.Unlocked -> () | P.Held_by _ | P.Changing | P.Unreadable _ -> Alcotest.fail "the ended child still held the lock");
    P.release holder;
    Alcotest.check sent "a released holder sends nothing" (Error P.Released) (P.request_kill holder lock_file)))

let holder_ends_on_kill () = with_root (fun root ->
  let profile = profile_with_lock root "kill" in
  let lock_file = opened ~profile in
  let child = holding_child ~term:Sys.Signal_ignore (Filename.concat profile lock_name) in
  Fun.protect ~finally:(fun () -> P.close_lock lock_file) (fun () ->
    let holder = held lock_file in
    Alcotest.check sent "TERM is sent" (Ok ()) (P.request_termination holder lock_file);
    Unix.sleepf 0.2;
    let again = held lock_file in
    Alcotest.(check bool) "the same process still holds the lock" true (P.same_process holder again);
    Alcotest.check sent "KILL is sent" (Ok ()) (P.request_kill holder lock_file);
    let _, status = Unix.waitpid [] child in
    Alcotest.(check bool) "the child ended on KILL" true (status = Unix.WSIGNALED Sys.sigkill)))

let holder_is_bound_to_its_file () = with_root (fun root ->
  let first = profile_with_lock root "first" and second = profile_with_lock root "second" in
  let first_lock = opened ~profile:first and second_lock = opened ~profile:second in
  let child = holding_child ~term:Sys.Signal_default (Filename.concat first lock_name) in
  Fun.protect ~finally:(fun () -> stop child; P.close_lock first_lock; P.close_lock second_lock) (fun () ->
    let holder = held first_lock in
    Alcotest.check sent "another profile's lock file cannot carry the signal" (Error P.Other_lock_file)
      (P.request_kill holder second_lock);
    P.close_lock first_lock;
    Alcotest.check sent "a closed lock file cannot carry the signal" (Error P.Lock_file_closed)
      (P.request_kill holder first_lock)))

let releasing_a_holder_keeps_this_process_lock () = with_root (fun root ->
  let profile = profile_with_lock root "keep" in
  let path = Filename.concat profile lock_name in
  let lock_file = opened ~profile in
  let child = holding_child ~term:Sys.Signal_default path in
  let holder = held lock_file in
  Alcotest.check sent "KILL is sent" (Ok ()) (P.request_kill holder lock_file);
  reap child;
  (match P.lock lock_file with
   | Ok P.Locked -> () | Ok P.Held_elsewhere | Error _ -> Alcotest.fail "the freed lock could not be taken");
  P.release holder;
  Alcotest.(check bool) "the lock stays with this process after the release" false
    (lock_taken_by_another_process path);
  P.close_lock lock_file;
  Alcotest.(check bool) "closing the lock file frees it" true (lock_taken_by_another_process path))

let held_lock_is_refused () = with_root (fun root ->
  let profile = profile_with_lock root "busy" in
  let lock_file = opened ~profile in
  let child = holding_child ~term:Sys.Signal_default (Filename.concat profile lock_name) in
  Fun.protect ~finally:(fun () -> stop child; P.close_lock lock_file) (fun () ->
    match P.lock lock_file with
    | Ok P.Held_elsewhere -> ()
    | Ok P.Locked | Error _ -> Alcotest.fail "a lock another process holds was taken"))

let removal_keeps_the_lock_file_last () = with_root (fun root ->
  let refused = profile_with_lock root "refused" in
  let outside = Filename.concat root "outside" in
  write outside "kept";
  Unix.link outside (Filename.concat refused "hard-linked");
  (match P.remove ~label:"Gecko profile" ~last:lock_name refused with
   | Error _ -> () | Ok () -> Alcotest.fail "a hard-linked entry was removed");
  Alcotest.(check bool) "the lock file outlives a refused entry" true
    (Sys.file_exists (Filename.concat refused lock_name));
  let removed = profile_with_lock root "removed" in
  Unix.mkdir (Filename.concat removed "nested") 0o700;
  write (Filename.concat (Filename.concat removed "nested") "prefs.js") "";
  Unix.symlink outside (Filename.concat removed "lock");
  (match P.remove ~label:"Gecko profile" ~last:lock_name removed with
   | Ok () -> () | Error detail -> Alcotest.fail detail);
  Alcotest.(check bool) "the profile is gone" false (Sys.file_exists removed);
  Alcotest.(check bool) "a symbolic link target is kept" true (Sys.file_exists outside))

let () = Alcotest.run "private browser profile" [
  "lock file", [
    Alcotest.test_case "refused lock files" `Quick refused_lock_files;
    Alcotest.test_case "a held lock is not taken" `Quick held_lock_is_refused;
    Alcotest.test_case "releasing a holder keeps this process's lock" `Quick
      releasing_a_holder_keeps_this_process_lock];
  "holder", [
    Alcotest.test_case "a holder ends on TERM" `Quick holder_ends_on_termination;
    Alcotest.test_case "a holder that ignores TERM ends on KILL" `Quick holder_ends_on_kill;
    Alcotest.test_case "a holder signals only through its own lock file" `Quick holder_is_bound_to_its_file];
  "removal", [
    Alcotest.test_case "the lock file is removed last" `Quick removal_keeps_the_lock_file_last]]
