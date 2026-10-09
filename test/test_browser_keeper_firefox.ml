(* RFC-browser-keeper-firefox §3.1-§3.3: the [browser.live.bidi] table, what
   the server runs, the detached spawn, and starting only what is missing. *)
open Alcotest
module Keeper_firefox = Masc.Browser_keeper_firefox
module Record = Masc.Browser_bidi_host_record
module Status = Masc.Browser_bidi_host_status
module Firefox_record = Masc.Browser_keeper_firefox_record

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

(* The group a process is in, as ps reports it; and none for a process that
   is gone. *)
let the_group_of_a_process () =
  with_workspace (fun base ->
    let output = output_file (Filename.concat base "out") in
    let pid, gone =
      Eio_main.run (fun _env -> Eio.Switch.run (fun sw ->
        let spawned argv =
          match Posix_spawn_detached.spawn ~sw ~argv ~env:(Unix.environment ()) ~output with
          | Error detail -> fail detail
          | Ok child -> child in
        let gone = spawned [ "/bin/sh"; "-c"; "exit 0" ] in
        ignore (Eio.Promise.await gone.exited);
        (spawned [ "/bin/sleep"; "30" ]).pid, gone.pid)) in
    Unix.close output;
    Fun.protect ~finally:(fun () -> stop pid) (fun () ->
      check bool "a detached child leads its own group" true (Posix_spawn_detached.group_of_pid pid = Ok pid);
      check bool "this process's group" true
        (Posix_spawn_detached.group_of_pid (Unix.getpid ()) = Ok (process_group (Unix.getpid ())));
      check bool "a process that is gone" true (Result.is_error (Posix_spawn_detached.group_of_pid gone));
      (* Signal 0 tells whether the guard holds without signalling anyone. *)
      check bool "0 is no group: kill(2) reads it as this process's own" false
        (Posix_spawn_detached.group_id_has_members 0);
      check bool "1 is no group: kill(2) reads -1 as every process" false
        (Posix_spawn_detached.group_id_has_members 1)))

let spawn_of_a_missing_executable_is_an_error () =
  Eio_main.run (fun _env -> Eio.Switch.run (fun sw ->
    match Posix_spawn_detached.spawn ~sw ~argv:[ "/nonexistent/firefox" ] ~env:[||] ~output:Unix.stdout with
    | Ok child -> stop child.pid; fail "started"
    | Error detail ->
      check bool detail true (String_util.contains_substring detail "/nonexistent/firefox")))

let await_file path =
  let deadline = Unix.gettimeofday () +. 10. in
  let rec wait () =
    if Sys.file_exists path && String.trim (read path) <> "" then ()
    else if Unix.gettimeofday () > deadline then fail (path ^ " was not written")
    else (Unix.sleepf 0.05; wait ()) in
  wait ()

(* A group that ends on SIGTERM is not sent SIGKILL; one that keeps SIGTERM
   ignored (an ignored disposition survives exec(2)) gets it after the
   grace. Each child says when it is set up, so the signal does not reach a
   shell that has not yet run its trap. *)
let stop_group_escalates_only_past_the_grace () =
  with_workspace (fun base ->
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      let output = Unix.openfile "/dev/null" [ Unix.O_WRONLY; Unix.O_CLOEXEC ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close output)
        (fun () ->
          let spawned name setup =
            let ready = Filename.concat base name in
            let script = Printf.sprintf "%s echo up > %s; exec %s" setup (Filename.quote ready) (sleeper_command ready) in
            match Posix_spawn_detached.spawn ~sw ~argv:[ "/bin/sh"; "-c"; script ] ~env:(Unix.environment ()) ~output with
            | Error detail -> fail detail
            | Ok child -> await_file ready; child
          in
          let ends = spawned "ends-on-term" "" in
          check bool "ends on SIGTERM" true
            (Posix_spawn_detached.stop_group ~clock ~grace_s:5. ends = Posix_spawn_detached.Ended_on_term);
          let stays = spawned "ignores-term" "trap '' TERM;" in
          check bool "killed past the grace" true
            (Posix_spawn_detached.stop_group ~clock ~grace_s:0.5 stays = Posix_spawn_detached.Killed_after_grace);
          check bool "and its group is emptied by the time the stop returns" false
            (Posix_spawn_detached.group_has_members stays)))))

