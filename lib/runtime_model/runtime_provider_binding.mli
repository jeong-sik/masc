(** Provider identity helpers.

    All functions are pure with respect to the runtime binding registry and
    {!Llm_provider} SSOTs. No I/O.

    @stability Internal *)

module Runtime_binding = Agent_core.Provider_runtime_binding

val default_headers_for_kind :
  Llm_provider.Provider_config.provider_kind -> (string * string) list
