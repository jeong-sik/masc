[@@@warning "-32-69"]

module Mcp_eio = Masc.Mcp_server_eio
module Server_runtime_bootstrap = Server_runtime_bootstrap
module Server_bootstrap_loops = Server_bootstrap_loops
module Shutdown_hooks = Masc.Shutdown_hooks
module Board_dispatch = Masc.Board_dispatch

open Cmdliner

let default_base_path () = Server_mcp_transport_http.default_base_path ()

let base_path =
  let doc =
    "Workspace root for MASC data. Runtime state lives under <base-path>/.masc; do not pass the .masc directory itself."
  in
  Arg.(value & opt string (default_base_path ()) & info ["base-path"] ~docv:"PATH" ~doc)

let run_cmd base_path =
  Printexc.record_backtrace true;
  let normalized_base_path =
    Env_config.normalize_masc_base_path_input base_path
  in
  let resolution_source =
    match Sys.getenv_opt "MASC_BASE_PATH_RESOLUTION_SOURCE" with
    | Some source when String.trim source <> "" -> String.trim source
    | _ ->
      (match Sys.getenv_opt "MASC_BASE_PATH" with
       | Some existing
         when String.equal
                (Env_config.normalize_masc_base_path_input existing)
                normalized_base_path -> "explicit_env"
       | _ -> "explicit_cli")
  in
  Server_base_path_guard.guard_self_repo_base_path normalized_base_path;
  Server_base_path_guard.guard_implicit_base_path
    ~resolution_source
    ~normalized_base_path;
  Unix.putenv "MASC_BASE_PATH_RESOLUTION_SOURCE" resolution_source;
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
