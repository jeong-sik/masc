module Upgrade = Server_upgrade_preparation
(* A capture that counts its signals and releases. *)
let counting_capture ~signals ~closes () =
  Ok ((fun () -> incr signals; Ok ()), (fun () -> incr closes))
let test_the_stop_is_confirmed_again_before_the_second_bearer () =
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let confirmed = ref (Ok ()) and admin = ref true and authorizations = ref 0 in
    let signals = ref 0 and closes = ref 0 in
    let owner = match Upgrade.For_testing.prepare ~sw ~capture:(counting_capture ~signals ~closes)
        ~confirm:(fun () -> !confirmed)
        ~authorize:(fun () -> incr authorizations; !admin) with
      | Ok owner -> owner | Error _ -> Alcotest.fail "valid owner preparation" in
    Alcotest.check Alcotest.int "preparation never stops server" 0 !signals;
    Alcotest.check Alcotest.int "the first bearer went out" 1 !authorizations;
    confirmed := Error Upgrade.Incumbent_changed;
    (match Upgrade.request_termination owner with
     | Error Incumbent_changed -> () | _ -> Alcotest.fail "a server the kernel no longer names was asked to stop");
    Alcotest.check Alcotest.int "no second bearer to a server the kernel no longer names" 1 !authorizations;
    confirmed := Ok (); admin := false;
    (match Upgrade.request_termination owner with
     | Error Admin_required -> () | _ -> Alcotest.fail "lost admin permission ignored");
    Alcotest.check Alcotest.int "revalidation failures never signal" 0 !signals;
    admin := true;
    ignore (Upgrade.request_termination owner |> Result.get_ok);
    (match Upgrade.request_termination owner with
     | Error Already_requested -> () | _ -> Alcotest.fail "duplicate request accepted");
    Alcotest.check Alcotest.int "explicit request exactly once" 1 !signals;
    Upgrade.close owner; Upgrade.close owner;
    Alcotest.check Alcotest.int "identity released once" 1 !closes))
let test_an_unconfirmed_owner_never_receives_the_bearer () =
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let authorizations = ref 0 and signals = ref 0 and closes = ref 0 in
    let result = Upgrade.For_testing.prepare ~sw ~capture:(counting_capture ~signals ~closes)
      ~confirm:(fun () -> Error Upgrade.Incumbent_changed)
      ~authorize:(fun () -> incr authorizations; true) in
    (match result with
     | Error Incumbent_changed -> ()
     | _ -> Alcotest.fail "a server the kernel does not name was prepared");
    Alcotest.check Alcotest.int "no bearer to a server the kernel does not name" 0 !authorizations;
    Alcotest.check Alcotest.int "the captured owner was released" 1 !closes;
    Alcotest.check Alcotest.int "nothing was signalled" 0 !signals))
let test_drain_requires_lease_and_port_release () =
  let root = Filename.temp_file "masc-upgrade-drain-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let base_path = Filename.concat root "workspace" and run_dir = Filename.concat root "run" in
    Unix.mkdir base_path 0o700; Unix.mkdir run_dir 0o700;
    let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback,0)); Unix.listen socket 1;
    let port = match Unix.getsockname socket with Unix.ADDR_INET (_,port) -> port
      | _ -> Alcotest.fail "loopback fixture port" in
    (match Upgrade.replacement_readiness ~run_dir ~base_path ~port with
     | Ok Port_busy -> () | _ -> Unix.close socket; Alcotest.fail "occupied port was restart-ready");
    Unix.close socket;
    (match Upgrade.replacement_readiness ~run_dir ~base_path ~port with
     | Ok Replacement_can_start -> () | _ -> Alcotest.fail "released owner/port not observed"))
let test_initial_login_waits_for_the_kernel_and_the_version () =
  let logins = ref 0 and versions = ref 0 in
  let login () = incr logins; true in
  let authorize ~confirm ~answered =
    Upgrade.For_testing.authorize_initial ~confirm
      ~version:(fun () -> incr versions; answered) ~expected_version:"0.35.4" ~login in
  (match authorize ~confirm:(fun () -> Error Upgrade.Incumbent_changed) ~answered:(Some "0.35.4") with
   | Error Incumbent_changed -> () | _ -> Alcotest.fail "a server the kernel does not name was signed in to");
  Alcotest.check Alcotest.int "the port was not asked before the kernel" 0 !versions;
  (match authorize ~confirm:(fun () -> Ok ()) ~answered:None with
   | Error Invalid_health -> () | _ -> Alcotest.fail "a port without a version was signed in to");
  (match authorize ~confirm:(fun () -> Ok ()) ~answered:(Some "0.35.5") with
   | Error Incumbent_changed -> () | _ -> Alcotest.fail "changed version invoked login");
  Alcotest.check Alcotest.int "rejected identity never mints" 0 !logins;
  (match authorize ~confirm:(fun () -> Ok ()) ~answered:(Some "0.35.4") with
   | Ok () -> () | Error _ -> Alcotest.fail "exact identity rejected");
  Alcotest.check Alcotest.int "exact identity authorizes once" 1 !logins
