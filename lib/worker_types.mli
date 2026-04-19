(** Worker execution types.

    Contains only the types actively used by the worker execution layer:
    [execution_scope] and [worker_class].

    Issue #8609: [wait_mode] type + helpers removed — zero OCaml callers.
    Issue #8605: [_of_string_opt] variants reject unknowns with [None]
    rather than silently routing to a valid constructor. *)

type execution_scope =
  | Observe_only
  | Limited_code_change
  | Autonomous

type worker_class =
  | Worker_manager
  | Worker_executor
  | Worker_scout
  | Worker_librarian
  | Worker_metacog

val execution_scope_to_string : execution_scope -> string

(** Accepts only the 3 wire-format names (["observe_only"],
    ["limited_code_change"], ["autonomous"]). Any other input — including
    capitalised typos or fabricated values — returns [None]. Callers
    must handle [None] explicitly (see issue #8605). *)
val execution_scope_of_string_opt : string -> execution_scope option

val worker_class_to_string : worker_class -> string

val worker_class_of_string : string -> worker_class option
