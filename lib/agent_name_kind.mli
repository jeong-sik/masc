(** Agent_name_kind — classifies agent name strings by origin. *)

(** [is_ephemeral name] is [true] when [name] starts with ["agent-"],
    indicating a system-generated, non-stable identity. *)
val is_ephemeral : string -> bool

(** [is_transient name] is [true] when [name] is either ephemeral
    (system-generated) or a dictionary-generated rotation nickname. *)
val is_transient : string -> bool