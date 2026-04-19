(** Worker execution types.

    Contains only the types actively used by the worker execution layer:
    execution_scope, worker_class, and wait_mode. *)

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

type wait_mode =
  | Wait_background
  | Wait_blocking

let execution_scope_to_string = function
  | Observe_only -> "observe_only"
  | Limited_code_change -> "limited_code_change"
  | Autonomous -> "autonomous"

(* Issue #8605: returns [Some] only for the 3 wire-format names; any
   other input (including typos like "Observe_only" with capitalisation
   or fabricated values) returns [None]. Callers must handle [None]
   explicitly — the previous variant-returning shape silently routed
   unknowns to [Limited_code_change], a *valid* variant, which is silent
   privilege miscategorization. *)
let execution_scope_of_string_opt = function
  | "observe_only" -> Some Observe_only
  | "limited_code_change" -> Some Limited_code_change
  | "autonomous" -> Some Autonomous
  | _ -> None

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

let wait_mode_to_string = function
  | Wait_background -> "background"
  | Wait_blocking -> "blocking"

let wait_mode_of_string = function
  | "blocking" -> Wait_blocking
  | _ -> Wait_background
