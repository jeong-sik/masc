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
module Keeper_execution = Masc.Keeper_execution
module Keeper_runtime = Masc.Keeper_runtime
module Keeper_sandbox_runtime = Masc.Keeper_sandbox_runtime
module Keeper_github_identity = Masc.Keeper_github_identity
module Keeper_github_login_lane = Masc.Keeper_github_login_lane
module Tool_operator = Masc.Tool_operator
module Operator_control = Operator_control
module Dashboard_execution = Dashboard_execution
module Dashboard_briefing = Dashboard_briefing
module Dashboard_briefing_sections = Dashboard_briefing_sections
module Build_identity = Masc.Build_identity
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

let default_base_path = Server_mcp_transport_http.default_base_path

let is_valid_protocol_version =
  Server_mcp_transport_http.is_valid_protocol_version

let get_session_id_any = Server_mcp_transport_http.get_session_id_any

let get_protocol_version_for_session =
  Server_mcp_transport_http.get_protocol_version_for_session

module Server_routes_http = Server_routes_http

open Server_routes_http

(* Issue #8403: derive probe exemptions from Server_health_paths SSOT
   so a renamed probe stays exempt from rate limits without a separate
   manual edit here. *)
let is_rate_limit_exempt path =
  String.equal path "/health"
  || Server_health_paths.is_public path

(** [safe_reqd_respond reqd response body] guards all direct
    [Httpun.Reqd.respond_with_string] calls in the main request handler
    against the "invalid state, currently handling error" [Failure] that
    httpun raises when the reqd has already entered its error-handling path
    (e.g. client disconnect during a long AGENT_CORE turn — 2026-05-05 cycle9
    FATAL race, also see [Http_server_eio.safe_respond_with_string]).
    [Eio.Cancel.Cancelled] is always re-raised.  The result says only whether
    httpun accepted the response write, not whether the peer received it. *)
let safe_reqd_respond reqd response body =
  try
    Httpun.Reqd.respond_with_string reqd response body;
    Transport_metrics.Accepted_by_writer
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Failure msg ->
      Log.Server.warn
        "[http] reqd respond skipped (invalid state; 2026-05-05 AGENT_CORE cancel race): %s"
        msg;
      Transport_metrics.Rejected_by_writer
  | exn ->
      Log.Server.warn "[http] reqd respond unexpected exception: %s"
        (Printexc.to_string exn);
      Transport_metrics.Rejected_by_writer

(** Returns true if the request was rate-limited and a 429 response write was
    attempted on [reqd]. Caller should short-circuit further handling in that
    case. The accepted-response counter advances only when the writer returns
    normally. Health-probe paths are always allowed through.

    Enforces two complementary rate limits:
    1. Per-client IP (via [client_addr]) — protects against volumetric abuse.
    2. MCP transport requests consume the per-agent operation bucket here.
       Authenticated API operation wrappers own that charge for their routes;
       charging them here too would double-debit one request. Dashboard assets
       and read observations remain under the same per-IP resource boundary. *)
let try_rate_limit_block ~path ~client_addr ~request reqd =
  if is_rate_limit_exempt path then false
  else
    let rl_key = Masc.Rate_limit.key_of_sockaddr client_addr in
    if not (Masc.Rate_limit.check_global ~key:rl_key) then begin
      let body = Masc.Rate_limit.too_many_requests_body () in
      let rl_headers = Masc.Rate_limit.headers_global ~key:rl_key in
      let headers = Httpun.Headers.of_list (
        ("content-type", "application/json") ::
        ("content-length", string_of_int (String.length body)) ::
        rl_headers
      ) in
      let acceptance =
        safe_reqd_respond reqd
          (Httpun.Response.create ~headers `Too_many_requests) body
      in
      Transport_metrics.record_http_rate_limit_response
        ~acceptance
        ~protocol:Transport_metrics.H1
        ~scope:Transport_metrics.Client_ip;
      true
    end else if not (is_mcp_transport_request request) then false
    else
      match auth_token_from_request request with
      | None -> false
      | Some token ->
          match Masc.Rate_limit.agent_key_of_token_or_name ~token () with
          | None -> false
          | Some agent_key ->
              if Masc.Rate_limit.check_agent_global ~key:agent_key then false
              else begin
                let body = Masc.Rate_limit.too_many_agent_requests_body () in
                let rl_headers =
                  Masc.Rate_limit.headers_agent_global ~key:agent_key
                in
                let headers =
                  Httpun.Headers.of_list
                    (("content-type", "application/json")
                    :: ("content-length", string_of_int (String.length body))
                    :: rl_headers)
                in
                let acceptance =
                  safe_reqd_respond reqd
                    (Httpun.Response.create ~headers `Too_many_requests)
                    body
                in
                Transport_metrics.record_http_rate_limit_response
                  ~acceptance
                  ~protocol:Transport_metrics.H1
                  ~scope:Transport_metrics.Agent;
                true
              end

(** Returns true if the request failed origin or protocol-version
    validation and the corresponding error response was sent on [reqd].
    Caller should short-circuit further handling in that case. *)
let try_mcp_validation_block
    ~request_authority
    ~request
    ~protocol_version
    ~origin
    reqd
  =
  let is_mcp_transport = is_mcp_transport_request request in
  if
    is_mcp_transport
    && not (validate_origin ~request_authority request)
  then begin
    let body = json_rpc_error Masc.Mcp_error_code.Invalid_request "Invalid origin" in
    let headers =
      Httpun.Headers.of_list
        ([ ("content-length", string_of_int (String.length body))
         ; ("content-type", "application/json")
         ; ("vary", "Origin")
         ]
         @ mcp_headers "-" protocol_version)
    in
    let response = Httpun.Response.create ~headers `Forbidden in
    ignore (safe_reqd_respond reqd response body);
    true
  end
  else if is_mcp_transport && request.Httpun.Request.meth <> `OPTIONS &&
          not (is_valid_protocol_version protocol_version) then begin
    let body = json_rpc_error Masc.Mcp_error_code.Invalid_request "Unsupported protocol version" in
    let headers = Httpun.Headers.of_list (
      ("content-length", string_of_int (String.length body))
      :: json_headers "-" protocol_version origin
    ) in
    let response = Httpun.Response.create ~headers `Bad_request in
    ignore (safe_reqd_respond reqd response body);
    true
  end
  else false


(** Method/path dispatcher for MCP-validated requests. Caller is
    responsible for rate limiting and origin/protocol-version checks
    before invoking this function.

    [GET /ws] (same-origin WebSocket upgrade + discovery) is owned by
    the route table ([Server_routes_http_routes_frontend] via
    [Http.Router.ws_get]) and reached through
    [Http.Router.dispatch ~upgrade] below.  RFC-0281 consolidated the
    previously-duplicated main_eio upgrade/discovery handlers into the
    router so [/ws] has a single owner that actually drives the
    connection. *)
let dispatch_route ~router ~request ~path ~upgrade reqd =
  match request.Httpun.Request.meth, path with
  | `OPTIONS, _ -> options_handler request reqd
  | `DELETE, "/mcp" -> handle_delete_mcp request reqd
  | `DELETE, "/mcp/managed" ->
      handle_delete_mcp
        ~profile:Server_mcp_transport_http.Managed_agent request reqd
  | `DELETE, "/mcp/operator" ->
      handle_delete_mcp
        ~profile:Server_mcp_transport_http.Operator_remote request reqd
  (* Board reads/reactions are owned by the typed route table: exact routes
     ([/api/v1/board/reactions], [/catalog]) win over the board prefix route,
     and the prefix route resolves the bearer-bound reaction actor itself. *)
  | _ -> Http.Router.dispatch router ~upgrade request reqd

let log_late_response_failure ~context msg =
  Log.Http.warn "%s: response already unwritable; skipped late response (%s)"
    context msg

let try_internal_error_response reqd msg =
  try Http.Response.internal_error msg reqd with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> (
      match Http.Late_response.classify_write_failure exn with
      | Some failure_msg ->
          log_late_response_failure ~context:"main_eio internal_error"
            failure_msg
      | None ->
          Log.Http.warn "main_eio internal_error response failed: %s"
            (Printexc.to_string exn))

let try_auth_config_error_response reqd =
  try
    Http.Response.text
      ~status:`Service_unavailable
      "Authentication configuration unavailable"
      reqd
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    (match Http.Late_response.classify_write_failure exn with
     | Some failure_msg ->
       log_late_response_failure
         ~context:"main_eio auth configuration unavailable"
         failure_msg
     | None ->
       Log.Http.warn "main_eio auth configuration response failed: %s"
         (Printexc.to_string exn))
