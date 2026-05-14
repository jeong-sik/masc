(** Cascade provider metadata read from [cascade.toml].

    This is the MASC-local overlay for runtime metadata that should not expand
    the legacy [Provider_adapter] surface. *)

val telemetry_bucket_of_provider_label : string -> string option

val telemetry_bucket_of_model_id : string -> string option

type tool_policy_metadata =
  { supports_runtime_mcp_http_headers : bool
  ; requires_per_keeper_bridging_for_bound_actor_tools : bool
  ; identity_runtime_mcp_header_keys : string list
  ; argv_prompt_preflight : bool
  ; uses_anthropic_caching : bool
  ; max_turns_per_attempt : int option
  ; tolerates_bound_actor_fallback : bool
  }

val tool_policy_metadata_of_provider_label : string -> tool_policy_metadata option

val provider_requires_argv_prompt_preflight :
  Llm_provider.Provider_config.t -> bool

val reset_cache_for_test : unit -> unit
