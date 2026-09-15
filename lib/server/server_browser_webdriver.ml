(* Browser policy and session ownership run in OCaml. geckodriver is the
   Firefox vendor's WebDriver remote end. The server starts its own driver,
   because a remote end holds one session and a driver that outlives the server
   keeps a session nobody can close (see Browser_driver_process). *)
let configured_browser () =
  let resolution = Config_dir_resolver.resolve () in
  let path = Filename.concat resolution.Config_dir_resolver.config_root.path
      Config_dir_resolver.runtime_toml_filename in
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Browser_configuration.Disabled
  | exception Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)
  | _ ->
    match Safe_ops.read_file_safe path with
    | Error detail -> Error detail
    | Ok text ->
      match Otoml.Parser.from_string_result text with
      | Error detail -> Error detail
      | Ok toml -> Browser_configuration.parse toml

let request ~pool ~clock ~endpoint ~method_ ~path ~body =
  match Masc_http_client.Pool.request pool ~clock ~timeout_seconds:60.
    ~method_ ~url:(endpoint ^ path)
    ~headers:["Content-Type", "application/json"]
    ?body:(Option.map Yojson.Safe.to_string body) () with
  | Error detail -> Error (Browser_webdriver.Transport detail)
  | Ok response -> Browser_webdriver.decode_response ~status:response.status response.body

let close_with_fresh_pool ~env ~endpoint driver =
  let clock = Eio.Stdenv.clock env in
  let result, finished = Eio.Promise.create () in
  (* The root switch is already releasing its sockets. This worker owns a
     fresh switch; after DELETE finishes, [first] cancels its pool's eviction
     fiber and releases all connections before returning the result. *)
  Eio.Fiber.first
    (fun () ->
      Eio.Switch.run (fun sw ->
        let pool = Masc_http_client.Pool.create ~sw ~env () in
        let outcome = Browser_webdriver.close driver
            ~request:(request ~pool ~clock ~endpoint) in
        Eio.Promise.resolve finished outcome;
        Eio.Fiber.await_cancel ()))
    (fun () -> Eio.Promise.await result)

(* geckodriver answers /status within 1.5 s of exec on the machine this was
   measured on (2026-09-15, M3 Max); ten seconds leaves room for a cold disk. *)
let driver_ready_timeout_s = 10.
let driver_ready_poll_s = 0.1
(* A stopped driver waits for its browser to quit. The session is closed first,
   so the browser is already leaving; five seconds bounds a browser that does
   not, after which the whole process group is killed. *)
let driver_stop_grace_s = 5.

let process_command pid =
  match Process_eio.run_argv_with_status [ "ps"; "-p"; string_of_int pid; "-o"; "command=" ] with
  | Unix.WEXITED 0, output ->
    (match String.trim output with "" -> None | command -> Some command)
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ -> None

(* The previous server on this workspace died before its release stopped its
   driver. That driver still holds its session and its browser, so it is
   stopped before a new one starts. The record is removed either way: it names
   a process that is now gone or was never the driver. *)
let stop_driver_left_behind ~record_path =
  if Sys.file_exists record_path then begin
    (match Safe_ops.read_file_safe record_path with
     | Error detail ->
       Log.Server.warn "browser-lane: driver record %s unreadable: %s" record_path detail
     | Ok text ->
       match Browser_driver_process.owner_of_string text with
       | Error detail ->
         Log.Server.warn "browser-lane: driver record %s is malformed: %s" record_path detail
       | Ok owner ->
         match Browser_driver_process.leftover owner ~command:(process_command owner.pid) with
         | Browser_driver_process.Not_the_recorded_driver -> ()
         | Browser_driver_process.Stop_recorded_driver pgid ->
           Log.Server.warn
             "browser-lane: stopping geckodriver pid %d left by a server that did not stop it" pgid;
           Eio_unix.run_in_systhread (fun () ->
             Process_eio_detached.tree_kill ~pgid ~signal:Sys.sigterm
               ~grace_sec:driver_stop_grace_s));
    Safe_ops.remove_file_logged ~context:"browser-lane driver record" record_path
  end

(* A browser that relaunched itself is outside the driver's process group, so
   it is found by the profile it still uses and stopped by pid. Its content
   processes exit when it does. *)
