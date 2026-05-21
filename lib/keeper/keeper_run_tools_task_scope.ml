(** Task-scope tool name helpers extracted from keeper_run_tools.ml.

    Pure helpers for selecting task_id-scoped tools and extracting the
    task_id from a tool input JSON object. *)

let task_scope_tool_names =
  [ "masc_transition"
  ; "keeper_task_done"
  ; "keeper_task_submit_for_verification"
  ; "keeper_task_force_done"
  ; "keeper_task_force_release"
  ]
;;

let json_string_opt name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`String value) when String.trim value <> "" -> Some (String.trim value)
     | _ -> None)
  | _ -> None
;;

let task_id_scope_of_tool_input ~tool_name input =
  if List.mem tool_name task_scope_tool_names
  then json_string_opt "task_id" input
  else None
;;
