val start : sw:Eio.Switch.t -> mono_clock:_ Eio.Time.Mono.t -> unit
(** Install the schedule store's change observer and the worker that
    announces for it. On the writer the observer drops the workspace's cached
    [/health] snapshot and fleet schedule list and enqueues the workspace; the
    worker publishes coalesced, workspace-scoped invalidations to SSE
    observers and counts each publication. *)

val notices : unit -> int
(** Schedule invalidations published in this process: the worker's
    publications of store writes and {!announce} calls. A schedule runner tick
    that sees it move knows a reader may have read the list while the tick
    ran. *)

val announce : base_path:string -> unit
(** The schedule runner recorded a tick that changed the list, or its status
    passed the staleness deadline: drop the workspace's cached fleet schedule
    list and publish the invalidation now. A failed publication is counted on
    [SseBroadcastFailures] and logged. *)

module For_testing : sig
  val start :
    sw:Eio.Switch.t -> mono_clock:_ Eio.Time.Mono.t -> publish:(base_path:string -> unit) ->
    invalidate:(base_path:string -> unit) -> unit
end
