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
      (* Which process answers is the kernel's to say, so nothing but the
         version is read: the public probe may drop every other field. *)
      {|{"version":"1.2.3"}|}, Some "1.2.3";
      {|{"live":true,"ready":true,"phase":"ready","version":"1.2.3"}|}, Some "1.2.3";
      {|{"version":123}|}, None;
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
   ended it, and [reap] waits for the end and says which. [withdraw] has it
   withdraw the announcement and keep the lease, as a server does once its
   listener closes, and returns when that is done. *)
let with_owner_that_withdraws ?(announce = Server_startup_takeover.announce_account_server) ~run_dir
    ~base_path ~announces f =
  let ready_read, ready_write = Unix.pipe () in
  let asked_read, asked_write = Unix.pipe () in
  let child = Unix.fork () in
  if child = 0 then (
    Unix.close ready_read;
    Unix.close asked_write;
    Sys.set_signal Sys.sigterm Sys.Signal_default;
    let withdrawal = ref ignore in
    let holds =
      match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
      | Server_startup_takeover.Base_path_acquired lease ->
        (match announces with
         | None -> true
         | Some port ->
           (* Until the lease is released or the test asks for the withdrawal:
              no listener here would withdraw it. *)
           (match
              Server_startup_takeover.loopback_listener
                ~address:(Ipaddr.V4 Ipaddr.V4.localhost)
                ~port
            with
            | Ok listener ->
              Result.is_ok
                (announce lease listener ~withdraw_with:(fun withdraw -> withdrawal := withdraw))
            | Error (_ : Server_startup_takeover.loopback_unreached) -> false))
      | Server_startup_takeover.Base_path_already_owned _
      | Server_startup_takeover.Base_path_rejected _ -> false in
    ignore (Unix.write_substring ready_write (if holds then "r" else "x") 0 1);
    (* One byte asks for the withdrawal, and one byte answers it. *)
    let asked = Bytes.create 1 in
    (match retrying (fun () -> Unix.read asked_read asked 0 1) with
     | 1 -> !withdrawal (); ignore (Unix.write_substring ready_write "w" 0 1)
     | (_ : int) -> ());
    Unix.close ready_write;
    while true do Unix.pause () done);
  Unix.close ready_write;
  Unix.close asked_read;
  let withdraw () =
    ignore (Unix.write_substring asked_write "w" 0 1);
    let answered = Bytes.create 1 in
    ignore (retrying (fun () -> Unix.read ready_read answered 0 1));
    Alcotest.(check string) "the owner withdrew its announcement" "w" (Bytes.to_string answered) in
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
      Unix.close asked_write;
      if Option.is_none !status then (
        (try Unix.kill child Sys.sigkill with Unix.Unix_error _ -> ());
        ignore (reap ())))
    (fun () ->
      let ready = Bytes.create 1 in
      ignore (retrying (fun () -> Unix.read ready_read ready 0 1));
      Alcotest.(check string) "the owner holds the workspace" "r" (Bytes.to_string ready);
      f ~still_runs ~reap ~withdraw)