;;

let respond_request_authority_bad_request ~error_code ~message reqd =
  Http.Response.json_value
    ~status:`Bad_request
    (`Assoc [ "error_code", `String error_code; "error", `String message ])
    reqd
;;

(** Extended router to handle OPTIONS *)
let make_extended_handler ~trust_policy routes =
  fun client_addr gluten_reqd ->
    let reqd = gluten_reqd.Gluten.Reqd.reqd in
    (* Gluten upgrade capability — only available here at the connection
       boundary.  Threaded to [Http.Router.dispatch] so WebSocket routes
       ([Http.Router.ws_get]) can drive the post-101 connection.
       RFC-0281. *)
    let upgrade = gluten_reqd.Gluten.Reqd.upgrade in
    let request = Httpun.Reqd.request reqd in
    match
      Server_request_authority.classify_http1_request ~trust_policy request
    with
    | Server_request_authority.Missing ->
      respond_request_authority_bad_request
        ~error_code:"request_authority_missing"
        ~message:"request is missing its Host authority"
        reqd
    | Server_request_authority.Multiple ->
      respond_request_authority_bad_request
        ~error_code:"request_authority_multiple"
        ~message:"request contains more than one Host field"
        reqd
    | Server_request_authority.Malformed ->
      respond_request_authority_bad_request
        ~error_code:"request_authority_malformed"
        ~message:"request Host authority is malformed"
        reqd
    | Server_request_authority.Untrusted ->
      respond_request_authority_bad_request
        ~error_code:"request_authority_untrusted"
        ~message:"request Host is not a configured server identity"
        reqd
    | Server_request_authority.Single request_authority ->
      (match classify_request_origin ~request_authority request with
       | Multiple_origins ->
         respond_request_authority_bad_request
           ~error_code:"request_origin_multiple"
           ~message:"request contains more than one Origin field"
           reqd
       | Malformed_origin ->
         respond_request_authority_bad_request
           ~error_code:"request_origin_malformed"
           ~message:"request Origin is not one complete HTTP(S) serialized origin"
           reqd
       | Missing_origin | Single_origin _ ->
         Server_request_authority.with_current request_authority (fun () ->
        (* Authority admission precedes rate limiting, auth, and routing so no
           credential I/O or URL projection can observe an untrusted Host or
           an ambiguous/malformed Origin field set. *)
        let path = Http.Request.path request in
        if try_rate_limit_block ~path ~client_addr ~request reqd
        then ()
        else
          try
            let session_id_for_version = get_session_id_any request in
            let protocol_version =
              get_protocol_version_for_session
                ?session_id:session_id_for_version
                request
            in
            let origin = get_origin request in
            if
              try_mcp_validation_block
                ~request_authority
                ~request
                ~protocol_version
                ~origin
                reqd
            then ()
            else dispatch_route ~router:routes ~request ~path ~upgrade reqd
          with
          (* Cancellation propagates through the connection switch without
             attempting a response from a cancelled handler. *)
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | Auth.Auth_config_error _ -> try_auth_config_error_response reqd
          | exn ->
            let msg = Printexc.to_string exn in
            (match Http.Late_response.classify_write_failure exn with
             | Some failure_msg ->
               log_late_response_failure
                 ~context:"main_eio request handler"
                 failure_msg
             | None -> try_internal_error_response reqd msg)))

(** Main server loop *)
let run_server ~sw ~env ~host ~port ~base_path ~input_base_path ~on_ready ~accept_store_quarantine =
  (* Use the parent switch directly so that ALL fibers spawned by
     Server_runtime_bootstrap (background maintenance, keeper loops,
     dashboard refresh, etc.) are children of this switch.  Graceful
     shutdown explicitly fails this switch after the signal handler
     finishes its phases (see [Graceful_shutdown] below); failing the
     switch propagates cancellation to every child fiber, preventing
     the 10s force-exit timeout. *)
  try
    Server_runtime_bootstrap.run ~sw ~env ~host ~port ~base_path
      ~input_base_path ~on_ready ~accept_store_quarantine ~make_routes
      ~make_request_handler:make_extended_handler
      ~make_h2_request_handler:Server_h2_gateway.make_request_handler
      ~make_h2_error_handler:Server_h2_gateway.make_error_handler
      ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Server.error
      "[main] keeper bootstrap failed; refusing to continue without keepers: %s"
      (Printexc.to_string exn);
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
let base_path = Term.(const (function Some raw -> raw | None -> default_base_path ()) $ run_base_path)
let selected_base_path requested =
  let selected = match requested with Some _ -> requested | None -> Option.map snd (Env_config_core.base_path_source_opt ()) in
  Option.map Env_config.normalize_masc_base_path_input selected
let resolve_connection_port requested cli =
  Workspace_connection.resolve ~base_path:(selected_base_path requested) ~cli
    ~environment:(Env_config_core.raw_value_opt Env_config_core.http_port_env_key)
let port = Term.(ret (const (fun requested cli -> match resolve_connection_port requested cli with
  | Ok value -> `Ok (Workspace_connection.to_int value)
  | Error error -> `Error (false, Workspace_connection.error_message error)) $ run_base_path $ port_argument))

let accept_store_quarantine =
  let doc =
    "Let boot move aside every keeper store this build cannot decode and start those keepers with empty stores. Without this flag boot refuses to start while such a store exists and prints each path with its rejection (RFC-0420). The deploy script never passes it: its preflight refuses the same files before the executable starts."
  in
  Arg.(value & flag & info ["accept-store-quarantine"] ~doc)

let record_default_arg =
  let doc =
    "Record this workspace as the default for later commands (in \
     XDG_CONFIG_HOME/masc/default-base-path, else ~/.config). Off by default: \
     a temporary server workspace must not overwrite the machine's default."
  in
  Arg.(value & flag & info [ "record-default" ] ~doc)

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

type shutdown_signal =
  | Sigterm
  | Sigint

let shutdown_signal_name = function
  | Sigterm -> "SIGTERM"
  | Sigint -> "SIGINT"

let acquire_pid_lock port =
  match Server_startup_takeover.acquire_pid_lock port with
  | Server_startup_takeover.Acquired -> ()
  | Server_startup_takeover.Already_running { pid } ->
      Log.legacy_stderr ~level:Log.Error ~module_name:"Server"
        (Printf.sprintf
           "[FATAL] Another MASC server (PID %d) is already running on port %d. Kill it first: kill %d"
           pid port pid);
      exit 1

let acquire_base_path_lock ~run_dir base_path =
  match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
  | Server_startup_takeover.Base_path_acquired lease -> lease
  | Server_startup_takeover.Base_path_already_owned { pid } ->
      let owner = Option.fold ~none:"unknown" ~some:string_of_int pid in
      Log.legacy_stderr ~level:Log.Error ~module_name:"Server"
        (Printf.sprintf
           "[FATAL] Another MASC runtime (PID %s) already owns base path %s"
           owner base_path);
      exit 1
  | Server_startup_takeover.Base_path_rejected rejection ->
      Log.legacy_stderr ~level:Log.Error ~module_name:"Server"
        (Printf.sprintf
           "[FATAL] BasePath ownership boundary rejected %s: %s"
           base_path
           (Server_startup_takeover.base_path_lock_rejection_to_string rejection));
      exit 1

