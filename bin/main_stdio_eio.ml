[@@@warning "-32-69"]

module Mcp_eio = Masc.Mcp_server_eio
module Server_startup_state = Masc.Server_startup_state
module Shutdown_hooks = Masc.Shutdown_hooks
module Board_dispatch = Masc.Board_dispatch

open Cmdliner

let base_path =
  let doc =
    "Workspace root for MASC data. Runtime state lives under <base-path>/.masc; do not pass the .masc directory itself."
  in
  Arg.(value & opt (some string) None & info ["base-path"] ~docv:"PATH" ~doc)

let run_cmd cli_base_path =
  (* Capture the external client's credential before owner startup establishes
     any internal runtime credentials. It is never logged or substituted by
     a bootstrap/admin token. *)
  let stdio_auth_token = Sys.getenv_opt "MASC_TOKEN" in
  Printexc.record_backtrace true;
  let workspace =
    Server_base_path_guard.exit_on_no_workspace
      (Server_base_path_guard.startup_root ~cli_base_path)
  in
  let normalized_base_path = workspace.Workspace_root.root in
  Unix.putenv
    "MASC_BASE_PATH_RESOLUTION_SOURCE"
    (Workspace_root.source_label workspace.Workspace_root.source);
  (* Create an explicit missing workspace root, then freeze the canonical
     owner identity before the lease, environment, backend, or runtime sees it. *)
  Fs_compat.mkdir_p normalized_base_path;
  let base_path =
    match Server_base_path_guard.canonicalize_existing normalized_base_path with
    | Ok canonical -> canonical
    | Error error ->
      Printf.eprintf
        "%s\n"
        (Server_base_path_guard.format_canonicalization_error error);
      exit 1
  in
  Unix.putenv Env_config_core.base_path_env_key base_path;
  Workspace_utils_backend_setup.cache_resolved_base_path base_path;
  Eio_main.run @@ fun env ->
  Crypto_rng.ensure_default ();
  Eio_guard.enable ();
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Server_session_switch.run @@ fun ~runtime_sw sw ->
  let clock, mono_clock, net, domain_mgr, proc_mgr, fs =
    Server_runtime_bootstrap.init_runtime_context env
  in
  let lease =
    match
      Server_startup_takeover.acquire_owner_lease
        (Host_config.host ()).base_path_lease_root base_path
    with
    | Server_startup_takeover.Base_path_acquired lease -> lease
    | Server_startup_takeover.Base_path_already_owned { owner; lock_path } ->
      Log.Server.error "stdio runtime cannot start: %s"
        (Server_startup_takeover.base_path_contention_message
           ~base_path ~lock_path owner);
      exit 1
    | Server_startup_takeover.Base_path_rejected rejection ->
      Log.Server.error
        "stdio runtime rejected BasePath %s: %s"
        base_path
        (Server_startup_takeover.base_path_lock_rejection_to_string rejection);
      exit 1
  in
  Eio.Switch.on_release sw (fun () ->
    Server_startup_takeover.release_base_path_lease lease);
  (* HIGH-RISK-UNREVIEWED: the stdio runtime opens a base path only after the
     same account mode judgment as the HTTP boot, right after the BasePath
     lease. MASC_ALLOW_ANONYMOUS_MUTATIONS configures the HTTP surface only;
     the stdio runtime never reads it, so it reports none. *)
  let single_user =
    match
      Authz_boot_mode_read.boot
        ~base_path
        ~config_dir:(Env_config_core.masc_config_dir_opt ())
        ~anonymous_mutations:false
    with
    | Ok (Authz_boot_mode_read.Single_user single_user) -> single_user
    | Ok (Authz_boot_mode_read.Multi_account (_ : Authz_boot_mode_read.multi_account)) ->
      (* The stdio runtime is the owner state of a single user. The account
         server of the HTTP boot serves a multi-account installation. *)
      Log.Server.error
        "[FATAL] the account mode refuses this stdio boot: the workspace is an active \
         multi-account installation, which the stdio runtime does not serve";
      exit 1
    | Error (first, rest) ->
      Log.Server.error
        "[FATAL] the account mode refuses this stdio boot: %s"
        (String.concat "; " (first :: rest));
      exit 1
  in
  (* Complete the system-thread inventory before cancellation can release the
     process lease or owner initialization can start original writers. *)
  let original_inventory_started = Unix.gettimeofday () in
  let original_inventory_elapsed () = max 0. (Unix.gettimeofday () -. original_inventory_started) in
  Eio.Cancel.protect (fun () ->
    match Masc.Lane_addon_original_body_inventory.run_at_startup ~base_path with
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception _ ->
      Log.Server.warn "[Startup] original request body inventory unavailable elapsed_s=%.3f"
        (original_inventory_elapsed ())
    | Error error ->
      Log.Server.warn "[Startup] original request body inventory unavailable elapsed_s=%.3f: %s"
        (original_inventory_elapsed ()) (Masc.Lane_addon_original_body_inventory.error_to_string error)
    | Ok report ->
      let message = Printf.sprintf
        "[Startup] original request body inventory: live_unprotected_files=%d live_unprotected_logical_bytes=%Ld protected_digests=%d elapsed_s=%.3f"
        report.unprotected_files report.unprotected_logical_bytes report.protected_digests
        (original_inventory_elapsed ()) in
      if report.unprotected_files > 0 then Log.Server.warn "%s" message else Log.Server.info "%s" message);
  Server_startup_state.reset ();
  Server_startup_state.mark_blocking ();
  let initialized =
    try
      Server_runtime_bootstrap.initialize_owner_state_blocking
        ~sw
        ~runtime_sw
        ~env
        ~single_user
        ~input_base_path:workspace.Workspace_root.requested
          (* The stdio runtime has no --accept-store-quarantine: a keeper store
             this build cannot decode makes it refuse, and the operator strips
             the file or starts the HTTP runtime with the flag (RFC-0420). *)
        ~accept_store_quarantine:false
        ~clock
        ~mono_clock
        ~net
        ~domain_mgr
        ~proc_mgr
        ~fs
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
  let activated =
    try
      Server_runtime_bootstrap.activate_owner_state
       ~sw
       ~clock
        ~mono_clock
       ~net
       ~proc_mgr
       initialized
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
      exit 1
  in
  let state = activated.Server_runtime_bootstrap.state in
  (match Server_runtime_bootstrap.mark_owner_state_ready () with
   | Ok () -> ()
   | Error error ->
     Log.Server.error
       "[FATAL] stdio readiness publication failed before MCP publication: %s"
       (Server_runtime_bootstrap.owner_initialization_error_to_string error);
     exit 1);
  ignore
    (Server_runtime_bootstrap.start_post_ready_owner_lanes
       ~sw
       ~clock
       ~env
       state);
  Fun.protect
    ~finally:(fun () ->
      (try Board_dispatch.flush () with
       | Eio.Cancel.Cancelled _ -> ()
       | exn ->
         Log.Misc.warn
           "shutdown: board flush failed: %s"
           (Printexc.to_string exn));
      Shutdown_hooks.run_all ())
    (fun () -> Mcp_eio.run_stdio ?auth_token:stdio_auth_token ~sw ~env state)

let cmd =
  let doc = "MASC MCP Server (stdio, Eio)" in
  let info = Cmd.info "masc-stdio" ~version:Runtime_build_version.current ~doc in
  Cmd.v info Term.(const run_cmd $ base_path)

let () = exit (Cmd.eval cmd)
