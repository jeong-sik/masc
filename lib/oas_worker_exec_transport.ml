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

let json_of_string_pairs pairs =
  `Assoc (List.map (fun (k, v) -> (k, `String v)) pairs)

let json_of_kimi_mcp_server = function
  | Llm_provider.Llm_transport.Stdio_server { command; args; env; _ } ->
      `Assoc
        [
          ("command", `String command);
          ("args", `List (List.map (fun arg -> `String arg) args));
          ("env", json_of_string_pairs env);
        ]
  | Llm_provider.Llm_transport.Http_server { url; headers; _ } ->
      `Assoc
        [
          ("url", `String url);
          ("headers", json_of_string_pairs headers);
        ]

let kimi_mcp_config_json_of_policy
    (policy : Llm_provider.Llm_transport.runtime_mcp_policy) : string option =
  let allowed_server_name name =
    match policy.allowed_server_names with
    | [] -> true
    | names -> List.mem name names
  in
  let servers =
    List.filter
      (fun server ->
        allowed_server_name
          (Llm_provider.Llm_transport.runtime_mcp_server_name server))
      policy.servers
  in
  match servers with
  | [] -> None
  | servers ->
      let config_json =
        `Assoc
          [
            ( "mcpServers",
              `Assoc
                (List.map
                   (fun server ->
                     ( Llm_provider.Llm_transport.runtime_mcp_server_name server,
                       json_of_kimi_mcp_server server ))
                   servers) );
          ]
      in
      Some (Yojson.Safe.to_string config_json)

let kimi_cli_model_for_provider (provider_cfg : Llm_provider.Provider_config.t) =
  match cli_model_override provider_cfg.model_id with
  | Some explicit -> Some explicit
  | None -> Llm_provider.Transport_kimi_cli.default_config.model

let provider_caps_of_config = Provider_tool_support.oas_capabilities_of_config
let provider_supports_inline_tools = Provider_tool_support.provider_supports_inline_tools
let provider_supports_runtime_mcp_lane =
  Provider_tool_support.provider_supports_runtime_mcp_lane

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

let upsert_http_header ~key ~value headers =
  let key_lc = String.lowercase_ascii key in
  let retained =
    List.filter
      (fun (existing_key, _) ->
        not (String.equal (String.lowercase_ascii existing_key) key_lc))
      headers
  in
  (key, value) :: retained

let runtime_mcp_policy_with_masc_agent_name
    ~(agent_name : string)
    (policy : Llm_provider.Llm_transport.runtime_mcp_policy) =
  let agent_name = String.trim agent_name in
  if String.equal agent_name "" then policy
  else
    let servers =
      List.map
        (function
          | Llm_provider.Llm_transport.Http_server ({ name; headers; _ } as server)
            when String.equal name "masc" ->
              Llm_provider.Llm_transport.Http_server
                {
                  server with
                  headers =
                    upsert_http_header
                      ~key:"x-masc-agent-name"
                      ~value:agent_name headers;
                }
          | server -> server)
        policy.servers
    in
    { policy with servers }

let runtime_mcp_policy_without_http_headers
    (policy : Llm_provider.Llm_transport.runtime_mcp_policy) =
  let servers =
    List.map
      (function
        | Llm_provider.Llm_transport.Http_server server ->
            Llm_provider.Llm_transport.Http_server { server with headers = [] }
        | server -> server)
      policy.servers
  in
  { policy with servers }

let runtime_mcp_policy_for_provider
    ~(provider_cfg : Llm_provider.Provider_config.t)
    ~(agent_name : string)
    (policy_opt : Llm_provider.Llm_transport.runtime_mcp_policy option) =
  let agent_name =
    let trimmed = String.trim agent_name in
    if String.equal trimmed "" then None else Some trimmed
  in
  match policy_opt, provider_cfg.kind, agent_name with
  | Some policy, Llm_provider.Provider_config.Codex_cli, _ ->
      (* Codex CLI runtime MCP currently rejects per-request HTTP headers.
         Keep the runtime lane, but strip request-scoped headers so ambient
         env auth continues to work. *)
      Some (runtime_mcp_policy_without_http_headers policy)
  | Some policy, _, Some agent_name ->
      Some (runtime_mcp_policy_with_masc_agent_name ~agent_name policy)
  | Some policy, _, None -> Some policy
  | None, _, _ -> None