let run_cmd ?(record_default = false) host port cli_base_path accept_store_quarantine =
  Printexc.record_backtrace true;
  let resolved_base_path =
    Server_base_path_guard.resolve_startup_base_path ~cli_base_path
      ~default_base_path ()
  in
  Server_base_path_guard.exit_on_violation
    (Server_base_path_guard.enforce resolved_base_path);
  let raw_base_path = resolved_base_path.raw_base_path in
  let normalized_base_path = resolved_base_path.normalized_base_path in
  let resolution_source =
    Server_base_path_guard.resolution_source_label
      resolved_base_path.resolution_source
  in
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
  Server_base_path_guard.exit_on_violation
    (Server_base_path_guard.enforce
       { resolved_base_path with normalized_base_path = canonical_base_path });
  let on_ready () =
    if record_default then
    (match resolved_base_path.resolution_source with
     | Server_base_path_guard.Explicit_cli | Server_base_path_guard.Explicit_env ->
       (match Env_config.record_default_base_path canonical_base_path with
        | Env_config.Recorded _ -> ()
        | Env_config.No_record_location ->
          Log.Server.warn
            "default workspace not recorded: neither XDG_CONFIG_HOME nor HOME is set; pass --base-path to later commands"
        | Env_config.Refused_under_test ->
          Log.Server.warn
            "default workspace not recorded: a test executable does not write the operator's default"
        | Env_config.Record_failed { record; reason } ->
          Log.Server.warn
            "default workspace not recorded: could not write %s (%s); pass --base-path to later commands"
            record reason)
     | Server_base_path_guard.Persisted_default | Server_base_path_guard.Implicit_default -> ())
  in
  let masc_dir = Filename.concat canonical_base_path Common.masc_dirname in
  let lease_dir = (Host_config.host ()).base_path_lease_dir in
  let _base_path_lease =
    acquire_base_path_lock ~run_dir:lease_dir canonical_base_path
  in
  acquire_pid_lock port;
  Log.init_from_env ();
  (* Report a fresh takeover breadcrumb at boot: after a SIGKILL escalation
     the victim could not log, so this is the only place the kill becomes
     visible. Skip the breadcrumb this process wrote itself while reclaiming
     the lock (the killer already logged its own WARN). *)
  (match
     Server_startup_takeover.read_takeover_breadcrumb
       ~lock_path:(Server_startup_takeover.pid_lock_path port)
       ()
   with
   | Server_startup_takeover.Breadcrumb_found { killer_pid = Some killer; _ }
     when killer = Unix.getpid () -> ()
   | Server_startup_takeover.Breadcrumb_found { breadcrumb_path; age_sec; payload; _ }
     ->
     Log.Server.warn
       "[Startup] takeover breadcrumb found (%.0fs old, %s) — previous instance was killed by a takeover: %s"
       age_sec breadcrumb_path payload
   | Server_startup_takeover.Breadcrumb_stale _ | Server_startup_takeover.Breadcrumb_absent
     -> ()
   | Server_startup_takeover.Breadcrumb_unreadable { breadcrumb_path; reason } ->
     Log.Server.warn "[Startup] takeover breadcrumb unreadable at %s: %s"
       breadcrumb_path reason);
  let shutdown_cfg =
    match Masc.Shutdown.config_from_env_result () with
    | Ok config -> config
    | Error error ->
        Log.Server.error "[FATAL] Invalid shutdown configuration: %s"
          (Masc.Shutdown.config_error_to_string error);
        exit 1
  in
  (* Decouple console mirror writes from the Eio domain before any keeper
     boots: with fd 2 on a pty, a full pty buffer (scrollback/copy-mode)
     blocks write(2) outside the scheduler and halts the whole fleet
     (#20684, 2026-06-10 live stall). *)
  Console_sink.start ();
  if stripped_base_path <> ""
     && String.equal (Filename.basename stripped_base_path) Common.masc_dirname
  then
    Log.Server.warn
      "Normalizing --base-path from %s to %s because runtime base paths must point at the workspace root, not the .masc directory."
      raw_base_path canonical_base_path;
  Unix.putenv "MASC_BASE_PATH_INPUT" raw_base_path;
  Unix.putenv "MASC_BASE_PATH" canonical_base_path;
  Workspace_utils_backend_setup.cache_resolved_base_path canonical_base_path;
  Unix.putenv "MASC_BASE_PATH_RESOLUTION_SOURCE" resolution_source;
  (* Persist logs inside .masc/logs/ — colocated with state, not a sibling.
     Previous code wrote to base_path/logs/ which diverged from .masc/ when
     base_path differed from the repo checkout directory. *)
  let log_dir = Filename.concat masc_dir "logs" in
  Fs_compat.mkdir_p log_dir;
  Log.Ring.init_file_sink log_dir;
  Log.Ring.cleanup_old_files log_dir;
  (* Only the server samples. Sampling starts before [Eio_main.run] so the
     executor pool, which the main domain spawns while sampling, shares the
     profile and the boot-time loads are in the tables. The rate is a tenth
     of the one the OCaml manual reports as having no visible effect.
     GET /api/v1/diagnostics/memprof reads the tables. *)
  Alloc_profile.start ~sampling_rate:Alloc_profile.default_sampling_rate;
  Eio_main.run @@ fun env ->
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

  (* Signal handlers do the minimum async-signal-safe work: mark the sticky
     global flag so any fiber that observes [Eio.Cancel.Cancelled] before the
     watcher fiber wakes up can still classify itself as a graceful drop
     ([Keeper_registry_types_failure.fiber_drop_cause]: [Graceful_shutdown]),
     then enqueue the signal name for the Eio watcher fiber to consume.
     [Atomic.set]/[Atomic.get] are lock-free and signal-safe. *)
  let pending_shutdown_signal = Atomic.make None in
  let shutdown_watchdog : Masc.Shutdown.watchdog option Atomic.t = Atomic.make None in
  let request_shutdown signal =
    Masc.Shutdown.mark_shutting_down ();
    Runtime_host_lifecycle.mark_shutting_down ();
    if Option.is_none (Atomic.get pending_shutdown_signal) then
      Atomic.set pending_shutdown_signal (Some signal)
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> request_shutdown Sigterm));
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> request_shutdown Sigint));

  let max_bind_retries = 5 in
  let rec try_start attempt =
    (try
      Eio.Switch.run @@ fun sw ->
      let clock = Eio.Stdenv.clock env in
      let rec await_shutdown_signal () =
        match Atomic.exchange pending_shutdown_signal None with
        | None ->
            Eio.Time.sleep clock 0.05;
            await_shutdown_signal ()
        | Some signal ->
            let force_timeout = shutdown_cfg.force_timeout_s in
            let t_shutdown_start = Unix.gettimeofday () in
            let signal_name = shutdown_signal_name signal in
            let watchdog =
              Masc.Shutdown.start_process_deadline_watchdog_or_exit
                ~timeout_s:force_timeout
            in
            Atomic.set shutdown_watchdog (Some watchdog);
            Log.Server.info
              "[MASC] Received %s, shutting down gracefully (timeout=%.0fs, hard_exit=%d)..."
              signal_name force_timeout Masc.Shutdown.process_deadline_exit_code;
            (* Signal-sender attribution for the restart-cycle investigation:
               a takeover killer writes a breadcrumb next to the pid lock
               right before signalling; its absence means the sender is
               external (user, pkill, system). *)
            (match
               Server_startup_takeover.read_takeover_breadcrumb
                 ~lock_path:(Server_startup_takeover.pid_lock_path port)
                 ()
             with
             | Server_startup_takeover.Breadcrumb_found { age_sec; payload; _ } ->
               Log.Server.info
                 "[Shutdown] signal attribution: takeover breadcrumb (%.1fs old): %s"
                 age_sec payload
             | Server_startup_takeover.Breadcrumb_stale { age_sec; _ } ->
               Log.Server.info
                 "[Shutdown] signal attribution: no fresh takeover breadcrumb (stale one is %.0fs old) — sender is external (user/pkill/system)"
                 age_sec
             | Server_startup_takeover.Breadcrumb_absent ->
               Log.Server.info
                 "[Shutdown] signal attribution: no takeover breadcrumb — sender is external (user/pkill/system)"
             | Server_startup_takeover.Breadcrumb_unreadable { breadcrumb_path; reason }
               ->
               Log.Server.warn
                 "[Shutdown] signal attribution: breadcrumb unreadable at %s: %s"
                 breadcrumb_path reason);
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
            (* Phase 2: Run shutdown hooks with cleanup timeout *)
            let t_phase = Unix.gettimeofday () in
            Log.Server.info "[Shutdown] Phase 2/4 HOOKS: starting (timeout=%.1fs)"
              shutdown_cfg.cleanup_timeout_s;
            (try
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
                ~env
                ~host
                ~port
                ~base_path:canonical_base_path
                ~input_base_path:raw_base_path
                ~on_ready
                ~accept_store_quarantine)
            await_shutdown_signal;
            (* Server stopped; close SSE connections after server is down. *)
            (try close_all_sse_connections ()
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
    | Unix.Unix_error (Unix.EADDRINUSE, _, _) when attempt < max_bind_retries ->
        let delay = Float.min 30.0 (2.0 ** Float.of_int attempt) in
        Log.Server.warn "Port %d in use, retrying in %.0fs (attempt %d/%d)"
          port delay (attempt + 1) max_bind_retries;
        Time_compat.sleep delay;
        try_start (attempt + 1)
    | Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
        Log.Server.error "[FATAL] Port %d is still in use after %d retries. Try: lsof -i :%d | grep LISTEN"
          port max_bind_retries port;
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
  try_start 0;
  (match Atomic.get shutdown_watchdog with
   | None -> ()
   | Some watchdog ->
       (match Masc.Shutdown.disarm_deadline_watchdog watchdog with
        | Masc.Shutdown.Disarmed | Masc.Shutdown.Already_disarmed -> ()
        | Masc.Shutdown.Already_fired ->
            Masc.Shutdown.await_deadline_watchdog watchdog));
  Log.Server.info "MASC MCP: Shutdown complete."

let run_cmd_exit host port base_path accept_store_quarantine provenance_path provenance_sha256 provenance_device provenance_inode record_default =
  let identity = Build_identity.current () in
  Installed_dashboard.initialize ~executable_path:identity.executable_path
    ~binary_commit:identity.binary_commit;
  match provenance_path, provenance_sha256, provenance_device, provenance_inode with
  | None, None, None, None ->
    run_cmd ~record_default host port base_path accept_store_quarantine;
    Cmd.Exit.ok
  | Some path, Some sha256, Some device, Some inode ->
    (match Build_identity.bind_executable_provenance ~path ~sha256 ~device ~inode with
     | Ok () ->
       run_cmd ~record_default host port base_path accept_store_quarantine;
       Cmd.Exit.ok
     | Error message ->
       Printf.eprintf "invalid build provenance: %s\n" message;
       Cmd.Exit.some_error)
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

let token_credentials base_path =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  (base_path, Auth.list_credentials base_path)

let token_list_cmd_exit base_path =
  let base_path, creds = token_credentials base_path in
  let now = Unix.gettimeofday () in
  if creds = []
  then print_endline "no credentials in this workspace"
  else begin
    List.iter
      (fun (c : Types_auth.agent_credential) ->
         let raw_present =
           Sys.file_exists (Auth.raw_token_file base_path c.agent_name)
         in
         print_endline (Auth_token_inventory.row ~now ~raw_present c))
      (Auth_token_inventory.ordered ~now creds);
    let expired = List.length (Auth_token_inventory.expired ~now creds) in
    Printf.printf
      "\n%d credential(s), %d expired.%s\n"
      (List.length creds)
      expired
      (if expired > 0 then " `masc token prune` removes the expired ones." else "")
  end;
  Cmd.Exit.ok

let token_revoke_cmd_exit base_path agent =
  let base_path, creds = token_credentials base_path in
  let known =
    List.exists (fun (c : Types_auth.agent_credential) -> c.agent_name = agent) creds
  in
  if not known
  then (
    Printf.eprintf
      "no credential named %S; `masc token list` shows what this workspace holds\n"
      agent;
    Cmd.Exit.some_error)
  else (
    Auth.delete_credential base_path agent;
    Printf.printf
      "retired %s. Its bearer stops validating from the next request; anything \
       still exporting it needs a new one from `masc login --agent %s`.\n"
      agent
      agent;
    Cmd.Exit.ok)

(* Only expired credentials. Removing one that already authenticates nothing is
   garbage collection rather than a security decision, which is why this needs
   no confirmation while [revoke] names its target. *)
let token_prune_cmd_exit base_path dry_run =
  let base_path, creds = token_credentials base_path in
  let now = Unix.gettimeofday () in
  let expired =
    Auth_token_inventory.expired ~now creds
    |> List.map (fun (c : Types_auth.agent_credential) -> (c.agent_name, "expired"))
  in
  (* A stub whose target is gone is invisible to a listing and authenticates
     nothing, so it belongs in the same sweep rather than living forever. *)
  let orphaned =
    Auth.orphaned_credential_stubs base_path
    |> List.map (fun name -> (name, "orphaned redirect"))
  in
  match expired @ orphaned with
  | [] ->
    print_endline "nothing to prune: no expired credentials, no orphaned stubs";
    Cmd.Exit.ok
  | doomed ->
    List.iter
      (fun (name, why) ->
         if dry_run
         then Printf.printf "would retire %s (%s)\n" name why
         else (
           Auth.delete_credential base_path name;
           Printf.printf "retired %s (%s)\n" name why))
      doomed;
    Printf.printf
      "%d credential(s)%s\n"
      (List.length doomed)
      (if dry_run then " would be retired (--dry-run)" else " retired");
    Cmd.Exit.ok

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
    Term.(const run_cmd_exit $ host $ port $ run_base_path $ accept_store_quarantine $ build_provenance_path $ build_provenance_sha256 $ build_provenance_device $ build_provenance_inode $ record_default_arg)

let init_force =
  let doc = "Overwrite existing config files instead of skipping them" in
  Arg.(value & flag & info ["force"] ~doc)

let init_record_default =
  let doc =
    "Record this workspace as the default for later commands (in \
     XDG_CONFIG_HOME/masc/default-base-path, else ~/.config). Off by default: \
     a throwaway workspace must not become the machine's default. `masc setup` \
     and the installer pass it."
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

(* [rel] keys the embedded tree and [dest_rel] names where it lands. They are
   the same string for every asset but the fresh-install roster, which is
   authored under [keepers-default/] and seeds as [keepers/]. *)
let seed_one ~target_root ~force tally (rel, dest_rel) =
  match Embedded_config.read rel with
  | None ->
    Printf.eprintf "init: missing embedded asset: %s\n" rel;
    { tally with failed = tally.failed + 1 }
  | Some content ->
    let dest = Filename.concat target_root dest_rel in
    Fs_compat.mkdir_p (Filename.dirname dest);
    if Fs_compat.file_exists dest && not force then begin
      Printf.printf "skip   %s (exists, --force to overwrite)\n" dest;
      { tally with skipped = tally.skipped + 1 }
    end else
      try
        Fs_compat.save_file dest content;
        Printf.printf "wrote  %s (%d bytes)\n" dest (String.length content);
        { tally with written = tally.written + 1 }
      with Sys_error msg ->
        Printf.eprintf "init: %s: %s\n" dest msg;
        { tally with failed = tally.failed + 1 }

let init_cmd_exit base_path force scope record_default =
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
        (seed_one ~target_root ~force)
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
    | Config_only -> 0
    | All | Skills_only -> Server_runtime_config_root_bootstrap.refresh_builtin_skills ~base_path in
  Printf.printf "init: %d written, %d skipped, %d failed, %d builtin Skill package(s) installed or updated (root=%s)\n"
    result.written result.skipped result.failed skills target_root;
  (* A seeded workspace is the one thing a later bare `masc` needs to know
     about, and until now nothing wrote it down: the operator had to re-supply
     --base-path or MASC_BASE_PATH on every command. Recorded on success only,
     and never fatal -- a workspace that seeded is worth more than a record of
     it.

     Off unless asked. `init` is what suites and scripts call to make a
     throwaway workspace, and a default recorded from one of those points the
     next process at a directory that is about to vanish. Only the operator
     paths ask: `masc setup`, and the installer's own seed. *)
  if record_default && result.failed = 0 then (
    match Env_config.record_default_base_path base_path with
    | Env_config.Recorded path ->
      Printf.printf "default workspace recorded: %s\n" path
    | Env_config.No_record_location ->
      Printf.printf
        "default workspace not recorded: neither XDG_CONFIG_HOME nor HOME is set; \
         pass --base-path to later commands\n"
    | Env_config.Record_failed { record; reason } ->
      Printf.printf
        "default workspace not recorded: could not write %s (%s); pass --base-path \
         to later commands\n"
        record reason
    | Env_config.Refused_under_test ->
      (* Says so rather than staying silent: a suite that expected a default
         to exist should fail on the missing default, not on its absence
         being invisible. *)
      Printf.printf
        "default workspace not recorded: a test executable does not write the \
         operator's default\n");
  if result.failed > 0 then 1 else 0

let init_cmd =
  let doc =
    "Seed default .masc/config/ from binary-embedded assets. Writes runtime \
     settings, prompts, tool definitions, connector declarations and first-party \
     Skills in .masc/skills/, and puts one Keeper in keepers/ for you to edit \
     -- it does not autoboot, so it waits until a model and a sandbox exist. \
     The same split the server makes when it creates a config root itself. \
     Existing config files are kept unless --force; recorded, unmodified Skill packages are updated. Operator edits and \
     packages without installation receipts are preserved."
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
        (match Builtin_skill_package.install ~base_path
                 ~request:(Builtin_skill_package.Replace_if_revisions { installed_revision; bundled_revision }) package with
         | Ok (Builtin_skill_package.Updated { backup }) ->
           Printf.printf "Updated %s; previous package: %s\nRefresh the running Skill catalog before a new instruction invocation.\n" name backup; 0
         | Ok Builtin_skill_package.Current -> print_endline "Package is current"; 0
         | Ok (Builtin_skill_package.Installed | Builtin_skill_package.Already_present
               | Builtin_skill_package.Preserved _ | Builtin_skill_package.Preserved_uninspectable _) ->
           prerr_endline "Package was not replaced"; 1
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

let runtime_default_set_cmd_exit base_path runtime_id setup_lanes fallback_runtime_ids bind_imp =
  let runtime_config_path = runtime_config_path_for_base_path base_path in
  let result =
    try
      (* Validate against the same catalog sources as server startup, before
         the config writer checks deployment-local provider/model bindings.
         This command edits the resolved runtime file, so its sibling overlay
         must come from that same config root. No server services are started. *)
      let (_ : string option) =
        Server_runtime_bootstrap.configure_agent_core_model_catalog_env ()
      in
      let (_ : string option) =
        Server_runtime_bootstrap.configure_agent_core_model_catalog_overlay
          ~config_root:(Filename.dirname runtime_config_path) ()
      in
      if setup_lanes then
        Runtime.set_first_run_runtime ~runtime_config_path ~fallback_runtime_ids ~bind_imp ~runtime_id ()
      else if bind_imp then Error "--setup-imp requires --setup-lanes"
      else if fallback_runtime_ids <> [] then
        Error "--fallback-runtime requires --setup-lanes"
      else Runtime.set_runtime_default ~runtime_config_path ~runtime_id ()
    with Env_config_core.Config_error message -> Error message
  in
  match result with
  | Ok _receipt ->
      Printf.printf "set [runtime].default = \"%s\" in %s\n" runtime_id
        runtime_config_path;
      0
  | Error msg ->
      Printf.eprintf "runtime-default-set failed: %s\n" msg;
      1

let runtime_default_set_cmd =
  let doc =
    "Validate and update [runtime].default in runtime.toml using the runtime \
     config writer."
  in
  let info = Cmd.info "runtime-default-set" ~doc in
  let setup_lanes = Arg.(value & flag & info ["setup-lanes"]
    ~doc:"Use this primary runtime for the default and internal model lanes; persist selected fallbacks in its declared lane.") in
  let fallback_runtime_ids = Arg.(value & opt_all string [] & info ["fallback-runtime"]
    ~docv:"RUNTIME_ID" ~doc:"Append an enabled runtime to the primary lane in option order. Requires --setup-lanes; internal exact-output lanes stay primary-only.") in
  let bind_imp = Arg.(value & flag & info ["setup-imp"]
    ~doc:"Explicitly select this primary lane for imp, preserving other Keeper assignments. Requires --setup-lanes.") in
  Cmd.v info Term.(const runtime_default_set_cmd_exit $ base_path $ runtime_default_id $ setup_lanes $ fallback_runtime_ids $ bind_imp)

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
   the runtime id is not configured (4). *)
let runtime_probe_subscription_timeout_s = 20.0

let runtime_verification_timeout_s = 120.0

let verify_runtime_execution runtime timeout_s =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let private_path = Filename.concat (Filename.get_temp_dir_name ())
      ("masc-runtime-verify-" ^ Random_id.hex ~bytes:16) in
    Unix.mkdir private_path 0o700;
    Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree private_path);
    Eio_context.set_env env;
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Runtime_verification.verify ~sw ~net:(Eio.Stdenv.net env)
      ~mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env)
      ~cwd:Eio.Path.(Eio.Stdenv.fs env / private_path) ~cwd_path:private_path ~timeout_s runtime))

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
      let (_ : string option) = Server_runtime_bootstrap.configure_agent_core_model_catalog_overlay
        ~config_root:(Filename.dirname config_path) () in
      Runtime.load_list ~config_path
      |> Result.map_error (Runtime.to_diagnostic_text ~config_path)
      with Env_config_core.Config_error message -> Error message in
    match loaded with
    | Error message ->
      unavailable
        ~detail:message
        "invalid_configuration"
        "The workspace runtime configuration could not be loaded."
    | Ok (runtimes, _, _, _, _) ->
      match List.find_opt (fun (runtime : Runtime.t) -> runtime.id = runtime_id) runtimes with
      | None -> unavailable "runtime_not_configured" "The requested runtime is not an enabled configured binding."
      | Some runtime ->
        (try
          let result = verify_runtime_execution runtime timeout_s in
          print_endline (Yojson.Safe.to_string (Runtime_verification.to_json result));
          Runtime_verification.exit_code result
         with Eio.Io _ | Unix.Unix_error _ | Sys_error _ ->
           unavailable "verification_session_failed" "The isolated verification session could not start or finish.")

