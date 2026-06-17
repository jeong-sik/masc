(** Runtime admission helpers for keeper turn driver.

    Admission system removed: this module now contains only provider
    candidate mapping utilities. *)

val release_client_capacity_quietly : (unit -> unit) option -> unit
val provider_config_identity_key : Llm_provider.Provider_config.t -> int

val runtime_candidates_of_providers :
  (Llm_provider.Provider_config.t * int option) list ->
  Runtime_candidate.t list