let kimi_cli_runtime_mcp_jsons
    ~(base : string list)
    (policy_opt : Llm_provider.Llm_transport.runtime_mcp_policy option) =
  let request_json =
    match policy_opt with
    | Some policy -> Option.to_list (kimi_mcp_config_json_of_policy policy)
    | None -> []
  in
  dedupe_preserve_order (base @ request_json)

let public_mcp_tool_names_of_oas_tools (tools : Oas.Tool.t list) =
  List.map (fun (tool : Oas.Tool.t) -> tool.schema.name) tools

let public_mcp_tools_of_oas_tools (tools : Oas.Tool.t list) =
  List.filter
    (fun (tool : Oas.Tool.t) -> Tool_catalog.is_public_mcp tool.schema.name)
    tools

let tool_names_are_public_mcp (tool_names : string list) =
  tool_names <> [] && List.for_all Tool_catalog.is_public_mcp tool_names

let trim_nonempty_string raw =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then None else Some trimmed

let trim_nonempty value =
  Option.bind value trim_nonempty_string

let first_nonempty_env names =
  List.find_map (fun name -> Sys.getenv_opt name |> trim_nonempty) names

let bearer_token_headers token =
  [ ("Authorization", "Bearer " ^ token) ]

let fallback_public_mcp_headers () =
  match first_nonempty_env [ "MASC_MCP_TOKEN" ] with
  | Some token -> bearer_token_headers token
  | None -> []

let keeper_public_mcp_headers ~agent_name =
  match Env_config_core.base_path_opt () with
  | Some base_path -> (
      match Auth.ensure_keeper_credential base_path ~agent_name with
      | Ok (token, _) -> bearer_token_headers token
      | Error err ->
          Log.warn ~ctx:"oas_worker_exec"
            "keeper MCP credential provisioning failed for %s: %s; falling back to MASC_MCP_TOKEN"
            agent_name (Types.masc_error_to_string err);
          fallback_public_mcp_headers ())
  | None -> fallback_public_mcp_headers ()

