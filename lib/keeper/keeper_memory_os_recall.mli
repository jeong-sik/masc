(** Render the exact LLM-selected current Memory OS snapshot.

    Recall reads the same snapshot as the dashboard and injects every current
    fact in stored order when the exact rendered fact payload fits the Memory OS
    byte budget. Recall never truncates, ranks, or partially injects facts.

    Oversized persisted state, a read error, and an empty store all produce the
    same turn: no recall block. The reason is emitted to the operator as the
    [MemoryOsRecallUnavailable] counter and a warn log; it is not stated to the
    keeper, which is never told that its memory is missing. *)

val render_context
  :  keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> unit
  -> string

val enabled : unit -> bool

val render_if_enabled
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> unit
  -> string option
