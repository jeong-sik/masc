(** Model-label resolution for runtime runtime transport. *)

type label_resolution_error = Invalid_model_label of string

val resolve_provider_config_of_label :
  string -> (Llm_provider.Provider_config.t, label_resolution_error) result
