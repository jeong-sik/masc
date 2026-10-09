module Keeper_firefox = Browser_keeper_firefox
module Firefox_record = Browser_keeper_firefox_record
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

(* Who opened the port: the process started here; once that one has ended,
   one it left in its process group; or, with that group empty, a process
   this server did not start. *)
type started = First_process | Its_group | Not_started_here

(* A Firefox started here that is left without a host is stopped: its port
   lets any local process drive it. SIGTERM lets it close its profile; one
   still running after this many seconds gets SIGKILL. *)
let firefox_stop_grace_s = 5.
let group_poll_s = 0.1

let stop_message = function
  | Posix_spawn_detached.Ended_on_term -> "It was stopped."
  | Posix_spawn_detached.Killed_after_grace ->
    Printf.sprintf "It was killed, %.0f s after SIGTERM." firefox_stop_grace_s

(* Only the group of a Firefox started here is signalled; a Firefox that
   was running already is never touched. *)
let stop_started ~clock firefox =
  Posix_spawn_detached.stop_group ~clock ~grace_s:firefox_stop_grace_s firefox

(* The record tells the process started here from a later one given its
   number by when it started (RFC-browser-keeper-firefox §3.4). *)
let running_leader (firefox : Posix_spawn_detached.t) =
  match Server_startup_takeover.process_started firefox.pid with
  | Some started -> Firefox_record.Started_at started
  | None -> Firefox_record.Start_unreadable

let forget ~base_path =
  match Firefox_record.remove ~base_path with
  | Ok () -> ()
  | Error detail -> Log.Server.error "browser-lane: the Keeper Firefox record is not removed: %s" detail

let recorded_firefox (entry : Firefox_record.entry) =
  Keeper_firefox.recorded_firefox entry
    ~leader_started:(Server_startup_takeover.process_started entry.group)
    ~leader_group:(Posix_spawn_detached.group_of_pid entry.group)
    ~group_has_members:(Posix_spawn_detached.group_id_has_members entry.group)

