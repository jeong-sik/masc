open Result.Syntax

module SMap = Set_util.StringMap

let rec atomic_update atomic f =
  let old_val = Atomic.get atomic in
  let new_val = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then ()
  else atomic_update atomic f

let mcp_protocol_versions = Mcp_transport_protocol.supported_protocol_versions

let mcp_protocol_version_default = Mcp_transport_protocol.default_protocol_version

let protocol_version_by_session : string SMap.t Atomic.t = Atomic.make SMap.empty

let mcp_profile_by_session : Server_mcp_transport_http_types.tool_profile SMap.t Atomic.t = Atomic.make SMap.empty

let session_started_at : float SMap.t Atomic.t = Atomic.make SMap.empty

let session_transport_context :
  Otel_dispatch_hook.transport_context SMap.t Atomic.t =
  Atomic.make SMap.empty

(** Grace period: seconds to keep a session after SSE disconnect before reaping.
    Prevents immediate reap on brief SSE interruptions or server restart.
    Configurable via [MASC_SESSION_SSE_GRACE_PERIOD_SEC] env var (default 300 = 5 min). *)
let grace_period_seconds = Env_config_runtime.Session.sse_grace_period_seconds

(** Per-session timestamp of last active SSE connection.
    Used by [reap_stale_sessions] to implement the grace period:
    sessions without active SSE are kept until [now - last_active > grace_period]. *)
let session_last_active_sse : float SMap.t Atomic.t = Atomic.make SMap.empty

let default_base_path () =
  (* Match the launcher guard: a direct binary launch from a checkout with its
     own .masc must not silently inherit a stale parent MASC_BASE_PATH.
     When no explicit base path is set, use the current checkout/cwd rather
     than HOME so runtime artifacts stay under a visible base path. *)
  let requested_path = Config_dir_resolver.current_working_dir () in
  Workspace_utils_backend_setup.resolve_server_default_base_path requested_path

let is_valid_protocol_version version =
  List.mem version mcp_protocol_versions

let option_label key = function
  | Some value when String.trim value <> "" -> [ key, value ]
  | _ -> []

let transport_context_labels = function
  | None -> []
  | Some transport ->
      option_label
        Otel_genai.Mcp_attr_key.network_protocol_name
        transport.Otel_dispatch_hook.network_protocol_name
      @ option_label
          Otel_genai.Mcp_attr_key.network_protocol_version
          transport.Otel_dispatch_hook.network_protocol_version
      @ option_label
          Otel_genai.Mcp_attr_key.network_transport
          transport.Otel_dispatch_hook.network_transport

let record_mcp_server_session_duration ?error_type session_id =
  match SMap.find_opt session_id (Atomic.get session_started_at) with
  | None -> ()
  | Some started_at ->
    (* NDT-OK: session duration is emitted as OTel telemetry only. *)
    let duration_s = max 0.0 (Unix.gettimeofday () -. started_at) in
    let labels =
      option_label
        Otel_genai.Mcp_attr_key.mcp_protocol_version
        (SMap.find_opt session_id (Atomic.get protocol_version_by_session))
      @ transport_context_labels
          (SMap.find_opt session_id (Atomic.get session_transport_context))
      @ option_label Otel_genai.Mcp_attr_key.error_type error_type
    in
    Otel_metric_store.observe_histogram
      Otel_genai.Mcp_metric_name.server_session_duration
      ~labels
      duration_s

let remember_session_activity ?otel_transport_context session_id =
  let now = Unix.gettimeofday () in
  atomic_update session_started_at (fun map ->
    if SMap.mem session_id map then map else SMap.add session_id now map);
  atomic_update session_last_active_sse (fun map -> SMap.add session_id now map);
  match otel_transport_context with
  | None -> ()
  | Some transport ->
    atomic_update session_transport_context (fun map ->
      SMap.add session_id transport map)

