(** Cascade tier admission helpers for keeper turn driver. *)

val keeper_cascade_tier_admission : Cascade_tier_admission.t

val cascade_tier_admission_policy_of_priority :
  Llm_provider.Request_priority.t -> Cascade_tier_admission.admission_policy

val keeper_cascade_wait_scheduler :
  Cascade_tier_wait_scheduler.t

val with_keeper_cascade_tier_admission :
  ?admission:Cascade_tier_admission.t ->
  ?wait_scheduler:Cascade_tier_wait_scheduler.t ->
  ?enabled:bool ->
  ?sw:Eio.Switch.t ->
  ?wait_timeout_sec:float ->
  tier_id:Cascade_tier_admission.tier_id ->
  admission_policy:Cascade_tier_admission.admission_policy ->
  (unit -> 'a) ->
  ('a, Cascade_saturation_signal.t) result
(** When [?sw] is provided and wait is enabled (env flag), uses bounded
    wait with backoff.  Otherwise falls back to non-blocking admission.

    RFC-0192 § 2: when [?wait_timeout_sec] is provided, the value is
    converted to a {!Cascade_deadline.t} relative to the wait scheduler's
    clock and passed to {!Cascade_tier_wait_scheduler.try_admission_or_wait}
    as the deadline. The per-attempt timeout becomes
    [min (env amplifier) (deadline - now)] — fixing the per-attempt fresh
    timeout accumulation that issue #18845 documents.

    Backward-compat: omitting [?wait_timeout_sec] (or when the scheduler
    has no clock) yields the legacy [env amplifier] behaviour. *)

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
