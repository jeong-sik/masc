(** Fusion_wake_route — in-memory reply-channel routes for in-flight fusion
    runs (feature-map gap: wake-family continuation-channel parity).

    [masc_fusion] is asynchronous: the keeper turn that starts a deliberation
    ends long before the [Fusion_completed] wake fires, so the originating
    connector conversation (RFC-0320 [Keeper_continuation_channel]) must be
    carried across that gap.  The pure run registry
    ([Fusion_run_registry], lib/fusion_core) cannot hold the channel — that
    layer is deliberately keeper-free — so this lib/fusion-local map owns it:
    registered at gate-Allow time next to [register_running], consumed exactly
    once by [Fusion_sink.wake_keeper_on_fusion_completion].

    Lifetime matches the wake itself, not the run record: routes live in
    process memory only.  A server restart drops them together with the
    in-flight fibers they route for (boot replay already drops [Running]
    runs), so a persisted route could never fire anyway. *)

(** [register ~run_id channel] remembers the originating channel for an
    in-flight run.  Unroutable channels ([Unrouted]) are not stored — the
    wake-side default already says "no originating connector". *)
val register : run_id:string -> Keeper_continuation_channel.t -> unit

(** [take ~run_id] returns the registered channel and removes the route
    (a completion wake fires once; keeping the route would leak).  [None]
    when the run was started without a routable channel. *)
val take : run_id:string -> Keeper_continuation_channel.t option

(** [peek ~run_id] returns the registered channel without removing the route.
    The completion wake builds its stimulus from this value and durably commits
    it before calling [take]: the route is the sole in-memory carrier of the
    reply channel, so a failed durable commit must leave it intact for a later
    retry instead of destroying it up front. [None] mirrors [take]. *)
val peek : run_id:string -> Keeper_continuation_channel.t option

(** [discard ~run_id] drops the route without returning it — the structural
    cancellation path terminates a run without emitting a completion wake. *)
val discard : run_id:string -> unit
