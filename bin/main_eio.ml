(** MASC MCP Server - Eio Native Entry Point
    MCP Streamable HTTP Transport with Eio concurrency (OCaml 5.x)

    Uses h2-eio for HTTP/2 with unlimited SSE streams per connection.
    HTTP/2 multiplexing eliminates browser's 6-connection-per-domain limit.
*)

open Cmdliner

(** Module aliases *)
module Http = Masc.Http_server_eio
module Mcp_server = Masc.Mcp_server
module Mcp_eio = Masc.Mcp_server_eio
module Workspace = Masc.Workspace
module Workspace_utils = Workspace_utils
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_microvm_backend = Masc.Keeper_microvm_backend
module Keeper_config = Masc.Keeper_config
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_memory = Masc.Keeper_memory
module Keeper_runtime = Masc.Keeper_runtime
module Keeper_sandbox_runtime = Masc.Keeper_sandbox_runtime
module Keeper_sandbox_image_catalog = Masc.Keeper_sandbox_image_catalog
module Keeper_sandbox_image_resolver = Masc.Keeper_sandbox_image_resolver
module Keeper_github_identity = Masc.Keeper_github_identity
module Keeper_github_login_lane = Masc.Keeper_github_login_lane
module Tool_operator = Masc.Tool_operator
module Operator_control = Operator_control
module Dashboard_execution = Dashboard_execution
module Dashboard_briefing = Dashboard_briefing
module Dashboard_briefing_sections = Dashboard_briefing_sections
module Build_identity = Masc.Build_identity
module Server_scheduler_eintr = Masc.Server_scheduler_eintr
module Server_startup_state = Masc.Server_startup_state
module Installed_dashboard = Masc.Installed_dashboard
module Keeper_status_bridge = Masc.Keeper_status_bridge
module Keeper_tool_call_log = Masc.Keeper_tool_call_log
module Graphql_api = Masc.Graphql_api
module Types = Masc_domain
module Tempo = Masc.Tempo
module Board = Masc.Board
module Board_curation = Masc.Board_curation
module Board_dispatch = Masc.Board_dispatch
module Task = Masc.Task
module Http_negotiation = Mcp_transport_protocol.Http_negotiation
module Progress = Masc.Progress
module Sse = Masc.Sse
module Safe_ops = Safe_ops
module Tool_board = Board_tool
module Transport_metrics = Masc.Transport_metrics
module Server_mcp_transport_http = Server_mcp_transport_http
module Server_mcp_transport_http_conn = Server_mcp_transport_http_conn

let () =
  Masc.Shutdown_hooks.register_sse_cleanup (fun () ->
    let closed = Sse.close_all_clients () in
    closed, Server_mcp_transport_http_conn.active_session_count ())


(* ============================================ *)
(* Extracted modules (lib/)                      *)
(* ============================================ *)
include Masc.Server_utils
include Server_auth
include Server_voice_config
include Server_dashboard_http
module Server_h2_gateway = Server_h2_gateway
module Server_runtime_bootstrap = Server_runtime_bootstrap
module Server_routes_http_runtime = Server_routes_http_runtime
module Server_startup_takeover = Server_startup_takeover

(** Main server loop *)
let run_server ~sw ~runtime_sw ~env ~address ~port ~judged ~input_base_path ~on_ready ~accept_store_quarantine =
  (* Service fibers attach to the session switch. Graceful shutdown fails
     that switch after the signal handler finishes its phases. Codec workers
     belong to the outer runtime switch, so they remain available until every
     cancelled service has finished its journal cleanup. *)
  try
    Server_runtime_bootstrap.run ~sw ~runtime_sw ~env ~address ~port ~judged
      ~input_base_path ~on_ready ~accept_store_quarantine ~make_routes:Server_routes_http.make_routes_with_transport
      ~make_request_handler:Server_http_ingress.http1_handler
      ~make_h2_request_handler:Server_h2_gateway.make_request_handler
      ~make_h2_error_handler:Server_h2_gateway.make_error_handler
      ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Server.error "[main] the server stopped with an exception: %s" (Printexc.to_string exn);
    raise exn

(** CLI options *)
let port_argument =
  Arg.(value & opt (some int) None & info ["p"; "port"] ~docv:"PORT"
    ~doc:"HTTP port resolution order (explicit flag, MASC_HTTP_PORT, saved workspace port, then default).")

let host =
  let default = Env_config.masc_host () in
  let doc =
    "Host/IP to bind. Defaults to loopback (`127.0.0.1`). Use `0.0.0.0` or `::` only when you also enable workspace auth with `require_token=true`."
  in
  Arg.(value & opt string default & info ["host"] ~docv:"HOST" ~doc)

let run_base_path =
  Arg.(value & opt (some string) None & info ["base-path"] ~docv:"PATH"
    ~doc:"Workspace root; runtime state lives under its .masc directory.")
(* In-process readers still find the workspace through MASC_BASE_PATH until
   RFC workspace-root-resolution stage 4 passes the root as an argument. Without
   this, a workspace found from the cwd would reach the command and then be lost
   to every reader below it. *)
let publish_workspace_root (workspace : Workspace_root.t) =
  Unix.putenv Env_config_core.base_path_env_key workspace.Workspace_root.root;
  Config_dir_resolver.reset ();
  Workspace_utils_backend_setup.cache_resolved_base_path workspace.Workspace_root.root

(* Every command that takes a workspace resolves it here, in Workspace_root's
   order, so `masc init` run inside a workspace finds it the way `masc start` does. *)
let base_path =
  Term.(ret (const (fun requested ->
    match Workspace_root.resolve_current ~flag:requested with
    | Ok workspace ->
      publish_workspace_root workspace;
      `Ok workspace.Workspace_root.root
    | Error error -> `Error (false, Workspace_root.error_message error)) $ run_base_path))
let selected_base_path requested =
  match Workspace_root.resolve_current ~flag:requested with
  | Ok workspace -> Some workspace.Workspace_root.root
  | Error (Workspace_root.No_workspace _ | Workspace_root.Unanchored _) -> None
let resolve_connection_port requested cli =
  Workspace_connection.resolve ~base_path:(selected_base_path requested) ~cli
    ~environment:(Env_config_core.raw_value_opt Env_config_core.http_port_env_key)
let port = Term.(ret (const (fun requested cli -> match resolve_connection_port requested cli with
  | Ok value -> `Ok (Workspace_connection.to_int value)
  | Error error -> `Error (false, Workspace_connection.error_message error)) $ run_base_path $ port_argument))

let accept_store_quarantine =
  let doc =
    "Let boot move aside every keeper store this build cannot decode and start those keepers with empty stores. Without this flag boot refuses to start while such a store exists and prints each path with its rejection (RFC-0420). The deployment preflight never passes it: it refuses the same files before the executable is replaced or started."
  in
  Arg.(value & flag & info ["accept-store-quarantine"] ~doc)

let record_default_arg =
  let doc =
    "Record this workspace as the default for later commands (in \
     XDG_CONFIG_HOME/masc/default-base-path, else ~/.config). Off by default: \
     a temporary server workspace must not overwrite the machine's default."
  in
  Arg.(value & flag & info [ "record-default" ] ~doc)

(* What `masc start` does when another process holds this workspace. *)
type previous_owner =
  | Refuse_previous_owner
  | Wait_for_previous_owner

let previous_owner_arg =
  let doc =
    "When another process holds this workspace, wait for it to exit instead \
     of refusing to start. Nothing is signalled: `masc restart` passes this \
     after it has asked the running server to stop."
  in
  Term.(const (function true -> Wait_for_previous_owner | false -> Refuse_previous_owner)
    $ Arg.(value & flag & info [ "wait-for-previous-owner" ] ~doc))

let build_provenance_path =
  let doc = "Absolute content-addressed executable provenance sidecar path" in
  Arg.(value & opt (some string) None & info ["build-provenance-path"] ~docv:"PATH" ~doc)

let build_provenance_sha256 =
  let doc = "Expected SHA-256 of --build-provenance-path" in
  Arg.(value & opt (some string) None & info ["build-provenance-sha256"] ~docv:"SHA256" ~doc)

let build_provenance_device =
  let doc = "Expected device number of --build-provenance-path" in
  Arg.(value & opt (some int) None & info ["build-provenance-device"] ~docv:"DEVICE" ~doc)

let build_provenance_inode =
  let doc = "Expected inode number of --build-provenance-path" in
  Arg.(value & opt (some int) None & info ["build-provenance-inode"] ~docv:"INODE" ~doc)

let login_json =
  let doc = "Emit machine-readable JSON instead of text output" in
  Arg.(value & flag & info ["json"] ~doc)

