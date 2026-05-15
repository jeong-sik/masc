(** Keeper_supervisor_types — pure type definitions and helpers extracted
    from Keeper_supervisor (2632 LoC godfile).

    Holds the [supervision_cohort] type + the deterministic-chunking
    [supervision_cohorts] function. State-touching supervisor operations
    remain in Keeper_supervisor. Re-included by Keeper_supervisor so
    existing callers continue to use [Keeper_supervisor.supervision_cohort]
    unchanged. *)

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
