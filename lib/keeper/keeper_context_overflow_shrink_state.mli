(** Process-local memory of the last model-input windowing capacity that
    completed a turn successfully for a given (keeper, runtime) pair.
    See the [.ml] for the #27320 rationale. Not durable.

    The unit is the lane's windowing unit: tokens on the AGENT_CORE lane,
    whose window is declared in tokens ([Keeper_context_window]), and bytes
    on the official-client lanes, which cut their seed history against a
    declared prompt byte cap. A runtime id belongs to exactly one lane kind,
    so the two never read each other's entries. *)

val starting_capacity :
  keeper_name:string -> runtime_id:string -> max_capacity:int -> int
(** [starting_capacity ~keeper_name ~runtime_id ~max_capacity] returns the
    remembered last-successful capacity for this (keeper, runtime) pair,
    clamped to never exceed [max_capacity] (the lane's current declared
    window). Returns [max_capacity] itself when nothing is remembered, or
    when the remembered value is stale (non-positive, or now above the
    current declaration). *)

val record_success :
  keeper_name:string -> runtime_id:string -> capacity:int -> unit
(** [record_success ~keeper_name ~runtime_id ~capacity] remembers [capacity]
    as the windowing capacity that last completed a turn for this (keeper,
    runtime) pair. Overwrites any prior value. *)

val forget : keeper_name:string -> runtime_id:string -> unit
(** [forget ~keeper_name ~runtime_id] drops the remembered capacity for this
    (keeper, runtime) pair, so the next turn starts from the lane's declared
    window again. Call it when a turn overflowed at the remembered capacity:
    that outcome disproves the memory, and keeping it would repeat the same
    refusal every turn for the life of the process. *)

module For_testing : sig
  val reset : unit -> unit
end
