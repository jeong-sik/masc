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

(* #10097: codex_cli omits keeper-bound runtime MCP tools that require
   request-scoped auth headers.  That omission is a structural provider
   limitation, not a per-call incident:

     - [WARN] emits only when an agent first sees an omitted-tool
       fingerprint, or when that agent's omitted tool set changes.
     - [Prometheus] per-tool counters increment on every omission so
       dashboards retain the frequency signal.

   Fingerprint = sorted, comma-joined tool list.  Stdlib.Mutex guards
   concurrent access from heartbeat/turn fibers across domains. *)
let codex_omission_state_mu = Stdlib.Mutex.create ()
let codex_omission_state : (string, string) Hashtbl.t = Hashtbl.create 16

let codex_cli_omission_fingerprint (tools : string list) : string =
  tools
  |> List.sort String.compare
  |> String.concat ","

let codex_omission_agent_key = function
  | Some agent_name ->
      let agent_name = String.trim agent_name in
      if String.equal agent_name "" then "<no_agent>" else agent_name
  | None -> "<no_agent>"

let codex_omission_should_log ~agent_name ~tool_fingerprint =
  Stdlib.Mutex.lock codex_omission_state_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock codex_omission_state_mu)
    (fun () ->
       match Hashtbl.find_opt codex_omission_state agent_name with
       | Some prev when String.equal prev tool_fingerprint -> false
       | _ ->
         Hashtbl.replace codex_omission_state agent_name tool_fingerprint;
         true)

let codex_cli_omission_fingerprint_seen fingerprint =
  not
    (codex_omission_should_log ~agent_name:"<no_agent>"
       ~tool_fingerprint:fingerprint)

(* For tests: reset the dedup state so each test starts clean. *)
let reset_codex_cli_omission_dedup_for_tests () =
  Stdlib.Mutex.lock codex_omission_state_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock codex_omission_state_mu)
    (fun () -> Hashtbl.clear codex_omission_state)

let record_codex_cli_omission_for_agent
    ~(agent_name : string option)
    ~(tools : string list)
  : unit =
  match tools with
  | [] -> ()
  | _ ->
    List.iter (fun tool ->
      Prometheus.inc_counter
        Prometheus.metric_codex_cli_mcp_tool_omission
        ~labels:[ ("tool", tool) ] ())
      tools;
    let tool_fingerprint = codex_cli_omission_fingerprint tools in
    let agent_name_key = codex_omission_agent_key agent_name in
    if
      codex_omission_should_log ~agent_name:agent_name_key
        ~tool_fingerprint
    then
      Log.warn ~ctx:"oas_worker_exec"
        "codex_cli omitting keeper-bound runtime MCP tool(s) that \
         require request-scoped auth headers: %s \
         (structural provider limitation for %s; subsequent omissions \
         of this same set are counted in \
         masc_codex_cli_mcp_tool_omission_total and not re-logged)"
        (String.concat ", " (List.sort String.compare tools))
        agent_name_key

let record_codex_cli_omission ~(tools : string list) : unit =
  record_codex_cli_omission_for_agent ~agent_name:None ~tools

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

let trim_nonempty value =
  match value with
  | Some raw ->
      let trimmed = String.trim raw in
      if String.equal trimmed "" then None else Some trimmed
  | None -> None

let first_nonempty_env names =
  List.find_map (fun name -> Sys.getenv_opt name |> trim_nonempty) names

let keeper_name_of_agent_name agent_name =
  let prefix = "keeper-" in
  let suffix = "-agent" in
  let value = String.trim agent_name in
  let vlen = String.length value in
  let plen = String.length prefix in
  let slen = String.length suffix in
  if
    vlen > plen + slen
    && String.sub value 0 plen = prefix
    && String.sub value (vlen - slen) slen = suffix
  then
    Some (String.sub value plen (vlen - plen - slen))
  else
    None

