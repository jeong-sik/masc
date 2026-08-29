(** Process-local memory of the last model-input windowing capacity that
    completed a turn successfully for a given (keeper, runtime) pair.
    See the [.ml] for the #27320 rationale. Not durable. *)

val starting_capacity_bytes :
  keeper_name:string -> runtime_id:string -> max_capacity_bytes:int -> int
(** [starting_capacity_bytes ~keeper_name ~runtime_id ~max_capacity_bytes]
    returns the remembered last-successful capacity for this (keeper,
    runtime) pair, clamped to never exceed [max_capacity_bytes] (the
    runtime's current declared request-body cap). Returns
    [max_capacity_bytes] itself when nothing is remembered, or when the
    remembered value is stale (non-positive, or now above the current cap). *)

val record_success :
  keeper_name:string -> runtime_id:string -> capacity_bytes:int -> unit
(** [record_success ~keeper_name ~runtime_id ~capacity_bytes] remembers
    [capacity_bytes] as the windowing capacity that last completed a turn
    for this (keeper, runtime) pair. Overwrites any prior value. *)

val forget : keeper_name:string -> runtime_id:string -> unit
(** [forget ~keeper_name ~runtime_id] drops the remembered capacity for this
    (keeper, runtime) pair, so the next turn starts from the runtime's
    declared cap again. Call it when a turn overflowed at the remembered
    capacity: that outcome disproves the memory, and keeping it would repeat
    the same refusal every turn for the life of the process. *)

module For_testing : sig
  val reset : unit -> unit
end
