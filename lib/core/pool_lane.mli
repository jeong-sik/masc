(** Who the current fiber is working for: an HTTP read being answered, or
    anything else. RFC-0204 §3.1.

    The mark lives in an Eio fiber key, so fibers forked while a read is being
    answered inherit it. A read ends when {!with_read} returns or raises;
    from then on {!current} reports [Background] in every fiber that carries
    the mark, so a fiber that outlives its request (a WebSocket heartbeat, a
    stale-while-revalidate recompute) needs no list of exceptions.

    A pool job does not inherit the submitting fiber's keys: inside the job
    the lane is [Background] unless the job itself marks a read. *)

type lane =
  | Read
  | Background

val current : unit -> lane
(** [Read] inside {!with_read} until it returns; [Background] otherwise and
    outside Eio. *)

val with_read : (unit -> 'a) -> 'a
(** Run [f] as one HTTP read. Outside Eio this runs [f] unmarked. *)

val to_string : lane -> string
