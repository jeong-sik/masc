(** Announces {!Keeper_event_queue_changed_event} for the Keeper whose event
    queue or reaction record was written (RFC-0480 §3.4). *)

val install : sw:Eio.Switch.t -> unit
(** Installs the event-queue and reaction-ledger change observers and the
    fiber that announces for them. The observer runs on the writer, for the
    event queue under the Keeper's queue owner lock: it drops the cached
    [/health] snapshot and the workspace's cached fleet schedule list, then
    wakes the fiber, which sends one {!Keeper_event_queue_changed_event} per
    changed Keeper to that workspace's observers. A failed broadcast is
    counted on [SseBroadcastFailures] and logged. *)
