open Result_syntax

let mcp_protocol_versions = Mcp_transport_protocol.supported_protocol_versions

let mcp_protocol_version_default = Mcp_transport_protocol.default_protocol_version

let protocol_version_by_session : (string, string) Hashtbl.t =
  Hashtbl.create 128

let mcp_profile_by_session : (string, Server_mcp_transport_http_types.tool_profile) Hashtbl.t =
  Hashtbl.create 128

(** Eio-cooperative mutex protecting both Hashtbl tables above.
    Concurrent HTTP request fibers can race on Hashtbl read/write. *)
let session_mutex = Eio.Mutex.create ()

let default_base_path () =
  (* Match the launcher guard: a direct binary launch from a checkout with its
     own .masc must not silently inherit a stale parent MASC_BASE_PATH. *)
  Room_utils_backend_setup.resolve_server_default_base_path (Sys.getcwd ())

let is_valid_protocol_version version =
  List.mem version mcp_protocol_versions

let remember_protocol_version session_id version =
  if is_valid_protocol_version version then
    Eio.Mutex.use_rw ~protect:true session_mutex (fun () ->
        Hashtbl.replace protocol_version_by_session session_id version)

let remember_mcp_profile session_id profile =
  Eio.Mutex.use_rw ~protect:true session_mutex (fun () ->
      Hashtbl.replace mcp_profile_by_session session_id profile)

let forget_mcp_session session_id =
  Eio.Mutex.use_rw ~protect:true session_mutex (fun () ->
      Hashtbl.remove protocol_version_by_session session_id;
      Hashtbl.remove mcp_profile_by_session session_id)

(** Reap session entries whose session_id has no active SSE connection.
    Call periodically from the cleanup loop. Returns number of reaped entries. *)
let reap_stale_sessions ~is_active_session =
  Eio.Mutex.use_rw ~protect:true session_mutex (fun () ->
    let stale =
      Hashtbl.fold (fun sid _ acc ->
        if not (is_active_session sid) then sid :: acc
        else acc
      ) protocol_version_by_session []
    in
    List.iter (fun sid ->
      Hashtbl.remove protocol_version_by_session sid;
      Hashtbl.remove mcp_profile_by_session sid
    ) stale;
    List.length stale)

let profile_label = function
  | Server_mcp_transport_http_types.Full -> "/mcp"
  | Server_mcp_transport_http_types.Managed_agent -> "/mcp/managed"
  | Server_mcp_transport_http_types.Operator_remote -> "/mcp/operator"

let validate_mcp_session_profile ~profile session_id =
  Eio.Mutex.use_ro session_mutex (fun () ->
      match Hashtbl.find_opt mcp_profile_by_session session_id with
      | None -> Ok ()
      | Some existing when existing = profile -> Ok ()
      | Some existing ->
          Error
            (Printf.sprintf "Session %s belongs to %s, not %s." session_id
               (profile_label existing) (profile_label profile)))

let validate_mcp_session_delete_profile ~profile session_id =
  match profile with
  | Server_mcp_transport_http_types.Operator_remote ->
      Eio.Mutex.use_ro session_mutex (fun () ->
          match Hashtbl.find_opt mcp_profile_by_session session_id with
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
            if
              String.length host >= 17
              && String.sub host 0 17 = "masc.crying.pict"
            then "https"
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
  Eio.Mutex.use_ro session_mutex (fun () ->
      match Hashtbl.find_opt protocol_version_by_session session_id with
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
          | None -> Ok ()))

let get_protocol_version_for_session ?session_id request =
  match session_id with
  | Some id ->
      Eio.Mutex.use_ro session_mutex (fun () ->
          match Hashtbl.find_opt protocol_version_by_session id with
          | Some v -> v
          | None -> get_protocol_version request)
  | None -> get_protocol_version request

let query_param request key =
  let uri = Uri.of_string request.Httpun.Request.target in
  Uri.get_query_param uri key
