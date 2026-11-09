(** Which fleet readings retain their whole cell budgets. *)

type reading =
  | Running
  | Turn_capacity
  | Blocker
  | Proactive_interval

val select :
  cells:int ->
  lead_cells:int ->
  separator_cells:int ->
  (reading * int) list ->
  reading list
(** [select ~cells ~lead_cells ~separator_cells readings] keeps the longest
    prefix whose lead, separators and reading cells fit in [cells]. *)
