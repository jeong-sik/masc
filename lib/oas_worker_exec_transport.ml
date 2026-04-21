(** Oas_worker_exec_transport — Transport and tool-lane helpers for OAS worker exec.

    Keeps provider label resolution, runtime MCP lane selection, and per-call
    CLI transport construction separate from the build/run orchestration in
    {!Oas_worker_exec}. *)

type cli_transport_overrides = {
  cwd : string option;
  claude_mcp_config : string option;
  claude_allowed_tools : string list option;
  claude_permission_mode : string option;
  claude_max_turns : int option;
  gemini_yolo : bool option;
}

(** Resolve a model label string to an OAS Provider.config.
    Uses MASC [Cascade_config.parse_model_string] (with Provider_registry as SSOT).
    Explicit model-label execution must never silently substitute a
    discovery-only model. Callers are expected to validate labels
    before reaching this helper. *)
type label_resolution_error =
  | Invalid_model_label of string

let label_resolution_error_to_string = function
  | Invalid_model_label label ->
      Printf.sprintf "invalid model label %S" label

let label_resolution_error_to_sdk_error err =
  Oas.Error.Config
    (Oas.Error.InvalidConfig
       {
         field = "model_label";
         detail = label_resolution_error_to_string err;
       })

let resolve_provider_config_of_label (label : string) :
    (Llm_provider.Provider_config.t, label_resolution_error) result =
  match Cascade_config.parse_model_string label with
  | Some pc -> Ok pc
  | None ->
      Log.error ~ctx:"oas_worker_exec"
        "refusing unresolved explicit model label=%S; execution never falls back to discovery-only models"
        label;
      Error (Invalid_model_label label)

let invalid_runtime_config field detail =
  Oas.Error.Config
    (Oas.Error.InvalidConfig { field; detail })

let cli_model_override model_id =
  match String.lowercase_ascii (String.trim model_id) with
  | "" | "auto" -> None
  | _ -> Some (String.trim model_id)

let provider_caps_of_config (provider_cfg : Llm_provider.Provider_config.t) =
  let base_caps =
    match provider_cfg.kind with
    | Llm_provider.Provider_config.Ollama ->
        Llm_provider.Capabilities.ollama_capabilities
    | Anthropic -> Llm_provider.Capabilities.anthropic_capabilities
    | Kimi -> Llm_provider.Capabilities.kimi_capabilities
    | Glm -> Llm_provider.Capabilities.glm_capabilities
    | Gemini -> Llm_provider.Capabilities.gemini_capabilities
    | OpenAI_compat -> Llm_provider.Capabilities.openai_chat_capabilities
    | Claude_code -> Llm_provider.Capabilities.claude_code_capabilities
    | Gemini_cli -> Llm_provider.Capabilities.gemini_cli_capabilities
    | Kimi_cli -> Llm_provider.Capabilities.kimi_cli_capabilities
    | Codex_cli -> Llm_provider.Capabilities.codex_cli_capabilities
  in
  let caps =
    match provider_cfg.kind with
    | Llm_provider.Provider_config.Claude_code
    | Gemini_cli
    | Codex_cli
    | Kimi_cli -> base_caps
    | _ -> (
        match Llm_provider.Capabilities.for_model_id provider_cfg.model_id with
        | Some caps -> caps
        | None -> base_caps)
  in
  match provider_cfg.supports_tool_choice_override with
  | Some supports_tool_choice -> { caps with supports_tool_choice }
  | None -> caps

let provider_supports_inline_tools (provider_cfg : Llm_provider.Provider_config.t) =
  (provider_caps_of_config provider_cfg).supports_tools

let provider_supports_runtime_mcp_lane
    (provider_cfg : Llm_provider.Provider_config.t) =
  let caps = provider_caps_of_config provider_cfg in
  caps.supports_runtime_mcp_tools && caps.supports_runtime_tool_events

let dedupe_preserve_order (items : string list) =
  let seen = Hashtbl.create (List.length items) in
  List.filter
    (fun item ->
      if Hashtbl.mem seen item then
        false
      else (
        Hashtbl.add seen item ();
        true))
    items

let public_mcp_tool_names_of_oas_tools (tools : Oas.Tool.t list) =
  List.map (fun (tool : Oas.Tool.t) -> tool.schema.name) tools

let tool_names_are_public_mcp (tool_names : string list) =
  tool_names <> [] && List.for_all Tool_catalog.is_public_mcp tool_names

let public_mcp_runtime_policy_of_tool_names (tool_names : string list) :
    Llm_provider.Llm_transport.runtime_mcp_policy option =
  let tool_names = dedupe_preserve_order tool_names in
  if not (tool_names_are_public_mcp tool_names) then
    None
  else
    Some
      {
        Llm_provider.Llm_transport.empty_runtime_mcp_policy with
        servers =
          [
            Llm_provider.Llm_transport.Http_server
              {
                name = "masc";
                url = Env_config_runtime.Local_runtime.mcp_url ();
                headers = [];
              };
          ];
        allowed_server_names = [ "masc" ];
        allowed_tool_names = tool_names;
        strict = true;
        disable_builtin_tools = true;
      }

let provider_label (provider_cfg : Llm_provider.Provider_config.t) =
  Printf.sprintf "%s:%s"
    (Llm_provider.Provider_config.string_of_provider_kind provider_cfg.kind)
    provider_cfg.model_id