let test_termination_request_survives_observation_failure () =
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    List.iter (fun expected ->
      let signals = ref 0 in
      let owner = Upgrade.For_testing.prepare ~sw ~confirm:(fun () -> Ok ()) ~authorize:(fun () -> true)
        ~capture:(fun () -> Ok ((fun () -> incr signals; Ok ()),(fun () -> ()))) |> Result.get_ok in
      (match Upgrade.request_termination_and_observe owner ~observe:(fun () -> expected) with
       | Requested observed when observed = expected -> ()
       | Requested _ | Not_requested _ -> Alcotest.fail "termination request lost or readiness invented");
      (match Upgrade.request_termination_and_observe owner
        ~observe:(fun () -> Alcotest.fail "duplicate termination observed again") with
       | Not_requested Already_requested -> ()
       | Not_requested _ | Requested _ -> Alcotest.fail "termination was replayed");
      Alcotest.check Alcotest.int "one signal regardless of observed readiness" 1 !signals;
      Upgrade.close owner)
      [Error Upgrade.Owner_unavailable; Ok Owner_draining; Ok Port_busy; Ok Replacement_can_start];
    let owner = Upgrade.For_testing.prepare ~sw ~confirm:(fun () -> Ok ()) ~authorize:(fun () -> true)
      ~capture:(fun () -> Ok ((fun () -> Ok ()),(fun () -> ()))) |> Result.get_ok in
    (match Upgrade.request_termination_and_observe owner
      ~observe:(fun () -> raise (Sys_error "lease observation failed")) with
     | Requested (Error Owner_unavailable) -> ()
     | Requested _ | Not_requested _ -> Alcotest.fail "post-request file error lost termination evidence")))
let test_refused_termination_never_observes () =
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let admin = ref true in
    let owner = Upgrade.For_testing.prepare ~sw ~confirm:(fun () -> Ok ())
      ~authorize:(fun () -> !admin)
      ~capture:(fun () -> Ok ((fun () -> Alcotest.fail "unauthorized signal"),(fun () -> ()))) |> Result.get_ok in
    admin := false;
    match Upgrade.request_termination_and_observe owner
      ~observe:(fun () -> Alcotest.fail "observation after refused termination") with
    | Not_requested Admin_required -> ()
    | Not_requested _ | Requested _ -> Alcotest.fail "refused request reported as sent"))
let test_compact_health_version_reads_one_version () =
  List.iter (fun (body, expected) ->
    Alcotest.(check (option string)) body expected (Upgrade.compact_health_version body))
    [ {|{"server":"masc","version":"1.2.3"}|}, Some "1.2.3";
      {|{"server":"masc","version":"1.2.3","version":"1.2.4"}|}, None;
      {|{"version":"1.2.3"}|}, None;
      {|{"server":"other","version":"1.2.3"}|}, None;
      {|{"server":"masc","version":""}|}, None;
      {|["masc","1.2.3"]|}, None;
      "not json", None ]
(* A process that ran an Eio loop keeps the SIGCHLD handler of the posix
   backend, and the end of a child then interrupts the call that waits for it. *)
let rec retrying f =
  match f () with
  | result -> result
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> retrying f
(* A child holds the lease of [base_path] and announces [announces] when it is
   a port. It ends by the signal it is sent: [still_runs] says whether one has
   ended it, and [reap] waits for the end and says which. *)
let with_owner ?(announce = Server_startup_takeover.announce_account_server) ~run_dir ~base_path
    ~announces f =
  let ready_read, ready_write = Unix.pipe () in
  let child = Unix.fork () in
  if child = 0 then (
    Unix.close ready_read;
    Sys.set_signal Sys.sigterm Sys.Signal_default;
    let holds =
      match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
      | Server_startup_takeover.Base_path_acquired lease ->
        (match announces with
         | None -> true
         | Some port ->
           (* Until the lease is released: these cases ask about the lock, not
              about the listener that would withdraw it. *)
           (match
              Server_startup_takeover.loopback_listener
                ~address:(Ipaddr.V4 Ipaddr.V4.localhost)
                ~port
            with
            | Ok listener ->
              Result.is_ok (announce lease listener ~withdraw_with:ignore)
            | Error (_ : Server_startup_takeover.loopback_unreached) -> false))
      | Server_startup_takeover.Base_path_already_owned _
      | Server_startup_takeover.Base_path_rejected _ -> false in
    ignore (Unix.write_substring ready_write (if holds then "r" else "x") 0 1);
    Unix.close ready_write;
    while true do Unix.pause () done);
  Unix.close ready_write;
  let status = ref None in
  let reap () = match !status with
    | Some ended -> ended
    | None ->
      let _, ended = retrying (fun () -> Unix.waitpid [] child) in
      status := Some ended; ended in
  let still_runs () = match !status with
    | Some (_ : Unix.process_status) -> false
    | None ->
      (match retrying (fun () -> Unix.waitpid [Unix.WNOHANG] child) with
       | 0, _ -> true
       | _, ended -> status := Some ended; false) in
  Fun.protect
    ~finally:(fun () ->
      Unix.close ready_read;
      if Option.is_none !status then (
        (try Unix.kill child Sys.sigkill with Unix.Unix_error _ -> ());
        ignore (reap ())))
    (fun () ->
      let ready = Bytes.create 1 in
      ignore (retrying (fun () -> Unix.read ready_read ready 0 1));
      Alcotest.(check string) "the owner holds the workspace" "r" (Bytes.to_string ready);
      f ~still_runs ~reap)
