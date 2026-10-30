open Masc

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let close_quietly fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()

let process_alive pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ -> true
  | _ -> false
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> false

(* [process_alive] answers about children, because waitpid is what it asks.
   Production asks kill(pid, 0), so a test that plants a number has to check
   it the same way or it is measuring a different question. *)
let pid_is_absent pid =
  match Unix.kill pid 0 with
  | () -> false
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> true
  | exception Unix.Unix_error (Unix.EPERM, _, _) -> false

(* A number that names no process: fork, let the child exit, reap it. Until the
   kernel wraps around to it again it is free. A large constant does not work --
   Linux pid_max is 4,194,304, so 2,000,000 can be a live process and the
   assertion would be about the host rather than the code. *)
let reaped_pid () =
  match Unix.fork () with
  | 0 -> Unix._exit 0
  | pid ->
    ignore (Unix.waitpid [] pid : int * Unix.process_status);
    pid

let rec waitpid_nointr pid =
  try Some (Unix.waitpid [] pid) with
  | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr pid
  | Unix.Unix_error (Unix.ECHILD, _, _) -> None

let stop_process pid =
  if process_alive pid then
    (try Unix.kill pid Sys.sigkill with _ -> ());
  ignore (waitpid_nointr pid)

let base_path_lock_path ~run_dir base_path =
  (* The v2 lease file of this directory: the path an acquire/release cycle
     leaves behind. Kept for the full-digest assertion in the digest test;
     file-planting fixtures use [For_testing.lease_path] instead. *)
  Server_startup_takeover.For_testing.lease_path
    ~run_dir:(Unix.realpath run_dir)
    ~canonical_base_path:(Unix.realpath base_path)

(* macOS answers realpath with two different strings for one directory:
   /private/tmp/X and /System/Volumes/Data/private/tmp/X are the same inode
   (hole-finder task-2206, run 37813366033). The lease must name the
   directory itself, so on a host without the second spelling this case has
   nothing to ask and is skipped instead of passing vacuously. *)
let second_realpath_spelling canonical_base_path =
  let prefix = "/private/" in
  if
    String.length canonical_base_path > String.length prefix
    && String.equal
         (String.sub canonical_base_path 0 (String.length prefix))
         prefix
  then Some ("/System/Volumes/Data/" ^ canonical_base_path)
  else None

let with_base_and_run prefix f =
  with_temp_dir (prefix ^ "-base") (fun base_path ->
    with_temp_dir (prefix ^ "-run") (fun run_dir ->
      f ~base_path ~run_dir))

let pid_from_file path =
  let first_line =
    match String.split_on_char '\n' (read_file path) with
    | line :: _ -> String.trim line
    | [] -> ""
  in
  match int_of_string_opt first_line with
  | Some pid -> pid
  | None -> Alcotest.failf "invalid pid file contents in %s" path

let test_base_path_lock_reports_a_recorded_owner_that_is_gone () =
  with_base_and_run "startup-takeover-base-path-stale-owner"
    (fun ~base_path ~run_dir ->
    let ready_read, ready_write = Unix.pipe () in
    let release_read, release_write = Unix.pipe () in
    match Unix.fork () with
    | 0 ->
      close_quietly ready_read;
      close_quietly release_write;
      (match
         Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
       with
       | Server_startup_takeover.Base_path_acquired lease ->
         ignore (Unix.write_substring ready_write "1" 0 1 : int);
         let buffer = Bytes.create 1 in
         ignore (Unix.read release_read buffer 0 1 : int);
         Server_startup_takeover.release_base_path_lease lease;
         exit 0
       | Server_startup_takeover.Base_path_already_owned _ -> exit 2
       | Server_startup_takeover.Base_path_rejected _ -> exit 3)
    | child_pid ->
      close_quietly ready_write;
      close_quietly release_read;
      Fun.protect
        ~finally:(fun () ->
          close_quietly ready_read;
          close_quietly release_write;
          if process_alive child_pid then stop_process child_pid)
        (fun () ->
           let buffer = Bytes.create 1 in
           Alcotest.(check int) "child acquired lease" 1
             (Unix.read ready_read buffer 0 1);
           (* Advisory locks do not stop a write, which is exactly how the
              file comes to disagree with the holder. *)
           let absent_pid = reaped_pid () in
           Alcotest.(check bool) "the planted number is not a live process"
             true (pid_is_absent absent_pid);
           let lease_path =
             Server_startup_takeover.For_testing.lease_path
               ~run_dir:(Unix.realpath run_dir)
               ~canonical_base_path:(Unix.realpath base_path)
           in
           let fd = Unix.openfile lease_path [ Unix.O_WRONLY ] 0o600 in
           Unix.ftruncate fd 0;
           let payload = Printf.sprintf "%d\n" absent_pid in
           ignore
             (Unix.write_substring fd payload 0 (String.length payload) : int);
           close_quietly fd;
           (match
              Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
            with
            | Server_startup_takeover.Base_path_already_owned { owner; _ } ->
              Alcotest.(check bool)
                "an absent recorded PID remains namespace-unverified"
                true
                (match owner with
                 | Server_startup_takeover.Owner_recorded pid ->
                   pid = absent_pid
                 | _ -> false)
            | Server_startup_takeover.Base_path_acquired lease ->
              Server_startup_takeover.release_base_path_lease lease;
              Alcotest.fail "a held BasePath lease was acquired twice"
            | Server_startup_takeover.Base_path_rejected rejection ->
              Alcotest.failf "valid BasePath was rejected: %s"
                (Server_startup_takeover.base_path_lock_rejection_to_string
                   rejection));
           ignore (Unix.write_substring release_write "1" 0 1 : int);
           ignore (Unix.waitpid [] child_pid : int * Unix.process_status)))

(* An owner child that takes the lease, says so on [ready], and exits on its
   own once it reads a byte from [release]. *)
let spawn_lease_owner ~run_dir base_path =
  let ready_read, ready_write = Unix.pipe () in
  let release_read, release_write = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
    close_quietly ready_read;
    close_quietly release_write;
    (match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
     | Server_startup_takeover.Base_path_acquired _ ->
       ignore (Unix.write_substring ready_write "1" 0 1 : int);
       let buffer = Bytes.create 1 in
       ignore (Unix.read release_read buffer 0 1 : int);
       Unix._exit 0
     | Server_startup_takeover.Base_path_already_owned _ -> Unix._exit 2
     | Server_startup_takeover.Base_path_rejected _ -> Unix._exit 3)
  | owner_pid ->
    close_quietly ready_write;
    close_quietly release_read;
    let buffer = Bytes.create 1 in
    Alcotest.(check int) "owner acquired the lease" 1
      (Unix.read ready_read buffer 0 1);
    close_quietly ready_read;
    (owner_pid, release_write)

let owner_exited_on_its_own owner_pid =
  match waitpid_nointr owner_pid with
  | Some (_, Unix.WEXITED 0) -> ()
  | Some (_, _) -> Alcotest.fail "the owner did not exit on its own"
  | None -> Alcotest.fail "the owner was reaped elsewhere"

