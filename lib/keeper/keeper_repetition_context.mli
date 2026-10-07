(** Context projection of repetition evidence, independent of turn results
    and dispatch. None of these operations commits a durable checkpoint. *)
val load : Agent_core.Context.t ->
  (Keeper_repetition_snapshot.t, Keeper_repetition_snapshot.error) result
val save : Agent_core.Context.t -> Keeper_repetition_snapshot.t -> unit
val install : target:Agent_core.Context.t -> Keeper_repetition_snapshot.t ->
  (unit, Keeper_repetition_snapshot.error) result
val restore : source:Agent_core.Context.t -> target:Agent_core.Context.t ->
  (Keeper_repetition_snapshot.t, Keeper_repetition_snapshot.error) result
