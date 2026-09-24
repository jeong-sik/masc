(* HIGH-RISK-UNREVIEWED: starts and stops a browser with a debugging socket
   and an owner-only profile that may hold an operator's logins
   (RFC-browser-lane-stagehand §4). *)
module Process = Browser_chromium_process
module Session = Browser_stagehand_session

(* The port file appeared 0.3–5.7 s after launch in the runs of 2026-09-24
   (Chrome Canary 156, M3 Max), the first cold launch slowest. Twenty seconds
   leaves room for a cold disk. *)
let devtools_port_timeout_s = 20.
let devtools_port_poll_s = 0.1

(* The longest CDP command is the readiness wait, which took under 2 s after
   the port appeared in those runs. A command unanswered for 30 s means the
   browser is wedged. *)
let cdp_command_deadline_s = 30.

(* The extension's service worker appeared within half a second of loading
   in those runs. *)
let service_worker_wait_s = 20.

(* stagehand.init answered 0.6 s after the marker on Chrome Canary 156 and
   5.1 s on a cold Chrome for Testing 154 (2026-09-24). Its JSON-RPC reply has
   no deadline of its own, so a runtime that never answers would leave the
   session opening for good. *)
let init_answer_s = 30.

(* Attach is bounded by the waits it is made of: the service worker, the
   longest CDP command (the readiness wait), and the init answer. *)
let attach_deadline_s = service_worker_wait_s +. cdp_command_deadline_s +. init_answer_s

(* ws-direct's own default. A screenshot of a long page is the largest
   frame the connection carries. *)
let max_message_bytes = 64 * 1024 * 1024

(* A stopped browser gets this long to exit before its group is killed. *)
let stop_grace_s = 5.
let owner_only = 0o700

type t = { session : Session.t; pid : int }

let session t = t.session
let pid t = t.pid

let failure_message = function
  | Browser_cdp.Command_rejected { code; message } -> Printf.sprintf "rejected (%d): %s" code message
  | Browser_cdp.Connection_lost reason -> "connection lost: " ^ reason
;;

let call_failure_message = function
  | Session.Not_attached -> "not attached"
  | Session.Detached -> "the service worker went away"
  | Session.Connection_gone reason -> "the connection ended: " ^ reason
  | Session.Abandoned_call_pending -> "an abandoned call has not answered yet"
  | Session.Not_delivered detail -> "not delivered: " ^ detail
  | Session.Rejected { code; message } -> Printf.sprintf "the extension refused (%d): %s" code message
  | Session.Lost detail -> "lost: " ^ detail
;;

let attach_error_message = function
  | Session.Extension_path detail -> "the extension directory has no real path: " ^ detail
  | Session.Load_rejected failure -> "Chrome did not load the extension: " ^ failure_message failure
  | Session.Extension_id_mismatch { expected; loaded } ->
    Printf.sprintf "Chrome loaded the extension as %s, not %s, so its origin is not the allowed one" loaded expected
  | Session.Service_worker_absent -> "the extension's service worker never appeared"
  | Session.Malformed_reply { method_; detail } -> Printf.sprintf "%s answered without what attach needs: %s" method_ detail
  | Session.Runtime_marker detail -> "the Stagehand runtime marker is unreadable: " ^ detail
  | Session.Runtime_incompatible { found; supported } ->
    Printf.sprintf "the Stagehand runtime speaks protocol %s; masc speaks major %d" found supported
  | Session.Init_failed failure -> "stagehand.init failed: " ^ call_failure_message failure
  | Session.Cdp failure -> "a CDP command failed: " ^ failure_message failure
;;

let process_command pid =
  match Process_eio.run_argv_with_status [ "ps"; "-p"; string_of_int pid; "-o"; "command=" ] with
  | Unix.WEXITED 0, output -> (match String.trim output with "" -> None | command -> Some command)
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ -> None
;;

let stop_left_behind ~masc_root =
  let record_path = Process.owner_record_path ~masc_root in
  if Sys.file_exists record_path then begin
    (match Safe_ops.read_file_safe record_path with
     | Error detail -> Log.Server.warn "browser-lane: stagehand record %s unreadable: %s" record_path detail
     | Ok text ->
       (match Process.owner_of_string text with
        | Error detail -> Log.Server.warn "browser-lane: stagehand record %s is malformed: %s" record_path detail
        | Ok owner ->
          (match Process.leftover owner ~command:(process_command owner.pid) with
           | Process.Not_the_recorded_browser -> ()
           | Process.Stop_recorded_browser pgid ->
             Log.Server.warn "browser-lane: stopping Chromium pid %d left by a server that did not stop it" pgid;
             Eio_unix.run_in_systhread (fun () ->
               Process_eio_detached.tree_kill ~pgid ~signal:Sys.sigterm ~grace_sec:stop_grace_s))));
    Safe_ops.remove_file_logged ~context:"browser-lane stagehand record" record_path
  end
