(** Agent_name_kind — classifies agent name strings by origin.

    Extracted from [Mcp_server_eio_execute] for reuse across modules.
    Provides predicates for agent-name classification used during
    join-state resolution and identity normalisation. *)

(** [is_ephemeral name] is [true] when [name] starts with ["agent-"],
    indicating a system-generated, non-stable identity. *)
let is_ephemeral name =
  String.starts_with name ~prefix:"agent-"

(** [is_transient name] is [true] when [name] is either ephemeral
    (system-generated) or a dictionary-generated rotation nickname. *)
let is_transient name =
  is_ephemeral name
  || Nickname.is_dictionary_generated_nickname name