let test_account_server_stop_needs_its_announced_port () =
  let root = Filename.temp_file "masc-upgrade-account-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let base_path = Filename.concat root "workspace" and run_dir = Filename.concat root "run" in
    Unix.mkdir base_path 0o700; Unix.mkdir run_dir 0o700;
    let port = 9000 in
    let stop port = Server_upgrade_preparation.stop_account_server ~run_dir ~base_path ~port in
    (match stop port with
     | Error Owner_unavailable -> ()
     | _ -> Alcotest.fail "a workspace nobody holds was asked to stop");
    with_owner ~run_dir ~base_path ~announces:None (fun ~still_runs ~reap:_ ->
      (match stop port with
       | Error Incumbent_changed -> ()
       | _ -> Alcotest.fail "an owner that announces no port was asked to stop");
      Alcotest.(check bool) "it was sent nothing" true (still_runs ()));
    with_owner ~run_dir ~base_path ~announces:(Some port) (fun ~still_runs ~reap ->
      (match stop (port + 1) with
       | Error Incumbent_changed -> ()
       | _ -> Alcotest.fail "the owner of another port was asked to stop");
      Alcotest.(check bool) "it was sent nothing" true (still_runs ());
      (match stop port with
       | Ok () -> ()
       | Error _ -> Alcotest.fail "the owner that announces the port was not asked to stop");
      Alcotest.(check bool) "SIGTERM, no escalation" true (reap () = Unix.WSIGNALED Sys.sigterm)))
(* A process without the lease locks [byte] of the announcement file of the
   workspace, as any process of this user can. It is killed at the end. *)
let with_byte_locker ?(suffix = ".account-server") ~run_dir ~base_path ~byte f =
  let path =
    Server_startup_takeover.For_testing.lease_path
      ~run_dir:(Unix.realpath run_dir) ~canonical_base_path:(Unix.realpath base_path)
    ^ suffix in
  let ready_read, ready_write = Unix.pipe () in
  let child = Unix.fork () in
  if child = 0 then (
    Unix.close ready_read;
    let locked =
      match
        let fd = Unix.openfile path [Unix.O_RDWR; Unix.O_CREAT] 0o600 in
        ignore (Unix.lseek fd byte Unix.SEEK_SET);
        Unix.lockf fd Unix.F_TLOCK 1
      with
      | () -> true
      | exception Unix.Unix_error _ -> false in
    ignore (Unix.write_substring ready_write (if locked then "r" else "x") 0 1);
    Unix.close ready_write;
    while true do Unix.pause () done);
  Unix.close ready_write;
  Fun.protect
    ~finally:(fun () ->
      Unix.close ready_read;
      (try Unix.kill child Sys.sigkill with Unix.Unix_error _ -> ());
      ignore (retrying (fun () -> Unix.waitpid [] child)))
    (fun () ->
      let ready = Bytes.create 1 in
      ignore (retrying (fun () -> Unix.read ready_read ready 0 1));
      Alcotest.(check string) "the other process locked its byte" "r" (Bytes.to_string ready);
      f child)
let sighting_label = function
  | Ok Server_upgrade_preparation.No_owner -> "nobody holds the workspace"
  | Ok Owner_announces_nothing -> "the owner announces nothing"
  | Ok (Account_server_on_port { pid }) -> Printf.sprintf "pid %d announces the port" pid
  | Ok (Account_server_on_another_port { pid; port }) ->
    Printf.sprintf "pid %d announces port %d" pid port
  | Error (Server_startup_takeover.Owner_lease_rejected rejection) ->
    "rejected: " ^ Server_startup_takeover.base_path_lock_rejection_to_string rejection
  | Error (Owner_identity_unavailable _) -> "the owner could not be read"
  | Error Current_process_owner -> "this process holds the lease"