(* Locks are not inherited across fork, and this probe asks the kernel
   directly, not this process's lease table. *)
let lease_is_held_in_the_kernel ~run_dir base_path =
  let lease_path =
    Server_startup_takeover.For_testing.lease_path
      ~run_dir:(Unix.realpath run_dir)
      ~canonical_base_path:(Unix.realpath base_path)
  in
  match Unix.fork () with
  | 0 ->
    let fd = Unix.openfile lease_path [ Unix.O_RDWR ] 0o600 in
    (match Unix.lockf fd Unix.F_TLOCK 0 with
     | () -> Unix._exit 1
     | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> Unix._exit 0
     | exception Unix.Unix_error _ -> Unix._exit 2)
  | probe_pid ->
    (match waitpid_nointr probe_pid with
     | Some (_, Unix.WEXITED 0) -> true
     | Some (_, _) | None -> false)

(* The owner is told to leave only from inside [on_wait], so the wait is
   proven to start while the lease is held and to end when the owner's exit
   closes its descriptor. The owner exits on its own; a zero status shows
   the waiting side sent it no signal. *)
let test_waiting_acquisition_takes_the_lease_when_the_owner_exits () =
  with_base_and_run "startup-takeover-base-path-wait"
    (fun ~base_path ~run_dir ->
    let owner_pid, release_owner = spawn_lease_owner ~run_dir base_path in
    Fun.protect
      ~finally:(fun () ->
        close_quietly release_owner;
        if process_alive owner_pid then stop_process owner_pid)
      (fun () ->
         let heard = ref [] in
         let on_wait owner =
           heard := owner :: !heard;
           ignore (Unix.write_substring release_owner "1" 0 1 : int)
         in
         (match
            Server_startup_takeover.acquire_base_path_lock_after_owner_exits
              ~run_dir ~on_wait base_path
          with
          | Ok (Server_startup_takeover.Base_path_acquired lease) ->
            Alcotest.(check bool) "the granted lease is held in the kernel" true
              (lease_is_held_in_the_kernel ~run_dir base_path);
            Server_startup_takeover.release_base_path_lease lease
          | Ok (Server_startup_takeover.Base_path_already_owned _) ->
            Alcotest.fail "the waiting acquisition returned instead of waiting"
          | Ok (Server_startup_takeover.Base_path_rejected rejection) ->
            Alcotest.failf "valid BasePath was rejected: %s"
              (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
          | Error (Server_startup_takeover.Another_replacement_waits _) ->
            Alcotest.fail "a lone waiter was refused as a second one");
         Alcotest.(check bool) "on_wait heard the recorded owner once" true
           (match !heard with
            | [ Server_startup_takeover.Owner_recorded pid ] -> pid = owner_pid
            | _ -> false);
         owner_exited_on_its_own owner_pid))

(* While one replacement waits, a second is refused at once rather than
   queued behind whichever process gets the lease next. The first waiter
   reports through a pipe from its own [on_wait], so the second attempt is
   made only while the first is known to wait. *)
let test_a_second_waiter_is_refused_while_one_waits () =
  with_base_and_run "startup-takeover-base-path-second-waiter"
    (fun ~base_path ~run_dir ->
    let owner_pid, release_owner = spawn_lease_owner ~run_dir base_path in
    let waiting_read, waiting_write = Unix.pipe () in
    match Unix.fork () with
    | 0 ->
      close_quietly waiting_read;
      close_quietly release_owner;
      let on_wait _ = ignore (Unix.write_substring waiting_write "W" 0 1 : int) in
      (match
         Server_startup_takeover.acquire_base_path_lock_after_owner_exits
           ~run_dir ~on_wait base_path
       with
       | Ok (Server_startup_takeover.Base_path_acquired _) -> Unix._exit 0
       | Ok _ | Error _ -> Unix._exit 4)
    | waiter_pid ->
      close_quietly waiting_write;
      Fun.protect
        ~finally:(fun () ->
          close_quietly waiting_read;
          close_quietly release_owner;
          if process_alive waiter_pid then stop_process waiter_pid;
          if process_alive owner_pid then stop_process owner_pid)
        (fun () ->
           let buffer = Bytes.create 1 in
           Alcotest.(check int) "the first waiter is waiting" 1
             (Unix.read waiting_read buffer 0 1);
           (match
              Server_startup_takeover.acquire_base_path_lock_after_owner_exits
                ~run_dir
                ~on_wait:(fun _ -> Alcotest.fail "the second waiter started to wait")
                base_path
            with
            | Error (Server_startup_takeover.Another_replacement_waits { waiter; _ }) ->
              Alcotest.(check bool) "the refusal names the first waiter" true
                (match waiter with
                 | Server_startup_takeover.Owner_recorded pid -> pid = waiter_pid
                 | Server_startup_takeover.Owner_this_process _
                 | Server_startup_takeover.Owner_unnamed -> false)
            | Ok (Server_startup_takeover.Base_path_acquired lease) ->
              Server_startup_takeover.release_base_path_lease lease;
              Alcotest.fail "the second waiter took the lease"
            | Ok (Server_startup_takeover.Base_path_already_owned _)
            | Ok (Server_startup_takeover.Base_path_rejected _) ->
              Alcotest.fail "the second waiter was not refused as a waiter");
           ignore (Unix.write_substring release_owner "1" 0 1 : int);
           owner_exited_on_its_own owner_pid;
           match waitpid_nointr waiter_pid with
           | Some (_, Unix.WEXITED 0) -> ()
           | Some (_, _) | None ->
             Alcotest.fail "the first waiter did not take the lease after the owner"))

let test_base_path_lock_rejects_concurrent_lease () =
  with_base_and_run "startup-takeover-base-path-live"
    (fun ~base_path ~run_dir ->
    let ready_read, ready_write = Unix.pipe () in
    let release_read, release_write = Unix.pipe () in
    match Unix.fork () with
    | 0 ->
      close_quietly ready_read;
      close_quietly release_write;
      (match
         Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
       with
       | Server_startup_takeover.Base_path_acquired lease ->
         ignore (Unix.write_substring ready_write "1" 0 1 : int);
         let buffer = Bytes.create 1 in
         ignore (Unix.read release_read buffer 0 1 : int);
         Server_startup_takeover.release_base_path_lease lease;
         exit 0
       | Server_startup_takeover.Base_path_already_owned _ -> exit 2
       | Server_startup_takeover.Base_path_rejected _ -> exit 3)
    | child_pid ->
      close_quietly ready_write;
      close_quietly release_read;
      Fun.protect
        ~finally:(fun () ->
          close_quietly ready_read;
          close_quietly release_write;
          if process_alive child_pid then stop_process child_pid)
        (fun () ->
           let buffer = Bytes.create 1 in
           Alcotest.(check int)
             "child acquired lease"
             1
             (Unix.read ready_read buffer 0 1);
           (match
              Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
            with
            | Server_startup_takeover.Base_path_already_owned { owner; _ } ->
              (* Even a locally running PID does not prove the namespace or
                 identity of the holder of a shared lease. *)
              Alcotest.(check bool) "running recorded PID remains unverified" true
                (match owner with
                 | Server_startup_takeover.Owner_recorded _ -> true
                 | Server_startup_takeover.Owner_this_process _
                 | Server_startup_takeover.Owner_unnamed -> false);
              Alcotest.(check (option int)) "owner pid is observable"
                (Some child_pid)
                (Server_startup_takeover.base_path_owner_pid owner)
            | Server_startup_takeover.Base_path_acquired lease ->
              Server_startup_takeover.release_base_path_lease lease;
              Alcotest.fail "concurrent BasePath lease was acquired twice"
            | Server_startup_takeover.Base_path_rejected rejection ->
              Alcotest.failf
                "valid BasePath was rejected: %s"
                (Server_startup_takeover.base_path_lock_rejection_to_string
                   rejection));
           ignore (Unix.write_substring release_write "1" 0 1 : int);
           match waitpid_nointr child_pid with
           | Some (_, Unix.WEXITED 0) -> ()
           | _ -> Alcotest.fail "BasePath lease holder did not exit cleanly"))

let test_base_path_lock_reclaims_stale_pid_file () =
  with_base_and_run "startup-takeover-base-path-stale"
    (fun ~base_path ~run_dir ->
      let pid = reaped_pid () in
      let path =
        Server_startup_takeover.For_testing.lease_path
          ~run_dir:(Unix.realpath run_dir)
          ~canonical_base_path:(Unix.realpath base_path)
      in
      write_file path (Printf.sprintf "%d\n" pid);
      match
        Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
      with
      | Server_startup_takeover.Base_path_acquired lease ->
          Alcotest.(check int) "current pid written" (Unix.getpid ())
            (pid_from_file path);
          Server_startup_takeover.release_base_path_lease lease
      | Server_startup_takeover.Base_path_already_owned _ ->
          Alcotest.fail "stale base-path owner should be reclaimed"
      | Server_startup_takeover.Base_path_rejected rejection ->
        Alcotest.failf
          "valid BasePath was rejected: %s"
          (Server_startup_takeover.base_path_lock_rejection_to_string
             rejection))

let test_base_path_lock_rejects_same_process_symlink_alias () =
  with_temp_dir "startup-takeover-base-path-alias" (fun dir ->
    with_temp_dir "startup-takeover-base-path-alias-run" (fun run_dir ->
    let real_base = Filename.concat dir "real" in
    let alias_base = Filename.concat dir "alias" in
    Unix.mkdir real_base 0o755;
    Unix.symlink real_base alias_base;
    match
      Server_startup_takeover.acquire_base_path_lock ~run_dir real_base
    with
    | Server_startup_takeover.Base_path_already_owned _ ->
      Alcotest.fail "first BasePath identity was already owned"
    | Server_startup_takeover.Base_path_acquired lease ->
      Fun.protect
        ~finally:(fun () ->
          Server_startup_takeover.release_base_path_lease lease;
          Sys.remove alias_base)
        (fun () ->
           match
             Server_startup_takeover.acquire_base_path_lock ~run_dir alias_base
           with
           | Server_startup_takeover.Base_path_already_owned { owner; _ } ->
             Alcotest.(check bool)
               "symlink alias names this process, not a killable other" true
               (match owner with
                | Server_startup_takeover.Owner_this_process _ -> true
                | Server_startup_takeover.Owner_recorded _
                | Server_startup_takeover.Owner_unnamed -> false);
             Alcotest.(check (option int))
               "symlink alias observes the same process-local owner"
               (Some (Unix.getpid ()))
               (Server_startup_takeover.base_path_owner_pid owner)
           | Server_startup_takeover.Base_path_acquired alias_lease ->
             Server_startup_takeover.release_base_path_lease alias_lease;
             Alcotest.fail
               "symlink alias bypassed the process-local BasePath lease"
           | Server_startup_takeover.Base_path_rejected rejection ->
             Alcotest.failf
               "canonical BasePath alias was rejected: %s"
               (Server_startup_takeover.base_path_lock_rejection_to_string
                  rejection))
    | Server_startup_takeover.Base_path_rejected rejection ->
      Alcotest.failf
        "valid BasePath was rejected: %s"
        (Server_startup_takeover.base_path_lock_rejection_to_string rejection)))

(* Two realpath spellings of one directory must share one lease. On Linux
   realpath resolves symlinks to one string, so the alias spelling is built
   from a symlink into the same directory; on macOS the second spelling is
   the /System/Volumes/Data prefix of the same path. Both shapes compare two
   different canonical strings for the same (st_dev, st_ino) directory. *)
let test_base_path_lock_shares_one_lease_across_realpath_spellings () =
  if Sys.os_type <> "Unix" then Alcotest.skip ();
  with_temp_dir "startup-takeover-spelling-base" (fun dir ->
    with_temp_dir "startup-takeover-spelling-run" (fun run_dir ->
      let real_base = Filename.concat dir "real" in
      Unix.mkdir real_base 0o755;
      let canonical = Unix.realpath real_base in
      let alias, alias_is_link =
        match second_realpath_spelling canonical with
        | Some spelling -> spelling, false
        | None ->
          let alias_base = Filename.concat dir "alias" in
          Unix.symlink real_base alias_base;
          alias_base, true
      in
      Fun.protect
        ~finally:(fun () ->
          (* A second realpath spelling is another name of the same directory
             (macOS), so there is no separate alias entry to remove:
             unlinking the directory path fails with EPERM there. The Linux
             shape is a symlink this test created. *)
          if alias_is_link then Sys.remove alias)
        (fun () ->
          let check_owner name = function
            | Server_startup_takeover.Owner_this_process _ -> ()
            | owner ->
              Alcotest.failf
                "%s observed an unexpected owner (expected this process)"
                name
          in
          let expect_refused name = function
            | Server_startup_takeover.Base_path_already_owned { owner; _ } ->
              check_owner name owner
            | Server_startup_takeover.Base_path_acquired lease ->
              Server_startup_takeover.release_base_path_lease lease;
              Alcotest.failf "%s acquired a second lease for one directory" name
            | Server_startup_takeover.Base_path_rejected rejection ->
              Alcotest.failf
                "%s was rejected: %s"
                name
                (Server_startup_takeover.base_path_lock_rejection_to_string
                   rejection)
          in
          match
            Server_startup_takeover.acquire_base_path_lock ~run_dir real_base
          with
          | Server_startup_takeover.Base_path_already_owned _ ->
            Alcotest.fail "first BasePath spelling was already owned"
          | Server_startup_takeover.Base_path_acquired lease ->
            Fun.protect
              ~finally:(fun () ->
                Server_startup_takeover.release_base_path_lease lease)
              (fun () ->
                 expect_refused "second realpath spelling"
                   (Server_startup_takeover.acquire_base_path_lock
                      ~run_dir
                      alias))
          | Server_startup_takeover.Base_path_rejected rejection ->
            Alcotest.failf
              "valid BasePath was rejected: %s"
              (Server_startup_takeover.base_path_lock_rejection_to_string
                 rejection))))

let test_stale_lease_release_preserves_new_active_lease () =
  with_base_and_run "startup-takeover-stale-release"
    (fun ~base_path ~run_dir ->
      let acquire () =
        match
          Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
        with
        | Server_startup_takeover.Base_path_acquired lease -> lease
        | Server_startup_takeover.Base_path_already_owned _ ->
          Alcotest.fail "fresh lease fixture was already owned"
        | Server_startup_takeover.Base_path_rejected rejection ->
          Alcotest.failf
            "fresh lease fixture was rejected: %s"
            (Server_startup_takeover.base_path_lock_rejection_to_string
               rejection)
      in
      let stale_lease = acquire () in
      Server_startup_takeover.release_base_path_lease stale_lease;
      let active_lease = acquire () in
      Server_startup_takeover.release_base_path_lease stale_lease;
      (match
         Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
       with
       | Server_startup_takeover.Base_path_already_owned { owner; _ } ->
         Alcotest.(check (option int))
           "stale release preserves current owner"
           (Some (Unix.getpid ()))
           (Server_startup_takeover.base_path_owner_pid owner)
       | Server_startup_takeover.Base_path_rejected rejection ->
         Alcotest.failf
           "stale release corrupted active ownership: %s"
           (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
       | Server_startup_takeover.Base_path_acquired unexpected ->
         Server_startup_takeover.release_base_path_lease unexpected;
         Alcotest.fail "stale release removed the current ownership fence");
      Server_startup_takeover.release_base_path_lease active_lease;
      let final_lease = acquire () in
      Server_startup_takeover.release_base_path_lease final_lease)

let test_base_path_lock_rejects_linked_runtime_directory () =
  with_base_and_run "startup-takeover-linked-runtime"
    (fun ~base_path ~run_dir ->
    with_temp_dir "startup-takeover-linked-runtime-outside" (fun outside ->
      let runtime_directory = Filename.concat base_path Common.masc_dirname in
      let canonical_runtime_directory =
        Filename.concat (Unix.realpath base_path) Common.masc_dirname
      in
      Unix.symlink outside runtime_directory;
      Fun.protect
        ~finally:(fun () -> Unix.unlink runtime_directory)
        (fun () ->
           (match
              Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
            with
            | Server_startup_takeover.Base_path_rejected
                (Server_startup_takeover.Runtime_directory_rejected
                  (Fs_compat.Owned_path_non_directory
                    { path; kind = Unix.S_LNK })) ->
              Alcotest.(check string)
                "linked runtime directory is identified"
                canonical_runtime_directory
                path
            | Server_startup_takeover.Base_path_rejected rejection ->
              Alcotest.failf
                "unexpected runtime-directory rejection: %s"
                (Server_startup_takeover.base_path_lock_rejection_to_string
                   rejection)
            | Server_startup_takeover.Base_path_already_owned _ ->
              Alcotest.fail "linked runtime directory looked owned"
            | Server_startup_takeover.Base_path_acquired lease ->
              Server_startup_takeover.release_base_path_lease lease;
              Alcotest.fail "linked runtime directory acquired ownership");
           Alcotest.(check bool)
             "outside lease file was not created"
             false
             (Sys.file_exists (Filename.concat outside "server-owner.pid")))))

let test_base_path_lock_rejects_linked_lease_directory () =
  with_base_and_run "startup-takeover-linked-lease-directory"
    (fun ~base_path ~run_dir ->
      with_temp_dir "startup-takeover-linked-lease-directory-outside"
        (fun outside ->
          let path =
            Server_startup_takeover.For_testing.lease_path
              ~run_dir:(Unix.realpath run_dir)
              ~canonical_base_path:(Unix.realpath base_path)
          in
          let lease_directory = Filename.dirname path in
          (try Unix.rmdir lease_directory with
           | Unix.Unix_error (Unix.ENOENT, _, _) -> ());
          Unix.symlink outside lease_directory;
          Fun.protect
            ~finally:(fun () -> Unix.unlink lease_directory)
            (fun () ->
              match
                Server_startup_takeover.acquire_base_path_lock
                  ~run_dir
                  base_path
              with
              | Server_startup_takeover.Base_path_rejected
                  (Server_startup_takeover.Lease_directory_not_directory
                    { path = rejected_path; kind = Unix.S_LNK }) ->
                Alcotest.(check string)
                  "linked private lease directory is identified"
                  lease_directory
                  rejected_path;
                Alcotest.(check int)
                  "linked target remains empty"
                  0
                  (Array.length (Sys.readdir outside))
              | Server_startup_takeover.Base_path_rejected rejection ->
                Alcotest.failf
                  "unexpected private lease-directory rejection: %s"
                  (Server_startup_takeover.base_path_lock_rejection_to_string
                     rejection)
              | Server_startup_takeover.Base_path_already_owned _ ->
                Alcotest.fail "linked private lease directory looked owned"
              | Server_startup_takeover.Base_path_acquired lease ->
                Server_startup_takeover.release_base_path_lease lease;
                Alcotest.fail "linked private lease directory acquired ownership")))

let test_base_path_lock_rejects_permissive_lease_directory () =
  with_base_and_run "startup-takeover-permissive-lease-directory"
    (fun ~base_path ~run_dir ->
      let path =
        Server_startup_takeover.For_testing.lease_path
          ~run_dir:(Unix.realpath run_dir)
          ~canonical_base_path:(Unix.realpath base_path)
      in
      let lease_directory = Filename.dirname path in
      Unix.chmod lease_directory 0o755;
      match
        Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
      with
      | Server_startup_takeover.Base_path_rejected
          (Server_startup_takeover.Lease_directory_insecure_permissions
            { path = rejected_path; permissions }) ->
        Alcotest.(check string)
          "permissive private lease directory is identified"
          lease_directory
          rejected_path;
        Alcotest.(check int) "observed private mode" 0o755 permissions
      | Server_startup_takeover.Base_path_rejected rejection ->
        Alcotest.failf
          "unexpected permissive lease-directory rejection: %s"
          (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
      | Server_startup_takeover.Base_path_already_owned _ ->
        Alcotest.fail "permissive private lease directory looked owned"
      | Server_startup_takeover.Base_path_acquired lease ->
        Server_startup_takeover.release_base_path_lease lease;
        Alcotest.fail "permissive private lease directory acquired ownership")

let test_base_path_lock_rejects_unprotected_shared_run_directory () =
  with_base_and_run "startup-takeover-unprotected-run-directory"
    (fun ~base_path ~run_dir ->
      Unix.chmod run_dir 0o777;
      match
        Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
      with
      | Server_startup_takeover.Base_path_rejected
          (Server_startup_takeover.Run_directory_insecure_permissions
            { path; permissions }) ->
        Alcotest.(check string)
          "unprotected host run directory is identified"
          (Unix.realpath run_dir)
          path;
        Alcotest.(check int) "observed host run mode" 0o777 permissions
      | Server_startup_takeover.Base_path_rejected rejection ->
        Alcotest.failf
          "unexpected host run-directory rejection: %s"
          (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
      | Server_startup_takeover.Base_path_already_owned _ ->
        Alcotest.fail "unprotected host run directory looked owned"
      | Server_startup_takeover.Base_path_acquired lease ->
        Server_startup_takeover.release_base_path_lease lease;
        Alcotest.fail "unprotected host run directory acquired ownership")

let test_base_path_lock_accepts_sticky_shared_run_directory () =
  with_base_and_run "startup-takeover-sticky-run-directory"
    (fun ~base_path ~run_dir ->
      Unix.chmod run_dir 0o1777;
      match
        Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
      with
      | Server_startup_takeover.Base_path_acquired lease ->
        Server_startup_takeover.release_base_path_lease lease
      | Server_startup_takeover.Base_path_already_owned _ ->
        Alcotest.fail "fresh sticky host run directory looked owned"
      | Server_startup_takeover.Base_path_rejected rejection ->
        Alcotest.failf
          "sticky host run directory was rejected: %s"
          (Server_startup_takeover.base_path_lock_rejection_to_string rejection))

let test_base_path_lock_rejects_lease_directory_retarget_before_open () =
  with_base_and_run "startup-takeover-lease-directory-pre-open-retarget"
    (fun ~base_path ~run_dir ->
      let path =
        Server_startup_takeover.For_testing.lease_path
          ~run_dir:(Unix.realpath run_dir)
          ~canonical_base_path:(Unix.realpath base_path)
      in
      let lease_directory = Filename.dirname path in
      let retired = lease_directory ^ ".retired" in
      Fun.protect
        ~finally:(fun () ->
          if Sys.file_exists lease_directory then rm_rf lease_directory;
          if Sys.file_exists retired then Unix.rename retired lease_directory)
        (fun () ->
          match
            Server_startup_takeover.For_testing.acquire_base_path_lock
              ~before_lease_open:(fun () ->
                Unix.rename lease_directory retired;
                Unix.mkdir lease_directory 0o700)
              ~before_commit_identity_check:(fun () -> ())
              ~before_runtime_identity_check:(fun () -> ())
              ~run_dir
              base_path
          with
          | Server_startup_takeover.Base_path_rejected
              (Server_startup_takeover.Lease_directory_identity_changed
                { path = rejected_path }) ->
            Alcotest.(check string)
              "pre-open private lease-directory retarget is identified"
              lease_directory
              rejected_path
          | Server_startup_takeover.Base_path_rejected rejection ->
            Alcotest.failf
              "unexpected pre-open lease-directory rejection: %s"
              (Server_startup_takeover.base_path_lock_rejection_to_string
                 rejection)
          | Server_startup_takeover.Base_path_already_owned _ ->
            Alcotest.fail "pre-open lease-directory retarget looked owned"
          | Server_startup_takeover.Base_path_acquired lease ->
            Server_startup_takeover.release_base_path_lease lease;
            Alcotest.fail "pre-open lease-directory retarget acquired ownership"))

let test_base_path_lock_rejects_lease_directory_retarget_after_open () =
  with_base_and_run "startup-takeover-lease-directory-post-open-retarget"
    (fun ~base_path ~run_dir ->
      let path =
        Server_startup_takeover.For_testing.lease_path
          ~run_dir:(Unix.realpath run_dir)
          ~canonical_base_path:(Unix.realpath base_path)
      in
      let lease_directory = Filename.dirname path in
      let retired = lease_directory ^ ".retired" in
      Fun.protect
        ~finally:(fun () ->
          if Sys.file_exists lease_directory then rm_rf lease_directory;
          if Sys.file_exists retired then Unix.rename retired lease_directory)
        (fun () ->
          match
            Server_startup_takeover.For_testing.acquire_base_path_lock
              ~before_lease_open:(fun () -> ())
              ~before_commit_identity_check:(fun () ->
                Unix.rename lease_directory retired;
                Unix.mkdir lease_directory 0o700)
              ~before_runtime_identity_check:(fun () -> ())
              ~run_dir
              base_path
          with
          | Server_startup_takeover.Base_path_rejected
              (Server_startup_takeover.Lease_directory_identity_changed
                { path = rejected_path }) ->
            Alcotest.(check string)
              "post-open private lease-directory retarget is identified"
              lease_directory
              rejected_path
          | Server_startup_takeover.Base_path_rejected rejection ->
            Alcotest.failf
              "unexpected post-open lease-directory rejection: %s"
              (Server_startup_takeover.base_path_lock_rejection_to_string
                 rejection)
          | Server_startup_takeover.Base_path_already_owned _ ->
            Alcotest.fail "post-open lease-directory retarget looked owned"
          | Server_startup_takeover.Base_path_acquired lease ->
            Server_startup_takeover.release_base_path_lease lease;
            Alcotest.fail "post-open lease-directory retarget acquired ownership"))

let test_base_path_lock_rejects_linked_lease_file () =
  with_base_and_run "startup-takeover-linked-lease"
    (fun ~base_path ~run_dir ->
    with_temp_dir "startup-takeover-linked-lease-outside" (fun outside ->
      let runtime_directory = Filename.concat base_path Common.masc_dirname in
      Unix.mkdir runtime_directory 0o755;
      let outside_file = Filename.concat outside "sentinel" in
      write_file outside_file "unchanged";
      let path =
        Server_startup_takeover.For_testing.lease_path
          ~run_dir:(Unix.realpath run_dir)
          ~canonical_base_path:(Unix.realpath base_path)
      in
      Unix.symlink outside_file path;
      Fun.protect
        ~finally:(fun () -> Unix.unlink path)
        (fun () ->
           (match
              Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
            with
            | Server_startup_takeover.Base_path_rejected
                (Server_startup_takeover.Lease_file_non_regular
                  { path = rejected_path; kind = Unix.S_LNK }) ->
              Alcotest.(check string)
                "linked lease file is identified"
                path
                rejected_path
            | Server_startup_takeover.Base_path_rejected rejection ->
              Alcotest.failf
                "unexpected lease-file rejection: %s"
                (Server_startup_takeover.base_path_lock_rejection_to_string
                   rejection)
            | Server_startup_takeover.Base_path_already_owned _ ->
              Alcotest.fail "linked lease file looked owned"
            | Server_startup_takeover.Base_path_acquired lease ->
              Server_startup_takeover.release_base_path_lease lease;
              Alcotest.fail "linked lease file acquired ownership");
           Alcotest.(check string)
             "outside sentinel remains unchanged"
           "unchanged"
           (read_file outside_file))))

let test_base_path_lock_rejects_multiply_linked_lease_file () =
  with_base_and_run "startup-takeover-hardlinked-lease"
    (fun ~base_path ~run_dir ->
    with_temp_dir "startup-takeover-hardlinked-lease-outside" (fun outside ->
      let runtime_directory = Filename.concat base_path Common.masc_dirname in
      Unix.mkdir runtime_directory 0o755;
      let outside_file = Filename.concat outside "sentinel" in
      write_file outside_file "unchanged";
      let path =
        Server_startup_takeover.For_testing.lease_path
          ~run_dir:(Unix.realpath run_dir)
          ~canonical_base_path:(Unix.realpath base_path)
      in
      Unix.link outside_file path;
      Fun.protect
        ~finally:(fun () -> Unix.unlink path)
        (fun () ->
           (match
              Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
            with
            | Server_startup_takeover.Base_path_rejected
                (Server_startup_takeover.Lease_file_multiply_linked
                  { path = rejected_path; links }) ->
              Alcotest.(check string)
                "multiply linked lease file is identified"
                path
                rejected_path;
              Alcotest.(check bool) "link count is unsafe" true (links > 1)
            | Server_startup_takeover.Base_path_rejected rejection ->
              Alcotest.failf
                "unexpected hardlink rejection: %s"
                (Server_startup_takeover.base_path_lock_rejection_to_string
                   rejection)
            | Server_startup_takeover.Base_path_already_owned _ ->
              Alcotest.fail "hardlinked lease file looked owned"
            | Server_startup_takeover.Base_path_acquired lease ->
              Server_startup_takeover.release_base_path_lease lease;
              Alcotest.fail "hardlinked lease file acquired ownership");
           Alcotest.(check string)
             "outside hardlink target remains unchanged"
             "unchanged"
             (read_file outside_file))))

let test_base_path_lock_rejects_lease_retarget_before_commit () =
  with_base_and_run "startup-takeover-retargeted-lease"
    (fun ~base_path ~run_dir ->
    with_temp_dir "startup-takeover-retargeted-lease-outside" (fun outside ->
      let runtime_directory = Filename.concat base_path Common.masc_dirname in
      Unix.mkdir runtime_directory 0o755;
      let path =
        Server_startup_takeover.For_testing.lease_path
          ~run_dir:(Unix.realpath run_dir)
          ~canonical_base_path:(Unix.realpath base_path)
      in
      let outside_file = Filename.concat outside "sentinel" in
      (try Unix.unlink path with
       | Unix.Unix_error (Unix.ENOENT, _, _) -> ());
      write_file path "stale\n";
      write_file outside_file "unchanged";
      Fun.protect
        ~finally:(fun () ->
          match Unix.lstat path with
          | _ -> Unix.unlink path
          | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ())
        (fun () ->
           (match
              Server_startup_takeover.For_testing.acquire_base_path_lock
                ~before_lease_open:(fun () -> ())
                ~before_commit_identity_check:(fun () ->
                  Sys.remove path;
                  Unix.symlink outside_file path)
                ~before_runtime_identity_check:(fun () -> ())
                ~run_dir
                base_path
            with
            | Server_startup_takeover.Base_path_rejected
                (Server_startup_takeover.Lease_file_non_regular
                  { path = rejected_path; kind = Unix.S_LNK }) ->
              Alcotest.(check string)
                "retargeted lease path is identified"
                path
                rejected_path
            | Server_startup_takeover.Base_path_rejected rejection ->
              Alcotest.failf
                "unexpected retarget rejection: %s"
                (Server_startup_takeover.base_path_lock_rejection_to_string
                   rejection)
            | Server_startup_takeover.Base_path_already_owned _ ->
              Alcotest.fail "retargeted lease file looked owned"
            | Server_startup_takeover.Base_path_acquired lease ->
              Server_startup_takeover.release_base_path_lease lease;
              Alcotest.fail "retargeted lease file acquired ownership");
           Alcotest.(check bool)
             "outside retarget remains unchanged"
             true
             (String.equal "unchanged" (read_file outside_file)))))

let test_base_path_lock_rejects_lease_retarget_at_final_commit () =
  with_base_and_run "startup-takeover-final-lease-retarget"
    (fun ~base_path ~run_dir ->
      with_temp_dir "startup-takeover-final-lease-retarget-outside"
        (fun outside ->
          let path =
            Server_startup_takeover.For_testing.lease_path
              ~run_dir:(Unix.realpath run_dir)
              ~canonical_base_path:(Unix.realpath base_path)
          in
          let outside_file = Filename.concat outside "sentinel" in
          write_file outside_file "unchanged";
          (try Unix.unlink path with
           | Unix.Unix_error (Unix.ENOENT, _, _) -> ());
          write_file path "stale\n";
          Fun.protect
            ~finally:(fun () ->
              (match Unix.lstat path with
               | _ -> Unix.unlink path
               | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()))
            (fun () ->
              match
                Server_startup_takeover.For_testing.acquire_base_path_lock
                  ~before_lease_open:(fun () -> ())
                  ~before_commit_identity_check:(fun () -> ())
                  ~before_runtime_identity_check:(fun () ->
                    Sys.remove path;
                    Unix.symlink outside_file path)
                  ~run_dir
                  base_path
              with
              | Server_startup_takeover.Base_path_rejected
                  (Server_startup_takeover.Lease_file_non_regular
                    { path = rejected_path; kind = Unix.S_LNK }) ->
                Alcotest.(check string)
                  "final-commit lease retarget is identified"
                  path
                  rejected_path;
                Alcotest.(check string)
                  "final-commit outside target remains unchanged"
                  "unchanged"
                  (read_file outside_file)
              | Server_startup_takeover.Base_path_rejected rejection ->
                Alcotest.failf
                  "unexpected final-commit retarget rejection: %s"
                  (Server_startup_takeover.base_path_lock_rejection_to_string
                     rejection)
              | Server_startup_takeover.Base_path_already_owned _ ->
                Alcotest.fail "final-commit retarget looked already owned"
              | Server_startup_takeover.Base_path_acquired lease ->
                Server_startup_takeover.release_base_path_lease lease;
                Alcotest.fail "final-commit retarget acquired ownership")))

let test_base_path_lock_failed_commit_closes_fd () =
  with_base_and_run "startup-takeover-failed-commit-close"
    (fun ~base_path ~run_dir ->
      let path =
        Server_startup_takeover.For_testing.lease_path
          ~run_dir:(Unix.realpath run_dir)
          ~canonical_base_path:(Unix.realpath base_path)
      in
      write_file path "stale\n";
      Fun.protect
        ~finally:(fun () ->
          match Unix.lstat path with
          | _ -> Unix.unlink path
          | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ())
        (fun () ->
          match
            Server_startup_takeover.For_testing.acquire_base_path_lock
              ~before_lease_commit:(fun fd -> Unix.close fd)
              ~before_lease_open:(fun () -> ())
              ~before_commit_identity_check:(fun () ->
                Alcotest.fail "acquisition continued after failed lock commit")
              ~before_runtime_identity_check:(fun () ->
                Alcotest.fail "acquisition continued after failed lock commit")
              ~run_dir
              base_path
          with
          | Server_startup_takeover.Base_path_rejected
              (Server_startup_takeover.Lease_io_failed
                { operation = "commit_base_path_lease"
                ; path = rejected_path
                ; reason
                })
            when String.equal rejected_path path ->
            (* The reason proves the exact deterministic path: [lockf] raised
               [EBADF] on the test-closed descriptor, no identity hook ran, and
               the rejected descriptor was closed — the close itself raising
               [EBADF] again is the fence-building [Failed_close] path, so the
               lease descriptor was already not live in this process. *)
            Alcotest.(check string)
              "failed-commit rejection is the deterministic EBADF"
              ("Unix.Unix_error(Unix.EBADF, \"lockf\", \"\"); close failed: \
                Unix.Unix_error(Unix.EBADF, \"close\", \"\")"
              |> String.trim)
              reason
          | Server_startup_takeover.Base_path_rejected rejection ->
            Alcotest.failf
              "unexpected failed-commit rejection: %s"
              (Server_startup_takeover.base_path_lock_rejection_to_string
                 rejection)
          | Server_startup_takeover.Base_path_already_owned _ ->
            Alcotest.fail "failed commit looked already owned"
          | Server_startup_takeover.Base_path_acquired lease ->
            Server_startup_takeover.release_base_path_lease lease;
            Alcotest.fail "failed commit acquired ownership"))

(* [Unix.lockf] fails while the [close] in the production path succeeds: the
   descriptor is swapped for a read-only stub with [dup2] before the lease
   commit, so [lockf F_TLOCK] raises [EBADF] but the same descriptor number is
   still open and closable. This walks the remaining branch of the commit
   failure handling — the close success branch that leaves no fence. The
   swapped-in descriptor is checked for closure with [fstat] before the fresh
   re-acquisition, and the re-acquisition proves no [Failed_close] fence
   remains after the successful close. *)
let test_base_path_lock_failed_commit_close_succeeds_releases_lock () =
  with_base_and_run "startup-takeover-failed-commit-close-succeeds"
    (fun ~base_path ~run_dir ->
      let path =
        Server_startup_takeover.For_testing.lease_path
          ~run_dir:(Unix.realpath run_dir)
          ~canonical_base_path:(Unix.realpath base_path)
      in
      write_file path "stale\n";
      let stub_fd = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
      let swapped_fd = ref None in
      Fun.protect
        ~finally:(fun () ->
          (try Unix.close stub_fd with
          | Unix.Unix_error (Unix.EBADF, _, _) -> ());
          match Unix.lstat path with
          | _ -> Unix.unlink path
          | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ())
        (fun () ->
          match
            Server_startup_takeover.For_testing.acquire_base_path_lock
              ~before_lease_commit:(fun fd ->
                (* The stub is not a regular file, so even a successful
                   [lockf F_TLOCK] could not persist; [dup2] makes [lockf]
                   raise [EBADF] deterministically while the descriptor number
                   stays open and its later [close] succeeds. *)
                Unix.dup2 stub_fd fd;
                swapped_fd := Some fd)
              ~before_lease_open:(fun () -> ())
              ~before_commit_identity_check:(fun () ->
                Alcotest.fail "acquisition continued after failed lock commit")
              ~before_runtime_identity_check:(fun () ->
                Alcotest.fail "acquisition continued after failed lock commit")
              ~run_dir
              base_path
          with
          | Server_startup_takeover.Base_path_rejected
              (Server_startup_takeover.Lease_io_failed
                {
                  operation = "commit_base_path_lease";
                  path = rejected_path;
                  reason;
                })
            when String.equal rejected_path path ->
            Alcotest.(check string)
              "failed-commit rejection reports only the lockf failure"
              "Unix.Unix_error(Unix.EBADF, \"lockf\", \"\")"
              (String.trim reason);
            (* The production close must have actually closed the swapped-in
               descriptor: [fstat] it before the fresh acquisition, since the
               new lease may receive the same descriptor number. Without the
               close this [fstat] succeeds on the still-open stub, so this
               check keeps the case honest about the closed-vs-left-open
               difference. *)
            (match !swapped_fd with
            | Some fd -> (
              match Unix.fstat fd with
              | exception Unix.Unix_error (Unix.EBADF, "fstat", "") -> ()
              | exception Unix.Unix_error (code, fn, _) ->
                Alcotest.failf
                  "swapped-in lease descriptor was not closed: fstat raised \
                   %s (%s)"
                  (Unix.error_message code)
                  fn
              | _ ->
                Alcotest.fail
                  "the swapped-in lease descriptor is still open; the \
                   close-success branch left it open")
            | None -> Alcotest.fail "before_lease_commit hook never ran");
            (* The close succeeded, so no [Failed_close] fence is recorded and
               a fresh acquisition must take the lock back. *)
            (match
               Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
             with
            | Server_startup_takeover.Base_path_acquired fresh ->
              Server_startup_takeover.release_base_path_lease fresh
            | _ -> Alcotest.fail "lock survived the failed commit")
          | Server_startup_takeover.Base_path_rejected rejection ->
            Alcotest.failf
              "unexpected failed-commit rejection: %s"
              (Server_startup_takeover.base_path_lock_rejection_to_string
                 rejection)
          | Server_startup_takeover.Base_path_already_owned _ ->
            Alcotest.fail "failed commit looked already owned"
          | Server_startup_takeover.Base_path_acquired lease ->
            Server_startup_takeover.release_base_path_lease lease;
            Alcotest.fail "failed commit acquired ownership"))

let test_base_path_lock_external_location_and_full_digest () =
  with_base_and_run "startup-takeover-external-location"
    (fun ~base_path ~run_dir ->
      let canonical_base_path = Unix.realpath base_path in
      let path =
        Server_startup_takeover.For_testing.lease_path
          ~run_dir:(Unix.realpath run_dir)
          ~canonical_base_path
      in
      let lease_directory = Filename.dirname path in
      let digest =
        Printf.sprintf "masc-base-path-lease:%d:%d"
          (Unix.stat canonical_base_path).Unix.st_dev
          (Unix.stat canonical_base_path).Unix.st_ino
        |> Agent_core_sha256.digest_string |> Agent_core_sha256.to_hex
      in
      Alcotest.(check string)
        "lease filename is the full (st_dev, st_ino) identity digest"
        (Printf.sprintf "masc-base-path-owner-v2-%s.lease" digest)
        (Filename.basename path);
      (match
         Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
       with
       | Server_startup_takeover.Base_path_acquired lease ->
         Fun.protect
           ~finally:(fun () ->
             Server_startup_takeover.release_base_path_lease lease)
           (fun () ->
             let runtime_directory =
               Filename.concat base_path Common.masc_dirname
             in
             Alcotest.(check bool)
               "runtime directory is established only after the external lease"
               true
               (Sys.file_exists runtime_directory
                && Sys.is_directory runtime_directory);
             Alcotest.(check string)
               "private lease directory is stored in canonical host run directory"
               (Unix.realpath run_dir)
               (Filename.dirname lease_directory);
             let lease_directory_stat = Unix.lstat lease_directory in
             Alcotest.(check int)
               "private lease directory owner"
               (Unix.geteuid ())
               lease_directory_stat.st_uid;
             Alcotest.(check int)
               "private lease directory mode"
               0o700
               (lease_directory_stat.st_perm land 0o7777);
             Alcotest.(check bool)
               "no BasePath-local lease file is created"
               false
               (Sys.file_exists
                  (Filename.concat runtime_directory "server-owner.pid")))
       | Server_startup_takeover.Base_path_already_owned _ ->
         Alcotest.fail "fresh external BasePath lease was already owned"
       | Server_startup_takeover.Base_path_rejected rejection ->
         Alcotest.failf
           "fresh external BasePath lease was rejected: %s"
           (Server_startup_takeover.base_path_lock_rejection_to_string rejection)))

let test_base_path_lock_pre_open_runtime_retarget_has_no_outside_write () =
  with_base_and_run "startup-takeover-pre-open-runtime-retarget"
    (fun ~base_path ~run_dir ->
      with_temp_dir "startup-takeover-pre-open-runtime-outside" (fun outside ->
        let runtime_directory =
          Filename.concat base_path Common.masc_dirname
        in
        let canonical_runtime_directory =
          Filename.concat (Unix.realpath base_path) Common.masc_dirname
        in
        Fun.protect
          ~finally:(fun () ->
            match Unix.lstat runtime_directory with
            | stat when stat.Unix.st_kind = Unix.S_LNK ->
              Unix.unlink runtime_directory
            | _ -> ()
            | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ())
          (fun () ->
            match
              Server_startup_takeover.For_testing.acquire_base_path_lock
                ~before_lease_open:(fun () ->
                  Unix.symlink outside runtime_directory)
                ~before_commit_identity_check:(fun () -> ())
                ~before_runtime_identity_check:(fun () -> ())
                ~run_dir
                base_path
            with
            | Server_startup_takeover.Base_path_rejected
                (Server_startup_takeover.Runtime_directory_rejected
                  (Fs_compat.Owned_path_non_directory
                    { path; kind = Unix.S_LNK })) ->
              Alcotest.(check string)
                "pre-open runtime retarget is identified"
                canonical_runtime_directory
                path;
              Alcotest.(check bool)
                "retarget cannot create a BasePath lease outside"
                false
                (Sys.file_exists (Filename.concat outside "server-owner.pid"))
            | Server_startup_takeover.Base_path_rejected rejection ->
              Alcotest.failf
                "unexpected pre-open runtime rejection: %s"
                (Server_startup_takeover.base_path_lock_rejection_to_string
                   rejection)
            | Server_startup_takeover.Base_path_already_owned _ ->
              Alcotest.fail "pre-open retarget looked already owned"
            | Server_startup_takeover.Base_path_acquired lease ->
              Server_startup_takeover.release_base_path_lease lease;
              Alcotest.fail "pre-open runtime symlink acquired ownership")))

let test_base_path_lock_rejects_invalid_run_directory () =
  with_temp_dir "startup-takeover-invalid-run-base" (fun base_path ->
    with_temp_dir "startup-takeover-invalid-run-parent" (fun parent ->
      let missing = Filename.concat parent "missing" in
      (match
         Server_startup_takeover.acquire_base_path_lock
           ~run_dir:missing
           base_path
       with
       | Server_startup_takeover.Base_path_rejected
           (Server_startup_takeover.Run_directory_canonicalization_failed
             { run_dir; _ }) ->
         Alcotest.(check string) "missing run directory" missing run_dir
       | Server_startup_takeover.Base_path_rejected rejection ->
         Alcotest.failf
           "unexpected missing run-directory rejection: %s"
           (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
       | Server_startup_takeover.Base_path_already_owned _
       | Server_startup_takeover.Base_path_acquired _ ->
         Alcotest.fail "missing run directory admitted a lease");
      let file = Filename.concat parent "not-a-directory" in
      write_file file "occupied";
      match
        Server_startup_takeover.acquire_base_path_lock ~run_dir:file base_path
      with
      | Server_startup_takeover.Base_path_rejected
          (Server_startup_takeover.Run_directory_not_directory
            { path; kind = Unix.S_REG }) ->
        Alcotest.(check string)
          "non-directory run path"
          (Unix.realpath file)
          path
      | Server_startup_takeover.Base_path_rejected rejection ->
        Alcotest.failf
          "unexpected non-directory run rejection: %s"
          (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
      | Server_startup_takeover.Base_path_already_owned _
      | Server_startup_takeover.Base_path_acquired _ ->
        Alcotest.fail "non-directory run path admitted a lease"))

let test_base_path_lock_rejects_run_directory_retarget () =
  with_base_and_run "startup-takeover-run-retarget"
    (fun ~base_path ~run_dir ->
      let canonical_run_dir = Unix.realpath run_dir in
      let retired = run_dir ^ ".retired" in
      Fun.protect
        ~finally:(fun () ->
          if Sys.file_exists run_dir then rm_rf run_dir;
          if Sys.file_exists retired then Unix.rename retired run_dir)
        (fun () ->
          match
            Server_startup_takeover.For_testing.acquire_base_path_lock
              ~before_lease_open:(fun () ->
                Unix.rename run_dir retired;
                Unix.mkdir run_dir 0o755)
              ~before_commit_identity_check:(fun () -> ())
              ~before_runtime_identity_check:(fun () -> ())
              ~run_dir
              base_path
          with
          | Server_startup_takeover.Base_path_rejected
              (Server_startup_takeover.Lease_identity_changed
                { path = rejected_path }) ->
            Alcotest.(check string)
              "retargeted host run directory identity"
              canonical_run_dir
              rejected_path
          | Server_startup_takeover.Base_path_rejected rejection ->
            Alcotest.failf
              "unexpected run-directory retarget rejection: %s"
              (Server_startup_takeover.base_path_lock_rejection_to_string
                 rejection)
          | Server_startup_takeover.Base_path_already_owned _ ->
            Alcotest.fail "retargeted run directory looked already owned"
          | Server_startup_takeover.Base_path_acquired lease ->
            Server_startup_takeover.release_base_path_lease lease;
            Alcotest.fail "retargeted run directory acquired ownership"))

let test_base_path_lock_rejects_runtime_retarget_after_establish () =
  with_base_and_run "startup-takeover-runtime-retarget-after-establish"
    (fun ~base_path ~run_dir ->
      let runtime_directory = Filename.concat base_path Common.masc_dirname in
      let canonical_runtime_directory =
        Filename.concat (Unix.realpath base_path) Common.masc_dirname
      in
      let retired_runtime = Filename.concat base_path ".masc-retired" in
      Unix.mkdir runtime_directory 0o755;
      match
        Server_startup_takeover.For_testing.acquire_base_path_lock
          ~before_lease_open:(fun () -> ())
          ~before_commit_identity_check:(fun () -> ())
          ~before_runtime_identity_check:(fun () ->
            Unix.rename runtime_directory retired_runtime;
            Unix.mkdir runtime_directory 0o755)
          ~run_dir
          base_path
      with
      | Server_startup_takeover.Base_path_rejected
          (Server_startup_takeover.Lease_identity_changed
            { path = rejected_path }) ->
        Alcotest.(check string)
          "post-establish runtime replacement is identified"
          canonical_runtime_directory
          rejected_path;
        Alcotest.(check bool)
          "runtime replacement never receives a local lease file"
          false
          (Sys.file_exists
             (Filename.concat runtime_directory "server-owner.pid"))
      | Server_startup_takeover.Base_path_rejected rejection ->
        Alcotest.failf
          "unexpected post-establish runtime rejection: %s"
          (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
      | Server_startup_takeover.Base_path_already_owned _ ->
        Alcotest.fail "post-establish runtime replacement looked already owned"
      | Server_startup_takeover.Base_path_acquired lease ->
        Server_startup_takeover.release_base_path_lease lease;
        Alcotest.fail "post-establish runtime replacement acquired ownership")

let test_contention_recovery_guidance () =
  let lock_path = "/tmp/shared lease/'quoted'/owner.lock" in
  List.iter
    (fun owner ->
      let message =
        Server_startup_takeover.base_path_contention_message
          ~base_path:"/workspace" ~lock_path owner
      in
      List.iter
        (fun expected ->
          Alcotest.(check bool) expected true
            (String_util.contains_substring message expected))
        [ Filename.quote lock_path
        ; "services or containers"
        ; "owning host"
        ; "If lsof is installed"
        ; "open files alone do not prove lock ownership"
        ; "Do not signal the recorded PID"
        ])
    [ Server_startup_takeover.Owner_this_process (Unix.getpid ())
    ; Server_startup_takeover.Owner_recorded (Unix.getpid ())
    ; Server_startup_takeover.Owner_unnamed
    ]

let () =
  Alcotest.run "Server_startup_takeover"
    [
      ( "helpers",
        [
          Alcotest.test_case "contention recovery includes host and lock evidence"
            `Quick test_contention_recovery_guidance;
        ] );
      ( "takeover",
        [
          Alcotest.test_case "concurrent BasePath lease blocks takeover" `Quick
            test_base_path_lock_rejects_concurrent_lease;
          Alcotest.test_case "a waiting start takes the lease when the owner exits"
            `Quick test_waiting_acquisition_takes_the_lease_when_the_owner_exits;
          Alcotest.test_case "a second waiter is refused while one waits"
            `Quick test_a_second_waiter_is_refused_while_one_waits;
          Alcotest.test_case "a recorded owner that is gone is named as stale"
            `Quick test_base_path_lock_reports_a_recorded_owner_that_is_gone;
          Alcotest.test_case "stale base-path owner is reclaimed" `Quick
            test_base_path_lock_reclaims_stale_pid_file;
          Alcotest.test_case "same-process symlink alias is rejected" `Quick
            test_base_path_lock_rejects_same_process_symlink_alias;
          Alcotest.test_case
            "one directory shares one lease across realpath spellings" `Quick
            test_base_path_lock_shares_one_lease_across_realpath_spellings;
          Alcotest.test_case "stale lease release preserves active ownership"
            `Quick test_stale_lease_release_preserves_new_active_lease;
          Alcotest.test_case "linked runtime directory is rejected" `Quick
            test_base_path_lock_rejects_linked_runtime_directory;
          Alcotest.test_case "linked private lease directory is rejected" `Quick
            test_base_path_lock_rejects_linked_lease_directory;
          Alcotest.test_case "permissive private lease directory is rejected"
            `Quick test_base_path_lock_rejects_permissive_lease_directory;
          Alcotest.test_case "unprotected shared run directory is rejected"
            `Quick test_base_path_lock_rejects_unprotected_shared_run_directory;
          Alcotest.test_case "sticky shared run directory is accepted" `Quick
            test_base_path_lock_accepts_sticky_shared_run_directory;
          Alcotest.test_case "private lease directory pre-open retarget is rejected"
            `Quick
            test_base_path_lock_rejects_lease_directory_retarget_before_open;
          Alcotest.test_case "private lease directory post-open retarget is rejected"
            `Quick
            test_base_path_lock_rejects_lease_directory_retarget_after_open;
          Alcotest.test_case "linked lease file is rejected" `Quick
            test_base_path_lock_rejects_linked_lease_file;
          Alcotest.test_case "multiply linked lease file is rejected" `Quick
            test_base_path_lock_rejects_multiply_linked_lease_file;
          Alcotest.test_case "lease retarget before commit is rejected" `Quick
            test_base_path_lock_rejects_lease_retarget_before_commit;
          Alcotest.test_case "lease retarget at final commit is rejected" `Quick
            test_base_path_lock_rejects_lease_retarget_at_final_commit;
          Alcotest.test_case "failed lock commit closes the lease descriptor"
            `Quick test_base_path_lock_failed_commit_closes_fd;
          Alcotest.test_case
            "failed lock commit with close success releases the lock" `Quick
            test_base_path_lock_failed_commit_close_succeeds_releases_lock;
          Alcotest.test_case "lease is external and full-digest keyed" `Quick
            test_base_path_lock_external_location_and_full_digest;
          Alcotest.test_case "pre-open runtime retarget has no outside write" `Quick
            test_base_path_lock_pre_open_runtime_retarget_has_no_outside_write;
          Alcotest.test_case "invalid host run directory is rejected" `Quick
            test_base_path_lock_rejects_invalid_run_directory;
          Alcotest.test_case "host run directory retarget is rejected" `Quick
            test_base_path_lock_rejects_run_directory_retarget;
          Alcotest.test_case "post-establish runtime retarget is rejected" `Quick
            test_base_path_lock_rejects_runtime_retarget_after_establish;
        ] );
    ]