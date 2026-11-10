(** Commit metadata enters the existing runtime observer bus outside the
    writer's lifetime. This module retains no rows or replay history. *)

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
    publisher's own non-raising failure contract still applies. *)