(* The lock of a process that does not hold the lease is no account server,
   on the byte of the port or on another one. The stop goes to the owner of
   the lease only when the owner itself holds the byte of the port. *)
let test_a_lock_without_the_lease_is_no_account_server () =
  let root = Filename.temp_file "masc-upgrade-account-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let base_path = Filename.concat root "workspace" and run_dir = Filename.concat root "run" in
    Unix.mkdir base_path 0o700; Unix.mkdir run_dir 0o700;
    let port = 9000 in
    let stop port = Server_upgrade_preparation.stop_account_server ~run_dir ~base_path ~port in
    let check_sighting message expected ~port =
      Alcotest.(check string) message (sighting_label (Ok expected))
        (sighting_label (Server_upgrade_preparation.account_server ~run_dir ~base_path ~port)) in
    check_sighting "a workspace nobody holds" No_owner ~port;
    with_byte_locker ~run_dir ~base_path ~byte:port (fun (_ : int) ->
      check_sighting "a lock on the port, and no owner" No_owner ~port;
      (* The owner of the lease is the server of a single user: it announces
         nothing, and the byte of the port is another process's. *)
      with_owner ~run_dir ~base_path ~announces:None (fun ~still_runs ~reap:_ ->
        check_sighting "a lock on the port, and an owner that announces nothing"
          Owner_announces_nothing ~port;
        (match stop port with
         | Error Incumbent_changed -> ()
         | _ -> Alcotest.fail "the owner was asked to stop for the lock of another process");
        Alcotest.(check bool) "it was sent nothing" true (still_runs ())));
    (* The lock of another process, taken before the server announced, is the
       one a read of the whole file may name. *)
    with_byte_locker ~run_dir ~base_path ~byte:(port - 1) (fun (_ : int) ->
      with_owner ~run_dir ~base_path ~announces:(Some port) (fun ~still_runs ~reap ->
        let owner =
          match Server_upgrade_preparation.account_server ~run_dir ~base_path ~port with
          | Ok (Account_server_on_port { pid }) -> pid
          | other -> Alcotest.failf "the account server was not seen: %s" (sighting_label other) in
        (match Server_upgrade_preparation.account_server ~run_dir ~base_path ~port:(port + 1) with
         | Ok (Account_server_on_another_port { pid; port = announced }) ->
           Alcotest.(check int) "the owner is named" owner pid;
           Alcotest.(check int) "with the port it announces" port announced
         | Ok Owner_announces_nothing -> ()
         | other -> Alcotest.failf "another port named a server of its own: %s" (sighting_label other));
        (match stop (port - 1) with
         | Error Incumbent_changed -> ()
         | _ -> Alcotest.fail "the owner was asked to stop on the byte of another process");
        Alcotest.(check bool) "it was sent nothing" true (still_runs ());
        (match stop port with
         | Ok () -> ()
         | Error _ -> Alcotest.fail "the owner that announces the port was not asked to stop");
        Alcotest.(check bool) "SIGTERM, no escalation" true (reap () = Unix.WSIGNALED Sys.sigterm))))
(* Asked about a port the owner does not announce, the answer names the one
   it does. That is all the read of the whole file gives, and with no lock of
   another process on the file it cannot miss the owner. *)
let test_another_port_names_the_port_the_owner_announces () =
  let root = Filename.temp_file "masc-upgrade-account-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let base_path = Filename.concat root "workspace" and run_dir = Filename.concat root "run" in
    Unix.mkdir base_path 0o700; Unix.mkdir run_dir 0o700;
    let port = 9000 in
    let sighting port = Server_upgrade_preparation.account_server ~run_dir ~base_path ~port in
    with_owner ~run_dir ~base_path ~announces:(Some port) (fun ~still_runs ~reap:_ ->
      let owner =
        match sighting port with
        | Ok (Account_server_on_port { pid }) -> pid
        | other -> Alcotest.failf "the account server was not seen: %s" (sighting_label other) in
      Alcotest.(check string) "asked about another port"
        (sighting_label (Ok (Account_server_on_another_port { pid = owner; port })))
        (sighting_label (sighting (port + 1)));
      Alcotest.(check bool) "the reads sent it nothing" true (still_runs ())))
let holder_label = function
  | Ok Server_upgrade_preparation.Held_by_nobody -> "nobody"
  | Ok Held_without_announcement -> "an owner that announces nothing"
  | Ok (Held_by_account_server { port }) -> Printf.sprintf "an account server on port %d" port
  | Error unread -> "unread: " ^ Server_startup_takeover.owner_capture_error_to_string unread
(* A command that only reads asks who holds the workspace. Where no lease was
   ever made the answer makes none, and an account server is named with the
   port it announces, whichever port was asked about. *)
