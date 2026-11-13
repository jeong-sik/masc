open Masc

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

(* [Sys.is_directory] stats through a link: a directory alias is walked into and
   its [Unix.rmdir] fails with ENOTDIR, and a dangling link reads false from
   [Sys.file_exists] and is skipped, leaving the parent behind (#26648). Read the
   entry itself with [Unix.lstat] and only a real directory is descended. *)
let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path
    |> Array.iter (fun name -> rm_rf (Filename.concat path name));
    Unix.rmdir path
  | _ -> Sys.remove path

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

(* A waiter that won the slot, committed the lease, and exec'd (as [masc
   start] does between acquiring the lease and serving) re-enters this same
   acquisition post-exec with the lease file already naming it. It must not
   re-contend the single waiter slot: a contender that grabbed the slot in
   the exec gap would otherwise kill the legitimate winner with
   Another_replacement_waits after it already won (2026-11-04 live
   incident). The winner re-enters in the same process here (no exec in
   tests, so the in-process table answers Already_owned); the lease record,
   not the process image, is what the bypass keys on. A contender holds the
   slot during the re-entry, so without the bypass the winner is refused. *)
let test_recorded_owner_is_not_refused_as_second_waiter () =
  with_base_and_run "startup-takeover-base-path-winner-reentry"
    (fun ~base_path ~run_dir ->
    let owner_pid, release_owner = spawn_lease_owner ~run_dir base_path in
    let waiting_read, waiting_write = Unix.pipe () in
    let won_read, won_write = Unix.pipe () in
    let go_read, go_write = Unix.pipe () in
    match Unix.fork () with
    | 0 ->
      close_quietly waiting_read;
      close_quietly won_read;
      close_quietly go_write;
      close_quietly release_owner;
      let on_wait _ = ignore (Unix.write_substring waiting_write "W" 0 1 : int) in
      (match
         Server_startup_takeover.acquire_base_path_lock_after_owner_exits
           ~run_dir ~on_wait base_path
       with
       | Ok (Server_startup_takeover.Base_path_acquired lease) ->
         ignore (Unix.write_substring won_write "1" 0 1 : int);
         let buffer = Bytes.create 1 in
         ignore (Unix.read go_read buffer 0 1 : int);
         let waited = ref false in
         let outcome =
           match
             Server_startup_takeover.acquire_base_path_lock_after_owner_exits
               ~run_dir
               ~on_wait:(fun _ -> waited := true)
               base_path
           with
           | Ok (Server_startup_takeover.Base_path_already_owned _) ->
             if !waited then 6 else 0
           | Ok
               ( Server_startup_takeover.Base_path_acquired _
               | Server_startup_takeover.Base_path_rejected _ ) -> 5
           | Error (Server_startup_takeover.Another_replacement_waits _) -> 4
         in
         Server_startup_takeover.release_base_path_lease lease;
         Unix._exit outcome
       | Ok _ | Error _ -> Unix._exit 3)
    | waiter_pid ->
      close_quietly waiting_write;
      close_quietly won_write;
      close_quietly go_read;
      let queued_read, queued_write = Unix.pipe () in
      let buffer = Bytes.create 1 in
      Fun.protect
        ~finally:(fun () ->
          close_quietly waiting_read;
          close_quietly won_read;
          close_quietly go_write;
          close_quietly queued_read;
          close_quietly queued_write;
          close_quietly release_owner;
          if process_alive waiter_pid then stop_process waiter_pid;
          if process_alive owner_pid then stop_process owner_pid)
        (fun () ->
           Alcotest.(check int) "the winner is waiting" 1
             (Unix.read waiting_read buffer 0 1);
           ignore (Unix.write_substring release_owner "1" 0 1 : int);
           Alcotest.(check int) "the winner committed the lease" 1
             (Unix.read won_read buffer 0 1);
           owner_exited_on_its_own owner_pid;
           let contender_pid =
             match Unix.fork () with
             | 0 ->
               (* Close only what is open here: the parent already closed
                  waiting_write, won_write and go_read, so their numbers were
                  recycled by the queued pipe itself; naming them would close
                  the queued pipe out from under this child (EBADF). *)
               close_quietly waiting_read;
               close_quietly won_read;
               close_quietly go_write;
               close_quietly queued_read;
               close_quietly release_owner;
               let on_wait _ =
                 ignore (Unix.write_substring queued_write "Q" 0 1 : int)
               in
               (* The contender must block on the winner's lease until the
                  parent stops it; any return or crash is reported back so a
                  failure names the outcome instead of hanging on EOF. *)
               (match
                  Server_startup_takeover.acquire_base_path_lock_after_owner_exits
                    ~run_dir ~on_wait base_path
                with
                | Ok _ ->
                  ignore (Unix.write_substring queued_write "O" 0 1 : int);
                  Unix._exit 7
                | Error _ ->
                  ignore (Unix.write_substring queued_write "E" 0 1 : int);
                  Unix._exit 7
                | exception _ ->
                  (try ignore (Unix.write_substring queued_write "X" 0 1 : int)
                   with Unix.Unix_error _ -> ());
                  Unix._exit 9)
             | contender_pid ->
               close_quietly queued_write;
               contender_pid
           in
           Fun.protect
             ~finally:(fun () ->
               if process_alive contender_pid then stop_process contender_pid)
             (fun () ->
                Alcotest.(check char)
                  "the contender is waiting (Q), not returned (O), refused (E), or crashed (X)"
                  'Q'
                  (let got = Unix.read queued_read buffer 0 1 in
                   if got <> 1
                   then Alcotest.failf "contender exited early (%d bytes)" got
                   else Bytes.get buffer 0);
                ignore (Unix.write_substring go_write "1" 0 1 : int);
                (match waitpid_nointr waiter_pid with
                 | Some (_, Unix.WEXITED 0) -> ()
                 | Some (_, Unix.WEXITED code) ->
                   Alcotest.failf
                     "winner re-entry exited %d (4 means refused as a second waiter)"
                     code
                 | Some (_, Unix.WSIGNALED signal) ->
                   Alcotest.failf "winner re-entry died on signal %d" signal
                 | Some (_, Unix.WSTOPPED _) | None ->
                   Alcotest.fail "winner re-entry did not exit on its own"))))

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