let stop_pids ~clock pids =
  let signal number pid =
    try Unix.kill pid number with Unix.Unix_error ((Unix.ESRCH | Unix.EPERM), _, _) -> () in
  let alive pid = match Unix.kill pid 0 with () -> true | exception Unix.Unix_error _ -> false in
  List.iter (signal Sys.sigterm) pids;
  let deadline = Monotonic_deadline.after ~seconds:driver_stop_grace_s in
  let rec wait () =
    match List.filter alive pids with
    | [] -> ()
    | survivors when Monotonic_deadline.passed deadline -> List.iter (signal Sys.sigkill) survivors
    | _ :: _ -> Eio.Time.sleep clock driver_ready_poll_s; wait ()
  in
  wait ()

let stop_browsers_using ~clock ~profile_root =
  match Process_eio.run_argv_with_status [ "ps"; "-ww"; "-axo"; "pid=,command=" ] with
  | (Unix.WEXITED 0, process_table) ->
    (match Browser_driver_process.browsers_using_profile_root ~profile_root ~process_table with
     | [] -> Ok ()
     | pids ->
       Log.Server.warn "browser-lane: stopping automation browser pid %s still using %s"
         (String.concat ", " (List.map string_of_int pids)) profile_root;
       stop_pids ~clock pids;
       Ok ())
  | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _) ->
    Error "the process table could not be read"

let free_loopback_port () =
  match Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 with
  | exception Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)
  | socket ->
    Fun.protect ~finally:(fun () -> Unix.close socket) (fun () ->
      match
        Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
        Unix.getsockname socket
      with
      | exception Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)
      | Unix.ADDR_INET (_, port) -> Ok port
      | Unix.ADDR_UNIX _ -> Error "loopback socket reported a unix address")

let remove_owner_record record_path =
  if Sys.file_exists record_path then
    Safe_ops.remove_file_logged ~context:"browser-lane driver record" record_path

(* Profiles a crashed session left behind are removed once no browser uses
   them; the directory belongs to this server alone. *)
let clear_profile_root ~profile_root =
  match Fs_compat.remove_tree profile_root; Fs_compat.mkdir_p profile_root with
  | () -> Ok ()
  | exception (Eio.Io _ as exn) -> Error (Printexc.to_string exn)
  | exception Unix.Unix_error (code, _, path) -> Error (path ^ ": " ^ Unix.error_message code)
  | exception Sys_error detail -> Error detail

(* Readiness races the driver's exit, so a driver that dies at start is
   reported at once instead of after the whole readiness timeout. *)
let await_driver ~clock ~pool ~endpoint ~process ~log_path =
  let deadline = Monotonic_deadline.after ~seconds:driver_ready_timeout_s in
  let rec poll () =
    match Masc_http_client.Pool.request pool ~clock ~timeout_seconds:driver_ready_poll_s
            ~method_:`GET ~url:(endpoint ^ "/status") ~headers:[] () with
    | Ok response when response.status = 200 -> Ok ()
    | Ok _ | Error _ when Monotonic_deadline.passed deadline ->
      Error (Printf.sprintf "geckodriver did not answer %s/status within %.0f s; its output is in %s"
               endpoint driver_ready_timeout_s log_path)
    | Ok _ | Error _ -> Eio.Time.sleep clock driver_ready_poll_s; poll ()
  in
  Eio.Fiber.first poll (fun () ->
    let status = Eio.Process.await process in
    Error (Format.asprintf "geckodriver exited before answering (%a); its output is in %s"
             Eio.Process.pp_status status log_path))

(* The driver is spawned on the server's switch through the posix_spawn
   manager: fork is refused once the server runs several domains, and the
   manager terminates the driver's whole process group when the switch is
   released. A hook registered before the spawn runs after that termination:
   it stops any browser still using this server's profile root, which a
   browser that relaunched itself outside the group does, then removes the
   record. *)
let launch_driver ~sw ~env ~masc_root ~record_path ~driver =
  let lane = Filename.concat masc_root "browser-lane" in
  let log_path = Filename.concat lane "geckodriver.log" in
  let prepared =
    match Fs_compat.mkdir_p (Browser_driver_process.profile_root ~masc_root) with
    | () -> Result.map_error (fun detail -> "no free loopback port: " ^ detail) (free_loopback_port ())
    | exception (Eio.Io _ as exn) ->
      Error (Printf.sprintf "cannot create %s: %s" lane (Printexc.to_string exn))
    | exception Unix.Unix_error (code, _, _) ->
      Error (Printf.sprintf "cannot create %s: %s" lane (Unix.error_message code))
  in
  match prepared with
  | Error detail -> Error detail
  | Ok port ->
    let clock = Eio.Stdenv.clock env in
    let profile_root = Browser_driver_process.profile_root ~masc_root in
    Eio.Switch.on_release sw (fun () ->
      (match stop_browsers_using ~clock ~profile_root with
       | Ok () -> ()
       | Error detail -> Log.Server.warn "browser-lane: browsers under %s not checked: %s" profile_root detail);
      remove_owner_record record_path);
    match
      let output =
        Eio.Path.open_out ~sw ~create:(`Or_truncate 0o600) Eio.Path.(Eio.Stdenv.fs env / log_path) in
      Eio.Process.spawn ~sw
        (Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds:driver_stop_grace_s)
        ~stdout:output ~stderr:output
        (Browser_driver_process.argv ~driver ~port ~profile_root)
    with
    | exception (Eio.Io _ as exn) -> Error ("geckodriver did not start: " ^ Printexc.to_string exn)
    | exception Unix.Unix_error (code, call, target) ->
      Error (Printf.sprintf "geckodriver did not start: %s %s: %s" call target (Unix.error_message code))
    | process ->
      let pid = Eio.Process.pid process in
      match
        Fs_compat.save_file_atomic record_path
          (Browser_driver_process.owner_to_string { pid; driver })
      with
      | Error detail ->
        (* Without the record a server that dies would leave this driver for
           nobody to stop, which is the failure this ownership removes. The
           switch release still stops the driver. *)
        Error (Printf.sprintf "cannot record geckodriver pid %d in %s: %s" pid record_path detail)
      | Ok () -> Ok
          ( Printf.sprintf
              "http://%s:%d"
              Masc_network_defaults.masc_http_loopback_peer
              port
          , process
          , pid
          , log_path )