let runtime_verify_cmd =
  let runtime_id = Arg.(required & pos 0 (some string) None & info [] ~docv:"RUNTIME_ID") in
  let timeout = Arg.(value & opt float runtime_verification_timeout_s & info ["timeout"] ~docv:"SECONDS"
    ~doc:"Deadline for this explicit readiness measurement, including client admission and model/tool roundtrip.") in
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

let voice_verify_cmd_exit message audio as_json =
  let tts = Masc.Voice_bridge.probe_tts ~message () in
  let stt =
    Option.map (fun audio_file -> audio_file, Masc.Voice_bridge.probe_stt ~audio_file ()) audio
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
    Term.(const voice_verify_cmd_exit $ message $ audio $ as_json)
let runtime_probe_cmd_exit base_path runtime_id =
  let runtime_config_path = runtime_config_path_for_base_path base_path in
  match Runtime.load_list ~config_path:runtime_config_path with
  | Error failure ->
      Printf.eprintf "runtime-probe failed: %s\n"
        (Runtime.to_diagnostic_text ~config_path:runtime_config_path failure);
      1
  | Ok (runtimes, _default, _, _, _) -> (
      match
        List.find_opt
          (fun (rt : Runtime.t) -> String.equal rt.id runtime_id)
          runtimes
      with
      | None ->
          Printf.eprintf "runtime-probe: runtime %S is not configured\n" runtime_id;
          4
      | Some (runtime : Runtime.t) -> (
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
          | Runtime_execution.Claude_code exec ->
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
                   ~mgr:(Eio.Stdenv.process_mgr env)
                   ~clock:(Eio.Stdenv.clock env)
                   ~cwd:Eio.Path.(Eio.Stdenv.fs env / base_path)
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
                   1)
          | Runtime_execution.Codex_app_server exec ->
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
                   ~mgr:(Eio.Stdenv.process_mgr env)
                   ~clock:(Eio.Stdenv.clock env)
                   ~cwd:Eio.Path.(Eio.Stdenv.fs env / base_path)
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
                   1)))

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
  let run base_path scenario_path runtime_ids =
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
        network_mode
        microvm_backend
        remote_endpoint
        mention_targets
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
        ; network_mode
        ; microvm_backend
        ; remote_endpoint
        ; mention_targets
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
    $ keeper_create_network_mode
    $ keeper_create_microvm_backend
    $ keeper_create_remote_endpoint
    $ keeper_create_mention_target
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
  && Option.is_none flags.network_mode
  && Option.is_none flags.microvm_backend
  && Option.is_none flags.remote_endpoint
  && List.is_empty flags.mention_targets
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
    | None -> Auth_login.read_persisted_token ~base_path ~agent_name:agent
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
    | _ -> Masc_cli_keeper_create.render outcome
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
      ; "                     --network-mode inherit"
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
  Arg.(value & opt string "github.com" & info [ "hostname" ] ~docv:"HOST" ~doc)

