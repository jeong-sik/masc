(** Nickname generator for MASC agents — Docker-style adjective+animal. *)

(** [generate agent_type] returns a nickname like "swift-fox-a3b". *)
val generate : string -> string

(** [is_generated_nickname name] returns true if [name] matches the generated pattern. *)
val is_generated_nickname : string -> bool

(** [generate_unique agent_type] returns a nickname with a random hex suffix. *)
val generate_unique : string -> string

(** [extract_agent_type name] extracts the stable agent prefix from a generated nickname. *)
val extract_agent_type : string -> string option
