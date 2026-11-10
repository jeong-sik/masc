(** Commit metadata enters the existing runtime observer bus outside the
    writer's lifetime. This module retains no rows or replay history. *)

val observations :
  Server_observation_input.t ->
  Sse_event.Types.dashboard_observation_changed_payload list
(** Closed dependencies of mounted Dashboard reads on canonical committed
    input. Source-dated agent changes refresh IDE presence; committed message
    delivery keeps its existing canonical client route. Keeper and
    chat-operation identities remain exact. A computed
    Dashboard observation is never reclassified as a new input. Native Logs
    and mounted series receive their own frames rather than polling here. *)

val install :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  unit
(** Each immutable workspace epoch owns its subscriptions and coalescing
    workers. A workspace-owned commit is resolved in the worker and admitted
    only to that workspace. Process-wide read models use workspace scope.
    The Tool_metrics leaf observer is connected here without introducing a
    dependency from that leaf to the application library.

    Store callbacks enqueue typed metadata only: no filesystem resolution,
    HTTP, SSE fanout, or cache read runs on a writer's completion path.
    Dependent REST caches are invalidated before publishing. In-flight input
    remains owed; successful idle has no timer. Epoch replacement releases
    every old subscription and cancels its publishers. The canonical
    publisher's own non-raising failure contract still applies. Initial
    installation returns after its source subscriptions are registered. *)
