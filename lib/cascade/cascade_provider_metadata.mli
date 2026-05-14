(** Cascade provider metadata read from [cascade.toml].

    This is the MASC-local overlay for runtime metadata that should not expand
    the legacy [Provider_adapter] surface. *)

val telemetry_bucket_of_provider_label : string -> string option

val telemetry_bucket_of_model_id : string -> string option

val provider_requires_argv_prompt_preflight :
  Llm_provider.Provider_config.t -> bool

val reset_cache_for_test : unit -> unit
