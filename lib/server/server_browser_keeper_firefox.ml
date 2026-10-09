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

let open_log path =
  match Fs_compat.mkdir_p (Filename.dirname path) with
  | exception (Eio.Io _ as exn) -> Error (Printexc.to_string exn)
  | exception Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)
  | () ->
    (match Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND; Unix.O_CLOEXEC ] 0o600 with
     | fd -> Ok fd
     | exception Unix.Unix_error (code, _, _) -> Error (Unix.error_message code))

(* The child keeps its own copy of the log descriptor; this process closes
   its copy either way. *)
let spawn_logged ~sw ~argv ~log_path =
  match open_log log_path with
  | Error detail -> Error (Printf.sprintf "cannot open %s: %s" log_path detail)
  | Ok output ->
    Fun.protect
      ~finally:(fun () -> try Unix.close output with Unix.Unix_error _ -> ())
      (fun () -> Posix_spawn_detached.spawn ~sw ~argv ~env:(Unix.environment ()) ~output)

(* A Firefox may end its first process and go on in another: applying a
   staged update it starts the updater, which starts Firefox again, and both
   stay in the group of the one started here unless they leave it. So the
   wait ends at an exit only once nothing is left in that group. *)
let start_firefox ~sw ~net ~clock ~ready_timeout_s ~base_path (config : Browser_configuration.live_bidi) =
  match
    spawn_logged ~sw ~argv:(Keeper_firefox.firefox_argv config)
      ~log_path:(Keeper_firefox.firefox_log_path ~base_path)
  with
  | Error detail -> Error (Keeper_firefox.Spawn_failed detail)
  | Ok firefox ->
    let deadline = Monotonic_deadline.after ~seconds:ready_timeout_s in
    let rec await () =
      match port_state ~net ~clock ~port:config.port with
      | Answers -> Ok firefox.pid
      | Nothing_listens | Unknown _ ->
        (match Eio.Promise.peek firefox.exited with
         | Some status when not (Posix_spawn_detached.group_has_members firefox) ->
           Error (Keeper_firefox.Exited_before_listening status)
         | Some _ | None when Monotonic_deadline.passed deadline ->
           Error (Keeper_firefox.Not_listening ready_timeout_s)
         | Some _ | None -> Eio.Time.sleep clock firefox_ready_poll_s; await ())
    in
    await ()

let start_host ~sw ~base_path (config : Browser_configuration.live_bidi) =
  match Keeper_firefox.host_step (Host_status.report (Host_status.observe ~base_path)) with
  | Keeper_firefox.Host_running ->
    Log.Server.info "browser-lane: a BiDi host is already running for this workspace"
  | Keeper_firefox.Launcher_not_ready missing ->
    Log.Server.error "browser-lane: the BiDi host is not started: %s"
      (Keeper_firefox.launcher_missing_message missing)
  | Keeper_firefox.Start_host launcher ->
    let log_path = Keeper_firefox.host_log_path ~base_path in
    (match
       spawn_logged ~sw ~argv:(Keeper_firefox.host_argv ~launcher ~port:config.port) ~log_path
     with
     | Error detail -> Log.Server.error "browser-lane: the BiDi host did not start: %s" detail
     | Ok host ->
       Log.Server.info "browser-lane: started the BiDi host (pid %d) for %s; its output is in %s"
         host.pid (Keeper_firefox.bidi_url ~port:config.port) log_path)

type firefox = Ready | Undetermined of string | Failed of Keeper_firefox.firefox_failure

let bring_up ~sw ~env ~ready_timeout_s ~base_path (config : Browser_configuration.live_bidi) =
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
       | Ok pid ->
         Log.Server.info "browser-lane: started the Keeper Firefox (pid %d) on %s with profile %s"
           pid (Keeper_firefox.bidi_url ~port:config.port) config.profile;
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
