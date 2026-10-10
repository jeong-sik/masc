module Keeper_firefox = Browser_keeper_firefox
module Starter = Browser_keeper_firefox_starter
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
  | Posix_spawn_detached.Ended_on_term -> "It ended on SIGTERM."
  | Posix_spawn_detached.Killed_after_grace ->
    Printf.sprintf "It got SIGKILL, %.0f s after SIGTERM." firefox_stop_grace_s
  | Posix_spawn_detached.Left_alone ->
    "It was not signalled: its process group number no longer names it."

(* The record tells the process started here from a later one given its
   number by when it started (RFC-browser-keeper-firefox §3.4), read before
   this server could reap it. *)
let running_leader (firefox : Posix_spawn_detached.t) =
  match firefox.started with
  | Some started -> Firefox_record.Started_at started
  | None -> Firefox_record.Start_unreadable

let no_process pid =
  match Unix.kill pid 0 with
  | () -> false
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> true
  | exception Unix.Unix_error (Unix.EPERM, _, _) -> false

(* The number still names the group [leader] started: that process runs
   with the start recorded, or no process has the number. No new process is
   given the number of a group that still exists (POSIX fork(2)), so members
   left without their leader are still that group's. *)
let same_group ~(leader : Firefox_record.leader) group () =
  match leader, Posix_spawn_detached.process_start group with
  | Firefox_record.Started_at recorded, Some now -> String.equal recorded now
  | Firefox_record.Start_unreadable, Some _ -> false
  | (Firefox_record.Started_at _ | Firefox_record.Start_unreadable), None -> no_process group

(* Only the group of a Firefox started here is signalled; a Firefox that
   was running already is never touched. Until this server reaps the process
   it started, that number is its own. *)
let stop_started ~clock ~leader (firefox : Posix_spawn_detached.t) =
  Posix_spawn_detached.stop_group ~clock ~grace_s:firefox_stop_grace_s
    ~same_group:(fun () ->
      Option.is_none (Eio.Promise.peek firefox.exited) || same_group ~leader firefox.pid ())
    firefox.pid

let forget ~base_path =
  match Firefox_record.remove ~base_path with
  | Ok () -> ()
  | Error detail -> Log.Server.error "browser-lane: the Keeper Firefox record is not removed: %s" detail

(* A record goes once nothing is left that it names: a group that outlived
   its stop stays named, so no second Firefox is started over it. *)
let forget_once_empty ~base_path group =
  if Posix_spawn_detached.group_id_has_members group then
    Log.Server.warn
      "browser-lane: process group %d still has processes after its stop; the Keeper Firefox record \
       is kept"
      group
  else forget ~base_path

let recorded_firefox (entry : Firefox_record.entry) =
  Keeper_firefox.recorded_firefox entry
    ~leader_started:(Posix_spawn_detached.process_start entry.group)
    ~leader_group:(Posix_spawn_detached.group_of_pid entry.group)
    ~group_has_members:(Posix_spawn_detached.group_id_has_members entry.group)

(* For a group {!recorded_firefox} found [Started_here]: each signal goes
   only while its number still names that group. *)
let stop_recorded_group ~clock (entry : Firefox_record.entry) =
  Posix_spawn_detached.stop_group ~clock ~grace_s:firefox_stop_grace_s
    ~same_group:(same_group ~leader:entry.leader entry.group) entry.group

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
let record_started ~clock ~base_path (config : Browser_configuration.live_bidi) ~leader firefox =
  let entry =
    { Firefox_record.group = firefox.Posix_spawn_detached.pid; leader
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
    ~leader (firefox : Posix_spawn_detached.t) =
  let deadline = Monotonic_deadline.after ~seconds:ready_timeout_s in
  let rec await () =
    match port_state ~net ~clock ~port:config.port with
    | Answers ->
      (match Eio.Promise.peek firefox.exited with
       | None -> Ok First_process
       | Some _ when Posix_spawn_detached.group_has_members firefox -> Ok Its_group
       | Some _ -> forget ~base_path; Ok Not_started_here)
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
      let stopped = stop_started ~clock ~leader firefox in
      forget_once_empty ~base_path firefox.pid;
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
        let leader = running_leader firefox in
        (match record_started ~clock ~base_path config ~leader firefox with
         | Error detail ->
           Error (Keeper_firefox.Not_recorded detail, Some (stop_started ~clock ~leader firefox))
         | Ok () -> Ok (firefox, leader)))
  in
  match recorded with
  | Error failure -> Error failure
  | Ok started ->
    let firefox, leader = started in
    Result.map (fun how -> started, how) (await_port ~net ~clock ~ready_timeout_s ~base_path config ~leader firefox)

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
    Ok host

let answering_port_line =
  "if that is not this profile's Firefox, the host's record says why it could not attach"

(* [Ready (Some (firefox, leader))]: the port answers from the Firefox
   started here, which is stopped if its host cannot be started. *)
type firefox =
  | Ready of (Posix_spawn_detached.t * Firefox_record.leader) option
  | Undetermined of string
  | Earlier_firefox of string
  | Failed of Keeper_firefox.firefox_failure * Posix_spawn_detached.stopped option
  | Still_held of string
      (** The Keeper Firefox MASC started, stopped to be started again, is not
          shown to have let go of its group or its port; this says which. *)

(* What one start did. The server log says it as it happens; a Keeper's
   request that asked for the start is answered from it
   (RFC-browser-keeper-firefox §3.5). *)
(* [firefox]: the Keeper Firefox started for this host, if one was. *)
type brought_up =
  | Host_started of
      { host : Posix_spawn_detached.t; firefox : (Posix_spawn_detached.t * Firefox_record.leader) option }
  | Host_running  (** A host for this port runs and the port answers: nothing was started. *)
  | Not_started of Starter.not_attached

(* Why nothing (more) was started, by what a retry of the request does:
   nothing changes until the operator acts, or a retry starts again. *)
let operator why = Starter.Operator_needed why
let attempt why = Starter.Start_failed why

let not_attached_message = function
  | Starter.Operator_needed why | Starter.Start_failed why | Starter.Not_listed_in_time why -> why

let not_started reason =
  Log.Server.error "browser-lane: %s" (not_attached_message reason);
  Not_started reason

let neither cause why = not_started (cause ("neither the Keeper Firefox nor its BiDi host is started: " ^ why))

let started_firefox ~sw ~net ~clock ~ready_timeout_s ~base_path (config : Browser_configuration.live_bidi) =
  match start_firefox ~sw ~net ~clock ~ready_timeout_s ~base_path config with
  | Ok (((started : Posix_spawn_detached.t), _) as here, First_process) ->
    Log.Server.info "browser-lane: started the Keeper Firefox (pid %d) on %s with profile %s"
      started.pid (Keeper_firefox.bidi_url ~port:config.port) config.profile;
    Ready (Some here)
  | Ok (((started : Posix_spawn_detached.t), _) as here, Its_group) ->
    Log.Server.info
      "browser-lane: started the Keeper Firefox (process group %d; its first process ended \
       before the port answered) on %s with profile %s"
      started.pid (Keeper_firefox.bidi_url ~port:config.port) config.profile;
    Ready (Some here)
  | Ok (_, Not_started_here) ->
    Log.Server.info
      "browser-lane: the Keeper Firefox started here ended with nothing left in its process \
       group, and port %d answers from another process; %s"
      config.port answering_port_line;
    Ready None
  | Error (failure, stop) -> Failed (failure, stop)

(* The Firefox on the port holds the session the last host left there, or
   refused that host one because it held one, as of [since], when that host
   ended; it refuses a host started now as well (RFC-browser-keeper-firefox
   §3.5.4). Only the Keeper Firefox MASC started is restarted for it. *)
let restart_target ~base_path (config : Browser_configuration.live_bidi) ~since =
  match Firefox_record.read ~base_path with
  | Firefox_record.Absent -> Error "MASC did not start it"
  | Firefox_record.Unreadable detail ->
    Error
      (Printf.sprintf "the record of the Keeper Firefox MASC started, %s, cannot be read (%s)"
         (Firefox_record.record_path ~base_path) detail)
  | Firefox_record.Recorded entry ->
    (match Keeper_firefox.restart_for_held_session entry ~port:config.port ~since (recorded_firefox entry) with
     | Keeper_firefox.Restart -> Ok entry
     | Keeper_firefox.Not_restarted why -> Error why)

(* On Darwin a group reads empty once every member is a zombie or exiting
   (Process_group_members), and an exiting process may not have closed its
   descriptors yet: the listening port and the profile lock among them. So
   the port of a Firefox stopped to be started again is waited for, this
   long at most. Not measured; the wait ends at the first refused connect. *)
let stopped_port_wait_s = 5.

let await_port_closed ~net ~clock ~port =
  let deadline = Monotonic_deadline.after ~seconds:stopped_port_wait_s in
  let rec wait () =
    match port_state ~net ~clock ~port with
    | Nothing_listens -> Ok ()
    | Answers when Monotonic_deadline.passed deadline ->
      Error (Printf.sprintf "port %d still answers %.0f s after its group was empty" port stopped_port_wait_s)
    | Unknown detail when Monotonic_deadline.passed deadline ->
      Error (Printf.sprintf "whether port %d still answers cannot be told: %s" port detail)
    | Answers | Unknown _ -> Eio.Time.sleep clock group_poll_s; wait ()
  in
  wait ()

let fresh_firefox ~sw ~net ~clock ~ready_timeout_s ~base_path (config : Browser_configuration.live_bidi) =
  match earlier_firefox ~base_path with
  | Error why -> Earlier_firefox why
  | Ok () -> started_firefox ~sw ~net ~clock ~ready_timeout_s ~base_path config

(* Its profile is kept, so the operator's logins stay. A group that keeps
   processes after the stop keeps its record. *)
let restarted ~sw ~net ~clock ~ready_timeout_s ~base_path (config : Browser_configuration.live_bidi)
    (entry : Firefox_record.entry) =
  let stopped = stop_recorded_group ~clock entry in
  Log.Server.info
    "browser-lane: the last BiDi host ended with a session held in the Keeper Firefox MASC started \
     on port %d (process group %d), which refuses the next host while it holds it, so that Firefox \
     is stopped, to be started again. %s"
    config.port entry.group (stop_message stopped);
  let still_held why =
    Still_held
      (Printf.sprintf "the Keeper Firefox MASC started on port %d was stopped to be started again, and %s. %s"
         config.port why (stop_message stopped)) in
  if Posix_spawn_detached.group_id_has_members entry.group then
    still_held (Printf.sprintf "process group %d still has processes" entry.group)
  else (
    forget ~base_path;
    match await_port_closed ~net ~clock ~port:config.port with
    | Error why -> still_held why
    | Ok () -> fresh_firefox ~sw ~net ~clock ~ready_timeout_s ~base_path config)

(* [held]: when the last host ended with a session held in the Firefox on
   the port. A Firefox that is not restarted for it is left running, and a
   host is started for it all the same: that Firefox may have started after
   the record was written, and a host it refuses writes so. *)
let firefox_for ~sw ~net ~clock ~ready_timeout_s ~base_path ~held (config : Browser_configuration.live_bidi) =
  match port_state ~net ~clock ~port:config.port, held with
  | Answers, None ->
    Log.Server.info "browser-lane: port %d already answers, so no Keeper Firefox is started; %s"
      config.port answering_port_line;
    Ready None
  | Answers, Some since ->
    (match restart_target ~base_path config ~since with
     | Error why ->
       Log.Server.warn
         "browser-lane: port %d answers, and the last BiDi host ended with a session held in the \
          Firefox there, which refuses the next host while it holds it. That Firefox is not \
          restarted, since %s. A host is started for it all the same; if that host is refused too, \
          close that Firefox."
         config.port why;
       Ready None
     | Ok entry -> restarted ~sw ~net ~clock ~ready_timeout_s ~base_path config entry)
  | Unknown detail, (Some _ | None) -> Undetermined detail
  | Nothing_listens, (Some _ | None) -> fresh_firefox ~sw ~net ~clock ~ready_timeout_s ~base_path config

let host_report ~base_path = Host_status.report (Host_status.observe ~base_path)

let start_both ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~base_path ~launcher
    (config : Browser_configuration.live_bidi) =
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  match await_free_lock ~clock ~wait_s:ending_host_wait_s ~base_path with
  | Error why -> neither attempt why
  | Ok () ->
    (* Read once the lock is free: a host that ended or started during the
       wait is the last host now. *)
    let held = Keeper_firefox.session_held_since ~port:config.port (host_report ~base_path) in
    let firefox = firefox_for ~sw ~net ~clock ~ready_timeout_s ~base_path ~held config in
    (match firefox with
     | Ready started_here ->
       (match start_host ~sw ~base_path ~launcher config with
        | Ok host -> Host_started { host; firefox = started_here }
        | Error detail ->
          not_started
            (attempt @@ Printf.sprintf "the BiDi host did not start: %s%s" detail
               (match started_here with
                | None -> ""
                | Some (started, leader) ->
                  let stopped = stop_started ~clock ~leader started in
                  forget_once_empty ~base_path started.pid;
                  " The Keeper Firefox started for it is left with no host. " ^ stop_message stopped)))
     | Earlier_firefox why -> neither operator why
     | Still_held why -> neither attempt why
     | Undetermined detail ->
       not_started
         (attempt @@ Printf.sprintf
            "cannot tell whether port %d answers (%s); neither the Keeper Firefox nor its host is \
             started"
            config.port detail)
     | Failed (failure, stop) ->
       not_started
         (attempt @@ Printf.sprintf "the Keeper Firefox did not start: %s%s Its output is in %s."
            (Keeper_firefox.firefox_failure_message config failure)
            (match stop with None -> "" | Some stop -> " " ^ stop_message stop)
            (Keeper_firefox.firefox_log_path ~base_path)))

(* The host holding the lock attached to its Firefox when it started and
   does not attach again, so a Firefox started now would have no host. *)
let leave_running ~env (config : Browser_configuration.live_bidi) =
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  match port_state ~net ~clock ~port:config.port with
  | Answers ->
    Log.Server.info "browser-lane: a BiDi host for port %d is running and the port answers; nothing \
                     is started"
      config.port;
    Host_running
  | Nothing_listens ->
    not_started
      (attempt @@ Printf.sprintf
         "a BiDi host for port %d holds this workspace while nothing answers on that port; nothing \
          is started. That host ends with its Firefox gone, and the next start, at a server start \
          or for a Keeper's request, opens both."
         config.port)
  | Unknown detail ->
    not_started
      (attempt @@ Printf.sprintf
         "a BiDi host for port %d is running, and whether the port answers cannot be told (%s); \
          nothing is started"
         config.port detail)

(* Firefox opens a port any local process may drive (RFC-browser-keeper-firefox
   §5), so it is started only when a host is started with it. *)
let bring_up ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~base_path (config : Browser_configuration.live_bidi) =
  match Keeper_firefox.host_step ~port:config.port (host_report ~base_path) with
  | Keeper_firefox.Launcher_not_ready missing -> neither operator (Keeper_firefox.launcher_missing_message missing)
  | Keeper_firefox.Host_on_another_port address ->
    neither operator (Keeper_firefox.host_on_another_port_message ~port:config.port address)
  | Keeper_firefox.Host_address_unknown ->
    neither operator (Keeper_firefox.host_address_unknown_message ~port:config.port)
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
       let stopped = stop_recorded_group ~clock:(Eio.Stdenv.clock env) entry in
       Log.Server.info
         "browser-lane: %s, so the Keeper Firefox MASC started on port %d (process group %d) is \
          stopped. %s"
         why entry.port entry.group (stop_message stopped);
       forget_once_empty ~base_path entry.group
     | Keeper_firefox.Gone -> forget ~base_path
     | Keeper_firefox.Unproven detail ->
       Log.Server.warn
         "browser-lane: %s; the Keeper Firefox MASC started on port %d is not stopped, since %s. \
          Close that Firefox if it is still open."
         why entry.port detail)

