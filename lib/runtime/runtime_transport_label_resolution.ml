(** Model-label resolution errors + resolver, extracted from
    runtime_transport.ml.

    Maps a string label to a {!Llm_provider.Provider_config.t} via
    {!Runtime_model_string.parse_model_string}; unresolved labels become
    [Error (Invalid_model_label _)] — execution never falls back to
    discovery-only models. *)

type label_resolution_error = Invalid_model_label of string

let label_resolution_error_to_string = function
  | Invalid_model_label label -> Printf.sprintf "invalid model label %S" label
;;

let label_resolution_error_to_sdk_error err =
  Agent_sdk.Error.Config
    (Agent_sdk.Error.InvalidConfig
       { field = "model_label"; detail = label_resolution_error_to_string err })
;;

let resolve_provider_config_of_label (label : string)
  : (Llm_provider.Provider_config.t, label_resolution_error) result
  =
  match Runtime_model_string.parse_model_string label with
  | Some pc -> Ok pc
  | None ->
    Log.Oas_worker_exec.error "refusing unresolved explicit model label=%S; execution never falls back to \
       discovery-only models"
      label;
    Error (Invalid_model_label label)
;;

let invalid_runtime_config field detail =
  Agent_sdk.Error.Config (Agent_sdk.Error.InvalidConfig { field; detail })
;;
