open Result.Syntax

module SMap = Map.Make(String)

let rec atomic_update atomic f =
  let old_val = Atomic.get atomic in
  let new_val = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then ()
  else atomic_update atomic f

let mcp_protocol_versions = Mcp_transport_protocol.supported_protocol_versions

let mcp_protocol_version_default = Mcp_transport_protocol.default_protocol_version

let protocol_version_by_session : string SMap.t Atomic.t = Atomic.make SMap.empty

let mcp_profile_by_session : Server_mcp_transport_http_types.tool_profile SMap.t Atomic.t = Atomic.make SMap.empty

let default_base_path () =
  (* Match the launcher guard: a direct binary launch from a checkout with its
     own .masc must not silently inherit a stale parent MASC_BASE_PATH.
     When no explicit base path is set, prefer HOME so runtime artifacts land
     under ~/.masc instead of the current checkout. *)
  let requested_path =
    match Env_config_core.base_path_opt () with
    | Some _ -> Sys.getcwd ()
    | None -> (
        match Env_config_core.home_dir_opt () with
        | Some home -> home
        | None -> Sys.getcwd ())
  in
  Coord_utils_backend_setup.resolve_server_default_base_path requested_path

let is_valid_protocol_version version =
  List.mem version mcp_protocol_versions

let remember_protocol_version session_id version =
  if is_valid_protocol_version version then
    atomic_update protocol_version_by_session (fun map -> SMap.add session_id version map)

let remember_mcp_profile session_id profile =
  atomic_update mcp_profile_by_session (fun map -> SMap.add session_id profile map)

let forget_mcp_session session_id =
  atomic_update protocol_version_by_session (fun map -> SMap.remove session_id map);
  atomic_update mcp_profile_by_session (fun map -> SMap.remove session_id map)

(** Reap session entries whose session_id has no active SSE connection.
    Call periodically from the cleanup loop. Returns number of reaped entries. *)
let reap_stale_sessions ~is_active_session =
  let stale =
    SMap.fold (fun sid _ acc ->
      if not (is_active_session sid) then sid :: acc
      else acc
    ) (Atomic.get protocol_version_by_session) []
  in
  if stale <> [] then begin
    atomic_update protocol_version_by_session (fun map ->
      List.fold_left (fun m sid -> SMap.remove sid m) map stale
    );
    atomic_update mcp_profile_by_session (fun map ->
      List.fold_left (fun m sid -> SMap.remove sid m) map stale
    )
  end;
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

let legacy_messages_endpoint_url (request : Httpun.Request.t) session_id =
  match Httpun.Headers.get request.headers "host" with
  | Some host ->
      let proto =
        match Httpun.Headers.get request.headers "x-forwarded-proto" with
        | Some p -> p
        | None ->
            (* Length-mismatched [String.sub host 0 17 = "masc.crying.pict"]
               (17-char substring vs 16-char literal) was always false, so
               tunnel hosts silently advertised http://. starts_with also
               drops a per-request allocation. *)
            if String.starts_with ~prefix:"masc.crying.pict" host then "https"
            else "http"
      in
      Printf.sprintf "%s://%s/messages?session_id=%s" proto host session_id
  | None -> Printf.sprintf "/messages?session_id=%s" session_id

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