(* [Some]: what the start did, for the requests that came while it ran.
   [None]: the workspace does not ask for a Keeper Firefox. *)
let boot_start ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~base_path configuration =
  match configuration with
  | Some { Browser_configuration.live_bidi = Some config; live_enabled = true; _ } ->
    Some (bring_up ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~base_path config)
  | Some { Browser_configuration.live_bidi = Some _; live_enabled = false; _ } ->
    stop_recorded ~env ~base_path ~why:"[browser.live] is off";
    None
  | Some { Browser_configuration.live_bidi = None; _ } ->
    stop_recorded ~env ~base_path ~why:"runtime.toml has no [browser.live.bidi]";
    None
  (* No runtime configuration was loaded, so what the operator asks for is
     not known, and nothing is stopped. *)
  | None -> None

let work ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~base_path ~configuration () =
  ignore
    (boot_start ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~base_path configuration : brought_up option)

(* How long a start has to show its BiDi connection in the server's list:
   from Firefox's start to the host's first poll took 1.75-5.68 s
   (2026-10-10, 14 runs, Firefox 157.0.1 headless, M3 Max under load
   110-150); a windowed Firefox on a quiet machine is not slower than that by
   this much. *)
let host_attach_wait_s = 15.
let attach_poll_s = 0.2

let listed_bidi_client () =
  List.find_opt
    (fun (info : Browser_lane.client_info) ->
      match info.transport with
      | Browser_lane.Webdriver_bidi -> true
      | Browser_lane.Web_extension -> false)
    (Browser_lane.active_clients ())

