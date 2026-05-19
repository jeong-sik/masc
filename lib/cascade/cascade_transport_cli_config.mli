val cli_model_override : string -> string option
val provider_label : Llm_provider.Provider_config.t -> string
val cli_model_for_provider_config : Llm_provider.Provider_config.t -> string option
val cli_command_for_provider_config : Llm_provider.Provider_config.t -> string option
val cli_process_name_for_provider_config : Llm_provider.Provider_config.t -> string
val cli_runtime_config_json_for_provider : Llm_provider.Provider_config.t -> string option
val cli_direct_binding_extra_env : Llm_provider.Provider_config.t -> (string * string) list
