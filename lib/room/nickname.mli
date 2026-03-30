(** Nickname generator for MASC agents — Docker-style adjective+animal. *)

val generate : string -> string
(** [generate agent_type] returns a nickname like "swift-fox-a3b". *)

val is_generated_nickname : string -> bool
(** [is_generated_nickname name] returns true if [name] matches the generated pattern. *)

val generate_unique : string -> string
(** [generate_unique agent_type] returns a nickname with a random hex suffix. *)

val extract_agent_type : string -> string option
(** [extract_agent_type name] extracts the agent_type prefix from a generated nickname. *)
