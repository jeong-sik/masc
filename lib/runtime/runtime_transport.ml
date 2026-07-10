(** Runtime_transport — Transport and tool-lane helpers for OAS worker exec.

    Keeps provider label resolution, runtime MCP lane selection, and per-call
    CLI transport construction separate from the build/run orchestration in
    {!Runtime_agent}. *)


(* RFC-0167: the client-named omission-dedup module (#10097) was removed
   in the big-bang sweep. The structural omission of keeper-bound runtime
   MCP tools (when the runtime adapter requires per-keeper bridging
   but no per-keeper bearer is available) now degrades by dropping those
   tools from the per-turn policy. *)

(** Resolve a model label string to an OAS Provider.config.
    Uses MASC [Runtime_model_string.parse_model_string] (with Provider_registry as SSOT).
    Explicit model-label execution must never silently substitute a
    discovery-only model. Callers are expected to validate labels
    before reaching this helper. *)
type label_resolution_error = Runtime_transport_label_resolution.label_resolution_error =
  | Invalid_model_label of string

let label_resolution_error_to_string = Runtime_transport_label_resolution.label_resolution_error_to_string
let label_resolution_error_to_sdk_error = Runtime_transport_label_resolution.label_resolution_error_to_sdk_error
let resolve_provider_config_of_label = Runtime_transport_label_resolution.resolve_provider_config_of_label
let invalid_runtime_config = Runtime_transport_label_resolution.invalid_runtime_config

let provider_caps_of_config = Provider_tool_support.oas_capabilities_of_config
let provider_supports_inline_tools = Provider_tool_support.provider_supports_inline_tools

let provider_supports_runtime_mcp_lane =
  Provider_tool_support.provider_supports_runtime_mcp_lane
;;

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

let upsert_http_header = Runtime_transport_authorization.upsert_http_header
(* Runtime-MCP policy header helpers extracted to
   [Runtime_transport_mcp_policy_helpers] (godfile decomp). *)
let keeper_name_of_agent_name = Runtime_transport_authorization.keeper_name_of_agent_name

let runtime_mcp_policy_with_masc_agent_name =
  Runtime_transport_mcp_policy_helpers.runtime_mcp_policy_with_masc_agent_name
;;

let runtime_mcp_policy_without_http_headers =
  Runtime_transport_mcp_policy_helpers.runtime_mcp_policy_without_http_headers
;;

let per_keeper_authorization_header = Runtime_transport_authorization.per_keeper_authorization_header
let runtime_mcp_policy_uses_bound_actor_tools = Runtime_transport_authorization.runtime_mcp_policy_uses_bound_actor_tools
let add_masc_authorization_header = Runtime_transport_authorization.add_masc_authorization_header

(* Per-keeper authorization bridging extracted to
   [Runtime_transport_auth_bridging] (godfile decomp). *)
let codex_cli_can_auth_keeper_bound_runtime_mcp =
  Runtime_transport_auth_bridging.codex_cli_can_auth_keeper_bound_runtime_mcp

let bridged_runtime_mcp_policy_for_agent =
  Runtime_transport_auth_bridging.bridged_runtime_mcp_policy_for_agent

(* Provider-driven runtime MCP policy resolver extracted to
   [Runtime_transport_runtime_policy_provider] (godfile decomp). *)
let runtime_mcp_policy_for_provider = Runtime_transport_runtime_policy_provider.runtime_mcp_policy_for_provider
let public_mcp_tool_names_of_oas_tools =
  Runtime_transport_mcp_tool_classifier.public_mcp_tool_names_of_oas_tools
;;

let public_mcp_tools_of_oas_tools =
  Runtime_transport_mcp_tool_classifier.public_mcp_tools_of_oas_tools
;;

let tool_names_are_public_mcp =
  Runtime_transport_mcp_tool_classifier.tool_names_are_public_mcp
;;

let runtime_mcp_tool_requires_bound_actor =
  Runtime_transport_mcp_tool_classifier.runtime_mcp_tool_requires_bound_actor
;;

let public_mcp_tool_requires_bound_actor =
  Runtime_transport_mcp_tool_classifier.public_mcp_tool_requires_bound_actor
;;

let tool_names_are_runtime_mcp =
  Runtime_transport_mcp_tool_classifier.tool_names_are_runtime_mcp
;;

;;

let runtime_mcp_policy_of_tool_names = Runtime_transport_runtime_mcp_policy_of_tool_names.runtime_mcp_policy_of_tool_names
let public_mcp_runtime_policy_of_tool_names = Runtime_transport_runtime_mcp_policy_of_tool_names.public_mcp_runtime_policy_of_tool_names

(* provider_label inlined from the removed [Runtime_transport_cli_config].
   General display label ([kind:model_id]); used by the surviving tool-lane
   resolver and external consumers, so it outlives the CLI transport purge. *)
let provider_label (provider_cfg : Llm_provider.Provider_config.t) =
  Printf.sprintf
    "%s:%s"
    (Llm_provider.Provider_config.string_of_provider_kind provider_cfg.kind)
    provider_cfg.model_id
;;

let resolve_tool_lane_for_oas_tools
      ~base_path
      ?agent_name
      ~(provider_cfg : Llm_provider.Provider_config.t)
      ~(tools : Agent_sdk.Tool.t list)
      ()
  : ( Agent_sdk.Tool.t list * Llm_provider.Llm_transport.runtime_mcp_policy option
      , Agent_sdk.Error.sdk_error )
      result
  =
  let public_tools = public_mcp_tools_of_oas_tools tools in
  let public_tool_names = public_mcp_tool_names_of_oas_tools public_tools in
  let requested_agent_name = Option.bind agent_name String_util.trim_nonempty in
  (* The Agent_internal surface was empty (agent_internal_surface_tools = []),
     so no tool was ever a member.  Surface deleted in the surface-cut
     refactor; the agent-internal contribution to the runtime tool set is
     always []. *)
  let agent_internal_tool_names = [] in
  let requires_per_keeper_bridging =
    Provider_tool_support
    .provider_requires_per_keeper_bridging_for_bound_actor_tools
      provider_cfg
  in
  let provider_can_auth_keeper_bound_actor_tools =
    match requested_agent_name with
    | Some agent_name
      when requires_per_keeper_bridging
           && Option.is_some (keeper_name_of_agent_name agent_name) ->
      Result.is_ok (per_keeper_authorization_header ~base_path ~agent_name)
    | _ -> false
  in
  let omitted_keeper_bound_actor_tools =
    match requested_agent_name with
    | Some agent_name
      when requires_per_keeper_bridging
           && Option.is_some (keeper_name_of_agent_name agent_name)
           && not provider_can_auth_keeper_bound_actor_tools ->
      List.filter
        runtime_mcp_tool_requires_bound_actor
        (public_tool_names @ agent_internal_tool_names)
    | _ -> []
  in
  (* Tool calls are advisory on the keeper path. If a provider cannot expose
     bound-actor runtime MCP tools for this keeper, drop only those tools and
     keep the turn alive with the remaining supported lane. *)
  (
    let public_tool_names =
      if omitted_keeper_bound_actor_tools = []
      then public_tool_names
      else
        List.filter
          (fun tool_name -> not (public_mcp_tool_requires_bound_actor tool_name))
          public_tool_names
    in
    let agent_internal_tool_names =
      if omitted_keeper_bound_actor_tools = []
      then agent_internal_tool_names
      else
        List.filter
          (fun tool_name -> not (runtime_mcp_tool_requires_bound_actor tool_name))
          agent_internal_tool_names
    in
    let runtime_tool_names =
      dedupe_preserve_order (public_tool_names @ agent_internal_tool_names)
    in
    (* RFC-0167 (was #12676): When all tools were bound-actor and got
       stripped on an optional turn, runtime_tool_names is empty. The
       keeper may still use an MCP connection for discovery, so build a
       minimal connect-only policy with the server URL and auth but no
       allowed_tool_names. *)
    let runtime_mcp_policy =
      if runtime_tool_names = [] && omitted_keeper_bound_actor_tools <> []
      then (
        let resolved =
          Auth_resolve.resolve_runtime_mcp ~base_path
            ~agent_name:requested_agent_name
        in
        Auth_resolve.emit_resolution_trace ~runtime:"runtime_mcp_connect_only"
          ~keeper_id:
            (Option.bind requested_agent_name keeper_name_of_agent_name)
          ~provider_label:(provider_label provider_cfg) ~outcome:resolved;
        match resolved with
        | Error _ -> None
        | Ok { Auth_resolve.raw; _ } ->
            Some
              { Llm_provider.Llm_transport.empty_runtime_mcp_policy with
                servers =
                  [ Llm_provider.Llm_transport.Http_server
                      { name = "masc"
                      ; url = Env_config_runtime.Local_runtime.mcp_url ()
                      ; headers = [ "Authorization", "Bearer " ^ raw ]
                      }
                  ]
              ; allowed_server_names = [ "masc" ]
              ; allowed_tool_names = []
              ; strict = false
              ; disable_builtin_tools = false
              }
            |> runtime_mcp_policy_for_provider ~base_path ~provider_cfg
                 ~agent_name:(Option.value ~default:"" requested_agent_name))
      else
        runtime_mcp_policy_of_tool_names
          ~base_path
          ?agent_name:requested_agent_name
          ~allow_agent_internal:(agent_internal_tool_names <> [])
          runtime_tool_names
        |> runtime_mcp_policy_for_provider
             ~base_path
             ~provider_cfg
             ~agent_name:(Option.value ~default:"" requested_agent_name)
    in
    match runtime_mcp_policy with
    | Some runtime_mcp_policy
      when Provider_tool_support.provider_supports_runtime_mcp_policy
             provider_cfg
             runtime_mcp_policy -> Ok ([], Some runtime_mcp_policy)
    | _ when tools = [] -> Ok (tools, None)
    | _ when provider_supports_inline_tools provider_cfg -> Ok (tools, None)
    | _ -> Ok ([], None))
;;

(* CLI subprocess transport (json-stream local transport, ctors, argv
   sanitization, MCP-config JSON, and the non-HTTP registry) was removed
   in the CLI provider purge (2026-05-31). Provider dispatch is now
   HTTP-only; the [Cli_tool_*] provider kinds remain defined in the pinned
   agent_sdk but have no registered transport and are unreachable here. *)
