(** Bind an observer and its point-in-time reads to one workspace generation. *)

type read_error = Ambiguous_instance | Instance_mismatch | Scope_changed

val instance_id : Mcp_server.workspace_scope -> string

val read_if_current :
  state:Mcp_server.server_state ->
  expected_instances:string list ->
  read:(Workspace.config -> 'a) ->
  (string * 'a, read_error) result
(** Accept no requested instance or one matching instance. A read crossing a
    workspace replacement is refused, including a replacement at the same path. *)