(* Without MASC_BASE_PATH_LEASE_DIR the lease root comes from the BasePath
   itself, so every process that names it, under any spelling and any TMPDIR,
   finds the one lease. *)
let test_lease_root_beside_base_path_is_shared_by_every_spelling () =
  if Sys.os_type <> "Unix" then Alcotest.skip ();
  with_temp_dir "startup-takeover-owner-root" (fun dir ->
    let real_base = Filename.concat dir "real" in
    Unix.mkdir real_base 0o755;
    let alias = Filename.concat dir "alias" in
    Unix.symlink real_base alias;
    Fun.protect
      ~finally:(fun () -> Sys.remove alias)
      (fun () ->
        let run_dir_of base_path =
          match
            Server_startup_takeover.lease_run_dir Host_config.Beside_base_path
              ~base_path
          with
          | Ok run_dir -> run_dir
          | Error rejection ->
            Alcotest.failf
              "the lease root was refused: %s"
              (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
        in
        let run_dir = run_dir_of real_base in
        Alcotest.(check string)
          "the lease root sits beside .masc"
          (Filename.concat (Unix.realpath real_base) ".masc-owner")
          run_dir;
        Alcotest.(check int)
          "the lease root is private to this UID"
          0o700
          ((Unix.stat run_dir).st_perm land 0o777);
        match Server_startup_takeover.acquire_base_path_lock ~run_dir real_base with
        | Server_startup_takeover.Base_path_acquired lease ->
          Fun.protect
            ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease)
            (fun () ->
              match
                Server_startup_takeover.acquire_base_path_lock
                  ~run_dir:(run_dir_of alias)
                  alias
              with
              | Server_startup_takeover.Base_path_already_owned _ -> ()
              | Server_startup_takeover.Base_path_acquired second ->
                Server_startup_takeover.release_base_path_lease second;
                Alcotest.fail "another spelling acquired a second lease"
              | Server_startup_takeover.Base_path_rejected rejection ->
                Alcotest.failf
                  "another spelling was rejected: %s"
                  (Server_startup_takeover.base_path_lock_rejection_to_string
                     rejection))
        | Server_startup_takeover.Base_path_already_owned _ ->
          Alcotest.fail "a fresh BasePath was already owned"
        | Server_startup_takeover.Base_path_rejected rejection ->
          Alcotest.failf
            "a valid BasePath was rejected: %s"
            (Server_startup_takeover.base_path_lock_rejection_to_string rejection)))

(* A command that only reads asks for the lease file before it reads the
   owner: reading the owner makes the private lease directory and the lease
   file when they are missing. *)
