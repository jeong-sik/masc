module G = Endpoint_process_gate

let get = function Ok value -> value | Error error -> Alcotest.fail (G.error_to_string error)
let check label condition = Alcotest.(check bool) label true condition
let check_exit expected (exit : G.exit_observation) =
  Alcotest.(check int) "original exit status" expected
    (match exit.status with G.Exited code -> code | G.Signaled signal -> -signal)

let file path =
  let input = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in input) (fun () -> really_input_string input (in_channel_length input))

type fixture = {
  work : string; secret : string; marker : string;
  uid : int; gid : int; input : Unix.file_descr; output : Unix.file_descr; output_path : string;
}

let with_fixture fn =
  let account = Unix.getpwnam "nobody" in
  let root = Filename.temp_file "masc-process-gate-" "" in
  Unix.unlink root; Unix.mkdir root 0o711;
  let work = Filename.concat root "work" in
  let private_dir = Filename.concat root "controller" in
  Unix.mkdir work 0o700; Unix.chown work account.pw_uid account.pw_gid;
  Unix.mkdir private_dir 0o700;
  let secret = Filename.concat private_dir "secret" in
  let oc = open_out_bin secret in output_string oc "synthetic-controller-only"; close_out oc;
  let output_path = Filename.concat root "stdout" in
  let output = Unix.openfile output_path [Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY; Unix.O_CLOEXEC] 0o600 in
  let input = Unix.openfile "/dev/null" [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 in
  let marker = Filename.concat work "activated" in
  Fun.protect
    ~finally:(fun () ->
      Unix.close input; Unix.close output;
      if Sys.file_exists marker then Unix.unlink marker;
      Unix.unlink output_path; Unix.unlink secret;
      Unix.rmdir private_dir; Unix.rmdir work; Unix.rmdir root)
    (fun () -> fn {work; secret; marker; uid=account.pw_uid; gid=account.pw_gid;
                  input; output; output_path})

let spawn ~sw fixture ?(executable="/bin/sh") ?(input=fixture.input) script =
  G.create ~sw ~executable ~argv:[|executable; "-c"; script|]
    ~env:[|"PATH=/usr/bin:/bin"; "ONLY_EXPECTED=explicit"|]
    ~cwd:fixture.work ~payload_uid:fixture.uid ~payload_gid:fixture.gid
    ~stdin:input ~stdout:fixture.output ~stderr:fixture.output

let run fn () = Eio_main.run (fun env ->
    (* Test-hang backstop only; the product has no synthetic process timeout. *)
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 20. (fun () -> with_fixture fn))

let activated_security = run (fun fixture -> Eio.Switch.run (fun sw ->
    let old = Sys.getenv_opt "CONTROLLER_ONLY" in
    Unix.putenv "CONTROLLER_ONLY" "synthetic-ambient";
    Fun.protect ~finally:(fun () -> match old with
        | None -> Unix.unsetenv "CONTROLLER_ONLY" | Some value -> Unix.putenv "CONTROLLER_ONLY" value)
      (fun () ->
        let script = Printf.sprintf
            "set -eu; test \"${ONLY_EXPECTED}\" = explicit; test -z \"${CONTROLLER_ONLY+x}\"; if /bin/cat %s >/dev/null 2>&1; then exit 91; fi; /usr/bin/id -u; /usr/bin/id -g; /usr/bin/id -G; /bin/cat /proc/self/status; : > activated"
            (Filename.quote fixture.secret) in
        let child = get (spawn ~sw fixture script) in
        get (G.await_ready child);
        check "no effect before activation" (not (Sys.file_exists fixture.marker));
        Alcotest.(check string) "stdio quiet before activation" "" (file fixture.output_path);
        get (G.activate child);
        let exit = get (G.await_exit child) in
        check_exit 0 exit;
        check "decision retained" (exit.boundary.decision = G.Activate_requested);
        check "payload effect after activation" (Sys.file_exists fixture.marker);
        let lines = String.split_on_char '\n' (file fixture.output_path) in
        (match lines with
         | uid :: gid :: groups :: status ->
             Alcotest.(check string) "distinct non-root UID" (string_of_int fixture.uid) uid;
             Alcotest.(check string) "explicit GID" (string_of_int fixture.gid) gid;
             Alcotest.(check string) "no supplementary controller groups" (string_of_int fixture.gid) groups;
             check "no-new-privs retained through exec" (List.mem "NoNewPrivs:\t1" status);
             check "effective capabilities cleared" (List.mem "CapEff:\t0000000000000000" status)
         | [] | [_] | [_; _] -> Alcotest.fail "missing payload security observations");
        check_exit 0 (get (G.release child)))))

let abort_without_effect = run (fun fixture -> Eio.Switch.run (fun sw ->
    let child = get (spawn ~sw fixture ": > activated") in
    get (G.abort child);
    let exit = get (G.await_exit child) in
    check_exit 125 exit;
    check "abort retained" (exit.boundary.decision = G.Abort_requested);
    check "no payload effect" (not (Sys.file_exists fixture.marker));
    check "cannot reactivate" (G.activate child = Error G.Already_decided)))

let rejected_exec = run (fun fixture -> Eio.Switch.run (fun sw ->
    let child = get (spawn ~sw fixture ~executable:(Filename.concat fixture.work "missing") "") in
    get (G.await_ready child); get (G.activate child);
    let exit = get (G.await_exit child) in
    check_exit 127 exit;
    (match exit.boundary.preparation with
     | G.Rejected {stage; error} ->
         check "exec-stage rejection retained" (stage = G.Child_exec && error = Unix.ENOENT)
     | G.Pending | G.Ready -> Alcotest.fail "bootstrap exit must retain exec rejection")))

let original_handle = run (fun fixture -> Eio.Switch.run (fun sw ->
    let first = get (spawn ~sw fixture ": > activated") in
    get (G.await_ready first);
    ignore (get (G.signal_main first G.Kill));
    check_exit (-9) (get (G.await_exit first));
    check "killed gate has no payload effect" (not (Sys.file_exists fixture.marker));
    let second = get (spawn ~sw fixture ": > activated") in
    get (G.await_ready second);
    check "old handle knows original is gone" (get (G.signal_main first G.Kill) = G.Already_exited);
    check "independent original remains paused" (get (G.poll_exit second) = None);
    get (G.activate second); check_exit 0 (get (G.await_exit second));
    check "new payload remains executable" (Sys.file_exists fixture.marker)))

let waiter_cancellation_and_progress = run (fun fixture ->
    let reader, writer = Unix.pipe ~cloexec:true () in
    let writer_open = ref true in
    Fun.protect ~finally:(fun () -> Unix.close reader; if !writer_open then Unix.close writer)
      (fun () -> Eio.Switch.run (fun sw ->
          let first = get (G.create ~sw ~executable:"/bin/cat" ~argv:[|"/bin/cat"|]
              ~env:[||] ~cwd:fixture.work ~payload_uid:fixture.uid ~payload_gid:fixture.gid
              ~stdin:reader ~stdout:fixture.output ~stderr:fixture.output) in
          get (G.await_ready first); get (G.activate first);
          let waiting, started = Eio.Promise.create () in
          Eio.Fiber.first
            (fun () -> Eio.Promise.resolve started (); ignore (get (G.await_exit first));
              Alcotest.fail "blocked input unexpectedly completed")
            (fun () -> Eio.Promise.await waiting);
          check "cancelled waiter did not cancel payload" (get (G.poll_exit first) = None);
          let second = get (spawn ~sw fixture "exit 7") in
          get (G.await_ready second); get (G.activate second);
          check_exit 7 (get (G.await_exit second));
          check "other child progressed while first awaited input" (get (G.poll_exit first) = None);
          let bytes = "original-input\n" in
          let count = Eio_unix.run_in_systhread (fun () -> Unix.write_substring writer bytes 0 (String.length bytes)) in
          Alcotest.(check int) "all input written" (String.length bytes) count;
          Unix.close writer; writer_open := false;
          check_exit 0 (get (G.await_exit first));
          Alcotest.(check string) "original output" bytes (file fixture.output_path))))

let owner_teardown = run (fun fixture ->
    let child = Eio.Switch.run (fun sw ->
        let child = get (spawn ~sw fixture ": > activated") in
        get (G.await_ready child); child) in
    check_exit (-9) (get (G.await_exit child));
    check_exit (-9) (get (G.release child));
    check "owner teardown prevented payload" (not (Sys.file_exists fixture.marker)))

let frozen_inputs = run (fun fixture -> Eio.Switch.run (fun sw ->
    let script = "printf '%s\\n' \"$1\" \"$FROZEN_ENV\"" in
    let argv = [|"/bin/sh"; "-c"; script; "gate-test"; "original-argument"|] in
    let env = [|"FROZEN_ENV=original-environment"|] in
    let reached, notify = Eio.Promise.create () in
    let mutex = Mutex.create () and condition = Condition.create () and proceed = ref false in
    let before_spawn_in_worker () =
      Mutex.lock mutex;
      Fun.protect ~finally:(fun () -> Mutex.unlock mutex) (fun () ->
          Eio.Promise.resolve notify ();
          while not !proceed do Condition.wait condition mutex done) in
    let child, () = Eio.Fiber.pair
        (fun () -> get (G.For_testing.create ~before_spawn_in_worker ~sw
            ~executable:"/bin/sh" ~argv ~env ~cwd:fixture.work
            ~payload_uid:fixture.uid ~payload_gid:fixture.gid
            ~stdin:fixture.input ~stdout:fixture.output ~stderr:fixture.output))
        (fun () ->
          Eio.Promise.await reached;
          Mutex.lock mutex;
          Fun.protect ~finally:(fun () ->
              proceed := true; Condition.broadcast condition; Mutex.unlock mutex)
            (fun () -> argv.(4) <- "replaced-argument"; env.(0) <- "FROZEN_ENV=replaced-environment")) in
    get (G.await_ready child); get (G.activate child);
    check_exit 0 (get (G.await_exit child));
    Alcotest.(check string) "worker executes original validated inputs"
      "original-argument\noriginal-environment\n" (file fixture.output_path)))

let get_group = function
  | Ok value -> value | Error error -> Alcotest.fail (G.Group.error_to_string error)
let group_name fixture = "masc-gate-" ^ Filename.basename (Filename.dirname fixture.work)
let spawn_group ~sw ~group fixture ?(input=fixture.input) ?(output=fixture.output) script =
  G.create_in_group ~group ~sw ~executable:"/bin/sh" ~argv:[|"/bin/sh"; "-c"; script|]
    ~env:[|"PATH=/usr/bin:/bin"|] ~cwd:fixture.work
    ~payload_uid:fixture.uid ~payload_gid:fixture.gid
    ~stdin:input ~stdout:output ~stderr:output

let recursive_tree_and_progress = run (fun fixture ->
    let reader, writer = Unix.pipe ~cloexec:true () in
    let output_reader, output_writer = Unix.pipe ~cloexec:true () in
    let output_open = ref true in
    Fun.protect ~finally:(fun () ->
        Unix.close reader; Unix.close writer; Unix.close output_reader;
        if !output_open then Unix.close output_writer)
      (fun () -> Eio.Switch.run (fun sw ->
          let parent_path="/sys/fs/cgroup" and name=group_name fixture in
          let group=get_group (G.Group.create ~sw ~parent_path ~name) in
          (* POSIX async lists may replace fd0 before redirections. Preserve
             the actual input on another fd before backgrounding, then prove
             the descendant received bytes from the parent's still-open pipe. *)
          let script="exec 9<&0; /bin/sh -c 'IFS= read -r first <&9; printf %s \"$first\"; exec /bin/cat <&9' & wait" in
          let child=get (spawn_group ~sw ~group fixture ~input:reader ~output:output_writer script) in
          Unix.close output_writer; output_open := false;
          get (G.await_ready child); get (G.activate child);
          let handshake="descendant-ready\n" in
          let sent=Eio_unix.run_in_systhread (fun () ->
              Unix.write_substring writer handshake 0 (String.length handshake)) in
          Alcotest.(check int) "actual pipe handshake written" (String.length handshake) sent;
          Eio_unix.await_readable output_reader;
          let bytes=Bytes.create (String.length "descendant-ready") in
          let read=Eio_unix.run_in_systhread (fun () -> Unix.read output_reader bytes 0 (Bytes.length bytes)) in
          Alcotest.(check string) "actual descendant reached payload" "descendant-ready"
            (Bytes.sub_string bytes 0 read);
          ignore (get (G.signal_main child G.Kill)); check_exit (-9) (get (G.await_exit child));
          check "main exit is not recursive emptiness" (get_group (G.Group.populated group));
          let waiting, started=Eio.Promise.create () in
          Eio.Fiber.first
            (fun () -> Eio.Promise.resolve started (); get_group (G.Group.await_empty group);
              Alcotest.fail "live descendant reported empty")
            (fun () -> Eio.Promise.await waiting);
          check "cancelled group waiter preserves descendants" (get_group (G.Group.populated group));
          let other=get_group (G.Group.create ~sw ~parent_path ~name:(name ^ "-other")) in
          let second=get (spawn_group ~sw ~group:other fixture "exit 6") in
          get (G.await_ready second); get (G.activate second);
          check_exit 6 (get (G.await_exit second)); get_group (G.Group.release other);
          check "independent group progressed" (get_group (G.Group.populated group));
          get_group (G.Group.kill_tree group);
          check "retired original cannot admit another child"
            (spawn_group ~sw ~group fixture "exit 0" = Error (G.Group_error G.Group.Retiring));
          get_group (G.Group.await_empty group);
          Eio_unix.await_readable output_reader;
          let count=Eio_unix.run_in_systhread (fun () -> Unix.read output_reader bytes 0 (Bytes.length bytes)) in
          Alcotest.(check int) "tree cancellation releases descendant-held output" 0 count;
          get_group (G.Group.release group);
          check "original group removed" (not (Sys.file_exists (Filename.concat parent_path name))))))

let exclusive_group_and_reused_name = run (fun fixture -> Eio.Switch.run (fun sw ->
    let parent_path="/sys/fs/cgroup" and name=group_name fixture in
    let original=get_group (G.Group.create ~sw ~parent_path ~name) in
    check "existing group cannot be adopted" (Result.is_error (G.Group.create ~sw ~parent_path ~name));
    let first=get (spawn_group ~sw ~group:original fixture ": > activated") in
    get (G.await_ready first); get_group (G.Group.release original);
    check_exit (-9) (get (G.await_exit first));
    check "tree teardown prevented activation" (not (Sys.file_exists fixture.marker));
    let replacement=get_group (G.Group.create ~sw ~parent_path ~name) in
    let second=get (spawn_group ~sw ~group:replacement fixture ": > activated") in
    get (G.await_ready second);
    get_group (G.Group.kill_tree original);
    check "old group handle never resolves a reused path" (get_group (G.Group.populated replacement));
    get (G.activate second); check_exit 0 (get (G.await_exit second));
    check "new original still executed" (Sys.file_exists fixture.marker));
    (* The owner's hooks also retire/remove replacement after main reaping. *)
    check "owner removed replacement group"
      (not (Sys.file_exists (Filename.concat "/sys/fs/cgroup" (group_name fixture)))))

let private_group_waiters_keep_their_transition = run (fun fixture -> Eio.Switch.run (fun sw ->
    let group=get_group (G.Group.create ~sw ~parent_path:"/sys/fs/cgroup"
        ~name:(group_name fixture ^ "-waiters")) in
    let child=get (spawn_group ~sw ~group fixture ": > activated") in
    get (G.await_ready child);
    let seen_a, saw_a=Eio.Promise.create () and seen_b, saw_b=Eio.Promise.create () in
    let resume_a, continue_a=Eio.Promise.create () and resume_b, continue_b=Eio.Promise.create () in
    let done_a, finished_a=Eio.Promise.create () and done_b, finished_b=Eio.Promise.create () in
    let pause observed resume =
      let first=ref true in
      fun populated -> if populated && !first then begin
        first:=false;Eio.Promise.resolve observed ();Eio.Promise.await resume
      end in
    Eio.Fiber.all [
      (fun () -> get_group (G.For_testing.await_group_empty
          ~after_populated:(pause saw_a resume_a) group);Eio.Promise.resolve finished_a ());
      (fun () -> get_group (G.For_testing.await_group_empty
          ~after_populated:(pause saw_b resume_b) group);Eio.Promise.resolve finished_b ());
      (fun () ->
        Eio.Promise.await seen_a;Eio.Promise.await seen_b;
        get_group (G.Group.kill_tree group);check_exit (-9) (get (G.await_exit child));
        check "another public reader observes the last transition" (not (get_group (G.Group.populated group)));
        Eio.Promise.resolve continue_b ();Eio.Promise.await done_b;
        check "the other waiter settled before A resumed" (Eio.Promise.peek done_a=None);
        Eio.Promise.resolve continue_a ();Eio.Promise.await done_a)
    ];
    check "neither wait permits payload activation" (not (Sys.file_exists fixture.marker));
    get_group (G.Group.release group)))

let cancel_private_group_waiter_preserves_owner = run (fun fixture -> Eio.Switch.run (fun sw ->
    let group=get_group (G.Group.create ~sw ~parent_path:"/sys/fs/cgroup"
        ~name:(group_name fixture ^ "-cancel-wait")) in
    let child=get (spawn_group ~sw ~group fixture ": > activated") in
    get (G.await_ready child);
    let observed, notify=Eio.Promise.create () and hold, _release=Eio.Promise.create () in
    Eio.Fiber.first
      (fun () -> get_group (G.For_testing.await_group_empty ~after_populated:(fun populated ->
          check "private cancellation boundary observes the actual child" populated;
          Eio.Promise.resolve notify ();Eio.Promise.await hold) group);
        Alcotest.fail "live child was reported empty")
      (fun () -> Eio.Promise.await observed);
    check "cancelling an acquired private waiter leaves the original populated" (get_group (G.Group.populated group));
    get_group (G.Group.kill_tree group);check_exit (-9) (get (G.await_exit child));
    get_group (G.Group.await_empty group);get_group (G.Group.release group)))

let invalid_owner = run (fun fixture -> Eio.Switch.run (fun sw ->
    let result = G.create ~sw ~executable:"/bin/sh" ~argv:[|"/bin/sh"|] ~env:[||]
        ~cwd:fixture.work ~payload_uid:0 ~payload_gid:fixture.gid
        ~stdin:fixture.input ~stdout:fixture.output ~stderr:fixture.output in
    check "root payload refused before any child" (result = Error (G.Invalid_input G.Payload_uid))))

let signal_failure_still_closes = run (fun fixture ->
    let expected = G.Syscall_failed {stage=G.Signal_main; error=Unix.EPERM} in
    (match Eio.Switch.run (fun sw ->
         let child = get (spawn ~sw fixture ": > activated") in
         get (G.await_ready child);
         let waiter = Eio.Fiber.fork_promise ~sw (fun () -> G.await_exit child) in
         let released = G.For_testing.release_with_signal_failure Unix.EPERM child in
         check "signal failure is the release result" (released = Error expected);
         check "failed release closed the handle" (G.observe_boundary child = Error G.Closed);
         check "blocked waiter released by the close" (Eio.Promise.await_exn waiter = Error G.Closed);
         check "failed settlement is cached" (G.release child = released)) with
     | () -> Alcotest.fail "switch cleanup must report the failed release"
     | exception G.Release_failed error -> check "switch cleanup reports that failure" (error = expected));
    check "closed gate prevented payload" (not (Sys.file_exists fixture.marker)))

let control_failure_keeps_reaped_status = run (fun fixture -> Eio.Switch.run (fun sw ->
    let child = get (spawn ~sw fixture ": > activated") in
    get (G.await_ready child);
    check "original kill requested" (get (G.signal_main child G.Kill) = G.Requested);
    let failed = G.Failed (G.Receive_failed Unix.ECONNRESET) in
    let exit = get (G.For_testing.await_exit_with_control_failure Unix.ECONNRESET child) in
    check_exit (-9) exit;
    check "reaped status carries the channel failure" (exit.boundary.control = failed);
    check "boundary reports the same failure" ((get (G.observe_boundary child)).control = failed);
    check "release settles the same observation" (get (G.release child) = exit);
    check "observation after close keeps the failure" (G.poll_exit child = Ok (Some exit))))

let unsupported () = Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let result = G.create ~sw ~executable:"/bin/sh" ~argv:[|"/bin/sh"|] ~env:[||] ~cwd:"/"
        ~payload_uid:1 ~payload_gid:1 ~stdin:Unix.stdin ~stdout:Unix.stdout ~stderr:Unix.stderr in
    check "unsupported platform refused" (result = Error G.Unsupported)))

let unprivileged () = Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let uid = if Unix.geteuid () = 1 then 2 else 1 in
    let result = G.create ~sw ~executable:"/bin/sh" ~argv:[|"/bin/sh"|] ~env:[||] ~cwd:"/"
        ~payload_uid:uid ~payload_gid:uid ~stdin:Unix.stdin ~stdout:Unix.stdout ~stderr:Unix.stderr in
    check "controller privilege required" (result = Error (G.Invalid_input G.Controller_not_root))))

