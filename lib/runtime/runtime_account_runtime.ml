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
    Printf.sprintf "no binding of the provider %s makes the Runtime %s on this account" template runtime_id
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

let of_template (config : Runtime_schema.config) ~template ~provider_id ~account_home ~binding:choice =
  match template_binding config ~template ~provider_id choice with
  | Error error -> Error error
  | Ok (provider, binding) ->
    let id = Runtime_schema.binding_key binding in
    let alone =
      { config with
        providers = [ { provider with id = provider_id; account_home = Some account_home; enabled = true } ]
      ; bindings = [ binding ]
      ; default_runtime_id = Some id
      ; keeper_assignments = []
      ; media_failover = []
      ; lane_decls = []
      ; exact_output_lane_decls = []
      }
    in
    (match Runtime.runtimes_of_config alone with
     | Error failure ->
       Error (Not_materialized (Runtime_config_error.to_diagnostic_text ~config_path:config_label failure))
     | Ok runtimes ->
       (match List.find_opt (fun (runtime : Runtime_instance.t) -> String.equal runtime.id id) runtimes with
        | Some runtime -> Ok runtime
        | None -> Error (Not_materialized ("no runtime " ^ id ^ " was materialized"))))
;;
