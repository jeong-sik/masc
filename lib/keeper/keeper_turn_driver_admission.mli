(** Cascade admission helpers for keeper turn driver.

    Admission system removed: this module now contains only provider
    candidate mapping utilities. *)

val release_client_capacity_quietly : (unit -> unit) option -> unit
val provider_config_identity_key : Llm_provider.Provider_config.t -> int

val runtime_candidates_of_providers :
  Cascade_catalog_runtime_named_providers.tiered_provider list ->
  Llm_provider.Provider_config.t list ->
  Cascade_runtime_candidate.t list