let test_the_holder_is_read_without_making_anything () =
  let root = Filename.temp_file "masc-upgrade-holder-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let base_path = Filename.concat root "workspace" and run_dir = Filename.concat root "run" in
    Unix.mkdir base_path 0o700; Unix.mkdir run_dir 0o700;
    let port = 9000 in
    let holder ?(lease_root = Host_config.Lease_dir_override run_dir) port =
      holder_label (Server_upgrade_preparation.holder lease_root ~base_path ~port) in
    let check message expected ~port =
      Alcotest.(check string) message (holder_label (Ok expected)) (holder port) in
    let entries path = Array.to_list (Sys.readdir path) in
    check "a workspace nothing started in" Held_by_nobody ~port;
    Alcotest.(check (list string)) "the read made nothing in the lease root" [] (entries run_dir);
    Alcotest.(check string) "with the lease root beside the workspace"
      (holder_label (Ok Held_by_nobody)) (holder ~lease_root:Host_config.Beside_base_path port);
    Alcotest.(check (list string)) "no lease root was made" [] (entries base_path);
    with_owner ~run_dir ~base_path ~announces:None (fun ~still_runs ~reap:_ ->
      check "the server of a single user" Held_without_announcement ~port;
      Alcotest.(check bool) "the read sent it nothing" true (still_runs ()));
    check "a lease file nothing holds any more" Held_by_nobody ~port;
    with_owner ~run_dir ~base_path ~announces:(Some port) (fun ~still_runs ~reap:_ ->
      check "an account server" (Held_by_account_server { port }) ~port;
      check "asked about another port" (Held_by_account_server { port }) ~port:(port + 1);
      Alcotest.(check bool) "the reads sent it nothing" true (still_runs ()));
    (* A lease root that can hold no lease is an answer of its own: that
       nobody holds the workspace is not known. *)
    let file = Filename.concat root "file" in
    Out_channel.with_open_bin file (fun (_ : Out_channel.t) -> ());
    match Server_upgrade_preparation.holder (Host_config.Lease_dir_override file) ~base_path ~port with
    | Error (Server_startup_takeover.Owner_lease_rejected _) -> ()
    | other -> Alcotest.failf "a lease root that is a file was read: %s" (holder_label other))
let replacement_sighting_label = function
  | Server_upgrade_preparation.Replacement_serves -> "the replacement serves"
  | Another_process_announces { pid } -> Printf.sprintf "pid %d announces the port" pid
  | Nobody_announces -> "nobody announces the port"
  | Announcement_unreadable (_ : Server_startup_takeover.base_path_lock_rejection) ->
    "the announcement cannot be read"
  | No_ready_answer -> "no ready answer"
(* The rule [masc restart] waits on. A 200 on the port is the predecessor's
   until the replacement holds the announcement lock of the port. The kernel
   is asked only once the port answered ready. *)
let test_ready_is_the_answer_of_the_replacement () =
  let child_pid = 4242 and predecessor = 77 in
  let row message answer holder ~asked expected =
    let asks = ref 0 in
    let sighting =
      Server_upgrade_preparation.replacement_sighting ~child_pid answer
        ~port_holder:(fun () -> incr asks; holder) in
    Alcotest.(check string) message expected (replacement_sighting_label sighting);
    Alcotest.(check int) (message ^ ": times the kernel was asked") asked !asks in
  row "a ready answer, and the replacement announces"
    Answered_ready (Ok (Some child_pid)) ~asked:1 "the replacement serves";
  row "a ready answer, and the predecessor still announces"
    Answered_ready (Ok (Some predecessor)) ~asked:1 "pid 77 announces the port";
  row "a ready answer, and nobody announces"
    Answered_ready (Ok None) ~asked:1 "nobody announces the port";
  row "a ready answer, and an announcement that cannot be read"
    Answered_ready (Error (Server_startup_takeover.Announcement_port_invalid { port = 0 }))
    ~asked:1 "the announcement cannot be read";
  row "no ready answer, while the replacement announces"
    Not_ready (Ok (Some child_pid)) ~asked:0 "no ready answer"
let owner_label = function
  | Ok (Upgrade.Single_user_server_here server) ->
    Printf.sprintf "pid %d serves port %d" (Upgrade.single_user_server_pid server)
      (Upgrade.single_user_server_port server)
  | Ok (Single_user_server_elsewhere { pid; port }) ->
    Printf.sprintf "pid %d serves port %d elsewhere" pid port
  | Ok (Account_server_here { pid }) -> Printf.sprintf "account server pid %d serves the port" pid
  | Ok (Account_server_elsewhere { pid; port }) ->
    Printf.sprintf "account server pid %d serves port %d elsewhere" pid port
  | Ok (Owner_unannounced { pid }) -> Printf.sprintf "pid %d announces nothing" pid
  | Ok Unowned -> "nobody holds the workspace"
  | Error unread -> "unread: " ^ Server_startup_takeover.owner_capture_error_to_string unread
