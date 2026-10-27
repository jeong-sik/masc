(** Who the current fiber is working for: an HTTP read being answered, or
    anything else. RFC-0204 §3.1.

    The mark lives in an Eio fiber key, so fibers forked while a read is being
    answered inherit it. A read ends when {!with_read} returns or raises;
    from then on {!current} reports [Background] in every fiber that carries
    the mark, so a fiber that outlives its request (a WebSocket heartbeat)
    needs no list of exceptions.

    A submission takes the lane its fiber has at the moment it submits. A
    fiber the request forked counts as [Read] for whatever it submits before
    the request ends, unless it runs under {!with_background}: work no request
    waits on, such as a stale-while-revalidate recompute, marks itself there.

    A pool job does not inherit the submitting fiber's keys: inside the job
    the lane is [Background] unless the job itself marks a read. Work handed
    to the owner domain ([Eio_context.run_on_owner_domain], used when the
    serving domain is enabled) runs unmarked. *)

type lane =
  | Read
  | Background

val current : unit -> lane
(** [Read] inside {!with_read} until it returns; [Background] otherwise and
    outside Eio. *)

val with_read : (unit -> 'a) -> 'a
(** Run [f] as one HTTP read. Outside Eio this runs [f] unmarked. *)

val with_background : (unit -> 'a) -> 'a
(** Run [f] as background work even inside a read, for work no request waits
    on: a refresh started after the request was already answered. Fibers
    forked inside inherit it. *)

val to_string : lane -> string
