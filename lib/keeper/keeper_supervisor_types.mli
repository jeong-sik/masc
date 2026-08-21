(** Keeper_supervisor_types — pure type definitions and helpers extracted
    from Keeper_supervisor (2632 LoC godfile).

    Holds cohort types and their pure helpers. State-touching
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
