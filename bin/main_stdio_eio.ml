[@@@warning "-32-69"]

module Mcp_eio = Masc_mcp.Mcp_server_eio
module Server_runtime_bootstrap = Masc_mcp.Server_runtime_bootstrap
module Shutdown_hooks = Masc_mcp.Shutdown_hooks
module Board_dispatch = Masc_mcp.Board_dispatch

open Cmdliner

let default_base_path () = Masc_mcp.Server_mcp_transport_http.default_base_path ()

let base_path =
  let doc = "Base path for MASC data (.masc folder location)" in
  Arg.(value & opt string (default_base_path ()) & info ["base-path"] ~docv:"PATH" ~doc)

let run_cmd base_path =
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  Masc_mcp.Prometheus.enable_eio ();
  Masc_mcp.Chain_telemetry.enable_eio ();
  Masc_mcp.Generational_metrics.enable_eio ();
  Masc_mcp.Dashboard_cache.enable_eio ();
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Masc_mcp.Cancellation.TokenStore.init ();
  Eio.Switch.run @@ fun sw ->
  let clock, mono_clock, net, _domain_mgr, proc_mgr, fs =
    Server_runtime_bootstrap.init_runtime_context env
  in
  let state =
    Server_runtime_bootstrap.create_server_state ~sw ~base_path ~clock
      ~mono_clock ~net ~proc_mgr ~fs
  in
  Server_runtime_bootstrap.bootstrap_server_state state;
  Server_runtime_bootstrap.bootstrap_keepers ~sw ~clock state;
  Server_runtime_bootstrap.init_task_backend ();
  Server_runtime_bootstrap.inject_shared_pg_pool ();
  Server_runtime_bootstrap.init_memory_pg_schema ();
  ignore (Server_runtime_bootstrap.start_background_maintenance ~sw ~clock state);
  Fun.protect
    ~finally:(fun () ->
      (try Board_dispatch.flush () with _ -> ());
      Shutdown_hooks.run_all ())
    (fun () -> Mcp_eio.run_stdio ~sw ~env state)

let cmd =
  let doc = "MASC MCP Server (stdio, Eio)" in
  let info = Cmd.info "masc-mcp-stdio" ~version:Masc_mcp.Version.version ~doc in
  Cmd.v info Term.(const run_cmd $ base_path)

let () = exit (Cmd.eval cmd)