(* A host that ends before its connection is listed (its Firefox refused
   the session, or ran another profile) leaves the Firefox started for it
   with no host, and its port open: that Firefox is stopped. *)
let host_ended ~clock ~base_path (host : Posix_spawn_detached.t) firefox =
  let left = match firefox with
    | None -> ""
    | Some ((started : Posix_spawn_detached.t), leader) ->
      let stopped = stop_started ~clock ~leader started in
      forget_once_empty ~base_path started.pid;
      " The Keeper Firefox started for it is left with no host. " ^ stop_message stopped in
  let ended_before = Printf.sprintf "the BiDi host (pid %d) ended before its connection was listed" host.pid in
  (* Its own record says why. A host that met another profile's Firefox on
     the port meets it again on every retry, until the operator quits that
     Firefox. *)
  let reason =
    match Browser_bidi_host_record.observe ~base_path with
    | Browser_bidi_host_record.Ended
        (entry, { because = Browser_bidi_host_record.Profile_not_kept { expected; found }; _ })
      when entry.pid = host.pid ->
      let holder =
        match found with
        | Some found ->
          Printf.sprintf
            "the Firefox on that port runs the profile %s, not %s, the profile kept for the Keeper. \
             Another Firefox holds that port"
            found expected
        | None ->
          Printf.sprintf
            "the Firefox on that port did not say which profile it runs, so it is not taken to run \
             %s, the profile kept for the Keeper. Unless it is the Keeper Firefox, another Firefox \
             holds that port"
            expected
      in
      operator
        (Printf.sprintf "%s: %s; the operator quits it, and the next start opens the Keeper Firefox.%s"
           ended_before holder left)
    | Browser_bidi_host_record.Ended (_, { because = Browser_bidi_host_record.(Profile_not_kept _ | Reason_only); _ })
    | Browser_bidi_host_record.Never_started
    | Browser_bidi_host_record.Record_missing_but_locked
    | Browser_bidi_host_record.Running _
    | Browser_bidi_host_record.Died _
    | Browser_bidi_host_record.Unreadable _ ->
      attempt
        (Printf.sprintf "%s; %s says why.%s" ended_before (Keeper_firefox.host_log_path ~base_path) left)
  in
  ignore (not_started reason : brought_up);
  reason