let with_workspace prefix f =
  let root = Filename.temp_file prefix "" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let base_path = Filename.concat root "workspace" and run_dir = Filename.concat root "run" in
    Unix.mkdir base_path 0o700; Unix.mkdir run_dir 0o700;
    f ~root ~base_path ~run_dir)
let single_user = Server_startup_takeover.announce_single_user_server
let here_pid ~run_dir ~base_path ~port =
  match Upgrade.owner ~run_dir ~base_path ~port with
  | Ok (Upgrade.Single_user_server_here server) -> server
  | other -> Alcotest.failf "the server of a single user was not seen: %s" (owner_label other)
let test_owner_names_a_single_user_server_on_its_port () =
  with_workspace "masc-upgrade-single-" (fun ~root:_ ~base_path ~run_dir ->
    let port = 9000 in
    with_owner ~announce:single_user ~run_dir ~base_path ~announces:(Some port) (fun ~still_runs ~reap:_ ->
      let server = here_pid ~run_dir ~base_path ~port in
      Alcotest.(check int) "the port it announces" port (Upgrade.single_user_server_port server);
      Alcotest.(check string) "the workspace it holds" base_path (Upgrade.single_user_server_base_path server);
      Alcotest.(check bool) "the read sent it nothing" true (still_runs ())))
let test_owner_names_the_port_a_single_user_server_announces () =
  with_workspace "masc-upgrade-single-" (fun ~root:_ ~base_path ~run_dir ->
    let port = 9000 in
    with_owner ~announce:single_user ~run_dir ~base_path ~announces:(Some port) (fun ~still_runs ~reap:_ ->
      let pid = Upgrade.single_user_server_pid (here_pid ~run_dir ~base_path ~port) in
      Alcotest.(check string) "asked about another port"
        (owner_label (Ok (Single_user_server_elsewhere { pid; port })))
        (owner_label (Upgrade.owner ~run_dir ~base_path ~port:(port + 1)));
      Alcotest.(check bool) "the reads sent it nothing" true (still_runs ())))
let test_owner_tells_an_account_server_from_a_single_user_server () =
  with_workspace "masc-upgrade-kind-" (fun ~root:_ ~base_path ~run_dir ->
    let port = 9000 in
    with_owner ~run_dir ~base_path ~announces:(Some port) (fun ~still_runs ~reap:_ ->
      let pid = match Upgrade.owner ~run_dir ~base_path ~port with
        | Ok (Upgrade.Account_server_here { pid }) -> pid
        | other -> Alcotest.failf "the account server was not seen: %s" (owner_label other) in
      Alcotest.(check string) "the account server, asked about another port"
        (owner_label (Ok (Account_server_elsewhere { pid; port })))
        (owner_label (Upgrade.owner ~run_dir ~base_path ~port:(port + 1)));
      Alcotest.(check bool) "the reads sent it nothing" true (still_runs ()));
    with_owner ~announce:single_user ~run_dir ~base_path ~announces:(Some port) (fun ~still_runs ~reap:_ ->
      (match Upgrade.account_server ~run_dir ~base_path ~port with
       | Ok Owner_announces_nothing -> ()
       | Ok _ | Error _ -> Alcotest.fail "the server of a single user was read as an account server");
      Alcotest.(check bool) "the reads sent it nothing" true (still_runs ())))
let test_an_owner_that_announces_nothing_is_named_by_pid () =
  with_workspace "masc-upgrade-silent-" (fun ~root:_ ~base_path ~run_dir ->
    let port = 9000 in
    with_owner ~run_dir ~base_path ~announces:None (fun ~still_runs ~reap:_ ->
      (match Upgrade.owner ~run_dir ~base_path ~port with
       | Ok (Upgrade.Owner_unannounced { pid }) ->
         Alcotest.(check bool) "a pid of a live process is named" true (pid > 0)
       | other -> Alcotest.failf "an owner that announces nothing was read as %s" (owner_label other));
      Alcotest.(check bool) "the read sent it nothing" true (still_runs ())))
let test_a_lock_without_the_lease_is_no_single_user_server () =
  with_workspace "masc-upgrade-squat-" (fun ~root:_ ~base_path ~run_dir ->
    let port = 9000 in
    with_byte_locker ~suffix:".single-user-server" ~run_dir ~base_path ~byte:port (fun (_ : int) ->
      Alcotest.(check string) "a lock on the port, and no owner"
        (owner_label (Ok Unowned)) (owner_label (Upgrade.owner ~run_dir ~base_path ~port));
      with_owner ~run_dir ~base_path ~announces:None (fun ~still_runs ~reap:_ ->
        (match Upgrade.owner ~run_dir ~base_path ~port with
         | Ok (Upgrade.Owner_unannounced { pid = (_ : int) }) -> ()
         | other -> Alcotest.failf "the lock of another process named the owner: %s" (owner_label other));
        Alcotest.(check bool) "it was sent nothing" true (still_runs ()))))
