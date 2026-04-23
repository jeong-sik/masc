(** Worker execution types.

    Contains only the types actively used by the worker execution layer:
    [worker_class].

    Issue #8609: [wait_mode] type + helpers removed — zero OCaml callers.
    *)

type worker_class =
  | Worker_manager
  | Worker_executor
  | Worker_scout
  | Worker_librarian
  | Worker_metacog

val worker_class_to_string : worker_class -> string

val worker_class_of_string : string -> worker_class option