let keeper_github_action_cmd name doc run =
  let invoke base_path keeper_name hostname =
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
      | Ok (Some meta) -> run ~config ~meta ~hostname
  in
  Cmd.v
    (Cmd.info name ~doc)
    Term.(
      const invoke
      $ base_path
      $ keeper_github_keeper_arg
      $ keeper_github_hostname_arg)

let keeper_github_cmd =
  let login =
    keeper_github_action_cmd
      "login"
      "Log a Keeper into GitHub CLI."
      (fun ~config ~(meta : Keeper_meta_contract.keeper_meta) ~hostname ->
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
        | Ok lane -> Keeper_github_identity.run_cli_login ~lane)
  in
  (* Status and logout still read and write this host's directory. For a
     Remote_ssh Keeper they therefore answer about the host, which is what
     they did before this command learned about lanes; closing that is
     RFC-sized work on [observe] and [logout_argv], not a lane switch. *)
  let status =
    keeper_github_action_cmd
      "status"
      "Observe stored and effective Keeper GitHub identities."
      (fun ~config ~(meta : Keeper_meta_contract.keeper_meta) ~hostname ->
        Keeper_github_identity.run_cli_status
          ~config
          ~keeper_name:meta.Keeper_meta_contract.name
          ~hostname)
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
    [ login; status; logout ]

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

