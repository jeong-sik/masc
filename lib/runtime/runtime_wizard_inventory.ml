module Catalog_binding = Agent_core.Provider_runtime_binding

let http_fields provider = match Runtime_adapter.http_protocol_metadata provider with
  | Error _ -> []
  | Ok (kind, path) -> ["provider_kind", `String (Llm_provider.Provider_config.string_of_provider_kind kind);
                        "request_path", `String path]

type setup_support = Existing_binding | New_connection | Unsupported

let setup_support_json = function
  | Existing_binding -> `String "existing_binding"
  | New_connection -> `String "new_connection"
  | Unsupported -> `String "unsupported"
;;

let endpoint_fields endpoint =
  let uri = Uri.of_string endpoint in
  if Uri.userinfo uri <> None || Uri.query uri <> [] || Uri.fragment uri <> None
  then [ "endpoint_redacted", `Bool true ]
  else [ "endpoint", `String endpoint ]
;;

let configured_runtime_ids (config : Runtime_schema.config) provider_id =
  config.bindings
  |> List.filter_map (fun (binding : Runtime_schema.binding) ->
    if String.equal binding.provider_id provider_id
    then Some (`String (Runtime_schema.binding_key binding)) else None)
;;

let integration_json config ~id ~display_name ~protocol ~origin ~supported ~verification_supported fields =
  let configured = configured_runtime_ids config id in
  let setup_support =
    if not supported then Unsupported
    else if configured = [] then New_connection else Existing_binding
  in
  `Assoc
    ([ "id", `String id
     ; "display_name", `String display_name
     ; "protocol", (match protocol with Some value -> `String value | None -> `Null)
     ; "origin", `String origin
     ; "configured_runtime_ids", `List configured
     ; "setup_support", setup_support_json setup_support
     ; "verification_support", `String (if verification_supported then "response_tool" else "unsupported")
     ; "account_availability_verified", `Bool false
     ] @ fields)
;;

let protocol_of_catalog_kind = function
  | Llm_provider.Provider_config.Anthropic | Kimi -> Some "messages-http"
  | OpenAI_compat | Glm -> Some "openai-compatible-http"
  | Ollama -> Some "ollama-http"
  | Gemini -> None
;;

let credential_fields ~include_credential_references = function
  | Some (Runtime_schema.Env name) ->
    [ "credential_kind", `String "env"; "api_key_env", `String name ]
  | Some (Runtime_schema.File path) ->
    [ "credential_kind", `String "file" ]
    @ (if include_credential_references then [ "credential_file", `String path ] else [])
  | Some (Runtime_schema.Inline _) -> [ "credential_kind", `String "inline" ]
  | None -> [ "credential_kind", `String "none" ]

let account_fields ~include_credential_references account_home =
  ["account_configured", `Bool (Option.is_some account_home)]
  @ (match account_home with
     | Some home when include_credential_references -> ["account_home", `String home]
     | Some _ | None -> [])

let provider_timeout_fields (provider : Runtime_schema.provider) =
  match provider.antigravity_cli with
  | Some options -> ["provider_timeout_s", `Float options.timeout_s]
  | None -> []
;;

let integrations_json ~include_credential_references (config : Runtime_schema.config) =
  let catalog = Catalog_binding.all () in
  let configured =
    List.map (fun (provider : Runtime_schema.provider) ->
      let supported =
        match provider.api_format with
        | Runtime_schema.Antigravity_cli_runtime | Messages_api | Chat_completions_api | Ollama_api
        | Codex_app_server_runtime | Claude_code_runtime
        | Gemini_api | Vertex_gemini_api | Muse_serve_runtime -> true
      in
      let fields =
        match provider.transport with
        | Runtime_schema.Http endpoint -> endpoint_fields endpoint
        | Cli command -> [ "command", `String command ]
      in
      let credential = credential_fields ~include_credential_references provider.credentials in
      integration_json config ~id:provider.id ~display_name:provider.display_name
        ~protocol:(Some provider.protocol) ~origin:"runtime_config" ~supported
        ~verification_supported:true
        (fields @ provider_timeout_fields provider @ credential @ account_fields ~include_credential_references provider.account_home @ http_fields provider @ [ "enabled", `Bool provider.enabled ])) config.providers
  in
  let declared id =
    List.exists (fun (provider : Runtime_schema.provider) -> String.equal provider.id id)
      config.providers
  in
  let prototypes =
    catalog |> List.filter_map (fun (entry : Catalog_binding.t) ->
      if declared entry.id then None else
      let protocol = protocol_of_catalog_kind entry.kind in
      let task =
        match entry.default_model with
        | None -> entry.capabilities.task
        | Some model_id ->
          (match Llm_provider.Capabilities.for_provider_model_id
                   ~wire:(Some entry.kind) ~allow_bare_fallback:false
                   ~provider_label:entry.id ~model_id with
           | None -> entry.capabilities.task
           | Some capabilities -> capabilities.task)
      in
      let supported = protocol <> None && task = None in
      Some (integration_json config ~id:entry.id ~display_name:entry.id ~protocol
        ~origin:"agent_core_catalog" ~supported ~verification_supported:supported
        (endpoint_fields entry.base_url
         @ [ "request_path", `String entry.request_path
           ; "api_key_env", `String entry.api_key_env
           ; "provider_kind", `String (Llm_provider.Provider_config.string_of_provider_kind entry.kind)
           ])))
  in
  (* Product integration identities declare transport only. Actual server model
     identity, capabilities and running context still come from discovery. *)
  let clients =
    [ "codex", "Codex", "codex-app-server", Some "codex", true
    ; "claude-code", "Claude Code", "claude-code", Some "claude", true
    ; "muse-code", "Muse Code", "muse-serve", Some "muse", true
    ; "antigravity", "Antigravity", "antigravity-cli", Some "agy", true
    ; "vllm", "vLLM", "openai-compatible-http", None, true
    ; "rapid-mlx", "RapidMLX", "openai-compatible-http", None, true
    ; "llama-cpp", "llama.cpp", "openai-compatible-http", None, true
    ; "unsloth", "Unsloth served weights", "openai-compatible-http", None, true
    ]
    |> List.filter_map (fun (id, display_name, protocol, command, supported) ->
      if declared id || List.exists (fun (entry : Catalog_binding.t) -> entry.id = id) catalog
      then None else
      Some (integration_json config ~id ~display_name ~protocol:(Some protocol)
        ~origin:"masc_integration" ~supported ~verification_supported:supported
        (match command with None -> [] | Some command -> [ "command", `String command ])))
  in
  `List (configured @ prototypes @ clients)
;;

(* Reuse the runtime's selected credential location, never a display name or
   email. This groups connections; it does not identify the provider account
   currently authenticated at that location. *)
let account_scope (provider : Runtime_schema.provider) =
  let native home scope = Option.bind home (fun home ->
    match Runtime_account_home.of_string home with
    | Ok home -> Some (scope home) | Error _ -> None) in
  match provider.api_format with
  | Codex_app_server_runtime ->
      native (Runtime_codex_app_server.effective_account_home provider.account_home)
        (fun home -> Runtime_quota_window.scope_of_codex_home (Some home))
  | Claude_code_runtime ->
      native (Runtime_claude_code.effective_account_home provider.account_home)
        (fun home -> Runtime_quota_window.scope_of_claude_code_home (Some home))
  | Muse_serve_runtime -> native provider.account_home Runtime_quota_window.scope_of_muse_home
  | Antigravity_cli_runtime ->
      (match provider.credentials with
       | Some (Runtime_schema.File _) ->
           Some (Runtime_quota_window.scope_of_credential ~provider_id:provider.id provider.credentials)
       | Some (Env _ | Inline _) | None -> None)
  | Chat_completions_api | Messages_api | Ollama_api | Gemini_api | Vertex_gemini_api -> None
;;

let account_groups_json (config : Runtime_schema.config) =
  let groups = List.fold_left (fun groups (provider : Runtime_schema.provider) ->
    match account_scope provider with
    | None -> groups
    | Some scope ->
      if List.exists (fun (known, _) -> Runtime_quota_window.scope_equal scope known) groups then
        List.map (fun (known, ids) -> known,
          if Runtime_quota_window.scope_equal scope known then ids @ [provider.id] else ids) groups
      else groups @ [scope, [provider.id]]) [] config.providers in
  `List (List.map (fun (scope, ids) ->
    let id = Runtime_quota_window.scope_id scope in
    let runtimes = List.filter_map (fun (binding : Runtime_schema.binding) ->
      if List.mem binding.provider_id ids then Some (`String (Runtime_schema.binding_key binding)) else None) config.bindings in
    `Assoc ["id", `String id;
      "integration_ids", `List (List.map (fun id -> `String id) ids);
      "runtime_ids", `List runtimes]) groups)
;;

let to_json ?(include_credential_references=false) (config : Runtime_schema.config) =
  let runtimes =
    List.filter_map
      (fun (binding : Runtime_schema.binding) ->
         if not binding.enabled
         then None
         else (
           match
             ( List.find_opt
                 (fun (p : Runtime_schema.provider) ->
                    p.id = binding.provider_id && p.enabled)
                 config.providers
             , List.find_opt
                 (fun (m : Runtime_schema.model_spec) -> m.id = binding.model_id)
                 config.models )
           with
           | Some provider, Some model ->
             let transport =
               match provider.transport with
               | Runtime_schema.Cli command -> [ "command", `String command ]
               | Runtime_schema.Http endpoint -> endpoint_fields endpoint
             in
             (* Setup edits declarations, not a credential-probing runtime.
                Preserve the most specific configured window in its form. *)
             let declared_context = match binding.max_context, provider.max_context, model.max_context with
               | Some tokens, _, _ -> Some (tokens, Runtime_instance.Binding_override)
               | None, Some tokens, _ -> Some (tokens, Runtime_instance.Provider_override)
               | None, None, Some tokens -> Some (tokens, Runtime_instance.Override)
               | None, None, None -> None in
             let credential = credential_fields ~include_credential_references provider.credentials in
             Some
               (`Assoc
                   ([ "id", `String (Runtime_schema.binding_key binding)
                    ; "provider_id", `String provider.id
                    ; "display_name", `String provider.display_name
                    ; "protocol", `String provider.protocol
                    ; "model", `String model.api_name
                    ; ( "max_context"
                      , match declared_context with
                        | None -> `Null
                        | Some (tokens, _) -> `Int tokens )
                    ; ( "max_context_source"
                      , match declared_context with
                        | None -> `Null
                        | Some (_, source) -> `String (Runtime_instance.max_context_source_to_string source) )
                    ; "tools", `Bool model.tools_support
                    ; "streaming", `Bool model.streaming
                    ]
                    @ transport
                    @ account_fields ~include_credential_references provider.account_home
                    @ http_fields provider
                    @ provider_timeout_fields provider
                    @ credential))
           | _ -> None))
      config.bindings
  in
  `Assoc
    [ ( "default_runtime_id"
      , match config.default_runtime_id with
        | None -> `Null
        | Some id -> `String id )
    ; ( "default_runtime_selection"
      , `List (List.map (fun id -> `String id)
          (match config.default_runtime_id with
           | None -> []
           | Some primary ->
             match List.find_opt
               (fun (lane : Runtime_schema.lane_decl) -> String.equal lane.id primary)
               config.lane_decls with
               | None -> [primary] | Some lane -> lane.candidate_ids)))
    ; "model_release_catalog", Model_release_evidence.default_catalog_json ()
    ; "runtimes", `List runtimes
    ; "integrations", integrations_json ~include_credential_references config
    ; "account_groups", account_groups_json config
    ]
;;


let binding_for_provider (cfg : Runtime_schema.config)
    (provider : Runtime_schema.provider) =
  let bindings =
    List.filter
      (fun (binding : Runtime_schema.binding) ->
         binding.enabled && String.equal binding.provider_id provider.id)
      cfg.bindings
  in
  match bindings with
  | [] -> Error (Printf.sprintf "provider %s has no concrete runtime binding" provider.id)
  | _ ->
      (match List.filter (fun (binding : Runtime_schema.binding) -> binding.wizard_default) bindings with
       | [ binding ] -> Ok binding
       (* One enabled binding is the default by arithmetic: there is nothing
          else the wizard could install, so requiring the operator to say so
          rejects a config the server boots from (#27991, live glm-coding).
          Two or more without a flag stays an error -- that one is a real
          choice and guessing it would install a model nobody picked. *)
       | [] when List.length bindings = 1 -> Ok (List.hd bindings)
       | [] ->
           (* Prefer the binding the config already runs by default: that is the
              operator's own pick, not a guess, so a live config with several
              bindings and one [runtime].default no longer fails the wizard.
              Only when this provider does not own the default runtime is the
              choice genuinely ambiguous, and then it stays an error the caller
              skips rather than guessing a model nobody picked. *)
           (match
              (match cfg.default_runtime_id with
               | None -> None
               | Some runtime_id ->
                   List.find_opt
                     (fun (binding : Runtime_schema.binding) ->
                        String.equal
                          (Runtime_schema.binding_key binding)
                          runtime_id)
                     bindings)
            with
            | Some binding -> Ok binding
            | None ->
                Error
                  (Printf.sprintf
                     "provider %s has %d enabled bindings and no install wizard default; set wizard-default = true on exactly one [%s.<model>] binding"
                     provider.id (List.length bindings) provider.id))
       | defaults ->
           Error
             (Printf.sprintf
                "provider %s has %d install wizard default bindings; set wizard-default = true on exactly one [%s.<model>] binding"
                provider.id
                (List.length defaults)
                provider.id))
;;

(* Rows the setup wizard can offer for one named catalog provider. The entries
   come from the embedded catalog scoped to [provider_name]; capabilities are
   resolved against the provider's own wire kind, so a row that only inherits
   from the provider base still reports the capabilities it will actually run
   with. A row without a positive declared context is not wizard-offerable —
   the wizard writes a runtime entry that needs a context — and stays out of
   the list. The loaded catalog is installed as the global before resolving
   capabilities, so entries and capabilities provably read one catalog
   whatever a caller left in the global before this call. *)
let provider_model_rows (provider_id : string) : (Yojson.Safe.t, string) result =
  match Llm_provider.Model_catalog.load_default () with
  | Error message -> Error message
  | Ok catalog ->
    Llm_provider.Model_catalog.set_global catalog;
    let providers = Catalog_binding.all () in
    let provider =
      providers
      |> List.find_opt (fun (entry : Catalog_binding.t) -> String.equal entry.id provider_id)
    in
    (match provider with
     | None ->
       let available =
         providers
         |> List.map (fun (entry : Catalog_binding.t) -> entry.id)
         |> List.sort_uniq String.compare
       in
       Error
         (Printf.sprintf "unknown provider %S; installed catalog providers: %s"
            provider_id (String.concat ", " available))
     | Some provider ->
       let rows =
         Llm_provider.Model_catalog.model_entries catalog
         |> List.filter (fun (entry : Llm_provider.Model_catalog.model_entry) ->
              match entry.provider_name with
              | Some name -> String.equal name provider_id
              | None -> false)
         |> List.filter_map (fun (entry : Llm_provider.Model_catalog.model_entry) ->
              match entry.max_context_tokens with
              | Some context when context > 0 ->
                (match
                   Llm_provider.Capabilities.for_provider_model_id
                     ~wire:(Some provider.kind)
                     ~allow_bare_fallback:false
                     ~provider_label:provider.id
                     ~model_id:
                       (Llm_provider.Model_identifiers.Id_prefix.to_string
                          entry.id_prefix)
                 with
                 | None -> None
                 | Some capabilities ->
                   (* "high" is the effort the seed rows pin. When a row's
                      accepted ladder does not carry it, take the strongest
                      rung that still reasons -- "none" is the disable, not a
                      default -- and a ladder of only "none" takes "none",
                      because that is all the row can encode. *)
                   let default_effort =
                     match entry.accepted_reasoning_efforts with
                     | None | Some [] -> `Null
                     | Some rungs ->
                       let chosen =
                         if List.exists (String.equal "high") rungs
                         then "high"
                         else
                           (match
                              List.rev (List.filter (fun rung -> not (String.equal "none" rung)) rungs)
                            with
                            | top :: _ -> top
                            | [] -> "none")
                       in
                       `String chosen
                   in
                   Some
                     (`Assoc
                        [ ( "id"
                          , `String
                              (Llm_provider.Model_identifiers.Id_prefix.to_string
                                 entry.id_prefix) )
                        ; ( "label"
                          , `String
                              (match entry.base_label with
                               Some label -> label
                               | None ->
                                 Llm_provider.Model_identifiers.Id_prefix.to_string
                                   entry.id_prefix) )
                        ; ("max_context", `Int context)
                        ; ( "accepted_reasoning_efforts"
                          , (match entry.accepted_reasoning_efforts with
                             | None -> `Null
                             | Some rungs -> `List (List.map (fun rung -> `String rung) rungs)) )
                        ; ("default_reasoning_effort", default_effort)
                        ; ("supports_tools", `Bool capabilities.supports_tools)
                        ; ("supports_streaming", `Bool capabilities.supports_native_streaming)
                        ]))
              | _ -> None)
       in
       Ok (`List rows))
;;