(* [host]: the host this start started, watched while its connection is
   awaited, with the Firefox started for it. *)
let await_bidi_client ~clock ~seconds ~base_path ~started ~host =
  let deadline = Monotonic_deadline.after ~seconds in
  let rec wait () =
    match listed_bidi_client (), host with
    | Some client, _ -> Starter.Attached { client; started }
    | None, Some ((host : Posix_spawn_detached.t), firefox) when Option.is_some (Eio.Promise.peek host.exited) ->
      Starter.Not_attached (host_ended ~clock ~base_path host firefox)
    | None, (Some _ | None) when Monotonic_deadline.passed deadline ->
      Starter.Not_attached
        (Starter.Not_listed_in_time
           (Printf.sprintf "no BiDi connection was listed within %.0f s; %s says why" seconds
              (Keeper_firefox.host_log_path ~base_path)))
    | None, (Some _ | None) -> Time_compat.sleep attach_poll_s; wait ()
  in
  wait ()

(* A start ends once its connection is listed, its host has ended, or the
   wait for it is over: a host that has just been started holds neither the
   lock nor a record yet, so a start in between would start a second host. *)
let attached_after ~clock ~host_attach_wait_s ~base_path = function
  | Not_started reason -> Starter.Not_attached reason
  | Host_started { host; firefox } ->
    let started = match firefox with Some _ -> Starter.Firefox_and_host | None -> Starter.Host_only in
    await_bidi_client ~clock ~seconds:host_attach_wait_s ~base_path ~started ~host:(Some (host, firefox))
  | Host_running ->
    await_bidi_client ~clock ~seconds:host_attach_wait_s ~base_path ~started:Starter.Nothing ~host:None

