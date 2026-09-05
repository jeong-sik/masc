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
module Keeper_config = Masc.Keeper_config
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_memory = Masc.Keeper_memory
module Keeper_execution = Masc.Keeper_execution
module Keeper_runtime = Masc.Keeper_runtime
module Keeper_github_identity = Masc.Keeper_github_identity
module Keeper_github_login_lane = Masc.Keeper_github_login_lane
module Tool_operator = Masc.Tool_operator
module Operator_control = Operator_control
module Dashboard_execution = Dashboard_execution
module Dashboard_briefing = Dashboard_briefing
module Dashboard_briefing_sections = Dashboard_briefing_sections
module Build_identity = Masc.Build_identity
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
    2. Per-agent bearer token (via Authorization header) — enforces per-agent
       quotas regardless of source IP, complementing the IP-level check. *)
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
    end else
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
let run_server ~sw ~env ~host ~port ~base_path ~input_base_path ~accept_store_quarantine =
  (* Use the parent switch directly so that ALL fibers spawned by
     Server_runtime_bootstrap (background maintenance, keeper loops,
     dashboard refresh, etc.) are children of this switch.  Graceful
     shutdown explicitly fails this switch after the signal handler
     finishes its phases (see [Graceful_shutdown] below); failing the
     switch propagates cancellation to every child fiber, preventing
     the 10s force-exit timeout. *)
  try
    Server_runtime_bootstrap.run ~sw ~env ~host ~port ~base_path
      ~input_base_path ~accept_store_quarantine ~make_routes
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
let port =
  let doc = "Port to listen on" in
  Arg.(value & opt int (Env_config_core.masc_http_port_int ()) & info ["p"; "port"] ~docv:"PORT" ~doc)

let host =
  let default = Env_config.masc_host () in
  let doc =
    "Host/IP to bind. Defaults to loopback (`127.0.0.1`). Use `0.0.0.0` or `::` only when you also enable workspace auth with `require_token=true`."
  in
  Arg.(value & opt string default & info ["host"] ~docv:"HOST" ~doc)

let base_path =
  let doc =
    "Workspace root for MASC data. Runtime state lives under <base-path>/.masc; do not pass the .masc directory itself."
  in
  (* [Arg.opt] takes a value, not a thunk, so its default is computed while the
     term is built — before Cmdliner has looked at argv. Calling
     [default_base_path ()] there ran the environment-backed resolver on every
     invocation: it logged a base path no command had selected, and it exited 1
     when MASC_BASE_PATH was unset even though --base-path carried one. Parse
     the flag as optional and consult the environment only when it is absent,
     matching [run_base_path]. *)
  let resolve = function Some raw -> raw | None -> default_base_path () in
  Term.(
    const resolve
    $ Arg.(
        value & opt (some string) None & info ["base-path"] ~docv:"PATH" ~doc))

let run_base_path =
  let doc =
    "Workspace root for MASC data. Runtime state lives under <base-path>/.masc; do not pass the .masc directory itself."
  in
  Arg.(value & opt (some string) None & info ["base-path"] ~docv:"PATH" ~doc)

let accept_store_quarantine =
  let doc =
    "Let boot move aside every keeper store this build cannot decode and start those keepers with empty stores. Without this flag boot refuses to start while such a store exists and prints each path with its rejection (RFC-0420). The deploy script never passes it: its preflight refuses the same files before the executable starts."
  in
  Arg.(value & flag & info ["accept-store-quarantine"] ~doc)

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

let run_cmd host port cli_base_path accept_store_quarantine =
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

