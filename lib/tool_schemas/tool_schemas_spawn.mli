(** The spawn tool surface: which four tools exist, what each one declares, and
    which of them a caller may treat as read-only. *)

type action =
  | Start
  | Read
  | Wait
  | Stop

(** [read_only] is the caller's question, not the store's: [Wait] changes
    nothing and is still [false], because a surface that lets a read-only tool
    block for a caller-supplied bound is a surface that can be made to hang.
    The reason lives with the value in [tool_schemas_spawn.ml]. *)
type definition = {
  action : action;
  id : string;  (** the suffix of the descriptor id, [masc.spawn.<id>] *)
  schema : Masc_domain.tool_schema;
  read_only : bool;
}

val definitions : definition list
(** All four. The descriptor list maps over this, so a tool declared here and
    nowhere else still reaches a keeper. *)

val schemas : Masc_domain.tool_schema list
(** [definitions], projected to just the schema each action runs. *)

val find_definition : string -> definition option
(** [find_definition name] is the declaration whose schema carries [name], or
    [None] when no spawn tool answers to it. Dispatch matches on the returned
    [action] rather than on the name again, so a renamed tool moves in one
    place. *)
