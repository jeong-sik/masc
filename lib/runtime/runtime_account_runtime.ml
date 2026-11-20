type binding =
  | Model of string
  | Runtime of string

type account =
  | Login
  | Key of { key_file : string }

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
  | Key_missing
  | Key_unreadable of Runtime_api_key_file.unreadable
  | Not_materialized of string

let error_to_string = function
  | Template_not_declared template -> Printf.sprintf "no provider %s is declared" template
  | Model_not_bound { template; model } ->
    Printf.sprintf "the provider %s has no binding of the model %s" template model
  | Runtime_not_bound { template; runtime_id } ->
    Printf.sprintf "no binding of the provider %s makes the Runtime %s on this account" template runtime_id
  | Key_missing -> Runtime_api_key_file.read_error_to_string Runtime_api_key_file.Key_missing
  | Key_unreadable why ->
    Runtime_api_key_file.read_error_to_string (Runtime_api_key_file.Key_unreadable why)
  | Not_materialized diagnostic -> "the runtime of the account does not load: " ^ diagnostic
;;

(* The label a load diagnostic names the configuration by: it is no file. *)
let config_label = "the runtime of one account"

(* A binding of the template, moved onto the account: its Runtime id is the
   one a verification records, so the same function answers both choices. *)
let on_account ~provider_id (binding : Runtime_schema.binding) = { binding with provider_id; enabled = true }

let chosen ~provider_id (binding : Runtime_schema.binding) = function
  | Model model -> String.equal binding.model_id model
  | Runtime runtime_id ->
    String.equal (Runtime_schema.binding_key (on_account ~provider_id binding)) runtime_id

let not_bound ~template = function
  | Model model -> Model_not_bound { template; model }
  | Runtime runtime_id -> Runtime_not_bound { template; runtime_id }

let error_code = function
  | Template_not_declared _ -> "template_not_declared"
  | Model_not_bound _ -> "model_not_bound"
  | Runtime_not_bound _ -> "runtime_not_bound"
  | Key_missing -> Runtime_api_key_file.(read_error_code Key_missing)
  | Key_unreadable why -> Runtime_api_key_file.(read_error_code (Key_unreadable why))
  | Not_materialized _ -> "not_materialized"
;;

(* The provider of the template and its chosen binding, moved onto the
   account. *)
let template_binding (config : Runtime_schema.config) ~template ~provider_id choice =
  match
    List.find_opt (fun (provider : Runtime_schema.provider) -> String.equal provider.id template) config.providers
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
          ; account_home = Some account_home
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
  let* provider, binding = template_binding config ~template ~provider_id choice in
  let* credentials = credentials_of account in
  materialize_single_runtime
    config
    ~provider
    ~binding
    ~provider_id
    ~account_home
    ~credentials
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
  let person_cfg =
    { config with
      providers =
        [ { provider with
            id = provider_id
          ; account_home = Some account_home
          ; credentials = None
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
