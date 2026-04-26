(** Head+tail truncating byte accumulator — Phase 3 of the Legendary
    Bash roadmap.

    Mirrors claude-code's [EndTruncatingAccumulator] but retains BOTH
    the head and tail of the stream, which keeps opening banners
    (usage strings, config echoes) and closing summaries (final exit
    status, error tails) readable when the middle is elided.

    Semantics:
    - The first [head_cap] bytes are written once to the head buffer
      and then frozen — subsequent writes never mutate those bytes.
    - The last [tail_cap] bytes are held in a ring buffer.  When new
      bytes arrive, the oldest tail bytes are overwritten.
    - [total_bytes] is the cumulative count of bytes ever offered via
      [add_*], independent of truncation.
    - [bytes_dropped] is the count of bytes that were not retained in
      either the head or the tail.  Zero means the full stream fit.

    Not thread-safe.  Callers that drain concurrent producers must
    serialise access.  In the intended use (single-pipe drainer per
    fd), the producer is sequential, so no lock is required. *)

type t

(** [head_cap] and [tail_cap] are byte budgets.  A value of [0] means
    "retain nothing from this end".  Negative values are rejected. *)
val create : head_cap:int -> tail_cap:int -> t

val add_string : t -> string -> unit

(** [add_bytes t buf off len] appends [buf.[off .. off+len-1]]. *)
val add_bytes : t -> bytes -> int -> int -> unit

val total_bytes : t -> int
val bytes_dropped : t -> int
val head : t -> string
val tail : t -> string

(** Returns [head] unchanged when nothing was dropped; otherwise
    [head ^ separator ^ tail] where separator is a single-line
    [\n...(truncated N bytes)...\n] marker.  The separator is only
    present when [bytes_dropped > 0] so golden tests on small outputs
    remain byte-identical to the raw stream.

    When truncation occurs, both head and tail are trimmed to UTF-8
    character boundaries so CJK and emoji output is never split mid-byte. *)
val render : t -> string

(** [utf8_truncate s max_bytes] returns the prefix of [s] that fits
    within [max_bytes], breaking only at UTF-8 character boundaries.
    Returns [s] unchanged if it already fits.  Safe for CJK, emoji,
    and other multi-byte sequences. *)
val utf8_truncate : string -> int -> string
