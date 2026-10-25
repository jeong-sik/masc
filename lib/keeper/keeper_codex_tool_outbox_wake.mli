(** Recover unread dynamic-tool results through the existing Keeper queue.
    Queue admission and wake hints do not acknowledge the result and never
    execute tools. The next successful Codex settlement owns the exact ACK. *)

val notify : base_path:string -> keeper_name:string -> (unit, string) result
(** Read the authoritative outbox, durably enqueue pointer-only notifications
    with pending/outbox deduplication, then hint the existing live owner.
    Failed provider turns may be notified again while receipts remain unread.
    An absent/paused owner is never started or unpaused. Recovery currently
    requires a nonempty Codex-only route: every reachable candidate must resolve
    to Codex. Mixed, unavailable and unknown routes retain receipts without
    initiating model turns that cannot consume them. *)

val route_can_consume : Keeper_meta_contract.keeper_meta -> bool
(** Every candidate in the current route must resolve to Codex developer-context
    delivery. Quota ordering or fallback may select any declared candidate;
    checking just the entry cannot establish consumption. Empty, mixed,
    missing or unavailable candidates retain their unread receipts. *)

type t
val create : config:Workspace.config -> t
val pulse : sw:Eio.Switch.t -> t -> unit
(** Startup and existing maintenance entrypoint. Reserve one yielding discovery
    child, coalescing only overlapping scans. Cancellation releases reservations
    and propagates. Disk state, not the process-local reservation, is authority.
    Retained Keeper names are discovered afresh each pass; individual failures
    leave their receipts for a later existing maintenance pulse. *)