let test_lease_file_presence_is_read_without_making_anything () =
  if Sys.os_type <> "Unix" then Alcotest.skip ();
  with_temp_dir "startup-takeover-lease-present" (fun dir ->
    let rejected what rejection =
      Alcotest.failf
        "%s: %s"
        what
        (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
    in
    let present root ~base_path =
      match Server_startup_takeover.lease_file_present root ~base_path with
      | Ok present -> present
      | Error rejection -> rejected "the lease file could not be looked for" rejection
    in
    let lease_root base_path =
      match
        Server_startup_takeover.lease_run_dir Host_config.Beside_base_path ~base_path
      with
      | Ok run_dir -> run_dir
      | Error rejection -> rejected "the lease root was refused" rejection
    in
    let entries path = List.sort String.compare (Array.to_list (Sys.readdir path)) in
    let beside = Host_config.Beside_base_path in
    let base_path = Filename.concat dir "workspace" in
    Alcotest.(check bool) "a BasePath that is not there" false (present beside ~base_path);
    Alcotest.(check (list string)) "and it was not made" [] (entries dir);
    Unix.mkdir base_path 0o755;
    Alcotest.(check bool) "a BasePath nothing started in" false (present beside ~base_path);
    Alcotest.(check (list string)) "nothing was made in it" [] (entries base_path);
    let run_dir = lease_root base_path in
    Alcotest.(check bool) "a lease root with nothing in it" false (present beside ~base_path);
    Alcotest.(check (list string)) "nothing was made in it" [] (entries run_dir);
    (* The helper that names the lease file makes the private lease
       directory, as a reader of the announcement does. *)
    let lease_path =
      Server_startup_takeover.For_testing.lease_path
        ~run_dir:(Unix.realpath run_dir)
        ~canonical_base_path:(Unix.realpath base_path)
    in
    Alcotest.(check bool)
      "a private lease directory with no lease file"
      false
      (present beside ~base_path);
    Alcotest.(check (list string))
      "no lease file was made"
      []
      (entries (Filename.dirname lease_path));
    (match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
     | Server_startup_takeover.Base_path_acquired lease ->
       Fun.protect
         ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease)
         (fun () ->
           Alcotest.(check bool) "the lease file of an owner" true (present beside ~base_path);
           Alcotest.(check bool)
             "under a root the host names"
             true
             (present (Host_config.Lease_dir_override run_dir) ~base_path);
           Alcotest.(check bool)
             "another root has no lease of it"
             false
             (present (Host_config.Lease_dir_override dir) ~base_path))
     | Server_startup_takeover.Base_path_already_owned _ ->
       Alcotest.fail "a fresh BasePath was already owned"
     | Server_startup_takeover.Base_path_rejected rejection ->
       rejected "a valid BasePath was rejected" rejection);
    (* An entry on the way that is no directory answers [true]: the read of
       the owner goes through the preparation an acquisition goes through,
       which refuses the entry before it makes anything. *)
    let blocked = Filename.concat dir "blocked" in
    Unix.mkdir blocked 0o755;
    let blocked_root = lease_root blocked in
    Unix.rmdir blocked_root;
    Out_channel.with_open_bin blocked_root (fun (_ : Out_channel.t) -> ());
    Alcotest.(check bool) "a lease root that is a file" true (present beside ~base_path:blocked);
    (match Server_startup_takeover.acquire_base_path_lock ~run_dir:blocked_root blocked with
     | Server_startup_takeover.Base_path_rejected
         (Server_startup_takeover.Run_directory_not_directory _) -> ()
     | Server_startup_takeover.Base_path_rejected rejection ->
       rejected "the file was refused for another reason" rejection
     | Server_startup_takeover.Base_path_acquired lease ->
       Server_startup_takeover.release_base_path_lease lease;
       Alcotest.fail "a lease was acquired under a file"
     | Server_startup_takeover.Base_path_already_owned _ ->
       Alcotest.fail "a file was read as an owned lease");
    Alcotest.(check (list string))
      "the refusal made nothing"
      [ Filename.basename blocked_root ]
      (entries blocked))

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

