(** Keeper_name_codec — the keeper<->agent name spellings, in one place.

    Both directions of the runtime keeper-agent identity convention. Lives
    in [masc_core] so the keeper and workspace layers share one codec
    instead of carrying drifting copies. *)

val keeper_name_of_agent_alias : string -> string option
(** Parse a keeper name out of an agent alias, accepting the four affix
    spellings ([keeper-x-agent], [keeper_x_agent], [keeper-x_agent],
    [keeper_x-agent]). [None] when the name is not an alias or the
    embedded keeper name is not a portable identifier. *)

val strip_keeper_prefix : string -> string option
(** ["keeper-<rest>"] -> [Some rest]; [None] otherwise. *)

val keeper_agent_name : string -> string
(** Render the canonical agent name for a keeper: ["keeper-<name>-agent"].
    Accepts an already-prefixed keeper name without doubling the prefix. *)
