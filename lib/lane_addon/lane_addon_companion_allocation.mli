(** Host-owned temporary IPC allocation, outside retained Lane data/work disks. *)
type t
type creation_error = Unavailable | Cleanup_unconfirmed
val create : sw:Eio.Switch.t -> max_message_bytes:int -> (t,creation_error) result
(** [Unavailable] has no remaining allocation. [Cleanup_unconfirmed] retains
    uncertainty from startup cleanup and must not certify owner release. *)
val broker : t -> Lane_addon_companion_broker.t
val on_finish : t -> (Lane_addon_companion_broker.completion -> (unit,string) result) ->
  ((Lane_addon_companion_broker.completion -> unit),string) result
(** Register settlement while binding, before Browser effects. Returns a
    nonblocking notification; [cleanup] joins every registered settlement.
    Cleanup supplies [Abandoned] if the joined broker never notified it. A
    daemon that cannot start or is cancelled resolves to a fixed unconfirmed
    result, never an ownerless promise. A started callback resolves settlement
    only after its cleanup returns. Callback errors and exceptions are fixed. *)
val cleanup : t -> (unit,string) result
(** Revoke and join the broker's original socket cleanup, then remove only the
    captured directory identity if empty. A remaining socket is unconfirmed,
    never removed using a later path snapshot. One retained result; no recursive delete
    or successor lookup. The startup guard owns the directory before protected
    allocation returns; cancellation cannot escape before guard installation.
    Startup failure joins partial resources before returning. Uncaptured or
    replaced socket identities are retained as unconfirmed. *)
