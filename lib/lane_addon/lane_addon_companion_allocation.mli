(** Host-owned temporary IPC allocation, outside retained Lane data/work disks. *)
type t
type creation_error = Unavailable | Cleanup_unconfirmed
type cleanup = Paths_retained of string
val create : sw:Eio.Switch.t -> max_message_bytes:int -> (t,creation_error) result
(** [Unavailable] has no remaining allocation. [Cleanup_unconfirmed] includes
    a retained startup path or uncertainty from startup resource cleanup and must
    not certify owner release. *)
val broker : t -> Lane_addon_companion_broker.t
val on_finish : t -> (Lane_addon_companion_broker.completion -> (unit,string) result) ->
  ((Lane_addon_companion_broker.completion -> unit),string) result
(** Register settlement while binding, before Browser effects. Returns a
    nonblocking notification; [cleanup] joins every registered settlement.
    Cleanup supplies [Abandoned] if the joined broker never notified it. A
    daemon that cannot start or is cancelled resolves to a fixed unconfirmed
    result, never an ownerless promise. A started callback resolves settlement
    only after its cleanup returns. Callback errors and exceptions are fixed. *)
val cleanup : t -> (cleanup,string) result
(** Revoke and join the original listener/connections, confirm descriptor close,
    and join every registered Browser settlement. [Paths_retained directory]
    confirms those active resources only: the original allocation pathname and
    socket entry are retained, and a fixed host warning names the allocation.
    Path identity checks cannot authorize unlink/rmdir against same-UID replacement;
    cleanup never deletes either name or follows a successor. Errors retain actual
    resource/settlement uncertainty. One retained result; no replay or recursive delete.
    The startup guard owns the directory before protected allocation returns;
    startup failure joins partial resources before returning. *)
