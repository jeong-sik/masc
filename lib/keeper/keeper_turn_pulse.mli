(** In-memory bounded cache of recent turn outcomes per keeper (RFC-0511 §2.3 S1a).

    Tracks recent autonomous turn execution outcomes ([Turn_ok], [Turn_rested],
    [Turn_failed]) for each keeper up to [max_samples_per_keeper]. Maintained
    in an Atomic map updated via CAS loop so read projections (such as the
    roster row builder running on another domain) observe immutable snapshots. *)

type outcome =
  | Turn_ok
  | Turn_rested
  | Turn_failed

val outcome_to_string : outcome -> string
val outcome_of_string : string -> outcome option

type sample = {
  at : float;
  outcome : outcome;
}

type pulse = {
  samples : sample list;
  truncated : bool;
}

val max_samples_per_keeper : int

val record : base_path:string -> keeper_name:string -> at:float -> outcome -> unit
(** [record ~base_path ~keeper_name ~at outcome] prepends [outcome] at time [at]
    to the keeper's pulse history. If the history exceeds [max_samples_per_keeper],
    older entries are dropped and [truncated] is set to true. *)

val get : base_path:string -> keeper_name:string -> pulse option
(** Returns the recorded pulse history for the given keeper, or [None] if neither
    seeded nor recorded. *)

val seed :
  ?override:bool ->
  base_path:string ->
  keeper_name:string ->
  samples:sample list ->
  truncated:bool ->
  unit ->
  unit
(** [seed ?override ~base_path ~keeper_name ~samples ~truncated ()] seeds the pulse
    cache if the keeper has no entry yet (or unconditionally if [override = true]). *)

val reset_for_tests : unit -> unit
