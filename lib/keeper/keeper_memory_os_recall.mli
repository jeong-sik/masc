(** Render the exact LLM-selected current Memory OS snapshot.

    Recall reads the same snapshot as the dashboard and injects every current
    fact in stored order. It has no count cap, byte budget, recency selection,
    episode fallback, or deterministic importance policy. *)

val render_context
  :  keeper_id:string
  -> now:float
  -> unit
  -> string

val enabled : unit -> bool

val render_if_enabled
  :  keeper_id:string
  -> now:float
  -> trace_id:string
  -> turn:int
  -> masc_root:string
  -> unit
  -> string option
