module Catalog_binding = Agent_core.Provider_runtime_binding

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

let integration_json config ~id ~display_name ~protocol ~origin ~supported fields =
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
     ; "verification_support", `String (if supported then "response_tool" else "unsupported")
     ; "account_availability_verified", `Bool false
     ] @ fields)
;;

let protocol_of_catalog_kind = function
  | Llm_provider.Provider_config.Anthropic | Kimi -> Some "messages-http"
  | OpenAI_compat | Glm -> Some "openai-compatible-http"
  | Ollama -> Some "ollama-http"
  | Gemini -> None
;;

let integrations_json (config : Runtime_schema.config) =
  let catalog = Catalog_binding.all () in
  let configured =
    List.map (fun (provider : Runtime_schema.provider) ->
      let supported =
        match provider.api_format with
        | Runtime_schema.Antigravity_cli_runtime -> false
        | Messages_api | Chat_completions_api | Ollama_api
        | Codex_app_server_runtime | Claude_code_runtime -> true
      in
      let fields =
        match provider.transport with
        | Runtime_schema.Http endpoint -> endpoint_fields endpoint
        | Cli command -> [ "command", `String command ]
      in
      let credential =
        match provider.credentials with
        | Some (Runtime_schema.Env name) -> [ "api_key_env", `String name ]
        | Some (File _ | Inline _) | None -> []
      in
      integration_json config ~id:provider.id ~display_name:provider.display_name
        ~protocol:(Some provider.protocol) ~origin:"runtime_config" ~supported
        (fields @ credential @ [ "enabled", `Bool provider.enabled ])) config.providers
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
        ~origin:"agent_core_catalog" ~supported
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
    ; "antigravity", "Antigravity", "antigravity-cli", Some "agy", false
    ; "vllm", "vLLM", "openai-compatible-http", None, true
    ; "rapid-mlx", "RapidMLX", "openai-compatible-http", None, true
    ; "llama-cpp", "llama.cpp", "openai-compatible-http", None, true
    ; "unsloth", "Unsloth served weights", "openai-compatible-http", None, true
    ]
    |> List.filter_map (fun (id, display_name, protocol, command, supported) ->
      if declared id || List.exists (fun (entry : Catalog_binding.t) -> entry.id = id) catalog
      then None else
      Some (integration_json config ~id ~display_name ~protocol:(Some protocol)
        ~origin:"masc_integration" ~supported
        (match command with None -> [] | Some command -> [ "command", `String command ])))
  in
  `List (configured @ prototypes @ clients)
;;

let to_json (config : Runtime_schema.config) =
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
             let credential =
               match provider.credentials with
               | Some (Runtime_schema.Env name) ->
                 [ "credential_kind", `String "env"; "api_key_env", `String name ]
               | Some (Runtime_schema.File _) -> [ "credential_kind", `String "file" ]
               | Some (Runtime_schema.Inline _) -> [ "credential_kind", `String "inline" ]
               | None -> [ "credential_kind", `String "none" ]
             in
             Some
               (`Assoc
                   ([ "id", `String (Runtime_schema.binding_key binding)
                    ; "provider_id", `String provider.id
                    ; "display_name", `String provider.display_name
                    ; "protocol", `String provider.protocol
                    ; "model", `String model.api_name
                    ; ( "max_context"
                      , match model.max_context with
                        | None -> `Null
                        | Some n -> `Int n )
                    ; "tools", `Bool model.tools_support
                    ; "streaming", `Bool model.streaming
                    ]
                    @ transport
                    @ credential))
           | _ -> None))
      config.bindings
  in
  `Assoc
    [ ( "default_runtime_id"
      , match config.default_runtime_id with
        | None -> `Null
        | Some id -> `String id )
    ; "runtimes", `List runtimes
    ; "integrations", integrations_json config
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
   the list. [global ()] and [load_default ()] read the same embedded catalog
   in this command's process; no override or overlay is installed. *)
let provider_model_rows (provider_id : string) : (Yojson.Safe.t, string) result =
  match Llm_provider.Model_catalog.load_default () with
  | Error message -> Error message
  | Ok catalog ->
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
                   Llm_provider.Capabilities.for_provider_model_id_row
                     ~wire:(Some provider.kind)
                     ~provider_label:provider.id
                     ~model_id:entry.id_prefix
                 with
                 | None -> None
                 | Some capabilities ->
                   (* "high" is the effort the seed rows pin; when a row's
                      accepted ladder does not carry it, the ladder runs weak
                      to strong and its top is the honest default. *)
                   let default_effort =
                     match entry.accepted_reasoning_efforts with
                     | None | Some [] -> `Null
                     | Some rungs ->
                       let chosen =
                         if List.exists (String.equal "high") rungs
                         then "high"
                         else (match List.rev rungs with top :: _ -> top | [] -> "high")
                       in
                       `String chosen
                   in
                   Some
                     (`Assoc
                        [ ("id", `String entry.id_prefix)
                        ; ("label", `String (Option.value entry.base_label ~default:entry.id_prefix))
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