let with_owner ?announce ~run_dir ~base_path ~announces f =
  with_owner_that_withdraws ?announce ~run_dir ~base_path ~announces
    (fun ~still_runs ~reap ~withdraw:(_ : unit -> unit) -> f ~still_runs ~reap)
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
    let owner port = Upgrade.owner ~run_dir ~base_path ~port in
    Alcotest.(check string) "a workspace nobody holds" (owner_label (Ok Unowned)) (owner_label (owner port));
    with_byte_locker ~run_dir ~base_path ~byte:port (fun (_ : int) ->
      Alcotest.(check string) "a lock on the port, and no owner"
        (owner_label (Ok Unowned)) (owner_label (owner port));
      (* The owner of the lease announces nothing, and the byte of the port
         is another process's. *)
      with_owner ~run_dir ~base_path ~announces:None (fun ~still_runs ~reap:_ ->
        (match owner port with
         | Ok (Upgrade.Owner_unannounced { pid = (_ : int) }) -> ()
         | other -> Alcotest.failf "the lock of another process named the owner: %s" (owner_label other));
        (match stop port with
         | Error Incumbent_changed -> ()
         | _ -> Alcotest.fail "the owner was asked to stop for the lock of another process");
        Alcotest.(check bool) "it was sent nothing" true (still_runs ())));
    (* The lock of another process, taken before the server announced, is the
       one a read of the whole file may name. *)
    with_byte_locker ~run_dir ~base_path ~byte:(port - 1) (fun (_ : int) ->
      with_owner ~run_dir ~base_path ~announces:(Some port) (fun ~still_runs ~reap ->
        let pid =
          match owner port with
          | Ok (Upgrade.Account_server_here { pid }) -> pid
          | other -> Alcotest.failf "the account server was not seen: %s" (owner_label other) in
        (match owner (port + 1) with
         | Ok (Upgrade.Account_server_elsewhere { pid = named; port = announced }) ->
           Alcotest.(check int) "the owner is named" pid named;
           Alcotest.(check int) "with the port it announces" port announced
         | Ok (Upgrade.Owner_unannounced { pid = named }) ->
           Alcotest.(check int) "the owner is named" pid named
         | other -> Alcotest.failf "another port named a server of its own: %s" (owner_label other));
        (match stop (port - 1) with
         | Error Incumbent_changed -> ()
         | _ -> Alcotest.fail "the owner was asked to stop on the byte of another process");
        Alcotest.(check bool) "it was sent nothing" true (still_runs ());
        (match stop port with
         | Ok () -> ()
         | Error _ -> Alcotest.fail "the owner that announces the port was not asked to stop");
        Alcotest.(check bool) "SIGTERM, no escalation" true (reap () = Unix.WSIGNALED Sys.sigterm))))
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
      (match Upgrade.owner ~run_dir ~base_path ~port with
       | Ok (Upgrade.Single_user_server_here (_ : Upgrade.single_user_server)) -> ()
       | other ->
         Alcotest.failf "the server of a single user was not told from an account server: %s"
           (owner_label other));
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
    (* Once a lease file is there the owner is read through it, and the kind
       of server it announces with it. *)
    let read_made port = Upgrade.owner_without_making (Host_config.Lease_dir_override run_dir) ~base_path ~port in
    with_owner ~run_dir ~base_path ~announces:None (fun ~still_runs ~reap:_ ->
      (match read_made port with
       | Ok (Upgrade.Owner_unannounced { pid = (_ : int) }) -> ()
       | other -> Alcotest.failf "an owner that announces nothing was read as %s" (owner_label other));
      Alcotest.(check bool) "the read sent it nothing" true (still_runs ()));
    Alcotest.(check string) "a lease file nothing holds any more" (owner_label (Ok Unowned))
      (owner_label (read_made port));
    with_owner ~run_dir ~base_path ~announces:(Some port) (fun ~still_runs ~reap:_ ->
      let pid = match read_made port with
        | Ok (Upgrade.Account_server_here { pid }) -> pid
        | other -> Alcotest.failf "the account server was not seen: %s" (owner_label other) in
      Alcotest.(check string) "asked about another port"
        (owner_label (Ok (Account_server_elsewhere { pid; port })))
        (owner_label (read_made (port + 1)));
      Alcotest.(check bool) "the reads sent it nothing" true (still_runs ()));
    let file = Filename.concat root "file" in
    Out_channel.with_open_bin file (fun (_ : Out_channel.t) -> ());
    match Upgrade.owner_without_making (Host_config.Lease_dir_override file) ~base_path ~port with
    | Error (Server_startup_takeover.Owner_lease_rejected _) -> ()
    | other -> Alcotest.failf "a lease root that is a file was read: %s" (owner_label other))
(* The lease is read before the announcements. When no announcement names
   the owner, the lease is read once more, so an owner that left meanwhile or
   a successor is not reported as the first pid announcing nothing. *)
let test_the_lease_is_read_again_before_an_owner_is_called_unannounced () =
  let first = 4242 and port = 9000 in
  let read_with second =
    let captures = ref 0 in
    let capture () = incr captures; if !captures = 1 then Ok first else second in
    let answer =
      Upgrade.For_testing.owner ~capture ~run_dir:"run" ~base_path:"workspace" ~port
        ~single_holder:(fun () -> Ok None) ~account_holder:(fun () -> Ok None)
        ~single_seen:(fun () -> Ok None) ~account_seen:(fun () -> Ok None) in
    Alcotest.(check int) "the lease was read twice" 2 !captures;
    owner_label answer in
  Alcotest.(check string) "the same owner still holds the lease"
    (owner_label (Ok (Owner_unannounced { pid = first }))) (read_with (Ok first));
  Alcotest.(check string) "the owner left meanwhile" (owner_label (Ok Unowned))
    (read_with (Error (Server_startup_takeover.Owner_identity_unavailable Owner_process_identity.No_owner)));
  Alcotest.(check string) "another process took the lease meanwhile"
    (owner_label
       (Error (Server_startup_takeover.Owner_identity_unavailable Owner_process_identity.Owner_changed)))
    (read_with (Ok (first + 1)))