(* A Keeper's request starts nothing in a workspace that does not ask for a
   Keeper Firefox, and stops nothing either: that is the server start's. *)
let for_request ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~host_attach_wait_s ~base_path configuration =
  match configuration with
  | Some { Browser_configuration.live_bidi = Some config; live_enabled = true; _ } ->
    attached_after ~clock:(Eio.Stdenv.clock env) ~host_attach_wait_s ~base_path
      (bring_up ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~base_path config)
  | Some { Browser_configuration.live_bidi = Some _; live_enabled = false; _ }
  | Some { Browser_configuration.live_bidi = None; _ }
  | None -> Starter.Not_asked_for

(* An exception the work did not expect is logged, as the Stagehand lane
   does, and does not end the fiber; a cancellation does. *)
let unexpected exn =
  let reason = attempt (Printf.sprintf "starting the Keeper Firefox failed: %s" (Printexc.to_string exn)) in
  ignore (not_started reason : brought_up);
  reason

let stopping_answer = Starter.Not_attached (Starter.Start_failed "the server is stopping")

(* Starts run one at a time, each with its wait for the connection, in one
   fiber on the server's switch: a request from another domain cannot start
   a process on that switch, and requests that come while a start runs are
   answered with that start (RFC-browser-keeper-firefox §3.5 step 3). The
   server start's own start, run beside it, answers the requests that come
   meanwhile. *)
let serve ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~host_attach_wait_s ~base_path ~configuration
    ~boot requests =
  let rec waiting asked =
    match Eio.Stream.take_nonblocking requests with
    | Some resolver -> waiting (resolver :: asked)
    | None -> asked
  in
  let answer_all first answer = List.iter (fun resolver -> Eio.Promise.resolve resolver answer) (waiting first) in
  let guarded run =
    match run () with
    | answer -> answer
    | exception (Eio.Cancel.Cancelled _ as cancelled) ->
      answer_all [] stopping_answer;
      raise cancelled
    | exception exn -> Starter.Not_attached (unexpected exn)
  in
  (match Eio.Promise.await boot with
   | None -> ()
   | Some brought ->
     answer_all []
       (guarded (fun () -> attached_after ~clock:(Eio.Stdenv.clock env) ~host_attach_wait_s ~base_path brought)));
  let rec loop () =
    let first = Eio.Stream.take requests in
    let answer =
      guarded (fun () ->
        for_request ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~host_attach_wait_s ~base_path
          (configuration ()))
    in
    answer_all [ first ] answer;
    loop ()
  in
  loop ()

(* A request from any fiber, on any domain: it hands the start to the fiber
   that serves starts and waits for its answer. A server that is stopping
   answers at once. *)
let request requests ~stopping () =
  match listed_bidi_client () with
  | Some client -> Starter.Attached { client; started = Starter.Nothing }
  | None ->
    let answer, resolver = Eio.Promise.create () in
    Eio.Stream.add requests resolver;
    Eio.Fiber.first
      (fun () -> Eio.Promise.await answer)
      (fun () -> Eio.Promise.await stopping; stopping_answer)

(* The server start's own start runs in a fiber of its own, as before: a
   server that stops waits for it. The fiber that serves requests is a
   daemon: it ends with the server. *)
let serving ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~host_attach_wait_s ~base_path ~configuration
    ~boot_start_wanted =
  let requests = Eio.Stream.create max_int in
  let stopping, stop = Eio.Promise.create () in
  Eio.Switch.on_release sw (fun () -> Eio.Promise.resolve stop ());
  let boot, booted = Eio.Promise.create () in
  if boot_start_wanted then
    Eio.Fiber.fork ~sw (fun () ->
      let brought =
        match
          boot_start ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~base_path (configuration ())
        with
        | brought -> brought
        | exception (Eio.Cancel.Cancelled _ as cancelled) -> Eio.Promise.resolve booted None; raise cancelled
        | exception exn -> Some (Not_started (unexpected exn))
      in
      Eio.Promise.resolve booted brought)
  else Eio.Promise.resolve booted None;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    serve ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~host_attach_wait_s ~base_path ~configuration
      ~boot requests);
  request requests ~stopping

let start ~sw ~env ~base_path ~configuration =
  let request =
    serving ~sw ~env ~ready_timeout_s:Keeper_firefox.firefox_ready_timeout_s ~ending_host_wait_s
      ~host_attach_wait_s ~base_path ~configuration ~boot_start_wanted:true
  in
  Starter.install (Some request);
  Eio.Switch.on_release sw (fun () -> Starter.install None)

module For_testing = struct
  let start ?(ending_host_wait_s = ending_host_wait_s) ~ready_timeout_s ~sw ~env ~base_path ~configuration () =
    Eio.Fiber.fork_promise ~sw (work ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~base_path ~configuration)

  let serve ?(ending_host_wait_s = ending_host_wait_s) ?(boot = false) ~ready_timeout_s ~host_attach_wait_s ~sw
      ~env ~base_path ~configuration () =
    serving ~sw ~env ~ready_timeout_s ~ending_host_wait_s ~host_attach_wait_s ~base_path ~configuration
      ~boot_start_wanted:boot
end
