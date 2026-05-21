(** Cascade tier admission helpers for keeper turn driver. *)

val keeper_cascade_tier_admission : Cascade_tier_admission.t

val cascade_tier_admission_policy_of_priority :
  Llm_provider.Request_priority.t ->
  Cascade_tier_admission.admission_policy

val with_keeper_cascade_tier_admission :
  ?admission:Cascade_tier_admission.t ->
  ?enabled:bool ->
  tier_id:string ->
  admission_policy:Cascade_tier_admission.admission_policy ->
  (unit -> 'a) ->
  ('a, Cascade_saturation_signal.t) result

val cascade_tier_admission_blocked_decision :
  Cascade_saturation_signal.t -> Yojson.Safe.t

val emit_cascade_tier_admission_signal_metric :
  cascade_name:string -> Cascade_saturation_signal.t -> unit

val release_client_capacity_quietly : (unit -> unit) option -> unit

val provider_config_identity_key : Llm_provider.Provider_config.t -> int

val runtime_candidates_of_tiered_providers :
  Cascade_catalog_runtime_named_providers.tiered_provider list ->
  Llm_provider.Provider_config.t list ->
  Cascade_runtime_candidate.t list
