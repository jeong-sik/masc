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
(* The pid a host record written for a launcher names, which that launcher
   replaces with its own as it writes it. *)
let ending_pid_mark = 424_242_424

(* [ending]: the launcher writes this host record under its own pid, as a
   host that ended does, then exits. *)
let install_lane ?(declared = true) ?(host_ends = false) ?ending base ~marker =
  List.iter (fun dir -> Unix.mkdir dir 0o700)
    [ Filename.concat base ".masc"; lane base; Filename.concat (lane base) "host" ];
  let tail =
    match ending, host_ends with
    | Some record, (true | false) ->
      let template = Filename.concat base "host-ending.json" in
      write template (Yojson.Safe.to_string record);
      Printf.sprintf "sed \"s/%d/$$/\" %s > %s\nexit 3" ending_pid_mark (Filename.quote template)
        (Filename.quote (Filename.concat (lane base) "bidi-host.json"))
    | None, true -> "exit 3"
    | None, false -> "exec " ^ sleeper_command marker in
  let script =
    Printf.sprintf
      "#!/bin/sh\nprintf '%%s\\n' \"${MASC_HTTP_PORT-unset} ${MASC_HTTP_BASE_URL-unset}\" > %s.env\n\
       printf '%%s\\n' \"$$\" \"$@\" > %s\n%s\n"
      (Filename.quote marker) (Filename.quote marker) tail in
  write ~mode:0o700 (launcher base) script;
  if declared then
    write (Filename.concat (lane base) "host/launch.json")
      (Yojson.Safe.to_string
         (`Assoc [ "destination", `String "workspace_connection";
                   "launcher_sha256", `String Digestif.SHA256.(to_hex (digest_string script)) ]))

let host_step ?(port = 9333) base = Keeper_firefox.host_step ~port (Status.report (Status.observe ~base_path:base ~configuration:None))

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

(* A child's start is read before anything here could reap it: one that
   exits at once has it too, and no later process shares it. *)
let the_start_of_a_child () =
  with_workspace (fun base ->
    let output = output_file (Filename.concat base "out") in
    let quick, sleeping =
      Eio_main.run (fun _env -> Eio.Switch.run (fun sw ->
        let spawned argv =
          match Posix_spawn_detached.spawn ~sw ~argv ~env:(Unix.environment ()) ~output with
          | Error detail -> fail detail
          | Ok child -> child in
        let quick = spawned [ "/bin/sh"; "-c"; "exit 0" ] in
        ignore (Eio.Promise.await quick.exited);
        quick, spawned [ "/bin/sleep"; "30" ])) in
    Unix.close output;
    Fun.protect ~finally:(fun () -> stop sleeping.pid) (fun () ->
      check bool "a child that exited at once has its start" true (Option.is_some quick.started);
      check bool "and once reaped, its number reads none" true
        (Posix_spawn_detached.process_start quick.pid = None);
      check bool "a running child reads the start it was given" true
        (Option.is_some sleeping.started && Posix_spawn_detached.process_start sleeping.pid = sleeping.started);
      check bool "another process reads another" true
        (Posix_spawn_detached.process_start (Unix.getpid ()) <> sleeping.started)))

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
          let same_group () = true in
          let ends = spawned "ends-on-term" "" in
          check bool "ends on SIGTERM" true
            (Posix_spawn_detached.stop_group ~clock ~grace_s:5. ~same_group ends.pid
             = Posix_spawn_detached.Ended_on_term);
          let stays = spawned "ignores-term" "trap '' TERM;" in
          check bool "killed past the grace" true
            (Posix_spawn_detached.stop_group ~clock ~grace_s:0.5 ~same_group stays.pid
             = Posix_spawn_detached.Killed_after_grace);
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

(* A number that no longer names the group meant is not signalled: neither
   at the start, nor when SIGKILL would be due. *)
let a_stop_leaves_a_group_its_number_no_longer_names () =
  with_workspace (fun base ->
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      let output = Unix.openfile "/dev/null" [ Unix.O_WRONLY; Unix.O_CLOEXEC ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close output)
        (fun () ->
          let ready = Filename.concat base "ignores-term" in
          let script = Printf.sprintf "trap '' TERM; echo up > %s; exec %s" (Filename.quote ready) (sleeper_command ready) in
          match Posix_spawn_detached.spawn ~sw ~argv:[ "/bin/sh"; "-c"; script ] ~env:(Unix.environment ()) ~output with
          | Error detail -> fail detail
          | Ok child ->
            await_file ready;
            Fun.protect ~finally:(fun () -> stop child.pid) (fun () ->
              check bool "named another from the start: nothing sent" true
                (Posix_spawn_detached.stop_group ~clock ~grace_s:0.5 ~same_group:(fun () -> false) child.pid
                 = Posix_spawn_detached.Left_alone);
              let asked = ref 0 in
              let first_time_only () = incr asked; !asked = 1 in
              check bool "named another once SIGKILL was due: not sent" true
                (Posix_spawn_detached.stop_group ~clock ~grace_s:0.5 ~same_group:first_time_only child.pid
                 = Posix_spawn_detached.Left_alone);
              check bool "so the group runs on" true (Posix_spawn_detached.group_has_members child))))))

(* A group of another account's processes is there, though this process may
   not signal it: kill(2) answers EPERM. *)
let a_group_this_account_cannot_signal_is_there () =
  if Unix.getuid () = 0 then ()
  else
    let ps = Unix.open_process_args_in "/bin/ps" [| "ps"; "-axo"; "pgid=,uid=" |] in
    let rows = In_channel.input_lines ps in
    ignore (Unix.close_process_in ps);
    let others =
      List.filter_map
        (fun row ->
          match List.filter (fun field -> field <> "") (String.split_on_char ' ' row) with
          | [ pgid; uid ] ->
            (match int_of_string_opt pgid, int_of_string_opt uid with
             | Some pgid, Some uid when pgid > 1 && uid <> Unix.getuid () -> Some pgid
             | (Some _ | None), (Some _ | None) -> None)
          | [] | [ _ ] | _ :: _ :: _ :: _ -> None)
        rows in
    let refused pgid =
      match Unix.kill (-pgid) 0 with
      | () -> false
      | exception Unix.Unix_error (Unix.EPERM, _, _) -> true
      | exception Unix.Unix_error (_, _, _) -> false in
    match List.find_opt refused others with
    | None -> ()
    | Some pgid -> check bool (Printf.sprintf "group %d" pgid) true (Posix_spawn_detached.group_id_has_members pgid)

(* --- what the server starts ------------------------------------------------ *)

let free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close socket) (fun () ->
    Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
    match Unix.getsockname socket with Unix.ADDR_INET (_, port) -> port | Unix.ADDR_UNIX _ -> fail "port")

(* Opens [port] for thirty seconds and writes its own pid to [pidfile], so a
   case can stop it. It takes and closes each connection, as Firefox answers
   one, so checks of the port never fill its backlog. [own_group]: first it
   leaves the process group it was started in. *)
let listener ~own_group =
  Printf.sprintf
    "python3 -c 'import os,select,socket,sys,time\n\
     %sopen(sys.argv[2], \"w\").write(str(os.getpid()))\n\
     s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n\
     s.bind((\"127.0.0.1\", int(sys.argv[1]))); s.listen(4); end=time.time()+30\n\
     while time.time() < end: r=select.select([s],[],[],1)[0]; r and s.accept()[0].close()'"
    (if own_group then "os.setpgid(0, 0)\n" else "")

let listener_command = listener ~own_group:false

type fake = Listens | Listens_apart | Exits | Relaunches | Never_listens

(* A Firefox that records its pid and what it was given, then behaves as
   [fake] says: [Exits] at once, as Firefox does on a profile another
   Firefox holds; [Relaunches], leaving a process in its group that opens
   the port half a second later, as a Firefox applying an update does;
   [Listens_apart], running on while a process it started holds the port
   from a group of its own, which a stop of its group does not reach. *)
let fake_firefox base ~marker fake =
  let path = Filename.concat base "firefox" in
  let pidfile = Filename.quote (marker ^ ".listener") in
  let tail = match fake with
    | Listens -> Printf.sprintf "exec %s \"$port\" %s\n" listener_command pidfile
    | Listens_apart ->
      Printf.sprintf "%s \"$port\" %s &\nexec %s\n" (listener ~own_group:true) pidfile (sleeper_command marker)
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
  (match Record.ended held ~because:Record.Reason_only ~reason:"stopped by SIGTERM" ~session:Record.No_session_left ~now:1_791_000_060. with
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
        check bool "written at the wall clock's time" true (Float.abs (entry.started_at -. Unix.gettimeofday ()) < 600.);
        check bool "when it started" true
          (Option.map (fun started -> Firefox_record.Started_at started) (Posix_spawn_detached.process_start pid)
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
          match Posix_spawn_detached.process_start pid with
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

(* --- a Keeper's request ----------------------------------------------------- *)

module Starter = Masc.Browser_keeper_firefox_starter

let bidi_client n : Browser_lane.client_info =
  match Browser_lane.client_id_of_string (Printf.sprintf "70000000-0000-4000-8000-%012d" n) with
  | Ok client_id ->
    { client_id; browser = Browser_lane.Firefox; version = "fixture"; engine_version = "fixture"
    ; transport = Browser_lane.Webdriver_bidi }
  | Error detail -> fail detail

(* Lists [client] as a host's first poll does, until the switch ends. *)
let attach ~sw (client : Browser_lane.client_info) =
  ignore (Browser_lane.take_command ~client_info:client ~window_sec:0.001);
  Eio.Switch.on_release sw (fun () -> ignore (Browser_lane.disconnect_client ~client_id:client.client_id))

(* [await_file] without holding up the fibers that serve the start. *)
let await_file_in_eio ~clock path =
  let deadline = Unix.gettimeofday () +. 10. in
  let rec wait () =
    if Sys.file_exists path && String.trim (read path) <> "" then ()
    else if Unix.gettimeofday () > deadline then fail (path ^ " was not written")
    else (Eio.Time.sleep clock 0.05; wait ()) in
  wait ()

let requested ?(host_attach_wait_s = 10.) ?(boot = false) ~base ~configuration f =
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let request =
        Server_browser_keeper_firefox.For_testing.serve ~boot ~ready_timeout_s:Keeper_firefox.firefox_ready_timeout_s
          ~host_attach_wait_s ~sw ~env ~base_path:base ~configuration:(fun () -> configuration) () in
      f ~sw ~clock:(Eio.Stdenv.clock env) request))

let attached_id = function
  | Starter.Attached { client; _ } -> Some (Browser_lane.client_id_to_string client.client_id)
  | Starter.Not_attached _ | Starter.Not_asked_for -> None

let what_started = function
  | Starter.Attached { started = Starter.Firefox_and_host; _ } -> "firefox and host"
  | Starter.Attached { started = Starter.Host_only; _ } -> "host only"
  | Starter.Attached { started = Starter.Nothing; _ } -> "nothing"
  | Starter.Not_attached _ | Starter.Not_asked_for -> "no connection"

let started_again path = Sys.file_exists (Keeper_firefox.previous_log_path path)

let id_of (client : Browser_lane.client_info) = Browser_lane.client_id_to_string client.client_id

(* The host attaches once it runs: here, as its launcher writes its marker. *)
let a_request_starts_both_and_waits_for_the_connection () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      requested ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) (fun ~sw ~clock request ->
        let client = bidi_client 1 in
        Eio.Fiber.fork ~sw (fun () -> await_file_in_eio ~clock host_marker; attach ~sw client);
        let answer = request () in
        check (option string) "the connection the start showed" (Some (id_of client)) (attached_id answer);
        check string "said to have started both" "firefox and host" (what_started answer));
      check bool "Firefox and its host were started" true (firefox_started base && host_started base)))

(* Firefox opens a profile once, so a second start would only fail; and a
   request that comes during a start waits for that one. *)
let requests_at_once_share_one_start () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      requested ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) (fun ~sw ~clock request ->
        let client = bidi_client 2 in
        Eio.Fiber.fork ~sw (fun () -> await_file_in_eio ~clock host_marker; attach ~sw client);
        let first, second = Eio.Fiber.pair request request in
        check (list (option string)) "both see the connection" [ Some (id_of client); Some (id_of client) ]
          [ attached_id first; attached_id second ]);
      check bool "one Firefox" false (started_again (Keeper_firefox.firefox_log_path ~base_path:base));
      check bool "one host" false (started_again (Keeper_firefox.host_log_path ~base_path:base))))

let a_listed_connection_starts_nothing () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      requested ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) (fun ~sw ~clock:_ request ->
        let client = bidi_client 3 in
        attach ~sw client;
        let answer = request () in
        check (option string) "that connection" (Some (id_of client)) (attached_id answer);
        check string "said to have started nothing" "nothing" (what_started answer));
      check bool "nothing started" false (firefox_started base || host_started base)))

let a_request_where_none_is_asked_for_starts_nothing () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      List.iter
        (fun (what, configuration) ->
          requested ~base ~configuration (fun ~sw:_ ~clock:_ request ->
            check bool what true (request () = Starter.Not_asked_for)))
        [ "no table", Some Browser_configuration.none
        ; "the lane off", configured ~live_enabled:false ~firefox ~port:(free_port ()) base
        ; "no configuration loaded", None ];
      check bool "nothing started" false (firefox_started base || host_started base)))

let a_request_hears_why_nothing_started () =
  with_workspace (fun base ->
    let firefox_marker, _ = markers base in
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker ] (fun () ->
      requested ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) (fun ~sw:_ ~clock:_ request ->
        match request () with
        | Starter.Not_attached (Starter.Operator_needed why) ->
          check bool ("the operator's step is named: " ^ why) true (String_util.contains_substring why "neither")
        | Starter.Not_attached (Starter.Start_failed _ | Starter.Not_listed_in_time _)
        | Starter.Attached _ | Starter.Not_asked_for -> fail "a start without a launcher is the operator's")))

let a_connection_that_never_shows_is_reported () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      requested ~host_attach_wait_s:0.5 ~base ~configuration:(configured ~firefox ~port:(free_port ()) base)
        (fun ~sw:_ ~clock:_ request ->
          match request () with
          | Starter.Not_attached (Starter.Not_listed_in_time why) ->
            check bool ("the host's log is named: " ^ why) true (String_util.contains_substring why "bidi-host.log")
          | Starter.Not_attached (Starter.Operator_needed _ | Starter.Start_failed _)
          | Starter.Attached _ | Starter.Not_asked_for -> fail "a connection that never polled")))

(* A host that ends before its connection is listed leaves the Firefox
   started for it with an open port and no host: that Firefox is stopped,
   and the answer says a retry starts again. *)
let a_host_that_ends_at_once_stops_its_firefox () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane ~host_ends:true base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      requested ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) (fun ~sw:_ ~clock:_ request ->
        match request () with
        | Starter.Not_attached (Starter.Start_failed why) ->
          check bool ("the host's end is named: " ^ why) true (String_util.contains_substring why "ended before")
        | Starter.Not_attached (Starter.Operator_needed _ | Starter.Not_listed_in_time _)
        | Starter.Attached _ | Starter.Not_asked_for -> fail "a host that ended is a failed start");
      check bool "the host ran" true (Sys.file_exists host_marker);
      check bool "the Firefox started for it is stopped" true (not_running ~base firefox_marker);
      check bool "and not recorded" true (recorded base = None)))

(* A host record that ended on another profile, for the Firefox on [port]. *)
let ended_on_another_profile ~port =
  match Browser_lane.client_id_of_string "0199c0de-0000-7000-8000-000000000001" with
  | Error detail -> fail detail
  | Ok client_id ->
    Record.entry_to_json
      { pid = ending_pid_mark; started_at = 1_791_000_000.; bidi_url = Printf.sprintf "ws://127.0.0.1:%d/session" port
      ; client_id; attached_at = None; unacknowledged = []
      ; ended =
          Some
            { at = 1_791_000_060.; reason = "this Firefox runs the profile /everyday, not /keeper/profile"
            ; session = Record.No_session_left
            ; because = Record.Profile_not_kept { expected = "/keeper/profile"; found = Some "/everyday" } } }

(* The Firefox on the port runs another profile, so every retry meets it
   again until the operator quits it. *)
let a_host_that_met_another_profile_is_the_operators () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    let port = free_port () in
    install_lane ~ending:(ended_on_another_profile ~port) base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      requested ~base ~configuration:(configured ~firefox ~port base) (fun ~sw:_ ~clock:_ request ->
        match request () with
        | Starter.Not_attached (Starter.Operator_needed why) ->
          check bool ("names the profile there: " ^ why) true (String_util.contains_substring why "/everyday")
        | Starter.Not_attached (Starter.Start_failed _ | Starter.Not_listed_in_time _)
        | Starter.Attached _ | Starter.Not_asked_for -> fail "another profile's Firefox is the operator's to quit")))

(* An earlier host's ending is not the reason the one just started ended. *)
let an_earlier_hosts_profile_is_not_this_ones () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    let port = free_port () in
    install_lane ~host_ends:true base ~marker:host_marker;
    write (Record.record_path ~base_path:base) (Yojson.Safe.to_string (ended_on_another_profile ~port));
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      requested ~base ~configuration:(configured ~firefox ~port base) (fun ~sw:_ ~clock:_ request ->
        match request () with
        | Starter.Not_attached (Starter.Start_failed _) -> ()
        | Starter.Not_attached (Starter.Operator_needed _ | Starter.Not_listed_in_time _)
        | Starter.Attached _ | Starter.Not_asked_for -> fail "a host that ended for its own reason is a failed start")))

(* --- the last start ---------------------------------------------------------- *)

module Start_record = Masc.Browser_keeper_firefox_start_record

let outcomes =
  [ Start_record.Attached Starter.Firefox_and_host; Start_record.Attached Starter.Host_only
  ; Start_record.Attached Starter.Nothing
  ; Start_record.Not_attached (Starter.Operator_needed "the browser lane is not installed")
  ; Start_record.Not_attached (Starter.Start_failed "the BiDi host did not start")
  ; Start_record.Not_attached (Starter.Not_listed_in_time "no BiDi connection was listed within 15 s") ]

let a_last_start_reads_back_as_written () =
  List.iter
    (fun outcome ->
      let entry = { Start_record.at = 1_791_000_060.; port = 9222; profile = "/keeper/profile"; outcome } in
      check bool "the same entry" true (Start_record.entry_of_json (Start_record.entry_to_json entry) = Ok entry))
    outcomes

let a_last_start_from_another_writer_is_not_read () =
  let written outcome = Start_record.entry_to_json { Start_record.at = 1_791_000_060.; port = 9222; profile = "/keeper/profile"; outcome } in
  let fields = function `Assoc fields -> fields | _ -> fail "an object" in
  let replaced name value json = `Assoc ((name, value) :: List.remove_assoc name (fields json)) in
  let failed = written (Start_record.Not_attached (Starter.Start_failed "x")) in
  let outcome_of json = List.assoc "outcome" (fields json) in
  List.iter
    (fun (what, json) ->
      match Start_record.entry_of_json json with
      | Ok _ -> fail (what ^ " was read")
      | Error _ -> ())
    [ "another layout", replaced "schema" (`Int 2) failed
    ; "a field this layout has not", replaced "pid" (`Int 1) failed
    ; "a port that is no port", replaced "port" (`Int 0) failed
    ; "a profile a server never writes", replaced "profile" (`String "/keeper\nprofile") failed
    ; "an outcome this reader does not know", replaced "outcome" (`Assoc [ "kind", `String "maybe" ]) failed
    ; ( "a failed start without its message"
      , replaced "outcome" (`Assoc [ "kind", `String "start_failed" ]) failed )
    ; ( "an attached start with a message"
      , replaced "outcome"
          (replaced "message" (`String "x") (outcome_of (written (Start_record.Attached Starter.Nothing))))
          failed )
    ; ( "a message a server never writes"
      , replaced "outcome" (replaced "message" (`String "line\nbreak \027[2J") (outcome_of failed)) failed ) ]

let a_last_starts_message_is_one_printable_line () =
  with_workspace (fun base ->
    let said message =
      (match
         Start_record.write ~base_path:base
           { Start_record.at = 1_791_000_060.; port = 9222; profile = "/keeper/profile"
           ; outcome = Start_record.Not_attached (Starter.Start_failed message) }
       with
       | Ok () -> ()
       | Error detail -> fail detail);
      match Start_record.read ~base_path:base with
      | Start_record.Recorded { outcome = Start_record.Not_attached (Starter.Start_failed message); _ } -> message
      | Start_record.Recorded _ | Start_record.Absent | Start_record.Unreadable _ -> fail "not read back" in
    check string "bytes that are not printable ASCII are named" "a\\x0Ab\\xFF" (said "a\nb\xff");
    check string "a long message is cut and marked"
      (String.make Start_record.message_limit_bytes 'a' ^ "...") (said (String.make 3000 'a')))

(* Each start that ended is written down; a request where none is asked for
   starts nothing and writes nothing. *)
let each_start_that_ended_is_recorded () =
  let recorded base =
    match Start_record.read ~base_path:base with
    | Start_record.Recorded { outcome; _ } -> Some outcome
    | Start_record.Absent -> None
    | Start_record.Unreadable detail -> fail detail in
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      requested ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) (fun ~sw ~clock request ->
        let client = bidi_client 7 in
        Eio.Fiber.fork ~sw (fun () -> await_file_in_eio ~clock host_marker; attach ~sw client);
        ignore (request () : Starter.outcome));
      check bool "an attached start" true (recorded base = Some (Start_record.Attached Starter.Firefox_and_host))));
  (* The server start's own start is written the same way. *)
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      requested ~boot:true ~base ~configuration:(configured ~firefox ~port:(free_port ()) base)
        (fun ~sw ~clock request ->
          let client = bidi_client 8 in
          Eio.Fiber.fork ~sw (fun () -> await_file_in_eio ~clock host_marker; attach ~sw client);
          ignore (request () : Starter.outcome));
      check bool "the server start's start" true
        (recorded base = Some (Start_record.Attached Starter.Firefox_and_host))));
  with_workspace (fun base ->
    let firefox_marker, _ = markers base in
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker ] (fun () ->
      requested ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) (fun ~sw:_ ~clock:_ request ->
        ignore (request () : Starter.outcome));
      check bool "a start that needs the operator" true
        (match recorded base with
         | Some (Start_record.Not_attached (Starter.Operator_needed _)) -> true
         | Some (Start_record.Attached _ | Start_record.Not_attached (Starter.Start_failed _ | Starter.Not_listed_in_time _))
         | None -> false)));
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    requested ~base ~configuration:(configured ~live_enabled:false ~firefox ~port:(free_port ()) base)
      (fun ~sw:_ ~clock:_ request -> ignore (request () : Starter.outcome));
    check bool "none asked for, none written" true (recorded base = None))

(* A request that comes while the server start's own start runs is answered
   with it, connection included: a host just started holds neither the lock
   nor a record yet, and a start then would start a second host. *)
let a_request_during_the_server_start_waits_for_it () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      requested ~boot:true ~base ~configuration:(configured ~firefox ~port:(free_port ()) base)
        (fun ~sw ~clock request ->
          let client = bidi_client 4 in
          Eio.Fiber.fork ~sw (fun () ->
            await_file_in_eio ~clock host_marker; Eio.Time.sleep clock 0.5; attach ~sw client);
          let answer = request () in
          check (option string) "the server start's connection" (Some (id_of client)) (attached_id answer);
          check string "and what it started" "firefox and host" (what_started answer));
      check bool "one Firefox" false (started_again (Keeper_firefox.firefox_log_path ~base_path:base));
      check bool "one host" false (started_again (Keeper_firefox.host_log_path ~base_path:base))))

(* A request that comes after a host was started, and before its connection
   is listed, waits for that start instead of starting another. *)
let a_request_while_the_host_comes_up_waits_for_it () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    with_children ~base [ firefox_marker; host_marker ] (fun () ->
      requested ~base ~configuration:(configured ~firefox ~port:(free_port ()) base) (fun ~sw ~clock request ->
        let client = bidi_client 5 in
        let late = ref None in
        Eio.Fiber.fork ~sw (fun () ->
          await_file_in_eio ~clock host_marker;
          Eio.Fiber.fork ~sw (fun () -> late := Some (request ()));
          Eio.Time.sleep clock 1.;
          attach ~sw client);
        let first = request () in
        let deadline = Unix.gettimeofday () +. 10. in
        while Option.is_none !late && Unix.gettimeofday () < deadline do Eio.Time.sleep clock 0.05 done;
        check (list (option string)) "both see the connection" [ Some (id_of client); Some (id_of client) ]
          [ attached_id first; Option.bind !late attached_id ]);
      check bool "one host" false (started_again (Keeper_firefox.host_log_path ~base_path:base))))

(* --- a session the last host left in Firefox ---------------------------------- *)

(* The last host's record: it ended at [now] with [session] in the Firefox
   on [port]. *)
let host_ended ?(port = 9333) base ~session ~now =
  let held = take ~port base in
  (match Record.ended held ~because:Record.Reason_only ~reason:"stopped by SIGTERM" ~session ~now with
   | Ok () -> ()
   | Error failure -> fail (Record.write_failure_message failure));
  released held

let held_since ~port base = Keeper_firefox.session_held_since ~port (Status.report (Status.observe ~base_path:base ~configuration:None))

let a_held_session_is_read_from_the_last_hosts_end () =
  List.iter
    (fun (what, session, expected) ->
      with_workspace (fun base ->
        install_lane base ~marker:"/unused";
        host_ended base ~session ~now:1_791_000_060.;
        check (option (float 0.001)) what expected (held_since ~port:9333 base)))
    [ "left", Record.Session_left, Some 1_791_000_060.
    ; "refused", Record.Session_refused, Some 1_791_000_060.
    ; "none left", Record.No_session_left, None
    ; "lost before it could end it", Record.Session_unknown, None ];
  with_workspace (fun base ->
    install_lane base ~marker:"/unused";
    host_ended ~port:9444 base ~session:Record.Session_left ~now:1_791_000_060.;
    check (option (float 0.001)) "a host that served another port" None (held_since ~port:9333 base));
  with_workspace (fun base ->
    install_lane base ~marker:"/unused";
    let held = take base in
    Fun.protect ~finally:(fun () -> released held) (fun () ->
      check (option (float 0.001)) "a host that runs" None (held_since ~port:9333 base)))

let only_the_firefox_masc_started_before_that_end_is_restarted () =
  let restart ?(port = 9222) ~since recorded =
    match Keeper_firefox.restart_for_held_session (entry ()) ~port ~since recorded with
    | Keeper_firefox.Restart -> "restart"
    | Keeper_firefox.Not_restarted _ -> "not restarted" in
  let ended_after = 1_791_000_060. and ended_before = 1_790_999_000. in
  check string "ours, started before that host ended" "restart" (restart ~since:ended_after Keeper_firefox.Started_here);
  check string "ours, started as it ended" "restart" (restart ~since:1_791_000_000. Keeper_firefox.Started_here);
  check string "ours, started after it ended" "not restarted" (restart ~since:ended_before Keeper_firefox.Started_here);
  check string "ours, on another port" "not restarted"
    (restart ~port:9333 ~since:ended_after Keeper_firefox.Started_here);
  check string "ended" "not restarted" (restart ~since:ended_after Keeper_firefox.Gone);
  check string "not shown to be ours" "not restarted" (restart ~since:ended_after (Keeper_firefox.Unproven "why"))

(* The Keeper Firefox MASC started, with its host, and the host then gone as
   one that ended with [session] at [now] (the wall clock when not given).
   Its marker goes with it, so the next host's shows when that one starts.
   That Firefox's pid is kept in [first_marker], since the next Firefox
   writes over its marker, and a case that fails to stop it still does. *)
let first_marker base = Filename.concat base "first-firefox"

let started_then_host_ended ?now base ~session ~configuration ~port ~firefox_marker ~host_marker =
  started ~base ~configuration ();
  await_file host_marker;
  Option.iter stop (first_pid host_marker);
  Sys.remove host_marker;
  host_ended ~port base ~session ~now:(match now with Some now -> now | None -> Unix.gettimeofday ());
  match first_pid firefox_marker with
  | Some pid -> write (first_marker base) (string_of_int pid ^ "\n"); pid
  | None -> fail "no Firefox"

let the_firefox_masc_started_is_restarted_for_a_held_session () =
  List.iter
    (fun (what, session) ->
      with_workspace (fun base ->
        let firefox_marker, host_marker = markers base in
        install_lane base ~marker:host_marker;
        let port = free_port () in
        let firefox = fake_firefox base ~marker:firefox_marker Listens in
        let configuration = configured ~firefox ~port base in
        with_children ~base [ firefox_marker; host_marker; first_marker base ] (fun () ->
          let first = started_then_host_ended base ~session ~configuration ~port ~firefox_marker ~host_marker in
          started ~base ~configuration ();
          await_file host_marker;
          check bool (what ^ ": the first Firefox is stopped") false (runs_under base first);
          check bool (what ^ ": another is started and recorded") true
            (match first_pid firefox_marker, recorded base with
             | Some again, Some (entry : Firefox_record.entry) -> again <> first && entry.group = again
             | (Some _ | None), (Some _ | None) -> false);
          check bool (what ^ ": with a host") true (started_again (Keeper_firefox.host_log_path ~base_path:base)))))
    [ "left", Record.Session_left; "refused", Record.Session_refused ]

(* The stopped Firefox's record goes once its group is empty, whether or not
   another one then starts. *)
let a_restart_whose_firefox_cannot_start_leaves_no_record () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let port = free_port () in
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    let configuration = configured ~firefox ~port base in
    with_children ~base [ firefox_marker; host_marker; first_marker base ] (fun () ->
      let first =
        started_then_host_ended base ~session:Record.Session_left ~configuration ~port ~firefox_marker ~host_marker in
      (* Its content is what it was; it can no longer be run. *)
      Unix.chmod firefox 0o600;
      started ~base ~configuration ();
      check bool "the first Firefox is stopped" false (runs_under base first);
      check bool "and no longer recorded" true (recorded base = None);
      check bool "no host for a Firefox that is not there" false (Sys.file_exists host_marker)))

(* A port still held once the stopped group is empty gets no new Firefox:
   it would meet that port, or that profile, still taken. *)
let a_restart_whose_port_stays_open_starts_nothing () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let port = free_port () in
    let firefox = fake_firefox base ~marker:firefox_marker Listens_apart in
    let configuration = configured ~firefox ~port base in
    with_children ~base [ firefox_marker; host_marker; first_marker base ] (fun () ->
      let first =
        started_then_host_ended base ~session:Record.Session_left ~configuration ~port ~firefox_marker ~host_marker in
      started ~base ~configuration ();
      check bool "the first Firefox's group is stopped" false (runs_under base first);
      check bool "the port's holder runs on" true
        (match first_pid (firefox_marker ^ ".listener") with Some pid -> runs_under base pid | None -> false);
      check bool "no second Firefox" false (started_again (Keeper_firefox.firefox_log_path ~base_path:base));
      check bool "no host" false (Sys.file_exists host_marker);
      check bool "the record of that empty group is gone" true (recorded base = None)))

(* The Firefox runs on, still recorded, and a host is started for it. *)
let a_firefox_that_holds_no_such_session_is_not_restarted () =
  List.iter
    (fun (what, session, now) ->
      with_workspace (fun base ->
        let firefox_marker, host_marker = markers base in
        install_lane base ~marker:host_marker;
        let port = free_port () in
        let firefox = fake_firefox base ~marker:firefox_marker Listens in
        let configuration = configured ~firefox ~port base in
        with_children ~base [ firefox_marker; host_marker ] (fun () ->
          let first = started_then_host_ended ?now base ~session ~configuration ~port ~firefox_marker ~host_marker in
          started ~base ~configuration ();
          await_file host_marker;
          check bool (what ^ ": the Firefox runs on") true (runs_under base first);
          check bool (what ^ ": still recorded") true
            (Option.map (fun (entry : Firefox_record.entry) -> entry.group) (recorded base) = Some first);
          check bool (what ^ ": no second Firefox") false
            (started_again (Keeper_firefox.firefox_log_path ~base_path:base));
          check bool (what ^ ": a host is started for it") true
            (started_again (Keeper_firefox.host_log_path ~base_path:base)))))
    [ "none left", Record.No_session_left, None
    ; "lost before it could end it", Record.Session_unknown, None
    ; "left before this Firefox started", Record.Session_left, Some 1_791_000_060. ]

(* A Firefox MASC is not shown to have started answers on the port: no
   record, or one whose number another process has, or one whose start was
   not read. Nothing is stopped, and a host is started for that Firefox. *)
let a_firefox_masc_did_not_start_is_not_restarted () =
  List.iter
    (fun (what, leader_of) ->
      with_workspace (fun base ->
        let firefox_marker, host_marker = markers base in
        install_lane base ~marker:host_marker;
        let firefox = fake_firefox base ~marker:firefox_marker Listens in
        let other = detached_sleeper base "other" in
        Fun.protect ~finally:(fun () -> stop other) (fun () ->
          with_children ~base [ firefox_marker; host_marker ] (fun () ->
            Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
              let listener =
                Eio.Net.listen (Eio.Stdenv.net env) ~sw ~reuse_addr:true ~backlog:4
                  (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
              let port = match Eio.Net.listening_addr listener with `Tcp (_, port) -> port | `Unix _ -> fail "tcp" in
              Option.iter
                (fun leader -> write_record base { (entry ~group:other ~leader ()) with port })
                leader_of;
              host_ended ~port base ~session:Record.Session_left ~now:(Unix.gettimeofday ());
              match
                Eio.Promise.await
                  (Server_browser_keeper_firefox.For_testing.start
                     ~ready_timeout_s:Keeper_firefox.firefox_ready_timeout_s ~sw ~env ~base_path:base
                     ~configuration:(configured ~firefox ~port base) ())
              with
              | Ok () -> ()
              | Error exn -> raise exn));
            await_file host_marker;
            check bool (what ^ ": no Firefox of MASC's") false (firefox_started base);
            check bool (what ^ ": the recorded number's process runs on") true (runs_under base other)))))
    [ "no record", None
    ; "another process under the recorded number", Some (Firefox_record.Started_at "proc:another:1")
    ; "a start that was not read", Some Firefox_record.Start_unreadable ]

(* The Keeper's request is answered once the restarted Firefox's host shows
   its connection. *)
let a_request_restarts_the_firefox_holding_a_session () =
  with_workspace (fun base ->
    let firefox_marker, host_marker = markers base in
    install_lane base ~marker:host_marker;
    let port = free_port () in
    let firefox = fake_firefox base ~marker:firefox_marker Listens in
    let configuration = configured ~firefox ~port base in
    with_children ~base [ firefox_marker; host_marker; first_marker base ] (fun () ->
      let first =
        started_then_host_ended base ~session:Record.Session_left ~configuration ~port ~firefox_marker ~host_marker in
      requested ~base ~configuration (fun ~sw ~clock request ->
        let client = bidi_client 6 in
        Eio.Fiber.fork ~sw (fun () -> await_file_in_eio ~clock host_marker; attach ~sw client);
        let answer = request () in
        check (option string) "the new connection" (Some (id_of client)) (attached_id answer);
        check string "said to have started both" "firefox and host" (what_started answer));
      check bool "the first Firefox is stopped" false (runs_under base first)))

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
        ; test_case "the start of a child" `Quick the_start_of_a_child
        ; test_case "a stop escalates only past the grace" `Quick stop_group_escalates_only_past_the_grace
        ; test_case "a number that names another group" `Quick a_stop_leaves_a_group_its_number_no_longer_names
        ; test_case "a group this account cannot signal" `Quick a_group_this_account_cannot_signal_is_there ] )
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
        ; test_case "a record that cannot be read" `Quick a_record_that_cannot_be_read_is_kept ] )
    ; ( "a Keeper's request"
      , [ test_case "starts both and waits for the connection" `Quick a_request_starts_both_and_waits_for_the_connection
        ; test_case "requests at once share one start" `Quick requests_at_once_share_one_start
        ; test_case "a listed connection starts nothing" `Quick a_listed_connection_starts_nothing
        ; test_case "nothing asked for, nothing started" `Quick a_request_where_none_is_asked_for_starts_nothing
        ; test_case "why nothing started" `Quick a_request_hears_why_nothing_started
        ; test_case "a connection that never shows" `Quick a_connection_that_never_shows_is_reported
        ; test_case "a host that ends at once" `Quick a_host_that_ends_at_once_stops_its_firefox
        ; test_case "a host that met another profile" `Quick a_host_that_met_another_profile_is_the_operators
        ; test_case "an earlier host's profile" `Quick an_earlier_hosts_profile_is_not_this_ones
        ; test_case "each start that ended is recorded" `Quick each_start_that_ended_is_recorded
        ; test_case "during the server start" `Quick a_request_during_the_server_start_waits_for_it
        ; test_case "while the host comes up" `Quick a_request_while_the_host_comes_up_waits_for_it ] )
    ; ( "the last start"
      , [ test_case "reads back as written" `Quick a_last_start_reads_back_as_written
        ; test_case "another writer's record" `Quick a_last_start_from_another_writer_is_not_read
        ; test_case "its message is one printable line" `Quick a_last_starts_message_is_one_printable_line ] )
    ; ( "a session left in Firefox"
      , [ test_case "read from the last host's end" `Quick a_held_session_is_read_from_the_last_hosts_end
        ; test_case "only the one MASC started before that end" `Quick
            only_the_firefox_masc_started_before_that_end_is_restarted
        ; test_case "the Firefox MASC started is restarted" `Quick
            the_firefox_masc_started_is_restarted_for_a_held_session
        ; test_case "a restart whose Firefox cannot start" `Quick
            a_restart_whose_firefox_cannot_start_leaves_no_record
        ; test_case "a restart whose port stays open" `Quick a_restart_whose_port_stays_open_starts_nothing
        ; test_case "one that holds no such session is not" `Quick
            a_firefox_that_holds_no_such_session_is_not_restarted
        ; test_case "one MASC did not start is not" `Quick a_firefox_masc_did_not_start_is_not_restarted
        ; test_case "a Keeper's request restarts it" `Quick a_request_restarts_the_firefox_holding_a_session ] ) ]
