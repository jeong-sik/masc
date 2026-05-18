(** Provider-list filtering + context-window helpers.

    Extracted from [cascade_config.ml]. Owns capability-based filtering
    ({!filter_by_capabilities}), explicit-kind filtering
    ({!apply_provider_filter}, {!apply_provider_filter_strict}), and the
    per-slot context resolution path shared with the provider registry.

    The strict filter rejection variant ({!provider_filter_rejection}) is
    defined here and aliased by {!Cascade_config} so the facade contract
    stays unchanged.

    @stability Internal *)

val effective_max_context :
  Llm_provider.Provider_registry.entry ->
  Llm_provider.Capabilities.capabilities ->
  int

val resolve_label_context : string -> int option

val filter_by_capabilities :
  pred:(Llm_provider.Capabilities.capabilities -> bool) ->
  Llm_provider.Provider_config.t list ->
  Llm_provider.Provider_config.t list

val text_of_response : Llm_provider.Types.api_response -> string

type provider_filter_rejection =
  | Filter_matched_none of { filter : string list; available_kinds : string list }

val provider_filter_rejection_to_string : provider_filter_rejection -> string

val apply_provider_filter :
  provider_filter:string list option ->
  label:string ->
  Llm_provider.Provider_config.t list ->
  Llm_provider.Provider_config.t list

val apply_provider_filter_strict :
  provider_filter:string list option ->
  label:string ->
  Llm_provider.Provider_config.t list ->
  (Llm_provider.Provider_config.t list, provider_filter_rejection) result
