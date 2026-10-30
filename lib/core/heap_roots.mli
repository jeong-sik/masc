(** Heap_roots — which registered value holds how much of the major heap.

    [Gc.quick_stat] says how large the live heap is, not what it is made of.
    Subsystems that retain state register a root here; a diagnostic walks
    each root with [Obj.reachable_words] and reports the transitive size.

    What the number is not.
    - It is not exclusive: two roots that share structure both count it, so
      the readings do not add up to the live heap.
    - It does not include fiber stacks. A suspended fiber's continuation
      keeps its stack behind a tagged pointer the walk cannot follow, so a
      root that holds waiting fibers (an Eio mutex, condition or promise)
      reports none of what those stacks reach. State that lives only on a
      fiber is invisible here; [Alloc_profile] sees it at allocation time.
    - It is not free. The walk holds the calling domain's runtime lock for
      its whole duration and every other domain waits at its next
      stop-the-world. It also allocates outside the OCaml heap: the runtime
      keeps a position table of about 24 to 48 bytes per visited block, and
      an old table overlaps the new one while it grows, so walking a root of
      tens of millions of blocks takes a comparable amount of transient
      memory. That path ends in an out-of-memory kill, not in [Failed].
    It is an operator diagnostic, not a metric to poll.

    A root that guards its state with a lock walks under that lock: the
    registration receives the walker and calls it wherever it likes, so a
    table is never counted while another domain resizes it. *)

type measurement =
  | Words of int  (** reachable words from the root, transitive *)
  | Absent  (** the root has no value right now (e.g. a snapshot not yet published) *)
  | Failed of string  (** the accessor or the walk raised; the message *)

type reading =
  { name : string
  ; measurement : measurement
  ; walk_ms : float
  }

type walk = Obj.t option -> measurement
(** What a root is handed at measure time: it calls this with its value, or
    with [None], and returns the result. Exceptions inside the walk are
    already folded into [Failed] when it returns. *)

val register : name:string -> (walk -> measurement) -> (unit, [ `Duplicate ]) result
(** [register ~name root] adds a root. [root] runs at walk time on the
    walking fiber and may hold its own lock around the call it makes. A
    second root with the same name is refused so a reading always names one
    thing. Safe to call from any domain. *)

val registered : unit -> string list
(** Root names in registration order. *)

val measure : now:(unit -> float) -> unit -> reading list
(** Walk every root in registration order. [now] supplies wall-clock seconds
    for [walk_ms] only; nothing else depends on it. *)

val total_walk_ms : reading list -> float

val reading_to_yojson : reading -> Yojson.Safe.t
(** [name], [status] ("measured" | "absent" | "failed"), and with it [words]
    and [bytes], or [error]; always [walk_ms]. *)

val words_to_bytes : int -> int
(** Words on this platform to bytes ([Sys.word_size / 8]). *)

module For_testing : sig
  val clear : unit -> unit
end
