(** Cascade_transport — Transport and tool-lane helpers for OAS worker exec.

    Keeps provider label resolution, runtime MCP lane selection, and per-call
    CLI transport construction separate from the build/run orchestration in
    {!Cascade_runner}. *)

(* cli_transport_overrides type extracted to
   [Cascade_transport_cli_overrides] (godfile decomp). *)
type cli_transport_overrides = Cascade_transport_cli_overrides.cli_transport_overrides =
  { cwd : string option
  ; claude_mcp_config : string option
  ; claude_allowed_tools : string list option
  ; claude_permission_mode : string option
  ; claude_max_turns : int option
  ; gemini_yolo : bool option
  ; cli_subprocess_idle_sec : float option
  }

(* OAS owns provider subprocess hard caps. This constant is a
   backward-compat re-export for tests and operator-facing labels only;
   MASC does not clamp provider-internal max_turns before dispatch. *)
let cli_tool_d_max_turns_hard_cap =
  Llm_provider.Provider_config.max_turns_hard_cap
    Llm_provider.Provider_config.Cli_tool_d
  |> Option.value ~default:30
;;

let provider_effective_max_turns _kind requested = requested

(* RFC-0167: the client-named omission-dedup module
   [Cascade_transport_codex_omission_dedup] (#10097) was removed in
   the big-bang sweep. The structural omission of keeper-bound runtime
   MCP tools (when the runtime adapter requires per-keeper bridging
   but no per-keeper bearer is available) is still detected and
   reported through the [Error (invalid_runtime_config ...)] path
   below — only the WARN-dedup + per-tool Prometheus counter were
   removed. *)

(** Resolve a model label string to an OAS Provider.config.
    Uses MASC [Cascade_config.parse_model_string] (with Provider_registry as SSOT).
    Explicit model-label execution must never silently substitute a
    discovery-only model. Callers are expected to validate labels
    before reaching this helper. *)
type label_resolution_error = Cascade_transport_label_resolution.label_resolution_error =
  | Invalid_model_label of string

let label_resolution_error_to_string = Cascade_transport_label_resolution.label_resolution_error_to_string
let label_resolution_error_to_sdk_error = Cascade_transport_label_resolution.label_resolution_error_to_sdk_error
let resolve_provider_config_of_label = Cascade_transport_label_resolution.resolve_provider_config_of_label
let invalid_runtime_config = Cascade_transport_label_resolution.invalid_runtime_config

let cli_model_override = Cascade_transport_cli_config.cli_model_override

(* CLI MCP config JSON serializer extracted to
   [Cascade_transport_cli_mcp_config_json] (godfile decomp). *)
let json_of_string_pairs = Cascade_transport_cli_mcp_config_json.json_of_string_pairs
let json_of_cli_mcp_server = Cascade_transport_cli_mcp_config_json.json_of_cli_mcp_server

let cli_mcp_config_json_of_policy =
  Cascade_transport_cli_mcp_config_json.cli_mcp_config_json_of_policy
;;

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

let upsert_http_header = Cascade_transport_authorization.upsert_http_header
(* String_util.trim_nonempty + first_nonempty_env + runtime-MCP policy header helpers
   extracted to [Cascade_transport_mcp_policy_helpers] (godfile decomp). *)
let first_nonempty_env = Cascade_transport_mcp_policy_helpers.first_nonempty_env
let keeper_name_of_agent_name = Cascade_transport_authorization.keeper_name_of_agent_name

let runtime_mcp_policy_with_masc_agent_name =
  Cascade_transport_mcp_policy_helpers.runtime_mcp_policy_with_masc_agent_name
;;

let runtime_mcp_policy_without_http_headers =
  Cascade_transport_mcp_policy_helpers.runtime_mcp_policy_without_http_headers
;;

let is_authorization_header = Cascade_transport_authorization.is_authorization_header
let authorization_header_from_policy = Cascade_transport_authorization.authorization_header_from_policy
let per_keeper_authorization_header = Cascade_transport_authorization.per_keeper_authorization_header
let runtime_mcp_policy_uses_bound_actor_tools = Cascade_transport_authorization.runtime_mcp_policy_uses_bound_actor_tools
let add_masc_authorization_header = Cascade_transport_authorization.add_masc_authorization_header

(* Per-keeper authorization bridging extracted to
   [Cascade_transport_auth_bridging] (godfile decomp). *)
let cli_tool_a_can_auth_keeper_bound_runtime_mcp = Cascade_transport_auth_bridging.cli_tool_a_can_auth_keeper_bound_runtime_mcp
let bridged_runtime_mcp_policy_for_agent = Cascade_transport_auth_bridging.bridged_runtime_mcp_policy_for_agent

(* Provider-driven runtime MCP policy resolver extracted to
   [Cascade_transport_runtime_policy_provider] (godfile decomp). *)
let runtime_mcp_policy_for_provider = Cascade_transport_runtime_policy_provider.runtime_mcp_policy_for_provider
let cli_runtime_mcp_jsons = Cascade_transport_runtime_policy_provider.cli_runtime_mcp_jsons
let public_mcp_tool_names_of_oas_tools =
  Cascade_transport_mcp_tool_classifier.public_mcp_tool_names_of_oas_tools
;;

let public_mcp_tools_of_oas_tools =
  Cascade_transport_mcp_tool_classifier.public_mcp_tools_of_oas_tools
;;

let tool_names_are_public_mcp =
  Cascade_transport_mcp_tool_classifier.tool_names_are_public_mcp
;;

let runtime_mcp_tool_requires_bound_actor =
  Cascade_transport_mcp_tool_classifier.runtime_mcp_tool_requires_bound_actor
;;

let public_mcp_tool_requires_bound_actor =
  Cascade_transport_mcp_tool_classifier.public_mcp_tool_requires_bound_actor
;;

let tool_names_are_runtime_mcp =
  Cascade_transport_mcp_tool_classifier.tool_names_are_runtime_mcp
;;

;;

let runtime_mcp_policy_of_tool_names = Cascade_transport_runtime_mcp_policy_of_tool_names.runtime_mcp_policy_of_tool_names
let public_mcp_runtime_policy_of_tool_names = Cascade_transport_runtime_mcp_policy_of_tool_names.public_mcp_runtime_policy_of_tool_names

let provider_label = Cascade_transport_cli_config.provider_label

let cli_model_for_provider_config =
  Cascade_transport_cli_config.cli_model_for_provider_config
;;

let cli_command_for_provider_config =
  Cascade_transport_cli_config.cli_command_for_provider_config
;;

let cli_process_name_for_provider_config =
  Cascade_transport_cli_config.cli_process_name_for_provider_config
;;

let cli_runtime_config_json_for_provider =
  Cascade_transport_cli_config.cli_runtime_config_json_for_provider
;;

let cli_direct_binding_extra_env =
  Cascade_transport_cli_config.cli_direct_binding_extra_env
;;

let resolve_tool_lane_for_oas_tools
      ?agent_name
      ?(tool_requirement = `Required)
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
  let keeper_internal_tool_names =
    match requested_agent_name with
    | Some agent_name when Option.is_some (keeper_name_of_agent_name agent_name) ->
      tools
      |> List.filter (fun (tool : Agent_sdk.Tool.t) ->
        Tool_catalog.is_on_surface Tool_catalog.Keeper_internal tool.schema.name)
      |> List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name)
      |> dedupe_preserve_order
    | _ -> []
  in
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
      Option.is_some (per_keeper_authorization_header ~agent_name)
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
        (public_tool_names @ keeper_internal_tool_names)
    | _ -> []
  in
  (* RFC-0167: previously routed [omitted_keeper_bound_actor_tools] through
     [Cascade_transport_codex_omission_dedup.record_cli_tool_a_omission_for_agent]
     for WARN-dedup + per-tool counter. The dedup module was a
     client-named adapter (cli_tool_a wire-quirk) and is removed; the
     omission is now silently reflected only in the [Error
     (invalid_runtime_config ...)] returned below. *)
  if tool_requirement = `Required && omitted_keeper_bound_actor_tools <> []
  then (
    let detail =
      Printf.sprintf
        "%s cannot satisfy required keeper-bound runtime MCP tools omitted by the runtime adapter: \
         %s"
        (provider_label provider_cfg)
        (String.concat ", " (List.sort String.compare omitted_keeper_bound_actor_tools))
    in
    Error (invalid_runtime_config "tool_support" detail))
  else (
    let public_tool_names =
      if omitted_keeper_bound_actor_tools = []
      then public_tool_names
      else
        List.filter
          (fun tool_name -> not (public_mcp_tool_requires_bound_actor tool_name))
          public_tool_names
    in
    let keeper_internal_tool_names =
      if omitted_keeper_bound_actor_tools = []
      then keeper_internal_tool_names
      else
        List.filter
          (fun tool_name -> not (runtime_mcp_tool_requires_bound_actor tool_name))
          keeper_internal_tool_names
    in
    let runtime_tool_names =
      dedupe_preserve_order (public_tool_names @ keeper_internal_tool_names)
    in
    (* RFC-0167 (was #12676): When all tools were bound-actor and got
       stripped on an optional turn, runtime_tool_names is empty. The
       keeper may still use an MCP connection for discovery, so build a
       minimal connect-only
       policy with the server URL and auth but no allowed_tool_names. Required
       turns reject above because a zero-tool policy cannot satisfy the tool
       contract. *)
    let runtime_mcp_policy =
      if runtime_tool_names = [] && omitted_keeper_bound_actor_tools <> []
      then (
        let env_token = first_nonempty_env [ "MASC_MCP_TOKEN" ] in
        let per_keeper_token =
          match env_token, requested_agent_name with
          | None, Some name ->
            let base_path = Env_config_core.base_path () in
            Auth.load_raw_token base_path ~agent_name:name
          | _ -> None
        in
        let auth_headers =
          match env_token, per_keeper_token with
          | Some raw, _ -> [ "Authorization", "Bearer " ^ raw ]
          | None, Some raw -> [ "Authorization", "Bearer " ^ raw ]
          | None, None -> []
        in
        Some
          { Llm_provider.Llm_transport.empty_runtime_mcp_policy with
            servers =
              [ Llm_provider.Llm_transport.Http_server
                  { name = "masc"
                  ; url = Env_config_runtime.Local_runtime.mcp_url ()
                  ; headers = auth_headers
                  }
              ]
          ; allowed_server_names = [ "masc" ]
          ; allowed_tool_names = []
          ; strict = false
          ; disable_builtin_tools = false
          }
        |> runtime_mcp_policy_for_provider
             ~provider_cfg
             ~agent_name:(Option.value ~default:"" requested_agent_name))
      else
        runtime_mcp_policy_of_tool_names
          ?agent_name:requested_agent_name
          ~allow_keeper_internal:(keeper_internal_tool_names <> [])
          runtime_tool_names
        |> runtime_mcp_policy_for_provider
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
    | _ when tool_requirement = `Optional -> Ok ([], None)
    | _ ->
      let detail =
        let runtime_mcp_requires_http_headers =
          match runtime_mcp_policy with
          | Some policy ->
            Provider_tool_support.runtime_mcp_policy_requires_unsupported_http_headers
              provider_cfg
              policy
          | None -> false
        in
        if
          public_tool_names <> []
          && runtime_mcp_requires_http_headers
          && provider_supports_runtime_mcp_lane provider_cfg
        then
          Printf.sprintf
            "%s does not support request-scoped runtime MCP HTTP headers required by \
             public MCP tools"
            (provider_label provider_cfg)
        else if public_tool_names <> []
        then
          Printf.sprintf
            "%s does not support inline tools or request-scoped runtime MCP tools"
            (provider_label provider_cfg)
        else
          Printf.sprintf "%s does not support inline tools" (provider_label provider_cfg)
      in
      Error (invalid_runtime_config "tool_support" detail))
;;

(* JSON-stream CLI transport (665 LOC nested module) extracted to
   [Cascade_transport_json_stream_cli_local] (godfile decomp).
   Module alias preserves type identity; [Cascade_transport.mli]
   signature constraint continues to apply unchanged. *)
module Json_stream_cli_transport_local = Cascade_transport_json_stream_cli_local

let json_stream_cli_transport_ctor
      ~(provider_cfg : Llm_provider.Provider_config.t)
      ~runtime_mcp_policy
      ~cli_transport_overrides
  =
  let cwd =
    Option.bind cli_transport_overrides (fun overrides ->
      overrides.Cascade_transport_cli_overrides.cwd)
  in
  let stdout_idle_timeout_s =
    Option.bind cli_transport_overrides (fun overrides ->
      overrides.Cascade_transport_cli_overrides.cli_subprocess_idle_sec)
  in
  let mcp_config_json = cli_runtime_mcp_jsons ~base:[] runtime_mcp_policy in
  let model = cli_model_for_provider_config provider_cfg in
  let config_json = cli_runtime_config_json_for_provider provider_cfg in
  let extra_env = cli_direct_binding_extra_env provider_cfg in
  let cli_path =
    cli_command_for_provider_config provider_cfg
    |> Option.value ~default:Json_stream_cli_transport_local.default_config.cli_path
  in
  let process_name = cli_process_name_for_provider_config provider_cfg in
  let config =
    { Json_stream_cli_transport_local.default_config with
      cli_path
    ; process_name
    ; model
    ; cwd
    ; config_json
    ; mcp_config_json
    ; extra_env
    ; stdout_idle_timeout_s
    }
  in
  match Process_eio.get_proc_mgr () with
  | Error detail -> Error (invalid_runtime_config "proc_mgr" detail)
  | Ok mgr ->
    Ok
      (Cascade_transport_cli_ctors.make_per_call_switch_transport (fun ~sw ->
         Json_stream_cli_transport_local.create ~sw ~mgr ~config))
;;

let () =
  Cascade_transport_non_http_registry.register_non_http_transport
    ~kind:Llm_provider.Provider_config.Cli_tool_c
    ~ctor:json_stream_cli_transport_ctor
;;

(* CLI transport constructors + per-call switch wrapping + ctor
   registration extracted to [Cascade_transport_cli_ctors]
   (godfile decomp). The sibling's top-level [let () = ...]
   block registers the 4 ctors into
   [Cascade_transport_non_http_registry] at module-load time. *)
let make_per_call_switch_transport = Cascade_transport_cli_ctors.make_per_call_switch_transport

(* CLI argv UTF-8 sanitization extracted to
   [Cascade_transport_cli_argv_sanitize] (godfile decomp). *)
let sanitize_runtime_mcp_server_for_cli =
  Cascade_transport_cli_argv_sanitize.sanitize_runtime_mcp_server_for_cli
;;

let sanitize_runtime_mcp_policy_for_cli =
  Cascade_transport_cli_argv_sanitize.sanitize_runtime_mcp_policy_for_cli
;;

let sanitize_cli_completion_request_for_argv =
  Cascade_transport_cli_argv_sanitize.sanitize_cli_completion_request_for_argv
;;
let non_http_transport_of_provider = Cascade_transport_non_http_registry.non_http_transport_of_provider