(* Build the general sandbox image from the recipe this binary carries. The
   Dockerfile goes to docker on stdin against a [-] context, so this works the
   same on a host that has no checkout -- which is the whole point, since the
   only image MASC described before was one you could build from the repository
   and nowhere else. *)
(* Build the recipe into the store of a runtime that takes a directory, not
   stdin. Apple's [container build] is the one: its usage line takes a
   context directory and it has no [-], so the recipe is written to a
   directory of its own and named with [-f]. Nothing else goes in that
   directory, so the context stays what the stdin form's [-] gave docker:
   the recipe and nothing else. *)
let sandbox_image_build_in_a_directory_exit ~cli ~tag =
  let context = Filename.temp_file "masc-sandbox-image-" ".d" in
  Sys.remove context;
  Unix.mkdir context 0o700;
  let cleanup () =
    (try Sys.remove (Filename.concat context "Dockerfile") with Sys_error _ -> ());
    try Unix.rmdir context with Unix.Unix_error _ -> ()
  in
  Fun.protect ~finally:cleanup (fun () ->
      let dockerfile = Keeper_sandbox_image.write_recipe_into ~dir:context in
      let argv =
        cli
        :: Keeper_sandbox_image.context_directory_build_argv ~tag ~dockerfile
             ~context
      in
      let pid =
        Unix.create_process cli (Array.of_list argv) Unix.stdin Unix.stdout
          Unix.stderr
      in
      let status = Masc_cli_setup.wait_for_child pid in
      match status with
      | Unix.WEXITED 0 ->
        Printf.printf
          "built %s into %s's image store\n\
           Point a Keeper at it with sandbox_image = %S in its TOML.\n"
          tag cli tag;
        Cmd.Exit.ok
      | Unix.WEXITED code ->
        Printf.eprintf "sandbox-image: %s build exited %d\n" cli code;
        Cmd.Exit.some_error
      | Unix.WSIGNALED n | Unix.WSTOPPED n ->
        Printf.eprintf "sandbox-image: %s build stopped by signal %d\n" cli n;
        Cmd.Exit.some_error)

let sandbox_image_build_exit ~command ~tag =
  match command with
  | [] ->
    prerr_endline "sandbox-image: no image build command resolved";
    Cmd.Exit.some_error
  | bin :: _ ->
    let argv = command @ Keeper_sandbox_image.build_argv ~tag in
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
       output_string oc Keeper_sandbox_image.dockerfile;
       close_out oc
     with Sys_error _ -> (try close_out_noerr oc with _ -> ()));  (* @observe-allowed: the write already failed; close_out_noerr is the no-raise form and there is no second failure to report *)
    let status = Masc_cli_setup.wait_for_child pid in
    (match status with
     | Unix.WEXITED 0 ->
       Printf.printf
         "built %s via %s\n\
          Point a Keeper at it with sandbox_image = %S in its TOML, or set \
          MASC_KEEPER_SANDBOX_DOCKER_IMAGE to make it that Keeper's default.\n"
         tag
         (String.concat " " command)
         tag;
       Cmd.Exit.ok
     | Unix.WEXITED code ->
       Printf.eprintf "sandbox-image: %s build exited %d\n" bin code;
       Cmd.Exit.some_error
     | Unix.WSIGNALED n | Unix.WSTOPPED n ->
       Printf.eprintf "sandbox-image: %s build stopped by signal %d\n" bin n;
       Cmd.Exit.some_error))

(* Which store to build into. Docker stays the default because that is where
   [sandbox_profile = "docker"] keepers look and where this command has always
   put it. A microVM keeper looks somewhere else entirely -- each runtime
   keeps its images apart from Docker's -- so the image its gate wants can
   only be made by naming that runtime here. *)
