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
let claude_code_max_turns_hard_cap =
  Llm_provider.Provider_config.max_turns_hard_cap
    Llm_provider.Provider_config.Claude_code
  |> Option.value ~default:30
;;

let provider_effective_max_turns _kind requested = requested

(* #10097: codex_cli can only expose keeper-bound runtime MCP tools when the
   keeper has a raw bearer token that OAS can route through bearer_token_env_var.
   Missing-token omissions are still a structural lane/auth setup issue, not a
   per-call incident:

     - [WARN] emits only when an agent first sees an omitted-tool
       fingerprint, or when that agent's omitted tool set changes.
     - [Prometheus] per-tool counters increment on every omission so
       dashboards retain the frequency signal.

   Fingerprint = sorted, comma-joined tool list.  Stdlib.Mutex guards
   concurrent access from heartbeat/turn fibers across domains. *)
(* Codex CLI tool-omission warning dedup extracted to
   [Cascade_transport_codex_omission_dedup] (godfile decomp).
   Public surface preserved via per-function aliases below. *)
module Codex_omission_dedup = Cascade_transport_codex_omission_dedup

let codex_cli_omission_fingerprint = Codex_omission_dedup.codex_cli_omission_fingerprint

let codex_cli_omission_fingerprint_seen =
  Codex_omission_dedup.codex_cli_omission_fingerprint_seen
;;

let reset_codex_cli_omission_dedup_for_tests =
  Codex_omission_dedup.reset_codex_cli_omission_dedup_for_tests
;;

let record_codex_cli_omission_for_agent =
  Codex_omission_dedup.record_codex_cli_omission_for_agent
;;

let record_codex_cli_omission = Codex_omission_dedup.record_codex_cli_omission

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
(* trim_nonempty + first_nonempty_env + runtime-MCP policy header helpers
   extracted to [Cascade_transport_mcp_policy_helpers] (godfile decomp). *)
let trim_nonempty = Cascade_transport_mcp_policy_helpers.trim_nonempty
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
let codex_cli_can_auth_keeper_bound_runtime_mcp = Cascade_transport_auth_bridging.codex_cli_can_auth_keeper_bound_runtime_mcp
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

