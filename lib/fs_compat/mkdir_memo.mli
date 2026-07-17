(** Idempotent directory-existence cache.

    Path-keyed memoize wrapper around a caller-supplied [mkdir_p]
    primitive. The cache stores only the {i fact} that the dir
    exists; no fd is held. External processes that delete the dir
    after first call will see silent skip — caller must ensure this
    is acceptable for their domain (e.g. self-owned [.masc/] trees).
    RFC-0162 §3.1.

    The [mkdir_p] callback is injected so this module stays free of
    [Fs_compat]'s Eio bridge, test-isolation guard, and Unix
    fallback. Cycle-free placement inside [fs_compat]'s wrapped
    library. *)

(** [mkdir_p_memoized ~mkdir_p path] skips [mkdir_p path] after the
    first successful completion for [path] in this process. Concurrent
    cache misses may call [mkdir_p path] more than once, so the callback
    must accept an already-created directory. *)
val mkdir_p_memoized : mkdir_p:(string -> unit) -> string -> unit

(** Reset the cache. Test-only — production code relies on
    process-lifetime persistence. *)
val reset_for_testing : unit -> unit
