type binding = Runtime_person_template.binding =
  | Model of string
  | Runtime of string

type account =
  | Login
  | Key of { key_file : string }

type error = Runtime_person_template.error =
  | Template_not_declared of string
  | Model_not_bound of
      { template : string
      ; model : string
      }
  | Runtime_not_bound of
      { template : string
      ; runtime_id : string
      }
  | Key_missing
  | Key_unreadable of Runtime_api_key_file.unreadable
  | Not_materialized of string

let error_to_string = Runtime_person_template.error_to_string

(* The label a load diagnostic names the configuration by: it is no file. *)
let config_label = "the runtime of one account"

let error_code = Runtime_person_template.error_code

let binding_of = Runtime_person_template.binding_of

let http_provider_takes_key = Runtime_person_template.http_provider_takes_key

(* The credential of the provider of the account. It is never the one of the
   template: a person's account runs on no credential of the workspace. *)
let credentials_of = function
  | Login -> Ok None
  | Key { key_file } ->
    (match Runtime_api_key_file.read key_file with
     | Ok (_ : Runtime_api_key_file.key) -> Ok (Some (Runtime_schema.File key_file))
     | Error Runtime_api_key_file.Key_missing -> Error Key_missing
     | Error (Runtime_api_key_file.Key_unreadable why) -> Error (Key_unreadable why))
;;

let materialize_single_runtime
    (config : Runtime_schema.config)
    ~(provider : Runtime_schema.provider)
    ~(binding : Runtime_schema.binding)
    ~provider_id
    ~account_home
    ~credentials
  =
  let id = Runtime_schema.binding_key binding in
  let alone =
    { config with
      providers =
        [ { provider with
            id = provider_id
          ; account_home
          ; credentials
          ; enabled = true
          }
        ]
    ; bindings = [ binding ]
    ; default_runtime_id = Some id
    ; keeper_assignments = []
    ; media_failover = []
    ; lane_decls = []
    ; exact_output_lane_decls = []
    }
  in
  match Runtime.runtimes_of_config alone with
  | Error failure ->
    Error (Not_materialized (Runtime_config_error.to_diagnostic_text ~config_path:config_label failure))
  | Ok runtimes ->
    (match List.find_opt (fun (runtime : Runtime_instance.t) -> String.equal runtime.id id) runtimes with
     | Some runtime -> Ok runtime
     | None -> Error (Not_materialized ("no runtime " ^ id ^ " was materialized")))
;;

let of_template
      (config : Runtime_schema.config)
      ~template
      ~provider_id
      ~account_home
      ~account
      ~binding:choice
  =
  let ( let* ) = Result.bind in
  let* provider, binding =
    Runtime_person_template.template_binding config ~template ~provider_id choice
  in
  let* credentials = credentials_of account in
  match provider.api_format, account_home, account with
  | ( ( Runtime_schema.Messages_api
      | Runtime_schema.Chat_completions_api
      | Runtime_schema.Ollama_api
      | Runtime_schema.Gemini_api
      | Runtime_schema.Vertex_gemini_api )
    , Some (_ : string)
    , (Login | Key _) ) ->
    Error (Not_materialized "HTTP provider account has no account home")
  | ( ( Runtime_schema.Messages_api
      | Runtime_schema.Chat_completions_api
      | Runtime_schema.Ollama_api
      | Runtime_schema.Gemini_api
      | Runtime_schema.Vertex_gemini_api )
    , None
    , Login ) ->
    Error (Not_materialized "HTTP provider account requires an API key")
  | Runtime_schema.Vertex_gemini_api, None, Key _ ->
    Error
      (Not_materialized
         "vertex-gemini uses Google Application Default Credentials and cannot run as a \
          person API key account")
  | ( ( Runtime_schema.Messages_api
      | Runtime_schema.Chat_completions_api
      | Runtime_schema.Ollama_api
      | Runtime_schema.Gemini_api )
    , None
    , Key _ ) ->
    (match
       Authz_types.Provider_account_id.of_string provider_id,
       Authz_types.Integration_id.of_string template
     with
     | Error _, _ -> Error (Not_materialized "person HTTP account provider_id is invalid")
     | _, Error _ -> Error (Not_materialized "person HTTP account integration_id is invalid")
     | Ok provider_account_id, Ok integration_id ->
       let* runtime =
         Runtime_person_template.materialize_person_binding
           config
           ~provider
           ~binding
           ~provider_account_id
           ~integration_id
           ~account_home:None
       in
       (* Execution stays strictly [seal_person_api] without credentials; preserve
          the verified key-file path on the metadata provider field for callers
          inspecting [of_template]'s account binding. *)
       Ok { runtime with provider = { runtime.provider with credentials } })
  | ( ( Runtime_schema.Codex_app_server_runtime
      | Runtime_schema.Claude_code_runtime
      | Runtime_schema.Antigravity_cli_runtime
      | Runtime_schema.Muse_serve_runtime
      | Runtime_schema.Vibe_cli_runtime )
    , None
    , (Login | Key _) ) ->
    Error (Not_materialized "official client account requires an account home")
  | ( ( Runtime_schema.Codex_app_server_runtime
      | Runtime_schema.Claude_code_runtime
      | Runtime_schema.Antigravity_cli_runtime
      | Runtime_schema.Muse_serve_runtime
      | Runtime_schema.Vibe_cli_runtime )
    , Some home
    , (Login | Key _) ) ->
    materialize_single_runtime
      config
      ~provider
      ~binding
      ~provider_id
      ~account_home:(Some home)
      ~credentials
;;

let of_person_template = Runtime_person_template.of_person_template
