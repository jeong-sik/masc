let test_admin_workspace_and_incarnation () =
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let base = Unix.realpath (Filename.get_temp_dir_name ()) in
    let version = ref "0.35.2" and admin = ref true and signals = ref 0 and closes = ref 0 in
    let health () = Ok (Yojson.Safe.to_string (`Assoc ["version",`String !version;
      "paths",`Assoc ["effective_base_path",`String base]])) in
    let prepare () = Server_upgrade_preparation.For_testing.prepare ~sw ~base_path:base
      ~observe:health ~authorize:(fun () -> !admin)
      ~capture:(fun () -> Ok ((fun () -> incr signals; Ok ()),(fun () -> incr closes))) in
    let owner = match prepare () with Ok owner -> owner | Error _ -> Alcotest.fail "valid owner preparation" in
    Alcotest.check Alcotest.int "preparation never stops server" 0 !signals;
    admin := false;
    (match Server_upgrade_preparation.request_termination owner with
     | Error Admin_required -> () | _ -> Alcotest.fail "lost admin permission ignored");
    admin := true; version := "0.35.5";
    (match Server_upgrade_preparation.request_termination owner with
     | Error Incumbent_changed -> () | _ -> Alcotest.fail "replaced incumbent accepted");
    Alcotest.check Alcotest.int "revalidation failures never signal" 0 !signals;
    version := "0.35.2";
    ignore (Server_upgrade_preparation.request_termination owner |> Result.get_ok);
    (match Server_upgrade_preparation.request_termination owner with
     | Error Already_requested -> () | _ -> Alcotest.fail "duplicate request accepted");
    Alcotest.check Alcotest.int "explicit request exactly once" 1 !signals;
    Server_upgrade_preparation.close owner; Server_upgrade_preparation.close owner;
    Alcotest.check Alcotest.int "identity released once" 1 !closes))
let test_other_workspace_never_receives_credentials () =
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let authorizations = ref 0 in
    let result = Server_upgrade_preparation.For_testing.prepare ~sw
      ~base_path:(Filename.get_temp_dir_name ())
      ~observe:(fun () -> Ok {|{"version":"0.35.2","paths":{"effective_base_path":"/"}}|})
      ~authorize:(fun () -> incr authorizations; true)
      ~capture:(fun () -> Alcotest.fail "unrelated workspace captured") in
    (match result with Error Different_workspace -> () | _ -> Alcotest.fail "workspace conflict ignored");
    Alcotest.check Alcotest.int "no credential transmission across workspace conflict" 0 !authorizations))
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
    (match Server_upgrade_preparation.replacement_readiness ~run_dir ~base_path ~port with
     | Ok Port_busy -> () | _ -> Unix.close socket; Alcotest.fail "occupied port was restart-ready");
    Unix.close socket;
    (match Server_upgrade_preparation.replacement_readiness ~run_dir ~base_path ~port with
     | Ok Replacement_can_start -> () | _ -> Alcotest.fail "released owner/port not observed"))
