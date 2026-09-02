(** The process-shared "why did the last turn stop" cell, keyed by base path
    and keeper name.

    [Keeper_heartbeat_loop_cycle.run_keeper_cycle] is the single writer: it
    records [Some checkpoint_reason] when a turn checkpoints and [None] for
    every other outcome, only when a cycle actually ran — a skipped cadence
    leaves the last real turn's reason in place. Every lane reads the same
    cell, so a yield on one lane (direct/TUI-attached, reactive) is visible
    to the next turn on any other lane. The state is process-local: a
    restart starts it empty, same as the ref it replaced. *)
val set :
  base_path:string -> keeper:string -> Keeper_turn_checkpoint_reason.t option -> unit
(** [set ~base_path ~keeper stop] overwrites the cell. [None] clears it. *)

val get :
  base_path:string -> keeper:string -> Keeper_turn_checkpoint_reason.t option
(** [get ~base_path ~keeper] is the recorded stop, [None] when nothing ran or
    the last turn completed. *)
