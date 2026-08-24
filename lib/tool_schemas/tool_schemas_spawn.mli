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
type definition =
  { action : action
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
  }

(** Every spawn schema, in declaration order. This is what a tool surface
    advertises. *)
val schemas : Masc_domain.tool_schema list

(** [find_definition name] is the declaration whose schema carries [name], or
    [None] when no spawn tool answers to it. Dispatch matches on the returned
    [action] rather than on the name again, so a renamed tool moves in one
    place. *)
val find_definition : string -> definition option