let parse_login_role value =
  match Masc_domain.agent_role_of_string (String.lowercase_ascii value) with
  | Ok role -> Ok role
  | Error msg -> Error (`Msg msg)

let login_role =
  let doc = "Role for the minted bearer token: admin or worker" in
  let role_printer fmt role =
    Format.pp_print_string fmt (Masc_domain.agent_role_to_string role)
  in
  let role_conv = Arg.conv (parse_login_role, role_printer) in
  Arg.(value & opt role_conv Masc_domain.Admin & info ["role"] ~docv:"ROLE" ~doc)

(* One spelling of the workspace's own operator identity. [login] mints under
   it and [keeper-create] presents what [login] wrote, so the two reading
   different names would send a keeper-create out with no credential while
   [masc login] reported success. *)
let default_login_agent = "local-admin"

let login_agent =
  let doc = "Agent identity bound to the minted bearer token" in
  Arg.(
    value
    & opt string default_login_agent
    & info ["agent"] ~docv:"AGENT" ~doc)

let login_shell =
  let doc = "Emit shell export commands only" in
  Arg.(value & flag & info ["shell"] ~doc)

let login_client_env =
  let doc =
    "Env var name your MCP client reads to pick up the minted bearer \
     token. Required; the server holds no list of \"known\" MCP \
     clients. Example: MASC_TOKEN or any \
     operator-chosen name. The value is \
     rendered verbatim into the shell exports and JSON output."
  in
  Arg.(
    required
    & opt (some string) None
    & info ["client-env"] ~docv:"VAR" ~doc)

let login_no_expiry =
  let doc =
    "Mint a long-lived token without an [expires_at] field. \
     Appropriate for long-running local MCP daemons that cannot \
     easily refresh on expiry. Omit for the default expiring policy."
  in
  Arg.(value & flag & info ["no-expiry"] ~doc)

let login_expiry_hours =
  let doc =
    "Mint a token that expires this many hours from now, whatever window \
     the workspace itself uses. For a client that outlives an operator \
     session but should still lose its bearer eventually. Accepts 1..8760; \
     cannot be combined with --no-expiry."
  in
  Arg.(value & opt (some int) None & info ["expiry-hours"] ~docv:"HOURS" ~doc)

(** Graceful shutdown exception.

    Raised from the main [Switch.run] fiber after shutdown phases complete.
    This causes [Eio.Switch.run] to fail the switch, which cancels every
    remaining background fiber and waits for them to finish.  Returning
    normally would leave non-daemon background fibers running and make
    [Switch.run] wait forever. *)
exception Graceful_shutdown

let announce_wait_for_previous_owner ~base_path owner =
  let recorded =
    match owner with
    | Server_startup_takeover.Owner_this_process pid
    | Server_startup_takeover.Owner_recorded pid -> Printf.sprintf "PID %d" pid
    | Server_startup_takeover.Owner_unnamed -> "an unnamed process"
  in
  Log.legacy_stderr ~level:Log.Info ~module_name:"Server"
    (Printf.sprintf
       "Waiting for the previous owner of %s (the lease records %s) to exit. \
        Nothing is signalled from here; stopping this process ends the wait."
       base_path recorded)

let acquire_base_path_lock ~previous_owner ~lease_root base_path =
  let acquired =
    match
      Server_startup_takeover.lease_run_dir lease_root ~base_path, previous_owner
    with
    | Error rejection, (Refuse_previous_owner | Wait_for_previous_owner) ->
      Server_startup_takeover.Base_path_rejected rejection
    | Ok run_dir, Refuse_previous_owner ->
      Server_startup_takeover.acquire_base_path_lock ~run_dir base_path
    | Ok run_dir, Wait_for_previous_owner ->
      (match
         Server_startup_takeover.acquire_base_path_lock_after_owner_exits ~run_dir
           ~on_wait:(announce_wait_for_previous_owner ~base_path) base_path
       with
       | Ok acquired -> acquired
       | Error (Server_startup_takeover.Another_replacement_waits { waiter; waiter_path }) ->
         let named =
           match Server_startup_takeover.base_path_owner_pid waiter with
           | Some pid -> Printf.sprintf "PID %d" pid
           | None -> "an unnamed process"
         in
         Log.legacy_stderr ~level:Log.Error ~module_name:"Server"
           (Printf.sprintf
              "[FATAL] Another replacement (%s, %s) already waits for the previous \
               owner of %s; it starts once that owner exits. This process waits for \
               nothing and exits."
              named (Filename.quote waiter_path) base_path);
         exit 1)
  in
  match acquired with
  | Server_startup_takeover.Base_path_acquired lease -> lease
  | Server_startup_takeover.Base_path_already_owned { owner; lock_path } ->
      let detail =
        Server_startup_takeover.base_path_contention_message
          ~base_path ~lock_path owner
      in
      Log.legacy_stderr ~level:Log.Error ~module_name:"Server"
        ("[FATAL] " ^ detail);
      exit 1
  | Server_startup_takeover.Base_path_rejected rejection ->
      Log.legacy_stderr ~level:Log.Error ~module_name:"Server"
        (Printf.sprintf
           "[FATAL] BasePath ownership boundary rejected %s: %s"
           base_path
           (Server_startup_takeover.base_path_lock_rejection_to_string rejection));
      exit 1

(* The startup work of a single user, under the BasePath lease and before a
   Keeper starts: three passes delete files (retained checkpoints, checkpoint
   objects, the settled archive) and one only counts (original request
   bodies). It takes the judgment of the boot and reads the base path out of
   it, so it runs neither before the judgment nor on another base path. It
   does nothing for the account server, which starts no Keeper and writes
   none of this state, and a boot that the judgment refuses does not reach
   it. *)
let sweep_single_user_state (judged : Server_runtime_bootstrap.judged) =
  match judged.Server_runtime_bootstrap.booted with
  | Authz_boot_mode_read.Multi_account (_ : Authz_boot_mode_read.multi_account) -> ()
  | Authz_boot_mode_read.Single_user single_user ->
    let canonical_base_path = Authz_boot_mode_read.single_user_base_path single_user in
    (* The BasePath writer lease is held and no keeper has started, so no
       retention is between writing its file and committing the execution that
       names it. *)
    (let runtime_root =
       (Workspace.backend_config_for canonical_base_path).Backend_types.base_path
     in
     (* Optional cleanup: an exception from it is logged, never a failed boot. *)
     (match Masc.Keeper_retained_checkpoint_sweep.run ~runtime_root with
      | exception exn ->
        Log.Server.warn "[Startup] retained checkpoint sweep raised: %s"
          (Printexc.to_string exn)
      | Error error ->
        Log.Server.warn "[Startup] retained checkpoint sweep skipped: %s"
          (Masc.Keeper_retained_checkpoint_sweep.error_to_string error)
      | Ok { live_references; removed; removed_bytes; failures } ->
        Log.Server.info
          "[Startup] retained checkpoint sweep: removed=%d bytes=%d live_references=%d failures=%d"
          removed removed_bytes live_references (List.length failures);
        List.iter
          (fun failure -> Log.Server.warn "[Startup] retained checkpoint sweep: %s" failure)
          failures);
     (* After the retained sweep, so the accepted checkpoints it removed are no
        longer roots. Optional cleanup, logged as the one above. *)
     let started = Unix.gettimeofday () in
     match
       Masc.Keeper_checkpoint_object_sweep.run ~runtime_root
         ~journal_inputs_dir:(Keeper_journal_preparation.input_directories canonical_base_path)
         ~journal_input_head:Keeper_journal_preparation.input_checkpoint_basename
     with
     | exception exn ->
       Log.Server.warn "[Startup] checkpoint object sweep raised: %s" (Printexc.to_string exn)
     | Error error ->
       Log.Server.warn "[Startup] checkpoint object sweep skipped: %s"
         (Masc.Keeper_checkpoint_object_sweep.error_to_string error)
     | Ok { sessions; roots; kept; removed; removed_bytes; failures } ->
       Log.Server.info
         "[Startup] checkpoint object sweep: sessions=%d roots=%d kept=%d removed=%d bytes=%d failures=%d elapsed_s=%.3f"
         sessions roots kept removed removed_bytes (List.length failures)
         (Unix.gettimeofday () -. started);
       List.iter
         (fun failure -> Log.Server.warn "[Startup] checkpoint object sweep: %s" failure)
         failures);
    (* The process lease is held and no original-request writer has started. *)
    let original_inventory_started = Unix.gettimeofday () in
    let original_inventory_elapsed () = max 0. (Unix.gettimeofday () -. original_inventory_started) in
    (match Masc.Lane_addon_original_body_inventory.run_at_startup ~base_path:canonical_base_path with
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
    (* RFC-0498 layer three a: the settled-archive pass deletes under the same
       lease, before any settle can run. *)
    let sweep_started = Unix.gettimeofday () in
    (match Server_settled_archive_sweep.run_at_startup ~base_path:canonical_base_path with
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception exn ->
       Log.Server.warn "[Startup] settled archive sweep unavailable elapsed_s=%.3f: %s"
         (Unix.gettimeofday () -. sweep_started) (Printexc.to_string exn)
     | Error error ->
       Log.Server.warn "[Startup] %s elapsed_s=%.3f"
         (Server_settled_archive_sweep.error_to_string error) (Unix.gettimeofday () -. sweep_started)
     | Ok report ->
       Log.Server.info
         "[Startup] settled archive sweep: live_records=%d named_ids=%d kept_records=%d removed_records=%d removed_record_bytes=%Ld removed_bodies=%d removed_body_bytes=%Ld elapsed_s=%.3f"
         report.live_records report.named_ids report.kept_records report.removed_records
         report.removed_record_bytes report.removed_bodies report.removed_body_bytes
         (Unix.gettimeofday () -. sweep_started))
;;

(* [prepare_identity] runs in the process that serves, after the runtime events
   step: that step may exec this binary again, and the work done before it is
   done twice. Hashing the executable and probing the repository belong to the
   serving process only (#48156). *)
let run_cmd ?schema_observation ?(record_default = false) ?(previous_owner = Refuse_previous_owner) ~prepare_identity ~executable_path host port cli_base_path accept_store_quarantine =
  Printexc.record_backtrace true;
  (* Read before the workspace directory is created or its lease taken, so a
     host the socket cannot bind leaves nothing behind. *)
  let bind_address =
    match Server_bootstrap_http.parse_bind_address host with
    | Ok address -> address
    | Error error ->
      Printf.eprintf
        "[FATAL] %s\n%!"
        (Server_bootstrap_http.bind_address_error_to_string error);
      exit 1
  in
  let workspace =
    Server_base_path_guard.exit_on_no_workspace
      (Server_base_path_guard.startup_root ~cli_base_path)
  in
  let raw_base_path = workspace.Workspace_root.requested in
  let normalized_base_path = workspace.Workspace_root.root in
  let resolution_source = Workspace_root.source_label workspace.Workspace_root.source in
  let stripped_base_path =
    Env_config.strip_path_trailing_slashes (String.trim raw_base_path)
  in
  (* Preserve support for a not-yet-created explicit workspace root, then
     freeze one canonical identity before acquiring any ownership lease or
     constructing paths that survive startup. *)
  Fs_compat.mkdir_p normalized_base_path;
  let canonical_base_path =
    match Server_base_path_guard.canonicalize_existing normalized_base_path with
    | Ok canonical -> canonical
    | Error error ->
      Printf.eprintf
        "%s\n"
        (Server_base_path_guard.format_canonicalization_error error);
      exit 1
  in
  let on_ready () =
    if record_default then
    (match workspace.Workspace_root.source with
     | Workspace_root.Flag | Workspace_root.Environment | Workspace_root.Current_directory ->
       (match Env_config.record_default_base_path canonical_base_path with
        | Env_config.Recorded _ -> ()
        | Env_config.No_record_location ->
          Log.Server.warn
            "default workspace not recorded: no absolute XDG_CONFIG_HOME and no HOME are set; pass --base-path to later commands"
        | Env_config.Refused_under_test ->
          Log.Server.warn
            "default workspace not recorded: a test executable does not write the operator's default"
        | Env_config.Record_failed { record; reason } ->
          Log.Server.warn
            "default workspace not recorded: could not write %s (%s); pass --base-path to later commands"
            record reason
        | Env_config.Not_a_workspace { path } ->
          Log.Server.warn
            "default workspace not recorded: %s holds no .masc/config (is MASC_CONFIG_DIR set?); pass --base-path to later commands"
            path)
     | Workspace_root.Recorded _ -> ())
  in
  let masc_dir = Filename.concat canonical_base_path Common.masc_dirname in
  let base_path_lease =
    acquire_base_path_lock ~previous_owner
      ~lease_root:(Host_config.host ()).base_path_lease_root canonical_base_path
  in
  (* The lease has established the canonical .masc boundary. OCaml read its
     event-directory environment before entering ML, so the default needs a
     same-process exec before any thread, sampler, or scheduler.
     Reuse the deployment handoff capability rather than release ownership
     while the replacement runtime reacquires its process-lifetime handle. *)
  let event_startup =
    match Masc_runtime_events.prepare_process
        ~base_path:canonical_base_path ~executable_path ~argv:Sys.argv
        ~before_exec:(fun () ->
          Server_startup_takeover.prepare_base_path_lease_exec_handoff base_path_lease)
    with
    | result -> result
    | exception error ->
      let backtrace = Printexc.get_raw_backtrace () in
      Server_startup_takeover.release_base_path_lease base_path_lease;
      Printexc.raise_with_backtrace error backtrace
  in
  (match event_startup with
   | Ok () -> ()
   | Error error ->
     Server_startup_takeover.release_base_path_lease base_path_lease;
     Printf.eprintf "%s\n"
       (Masc_runtime_events.startup_error_to_string
          ~handoff_error_to_string:Server_startup_takeover.base_path_lock_rejection_to_string
          error);
     exit 1);
  (match prepare_identity () with
   | Ok () -> ()
   | Error (message, code) ->
     Server_startup_takeover.release_base_path_lease base_path_lease;
     Printf.eprintf "%s\n" message;
     exit code);
  (* From here on nothing depends on the directory the server was launched
     from, which may be a worktree removed while the server runs (#49545). *)
  (match Server_base_path_guard.enter canonical_base_path with
   | Ok () -> ()
   | Error message ->
     Server_startup_takeover.release_base_path_lease base_path_lease;
     Printf.eprintf "%s\n" message;
     exit 1);
  Log.init_from_env ();
  let shutdown_cfg =
    match Masc.Shutdown.config_from_env_result () with
    | Ok config -> config
    | Error error ->
        Log.Server.error "[FATAL] Invalid shutdown configuration: %s"
          (Masc.Shutdown.config_error_to_string error);
        exit 1
  in
  if stripped_base_path <> ""
     && String.equal (Filename.basename stripped_base_path) Common.masc_dirname
  then
    Log.Server.warn
      "Normalizing --base-path from %s to %s because runtime base paths must point at the workspace root, not the .masc directory."
      raw_base_path canonical_base_path;
  Unix.putenv Env_config_core.base_path_env_key canonical_base_path;
  Workspace_utils_backend_setup.cache_resolved_base_path canonical_base_path;
  Unix.putenv "MASC_BASE_PATH_RESOLUTION_SOURCE" resolution_source;
  (* Persist logs inside .masc/logs/ — colocated with state, not a sibling.
     Previous code wrote to base_path/logs/ which diverged from .masc/ when
     base_path differed from the repo checkout directory. *)
  let log_dir = Filename.concat masc_dir "logs" in
  (* No Eio loop runs here, so [Fs_compat.mkdir_p] takes its [Unix] path and
     a refused mkdir is a [Unix_error]. Both failures end the boot like the
     refusals around them: one [FATAL] sentence and exit 1. Left to escape,
     the exception reaches the command line parser, which exits 125 (#51246).
     The file sink is not up, and a record emitted now would retry the
     directory that was just refused, so the sentence goes to stderr. *)
  (match Fs_compat.mkdir_p log_dir with
   | () -> ()
   | exception Unix.Unix_error (error, call, path) ->
     Printf.eprintf "[FATAL] cannot create the log directory %s: %s (%s %s)\n%!"
       log_dir (Unix.error_message error) call path;
     exit 1);
  (match Log.Ring.init_file_sink log_dir with
   | Ok () -> ()
   | Error error ->
     Printf.eprintf "[FATAL] %s\n%!" (Log.Ring.file_sink_error_to_string error);
     exit 1);
  (* Before any keeper boots, as for the console mirror below: the JSONL
     append and flush move to one OS thread, so a slow write() no longer
     stops the producing domain. They were the main thread's largest
     blocking call after #46467 (#46410). *)
  Log.Ring.start_writer ();
  Log.Ring.cleanup_old_files log_dir;
  (* HIGH-RISK-UNREVIEWED: the account mode is judged here, once per boot.
     The lease is held, the log sinks are up, and nothing that belongs to one
     kind of server has run. [Authz_boot_mode_read.boot] is to be called
     inside an Eio event loop (its interface), so the judgment runs in a loop
     of its own, which ends before the startup work of a single user and
     before the loop of the server. Only values leave it: no open file and
     no lock crosses to the loop of the server.

     A refusal and an exception both end the boot with a [FATAL] record and
     exit 1, as they did when the judgment ran inside the loop of the
     server. An exception left to escape from here would reach the command
     line parser, which prints it and exits 125 with no log record. The
     console mirror has not started, so the caller writes the line to the
     console before the process exits; the mirror drains nothing at exit.

     The handlers of SIGTERM and SIGINT are installed inside the loop of the
     server. A signal that arrives during the judgment or the startup work
     ends the process by the default action, as it always did during the
     startup work. *)
  let judged =
    match
      Eio_main.run (fun _env ->
        Server_runtime_bootstrap.judge ~lease:base_path_lease ~base_path:canonical_base_path)
    with
    | Ok judged -> judged
    | Error refusal ->
      Log.Server.error "[FATAL] %s" (Server_runtime_bootstrap.judge_refusal_to_string refusal);
      exit 1
    | exception exn ->
      let bt = Printexc.get_backtrace () in
      Log.Server.error "[FATAL] The account mode judgment raised: %s" (Printexc.to_string exn);
      if bt <> "" then Log.Server.error "[FATAL] Backtrace:\n%s" bt;
      exit 1
  in
  (* Decouple console mirror writes from the Eio domain before any keeper
     boots: with fd 2 on a pty, a full pty buffer (scrollback/copy-mode)
     blocks write(2) outside the scheduler and halts the whole fleet
     (#20684, 2026-06-10 live stall). It starts after the judgment so that
     the line of a refused boot is on the console when the process exits:
     of 24 refused boots measured with the mirror already running, three
     ended before the mirror wrote the line. *)
  Console_sink.start ();
  sweep_single_user_state judged;
  (* Only the server samples. Sampling starts before the [Eio_main.run] of
     the server so the executor pool, which the main domain spawns while
     sampling, shares the profile and the boot-time loads of the server loop
     are in the tables. It starts after the judgment and after the startup
     work of a single user, so what those two allocate is not in the tables,
     the judged value that the server keeps included. The rate is a tenth
     of the one the OCaml manual reports as having no visible effect.
     GET /api/v1/diagnostics/memprof reads the tables. *)
  Alloc_profile.start ~sampling_rate:Alloc_profile.default_sampling_rate;
  (* Hoisted above [Eio_main.run]: the scheduler-EINTR fatal handler reads
     the pending signal after the scheduler has escaped (#43225), so the cell
     must outlive the run. The watcher fiber inside still owns consumption. *)
  let pending_shutdown_signal : Masc.Shutdown.signal option Atomic.t =
    Atomic.make None
  in
  let run_inside_scheduler env =
  Crypto_rng.ensure_default ();

  (* Enable Eio-aware locking globally (single call replaces per-module enable_eio) *)
  Eio_guard.enable ();

  (* Set global clock for Time_compat (Eio-native timestamps).
     Dashboard_cache.now() reads from Time_compat directly. *)
  Time_compat.set_clock (Eio.Stdenv.clock env);

  (* RFC-0372 Phase 3: register the clock with Dashboard_cache so every
     [get_or_compute] runs under a timeout. Without this the 37 call sites that
     do not pass a clock compute without any ceiling. *)
  Dashboard_cache.set_default_clock (Eio.Stdenv.clock env);

  (* Wire Runtime_events listener. After masc#18567 removed dead
     [Http_server_eio.start] (the only prior production caller), this
     would have been silently uninitialized. Idempotent-safe per
     [Masc_runtime_events] mli; consumed by Olly / custom callbacks
     to bracket agent turn spans ([emit_turn_start]/[emit_turn_end]). *)
  Masc_runtime_events.start_listener ();
  Masc.Fusion_official_client.sweep_stale_antigravity_panel_roots ();

  (* Signal handlers do the minimum async-signal-safe work: mark the sticky
     global flag so any fiber that observes [Eio.Cancel.Cancelled] before the
     watcher fiber wakes up can still classify itself as a graceful drop
     ([Keeper_registry_types_failure.fiber_drop_cause]: [Graceful_shutdown]),
     then enqueue the signal name for the Eio watcher fiber to consume.
     [Atomic.set]/[Atomic.get] are lock-free and signal-safe.
     [pending_shutdown_signal] itself is bound above [Eio_main.run] so the
     scheduler-EINTR fatal handler can read it after an escape. *)
  let shutdown_watchdog : Masc.Shutdown.watchdog option Atomic.t = Atomic.make None in
  let request_shutdown signal =
    Masc.Shutdown.mark_shutting_down ();
    Runtime_host_lifecycle.mark_shutting_down ();
    if Option.is_none (Atomic.get pending_shutdown_signal) then
      Atomic.set pending_shutdown_signal (Some signal)
  in
  Sys.set_signal
    Sys.sigterm
    (Sys.Signal_handle (fun _ -> request_shutdown Masc.Shutdown.Sigterm));
  Sys.set_signal
    Sys.sigint
    (Sys.Signal_handle (fun _ -> request_shutdown Masc.Shutdown.Sigint));

  let start () =
    (try
      Server_session_switch.run @@ fun ~runtime_sw sw ->
      let clock = Eio.Stdenv.clock env in
      let rec await_shutdown_signal () =
        match Atomic.exchange pending_shutdown_signal None with
        | None ->
            Eio.Time.sleep clock 0.05;
            await_shutdown_signal ()
        | Some signal ->
            let force_timeout = shutdown_cfg.force_timeout_s in
            let t_shutdown_start = Unix.gettimeofday () in
            let signal_name = Masc.Shutdown.signal_name signal in
            let watchdog =
              Masc.Shutdown.start_process_deadline_watchdog_or_exit
                ~timeout_s:force_timeout
            in
            Atomic.set shutdown_watchdog (Some watchdog);
            Log.Server.info
              ~diagnostic_kind:(Log.External_signal signal_name)
              "[MASC] Received %s, shutting down gracefully (timeout=%.0fs, hard_exit=%d)..."
              signal_name force_timeout Masc.Shutdown.process_deadline_exit_code;
            (* Phase 1: Notify SSE clients *)
            let t_phase = Unix.gettimeofday () in
            let shutdown_data =
              Printf.sprintf
                {|{"jsonrpc":"2.0","method":"notifications/shutdown","params":{"reason":"%s","message":"Server is shutting down, please reconnect"}}|}
                signal_name
            in
            Sse.broadcast (Yojson.Safe.from_string shutdown_data);
            Log.Server.info
              "[Shutdown] Phase 1/4 NOTIFY: sent to %d SSE clients (%.2fs) [active conn: %d, ws: %d]"
              (Sse.client_count ())
              (Unix.gettimeofday () -. t_phase)
              (Server_mcp_transport_http_conn.active_session_count ())
              (Server_mcp_transport_ws.session_count ());

            Eio.Time.sleep clock shutdown_cfg.notify_delay_s;
            (* Phase 2: Run shutdown hooks with cleanup timeout. Native Lane
               Add-on instances are detached alongside, under the same
               timeout, by the binary that wrote their cleanup descriptors.
               There is no room after the Board flush: the switch cancel that
               follows takes seconds more before the process deadline is
               disarmed. A detach the timeout cuts short leaves its binding
               for the next server, as before
               (RFC lane-addon-shutdown-detaches-native-instances §3). *)
            let t_phase = Unix.gettimeofday () in
            Log.Server.info "[Shutdown] Phase 2/4 HOOKS: starting (timeout=%.1fs)"
              shutdown_cfg.cleanup_timeout_s;
            Eio.Fiber.both
              (fun () ->
                try
                  Eio.Time.with_timeout_exn clock shutdown_cfg.cleanup_timeout_s
                    (fun () -> Masc.Shutdown_hooks.run_all ())
                with
                | Eio.Time.Timeout ->
                    Log.Server.warn
                      "[Shutdown] Phase 2/4 HOOKS: timeout after %.1fs, proceeding (total=%.1fs)"
                      shutdown_cfg.cleanup_timeout_s
                      (Unix.gettimeofday () -. t_shutdown_start)
                | Eio.Cancel.Cancelled _ as e -> raise e
                | exn ->
                    Log.Server.warn
                      "[Shutdown] Phase 2/4 HOOKS: failed after %.2fs: %s"
                      (Unix.gettimeofday () -. t_phase)
                      (Printexc.to_string exn))
              (fun () ->
                try
                  Eio.Time.with_timeout_exn clock shutdown_cfg.cleanup_timeout_s
                    Masc.Shutdown_hooks.run_lane_addon_shutdown;
                  Log.Server.info "[Shutdown] Phase 2/4 LANE: done (%.2fs)"
                    (Unix.gettimeofday () -. t_phase)
                with
                | Eio.Time.Timeout ->
                    Log.Server.warn
                      "[Shutdown] Phase 2/4 LANE: timeout after %.1fs; the next server recovers what is left (total=%.1fs)"
                      shutdown_cfg.cleanup_timeout_s
                      (Unix.gettimeofday () -. t_shutdown_start)
                | Eio.Cancel.Cancelled _ as e -> raise e
                | exn ->
                    Log.Server.warn
                      "[Shutdown] Phase 2/4 LANE: failed after %.2fs: %s"
                      (Unix.gettimeofday () -. t_phase)
                      (Printexc.to_string exn));
            let now = Unix.gettimeofday () in
            Log.Server.info "[Shutdown] Phase 2/4 HOOKS: done (%.2fs, total=%.1fs) [active conn: %d, ws: %d]"
              (now -. t_phase)
              (now -. t_shutdown_start)
              (Server_mcp_transport_http_conn.active_session_count ())
              (Server_mcp_transport_ws.session_count ());
            (* Phase 3: Board flush with 2s timeout *)
            let t_phase = Unix.gettimeofday () in
            Log.Server.info "[Shutdown] Phase 3/4 BOARD: flush starting (timeout=2.0s)";
            (try
              Eio.Time.with_timeout_exn clock 2.0
                (fun () -> Board_dispatch.flush ())
            with
            | Eio.Time.Timeout ->
                Log.Server.warn
                  "[Shutdown] Phase 3/4 BOARD: timeout after 2.0s (total=%.1fs)"
                  (Unix.gettimeofday () -. t_shutdown_start)
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
                Log.Server.warn
                  "[Shutdown] Phase 3/4 BOARD: skipped after %.2fs: %s"
                  (Unix.gettimeofday () -. t_phase)
                  (Printexc.to_string exn));
            let now = Unix.gettimeofday () in
            Log.Server.info "[Shutdown] Phase 3/4 BOARD: done (%.2fs, total=%.1fs) [active conn: %d, ws: %d]"
              (now -. t_phase)
              (now -. t_shutdown_start)
              (Server_mcp_transport_http_conn.active_session_count ())
              (Server_mcp_transport_ws.session_count ());

            (* Phase 4: Return normally — Eio.Fiber.first will cancel
               run_server cleanly via Eio.Cancel.Cancelled. *)
            Log.Server.info
              "[Shutdown] Phase 4/4 CANCEL: server cancel (total=%.1fs) [active conn: %d, ws: %d]"
              (Unix.gettimeofday () -. t_shutdown_start)
              (Server_mcp_transport_http_conn.active_session_count ())
              (Server_mcp_transport_ws.session_count ());
            ()
            in
            Eio.Fiber.first
            (fun () ->
              run_server
                ~sw
                ~runtime_sw
                ~env
                ~address:bind_address
                ~port
                ~judged
                ~input_base_path:raw_base_path
                ~on_ready
                ~accept_store_quarantine)
            await_shutdown_signal;
            (* Server stopped; close SSE connections after server is down. *)
            (try Server_mcp_transport_http_conn.close_all_sse_connections ()
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
                Log.Server.warn "shutdown: SSE close error: %s"
                  (Printexc.to_string exn));
            Log.Server.info "MASC MCP: Server stopped, waiting for background fibers... [active conn: %d, ws: %d]"
            (Server_mcp_transport_http_conn.active_session_count ())
            (Server_mcp_transport_ws.session_count ());
            (* Failing the switch cancels all remaining background fibers.
               Returning normally would leave non-daemon background loops
               running and make [Eio.Switch.run] wait forever. *)
            raise Graceful_shutdown

    with
    | Graceful_shutdown ->
        Log.Server.info "MASC MCP: Background fibers finished, shutdown complete."
    | Eio.Cancel.Cancelled _ ->
        Log.Server.info "MASC MCP: Server cancelled, waiting for background fibers..."
    | exn
      when Masc.Shutdown.is_benign_termination
             ~benign:(function
               | Graceful_shutdown | Eio.Cancel.Cancelled _ -> true
               | _ -> false)
             exn ->
        (* Failing the switch to end shutdown cancels in-flight fibers; a
           cancellable finalizer then raises [Cancelled] wrapped as
           [Fun.Finally_raised], which Eio combines with [Graceful_shutdown]
           into one [Eio.Exn.Multiple].  [is_benign_termination] unwraps that
           wrapper structure and classifies the leaves, so the combined value
           is recognised as a clean shutdown rather than falling through to the
           [FATAL] handler below and exiting 1 on every restart (#25118). The
           caller-side [benign] classifies only leaf exceptions. *)
        Log.Server.info
          "MASC MCP: Background fibers finished, shutdown complete (with benign in-flight cancellations)."
    | Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
        Log.Server.error "[FATAL] Listener bind refused: port=%d errno=EADDRINUSE (%s)"
          port (Unix.error_message Unix.EADDRINUSE);
        exit 1
    | Unix.Unix_error (Unix.EACCES, _, _) ->
        Log.Server.error "[FATAL] Permission denied binding to port %d" port;
        exit 1
    | Out_of_memory ->
        Printf.eprintf "[FATAL] Out_of_memory\n%!";
        exit 1
    | Stack_overflow ->
        Printf.eprintf "[FATAL] Stack_overflow\n%!";
        exit 1
    | exn ->
        let bt = Printexc.get_backtrace () in
        Log.Server.error "[FATAL] Unhandled exception: %s" (Printexc.to_string exn);
        if bt <> "" then Log.Server.error "[FATAL] Backtrace:\n%s" bt;
        exit 1)
  in
  start ();
  (match Atomic.get shutdown_watchdog with
   | None -> ()
   | Some watchdog ->
       (match Masc.Shutdown.disarm_deadline_watchdog watchdog with
        | Masc.Shutdown.Disarmed | Masc.Shutdown.Already_disarmed -> ()
        | Masc.Shutdown.Already_fired ->
            Masc.Shutdown.await_deadline_watchdog watchdog));
  Log.Server.info "MASC MCP: Shutdown complete."
  in
  (* [Eio_posix.Sched.clear_event_fd] in the locked eio 1.3 lets EINTR escape
     the scheduler loop, killing the server (#43225). The loop state is
     unrecoverable from the outside, so record the signal and process state,
     then exit. Only EINTR is caught here; anything else keeps its existing
     path to the toplevel. Every sampled field is scheduler-independent
     (atomics, a try-lock counter, module-init constants). *)
  let run_observed env =
    match schema_observation with
    | None -> run_inside_scheduler env
    | Some (mode, directory) ->
      (* Runtime-events setup above can exec this same argv before starting
         the scheduler. Own the output only after that handoff, and install
         the finalizer only after exclusive creation succeeds. *)
      Unix.mkdir directory 0o700;
      let observer = Agent_core.Base.Schema_observation.create ~mode in
      let write_report () =
          (* All server-owned switches and pool jobs have settled. The
             observer binding is gone before snapshot serialization and I/O. *)
          let report = Agent_core.Base.Schema_observation.snapshot observer in
          match Fs_compat.write_file_atomic_strict_staged
                  (Filename.concat directory "report.json")
                  ~write:(fun channel ->
                    Agent_core.Base.Schema_observation.write_report_json
                      ~write:(output_string channel) report) with
          | Ok () -> ()
          | Error failure ->
            Printexc.raise_with_backtrace failure.exception_ failure.backtrace
      in
      match Agent_core.Base.Schema_observation.within observer
              (fun () -> run_inside_scheduler env) with
      | result ->
          (* Keep report-only failures on the existing finalizer path. In
             particular, report I/O EINTR is not a scheduler-loop EINTR. *)
          Fun.protect (fun () -> result) ~finally:write_report
      | exception primary ->
          let primary_backtrace = Printexc.get_raw_backtrace () in
          (match write_report () with
           | () -> Printexc.raise_with_backtrace primary primary_backtrace
           | exception report_error ->
               let report_backtrace = Printexc.get_raw_backtrace () in
               let primary_failure = primary, primary_backtrace in
               let report_failure = report_error, report_backtrace in
               let log_other (error, backtrace) =
                 Eio.traceln "schema-observe: additional failure: %s\n%s"
                   (Printexc.to_string error)
                   (Printexc.raw_backtrace_to_string backtrace)
               in
               let preserve_reserved (error, backtrace) other =
                 match Agent_core.Llm_provider.Reserved_exn.reraise_if_reserved error with
                 | () -> ()
                 | exception reserved ->
                     log_other other;
                     Printexc.raise_with_backtrace reserved backtrace
               in
               (* A primary control exception wins over any report failure.
                  [combine] would discard bare cancellation; wrapping EINTR
                  would bypass the typed scheduler diagnostic below. *)
               preserve_reserved primary_failure report_failure;
               match primary with
               | Unix.Unix_error (error, _, _) when error = Unix.EINTR ->
                   log_other report_failure;
                   Printexc.raise_with_backtrace primary primary_backtrace
               | other_primary ->
                   preserve_reserved report_failure primary_failure;
                   let combined, backtrace =
                     Eio.Exn.combine primary_failure report_failure
                   in
                   Printexc.raise_with_backtrace combined backtrace)
  in
  (match Eio_main.run run_observed with
   | () -> ()
   | exception Unix.Unix_error (Unix.EINTR, func, _) ->
     let ctx : Masc.Server_scheduler_eintr.context =
       {
         Masc.Server_scheduler_eintr.pending_shutdown =
           Atomic.get pending_shutdown_signal;
         uptime_s = Masc.Server_startup_state.elapsed_since_start ();
         mcp_sessions = Server_mcp_transport_http_conn.active_session_count ();
         ws_sessions = Server_mcp_transport_ws.try_session_count ();
         ocaml_version = Sys.ocaml_version;
         masc_version = Runtime_build_version.current;
         git_commit = Build_identity.embedded_commit;
         pid = Unix.getpid ();
       }
     in
     Log.Server.error
       "%s"
       (Masc.Server_scheduler_eintr.describe
          ctx
          ~syscall:func
          ~backtrace:(Printexc.get_backtrace ()));
     exit 1)

(* The identity a serving process reports and the dashboard it installs. *)
let initialize_served_identity () =
  let identity = Build_identity.current () in
  Installed_dashboard.initialize ~executable_path:identity.executable_path
    ~binary_commit:identity.binary_commit

let run_cmd_exit host port base_path accept_store_quarantine provenance_path provenance_sha256 provenance_device provenance_inode record_default previous_owner =
  let serve ~bind_provenance =
    let prepare_identity () =
      initialize_served_identity ();
      bind_provenance ()
    in
    run_cmd ~record_default ~previous_owner ~prepare_identity
      ~executable_path:Build_identity.resolved_executable_path
      host port base_path accept_store_quarantine;
    Cmd.Exit.ok
  in
  match provenance_path, provenance_sha256, provenance_device, provenance_inode with
  | None, None, None, None -> serve ~bind_provenance:(fun () -> Ok ())
  | Some path, Some sha256, Some device, Some inode ->
    serve ~bind_provenance:(fun () ->
      Build_identity.bind_executable_provenance ~path ~sha256 ~device ~inode
      |> Result.map_error (fun message ->
        (Printf.sprintf "invalid build provenance: %s" message, Cmd.Exit.some_error)))
  | _ ->
    Printf.eprintf
      "all build provenance path, SHA-256, device, and inode fields must be provided together\n";
    Cmd.Exit.cli_error

let login_cmd_exit base_path host port agent role client_env no_expiry
    expiry_hours as_json as_shell =
  match Auth_login.lifetime_of_flags ~no_expiry ~expiry_hours with
  | Error message ->
      Printf.eprintf "login failed: %s\n" message;
      1
  | Ok token_lifetime -> (
  match
    Auth_login.mint ~base_path ~host ~port ~agent_name:agent ~role
      ~token_env_var:client_env ~token_lifetime ()
  with
  | Error err ->
      Printf.eprintf "login failed: %s\n" (Masc_domain.masc_error_to_string err);
      1
  | Ok report ->
      let output =
        if as_shell then
          Auth_login.render_shell report
        else if as_json then
          Auth_login.to_yojson report |> Yojson.Safe.pretty_to_string
        else
          Auth_login.render_text report
      in
      print_endline output;
      0)

(* [masc token] — what bearer credentials this workspace holds, and retiring
   one. Auth.list_credentials and Auth.delete_credential have been here all
   along with nothing reaching them from a command line, so an operator who
   wanted to know what tokens existed, or to retire one, edited files under
   .masc/auth/ by hand. *)
let token_agent_arg =
  let doc = "Agent whose credential to retire." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"AGENT" ~doc)

let token_list_cmd_exit base_path =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  let creds, failures = Auth.list_credential_results base_path |> List.partition_map
      (function Ok credential -> Either.Left credential | Error error -> Either.Right error) in
  let now = Unix.gettimeofday () in
  if creds = [] && failures = []
  then print_endline "no credentials in this workspace"
  else begin
    List.iter
      (fun (c : Types_auth.agent_credential) ->
         let raw_present =
           Sys.file_exists (Auth.raw_token_file base_path c.agent_name)
         in
         print_endline (Auth_token_inventory.row ~now ~raw_present c))
      (Auth_token_inventory.ordered ~now creds);
    List.iter (fun error -> print_endline (Auth_token_inventory.error_row error)) failures;
    let expired = List.length (Auth_token_inventory.expired ~now creds) in
    Printf.printf
      "\n%d credential(s), %d expired, %d unreadable.%s\n"
      (List.length creds)
      expired
      (List.length failures)
      (if expired > 0 then " `masc token prune` removes the expired ones." else "")
  end;
  Cmd.Exit.ok

let token_revoke_cmd_exit base_path agent =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  let retired = Auth.with_credential_transaction base_path (fun transaction ->
    let open Result.Syntax in
    let* present = Auth.credential_exists_in_transaction transaction agent in
    if not present then Ok false
    else Auth.delete_credential_in_transaction transaction agent |> Result.map (fun () -> true))
    |> Result.join in
  match retired with
  | Error error ->
    Printf.eprintf "cannot retire %S: %s\n" agent (Masc_domain.masc_error_to_string error);
    Cmd.Exit.some_error
  | Ok false ->
    Printf.eprintf
      "no credential named %S; `masc token list` shows what this workspace holds\n" agent;
    Cmd.Exit.some_error
  | Ok true ->
    Printf.printf
      "retired %s. Its bearer stops validating from the next request; anything \
       still exporting it needs a new one from `masc login --agent %s`.\n"
      agent agent;
    Cmd.Exit.ok

(* Only expired credentials. Removing one that already authenticates nothing is
   garbage collection rather than a security decision, which is why this needs
   no confirmation while [revoke] names its target. *)
let token_prune_cmd_exit base_path dry_run =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  let now = Unix.gettimeofday () in
  let mode = if dry_run then Auth_token_prune.Preview else Auth_token_prune.Retire in
  match Auth_token_prune.run ~base_path ~now ~mode with
  | Error error ->
    Printf.eprintf "could not prune credentials: %s\n" (Masc_domain.masc_error_to_string error);
    Cmd.Exit.some_error
  | Ok [] ->
    print_endline "nothing to prune: no expired credentials, no orphaned stubs";
    Cmd.Exit.ok
  | Ok entries ->
    let retired = ref 0 and previewed = ref 0 and failed = ref 0 in
    List.iter
      (fun { Auth_token_prune.agent_name; reason; outcome } ->
         let why = match reason with
           | Auth_token_prune.Expired -> "expired"
           | Auth_token_prune.Orphaned_redirect -> "orphaned redirect" in
         match outcome with
         | Auth_token_prune.Would_retire ->
           incr previewed;
           Printf.printf "would retire %s (%s)\n" agent_name why
         | Auth_token_prune.Retired ->
           incr retired;
           Printf.printf "retired %s (%s)\n" agent_name why
         | Auth_token_prune.Failed error ->
           incr failed;
           Printf.eprintf "could not fully retire %s (%s; some files may already be removed): %s\n"
             agent_name why (Masc_domain.masc_error_to_string error))
      entries;
    (match mode with
     | Auth_token_prune.Preview -> Printf.printf "%d credential(s) would be retired (--dry-run)\n" !previewed
     | Auth_token_prune.Retire -> Printf.printf "%d credential(s) retired, %d failed\n" !retired !failed);
    if !failed = 0 then Cmd.Exit.ok else Cmd.Exit.some_error

let token_cmd =
  let list_cmd =
    let doc = "List this workspace's bearer credentials." in
    Cmd.v (Cmd.info "list" ~doc) Term.(const token_list_cmd_exit $ base_path)
  in
  let revoke_cmd =
    let doc = "Retire one agent's bearer credential." in
    Cmd.v (Cmd.info "revoke" ~doc)
      Term.(const token_revoke_cmd_exit $ base_path $ token_agent_arg)
  in
  let prune_cmd =
    let doc = "Retire every expired credential and every orphaned stub." in
    let dry_run =
      let doc = "List what would be retired without removing anything." in
      Arg.(value & flag & info [ "dry-run" ] ~doc)
    in
    Cmd.v (Cmd.info "prune" ~doc)
      Term.(const token_prune_cmd_exit $ base_path $ dry_run)
  in
  let doc = "Inspect and retire the workspace's bearer credentials." in
  let man =
    [ `S Manpage.s_description
    ; `P
        "`masc login` mints a bearer and replaces whatever that agent had, so \
         minting again is how a token is rotated: the previous one stops \
         validating. These are the other two halves -- seeing what exists, and \
         retiring one without minting a replacement."
    ; `P
        "The store keeps a SHA-256 of each token, never the token, so a listing \
         cannot show you a bearer you have lost. What it can show is whether \
         the raw secret is still on disk at .masc/auth/<agent>.token, which is \
         the only place it survives a mint."
    ]
  in
  Cmd.group (Cmd.info "token" ~doc ~man) [ list_cmd; revoke_cmd; prune_cmd ]

let oauth_client_id_arg =
  let doc = "Client id to revoke, as `masc oauth-client list` prints it." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"CLIENT_ID" ~doc)