let resolve_tool_lane_for_oas_tools
    ~(provider_cfg : Llm_provider.Provider_config.t)
    ~(tools : Oas.Tool.t list)
  : (Oas.Tool.t list
     * Llm_provider.Llm_transport.runtime_mcp_policy option,
     Oas.Error.sdk_error)
    result =
  let tool_names = public_mcp_tool_names_of_oas_tools tools in
  match public_mcp_runtime_policy_of_tool_names tool_names with
  | Some runtime_mcp_policy
    when provider_supports_runtime_mcp_lane provider_cfg ->
      Ok ([], Some runtime_mcp_policy)
  | _ when tools = [] ->
      Ok (tools, None)
  | _ when provider_supports_inline_tools provider_cfg ->
      Ok (tools, None)
  | _ ->
      let detail =
        if tool_names_are_public_mcp tool_names then
          Printf.sprintf
            "%s does not support inline tools or request-scoped runtime MCP tools"
            (provider_label provider_cfg)
        else
          Printf.sprintf "%s does not support inline tools"
            (provider_label provider_cfg)
      in
      Error (invalid_runtime_config "tool_support" detail)

(** Wrap CLI transports in a per-call sub-switch.

    agent_sdk's CLI subprocess helper binds stdout/stderr pipes to the
    switch passed at transport construction time. Reusing a long-lived
    keeper/server switch across many calls can therefore retain those pipe
    resources until the outer switch exits. By instantiating the real CLI
    transport inside a fresh sub-switch for each completion call, any
    leftover pipe resources are deterministically released at the end of the
    call even when the outer keeper lifetime is long-lived. *)
let make_per_call_switch_transport
    (factory : sw:Eio.Switch.t -> Llm_provider.Llm_transport.t)
  : Llm_provider.Llm_transport.t =
  let with_call_switch f =
    Eio.Switch.run (fun sw -> f (factory ~sw))
  in
  {
    complete_sync =
      (fun req ->
        with_call_switch (fun transport -> transport.complete_sync req));
    complete_stream =
      (fun ~on_event req ->
        with_call_switch (fun transport ->
            transport.complete_stream ~on_event req));
  }

let non_http_transport_of_provider
    ~(sw : Eio.Switch.t)
    ~(provider_cfg : Llm_provider.Provider_config.t)
    ?cli_transport_overrides
    ()
  : (Llm_provider.Llm_transport.t option, Oas.Error.sdk_error) result =
  let _ = sw in
  let proc_mgr_result () =
    match Process_eio.get_proc_mgr () with
    | Ok mgr -> Ok mgr
    | Error detail -> Error (invalid_runtime_config "proc_mgr" detail)
  in
  match provider_cfg.kind with
  | Llm_provider.Provider_config.Claude_code -> (
      match proc_mgr_result () with
      | Error _ as e -> e
      | Ok mgr ->
          let overrides =
            Option.value
              ~default:
                {
                  cwd = None;
                  claude_mcp_config = None;
                  claude_allowed_tools = None;
                  claude_permission_mode = None;
                  claude_max_turns = None;
                  gemini_yolo = None;
                }
              cli_transport_overrides
          in
          let config =
            {
              Llm_provider.Transport_claude_code.default_config with
              model = cli_model_override provider_cfg.model_id;
              cwd = overrides.cwd;
              mcp_config = overrides.claude_mcp_config;
              allowed_tools =
                Option.value ~default:[] overrides.claude_allowed_tools;
              permission_mode = overrides.claude_permission_mode;
              max_turns = overrides.claude_max_turns;
            }
          in
          Ok
            (Some
               (make_per_call_switch_transport (fun ~sw ->
                    Llm_provider.Transport_claude_code.create ~sw ~mgr
                      ~config))))
  | Llm_provider.Provider_config.Gemini_cli -> (
      match proc_mgr_result () with
      | Error _ as e -> e
      | Ok mgr ->
          let overrides =
            Option.value
              ~default:
                {
                  cwd = None;
                  claude_mcp_config = None;
                  claude_allowed_tools = None;
                  claude_permission_mode = None;
                  claude_max_turns = None;
                  gemini_yolo = None;
                }
              cli_transport_overrides
          in
          let config =
            {
              Llm_provider.Transport_gemini_cli.default_config with
              model = cli_model_override provider_cfg.model_id;
              cwd = overrides.cwd;
              yolo = Option.value ~default:true overrides.gemini_yolo;
            }
          in
          Ok
            (Some
               (make_per_call_switch_transport (fun ~sw ->
                    Llm_provider.Transport_gemini_cli.create ~sw ~mgr
                      ~config))))
  | Llm_provider.Provider_config.Kimi_cli -> (
      match proc_mgr_result () with
      | Error _ as e -> e
      | Ok mgr ->
          let config =
            {
              Llm_provider.Transport_kimi_cli.default_config with
              model = cli_model_override provider_cfg.model_id;
            }
          in
          Ok
            (Some
               (make_per_call_switch_transport (fun ~sw ->
                    Llm_provider.Transport_kimi_cli.create ~sw ~mgr
                      ~config))))
  | Llm_provider.Provider_config.Codex_cli -> (
      match proc_mgr_result () with
      | Error _ as e -> e
      | Ok mgr ->
          let cwd =
            Option.bind cli_transport_overrides (fun overrides -> overrides.cwd)
          in
          Ok
            (Some
               (make_per_call_switch_transport (fun ~sw ->
                    Llm_provider.Transport_codex_cli.create ~sw ~mgr
                      ~config:
                        {
                          Llm_provider.Transport_codex_cli.default_config with
                          cwd;
                        }))))
  | Anthropic | OpenAI_compat | Ollama | Gemini | Glm | Kimi ->
      Ok None
