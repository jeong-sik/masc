(* Firefox's Remote Agent opens its BiDi address on the loopback interface
   only; 157.0.1 said "WebDriver BiDi listening on ws://127.0.0.1:9222". *)
let loopback = "127.0.0.1"
let bidi_url ~port = Printf.sprintf "ws://%s:%d/session" loopback port

let firefox_argv (config : Browser_configuration.live_bidi) =
  [ config.firefox
  ; "--no-remote"
  ; "--profile"
  ; config.profile
  ; Browser_bidi_host_status.firefox_flag
  ; string_of_int config.port
  ]

let host_argv ~launcher (config : Browser_configuration.live_bidi) =
  [ launcher
  ; Browser_bidi_host_status.bidi_url_flag
  ; bidi_url ~port:config.port
  ; Browser_bidi_host_status.firefox_profile_flag
  ; config.profile
  ]

(* The directory the host keeps its record in (Browser_bidi_host_record). *)
let lane_path ~base_path name =
  List.fold_left Filename.concat base_path [ Common.masc_dirname; Common.browser_lane_dirname; name ]

let firefox_log_path ~base_path = lane_path ~base_path "keeper-firefox.log"
let host_log_path ~base_path = lane_path ~base_path "bidi-host.log"
let previous_log_path path = path ^ ".1"

(* A fresh profile opened its port in 0.67-0.85 s (headless Firefox 157.0.1,
   M3 Max, 2026-10-09). A profile with history, a visible window and a cold
   disk take longer; thirty seconds still ends a wait for one that never
   opens. *)
let firefox_ready_timeout_s = 30.

type firefox_failure =
  | Spawn_failed of string
  | Not_recorded of string
  | Exited_before_listening of Unix.process_status option
  | Not_listening of float
  | Port_unknown of { seconds : float; detail : string }

let status_text = function
  | Some (Unix.WEXITED code) -> Printf.sprintf "exit status %d" code
  | Some (Unix.WSIGNALED signal) -> Printf.sprintf "signal %d" signal
  | Some (Unix.WSTOPPED signal) -> Printf.sprintf "stopped by signal %d" signal
  | None -> "status unknown"

let firefox_failure_message (config : Browser_configuration.live_bidi) = function
  | Spawn_failed detail -> Printf.sprintf "%s could not be started: %s" config.firefox detail
  | Not_recorded detail ->
    Printf.sprintf "Firefox was started and could not be recorded, so it is not kept: %s." detail
  | Exited_before_listening (Some (Unix.WEXITED 0) as status) ->
    Printf.sprintf
      "Firefox exited (%s) before port %d answered. Another Firefox may have %s open; \
       quit it and the next server start opens this one."
      (status_text status) config.port config.profile
  | Exited_before_listening status ->
    Printf.sprintf "Firefox exited (%s) before port %d answered." (status_text status) config.port
  | Not_listening seconds ->
    Printf.sprintf "Firefox did not open port %d within %.0f s." config.port seconds
  | Port_unknown { seconds; detail } ->
    Printf.sprintf "Port %d did not answer within %.0f s, and the last check could not tell whether \
                    anything listens: %s."
      config.port seconds detail

type launcher_missing = Not_installed | Needs_reinstall

type host_step =
  | Host_running
  | Host_on_another_port of string
  | Host_address_unknown
  | Start_host of string
  | Launcher_not_ready of launcher_missing

let launcher_missing_message missing =
  Printf.sprintf "the browser lane is %s; run connectors/browser/install-host.sh for this workspace"
    (match missing with
     | Not_installed -> "not installed"
     | Needs_reinstall -> "not as its installation wrote it")

let host_on_another_port_message ~port address =
  Printf.sprintf
    "a BiDi host given %s runs for this workspace, which has one host at a time; stop it so the \
     next server start attaches one to port %d"
    address port

let host_address_unknown_message ~port =
  Printf.sprintf
    "a BiDi host holds this workspace's lock and which Firefox it serves cannot be read from its \
     record; stop it so the next server start attaches one to port %d"
    port

(* The record keeps the address as the host was given it. *)
let running_host ~port bidi_url =
  match Browser_bidi_downloads.endpoint bidi_url with
  | Ok (_host, recorded_port, _resource) when recorded_port = port -> Host_running
  | Ok _ -> Host_on_another_port bidi_url
  | Error _ -> Host_address_unknown

let host_step ~port (report : Browser_bidi_host_status.report) =
  let running =
    match report.state with
    | Browser_bidi_host_record.Running entry -> Some (running_host ~port entry.bidi_url)
    | Browser_bidi_host_record.Unreadable { held = Some true; _ }
    | Browser_bidi_host_record.Record_missing_but_locked -> Some Host_address_unknown
    | Browser_bidi_host_record.Unreadable { held = Some false | None; _ }
    | Browser_bidi_host_record.Never_started
    | Browser_bidi_host_record.Ended _
    | Browser_bidi_host_record.Died _ -> None
  in
  match running with
  | Some step -> step
  | None ->
    match report.attach.standing with
    | Browser_bidi_host_status.Launcher_installed -> Start_host report.attach.launcher
    | Browser_bidi_host_status.Launcher_not_installed -> Launcher_not_ready Not_installed
    | Browser_bidi_host_status.Launcher_needs_reinstall -> Launcher_not_ready Needs_reinstall

type recorded_firefox = Started_here | Gone | Unproven of string

(* A process number is given again once its process is gone; when that
   process started is not. So a group is the one started here only while the
   process it is numbered after runs, with the recorded start, in it. And a
   new process is never given the number of a group that still exists
   (POSIX fork(2): "The child process ID also shall not match any active
   process group ID"), so another process under that number means the
   recorded group has ended, whatever group that number names now. *)
let recorded_firefox (entry : Browser_keeper_firefox_record.entry) ~leader_started ~leader_group
    ~group_has_members =
  let unproven why = if group_has_members then Unproven why else Gone in
  match entry.leader with
  | Browser_keeper_firefox_record.Start_unreadable ->
    unproven
      (Printf.sprintf
         "when process %d started could not be read when it was started, so nothing tells it from \
          a later process with that number"
         entry.group)
  | Browser_keeper_firefox_record.Started_at recorded ->
    (match leader_started with
     | None ->
       unproven
         (Printf.sprintf
            "process %d no longer runs, or when it started cannot be read, and nothing tells what \
             is left in its group from a later group with that number"
            entry.group)
     | Some now when not (String.equal now recorded) -> Gone
     | Some _ ->
       (match leader_group with
        | Ok group when group = entry.group -> Started_here
        | Ok group ->
          unproven
            (Printf.sprintf "process %d is in process group %d now, not %d" entry.group group
               entry.group)
        | Error detail ->
          unproven
            (Printf.sprintf "which process group process %d is in cannot be told: %s" entry.group
               detail)))