let test_owner_without_making_makes_nothing () =
  with_workspace "masc-upgrade-unmade-" (fun ~root ~base_path ~run_dir ->
    let port = 9000 in
    let read root = owner_label (Upgrade.owner_without_making root ~base_path ~port) in
    Alcotest.(check string) "a workspace nothing started in" (owner_label (Ok Unowned))
      (read (Host_config.Lease_dir_override run_dir));
    Alcotest.(check (array string)) "the read made nothing in the lease root" [||] (Sys.readdir run_dir);
    Alcotest.(check string) "with the lease root beside the workspace" (owner_label (Ok Unowned))
      (read Host_config.Beside_base_path);
    Alcotest.(check (array string)) "no lease root was made" [||] (Sys.readdir base_path);
    let file = Filename.concat root "file" in
    Out_channel.with_open_bin file (fun (_ : Out_channel.t) -> ());
    match Upgrade.owner_without_making (Host_config.Lease_dir_override file) ~base_path ~port with
    | Error (Server_startup_takeover.Owner_lease_rejected _) -> ()
    | other -> Alcotest.failf "a lease root that is a file was read: %s" (owner_label other))
let departure_label = function
  | Ok () -> "confirmed"
  | Error (Upgrade.Owner_now now) -> "now " ^ owner_label (Ok now)
  | Error (Owner_unreadable unread) -> owner_label (Error unread)
let test_confirm_follows_the_kernel () =
  with_workspace "masc-upgrade-confirm-" (fun ~root:_ ~base_path ~run_dir ->
    let port = 9000 in
    with_owner ~announce:single_user ~run_dir ~base_path ~announces:(Some port) (fun ~still_runs:_ ~reap ->
      let server = here_pid ~run_dir ~base_path ~port in
      Alcotest.(check string) "the same server" "confirmed" (departure_label (Upgrade.confirm server));
      Unix.kill (Upgrade.single_user_server_pid server) Sys.sigterm;
      Alcotest.(check bool) "the pid named is the process that held the lease" true
        (reap () = Unix.WSIGNALED Sys.sigterm);
      Alcotest.(check string) "the server is gone" ("now " ^ owner_label (Ok Unowned))
        (departure_label (Upgrade.confirm server));
      with_owner ~announce:single_user ~run_dir ~base_path ~announces:(Some port) (fun ~still_runs:_ ~reap:_ ->
        let successor = here_pid ~run_dir ~base_path ~port in
        Alcotest.(check bool) "another process" true
          (Upgrade.single_user_server_pid successor <> Upgrade.single_user_server_pid server);
        Alcotest.(check string) "another process announces the port"
          ("now " ^ owner_label (Ok (Single_user_server_here successor)))
          (departure_label (Upgrade.confirm server)))))
(* A loopback listener that answers 200 to every request and records the
   authorization header of each, for as long as [f] runs. *)
let with_recording_listener listening f =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    Eio_context.set_env env; Eio_context.set_switch sw;
    Eio_context.set_net (Eio.Stdenv.net env); Eio_context.set_clock (Eio.Stdenv.clock env);
    let socket = Eio_unix.Net.import_socket_listening ~sw ~close_unix:false listening in
    let seen = ref [] in
    let answer flow =
      let reader = Eio.Buf_read.of_flow flow ~max_size:65536 in
      let rec headers acc =
        match Eio.Buf_read.line reader with
        | "" -> acc
        | line ->
          (match String.index_opt line ':' with
           | Some colon when String.lowercase_ascii (String.sub line 0 colon) = "authorization" ->
             headers (Some (String.trim (String.sub line (colon + 1) (String.length line - colon - 1))))
           | Some _ | None -> headers acc) in
      let (_ : string) = Eio.Buf_read.line reader in
      seen := headers None :: !seen;
      Eio.Flow.copy_string "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}" flow in
    let rec serve () =
      Eio.Net.accept_fork ~sw socket ~on_error:ignore (fun flow _ -> answer flow);
      serve () in
    Masc_http_client.with_scoped_pool ~sw ~env (fun () ->
      Eio.Fiber.first serve (fun () -> f ~sw ~clock:(Eio.Stdenv.clock env) ~seen))))
