(** The filesystem write mode a Write/Edit call names. One definition for the
    host handler and the remote-lane handler. *)

type t =
  | Overwrite
  | Append
  | Patch

val to_string : t -> string
val of_string_opt : string -> t option
val all : t list

val valid_strings : string list
(** The canonical enum [Tool_shard_types_enum_mirrors.fs_write_mode_enum_strings]
    hand-copies. *)

val of_args : Yojson.Safe.t -> (t, string) result
(** The [mode] member of a Write/Edit call. An absent member, a non-string
    member and an unknown string are all rejected; the [Error] carries the
    spelling seen ([(absent)] when there was none) for the caller's message.
    There is no default: a missing mode must never become a whole-file
    write. *)

val rejection_message : string -> string
(** The Policy_rejection text for a mode {!of_args} rejected. *)
