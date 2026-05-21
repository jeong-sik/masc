(** Model-label resolution helpers for cascade transport. *)

type label_resolution_error = Invalid_model_label of string

val label_resolution_error_to_string : label_resolution_error -> string
val label_resolution_error_to_sdk_error : label_resolution_error -> Agent_sdk.Error.sdk_error

val resolve_provider_config_of_label :
  string -> (Llm_provider.Provider_config.t, label_resolution_error) result

val invalid_runtime_config : string -> string -> Agent_sdk.Error.sdk_error
