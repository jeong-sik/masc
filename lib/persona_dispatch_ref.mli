(** RFC-0182 §3.1 — persona dispatch dependency inversion ref.

    Same pattern as [Coord_dispatch_ref]. The persona cluster
    handlers in [Keeper_persona] / [Keeper_persona_authoring] are
    pure with respect to keeper context but the modules themselves
    transitively import [Keeper_turn] / [Keeper_turn_driver], which
    sit late in module order (deep in the keeper chain).
    [Agent_tool_in_process_runtime] is compiled early, so a direct
    static import closes a cycle.

    Resolution: register from a late module ([Tool_keeper]) into the
    ref at module load.  [Agent_tool_in_process_runtime] reads the
    ref at dispatch time. *)

val dispatch
  : (name:string -> args:Yojson.Safe.t -> Tool_result.result option) ref