(* A client chose these strings without a credential. Registration refuses
   control characters, but an older record may still hold one, so it is
   shown escaped and cannot rewrite the operator's terminal. *)
let oauth_client_terminal_text value =
  if Auth_oauth_client_metadata.has_control_character value
  then String.escaped value
  else value

let oauth_client_list_cmd_exit base_path =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  let store = Auth_oauth.oauth_store_path base_path in
  match Auth_oauth.list_clients ~base_path with
  | Error error ->
    Printf.eprintf "cannot read OAuth clients: %s\n" (Auth_oauth.show_error error);
    Cmd.Exit.some_error
  | Ok None ->
    Printf.printf "no OAuth store at %s\n" store;
    Cmd.Exit.ok
  | Ok (Some listings) ->
    List.iter
      (fun { Auth_oauth.client = (client : Auth_oauth.client); live_families } ->
         Printf.printf "%s  %s  live_token_families=%d  redirect_uris=%s\n"
           client.client_id
           (oauth_client_terminal_text
              (Option.value ~default:"(no name)" client.client_name))
           live_families
           (String.concat "," (List.map oauth_client_terminal_text client.redirect_uris)))
      listings;
    Printf.printf
      "%d registered clients stored in %s; this shell's MASC_OAUTH_MAX_CLIENTS \
       allows %d (the server uses its own environment)\n"
      (List.length listings)
      store
      (Env_config_runtime_services.OAuth.max_clients ());
    Cmd.Exit.ok

let oauth_client_revoke_cmd_exit base_path client_id =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  match Auth_oauth.revoke_client ~base_path ~client_id with
  | Error error ->
    Printf.eprintf "cannot revoke %S: %s\n" client_id (Auth_oauth.show_error error);
    Cmd.Exit.some_error
  | Ok None ->
    Printf.eprintf
      "no registered client %S in %s; `masc oauth-client list` shows what is stored\n"
      client_id
      (Auth_oauth.oauth_store_path base_path);
    Cmd.Exit.some_error
  | Ok (Some { Auth_oauth.revoked_families }) ->
    Printf.printf "revoked %s and %d live token famil%s\n" client_id revoked_families
      (if revoked_families = 1 then "y" else "ies");
    Cmd.Exit.ok

let oauth_client_cmd =
  let list_cmd =
    let doc = "List the clients Dynamic Client Registration stored." in
    Cmd.v (Cmd.info "list" ~doc) Term.(const oauth_client_list_cmd_exit $ base_path)
  in
  let revoke_cmd =
    let doc = "Revoke one registered client and every token issued to it." in
    Cmd.v (Cmd.info "revoke" ~doc)
      Term.(const oauth_client_revoke_cmd_exit $ base_path $ oauth_client_id_arg)
  in
  let doc = "Inspect and release the OAuth clients registered on this workspace." in
  let man =
    [ `S Manpage.s_description
    ; `P
        "Dynamic Client Registration needs no credential, and the store holds \
         at most MASC_OAUTH_MAX_CLIENTS clients. Once it is full a new \
         registration is refused until a client is revoked here. Revoking \
         revokes the client's open token families first, so its access and \
         refresh tokens stop working, then deletes its record."
    ; `P
        "Clients that sign in with a Client ID Metadata Document (an https \
         client_id, as Claude Code does) are not stored and do not appear."
    ]
  in
  Cmd.group (Cmd.info "oauth-client" ~doc ~man) [ list_cmd; revoke_cmd ]

let auth_cmd =
  let external_store =
    let doc =
      "Absolute path of the external store of the authorization log. Put it \
       outside what the backups of the base path copy: a backup restored over \
       the base path must not take the store back with it."
    in
    Arg.(required & opt (some string) None & info [ "external-store" ] ~docv:"PATH" ~doc)
  in
  let bootstrap_cmd =
    let doc =
      "Activate multi-account use while no server runs on the workspace, and \
       print the link of the first Admin invitation once."
    in
    let man =
      [ `S Manpage.s_description
      ; `P
          "config.json must ask for account_mode Multi_account with enabled \
           and require_token, MASC_ALLOW_ANONYMOUS_MUTATIONS must be off in \
           this shell, and the workspace must hold no authorization log and \
           no external store yet. The command takes the workspace lease, so \
           stop the server first."
      ; `P
          "MASC_HTTP_BASE_URL must be the http(s) address the person opens; \
           the link is built on it."
      ; `P
          "The link carries the invitation token after #, so a browser keeps \
           it out of the request URL. Only a digest of the token is written. \
           The invitation works once and expires after 24 hours."
      ; `P
          ("Once the command succeeds, "
           ^ Masc_cli_auth.account_server_line
           ^ ". "
           ^ String.capitalize_ascii Authz_boot_mode_read.turn_off_line
           ^ ".")
      ]
    in
    Cmd.v
      (Cmd.info "bootstrap" ~doc ~man)
      Term.(
        const (fun base_path external_store ->
          Masc_cli_auth.bootstrap
            ~base_path:(Env_config.normalize_masc_base_path_input base_path)
            ~external_store)
        $ base_path
        $ external_store)
  in
  let invite_cmd =
    let doc =
      "Write one more Admin invitation while no server runs on the workspace, \
       and print its link once."
    in
    let man =
      [ `S Manpage.s_description
      ; `P
          "For a first invitation that expired before it was spent, or whose \
           link was lost. The workspace must be activated with masc auth \
           bootstrap. It adds one Admin invitation each time and revokes none: \
           an earlier link stays usable until it is spent or expires, even when \
           it was lost. This build has no command that revokes an invitation or \
           writes a Member invitation."
      ; `P
          "MASC_HTTP_BASE_URL must be the http(s) address the person opens, as \
           for masc auth bootstrap. The command takes the workspace lease, so \
           stop the server first."
      ]
    in
    Cmd.v
      (Cmd.info "invite" ~doc ~man)
      Term.(
        const (fun base_path ->
          Masc_cli_auth.invite ~base_path:(Env_config.normalize_masc_base_path_input base_path))
        $ base_path)
  in
  let off_cmd =
    let doc = "Turn the accounts of an activated workspace off while no server runs on it." in
    let man =
      [ `S Manpage.s_description
      ; `P
          "Writes an Off mode event to the authorization log and the external \
           store. The log must have made Multi_account, and the external store \
           must match it; config.json may ask for anything. The command takes \
           the workspace lease, so stop the server first."
      ; `P
          "Once config.json does not ask for Multi_account (take account_mode \
           out), a server boots a single user. The records of the accounts stay \
           read-only: no turn runs for a Keeper or on a Runtime of the log, and \
           no client starts on a home under .masc/accounts. A config.json that \
           asks for Multi_account again is a reactivation, which this build \
           refuses."
      ]
    in
    Cmd.v
      (Cmd.info "off" ~doc ~man)
      Term.(
        const (fun base_path ->
          Masc_cli_auth.off ~base_path:(Env_config.normalize_masc_base_path_input base_path))
        $ base_path)
  in
  let preview_cmd =
    let doc =
      "Serve a localhost preview of multi-account login on 127.0.0.1, while no \
       server runs on the workspace."
    in
    let man =
      [ `S Manpage.s_description
      ; `P
          "A person signs in with GitHub, connects their own Claude Code or \
           Codex subscription, makes Runtimes and Keepers on it, and sends a \
           Keeper a message that the subscription answers once. The preview \
           serves the login routes, the routes of a person's own \
           subscriptions, Runtimes and Keepers, and the MCP endpoint of a \
           person, and no Board route. It takes the workspace lease until it \
           stops."
      ; `P
          "The workspace must be activated with masc auth bootstrap. Make the \
           invitation link with MASC_HTTP_BASE_URL=http://127.0.0.1:PORT so it \
           opens the preview."
      ; `P
          ("The GitHub OAuth App needs the callback URL \
            http://127.0.0.1/auth/github/callback; GitHub takes a loopback \
            redirect on any port. Its client secret is read from "
           ^ Masc_cli_auth.github_client_secret_env
           ^ ".")
      ]
    in
    let port =
      let doc = "The port on 127.0.0.1." in
      Arg.(value & opt int Masc_cli_auth.default_preview_port & info [ "port" ] ~docv:"PORT" ~doc)
    in
    let github_client_id =
      let doc = "The client ID of the GitHub OAuth App." in
      Arg.(required & opt (some string) None & info [ "github-client-id" ] ~docv:"ID" ~doc)
    in
    Cmd.v
      (Cmd.info "preview" ~doc ~man)
      Term.(
        const (fun base_path port github_client_id ->
          Masc_cli_auth.preview
            ~base_path:(Env_config.normalize_masc_base_path_input base_path)
            ~port
            ~github_client_id)
        $ base_path
        $ port
        $ github_client_id)
  in
  let doc = "Set up multi-account authorization on this workspace." in
  let service_credential_cmd =
    let lease_note =
      `P
        "The workspace must be activated with masc auth bootstrap. The command \
         takes the workspace lease, so stop the server first."
    in
    let normalized base_path = Env_config.normalize_masc_base_path_input base_path in
    let issue_cmd =
      let service =
        let doc = "The id of the service the credential acts as." in
        Arg.(required & opt (some string) None & info [ "service" ] ~docv:"SERVICE" ~doc)
      in
      let doc = "Issue a Service credential and print its token once." in
      Cmd.v
        (Cmd.info "issue" ~doc ~man:[ `S Manpage.s_description; lease_note ])
        Term.(
          const (fun base_path service ->
            Masc_cli_auth.service_credential_issue ~base_path:(normalized base_path) ~service)
          $ base_path
          $ service)
    in
    let revoke_cmd =
      let credential =
        let doc = "The id of the credential, as masc auth service-credential list prints it." in
        Arg.(required & opt (some string) None & info [ "credential" ] ~docv:"ID" ~doc)
      in
      let doc = "Revoke a Service credential." in
      Cmd.v
        (Cmd.info "revoke" ~doc ~man:[ `S Manpage.s_description; lease_note ])
        Term.(
          const (fun base_path credential ->
            Masc_cli_auth.service_credential_revoke ~base_path:(normalized base_path) ~credential)
          $ base_path
          $ credential)
    in
    let list_cmd =
      let doc = "List the Service credentials with their service and status, with no secret." in
      Cmd.v
        (Cmd.info "list" ~doc ~man:[ `S Manpage.s_description; lease_note ])
        Term.(
          const (fun base_path ->
            Masc_cli_auth.service_credential_list ~base_path:(normalized base_path))
          $ base_path)
    in
    let doc = "Issue, revoke and list the credentials of internal services (plan C4-9)." in
    Cmd.group (Cmd.info "service-credential" ~doc) [ issue_cmd; revoke_cmd; list_cmd ]
  in
  Cmd.group
    (Cmd.info "auth" ~doc)
    [ bootstrap_cmd; invite_cmd; off_cmd; preview_cmd; service_credential_cmd ]

let login_cmd =
  let doc =
    "Mint a local bearer token, persist its raw token file, and print \
     dashboard / MCP auth exports. Requires --client-env <VAR> to \
     name the env var your MCP client reads; the server itself is \
     client-agnostic."
  in
  let info = Cmd.info "login" ~doc in
  Cmd.v info
    Term.(
      const login_cmd_exit $ base_path $ host $ port $ login_agent
      $ login_role $ login_client_env $ login_no_expiry $ login_expiry_hours
      $ login_json $ login_shell)

(* One-touch "connect your MCP client". [login] mints and persists the bearer;
   this reuses that same local mint ([Auth_login.mint], no running server) and
   wraps the result in a ready client-config block. It exists so a new user
   pastes one block instead of assembling the URL, the bearer, and the header
   by hand. The blocks are the two shapes the docs already document
   (docs/MCP-TEMPLATE.md, README "MCP client setup"): a bearer-env TOML for
   Codex-style clients, a mcp-remote JSON for Claude Desktop, and the shell
   exports for anything that reads the token from the environment. *)
let mcp_config_agent =
  let doc = "Agent identity bound to the minted bearer token" in
  Arg.(value & opt string "local-mcp-client" & info ["agent"] ~docv:"AGENT" ~doc)

let mcp_config_client_env =
  let doc =
    "Env var name your MCP client reads to pick up the bearer token. Rendered \
     verbatim into the emitted config."
  in
  Arg.(value & opt string "MASC_TOKEN" & info ["client-env"] ~docv:"VAR" ~doc)

let mcp_config_expiring =
  let doc =
    "Mint an expiring token instead of a long-lived one. A one-touch client \
     config defaults to long-lived because a local MCP daemon cannot refresh \
     on expiry; pass this for a session-scoped bearer."
  in
  Arg.(value & flag & info ["expiring"] ~doc)

let mcp_config_client =
  let doc =
    "Which config block to emit: env (shell exports, any bearer-env client), \
     codex (bearer-env TOML), or claude-desktop (mcp-remote JSON)."
  in
  Arg.(value & opt string "env" & info ["client"] ~docv:"CLIENT" ~doc)

let mcp_config_cmd_exit base_path host port agent client_env expiring client =
  match Auth_login.mcp_client_of_string client with
  | None ->
      Printf.eprintf
        "mcp-config: unknown client %S (use env, codex, or claude-desktop)\n"
        client;
      2
  | Some mcp_client -> (
      match
        Auth_login.lifetime_of_flags ~no_expiry:(not expiring) ~expiry_hours:None
      with
      | Error message ->
          Printf.eprintf "mcp-config failed: %s\n" message;
          1
      | Ok token_lifetime -> (
          match
            Auth_login.mint ~base_path ~host ~port ~agent_name:agent
              ~role:Masc_domain.Worker ~token_env_var:client_env ~token_lifetime
              ()
          with
          | Error err ->
              Printf.eprintf "mcp-config failed: %s\n"
                (Masc_domain.masc_error_to_string err);
              1
          | Ok report ->
              print_endline (Auth_login.render_mcp_client_config report mcp_client);
              0))

let mcp_config_cmd =
  let doc =
    "Mint a bearer and print a ready MCP client config so a client can connect \
     without hand-wiring the URL, token, and header."
  in
  let info = Cmd.info "mcp-config" ~doc in
  Cmd.v info
    Term.(
      const mcp_config_cmd_exit $ base_path $ host $ port $ mcp_config_agent
      $ mcp_config_client_env $ mcp_config_expiring $ mcp_config_client)

(* `masc` with no subcommand is the product's front door, and the front door is
   the terminal: the TUI is where Keepers are watched and steered, and it starts
   this same binary as its server when nothing answers the port. So an
   interactive bare invocation hands over to [masc-tui] instead of serving.

   Every condition has to hold, because the same bare invocation is how service
   managers and containers start the server:

   - a terminal on both stdin and stdout — a pipe, a unit file or a CI step has
     neither;
   - the default loopback host — `--host 0.0.0.0` is a deployment asking for a
     server, and the TUI carries no --host to hand it;
   - no server-deployment flag — build provenance and the store-quarantine
     override are passed by the deploy path and by nothing else;
   - a `masc-tui` beside this binary or on PATH — the layout install.sh creates.
     A source checkout builds `masc_tui.exe` under a different name and the
     container image ships no TUI at all, so both keep the server they had.

   `masc start` always serves, whatever the terminal looks like. The rule itself
   lives in [Masc_front_door] so it runs under a test without a TTY; what stays
   here is the effects it reads and the handover it performs. *)
let stdio_is_a_terminal () =
  match Unix.isatty Unix.stdin && Unix.isatty Unix.stdout with
  | answer -> answer
  | exception Unix.Unix_error _ -> false

let path_is_executable candidate =
  match Unix.access candidate [ Unix.X_OK ] with
  | () -> true
  | exception Unix.Unix_error _ -> false

let front_door_cmd_exit
      host requested_port base_path accept_store_quarantine
      provenance_path provenance_sha256 provenance_device provenance_inode
      record_default =
  let serve () =
    match resolve_connection_port base_path requested_port with
    | Error error ->
      prerr_endline (Workspace_connection.error_message error);
      1
    | Ok port ->
      run_cmd_exit host (Workspace_connection.to_int port) base_path accept_store_quarantine provenance_path
        provenance_sha256 provenance_device provenance_inode record_default
        Refuse_previous_owner
  in
  let deployment_flags_present =
    record_default
    || accept_store_quarantine
    || Option.is_some provenance_path
    || Option.is_some provenance_sha256
    || Option.is_some provenance_device
    || Option.is_some provenance_inode
  in
  (* Routing only constructs an unused TUI argv. Resolve the workspace's saved
     endpoint only after the interactive journey has chosen its workspace. *)
  match Workspace_connection.resolve ~base_path:None ~cli:requested_port
          ~environment:(Env_config_core.raw_value_opt Env_config_core.http_port_env_key) with
  | Error error -> prerr_endline (Workspace_connection.error_message error); 1
  | Ok routing_port ->
  match
    Masc_front_door.decide
      ~interactive:(stdio_is_a_terminal ())
      ~host
      ~default_host:(Env_config.masc_host ())
      ~deployment_flags_present
      ~port:(Workspace_connection.to_int routing_port)
      ~base_path
      ~executable_name:Sys.executable_name
      ~path_env:(Sys.getenv_opt "PATH")
      ~is_executable:path_is_executable
  with
  | Masc_front_door.Serve -> serve ()
  | Masc_front_door.Open_tui _ ->
    Masc_cli_onboarding.run ~base_path ~port:requested_port ~resume:true ~sandbox_step:false

let start_cmd =
  let doc =
    "Start the MASC MCP server (HTTP/SSE). What `masc` with no subcommand does \
     everywhere except an interactive terminal, where the bare name opens the \
     fleet TUI instead. Use this name whenever the server is what you want."
  in
  let info = Cmd.info "start" ~doc in
  Cmd.v info
    Term.(const run_cmd_exit $ host $ port $ run_base_path $ accept_store_quarantine $ build_provenance_path $ build_provenance_sha256 $ build_provenance_device $ build_provenance_inode $ record_default_arg $ previous_owner_arg)

let schema_observe_cmd =
  let module Observation = Agent_core.Base.Schema_observation in
  let mode =
    Arg.(required & opt (some (enum
      [ "disabled", Observation.Disabled
      ; "identity", Observation.Identity_only
      ; "timed", Observation.Timed ])) None
      & info ["observation-mode"] ~docv:"MODE"
          ~doc:"Schema diagnostic mode: disabled, identity, or timed.")
  in
  let directory =
    Arg.(required & opt (some string) None
      & info ["observation-directory"] ~docv:"NEW_DIRECTORY"
          ~doc:"Create an exclusive diagnostic output directory after startup handoff. After owned server work settles, write report.json. A forced exit leaves no final report.")
  in
  let run mode directory host port = function
    | None ->
      prerr_endline "schema-observe requires an explicit --base-path for its owned workspace";
      Cmd.Exit.cli_error
    | Some workspace ->
    run_cmd ~schema_observation:(mode, directory)
      ~prepare_identity:(fun () -> initialize_served_identity (); Ok ())
      ~executable_path:Build_identity.resolved_executable_path
      host port (Some workspace) false;
    Cmd.Exit.ok
  in
  Cmd.v (Cmd.info "schema-observe"
    ~doc:"Run an owned server experiment and record actual schema work until shutdown.")
    Term.(const run $ mode $ directory $ host $ port $ run_base_path)

let init_force =
  let doc = "Overwrite existing config files instead of skipping them" in
  Arg.(value & flag & info ["force"] ~doc)

let init_record_default =
  let doc =
    "Record this workspace as the default for later commands (in \
     XDG_CONFIG_HOME/masc/default-base-path, else ~/.config). Off by default: \
     a throwaway workspace must not become the machine's default. The installer \
     and `masc setup` pass it only when run on a terminal, and the setup journey \
     passes it for the workspace chosen there."
  in
  Arg.(value & flag & info [ "record-default" ] ~doc)

type init_scope = All | Config_only | Skills_only

let init_scope =
  Arg.(value & vflag All [
    Skills_only, info ["skills-only"]
      ~doc:"Install or update unmodified builtin Skills without changing runtime config files";
    Config_only, info ["config-only"]
      ~doc:"Seed runtime config without publishing builtin Skill packages";
  ])

type init_tally = { written : int; skipped : int; failed : int }

(* [masc init] prints one line per file and per Skill. [masc setup] runs the
   same work as one step of a longer install, where hundreds of routine lines
   bury the ones that need a look, so it asks for [Summary]: routine lines are
   left out and the closing count line, failures and Skills kept for operator
   review are still printed. *)
type init_report = Every_line | Summary

(* [rel] keys the embedded tree and [dest_rel] names where it lands. They are
   the same string for every asset but the fresh-install roster, which is
   authored under [keepers-default/] and seeds as [keepers/]. *)
let seed_one ~report ~target_root ~force tally (rel, dest_rel) =
  match Embedded_config.read rel with
  | None ->
    Printf.eprintf "init: missing embedded asset: %s\n" rel;
    { tally with failed = tally.failed + 1 }
  | Some content ->
    let dest = Filename.concat target_root dest_rel in
    Fs_compat.mkdir_p (Filename.dirname dest);
    if Fs_compat.file_exists dest && not force then begin
      (match report with
       | Every_line -> Printf.printf "skip   %s (exists, --force to overwrite)\n" dest
       | Summary -> ());
      { tally with skipped = tally.skipped + 1 }
    end else
      try
        Fs_compat.save_file dest content;
        (match report with
         | Every_line -> Printf.printf "wrote  %s (%d bytes)\n" dest (String.length content)
         | Summary -> ());
        { tally with written = tally.written + 1 }
      with Sys_error msg ->
        Printf.eprintf "init: %s: %s\n" dest msg;
        { tally with failed = tally.failed + 1 }

type init_skills = { changed : int; skill_failed : bool }

(* The two outcomes a healthy install repeats on every run. Anything else is
   news to the operator, so a report this list does not name is printed. *)
let routine_skill_report = function
  | Builtin_skill_package.Bundled
      { result = Ok (Builtin_skill_package.Up_to_date
                    | Builtin_skill_package.Install_missing); _ } -> true
  | Builtin_skill_package.Bundled { result = Ok (Builtin_skill_judgement.Adopt_identical | (Builtin_skill_judgement.Adopt_with_release_permissions | (Builtin_skill_judgement.Permissions_pending _ | (Builtin_skill_judgement.Replace_recorded _ | (Builtin_skill_judgement.Replace_pending _ | (Builtin_skill_judgement.Keep_modified _ | (Builtin_skill_judgement.Keep_untracked_different _ | Builtin_skill_judgement.Keep_uninspectable _)))))));_}
  | Builtin_skill_package.Bundled { result = Error _;_} | Builtin_skill_package.Interrupted _
  | Builtin_skill_package.Retired _ | Builtin_skill_package.Unfinished _ -> false

let print_skill_report ~report skill_report =
  match report with
  | Every_line -> Printf.printf "%s\n" (Builtin_skill_package.report_to_string skill_report)
  | Summary ->
    if not (routine_skill_report skill_report)
    then Printf.printf "%s\n" (Builtin_skill_package.report_to_string skill_report)

(* Every package's verdict is printed, except that [Summary] leaves out the
   routine ones. A package that was not reconciled
   fails the command; packages kept for operator review do not, and neither
   does a leftover staging directory that could not be removed, which the next
   installation tries again. *)
let init_builtin_skills_reconcile ~report = function
  | Error error ->
    Printf.eprintf "init: builtin Skills were not reconciled: %s\n"
      (Builtin_skill_package.error_message error);
    { changed = 0; skill_failed = true }
  | Ok reports ->
    List.fold_left (fun tally skill_report ->
      print_skill_report ~report skill_report;
      match skill_report with
      | Builtin_skill_package.Bundled
          { result = Ok (Builtin_skill_package.Install_missing
                        | Builtin_skill_package.Adopt_identical
                        | Builtin_skill_package.Adopt_with_release_permissions
                        | Builtin_skill_package.Replace_recorded _); _ }
      | Builtin_skill_package.Retired
          { result = Ok (Builtin_skill_package.Retire_recorded _); _ }
      | Builtin_skill_package.Interrupted
          { result = Ok (Builtin_skill_package.Move_finished _); _ } ->
        { tally with changed = tally.changed + 1 }
      | Builtin_skill_package.Bundled
          { result = Ok (Builtin_skill_package.Up_to_date
                        | Builtin_skill_package.Permissions_pending _
                        | Builtin_skill_package.Replace_pending _
                        | Builtin_skill_package.Keep_modified _
                        | Builtin_skill_package.Keep_untracked_different _
                        | Builtin_skill_package.Keep_uninspectable _); _ }
      | Builtin_skill_package.Retired
          { result = Ok (Builtin_skill_package.Retire_pending _
                        | Builtin_skill_package.Keep_retired_modified _
                        | Builtin_skill_package.Keep_retired_uninspectable _); _ }
      | Builtin_skill_package.Interrupted
          { result = Ok (Builtin_skill_package.Move_never_started
                        | Builtin_skill_package.Move_completed); _ }
      | Builtin_skill_package.Unfinished _ -> tally
      | Builtin_skill_package.Bundled { result = Error _; _ }
      | Builtin_skill_package.Retired { result = Error _; _ }
      | Builtin_skill_package.Interrupted { result = Error _; _ } ->
        { tally with skill_failed = true })
      { changed = 0; skill_failed = false } reports

(* Says once which lock the installer waits for, so an installation stopped
   while holding it shows up instead of a silent pause. Standard error, because
   the installer script keeps standard output for its own summary. *)
let print_skill_lock_wait lock =
  Printf.eprintf "waiting for another Skill installation to release %s\n%!" lock

let init_cmd_exit_with ~report base_path force scope record_default =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  (* [init] seeds the explicitly requested workspace; runtime resolution may
     honor [MASC_CONFIG_DIR], but bootstrap materialization must not. *)
  let target_root =
    Config_dir_resolver.base_path_config_root
      ~cwd:(Config_dir_resolver.current_working_dir ())
      base_path
  in
  let result =
    if scope = Skills_only then { written = 0; skipped = 0; failed = 0 }
    else (
      Fs_compat.mkdir_p target_root;
      Fs_compat.mkdir_p (Filename.concat target_root Common.keepers_runtime_dirname);
      List.fold_left
        (seed_one ~report ~target_root ~force)
        { written = 0; skipped = 0; failed = 0 }
        (List.filter_map
           (fun rel ->
             if Common.seeds_into_fresh_config_root rel
             then Some (rel, rel)
             else
               Common.fresh_config_root_keeper_seed_target rel
               |> Option.map (fun dest_rel -> rel, dest_rel))
           Embedded_config.file_list))
  in
  let skills = match scope with
    | Config_only -> { changed = 0; skill_failed = false }
    | All | Skills_only ->
      init_builtin_skills_reconcile ~report
        (Server_runtime_config_root_bootstrap.install_builtin_skills
           ~on_wait:print_skill_lock_wait ~base_path) in
  Printf.printf "init: %d written, %d skipped, %d failed, %d builtin Skill package(s) changed (root=%s)\n"
    result.written result.skipped result.failed skills.changed target_root;
  (* A seeded workspace is the one thing a later bare `masc` needs to know
     about, and until now nothing wrote it down: the operator had to re-supply
     --base-path or MASC_BASE_PATH on every command. Recorded on success only,
     and never fatal -- a workspace that seeded is worth more than a record of
     it.

     Off unless asked. `init` is what suites and scripts call to make a
     throwaway workspace, and a default recorded from one of those points the
     next process at a directory that is about to vanish. Only a person asks:
     the installer and `masc setup` on a terminal, and the setup journey. *)
  if record_default && result.failed = 0 && not skills.skill_failed then (
    match Env_config.record_default_base_path base_path with
    | Env_config.Recorded path ->
      Printf.printf "default workspace recorded: %s\n" path
    | Env_config.No_record_location ->
      Printf.printf
        "default workspace not recorded: no absolute XDG_CONFIG_HOME and no HOME are set; \
         pass --base-path to later commands\n"
    | Env_config.Record_failed { record; reason } ->
      Printf.printf
        "default workspace not recorded: could not write %s (%s); pass --base-path \
         to later commands\n"
        record reason
    | Env_config.Not_a_workspace { path } ->
      Printf.printf
        "default workspace not recorded: %s holds no .masc/config; pass --base-path \
         to later commands\n"
        path
    | Env_config.Refused_under_test ->
      (* Says so rather than staying silent: a suite that expected a default
         to exist should fail on the missing default, not on its absence
         being invisible. *)
      Printf.printf
        "default workspace not recorded: a test executable does not write the \
         operator's default\n");
  if result.failed > 0 || skills.skill_failed then 1 else 0

let init_cmd_exit = init_cmd_exit_with ~report:Every_line

let init_cmd =
  let doc =
    "Seed default .masc/config/ from binary-embedded assets. Writes runtime \
     settings, prompts, tool definitions, connector declarations and first-party \
     Skills in .masc/skills/, and puts one Keeper in keepers/ for you to edit \
     -- it does not autoboot, so it waits until a model and a sandbox exist. \
     The same split the server makes when it creates a config root itself. \
     Existing config files are kept unless --force. Builtin Skill packages are \
     reconciled with this binary: missing ones are installed, unmodified recorded \
     ones are updated or, when no longer shipped, moved aside, and packages whose \
     files already match are recorded, with their permissions set to the \
     release's when only those differ. Server start only installs missing \
     packages and records matching ones; the rest waits for this command. \
     Operator edits and other packages without installation receipts are kept, \
     and each package's result is printed."
  in
  let info = Cmd.info "init" ~doc in
  Cmd.v info
    Term.(
      const init_cmd_exit $ base_path $ init_force $ init_scope
      $ init_record_default)

let skills_refresh_exit base_path name apply expected_revision expected_bundle_revision export_to =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  match List.find_opt (fun package -> Builtin_skill_package.name package = name)
          (Server_runtime_config_root_bootstrap.builtin_skills ()) with
  | None -> Printf.eprintf "Unknown builtin Skill package: %s\n" name; 1
  | Some package ->
    if Option.is_some export_to then
      match apply, expected_revision, expected_bundle_revision, export_to with
      | false, None, None, Some destination ->
        (match Builtin_skill_package.export ~destination package with
         | Ok () ->
           Printf.printf "Bundled package exported to %s\nbundled revision: %s\n"
             destination (Builtin_skill_package.bundled_revision package); 0
         | Error error -> prerr_endline (Builtin_skill_package.error_message error); 1)
      | (true, _, _, _) | (false, Some _, _, _) | (false, None, Some _, _) | (false, None, None, None) ->
        prerr_endline "--export-to cannot be combined with --apply or expected revisions"; 1
    else if apply then
      match expected_revision, expected_bundle_revision with
      | (None, _) | (Some _, None) ->
        prerr_endline "--apply requires --expected-revision and --expected-bundle-revision from a reviewed package"; 1
      | Some installed_revision, Some bundled_revision ->
        (match Builtin_skill_package.replace_reviewed ~on_wait:print_skill_lock_wait ~base_path
                 ~installed_revision ~bundled_revision package with
         | Ok (Builtin_skill_package.Replaced { backup }) ->
           Printf.printf "Updated %s; previous package: %s\nThe next replacement or retirement of %s, including masc init, replaces that backup; copy it elsewhere to keep your changes.\nRefresh the running Skill catalog before a new instruction invocation.\n" name backup name; 0
         | Ok Builtin_skill_package.Already_current -> print_endline "Package is current"; 0
         | Error error -> prerr_endline (Builtin_skill_package.error_message error); 1)
    else if Option.is_some expected_revision || Option.is_some expected_bundle_revision then (
      prerr_endline "Expected revisions require --apply"; 1)
    else
      match Builtin_skill_package.inspect ~base_path package with
      | Error error -> prerr_endline (Builtin_skill_package.error_message error); 1
      | Ok Builtin_skill_package.Missing -> print_endline "Package is missing; masc init --skills-only installs it"; 0
      | Ok (Builtin_skill_package.Present { revision; bundled_revision; ownership }) ->
        let ownership = match ownership with
          | Builtin_skill_package.Recorded -> "recorded, unchanged since installation"
          | Builtin_skill_package.Untracked -> "untracked; review operator changes before replacement"
          | Builtin_skill_package.Modified -> "modified since installation; review operator changes before replacement"
        in
        Printf.printf "package: %s\ninstalled revision: %s\nbundled revision: %s\nownership: %s\nReview the complete package, then use --apply --expected-revision %s --expected-bundle-revision %s.\n" name revision bundled_revision ownership revision bundled_revision;
        0

