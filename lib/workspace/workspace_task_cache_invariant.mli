(** Guard stale task-cache broadcasts against canonical backlog state. *)


val rewrite_broadcast_content :
  config:Workspace_utils_backend_setup.config ->
  from_agent:string ->
  module_name:string ->
  content:string ->
  string
