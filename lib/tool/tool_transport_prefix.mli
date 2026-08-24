(** The prefix MCP puts on every masc tool name on the wire.

    The literal lived in four places -- [Capability_registry.prefixed_tool_names]
    built names with it, [Tool_dispatch.surface_of_tool_name] and
    [Keeper_tool_descriptor_resolution] detected it, and [Tool_misc] removed it
    -- and the two removers disagreed. One required a non-empty remainder, the
    other did not, so a bare ["mcp__masc__"] came back unchanged from one and
    empty from the other. One of them also spelled the prefix length as the
    literal [11], which a change to the prefix would have left cutting at the
    wrong offset.

    The prefix itself and its length stay inside: a caller that needs either is
    a caller doing the arithmetic here again. *)

val has : string -> bool

val add : string -> string
(** [add name] is the wire spelling of [name]. *)

val strip : string -> string
(** [strip name] removes the prefix when something follows it, and returns
    [name] unchanged otherwise -- including for the bare prefix, which is not a
    tool name and whose stripped form would be the empty string. *)