let skills_refresh_cmd =
  let name = Arg.(required & pos 0 (some string) None & info [] ~docv:"PACKAGE") in
  let apply = Arg.(value & flag & info [ "apply" ] ~doc:"Replace the reviewed package and retain its complete previous directory") in
  let expected = Arg.(value & opt (some string) None & info [ "expected-revision" ] ~docv:"SHA256"
    ~doc:"Reviewed whole-package revision; edits after inspection reject the update") in
  let expected_bundle = Arg.(value & opt (some string) None & info [ "expected-bundle-revision" ] ~docv:"SHA256"
    ~doc:"Reviewed bundled package revision; a different executable bundle rejects the update") in
  let export_to = Arg.(value & opt (some string) None & info [ "export-to" ] ~docv:"NEW_DIRECTORY"
    ~doc:"Export the bundled package to a new directory so its complete changes can be reviewed with diff") in
  Cmd.v (Cmd.info "skills-refresh" ~doc:"Inspect or explicitly replace one installed builtin Skill package")
    Term.(const skills_refresh_exit $ base_path $ name $ apply $ expected $ expected_bundle $ export_to)

let runtime_config_path_for_base_path base_path =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  let config_root =
    Config_dir_resolver.base_path_config_root
      ~cwd:(Config_dir_resolver.current_working_dir ())
      base_path
  in
  Filename.concat config_root Config_dir_resolver.runtime_toml_filename

let runtime_default_id =
  let doc = "Concrete runtime id to write into [runtime].default" in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"RUNTIME_ID" ~doc)

let runtime_default_set_cmd_exit base_path port agent runtime_id setup_lanes fallback_runtime_ids bind_imp =
  let fail msg = Printf.eprintf "runtime-default-set failed: %s\n" msg; 1 in
  let runtime_config_path = runtime_config_path_for_base_path base_path in
  match
    if setup_lanes then Ok ()
    else if bind_imp then Error "--setup-imp requires --setup-lanes"
    else if fallback_runtime_ids <> [] then Error "--fallback-runtime requires --setup-lanes"
    else Ok ()
  with
  | Error msg -> fail msg
  | Ok () ->
  (* Validate against the same catalog sources as server startup, before the
     config writer checks deployment-local provider/model bindings. This
     command edits the resolved runtime file, so its sibling overlay must come
     from that same config root. No server services are started. *)
  match Server_runtime_bootstrap.configure_agent_core_model_catalog_env () with
  | exception Env_config_core.Config_error message -> fail message
  | (_ : string option) ->
  (* With no server answering on the port, the command writes the file
     itself: then nothing else writes it and no reader is waiting to be told. *)
  let write_locally () =
    let result =
      try
        if setup_lanes then
          Runtime.set_first_run_runtime ~runtime_config_path ~fallback_runtime_ids ~bind_imp ~runtime_id ()
        else Runtime.set_runtime_default ~runtime_config_path ~runtime_id ()
      with Env_config_core.Config_error message -> Error message
    in
    match result with
    | Ok _receipt ->
        Printf.printf "set [runtime].default = \"%s\" in %s\n" runtime_id
          runtime_config_path;
        0
    | Error msg -> fail msg
  in
  match Unix.realpath base_path with
  | exception Unix.Unix_error _ -> write_locally ()
  | real_base_path ->
    let route =
      Masc_cli_runtime_config_remote.with_client (fun ~clock ->
        match
          Masc_cli_runtime_config_remote.find ~clock ~base_path:real_base_path ~port ~agent
        with
        | Error message -> `Refused message
        | Ok Masc_cli_runtime_config_remote.No_server -> `Local
        | Ok (Masc_cli_runtime_config_remote.Running_server server) ->
          (* RFC-0482 §3.2: the running server is the writer. The edit is the
             one the local write commits, made to the text the server holds;
             the server validates the whole file again when it saves. *)
          let edit text =
            try
              if setup_lanes then
                Runtime.first_run_runtime_text ~fallback_runtime_ids ~bind_imp ~runtime_id text
              else Runtime.runtime_default_text ~runtime_id text
            with Env_config_core.Config_error message -> Error message
          in
          `Through_server (Masc_cli_runtime_config_remote.save ~clock server ~edit))
    in
    (match route with
     | `Refused message -> fail message
     | `Local -> write_locally ()
     | `Through_server (Error message) -> fail message
     | `Through_server (Ok Masc_cli_runtime_config_remote.Unchanged) ->
         Printf.printf "[runtime].default is already \"%s\" in the running server's runtime.toml\n"
           runtime_id;
         0
     | `Through_server (Ok (Masc_cli_runtime_config_remote.Saved { path })) ->
         Printf.printf "set [runtime].default = \"%s\" in %s through the running server\n"
           runtime_id path;
         0)

let runtime_default_set_cmd =
  let doc =
    "Validate and update [runtime].default in runtime.toml using the runtime \
     config writer. While this workspace's server answers on the port, the \
     edit is saved through that server."
  in
  let info = Cmd.info "runtime-default-set" ~doc in
  let setup_lanes = Arg.(value & flag & info ["setup-lanes"]
    ~doc:"Use this primary runtime for the default and internal model lanes; persist selected fallbacks in its declared lane.") in
  let fallback_runtime_ids = Arg.(value & opt_all string [] & info ["fallback-runtime"]
    ~docv:"RUNTIME_ID" ~doc:"Append an enabled runtime to the primary lane in option order. Requires --setup-lanes; internal exact-output lanes stay primary-only.") in
  let bind_imp = Arg.(value & flag & info ["setup-imp"]
    ~doc:"Explicitly select this primary lane for imp, preserving other Keeper assignments. Requires --setup-lanes.") in
  Cmd.v info Term.(const runtime_default_set_cmd_exit $ base_path $ port $ login_agent $ runtime_default_id $ setup_lanes $ fallback_runtime_ids $ bind_imp)

let runtime_wizard_field ~field value =
  if String.exists (Char.equal '\000') value
  then Error (Printf.sprintf "runtime-wizard-catalog field %s contains a NUL byte" field)
  else Ok value

let runtime_wizard_fields fields =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (field, value) :: rest ->
        (match runtime_wizard_field ~field value with
         | Error _ as err -> err
         | Ok value -> loop (value :: acc) rest)
  in
  loop [] fields

let runtime_wizard_credential_key (provider : Runtime_schema.provider) =
  match provider.credentials with
  | None -> Ok ""
  | Some (Runtime_schema.Env key) -> Ok key
  | Some (Runtime_schema.File _ | Runtime_schema.Inline _) ->
      Error
        (Printf.sprintf
           "provider %s uses a non-env credential; the setup wizard reports only \
            environment-variable keys"
           provider.id)

let runtime_wizard_binding_for_provider = Runtime_wizard_inventory.binding_for_provider

let runtime_wizard_provider_record cfg (provider : Runtime_schema.provider) =
  match provider.transport with
  | Runtime_schema.Cli command ->
      (* A subscription runtime is reached through its own CLI (Claude Code /
         Codex / Antigravity), not an HTTP endpoint and not an .env key: the
         wizard offers it as a subscription and lets that CLI own the login.
         [command] is the binary the installer probes for with `command -v`;
         whether that CLI is actually signed in is a later, probe-based step
         (RFC-0408). *)
      (match runtime_wizard_binding_for_provider cfg provider with
       | Error _ as err -> err
       | Ok binding ->
           runtime_wizard_fields
             [ "kind", "subscription"
             ; "id", provider.id
             ; "display_name", provider.display_name
             ; "command", command
             ; "runtime_id", Runtime_schema.binding_key binding
             ])
  | Runtime_schema.Http endpoint ->
      (match
         ( runtime_wizard_credential_key provider
         , runtime_wizard_binding_for_provider cfg provider )
       with
       | Error msg, _ | _, Error msg -> Error msg
       | Ok credential_key, Ok binding ->
           let runtime_id = Runtime_schema.binding_key binding in
           runtime_wizard_fields
             [ "kind", "provider"
             ; "id", provider.id
             ; "display_name", provider.display_name
             ; "credential_key", credential_key
             ; "endpoint", endpoint
             ; "healthcheck_path", Option.value ~default:"" provider.healthcheck_path
             ; "runtime_id", runtime_id
             ])

let runtime_wizard_default_record (cfg : Runtime_schema.config) =
  match cfg.default_runtime_id with
  | None -> Ok None
  | Some runtime_id ->
      (match
         List.find_opt
           (fun (binding : Runtime_schema.binding) ->
              String.equal (Runtime_schema.binding_key binding) runtime_id)
           cfg.bindings
       with
       | Some binding ->
           (match
              runtime_wizard_fields
                [ "kind", "default-provider"; "id", binding.provider_id ]
            with
            | Error _ as err -> err
            | Ok record -> Ok (Some record))
       | None ->
           (match
              runtime_wizard_fields
                [ "kind", "default-runtime-missing"; "runtime_id", runtime_id ]
            with
            | Error _ as err -> err
            | Ok record -> Ok (Some record)))

let runtime_wizard_catalog_records (cfg : Runtime_schema.config) =
  (* One provider the wizard cannot represent -- a CLI-transport runtime with no
     endpoint, or ambiguous bindings it will not guess -- is skipped with a
     warning rather than failing the whole catalog. The wizard offers what it
     can and stays silent about what it cannot, so a single misconfigured or
     out-of-scope provider does not deny every other one. *)
  let rec provider_records acc = function
    | [] -> List.rev acc
    | provider :: rest ->
        (match runtime_wizard_provider_record cfg provider with
         | Error msg ->
             Printf.eprintf "runtime-wizard-catalog: skipping provider %s: %s\n"
               provider.id msg;
             provider_records acc rest
         | Ok record -> provider_records (record :: acc) rest)
  in
  let enabled_providers =
    List.filter (fun (provider : Runtime_schema.provider) -> provider.enabled) cfg.providers
  in
  match provider_records [] enabled_providers with
  | [] ->
      Error
        "runtime.toml has no provider the setup wizard can offer (every enabled \
         provider was CLI-transport, credential-less, or had ambiguous bindings)"
  | records ->
      (match runtime_wizard_default_record cfg with
       | Error _ as err -> err
       | Ok None -> Ok records
       | Ok (Some default_record) -> Ok (records @ [ default_record ]))

let runtime_wizard_print_record fields =
  List.iter
    (fun field ->
       output_string stdout field;
       output_char stdout '\000')
    fields

let runtime_wizard_parse_errors errors =
  errors
  |> List.map (fun (err : Runtime_toml.parse_error) ->
    Printf.sprintf "%s: %s" err.path err.message)
  |> String.concat "; "

let runtime_wizard_catalog_cmd_exit base_path json private_credentials =
  let runtime_config_path = runtime_config_path_for_base_path base_path in
  match Runtime_toml.parse_file runtime_config_path with
  | Error errors ->
      Printf.eprintf "runtime-wizard-catalog failed: %s\n"
        (runtime_wizard_parse_errors errors);
      1
  | Ok cfg when json ->
      print_endline (Yojson.Safe.to_string (Runtime_wizard_inventory.to_json
        ~include_credential_references:private_credentials cfg)); 0
  | Ok cfg ->
      (match runtime_wizard_catalog_records cfg with
       | Error msg ->
           Printf.eprintf "runtime-wizard-catalog failed: %s\n" msg;
           1
       | Ok records ->
           List.iter runtime_wizard_print_record records;
           0)

let runtime_wizard_catalog_cmd =
  let doc =
    "Print the typed provider catalog used by the first-run install wizard."
  in
  let info = Cmd.info "runtime-wizard-catalog" ~doc in
  let json = Arg.(value & flag & info [ "json" ] ~doc:"Print every enabled provider/model binding as JSON.") in
  let private_credentials = Arg.(value & flag & info ["private-credentials"]
    ~doc:"Local setup only: include protected credential file references in JSON, never their values.") in
  Cmd.v info Term.(const runtime_wizard_catalog_cmd_exit $ base_path $ json $ private_credentials)

(* A subscription runtime signs in through its own CLI. This asks whether it is
   signed in *right now*, reusing the same login checks the server's official-
   client probe uses -- [Runtime_claude_code.probe_subscription] /
   [Runtime_codex_app_server.probe_subscription], which measure the login
   without submitting a model turn. The install wizard calls this to upgrade a
   subscription from "installed" (command -v) to "signed in". A CLI probe has no
   drift-safe shell equivalent, which is why it lives here rather than in
   install.sh.

   Output contract (stdout first word, then exit code) so a shell caller can
   read either: authenticated (0) / not-authenticated (1) / not-a-subscription
   (2, an HTTP provider) / unsupported (3, antigravity has no login probe) /
   the runtime id is not configured (4) / account-not-authorized (5, the
   account access of the workspace refused the probe). *)
let runtime_probe_subscription_timeout_s = 20.0

let runtime_verification_timeout_s = 120.0

(* HIGH-RISK-UNREVIEWED: a host tool starts a client on an account only as the
   single user of a base path never set up for accounts (plan D2-2, D2-3).
   Every command that verifies a runtime publishes that access here, once,
   before the verification: runtime-verify and the model check of setup
   alike. On a base path set up for accounts the judgment refuses, so an
   operator call stays closed there (plan D2-4). The error is the reasons of
   the judgment. *)
let verify_runtime_execution ~base_path runtime timeout_s =
  match
    Runtime_account_access.publish_host_tool ~base_path
      ~config_dir:(Env_config_core.masc_config_dir_opt ())
  with
  | Error (first, rest) -> Error (first :: rest)
  | Ok () ->
    Ok (Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      (* macOS TMPDIR sits under the /var -> /private/var symlink, and an
         Antigravity runtime root must be its own realpath. *)
      let private_path = Filename.temp_dir "masc-runtime-verify-" "" |> Unix.realpath in
      Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree private_path);
      (* The env and clock a provider request reads are installed inside; the
         verification's own bound is the command's [timeout_s]. *)
      Runtime_verification.verify_as_command ~env ~sw ~private_dir:private_path ~timeout_s
        ~account_request:Runtime_account_access.Operator_call runtime)))

let account_access_refused = "A host tool does not start a client on an account of this base path."

let runtime_verify_cmd_exit base_path runtime_id timeout_s =
  let unavailable ?detail code message =
    print_endline
      (Yojson.Safe.to_string
         (Runtime_verification.unavailable_to_json ?detail ~runtime_id ~code ~message ()));
    2
  in
  if not (Float.is_finite timeout_s) || timeout_s <= 0. then
    unavailable "invalid_timeout" "Verification timeout must be finite and positive."
  else
    let config_path = runtime_config_path_for_base_path base_path in
    let loaded = try
      let (_ : string option) = Server_runtime_bootstrap.configure_agent_core_model_catalog_env () in
      Runtime.load_list ~config_path
      |> Result.map_error (Runtime_config_error.to_diagnostic_text ~config_path)
      with Env_config_core.Config_error message -> Error message in
    match loaded with
    | Error message ->
      unavailable
        ~detail:message
        "invalid_configuration"
        "The workspace runtime configuration could not be loaded."
    | Ok (runtimes, _, _, _, _) ->
      match List.find_opt (fun (runtime : Runtime_instance.t) -> runtime.id = runtime_id) runtimes with
      | None -> unavailable "runtime_not_configured" "The requested runtime is not an enabled configured binding."
      | Some runtime ->
        (try
          match verify_runtime_execution ~base_path runtime timeout_s with
          | Error reasons ->
            unavailable ~detail:(String.concat "; " reasons) "account_access_refused"
              account_access_refused
          | Ok result ->
            print_endline (Yojson.Safe.to_string (Runtime_verification.to_json result));
            Runtime_verification.exit_code result
         with Eio.Io _ | Unix.Unix_error _ | Sys_error _ ->
           unavailable "verification_session_failed" "The isolated verification session could not start or finish.")

let runtime_verify_cmd =
  let runtime_id = Arg.(required & pos 0 (some string) None & info [] ~docv:"RUNTIME_ID") in
  let timeout = Arg.(value & opt float runtime_verification_timeout_s & info ["timeout"] ~docv:"SECONDS"
    ~doc:"Deadline for cancellable client admission and model/tool exchange; blocking Muse account preparation can delay it.") in
  Cmd.v (Cmd.info "runtime-verify" ~doc:"Verify the selected model response and a harmless tool-result roundtrip.")
    Term.(const runtime_verify_cmd_exit $ base_path $ runtime_id $ timeout)


let voice_probe_lines attempts =
  List.map
    (fun (attempt : Masc.Voice_bridge.probe_attempt) ->
      Printf.sprintf
        "  %-22s %-18s %s"
        attempt.Masc.Voice_bridge.endpoint_id
        (Voice_config.string_of_endpoint_kind attempt.Masc.Voice_bridge.kind)
        (Masc.Voice_bridge.probe_outcome_to_string attempt.Masc.Voice_bridge.outcome))
    attempts

let voice_probe_answered attempts =
  List.exists
    (fun (attempt : Masc.Voice_bridge.probe_attempt) ->
      match attempt.Masc.Voice_bridge.outcome with
      | Masc.Voice_bridge.Answered _ -> true
      | Masc.Voice_bridge.Refused _ | Masc.Voice_bridge.Skipped _ -> false)
    attempts

let voice_verify_show heading = function
  | Ok [] ->
    print_endline heading;
    print_endline "  no endpoints are configured in this section"
  | Ok attempts ->
    print_endline heading;
    List.iter print_endline (voice_probe_lines attempts)
  | Error reason ->
    print_endline heading;
    print_endline ("  " ^ reason)

let voice_verify_cmd_exit requested_base_path message audio agent as_json =
  (* The workspace whose configuration is probed, when one is named. The voice
     loader finds runtime.toml through the environment, so a workspace set up
     with `voice-local-setup --base-path` and never recorded as the default had
     no way to be checked from this command: measured 2026-09-13 with only
     HOME and PATH set, run inside that workspace, it answered "voice config
     missing" while the section was there. Exported the way the server boot
     exports it, and the resolver's cache is cleared because the tool registry
     has already resolved once by the time a subcommand runs. *)
  Option.iter
    (fun raw ->
      Unix.putenv Env_config_core.base_path_env_key (Env_config.normalize_masc_base_path_input raw);
      Config_dir_resolver.reset ())
    requested_base_path;
  (* The keeper whose voice is being checked, when one is named. A voice is
     resolved per keeper and per endpoint, so "does this configuration work"
     and "does this keeper have the voice I gave it" are different questions
     -- and for say only the second one can catch a wrong name, because say
     speaks in another voice rather than failing on one it does not have. The
     probe looks the name up in say's own list and refuses one that is not
     there. *)
  (* Under an event loop, because a voice_mcp endpoint is asked over the same
     MCP HTTP client a turn uses, and that client needs a switch, a clock and
     a connection pool. The HTTP and command kinds run a process and do not
     depend on it. *)
  let tts, stt =
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        Eio_context.set_env env;
        Eio_context.set_switch sw;
        Eio_context.set_net (Eio.Stdenv.net env);
        Eio_context.set_clock (Eio.Stdenv.clock env);
        Masc_http_client.with_scoped_pool ~sw ~env (fun () ->
          let tts =
            match agent with
            | Some agent_id -> Masc.Voice_bridge.probe_tts ~agent_id ~message ()
            | None -> Masc.Voice_bridge.probe_tts ~message ()
          in
          let stt =
            Option.map
              (fun audio_file -> audio_file, Masc.Voice_bridge.probe_stt ~audio_file ())
              audio
          in
          tts, stt)))
  in
  let section name = function
    | Ok attempts -> name, `List (List.map Masc.Voice_bridge.probe_attempt_json attempts)
    | Error reason -> name, `Assoc [ "error", `String reason ]
  in
  if as_json
  then
    print_endline
      (Yojson.Safe.to_string
         (`Assoc
           (section "tts" tts
            :: (match stt with
                | Some (_, result) -> [ section "stt" result ]
                | None -> []))))
  else (
    voice_verify_show "tts" tts;
    match stt with
    | None ->
      print_newline ();
      print_endline "stt";
      print_endline "  not probed. Pass --audio FILE to have each endpoint transcribe one."
    | Some (audio_file, result) ->
      print_newline ();
      voice_verify_show (Printf.sprintf "stt  (%s)" audio_file) result);
  let answered = function
    | Ok attempts -> voice_probe_answered attempts
    | Error _ -> false
  in
  let anything_answered =
    answered tts
    ||
    match stt with
    | Some (_, result) -> answered result
    | None -> false
  in
  if anything_answered then 0 else 1

