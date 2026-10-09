module Keeper_firefox = Browser_keeper_firefox
module Host_status = Browser_bidi_host_status

(* One attempt to reach a loopback port. A refused connect is the answer
   "nothing listens"; the timeout bounds one that hangs. *)
let port_check_timeout_s = 1.
let firefox_ready_poll_s = 0.1

type port = Answers | Nothing_listens | Unknown of string

let port_state ~net ~clock ~port =
  match
    Eio.Time.with_timeout clock port_check_timeout_s (fun () ->
      Eio.Switch.run (fun sw ->
        match Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) with
        | flow -> Eio.Flow.close flow; Ok Answers
        | exception Eio.Io (Eio.Net.E (Eio.Net.Connection_failure (Eio.Net.Refused _)), _) ->
          Ok Nothing_listens
        | exception (Eio.Io _ as exn) -> Ok (Unknown (Printexc.to_string exn))))
  with
  | Ok state -> state
  | Error `Timeout -> Unknown (Printf.sprintf "no answer within %.0f s" port_check_timeout_s)

(* A log holds one run of the process and the run before it: each start
   moves the last run's log aside, over the one before. A host whose server
   stays away writes a line every five seconds (Browser_host), so a log
   still grows for as long as one run lasts. *)
let open_log path =
  match Fs_compat.mkdir_p (Filename.dirname path) with
  | exception (Eio.Io _ as exn) -> Error (Printexc.to_string exn)
  | exception Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)
  | () ->
    (match Unix.rename path (Keeper_firefox.previous_log_path path) with
     | exception Unix.Unix_error (Unix.ENOENT, _, _) | () ->
       (match Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND; Unix.O_CLOEXEC ] 0o600 with
        | fd -> Ok fd
        | exception Unix.Unix_error (code, _, _) -> Error (Unix.error_message code))
     | exception Unix.Unix_error (code, _, _) ->
       Error (Printf.sprintf "moving the last run's log aside: %s" (Unix.error_message code)))

(* The child keeps its own copy of the log descriptor; this process closes
   its copy either way. *)
let spawn_logged ~sw ~argv ~env ~log_path =
  match open_log log_path with
  | Error detail -> Error (Printf.sprintf "cannot open %s: %s" log_path detail)
  | Ok output ->
    Fun.protect
      ~finally:(fun () -> try Unix.close output with Unix.Unix_error _ -> ())
      (fun () -> Posix_spawn_detached.spawn ~sw ~argv ~env ~output)

(* The host takes either of these over the workspace's connection.toml as a
   fixed server address (connectors/browser/host/README.md). The server's own
   values would pin the host to it, past a restart on another port. *)
let host_environment () =
  let fixed = [ Env_config_core.http_port_env_key; Env_config_core.http_base_url_env_key ] in
  let key entry = match String.index_opt entry '=' with Some i -> String.sub entry 0 i | None -> entry in
  Array.of_list
    (List.filter (fun entry -> not (List.mem (key entry) fixed)) (Array.to_list (Unix.environment ())))

(* Who opened the port: the process started here, or, once that one has
   ended, one it left in its process group. *)
type started = First_process of int | Its_group of int

(* A Firefox may end its first process and go on in another. Applying a
   staged update, it starts the updater, which starts Firefox again; whether
   those stay in the group of the one started here was not measured
   (RFC-browser-keeper-firefox §3.2). So the wait ends at an exit only once
   nothing is left in that group. *)
let start_firefox ~sw ~net ~clock ~ready_timeout_s ~base_path (config : Browser_configuration.live_bidi) =
  match
    spawn_logged ~sw ~argv:(Keeper_firefox.firefox_argv config) ~env:(Unix.environment ())
      ~log_path:(Keeper_firefox.firefox_log_path ~base_path)
  with
  | Error detail -> Error (Keeper_firefox.Spawn_failed detail)
  | Ok firefox ->
    let deadline = Monotonic_deadline.after ~seconds:ready_timeout_s in
    let rec await () =
      match port_state ~net ~clock ~port:config.port with
      | Answers ->
        (match Eio.Promise.peek firefox.exited with
         | None -> Ok (First_process firefox.pid)
         | Some _ -> Ok (Its_group firefox.pid))
      | Nothing_listens -> not_yet ~timed_out:(Keeper_firefox.Not_listening ready_timeout_s)
      | Unknown detail ->
        not_yet ~timed_out:(Keeper_firefox.Port_unknown { seconds = ready_timeout_s; detail })
    (* [timed_out] is what this check found, reported if it was the last. *)
    and not_yet ~timed_out =
      match Eio.Promise.peek firefox.exited with
      | Some status when not (Posix_spawn_detached.group_has_members firefox) ->
        Error (Keeper_firefox.Exited_before_listening status)
      | Some _ | None when Monotonic_deadline.passed deadline -> Error timed_out
      | Some _ | None -> Eio.Time.sleep clock firefox_ready_poll_s; await ()
    in
    await ()

let host_step ~base_path (config : Browser_configuration.live_bidi) =
  Keeper_firefox.host_step ~port:config.port (Host_status.report (Host_status.observe ~base_path))

(* Asked again once Firefox answers: a host may have started meanwhile. *)
let start_host ~sw ~base_path (config : Browser_configuration.live_bidi) =
  match host_step ~base_path config with
  | Keeper_firefox.Host_running ->
    Log.Server.info "browser-lane: a BiDi host is already running for this workspace"
  | Keeper_firefox.Host_on_another_port address ->
    Log.Server.error "browser-lane: the BiDi host is not started: %s"
      (Keeper_firefox.host_on_another_port_message ~port:config.port address)
  | Keeper_firefox.Launcher_not_ready missing ->
    Log.Server.error "browser-lane: the BiDi host is not started: %s"
      (Keeper_firefox.launcher_missing_message missing)
  | Keeper_firefox.Start_host launcher ->
    let log_path = Keeper_firefox.host_log_path ~base_path in
    (match
       spawn_logged ~sw ~argv:(Keeper_firefox.host_argv ~launcher ~port:config.port)
         ~env:(host_environment ()) ~log_path
     with
     | Error detail -> Log.Server.error "browser-lane: the BiDi host did not start: %s" detail
     | Ok host ->
       Log.Server.info "browser-lane: started the BiDi host (pid %d) for %s; its output is in %s"
         host.pid (Keeper_firefox.bidi_url ~port:config.port) log_path)

type firefox = Ready | Undetermined of string | Failed of Keeper_firefox.firefox_failure

let start_both ~sw ~env ~ready_timeout_s ~base_path (config : Browser_configuration.live_bidi) =
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  let firefox =
    match port_state ~net ~clock ~port:config.port with
    | Answers ->
      Log.Server.info
        "browser-lane: port %d already answers, so no Keeper Firefox is started; if that is not \
         this profile's Firefox, the host's record says why it could not attach"
        config.port;
      Ready
    | Unknown detail -> Undetermined detail
    | Nothing_listens ->
      (match start_firefox ~sw ~net ~clock ~ready_timeout_s ~base_path config with
       | Ok started ->
         Log.Server.info "browser-lane: started the Keeper Firefox (%s) on %s with profile %s"
           (match started with
            | First_process pid -> Printf.sprintf "pid %d" pid
            | Its_group pgid ->
              Printf.sprintf "process group %d; its first process ended before the port answered" pgid)
           (Keeper_firefox.bidi_url ~port:config.port) config.profile;
         Ready
       | Error failure -> Failed failure)
  in
  match firefox with
  | Ready -> start_host ~sw ~base_path config
  | Undetermined detail ->
    Log.Server.error
      "browser-lane: cannot tell whether port %d answers (%s); neither the Keeper Firefox nor \
       its host is started"
      config.port detail
  | Failed failure ->
    Log.Server.error "browser-lane: the Keeper Firefox did not start: %s Its output is in %s."
      (Keeper_firefox.firefox_failure_message config failure)
      (Keeper_firefox.firefox_log_path ~base_path)

(* Firefox opens a port any local process may drive (RFC-browser-keeper-firefox
   §5), so it is started only when a host can be attached to it. *)
let bring_up ~sw ~env ~ready_timeout_s ~base_path (config : Browser_configuration.live_bidi) =
  let neither why = Log.Server.error "browser-lane: neither the Keeper Firefox nor its BiDi host is started: %s" why in
  match host_step ~base_path config with
  | Keeper_firefox.Launcher_not_ready missing -> neither (Keeper_firefox.launcher_missing_message missing)
  | Keeper_firefox.Host_on_another_port address ->
    neither (Keeper_firefox.host_on_another_port_message ~port:config.port address)
  | Keeper_firefox.Host_running | Keeper_firefox.Start_host _ ->
    start_both ~sw ~env ~ready_timeout_s ~base_path config

let work ~sw ~env ~ready_timeout_s ~base_path ~configuration () =
  match configuration with
  | Some { Browser_configuration.live_bidi = Some config; live_enabled = true; _ } ->
    bring_up ~sw ~env ~ready_timeout_s ~base_path config
  | Some { Browser_configuration.live_bidi = Some _; live_enabled = false; _ } ->
    Log.Server.info
      "browser-lane: [browser.live] is off; the Keeper Firefox and its host are neither \
       started nor checked"
  | Some { Browser_configuration.live_bidi = None; _ } | None -> ()

(* This fiber runs on the server's root switch, where an exception would end
   the server. One the work did not expect is logged instead, as the
   Stagehand lane does; a cancellation still ends it. *)
let start ~sw ~env ~base_path ~configuration =
  Eio.Fiber.fork ~sw (fun () ->
    try
      work ~sw ~env ~ready_timeout_s:Keeper_firefox.firefox_ready_timeout_s ~base_path
        ~configuration ()
    with
    | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
    | exn ->
      Log.Server.error "browser-lane: starting the Keeper Firefox failed: %s" (Printexc.to_string exn))

module For_testing = struct
  let start ~ready_timeout_s ~sw ~env ~base_path ~configuration =
    Eio.Fiber.fork_promise ~sw (work ~sw ~env ~ready_timeout_s ~base_path ~configuration)
end
