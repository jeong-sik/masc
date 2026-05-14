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
val supported_models : binding -> string list
val available : binding -> bool
val auth_kind : binding -> string
val primary_api_key_env : binding -> string option
val auth_env_keys : binding -> string list
val runtime_kind : binding -> [ `Local | `Cli_agent | `Direct_api ]
val supports_runtime_mcp_http_headers : binding -> bool
val uses_prompt_caching : binding -> bool
val usage_missing_by_design : binding -> bool
val resolve_model : ?requested_model:string -> binding -> string
val provider_config : ?model:string -> binding -> Llm_provider.Provider_config.t

(** Per-provider per-attempt timeout bounds projected from OAS
    [Provider_config] defaults plus local compatibility semantics.

    [min_timeout_s] floors too-short caller budgets for cold local runtimes.
    [max_timeout_s] caps providers that should not block past a known hard
    ceiling. *)
type timeout_bounds =
  { min_timeout_s : float option
  ; max_timeout_s : float option
  }

val timeout_bounds_of_kind :
  Llm_provider.Provider_config.provider_kind -> timeout_bounds

val max_turns_hard_cap : Llm_provider.Provider_config.provider_kind -> int option
val clamp_max_turns : Llm_provider.Provider_config.provider_kind -> int -> int
