(** Per-cascade-name in-memory cursor state.

    Cascade strategy variants are currently stateless, but runtime
    model expansion still uses a per-cascade round-robin cursor to
    avoid always putting the same expanded model first.

    All entries live in process-local state.  Restart resets everything.

    Concurrency: every operation uses [Atomic.t] or short critical
    sections under [Eio.Mutex.t].  Safe to call from multiple Eio
    fibers and (for Atomic-only ops) from multiple OCaml domains.

    @since 0.9.7 *)

(** {1 Round-robin state} *)

val rotate_round_robin : cascade:string -> bound:int -> int
(** [rotate_round_robin ~cascade ~bound] returns the current cursor
    value modulo [bound] and atomically advances the cursor by 1.
    Returns [0] when [bound <= 0] (caller is responsible for
    treating the empty list as a no-op).  Atomic — safe under
    contention. *)

val peek_round_robin : cascade:string -> int
(** Return the current cursor value without advancing.  Test helper. *)

val clear_round_robin : unit -> unit
(** Reset every cursor to 0.  Test helper. *)

(** {1 Bulk reset} *)

val clear_all : unit -> unit
(** Equivalent to {!clear_round_robin}.  Used by tests and future
    hot-reload code paths. *)
