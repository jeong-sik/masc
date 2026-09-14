(** The keeper's reading of a tool's {!Tool_outcome_declaration}: the
    declaration a handler put in its result metadata, carried to the hooks as
    the agent-core tool output's [_meta], mapped onto {!Keeper_tool_outcome.t}.
    The hooks keep the output content opaque; the declaration travels beside
    it, typed, and a tool that declared nothing is read as [None] rather than
    guessed from its bytes. *)

val declared : Yojson.Safe.t option -> Keeper_tool_outcome.t option
