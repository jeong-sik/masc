(** Incremental, offset-tracked projection for large append-only JSONL logs.

    Folds only the bytes appended since the previous read into a per-key
    accumulator, so an actively written multi-MB log is never re-parsed in full
    (steady-state cost is O(new bytes), not O(tail size)). See the
    implementation header for boundary handling — partial trailing lines,
    cold-start tail seek with line alignment, and truncation/rotation — and for
    the single-domain concurrency contract. *)

type 'a t
(** A projection cache keyed by string, holding per key the consumed byte offset
    (at a line boundary) and the accumulated projection of type ['a]. *)

val create : unit -> 'a t
(** A fresh, empty cache. Typically created once at module load. *)

val read :
  'a t ->
  key:string ->
  path:string ->
  empty:'a ->
  add:('a -> string -> 'a) ->
  initial_tail_bytes:int ->
  'a
(** [read t ~key ~path ~empty ~add ~initial_tail_bytes] returns the accumulator
    for [key]. On a cold key it seeds from [empty] over the last
    [initial_tail_bytes] of [path], aligned to the next line boundary;
    thereafter it folds only newly appended complete lines through [add]. [add]
    runs exactly once per new complete line and is never re-run for an
    already-consumed line, so it is where a feed enforces a most-recent-N ring.
    A partial trailing line is held until the writer completes it; a file
    shorter than the consumed offset reseeds from the tail. *)
