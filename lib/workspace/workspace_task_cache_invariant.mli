(** Guard an agent-owned task cache against canonical backlog state. *)

type rewrite =
  | Unchanged of string
  | Invalidated of string

val rewrite_current_task :
  config:Workspace_utils_backend_setup.config ->
  from_agent:string ->
  module_name:string ->
  task_id:string ->
  content:string ->
  rewrite