let test_prepare_sends_the_bearer_only_to_the_announcing_owner () =
  with_workspace "masc-upgrade-bearer-" (fun ~root:_ ~base_path ~run_dir ->
    let listening = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect ~finally:(fun () -> Unix.close listening) (fun () ->
      Unix.setsockopt listening Unix.SO_REUSEADDR true;
      Unix.bind listening (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      Unix.listen listening 8;
      let port = match Unix.getsockname listening with
        | Unix.ADDR_INET (_, port) -> port | Unix.ADDR_UNIX _ -> Alcotest.fail "loopback fixture port" in
      let headers = ["authorization", "Bearer fixture-bearer"] in
      let gone =
        with_owner ~announce:single_user ~run_dir ~base_path ~announces:(Some port) (fun ~still_runs:_ ~reap ->
          let server = here_pid ~run_dir ~base_path ~port in
          Unix.kill (Upgrade.single_user_server_pid server) Sys.sigterm;
          ignore (reap ());
          server) in
      with_recording_listener listening (fun ~sw ~clock ~seen ->
        (match Upgrade.prepare ~sw ~clock ~headers gone with
         | Error (Incumbent_changed | Owner_unavailable) -> ()
         | Ok _ | Error _ -> Alcotest.fail "a server that is gone was prepared");
        Alcotest.(check int) "nothing was sent to the port" 0 (List.length !seen));
      with_owner ~announce:single_user ~run_dir ~base_path ~announces:(Some port) (fun ~still_runs:_ ~reap ->
        let server = here_pid ~run_dir ~base_path ~port in
        with_recording_listener listening (fun ~sw ~clock ~seen ->
          let owner = match Upgrade.prepare ~sw ~clock ~headers server with
            | Ok owner -> owner
            | Error _ -> Alcotest.fail "the server the kernel names was not prepared" in
          Alcotest.(check (list (option string))) "the bearer went to the port once"
            [Some "Bearer fixture-bearer"] !seen;
          (match Upgrade.request_termination owner with
           | Ok () -> () | Error _ -> Alcotest.fail "the server the kernel names was not asked to stop");
          Alcotest.(check int) "the bearer went again before the stop" 2 (List.length !seen);
          Upgrade.close owner);
        Alcotest.(check bool) "SIGTERM, no escalation" true (reap () = Unix.WSIGNALED Sys.sigterm))))
let () = Alcotest.run "upgrade preparation"
  ["owner checks",[Alcotest.test_case "initial login waits for the kernel and the version" `Quick
      test_initial_login_waits_for_the_kernel_and_the_version;
    Alcotest.test_case "the stop is confirmed again before the second bearer" `Quick
      test_the_stop_is_confirmed_again_before_the_second_bearer;
    Alcotest.test_case "an unconfirmed owner never receives the bearer" `Quick
      test_an_unconfirmed_owner_never_receives_the_bearer;
    Alcotest.test_case "kernel lease and port drain" `Quick test_drain_requires_lease_and_port_release;
    Alcotest.test_case "request and observation stay distinct" `Quick test_termination_request_survives_observation_failure;
    Alcotest.test_case "refused request never observes" `Quick test_refused_termination_never_observes;
    Alcotest.test_case "compact health version" `Quick test_compact_health_version_reads_one_version];
   "single-user server",[Alcotest.test_case "the owner names a single-user server on its port" `Quick
      test_owner_names_a_single_user_server_on_its_port;
    Alcotest.test_case "the owner names the port a single-user server announces" `Quick
      test_owner_names_the_port_a_single_user_server_announces;
    Alcotest.test_case "the owner tells an account server from a single-user server" `Quick
      test_owner_tells_an_account_server_from_a_single_user_server;
    Alcotest.test_case "an owner that announces nothing is named by pid" `Quick
      test_an_owner_that_announces_nothing_is_named_by_pid;
    Alcotest.test_case "a lock without the lease is no single-user server" `Quick
      test_a_lock_without_the_lease_is_no_single_user_server;
    Alcotest.test_case "the owner is read without making anything" `Quick
      test_owner_without_making_makes_nothing;
    Alcotest.test_case "confirm follows the kernel" `Quick test_confirm_follows_the_kernel;
    Alcotest.test_case "prepare sends the bearer only to the announcing owner" `Quick
      test_prepare_sends_the_bearer_only_to_the_announcing_owner];
   "account server",[Alcotest.test_case "the stop goes to the owner that announces the port" `Quick
     test_account_server_stop_needs_its_announced_port;
     Alcotest.test_case "a lock without the lease is no account server" `Quick
       test_a_lock_without_the_lease_is_no_account_server;
     Alcotest.test_case "another port names the port the owner announces" `Quick
       test_another_port_names_the_port_the_owner_announces;
     Alcotest.test_case "the holder is read without making anything" `Quick
       test_the_holder_is_read_without_making_anything;
     Alcotest.test_case "ready is the answer of the replacement" `Quick
       test_ready_is_the_answer_of_the_replacement]]
