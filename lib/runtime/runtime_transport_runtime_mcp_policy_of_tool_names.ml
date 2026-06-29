(** Runtime-MCP policy builder for tool-name lists, extracted from
    [runtime_transport.ml] (godfile decomp).

    - [runtime_mcp_policy_of_tool_names] — builds a runtime MCP policy
      pinned to the local [masc] HTTP server. Resolves
      [Authorization]/internal-keeper headers via:
      1. [MASC_INTERNAL_MCP_TOKEN] env + keeper-name when a
         [Agent_internal] surface tool is requested, OR
      2. [MASC_TOKEN] env, falling back to the per-keeper raw
         token at [<base_path>/.masc/auth/<agent_name>.token]
         (Phase A F1: CLI-spawned subprocesses without parent env).
      Returns [None] when the tools aren't runtime-MCP-eligible, or
      when a Agent_internal tool was requested without
      keeper_name/internal_keeper_token.
    - [public_mcp_runtime_policy_of_tool_names] — public-only
      forwarder (no [allow_agent_internal] knob). *)

module Mcp_policy_helpers = Runtime_transport_mcp_policy_helpers
module Authorization = Runtime_transport_authorization
module Mcp_tool_classifier = Runtime_transport_mcp_tool_classifier

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

(* Duplicated locally for the same reason — 4-line idempotent helper
   used only by this sibling. *)
;;

let workspace_auth_requires_bearer ~base_path =
  try
    let auth_config = Auth.load_auth_config base_path in
    auth_config.Masc_domain.enabled && auth_config.Masc_domain.require_token
  with
  | Sys_error _ | Unix.Unix_error _ ->
    (* No resolvable workspace auth state means we cannot safely build an
       unauthenticated local-MASC runtime policy. *)
    true
;;

let runtime_mcp_policy_of_tool_names
      ~base_path
      ?agent_name
      ?(allow_agent_internal = false)
      (tool_names : string list)
  : Llm_provider.Llm_transport.runtime_mcp_policy option
  =
  (* [allow_agent_internal] is retained as a no-op parameter: the
     Agent_internal surface was empty (agent_internal_surface_tools = []), so
     no tool was ever a member.  Surface deleted in the surface-cut refactor;
     the [has_agent_internal] gate is now always [false]. *)
  ignore (allow_agent_internal : bool);
  let tool_names = dedupe_preserve_order tool_names in
  if not (Mcp_tool_classifier.tool_names_are_runtime_mcp tool_names)
  then None
  else (
    let agent_name = Option.bind agent_name String_util.trim_nonempty in
    let keeper_name = Option.bind agent_name Authorization.keeper_name_of_agent_name in
    let internal_keeper_token =
      Mcp_policy_helpers.first_nonempty_env [ "MASC_INTERNAL_MCP_TOKEN" ]
    in
    let masc_headers =
        match keeper_name, internal_keeper_token with
        | Some keeper_name, Some token ->
          let agent_header =
            match agent_name with
            | Some agent_name -> [ "x-masc-agent-name", agent_name ]
            | None -> []
          in
          Auth_resolve.emit_resolution_trace
            ~runtime:"runtime_mcp_policy"
            ~keeper_id:(Some keeper_name)
            ~provider_label:"masc"
            ~outcome:
              (Ok { Auth_resolve.raw = token; source = Auth_resolve.Internal_keeper_env });
          Some
            (("x-masc-internal-token", token)
             :: ("x-masc-keeper-name", keeper_name)
             :: agent_header)
        | _ ->
          let env_token = Mcp_policy_helpers.first_nonempty_env [ "MASC_TOKEN" ] in
          (* Phase A F1: when MASC_TOKEN is unset, fall back to the
             per-keeper raw token at <base_path>/.masc/auth/<agent_name>.token.
             This wires CLI-spawned subprocesses that callback to masc tools
             but do not inherit the parent process env. *)
          let per_keeper_token =
            match env_token, agent_name with
            | None, Some name ->
              Auth.load_raw_token base_path ~agent_name:name
            | _ -> None
          in
          let resolved : (Auth_resolve.token, Auth_resolve.auth_error) result =
            match env_token, per_keeper_token with
            | Some raw, _ -> Ok { Auth_resolve.raw; source = Auth_resolve.Mcp_bearer_env }
            | None, Some raw ->
              Ok { Auth_resolve.raw; source = Auth_resolve.Per_keeper_token_file }
            | None, None ->
              Error (Auth_resolve.Api_key_env_unset { var_name = "MASC_TOKEN" })
          in
          (match resolved with
           | Ok { raw; _ } ->
             Auth_resolve.emit_resolution_trace
               ~runtime:"runtime_mcp_policy"
               ~keeper_id:keeper_name
               ~provider_label:"masc"
               ~outcome:resolved;
             Some [ "Authorization", "Bearer " ^ raw ]
           | Error _ when workspace_auth_requires_bearer ~base_path -> None
           | Error _ -> Some [])
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

let public_mcp_runtime_policy_of_tool_names ~base_path ?agent_name (tool_names : string list)
  : Llm_provider.Llm_transport.runtime_mcp_policy option
  =
  runtime_mcp_policy_of_tool_names ~base_path ?agent_name tool_names
;;
