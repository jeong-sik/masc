(** What a surface owes its server reading after the server announced a
    change (RFC-0480 §3.1).

    The observer feed says that something changed; the surface reads it from
    the server. A change can arrive while a read of the same surface is in
    flight, while the surface cannot read (the chat is scrolled into older
    rows), or the read can fail. Each of those used to be caught up by the
    next refresh tick. This value remembers it instead, so a read is owed
    exactly until one read that began after the change succeeds.

    Nothing here performs I/O or reads a clock. The caller passes [now] and
    asks {!due} whether to start a read. *)

type t =
  | Settled  (** Nothing is owed. *)
  | Owed of { failures : int }
      (** A change has not been read. [failures] counts the reads that failed
          in a row before it, so a retry keeps backing off. *)
  | Reading of { failures : int; changed_since : bool }
      (** A read is in flight. [changed_since] records a change announced
          after the read began, which the read may have missed. *)
  | Waiting of { failures : int; retry_at : float }
      (** The last read failed; the next one starts at [retry_at]. *)

val settled : t

val changed : t -> t
(** The server announced a change of this surface. A change while waiting
    out a failure does not shorten the wait: the retry reads the newest. *)

val started : t -> t
(** A read of this surface began, whatever started it. *)

val succeeded : t -> t
(** The read that began last succeeded. A change announced while it was in
    flight is still owed. *)

val failed : retry_s:float -> max_retry_s:float -> now:float -> t -> t
(** The read that began last failed. The wait is [retry_s] after the first
    failure and doubles with each failure in a row, up to [max_retry_s]. *)

val due : now:float -> t -> bool
(** Whether a read should start now, when the surface is able to read. *)
