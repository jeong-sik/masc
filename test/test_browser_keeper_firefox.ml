(* RFC-browser-keeper-firefox §3.1-§3.3: the [browser.live.bidi] table, what
   the server runs, the detached spawn, and starting only what is missing. *)
open Alcotest
module Keeper_firefox = Masc.Browser_keeper_firefox
module Record = Masc.Browser_bidi_host_record
module Status = Masc.Browser_bidi_host_status

let parse text =
  match Otoml.Parser.from_string_result text with
  | Error detail -> fail detail
  | Ok toml -> Browser_configuration.parse toml

let refused ~mentions text =
  match parse text with
  | Ok _ -> fail ("accepted: " ^ text)
  | Error detail ->
    check bool (Printf.sprintf "%S names %S" detail mentions) true
      (String_util.contains_substring detail mentions)

let bidi = "[browser.live.bidi]\nfirefox = \"/Apps/firefox\"\nprofile = \"/keeper/profile\"\n"

let table_with_both_paths_and_the_default_port () =
  match parse bidi with
  | Error detail -> fail detail
  | Ok config ->
    check bool "read as written, port 9222" true
      (config.live_bidi = Some { firefox = "/Apps/firefox"; profile = "/keeper/profile"; port = 9222 });
    check bool "the live lane stays on" true config.live_enabled

let table_with_a_port_and_the_live_lane_off () =
  match parse ("[browser.live]\nenabled = false\n" ^ bidi ^ "port = 9333\n") with
  | Error detail -> fail detail
  | Ok config ->
    check bool "both read" true
      (config.live_bidi = Some { firefox = "/Apps/firefox"; profile = "/keeper/profile"; port = 9333 }
       && not config.live_enabled)

let no_table_names_no_firefox () =
  match parse "[browser.live]\nenabled = true\n" with
  | Error detail -> fail detail
  | Ok config -> check bool "none" true (config.live_bidi = None)

let a_table_that_cannot_start_firefox_is_refused () =
  refused ~mentions:"browser.live.bidi.firefox is required" "[browser.live.bidi]\nprofile = \"/p\"\n";
  refused ~mentions:"browser.live.bidi.profile is required" "[browser.live.bidi]\nfirefox = \"/f\"\n";
  refused ~mentions:"browser.live.bidi.firefox is required" "[browser.live.bidi]\nport = 9222\n";
  refused ~mentions:"browser.live.bidi.profile must be a non-empty absolute path"
    "[browser.live.bidi]\nfirefox = \"/f\"\nprofile = \"keeper\"\n";
  List.iter
    (fun port ->
      refused ~mentions:"browser.live.bidi.port must be an integer from 1 to 65535"
        (bidi ^ "port = " ^ port ^ "\n"))
    [ "0"; "65536"; "\"9222\"" ];
  refused ~mentions:"browser.live.bidi.headless is not a supported setting" (bidi ^ "headless = true\n");
  refused ~mentions:"browser.live.other is not a supported setting" "[browser.live]\nother = 1\n"

let config : Browser_configuration.live_bidi =
  { firefox = "/Apps/firefox"; profile = "/keeper/profile"; port = 9333 }

let commands_run () =
  check (list string) "firefox"
    [ "/Apps/firefox"; "--no-remote"; "--profile"; "/keeper/profile"; "--remote-debugging-port"; "9333" ]
    (Keeper_firefox.firefox_argv config);
  check (list string) "host"
    [ "/ws/.masc/browser-lane/host/launch"; "--bidi-url"; "ws://127.0.0.1:9333/session"
    ; "--firefox-profile"; "/keeper/profile" ]
    (Keeper_firefox.host_argv ~launcher:"/ws/.masc/browser-lane/host/launch" config);
  check string "firefox log" "/ws/.masc/browser-lane/keeper-firefox.log"
    (Keeper_firefox.firefox_log_path ~base_path:"/ws");
  check string "host log" "/ws/.masc/browser-lane/bidi-host.log" (Keeper_firefox.host_log_path ~base_path:"/ws");
  let says status = String_util.contains_substring
      (Keeper_firefox.firefox_failure_message config (Keeper_firefox.Exited_before_listening status))
      "Another Firefox may have /keeper/profile open" in
  check bool "status 0 names a profile another Firefox holds" true (says (Some (Unix.WEXITED 0)));
  check bool "another status does not" false (says (Some (Unix.WEXITED 1)) || says None);
  check bool "a port no check could read keeps the last reason" true
    (String_util.contains_substring
       (Keeper_firefox.firefox_failure_message config
          (Keeper_firefox.Port_unknown { seconds = 30.; detail = "no answer within 1 s" }))
       "no answer within 1 s")

