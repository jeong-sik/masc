(** Runtime-MCP policy builder for tool-name lists.

    The caller supplies the MASC schemas for this exact run; their non-empty
    names are the transport policy SSOT. This module does not reclassify them
    through a static product catalog. Authentication is resolved independently
    from the supplied names: the exact agent's persisted token is preferred
    when an identity is present, then the workspace bearer is used, and a
    headerless policy is only admitted when workspace authentication permits it. *)

(* Duplicated locally to avoid sibling -> parent cycle. The parent
   keeps its own copy because three other sites there call it. *)
let dedupe_preserve_order (items : string list) =
  let seen = Hashtbl.create (List.length items) in
  List.filter
    (fun item ->
       if Hashtbl.mem seen item
       then false
       else (
         Hashtbl.add seen item ();
         true))
    items
;;

let first_nonempty_env names =
  List.find_map
    (fun name -> Sys.getenv_opt name |> String_util.option_trim)
    names
;;

type bearer_source =
  | Keeper_token_file
  | Workspace_bearer_env

type bearer =
  { raw : string
  ; source : bearer_source
  }

let bearer_source_label = function
  | Keeper_token_file -> "keeper_token_file"
  | Workspace_bearer_env -> "workspace_bearer_env"
;;

let resolve_bearer ~base_path ~agent_name =
  let keeper_token =
    Option.bind agent_name (fun name -> Auth.load_raw_token base_path ~agent_name:name)
  in
  match keeper_token, first_nonempty_env [ "MASC_TOKEN" ] with
  | Some raw, _ -> Some { raw; source = Keeper_token_file }
  | None, Some raw -> Some { raw; source = Workspace_bearer_env }
  | None, None -> None
;;

let workspace_auth_requires_bearer ~base_path =
  try
    let auth_config = Auth.load_auth_config base_path in
    auth_config.Masc_domain.enabled && auth_config.Masc_domain.require_token
  with
  | Sys_error message ->
    Log.Auth.error
      "runtime_mcp_policy: workspace auth state unavailable base_path=%s error=%s"
      base_path
      message;
    (* No resolvable workspace auth state means we cannot safely build an
       unauthenticated local-MASC runtime policy. *)
    true
  | Unix.Unix_error (error, operation, argument) ->
    Log.Auth.error
      "runtime_mcp_policy: workspace auth state unavailable base_path=%s operation=%s argument=%s error=%s"
      base_path
      operation
      argument
      (Unix.error_message error);
    (* No resolvable workspace auth state means we cannot safely build an
       unauthenticated local-MASC runtime policy. *)
    true
;;

let runtime_mcp_policy_of_tool_names
      ~base_path
      ?agent_name
      (tool_names : string list)
  : Llm_provider.Llm_transport.runtime_mcp_policy option
  =
  let tool_names = List.map String.trim tool_names |> dedupe_preserve_order in
  if tool_names = [] || List.exists (String.equal "") tool_names
  then None
  else (
    let agent_name = Option.bind agent_name String_util.trim_nonempty in
    let masc_headers =
      match resolve_bearer ~base_path ~agent_name with
      | Some { raw; source } ->
        Log.Auth.routine
          ?keeper_name:agent_name
          "runtime_mcp_policy: bearer resolved source=%s"
          (bearer_source_label source);
        let identity_headers =
          Option.fold
            ~none:[]
            ~some:(fun agent_name -> [ "x-masc-agent-name", agent_name ])
            agent_name
        in
        Some (("Authorization", "Bearer " ^ raw) :: identity_headers)
      | None when workspace_auth_requires_bearer ~base_path ->
        Log.Auth.error
          ?keeper_name:agent_name
          "runtime_mcp_policy: bearer required but neither keeper token nor MASC_TOKEN is available";
        None
      | None ->
        Log.Auth.routine
          ?keeper_name:agent_name
          "runtime_mcp_policy: workspace auth does not require a bearer";
        Some []
      in
      Option.map
        (fun masc_headers ->
           { Llm_provider.Llm_transport.empty_runtime_mcp_policy with
             servers =
               [ Llm_provider.Llm_transport.Http_server
                   { name = "masc"
                   ; url = Env_config_runtime.Local_runtime.mcp_url ()
                   ; headers = masc_headers
                   }
               ]
           ; allowed_server_names = [ "masc" ]
           ; allowed_tool_names = tool_names
           ; strict = true
           ; disable_builtin_tools = true
           })
        masc_headers)
;;
