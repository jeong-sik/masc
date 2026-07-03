(** Keeper_supervisor_types — pure type definitions and helpers extracted
    from Keeper_supervisor (2632 LoC godfile).

    Holds cohort + persona-drift types + their pure helpers. State-touching
    supervisor operations remain in Keeper_supervisor. Re-included by
    Keeper_supervisor so existing callers continue to use
    [Keeper_supervisor.supervision_cohort] etc. unchanged. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val supervisor_agent_name : string
(** Agent identity used by supervisor-owned Workspace mutations. *)

val supervision_cohort_size : int
(** Target keeper count per supervisor cohort.  The first 2-level
    supervision slice groups the 64-keeper fleet as 8 cohorts of 8. *)

type supervision_cohort = {
  cohort_id : int;
  keepers : Keeper_registry.registry_entry list;
}
(** Deterministic keeper cohort used by the supervisor sweep. *)

val supervision_cohorts :
  ?cohort_size:int ->
  Keeper_registry.registry_entry list ->
  supervision_cohort list
(** Sort and chunk registry entries into deterministic supervisor cohorts.
    [cohort_size <= 0] is coerced to 1. *)

val fresh_supervision_cohort_keepers :
  base_path:string ->
  supervision_cohort ->
  Keeper_registry.registry_entry list
(** Re-read a cohort's keeper entries from the registry by name. Entries that
    disappeared since the original sweep snapshot are omitted. *)

val iter_supervision_cohorts :
  ?yield_between:(unit -> unit) ->
  supervision_cohort list ->
  f:(supervision_cohort -> unit) ->
  unit
(** Iterate cohorts in order and yield only between cohort boundaries. *)

type persona_drift_log_level =
  | Persona_drift_warn
  | Persona_drift_error

val persona_drift_log_level_for_missing_profile :
  keeper_meta -> persona_drift_log_level
(** Classify a missing persona profile.  Keeper TOML with enough inline
    identity remains operational and is WARN; keepers without TOML/persona
    identity are ERROR. *)

val should_cleanup_dead :
  now:float -> dead_ttl_sec:float -> Keeper_registry.registry_entry -> bool
(** True when a Dead tombstone has exceeded the configured TTL. *)

val is_stale_paused_meta :
  now:float -> paused_ttl_sec:float -> keeper_meta -> bool
(** Check if a paused keeper meta file on disk is stale enough to remove. *)

val paused_meta_requires_reconcile_recovery : keeper_meta -> bool
(** Internal: predicate identifying paused metas whose last_blocker class
    requires reconcile-recovery rather than straight resume. *)

val paused_meta_auto_resume_due : now:float -> keeper_meta -> bool
(** True when [meta] is an auto-paused keeper whose self-healing backoff has
    elapsed.  Intentional/operator pauses and reconcile-gated pauses are
    excluded.  Dead-tombstone cleanup pauses are also terminal and never
    auto-resumed.  Explicit [auto_resume_after_sec] is preferred; legacy
    [Turn_timeout] blocker metadata without that field uses the current initial
    auto-resume backoff so old timeout pauses do not become permanent operator
    pauses.  This predicate deliberately does not inspect runtime health or
    approval queues; callers that can see those runtime surfaces must still
    apply them before mutating state. *)

val paused_meta_effective_auto_resume_after_sec : keeper_meta -> float option
(** Effective auto-resume delay used by supervisor and health JSON.  Returns
    the persisted value when present, otherwise the implicit legacy timeout
    delay when the last blocker proves the pause was an auto-recoverable turn
    timeout. *)

val cohort_key_of_reason : Keeper_registry.failure_reason option -> string
(** Map a structured failure_reason to a cohort key for self-preservation grouping. *)

val stale_turn_timeout_cohort_key : string
(** Internal: pre-computed cohort key for [Stale_turn_timeout] used by the
    self-preservation probe escape valve. *)

val active_supervision_keeper_count :
  Keeper_registry.registry_entry list -> int
(** Count currently active keepers for self-preservation denominators. *)

val next_auto_resume_after_sec :
  initial_sec:float -> max_sec:float -> float option -> float option
(** Compute the next auto-resume backoff delay after an auto-pause.  [None]
    means this is the first auto-pause; [Some sec] means the previous
    backoff should double up to [max_sec].  [initial_sec <= 0] disables
    auto-resume. *)