(* The lease fixtures link [alias] at a directory inside the tree their cleanup
   removes, so the cleanup has to finish that link itself; a dangling one must
   not be skipped and a followed one must not reach the target (#26648). *)
let test_rm_rf_unlinks_symlinks () =
  let fresh_dir prefix =
    let path = Filename.temp_file prefix "" in
    Sys.remove path;
    Unix.mkdir path 0o755;
    path
  in
  let root = fresh_dir "startup-rm-rf-root" in
  let kept_dir = fresh_dir "startup-rm-rf-kept" in
  Fun.protect
    ~finally:(fun () ->
      rm_rf root;
      rm_rf kept_dir)
  @@ fun () ->
  let kept = Filename.concat kept_dir "kept" in
  write_file kept "kept";
  Unix.mkdir (Filename.concat root "real") 0o755;
  Unix.symlink kept_dir (Filename.concat root "alias");
  Unix.symlink (Filename.concat root "gone") (Filename.concat root "dangling");
  rm_rf root;
  Alcotest.(check bool) "the tree is gone" false (Sys.file_exists root);
  Alcotest.(check bool) "the link target survived" true (Sys.file_exists kept);
  Alcotest.(check string) "the link target kept its contents" "kept"
    (read_file kept)

(* The account server announcement. *)

let announcement_label = function
  | Ok None -> "nothing announced"
  | Ok (Some { Server_startup_takeover.pid; port }) ->
    Printf.sprintf "pid %d announces port %d" pid port
  | Error rejection ->
    "rejected: " ^ Server_startup_takeover.base_path_lock_rejection_to_string rejection

let check_announcement message expected ~run_dir base_path =
  Alcotest.(check string) message (announcement_label expected)
    (announcement_label
       (Server_startup_takeover.account_server_announcement ~run_dir ~base_path))

let port_holder_label = function
  | Ok None -> "no process holds the byte of the port"
  | Ok (Some pid) -> Printf.sprintf "pid %d holds the byte of the port" pid
  | Error rejection ->
    "rejected: " ^ Server_startup_takeover.base_path_lock_rejection_to_string rejection

let check_port_holder message expected ~run_dir base_path ~port =
  Alcotest.(check string) message (port_holder_label expected)
    (port_holder_label
       (Server_startup_takeover.account_server_port_holder ~run_dir ~base_path ~port))

(* What an announcement came to, with what a refusal names. The path is left
   out: it is a file of the temporary directory. *)
let announced_label = function
  | Ok () -> "announced"
  | Error (Server_startup_takeover.Announcement_port_invalid { port }) ->
    Printf.sprintf "%d is not a port" port
  | Error (Server_startup_takeover.Announcement_already_made { port; path = _ }) ->
    Printf.sprintf "this process already announces port %d" port
  | Error (Server_startup_takeover.Announcement_lease_not_active { path = _ }) ->
    "the lease handle is not the active owner"
  | Error (Server_startup_takeover.Announcement_port_locked { port; holder = Some pid; path = _ }) ->
    Printf.sprintf "the byte of port %d is locked by pid %d" port pid
  | Error (Server_startup_takeover.Announcement_port_locked { port; holder = None; path = _ }) ->
    Printf.sprintf "the byte of port %d is locked by a process the kernel did not name" port
  | Error rejection ->
    "rejected: " ^ Server_startup_takeover.base_path_lock_rejection_to_string rejection

let check_announced message expected actual =
  Alcotest.(check string) message expected (announced_label actual)

(* The file the announcement lock is taken on. The suffix is written out here
   so that a change of the name in the library fails these cases. *)
let announcement_path ~run_dir base_path =
  Server_startup_takeover.For_testing.lease_path
    ~run_dir:(Unix.realpath run_dir)
    ~canonical_base_path:(Unix.realpath base_path)
  ^ ".account-server"

(* Another process holds the lease and announces [port] with [announce]; it
   leaves when the write end it is given back closes. *)
let spawn_announcing_owner ~announce ~run_dir base_path ~port =
  let ready_read, ready_write = Unix.pipe () in
  let release_read, release_write = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
    close_quietly ready_read;
    close_quietly release_write;
    (match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
     | Server_startup_takeover.Base_path_acquired lease ->
       (match announce lease ~port with
        | Ok () ->
          ignore (Unix.write_substring ready_write "1" 0 1 : int);
          let buffer = Bytes.create 1 in
          ignore (Unix.read release_read buffer 0 1 : int);
          Unix._exit 0
        | Error _ -> Unix._exit 4)
     | Server_startup_takeover.Base_path_already_owned _ -> Unix._exit 2
     | Server_startup_takeover.Base_path_rejected _ -> Unix._exit 3)
  | owner_pid ->
    close_quietly ready_write;
    close_quietly release_read;
    let buffer = Bytes.create 1 in
    Alcotest.(check int) "the owner announced its port" 1
      (Unix.read ready_read buffer 0 1);
    close_quietly ready_read;
    (owner_pid, release_write)

(* Asks the kernel from another process whether the byte of [port] in the
   file at [path] is locked: a lock is not inherited across fork, and the
   tables of this process are. A file that is not there holds no lock. *)
let byte_is_held_in_the_kernel path ~port =
  match Unix.fork () with
  | 0 ->
    (match
       let fd = Unix.openfile path [ Unix.O_RDWR ] 0o600 in
       ignore (Unix.lseek fd port Unix.SEEK_SET : int);
       Unix.lockf fd Unix.F_TEST 1
     with
     | () -> Unix._exit 1
     | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> Unix._exit 0
     | exception Unix.Unix_error _ -> Unix._exit 2)
  | probe_pid ->
    (match waitpid_nointr probe_pid with
     | Some (_, Unix.WEXITED 0) -> true
     | Some (_, _) | None -> false)

let announcement_is_held_in_the_kernel ~run_dir base_path ~port =
  byte_is_held_in_the_kernel (announcement_path ~run_dir base_path) ~port

(* The end of a child interrupts a read once an Eio loop left its SIGCHLD
   handler in this process. *)
let rec read_nointr fd buffer =
  try Unix.read fd buffer 0 1 with
  | Unix.Unix_error (Unix.EINTR, _, _) -> read_nointr fd buffer

(* A process without the lease locks one byte of the announcement file, as
   any process of this user can. It leaves when the write end closes. *)
let spawn_byte_locker ~run_dir base_path ~byte =
  let path = announcement_path ~run_dir base_path in
  let ready_read, ready_write = Unix.pipe () in
  let release_read, release_write = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
    close_quietly ready_read;
    close_quietly release_write;
    (match
       let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT ] 0o600 in
       ignore (Unix.lseek fd byte Unix.SEEK_SET : int);
       Unix.lockf fd Unix.F_TLOCK 1
     with
     | () ->
       ignore (Unix.write_substring ready_write "1" 0 1 : int);
       let buffer = Bytes.create 1 in
       ignore (read_nointr release_read buffer : int);
       Unix._exit 0
     | exception Unix.Unix_error _ -> Unix._exit 4)
  | locker_pid ->
    close_quietly ready_write;
    close_quietly release_read;
    let buffer = Bytes.create 1 in
    Alcotest.(check int) "the other process locked its byte" 1 (read_nointr ready_read buffer);
    close_quietly ready_read;
    (locker_pid, release_write)

(* The lock of another process on another byte, taken before the owner
   announced and after, changes nothing in who holds the byte of a port. The
   read of the whole file names one lock and cannot say that it is the
   owner's. *)
let test_port_holder_is_exact_beside_the_locks_of_other_processes () =
  with_base_and_run "startup-takeover-announcement-beside" (fun ~base_path ~run_dir ->
    let port = 9000 and before = 7000 and after = 11000 in
    check_port_holder "nothing before any file" (Ok None) ~run_dir base_path ~port;
    Alcotest.(check bool) "a read makes no file" false
      (Sys.file_exists (announcement_path ~run_dir base_path));
    let first_pid, first_release = spawn_byte_locker ~run_dir base_path ~byte:before in
    let owner_pid, owner_release =
      spawn_announcing_owner
        ~announce:Server_startup_takeover.announce_account_server
        ~run_dir base_path ~port
    in
    let second_pid, second_release = spawn_byte_locker ~run_dir base_path ~byte:after in
    Fun.protect
      ~finally:(fun () ->
        List.iter close_quietly [ first_release; owner_release; second_release ];
        List.iter stop_process [ first_pid; owner_pid; second_pid ])
      (fun () ->
        check_port_holder "the owner holds the byte of its port" (Ok (Some owner_pid))
          ~run_dir base_path ~port;
        check_port_holder "the lock taken before it is on its own byte" (Ok (Some first_pid))
          ~run_dir base_path ~port:before;
        check_port_holder "the lock taken after it is on its own byte" (Ok (Some second_pid))
          ~run_dir base_path ~port:after;
        check_port_holder "a port between them" (Ok None) ~run_dir base_path ~port:(port + 1);
        (match Server_startup_takeover.account_server_port_holder ~run_dir ~base_path ~port:0 with
         | Error (Server_startup_takeover.Announcement_port_invalid { port = 0 }) -> ()
         | answer ->
           Alcotest.fail ("a number that is no port was asked about: " ^ port_holder_label answer));
        (match Server_startup_takeover.account_server_announcement ~run_dir ~base_path with
         | Ok (Some { Server_startup_takeover.pid; port = named }) ->
           Alcotest.(check bool) "the whole file names one of the three locks" true
             (List.mem (pid, named) [ first_pid, before; owner_pid, port; second_pid, after ])
         | Ok None -> Alcotest.fail "the whole file named no lock"
         | Error rejection ->
           Alcotest.fail (Server_startup_takeover.base_path_lock_rejection_to_string rejection))))

(* A byte another process locked first is not announced over: the boot of a
   server stops on it, and no reader takes that process for the server. *)
let test_a_port_another_process_locked_is_not_announced () =
  with_base_and_run "startup-takeover-announcement-taken" (fun ~base_path ~run_dir ->
    let port = 9000 in
    let locker_pid, locker_release = spawn_byte_locker ~run_dir base_path ~byte:port in
    Fun.protect
      ~finally:(fun () ->
        close_quietly locker_release;
        stop_process locker_pid)
      (fun () ->
        match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
        | Server_startup_takeover.Base_path_already_owned _
        | Server_startup_takeover.Base_path_rejected _ ->
          Alcotest.fail "the lease was not acquired"
        | Server_startup_takeover.Base_path_acquired lease ->
          Fun.protect
            ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease)
            (fun () ->
              check_announced "the owner does not announce the port, and names who holds it"
                (Printf.sprintf "the byte of port %d is locked by pid %d" port locker_pid)
                (Server_startup_takeover.announce_account_server lease ~port);
              check_port_holder "the byte is still the other process's" (Ok (Some locker_pid))
                ~run_dir base_path ~port;
              check_announced "another port is announced" "announced"
                (Server_startup_takeover.announce_account_server lease ~port:(port + 1)))))

(* An announcement file with a second name is refused by the writer and by
   the reader: the other name could be opened and closed outside the checks
   of this directory. *)
let test_a_linked_announcement_file_is_refused () =
  with_base_and_run "startup-takeover-announcement-linked" (fun ~base_path ~run_dir ->
    match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
    | Server_startup_takeover.Base_path_already_owned _
    | Server_startup_takeover.Base_path_rejected _ ->
      Alcotest.fail "the lease was not acquired"
    | Server_startup_takeover.Base_path_acquired lease ->
      let path = announcement_path ~run_dir base_path in
      let is_link_refusal = function
        | Error (Server_startup_takeover.Lease_file_multiply_linked { links = 2; _ }) -> true
        | Error _ | Ok _ -> false
      in
      write_file path "";
      Unix.chmod path 0o600;
      Unix.link path (path ^ ".second-name");
      Fun.protect
        ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease)
        (fun () ->
          Alcotest.(check bool) "the owner does not announce on a file with two names" true
            (is_link_refusal (Server_startup_takeover.announce_account_server lease ~port:9000)));
      Alcotest.(check bool) "a reader does not read a file with two names" true
        (is_link_refusal
           (Server_startup_takeover.account_server_port_holder ~run_dir ~base_path ~port:9000)))