let test_duplicate_health_never_authorizes () =
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let base = Filename.get_temp_dir_name () in
    let path = Yojson.Safe.to_string (`String base) in
    let payloads = [
      "{\"version\":\"0.35.2\",\"version\":\"0.35.5\",\"paths\":{\"effective_base_path\":" ^ path ^ "}}";
      "{\"version\":\"0.35.2\",\"paths\":{\"effective_base_path\":" ^ path ^ ",\"effective_base_path\":\"/\"}}"] in
    List.iter (fun body ->
      (match Server_upgrade_preparation.authorize_initial ~base_path:base
        ~expected_version:"0.35.2" ~body
        ~login:(fun () -> Alcotest.fail "ambiguous initial health invoked login/mint") with
       | Error Invalid_health -> () | _ -> Alcotest.fail "ambiguous pre-login identity accepted");
      match Server_upgrade_preparation.For_testing.prepare ~sw ~base_path:base
        ~observe:(fun () -> Ok body)
        ~authorize:(fun () -> Alcotest.fail "ambiguous health transmitted credentials")
        ~capture:(fun () -> Alcotest.fail "ambiguous health captured owner") with
      | Error Invalid_health -> () | _ -> Alcotest.fail "duplicate identity fields accepted") payloads))
let test_initial_login_identity () =
  let base_path = Unix.realpath (Filename.get_temp_dir_name ()) in
  let body = Yojson.Safe.to_string (`Assoc ["version", `String "0.35.4";
    "paths", `Assoc ["effective_base_path", `String base_path]]) in
  let calls = ref 0 in
  let login () = incr calls; true in
  (match Server_upgrade_preparation.authorize_initial ~base_path ~expected_version:"0.35.5" ~body ~login with
   | Error Incumbent_changed -> () | _ -> Alcotest.fail "changed version invoked login");
  (match Server_upgrade_preparation.authorize_initial ~base_path:"/" ~expected_version:"0.35.4" ~body ~login with
   | Error Different_workspace -> () | _ -> Alcotest.fail "other workspace invoked login");
  Alcotest.check Alcotest.int "rejected identity never mints" 0 !calls;
  (match Server_upgrade_preparation.authorize_initial ~base_path ~expected_version:"0.35.4" ~body ~login with
   | Ok () -> () | Error _ -> Alcotest.fail "exact identity rejected");
  Alcotest.check Alcotest.int "exact identity authorizes once" 1 !calls
let test_termination_request_survives_observation_failure () =
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let base = Unix.realpath (Filename.get_temp_dir_name ()) in
    let health () = Ok (Yojson.Safe.to_string (`Assoc ["version",`String "fixture";
      "paths",`Assoc ["effective_base_path",`String base]])) in
    List.iter (fun expected ->
      let signals = ref 0 in
      let owner = Server_upgrade_preparation.For_testing.prepare ~sw ~base_path:base
        ~observe:health ~authorize:(fun () -> true)
        ~capture:(fun () -> Ok ((fun () -> incr signals; Ok ()),(fun () -> ()))) |> Result.get_ok in
      (match Server_upgrade_preparation.request_termination_and_observe owner ~observe:(fun () -> expected) with
       | Requested observed when observed = expected -> ()
       | Requested _ | Not_requested _ -> Alcotest.fail "termination request lost or readiness invented");
      (match Server_upgrade_preparation.request_termination_and_observe owner
        ~observe:(fun () -> Alcotest.fail "duplicate termination observed again") with
       | Not_requested Already_requested -> ()
       | Not_requested _ | Requested _ -> Alcotest.fail "termination was replayed");
      Alcotest.check Alcotest.int "one signal regardless of observed readiness" 1 !signals;
      Server_upgrade_preparation.close owner)
      [Error Server_upgrade_preparation.Owner_unavailable; Ok Owner_draining; Ok Port_busy; Ok Replacement_can_start];
    let owner = Server_upgrade_preparation.For_testing.prepare ~sw ~base_path:base
      ~observe:health ~authorize:(fun () -> true)
      ~capture:(fun () -> Ok ((fun () -> Ok ()),(fun () -> ()))) |> Result.get_ok in
    (match Server_upgrade_preparation.request_termination_and_observe owner
      ~observe:(fun () -> raise (Sys_error "lease observation failed")) with
     | Requested (Error Owner_unavailable) -> ()
     | Requested _ | Not_requested _ -> Alcotest.fail "post-request file error lost termination evidence")))
let test_refused_termination_never_observes () =
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let base = Unix.realpath (Filename.get_temp_dir_name ()) and admin = ref true in
    let owner = Server_upgrade_preparation.For_testing.prepare ~sw ~base_path:base
      ~observe:(fun () -> Ok (Yojson.Safe.to_string (`Assoc ["version",`String "fixture";
        "paths",`Assoc ["effective_base_path",`String base]])))
      ~authorize:(fun () -> !admin)
      ~capture:(fun () -> Ok ((fun () -> Alcotest.fail "unauthorized signal"),(fun () -> ()))) |> Result.get_ok in
    admin := false;
    match Server_upgrade_preparation.request_termination_and_observe owner
      ~observe:(fun () -> Alcotest.fail "observation after refused termination") with
    | Not_requested Admin_required -> ()
    | Not_requested _ | Requested _ -> Alcotest.fail "refused request reported as sent"))
(* A process that ran an Eio loop keeps the SIGCHLD handler of the posix
   backend, and the end of a child then interrupts the call that waits for it. *)
let rec retrying f =
  match f () with
  | result -> result
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> retrying f
(* A child holds the lease of [base_path] and announces [announces] when it is
   a port. It ends by the signal it is sent: [still_runs] says whether one has
   ended it, and [reap] waits for the end and says which. *)
let with_owner ~run_dir ~base_path ~announces f =
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
              Result.is_ok
                (Server_startup_takeover.announce_account_server lease listener
                   ~withdraw_with:ignore)
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
let with_byte_locker ~run_dir ~base_path ~byte f =
  let path =
    Server_startup_takeover.For_testing.lease_path
      ~run_dir:(Unix.realpath run_dir) ~canonical_base_path:(Unix.realpath base_path)
    ^ ".account-server" in
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
  | Another_server_answers { pid } -> Printf.sprintf "pid %d answers" pid
  | Another_process_announces { pid } -> Printf.sprintf "pid %d announces the port" pid
  | Nobody_announces -> "nobody announces the port"
  | Announcement_unreadable (_ : Server_startup_takeover.base_path_lock_rejection) ->
    "the announcement cannot be read"
  | No_ready_answer -> "no ready answer"
(* The rule [masc restart] waits on. A 200 on the port is the predecessor's
   until it is the replacement's own: by the pid in the answer, or, for an
   answer that names no process, by who holds the announcement lock. The
   kernel is asked only for an answer that names no process. *)
let test_ready_is_the_answer_of_the_replacement () =
  let child_pid = 4242 and predecessor = 77 in
  let row message answer holder ~asked expected =
    let asks = ref 0 in
    let sighting =
      Server_upgrade_preparation.replacement_sighting ~child_pid answer
        ~port_holder:(fun () -> incr asks; holder) in
    Alcotest.(check string) message expected (replacement_sighting_label sighting);
    Alcotest.(check int) (message ^ ": times the kernel was asked") asked !asks in
  row "an answer that names the replacement" (Ready_named child_pid) (Ok None)
    ~asked:0 "the replacement serves";
  row "an answer that names the predecessor, while the replacement announces"
    (Ready_named predecessor) (Ok (Some child_pid)) ~asked:0 "pid 77 answers";
  row "an answer that names no process, and the replacement announces"
    Ready_unnamed (Ok (Some child_pid)) ~asked:1 "the replacement serves";
  row "an answer that names no process, and the predecessor still announces"
    Ready_unnamed (Ok (Some predecessor)) ~asked:1 "pid 77 announces the port";
  row "an answer that names no process, and nobody announces"
    Ready_unnamed (Ok None) ~asked:1 "nobody announces the port";
  row "an answer that names no process, and an announcement that cannot be read"
    Ready_unnamed (Error (Server_startup_takeover.Announcement_port_invalid { port = 0 }))
    ~asked:1 "the announcement cannot be read";
  row "no ready answer, while the replacement announces"
    Not_ready (Ok (Some child_pid)) ~asked:0 "no ready answer"
let () = Alcotest.run "upgrade preparation"
  ["owner checks",[Alcotest.test_case "initial login identity" `Quick test_initial_login_identity;Alcotest.test_case "admin and exact incumbent" `Quick test_admin_workspace_and_incarnation;
    Alcotest.test_case "workspace conflict" `Quick test_other_workspace_never_receives_credentials;
    Alcotest.test_case "kernel lease and port drain" `Quick test_drain_requires_lease_and_port_release;
    Alcotest.test_case "request and observation stay distinct" `Quick test_termination_request_survives_observation_failure;
    Alcotest.test_case "refused request never observes" `Quick test_refused_termination_never_observes;
    Alcotest.test_case "duplicate health identity" `Quick test_duplicate_health_never_authorizes];
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
