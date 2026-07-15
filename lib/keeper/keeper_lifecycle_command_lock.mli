(** Serialize complete high-level lifecycle commands for one canonical
    BasePath/Keeper key. Internal registry and persistence locks remain
    narrower and may safely be acquired inside the callback. Acquisition is
    cancellable; after acquisition, cancellation is deferred until the full
    lifecycle transition has returned and released the lock. Inactive keys are
    weakly retained rather than accumulating for the lifetime of the process. *)

val with_lock :
  base_path:string -> keeper_name:string -> (unit -> 'a) -> 'a
