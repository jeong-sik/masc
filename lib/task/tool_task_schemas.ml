(** Tool_task_schemas — JSON schema definitions for task tools.

    Pure data module containing MCP tool schemas for all task operations.

    @since God file decomposition — extracted from tool_task.ml *)

(* One schema per Tool_name.Task_name constructor, so the advertised set and the
   set Tool_task.dispatch routes cannot drift: adding a constructor is a compile
   error here as well as at the dispatch. *)
let schema_for : Tool_name.Task_name.t -> Masc_domain.tool_schema = function
  | Tool_name.Task_name.Add_task -> Tool_task_schemas_toml.add_task
  | Tool_name.Task_name.Batch_add_tasks -> Tool_task_schemas_toml.batch_add_tasks
  | Tool_name.Task_name.Task_history -> Tool_task_schemas_toml.task_history
  (* RFC-0267 Phase 2: assign an existing goalless task to a goal. *)
  | Tool_name.Task_name.Task_set_goal -> Tool_task_schemas_toml.task_set_goal
  | Tool_name.Task_name.Tasks -> Tool_task_schemas_toml.tasks
  | Tool_name.Task_name.Transition -> Tool_task_schemas_toml.transition
  | Tool_name.Task_name.Update_priority -> Tool_task_schemas_toml.update_priority
;;

let schemas : Masc_domain.tool_schema list =
  List.map schema_for Tool_name.Task_name.all
