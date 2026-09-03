(** Tool_shard_types_schemas_taskboard — task/broadcast tool schemas (keeper_tasks_*, keeper_task_*, keeper_broadcast). *)

let taskboard_tools : Masc_domain.tool_schema list =
  [ Tool_shard_types_schemas_taskboard_toml.tasks_list
  ; Tool_shard_types_schemas_taskboard_toml.tasks_audit
  ; Tool_shard_types_schemas_taskboard_toml.broadcast
  ; Tool_shard_types_schemas_taskboard_toml.task_claim
  ; Tool_shard_types_schemas_taskboard_toml.task_done
  ; Tool_shard_types_schemas_taskboard_toml.task_cancel
  ; Tool_shard_types_schemas_taskboard_toml.task_release
  ; Tool_shard_types_schemas_taskboard_toml.task_create
  ]
;;
