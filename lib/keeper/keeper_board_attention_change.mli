(** Metadata from the canonical Board-attention ledger write boundaries. *)

type source = Candidate | Partition
type change = {canonical_masc_root : string; keeper_name : string; source : source}

val subscribe : (change -> unit) -> (unit -> unit)
(** Synchronous non-I/O after-attempt callback. Consumers may enqueue bounded
    invalidation debt. No raw candidate, decision or partition row is exposed.
    Listener exceptions cannot replace the original result or cancellation. *)

val with_attempt :
  base_path:string -> keeper_name:string -> source:source ->
  ((unit -> unit) -> 'a) -> 'a
(** Capture source ownership before entering the mutation. The operation marks
    only its actual filesystem publication/recovery/purge attempt. Notification
    runs after its existing lock/worker scope returns, also on uncertain
    failure/cancellation; rejected validation and unchanged reads do not mark.
    The final notification performs no filesystem, clock or transport work. *)
