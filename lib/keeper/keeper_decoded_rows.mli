(** Decoded lines of append-only row stores, kept between reads.

    A store that only grows by appended lines is decoded again in full by
    every reader unless something remembers the lines already decoded. A
    value of this module remembers, per store path, the bytes last read and
    their decoded lines. It never reads a file: the caller reads the bytes,
    under whatever lock the store needs, and asks for their lines.

    What is kept is bounded by [budget_bytes] of store bytes over all paths.
    The decoded lines of a store take about as much again. When a read takes
    the total over the budget, the stores read longest ago are dropped until
    it fits; a store larger than the whole budget is not kept. Dropping a
    store costs its next reader a full decode and changes no answer. *)

type 'line t

(** [budget_bytes] is the most store bytes kept over all paths. Raises
    [Invalid_argument] when it is negative. *)
val create : budget_bytes:int -> 'line t

(** The decoded lines of [rows], the bytes of the store at [path] as just
    read. [decode ~after bytes] decodes the complete lines in [bytes], the
    first of which follows [after] earlier lines.

    When [rows] are the bytes kept for [path], the kept lines are the answer
    and nothing is decoded. When [rows] start with the kept bytes, only what
    follows them is decoded and the kept lines come first, as the values
    already built. Otherwise all of [rows] is decoded. The answer is then
    kept for [path], and [path] counts as the store read last. *)
val lines
  :  'line t
  -> path:string
  -> rows:string
  -> decode:(after:int -> string -> 'line list)
  -> 'line list

(** Drop what is kept for [path]: the store is gone. *)
val forget : 'line t -> path:string -> unit

(** The store bytes kept now, over all paths. *)
val kept_bytes : 'line t -> int
