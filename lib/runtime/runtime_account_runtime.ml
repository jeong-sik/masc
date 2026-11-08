type error =
  | Template_not_declared of string
  | Model_not_bound of
      { template : string
      ; model : string
      }
  | Not_materialized of string

let error_to_string = function
  | Template_not_declared template -> Printf.sprintf "no provider %s is declared" template
  | Model_not_bound { template; model } ->
    Printf.sprintf "the provider %s has no binding of the model %s" template model
  | Not_materialized diagnostic -> "the runtime of the account does not load: " ^ diagnostic
;;

(* The label a load diagnostic names the configuration by: it is no file. *)
let config_label = "the runtime of one account"

let of_template (config : Runtime_schema.config) ~template ~provider_id ~account_home ~model =
  match
    List.find_opt (fun (provider : Runtime_schema.provider) -> String.equal provider.id template) config.providers
  with
  | None -> Error (Template_not_declared template)
  | Some provider ->
    (match
       List.find_opt
         (fun (binding : Runtime_schema.binding) ->
           String.equal binding.provider_id template && String.equal binding.model_id model)
         config.bindings
     with
     | None -> Error (Model_not_bound { template; model })
     | Some binding ->
       let binding = { binding with provider_id; enabled = true } in
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
           | None -> Error (Not_materialized ("no runtime " ^ id ^ " was materialized")))))
;;
