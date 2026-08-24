(** The spawn tool surface: which four tools exist, what each one's schema is,
    and which of them only reads.

    [Tool_spawn] dispatches on {!action} and looks a tool up by name, so both
    the variant and the record's fields are visible here. [definitions] is not:
    the list is what {!schemas} and {!find_definition} are built from, and a
    caller walking it would be re-deriving one of those two. *)

type action =
  | Start
  | Read
  | Wait
  | Stop

type definition =
  { action : action
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
        (** Whether the tool only observes. [Wait] is [false] despite changing
            nothing: it blocks for a caller-supplied bound, and a surface that
            lets a read-only tool block is one that can be made to hang. *)
  }

val schemas : Masc_domain.tool_schema list
(** Every spawn schema, in declaration order. *)

val find_definition : string -> definition option
(** [find_definition name] is the definition whose schema carries [name], or
    [None] when no spawn tool answers to it. *)