let runtime_mcp_policy_with_masc_agent_name
    ?(include_internal_token = true)
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
              let headers =
                upsert_http_header
                  ~key:"x-masc-agent-name"
                  ~value:agent_name headers
              in
              let headers =
                if include_internal_token then
                  match
                    ( first_nonempty_env [ "MASC_INTERNAL_MCP_TOKEN" ],
                      keeper_name_of_agent_name agent_name )
                  with
                  | Some token, Some _ ->
                      upsert_http_header
                        ~key:"x-masc-internal-token"
                        ~value:token headers
                  | _ -> headers
                else headers
              in
              let headers =
                match keeper_name_of_agent_name agent_name with
                | Some keeper_name ->
                    upsert_http_header
                      ~key:"x-masc-keeper-name"
                      ~value:keeper_name headers
                | None -> headers
              in
              Llm_provider.Llm_transport.Http_server
                {
                  server with
                  headers;
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
  | Some policy, Llm_provider.Provider_config.Codex_cli, Some agent_name ->
      (* PR-F (Plan v3 Leak 2a): Codex CLI runtime MCP rejects most
         per-request HTTP headers, but the masc HTTP server still needs
         the keeper's identity to avoid collapsing to
         [Auth.find_credential_by_token]'s alphabetical first-match
         (the #9786 root cause behind the [bearer token belongs to X]
         rejection storm).  Strip ambient/auth headers as before, then
         re-inject the non-secret identity-only whitelist
         (x-masc-agent-name, x-masc-keeper-name)
         so the server side resolves the requester correctly even when
         ambient-env auth is the primary channel. *)
      let stripped = runtime_mcp_policy_without_http_headers policy in
      Some
        (runtime_mcp_policy_with_masc_agent_name
           ~include_internal_token:false ~agent_name stripped)
  | Some policy, Llm_provider.Provider_config.Codex_cli, None ->
      (* No agent_name to inject — preserve the legacy strip-all behavior. *)
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

let runtime_mcp_tool_requires_bound_actor tool_name =
  Tool_catalog.requires_actor_binding tool_name

let public_mcp_tool_requires_bound_actor tool_name =
  Tool_catalog.is_public_mcp tool_name
  && runtime_mcp_tool_requires_bound_actor tool_name

let tool_names_are_runtime_mcp ?(allow_keeper_internal = false)
    (tool_names : string list) =
  tool_names <> []
  && List.for_all
    (fun tool_name ->
      Tool_catalog.is_public_mcp tool_name
      ||
      (allow_keeper_internal
       && Tool_catalog.is_on_surface Tool_catalog.Keeper_internal tool_name))
    tool_names

let trim_nonempty_string raw =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then None else Some trimmed

let trim_nonempty value =
  Option.bind value trim_nonempty_string

let first_nonempty_env names =
  List.find_map (fun name -> Sys.getenv_opt name |> trim_nonempty) names

let runtime_mcp_policy_of_tool_names ?agent_name
    ?(allow_keeper_internal = false) (tool_names : string list) :
    Llm_provider.Llm_transport.runtime_mcp_policy option =
  let tool_names = dedupe_preserve_order tool_names in
  let has_keeper_internal =
    List.exists
      (Tool_catalog.is_on_surface Tool_catalog.Keeper_internal)
      tool_names
  in
  if
    not (tool_names_are_runtime_mcp ~allow_keeper_internal tool_names)
  then
    None
  else
    let agent_name = Option.bind agent_name trim_nonempty_string in
    let keeper_name = Option.bind agent_name keeper_name_of_agent_name in
    let internal_keeper_token =
      first_nonempty_env [ "MASC_INTERNAL_MCP_TOKEN" ]
    in
    if has_keeper_internal
       && (Option.is_none keeper_name || Option.is_none internal_keeper_token)
    then
      None
    else
    let masc_headers =
      match (keeper_name, internal_keeper_token) with
      | Some keeper_name, Some token ->
          let agent_header =
            match agent_name with
            | Some agent_name -> [ ("x-masc-agent-name", agent_name) ]
            | None -> []
          in
          Auth_resolve.emit_resolution_trace
            ~cascade:"runtime_mcp_policy"
            ~keeper_id:(Some keeper_name)
            ~provider_label:"masc-mcp"
            ~outcome:(Ok {
              Auth_resolve.raw = token;
              source = Auth_resolve.Internal_keeper_env;
            });
          ("x-masc-internal-token", token)
          :: ("x-masc-keeper-name", keeper_name)
          :: agent_header
      | _ ->
          let env_token = first_nonempty_env [ "MASC_MCP_TOKEN" ] in
          (* Phase A F1: when MASC_MCP_TOKEN is unset, fall back to the
             per-keeper raw token at <base_path>/.masc/auth/<agent_name>.token.
             This wires CLI-spawned subprocesses (codex_cli/gemini_cli/kimi_cli)
             that callback to masc-mcp tools but do not inherit the parent
             process env. *)
          let per_keeper_token =
            match env_token, agent_name with
            | None, Some name ->
                let base_path = Env_config_core.base_path () in
                Auth.load_raw_token base_path ~agent_name:name
            | _ -> None
          in
          let resolved : (Auth_resolve.token, Auth_resolve.auth_error) result =
            match env_token, per_keeper_token with
            | Some raw, _ ->
                Ok {
                  Auth_resolve.raw;
                  source = Auth_resolve.Mcp_bearer_env;
                }
            | None, Some raw ->
                Ok {
                  Auth_resolve.raw;
                  source = Auth_resolve.Per_keeper_token_file;
                }
            | None, None ->
                Error
                  (Auth_resolve.Api_key_env_unset {
                    var_name = "MASC_MCP_TOKEN";
                  })
          in
          Auth_resolve.emit_resolution_trace
            ~cascade:"runtime_mcp_policy"
            ~keeper_id:keeper_name
            ~provider_label:"masc-mcp"
            ~outcome:resolved;
          (match resolved with
           | Ok { raw; _ } -> [ ("Authorization", "Bearer " ^ raw) ]
           | Error _ -> [])
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

let public_mcp_runtime_policy_of_tool_names ?agent_name (tool_names : string list) :
    Llm_provider.Llm_transport.runtime_mcp_policy option =
  runtime_mcp_policy_of_tool_names ?agent_name tool_names

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
      let max_context_size = Cascade_config.resolve_kimi_max_context model_name in
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
                        ("max_context_size", `Int max_context_size);
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
    ?(tool_requirement = `Required)
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
  let keeper_internal_tool_names =
    match requested_agent_name with
    | Some agent_name when Option.is_some (keeper_name_of_agent_name agent_name) ->
        tools
        |> List.filter (fun (tool : Oas.Tool.t) ->
               Tool_catalog.is_on_surface Tool_catalog.Keeper_internal
                 tool.schema.name)
        |> List.map (fun (tool : Oas.Tool.t) -> tool.schema.name)
        |> dedupe_preserve_order
    | _ -> []
  in
  let codex_keeper_bound_actor_tools =
    match provider_cfg.kind, requested_agent_name with
    | Llm_provider.Provider_config.Codex_cli, Some agent_name
      when Option.is_some (keeper_name_of_agent_name agent_name) ->
        List.filter runtime_mcp_tool_requires_bound_actor
          (public_tool_names @ keeper_internal_tool_names)
    | _ -> []
  in
  (* #10097: WARN once per distinct fingerprint + always-emit
     per-tool counter.  See [record_codex_cli_omission] docs. *)
  record_codex_cli_omission_for_agent ~agent_name:requested_agent_name
    ~tools:codex_keeper_bound_actor_tools;
  let public_tool_names =
    if codex_keeper_bound_actor_tools = [] then
      public_tool_names
    else
      List.filter
        (fun tool_name -> not (public_mcp_tool_requires_bound_actor tool_name))
        public_tool_names
  in
  let keeper_internal_tool_names =
    if codex_keeper_bound_actor_tools = [] then
      keeper_internal_tool_names
    else
      List.filter
        (fun tool_name ->
          not (runtime_mcp_tool_requires_bound_actor tool_name))
        keeper_internal_tool_names
  in
  let runtime_tool_names =
    dedupe_preserve_order (public_tool_names @ keeper_internal_tool_names)
  in
  let runtime_mcp_policy =
    runtime_mcp_policy_of_tool_names
      ?agent_name:requested_agent_name
      ~allow_keeper_internal:(keeper_internal_tool_names <> [])
      runtime_tool_names
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
  | _ when tool_requirement = `Optional ->
      Ok ([], None)
  | _ ->
      let detail =
        let runtime_mcp_requires_http_headers =
          match runtime_mcp_policy with
          | Some policy ->
              Provider_tool_support.runtime_mcp_policy_requires_unsupported_http_headers
                provider_cfg policy
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

  (* Kimi CLI imports [setproctitle] on macOS before processing the
     request. UTF-8 prompts in argv can make setproctitle's import-time
     [getproctitle()] decode fail before Kimi reads the prompt, so keep
     non-ASCII or large prompts out of argv and stream them via stdin. *)
  let default_prompt_argv_threshold = 16 * 1024

  let prompt_argv_threshold () =
    match Sys.getenv_opt "OAS_KIMI_PROMPT_ARGV_THRESHOLD" with
    | Some raw -> (
        match int_of_string_opt (String.trim raw) with
        | Some value when value >= 0 -> value
        | _ -> default_prompt_argv_threshold)
    | None -> default_prompt_argv_threshold

  let prompt_exceeds_argv_budget prompt =
    String.length prompt >= prompt_argv_threshold ()

  let prompt_contains_non_ascii prompt =
    let rec loop idx =
      idx < String.length prompt
      && (Char.code prompt.[idx] > 0x7f || loop (idx + 1))
    in
    loop 0

  let prompt_needs_stdin prompt =
    prompt_exceeds_argv_budget prompt || prompt_contains_non_ascii prompt

  let stdin_for_prompt prompt =
    if prompt_needs_stdin prompt then Some prompt else None

  let cli_model_override ~(config : config)
      ~(req_config : Llm_provider.Provider_config.t) =
    match String.trim req_config.model_id |> String.lowercase_ascii with
    | "" | "auto" -> config.model
    | _ -> Some (String.trim req_config.model_id)

  let build_args ~(config : config)
      ~(req_config : Llm_provider.Provider_config.t)
      ~(mcp_config_json : string list)
      ~prompt =
    let prompt_via_stdin = prompt_needs_stdin prompt in
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

  let starts_with text prefix = String.starts_with ~prefix text

  let resumable_session_detail =
    "kimi_cli reported a resumable CLI session. Resumable session available via -r."

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

  let exit_code_marker_of_text text =
    let marker = "(exit " in
    let lower = String.lowercase_ascii text in
    let marker_len = String.length marker in
    let text_len = String.length lower in
    let rec find_marker index =
      if index + marker_len > text_len then None
      else if String.sub lower index marker_len = marker then
        let number_start = index + marker_len in
        match String.index_from_opt lower number_start ')' with
        | Some number_end when number_end > number_start ->
            String.sub lower number_start (number_end - number_start)
            |> String.trim |> int_of_string_opt
        | _ -> None
      else find_marker (index + 1)
    in
    find_marker 0

  let exit_payload_of_message message =
    let prefix = "kimi exited with code " in
    if not (starts_with message prefix) then None
    else
      match String.index_from_opt message (String.length prefix) ':' with
      | None -> None
      | Some colon ->
          Some
            (String.sub message (colon + 1)
               (String.length message - colon - 1)
             |> String.trim)

  let payload_has_only_resume_hint payload =
    payload
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun line -> line <> "")
    |> fun lines -> lines <> [] && List.for_all is_resume_hint_line lines

  let text_looks_like_resumable_session text =
    let trimmed = String.trim text in
    let has_raw_resume_hint =
      match exit_code_of_message trimmed with
      | Some 75 -> is_resume_hint_line trimmed
      | Some 1 -> (
          match exit_payload_of_message trimmed with
          | Some payload -> payload_has_only_resume_hint payload
          | None -> false)
      | _ -> false
    in
    trimmed <> ""
    &&
    (has_raw_resume_hint
    || String_util.contains_substring_ci trimmed resumable_session_public_marker
    || String_util.contains_substring_ci trimmed legacy_resumable_session_public_marker)

  let resumable_session_detail_of_text text =
    if text_looks_like_resumable_session text then
      let trimmed = String.trim text in
      match
        match exit_code_of_message trimmed with
        | Some code -> Some code
        | None -> exit_code_marker_of_text trimmed
      with
      | Some code ->
          Printf.sprintf
            "kimi_cli reported a resumable CLI session (exit %d). \
             Resumable session available via -r."
            code
      | None -> resumable_session_detail
    else String.trim text

  let resumable_session_exit_code_of_text text =
    match exit_code_of_message text with
    | Some (75 as code) -> Some code
    | Some (1 as code) when text_looks_like_resumable_session text -> Some code
    | _ when text_looks_like_resumable_session text -> exit_code_marker_of_text text
    | _ -> None

  let text_looks_like_process_title_unicode_crash text =
    String_util.contains_substring_ci text "UnicodeDecodeError"
    && String_util.contains_substring_ci text "setproctitle"

  let classify_cli_error = function
    | Error (Llm_provider.Http_client.NetworkError { message; _ }) as err -> (
        if text_looks_like_resumable_session message then
          Error
            (Llm_provider.Http_client.AcceptRejected
               { reason = resumable_session_detail_of_text message })
        else if text_looks_like_process_title_unicode_crash message then
          Error
            (Llm_provider.Http_client.AcceptRejected
               {
                 reason =
                   "kimi_cli startup crash while setting process title \
                    (UnicodeDecodeError). This is a local CLI/runtime \
                    failure, not keeper auth or sandbox failure; rejecting \
                    without retry so the cascade can move on. "
                   ^ message;
               })
        else
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
                 { reason = resumable_session_detail_of_text message })
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
  | Anthropic | OpenAI_compat | Ollama | Gemini | Glm | Kimi | DashScope ->
      Ok None
