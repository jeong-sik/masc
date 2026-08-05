let mcp_protocol_versions = Mcp_transport_protocol.supported_protocol_versions

let mcp_protocol_version_default = Mcp_transport_protocol.default_protocol_version

let default_base_path () =
  let requested_path = Config_dir_resolver.current_working_dir () in
  Workspace_utils_backend_setup.resolve_server_default_base_path requested_path

let is_valid_protocol_version version =
  List.mem version mcp_protocol_versions

let observer_session_id (request : Httpun.Request.t) =
  let uri = Uri.of_string request.target in
  match Uri.get_query_param uri "session_id" with
  | Some value when String.trim value <> "" -> Some value
  | Some _ | None -> None

let query_param request key =
  let uri = Uri.of_string request.Httpun.Request.target in
  Uri.get_query_param uri key