let public_mcp_runtime_policy_of_tool_names ?agent_name (tool_names : string list) :
    Llm_provider.Llm_transport.runtime_mcp_policy option =
  let tool_names = dedupe_preserve_order tool_names in
  if not (tool_names_are_public_mcp tool_names) then
    None
  else
    let masc_headers =
      match Option.bind agent_name trim_nonempty_string with
      | Some agent_name -> keeper_public_mcp_headers ~agent_name
      | None -> fallback_public_mcp_headers ()
    in
    Some
      {
        Llm_provider.Llm_transport.empty_runtime_mcp_policy with
        servers =
          [
            Llm_provider.Llm_transport.Http_server
              {
                name = "masc";
                url = Env_config_runtime.Local_runtime.mcp_url ();
                headers = masc_headers;
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

let kimi_cli_auth_value (provider_cfg : Llm_provider.Provider_config.t) =
  match trim_nonempty (Some provider_cfg.api_key) with
  | Some key -> Some key
  | None ->
      first_nonempty_env
        (Provider_adapter.auth_env_keys_of_provider_kind
           Llm_provider.Provider_config.Kimi)

let kimi_cli_base_url () =
  match Sys.getenv_opt "KIMI_BASE_URL" |> trim_nonempty with
  | Some url -> url
  | None -> "https://api.kimi.com/coding/v1"

let kimi_cli_config_json_for_provider
    (provider_cfg : Llm_provider.Provider_config.t) : string option =
  match kimi_cli_model_for_provider provider_cfg, kimi_cli_auth_value provider_cfg with
  | Some model_name, Some _ ->
      let provider_name = "masc-kimi" in
      let config_json =
        `Assoc
          [
            ("default_model", `String model_name);
            ( "providers",
              `Assoc
                [
                  ( provider_name,
                    `Assoc
                      [
                        ("type", `String "kimi");
                        ("base_url", `String (kimi_cli_base_url ()));
                        ("api_key", `String "");
                      ] );
                ] );
            ( "models",
              `Assoc
                [
                  ( model_name,
                    `Assoc
                      [
                        ("provider", `String provider_name);
                        ("model", `String model_name);
                        ("max_context_size", `Int 262144);
                      ] );
                ] );
          ]
      in
      Some (Yojson.Safe.to_string config_json)
  | _ -> None

let kimi_cli_extra_env (provider_cfg : Llm_provider.Provider_config.t) =
  match kimi_cli_auth_value provider_cfg with
  | Some key -> [ ("KIMI_API_KEY", key) ]
  | None -> []

let resolve_tool_lane_for_oas_tools
    ?agent_name
    ~(provider_cfg : Llm_provider.Provider_config.t)
    ~(tools : Oas.Tool.t list)
    ()
  : (Oas.Tool.t list
     * Llm_provider.Llm_transport.runtime_mcp_policy option,
     Oas.Error.sdk_error)
    result =
  let public_tools = public_mcp_tools_of_oas_tools tools in
  let public_tool_names = public_mcp_tool_names_of_oas_tools public_tools in
  let requested_agent_name =
    Option.bind agent_name trim_nonempty_string
  in
  let runtime_mcp_policy =
    public_mcp_runtime_policy_of_tool_names
      ?agent_name:requested_agent_name public_tool_names
    |> runtime_mcp_policy_for_provider ~provider_cfg
         ~agent_name:(Option.value ~default:"" requested_agent_name)
  in
  match runtime_mcp_policy with
  | Some runtime_mcp_policy
    when Provider_tool_support.provider_supports_runtime_mcp_policy
           provider_cfg runtime_mcp_policy ->
      Ok ([], Some runtime_mcp_policy)
  | _ when tools = [] ->
      Ok (tools, None)
  | _ when provider_supports_inline_tools provider_cfg ->
      Ok (tools, None)
  | _ ->
      let detail =
        let runtime_mcp_requires_http_headers =
          match runtime_mcp_policy with
          | Some policy ->
              Provider_tool_support.runtime_mcp_policy_requires_http_headers
                policy
          | None -> false
        in
        if public_tool_names <> []
           && runtime_mcp_requires_http_headers
           && provider_supports_runtime_mcp_lane provider_cfg
        then
          Printf.sprintf
            "%s does not support request-scoped runtime MCP HTTP headers required by public MCP tools"
            (provider_label provider_cfg)
        else if public_tool_names <> [] then
          Printf.sprintf
            "%s does not support inline tools or request-scoped runtime MCP tools"
            (provider_label provider_cfg)
        else
          Printf.sprintf "%s does not support inline tools"
            (provider_label provider_cfg)
      in
      Error (invalid_runtime_config "tool_support" detail)

module Kimi_cli_transport_local = struct
  type config = {
    kimi_path : string;
    model : string option;
    cwd : string option;
    config_json : string option;
    mcp_config_json : string list;
    extra_env : (string * string) list;
    cancel : unit Eio.Promise.t option;
  }

  let default_config =
    {
      kimi_path = "kimi";
      model = Some "kimi-for-coding";
      cwd = None;
      config_json = None;
      mcp_config_json = [];
      extra_env = [];
      cancel = None;
    }

  let default_prompt_argv_threshold = 512 * 1024

  let prompt_argv_threshold () =
    match Sys.getenv_opt "OAS_KIMI_PROMPT_ARGV_THRESHOLD" with
    | Some raw -> (
        match int_of_string_opt (String.trim raw) with
        | Some value when value >= 0 -> value
        | _ -> default_prompt_argv_threshold)
    | None -> default_prompt_argv_threshold

  let prompt_exceeds_argv_budget prompt =
    String.length prompt >= prompt_argv_threshold ()

  let stdin_for_prompt prompt =
    if prompt_exceeds_argv_budget prompt then Some prompt else None

  let cli_model_override ~(config : config)
      ~(req_config : Llm_provider.Provider_config.t) =
    match String.trim req_config.model_id |> String.lowercase_ascii with
    | "" | "auto" -> config.model
    | _ -> Some (String.trim req_config.model_id)

  let build_args ~(config : config)
      ~(req_config : Llm_provider.Provider_config.t)
      ~(mcp_config_json : string list)
      ~prompt =
    let prompt_via_stdin = prompt_exceeds_argv_budget prompt in
    let args =
      ref [ config.kimi_path; "--print"; "--output-format"; "stream-json" ]
    in
    let add xs = args := !args @ xs in
    (match config.config_json with
     | Some json -> add [ "--config"; json ]
     | None -> ());
    if not prompt_via_stdin then add [ "-p"; prompt ];
    (match cli_model_override ~config ~req_config with
     | Some model -> add [ "--model"; model ]
     | None -> ());
    (match config.cwd with
     | Some dir when String.trim dir <> "" -> add [ "--work-dir"; dir ]
     | None | Some _ -> ());
    List.iter (fun json -> add [ "--mcp-config"; json ]) mcp_config_json;
    (match req_config.enable_thinking with
     | Some true -> add [ "--thinking" ]
     | Some false -> add [ "--no-thinking" ]
     | None -> ());
    !args

  let json_of_argument_string = function
    | None | Some "" -> `Assoc []
    | Some raw -> (
        try Yojson.Safe.from_string raw with Yojson.Json_error _ -> `Assoc [])

  let blocks_of_message_content json =
    match json with
    | `String text when String.trim text = "" -> []
    | `String text -> [ Oas.Types.Text text ]
    | `List items ->
        List.filter_map Llm_provider.Api_common.content_block_of_json items
    | `Null -> []
    | other -> [ Oas.Types.Text (Yojson.Safe.to_string other) ]

  let tool_use_of_json json =
    let open Yojson.Safe.Util in
    try
      let fn = json |> member "function" in
      let id = Llm_provider.Cli_common_json.member_str "id" json in
      let name = Llm_provider.Cli_common_json.member_str "name" fn in
      let args =
        fn |> member "arguments" |> to_string_option |> json_of_argument_string
      in
      Some (Oas.Types.ToolUse { id; name; input = args })
    with Type_error _ -> None

  let tool_result_of_json json =
    let open Yojson.Safe.Util in
    match json |> member "tool_call_id" |> to_string_option with
    | Some tool_use_id ->
        let content_json = json |> member "content" in
        let content, parsed_json =
          match content_json with
          | `String text -> text, Oas.Types.try_parse_json text
          | `Null -> "", None
          | other -> Yojson.Safe.to_string other, Some other
        in
        Some
          (Oas.Types.ToolResult
             { tool_use_id; content; is_error = false; json = parsed_json })
    | None -> None

  let blocks_of_output_line line =
    let open Yojson.Safe.Util in
    try
      let json = Yojson.Safe.from_string line in
      match json |> member "role" |> to_string_option with
      | Some "assistant" ->
          let content = blocks_of_message_content (json |> member "content") in
          let tool_uses =
            match json |> member "tool_calls" with
            | `List calls -> List.filter_map tool_use_of_json calls
            | _ -> []
          in
          content @ tool_uses
      | Some "tool" -> (
          match tool_result_of_json json with
          | Some block -> [ block ]
          | None -> [])
      | _ -> []
    with Yojson.Json_error _ | Type_error _ -> []

  let response_id_of_lines lines =
    let open Yojson.Safe.Util in
    let find_id line =
      try
        let json = Yojson.Safe.from_string line in
        match json |> member "id" |> to_string_option with
        | Some id when String.trim id <> "" -> Some id
        | _ -> (
            match json |> member "session_id" |> to_string_option with
            | Some id when String.trim id <> "" -> Some id
            | _ -> None)
      with Yojson.Json_error _ | Type_error _ -> None
    in
    List.find_map find_id lines |> Option.value ~default:"kimi-print"

  let response_model_of_lines ~model_id lines =
    let open Yojson.Safe.Util in
    let find_model line =
      try
        let json = Yojson.Safe.from_string line in
        match json |> member "model" |> to_string_option with
        | Some model when String.trim model <> "" -> Some model
        | _ -> None
      with Yojson.Json_error _ | Type_error _ -> None
    in
    List.find_map find_model lines |> Option.value ~default:model_id

  let parse_jsonl_result ~model_id lines =
    let content = List.concat_map blocks_of_output_line lines in
    if content = [] then
      Error
        (Llm_provider.Http_client.NetworkError
           { message = "no messages parsed from kimi output"; kind = Unknown })
    else
      Ok
        {
          Oas.Types.id = response_id_of_lines lines;
          model = response_model_of_lines ~model_id lines;
          stop_reason = Oas.Types.EndTurn;
          content;
          usage = None;
          telemetry = None;
        }

  let events_of_block ~index = function
    | Oas.Types.Text text ->
        [
          Oas.Types.ContentBlockStart
            { index; content_type = "text"; tool_id = None; tool_name = None };
          Oas.Types.ContentBlockDelta { index; delta = Oas.Types.TextDelta text };
          Oas.Types.ContentBlockStop { index };
        ]
    | Oas.Types.Thinking { content; _ } ->
        [
          Oas.Types.ContentBlockStart
            {
              index;
              content_type = "thinking";
              tool_id = None;
              tool_name = None;
            };
          Oas.Types.ContentBlockDelta
            { index; delta = Oas.Types.ThinkingDelta content };
          Oas.Types.ContentBlockStop { index };
        ]
    | Oas.Types.ToolUse { id; name; input } ->
        [
          Oas.Types.ContentBlockStart
            {
              index;
              content_type = "tool_use";
              tool_id = Some id;
              tool_name = Some name;
            };
          Oas.Types.ContentBlockDelta
            {
              index;
              delta = Oas.Types.InputJsonDelta (Yojson.Safe.to_string input);
            };
          Oas.Types.ContentBlockStop { index };
        ]
    | Oas.Types.ToolResult { tool_use_id; content; _ } ->
        [
          Oas.Types.ContentBlockStart
            {
              index;
              content_type = "tool_result";
              tool_id = Some tool_use_id;
              tool_name = None;
            };
          Oas.Types.ContentBlockDelta
            { index; delta = Oas.Types.TextDelta content };
          Oas.Types.ContentBlockStop { index };
        ]
    | Oas.Types.RedactedThinking _
    | Oas.Types.Image _
    | Oas.Types.Document _
    | Oas.Types.Audio _ -> []

  let emit_blocks ~on_event ~start_index blocks =
    List.fold_left
      (fun index block ->
        match events_of_block ~index block with
        | [] -> index
        | events ->
            List.iter on_event events;
            index + 1)
      start_index blocks

  let starts_with text prefix =
    let prefix_len = String.length prefix in
    String.length text >= prefix_len
    && String.sub text 0 prefix_len = prefix

  let resumable_session_detail =
    "kimi_cli session limit exceeded (exit 75). Resumable session available via -r."

  let resume_hint_marker = "to resume this session:"
  let resumable_session_public_marker = "resumable session available via -r."
  let legacy_resumable_session_public_marker =
    "the session is resumable with -r flag."

  let is_resume_hint_line line =
    let trimmed = String.trim line in
    trimmed <> ""
    && String_util.contains_substring_ci trimmed resume_hint_marker

  let should_log_stderr_line line =
    let trimmed = String.trim line in
    trimmed <> ""
    && not (is_resume_hint_line trimmed)

  let on_stderr_line line =
    if should_log_stderr_line line then
      Llm_provider.Cli_common_subprocess.default_on_stderr_line
        ~name:"kimi" line

  let exit_code_of_message message =
    let prefix = "kimi exited with code " in
    if not (starts_with message prefix) then None
    else
      match String.index_from_opt message (String.length prefix) ':' with
      | None -> None
      | Some colon ->
          let raw =
            String.sub message (String.length prefix)
              (colon - String.length prefix)
            |> String.trim
          in
          int_of_string_opt raw

  let text_looks_like_resumable_session text =
    let trimmed = String.trim text in
    let has_raw_resume_hint =
      match exit_code_of_message trimmed with
      | Some 75 -> is_resume_hint_line trimmed
      | _ -> false
    in
    trimmed <> ""
    &&
    (has_raw_resume_hint
    || String_util.contains_substring_ci trimmed resumable_session_public_marker
    || String_util.contains_substring_ci trimmed legacy_resumable_session_public_marker)

  let resumable_session_detail_of_text text =
    if text_looks_like_resumable_session text then resumable_session_detail
    else String.trim text

  let resumable_session_exit_code_of_text text =
    match exit_code_of_message text with
    | Some 75 -> Some 75
    | _ when text_looks_like_resumable_session text -> Some 75
    | _ -> None

  let classify_cli_error = function
    | Error (Llm_provider.Http_client.NetworkError { message; _ }) as err -> (
        match exit_code_of_message message with
        | Some 1 ->
            Error
              (Llm_provider.Http_client.AcceptRejected
                 {
                   reason =
                     "kimi_cli rejected the request (exit 1). "
                     ^ "This is usually a permanent auth/config/model error rather "
                     ^ "than a transient transport failure. "
                     ^ message;
                 })
        | Some 75 ->
            Error
              (Llm_provider.Http_client.AcceptRejected
                 { reason = resumable_session_detail })
        | _ -> err)
    | other -> other

  let warn_external_tools_once warned tools =
    if !warned || tools = [] then ()
    else (
      warned := true;
      Eio.traceln
        "[warn] kimi_cli print mode ignores OAS req.tools. \
         Provider-native built-in tools and configured MCP servers remain \
         available; external OAS tool callbacks require a future wire-mode \
         transport.")

  let create ~sw ~(mgr : _ Eio.Process.mgr) ~(config : config) =
    let warned = ref false in
    {
      Llm_provider.Llm_transport.complete_sync =
        (fun (req : Llm_provider.Llm_transport.completion_request) ->
          warn_external_tools_once warned req.tools;
          let messages =
            Llm_provider.Cli_common_prompt.non_system_messages req.messages
          in
          let system_prompt =
            Llm_provider.Cli_common_prompt.system_prompt_of
              ~req_config:req.config req.messages
          in
          let prompt =
            Llm_provider.Cli_common_prompt.prompt_of_messages
              ~include_tool_blocks:true messages
            |> fun prompt ->
            Llm_provider.Cli_common_prompt.prompt_with_system_prompt
              ~prompt ~system_prompt
          in
          let model_id =
            Option.value ~default:"kimi-for-coding"
              (cli_model_override ~config ~req_config:req.config)
          in
          let mcp_config_json =
            kimi_cli_runtime_mcp_jsons ~base:config.mcp_config_json
              req.runtime_mcp_policy
          in
          let argv =
            build_args ~config ~req_config:req.config ~mcp_config_json ~prompt
          in
          let seen_lines = ref [] in
          let on_line line =
            if String.trim line <> "" then seen_lines := line :: !seen_lines
          in
          match
            Llm_provider.Cli_common_subprocess.run_stream_lines ~sw ~mgr
              ~name:"kimi" ~cwd:config.cwd ~extra_env:config.extra_env
              ~on_stderr_line
              ?stdin_content:(stdin_for_prompt prompt)
              ~on_line ?cancel:config.cancel argv
          with
          | Error _ as err ->
              { Llm_provider.Llm_transport.response = classify_cli_error err; latency_ms = 0 }
          | Ok { latency_ms; _ } ->
              let response =
                parse_jsonl_result ~model_id (List.rev !seen_lines)
              in
              { Llm_provider.Llm_transport.response; latency_ms });
      complete_stream =
        (fun ~on_event (req : Llm_provider.Llm_transport.completion_request) ->
          warn_external_tools_once warned req.tools;
          let messages =
            Llm_provider.Cli_common_prompt.non_system_messages req.messages
          in
          let system_prompt =
            Llm_provider.Cli_common_prompt.system_prompt_of
              ~req_config:req.config req.messages
          in
          let prompt =
            Llm_provider.Cli_common_prompt.prompt_of_messages
              ~include_tool_blocks:true messages
            |> fun prompt ->
            Llm_provider.Cli_common_prompt.prompt_with_system_prompt
              ~prompt ~system_prompt
          in
          let model_id =
            Option.value ~default:"kimi-for-coding"
              (cli_model_override ~config ~req_config:req.config)
          in
          let mcp_config_json =
            kimi_cli_runtime_mcp_jsons ~base:config.mcp_config_json
              req.runtime_mcp_policy
          in
          let argv =
            build_args ~config ~req_config:req.config ~mcp_config_json ~prompt
          in
          let seen_lines = ref [] in
          let next_index = ref 0 in
          let started = ref false in
          let ensure_started () =
            if not !started then (
              started := true;
              on_event
                (Oas.Types.MessageStart
                   { id = "kimi-print"; model = model_id; usage = None }))
          in
          let on_line line =
            if String.trim line <> "" then (
              seen_lines := line :: !seen_lines;
              let blocks = blocks_of_output_line line in
              if blocks <> [] then (
                ensure_started ();
                next_index :=
                  emit_blocks ~on_event ~start_index:!next_index blocks))
          in
          match
            classify_cli_error
              (Llm_provider.Cli_common_subprocess.run_stream_lines ~sw ~mgr
                 ~name:"kimi" ~cwd:config.cwd ~extra_env:config.extra_env
                 ~on_stderr_line
                 ?stdin_content:(stdin_for_prompt prompt)
                 ~on_line ?cancel:config.cancel argv)
          with
          | Error _ as err -> err
          | Ok _ -> (
              match parse_jsonl_result ~model_id (List.rev !seen_lines) with
              | Error _ as err -> err
              | Ok resp as ok ->
                  if !started then (
                    on_event
                      (Oas.Types.MessageDelta
                         { stop_reason = Some resp.stop_reason; usage = resp.usage });
                    on_event Oas.Types.MessageStop)
                  else
                    Llm_provider.Cli_common_synthetic_events.replay ~on_event
                      resp;
                  ok));
    }
end

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
    ?runtime_mcp_policy
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
          let cwd =
            Option.bind cli_transport_overrides (fun overrides -> overrides.cwd)
          in
          let mcp_config_json =
            kimi_cli_runtime_mcp_jsons ~base:[] runtime_mcp_policy
          in
          let model = kimi_cli_model_for_provider provider_cfg in
          let config_json = kimi_cli_config_json_for_provider provider_cfg in
          let extra_env = kimi_cli_extra_env provider_cfg in
          let config =
            {
              Kimi_cli_transport_local.default_config with
              model;
              cwd;
              config_json;
              mcp_config_json;
              extra_env;
            }
          in
          Ok
            (Some
               (make_per_call_switch_transport (fun ~sw ->
                    Kimi_cli_transport_local.create ~sw ~mgr
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
