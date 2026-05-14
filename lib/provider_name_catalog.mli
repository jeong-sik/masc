(** MASC-local provider/client literal catalog.

    This module is intentionally private to the library. It gives code that is
    still MASC-owned a narrow boundary for provider/client wire strings without
    widening the legacy [Provider_adapter] API. *)

val cn_claude : string
val cn_kimi : string
val configured_kimi_api_key_env_hint : string
val claude_cli_exit_code_1 : string

val kimi_cli_auth_env_keys : string list
val kimi_cli_runtime_api_key_env : string
val kimi_cli_base_url : unit -> string
val kimi_cli_config_provider_name : string
val kimi_cli_config_provider_type : string
val kimi_cli_executable : string
val kimi_cli_process_name : string
val kimi_cli_default_model : string
val kimi_cli_response_id_fallback : string
val kimi_cli_exit_code_prefix : string
val kimi_cli_resumable_session_detail : string

val headers_with_auth_for_provider_kind
  :  kind:Llm_provider.Provider_config.provider_kind
  -> api_key:string
  -> (string * string) list

val inference_model_bucket : provider:string -> model:string -> string
