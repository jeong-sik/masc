(** Provider identity helpers.

    All functions are pure with respect to the runtime binding registry and
    {!Llm_provider} SSOTs. No I/O.

    @stability Internal *)

module Runtime_binding = Agent_core.Provider_runtime_binding

val local_runtime_label : string -> string

val default_headers_for_kind :
  Llm_provider.Provider_config.provider_kind -> (string * string) list

val normalize_openai_compat_request_path :
  base_url:string -> request_path:string -> string
