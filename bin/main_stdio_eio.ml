[@@@warning "-32-69"]

module Mcp_eio = Masc.Mcp_server_eio
module Server_startup_state = Masc.Server_startup_state
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
  Unix.putenv "MASC_BASE_PATH_INPUT" resolved_base_path.raw_base_path;
  Unix.putenv "MASC_BASE_PATH" base_path;
  Unix.putenv
    "MASC_BASE_PATH_RESOLUTION_SOURCE"
    (Server_base_path_guard.resolution_source_label
       resolved_base_path.resolution_source);
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  Eio_guard.enable ();
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  let clock, mono_clock, net, domain_mgr, proc_mgr, fs =
    Server_runtime_bootstrap.init_runtime_context env
  in
  Fs_compat.mkdir_p (Filename.concat base_path Common.masc_dirname);
  let lease =
    match Server_startup_takeover.acquire_base_path_lock base_path with
    | Server_startup_takeover.Base_path_acquired lease -> lease
    | Server_startup_takeover.Base_path_already_owned { pid } ->
      Log.Server.error
        "stdio runtime cannot start because PID %s owns BasePath %s; use the owning runtime command plane"
        (Option.fold ~none:"unknown" ~some:string_of_int pid)
        base_path;
      exit 1
  in
  Eio.Switch.on_release sw (fun () ->
    Server_startup_takeover.release_base_path_lease lease);
  Server_startup_state.reset ~backend_mode:"filesystem" ();
  Server_startup_state.mark_blocking ~backend_mode:"filesystem";
  let governance_level = Env_config_core.governance_level () in
  let initialized =
    try
      Server_runtime_bootstrap.initialize_owner_state_blocking
        ~sw
        ~env
        ~base_path
        ~clock
        ~mono_clock
        ~net
        ~domain_mgr
        ~proc_mgr
        ~fs
        ~governance_level
        ()
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Server_runtime_bootstrap.Owner_initialization_failed error ->
      Log.Server.error
        "[FATAL] stdio owner initialization failed before MCP publication: %s"
        (Server_runtime_bootstrap.owner_initialization_error_to_string error);
      exit 1
    | exn ->
      Log.Server.error
        "[FATAL] stdio owner initialization failed before MCP publication: %s"
        (Printexc.to_string exn);
      exit 1
  in
  let state = initialized.Server_runtime_bootstrap.state in
  (try
     Server_runtime_bootstrap.start_owner_lazy_tasks ~sw state;
     Server_bootstrap_loops.start_keeper_loops
       ~claimed_persistence:initialized.claimed_keeper_persistence
       ~sw
       ~clock
       ~net
       ~domain_mgr
       ~proc_mgr
       state;
     (match Server_runtime_bootstrap.mark_owner_state_ready state with
      | Ok () -> ()
      | Error error ->
        raise (Server_runtime_bootstrap.Owner_initialization_failed error))
   with
   | Eio.Cancel.Cancelled _ as exn -> raise exn
   | Server_runtime_bootstrap.Owner_initialization_failed error ->
     Log.Server.error
       "[FATAL] stdio startup barrier failed before MCP publication: %s"
       (Server_runtime_bootstrap.owner_initialization_error_to_string error);
     exit 1
   | exn ->
     Log.Server.error
       "[FATAL] stdio Keeper runtime failed before MCP publication: %s"
       (Printexc.to_string exn);
     exit 1);
  ignore
    (Server_bootstrap_loops.start_background_maintenance ~sw ~clock ~env state);
  Fun.protect
    ~finally:(fun () ->
      (try Board_dispatch.flush () with
       | Eio.Cancel.Cancelled _ -> ()
       | exn ->
         Log.Misc.warn
           "shutdown: board flush failed: %s"
           (Printexc.to_string exn));
      Shutdown_hooks.run_all ())
    (fun () -> Mcp_eio.run_stdio ~sw ~env state)

let cmd =
  let doc = "MASC MCP Server (stdio, Eio)" in
  let info = Cmd.info "masc-stdio" ~version:Masc.Version.version ~doc in
  Cmd.v info Term.(const run_cmd $ base_path)

let () = exit (Cmd.eval cmd)
