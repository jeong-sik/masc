(** Typed audience projection for MASC capabilities that have distinct
    external-transport and Keeper-model names. *)

type task_list =
  | External_masc_tasks
  | Keeper_tasks_list

val task_list_name : task_list -> string