let start ~sw ~env =
  let clock = Eio.Stdenv.clock env in
  let base_path = Config_dir_resolver.base_path_or_cwd () in
  let masc_root = Config_dir_resolver.masc_root ~base_path in
  let record_path = Browser_driver_process.owner_record_path ~masc_root in
  let profile_root = Browser_driver_process.profile_root ~masc_root in
  Eio.Fiber.fork ~sw (fun () ->
    stop_driver_left_behind ~record_path;
    (* Profiles are cleared only once no browser can still be using one. *)
    (match Result.bind (stop_browsers_using ~clock ~profile_root) (fun () -> clear_profile_root ~profile_root) with
     | Ok () -> ()
     | Error detail -> Log.Server.warn "browser-lane: profiles under %s kept: %s" profile_root detail);
    match configured_browser () with
    | Error detail -> Log.Server.error "browser-lane: %s" detail
    | Ok Browser_configuration.Disabled ->
      Log.Server.info "browser-lane: automation has no browser.geckodriver"
    | Ok (Browser_configuration.Geckodriver { driver; binary }) ->
      match launch_driver ~sw ~env ~masc_root ~record_path ~driver with
      | Error detail -> Log.Server.error "browser-lane: %s" detail
      | Ok (endpoint, process, pid, log_path) ->
        let pool = Masc_http_client.Pool.create ~sw ~env () in
        match await_driver ~clock ~pool ~endpoint ~process ~log_path with
        | Error detail -> Log.Server.error "browser-lane: %s" detail
        | Ok () ->
          let root = Filename.concat masc_root "browser-downloads" in
          let driver_client = Browser_webdriver.create ?binary
            ~start_downloads:(Browser_bidi_downloads.start ~sw ~env ~root
              ~publish:(Browser_download_artifact.publish ~base_path)) ~request:(request ~pool ~clock ~endpoint) () in
          Browser_lane.install_automation_executor (Some (Browser_webdriver.execute driver_client));
          Browser_lane.install_automation_document_observer
            (Some (Browser_webdriver.observe_document_if_idle driver_client));
          (* Registered after the driver's stop, so it runs before it: the
             session is closed while the driver can still close its browser. *)
          Eio.Switch.on_release sw (fun () ->
            Browser_lane.install_automation_executor None;
            Browser_lane.install_automation_document_observer None;
            match close_with_fresh_pool ~env ~endpoint driver_client with
            | Ok () -> ()
            | Error error -> Log.Server.warn "browser-lane: close failed: %s"
                (Browser_webdriver.error_message error));
          Log.Server.info "browser-lane: geckodriver pid %d serves automation at %s" pid endpoint)
