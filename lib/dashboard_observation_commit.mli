(** Non-yielding after-commit notifications for Dashboard read models that
    have no existing typed publication. Topics and reader scopes come from
    the shared ATD contract; no content, transport queue or replay is stored. *)

type change =
  | Workspace of {
      base_path : string;
      payload : Sse_event.Types.dashboard_observation_changed_payload;
    }
  | Process of Sse_event.Types.dashboard_observation_topic

val subscribe : (change -> unit) -> (unit -> unit)
(** Callbacks run synchronously outside the registry mutex and must not block
    or yield. The returned removal is idempotent and removes only this
    subscription. A server subscriber records/coalesces the metadata and
    performs SSE fanout in its own switch-owned worker. *)

val written :
  base_path:string -> scope:Sse_event.Types.dashboard_observation_scope ->
  Sse_event.Types.dashboard_observation_topic -> unit
(** Notify after the authoritative write attempt, including a failure whose
    atomic rename may already be visible. [base_path] retains the writer's
    workspace owner spelling. The server worker resolves its authority before
    publication; this after-commit function performs no filesystem work.
    The notification does not change the
    writer's result; subscriber exceptions, cancellation included, are logged
    without escaping this non-yielding boundary. *)

val process_written : Sse_event.Types.dashboard_observation_topic -> unit
(** A process-local metric/ring input changed. Its read model is shared by
    workspaces and its invalidation has workspace scope, without resource
    identity or content. Do not use this for workspace-owned stores. *)