let remember_protocol_version ?otel_transport_context session_id version =
  if is_valid_protocol_version version then begin
    atomic_update protocol_version_by_session (fun map -> SMap.add session_id version map);
    remember_session_activity ?otel_transport_context session_id
  end

let jsonrpc_response_succeeded = function
  | `Assoc fields ->
    (match List.assoc_opt "jsonrpc" fields with
     | Some (`String "2.0") ->
       List.mem_assoc "id" fields
       && List.mem_assoc "result" fields
       && not (List.mem_assoc "error" fields)
     | _ -> false)
  | _ -> false

let remember_protocol_version_if_initialize_succeeded
      ?otel_transport_context
      session_id
      ~request_body
      ~response_json
  =
  if jsonrpc_response_succeeded response_json then
    match Mcp_transport_protocol.protocol_version_from_body request_body with
    | Some version ->
      remember_protocol_version ?otel_transport_context session_id version
    | None -> ()

(** RFC-0100 PR-3 — Q3 default: known-session predicate.

    A session is "known" once an [initialize] body has registered a
    protocol version for its id (see [remember_protocol_version]). Use
    this to distinguish the legitimate "fresh session, no header"
    handshake (where the server mints an id) from a client echoing an
    [Mcp-Session-Id] header that the server has no state for — the latter
    is rejected with [404 Not Found] so the client must re-handshake
    instead of silently riding on a phantom session.

    [mcp_profile_by_session] is not consulted because it is populated on
    every POST regardless of whether [initialize] has succeeded, so it
    cannot distinguish the handshake transition. *)
let is_known_session session_id =
  SMap.mem session_id (Atomic.get protocol_version_by_session)

let remember_mcp_profile ?otel_transport_context session_id profile =
  atomic_update mcp_profile_by_session (fun map -> SMap.add session_id profile map);
  if is_known_session session_id then
    remember_session_activity ?otel_transport_context session_id

let forget_mcp_session session_id =
  record_mcp_server_session_duration session_id;
  atomic_update protocol_version_by_session (fun map -> SMap.remove session_id map);
  atomic_update mcp_profile_by_session (fun map -> SMap.remove session_id map);
  atomic_update session_last_active_sse (fun map -> SMap.remove session_id map);
  atomic_update session_started_at (fun map -> SMap.remove session_id map);
  atomic_update session_transport_context (fun map -> SMap.remove session_id map)

(* ===== File persistence ===== *)

let profile_to_string = function
  | Server_mcp_transport_http_types.Full -> "full"
  | Server_mcp_transport_http_types.Managed_agent -> "managed_agent"
  | Server_mcp_transport_http_types.Operator_remote -> "operator_remote"

let profile_of_string = function
  | "full" -> Some Server_mcp_transport_http_types.Full
  | "managed_agent" -> Some Server_mcp_transport_http_types.Managed_agent
  | "operator_remote" -> Some Server_mcp_transport_http_types.Operator_remote
  | _ -> None

let sessions_file_path () =
  let base = default_base_path () in
  Filename.concat (Filename.concat base ".masc") "mcp_transport_sessions.json"

(** Serialize current session state to JSON and write to disk atomically.
    Uses write-then-rename to avoid partial writes on crash. *)