let run_cmd_exit host port base_path accept_store_quarantine provenance_path provenance_sha256 provenance_device provenance_inode =
  match provenance_path, provenance_sha256, provenance_device, provenance_inode with
  | None, None, None, None ->
    run_cmd host port base_path accept_store_quarantine;
    Cmd.Exit.ok
  | Some path, Some sha256, Some device, Some inode ->
    (match Build_identity.bind_executable_provenance ~path ~sha256 ~device ~inode with
     | Ok () ->
       run_cmd host port base_path accept_store_quarantine;
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
      host port base_path accept_store_quarantine
      provenance_path provenance_sha256 provenance_device provenance_inode =
  let serve () =
    run_cmd_exit host port base_path accept_store_quarantine provenance_path
      provenance_sha256 provenance_device provenance_inode
  in
  let deployment_flags_present =
    accept_store_quarantine
    || Option.is_some provenance_path
    || Option.is_some provenance_sha256
    || Option.is_some provenance_device
    || Option.is_some provenance_inode
  in
  match
    Masc_front_door.decide
      ~interactive:(stdio_is_a_terminal ())
      ~host
      ~default_host:(Env_config.masc_host ())
      ~deployment_flags_present
      ~port
      ~base_path
      ~executable_name:Sys.executable_name
      ~path_env:(Sys.getenv_opt "PATH")
      ~is_executable:path_is_executable
  with
  | Masc_front_door.Serve -> serve ()
  | Masc_front_door.Open_tui { binary; argv } ->
    Printf.printf "masc: opening %s — `masc start` runs the server alone\n%!" binary;
    (try Unix.execv binary (Array.of_list argv) with
     | Unix.Unix_error (err, _, _) ->
       Printf.eprintf "masc: could not run %s (%s); starting the server instead\n%!"
         binary (Unix.error_message err);
       serve ())

let start_cmd =
  let doc =
    "Start the MASC MCP server (HTTP/SSE). What `masc` with no subcommand does \
     everywhere except an interactive terminal, where the bare name opens the \
     fleet TUI instead. Use this name whenever the server is what you want."
  in
  let info = Cmd.info "start" ~doc in
  Cmd.v info
    Term.(const run_cmd_exit $ host $ port $ run_base_path $ accept_store_quarantine $ build_provenance_path $ build_provenance_sha256 $ build_provenance_device $ build_provenance_inode)

let init_force =
  let doc = "Overwrite existing config files instead of skipping them" in
  Arg.(value & flag & info ["force"] ~doc)

type init_tally = { written : int; skipped : int; failed : int }

let seed_one ~target_root ~force tally rel =
  match Embedded_config.read rel with
  | None ->
    Printf.eprintf "init: missing embedded asset: %s\n" rel;
    { tally with failed = tally.failed + 1 }
  | Some content ->
    let dest = Filename.concat target_root rel in
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

let init_cmd_exit base_path force =
  let base_path = Env_config.normalize_masc_base_path_input base_path in
  (* [init] seeds the explicitly requested workspace; runtime resolution may
     honor [MASC_CONFIG_DIR], but bootstrap materialization must not. *)
  let target_root =
    Config_dir_resolver.base_path_config_root
      ~cwd:(Config_dir_resolver.current_working_dir ())
      base_path
  in
  Fs_compat.mkdir_p target_root;
  (* Same distribution/operator split the server's own config-root seed makes
     ([Server_runtime_config_root_bootstrap.copy_missing_config_root_seed]), so
     the two paths hand back the same workspace: keeper manifests are the
     operator's to write, and [init] leaves the directory empty for them. *)
  Fs_compat.mkdir_p (Filename.concat target_root Common.keepers_runtime_dirname);
  let result =
    List.fold_left
      (seed_one ~target_root ~force)
      { written = 0; skipped = 0; failed = 0 }
      (List.filter Common.seeds_into_fresh_config_root Embedded_config.file_list)
  in
  Printf.printf "init: %d written, %d skipped, %d failed (root=%s)\n"
    result.written result.skipped result.failed target_root;
  if result.failed > 0 then 1 else 0

let init_cmd =
  let doc =
    "Seed default .masc/config/ from binary-embedded assets. Writes runtime \
     settings, prompts, tool definitions and connector declarations, and leaves \
     keepers/ empty for you to declare -- the same split the server makes when \
     it creates a config root itself. Existing files are kept unless --force."
  in
  let info = Cmd.info "init" ~doc in
  Cmd.v info Term.(const init_cmd_exit $ base_path $ init_force)

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

let runtime_default_set_cmd_exit base_path runtime_id =
  let runtime_config_path = runtime_config_path_for_base_path base_path in
  match
    Runtime.set_runtime_default ~runtime_config_path ~runtime_id ()
  with
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
  Cmd.v info Term.(const runtime_default_set_cmd_exit $ base_path $ runtime_default_id)

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

let runtime_wizard_binding_for_provider (cfg : Runtime_schema.config)
    (provider : Runtime_schema.provider) =
  let bindings =
    List.filter
      (fun (binding : Runtime_schema.binding) ->
         binding.enabled && String.equal binding.provider_id provider.id)
      cfg.bindings
  in
  match bindings with
  | [] -> Error (Printf.sprintf "provider %s has no concrete runtime binding" provider.id)
  | _ ->
      (match List.filter (fun (binding : Runtime_schema.binding) -> binding.wizard_default) bindings with
       | [ binding ] -> Ok binding
       (* One enabled binding is the default by arithmetic: there is nothing
          else the wizard could install, so requiring the operator to say so
          rejects a config the server boots from (#27991, live glm-coding).
          Two or more without a flag stays an error -- that one is a real
          choice and guessing it would install a model nobody picked. *)
       | [] when List.length bindings = 1 -> Ok (List.hd bindings)
       | [] ->
           (* Prefer the binding the config already runs by default: that is the
              operator's own pick, not a guess, so a live config with several
              bindings and one [runtime].default no longer fails the wizard.
              Only when this provider does not own the default runtime is the
              choice genuinely ambiguous, and then it stays an error the caller
              skips rather than guessing a model nobody picked. *)
           (match
              (match cfg.default_runtime_id with
               | None -> None
               | Some runtime_id ->
                   List.find_opt
                     (fun (binding : Runtime_schema.binding) ->
                        String.equal
                          (Runtime_schema.binding_key binding)
                          runtime_id)
                     bindings)
            with
            | Some binding -> Ok binding
            | None ->
                Error
                  (Printf.sprintf
                     "provider %s has %d enabled bindings and no install wizard default; set wizard-default = true on exactly one [%s.<model>] binding"
                     provider.id (List.length bindings) provider.id))
       | defaults ->
           Error
             (Printf.sprintf
                "provider %s has %d install wizard default bindings; set wizard-default = true on exactly one [%s.<model>] binding"
                provider.id
                (List.length defaults)
                provider.id))

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

let runtime_wizard_catalog_cmd_exit base_path =
  let runtime_config_path = runtime_config_path_for_base_path base_path in
  match Runtime_toml.parse_file runtime_config_path with
  | Error errors ->
      Printf.eprintf "runtime-wizard-catalog failed: %s\n"
        (runtime_wizard_parse_errors errors);
      1
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
  Cmd.v info Term.(const runtime_wizard_catalog_cmd_exit $ base_path)

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

let runtime_probe_cmd_exit base_path runtime_id =
  let runtime_config_path = runtime_config_path_for_base_path base_path in
  match Runtime.load_list ~config_path:runtime_config_path with
  | Error msg ->
      Printf.eprintf "runtime-probe failed: %s\n" msg;
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
                     "authenticated auth_method=%s subscription_type=%s\n"
                     sub.auth_method sub.subscription_type;
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
                   Printf.printf "authenticated subscription_type=%s\n"
                     result.subscription.plan_type;
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

(* Tri-state, not [Arg.flag]. A [bool] cannot say "leave the key out", and the
   key's absence is load-bearing: the config writer persists whatever the meta
   holds, so a two-valued flag would write an autoboot decision the operator
   never made. [vflag] also lets cmdliner refuse both spellings at once. *)
let keeper_create_autoboot =
  Arg.(
    value
    & vflag
        None
        [ ( Some true
          , info [ "autoboot" ] ~doc:"Start this keeper on every server boot." )
        ; ( Some false
          , info
              [ "no-autoboot" ]
              ~doc:
                "Persist this keeper but do not start it on future server \
                 boots. It still starts once now." )
        ])

let keeper_create_proactive =
  Arg.(
    value
    & vflag
        None
        [ ( Some true
          , info
              [ "proactive" ]
              ~doc:"Let scheduled cycles produce proactive responses." )
        ; ( Some false
          , info
              [ "no-proactive" ]
              ~doc:"Answer only when addressed." )
        ])

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
        remote_endpoint
        mention_targets
        skill_names
        no_skills
        max_context_override
        autoboot
        proactive
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
      let booleans : Masc_cli_keeper_create.booleans = { autoboot; proactive } in
      let flags : Masc_cli_keeper_create.flags =
        { name
        ; instructions
        ; sandbox_profile
        ; network_mode
        ; remote_endpoint
        ; mention_targets
        ; skills
        ; max_context_override
        ; booleans
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
    $ keeper_create_remote_endpoint
    $ keeper_create_mention_target
    $ keeper_create_skill
    $ keeper_create_no_skills
    $ keeper_create_max_context_override
    $ keeper_create_autoboot
    $ keeper_create_proactive)

(* [--edit] takes the whole declaration from the editor, so a flag passed
   alongside it would be read by nobody. Naming the conflict costs one
   comparison; dropping the flags silently is the shape this command exists to
   stop. *)
let keeper_create_flags_are_absent (flags : Masc_cli_keeper_create.flags) =
  String.equal (String.trim flags.name) ""
  && String.equal (String.trim flags.instructions) ""
  && String.equal (String.trim flags.sandbox_profile) ""
  && Option.is_none flags.network_mode
  && Option.is_none flags.remote_endpoint
  && List.is_empty flags.mention_targets
  && Option.is_none flags.skills
  && Option.is_none flags.max_context_override
  && Option.is_none flags.booleans.autoboot
  && Option.is_none flags.booleans.proactive

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
let keeper_create_post ~base_path ~host ~port ~agent ~token ~keeper_name
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
      "http://%s:%d/api/v1/keepers/%s/up"
      host
      port
      (Uri.pct_encode keeper_name)
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
          Masc_cli_keeper_create.outcome_of_response ~status ~body:response_body))
  in
  let text, code = Masc_cli_keeper_create.render outcome in
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
      keeper_create_post ~base_path ~host ~port ~agent ~token ~keeper_name
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
  match (Build_identity.current ()).binary_commit with
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
let sandbox_image_build_exit ~tag =
  let argv =
    Keeper_sandbox_runtime.docker_command_argv ()
    @ Keeper_sandbox_image.build_argv ~tag
  in
  match argv with
  | [] ->
    prerr_endline "sandbox-image: no docker command resolved";
    Cmd.Exit.some_error
  | bin :: _ ->
    (* docker exiting first would otherwise kill this process mid-write, and
       the exit status we want to report is docker's own. *)
    let previous_sigpipe = Sys.signal Sys.sigpipe Sys.Signal_ignore in
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
     with Sys_error _ -> (try close_out_noerr oc with _ -> ()));
    let _, status = Unix.waitpid [] pid in
    Sys.set_signal Sys.sigpipe previous_sigpipe;
    (match status with
     | Unix.WEXITED 0 ->
       Printf.printf
         "built %s\n\
          Point a Keeper at it with sandbox_image = %S in its TOML, or set \
          MASC_KEEPER_SANDBOX_DOCKER_IMAGE to make it that Keeper's default.\n"
         tag
         tag;
       Cmd.Exit.ok
     | Unix.WEXITED code ->
       Printf.eprintf "sandbox-image: docker build exited %d\n" code;
       Cmd.Exit.some_error
     | Unix.WSIGNALED n | Unix.WSTOPPED n ->
       Printf.eprintf "sandbox-image: docker build stopped by signal %d\n" n;
       Cmd.Exit.some_error)

let sandbox_image_cmd_exit print_only tag =
  let tag = match tag with Some t -> t | None -> Keeper_sandbox_image.default_tag in
  if print_only
  then (
    print_string Keeper_sandbox_image.dockerfile;
    Cmd.Exit.ok)
  else sandbox_image_build_exit ~tag

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
         recipe is embedded in this binary and reaches docker on stdin, so no \
         checkout and no registry is involved."
    ; `P
        "It is not polyglot on purpose. A Keeper that has to build a project \
         needs that project's toolchain, named in its TOML with sandbox_image; \
         the container is read-only, so a turn cannot install what is missing."
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
  Cmd.v
    (Cmd.info "sandbox-image" ~doc ~man)
    Term.(const sandbox_image_cmd_exit $ print_only $ tag)

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

let cmd =
  let doc =
    "MASC workspace: the fleet TUI on a terminal, the MCP server everywhere else"
  in
  let info = Cmd.info "masc" ~version:Runtime_build_version.current ~doc in
  Cmd.group
    ~default:
      Term.(const front_door_cmd_exit $ host $ port $ run_base_path $ accept_store_quarantine $ build_provenance_path $ build_provenance_sha256 $ build_provenance_device $ build_provenance_inode)
    info
    [ init_cmd
    ; start_cmd
    ; login_cmd
    ; mcp_config_cmd
    ; runtime_default_set_cmd
    ; runtime_wizard_catalog_cmd
    ; runtime_probe_cmd
    ; schedule_prune_cmd
    ; keeper_create_cmd
    ; keeper_github_cmd
    ; sandbox_image_cmd
    ; build_commit_cmd
    ]

let () =
  setup_gc ();
  exit (Cmd.eval' cmd)