let voice_verify_cmd =
  let message =
    Arg.(
      value
      & opt string "음성 연결을 확인합니다"
      & info
          [ "message" ]
          ~docv:"TEXT"
          ~doc:
            "Sentence each TTS endpoint is asked to synthesize. Say it in the language \
             you actually use: an endpoint can answer for one language and not another.")
  in
  let audio =
    Arg.(
      value
      & opt (some string) None
      & info
          [ "audio" ]
          ~docv:"FILE"
          ~doc:
            "Audio file each STT endpoint is asked to transcribe. Without it, only TTS \
             is probed.")
  in
  let agent =
    Arg.(
      value
      & opt (some string) None
      & info
          [ "agent" ]
          ~docv:"KEEPER"
          ~doc:
            "Probe with the voice this keeper is mapped to, rather than the section \
             default. A voice is resolved per keeper and per endpoint, so a mapping \
             that names a voice an endpoint does not have is only visible this way.")
  in
  let as_json =
    Arg.(
      value
      & flag
      & info [ "json" ] ~doc:"Emit one JSON object instead of the readable report.")
  in
  Cmd.v
    (Cmd.info
       "voice-verify"
       ~doc:"Ask every configured voice endpoint to answer, and report each separately."
       ~man:
         [ `S Manpage.s_description
         ; `P
             "The fallback chain stops at the first endpoint that answers, so a chain \
              that works says nothing about the endpoints behind it: a dead fallback \
              looks healthy until the one in front of it goes away. This asks every \
              endpoint and reports each."
         ; `P
             "Exit status is 0 when at least one endpoint answered, 1 when none did. A \
              configuration that does not load is reported as the loader's own sentence."
         ])
    Term.(const voice_verify_cmd_exit $ run_base_path $ message $ audio $ agent $ as_json)
(* Turning voice on without a server running.

   The setup journey runs before there is anything to talk to over HTTP, and
   the two command kinds need no server of their own, so this writes the
   section through the same writer the route uses -- same revision guard, same
   refusal to publish a section the loader would reject.

   It writes only what it was asked for: listing is a separate mode because the
   journey has to show the voices before it can ask which one. *)
let voice_local_endpoint ~id ~kind =
  { Voice_config.id
  ; kind
  ; base_url = None
  ; mcp_url = None
  ; health_url = None
  ; api_key_env = None
  ; enabled = true
  ; timeout_seconds = None
  ; default_voice = None
  ; agent_voices = []
  ; command = None
  ; model = None
  }

let voice_local_voices_exit () =
  match
    Masc.Voice_bridge.list_voices
      (voice_local_endpoint ~id:"macos-say" ~kind:Voice_config.Macos_say)
  with
  | Error message ->
    prerr_endline message;
    1
  | Ok voices ->
    print_endline
      (Yojson.Safe.to_string
         (`Assoc
           [ "voices", `List (List.map Masc.Voice_bridge.catalogue_voice_json voices) ]));
    0

(* The changes voice-local-setup makes, decided against [ground]: the
   observation of the writer they go to. [Error] carries the exit code after
   the reason has been printed. *)
let voice_local_changes ~refuse (ground : Masc_cli_runtime_config_remote.voice_ground)
    speak_voice hear_model =
  match ground.standalone with
  (* The writer refuses this too, under its lock; said here first so nothing
     below is decided against a configuration this command cannot write. *)
  | Some path ->
    Error (refuse (Voice_setup.error_message (Voice_setup.Standalone_source_active path)))
  | None ->
    if Option.is_some speak_voice
      && List.exists
           (fun (id, kind) ->
             String.equal id "macos-say" && kind <> Some Voice_config.Macos_say)
           ground.speaking then
      Error (refuse "The endpoint macos-say already names another provider; nothing was written.")
    else
      let speaking =
        match speak_voice with
        | None -> []
        | Some voice ->
          (* Where the choice is written decides whether per-keeper voices
             still reach this endpoint. {!Voice_setup.voice_placement} carries
             the reason and the measurement. *)
          let alongside = List.map snd ground.speaking in
          let endpoint_voice, section =
            match Voice_setup.voice_placement ~alongside ~adding:Voice_config.Macos_say with
            | Voice_setup.On_the_endpoint -> Some voice, []
            | Voice_setup.On_the_section ->
              None, [ Voice_setup.Set_tts_default_voice voice ]
          in
          let endpoint =
            { (voice_local_endpoint ~id:"macos-say" ~kind:Voice_config.Macos_say)
              with default_voice = endpoint_voice }
          in
          (Voice_setup.Put_endpoint (Voice_setup.Tts, endpoint) :: section)
      in
      let hearing =
        match hear_model with
        | None -> []
        | Some model ->
          (* The file goes on the whisper-cli endpoint. Written as the
             section's default_model it became the model name every provider
             endpoint in the section was asked for, which is why this used to
             refuse whenever one was there. *)
          [ Voice_setup.Put_endpoint
              ( Voice_setup.Stt
              , { (voice_local_endpoint ~id:"whisper-local" ~kind:Voice_config.Whisper_cli)
                  with model = Some model } )
          ]
      in
      match speaking @ hearing with
      | [] ->
          prerr_endline
            "Nothing to set up: pass --voice to speak, --model to listen, or both.";
          Error 2
      | changes -> Ok changes

(* With no server answering on the port, the command is the writer: it reads
   the file, decides, and writes it itself. Then nothing else writes it and no
   reader is waiting to be told. *)
let voice_local_setup_locally ~refuse ~base_path speak_voice hear_model =
  let runtime_config_path = runtime_config_path_for_base_path base_path in
  (* Voice is a section of the configuration [masc init] writes, so a directory
     that was never initialized has nowhere to put one. Checked here, by the
     file's existence, rather than read out of the writer's error: that error
     carries the exception as text, and telling "absent" from "unreadable" in it
     would mean matching a string. A file that exists and cannot be read still
     falls through to the writer's own sentence.

     Measured 2026-09-13 on an empty directory before this: exit 1 and
     [Sys_error("<path>: No such file or directory")], with nothing created. *)
  if not (Sys.file_exists runtime_config_path) then
    refuse
      (Printf.sprintf
         "No masc workspace at %s: %s does not exist. Run masc init --base-path %s \
          first, then this again."
         base_path runtime_config_path (Filename.quote base_path))
  else
  let standalone_path = Voice_config.voice_config_file_in base_path in
  match Voice_setup.observe ~runtime_config_path ~standalone_path with
  | Error error -> refuse (Voice_setup.error_message error)
  | Ok (revision, active) ->
    let ground =
      { Masc_cli_runtime_config_remote.revision
      ; standalone =
          (match active with
           | Some (Voice_setup.Standalone_json path, _) -> Some path
           | None | Some (Voice_setup.Runtime_toml, _) -> None)
      ; speaking =
          (match Option.bind active (fun (_, config) -> config.Voice_config.tts) with
           | None -> []
           | Some (tts : Voice_config.tts_config) ->
             List.map
               (fun (endpoint : Voice_config.endpoint) ->
                 endpoint.Voice_config.id, Some endpoint.Voice_config.kind)
               tts.Voice_config.endpoints)
      }
    in
    match voice_local_changes ~refuse ground speak_voice hear_model with
    | Error code -> code
    | Ok changes ->
      (match
         Voice_setup.apply
           ~check_command_voices:Masc.Voice_bridge.check_command_voices
           ~runtime_config_path ~standalone_path
           ~expected_revision:revision changes
       with
       | Error error -> refuse (Voice_setup.error_message error)
       | Ok _revision ->
           print_endline "voice is configured";
           0)

(* RFC-0482 §3.2: while this workspace's server answers on the port, it is the
   writer. The changes are decided against what the server holds, read from its
   voice route, because the server may resolve a different configuration file
   than this process would; they go back to the same route with the revision
   they were decided on. *)
let voice_local_setup_exit base_path ~port ~agent speak_voice hear_model =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  let refuse message = prerr_endline message; 1 in
  let writer =
    match Unix.realpath base_path with
    | exception Unix.Unix_error _ -> Ok `Local
    | real_base_path ->
      Masc_cli_runtime_config_remote.with_client (fun ~clock ->
        match
          Masc_cli_runtime_config_remote.find ~clock ~base_path:real_base_path ~port ~agent
        with
        | Error message -> Error message
        | Ok Masc_cli_runtime_config_remote.No_server -> Ok `Local
        | Ok (Masc_cli_runtime_config_remote.Running_server server) ->
          Result.map
            (fun ground -> `Through_server (server, ground))
            (Masc_cli_runtime_config_remote.fetch_voice_ground ~clock server))
  in
  match writer with
  | Error message -> refuse message
  | Ok `Local -> voice_local_setup_locally ~refuse ~base_path speak_voice hear_model
  | Ok (`Through_server (server, (ground : Masc_cli_runtime_config_remote.voice_ground))) ->
    (match voice_local_changes ~refuse ground speak_voice hear_model with
     | Error code -> code
     | Ok changes ->
       (match
          Masc_cli_runtime_config_remote.with_client (fun ~clock ->
            Masc_cli_runtime_config_remote.apply_voice_setup ~clock server
              ~revision:ground.revision changes)
        with
        | Error message -> refuse message
        | Ok () ->
            print_endline "voice is configured through the running server";
            0))

let browser_lane_setup_cmd =
  let modes =
    Arg.(
      value
      & opt_all
          (enum
             (List.map
                (fun mode -> Masc_cli_browser_lane_setup.mode_name mode, mode)
                Masc_cli_browser_lane_setup.all_modes))
          []
      & info
          [ "mode" ]
          ~docv:"MODE"
          ~doc:
            "How to connect a browser: addon writes the browser Add-on package of each \
             browser source the workspace runs to .masc/packages/browser-<source> and \
             declares it when no declaration of that source exists, which every other \
             mode also does; ego writes the [browser.live.ego] table so the browser \
             Add-on serves an ego lite task space. Give it more than once for more than \
             one. Without a mode nothing is written and the current state is printed.")
  in
  let ego_command =
    Arg.(
      value
      & opt (some string) None
      & info
          [ "ego-command" ]
          ~docv:"FILE"
          ~doc:
            "With --mode ego, the ego-browser executable, an absolute path. By default \
             the first ego-browser that answers --version, on PATH or in ~/.local/bin. It \
             must answer with ego lite's and Chromium's versions. A table that is already \
             there keeps its value unless this is given.")
  in
  let ego_space =
    Arg.(
      value
      & opt (some string) None
      & info
          [ "ego-space" ]
          ~docv:"NAME"
          ~doc:
            "With --mode ego, the ego lite task space the Add-on serves. By default \
             masc-keepers. A table that is already there keeps its value unless this is \
             given. The space the table holds, new or kept, is refused when a task space \
             you made in ego lite already has that name.")
  in
  let no_addon =
    Arg.(
      value
      & flag
      & info
          [ "no-addon" ]
          ~doc:
            "Leave the browser Add-on package and its declaration as they are. Every \
             mode but addon otherwise writes the package and declares it when the \
             workspace has none.")
  in
  Cmd.v
    (Cmd.info
       "browser-lane-setup"
       ~doc:"Connect this workspace's browser lane to a browser."
       ~man:
         [ `S Manpage.s_description
         ; `P
             "It starts no browser: the browser Add-on the server attaches starts it."
         ; `P
             "Every route runs in a browser Lane Add-on, one per browser source, so every \
              mode also writes the package of each source the workspace runs to \
              .masc/packages/browser-<source> and, when the workspace has no declaration of \
              that source, creates browser-<source>.toml in its Lane directory: ego \
              when runtime.toml has its table or the mode writes it. A source \
              whose table the mode writes is declared once that table is written. A declaration's enabled switches its source on or off. An existing \
              declaration is left as it is. \
              The server attaches the Add-ons when it starts and on its maintenance pass. \
              Outside --mode addon a refusal of that step is reported and the mode goes on; \
              --no-addon skips it."
         ; `P
             "--mode ego writes [browser.live.ego]: the ego-browser the browser Add-on runs \
              and the ego lite task space it serves, after checking that ego-browser \
              answers --version and that no task space you made in ego lite has that \
              name. When ego lite does not list its spaces, nothing is written. An \
              existing table keeps its values unless they are named. \
              The server reads the table when it starts."
         ; `P
             "While this workspace's server answers on its port, the ego table is \
              planned against the runtime.toml the server holds and saved through it; \
              with no server answering it is written to the file. The server's port is \
              MASC_HTTP_PORT, the workspace's saved port or the default. While the server \
              is still starting, or no sign-in is stored for --agent (masc login), nothing \
              is set up."
         ])
    Term.(
      const (fun base_path requested_base_path named_agent modes no_addon
                  ego_command ego_space ->
        let base_path = Env_config.normalize_masc_base_path_input base_path in
        Masc_cli_browser_lane_setup.run
          ~base_path
          (* The file the server and masc doctor read: it honors MASC_CONFIG_DIR,
             which the helper the other setup commands use does not. *)
          ~runtime_config_path:(Config_dir_resolver.runtime_toml_path_for_base_path ~base_path)
          (* The server's port is resolved without a flag: MASC_HTTP_PORT, the
             workspace's saved port, the default. *)
          ~server_port:
            (resolve_connection_port requested_base_path None
             |> Result.map Workspace_connection.to_int
             |> Result.map_error Workspace_connection.error_message)
          ~agent:(Option.value named_agent ~default:default_login_agent)
          ~agent_named:(Option.is_some named_agent)
          ~modes ~no_addon ~ego_command ~ego_space)
      $ base_path
      $ run_base_path
      $ Arg.(
          value
          & opt (some string) None
          & info [ "agent" ] ~docv:"AGENT"
              ~doc:"The sign-in an ego table is saved through the workspace's running server with (masc login --agent). Defaults to local-admin.")
      $ modes
      $ no_addon
      $ ego_command
      $ ego_space)

let voice_local_setup_cmd =
  let voice =
    Arg.(
      value
      & opt (some string) None
      & info
          [ "voice" ]
          ~docv:"NAME"
          ~doc:
            "Speak with this system voice. The name is the whole label say prints, \
             parentheses included, compared without regard to case. A name say does not \
             list is refused and nothing is written: say itself would speak it in another \
             voice without failing, and a bare name that exists in several languages \
             selects one of them silently.")
  in
  let model =
    Arg.(
      value
      & opt (some string) None
      & info
          [ "model" ]
          ~docv:"FILE"
          ~doc:"Listen with whisper-cli, loading this ggml model file.")
  in
  let list_voices =
    Arg.(
      value
      & flag
      & info
          [ "list-voices" ]
          ~doc:"Print the voices this machine has as JSON, and change nothing.")
  in
  Cmd.v
    (Cmd.info
       "voice-local-setup"
       ~doc:"Turn on voice that needs no server."
       ~man:
         [ `S Manpage.s_description
         ; `P
             "say is in the base system of every mac and whisper-cli comes from one brew \
              formula. Both run once and exit, so neither needs a server -- which is why \
              this can run during setup, before there is anything to talk to over HTTP."
         ; `P
             "While this workspace's server answers on the port, the changes go to its \
              voice setup route, which saves them and tells its readers. With no server \
              answering, the command writes the file itself with the same writer: the \
              same revision guard, and the same refusal to publish a section the loader \
              would reject."
         ])
    Term.(
      const (fun base_path requested_base_path cli_port agent voice model list_voices ->
        if list_voices then voice_local_voices_exit ()
        else
          (* Resolved here rather than by the shared [port] term: listing
             voices talks to no server, so a port setting it cannot read
             is no reason to refuse it. *)
          match resolve_connection_port requested_base_path cli_port with
          | Error error ->
              prerr_endline (Workspace_connection.error_message error);
              1
          | Ok port ->
              voice_local_setup_exit base_path ~port:(Workspace_connection.to_int port)
                ~agent voice model)
      $ base_path
      $ run_base_path
      $ port_argument
      $ login_agent
      $ voice
      $ model
      $ list_voices)

(* [masc web-search-setup]. The behaviour is in Masc_cli_web_search_setup; this
   is the option table. *)
let web_search_setup_cmd =
  let provider_names = Masc_cli_web_search_setup.provider_names in
  let searxng_url =
    Arg.(value & opt (some string) None
         & info [ "searxng-url" ] ~docv:"URL"
             ~doc:"Address of a SearXNG instance, http or https with a host. Written as \
                   web_search.searxng_url, which also admits the searxng provider.")
  in
  let provider =
    Arg.(value & opt (some string) None
         & info [ "provider" ] ~docv:"NAME"
             ~doc:("The provider tried first; the others follow it. One of: "
                   ^ provider_names ^ "."))
  in
  let provider_order =
    Arg.(value & opt (some string) None
         & info [ "provider-order" ] ~docv:"NAMES"
             ~doc:"Comma separated providers, the whole chain in order. A provider named \
                   here without its credential fails on every call, because only the \
                   default order filters by credential. SearXNG is the exception: it \
                   falls back to its default address.")
  in
  let fallbacks =
    Arg.(value & opt (some string) None
         & info [ "fallbacks" ] ~docv:"NAMES"
             ~doc:"Comma separated providers tried after --provider.")
  in
  let timeout_sec =
    Arg.(value & opt (some int) None
         & info [ "timeout-sec" ] ~docv:"SECONDS" ~doc:"Request timeout, 1 to 60.")
  in
  let cache_ttl_sec =
    Arg.(value & opt (some float) None
         & info [ "cache-ttl-sec" ] ~docv:"SECONDS"
             ~doc:"How long a result is reused, 0 or more.")
  in
  let unset =
    let dashed key = String.map (function '_' -> '-' | c -> c) (Web_search_setup.key_name key) in
    Arg.(value
         & opt_all (enum (List.map (fun key -> dashed key, key) Web_search_setup.all_of_key)) []
         & info [ "unset" ] ~docv:"KEY"
             ~doc:"Remove this key so its default applies again. Repeat for several.")
  in
  Cmd.v
    (Cmd.info
       "web-search-setup"
       ~doc:"Show what each web search provider needs and write the [web_search] settings."
       ~man:
         [ `S Manpage.s_description
         ; `P
             "With no option it writes nothing and prints each provider's state, the \
              search order a call would use now, and the variable to export for a \
              provider that is missing."
         ; `P
             "Writes only the [web_search] section of runtime.toml, keeping comments \
              and other tables as they are. While this workspace's server answers on the \
              port, the section is saved through that server; otherwise the command \
              writes the file itself. An API key is never written: it is read from the \
              environment of the process that starts the server."
         ])
    Term.(
      const (fun base_path port agent searxng_url provider provider_order fallbacks timeout_sec
                 cache_ttl_sec unset ->
        let base_path = Env_config.normalize_masc_base_path_input base_path in
        Masc_cli_web_search_setup.run ~base_path ~port ~agent
          ~searxng_url ~provider ~provider_order ~fallbacks ~timeout_sec ~cache_ttl_sec
          ~unset)
      $ base_path
      $ port
      $ login_agent
      $ searxng_url
      $ provider
      $ provider_order
      $ fallbacks
      $ timeout_sec
      $ cache_ttl_sec
      $ unset)

(* [masc config set]. The behaviour is in Masc_cli_config_set; this is the
   argument table. *)
let config_set_cmd =
  let assignments =
    Arg.(non_empty & pos_all string []
         & info [] ~docv:"KEY=VALUE"
             ~doc:"A runtime.toml key as the settings registry names it, such as \
                   autonomous.enabled, and the value to write. Repeat for several: \
                   they are written in one commit or not at all.")
  in
  Cmd.v
    (Cmd.info
       "set"
       ~doc:"Write keys of runtime.toml."
       ~man:
         [ `S Manpage.s_description
         ; `P
             "Writes each KEY=VALUE into the runtime.toml the server reads for the \
              workspace, through the same locked writer as web-search-setup, keeping \
              comments and other tables as they are. A key the settings registry \
              does not name, or a value that is not the kind the key holds, is \
              refused and nothing is written."
         ; `P
             "When the workspace's server answers on the port, the keys are saved \
              through it: it is the one writer of runtime.toml while it runs, and it \
              tells its readers. This needs the sign-in masc login keeps. With no \
              server answering, the file is written here."
         ; `P
             "A workspace with no runtime.toml is seeded the way server start seeds \
              it, so a script can set a key before the first start. What a value \
              means (a blank wake prompt, an address a guest cannot use) is checked \
              when the server starts, not here."
         ])
    Term.(
      const (fun base_path port agent assignments ->
        let base_path = Env_config.normalize_masc_base_path_input base_path in
        Masc_cli_config_set.run ~base_path ~port ~agent ~assignments)
      $ base_path
      $ port
      $ login_agent
      $ assignments)

let config_cmd =
  Cmd.group
    (Cmd.info "config" ~doc:"Write the workspace configuration.")
    [ config_set_cmd ]

(* HIGH-RISK-UNREVIEWED: a probe is a call of the operator. As a host tool it
   publishes its access after its own judgment, and the client starts only on
   an account that access allows (plan D2-5 for Claude Code, D2-6 for Codex). *)
let runtime_probe_account ~base_path account =
  Result.bind
    (Runtime_account_access.publish_host_tool ~base_path
       ~config_dir:(Env_config_core.masc_config_dir_opt ()))
    (fun () ->
      Runtime_account_access.authorize Runtime_account_access.Operator_call account
      |> Result.map_error (fun refusal ->
        Runtime_account_access.refusal_to_string refusal, []))

let runtime_probe_refused (first, rest) =
  print_string "account-not-authorized\n";
  Printf.eprintf "%s\n" (String.concat "; " (first :: rest));
  5

let runtime_probe_cmd_exit base_path runtime_id =
  let runtime_config_path = runtime_config_path_for_base_path base_path in
  match Runtime.load_list ~config_path:runtime_config_path with
  | Error failure ->
      Printf.eprintf "runtime-probe failed: %s\n"
        (Runtime_config_error.to_diagnostic_text ~config_path:runtime_config_path failure);
      1
  | Ok (runtimes, _default, _, _, _) -> (
      match
        List.find_opt
          (fun (rt : Runtime_instance.t) -> String.equal rt.id runtime_id)
          runtimes
      with
      | None ->
          Printf.eprintf "runtime-probe: runtime %S is not configured\n" runtime_id;
          4
      | Some (runtime : Runtime_instance.t) -> (
          match runtime.execution with
          | Runtime_execution.Agent_core _ ->
              print_string "not-a-subscription\n";
              Printf.eprintf
                "runtime %S is an HTTP provider; probe its endpoint instead\n"
                runtime_id;
              2
          | Runtime_execution.Antigravity_cli _ ->
              print_string "unsupported\n";
              Printf.eprintf "runtime %S (antigravity) exposes no login probe\n"
                runtime_id;
              3
          | Runtime_execution.Muse_serve _ ->
              print_string "unsupported\n";
              Printf.eprintf "runtime %S (muse code) exposes no login probe\n"
                runtime_id;
              3
          | Runtime_execution.Vibe_cli _ ->
              print_string "unsupported\n";
              Printf.eprintf "runtime %S (mistral vibe) exposes no login probe\n"
                runtime_id;
              3
          | Runtime_execution.Claude_code exec ->
              (match runtime_probe_account ~base_path exec.account_home with
               | Error reasons -> runtime_probe_refused reasons
               | Ok account ->
              Eio_main.run @@ fun env ->
              let bound =
                Float.min runtime_probe_subscription_timeout_s exec.timeout_s
              in
              let config =
                { (Runtime_claude_code.default_config ~cwd:base_path) with
                  cli_path = exec.cli_path
                ; model = exec.model
                ; admission_timeout_s = bound
                ; timeout_s = Some bound
                }
              in
              (match
                 Runtime_claude_code.probe_subscription
                   ~mgr:(Posix_spawn_process_mgr.foreground_mgr
                     ~clock:(Eio.Stdenv.clock env)
                     ~grace_seconds:Process_eio.child_exit_grace_seconds)
                   ~clock:(Eio.Stdenv.clock env)
                   ~cwd:Eio.Path.(Eio.Stdenv.fs env / base_path)
                   ~account
                   config
               with
               | Ok sub ->
                   Printf.printf
                     "configured authentication=%s api_provider=%s\n"
                     (Runtime_claude_code.authentication_to_string sub.authentication)
                     (Runtime_claude_code.api_provider_to_string sub.api_provider);
                   0
               | Error e ->
                   print_string "not-authenticated\n";
                   Printf.eprintf "%s\n" (Runtime_claude_code.error_to_string e);
                   1))
          | Runtime_execution.Codex_app_server exec ->
              (match runtime_probe_account ~base_path exec.account_home with
               | Error reasons -> runtime_probe_refused reasons
               | Ok account ->
              Eio_main.run @@ fun env ->
              let bound =
                Float.min runtime_probe_subscription_timeout_s exec.timeout_s
              in
              let config =
                { (Runtime_codex_app_server.default_config ()) with
                  cli_path = exec.cli_path
                ; model = exec.model
                ; admission_timeout_s = bound
                ; timeout_s = Some bound
                }
              in
              (match
                 Runtime_codex_app_server.probe_subscription
                   ~mgr:(Posix_spawn_process_mgr.foreground_mgr
                     ~clock:(Eio.Stdenv.clock env)
                     ~grace_seconds:Process_eio.child_exit_grace_seconds)
                   ~clock:(Eio.Stdenv.clock env)
                   ~cwd:Eio.Path.(Eio.Stdenv.fs env / base_path)
                   ~account
                   config
               with
               | Ok result ->
                   Printf.printf "configured authentication=%s\n"
                     (Runtime_codex_app_server.authentication_to_string result.subscription);
                   0
               | Error e ->
                   print_string "not-authenticated\n";
                   Printf.eprintf "%s\n"
                     (Runtime_codex_app_server.error_to_string e);
                   1))))

let runtime_probe_id =
  let doc = "Runtime id (provider.model) to probe for subscription sign-in" in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"RUNTIME_ID" ~doc)

let runtime_probe_cmd =
  let doc =
    "Report whether a subscription runtime (Claude Code / Codex) is signed in."
  in
  let info = Cmd.info "runtime-probe" ~doc in
  Cmd.v info Term.(const runtime_probe_cmd_exit $ base_path $ runtime_probe_id)

let runtime_token_sample_cmd =
  let runtime_ids =
    Arg.(non_empty & opt_all string [] & info [ "runtime" ] ~docv:"RUNTIME_ID"
           ~doc:"Exact runtime ID to sample. Repeat to compare runtimes.")
  in
  let scenario_path =
    Arg.(required & opt (some file) None & info [ "scenario" ] ~docv:"JSON"
           ~doc:"JSON with system_prompt and a nonempty prompts array. Makes live model calls.")
  in
  (* HIGH-RISK-UNREVIEWED: the sample calls the API providers of the runtime
     table with the credentials their operator declared. As a host tool it
     publishes its access first, so a provider is called only as the single
     user of a base path never set up for accounts (plan D4). *)
  let run base_path scenario_path runtime_ids =
    match
      Runtime_account_access.publish_host_tool ~base_path
        ~config_dir:(Env_config_core.masc_config_dir_opt ())
    with
    | Error (first, rest) ->
      Printf.eprintf "runtime-token-sample: %s\n" (String.concat "; " (first :: rest));
      1
    | Ok () ->
      Masc_cli_runtime_sample.run
        ~config_path:(runtime_config_path_for_base_path base_path)
        ~scenario_path ~runtime_ids
  in
  Cmd.v (Cmd.info "runtime-token-sample"
           ~doc:"Record configured Agent Core conversation usage as JSONL.")
    Term.(const run $ base_path $ scenario_path $ runtime_ids)

let schedule_prune_cmd_exit base_path =
  let config = Workspace_utils.default_config base_path in
  match Schedule_service.prune config with
  | Error err ->
      prerr_endline (Schedule_service.service_error_to_string err);
      1
  | Ok (_, count) ->
      Printf.printf "Successfully pruned %d completed schedule(s).\n" count;
      0

let schedule_prune_cmd =
  let doc =
    "Prune completed (Succeeded/Failed/Cancelled/Expired) schedules and associated executions."
  in
  let info = Cmd.info "schedule-prune" ~doc in
  Cmd.v info Term.(const schedule_prune_cmd_exit $ base_path)

(* ── masc keeper-create ──────────────────────────────────────────────────

   The one path that creates a keeper without an MCP client. It exists because
   the tool that did the creating could not set [network_mode]: the descriptor
   did not declare it and the create branch dropped it, so a keeper made to
   search the web landed with no network and its operator edited the TOML by
   hand afterwards. This command refuses to send a declaration that leaves the
   field unsaid. *)

let keeper_create_name =
  let doc = "Keeper handle to create. Required unless --edit is given." in
  Arg.(value & opt string "" & info [ "name" ] ~docv:"NAME" ~doc)

let keeper_create_instructions =
  let doc =
    "What this keeper is for, written verbatim into its TOML declaration."
  in
  Arg.(value & opt string "" & info [ "instructions" ] ~docv:"TEXT" ~doc)

let keeper_create_sandbox_profile =
  let doc =
    "Sandbox isolation profile: docker, microvm or remote_ssh. Required unless \
     --edit is given; a creation without one is refused by the server. The \
     spelling is the server's to judge, not this command's."
  in
  Arg.(value & opt string "" & info [ "sandbox-profile" ] ~docv:"PROFILE" ~doc)

let keeper_create_sandbox_image =
  let doc =
    Printf.sprintf
      "Name of the image the keeper's container runs in, from the host's image \
       catalog (sandbox-images.toml). Required with --sandbox-profile docker \
       or microvm: the server refuses a keeper that names none rather than \
       choosing one for it. %s carries no language toolchain; a keeper that \
       builds code names an image that does."
      Keeper_sandbox_image_version.(base_embedded.name)
  in
  Arg.(value & opt (some string) None & info [ "sandbox-image" ] ~docv:"NAME" ~doc)

let keeper_create_network_mode =
  (* Spellings and behaviour both come from the typed owner through
     [Masc_cli_keeper_create.network_mode_behaviours], so a mode the owner
     gains is in this help text without an edit here. *)
  let doc =
    Printf.sprintf
      "Whether the sandbox guest reaches the network: %s. Required: the \
       server's own default for docker and microvm is none, which is why this \
       command will not send a declaration that leaves it unsaid. %s"
      (String.concat ", " (List.map fst Masc_cli_keeper_create.network_mode_behaviours))
      (String.concat
         " "
         (List.map
            (fun (spelling, behaviour) -> Printf.sprintf "With %s, %s" spelling behaviour)
            Masc_cli_keeper_create.network_mode_behaviours))
  in
  Arg.(value & opt (some string) None & info [ "network-mode" ] ~docv:"MODE" ~doc)

let keeper_create_microvm_backend =
  let doc =
    Printf.sprintf
      "MicroVM runtime (%s), valid only with --sandbox-profile microvm. \
       Linux requires an explicit backend; the server validates the selection."
      (String.concat ", " Keeper_microvm_backend.valid_strings)
  in
  Arg.(value & opt (some string) None & info [ "microvm-backend" ] ~docv:"BACKEND" ~doc)

let keeper_create_remote_endpoint =
  let doc =
    "Endpoint registry name under [exec.ssh.endpoints.<name>] in runtime.toml. \
     The server requires one with --sandbox-profile remote_ssh."
  in
  Arg.(
    value & opt (some string) None & info [ "remote-endpoint" ] ~docv:"NAME" ~doc)

let keeper_create_mention_target =
  let doc =
    "Direct-mention token that wakes this keeper. Repeatable. Omitted \
     entirely, the server uses the keeper's own name."
  in
  Arg.(
    value & opt_all string [] & info [ "mention-target" ] ~docv:"TOKEN" ~doc)

let keeper_create_board_interest =
  let doc =
    "Semantic topic for targetless Board discovery. Repeatable. Omit every \
     value, or pass none in the editor form, to keep targetless discovery off."
  in
  Arg.(
    value & opt_all string [] & info [ "board-interest" ] ~docv:"TOPIC" ~doc)

let keeper_create_skill =
  let doc =
    "Exact Keeper Skill name to select. Repeatable. Omitted entirely, the \
     selection is left to the server."
  in
  Arg.(value & opt_all string [] & info [ "skill" ] ~docv:"NAME" ~doc)

let keeper_create_no_skills =
  let doc =
    "Select no Skills at all. This is the empty selection, which repeating \
     --skill zero times cannot say: omitting --skill leaves the selection \
     alone, and this clears it."
  in
  Arg.(value & flag & info [ "no-skills" ] ~doc)

let keeper_create_max_context_override =
  let doc = "Absolute context token limit for this keeper. 0 clears it." in
  Arg.(
    value
    & opt (some int) None
    & info [ "max-context-override" ] ~docv:"N" ~doc)

let keeper_create_activation_mode =
  Arg.(value & opt (some (enum ["manual", "manual"; "on_demand", "on_demand";
                               "autonomous", "autonomous"])) None
       & info ["activation-mode"] ~docv:"MODE"
           ~doc:"Activation: manual, on_demand, or autonomous.")

(* This command's own [--host] and [--port], not the server's. The shared
   terms are [masc serve]'s bind address, and they render in this command's
   [--help] as "Port to listen on" and "Host/IP to bind" -- true of the
   server, false of a client, and an operator reading them as the scope of the
   request is told the wrong thing by the help text itself. The defaults are
   unchanged: the workspace's own server is the one this command usually
   means. What decides which server is reached is these two terms alone --
   [--base-path] only says where to look for the credential, and the manpage
   now says so. *)
let keeper_create_host =
  let doc =
    "Host of the running masc server this declaration is sent to. Defaults to \
     loopback. This is a request target, not a bind address."
  in
  Arg.(
    value
    & opt string (Env_config.masc_host ())
    & info [ "host" ] ~docv:"HOST" ~doc)

let keeper_create_port =
  let doc =
    "Port of the running masc server this declaration is sent to. This is a \
     request target, not a port to listen on."
  in
  Arg.(
    value
    & opt int (Env_config_core.masc_http_port_int ())
    & info [ "p"; "port" ] ~docv:"PORT" ~doc)

let keeper_create_token =
  let doc =
    "Bearer to present instead of the one masc login persisted for --agent."
  in
  Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc)

let keeper_create_edit =
  let doc =
    "Fill the declaration in the editor named by the EDITOR or VISUAL \
     environment variable, instead of passing flags. Needs a terminal, and it \
     cannot be combined with the declaration flags."
  in
  Arg.(value & flag & info [ "edit" ] ~doc)

let keeper_create_flags_term =
  let build
        name
        instructions
        sandbox_profile
        sandbox_image
        network_mode
        microvm_backend
        remote_endpoint
        mention_targets
        board_interests
        skill_names
        no_skills
        max_context_override
        activation_mode
    : (Masc_cli_keeper_create.flags, string) result
    =
    let selected_skills =
      match skill_names, no_skills with
      | _ :: _, true ->
        Error
          "masc keeper-create: --skill and --no-skills contradict each other. \
           Nothing was created."
      | [], true -> Ok (Some [])
      | [], false -> Ok None
      | (_ :: _ as names), false -> Ok (Some names)
    in
    match selected_skills with
    | Error message -> Error message
    | Ok skills ->
      let flags : Masc_cli_keeper_create.flags =
        { name
        ; instructions
        ; sandbox_profile
        ; sandbox_image
        ; network_mode
        ; microvm_backend
        ; remote_endpoint
        ; mention_targets
        ; board_interests
        ; skills
        ; max_context_override
        ; activation_mode
        }
      in
      Ok flags
  in
  Term.(
    const build
    $ keeper_create_name
    $ keeper_create_instructions
    $ keeper_create_sandbox_profile
    $ keeper_create_sandbox_image
    $ keeper_create_network_mode
    $ keeper_create_microvm_backend
    $ keeper_create_remote_endpoint
    $ keeper_create_mention_target
    $ keeper_create_board_interest
    $ keeper_create_skill
    $ keeper_create_no_skills
    $ keeper_create_max_context_override
    $ keeper_create_activation_mode)

(* [--edit] takes the whole declaration from the editor, so a flag passed
   alongside it would be read by nobody. Naming the conflict costs one
   comparison; dropping the flags silently is the shape this command exists to
   stop. *)
let keeper_create_flags_are_absent (flags : Masc_cli_keeper_create.flags) =
  String.equal (String.trim flags.name) ""
  && String.equal (String.trim flags.instructions) ""
  && String.equal (String.trim flags.sandbox_profile) ""
  && Option.is_none flags.sandbox_image
  && Option.is_none flags.network_mode
  && Option.is_none flags.microvm_backend
  && Option.is_none flags.remote_endpoint
  && List.is_empty flags.mention_targets
  && List.is_empty flags.board_interests
  && Option.is_none flags.skills
  && Option.is_none flags.max_context_override
  && Option.is_none flags.activation_mode

let keeper_create_edit_conflict_message =
  "masc keeper-create: --edit takes the declaration from the editor, so it \
   cannot be combined with the declaration flags. Nothing was created."

let keeper_create_declaration_from_editor () =
  match
    Masc_cli_keeper_create.form_input_refusal
      ~stdin_is_tty:(Unix.isatty Unix.stdin)
      ~editor:(Masc_tui_editor.editor_command ())
  with
  | Some message -> Error message
  | None ->
    (* This process is not a TUI: it never left cooked mode, so there is no
       terminal state to hand back and none to reclaim. *)
    (match
       Masc_tui_editor.roundtrip
         ~restore:(fun () -> ())
         ~reenter:(fun () -> ())
         Masc_cli_keeper_create.form_stem
     with
     | Error abort ->
       Error
         (Printf.sprintf
            "masc keeper-create --edit: %s. Nothing was created."
            (Masc_tui_editor.abort_detail abort))
     | Ok edited -> Masc_cli_keeper_create.declaration_of_form edited)

(* The keeper name becomes a path segment in the request URL, so it is both
   checked and encoded. [Keeper_config.validate_name] runs first and admits
   only [A-Za-z0-9._-], which makes the encoding a no-op today -- and that is
   the reason to have it rather than to skip it: relying on the two staying in
   step leaves a widened name grammar to show up as a malformed request line.
   The TUI's own keeper calls encode the same segment. *)
let keeper_lifecycle_post ~action ~base_path ~host ~port ~agent ~token ~keeper_name
      ~declaration =
  let bearer =
    match token with
    | Some raw -> Some raw
    | None -> Auth_login.read_persisted_http_token ~base_path ~agent_name:agent
  in
  let headers =
    ("content-type", "application/json")
    :: (match bearer with
        | None -> []
        | Some value -> [ "authorization", "Bearer " ^ value ])
  in
  let url =
    Printf.sprintf
      "http://%s:%d/api/v1/keepers/%s/%s"
      host
      port
      (Uri.pct_encode keeper_name)
      (match action with `Up -> "up" | `Boot -> "boot")
  in
  let body = Yojson.Safe.to_string declaration in
  let outcome =
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        Eio_context.set_env env;
        Eio_context.set_switch sw;
        Eio_context.set_net (Eio.Stdenv.net env);
        Eio_context.set_clock (Eio.Stdenv.clock env);
        (* The same deadline the TUI's own create already runs under; this
           command does not invent a second one. *)
        Masc_http_client.with_scoped_pool ~sw ~env (fun () ->
        match
          Masc_http_client.post_sync
            ~clock:(Eio.Stdenv.clock env)
            ~timeout_sec:Masc_http_client.default_request_timeout_sec
            ~url
            ~headers
            ~body
            ()
        with
        | Error message -> Masc_cli_keeper_create.Unreachable message
        | Ok (status, response_body) ->
          Masc_cli_keeper_create.outcome_of_response ~status ~body:response_body)))
  in
  let text, code =
    match action, outcome with
    | `Boot, (Masc_cli_keeper_create.Created _ | Masc_cli_keeper_create.Reconfigured _) -> "imp is running.", 0
    | ( `Up
      , ( Masc_cli_keeper_create.Created _
        | Masc_cli_keeper_create.Reconfigured _
        | Masc_cli_keeper_create.Revision_conflict
        | Masc_cli_keeper_create.Unauthorized _
        | Masc_cli_keeper_create.Refused _
        | Masc_cli_keeper_create.Unreachable _ ) )
    | ( `Boot
      , ( Masc_cli_keeper_create.Revision_conflict
        | Masc_cli_keeper_create.Unauthorized _
        | Masc_cli_keeper_create.Refused _
        | Masc_cli_keeper_create.Unreachable _ ) ) -> Masc_cli_keeper_create.render outcome
  in
  if code = 0 then print_endline text else prerr_endline text;
  code

let keeper_create_cmd_exit base_path host port flags_result token agent edit =
  let declaration_result =
    match edit, flags_result with
    | true, Ok flags when not (keeper_create_flags_are_absent flags) ->
      Error keeper_create_edit_conflict_message
    | true, Error _ -> Error keeper_create_edit_conflict_message
    | true, Ok _ -> keeper_create_declaration_from_editor ()
    | false, Error message -> Error message
    | false, Ok (flags : Masc_cli_keeper_create.flags) ->
      (match Masc_cli_keeper_create.declaration_of_flags flags with
       | Error message -> Error message
       | Ok declaration -> Ok (declaration, String.trim flags.name))
  in
  match declaration_result with
  | Error message ->
    prerr_endline message;
    2
  | Ok (declaration, keeper_name) ->
    if not (Keeper_config.validate_name keeper_name)
    then (
      prerr_endline (Keeper_config.invalid_name_error keeper_name);
      prerr_endline "Nothing was created.";
      2)
    else
      keeper_lifecycle_post ~action:`Up ~base_path ~host ~port ~agent ~token ~keeper_name
        ~declaration

let keeper_create_cmd =
  let doc = "Create a keeper from the command line." in
  let example =
    String.concat
      "\n"
      [ "  masc keeper-create --name scout --sandbox-profile docker"
      ; "                     --sandbox-image base --network-mode inherit"
      ; "                     --instructions 'Search the web.'"
      ; ""
      ; "  masc keeper-create --edit"
      ]
  in
  let man =
    [ `S Manpage.s_description
    ; `P
        "Sends one create-or-update declaration to a running server at \
         --host/--port. The keeper starts immediately: the server boots it \
         inside the same call, and a create answers only once its keepalive \
         lane is running."
    ; `P
        "--host and --port choose that server, and they are the only things \
         that do. --base-path does not: it says where to look for the bearer \
         token masc login persisted for --agent, and a base path with no \
         running server of its own still sends the declaration to \
         --host/--port. Scoping a create to a scratch workspace means \
         pointing --host/--port at that workspace's server."
    ; `P
        "--network-mode is required, on the flags and in the --edit form \
         alike. The server's default for docker and microvm is none, which \
         gives the guest no network at all, so a keeper whose work is web \
         search or repository traffic has to say here which network it gets. \
         This command refuses rather than choosing for you. The modes, from \
         the server's own list:"
    ]
    (* One item per mode, rendered from the typed owner: a mode the owner
       gains is in this manpage without an edit here. *)
    @ List.map
        (fun (spelling, behaviour) -> `I (spelling, behaviour))
        Masc_cli_keeper_create.network_mode_behaviours
    @ [ `P
          "Naming a keeper that already exists reconfigures it instead of \
           making a second one, and this command says so. Read what the \
           required flags do on that path: --sandbox-profile and \
           --network-mode are sent on every invocation, so they overwrite the \
           existing keeper's isolation with whatever was typed. --instructions \
           is the opposite -- left blank it is not sent, and the existing text \
           stands. To change only the instructions, restate the profile and \
           the network mode the keeper already has."
      ; `S Manpage.s_examples
      ; `Pre example
      ]
  in
  let info = Cmd.info "keeper-create" ~doc ~man in
  Cmd.v
    info
    Term.(
      const keeper_create_cmd_exit
      $ base_path
      $ keeper_create_host
      $ keeper_create_port
      $ keeper_create_flags_term
      $ keeper_create_token
      $ login_agent
      $ keeper_create_edit)

let keeper_github_keeper_arg =
  let doc = "Keeper name whose GitHub CLI identity is managed." in
  Arg.(required & opt (some string) None & info [ "keeper" ] ~docv:"NAME" ~doc)

let keeper_github_hostname_arg =
  let doc = "GitHub hostname." in
  Arg.(value & opt string Keeper_github_identity.default_hostname & info [ "hostname" ] ~docv:"HOST" ~doc)

(* Resolve the Keeper a [keeper github] subcommand names, the same way for
   every subcommand, before handing it the config and its effective meta. *)
let with_keeper_github_meta base_path keeper_name run =
  let config = Workspace_utils.default_config base_path in
  if not (Keeper_config.validate_name keeper_name)
  then (
    prerr_endline (Printf.sprintf "invalid keeper name: %s" keeper_name);
    1)
  else
    (* Effective meta, not persisted meta: [sandbox_profile] is TOML-owned
       and a persisted read answers with the default, which would send every
       Keeper's login to this host. *)
    match Keeper_meta_store.read_effective_meta config keeper_name with
    | Error message ->
      prerr_endline message;
      1
    | Ok None ->
      prerr_endline (Printf.sprintf "keeper %S not found" keeper_name);
      1
    | Ok (Some meta) -> run ~config ~meta
;;

let keeper_github_action_cmd name doc run =
  let invoke base_path keeper_name hostname =
    with_keeper_github_meta base_path keeper_name (fun ~config ~meta ->
      run ~config ~meta ~hostname)
  in
  Cmd.v
    (Cmd.info name ~doc)
    Term.(
      const invoke
      $ base_path
      $ keeper_github_keeper_arg
      $ keeper_github_hostname_arg)

(* The scopes the TUI and the dashboard let an operator tick, offered here by
   the same names. Parsed by cmdliner into the closed type, so a name the
   server does not offer is refused before any login starts. *)
let keeper_github_login_scope_arg =
  let choices =
    List.map
      (fun scope -> (Keeper_github_identity.login_scope_to_string scope, scope))
      Keeper_github_identity.all_login_scopes
  in
  let doc =
    Printf.sprintf
      "A GitHub scope to ask for beyond gh's minimum (repo, read:org, gist). \
       Repeat for more than one. One of: %s. Logging in again without it \
       replaces a token that had it with one that does not."
      (String.concat ", " (List.map fst choices))
  in
  Arg.(value & opt_all (enum choices) [] & info [ "scope" ] ~docv:"SCOPE" ~doc)

let keeper_github_cmd =
  let login =
    let run ~config ~(meta : Keeper_meta_contract.keeper_meta) ~hostname ~scopes =
        (* This subcommand runs under [Cmd.eval'], outside the [Eio_main.run]
           that only the server's [start] enters, and both lanes need a runtime.
           The remote lane opens an Eio switch per remote command, which without
           a runtime raises [Effect.Unhandled]. The host lane runs, but an
           uninitialized [Process_eio] takes the fallback that collects the
           child's output and replays it after exit, so a device flow would show
           its one-time code only once the wait for that code had expired. *)
        Eio_main.run
        @@ fun env ->
        Process_eio.init
          ~cwd_default:(Eio.Stdenv.cwd env)
          ~proc_mgr:(Eio.Stdenv.process_mgr env)
          ~clock:(Eio.Stdenv.clock env);
        match Keeper_github_login_lane.for_keeper ~config ~meta ~hostname with
        | Error message ->
          prerr_endline message;
          1
        | Ok lane -> Keeper_github_identity.run_cli_login ~lane ~scopes
    in
    let invoke base_path keeper_name hostname scopes =
      with_keeper_github_meta base_path keeper_name (fun ~config ~meta ->
        run ~config ~meta ~hostname ~scopes)
    in
    Cmd.v
      (Cmd.info "login" ~doc:"Log a Keeper into GitHub CLI.")
      Term.(
        const invoke
        $ base_path
        $ keeper_github_keeper_arg
        $ keeper_github_hostname_arg
        $ keeper_github_login_scope_arg)
  in
  let set_token =
    let invoke base_path keeper_name hostname =
      let config = Workspace_utils.default_config base_path in
      if not (Keeper_config.validate_name keeper_name)
      then (
        prerr_endline (Printf.sprintf "invalid keeper name: %s" keeper_name);
        1)
      else
        let token =
          if Unix.isatty Unix.stdin then (
            prerr_string "Enter GitHub personal access token (PAT): ";
            flush stderr;
            String.trim (read_line ()))
          else String.trim (In_channel.input_all stdin)
        in
        if String.equal token "" then (
          prerr_endline "token must not be empty";
          1)
        else
          match Keeper_meta_store.read_effective_meta config keeper_name with
          | Error message ->
            prerr_endline message;
            1
          | Ok None ->
            prerr_endline (Printf.sprintf "keeper %S not found" keeper_name);
            1
          | Ok (Some meta) ->
            Eio_main.run
            @@ fun env ->
            Process_eio.init
              ~cwd_default:(Eio.Stdenv.cwd env)
              ~proc_mgr:(Eio.Stdenv.process_mgr env)
              ~clock:(Eio.Stdenv.clock env);
            match Keeper_github_login_lane.for_keeper ~config ~meta ~hostname with
            | Error message ->
              prerr_endline message;
              1
            | Ok lane ->
              Keeper_github_identity.run_cli_set_token
                ~lane
                ~base_path:config.Workspace.base_path
                ~keeper_name:meta.Keeper_meta_contract.name
                ~token
    in
    Cmd.v
      (Cmd.info "set-token"
         ~doc:"Set a personal access token (e.g. Fine-grained PAT) for a Keeper, read from standard input.")
      Term.(
        const invoke
        $ base_path
        $ keeper_github_keeper_arg
        $ keeper_github_hostname_arg)
  in
  (* Status reads the machine the login was written to, so a Remote_ssh
     Keeper answers from its endpoint and needs the same runtime [login] opens.
     Logout still runs [gh auth logout] against this host's directory. *)
  let status =
    keeper_github_action_cmd
      "status"
      "Observe stored and effective Keeper GitHub identities."
      (fun ~config ~(meta : Keeper_meta_contract.keeper_meta) ~hostname ->
        Eio_main.run
        @@ fun env ->
        Process_eio.init
          ~cwd_default:(Eio.Stdenv.cwd env)
          ~proc_mgr:(Eio.Stdenv.process_mgr env)
          ~clock:(Eio.Stdenv.clock env);
        Keeper_github_identity.run_cli_status ~observe:(fun () ->
          Keeper_github_login_lane.observe ~config ~meta ~hostname))
  in
  let logout =
    keeper_github_action_cmd
      "logout"
      "Remove a Keeper GitHub CLI login."
      (fun ~config ~(meta : Keeper_meta_contract.keeper_meta) ~hostname ->
        Keeper_github_identity.run_cli_logout
          ~config
          ~keeper_name:meta.Keeper_meta_contract.name
          ~hostname)
  in
  Cmd.group
    (Cmd.info "keeper-github" ~doc:"Manage Keeper-specific GitHub CLI identity.")
    [ login; set_token; status; logout ]

let build_commit_cmd_exit () =
  match Build_identity.embedded_commit with
  | Some commit ->
      print_endline commit;
      0
  | None ->
      prerr_endline "build commit is not embedded";
      1

let build_commit_cmd =
  let doc = "Print the Git commit embedded in this server binary at build time." in
  Cmd.v (Cmd.info "build-commit" ~doc) Term.(const build_commit_cmd_exit $ const ())

(* Build one sandbox recipe into one image store, under a tag that names that
   build. RFC keeper-sandbox-images-have-versions (#38699) §2.2: the tag is never moved
   to new content, so a tag already in the store refuses the build instead of
   being rebuilt in place. *)

let rec sandbox_image_remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter
      (fun entry -> sandbox_image_remove_tree (Filename.concat path entry))
      (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind =
        ( Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK )
    ; _
    } -> Sys.remove path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let sandbox_image_report_build ~cli ~tag status =
  match status with
  | Unix.WEXITED 0 ->
    Printf.printf "built %s into %s's image store\n" tag cli;
    Cmd.Exit.ok
  | Unix.WEXITED code ->
    Printf.eprintf "sandbox-image: %s build exited %d\n" cli code;
    Cmd.Exit.some_error
  | Unix.WSIGNALED n | Unix.WSTOPPED n ->
    Printf.eprintf "sandbox-image: %s build stopped by signal %d\n" cli n;
    Cmd.Exit.some_error

(* A runtime that takes a directory rather than stdin, or a recipe whose
   COPY lines need files: the recipe and its listed inputs are written to a
   directory of their own, and nothing else goes in it. *)
let sandbox_image_build_in_a_directory_exit ~command ~tag ~labels ~recipe =
  match command with
  | [] ->
    prerr_endline "sandbox-image: no image build command resolved";
    Cmd.Exit.some_error
  | cli :: _ ->
    let context = Filename.temp_file "masc-sandbox-image-" ".d" in
    Sys.remove context;
    Unix.mkdir context 0o700;
    let cleanup () =
      try sandbox_image_remove_tree context
      with Unix.Unix_error _ | Sys_error _ -> ()
    in
    Fun.protect ~finally:cleanup (fun () ->
        match Keeper_sandbox_image_version.write_context ~dir:context recipe with
        | Error error ->
          prerr_endline
            ("sandbox-image: " ^ Keeper_sandbox_image_version.load_error_to_string error);
          Cmd.Exit.some_error
        | Ok dockerfile ->
          let argv =
            command
            @ Keeper_sandbox_image.context_directory_build_argv ~labels ~tag
                ~dockerfile ~context ()
          in
          let pid =
            Unix.create_process cli (Array.of_list argv) Unix.stdin Unix.stdout
              Unix.stderr
          in
          sandbox_image_report_build ~cli ~tag (Masc_cli_setup.wait_for_child pid))

(* A recipe with no inputs, to a runtime that reads the Dockerfile on stdin
   against a [-] context. *)
let sandbox_image_build_on_stdin_exit ~command ~tag ~labels ~dockerfile =
  match command with
  | [] ->
    prerr_endline "sandbox-image: no image build command resolved";
    Cmd.Exit.some_error
  | bin :: _ ->
    let argv = command @ Keeper_sandbox_image.build_argv ~labels ~tag () in
    (* The runtime exiting first would otherwise kill this process mid-write, and
       the exit status we want to report is the runtime's own. *)
    let previous_sigpipe = Sys.signal Sys.sigpipe Sys.Signal_ignore in
    Fun.protect
      ~finally:(fun () -> Sys.set_signal Sys.sigpipe previous_sigpipe)
      (fun () ->
    let read_fd, write_fd = Unix.pipe () in
    Unix.set_close_on_exec write_fd;
    let pid =
      Unix.create_process bin (Array.of_list argv) read_fd Unix.stdout Unix.stderr
    in
    Unix.close read_fd;
    let oc = Unix.out_channel_of_descr write_fd in
    (try
       output_string oc dockerfile;
       close_out oc
     with Sys_error _ -> (try close_out_noerr oc with _ -> ()));  (* @observe-allowed: the write already failed; close_out_noerr is the no-raise form and there is no second failure to report *)
    sandbox_image_report_build ~cli:bin ~tag (Masc_cli_setup.wait_for_child pid))

type sandbox_image_presence =
  | Tag_present
  | Tag_absent
  | Store_unanswered of string

(* [<command> image inspect <tag>]: docker, nerdctl and Apple's container all
   exit 0 when the store holds the tag and 1 when it does not. Docker also
   exits 1 when its daemon is down, so a daemon that stops between this probe
   and the build is the one window this cannot close; the build then fails on
   the same dead daemon. Any other status, or a command that is not there,
   is an answer this does not read as absence. A promote asks msb the same
   way and records a tag only on exit 0, so an msb status this does not
   know refuses the promote rather than passing it. *)
let sandbox_image_tag_presence ~command ~tag =
  match command with
  | [] -> Store_unanswered "no image command resolved"
  | bin :: _ ->
    let devnull = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close devnull)
      (fun () ->
         let argv = command @ [ "image"; "inspect"; tag ] in
         match Unix.create_process bin (Array.of_list argv) Unix.stdin devnull devnull with
         | exception Unix.Unix_error (error, _, _) ->
           Store_unanswered (Printf.sprintf "%s: %s" bin (Unix.error_message error))
         | pid ->
           (match Masc_cli_setup.wait_for_child pid with
            | Unix.WEXITED 0 -> Tag_present
            | Unix.WEXITED 1 -> Tag_absent
            | Unix.WEXITED code ->
              Store_unanswered (Printf.sprintf "%s image inspect exited %d" bin code)
            | Unix.WSIGNALED n | Unix.WSTOPPED n ->
              Store_unanswered
                (Printf.sprintf "%s image inspect stopped by signal %d" bin n)))

(* The CLI that answers for the image store --runtime names: Docker's
   configured argv when it is omitted, otherwise the microVM runtime's own.
   Each has [image inspect], msb included, so every store can be asked
   whether it holds a tag, including the one masc cannot build into. *)
let sandbox_image_store_command = function
  | None -> Keeper_sandbox_runtime.docker_command_argv ()
  | Some backend -> [ Keeper_microvm_backend.cli_name backend ]

type sandbox_image_builder =
  { build_command : string list
  ; reads_stdin : bool
  }

(* Which store to build into. Docker stays the default because that is where
   [sandbox_profile = "docker"] keepers look and where this command has always
   put it. A microVM keeper looks somewhere else entirely -- each runtime
   keeps its images apart from Docker's -- so the image its gate wants can
   only be made by naming that runtime here. *)
let sandbox_image_builder runtime =
  let build_command = sandbox_image_store_command runtime in
  match runtime with
  | None -> Ok { build_command; reads_stdin = true }
  | Some backend ->
    let cli = Keeper_microvm_backend.cli_name backend in
    (match Keeper_microvm_backend.recipe_delivery backend with
     | Keeper_microvm_backend.On_stdin -> Ok { build_command; reads_stdin = true }
     | Keeper_microvm_backend.In_a_context_directory ->
       Ok { build_command; reads_stdin = false }
     | Keeper_microvm_backend.Builds_no_images ->
       Error
         (Printf.sprintf
            "sandbox-image: %s builds no images -- it has pull, load and save \
             and no build. Next: build the image elsewhere, save it as an OCI \
             archive, `%s load` it, and record its tag with `masc sandbox-image \
             promote <name> <tag> --runtime %s`."
            cli cli (Keeper_microvm_backend.to_string backend)))

(* Only [base] travels inside the binary. Every other recipe names repository
   files in its inputs, so it is read from a checkout. *)
let sandbox_image_recipe ~recipe_name ~source =
  match source with
  | Some source ->
    Result.map_error
      (fun error ->
         "sandbox-image: " ^ Keeper_sandbox_image_version.load_error_to_string error)
      (Keeper_sandbox_image_version.load ~source ~name:recipe_name)
  | None ->
    let carried = Keeper_sandbox_image_version.base_embedded in
    if String.equal recipe_name carried.Keeper_sandbox_image_version.name then Ok carried
    else
      Error
        (Printf.sprintf
           "sandbox-image: the %s recipe is read from a checkout; pass --source \
            <checkout>. This binary carries only the %s recipe."
           recipe_name carried.Keeper_sandbox_image_version.name)

let sandbox_image_build ~builder ~recipe ~tag ~labels =
  match recipe.Keeper_sandbox_image_version.inputs, builder.reads_stdin with
  | [], true ->
    sandbox_image_build_on_stdin_exit ~command:builder.build_command ~tag ~labels
      ~dockerfile:recipe.Keeper_sandbox_image_version.dockerfile
  | [], false | _ :: _, _ ->
    sandbox_image_build_in_a_directory_exit ~command:builder.build_command ~tag
      ~labels ~recipe

let sandbox_image_cmd_exit print_only tag runtime recipe_name source =
  let open Result.Syntax in
  let run =
    let* recipe = sandbox_image_recipe ~recipe_name ~source in
    if print_only
    then (
      print_string recipe.Keeper_sandbox_image_version.dockerfile;
      Ok Cmd.Exit.ok)
    else
      let* runtime = runtime in
      let* builder = sandbox_image_builder runtime in
      let built_at = Unix.gettimeofday () in
      let tag =
        match tag with
        | Some tag -> tag
        | None -> Keeper_sandbox_image_version.tag ~built_at recipe
      in
      match sandbox_image_tag_presence ~command:builder.build_command ~tag with
      | Store_unanswered detail ->
        Error
          (Printf.sprintf
             "sandbox-image: could not ask the image store whether %s is there \
              (%s), so nothing was built."
             tag detail)
      | Tag_present ->
        Error
          (Printf.sprintf
             "sandbox-image: %s is already in the image store. A tag names one \
              build and is not rebuilt in place. The same recipe built in a \
              later minute gets a new tag; to replace this one, remove the \
              image first."
             tag)
      | Tag_absent ->
        let labels = Keeper_sandbox_image_version.labels ~built_at recipe in
        let code = sandbox_image_build ~builder ~recipe ~tag ~labels in
        (* A Keeper's sandbox_image is a catalog name, never a tag, so the
           next step for a build is the promote that makes it what that name
           starts from. *)
        if code = Cmd.Exit.ok
        then
          Printf.printf "Make it what %s starts from: masc sandbox-image promote %s %s%s\n"
            recipe.Keeper_sandbox_image_version.name
            recipe.Keeper_sandbox_image_version.name tag
            (match runtime with
             | None -> ""
             | Some backend -> " --runtime " ^ Keeper_microvm_backend.to_string backend);
        Ok code
  in
  match run with
  | Ok code -> code
  | Error message ->
    prerr_endline message;
    Cmd.Exit.some_error

(* Which image store --runtime names: Docker's when it is omitted, otherwise
   the named microVM runtime's own. *)
let sandbox_image_runtime_term =
  let runtime =
    let doc =
      "microVM runtime whose image store to use (one of "
      ^ String.concat ", " Keeper_microvm_backend.valid_strings
      ^ "). Omit for Docker's store, which is where sandbox_profile = \"docker\" \
         keepers look. Each runtime keeps its images apart from Docker's, so a \
         microvm keeper cannot see one built without this."
    in
    Arg.(value & opt (some string) None & info [ "runtime" ] ~docv:"RUNTIME" ~doc)
  in
  Term.(
    const (fun named ->
        match named with
        | None -> Ok None
        | Some name ->
          (match Keeper_microvm_backend.of_string name with
           | Some backend -> Ok (Some backend)
           | None ->
             Error
               (Printf.sprintf
                  "sandbox-image: --runtime %S names no microVM runtime. One \
                   of: %s."
                  name
                  (String.concat ", " Keeper_microvm_backend.valid_strings))))
    $ runtime)

let sandbox_image_store = function
  | None -> Keeper_sandbox_image_catalog.Docker_daemon
  | Some backend -> Keeper_sandbox_image_catalog.Microvm backend

(* The catalog is read by the server from the config root it resolves for its
   workspace, [MASC_CONFIG_DIR] included, so it is written there too. *)
let sandbox_image_config_root base_path =
  let resolution = Config_dir_resolver.resolve_for_base_path ~base_path in
  resolution.Config_dir_resolver.config_root.Config_dir_resolver.path

(* Load this host's catalog (or the shipped one it starts from), apply one
   change, and write it back. *)
let sandbox_image_change_catalog ~base_path change =
  let open Result.Syntax in
  let config_root = sandbox_image_config_root base_path in
  let* shipped =
    match Embedded_config.read Keeper_sandbox_image_catalog.shipped_file_name with
    | Some shipped -> Ok shipped
    | None ->
      Error "sandbox-image: missing embedded config/sandbox-images.toml"
  in
  let* catalog, expected =
    Result.map_error
      (fun error -> "sandbox-image: " ^ Keeper_sandbox_image_catalog.load_error_to_string error)
      (Keeper_sandbox_image_catalog.load_for_change ~config_root ~shipped)
  in
  let* next = change catalog in
  Result.map_error
    (fun error -> "sandbox-image: " ^ Keeper_sandbox_image_catalog.save_error_to_string error)
    (Keeper_sandbox_image_catalog.save ~config_root ~expected next)
  |> Result.map (fun () -> Filename.concat config_root Keeper_sandbox_image_catalog.file_name)

let sandbox_image_exit_of = function
  | Ok message ->
    print_endline message;
    Cmd.Exit.ok
  | Error message ->
    prerr_endline message;
    Cmd.Exit.some_error

(* The catalog records a tag and nothing read from the store, so the store is
   asked before the file is written: a tag it does not hold, or a store that
   does not answer, is refused and nothing is saved. The catalog judges the
   name and reference first, so an unknown name is reported as that.
   [command] is the store's own CLI, which msb has even though masc cannot
   build into it. The store stays free to drop the image after the answer;
   the start gate asks again before a Keeper runs. *)
let sandbox_image_promote ~base_path ~command ~store ~name ~reference =
  let open Result.Syntax in
  let store_name = Keeper_sandbox_image_catalog.store_to_string store in
  let store_holds_reference () =
    match sandbox_image_tag_presence ~command ~tag:reference with
    | Tag_present -> Ok ()
    | Tag_absent ->
      Error
        (Printf.sprintf
           "sandbox-image: the %s image store did not report %s (`image inspect` \
            exited 1, which is also how a stopped store answers), so nothing \
            was promoted. Check that the store is running and holds the tag; \
            build or load it there first."
           store_name reference)
    | Store_unanswered detail ->
      Error
        (Printf.sprintf
           "sandbox-image: could not ask the %s image store whether %s is there \
            (%s), so nothing was promoted."
           store_name reference detail)
  in
  let* path =
    sandbox_image_change_catalog ~base_path (fun catalog ->
      let* next =
        Keeper_sandbox_image_catalog.promote catalog ~name ~store ~reference
        |> Result.map_error (fun error ->
             "sandbox-image: " ^ Keeper_sandbox_image_catalog.change_error_to_string error)
      in
      let* () = store_holds_reference () in
      Ok next)
  in
  Ok (Printf.sprintf "%s on %s is now %s, recorded in %s." name store_name reference path)

let sandbox_image_promote_exit base_path runtime name reference =
  let open Result.Syntax in
  sandbox_image_exit_of
    (let* () =
       if Keeper_sandbox_image_catalog.is_reference reference then Ok ()
       else
         Error
           (Printf.sprintf
              "sandbox-image: %S is not repository:tag (a tag after the last ':'; \
               not a digest reference, not starting with '-')"
              reference)
     in
     let* runtime = runtime in
     sandbox_image_promote ~base_path ~command:(sandbox_image_store_command runtime)
       ~store:(sandbox_image_store runtime) ~name ~reference)

(* Setup leaves the host able to start a Keeper that names [base]: when the
   catalog has no [base] build for the chosen store, it builds one under a new
   tag and promotes it. A promoted build is left alone. One the catalog names
   and the store no longer has is not rebuilt behind the operator's back:
   the catalog would then name a build nobody promoted. Names come from the
   catalog this binary ships, so [base] is always one; a host that has not
   promoted anything yet has no builds, which is the first case. *)
let sandbox_image_ensure_exit ~base_path runtime =
  let open Result.Syntax in
  let recipe = Keeper_sandbox_image_version.base_embedded in
  let name = recipe.Keeper_sandbox_image_version.name in
  let store = sandbox_image_store runtime in
  let store_name = Keeper_sandbox_image_catalog.store_to_string store in
  sandbox_image_exit_of
    (let* builder = sandbox_image_builder runtime in
     let build_and_promote () =
       let built_at = Unix.gettimeofday () in
       let tag = Keeper_sandbox_image_version.tag ~built_at recipe in
       let* () =
         match sandbox_image_tag_presence ~command:builder.build_command ~tag with
         (* The same recipe in the same minute: an earlier setup built it and
            did not get to promote it. *)
         | Tag_present -> Ok ()
         | Tag_absent ->
           let labels = Keeper_sandbox_image_version.labels ~built_at recipe in
           if sandbox_image_build ~builder ~recipe ~tag ~labels = Cmd.Exit.ok then Ok ()
           else Error (Printf.sprintf "sandbox-image: building %s failed, so nothing was promoted." tag)
         | Store_unanswered detail ->
           Error
             (Printf.sprintf
                "sandbox-image: could not ask the image store whether %s is there (%s), \
                 so nothing was built."
                tag detail)
       in
       sandbox_image_promote ~base_path ~command:builder.build_command ~store ~name
         ~reference:tag
     in
     match Keeper_sandbox_image_resolver.resolve_in_workspace ~base_path ~store (Some name) with
     | Ok pinned ->
       let reference = pinned.Keeper_sandbox_image_catalog.reference in
       (match sandbox_image_tag_presence ~command:builder.build_command ~tag:reference with
        | Tag_present ->
          Ok (Printf.sprintf "%s on %s is %s; left as it is." name store_name reference)
        | Tag_absent ->
          let runtime_flag =
            match runtime with
            | None -> ""
            | Some backend -> " --runtime " ^ Keeper_microvm_backend.to_string backend
          in
          Error
            (Printf.sprintf
               "sandbox-image: the catalog names %s for %s on %s and the image store \
                does not have it. Build %s again with `masc sandbox-image%s` and \
                promote the tag it prints, or promote an earlier tag the store \
                still has: `masc sandbox-image promote %s <tag>%s`."
               reference name store_name name runtime_flag name runtime_flag)
        | Store_unanswered detail ->
          Error
            (Printf.sprintf
               "sandbox-image: could not ask the image store whether %s is there (%s)."
               reference detail))
     | Error (Keeper_sandbox_image_resolver.Unresolved
                (Keeper_sandbox_image_catalog.Not_built_on_host _)) -> build_and_promote ()
     | Error
         (( Keeper_sandbox_image_resolver.Not_declared
          | Keeper_sandbox_image_resolver.Unresolved
              (Keeper_sandbox_image_catalog.Unknown_image _)
          | Keeper_sandbox_image_resolver.No_image_store _
          | Keeper_sandbox_image_resolver.Catalog_unreadable _ )
          as error) ->
       Error ("sandbox-image: " ^ Keeper_sandbox_image_resolver.error_to_string error))

let sandbox_image_name_arg =
  let doc = "Image name from the catalog (config/sandbox-images.toml), such as base or ocaml." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)

let sandbox_image_promote_cmd =
  let doc = "Make a built image the current build of a catalog name on this host." in
  let man =
    [ `S Manpage.s_description
    ; `P
        "Asks the image store --runtime names whether it holds REFERENCE, and \
         records REFERENCE as the build NAME starts from on that store. A \
         reference the store does not hold is refused. The name has to be in \
         the catalog already."
    ; `P
        "To go back, promote an earlier tag the store still has. `masc \
         sandbox-image` refuses a tag its store already holds, so a tag it \
         built names that build until the image is removed or retagged \
         outside masc; the catalog cannot tell when that happens."
    ; `P
        "On Docker, apple_container and nerdctl_kata, `masc sandbox-image` \
         builds the tag to promote. msb has no build command: load a build \
         into its store with `msb load`, then promote that tag with --runtime \
         microsandbox."
    ]
  in
  let reference =
    let doc =
      "Image reference in that store: the tag `masc sandbox-image` printed, or \
       for microsandbox the tag `msb load` put there."
    in
    Arg.(required & pos 1 (some string) None & info [] ~docv:"REFERENCE" ~doc)
  in
  Cmd.v (Cmd.info "promote" ~doc ~man)
    Term.(
      const sandbox_image_promote_exit $ base_path $ sandbox_image_runtime_term
      $ sandbox_image_name_arg $ reference)

let sandbox_image_cmd =
  let doc = "Build a Keeper sandbox image under a tag that names that one build." in
  let man =
    [ `S Manpage.s_description
    ; `P
        "A Keeper on sandbox_profile = \"docker\" runs each turn inside an \
         image, and the image MASC develops itself in carries OCaml and this \
         project's opam dependencies -- the wrong toolchain for anything else, \
         and buildable only from a source checkout."
    ; `P
        "This builds the other one: bash, ripgrep and git on a Debian base, \
         which is what a turn needs to read, search and edit a repository. The \
         recipe is embedded in this binary and goes straight to the runtime's \
         build command, so no source checkout or prepublished MASC image is \
         needed. The initial Debian base image pull and package downloads \
         require network access."
    ; `P
        "It carries gh and python3 because MASC itself asks the guest for \
         them: it mounts a GitHub CLI config there, and its own \
         repository-checkout probe runs python3. A Keeper that has to build a \
         project needs that project's toolchain instead, named in its TOML \
         with sandbox_image; the container is read-only, so a turn cannot \
         install what is missing."
    ; `P
        "Without --tag the image is tagged \
         masc-sandbox-<recipe>:<UTC build minute>-<input hash>, where the hash \
         covers the Dockerfile and every file its inputs list. A tag already in \
         the store is refused, with or without --tag: a tag names one build \
         and is never moved to new content. Recipes other than base live under \
         sandbox-images/ in a checkout and are read with --source."
    ]
  in
  let print_only =
    let doc = "Write the Dockerfile to stdout instead of building it." in
    Arg.(value & flag & info [ "print" ] ~doc)
  in
  let tag =
    let doc =
      "Image tag to build. The default names the build: \
       masc-sandbox-<recipe>:<UTC minute>-<input hash>."
    in
    Arg.(value & opt (some string) None & info [ "tag" ] ~docv:"TAG" ~doc)
  in
  let recipe_name =
    let doc =
      "Recipe under sandbox-images/ to build. The default, "
      ^ Keeper_sandbox_image_version.(base_embedded.name)
      ^ ", is carried in this binary; any other needs --source."
    in
    Arg.(
      value
      & opt string Keeper_sandbox_image_version.(base_embedded.name)
      & info [ "recipe" ] ~docv:"NAME" ~doc)
  in
  let source =
    let doc = "Checkout to read the recipe and its inputs from." in
    Arg.(value & opt (some dir) None & info [ "source" ] ~docv:"DIR" ~doc)
  in
  Cmd.group
    ~default:
      Term.(
        const sandbox_image_cmd_exit $ print_only $ tag $ sandbox_image_runtime_term
        $ recipe_name $ source)
    (Cmd.info "sandbox-image" ~doc ~man)
    [ sandbox_image_promote_cmd ]

(* Catalog model families are selectable suggestions, not account entitlement.
   Do not expose broad fallback rows such as [gpt], [cc:] or [claude_code]
   as if they were concrete CLI model IDs. *)
type wizard_model_client = Wizard_claude_code | Wizard_codex

let wizard_model_client_arg =
  Arg.enum [ "claude-code", Wizard_claude_code; "codex", Wizard_codex ]

let wizard_model_entries client catalog =
  let suggested_client = match client with
    | Wizard_claude_code -> Llm_provider.Model_catalog.Claude_code
    | Wizard_codex -> Llm_provider.Model_catalog.Codex in
  Llm_provider.Model_catalog.model_entries catalog
  |> List.filter (fun (entry : Llm_provider.Model_catalog.model_entry) ->
      List.mem suggested_client entry.suggested_clients)

let wizard_exact_model_entries ~prefer_bare model entries =
  let requested = Llm_provider.Model_identifiers.Model_id.of_string model in
  let exact_entries = entries
    |> List.filter (fun (entry : Llm_provider.Model_catalog.model_entry) ->
      match requested with
      | Error _ -> false
      | Ok requested ->
        let same raw = match Llm_provider.Model_identifiers.Model_id.of_string raw with
          | Ok id -> Llm_provider.Model_identifiers.Model_id.equal id requested
          | Error _ -> false in
        Llm_provider.Model_identifiers.Model_id.equal entry.model_id requested
        || Option.fold ~none:false ~some:(List.exists same) entry.supported_models)
  in
  let entries =
    if prefer_bare
    then
      match List.filter (fun (entry : Llm_provider.Model_catalog.model_entry) ->
        Option.is_none entry.provider_name) exact_entries with
      | [] -> exact_entries
      | bare -> bare
    else exact_entries
  in
  entries

let wizard_model_image_input ~prefer_bare model entries =
  let values = wizard_exact_model_entries ~prefer_bare model entries
    |> List.map (fun (entry : Llm_provider.Model_catalog.model_entry) ->
         match entry.supports_image_input with
         | Some _ as declared -> declared
         | None ->
           Option.bind entry.base_label (fun preset ->
             (Llm_provider.Capability_profile.capabilities_of_preset preset).declared_image_input))
    |> List.sort_uniq (Option.compare Bool.compare) in
  match values with [Some value] -> Some value | _ -> None

let wizard_model_context ?(prefer_bare = false) model entries =
  let contexts = wizard_exact_model_entries ~prefer_bare model entries
    |> List.filter_map (fun (entry : Llm_provider.Model_catalog.model_entry) ->
      match entry.max_context_tokens with
      | Some context when context > 0 -> Some context
      | _ -> None)
    |> List.sort_uniq Int.compare
  in
  match contexts with [ context ] -> Some context | [] | _ :: _ -> None

let runtime_model_list_cmd =
  let client =
    Arg.(value & pos 0 (some wizard_model_client_arg) None & info [] ~docv:"CLIENT")
  in
  let provider =
    Arg.(value & opt (some string) None & info [ "provider" ] ~docv:"PROVIDER"
      ~doc:"List the catalog's curated rows for one named provider instead of a client's.")
  in
  let usage = "runtime-model-list: pass a CLIENT (claude-code, codex) or --provider PROVIDER, not both" in
  let run client provider =
    let models_result = match client, provider with
      | Some _, Some _ | None, None -> Error usage
      | Some client, None ->
        (match Llm_provider.Model_catalog.load_default () with
         | Error message -> Error message
         | Ok catalog ->
           let entries = wizard_model_entries client catalog in
           let entries = match client with
             | Wizard_codex -> List.filter (fun (entry : Llm_provider.Model_catalog.model_entry) ->
                 Option.is_none entry.provider_name) entries
             | Wizard_claude_code -> entries in
           Ok
             (`List
               (entries
                |> List.map (fun (entry : Llm_provider.Model_catalog.model_entry) ->
                       Llm_provider.Model_identifiers.Model_id.to_string entry.model_id)
                |> List.sort_uniq String.compare
                |> List.filter_map (fun model ->
                     Option.map (fun context -> `Assoc [ "id", `String model
                                                       ; "label", `String model
                                                       ; "max_context", `Int context
                                                       ; "supports_image_input", (match wizard_model_image_input
                                                           ~prefer_bare:(match client with Wizard_codex -> true | Wizard_claude_code -> false)
                                                           model entries with Some value -> `Bool value | None -> `Null)
                                                       ; "release", Model_release_evidence.default_model_json
                                                           ~publisher:(match client with Wizard_claude_code -> "anthropic" | Wizard_codex -> "openai")
                                                           ~model_id:model ])
                       (* Bare rows describe the native client; a direct API
                          row can have a different context for the same ID. *)
                       (wizard_model_context
                          ~prefer_bare:(match client with Wizard_codex -> true | Wizard_claude_code -> false)
                          model entries)))))
      | None, Some provider_id -> Runtime_wizard_inventory.provider_model_rows provider_id
    in
    match models_result with
    | Error message -> prerr_endline message; 1
    | Ok models ->
      print_endline (Yojson.Safe.to_string (`Assoc [
        "source", `String "installed MASC model catalog";
        "account_availability_verified", `Bool false;
        "models", models ]));
      0
  in
  Cmd.v (Cmd.info "runtime-model-list" ~doc:"List catalog model IDs and context limits for an official client or, with --provider, a named catalog provider; account availability is not verified.")
    Term.(const run $ client $ provider)

let runtime_codex_models_cmd =
  let cli = Arg.(value & opt string "codex" & info ["cli-path"] ~docv:"EXECUTABLE") in
  let account_home = Arg.(value & opt (some string) None & info ["account-home"]
    ~docv:"DIRECTORY" ~doc:"Selected CODEX_HOME for metadata discovery.") in
  let run base_path cli_path account_home =
    Masc_cli_codex_models.run ~base_path
      ~cli_path:(Runtime_official_cli_install.spawn_path Codex ~command:cli_path)
      ~account_home ~timeout_s:runtime_probe_subscription_timeout_s
  in
  Cmd.v (Cmd.info "runtime-codex-models" ~doc:"Refresh selected Codex model metadata in an isolated connection home without a model turn. The workspace decides whether the operator may start Codex on the account.")
    Term.(const run $ base_path $ cli $ account_home)

let runtime_muse_models_cmd =
  let cli = Arg.(value & opt string "muse" & info ["cli-path"] ~docv:"EXECUTABLE") in
  let account_home = Arg.(required & opt (some string) None & info ["account-home"]
    ~docv:"DIRECTORY" ~doc:"Explicit Muse account HOME; never inherited from the caller.") in
  let timeout = Arg.(value & opt float runtime_probe_subscription_timeout_s
    & info ["timeout-s"] ~docv:"SECONDS"
      ~doc:"Finite positive deadline for the metadata exchange, including protocol notifications; blocking account preparation can delay it.") in
  let run base_path cli_path account_home timeout_s =
    if not (Float.is_finite timeout_s) || timeout_s <= 0. then (
      prerr_endline "Muse discovery timeout must be finite and positive.";
      1)
    else Masc_cli_muse_models.run ~base_path
      ~cli_path:(Runtime_official_cli_install.spawn_path Muse ~command:cli_path)
      ~account_home ~timeout_s in
  Cmd.v (Cmd.info "runtime-muse-models"
    ~doc:"List source-labelled Muse model metadata without a session or model turn; account availability is not verified. The workspace decides whether the operator may start Muse on the account.")
    Term.(const run $ base_path $ cli $ account_home $ timeout)

let runtime_account_login_cmd =
  let client = Arg.(required & opt (some (enum
      [ "codex", Runtime_setup_login_client.Codex_home; "claude", Runtime_setup_login_client.Claude_home;
        "muse", Runtime_setup_login_client.Muse_home ])) None
    & info ["client"] ~docv:"CLIENT" ~doc:"The official client to sign in: codex, claude or muse.") in
  let cli = Arg.(value & opt (some string) None & info ["cli-path"] ~docv:"EXECUTABLE"
    ~doc:"The client's executable; its usual command name when omitted.") in
  let account_home = Arg.(required & opt (some string) None & info ["account-home"]
    ~docv:"DIRECTORY" ~doc:"Explicit account home runtime.toml declares; never inherited from the caller.") in
  let run client cli_path account_home =
    let install_client = match client with
      | Runtime_setup_login_client.Codex_home -> Runtime_official_cli_install.Codex
      | Claude_home -> Runtime_official_cli_install.Claude
      | Muse_home -> Runtime_official_cli_install.Muse in
    let command = match cli_path with
      | Some command -> command
      | None -> Runtime_official_cli_install.name install_client in
    Masc_cli_account_login.run ~client
      ~cli_path:(Runtime_official_cli_install.spawn_path install_client ~command)
      ~account_home in
  Cmd.v (Cmd.info "runtime-account-login"
    ~doc:"Run the official sign-in for a declared Codex, Claude Code or Muse Code account home with the environment /login gives that client.")
    Term.(const run $ client $ cli $ account_home)

let runtime_setup_render_cmd =
  let spec = Arg.(required & opt (some string) None & info ["spec"] ~doc:"Private setup JSON file.") in
  let workspace = Arg.(value & opt (some string) None & info ["base-path"]
    ~doc:"Resolve an existing account from this workspace before rendering its model identity.") in
  Cmd.v (Cmd.info "runtime-setup-render" ~doc:"Render a native runtime specification for local setup.")
    Term.(const (fun base_path spec_path -> Masc_cli_runtime_setup.render ~base_path ~spec_path) $ workspace $ spec)

let runtime_setup_inventory_cmd =
  Cmd.v (Cmd.info "runtime-setup-inventory" ~doc:"Read setup choices and their configuration revision together, from the workspace's running server while it answers.")
    Term.(const (fun base_path port agent -> Masc_cli_runtime_setup.inventory ~base_path ~port ~agent)
      $ base_path $ port $ login_agent)

let runtime_setup_batch_cmd =
  let request = Arg.(required & opt (some string) None & info ["request"] ~doc:"Private setup selection JSON file.") in
  Cmd.v (Cmd.info "runtime-setup-batch" ~doc:"Validate and save the selected runtimes against their original revision.")
    Term.(const (fun base_path port agent request_path ->
        Masc_cli_runtime_setup.configure ~base_path ~port ~agent ~request_path)
      $ base_path $ port $ login_agent $ request)

let runtime_discover_models_cmd =
  let spec = Arg.(required & opt (some string) None & info ["spec"]
    ~doc:"Private JSON connection specification containing credential references, never raw secrets.") in
  let run path =
    let parsed = try Runtime_model_discovery.connection_of_json (Yojson.Safe.from_file path)
      with Sys_error _ | Yojson.Json_error _ -> Error Runtime_model_discovery.Invalid_connection in
    match parsed with
    | Error error -> prerr_endline (Runtime_model_discovery.error_message error); 1
    | Ok connection -> Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
        match Runtime_model_discovery.discover ~sw ~net:(Eio.Stdenv.net env) connection with
        | Ok result -> print_endline (Yojson.Safe.to_string result); 0
        | Error error -> prerr_endline (Runtime_model_discovery.error_message error); 1)) in
  Cmd.v (Cmd.info "runtime-discover-models" ~doc:"Read account or server model metadata without creating a runtime.")
    Term.(const run $ spec)

let runtime_store_credential_cmd =
  let run () =
    if Unix.isatty Unix.stdin then (
      prerr_endline "Use the hidden API-key field in masc setup. This command accepts a private stdin pipe.";
      1)
    else
      match Runtime_setup_credentials.save ~secret:(In_channel.input_all stdin) () with
      | Error error -> prerr_endline (Runtime_setup_credentials.error_message error); 1
      | Ok pending ->
        let path = Runtime_setup_credentials.reference_path pending in
        (* The local setup caller owns the returned pending reference and
           removes it if no configuration transaction commits it. *)
        Runtime_setup_credentials.retain pending;
        print_endline (Yojson.Safe.to_string (`Assoc [
          "schema", `String "masc.private_credential_reference.v1";
          "credential_file", `String path]));
        0 in
  Cmd.v (Cmd.info "runtime-store-credential" ~doc:"Save an API key from a private stdin pipe for local setup.")
    Term.(const run $ const ())

let runtime_serving_context_cmd =
  let spec = Arg.(required & opt (some string) None & info ["spec"] ~doc:"Private connection JSON with credential references.") in
  let model = Arg.(required & opt (some string) None & info ["model"] ~doc:"Exact selected model ID.") in
  let load = Arg.(value & flag & info ["load"] ~doc:"Preload only the selected Ollama model before observing its running context.") in
  let run path model load =
    let connection = try Runtime_model_discovery.connection_of_json (Yojson.Safe.from_file path)
      with Sys_error _ | Yojson.Json_error _ -> Error Runtime_model_discovery.Invalid_connection in
    match connection with
    | Error error -> prerr_endline (Runtime_model_discovery.error_message error); 1
    | Ok connection -> Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
        match Runtime_serving_context.observe ~sw ~net:(Eio.Stdenv.net env) connection ~model ~load with
        | Ok observation -> print_endline (Yojson.Safe.to_string observation); 0
        | Error error -> prerr_endline (Runtime_model_discovery.error_message error); 1)) in
  Cmd.v (Cmd.info "runtime-serving-context" ~doc:"Observe a selected Ollama or llama.cpp serving window with its protected credential.")
    Term.(const run $ spec $ model $ load)

let runtime_model_info_cmd =
  let model = Arg.(required & pos 0 (some string) None & info [] ~docv:"MODEL") in
  let client = Arg.(value & opt (some wizard_model_client_arg) None & info [ "client" ] ~docv:"CLIENT") in
  let provider = Arg.(value & opt (some string) None & info ["provider"]
    ~doc:"Limit exact catalog metadata to this provider identity; no endpoint or model-name inference.") in
  let run model client provider =
    match Llm_provider.Model_catalog.load_default () with
    | Error message -> prerr_endline message; 1
    | Ok catalog ->
      let entries = match client with
        | None -> Llm_provider.Model_catalog.model_entries catalog
        | Some client -> wizard_model_entries client catalog
      in
      let entries = match provider with
        | None -> entries
        | Some provider -> (match Agent_core.Provider_runtime_binding.find provider with
          | None -> []
          | Some binding ->
            let scoped = List.filter (fun (entry : Llm_provider.Model_catalog.model_entry) ->
              match entry.provider_name with
              | Some name -> name = binding.id || List.mem name binding.aliases
              | None -> false) entries in
            let has_exact_scoped = List.exists
              (fun (entry : Llm_provider.Model_catalog.model_entry) ->
                (match Llm_provider.Model_identifiers.Model_id.of_string model with
                 | Ok id -> Llm_provider.Model_identifiers.Model_id.equal entry.model_id id
                 | Error _ -> false)
                || Option.fold ~none:false ~some:(List.mem model) entry.supported_models)
              scoped in
            if has_exact_scoped then scoped else
            List.filter (fun (entry : Llm_provider.Model_catalog.model_entry) ->
              match entry.provider_name with
              | None -> true
              | Some name -> name = binding.id || List.mem name binding.aliases) entries) in
      (* A generic family prefix is not evidence for an unknown model. The
         explicit provider owns its scoped exact row; Codex owns its bare
         exact row. Conflicts within that chosen source remain unknown. *)
      let prefer_bare = match client, provider with
        | Some Wizard_codex, None -> true
        | Some Wizard_claude_code, _ | None, _ | Some Wizard_codex, Some _ -> false in
      match wizard_model_context ~prefer_bare model entries with
      | Some context ->
        print_endline (Yojson.Safe.to_string (`Assoc ["model", `String model; "max_context", `Int context])); 0
      | None -> 1
  in
  Cmd.v (Cmd.info "runtime-model-info" ~doc:"Read an exact model's declared context size from the installed catalog.")
    Term.(const run $ model $ client $ provider)

let setup_validate_runtime base_path =
  let config_path = runtime_config_path_for_base_path base_path in
  let loaded =
    try
      let (_ : string option) = Server_runtime_bootstrap.configure_agent_core_model_catalog_env () in
      Runtime.load_list ~config_path
      |> Result.map_error (Runtime_config_error.to_diagnostic_text ~config_path)
    with Env_config_core.Config_error message -> Error message
  in
  match loaded with
  | Error message ->
    prerr_endline (Server_runtime_bootstrap.config_load_failure_diagnostic ~detail:message);
    1
  | Ok (runtimes, default, assignments, _, lanes) ->
    let selected =
      Option.bind
        (Runtime_verification.initial_runtime_id ~default_runtime_id:default.id
          ~assignments ~lanes ~keeper_name:"imp")
        (fun id -> List.find_opt (fun (runtime : Runtime_instance.t) -> String.equal runtime.id id) runtimes) in
    match selected with
    | None -> prerr_endline "imp's assigned runtime is unavailable. Choose a model in the installation wizard."; 1
    | Some runtime ->
      Printf.printf "Model connection: %s / %s\n%!" runtime.provider.display_name runtime.model.api_name;
      if not runtime.model.tools_support then (
        prerr_endline "This model has tool calling disabled. Select a tool-capable model in the installation wizard before starting imp."; 1)
      else
        match verify_runtime_execution ~base_path runtime runtime_verification_timeout_s with
        | Error reasons ->
          Printf.eprintf "%s %s\n%!" account_access_refused (String.concat "; " reasons);
          1
        | Ok result ->
        let code = Runtime_verification.exit_code result in
        match result.failure with
        | None when code = 0 -> print_endline (Masc_cli_setup.ok_line "Model response and harmless tool roundtrip verified."); 0
        | Some failure when Runtime_setup_batch.usage_limit failure ->
          (* The same rule as the setup save: the provider answered for the
             account and declined for its usage, so the connection stands.
             The detail carries the retry hint or the usage window's reopen
             time. *)
          Printf.eprintf "%s: the provider declined the check for the account's usage, so the model's response and tool path were not measured.\n%!"
            (Runtime_verification.failure_code failure);
          Option.iter (Printf.eprintf "  %s\n%!") (Runtime_verification.failure_detail failure);
          0
        | None | Some _ ->
          (match result.failure, runtime.provider.credentials with
           | Some (Runtime_verification.Unavailable (Missing_credential _)), Some (Runtime_schema.Env key) ->
             Printf.eprintf "Missing model credential: %s. Set this variable in the shell that starts MASC.\n" key
           | (Some (Runtime_verification.Unavailable (Runtime_verification.Missing_credential _)), Some (Runtime_schema.File _ | Runtime_schema.Inline _))
           | (Some (Runtime_verification.Unavailable (Runtime_verification.Missing_credential _)), None)
           | (Some (Runtime_verification.Unavailable (Runtime_verification.Unsupported_runtime | (Runtime_verification.Tools_not_declared | (Runtime_verification.Invalid_credential _ | (Runtime_verification.Invalid_configuration _ | (Runtime_verification.Client_not_authenticated _ | (Runtime_verification.Client_not_started _ | Runtime_verification.Account_not_authorized _))))))), _)
           | (Some (Runtime_verification.Timed_out | (Runtime_verification.Tool_not_called | (Runtime_verification.Tool_result_not_consumed | (Runtime_verification.Empty_response | (Runtime_verification.Model_unreported | (Runtime_verification.Rate_limited _ | (Runtime_verification.Quota_exhausted _ | (Runtime_verification.Provider_overloaded _ | (Runtime_verification.Provider_auth_refused _ | (Runtime_verification.Provider_unreachable _ | (Runtime_verification.Model_not_found _ | Runtime_verification.Provider_rejected _))))))))))), _)
           | (None, _) -> ());
          (* Name the cause: a refused key needs a new one, a missing model
             another choice, and the operator cannot tell them apart from the
             sentence below alone. *)
          Option.iter
            (fun failure ->
               Printf.eprintf "%s: %s\n%!"
                 (Runtime_verification.failure_code failure)
                 (Runtime_verification.failure_message failure);
               Option.iter
                 (Printf.eprintf "  %s\n%!")
                 (Runtime_verification.failure_detail failure))
            result.failure;
          prerr_endline "The selected model did not pass its real response/tool check. Run masc runtime-verify for details or choose another connection in the installer.";
          code

let ensure_local_operator_login ~base_path ~port ~agent =
  match Auth_login.ensure_local_operator ~base_path ~host:"127.0.0.1" ~port
      ~agent_name:agent ~token_env_var:"MASC_TOKEN"
      ~token_lifetime:Auth_login.With_expiry () with
  | Ok None -> 0
  | Ok (Some _) -> prerr_endline "Local operator credential ready."; 0
  | Error error -> prerr_endline (Masc_domain.masc_error_to_string error); 1

let setup_cmd_exit base_path port no_tui sandbox_profile microvm_backend network_mode =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  Masc_cli_setup.run_with_selection ~network_mode ~base_path ~port ~open_tui:(not no_tui)
    ~sandbox_profile ~microvm_backend
    (* A person running setup on a terminal makes the workspace the default for
       later commands; a scripted `setup --no-tui` does not change the machine's
       default. *)
    ~initialize:(fun () -> init_cmd_exit_with ~report:Summary base_path false All (stdio_is_a_terminal ()))
    ~validate_runtime:(fun () -> setup_validate_runtime base_path)
    ~prepare_image:(fun ~selection ->
      let runtime = Masc.Sandbox_readiness.microvm_backend selection.Masc.Sandbox_readiness.backend in
      sandbox_image_ensure_exit ~base_path runtime)
    ~login:(fun () -> ensure_local_operator_login ~base_path ~port ~agent:default_login_agent)
    ~resume_models:(fun () -> Masc_cli_model_resume.run ~base_path ~port ~agent:default_login_agent)
    ~start_keeper:(fun () ->
      keeper_lifecycle_post ~action:`Boot ~base_path ~host:"127.0.0.1" ~port
        ~agent:default_login_agent ~token:None ~keeper_name:"imp"
        ~declaration:(`Assoc ["name", `String "imp"]))

let setup_preflight_cmd =
  let info = Cmd.info "setup-preflight"
    ~doc:"Read existing Keeper and Goal state without initialization or writes." in
  Cmd.v info Term.(const Masc_cli_setup.preflight_cmd_exit $ base_path)

let runtime_resume_cmd =
  let run base_path port agent = Masc_cli_model_resume.run ~base_path ~port ~agent in
  Cmd.v (Cmd.info "runtime-resume" ~doc:"Apply saved model settings to this running workspace after sign-in.")
    Term.(const run $ base_path $ port $ login_agent)

let workspace_upgrade_cmd =
  let open Masc_cli_workspace_upgrade in
  let apply = Arg.(value & opt (some string) None & info ["apply"] ~docv:"KEEPER"
    ~doc:"Back up and upgrade this selected Keeper's known released configuration.") in
  let source_sha256 = Arg.(value & opt (some string) None & info ["source-sha256"] ~docv:"SHA256"
    ~doc:"Require the exact configuration digest displayed during assessment.") in
  let restore = Arg.(value & opt (some string) None & info ["restore"] ~docv:"BACKUP_ID"
    ~doc:"Restore a selected configuration backup only while its output remains unchanged.") in
  let run_configuration base_path apply source_sha256 restore =
    let action = match apply,source_sha256,restore with
      | None,None,None -> Some Inspect
      | Some keeper_name,Some source_sha256,None -> Some (Apply {keeper_name;source_sha256})
      | None,None,Some backup_id -> Some (Restore {backup_id})
      | _ -> None in
    match action with Some action -> run ~base_path ~action
    | None -> prerr_endline "Choose configuration inspection, --apply with --source-sha256, or --restore."; 1 in
  let argument name docv doc = Arg.(required & opt (some string) None & info [name] ~docv ~doc) in
  let keeper = argument "keeper" "KEEPER" "Select the existing Keeper journal." in
  let bundle = argument "bundle" "BUNDLE_ID" "Select a preserved journal bundle." in
  let trace = argument "trace" "TRACE_ID" "Select the current trace named by Keeper metadata." in
  let adoption = argument "adoption" "ADOPTION_ID" "Select an exact-input adoption bundle." in
  let installation = argument "installation" "INSTALLATION_ID" "Select a preserved installation intent." in
  let journal_source = argument "source-sha256" "SHA256" "Require the exact assessed original journal digest." in
  let checkpoint = argument "checkpoint-sha256" "SHA256" "Require the exact assessed canonical checkpoint digest." in
  let adopted = argument "adopted-sha256" "SHA256" "Require the exact assessed derivative journal digest." in
  let leaf name doc action =
    Cmd.v (Cmd.info name ~doc) Term.(const (fun base_path action -> run ~base_path ~action) $ base_path $ action) in
  let journal = Cmd.group (Cmd.info "journal" ~doc:"Offline journal evidence, explicit input adoption and conditional installation.")
    [leaf "inspect" "Read an existing journal identity without conversion."
       Term.(const (fun keeper -> Inspect_journal keeper) $ keeper);
     leaf "prepare" "Preserve the assessed original journal and prepare a private recovery bundle."
       Term.(const (fun keeper_name source_sha256 -> Prepare_journal {keeper_name;source_sha256}) $ keeper $ journal_source);
     leaf "bundle" "Verify a preserved journal bundle without installation."
       Term.(const (fun bundle -> Inspect_journal_bundle bundle) $ bundle);
     leaf "input" "Assess exact current input evidence against a preserved bundle."
       Term.(const (fun bundle_id trace_id -> Inspect_journal_input {bundle_id;trace_id}) $ bundle $ trace);
     leaf "adopt" "Explicitly adopt assessed canonical input into a separate bundle."
       Term.(const (fun bundle_id trace_id checkpoint_sha256 -> Adopt_journal_input {bundle_id;trace_id;checkpoint_sha256})
         $ bundle $ trace $ checkpoint);
     leaf "adoption" "Verify an input-adoption bundle and its actual retained payload."
       Term.(const (fun adoption -> Inspect_journal_adoption adoption) $ adoption);
     leaf "installation-plan" "Assess exact original and adopted bytes before offline installation."
       Term.(const (fun adoption -> Assess_journal_installation adoption) $ adoption);
     leaf "install" "Replace the unchanged original journal with the explicitly adopted derivative while offline."
       Term.(const (fun adoption_id source_sha256 adopted_sha256 -> Install_journal {adoption_id;source_sha256;adopted_sha256})
         $ adoption $ journal_source $ adopted);
     leaf "installations" "Discover installation intents and per-record errors without creating or repairing evidence."
       Term.(const List_journal_installations);
     leaf "installation" "Inspect an intent and classify actual original, adopted, changed or missing bytes."
       Term.(const (fun installation -> Inspect_journal_installation installation) $ installation);
     leaf "restore" "Restore original journal bytes only while installed journal and input evidence remain unchanged."
       Term.(const (fun installation -> Restore_journal_installation installation) $ installation)] in
  Cmd.group (Cmd.info "workspace-upgrade" ~doc:"Inspect configuration upgrades and manage offline journal recovery.")
    ~default:Term.(const run_configuration $ base_path $ apply $ source_sha256 $ restore)
    [journal]

let antigravity_account_cmd =
  let cli_path = Arg.(value & opt string "agy" & info ["cli-path"] ~docv:"EXECUTABLE") in
  let sign_in = Arg.(value & flag & info ["sign-in"] ~doc:"Open official sign-in in a private account directory.") in
  let credential = Arg.(value & opt (some string) None & info ["credential-file"] ~docv:"PRIVATE_REFERENCE") in
  let run base_path cli_path sign_in credential =
    let action = match sign_in, credential with
      | true, Some _ -> None
      | true, None -> Some Masc_cli_antigravity.Sign_in
      | false, Some path -> Some (Use_reference path)
      | false, None -> Some Import_current in
    match action with
    | None -> prerr_endline "Choose sign-in or an existing account reference."; 1
    | Some action ->
      Masc_cli_antigravity.account ~base_path
        ~cli_path:(Runtime_official_cli_install.spawn_path Antigravity ~command:cli_path)
        ~timeout_s:runtime_probe_subscription_timeout_s ~action in
  Cmd.v (Cmd.info "runtime-antigravity-account" ~doc:"Select an Antigravity account and list its actual models without a model turn.")
    Term.(const run $ base_path $ cli_path $ sign_in $ credential)

let antigravity_models_cmd =
  let cli_path = Arg.(value & opt string "agy" & info ["cli-path"] ~docv:"EXECUTABLE") in
  let credential = Arg.(required & opt (some string) None & info ["credential-file"] ~docv:"PRIVATE_REFERENCE") in
  let run base_path cli_path oauth_source =
    Masc_cli_antigravity.models ~base_path
      ~cli_path:(Runtime_official_cli_install.spawn_path Antigravity ~command:cli_path)
      ~oauth_source ~timeout_s:runtime_probe_subscription_timeout_s
  in
  Cmd.v (Cmd.info "runtime-antigravity-models" ~doc:"Refresh the selected Antigravity account's models without a model turn. The workspace decides whether the host account may start.")
    Term.(const run $ base_path $ cli_path $ credential)

let antigravity_context_cmd =
  let cli_path = Arg.(value & opt string "agy" & info ["cli-path"] ~docv:"EXECUTABLE") in
  let credential = Arg.(required & opt (some string) None & info ["credential-file"] ~docv:"PRIVATE_REFERENCE") in
  let model = Arg.(required & opt (some string) None & info ["model"] ~docv:"MODEL_ID") in
  let run base_path cli_path oauth_source model_id =
    match Masc_cli_onboarding.python (Unix.realpath Sys.executable_name) with
    | None -> prerr_endline "The installed Python helper is missing. Reinstall the complete MASC release."; 1
    | Some python_path ->
      Masc_cli_antigravity.context ~base_path ~python_path
        ~cli_path:(Runtime_official_cli_install.spawn_path Antigravity ~command:cli_path)
        ~oauth_source ~model_id
        ~timeout_s:runtime_probe_subscription_timeout_s in
  Cmd.v (Cmd.info "runtime-antigravity-context" ~doc:"Read the selected account model's actual CLI context without a model prompt. The workspace decides whether the host account may start.")
    Term.(const run $ base_path $ cli_path $ credential $ model)

let setup_server_cmd =
  let inspect base_path port = Masc_cli_owner_upgrade.inspect ~base_path ~port in
  Cmd.v (Cmd.info "setup-server" ~doc:"Inspect this setup port and offer an unused port without changing any server.")
    Term.(const inspect $ base_path $ port)

let setup_stop_owner_cmd =
  let expected_version = Arg.(required & opt (some string) None & info ["expected-version"] ~docv:"VERSION") in
  let stop base_path port agent expected_version = Masc_cli_owner_upgrade.stop ~base_path ~port ~agent ~expected_version
    ~login:(fun () -> ensure_local_operator_login ~base_path ~port ~agent) in
  Cmd.v (Cmd.info "setup-stop-previous-owner" ~doc:"Gracefully stop the authenticated owner selected for workspace upgrade.")
    Term.(const stop $ base_path $ port $ login_agent $ expected_version)

let restart_cmd =
  let log_path =
    Arg.(value & opt (some string) None & info ["log"] ~docv:"FILE"
      ~doc:"Append the replacement server's output to $(docv). Defaults to a new \
            masc-start-<UTC time>.log under the workspace's .masc/logs.")
  in
  let restart base_path port host agent log_path =
    Masc_cli_restart.run ~base_path ~port ~host ~log_path ~agent
      ~login:(fun () -> ensure_local_operator_login ~base_path ~port ~agent)
  in
  Cmd.v (Cmd.info "restart"
    ~doc:"Ask this workspace's running server to stop gracefully, start the installed build \
          in its place in the background, and wait until it is ready. Nothing is forced down.")
    Term.(const restart $ base_path $ port $ host $ login_agent $ log_path)

let runtime_client_path_cmd =
  let client = Arg.(required & opt (some Masc_cli_client_path.client_arg) None & info ["client"]
    ~docv:"CLIENT" ~doc:"claude-code, codex, antigravity or muse-code.") in
  let command = Arg.(value & opt (some string) None & info ["command"]
    ~docv:"COMMAND" ~doc:"The configured command; defaults to the client's own name.") in
  Cmd.v (Cmd.info "runtime-client-path"
    ~doc:"Print where an official client runs from, as the runtime will spawn it.")
    Term.(const (fun client command -> Masc_cli_client_path.run ~client ~command) $ client $ command)

let sandbox_catalog_cmd =
  let inspect requested =
    (* The setup journey reads this catalog for the workspace doctor offered;
       both answer in Workspace_root's order. *)
    let base_path = selected_base_path requested in
    print_endline (Yojson.Safe.to_string
      (Masc.Sandbox_readiness.inspect ~run:Masc.Sandbox_readiness.system_runner ~base_path));
    0 in
  Cmd.v (Cmd.info "sandbox-catalog" ~doc:"Inspect sandbox choices and host prerequisites without changing settings.")
    Term.(const inspect $ run_base_path)

let doctor_cmd =
  let json = Arg.(value & flag & info ["json"]
    ~doc:"Print the shared read-only onboarding state as JSON.") in
  let inspect requested json =
    (* The setup journey asks doctor which workspace to offer, so doctor answers
       in the same order `masc start` boots in; a workspace cwd is found here. *)
    let state = Onboarding_status.inspect
        ~sandbox:(Onboarding_status.Probe_with Masc.Sandbox_readiness.system_runner)
        ~base_path:(selected_base_path requested) in
    print_endline (if json then Yojson.Safe.to_string (Onboarding_status.to_json state)
                   else Onboarding_status.to_text state);
    (* Reporting incomplete preparation is successful observation, never a
       claim that authentication, model calls or sandbox execution passed. *)
    0
  in
  Cmd.v (Cmd.info "doctor" ~doc:"Show workspace and imp preparation without starting models or changing files.")
    Term.(const inspect $ run_base_path $ json)

(* cmdliner cannot fail a flag on the value of another flag, so the pairing
   rule (a backend only means something under microvm) is checked here and
   reported as a usage error rather than being silently ignored. *)
let setup_sandbox_selection sandbox_profile microvm_backend =
  match sandbox_profile, microvm_backend with
  | None, Some _ ->
    `Error
      (false,
       "--microvm-backend requires --sandbox-profile microvm")
  | Some profile, backend ->
    (match Keeper_sandbox_config.sandbox_profile_of_string profile with
     | None ->
       `Error
         (false,
          Printf.sprintf "--sandbox-profile takes one of: %s"
            (String.concat ", " Keeper_sandbox_config.valid_sandbox_profile_strings))
     | Some Keeper_sandbox_config.Micro_vm ->
       (match backend with
        | None -> `Ok (Some Keeper_sandbox_config.Micro_vm, None)
        | Some raw ->
          (match Keeper_microvm_backend.of_string raw with
           | None ->
             `Error
               (false,
                Printf.sprintf "--microvm-backend takes one of: %s"
                  (String.concat ", " Keeper_microvm_backend.valid_strings))
           | Some backend -> `Ok (Some Keeper_sandbox_config.Micro_vm, Some backend)))
     | Some ((Keeper_sandbox_config.Docker | Keeper_sandbox_config.Remote_ssh) as profile) ->
       (match backend with
        | None -> `Ok (Some profile, None)
        | Some _ ->
          `Error (false, "--microvm-backend requires --sandbox-profile microvm")))
  | None, None -> `Ok (None, None)

let setup_cmd =
  let no_tui = Arg.(value & flag & info ["no-tui"]
    ~doc:"Prepare imp and leave the server running without opening the terminal UI.") in
  let sandbox_profile =
    let doc =
      Printf.sprintf
        "Sandbox imp runs its turns on (%s). Recorded in imp's keeper TOML, and          setup checks what that profile needs on this host. Omitted, setup uses          the profile imp already declares."
        (String.concat ", " Keeper_sandbox_config.valid_sandbox_profile_strings)
    in
    Arg.(value & opt (some string) None & info [ "sandbox-profile" ] ~docv:"PROFILE" ~doc)
  in
  let microvm_backend =
    let doc =
      Printf.sprintf
        "MicroVM runtime (%s), valid only with --sandbox-profile microvm."
        (String.concat ", " Keeper_microvm_backend.valid_strings)
    in
    Arg.(value & opt (some string) None & info [ "microvm-backend" ] ~docv:"BACKEND" ~doc)
  in
  let network_mode = Arg.(value & opt (some string) None & info ["network-mode"]
    ~doc:"Sandbox network mode: inherit, none, or policy where supported.") in
  let run base_path requested_port no_tui sandbox_profile microvm_backend network_mode =
    let network = match network_mode with
      | None -> Ok None
      | Some value -> (match Keeper_types_profile_sandbox.network_mode_of_string value with
        | Some mode -> Ok (Some mode)
        | None -> Error "Unknown sandbox network mode. Use masc sandbox-catalog to see supported choices.") in
    match network with
    | Error message -> `Error (false, message)
    | Ok network_mode ->
    match setup_sandbox_selection sandbox_profile microvm_backend with
    | `Error _ as error -> error
    | `Ok (profile, backend) ->
      if not no_tui && profile = None && backend = None && network_mode = None && stdio_is_a_terminal () then
        `Ok (Masc_cli_onboarding.run ~base_path ~port:requested_port ~resume:false ~sandbox_step:false)
      else
        match Workspace_root.resolve_current ~flag:base_path with
        | Ok workspace ->
          publish_workspace_root workspace;
          let path = workspace.Workspace_root.root in
          (match resolve_connection_port (Some path) requested_port with
           | Ok port -> `Ok (setup_cmd_exit path (Workspace_connection.to_int port) no_tui profile backend network_mode)
           | Error error -> `Error (false, Workspace_connection.error_message error))
        | Error error ->
          `Error (false, Workspace_root.error_message error
                         ^ "\nOr run masc setup in a terminal to choose one.")
  in
  Cmd.v
    (Cmd.info "setup"
       ~doc:"Prepare imp's sandbox, start imp, and open its workspace.")
    Term.(ret (const run $ run_base_path $ port_argument $ no_tui $ sandbox_profile $ microvm_backend $ network_mode))

let setup_gc () = Minor_heap.tune ()

(* Internal elevation endpoint: no workspace, login, or model initialization. *)
let sandbox_install_apple_verified_cmd =
  let run argv = match argv with
    | [] -> Error ()
    | executable :: _ ->
      try
        let channel = Unix.open_process_args_in executable (Array.of_list argv) in
        let status = ref None in
        let output = Fun.protect
          ~finally:(fun () -> status := Some (Unix.close_process_in channel))
          (fun () -> In_channel.input_all channel) in
        (match !status with
         | Some (Unix.WEXITED 0) -> Ok output
         | Some (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) | None -> Error ())
      with Unix.Unix_error _ | Sys_error _ -> Error () in
  let execute source sha256 size =
    match Masc.Apple_container_install.install_privileged ~run ~source ~sha256 ~size with
    | Ok () -> print_endline "Package installed. Sandbox service and guest execution still require verification."; Cmd.Exit.ok
    | Error error -> prerr_endline (Masc.Apple_container_install.error_message error); Cmd.Exit.some_error in
  let source = Arg.(required & opt (some string) None & info ["source"]) in
  let sha256 = Arg.(required & opt (some string) None & info ["sha256"]) in
  let size = Arg.(required & opt (some int) None & info ["size"]) in
  Cmd.v (Cmd.info "sandbox-install-apple-verified"
    ~doc:"Internal root-only installer for an explicitly selected Apple Container package.")
    Term.(const execute $ source $ sha256 $ size)

let sandbox_install_docker_verified_cmd =
  let source = Arg.(required & opt (some string) None & info ["source"] ~docv:"PATH") in
  let sha256 = Arg.(required & opt (some string) None & info ["sha256"] ~docv:"SHA256") in
  let size = Arg.(required & opt (some int) None & info ["size"] ~docv:"BYTES") in
  let run source sha256 size =
    match Masc.Docker_desktop_install.install_privileged ~run:Masc.Prerequisite_terminal_runner.capture ~source ~sha256 ~size with
    | Ok completion ->
      print_endline (Yojson.Safe.to_string (Masc.Docker_desktop_install.completion_to_json completion)); 0
    | Error error -> prerr_endline (Masc.Docker_desktop_install.error_message error); 1 in
  Cmd.v (Cmd.info "sandbox-install-docker-verified" ~doc:"Internal privileged installation of the selected verified Docker package.")
    Term.(const run $ source $ sha256 $ size)

let docker_account_access_cmd =
  let action = Arg.(value & opt (some string) None & info ["execute"] ~docv:"ACTION") in
  Cmd.v (Cmd.info "docker-account-access" ~doc:"Select ordinary-account Docker access or continue saved setup in a group session.")
    Term.(const (fun action base_path port -> Masc_cli_docker_session.run ~action ~base_path ~port) $ action $ run_base_path $ port)

let docker_session_resume_cmd =
  let base = base_path in
  let expected_uid = Arg.(required & opt (some int) None & info ["expected-uid"] ~docv:"UID") in
  Cmd.v (Cmd.info "docker-session-resume" ~doc:"Internal same-account continuation after Docker group selection.")
    Term.(const (fun base_path port expected_uid -> Masc_cli_docker_session.resume ~base_path ~port ~expected_uid) $ base $ port $ expected_uid)

let workspace_connection_cmd =
  let save = Arg.(value & flag & info ["save"] ~doc:"Save the explicitly selected desired port; this is not a readiness check.") in
  let run requested cli save =
    match resolve_connection_port requested cli with
    | Error error -> prerr_endline (Workspace_connection.error_message error); 1
    | Ok selected ->
      let base = selected_base_path requested in
      let saved = if not save then Ok () else match base,cli with
        | Some base_path,Some _ -> Workspace_connection.save ~base_path ~port:selected
        | _ -> Error Workspace_connection.Invalid_port in
      match saved with
      | Error error -> prerr_endline (Workspace_connection.error_message error); 1
      | Ok () -> print_endline (Yojson.Safe.to_string (`Assoc [
          "schema",`String "masc.workspace_connection.v1";
          "base_path",(match base with None -> `Null | Some path -> `String path);
          "port",`Int (Workspace_connection.to_int selected);"readiness",`String "not_checked"])); 0 in
  Cmd.v (Cmd.info "workspace-connection" ~doc:"Resolve or save this workspace's desired HTTP port.")
    Term.(const run $ run_base_path $ port_argument $ save)

let prerequisite_actions_cmd =
  let dependency = Arg.(required & pos 0 (some string) None & info [] ~docv:"DEPENDENCY") in
  let action = Arg.(value & opt (some string) None & info ["execute"]
    ~doc:"Execute this explicitly selected action from the current host catalog.") in
  Cmd.v (Cmd.info "prerequisite-actions" ~doc:"Show installation actions for a sandbox, official client, pdf-tools, presentation-tools, ego-browser, or searxng.")
    (* Resolved on demand: only presentation-tools and searxng are scoped to a workspace, and
       an operator installing Codex or Docker has not made one yet. Taking the
       resolving [base_path] term here refused every dependency with "MASC_BASE_PATH
       is not set" -- advice that does not install anything. *)
    Term.(const (fun base_path dependency action ->
      Masc_cli_prerequisites.run
        ~base_path:(fun () ->
          match Workspace_root.resolve_current ~flag:base_path with
          | Ok workspace ->
            publish_workspace_root workspace;
            workspace.Workspace_root.root
          | Error error -> prerr_endline (Workspace_root.error_message error); exit 1)
        ~dependency ~action)
      $ run_base_path $ dependency $ action)

let inspect_file_cmd =
  let path = Arg.(required & pos 0 (some string) None & info [] ~docv:"FILE"
    ~doc:"Original PDF, PPTX or MP4 to inspect completely without modifying the file.") in
  Cmd.v (Cmd.info "inspect-file"
    ~doc:"Inspect original media as JSON with rendered content. No LLM verdict or Task/Goal transition.")
    Term.(const (fun base_path path -> Masc_cli_inspect_file.run ~base_path ~path) $ base_path $ path)

let inspect_checkpoint_cmd =
  let workspace =
    let doc = "Workspace containing the Keeper checkpoint." in
    Arg.(required & opt (some dir) None & info ["base-path"] ~docv:"PATH" ~doc)
  in
  let keeper =
    let doc = "Keeper whose canonical checkpoint is inspected." in
    Arg.(required & opt (some string) None & info ["keeper"] ~docv:"NAME" ~doc)
  in
  Cmd.v
    (Cmd.info "inspect-checkpoint"
       ~doc:"Print a decoded canonical Keeper checkpoint, including conversation context, as JSON.")
    Term.(const (fun base_path keeper_name ->
      Masc_cli_checkpoint_inspect.run ~base_path ~keeper_name) $ workspace $ keeper)

let cmd =
  let doc =
    "MASC workspace: the fleet TUI on a terminal, the MCP server everywhere else"
  in
  let info = Cmd.info "masc" ~version:Runtime_build_version.current ~doc in
  Cmd.group
    ~default:
      Term.(const front_door_cmd_exit $ host $ port_argument $ run_base_path $ accept_store_quarantine $ build_provenance_path $ build_provenance_sha256 $ build_provenance_device $ build_provenance_inode $ record_default_arg)
    info
    [ init_cmd
    ; inspect_file_cmd
    ; inspect_checkpoint_cmd
    ; skills_refresh_cmd
    ; start_cmd
    ; schema_observe_cmd
    ; login_cmd
    ; mcp_config_cmd
    ; runtime_default_set_cmd
    ; runtime_wizard_catalog_cmd
    ; runtime_probe_cmd
    ; runtime_token_sample_cmd
    ; runtime_verify_cmd
    ; voice_verify_cmd
    ; browser_lane_setup_cmd
    ; voice_local_setup_cmd
    ; web_search_setup_cmd
    ; config_cmd
    ; runtime_model_list_cmd
    ; runtime_codex_models_cmd
    ; runtime_muse_models_cmd
    ; runtime_account_login_cmd
    ; runtime_setup_render_cmd
    ; runtime_setup_inventory_cmd
    ; runtime_setup_batch_cmd
    ; runtime_discover_models_cmd
    ; runtime_store_credential_cmd
    ; runtime_serving_context_cmd
    ; runtime_model_info_cmd
    ; schedule_prune_cmd
    ; keeper_create_cmd
    ; keeper_github_cmd
    ; sandbox_image_cmd
    ; sandbox_install_apple_verified_cmd
    ; sandbox_install_docker_verified_cmd
    ; docker_account_access_cmd
    ; docker_session_resume_cmd
    ; workspace_connection_cmd
    ; prerequisite_actions_cmd
    ; setup_cmd
    ; setup_preflight_cmd
    ; runtime_resume_cmd
    ; workspace_upgrade_cmd
    ; antigravity_account_cmd
    ; antigravity_models_cmd
    ; antigravity_context_cmd
    ; setup_server_cmd
    ; setup_stop_owner_cmd
    ; restart_cmd
    ; doctor_cmd
    ; sandbox_catalog_cmd
    ; runtime_client_path_cmd
    ; token_cmd
    ; oauth_client_cmd
    ; auth_cmd
    ; build_commit_cmd
    ]

let () =
  setup_gc ();
  exit (Cmd.eval' cmd)
