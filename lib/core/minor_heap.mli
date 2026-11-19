(** The minor heap a domain collects on, chosen where the domain starts.

    [Gc.set]'s [minor_heap_size] is per-domain in OCaml 5: it resizes the
    caller's minor heap, and a domain spawned later starts on the runtime's
    initial size (256k words, or the [s] of [OCAMLRUNPARAM]) whatever its
    parent set. So no domain inherits a size: the code that starts a domain
    names the heap it collects on, once, and nothing below that code
    changes it. Each process decides for its own domains: the server keeps
    every domain of its own work on {!Tuned}, and the TUI decides per domain
    ([Masc_tui_domains]). *)

type t =
  | Runtime_default
      (** Leave the domain on the size the runtime gave it. *)
  | Tuned
      (** 4M words (32 MiB on 64-bit), unless [OCAMLRUNPARAM] is set. A
          present [OCAMLRUNPARAM] is the operator's configuration and stays
          authoritative, so the domain then keeps the runtime's size too. *)

val apply : t -> unit
(** Give the calling domain the heap [t] names. {!Tuned} raises only a
    smaller heap and keeps every other GC control; it is idempotent.
    {!Runtime_default} changes nothing. Call it on the domain's first step,
    before it allocates for its work. *)

val domain_mgr : t -> _ Eio.Domain_manager.t -> Eio.Domain_manager.ty Eio.Resource.t
(** [domain_mgr t mgr] starts domains as [mgr] does, and each applies [t]
    before it runs anything else. [Eio.Executor_pool.create] starts its
    workers through the manager it is given, so this is where a pool's
    domains get their heap: once per domain, not once per job. *)
