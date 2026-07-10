[@@@warning "-32-69"]

module Mcp_eio = Masc.Mcp_server_eio
module Server_runtime_bootstrap = Server_runtime_bootstrap
module Server_bootstrap_loops = Server_bootstrap_loops
module Shutdown_hooks = Masc.Shutdown_hooks
module Board_dispatch = Masc.Board_dispatch

open Cmdliner

let default_base_path () =
  Config_dir_resolver.current_working_dir ()
  |> Workspace_utils_backend_setup.resolve_server_default_base_path

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