let sandbox_image_build_for_runtime ~runtime ~tag =
  match runtime with
  | None ->
    sandbox_image_build_exit
      ~command:(Keeper_sandbox_runtime.docker_command_argv ()) ~tag
  | Some backend ->
    (match Keeper_microvm_backend.recipe_delivery backend with
     | Keeper_microvm_backend.On_stdin ->
       sandbox_image_build_exit
         ~command:[ Keeper_microvm_backend.cli_name backend ] ~tag
     | Keeper_microvm_backend.In_a_context_directory ->
       sandbox_image_build_in_a_directory_exit
         ~cli:(Keeper_microvm_backend.cli_name backend)
         ~tag
     | Keeper_microvm_backend.Builds_no_images ->
       Printf.eprintf
         "sandbox-image: %s builds no images -- it has pull, load and save \
          and no build. Next: build %s elsewhere, save it as an OCI archive, \
          and `%s load` it.\n"
         (Keeper_microvm_backend.cli_name backend)
         tag
         (Keeper_microvm_backend.cli_name backend);
       Cmd.Exit.some_error)

let sandbox_image_cmd_exit print_only tag runtime =
  let tag = match tag with Some t -> t | None -> Keeper_sandbox_image.default_tag in
  if print_only
  then (
    print_string Keeper_sandbox_image.dockerfile;
    Cmd.Exit.ok)
  else
    match runtime with
    | Error message ->
      prerr_endline message;
      Cmd.Exit.some_error
    | Ok runtime -> sandbox_image_build_for_runtime ~runtime ~tag

let sandbox_image_cmd =
  let doc = "Build the general Keeper sandbox image from the recipe in this binary." in
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
    ]
  in
  let print_only =
    let doc = "Write the Dockerfile to stdout instead of building it." in
    Arg.(value & flag & info [ "print" ] ~doc)
  in
  let tag =
    let doc = "Image tag to build (default: " ^ Keeper_sandbox_image.default_tag ^ ")." in
    Arg.(value & opt (some string) None & info [ "tag" ] ~docv:"TAG" ~doc)
  in
  let runtime =
    let doc =
      "microVM runtime whose image store to build into (one of "
      ^ String.concat ", " Keeper_microvm_backend.valid_strings
      ^ "). Omit for Docker's store, which is where sandbox_profile = \"docker\" \
         keepers look. Each runtime keeps its images apart from Docker's, so a \
         microvm keeper cannot see one built without this."
    in
    Arg.(value & opt (some string) None & info [ "runtime" ] ~docv:"RUNTIME" ~doc)
  in
  let resolved_runtime =
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
  in
  Cmd.v
    (Cmd.info "sandbox-image" ~doc ~man)
    Term.(const sandbox_image_cmd_exit $ print_only $ tag $ resolved_runtime)

(* Catalog model families are selectable suggestions, not account entitlement.
   Do not expose broad fallback rows such as [gpt], [cc:] or [claude_code]
   as if they were concrete CLI model IDs. *)
type wizard_model_client = Wizard_claude_code | Wizard_codex

let wizard_model_client_arg =
  Arg.enum [ "claude-code", Wizard_claude_code; "codex", Wizard_codex ]

let wizard_model_entries client catalog =
  Llm_provider.Model_catalog.model_entries catalog
  |> List.filter (fun (entry : Llm_provider.Model_catalog.model_entry) ->
    match client, entry.provider_name with
    | Wizard_claude_code, (None | Some "anthropic") ->
      String.starts_with ~prefix:"claude-" entry.id_prefix
    | Wizard_codex, (None | Some "openai-responses") ->
      String.starts_with ~prefix:"gpt-" entry.id_prefix
    | _ -> false)

