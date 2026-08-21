(** Guard an explicitly declared task-cache signal against canonical backlog state. *)

type signal =
  { subject_agent : string
  ; task_id : string
  }

type rewrite =
  | Unchanged of string
  | Invalidated of string

val rewrite_signal :
  config:Workspace_utils_backend_setup.config ->
  module_name:string ->
  signal:signal ->
  content:string ->
  rewrite