(* The lease path names another file than the one this process holds locked:
   the directory was replaced under the owner, so what it would announce
   there is not read by a process that asks about the lease of the path. *)
let test_a_replaced_lease_path_announces_nothing () =
  with_base_and_run "startup-takeover-announcement-replaced" (fun ~base_path ~run_dir ->
    match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
    | Server_startup_takeover.Base_path_already_owned _
    | Server_startup_takeover.Base_path_rejected _ ->
      Alcotest.fail "the lease was not acquired"
    | Server_startup_takeover.Base_path_acquired lease ->
      let lease_path =
        Server_startup_takeover.For_testing.lease_path
          ~run_dir:(Unix.realpath run_dir)
          ~canonical_base_path:(Unix.realpath base_path)
      in
      Fun.protect
        ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease)
        (fun () ->
          Unix.rename lease_path (lease_path ^ ".moved");
          write_file lease_path "";
          (match Server_startup_takeover.announce_account_server lease ~port:9000 with
           | Error (Server_startup_takeover.Lease_identity_changed _) -> ()
           | Error rejection ->
             Alcotest.fail (Server_startup_takeover.base_path_lock_rejection_to_string rejection)
           | Ok () -> Alcotest.fail "a port was announced beside a lease path of another file");
          Alcotest.(check bool) "no announcement file was made" false
            (Sys.file_exists (announcement_path ~run_dir base_path))))