let wizard_model_context model entries =
  let contexts = entries
    |> List.filter_map (fun (entry : Llm_provider.Model_catalog.model_entry) ->
      let exact = String.equal entry.id_prefix model
        || Option.fold ~none:false ~some:(List.mem model) entry.supported_models in
      match entry.max_context_tokens with
      | Some context when exact && context > 0 -> Some context
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
           Ok
             (`List
               (entries
                |> List.map (fun (entry : Llm_provider.Model_catalog.model_entry) -> entry.id_prefix)
                |> List.sort_uniq String.compare
                |> List.filter_map (fun model ->
                     Option.map (fun context -> `Assoc [ "id", `String model
                                                       ; "label", `String model
                                                       ; "max_context", `Int context
                                                       ; "release", Model_release_evidence.default_model_json
                                                           ~publisher:(match client with Wizard_claude_code -> "anthropic" | Wizard_codex -> "openai")
                                                           ~model_id:model ])
                       (wizard_model_context model entries)))))
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
  let run cli_path = Masc_cli_codex_models.run ~cli_path ~timeout_s:runtime_probe_subscription_timeout_s in
  Cmd.v (Cmd.info "runtime-codex-models" ~doc:"Refresh selected Codex model metadata in an isolated connection home without a model turn.")
    Term.(const run $ cli)

let runtime_setup_render_cmd =
  let spec = Arg.(required & opt (some string) None & info ["spec"] ~doc:"Private setup JSON file.") in
  Cmd.v (Cmd.info "runtime-setup-render" ~doc:"Render a native runtime specification for local setup.")
    Term.(const (fun spec_path -> Masc_cli_runtime_setup.render ~spec_path) $ spec)

let runtime_setup_inventory_cmd =
  Cmd.v (Cmd.info "runtime-setup-inventory" ~doc:"Read local setup choices and their configuration revision together.")
    Term.(const (fun base_path -> Masc_cli_runtime_setup.inventory ~base_path) $ base_path)

let runtime_setup_batch_cmd =
  let request = Arg.(required & opt (some string) None & info ["request"] ~doc:"Private setup selection JSON file.") in
  Cmd.v (Cmd.info "runtime-setup-batch" ~doc:"Validate and save the selected runtimes against their original revision.")
    Term.(const (fun base_path request_path -> Masc_cli_runtime_setup.configure ~base_path ~request_path) $ base_path $ request)

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
          | Some binding -> List.filter (fun (entry : Llm_provider.Model_catalog.model_entry) ->
              match entry.provider_name with
              | None -> true
              | Some name -> name = binding.id || List.mem name binding.aliases) entries) in
      (* A generic family prefix is not evidence for the context of a model
         the installer does not know. Include provider-scoped exact rows, and
         reject conflicting declarations rather than pick a convenient one. *)
      match wizard_model_context model entries with
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
      let (_ : string option) = Server_runtime_bootstrap.configure_agent_core_model_catalog_overlay
        ~config_root:(Filename.dirname config_path) () in
      Runtime.load_list ~config_path
      |> Result.map_error (Runtime.to_diagnostic_text ~config_path)
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
        (fun id -> List.find_opt (fun (runtime : Runtime.t) -> String.equal runtime.id id) runtimes) in
    match selected with
    | None -> prerr_endline "imp's assigned runtime is unavailable. Choose a model in the installation wizard."; 1
    | Some runtime ->
      Printf.printf "Model connection: %s / %s\n%!" runtime.provider.display_name runtime.model.api_name;
      if not runtime.model.tools_support then (
        prerr_endline "This model has tool calling disabled. Select a tool-capable model in the installation wizard before starting imp."; 1)
      else
        let result = verify_runtime_execution runtime runtime_verification_timeout_s in
        let code = Runtime_verification.exit_code result in
        if code = 0 then print_endline "Model response and harmless tool roundtrip verified."
        else (
          (match result.failure, runtime.provider.credentials with
           | Some (Runtime_verification.Unavailable Missing_credential), Some (Runtime_schema.Env key) ->
             Printf.eprintf "Missing model credential: %s. Set this variable in the shell that starts MASC.\n" key
           | _ -> ());
          prerr_endline "The selected model did not pass its real response/tool check. Run masc runtime-verify for details or choose another connection in the installer.");
        code

let ensure_local_operator_login ~base_path ~port ~agent =
  match Auth_login.read_persisted_token ~base_path ~agent_name:agent with
  | Some token when (match Auth.verify_token base_path ~agent_name:agent ~token with
      | Ok credential -> credential.role = Masc_domain.Admin
      | Error _ -> false) -> 0
  | Some _ | None ->
    (match Auth_login.mint ~base_path ~host:"127.0.0.1" ~port
        ~agent_name:agent ~role:Masc_domain.Admin
        ~token_env_var:"MASC_TOKEN" ~token_lifetime:Auth_login.With_expiry () with
    | Ok _ -> prerr_endline "Local operator credential ready."; 0
    | Error error -> prerr_endline (Masc_domain.masc_error_to_string error); 1)

let setup_cmd_exit base_path port no_tui sandbox_profile microvm_backend network_mode =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  Masc_cli_setup.run_with_selection ~network_mode ~base_path ~port ~open_tui:(not no_tui)
    ~sandbox_profile ~microvm_backend
    (* setup is an operator command: the workspace it prepares becomes the
       default for later ones. *)
    ~initialize:(fun () -> init_cmd_exit base_path false All true)
    ~validate_runtime:(fun () -> setup_validate_runtime base_path)
    ~prepare_image:(fun ~selection ->
      let runtime = Masc.Sandbox_readiness.microvm_backend selection.Masc.Sandbox_readiness.backend in
      sandbox_image_cmd_exit false None (Ok runtime))
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
  let apply = Arg.(value & opt (some string) None & info ["apply"] ~docv:"KEEPER"
    ~doc:"Back up and upgrade this selected Keeper's known released configuration.") in
  let source_sha256 = Arg.(value & opt (some string) None & info ["source-sha256"] ~docv:"SHA256"
    ~doc:"Require the exact configuration digest displayed during assessment.") in
  let restore = Arg.(value & opt (some string) None & info ["restore"] ~docv:"BACKUP_ID"
    ~doc:"Restore a selected backup only while its upgrade output remains unchanged.") in
  let run base_path apply source_sha256 restore =
    let action = match apply, source_sha256, restore with
      | None, None, None -> Some Masc_cli_workspace_upgrade.Inspect
      | Some keeper_name, Some source_sha256, None -> Some (Apply {keeper_name; source_sha256})
      | None, None, Some backup_id -> Some (Restore {backup_id})
      | _ -> None in
    match action with Some action -> Masc_cli_workspace_upgrade.run ~base_path ~action
    | None -> prerr_endline "Choose inspection, --apply KEEPER with --source-sha256, or --restore BACKUP_ID."; 1 in
  Cmd.v (Cmd.info "workspace-upgrade" ~doc:"Inspect known configuration upgrades and private recovery backups.")
    Term.(const run $ base_path $ apply $ source_sha256 $ restore)

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
    | Some action -> Masc_cli_antigravity.account ~base_path ~cli_path
        ~timeout_s:runtime_probe_subscription_timeout_s ~action in
  Cmd.v (Cmd.info "runtime-antigravity-account" ~doc:"Select an Antigravity account and list its actual models without a model turn.")
    Term.(const run $ base_path $ cli_path $ sign_in $ credential)

let antigravity_models_cmd =
  let cli_path = Arg.(value & opt string "agy" & info ["cli-path"] ~docv:"EXECUTABLE") in
  let credential = Arg.(required & opt (some string) None & info ["credential-file"] ~docv:"PRIVATE_REFERENCE") in
  let run cli_path oauth_source = Masc_cli_antigravity.models ~cli_path ~oauth_source
    ~timeout_s:runtime_probe_subscription_timeout_s in
  Cmd.v (Cmd.info "runtime-antigravity-models" ~doc:"Refresh the selected Antigravity account's models without a model turn.")
    Term.(const run $ cli_path $ credential)

let antigravity_context_cmd =
  let cli_path = Arg.(value & opt string "agy" & info ["cli-path"] ~docv:"EXECUTABLE") in
  let credential = Arg.(required & opt (some string) None & info ["credential-file"] ~docv:"PRIVATE_REFERENCE") in
  let model = Arg.(required & opt (some string) None & info ["model"] ~docv:"MODEL_ID") in
  let run cli_path oauth_source model_id =
    match Masc_cli_onboarding.python (Unix.realpath Sys.executable_name) with
    | None -> prerr_endline "The installed Python helper is missing. Reinstall the complete MASC release."; 1
    | Some python_path -> Masc_cli_antigravity.context ~python_path ~cli_path ~oauth_source ~model_id
        ~timeout_s:runtime_probe_subscription_timeout_s in
  Cmd.v (Cmd.info "runtime-antigravity-context" ~doc:"Read the selected account model's actual CLI context without a model prompt.")
    Term.(const run $ cli_path $ credential $ model)

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

let sandbox_catalog_cmd =
  let inspect requested =
    let base_path = match requested with Some path -> Some path
      | None -> Option.map snd (Env_config_core.base_path_source_opt ()) in
    print_endline (Yojson.Safe.to_string (Masc.Sandbox_readiness.inspect ~base_path));
    0 in
  Cmd.v (Cmd.info "sandbox-catalog" ~doc:"Inspect sandbox choices and host prerequisites without changing settings.")
    Term.(const inspect $ run_base_path)

let doctor_cmd =
  let json = Arg.(value & flag & info ["json"]
    ~doc:"Print the shared read-only onboarding state as JSON.") in
  let inspect requested json =
    let selected = match requested with
      | Some path -> Some path
      | None -> Option.map snd (Env_config_core.base_path_source_opt ()) in
    let state = Onboarding_status.inspect ~base_path:selected in
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
     | Some profile ->
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
        let resolved = match base_path with
          | Some path -> Some path
          | None -> Option.map snd (Env_config_core.base_path_source_opt ()) in
        match resolved with
        | Some path ->
          (match resolve_connection_port (Some path) requested_port with
           | Ok port -> `Ok (setup_cmd_exit path (Workspace_connection.to_int port) no_tui profile backend network_mode)
           | Error error -> `Error (false, Workspace_connection.error_message error))
        | None -> `Error (false, "Choose a workspace with --base-path, or run masc setup in a terminal.")
  in
  Cmd.v
    (Cmd.info "setup"
       ~doc:"Prepare imp's sandbox, start imp, and open its workspace.")
    Term.(ret (const run $ run_base_path $ port_argument $ no_tui $ sandbox_profile $ microvm_backend $ network_mode))

let setup_gc () =
  (* OCaml 5 defaults to a 2 MiB minor heap per active domain.  Sampling
     main_eio.exe showed heavy stop-the-world minor-GC pressure from JSON
     parsing and metric encoding, with many domains parked waiting for STW.
     Bumping the per-domain minor heap reduces the frequency of those
     parallel pauses.  We only override when the operator has not set
     OCAMLRUNPARAM so existing tuning instructions remain authoritative. *)
  match Sys.getenv_opt "OCAMLRUNPARAM" with
  | Some _ -> ()
  | None ->
      let gc = Gc.get () in
      let desired_minor_words = 4 * 1024 * 1024 in
      (* 4M words ~= 32 MiB on 64-bit *)
      if gc.minor_heap_size < desired_minor_words then
        Gc.set { gc with minor_heap_size = desired_minor_words }

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
        (match !status with Some (Unix.WEXITED 0) -> Ok output | _ -> Error ())
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
  Cmd.v (Cmd.info "prerequisite-actions" ~doc:"Show installation actions for a sandbox, official client, pdf-tools, or presentation-tools.")
    Term.(const (fun base_path dependency action -> Masc_cli_prerequisites.run ~base_path ~dependency ~action) $ base_path $ dependency $ action)

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
    ; skills_refresh_cmd
    ; start_cmd
    ; login_cmd
    ; mcp_config_cmd
    ; runtime_default_set_cmd
    ; runtime_wizard_catalog_cmd
    ; runtime_probe_cmd
    ; runtime_token_sample_cmd
    ; runtime_verify_cmd
    ; voice_verify_cmd
    ; runtime_model_list_cmd
    ; runtime_codex_models_cmd
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
    ; doctor_cmd
    ; sandbox_catalog_cmd
    ; token_cmd
    ; build_commit_cmd
    ]

let () =
  setup_gc ();
  exit (Cmd.eval' cmd)
