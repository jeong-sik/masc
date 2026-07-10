(** Runtime-MCP policy builder for tool-name lists, extracted from
    [runtime_transport.ml] (godfile decomp).

    - [runtime_mcp_policy_of_tool_names] — builds a runtime MCP policy
      pinned to the local [masc] HTTP server. Actor-bound policies use only
      the exact raw credential at
      [<base_path>/.masc/auth/<agent_name>.token]. Unbound policies may use
      [MASC_TOKEN]. Shared internal tokens never authenticate this protected
      transport. Returns [None] when the tools aren't runtime-MCP-eligible or
      no exact credential is available.
    - [public_mcp_runtime_policy_of_tool_names] — public-only
      forwarder (no [allow_agent_internal] knob). *)

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
    let resolved = Auth_resolve.resolve_runtime_mcp ~base_path ~agent_name in
    let masc_headers =
      Auth_resolve.emit_resolution_trace
        ~runtime:"runtime_mcp_policy"
        ~keeper_id:keeper_name
        ~provider_label:"masc"
        ~outcome:resolved;
      match resolved with
      | Ok { raw; _ } -> Some [ "Authorization", "Bearer " ^ raw ]
      | Error _ -> None
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
