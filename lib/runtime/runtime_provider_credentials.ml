(** Runtime-boundary projection for provider credential metadata. *)

let api_key_env_var_for_kind kind =
  Llm_provider.Provider_config.default_api_key_env kind
;;

let provider_kind_label kind =
  Llm_provider.Provider_config.string_of_provider_kind kind
;;
