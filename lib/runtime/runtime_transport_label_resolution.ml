(** Model-label resolution errors + resolver, extracted from
    runtime_transport.ml.

    Maps a string label to a {!Llm_provider.Provider_config.t} via
    {!Runtime_model_string.parse_model_string}; unresolved labels become
    [Error (Invalid_model_label _)]. Only a defaultless Ollama [auto] may use
    discovery scoped to its exact endpoint; no other provider's model is inferred. *)

type label_resolution_error = Invalid_model_label of string

let label_resolution_error_to_string = function
  | Invalid_model_label label -> Printf.sprintf "invalid model label %S" label
;;

let label_resolution_error_to_core_error err =
  Agent_core.Error.Config
    (Agent_core.Error.InvalidConfig
       { field = "model_label"; detail = label_resolution_error_to_string err })
;;

let resolve_provider_config_of_label (label : string)
  : (Llm_provider.Provider_config.t, label_resolution_error) result
  =
  match Runtime_model_string.parse_model_string label with
  | Some pc -> Ok pc
  | None ->
    Log.Runtime_agent.error "refusing unresolved explicit model label=%S; no declared default or exact-endpoint discovery result"
      label;
    Error (Invalid_model_label label)
;;

let invalid_runtime_config field detail =
  Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; detail })
;;
