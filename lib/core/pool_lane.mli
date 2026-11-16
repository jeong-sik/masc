(** Who the current fiber is working for: an HTTP read being answered, a
    Librarian unit, or anything else. RFC-0204 §3.1.

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
  | Librarian
      (** Memory upkeep for one Keeper. Its pool work goes to a pool of its
          own, so a Librarian slowed by an outside service it depends on
          spends only that pool, not the workers Keeper turns and requests
          use. *)
  | Background

val current : unit -> lane
(** [Read] inside {!with_read} until it returns; [Librarian] inside
    {!with_librarian}; [Background] otherwise and outside Eio. A read wins
    over a Librarian mark. *)

val with_read : (unit -> 'a) -> 'a
(** Run [f] as one HTTP read. Outside Eio this runs [f] unmarked. *)

val with_background : (unit -> 'a) -> 'a
(** Run [f] as background work even inside a read or a Librarian unit, for
    work no request waits on: a refresh started after the request was already
    answered. Fibers forked inside inherit it. *)

val with_librarian : (unit -> 'a) -> 'a
(** Run [f] as one Librarian unit. Fibers forked inside inherit it. Outside
    Eio this runs [f] unmarked. *)

val to_string : lane -> string
