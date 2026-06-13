(** Runtime-boundary projection for provider credential metadata.

    MASC auth code receives an already-resolved provider kind from the runtime
    layer. OAS still owns the concrete provider-kind vocabulary and default
    API-key environment variable mapping; this module is the narrow boundary
    that projects those OAS facts into auth without exposing provider/model
    parsing to masc-core callers. *)

val api_key_env_var_for_kind :
  Llm_provider.Provider_config.provider_kind -> string option

val provider_kind_label :
  Llm_provider.Provider_config.provider_kind -> string
