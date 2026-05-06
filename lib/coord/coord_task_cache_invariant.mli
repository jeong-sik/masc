(** Guard stale task-cache broadcasts against canonical backlog state. *)

val stale_active_task_signal_present :
  config:Coord_utils_backend_setup.config ->
  from_agent:string ->
  module_name:string ->
  content:string ->
  bool

val rewrite_broadcast_content :
  config:Coord_utils_backend_setup.config ->
  from_agent:string ->
  module_name:string ->
  content:string ->
  string
