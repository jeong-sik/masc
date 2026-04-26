(** Nickname generator for MASC agents — Docker-style adjective+animal. *)

val generate : string -> string
(** [generate agent_type] returns a nickname like "swift-fox-a3b". *)

val is_generated_nickname : string -> bool
(** [is_generated_nickname name] returns true if [name] has the 3+ part shape used
    by [generate]. This is permissive — any [a-b-c]-shaped string passes. Used by
    the join/coord_lifecycle path so structured operator fixtures stay acceptable. *)

val is_dictionary_generated_nickname : string -> bool
(** [is_dictionary_generated_nickname name] returns true only when the trailing
    components match the [adjectives]/[animals] word lists. Use on auth paths
    that must distinguish real generated nicknames from structured operator
    names like [keeper-<id>-agent] (avoids the [silent:auth_token_resolve_error]
    storm produced by misclassifying them as transient aliases). *)

val generate_unique : string -> string
(** [generate_unique agent_type] returns a nickname with a random hex suffix. *)

val extract_agent_type : string -> string option
(** [extract_agent_type name] extracts the stable agent prefix from a generated nickname. *)
