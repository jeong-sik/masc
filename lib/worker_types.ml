(** Worker execution types.

    Contains only the types actively used by the worker execution layer.

    Issue #8609: removed [wait_mode] type + helpers — zero OCaml callers
    (TS dashboard has its own independent type). *)

type worker_class =
  | Worker_manager
  | Worker_executor
  | Worker_scout
  | Worker_librarian
  | Worker_metacog

let worker_class_to_string = function
  | Worker_manager -> "manager"
  | Worker_executor -> "executor"
  | Worker_scout -> "scout"
  | Worker_librarian -> "librarian"
  | Worker_metacog -> "metacog"

let worker_class_of_string = function
  | "manager" -> Some Worker_manager
  | "executor" -> Some Worker_executor
  | "scout" -> Some Worker_scout
  | "librarian" -> Some Worker_librarian
  | "metacog" -> Some Worker_metacog
  | _ -> None