(* One directory has two spellings on macOS, and the table of this process is
   keyed by the one it took the lease under. A read under the other spelling
   must find the announcement of this process by the file: opening a second
   descriptor on it and closing it would drop the lock. A host with one
   spelling has nothing to ask here, so the case is skipped there: that is
   every Linux host, and the Linux runs of this suite say nothing of the
   lookup by file. *)
let test_owner_is_found_under_another_spelling_of_the_lease_root () =
  with_base_and_run "startup-takeover-announcement-spelling" (fun ~base_path ~run_dir ->
    match second_realpath_spelling (Unix.realpath run_dir) with
    | None -> Alcotest.skip ()
    | Some other_spelling ->
      (match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
       | Server_startup_takeover.Base_path_already_owned _
       | Server_startup_takeover.Base_path_rejected _ ->
         Alcotest.fail "the lease was not acquired"
       | Server_startup_takeover.Base_path_acquired lease ->
         let port = 9002 in
         Fun.protect
           ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease)
           (fun () ->
             check_announced "the port is announced" "announced"
               (Server_startup_takeover.announce_account_server lease ~port);
             check_port_holder "under the other spelling, the holder is this process"
               (Ok (Some (Unix.getpid ())))
               ~run_dir:other_spelling base_path ~port;
             check_announcement "under the other spelling, the announcement is this process's"
               (Ok (Some { Server_startup_takeover.pid = Unix.getpid (); port }))
               ~run_dir:other_spelling base_path;
             Alcotest.(check bool) "the reads did not drop the lock" true
               (announcement_is_held_in_the_kernel ~run_dir base_path ~port))))

let test_announcement_names_the_owner_and_ends_with_it () =
  with_base_and_run "startup-takeover-announcement" (fun ~base_path ~run_dir ->
    let port = 9000 in
    check_announcement "nothing before any owner" (Ok None) ~run_dir base_path;
    let owner_pid, release_write =
      spawn_announcing_owner
        ~announce:Server_startup_takeover.announce_account_server
        ~run_dir base_path ~port
    in
    let released = ref false in
    let release () =
      if not !released
      then (
        released := true;
        close_quietly release_write)
    in
    Fun.protect
      ~finally:(fun () ->
        release ();
        stop_process owner_pid)
      (fun () ->
        check_announcement "the kernel names the owner and its port"
          (Ok (Some { Server_startup_takeover.pid = owner_pid; port }))
          ~run_dir base_path;
        Alcotest.(check int) "the file stays empty" 0
          (Unix.stat (announcement_path ~run_dir base_path)).Unix.st_size;
        release ();
        owner_exited_on_its_own owner_pid;
        check_announcement "nothing once the owner is gone" (Ok None) ~run_dir base_path))

let test_owner_reads_its_own_announcement_and_keeps_it () =
  with_base_and_run "startup-takeover-announcement-own" (fun ~base_path ~run_dir ->
    match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
    | Server_startup_takeover.Base_path_already_owned _
    | Server_startup_takeover.Base_path_rejected _ ->
      Alcotest.fail "the lease was not acquired"
    | Server_startup_takeover.Base_path_acquired lease ->
      let port = 9001 in
      let released = ref false in
      let release () =
        if not !released
        then (
          released := true;
          Server_startup_takeover.release_base_path_lease lease)
      in
      let announce port = Server_startup_takeover.announce_account_server lease ~port in
      Fun.protect ~finally:release (fun () ->
        check_announcement "an owner that announced nothing" (Ok None) ~run_dir base_path;
        check_announced "a number that is no port is refused" "65536 is not a port"
          (announce 65536);
        check_announced "the port is announced" "announced" (announce port);
        check_announcement "the owner reads its own announcement"
          (Ok (Some { Server_startup_takeover.pid = Unix.getpid (); port }))
          ~run_dir base_path;
        check_port_holder "the owner holds the byte of its port"
          (Ok (Some (Unix.getpid ())))
          ~run_dir base_path ~port;
        check_port_holder "and no other byte" (Ok None) ~run_dir base_path ~port:(port + 1);
        Alcotest.(check bool) "reading it did not drop the lock" true
          (announcement_is_held_in_the_kernel ~run_dir base_path ~port);
        check_announced "a second announcement is refused, and names the first"
          (Printf.sprintf "this process already announces port %d" port)
          (announce (port + 1));
        Alcotest.(check bool) "the refusal left the first announcement in the kernel" true
          (announcement_is_held_in_the_kernel ~run_dir base_path ~port);
        Alcotest.(check bool) "and took no lock on the second port" false
          (announcement_is_held_in_the_kernel ~run_dir base_path ~port:(port + 1));
        release ();
        Alcotest.(check bool) "the release of the lease withdrew it" false
          (announcement_is_held_in_the_kernel ~run_dir base_path ~port);
        check_announcement "nothing after the release" (Ok None) ~run_dir base_path;
        check_announced "a released lease announces nothing"
          "the lease handle is not the active owner" (announce port)))

