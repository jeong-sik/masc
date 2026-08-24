(** Tool_task_schemas — JSON schema definitions for task tools.

    Pure data module containing MCP tool schemas for all task operations.

    @since God file decomposition — extracted from tool_task.ml *)

let schemas : Masc_domain.tool_schema list = [
  Tool_task_schemas_toml.add_task;
  Tool_task_schemas_toml.batch_add_tasks;
  Tool_task_schemas_toml.task_history;
  Tool_task_schemas_toml.tasks;

  Tool_task_schemas_toml.update_priority;
  Tool_task_schemas_toml.transition;
  (* RFC-0267 Phase 2: assign an existing goalless task to a goal. *)
  Tool_task_schemas_toml.task_set_goal;
]
