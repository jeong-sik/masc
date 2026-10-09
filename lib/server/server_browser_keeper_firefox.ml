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

(* Who opened the port: the process started here, with the handle a failure
   path stops; once that one has ended, one it left in its process group;
   or, with that group empty, a process this server did not start. *)
type started =
  | First_process of Posix_spawn_detached.t
  | Its_group of Posix_spawn_detached.t
  | Not_started_here

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
         | None -> Ok (First_process firefox)
         | Some _ when Posix_spawn_detached.group_has_members firefox -> Ok (Its_group firefox)
         | Some _ -> Ok Not_started_here)
      | Nothing_listens -> not_yet ~timed_out:(Keeper_firefox.Not_listening ready_timeout_s)
      | Unknown detail ->
        not_yet ~timed_out:(Keeper_firefox.Port_unknown { seconds = ready_timeout_s; detail })
    (* [timed_out] is what this check found, reported if it was the last. *)
    and not_yet ~timed_out =
      match Eio.Promise.peek firefox.exited with
      | Some status when not (Posix_spawn_detached.group_has_members firefox) ->
        Error (Keeper_firefox.Exited_before_listening status)
      | Some _ | None when Monotonic_deadline.passed deadline ->
        (* The Firefox started here holds the port unauthenticated (RFC
           §5), so a readiness failure stops it rather than leaving it for
           the next boot to find. *)
        Posix_spawn_detached.stop_group ~clock firefox;
        Error timed_out
      | Some _ | None -> Eio.Time.sleep clock firefox_ready_poll_s; await ()
    in
    await ()

let host_step ~base_path (config : Browser_configuration.live_bidi) =
  Keeper_firefox.host_step ~port:config.port (Host_status.report (Host_status.observe ~base_path))

(* Decided once, before Firefox: a host that started meanwhile holds the lock,
   and the one started here is refused there and says so in its own log. *)
let start_host ~sw ~base_path ~launcher (config : Browser_configuration.live_bidi) =
  let log_path = Keeper_firefox.host_log_path ~base_path in
  match
    spawn_logged ~sw ~argv:(Keeper_firefox.host_argv ~launcher ~port:config.port)
      ~env:(host_environment ()) ~log_path
  with
  | Error detail -> Error detail
  | Ok host ->
    Log.Server.info "browser-lane: started the BiDi host (pid %d) for %s; its output is in %s"
      host.pid (Keeper_firefox.bidi_url ~port:config.port) log_path;
    Ok ()

let answering_port_line =
  "if that is not this profile's Firefox, the host's record says why it could not attach"

(* [Ready] carries the Firefox this run started, when it did: one whose port
   already answered, or that answered only after emptying its group, was not
   started here and is not this server's to stop. *)
type firefox =
  | Ready of Posix_spawn_detached.t option
  | Undetermined of string
  | Failed of Keeper_firefox.firefox_failure

let start_both ~sw ~env ~ready_timeout_s ~base_path ~launcher (config : Browser_configuration.live_bidi) =
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  let firefox =
    match port_state ~net ~clock ~port:config.port with
    | Answers ->
      Log.Server.info "browser-lane: port %d already answers, so no Keeper Firefox is started; %s"
        config.port answering_port_line;
      Ready None
    | Unknown detail -> Undetermined detail
    | Nothing_listens ->
      (match start_firefox ~sw ~net ~clock ~ready_timeout_s ~base_path config with
       | Ok (First_process handle) ->
         Log.Server.info "browser-lane: started the Keeper Firefox (pid %d) on %s with profile %s"
           handle.pid (Keeper_firefox.bidi_url ~port:config.port) config.profile;
         Ready (Some handle)
       | Ok (Its_group handle) ->
         Log.Server.info
           "browser-lane: started the Keeper Firefox (process group %d; its first process ended before \
            the port answered) on %s with profile %s"
           handle.pid (Keeper_firefox.bidi_url ~port:config.port) config.profile;
         Ready (Some handle)
       | Ok Not_started_here ->
         Log.Server.info
           "browser-lane: the Keeper Firefox started here ended with nothing left in its process \
            group, and port %d answers from another process; %s"
           config.port answering_port_line;
         Ready None
       | Error failure -> Failed failure)
  in
  match firefox with
  | Ready owned -> (
    match start_host ~sw ~base_path ~launcher config with
    | Ok () -> ()
    | Error detail ->
      Log.Server.error "browser-lane: the BiDi host did not start: %s" detail;
      (* The pairing is the point (RFC §5): the Firefox this run started is
         stopped when no host serves its lane; one already running stays. *)
      Option.iter (Posix_spawn_detached.stop_group ~clock) owned)
  | Undetermined detail ->
    Log.Server.error
      "browser-lane: cannot tell whether port %d answers (%s); neither the Keeper Firefox nor \
       its host is started"
      config.port detail
  | Failed failure ->
    Log.Server.error "browser-lane: the Keeper Firefox did not start: %s Its output is in %s."
      (Keeper_firefox.firefox_failure_message config failure)
      (Keeper_firefox.firefox_log_path ~base_path)

(* The host holding the lock attached to its Firefox when it started and
   does not attach again, so a Firefox started now would have no host. *)
let leave_running ~env (config : Browser_configuration.live_bidi) =
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  match port_state ~net ~clock ~port:config.port with
  | Answers ->
    Log.Server.info "browser-lane: a BiDi host for port %d is running and the port answers; nothing \
                     is started"
      config.port
  | Nothing_listens ->
    Log.Server.error
      "browser-lane: a BiDi host for port %d holds this workspace while nothing answers on that \
       port; nothing is started. That host ends with its Firefox gone, and the next server start \
       opens both."
      config.port
  | Unknown detail ->
    Log.Server.error
      "browser-lane: a BiDi host for port %d is running, and whether the port answers cannot be \
       told (%s); nothing is started"
      config.port detail

(* Firefox opens a port any local process may drive (RFC-browser-keeper-firefox
   §5), so it is started only when a host is started with it. *)
let bring_up ~sw ~env ~ready_timeout_s ~base_path (config : Browser_configuration.live_bidi) =
  let neither why = Log.Server.error "browser-lane: neither the Keeper Firefox nor its BiDi host is started: %s" why in
  match host_step ~base_path config with
  | Keeper_firefox.Launcher_not_ready missing -> neither (Keeper_firefox.launcher_missing_message missing)
  | Keeper_firefox.Host_on_another_port address ->
    neither (Keeper_firefox.host_on_another_port_message ~port:config.port address)
  | Keeper_firefox.Host_address_unknown -> neither (Keeper_firefox.host_address_unknown_message ~port:config.port)
  | Keeper_firefox.Host_running -> leave_running ~env config
  | Keeper_firefox.Start_host launcher -> start_both ~sw ~env ~ready_timeout_s ~base_path ~launcher config

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
