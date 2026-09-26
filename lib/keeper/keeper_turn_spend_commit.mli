(** The commit of a Keeper turn that ends outside the success path.

    Such a turn already wrote under its keeper turn id (manifest, receipt,
    turn record, FSM) and spent what its attempts read. Both lanes end it
    here: the autonomous cycle's failure and preemption, and every direct
    lane exit after the run. The success path settles in
    {!Keeper_unified_turn_success}. *)

type error =
  | Keeper_removed  (** The Owner removed the Keeper's metadata during the commit. *)
  | Commit_rejected of Keeper_owner_registry.command_error

val error_to_string : error -> string

val count_turn : Keeper_meta_contract.keeper_meta -> Keeper_meta_contract.keeper_meta
(** [meta] with the turn counted and its time stamped, so the next turn does
    not write under the same keeper turn id. Nothing else moves: no failure,
    latency or proactive bookkeeping. *)

val commit
  :  config:Workspace.config
  -> keeper_turn_id:int
  -> before:Keeper_meta_contract.keeper_meta
  -> attempt_spend:Keeper_turn_spend.attempt list
  -> Keeper_meta_contract.keeper_meta
  -> (Keeper_meta_contract.keeper_meta, error) result
(** [commit ~config ~keeper_turn_id ~before ~attempt_spend after] resolves
    every reading of [attempt_spend] against the cursor [before] holds, adds
    the spend and the cursor it leaves to [after], and commits [after] over
    [before] through the Keeper's Owner. Only a commit that holds writes the
    resolved rows under [keeper_turn_id]; a failed one writes none, so the
    next turn, resolving from the same cursor, does not count them twice. *)