let test_announcement_on_a_directory_is_refused () =
  with_base_and_run "startup-takeover-announcement-dir" (fun ~base_path ~run_dir ->
    match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
    | Server_startup_takeover.Base_path_already_owned _
    | Server_startup_takeover.Base_path_rejected _ ->
      Alcotest.fail "the lease was not acquired"
    | Server_startup_takeover.Base_path_acquired lease ->
      let is_directory_refusal = function
        | Error (Server_startup_takeover.Lease_file_non_regular { kind = Unix.S_DIR; _ }) -> true
        | Error _ | Ok _ -> false
      in
      Unix.mkdir (announcement_path ~run_dir base_path) 0o700;
      Fun.protect
        ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease)
        (fun () ->
          Alcotest.(check bool) "the owner does not announce on a directory" true
            (is_directory_refusal
               (Server_startup_takeover.announce_account_server lease ~port:9000)));
      Alcotest.(check bool) "a reader does not take a directory for an announcement" true
        (is_directory_refusal
           (Server_startup_takeover.account_server_announcement ~run_dir ~base_path));
      Alcotest.(check bool) "nor for the lock of a port" true
        (is_directory_refusal
           (Server_startup_takeover.account_server_port_holder ~run_dir ~base_path ~port:9000)))

(* The announcement of the server of a single user. *)

(* The file the server of a single user announces on, its suffix written out
   as [announcement_path] writes out the one of the account server. *)
let single_user_announcement_path ~run_dir base_path =
  Server_startup_takeover.For_testing.lease_path
    ~run_dir:(Unix.realpath run_dir)
    ~canonical_base_path:(Unix.realpath base_path)
  ^ ".single-user-server"

let check_single_user_port_holder message expected ~run_dir base_path ~port =
  Alcotest.(check string) message (port_holder_label expected)
    (port_holder_label
       (Server_startup_takeover.single_user_server_port_holder ~run_dir ~base_path ~port))

let check_single_user_announcement message expected ~run_dir base_path =
  Alcotest.(check string) message (announcement_label expected)
    (announcement_label
       (Server_startup_takeover.single_user_server_announcement ~run_dir ~base_path))

(* Another process announces as the server of a single user. A reader of
   that kind is answered with it, and a reader of the account server is not:
   were the two kinds on one file, the kernel would name the owner to both. *)
let test_a_single_user_announcement_is_not_the_account_servers () =
  with_base_and_run "startup-takeover-single-user-apart" (fun ~base_path ~run_dir ->
    let port = 9000 in
    let owner_pid, release_write =
      spawn_announcing_owner
        ~announce:Server_startup_takeover.announce_single_user_server
        ~run_dir base_path ~port
    in
    let released = ref false in
    let release () =
      if not !released
      then (
        released := true;
        close_quietly release_write)
    in
    Fun.protect
      ~finally:(fun () ->
        release ();
        stop_process owner_pid)
      (fun () ->
        check_single_user_port_holder "the kernel names the owner for its port"
          (Ok (Some owner_pid)) ~run_dir base_path ~port;
        check_single_user_announcement "and for the whole file"
          (Ok (Some { Server_startup_takeover.pid = owner_pid; port }))
          ~run_dir base_path;
        check_port_holder "a reader of the account server is not answered with it" (Ok None)
          ~run_dir base_path ~port;
        check_announcement "nor for the whole file of the account server" (Ok None)
          ~run_dir base_path;
        Alcotest.(check bool) "the lock is on the file of a single user" true
          (byte_is_held_in_the_kernel (single_user_announcement_path ~run_dir base_path) ~port);
        release ();
        owner_exited_on_its_own owner_pid;
        check_single_user_port_holder "nothing once the owner is gone" (Ok None)
          ~run_dir base_path ~port))

(* The other way round: the account server announces, and a reader of a
   single user is not answered with it. *)
let test_an_account_server_announcement_is_not_a_single_users () =
  with_base_and_run "startup-takeover-account-apart" (fun ~base_path ~run_dir ->
    let port = 9000 in
    let owner_pid, release_write =
      spawn_announcing_owner
        ~announce:Server_startup_takeover.announce_account_server
        ~run_dir base_path ~port
    in
    Fun.protect
      ~finally:(fun () ->
        close_quietly release_write;
        stop_process owner_pid)
      (fun () ->
        check_port_holder "the kernel names the account server for its port"
          (Ok (Some owner_pid)) ~run_dir base_path ~port;
        check_single_user_port_holder "a reader of a single user is not answered with it"
          (Ok None) ~run_dir base_path ~port;
        check_single_user_announcement "nor for the whole file of a single user" (Ok None)
          ~run_dir base_path))

(* The owner announces one port, once; a number that is no port is refused
   before anything is announced. *)