let departure_label = function
  | Ok () -> "confirmed"
  | Error (Upgrade.Announcement_withdrawn { pid }) ->
    Printf.sprintf "pid %d withdrew its announcement" pid
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
(* A socket that listens on a loopback port the system picked. *)
let with_loopback_port f =
  let listening = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close listening) (fun () ->
    Unix.setsockopt listening Unix.SO_REUSEADDR true;
    Unix.bind listening (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
    Unix.listen listening 8;
    match Unix.getsockname listening with
    | Unix.ADDR_INET (_, port) -> f listening port
    | Unix.ADDR_UNIX _ -> Alcotest.fail "loopback fixture port")
let headers = ["authorization", "Bearer fixture-bearer"]
let test_prepare_sends_the_bearer_only_to_the_announcing_owner () =
  with_workspace "masc-upgrade-bearer-" (fun ~root:_ ~base_path ~run_dir ->
    with_loopback_port (fun listening port ->
      let gone =
        with_owner ~announce:single_user ~run_dir ~base_path ~announces:(Some port) (fun ~still_runs:_ ~reap ->
          let server = here_pid ~run_dir ~base_path ~port in
          Unix.kill (Upgrade.single_user_server_pid server) Sys.sigterm;
          ignore (reap ());
          server) in
      with_recording_listener listening (fun ~sw ~clock ~seen ->
        (match Upgrade.prepare ~sw ~clock ~headers gone with
         | Error Owner_unavailable -> ()
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
(* A server that shuts down keeps the lease and withdraws its announcement.
   The capture of the lease owner still names the same process, so only the
   kernel check right before each send keeps the bearer, the stop and the
   sign-in from it. *)
let test_a_server_that_withdrew_its_announcement_is_sent_nothing_more () =
  with_workspace "masc-upgrade-withdrawn-" (fun ~root:_ ~base_path ~run_dir ->
    with_loopback_port (fun listening port ->
      with_owner_that_withdraws ~announce:single_user ~run_dir ~base_path ~announces:(Some port)
        (fun ~still_runs ~reap:_ ~withdraw ->
          let server = here_pid ~run_dir ~base_path ~port in
          with_recording_listener listening (fun ~sw ~clock ~seen ->
            let owner = match Upgrade.prepare ~sw ~clock ~headers server with
              | Ok owner -> owner
              | Error _ -> Alcotest.fail "the server the kernel names was not prepared" in
            Alcotest.(check (list (option string))) "the bearer went to the port once"
              [Some "Bearer fixture-bearer"] !seen;
            withdraw ();
            Alcotest.(check string) "the kernel names the same process without a port"
              (Printf.sprintf "pid %d withdrew its announcement" (Upgrade.single_user_server_pid server))
              (departure_label (Upgrade.confirm server));
            (* Each refusal carries the pid that withdrew, which is what
               restart and setup tell the operator. *)
            let withdrawn step = function
              | Error (Upgrade.Not_confirmed { server = refused; departure = Announcement_withdrawn { pid } }) ->
                Alcotest.(check int) (step ^ ": the pid that withdrew is carried")
                  (Upgrade.single_user_server_pid server) pid;
                Alcotest.(check int) (step ^ ": for the server that was checked")
                  (Upgrade.single_user_server_pid server) (Upgrade.single_user_server_pid refused)
              | Ok () | Error _ -> Alcotest.failf "%s: a server that withdrew its announcement went on" step in
            withdrawn "the stop" (Upgrade.request_termination owner);
            withdrawn "the first bearer"
              (Result.map (fun (_ : Upgrade.t) -> ()) (Upgrade.prepare ~sw ~clock ~headers server));
            withdrawn "the sign-in"
              (Upgrade.authorize_initial ~clock server ~expected_version:"0.0.0"
                 ~login:(fun () -> Alcotest.fail "a server that withdrew its announcement was signed in to"));
            Alcotest.(check (list (option string))) "nothing more went to the port"
              [Some "Bearer fixture-bearer"] !seen;
            Upgrade.close owner);
          Alcotest.(check bool) "it was not asked to stop" true (still_runs ()))))
(* The public probe is what a server answers a command line that sends no
   credential under strict auth, and what every requester gets before the
   workspace is published. The command line reads its version from it, and
   the reader of an account server's answer does not take it for one. *)
let test_the_public_probe_is_a_version_the_command_line_reads () =
  let body =
    Yojson.Safe.to_string
      (Server_health_public.health_json ~ready:false ~phase:Masc.Server_startup_state.Blocking)
  in
  Alcotest.(check (option string)) "the command line reads the release version"
    (Some Runtime_build_version.current) (Upgrade.compact_health_version body);
  Alcotest.(check (option string)) "it is not an account server's answer" None
    (Server_accounts.health_version body)
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
    Alcotest.test_case "compact health version" `Quick test_compact_health_version_reads_one_version;
    Alcotest.test_case "the public probe is a version the command line reads" `Quick
      test_the_public_probe_is_a_version_the_command_line_reads];
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
    Alcotest.test_case "the lease is read again before an owner is called unannounced" `Quick
      test_the_lease_is_read_again_before_an_owner_is_called_unannounced;
    Alcotest.test_case "confirm follows the kernel" `Quick test_confirm_follows_the_kernel;
    Alcotest.test_case "prepare sends the bearer only to the announcing owner" `Quick
      test_prepare_sends_the_bearer_only_to_the_announcing_owner;
    Alcotest.test_case "a server that withdrew its announcement is sent nothing more" `Quick
      test_a_server_that_withdrew_its_announcement_is_sent_nothing_more];
   "account server",[Alcotest.test_case "the stop goes to the owner that announces the port" `Quick
     test_account_server_stop_needs_its_announced_port;
     Alcotest.test_case "a lock without the lease is no account server" `Quick
       test_a_lock_without_the_lease_is_no_account_server;
     Alcotest.test_case "ready is the answer of the replacement" `Quick
       test_ready_is_the_answer_of_the_replacement]]