let trim_nonempty_string raw =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then None else Some trimmed
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
  let requested_agent_name = Option.bind agent_name trim_nonempty_string in
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
  let codex_can_auth_keeper_bound_actor_tools =
    match requested_agent_name with
    | Some agent_name
      when requires_per_keeper_bridging
           && Option.is_some (keeper_name_of_agent_name agent_name) ->
      Option.is_some (per_keeper_authorization_header ~agent_name)
    | _ -> false
  in
  let codex_keeper_bound_actor_tools =
    match requested_agent_name with
    | Some agent_name
      when requires_per_keeper_bridging
           && Option.is_some (keeper_name_of_agent_name agent_name)
           && not codex_can_auth_keeper_bound_actor_tools ->
      List.filter
        runtime_mcp_tool_requires_bound_actor
        (public_tool_names @ keeper_internal_tool_names)
    | _ -> []
  in
  (* #10097: WARN once per distinct fingerprint + always-emit
     per-tool counter.  See [record_codex_cli_omission] docs. *)
  record_codex_cli_omission_for_agent
    ~agent_name:requested_agent_name
    ~tools:codex_keeper_bound_actor_tools;
  if tool_requirement = `Required && codex_keeper_bound_actor_tools <> []
  then (
    let detail =
      Printf.sprintf
        "%s cannot satisfy required keeper-bound runtime MCP tools omitted by codex_cli: \
         %s"
        (provider_label provider_cfg)
        (String.concat ", " (List.sort String.compare codex_keeper_bound_actor_tools))
    in
    Error (invalid_runtime_config "tool_support" detail))
  else (
    let public_tool_names =
      if codex_keeper_bound_actor_tools = []
      then public_tool_names
      else
        List.filter
          (fun tool_name -> not (public_mcp_tool_requires_bound_actor tool_name))
          public_tool_names
    in
    let keeper_internal_tool_names =
      if codex_keeper_bound_actor_tools = []
      then keeper_internal_tool_names
      else
        List.filter
          (fun tool_name -> not (runtime_mcp_tool_requires_bound_actor tool_name))
          keeper_internal_tool_names
    in
    let runtime_tool_names =
      dedupe_preserve_order (public_tool_names @ keeper_internal_tool_names)
    in
    (* #12676: When all tools were bound-actor and got stripped for codex_cli
       on an optional turn, runtime_tool_names is empty. The keeper may still
       use an MCP connection for discovery, so build a minimal connect-only
       policy with the server URL and auth but no allowed_tool_names. Required
       turns reject above because a zero-tool policy cannot satisfy the tool
       contract. *)
    let runtime_mcp_policy =
      if runtime_tool_names = [] && codex_keeper_bound_actor_tools <> []
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

module Json_stream_cli_transport_local = struct
  type config =
    { cli_path : string
    ; process_name : string
    ; model : string option
    ; cwd : string option
    ; config_json : string option
    ; mcp_config_json : string list
    ; extra_env : (string * string) list
    ; cancel : unit Eio.Promise.t option
    ; stdout_idle_timeout_s : float option
    }

  let default_config =
    { cli_path = "json-stream-cli"
    ; process_name = "json_stream_cli"
    ; model = None
    ; cwd = None
    ; config_json = None
    ; mcp_config_json = []
    ; extra_env = []
    ; cancel = None
    ; stdout_idle_timeout_s = None
    }
  ;;

  (* Some Python CLI launchers import [setproctitle] before processing the
     request. UTF-8 prompts in argv can make setproctitle's import-time
     [getproctitle()] decode fail before the CLI reads the prompt, so keep
     non-ASCII or large prompts out of argv and stream them via stdin. *)
  let default_prompt_argv_threshold = 16 * 1024

  let prompt_argv_threshold () =
    match Sys.getenv_opt "MASC_JSON_STREAM_CLI_PROMPT_ARGV_THRESHOLD" with
    | Some raw ->
      (match int_of_string_opt (String.trim raw) with
       | Some value when value >= 0 -> value
       | _ -> default_prompt_argv_threshold)
    | None -> default_prompt_argv_threshold
  ;;

  let prompt_exceeds_argv_budget prompt = String.length prompt >= prompt_argv_threshold ()

  let prompt_contains_non_ascii prompt =
    let rec loop idx =
      idx < String.length prompt && (Char.code prompt.[idx] > 0x7f || loop (idx + 1))
    in
    loop 0
  ;;

  let prompt_needs_stdin prompt =
    prompt_exceeds_argv_budget prompt || prompt_contains_non_ascii prompt
  ;;

  let sanitize_for_cli_prompt prompt = Inference_utils.sanitize_text_utf8 prompt

  let stdin_for_prompt prompt =
    let prompt = sanitize_for_cli_prompt prompt in
    if prompt_needs_stdin prompt then Some prompt else None
  ;;

  let cli_model_override ~(config : config) ~(req_config : Llm_provider.Provider_config.t)
    =
    match String.trim req_config.model_id |> String.lowercase_ascii with
    | "" | "auto" -> config.model
    | _ -> Some (String.trim req_config.model_id)
  ;;

  let build_args
        ~(config : config)
        ~(req_config : Llm_provider.Provider_config.t)
        ~(mcp_config_json : string list)
        ~prompt
    =
    let prompt = sanitize_for_cli_prompt prompt in
    let prompt_via_stdin = prompt_needs_stdin prompt in
    let args = ref [ config.cli_path; "--print"; "--output-format"; "stream-json" ] in
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
  ;;

  let json_of_argument_string = function
    | None | Some "" -> Ok (`Assoc [])
    | Some raw ->
      let raw = String.trim raw in
      if raw = ""
      then Ok (`Assoc [])
      else (
        try Ok (Yojson.Safe.from_string raw) with
        | Yojson.Json_error msg -> Error msg)
  ;;

  let blocks_of_message_content json =
    match json with
    | `String text when String.trim text = "" -> []
    | `String text -> [ Agent_sdk.Types.Text text ]
    | `List items -> List.filter_map Llm_provider.Api_common.content_block_of_json items
    | `Null -> []
    | other -> [ Agent_sdk.Types.Text (Yojson.Safe.to_string other) ]
  ;;

  let tool_use_of_json json =
    let open Yojson.Safe.Util in
    try
      let fn = json |> member "function" in
      let id = Llm_provider.Cli_common_json.member_str "id" json in
      let name = Llm_provider.Cli_common_json.member_str "name" fn in
      match fn |> member "arguments" |> to_string_option |> json_of_argument_string with
      | Ok args -> Ok (Some (Agent_sdk.Types.ToolUse { id; name; input = args }))
      | Error msg ->
        Error
          (Printf.sprintf "invalid CLI tool arguments JSON for tool %S: %s" name msg)
    with
    | Type_error _ -> Ok None
  ;;

  let tool_uses_of_json calls =
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | call :: rest ->
        (match tool_use_of_json call with
         | Ok (Some block) -> loop (block :: acc) rest
         | Ok None -> loop acc rest
         | Error _ as err -> err)
    in
    loop [] calls
  ;;

  let tool_result_of_json json =
    let open Yojson.Safe.Util in
    match json |> member "tool_call_id" |> to_string_option with
    | Some tool_use_id ->
      let content_json = json |> member "content" in
      let content, parsed_json =
        match content_json with
        | `String text -> text, Agent_sdk.Types.try_parse_json text
        | `Null -> "", None
        | other -> Yojson.Safe.to_string other, Some other
      in
      Some
        (Agent_sdk.Types.ToolResult
           { tool_use_id; content; is_error = false; json = parsed_json })
    | None -> None
  ;;

  let parse_json_line line =
    Yojson.Safe.from_string (Inference_utils.sanitize_text_utf8 line)
  ;;

  let blocks_of_output_line line =
    let open Yojson.Safe.Util in
    try
      let json = parse_json_line line in
      match json |> member "role" |> to_string_option with
      | Some "assistant" ->
        let content = blocks_of_message_content (json |> member "content") in
        let tool_uses_result =
          match json |> member "tool_calls" with
          | `List calls -> tool_uses_of_json calls
          | _ -> Ok []
        in
        Result.map (fun tool_uses -> content @ tool_uses) tool_uses_result
      | Some "tool" ->
        (match tool_result_of_json json with
         | Some block -> Ok [ block ]
         | None -> Ok [])
      | _ -> Ok []
    with
    | Yojson.Json_error _ | Type_error _ -> Ok []
  ;;

  let response_id_of_lines lines =
    let open Yojson.Safe.Util in
    let find_id line =
      try
        let json = parse_json_line line in
        match json |> member "id" |> to_string_option with
        | Some id when String.trim id <> "" -> Some id
        | _ ->
          (match json |> member "session_id" |> to_string_option with
           | Some id when String.trim id <> "" -> Some id
           | _ -> None)
      with
      | Yojson.Json_error _ | Type_error _ -> None
    in
    List.find_map find_id lines |> Option.value ~default:"cli-json-stream"
  ;;

  let response_model_of_lines ~model_id lines =
    let open Yojson.Safe.Util in
    let find_model line =
      try
        let json = parse_json_line line in
        match json |> member "model" |> to_string_option with
        | Some model when String.trim model <> "" -> Some model
        | _ -> None
      with
      | Yojson.Json_error _ | Type_error _ -> None
    in
    List.find_map find_model lines |> Option.value ~default:model_id
  ;;

  let parse_jsonl_result ~model_id lines =
    let content_result =
      let rec loop acc = function
        | [] -> Ok (List.concat (List.rev acc))
        | line :: rest ->
          (match blocks_of_output_line line with
           | Ok blocks -> loop (blocks :: acc) rest
           | Error _ as err -> err)
      in
      loop [] lines
    in
    match content_result with
    | Error message ->
      Error (Llm_provider.Http_client.NetworkError { message; kind = Unknown })
    | Ok [] ->
      Error
        (Llm_provider.Http_client.NetworkError
           { message = "no messages parsed from CLI JSON-stream output"; kind = Unknown })
    | Ok content ->
      Ok
        { Agent_sdk.Types.id = response_id_of_lines lines
        ; model = response_model_of_lines ~model_id lines
        ; stop_reason = Agent_sdk.Types.EndTurn
        ; content
        ; usage = None
        ; telemetry = None
        }
  ;;

  let events_of_block ~index = function
    | Agent_sdk.Types.Text text ->
      [ Agent_sdk.Types.ContentBlockStart
          { index; content_type = "text"; tool_id = None; tool_name = None }
      ; Agent_sdk.Types.ContentBlockDelta
          { index; delta = Agent_sdk.Types.TextDelta text }
      ; Agent_sdk.Types.ContentBlockStop { index }
      ]
    | Agent_sdk.Types.Thinking { content; _ } ->
      [ Agent_sdk.Types.ContentBlockStart
          { index; content_type = "thinking"; tool_id = None; tool_name = None }
      ; Agent_sdk.Types.ContentBlockDelta
          { index; delta = Agent_sdk.Types.ThinkingDelta content }
      ; Agent_sdk.Types.ContentBlockStop { index }
      ]
    | Agent_sdk.Types.ToolUse { id; name; input } ->
      [ Agent_sdk.Types.ContentBlockStart
          { index; content_type = "tool_use"; tool_id = Some id; tool_name = Some name }
      ; Agent_sdk.Types.ContentBlockDelta
          { index; delta = Agent_sdk.Types.InputJsonDelta (Yojson.Safe.to_string input) }
      ; Agent_sdk.Types.ContentBlockStop { index }
      ]
    | Agent_sdk.Types.ToolResult { tool_use_id; content; _ } ->
      [ Agent_sdk.Types.ContentBlockStart
          { index
          ; content_type = "tool_result"
          ; tool_id = Some tool_use_id
          ; tool_name = None
          }
      ; Agent_sdk.Types.ContentBlockDelta
          { index; delta = Agent_sdk.Types.TextDelta content }
      ; Agent_sdk.Types.ContentBlockStop { index }
      ]
    | Agent_sdk.Types.RedactedThinking _
    | Agent_sdk.Types.Image _
    | Agent_sdk.Types.Document _
    | Agent_sdk.Types.Audio _ -> []
  ;;

  let emit_blocks ~on_event ~start_index blocks =
    List.fold_left
      (fun index block ->
         match events_of_block ~index block with
         | [] -> index
         | events ->
           List.iter on_event events;
           index + 1)
      start_index
      blocks
  ;;

  let starts_with text prefix = String.starts_with ~prefix text

  let resumable_session_detail =
    "CLI JSON-stream transport reported a resumable session. Resumable session \
     available via -r."
  ;;

  let resume_hint_marker = "to resume this session:"
  let resumable_session_public_marker = "resumable session available via -r."
  let legacy_resumable_session_public_marker = "the session is resumable with -r flag."

  let is_resume_hint_line line =
    let trimmed = String.trim line in
    trimmed <> "" && String_util.contains_substring_ci trimmed resume_hint_marker
  ;;

  let should_log_stderr_line line =
    let trimmed = String.trim line in
    trimmed <> "" && not (is_resume_hint_line trimmed)
  ;;

  let on_stderr_line ~process_name line =
    if should_log_stderr_line line
    then
      Llm_provider.Cli_common_subprocess.default_on_stderr_line ~name:process_name line
  ;;

  let index_of_substring text marker =
    let marker_len = String.length marker in
    let text_len = String.length text in
    let rec loop idx =
      if marker_len = 0
      then Some idx
      else if idx + marker_len > text_len
      then None
      else if String.sub text idx marker_len = marker
      then Some idx
      else loop (idx + 1)
    in
    loop 0
  ;;

  let exit_code_span_of_message message =
    let marker = " exited with code " in
    match index_of_substring message marker with
    | None -> None
    | Some marker_start ->
      let code_start = marker_start + String.length marker in
      (match String.index_from_opt message code_start ':' with
       | None -> None
       | Some colon ->
         let raw = String.sub message code_start (colon - code_start) |> String.trim in
         Option.map (fun code -> code, colon) (int_of_string_opt raw))
  ;;

  let exit_code_of_message message =
    Option.map fst (exit_code_span_of_message message)
  ;;

  let exit_code_marker_of_text text =
    let marker = "(exit " in
    let lower = String.lowercase_ascii text in
    let marker_len = String.length marker in
    let text_len = String.length lower in
    let rec find_marker index =
      if index + marker_len > text_len
      then None
      else if String.sub lower index marker_len = marker
      then (
        let number_start = index + marker_len in
        match String.index_from_opt lower number_start ')' with
        | Some number_end when number_end > number_start ->
          String.sub lower number_start (number_end - number_start)
          |> String.trim
          |> int_of_string_opt
        | _ -> None)
      else find_marker (index + 1)
    in
    find_marker 0
  ;;

  let exit_payload_of_message message =
    match exit_code_span_of_message message with
    | None -> None
    | Some (_, colon) ->
      Some
        (String.sub message (colon + 1) (String.length message - colon - 1)
         |> String.trim)
  ;;

  let payload_has_only_resume_hint payload =
    payload
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun line -> line <> "")
    |> fun lines -> lines <> [] && List.for_all is_resume_hint_line lines
  ;;

  let text_looks_like_resumable_session text =
    let trimmed = String.trim text in
    let has_raw_resume_hint =
      match exit_code_of_message trimmed with
      | Some 75 -> is_resume_hint_line trimmed
      | Some 1 ->
        (match exit_payload_of_message trimmed with
         | Some payload -> payload_has_only_resume_hint payload
         | None -> false)
      | _ -> false
    in
    trimmed <> ""
    && (has_raw_resume_hint
        || String_util.contains_substring_ci trimmed resumable_session_public_marker
        || String_util.contains_substring_ci
             trimmed
             legacy_resumable_session_public_marker)
  ;;

  let resumable_session_detail_of_text text =
    if text_looks_like_resumable_session text
    then (
      let trimmed = String.trim text in
      match
        match exit_code_of_message trimmed with
        | Some code -> Some code
        | None -> exit_code_marker_of_text trimmed
      with
      | Some code ->
        Printf.sprintf
          "CLI JSON-stream transport reported a resumable session (exit %d). \
           Resumable session available via -r."
          code
      | None -> resumable_session_detail)
    else String.trim text
  ;;

  let resumable_session_exit_code_of_text text =
    match exit_code_of_message text with
    | Some (75 as code) -> Some code
    | Some (1 as code) when text_looks_like_resumable_session text -> Some code
    | _ when text_looks_like_resumable_session text -> exit_code_marker_of_text text
    | _ -> None
  ;;

  let text_looks_like_process_title_unicode_crash text =
    String_util.contains_substring_ci text "UnicodeDecodeError"
    && String_util.contains_substring_ci text "setproctitle"
  ;;

  let classify_cli_error = function
    | Error (Llm_provider.Http_client.NetworkError { message; _ }) as err ->
      if text_looks_like_resumable_session message
      then
        Error
          (Llm_provider.Http_client.AcceptRejected
             { reason = resumable_session_detail_of_text message })
      else if text_looks_like_process_title_unicode_crash message
      then
        Error
          (Llm_provider.Http_client.AcceptRejected
             { reason =
                 "provider CLI startup crash while setting process title \
                  (UnicodeDecodeError). This is a local CLI/runtime failure, not keeper \
                  auth or sandbox failure; rejecting without retry so the cascade can \
                  move on. "
                 ^ message
             })
      else (
        match exit_code_of_message message with
        | Some 1 ->
          Error
            (Llm_provider.Http_client.AcceptRejected
               { reason =
                   "provider CLI rejected the request (exit 1). "
                   ^ "This is usually a permanent auth/config/model error rather "
                   ^ "than a transient transport failure. "
                   ^ message
               })
        | Some 75 ->
          Error
            (Llm_provider.Http_client.AcceptRejected
               { reason = resumable_session_detail_of_text message })
        | _ -> err)
    | other -> other
  ;;

  let warn_external_tools_once warned tools =
    if !warned || tools = []
    then ()
    else (
      warned := true;
      Log.Misc.warn
        "CLI JSON-stream print mode ignores OAS req.tools. Provider-native built-in tools and \
         configured MCP servers remain available; external OAS tool callbacks require a \
         future wire-mode transport.")
  ;;

  let create ~sw ~(mgr : _ Eio.Process.mgr) ~(config : config) =
    let warned = ref false in
    { Llm_provider.Llm_transport.complete_sync =
        (fun (req : Llm_provider.Llm_transport.completion_request) ->
          warn_external_tools_once warned req.tools;
          let messages =
            Llm_provider.Cli_common_prompt.non_system_messages req.messages
          in
          let system_prompt =
            Llm_provider.Cli_common_prompt.system_prompt_of
              ~req_config:req.config
              req.messages
          in
          let prompt =
            Llm_provider.Cli_common_prompt.prompt_of_messages
              ~include_tool_blocks:true
              messages
            |> fun prompt ->
            Llm_provider.Cli_common_prompt.prompt_with_system_prompt
              ~prompt
              ~system_prompt
          in
          let prompt = sanitize_for_cli_prompt prompt in
          let model_id =
            match cli_model_override ~config ~req_config:req.config with
            | Some model -> model
            | None -> req.config.model_id
          in
          let mcp_config_json =
            cli_runtime_mcp_jsons ~base:config.mcp_config_json req.runtime_mcp_policy
          in
          let argv = build_args ~config ~req_config:req.config ~mcp_config_json ~prompt in
          let seen_lines = ref [] in
          let on_line line =
            if String.trim line <> "" then seen_lines := line :: !seen_lines
          in
          let stdout_idle_timeout_s = config.stdout_idle_timeout_s in
          let clock_opt =
            match stdout_idle_timeout_s with
            | None -> None
            | Some _ ->
              (match Process_eio.get_clock () with
               | Ok c -> Some c
               | Error _ -> None)
          in
          let run_result, measured_latency_ms =
            Inference_utils.timed (fun () ->
              Llm_provider.Cli_common_subprocess.run_stream_lines
                ~sw
                ~mgr
                ?clock:clock_opt
                ?stdout_idle_timeout_s
                ~name:config.process_name
                ~cwd:config.cwd
                ~extra_env:config.extra_env
                ~on_stderr_line:(on_stderr_line ~process_name:config.process_name)
                ?stdin_content:(stdin_for_prompt prompt)
                ~on_line
                ?cancel:config.cancel
                argv)
          in
          match run_result with
          | Error _ as err ->
            { Llm_provider.Llm_transport.response = classify_cli_error err
            ; latency_ms = Some measured_latency_ms
            }
          | Ok { latency_ms; _ } ->
            let response = parse_jsonl_result ~model_id (List.rev !seen_lines) in
            { Llm_provider.Llm_transport.response; latency_ms = Some latency_ms })
    ; complete_stream =
        (fun ?on_telemetry:_
          ~on_event
          (req : Llm_provider.Llm_transport.completion_request) ->
          warn_external_tools_once warned req.tools;
          let messages =
            Llm_provider.Cli_common_prompt.non_system_messages req.messages
          in
          let system_prompt =
            Llm_provider.Cli_common_prompt.system_prompt_of
              ~req_config:req.config
              req.messages
          in
          let prompt =
            Llm_provider.Cli_common_prompt.prompt_of_messages
              ~include_tool_blocks:true
              messages
            |> fun prompt ->
            Llm_provider.Cli_common_prompt.prompt_with_system_prompt
              ~prompt
              ~system_prompt
          in
          let prompt = sanitize_for_cli_prompt prompt in
          let model_id =
            match cli_model_override ~config ~req_config:req.config with
            | Some model -> model
            | None -> req.config.model_id
          in
          let mcp_config_json =
            cli_runtime_mcp_jsons ~base:config.mcp_config_json req.runtime_mcp_policy
          in
          let argv = build_args ~config ~req_config:req.config ~mcp_config_json ~prompt in
          let seen_lines = ref [] in
          let next_index = ref 0 in
          let started = ref false in
          let parse_error = ref None in
          let ensure_started () =
            if not !started
            then (
              started := true;
              on_event
                (Agent_sdk.Types.MessageStart
                   { id = "cli-json-stream"; model = model_id; usage = None }))
          in
          let on_line line =
            match !parse_error with
            | Some _ -> ()
            | None ->
              if String.trim line <> ""
              then (
                seen_lines := line :: !seen_lines;
                match blocks_of_output_line line with
                | Error message -> parse_error := Some message
                | Ok blocks ->
                  if blocks <> []
                  then (
                    ensure_started ();
                    next_index := emit_blocks ~on_event ~start_index:!next_index blocks))
          in
          let stdout_idle_timeout_s = config.stdout_idle_timeout_s in
          let clock_opt =
            match stdout_idle_timeout_s with
            | None -> None
            | Some _ ->
              (match Process_eio.get_clock () with
               | Ok c -> Some c
               | Error _ -> None)
          in
          match
            classify_cli_error
              (Llm_provider.Cli_common_subprocess.run_stream_lines
                 ~sw
                 ~mgr
                 ?clock:clock_opt
                 ?stdout_idle_timeout_s
                 ~name:config.process_name
                 ~cwd:config.cwd
                 ~extra_env:config.extra_env
                 ~on_stderr_line:(on_stderr_line ~process_name:config.process_name)
                 ?stdin_content:(stdin_for_prompt prompt)
                 ~on_line
                 ?cancel:config.cancel
                 argv)
          with
          | Error _ as err -> err
          | Ok _ ->
            (match !parse_error with
             | Some message ->
               Error (Llm_provider.Http_client.NetworkError { message; kind = Unknown })
             | None ->
               (match parse_jsonl_result ~model_id (List.rev !seen_lines) with
                | Error _ as err -> err
                | Ok resp as ok ->
                  if !started
                  then (
                    on_event
                      (Agent_sdk.Types.MessageDelta
                         { stop_reason = Some resp.stop_reason; usage = resp.usage });
                    on_event Agent_sdk.Types.MessageStop)
                  else Llm_provider.Cli_common_synthetic_events.replay ~on_event resp;
                  ok)))
    }
  ;;
end

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
