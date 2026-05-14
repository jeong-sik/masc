(** Projection helpers for OAS runtime provider bindings.

    OAS owns provider identity, transport defaults, auth hints, and
    capability truth. MASC projects those bindings into its local adapter
    policy without exposing Provider_adapter's record types here. *)

type binding = Agent_sdk.Provider_runtime_binding.t

val all : unit -> binding list
val id : binding -> string
val command : binding -> string option
val labels : binding -> string list
val find_by_candidates : string list -> binding option
val find_unique_by_kind : Llm_provider.Provider_config.provider_kind -> binding option
val endpoint_url : binding -> string option
val default_model_id : binding -> string option
val primary_api_key_env : binding -> string option
val auth_env_keys : binding -> string list
val runtime_kind : binding -> [ `Local | `Cli_agent | `Direct_api ]
val supports_runtime_mcp_http_headers : binding -> bool
val uses_prompt_caching : binding -> bool
val usage_missing_by_design : binding -> bool
val provider_config : ?model:string -> binding -> Llm_provider.Provider_config.t