(* --- the record of the Firefox MASC started ---------------------------------- *)

let entry ?(leader = Firefox_record.Started_at "proc:boot:100") ?(group = 4242) () =
  { Firefox_record.group; leader; profile = "/keeper/profile"; port = 9222; started_at = 1_791_000_000. }

let leaders = [ Firefox_record.Started_at "proc:boot:100"; Start_unreadable ]

let a_record_reads_back_as_written () =
  List.iter
    (fun leader ->
      let written = entry ~leader () in
      match Firefox_record.entry_of_json (Firefox_record.entry_to_json written) with
      | Ok read -> check bool "the same entry" true (read = written)
      | Error detail -> fail detail)
    leaders

let a_record_from_another_writer_is_not_read () =
  let replaced name value =
    match Firefox_record.entry_to_json (entry ()) with
    | `Assoc fields -> `Assoc ((name, value) :: List.remove_assoc name fields)
    | _ -> fail "an object" in
  List.iter
    (fun (what, json) ->
      match Firefox_record.entry_of_json json with
      | Ok _ -> fail (what ^ " was read")
      | Error _ -> ())
    [ "another layout", replaced "schema" (`Int 2)
    ; "a field this layout has not", replaced "pid" (`Int 1)
    ; "a leader this reader does not know", replaced "leader" (`Assoc [ "kind", `String "guessed" ])
    ; ( "a leader with a field its kind has not"
      , replaced "leader" (`Assoc [ "kind", `String "start_unreadable"; "started", `String "proc:boot:1" ]) )
    ; "a group that is no process", replaced "group" (`Int 0)
    ; "the group kill(2) reads as every process", replaced "group" (`Int 1)
    ; "a group past pid_t", replaced "group" (`Int (Int32.to_int Int32.max_int + 1))
    ; "a port that is no port", replaced "port" (`String "9222") ]

let recorded base =
  match Firefox_record.read ~base_path:base with
  | Firefox_record.Recorded entry -> Some entry
  | Firefox_record.Absent -> None
  | Firefox_record.Unreadable detail -> fail detail

let a_record_that_is_not_there_or_not_json () =
  with_workspace (fun base ->
    check bool "not there" true (recorded base = None);
    List.iter (fun dir -> Unix.mkdir dir 0o700) [ Filename.concat base ".masc"; lane base ];
    write (Firefox_record.record_path ~base_path:base) "{";
    match Firefox_record.read ~base_path:base with
    | Firefox_record.Unreadable _ -> ()
    | Firefox_record.Recorded _ | Firefox_record.Absent -> fail "read as a record")

(* The lane directory is a file, so nothing can be written under it. *)
let a_record_that_cannot_be_written_says_so () =
  with_workspace (fun base ->
    Unix.mkdir (Filename.concat base ".masc") 0o700;
    write (lane base) "";
    match Firefox_record.write ~base_path:base (entry ()) with
    | Error (Firefox_record.Not_written _) -> ()
    | Error (Firefox_record.Not_synced detail) -> fail ("written: " ^ detail)
    | Ok () -> fail "written")

(* A group is the Firefox started there only while the process it is
   numbered after runs, with the recorded start, in it. *)
let a_recorded_group_is_ours_only_when_shown () =
  let recorded_start = "proc:boot:100" in
  let found ?(leader = Firefox_record.Started_at recorded_start) ~started ~group ~members () =
    Keeper_firefox.recorded_firefox (entry ~leader ()) ~leader_started:started ~leader_group:group
      ~group_has_members:members in
  let unproven = function
    | Keeper_firefox.Unproven _ -> true
    | Keeper_firefox.Started_here | Keeper_firefox.Gone -> false in
  check bool "its process, started then, in its group" true
    (found ~started:(Some recorded_start) ~group:(Ok 4242) ~members:true () = Keeper_firefox.Started_here);
  (* No process is given the number of a group that still exists, so the
     recorded group has ended, whatever group that number names now. *)
  check bool "another process with its number" true
    (found ~started:(Some "proc:boot:200") ~group:(Ok 4242) ~members:true () = Keeper_firefox.Gone);
  check bool "another process with its number, and its group empty" true
    (found ~started:(Some "proc:boot:200") ~group:(Ok 4242) ~members:false () = Keeper_firefox.Gone);
  check bool "its process, in another group" true
    (unproven (found ~started:(Some recorded_start) ~group:(Ok 4343) ~members:true ()));
  check bool "its process, in a group that cannot be told" true
    (unproven (found ~started:(Some recorded_start) ~group:(Error "No such process") ~members:true ()));
  check bool "its process gone, its group not" true
    (unproven (found ~started:None ~group:(Error "No such process") ~members:true ()));
  check bool "its process and its group gone" true
    (found ~started:None ~group:(Error "No such process") ~members:false () = Keeper_firefox.Gone);
  List.iter
    (fun leader ->
      check bool "a group nothing names is left running" true
        (unproven (found ~leader ~started:(Some recorded_start) ~group:(Ok 4242) ~members:true ()));
      check bool "and forgotten once it is empty" true
        (found ~leader ~started:None ~group:(Error "No such process") ~members:false () = Keeper_firefox.Gone))
    [ Firefox_record.Start_unreadable ]

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

let first_pid path =
  if Sys.file_exists path && String.trim (read path) <> "" then Some (int_of_string (List.hd (lines path)))
  else None

let started ?ending_host_wait_s ?(ready_timeout_s = Keeper_firefox.firefox_ready_timeout_s) ~base ~configuration () =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    match
      Eio.Promise.await
        (Server_browser_keeper_firefox.For_testing.start ?ending_host_wait_s ~ready_timeout_s ~sw ~env
           ~base_path:base ~configuration ())
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

(* No process with the pid [marker] names runs a command under [base]: it
   ended, and the system may have given its pid to another process since.
   A marker never written is a process stopped before it wrote it; one left
   running writes it. *)
let not_running ~base marker =
  match first_pid marker with
  | None -> true
  | Some pid -> not (String_util.contains_substring (command_line pid) base)

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
               ~configuration:(configured ~firefox ~port base) ())
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
      check bool "no host for a Firefox that is not there" false (host_started base);
      check bool "not recorded" true (recorded base = None)))

let a_firefox_that_goes_on_in_another_process_gets_its_host () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Relaunches in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      started ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) ();
      await_file host_marker;
      check bool "the host was started for the port the second process opened" true (host_started base);
      check bool "the group is recorded" true
        (Option.map (fun (entry : Firefox_record.entry) -> entry.group) (recorded base) = first_pid firefox_marker);
      (* Its first process is gone, so nothing tells the process left in its
         group from one in a later group with that number. *)
      started ~base ~configuration:(Some Browser_configuration.none) ();
      check bool "left running once no longer asked for" false (not_running ~base (firefox_marker ^ ".listener"));
      check bool "and still recorded" true (recorded base <> None)))

let a_firefox_that_never_opens_its_port_starts_no_host () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Never_listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      let began = Unix.gettimeofday () in
      started ~ready_timeout_s:1. ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) ();
      let waited = Unix.gettimeofday () -. began in
      check bool "waited until the timeout, and no longer" true (waited >= 1. && waited < 15.);
      check bool "no host" false (host_started base);
      check bool "the Firefox started for it is stopped" true (not_running ~base firefox_marker);
      check bool "and not recorded" true (recorded base = None)))

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

let a_host_that_cannot_start_stops_its_firefox () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    (* Its content is still what the installation declared; it cannot run. *)
    Unix.chmod (launcher base) 0o600;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      started ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) ();
      check bool "firefox was started" true (firefox_started base);
      check bool "the host never ran" false (Sys.file_exists host_marker);
      check bool "and the Firefox started for it is stopped" true (not_running ~base firefox_marker);
      check bool "and no longer recorded" true (recorded base = None)))

(* A host that leaves in order writes its ending, then gives the lock up. *)
let ended_holding_the_lock base ~port =
  let held = take ~port base in
  (match Record.ended held ~reason:"stopped by SIGTERM" ~session:Record.No_session_left ~now:1_791_000_060. with
   | Ok () -> ()
   | Error failure -> fail (Record.write_failure_message failure));
  held

let a_host_that_is_ending_is_waited_for () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    let port = free_port () in
    let held = ended_holding_the_lock base ~port in
    let given_up_at = ref Float.infinity in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
        Eio.Fiber.fork ~sw (fun () ->
          Eio.Time.sleep (Eio.Stdenv.clock env) 0.5;
          released held;
          given_up_at := Unix.gettimeofday ());
        match
          Eio.Promise.await
            (Server_browser_keeper_firefox.For_testing.start
               ~ready_timeout_s:Keeper_firefox.firefox_ready_timeout_s ~sw ~env ~base_path:base
               ~configuration:(configured ~firefox ~port base) ())
        with
        | Ok () -> ()
        | Error exn -> raise exn));
      await_file host_marker;
      (* The launcher writes its marker as it starts. *)
      check bool "the host started once the lock was given up" true
        ((Unix.stat host_marker).Unix.st_mtime >= !given_up_at)))

let a_lock_that_is_not_given_up_starts_nothing () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    let port = free_port () in
    let held = ended_holding_the_lock base ~port in
    Fun.protect ~finally:(fun () -> released held) (fun () ->
      with_children ~base [ firefox_marker; host_marker ] (fun () ->
        started ~ending_host_wait_s:0.5 ~base ~configuration:(configured ~firefox ~port base) ();
        check bool "no Firefox" false (firefox_started base);
        check bool "no host" false (host_started base))))

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

let a_started_firefox_is_recorded () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let port = free_port () in
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      started ~base ~configuration:(configured ~firefox ~port base) ();
      match first_pid firefox_marker, recorded base with
      | None, _ -> fail "firefox did not run"
      | Some _, None -> fail "not recorded"
      | Some pid, Some entry ->
        check int "the group it leads" pid entry.group;
        check int "its port" port entry.port;
        check string "its profile" (Filename.concat base "profile") entry.profile;
        check bool "when it started" true
          (Option.map (fun started -> Firefox_record.Started_at started) (Server_startup_takeover.process_started pid)
           = Some entry.leader)))

(* A server that ends while it waits for the port leaves that Firefox
   named. *)
let the_record_is_written_before_the_port_answers () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Never_listens in
    let during_the_wait = ref None in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
        Eio.Fiber.fork ~sw (fun () ->
          Eio.Time.sleep (Eio.Stdenv.clock env) 1.;
          during_the_wait := recorded base);
        match
          Eio.Promise.await
            (Server_browser_keeper_firefox.For_testing.start ~ready_timeout_s:2. ~sw ~env ~base_path:base
               ~configuration:(configured ~firefox ~port:(free_port ()) base) ())
        with
        | Ok () -> ()
        | Error exn -> raise exn));
      check bool "recorded while the port was awaited" true
        (Option.map (fun (entry : Firefox_record.entry) -> entry.group) !during_the_wait
         = first_pid firefox_marker)))

(* --- a workspace that no longer asks for a Keeper Firefox ------------------- *)

let no_longer_asked =
  [ "the lane off", (fun ~firefox ~port base -> configured ~live_enabled:false ~firefox ~port base)
  ; "no table", (fun ~firefox:_ ~port:_ _ -> Some Browser_configuration.none) ]

let the_firefox_masc_started_is_stopped_when_no_longer_asked () =
  List.iter
    (fun (what, asked) ->
      with_workspace (fun base ->
        let firefox_marker, host_marker = markers base in
        install_lane base ~marker:host_marker;
        let port = free_port () in
        let firefox = fake_firefox base ~marker:firefox_marker Listens in
        with_children ~base [ firefox_marker; host_marker ] (fun () ->
          started ~base ~configuration:(configured ~firefox ~port base) ();
          await_file host_marker;
          started ~base ~configuration:None ();
          check bool "no configuration loaded: left running" false (not_running ~base firefox_marker);
          started ~base ~configuration:(asked ~firefox ~port base) ();
          check bool (what ^ ": stopped") true (not_running ~base firefox_marker);
          check bool (what ^ ": no longer recorded") true (recorded base = None))))
    no_longer_asked

(* A process in a group of its own, as the Keeper Firefox is, that this
   process does not wait for. *)
let detached_sleeper base name =
  let marker = Filename.concat base name in
  let output = Unix.openfile "/dev/null" [ Unix.O_WRONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close output) (fun () ->
    Eio_main.run (fun _env -> Eio.Switch.run (fun sw ->
      match
        Posix_spawn_detached.spawn ~sw ~argv:[ "/bin/sh"; "-c"; "exec " ^ sleeper_command marker ]
          ~env:(Unix.environment ()) ~output
      with
      | Error detail -> fail detail
      | Ok child -> child.pid)))

let write_record base entry =
  match Firefox_record.write ~base_path:base entry with
  | Ok () -> ()
  | Error failure -> fail (Firefox_record.write_failure_message failure)

let runs_under base pid = String_util.contains_substring (command_line pid) base

let another_process_under_the_number_is_not_stopped () =
  with_workspace (fun base ->
    let pid = detached_sleeper base "other" in
    Fun.protect ~finally:(fun () -> stop pid) (fun () ->
      write_record base (entry ~group:pid ~leader:(Firefox_record.Started_at "proc:another:1") ());
      started ~base ~configuration:(Some Browser_configuration.none) ();
      check bool "the other process runs on" true (runs_under base pid);
      check bool "the record of a group that ended is forgotten" true (recorded base = None)))

let a_group_not_shown_to_be_ours_is_not_stopped () =
  with_workspace (fun base ->
    let pid = detached_sleeper base "other" in
    Fun.protect ~finally:(fun () -> stop pid) (fun () ->
      write_record base (entry ~group:pid ~leader:Firefox_record.Start_unreadable ());
      started ~base ~configuration:(Some Browser_configuration.none) ();
      (* Not [alive]: nothing reaps this process, so one that was stopped
         stays a zombie, and a zombie takes signal 0. *)
      check bool "the other process runs on" true
        (String_util.contains_substring (command_line pid) base);
      check bool "the record is kept" true (recorded base <> None)))

let a_record_that_names_nothing_is_forgotten () =
  with_workspace (fun base ->
    let pid =
      Eio_main.run (fun _env -> Eio.Switch.run (fun sw ->
        match Posix_spawn_detached.spawn ~sw ~argv:[ "/bin/sh"; "-c"; "exit 0" ] ~env:[||] ~output:Unix.stdout with
        | Error detail -> fail detail
        | Ok child -> ignore (Eio.Promise.await child.exited); child.pid)) in
    write_record base (entry ~group:pid ());
    started ~base ~configuration:(Some Browser_configuration.none) ();
    check bool "forgotten" true (recorded base = None))

(* Either the earlier one is shown to be the Firefox MASC started, or what
   is left in its group cannot be told from it. *)
let firefox_is_not_started_over_a_record_that_may_still_run () =
  List.iter
    (fun (what, leader_of) ->
      with_workspace (fun base ->
        let firefox_marker, host_marker = markers base in
        install_lane base ~marker:host_marker;
        let firefox = fake_firefox base ~marker:firefox_marker Listens in
        let port = free_port () in
        let earlier = detached_sleeper base "earlier" in
        Fun.protect ~finally:(fun () -> stop earlier) (fun () ->
          with_children ~base [ firefox_marker; host_marker ] (fun () ->
            write_record base { (entry ~group:earlier ~leader:(leader_of earlier) ()) with port };
            started ~base ~configuration:(configured ~firefox ~port base) ();
            check bool (what ^ ": no second Firefox") false (firefox_started base);
            check bool (what ^ ": no host") false (host_started base);
            check bool (what ^ ": the earlier one runs on, still recorded") true
              (runs_under base earlier
               && Option.map (fun (entry : Firefox_record.entry) -> entry.group) (recorded base)
                  = Some earlier)))))
    [ ( "shown to be ours"
      , fun pid ->
          match Server_startup_takeover.process_started pid with
          | Some started -> Firefox_record.Started_at started
          | None -> fail "when the earlier one started cannot be read" )
    ; "not told apart", fun _ -> Firefox_record.Start_unreadable ]

let firefox_is_not_started_over_a_record_that_cannot_be_read () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    write (Firefox_record.record_path ~base_path:base) "{";
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      started ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) ();
      check bool "no Firefox" false (firefox_started base);
      check string "the record is left as it was" "{" (read (Firefox_record.record_path ~base_path:base))))

let a_record_of_a_firefox_that_ended_is_replaced () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    write_record base (entry ~group:(Int32.to_int Int32.max_int) ());
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      started ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) ();
      check bool "the new one is recorded" true
        (Option.map (fun (entry : Firefox_record.entry) -> entry.group) (recorded base) = first_pid firefox_marker)))

let a_record_that_cannot_be_read_is_kept () =
  with_workspace (fun base ->
    List.iter (fun dir -> Unix.mkdir dir 0o700) [ Filename.concat base ".masc"; lane base ];
    let path = Firefox_record.record_path ~base_path:base in
    write path "{";
    started ~base ~configuration:(Some Browser_configuration.none) ();
    check string "left as it was" "{" (read path))

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
        ; test_case "a missing executable" `Quick spawn_of_a_missing_executable_is_an_error
        ; test_case "the group of a process" `Quick the_group_of_a_process
        ; test_case "a stop escalates only past the grace" `Quick stop_group_escalates_only_past_the_grace ] )
    ; ( "the record"
      , [ test_case "read back as written" `Quick a_record_reads_back_as_written
        ; test_case "another writer's record" `Quick a_record_from_another_writer_is_not_read
        ; test_case "not there, or not JSON" `Quick a_record_that_is_not_there_or_not_json
        ; test_case "a record that cannot be written" `Quick a_record_that_cannot_be_written_says_so
        ; test_case "a group is ours only when shown" `Quick a_recorded_group_is_ours_only_when_shown ] )
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
        ; test_case "a host that cannot start" `Quick a_host_that_cannot_start_stops_its_firefox
        ; test_case "a host that is ending" `Quick a_host_that_is_ending_is_waited_for
        ; test_case "a lock that is not given up" `Quick a_lock_that_is_not_given_up_starts_nothing
        ; test_case "no launcher" `Quick without_a_launcher_nothing_starts
        ; test_case "a started Firefox is recorded" `Quick a_started_firefox_is_recorded
        ; test_case "recorded before its port answers" `Quick the_record_is_written_before_the_port_answers
        ; test_case "not over a record that may still run" `Quick firefox_is_not_started_over_a_record_that_may_still_run
        ; test_case "not over a record that cannot be read" `Quick
            firefox_is_not_started_over_a_record_that_cannot_be_read
        ; test_case "over the record of one that ended" `Quick a_record_of_a_firefox_that_ended_is_replaced ] )
    ; ( "no longer asked for"
      , [ test_case "the Firefox MASC started is stopped" `Quick
            the_firefox_masc_started_is_stopped_when_no_longer_asked
        ; test_case "a group not shown to be ours" `Quick a_group_not_shown_to_be_ours_is_not_stopped
        ; test_case "another process under the number" `Quick another_process_under_the_number_is_not_stopped
        ; test_case "a record that names nothing" `Quick a_record_that_names_nothing_is_forgotten
        ; test_case "a record that cannot be read" `Quick a_record_that_cannot_be_read_is_kept ] ) ]