let test_a_single_user_owner_announces_one_port_once () =
  with_base_and_run "startup-takeover-single-user-own" (fun ~base_path ~run_dir ->
    match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
    | Server_startup_takeover.Base_path_already_owned _
    | Server_startup_takeover.Base_path_rejected _ ->
      Alcotest.fail "the lease was not acquired"
    | Server_startup_takeover.Base_path_acquired lease ->
      let port = 9001 in
      let path = single_user_announcement_path ~run_dir base_path in
      let released = ref false in
      let release () =
        if not !released
        then (
          released := true;
          Server_startup_takeover.release_base_path_lease lease)
      in
      let announce port = Server_startup_takeover.announce_single_user_server lease ~port in
      Fun.protect ~finally:release (fun () ->
        check_announced "a number below the ports is refused" "0 is not a port" (announce 0);
        check_announced "a number above the ports is refused" "65536 is not a port"
          (announce 65536);
        (match
           Server_startup_takeover.single_user_server_port_holder ~run_dir ~base_path ~port:0
         with
         | Error (Server_startup_takeover.Announcement_port_invalid { port = 0 }) -> ()
         | answer ->
           Alcotest.fail ("a number that is no port was asked about: " ^ port_holder_label answer));
        check_announced "the port is announced" "announced" (announce port);
        check_single_user_port_holder "the owner holds the byte of its port"
          (Ok (Some (Unix.getpid ()))) ~run_dir base_path ~port;
        check_single_user_announcement "the owner reads its own announcement"
          (Ok (Some { Server_startup_takeover.pid = Unix.getpid (); port }))
          ~run_dir base_path;
        check_announced "a second announcement is refused, and names the first"
          (Printf.sprintf "this process already announces port %d" port)
          (announce (port + 1));
        check_port_holder "a reader of the account server is not answered" (Ok None)
          ~run_dir base_path ~port;
        Alcotest.(check bool) "the reads left the lock on the file of a single user" true
          (byte_is_held_in_the_kernel path ~port);
        Alcotest.(check bool) "and the refusal took no lock on the second port" false
          (byte_is_held_in_the_kernel path ~port:(port + 1));
        release ();
        Alcotest.(check bool) "the release of the lease withdrew it" false
          (byte_is_held_in_the_kernel path ~port);
        check_single_user_announcement "nothing after the release" (Ok None)
          ~run_dir base_path))

let () =
  Alcotest.run "Server_startup_takeover"
    [
      ( "temp directory cleanup",
        [
          Alcotest.test_case "rm_rf unlinks live and dangling links" `Quick
            test_rm_rf_unlinks_symlinks;
        ] );
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
          Alcotest.test_case "a recorded owner is not refused as a second waiter"
            `Quick test_recorded_owner_is_not_refused_as_second_waiter;
          Alcotest.test_case "a recorded owner that is gone is named as stale"
            `Quick test_base_path_lock_reports_a_recorded_owner_that_is_gone;
          Alcotest.test_case "stale base-path owner is reclaimed" `Quick
            test_base_path_lock_reclaims_stale_pid_file;
          Alcotest.test_case "same-process symlink alias is rejected" `Quick
            test_base_path_lock_rejects_same_process_symlink_alias;
          Alcotest.test_case
            "one directory shares one lease across realpath spellings" `Quick
            test_base_path_lock_shares_one_lease_across_realpath_spellings;
          Alcotest.test_case
            "a lease root beside the BasePath is shared by every spelling" `Quick
            test_lease_root_beside_base_path_is_shared_by_every_spelling;
          Alcotest.test_case
            "the presence of the lease file is read without making anything" `Quick
            test_lease_file_presence_is_read_without_making_anything;
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
      ( "account server announcement",
        [
          Alcotest.test_case "the kernel names the owner and its port while it lives"
            `Quick test_announcement_names_the_owner_and_ends_with_it;
          Alcotest.test_case "the owner reads its own announcement and keeps it" `Quick
            test_owner_reads_its_own_announcement_and_keeps_it;
          Alcotest.test_case "an announcement file that is a directory is refused" `Quick
            test_announcement_on_a_directory_is_refused;
          Alcotest.test_case "the holder of a port is exact beside the locks of other processes"
            `Quick test_port_holder_is_exact_beside_the_locks_of_other_processes;
          Alcotest.test_case "a port another process locked is not announced" `Quick
            test_a_port_another_process_locked_is_not_announced;
          Alcotest.test_case "an announcement file with two names is refused" `Quick
            test_a_linked_announcement_file_is_refused;
          Alcotest.test_case "a lease path that names another file announces nothing" `Quick
            test_a_replaced_lease_path_announces_nothing;
          Alcotest.test_case "the owner is found under another spelling of the lease root"
            `Quick test_owner_is_found_under_another_spelling_of_the_lease_root;
        ] );
      ( "single-user server announcement",
        [
          Alcotest.test_case "it is not read as the account server's" `Quick
            test_a_single_user_announcement_is_not_the_account_servers;
          Alcotest.test_case "the account server's is not read as it" `Quick
            test_an_account_server_announcement_is_not_a_single_users;
          Alcotest.test_case "the owner announces one port once" `Quick
            test_a_single_user_owner_announces_one_port_once;
        ] );
    ]