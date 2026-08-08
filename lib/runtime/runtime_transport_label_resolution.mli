(** Model-label resolution for runtime runtime transport. *)

type label_resolution_error = Invalid_model_label of string

val label_resolution_error_to_string : label_resolution_error -> string
val label_resolution_error_to_sdk_error : label_resolution_error -> Masc_agent_core.Error.sdk_error

val resolve_provider_config_of_label :
  string -> (Llm_provider.Provider_config.t, label_resolution_error) result

val invalid_runtime_config : string -> string -> Masc_agent_core.Error.sdk_error
