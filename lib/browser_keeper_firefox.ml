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

let host_argv ~launcher ~port = [ launcher; Browser_bidi_host_status.bidi_url_flag; bidi_url ~port ]

(* The directory the host keeps its record in (Browser_bidi_host_record). *)
let lane_path ~base_path name =
  List.fold_left Filename.concat base_path [ Common.masc_dirname; Common.browser_lane_dirname; name ]

let firefox_log_path ~base_path = lane_path ~base_path "keeper-firefox.log"
let host_log_path ~base_path = lane_path ~base_path "bidi-host.log"

(* A fresh profile opened its port in 0.67-0.85 s (headless Firefox 157.0.1,
   M3 Max, 2026-10-09). A profile with history, a visible window and a cold
   disk take longer; thirty seconds still ends a wait for one that never
   opens. *)
let firefox_ready_timeout_s = 30.

type firefox_failure =
  | Spawn_failed of string
  | Exited_before_listening of Unix.process_status option
  | Not_listening of float

let status_text = function
  | Some (Unix.WEXITED code) -> Printf.sprintf "exit status %d" code
  | Some (Unix.WSIGNALED signal) -> Printf.sprintf "signal %d" signal
  | Some (Unix.WSTOPPED signal) -> Printf.sprintf "stopped by signal %d" signal
  | None -> "status unknown"

let firefox_failure_message (config : Browser_configuration.live_bidi) = function
  | Spawn_failed detail -> Printf.sprintf "%s could not be started: %s" config.firefox detail
  | Exited_before_listening (Some (Unix.WEXITED 0) as status) ->
    Printf.sprintf
      "Firefox exited (%s) before port %d answered. Another Firefox may have %s open; \
       quit it and the next server start opens this one."
      (status_text status) config.port config.profile
  | Exited_before_listening status ->
    Printf.sprintf "Firefox exited (%s) before port %d answered." (status_text status) config.port
  | Not_listening seconds ->
    Printf.sprintf "Firefox did not open port %d within %.0f s." config.port seconds

type launcher_missing = Not_installed | Needs_reinstall

type host_step =
  | Host_running
  | Start_host of string
  | Launcher_not_ready of launcher_missing

let launcher_missing_message missing =
  Printf.sprintf "the browser lane is %s; run connectors/browser/install-host.sh for this workspace"
    (match missing with
     | Not_installed -> "not installed"
     | Needs_reinstall -> "not as its installation wrote it")

let host_step (report : Browser_bidi_host_status.report) =
  let holds_lock =
    match report.state with
    | Browser_bidi_host_record.Running _ -> true
    | Browser_bidi_host_record.Unreadable { held = Some true; _ } -> true
    | Browser_bidi_host_record.Unreadable { held = Some false | None; _ }
    | Browser_bidi_host_record.Never_started
    | Browser_bidi_host_record.Ended _
    | Browser_bidi_host_record.Died _ -> false
  in
  if holds_lock then Host_running
  else
    match report.attach.standing with
    | Browser_bidi_host_status.Launcher_installed -> Start_host report.attach.launcher
    | Browser_bidi_host_status.Launcher_not_installed -> Launcher_not_ready Not_installed
    | Browser_bidi_host_status.Launcher_needs_reinstall -> Launcher_not_ready Needs_reinstall
