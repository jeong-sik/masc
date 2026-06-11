(** Keeper_librarian_runtime — LLM invocation wrapper for the librarian.

    Builds a closure that sends the librarian prompt to the default
    runtime's direct-completion provider and parses the returned JSON
    into a [Keeper_memory_os_types.episode]. *)

(** Build a librarian callback for the given trace/generation.

    Returns [None] when:
    - the fiber-local Eio switch/net is unavailable,
    - no default runtime is configured,
    - the default provider is not a direct-completion provider.

    The returned closure is safe to pass to
    [Keeper_compact_policy.compact_if_needed_typed]. *)
val make
  :  trace_id:string
  -> generation:int
  -> unit
  -> Keeper_compact_policy.librarian_callback option
