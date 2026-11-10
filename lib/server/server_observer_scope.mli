(** Bind an observer and its point-in-time reads to one workspace generation. *)

type read_error = Ambiguous_instance | Instance_mismatch | Scope_changed

val instance_id : Mcp_server.workspace_scope -> string

type stream_owner
type stream_admission_error =
  | Instance_required
  | Instance_ambiguous
  | Instance_changed

val admit_stream :
  state:Mcp_server.server_state -> Httpun.Request.t ->
  (stream_owner, stream_admission_error) result
(** Require exactly one instance header identifying the caller's original
    observation. Never infer it from the workspace current at request time. *)

val stream_config : stream_owner -> Workspace.config
val stream_instance : stream_owner -> string
val stream_is_current : stream_owner -> bool
val await_stream_replaced : stream_owner -> unit
(** The owner captures the server state and immutable scope together. Test
    [stream_is_current] after each asynchronous read and before writing bytes;
    also race the stream lifetime against [await_stream_replaced]. Replacement
    at the same path retires the owner, independently of notification timing. *)

val refuse_stream : stream_admission_error -> Http_reqd.t -> unit
(** Required/ambiguous headers answer 400; a retired instance answers 409.
    No successful stream headers or query work are admitted on rejection. *)

val read_if_current :
  state:Mcp_server.server_state ->
  expected_instances:string list ->
  read:(Workspace.config -> 'a) ->
  (string * 'a, read_error) result
(** Accept no requested instance or one matching instance. A read crossing a
    workspace replacement is refused, including a replacement at the same path. *)
