(** Switch-owned maintenance of the existing Goal and explicit-mention outboxes.
    Neither an idle reservation nor a settled delivery proves useful Task work. *)
type kind = Goal_effects | Broadcast_mentions

type settlement =
  | Goal_settled of (unit, string) result
  | Broadcast_settled of (Workspace_broadcast.reconciliation_report, string) result

type t

val create : ?on_settled:(base_path:string -> settlement -> unit) -> unit -> t
(** One server-lifetime supervisor. The observer runs after the original drain
    returns and before its active reservation is released, with the reserved
    workspace's original base path. Observer failure
    cannot undo durable delivery. No prior outcome is cached for a later pulse. *)

val pulse :
  sw:Eio.Switch.t -> config:Workspace_utils.config -> t -> kind -> unit
(** Reserve at most one live worker per delivery kind, then return without
    joining its lock/store/recipient I/O. The worker yields before entering the
    original [Goal_delivery.flush] or [Workspace_broadcast.reconcile_pending_mentions].
    Their original locks, sequence/predecessor checks, exact identities and ACKs
    remain authoritative. The two kinds are independent; each kind keeps its
    existing whole-drain serial order, including unrelated recipients' waits.

    Capture this pulse's workspace configuration only when reserving a worker.
    A workspace switch cannot retarget an active worker. A pulse while active
    is coalesced; the next pulse rereads durable work with its own configuration.
    The reservation remains active through the observer and cancellation cleanup.
    Check the supplied switch before reservation and fork; propagate structural
    cancellation. Shutdown still joins protected physical I/O. Single-domain
    Eio caller; no timer, retry interval, delivery cache or replacement effect. *)
