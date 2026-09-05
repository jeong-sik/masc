(** Heap_roots — which registered value holds how much of the major heap.

    [Gc.quick_stat] says how large the live heap is, not what it is made of.
    Subsystems that retain state register a root here; a diagnostic walks
    each root with [Obj.reachable_words] and reports the transitive size.

    Two things the number is not. It is not exclusive: two roots that share
    structure both count it, so the readings do not add up to the live heap.
    And it is not free: the walk holds the calling domain's runtime lock for
    its whole duration and every other domain waits at its next
    stop-the-world, so a walk over a gigabyte stalls the process for seconds.
    It is an operator diagnostic, not a metric to poll. *)

type measurement =
  | Words of int  (** reachable words from the root, transitive *)
  | Absent  (** the root has no value right now (e.g. a snapshot not yet published) *)
  | Failed of string  (** the accessor or the walk raised; the message *)

type reading =
  { name : string
  ; measurement : measurement
  ; walk_ms : float
  }

val register : name:string -> (unit -> Obj.t option) -> (unit, [ `Duplicate ]) result
(** [register ~name value] adds a root. The accessor runs at walk time on the
    walking fiber. A second root with the same name is refused so a reading
    always names one thing. Safe to call from any domain. *)

val registered : unit -> string list
(** Root names in registration order. *)

val measure : now:(unit -> float) -> unit -> reading list
(** Walk every root in registration order. [now] supplies wall-clock seconds
    for [walk_ms] only; nothing else depends on it. *)

val reading_to_yojson : reading -> Yojson.Safe.t
(** [name], [status] ("measured" | "absent" | "failed"), and with it [words]
    and [bytes], or [error]; always [walk_ms]. *)

val words_to_bytes : int -> int
(** Words on this platform to bytes ([Sys.word_size / 8]). *)

val clear_for_tests : unit -> unit