;;

(* For the three exceptions a file or process step raises: [Eio.Io],
   [Unix.Unix_error] and [Sys_error]. *)
let io_error what exn = Error (Printf.sprintf "%s: %s" what (Printexc.to_string exn))

(* An operator-owned profile keeps its logins; only the port file of an
   earlier run is removed, so the new port is not confused with it. The
   server's own profile starts empty. Either way it is made owner-only: it
   holds cookies. *)
let prepare_profile ~masc_root (config : Browser_configuration.stagehand) =
  let profile, fresh =
    match config.profile with
    | Some profile -> profile, false
    | None -> Process.server_profile ~masc_root, true
  in
  match
    if fresh then Fs_compat.remove_tree profile;
    Fs_compat.mkdir_p profile;
    Unix.chmod profile owner_only;
    Fs_compat.remove_tree (Filename.concat profile Process.devtools_port_file)
  with
  | () -> Ok profile
  | exception ((Eio.Io _ | Unix.Unix_error _ | Sys_error _) as exn) -> io_error ("cannot prepare the profile " ^ profile) exn
;;

let await_devtools_endpoint ~clock ~profile ~process =
  let file = Filename.concat profile Process.devtools_port_file in
  let deadline = Monotonic_deadline.after ~seconds:devtools_port_timeout_s in
  let rec poll () =
    (* Chrome may be caught mid-write, so an unreadable file is read again. *)
    match Result.bind (Safe_ops.read_file_safe file) Process.devtools_endpoint_of_string with
    | Ok endpoint -> Ok endpoint
    | Error _ when Monotonic_deadline.passed deadline ->
      Error (Printf.sprintf "Chromium wrote no %s within %.0f s" file devtools_port_timeout_s)
    | Error _ ->
      Eio.Time.sleep clock devtools_port_poll_s;
      poll ()
  in
  Eio.Fiber.first poll (fun () ->
    let status = Eio.Process.await process in
    Error (Format.asprintf "Chromium exited before writing its debugging port (%a)" Eio.Process.pp_status status))
;;

let ( let* ) = Result.bind

let open_ ~sw ~env ~masc_root ~(config : Browser_configuration.stagehand) ~headless ~model ~log =
  let clock = Eio.Stdenv.clock env in
  let lane = Filename.concat masc_root "browser-lane" in
  let record_path = Process.owner_record_path ~masc_root in
  let* extension_dir =
    match Unix.realpath config.extension with
    | path -> Ok path
    | exception (Unix.Unix_error _ as exn) -> io_error "the Stagehand extension directory" exn
  in
  let extension_id = Browser_stagehand_wire.extension_id_of_real_path extension_dir in
  let* profile = prepare_profile ~masc_root config in
  (* Registered before the spawn, so it runs after the spawn's own release
     has stopped the browser's process group. *)
  Eio.Switch.on_release sw (fun () ->
    if Sys.file_exists record_path then Safe_ops.remove_file_logged ~context:"browser-lane stagehand record" record_path);
  let* process =
    match
      Fs_compat.mkdir_p lane;
      let output =
        Eio.Path.open_out ~sw ~create:(`Or_truncate 0o600) Eio.Path.(Eio.Stdenv.fs env / Filename.concat lane "chromium.log")
      in
      Eio.Process.spawn ~sw
        (Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds:stop_grace_s)
        ~stdout:output ~stderr:output
        (Process.argv ~chrome:config.chrome ~profile ~extension_id ~headless)
    with
    | process -> Ok process
    | exception ((Eio.Io _ | Unix.Unix_error _ | Sys_error _) as exn) -> io_error "Chromium did not start" exn
  in
  let pid = Eio.Process.pid process in
  let* () =
    Result.map_error
      (fun detail -> Printf.sprintf "cannot record Chromium pid %d in %s: %s" pid record_path detail)
      (Fs_compat.save_file_atomic record_path
         (Process.owner_to_string { Process.pid; chrome = config.chrome; profile }))
  in
  let* port, path = await_devtools_endpoint ~clock ~profile ~process in
  let url = Process.browser_ws_url ~port ~path in
  let session = Session.create ~sw ~clock ~worker_wait_s:service_worker_wait_s ~model ~log in
  let* cdp =
    Browser_cdp.connect ~sw ~net:(Eio.Stdenv.net env) ~clock ~url ~max_message:max_message_bytes
      ~command_deadline_s:cdp_command_deadline_s ~on_event:(Session.on_cdp_event session)
  in
  let* init =
    Watched_work.run
      ~watcher:(fun () ->
        Eio.Time.sleep clock attach_deadline_s;
        Error (Printf.sprintf "Stagehand did not finish attaching within %.0f s" attach_deadline_s))
      (fun () -> Result.map_error attach_error_message (Session.attach session cdp ~extension_dir ~browser_cdp_url:url))
  in
  Ok ({ session; pid }, init)
;;
