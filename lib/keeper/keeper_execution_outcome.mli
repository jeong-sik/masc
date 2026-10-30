(** Normalized successful Keeper execution boundary.

    A provider run is not yet a product terminal.  This value keeps the
    response surface, checkpoint/durability evidence, lifecycle input, and
    optional delivery obligation attached to the exact run result while also
    declaring which outer lane owns the terminal consumer.  Direct chat and
    autonomous wake paths must both pass this value to the common terminal
    pipeline. *)

type lane =
  | Direct
  | Autonomous of Keeper_world_observation.keeper_cycle_channel

type terminal =
  | Completed
  | Checkpointed
  | Input_required

type t

val create : lane:lane -> Keeper_agent_run.run_result -> t

val lane : t -> lane
val result : t -> Keeper_agent_run.run_result
val response_text : t -> string

val completion_contract_result
  :  t
  -> Keeper_execution_receipt.completion_contract_result

val terminal : t -> terminal
val is_autonomous : t -> bool

val metrics_channel
  :  t
  -> Keeper_world_observation.keeper_cycle_channel
(** Direct chat is projected through the reactive metrics channel. *)
