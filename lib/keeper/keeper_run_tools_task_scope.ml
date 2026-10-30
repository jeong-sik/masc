(** Task-scope tool name helpers extracted from keeper_run_tools.ml.

    Pure helpers for selecting task_id-scoped tools and extracting the
    task_id from a tool input JSON object. *)

let task_scope_tool_names =
  [ "masc_transition"
  ; "keeper_task_done"
  ]
;;


let task_id_scope_of_tool_input ~tool_name input =
  if List.mem tool_name task_scope_tool_names
  then Json_util.get_string_nonempty input "task_id"
  else None
;;

let current_task_id_of_meta (meta : Keeper_meta_contract.keeper_meta) =
  Option.map Keeper_id.Task_id.to_string meta.current_task_id
;;

let task_id_scope_of_tool_call ~tool_name ~input ~meta =
  Dashboard_utils.first_some
    (task_id_scope_of_tool_input ~tool_name input)
    (current_task_id_of_meta meta)
;;
