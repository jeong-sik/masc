type binding =
  | Model of string
  | Runtime of string

type error =
  | Template_not_declared of string
  | Model_not_bound of
      { template : string
      ; model : string
      }
  | Runtime_not_bound of
      { template : string
      ; runtime_id : string
      }
  | Not_materialized of string

let error_to_string = function
  | Template_not_declared template -> Printf.sprintf "no provider %s is declared" template
  | Model_not_bound { template; model } ->
    Printf.sprintf "the provider %s has no binding of the model %s" template model
  | Runtime_not_bound { template; runtime_id } ->
    Printf.sprintf
      "no binding of the provider %s makes the Runtime %s on this account"
      template
      runtime_id
  | Not_materialized diagnostic -> "the runtime of the account does not load: " ^ diagnostic
;;

let config_label = "the runtime of one account"

let on_account ~provider_id (binding : Runtime_schema.binding) =
  { binding with provider_id; enabled = true }
;;

let chosen ~provider_id (binding : Runtime_schema.binding) = function
  | Model model -> String.equal binding.model_id model
  | Runtime runtime_id ->
    String.equal (Runtime_schema.binding_key (on_account ~provider_id binding)) runtime_id
;;

let not_bound ~template = function
  | Model model -> Model_not_bound { template; model }
  | Runtime runtime_id -> Runtime_not_bound { template; runtime_id }
;;

let error_code = function
  | Template_not_declared _ -> "template_not_declared"
  | Model_not_bound _ -> "model_not_bound"
  | Runtime_not_bound _ -> "runtime_not_bound"
  | Not_materialized _ -> "not_materialized"
;;

let template_binding (config : Runtime_schema.config) ~template ~provider_id choice =
  match
    List.find_opt
      (fun (provider : Runtime_schema.provider) -> String.equal provider.id template)
      config.providers
  with
  | None -> Error (Template_not_declared template)
  | Some provider ->
    (match
       List.find_opt
         (fun (binding : Runtime_schema.binding) ->
           String.equal binding.provider_id template && chosen ~provider_id binding choice)
         config.bindings
     with
     | None -> Error (not_bound ~template choice)
     | Some binding -> Ok (provider, on_account ~provider_id binding))
;;

let binding_of config ~template ~provider_id ~binding:choice =
  Result.map snd (template_binding config ~template ~provider_id choice)
;;

let http_provider_takes_key (provider : Runtime_schema.provider) =
  match provider.transport, provider.api_format with
  | ( Runtime_schema.Http (_ : string)
    , ( Runtime_schema.Messages_api
      | Runtime_schema.Chat_completions_api
      | Runtime_schema.Ollama_api
      | Runtime_schema.Gemini_api ) ) ->
    let catalog_id = Runtime_schema.catalog_provider_id provider in
    (match Agent_core.Provider_runtime_binding.find catalog_id with
     | Some binding ->
       binding.Agent_core.Provider_runtime_binding.requires_api_key
       || Option.is_some provider.credentials
     | None -> Option.is_some provider.credentials)
  | ( Runtime_schema.Http (_ : string)
    , ( Runtime_schema.Vertex_gemini_api
      | Runtime_schema.Codex_app_server_runtime
      | Runtime_schema.Claude_code_runtime
      | Runtime_schema.Antigravity_cli_runtime ) )
  | Runtime_schema.Cli (_ : string), _ -> false
;;

let catalog_provider_of_template (provider : Runtime_schema.provider) ~provider_id =
  match provider.transport with
  | Runtime_schema.Cli (_ : string) -> provider.catalog_provider
  | Runtime_schema.Http (_ : string) ->
    (match provider.catalog_provider, provider.wire_kind with
     | Some _ as explicit, _ -> explicit
     | None, Some _ -> None
     | None, None ->
       (match Llm_provider.Catalog_snapshot.(find (current ()) provider.id) with
        | Some entry when not (String.equal entry.id provider_id) -> Some entry.id
        | Some _ | None -> None))
;;

let materialize_person_binding
    (config : Runtime_schema.config)
    ~(provider : Runtime_schema.provider)
    ~(binding : Runtime_schema.binding)
    ~provider_account_id
    ~integration_id
    ~account_home
  =
  let ( let* ) = Result.bind in
  let provider_id = Authz_types.Provider_account_id.to_string provider_account_id in
  let person_cfg =
    { config with
      providers =
        [ { provider with
            id = provider_id
          ; catalog_provider = catalog_provider_of_template provider ~provider_id
          ; account_home
          ; credentials = None
          ; headers = None
          ; enabled = true
          }
        ]
    }
  in
  match
    Runtime_instance.of_person_binding
      ~provider_account_id
      ~integration_id
      ~account_home
      person_cfg
      binding
  with
  | Error reason ->
    Error (Not_materialized (Runtime_config_error.string_of_drop_reason reason))
  | Ok runtime ->
    let validation =
      let* () = Runtime_config_validation.validate_runtime_max_context [ runtime ] in
      Runtime_config_validation.validate_runtime_thinking_requests [ runtime ]
    in
    (match validation with
     | Ok () -> Ok runtime
     | Error failure ->
       Error
         (Not_materialized
            (Runtime_config_error.to_diagnostic_text ~config_path:config_label failure)))
;;

let of_person_template
      (config : Runtime_schema.config)
      ~template
      ~provider_account_id
      ~integration_id
      ~account_home
      ~binding:choice
  =
  let ( let* ) = Result.bind in
  let provider_id = Authz_types.Provider_account_id.to_string provider_account_id in
  let* provider, binding = template_binding config ~template ~provider_id choice in
  materialize_person_binding
    config
    ~provider
    ~binding
    ~provider_account_id
    ~integration_id
    ~account_home
;;
