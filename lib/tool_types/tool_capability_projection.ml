type task_list =
  | External_masc_tasks
  | Keeper_tasks_list

let task_list_name = function
  | External_masc_tasks -> "masc_tasks"
  | Keeper_tasks_list -> "keeper_tasks_list"
;;