(* A record names the only Keeper Firefox MASC knows it started. A second
   one is not started over a record whose group may still run: that would
   take the first one's only name, and Firefox refuses a profile another
   Firefox holds, so the second would end and leave the first unnamed. A
   server that ended while it waited for that Firefox's port leaves it so. *)
let earlier_firefox ~base_path =
  match Firefox_record.read ~base_path with
  | Firefox_record.Absent -> Ok ()
  | Firefox_record.Unreadable detail ->
    Error
      (Printf.sprintf
         "the record of the Keeper Firefox MASC started, %s, cannot be read (%s); remove it once no \
          Firefox it may name runs"
         (Firefox_record.record_path ~base_path) detail)
  | Firefox_record.Recorded entry ->
    (match recorded_firefox entry with
     | Keeper_firefox.Gone -> Ok ()
     | Keeper_firefox.Started_here ->
       Error
         (Printf.sprintf
            "the Keeper Firefox MASC started earlier (process group %d, port %d) still runs, and \
             nothing answers on the port asked for. Close it, and the next server start opens one"
            entry.group entry.port)
     | Keeper_firefox.Unproven why ->
       Error
         (Printf.sprintf
            "the record names process group %d (port %d), which is not shown to have ended: %s. \
             Close that Firefox if it runs, then remove %s"
            entry.group entry.port why (Firefox_record.record_path ~base_path)))

(* A start counts once the record names it: a server that later finds the
   workspace no longer asks for a Keeper Firefox stops this one by it, and
   nothing else would name it once this server is gone. It is written before
   the wait for the port, so a server that ends during that wait leaves it
   named. *)
let record_started ~clock ~base_path (config : Browser_configuration.live_bidi) firefox =
  let entry =
    { Firefox_record.group = firefox.Posix_spawn_detached.pid; leader = running_leader firefox
    ; profile = config.profile; port = config.port; started_at = Eio.Time.now clock }
  in
  match Firefox_record.write ~base_path entry with
  | Ok () -> Ok ()
  | Error (Firefox_record.Not_synced _ as failure) ->
    Log.Server.warn "browser-lane: the Keeper Firefox record %s is %s"
      (Firefox_record.record_path ~base_path) (Firefox_record.write_failure_message failure);
    Ok ()
  | Error (Firefox_record.Not_written _ as failure) ->
    Error
      (Printf.sprintf "%s is %s" (Firefox_record.record_path ~base_path)
         (Firefox_record.write_failure_message failure))

(* A Firefox may end its first process and go on in another. Applying a
   staged update, it starts the updater, which starts Firefox again; whether
   those stay in the group of the one started here was not measured
   (RFC-browser-keeper-firefox §3.2). So the wait ends at an exit only once
   nothing is left in that group. A Firefox still there at the deadline is
   stopped. *)
let await_port ~net ~clock ~ready_timeout_s ~base_path (config : Browser_configuration.live_bidi)
    (firefox : Posix_spawn_detached.t) =
  let deadline = Monotonic_deadline.after ~seconds:ready_timeout_s in
  let rec await () =
    match port_state ~net ~clock ~port:config.port with
    | Answers ->
      (match Eio.Promise.peek firefox.exited with
       | None -> Ok (firefox, First_process)
       | Some _ when Posix_spawn_detached.group_has_members firefox -> Ok (firefox, Its_group)
       | Some _ -> forget ~base_path; Ok (firefox, Not_started_here))
    | Nothing_listens -> not_yet ~timed_out:(Keeper_firefox.Not_listening ready_timeout_s)
    | Unknown detail ->
      not_yet ~timed_out:(Keeper_firefox.Port_unknown { seconds = ready_timeout_s; detail })
  (* [timed_out] is what this check found, reported if it was the last. *)
  and not_yet ~timed_out =
    match Eio.Promise.peek firefox.exited with
    | Some status when not (Posix_spawn_detached.group_has_members firefox) ->
      forget ~base_path;
      Error (Keeper_firefox.Exited_before_listening status, None)
    | Some _ | None when Monotonic_deadline.passed deadline ->
      let stopped = stop_started ~clock firefox in
      forget ~base_path;
      Error (timed_out, Some stopped)
    | Some _ | None -> Eio.Time.sleep clock firefox_ready_poll_s; await ()
  in
  await ()

(* The spawn and its record are not cancelled apart: a server that stops
   between them would leave a Firefox nothing names. *)
let start_firefox ~sw ~net ~clock ~ready_timeout_s ~base_path (config : Browser_configuration.live_bidi) =
  let recorded =
    Eio.Cancel.protect (fun () ->
      match
        spawn_logged ~sw ~argv:(Keeper_firefox.firefox_argv config) ~env:(Unix.environment ())
          ~log_path:(Keeper_firefox.firefox_log_path ~base_path)
      with
      | Error detail -> Error (Keeper_firefox.Spawn_failed detail, None)
      | Ok firefox ->
        (match record_started ~clock ~base_path config firefox with
         | Error detail -> Error (Keeper_firefox.Not_recorded detail, Some (stop_started ~clock firefox))
         | Ok () -> Ok firefox))
  in
  match recorded with
  | Error failure -> Error failure
  | Ok firefox -> await_port ~net ~clock ~ready_timeout_s ~base_path config firefox

let host_step ~base_path (config : Browser_configuration.live_bidi) =
  Keeper_firefox.host_step ~port:config.port (Host_status.report (Host_status.observe ~base_path))

(* A host that leaves in order writes its ending, then gives the lock up as
   it exits; a host started in between would be refused at the lock and
   end, leaving none. So the lock is waited for, this long at most. *)
let ending_host_wait_s = 5.

let await_free_lock ~clock ~wait_s ~base_path =
  let deadline = Monotonic_deadline.after ~seconds:wait_s in
  let rec wait () =
    match Browser_bidi_host_record.lock_is_held ~base_path with
    | Ok false -> Ok ()
    | Ok true when Monotonic_deadline.passed deadline ->
      Error (Printf.sprintf "a BiDi host still holds this workspace's lock after %.0f s" wait_s)
    | Ok true -> Eio.Time.sleep clock group_poll_s; wait ()
    | Error detail -> Error ("whether a BiDi host holds this workspace's lock cannot be told: " ^ detail)
  in
  wait ()

(* Decided once, before Firefox: a host that started meanwhile holds the lock,
   and the one started here is refused there and says so in its own log. *)
let start_host ~sw ~base_path ~launcher (config : Browser_configuration.live_bidi) =
  let log_path = Keeper_firefox.host_log_path ~base_path in
  match
    spawn_logged ~sw ~argv:(Keeper_firefox.host_argv ~launcher config)
      ~env:(host_environment ()) ~log_path
  with
  | Error detail -> Error detail
  | Ok host ->
    Log.Server.info "browser-lane: started the BiDi host (pid %d) for %s; its output is in %s"
      host.pid (Keeper_firefox.bidi_url ~port:config.port) log_path;
    Ok ()

let answering_port_line =
  "if that is not this profile's Firefox, the host's record says why it could not attach"

(* [Ready (Some firefox)]: the port answers from the Firefox started here,
   which is stopped if its host cannot be started. *)
type firefox =
  | Ready of Posix_spawn_detached.t option
  | Undetermined of string
  | Earlier_firefox of string
  | Failed of Keeper_firefox.firefox_failure * Posix_spawn_detached.stopped option

let neither why = Log.Server.error "browser-lane: neither the Keeper Firefox nor its BiDi host is started: %s" why

let started_firefox ~sw ~net ~clock ~ready_timeout_s ~base_path (config : Browser_configuration.live_bidi) =
  match start_firefox ~sw ~net ~clock ~ready_timeout_s ~base_path config with
  | Ok (started, First_process) ->
    Log.Server.info "browser-lane: started the Keeper Firefox (pid %d) on %s with profile %s"
      started.pid (Keeper_firefox.bidi_url ~port:config.port) config.profile;
    Ready (Some started)
  | Ok (started, Its_group) ->
    Log.Server.info
      "browser-lane: started the Keeper Firefox (process group %d; its first process ended \
       before the port answered) on %s with profile %s"
      started.pid (Keeper_firefox.bidi_url ~port:config.port) config.profile;
    Ready (Some started)
  | Ok (_, Not_started_here) ->
    Log.Server.info
      "browser-lane: the Keeper Firefox started here ended with nothing left in its process \
       group, and port %d answers from another process; %s"
      config.port answering_port_line;
    Ready None
  | Error (failure, stop) -> Failed (failure, stop)

let start_both ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~base_path ~launcher
    (config : Browser_configuration.live_bidi) =
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  match await_free_lock ~clock ~wait_s:ending_host_wait_s ~base_path with
  | Error why -> neither why
  | Ok () ->
    let firefox =
      match port_state ~net ~clock ~port:config.port with
      | Answers ->
        Log.Server.info "browser-lane: port %d already answers, so no Keeper Firefox is started; %s"
          config.port answering_port_line;
        Ready None
      | Unknown detail -> Undetermined detail
      | Nothing_listens ->
        (match earlier_firefox ~base_path with
         | Error why -> Earlier_firefox why
         | Ok () -> started_firefox ~sw ~net ~clock ~ready_timeout_s ~base_path config)
    in
    (match firefox with
     | Ready started_here ->
       (match start_host ~sw ~base_path ~launcher config with
        | Ok () -> ()
        | Error detail ->
          Log.Server.error "browser-lane: the BiDi host did not start: %s%s" detail
            (match started_here with
             | None -> ""
             | Some started ->
               let stopped = stop_started ~clock started in
               forget ~base_path;
               " The Keeper Firefox started for it is left with no host. " ^ stop_message stopped))
     | Earlier_firefox why -> neither why
     | Undetermined detail ->
       Log.Server.error
         "browser-lane: cannot tell whether port %d answers (%s); neither the Keeper Firefox nor \
          its host is started"
         config.port detail
     | Failed (failure, stop) ->
       Log.Server.error "browser-lane: the Keeper Firefox did not start: %s%s Its output is in %s."
         (Keeper_firefox.firefox_failure_message config failure)
         (match stop with None -> "" | Some stop -> " " ^ stop_message stop)
         (Keeper_firefox.firefox_log_path ~base_path))

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
let bring_up ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~base_path (config : Browser_configuration.live_bidi) =
  match host_step ~base_path config with
  | Keeper_firefox.Launcher_not_ready missing -> neither (Keeper_firefox.launcher_missing_message missing)
  | Keeper_firefox.Host_on_another_port address ->
    neither (Keeper_firefox.host_on_another_port_message ~port:config.port address)
  | Keeper_firefox.Host_address_unknown -> neither (Keeper_firefox.host_address_unknown_message ~port:config.port)
  | Keeper_firefox.Host_running -> leave_running ~env config
  | Keeper_firefox.Start_host launcher ->
    start_both ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~base_path ~launcher config

(* A workspace that no longer asks for a Keeper Firefox has the one MASC
   started stopped, and no other process: a group is stopped only once it is
   shown to be that Firefox (RFC-browser-keeper-firefox §3.3, §3.5.4). Its
   host ends with its Firefox. *)
let stop_recorded ~env ~base_path ~why =
  match Firefox_record.read ~base_path with
  | Firefox_record.Absent -> ()
  | Firefox_record.Unreadable detail ->
    Log.Server.error
      "browser-lane: %s, and the record of the Keeper Firefox MASC started cannot be read (%s); \
       nothing is stopped"
      why detail
  | Firefox_record.Recorded entry ->
    (match recorded_firefox entry with
     | Keeper_firefox.Started_here ->
       let stopped =
         Posix_spawn_detached.stop_group_id ~clock:(Eio.Stdenv.clock env) ~grace_s:firefox_stop_grace_s
           entry.group
       in
       Log.Server.info
         "browser-lane: %s, so the Keeper Firefox MASC started on port %d (process group %d) is \
          stopped. %s"
         why entry.port entry.group (stop_message stopped);
       (* Its record goes once nothing is left that it names. *)
       if Posix_spawn_detached.group_id_has_members entry.group then
         Log.Server.warn
           "browser-lane: process group %d still has processes after SIGKILL; its record is kept"
           entry.group
       else forget ~base_path
     | Keeper_firefox.Gone -> forget ~base_path
     | Keeper_firefox.Unproven detail ->
       Log.Server.warn
         "browser-lane: %s; the Keeper Firefox MASC started on port %d is not stopped, since %s. \
          Close that Firefox if it is still open."
         why entry.port detail)

let work ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~base_path ~configuration () =
  match configuration with
  | Some { Browser_configuration.live_bidi = Some config; live_enabled = true; _ } ->
    bring_up ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~base_path config
  | Some { Browser_configuration.live_bidi = Some _; live_enabled = false; _ } ->
    stop_recorded ~env ~base_path ~why:"[browser.live] is off"
  | Some { Browser_configuration.live_bidi = None; _ } ->
    stop_recorded ~env ~base_path ~why:"runtime.toml has no [browser.live.bidi]"
  (* No runtime configuration was loaded, so what the operator asks for is
     not known, and nothing is stopped. *)
  | None -> ()

(* This fiber runs on the server's root switch, where an exception would end
   the server. One the work did not expect is logged instead, as the
   Stagehand lane does; a cancellation still ends it. *)
let start ~sw ~env ~base_path ~configuration =
  Eio.Fiber.fork ~sw (fun () ->
    try
      work ~sw ~env ~ready_timeout_s:Keeper_firefox.firefox_ready_timeout_s ~ending_host_wait_s
        ~base_path ~configuration ()
    with
    | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
    | exn ->
      Log.Server.error "browser-lane: starting the Keeper Firefox failed: %s" (Printexc.to_string exn))

module For_testing = struct
  let start ?(ending_host_wait_s = ending_host_wait_s) ~ready_timeout_s ~sw ~env ~base_path ~configuration () =
    Eio.Fiber.fork_promise ~sw (work ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~base_path ~configuration)
end
