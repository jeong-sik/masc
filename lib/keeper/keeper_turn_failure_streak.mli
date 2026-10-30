(** Durable boundary around the in-memory Keeper registry failure counter.

    Production turn paths are single-owner per Keeper. They publish the next
    positive count durably before updating the registry, and remove the record
    durably before a successful turn resets the registry to zero. *)

val increment : base_path:string -> keeper_name:string -> int
val reset : base_path:string -> keeper_name:string -> bool
(** [true] only after durable removal, registry zeroing, and typed failure
    reason clearing all complete. A failed durable remove retains the previous
    in-memory failure observation. *)
