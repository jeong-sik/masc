(** A durable workspace-memory input may have changed. These callbacks bridge
    the store commit to cache invalidation and the existing SSE bus; they are
    not another event queue. *)

val subscribe : (directory:string -> unit) -> (unit -> unit)
(** Subscribe before reading an inventory. The directory passed to callbacks
    was resolved by the writer before its atomic replacement attempt. Callbacks
    run synchronously on the writer's domain and must not block or yield.
    The returned unsubscribe is idempotent. *)

val written : directory:string -> unit
(** Notify after an atomic replacement was attempted, including an uncertain
    post-rename failure. [directory] must already name the resolved owner;
    resolving a path here would add a cancellation point after the commit.
    Subscribers belong to another lifecycle: their
    exceptions are logged without replacing the writer's outcome. *)