let () =
  (* Only the selected CI test executable is elevated. A missing CI privilege
     boundary fails visibly; no kernel cases silently pass as platform skips. *)
  if G.For_testing.linux_build && Unix.geteuid () <> 0
     && Sys.getenv_opt "GITHUB_ACTIONS" = Some "true" then begin
    let executable = Unix.realpath Sys.executable_name in
    Unix.execvp "sudo" (Array.concat [[|"sudo"; "-n"; "--"; executable|];
                                     Array.sub Sys.argv 1 (Array.length Sys.argv - 1)])
  end;
  let cases =
    if not G.For_testing.linux_build then ["platform refusal", unsupported]
    else if Unix.geteuid () <> 0 then ["unprivileged refusal (kernel cases not run)", unprivileged]
    else ["activation and credential boundary", activated_security;
          "abort before payload", abort_without_effect;
          "exec rejection is bootstrap evidence", rejected_exec;
          "original handle never selects another process", original_handle;
          "wait cancellation and independent progress", waiter_cancellation_and_progress;
          "owner teardown settles paused main", owner_teardown;
          "failed release signal still closes the handle", signal_failure_still_closes;
          "control failure keeps the reaped status", control_failure_keeps_reaped_status;
          "source mutation cannot replace validated inputs", frozen_inputs;
          "root payload refusal", invalid_owner;
          "recursive tree cancellation and independent progress", recursive_tree_and_progress;
          "exclusive group and original handle after name reuse", exclusive_group_and_reused_name;
          "private group waiters retain transitions across other reads", private_group_waiters_keep_their_transition;
          "cancelling an acquired group waiter preserves its owner", cancel_private_group_waiter_preserves_owner] in
  Alcotest.run "Endpoint process gate" ["kernel", List.map (fun (name, test) -> Alcotest.test_case name `Quick test) cases]