let save_sessions_to_file () =
  let path = sessions_file_path () in
  let dir = Filename.dirname path in
  if not (Stdlib.Sys.file_exists dir) then
    try Unix.mkdir dir 0o755 with Unix.Unix_error _ -> ();
  let versions = Atomic.get protocol_version_by_session in
  let profiles = Atomic.get mcp_profile_by_session in
  let timestamps = Atomic.get session_last_active_sse in
  let started_at = Atomic.get session_started_at in
  let transports = Atomic.get session_transport_context in
  let all_ids = SMap.fold (fun sid _ acc -> sid :: acc) versions [] in
  let string_field key = function
    | Some value when String.trim value <> "" -> [ key, `String value ]
    | _ -> []
  in
  let json_entries =
    List.filter_map (fun sid ->
      match SMap.find_opt sid versions with
      | None -> None
      | Some pv ->
          let profile_str =
            match SMap.find_opt sid profiles with
            | Some p -> profile_to_string p
            | None -> "full"
          in
          let ts =
            match SMap.find_opt sid timestamps with
            | Some t -> t
            | None -> 0.0
          in
          let started =
            match SMap.find_opt sid started_at with
            | Some t -> t
            | None -> ts
          in
          let transport_fields =
            match SMap.find_opt sid transports with
            | None -> []
            | Some transport ->
                string_field
                  "network_protocol_name"
                  transport.Otel_dispatch_hook.network_protocol_name
                @ string_field
                    "network_protocol_version"
                    transport.Otel_dispatch_hook.network_protocol_version
                @ string_field
                    "network_transport"
                    transport.Otel_dispatch_hook.network_transport
          in
          Some
            ( sid
            , `Assoc
                ([ "protocol_version", `String pv
                 ; "profile", `String profile_str
                 ; "last_active_sse", `Float ts
                 ; "started_at", `Float started
                 ]
                 @ transport_fields) )
    ) all_ids
  in
  let json = `Assoc [ "sessions", `Assoc json_entries ] in
  let tmp_path = path ^ ".tmp" in
  let oc = open_out tmp_path in
  output_string oc (Yojson.Basic.to_string json);
  output_char oc '\n';
  close_out oc;
  Unix.rename tmp_path path

(** Load session state from disk. Restores protocol versions, profiles,
    and last-active timestamps so the grace period applies correctly
    after a server restart.

    Errors (missing file, corrupt JSON) are silently ignored — the
    server starts with a clean slate, which is safe but means clients
    must re-handshake. *)
