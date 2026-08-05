(** Render the exact LLM-selected current Memory OS snapshot.

    Recall reads the same snapshot as the dashboard and injects every current
    fact in stored order when the exact rendered fact payload fits the Memory OS
    byte budget. Oversized persisted state fails closed with explicit unavailable
    evidence; recall never truncates, ranks, or partially injects facts. *)

val render_context
  :  keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> unit
  -> string

val enabled : unit -> bool

val render_if_enabled
  :  keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> unit
  -> string option