(* --- workspaces --------------------------------------------------------- *)

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  | _ -> Sys.remove path

let with_workspace f =
  let base = Filename.temp_file "masc-keeper-firefox-" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  Fun.protect ~finally:(fun () -> remove base) (fun () -> f base)

let write ?(mode = 0o600) path text =
  Out_channel.with_open_bin path (fun output -> output_string output text);
  Unix.chmod path mode

let read path = In_channel.with_open_bin path In_channel.input_all
let lane base = List.fold_left Filename.concat base [ ".masc"; "browser-lane" ]
let launcher base = Filename.concat (lane base) "host/launch"

(* Runs until it is stopped. [name] is in its command line, which is how the
   cleanup tells it from a process that later got the same pid. *)
let sleeper_command name = Printf.sprintf "python3 -c 'import time; time.sleep(30)' %s" (Filename.quote name)

(* What install-host.sh leaves, with a launcher that records what it was
   given. [declared:false] leaves out launch.json, which reads as a launcher
   to install again. *)
let install_lane ?(declared = true) base ~marker =
  List.iter (fun dir -> Unix.mkdir dir 0o700)
    [ Filename.concat base ".masc"; lane base; Filename.concat (lane base) "host" ];
  let script =
    Printf.sprintf
      "#!/bin/sh\nprintf '%%s\\n' \"${MASC_HTTP_PORT-unset} ${MASC_HTTP_BASE_URL-unset}\" > %s.env\n\
       printf '%%s\\n' \"$$\" \"$@\" > %s\nexec %s\n"
      (Filename.quote marker) (Filename.quote marker) (sleeper_command marker) in
  write ~mode:0o700 (launcher base) script;
  if declared then
    write (Filename.concat (lane base) "host/launch.json")
      (Yojson.Safe.to_string
         (`Assoc [ "destination", `String "workspace_connection";
                   "launcher_sha256", `String Digestif.SHA256.(to_hex (digest_string script)) ]))

let host_step ?(port = 9333) base = Keeper_firefox.host_step ~port (Status.report (Status.observe ~base_path:base))

let take ?(port = 9333) base =
  match
    Record.take ~base_path:base ~pid:(Unix.getpid ()) ~bidi_url:(Printf.sprintf "ws://127.0.0.1:%d/session" port)
      ~client_id:(match Browser_lane.client_id_of_string "0199c0de-0000-7000-8000-000000000001" with
        | Ok id -> id | Error detail -> fail detail)
      ~now:1_791_000_000.
  with
  | Ok { held; not_synced = None } -> held
  | Ok { not_synced = Some detail; _ } -> fail detail
  | Error refusal -> fail (Record.refusal_message refusal)

let released held = match Record.release held with Ok () -> () | Error detail -> fail detail

let host_is_started_only_with_an_installed_launcher_and_no_host () =
  with_workspace (fun base ->
    install_lane base ~marker:"/unused";
    (match host_step base with
     | Keeper_firefox.Start_host path -> check string "the workspace launcher" (launcher base) path
     | Keeper_firefox.Host_running | Keeper_firefox.Host_on_another_port _ | Keeper_firefox.Host_address_unknown
     | Keeper_firefox.Launcher_not_ready _ ->
       fail "not started");
    let held = take base in
    Fun.protect ~finally:(fun () -> released held) (fun () ->
      check bool "a host holds the lock" true (host_step base = Keeper_firefox.Host_running);
      check bool "a host given another port" true
        (host_step ~port:9444 base = Keeper_firefox.Host_on_another_port "ws://127.0.0.1:9333/session");
      (* A host that has just taken the lock has not written its record. *)
      Sys.remove (Record.record_path ~base_path:base);
      (match Record.observe ~base_path:base with
       | Record.Record_missing_but_locked -> ()
       | _ -> fail "expected a held lock with no record");
      check bool "a held lock with no record: a host, on a port not known" true
        (host_step base = Keeper_firefox.Host_address_unknown);
      (* A record no reader can load, beside a lock still held, is a host
         that runs: a second one would only be refused at the lock. *)
      write (Record.record_path ~base_path:base) "{";
      (match Record.observe ~base_path:base with
       | Record.Unreadable { held = Some true; _ } -> ()
       | _ -> fail "expected an unreadable record beside a held lock");
      check bool "an unreadable record beside a held lock: a host, on a port not known" true
        (host_step base = Keeper_firefox.Host_address_unknown)));
  with_workspace (fun base ->
    check bool "no lane" true
      (host_step base = Keeper_firefox.Launcher_not_ready Keeper_firefox.Not_installed));
  with_workspace (fun base ->
    install_lane ~declared:false base ~marker:"/unused";
    check bool "an undeclared launcher" true
      (host_step base = Keeper_firefox.Launcher_not_ready Keeper_firefox.Needs_reinstall))

(* --- the detached spawn ---------------------------------------------------- *)

let alive pid = match Unix.kill pid 0 with () -> true | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
let stop pid = if alive pid then try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ()

let output_file path = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_CLOEXEC ] 0o600

let process_group pid =
  let ps = Unix.open_process_args_in "/bin/ps" [| "ps"; "-o"; "pgid="; "-p"; string_of_int pid |] in
  let text = In_channel.input_all ps in
  ignore (Unix.close_process_in ps);
  int_of_string (String.trim text)

let spawn_reports_exit_and_writes_output () =
  with_workspace (fun base ->
    let path = Filename.concat base "out" in
    Eio_main.run (fun _env -> Eio.Switch.run (fun sw ->
      let output = output_file path in
      let spawned =
        Posix_spawn_detached.spawn ~sw ~argv:[ "/bin/sh"; "-c"; "echo out; echo err >&2; exit 3" ]
          ~env:(Unix.environment ()) ~output in
      Unix.close output;
      match spawned with
      | Error detail -> fail detail
      | Ok child ->
        check bool "exit 3" true (Eio.Promise.await child.exited = Some (Unix.WEXITED 3))));
    check string "stdout and stderr" "out\nerr\n" (read path))

let spawn_outlives_its_switch_in_its_own_group () =
  with_workspace (fun base ->
    let output = output_file (Filename.concat base "out") in
    let pid =
      Eio_main.run (fun _env -> Eio.Switch.run (fun sw ->
        match Posix_spawn_detached.spawn ~sw ~argv:[ "/bin/sleep"; "30" ] ~env:(Unix.environment ()) ~output with
        | Error detail -> fail detail
        | Ok child -> child.pid)) in
    Unix.close output;
    Fun.protect ~finally:(fun () -> stop pid) (fun () ->
      check bool "still running after its switch" true (alive pid);
      check int "its own process group" pid (process_group pid)))

let spawn_of_a_missing_executable_is_an_error () =
  Eio_main.run (fun _env -> Eio.Switch.run (fun sw ->
    match Posix_spawn_detached.spawn ~sw ~argv:[ "/nonexistent/firefox" ] ~env:[||] ~output:Unix.stdout with
    | Ok child -> stop child.pid; fail "started"
    | Error detail ->
      check bool detail true (String_util.contains_substring detail "/nonexistent/firefox")))

(* --- what the server starts ------------------------------------------------ *)

let free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close socket) (fun () ->
    Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
    match Unix.getsockname socket with Unix.ADDR_INET (_, port) -> port | Unix.ADDR_UNIX _ -> fail "port")

(* Opens [port] and writes its own pid to [pidfile], so a case can stop it. *)
let listener_command =
  "python3 -c 'import os,socket,sys,time\n\
   open(sys.argv[2], \"w\").write(str(os.getpid()))\n\
   s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n\
   s.bind((\"127.0.0.1\", int(sys.argv[1]))); s.listen(4); time.sleep(30)'"

type fake = Listens | Exits | Relaunches | Never_listens

(* A Firefox that records its pid and what it was given, then behaves as
   [fake] says: [Exits] at once, as Firefox does on a profile another
   Firefox holds; [Relaunches], leaving a process in its group that opens
   the port half a second later, as a Firefox applying an update does. *)
let fake_firefox base ~marker fake =
  let path = Filename.concat base "firefox" in
  let pidfile = Filename.quote (marker ^ ".listener") in
  let tail = match fake with
    | Listens -> Printf.sprintf "exec %s \"$port\" %s\n" listener_command pidfile
    | Exits -> "exit 0\n"
    | Relaunches -> Printf.sprintf "( sleep 0.5; exec %s \"$port\" %s ) &\nexit 0\n" listener_command pidfile
    | Never_listens -> Printf.sprintf "exec %s\n" (sleeper_command marker) in
  write ~mode:0o700 path
    (Printf.sprintf
       "#!/bin/sh\nprev=\nfor arg in \"$@\"; do [ \"$prev\" = --remote-debugging-port ] && port=$arg; prev=$arg; done\n\
        printf '%%s\\n' \"$$\" \"$@\" > %s\n%s"
       (Filename.quote marker) tail);
  path

let lines path = String.split_on_char '\n' (String.trim (read path))

let await_file path =
  let deadline = Unix.gettimeofday () +. 10. in
  let rec wait () =
    if Sys.file_exists path && String.trim (read path) <> "" then ()
    else if Unix.gettimeofday () > deadline then fail (path ^ " was not written")
    else (Unix.sleepf 0.05; wait ()) in
  wait ()

let first_pid path =
  if Sys.file_exists path && String.trim (read path) <> "" then Some (int_of_string (List.hd (lines path)))
  else None

let started ?(ready_timeout_s = Keeper_firefox.firefox_ready_timeout_s) ~base ~configuration () =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    match
      Eio.Promise.await
        (Server_browser_keeper_firefox.For_testing.start ~ready_timeout_s ~sw ~env ~base_path:base
           ~configuration)
    with
    | Ok () -> ()
    | Error exn -> raise exn))

let configured ?(live_enabled = true) ~firefox ~port base =
  Some { Browser_configuration.none with
         live_enabled;
         live_bidi = Some { firefox; profile = Filename.concat base "profile"; port } }

(* The server opens each log before it starts the process that writes it,
   so a log that is not there says the process was never started. *)
let firefox_started base = Sys.file_exists (Keeper_firefox.firefox_log_path ~base_path:base)
let host_started base = Sys.file_exists (Keeper_firefox.host_log_path ~base_path:base)

(* The command line of [pid], or "" when no process has that pid. *)
let command_line pid =
  let ps = Unix.open_process_args_in "/bin/ps" [| "ps"; "-ww"; "-o"; "command="; "-p"; string_of_int pid |] in
  let text = In_channel.input_all ps in
  ignore (Unix.close_process_in ps);
  String.trim text

(* Children are detached: stop them whatever the case checked. A marker
   keeps the pid of a process that may have ended and been reaped already,
   as a Firefox that exits does, and the system may have given that pid to
   another process since. Every process a case starts names a path under
   [base] in its command line, so only those are stopped. *)
let with_children ~base markers f =
  let stop_ours pid =
    if String_util.contains_substring (command_line pid) base then
      try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> () in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun marker -> List.iter (fun path -> Option.iter stop_ours (first_pid path)) [ marker; marker ^ ".listener" ])
        markers)
    f

let markers base = Filename.concat base "firefox-ran", Filename.concat base "host-ran"

let a_free_port_starts_firefox_then_the_host () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let port = free_port () in
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      started ~base ~configuration:(configured ~firefox ~port base) ();
      check (list string) "firefox was given the profile and the port"
        [ "--no-remote"; "--profile"; Filename.concat base "profile"; "--remote-debugging-port"; string_of_int port ]
        (List.tl (lines firefox_marker));
      await_file host_marker;
      check (list string) "the host was given that Firefox's address and profile"
        [ "--bidi-url"; Printf.sprintf "ws://127.0.0.1:%d/session" port
        ; "--firefox-profile"; Filename.concat base "profile" ]
        (List.tl (lines host_marker));
      check bool "both write under the lane" true (firefox_started base && host_started base)))

let an_answering_port_starts_only_the_host () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
        let listener =
          Eio.Net.listen (Eio.Stdenv.net env) ~sw ~reuse_addr:true ~backlog:4
            (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
        let port = match Eio.Net.listening_addr listener with `Tcp (_, port) -> port | `Unix _ -> fail "tcp" in
        match
          Eio.Promise.await
            (Server_browser_keeper_firefox.For_testing.start
               ~ready_timeout_s:Keeper_firefox.firefox_ready_timeout_s ~sw ~env ~base_path:base
               ~configuration:(configured ~firefox ~port base))
        with
        | Ok () -> ()
        | Error exn -> raise exn));
      await_file host_marker;
      check bool "no second Firefox" false (firefox_started base)))

let a_running_host_with_no_firefox_starts_nothing () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    let port = free_port () in
    let held = take ~port base in
    Fun.protect ~finally:(fun () -> released held) (fun () ->
      with_children ~base [ firefox_marker; host_marker ] (fun () ->
        started ~base ~configuration:(configured ~firefox ~port base) ();
        check bool "no Firefox that host would not attach to" false (firefox_started base);
        check bool "no second host" false (host_started base))))

let a_host_whose_address_cannot_be_read_starts_nothing () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    let held = take base in
    Fun.protect ~finally:(fun () -> released held) (fun () ->
      write (Record.record_path ~base_path:base) "{";
      with_children ~base [ firefox_marker; host_marker ] (fun () ->
        started ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) ();
        check bool "no Firefox" false (firefox_started base);
        check bool "no second host" false (host_started base))))

let a_host_on_another_port_starts_nothing () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    let port = free_port () in
    let held = take ~port:(if port = 9333 then 9334 else 9333) base in
    Fun.protect ~finally:(fun () -> released held) (fun () ->
      with_children ~base [ firefox_marker; host_marker ] (fun () ->
        started ~base ~configuration:(configured ~firefox ~port base) ();
        check bool "no Firefox no host can use" false (firefox_started base);
        check bool "no second host" false (host_started base))))

let a_firefox_that_exits_first_starts_no_host () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Exits in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      let began = Unix.gettimeofday () in
      started ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) ();
      check bool "its exit ends the wait, not the timeout" true
        (Unix.gettimeofday () -. began < Keeper_firefox.firefox_ready_timeout_s /. 3.);
      check bool "firefox ran" true (Sys.file_exists firefox_marker);
      check bool "no host for a Firefox that is not there" false (host_started base)))

let a_firefox_that_goes_on_in_another_process_gets_its_host () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Relaunches in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      started ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) ();
      await_file host_marker;
      check bool "the host was started for the port the second process opened" true (host_started base)))

let a_firefox_that_never_opens_its_port_starts_no_host () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Never_listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      let began = Unix.gettimeofday () in
      started ~ready_timeout_s:1. ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) ();
      let waited = Unix.gettimeofday () -. began in
      check bool "waited until the timeout, and no longer" true (waited >= 1. && waited < 10.);
      check bool "no host" false (host_started base)))

let nothing_is_started_without_the_table_or_with_the_lane_off () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      started ~base ~configuration:(configured ~live_enabled:false ~firefox ~port:(free_port ()) base) ();
      started ~base ~configuration:(Some Browser_configuration.none) ();
      started ~base ~configuration:None ();
      check bool "no Firefox" false (firefox_started base);
      check bool "no host" false (host_started base)))

let without_a_launcher_nothing_starts () =
  with_workspace (fun base ->
    let firefox_marker, _ = markers base in
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker ] (fun () ->
      started ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) ();
      check bool "no Firefox no host can use" false (firefox_started base);
      check bool "no host without a launcher" false (host_started base)))

(* Set for one case: the server's environment is what a child inherits.
   Each variable is put back as it was, or removed when it was not set. *)
let with_variables variables f =
  let before = List.map (fun (key, _) -> key, Sys.getenv_opt key) variables in
  List.iter (fun (key, value) -> Unix.putenv key value) variables;
  Fun.protect
    ~finally:(fun () ->
      List.iter (function key, Some value -> Unix.putenv key value | key, None -> Unix.unsetenv key) before)
    f

let the_host_is_not_given_the_servers_address () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      with_variables [ "MASC_HTTP_PORT", "8935"; "MASC_HTTP_BASE_URL", "https://masc.example" ] (fun () ->
        started ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) ());
      await_file (host_marker ^ ".env");
      check string "neither address variable" "unset unset" (String.trim (read (host_marker ^ ".env")))))

let each_start_keeps_the_last_runs_log () =
  with_workspace (fun base ->
    let firefox_marker, _ = markers base in
    let firefox = fake_firefox base ~marker:firefox_marker Exits in
    let configuration = configured ~firefox ~port:(free_port ()) base in
    let log = Keeper_firefox.firefox_log_path ~base_path:base in
    with_children ~base [ firefox_marker ] (fun () ->
      install_lane base ~marker:(Filename.concat base "host-ran");
      started ~base ~configuration ();
      Out_channel.with_open_gen [ Open_append ] 0o600 log (fun output -> output_string output "first run\n");
      started ~base ~configuration ();
      check string "the last run moved aside" "first run\n" (read (Keeper_firefox.previous_log_path log));
      check string "this run's log is new" "" (read log)))

let () =
  run "browser_keeper_firefox"
    [ ( "configuration"
      , [ test_case "both paths and the default port" `Quick table_with_both_paths_and_the_default_port
        ; test_case "a port beside the live lane turned off" `Quick table_with_a_port_and_the_live_lane_off
        ; test_case "no table" `Quick no_table_names_no_firefox
        ; test_case "a table that cannot start Firefox" `Quick a_table_that_cannot_start_firefox_is_refused ] )
    ; ( "what runs"
      , [ test_case "commands and logs" `Quick commands_run
        ; test_case "when a host is started" `Quick host_is_started_only_with_an_installed_launcher_and_no_host ] )
    ; ( "detached spawn"
      , [ test_case "exit status and output" `Quick spawn_reports_exit_and_writes_output
        ; test_case "outlives its switch in its own group" `Quick spawn_outlives_its_switch_in_its_own_group
        ; test_case "a missing executable" `Quick spawn_of_a_missing_executable_is_an_error ] )
    ; ( "server start"
      , [ test_case "a free port: Firefox, then the host" `Quick a_free_port_starts_firefox_then_the_host
        ; test_case "an answering port: the host only" `Quick an_answering_port_starts_only_the_host
        ; test_case "a running host and no Firefox" `Quick a_running_host_with_no_firefox_starts_nothing
        ; test_case "a host whose address cannot be read" `Quick a_host_whose_address_cannot_be_read_starts_nothing
        ; test_case "a Firefox that exits first" `Quick a_firefox_that_exits_first_starts_no_host
        ; test_case "a Firefox that goes on in another process" `Quick
            a_firefox_that_goes_on_in_another_process_gets_its_host
        ; test_case "a Firefox that never opens its port" `Quick a_firefox_that_never_opens_its_port_starts_no_host
        ; test_case "no table, or the lane off" `Quick nothing_is_started_without_the_table_or_with_the_lane_off
        ; test_case "a host on another port" `Quick a_host_on_another_port_starts_nothing
        ; test_case "the host's environment" `Quick the_host_is_not_given_the_servers_address
        ; test_case "the last run's log" `Quick each_start_keeps_the_last_runs_log
        ; test_case "no launcher" `Quick without_a_launcher_nothing_starts ] ) ]