let load_sessions_from_file () =
  let path = sessions_file_path () in
  if not (Stdlib.Sys.file_exists path) then ()
  else begin
    try
      let float_field = function
        | Some (`Float value) -> Some value
        | Some (`Int value) -> Some (float_of_int value)
        | _ -> None
      in
      let string_field key fields =
        match List.assoc_opt key fields with
        | Some (`String value) when String.trim value <> "" -> Some value
        | _ -> None
      in
      let transport_context fields =
        let network_protocol_name = string_field "network_protocol_name" fields in
        let network_protocol_version =
          string_field "network_protocol_version" fields
        in
        let network_transport = string_field "network_transport" fields in
        match
          network_protocol_name, network_protocol_version, network_transport
        with
        | None, None, None -> None
        | _ ->
          Some
            { Otel_dispatch_hook.network_protocol_name
            ; network_protocol_version
            ; network_transport
            }
      in
      let json = Yojson.Basic.from_file path in
      (match json with
       | `Assoc [("sessions", `Assoc entries)] ->
           List.iter (fun (sid, entry) ->
             match entry with
             | `Assoc fields ->
                 let pv = List.assoc_opt "protocol_version" fields in
                 let profile_str = List.assoc_opt "profile" fields in
                 let ts = List.assoc_opt "last_active_sse" fields in
                 let started = List.assoc_opt "started_at" fields in
                 (match pv with
                  | Some (`String v) ->
                      if is_valid_protocol_version v then begin
                        let t =
                          match float_field ts with
                          | Some value -> value
                          | None -> 0.0
                        in
                        let started_at =
                          match float_field started with
                          | Some value -> value
                          | None -> t
                        in
                        atomic_update protocol_version_by_session
                          (fun map -> SMap.add sid v map);
                        let profile =
                          match profile_str with
                          | Some (`String p) -> profile_of_string p
                          | _ -> None
                        in
                        (match profile with
                         | Some profile ->
                             atomic_update mcp_profile_by_session
                               (fun map -> SMap.add sid profile map)
                         | None -> ());
                        atomic_update session_last_active_sse
                          (fun map -> SMap.add sid t map);
                        atomic_update session_started_at
                          (fun map -> SMap.add sid started_at map);
                        (match transport_context fields with
                         | Some transport ->
                             atomic_update session_transport_context
                               (fun map -> SMap.add sid transport map)
                         | None -> ())
                      end
                  | _ -> ())
             | _ -> ()
           ) entries
       | _ -> ())
    with
    | Stdlib.Sys_error _ -> ()
    | Yojson.Json_error _ -> ()
  end

(** Reap session entries whose session_id has no active SSE connection
    AND whose grace period has expired.

    Grace period logic: when a session's SSE goes inactive, we record the
    timestamp in [session_last_active_sse]. The session is kept for
    [grace_period_seconds] after that point, giving the client time to
    reconnect without triggering "Unknown Mcp-Session-Id" errors.

    Call periodically from the cleanup loop. Returns number of reaped entries. *)
let reap_stale_sessions ~is_active_session =
  let now = Unix.gettimeofday () in
  let stale, kept_by_grace =
    SMap.fold (fun sid _ (stale_acc, grace_acc) ->
      if is_active_session sid then begin
        (* Active right now — refresh timestamp, keep session *)
        atomic_update session_last_active_sse
          (fun map -> SMap.add sid now map);
        (stale_acc, grace_acc)
      end else begin
        (* Not active — check grace period *)
        match SMap.find_opt sid (Atomic.get session_last_active_sse) with
        | Some last_active when now -. last_active < grace_period_seconds ->
            (* Within grace period — keep *)
            (stale_acc, grace_acc + 1)
        | _ ->
            (* Grace expired or never tracked — reap *)
            (sid :: stale_acc, grace_acc)
      end
    ) (Atomic.get protocol_version_by_session) ([], 0)
  in
  if stale <> [] then begin
    List.iter record_mcp_server_session_duration stale;
    atomic_update protocol_version_by_session (fun map ->
      List.fold_left (fun m sid -> SMap.remove sid m) map stale
    );
    atomic_update mcp_profile_by_session (fun map ->
      List.fold_left (fun m sid -> SMap.remove sid m) map stale
    );
    atomic_update session_last_active_sse (fun map ->
      List.fold_left (fun m sid -> SMap.remove sid m) map stale
    );
    atomic_update session_started_at (fun map ->
      List.fold_left (fun m sid -> SMap.remove sid m) map stale
    );
    atomic_update session_transport_context (fun map ->
      List.fold_left (fun m sid -> SMap.remove sid m) map stale
    )
  end;
  if kept_by_grace > 0 then
    Log.Server.info "session grace: %d sessions kept (inactive but within %.0fs grace)"
      kept_by_grace grace_period_seconds;
  (* Persist session state after each reap cycle so file stays current. *)
  (try save_sessions_to_file ()
   with Stdlib.Sys_error msg ->
     Log.Server.warn "session persist failed: %s" msg);
  List.length stale

let profile_label = function
  | Server_mcp_transport_http_types.Full -> "/mcp"
  | Server_mcp_transport_http_types.Managed_agent -> "/mcp/managed"
  | Server_mcp_transport_http_types.Operator_remote -> "/mcp/operator"

let validate_mcp_session_profile ~profile session_id =
  match SMap.find_opt session_id (Atomic.get mcp_profile_by_session) with
  | None -> Ok ()
  | Some existing when existing = profile -> Ok ()
  | Some existing ->
      Error
        (Printf.sprintf "Session %s belongs to %s, not %s." session_id
           (profile_label existing) (profile_label profile))

let validate_mcp_session_delete_profile ~profile session_id =
  match profile with
  | Server_mcp_transport_http_types.Operator_remote ->
      (match SMap.find_opt session_id (Atomic.get mcp_profile_by_session) with
       | Some Server_mcp_transport_http_types.Operator_remote -> Ok ()
       | Some existing ->
           Error
             (Printf.sprintf "Session %s belongs to %s, not %s." session_id
                (profile_label existing) (profile_label profile))
       | None ->
           Error
             (Printf.sprintf "Session %s is not registered on %s." session_id
                (profile_label profile)))
  | Server_mcp_transport_http_types.Full
  | Server_mcp_transport_http_types.Managed_agent ->
      validate_mcp_session_profile ~profile session_id

let protocol_version_from_body body_str =
  Mcp_transport_protocol.protocol_version_from_body body_str

let get_session_id_query target =
  match String.split_on_char '?' target with
  | [ _; query ] ->
      query
      |> String.split_on_char '&'
      |> List.find_map (fun param ->
             match String.split_on_char '=' param with
             | [ "session_id"; v ] | [ "sessionId"; v ] -> Some v
             | _ -> None)
  | _ -> None

let capitalize_ascii (s : string) =
  if s = "" then
    s
  else
    let first = Char.uppercase_ascii s.[0] |> String.make 1 in
    let rest =
      if String.length s > 1 then
        String.sub s 1 (String.length s - 1) |> String.lowercase_ascii
      else
        ""
    in
    first ^ rest

let title_case_header_name (header_name : string) =
  header_name |> String.split_on_char '-' |> List.map capitalize_ascii
  |> String.concat "-"

let get_header_any_case (headers : Httpun.Headers.t) (name : string) =
  match Httpun.Headers.get headers name with
  | Some _ as value -> value
  | None ->
      let title_case = title_case_header_name name in
      (match Httpun.Headers.get headers title_case with
      | Some _ as value -> value
      | None -> Httpun.Headers.get headers (String.uppercase_ascii name))

let get_cookie_value (request : Httpun.Request.t) cookie_name =
  match get_header_any_case request.headers "cookie" with
  | None -> None
  | Some raw ->
      raw
      |> String.split_on_char ';'
      |> List.find_map (fun part ->
             match String.split_on_char '=' (String.trim part) with
             | key :: value_parts
               when String.lowercase_ascii (String.trim key)
                    = String.lowercase_ascii cookie_name ->
                 let value = String.concat "=" value_parts |> String.trim in
                 if value = "" then None else Some value
             | _ -> None)

let get_session_id_any (request : Httpun.Request.t) =
  match get_session_id_query request.target with
  | Some _ as id -> id
  | None -> (
      match get_header_any_case request.headers "mcp-session-id" with
      | Some _ as id -> id
      | None -> get_cookie_value request "mcp-session-id")

let get_protocol_version (request : Httpun.Request.t) =
  match get_header_any_case request.headers "mcp-protocol-version" with
  | Some v -> v
  | None -> mcp_protocol_version_default

let get_protocol_version_header_opt (request : Httpun.Request.t) =
  get_header_any_case request.headers "mcp-protocol-version"

let validate_protocol_version_continuity ~session_id request =
  let validate_supported version =
    if is_valid_protocol_version version then
      Ok ()
    else
      Error (Printf.sprintf "Unsupported MCP-Protocol-Version: %s" version)
  in
  let provided = get_protocol_version_header_opt request in
  match SMap.find_opt session_id (Atomic.get protocol_version_by_session) with
  | Some expected -> (
      match provided with
      | None -> Ok ()
      | Some version ->
          let* () = validate_supported version in
          if String.equal version expected then
            Ok ()
          else
            Error
              (Printf.sprintf
                 "MCP-Protocol-Version mismatch for session %s: expected %s, \
                  got %s."
                 session_id expected version))
  | None -> (
      match provided with
      | Some version -> validate_supported version
      | None -> Ok ())

let get_protocol_version_for_session ?session_id request =
  match session_id with
  | Some id ->
      (match SMap.find_opt id (Atomic.get protocol_version_by_session) with
       | Some v -> v
       | None -> get_protocol_version request)
  | None -> get_protocol_version request

let query_param request key =
  let uri = Uri.of_string request.Httpun.Request.target in
  Uri.get_query_param uri key
