(** Process-local memory of the last prompt byte capacity that completed a
    turn successfully for a given (keeper, runtime) pair on an
    official-client lane, which cuts its seed history against a declared
    prompt byte cap. See the [.ml] for the #27320 rationale. Not durable.
    The Agent Core lane keeps no such memory: its carried range lives in
    {!Keeper_model_input_ledger}. *)

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

module For_testing : sig
  val reset : unit -> unit
end
