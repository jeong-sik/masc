[@@@warning "-32-69"]

module Mcp_eio = Masc.Mcp_server_eio
module Server_runtime_bootstrap = Server_runtime_bootstrap
module Server_bootstrap_loops = Server_bootstrap_loops
module Server_startup_takeover = Server_startup_takeover
module Shutdown_hooks = Masc.Shutdown_hooks
module Board_dispatch = Masc.Board_dispatch

open Cmdliner

let default_base_path () = Server_mcp_transport_http.default_base_path ()

let base_path =
  let doc =
    "Workspace root for MASC data. Runtime state lives under <base-path>/.masc; do not pass the .masc directory itself."
  in
  Arg.(value & opt (some string) None & info ["base-path"] ~docv:"PATH" ~doc)

let run_cmd cli_base_path =
  Printexc.record_backtrace true;
  let resolved_base_path =
    Server_base_path_guard.resolve_startup_base_path ~cli_base_path
      ~default_base_path ()
  in
  Server_base_path_guard.exit_on_violation
    (Server_base_path_guard.enforce resolved_base_path);
  let base_path = resolved_base_path.normalized_base_path in
  (match Server_startup_takeover.acquire_base_path_lock base_path with
   | Server_startup_takeover.Acquired -> ()
   | Server_startup_takeover.Already_running { pid } ->
     Log.legacy_stderr ~level:Log.Error ~module_name:"Server"
       (Printf.sprintf
          "[FATAL] Another MASC server (PID %d) already owns base path %s"
          pid
          base_path);
     exit 1);
  Unix.putenv "MASC_BASE_PATH_INPUT" resolved_base_path.raw_base_path;
  Unix.putenv "MASC_BASE_PATH" base_path;
  Unix.putenv "MASC_BASE_PATH_RESOLUTION_SOURCE"
    (Server_base_path_guard.resolution_source_label
       resolved_base_path.resolution_source);
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  Eio_guard.enable ();
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  let clock, mono_clock, net, _domain_mgr, proc_mgr, fs =
    Server_runtime_bootstrap.init_runtime_context env
  in
  let state, _remaining_work =
    Gc.ramp_up (fun () ->
      Server_runtime_bootstrap.create_server_state ~sw ~base_path ~clock
        ~mono_clock ~net ~proc_mgr ~fs ~env ())
  in
  Server_runtime_bootstrap.bootstrap_server_state_blocking state;
  Masc.Runtime_params.restore ~base_path;
  (match Server_runtime_bootstrap.initialize_memory_lane ~sw ~clock state with
   | Ok report ->
     Log.Server.info
       "stdio memory lane initialized discovered=%d started=%d deferred=%d keeper_errors=%d root_error=%b"
       report.discovered_keepers
       report.workers_started
       report.workers_deferred
       (List.length report.keeper_discovery_errors)
       (Option.is_some report.discovery_error)
   | Error detail ->
     Log.Server.error "stdio memory lane initialization deferred: %s" detail);
  ignore (Server_bootstrap_loops.start_background_maintenance ~sw ~clock ~env state);
  Fun.protect
    ~finally:(fun () ->
      (try Board_dispatch.flush ()
       with
       | Eio.Cancel.Cancelled _ -> ()
       | exn ->
           Log.Misc.warn "shutdown: board flush failed: %s"
             (Printexc.to_string exn));
      Shutdown_hooks.run_all ())
    (fun () -> Mcp_eio.run_stdio ~sw ~env state)

let cmd =
  let doc = "MASC MCP Server (stdio, Eio)" in
  let info = Cmd.info "masc-stdio" ~version:Masc.Version.version ~doc in
  Cmd.v info Term.(const run_cmd $ base_path)

let () = exit (Cmd.eval cmd)
