(** One listing of a host cycle, walked in order. A listing is
    one page or several (RFC
    librarian-read-waits-and-shrinks-no-further-than-the-refusal-says 3.1).

    The walk starts each request once. A request that runs beside the walk
    gets its own fiber, and the walk goes on to the next request only while
    fewer than [max_in_flight] of them are running. With
    {!Lane_addon_config.one_exact_at_a_time} the walk waits for each one, so
    every request starts after the one before it has ended.

    The walk owns no request state. It counts the fibers it started. *)

type 'halt run = running_at_start:int -> (unit, 'halt) result
(** One request from its start to its end. [running_at_start] is how many
    [Beside] requests were running when this one started. [Error] ends the
    cycle. *)

type 'halt step =
  | Skip  (** Nothing to do for this request in this listing. *)
  | Halt of 'halt  (** The listing itself ends the cycle here. *)
  | Here of 'halt run  (** Handled where the walk stands; the walk waits for it. *)
  | Beside of 'halt run  (** Runs in its own fiber. *)

type ('request, 'halt) listing =
  | Done  (** Nothing more to list. *)
  | Page of 'request * 'request list * (unit -> (('request, 'halt) listing, 'halt) result)
      (** A page of one or more requests, and how to read what follows it. *)

val walk :
  max_in_flight:Lane_addon_config.exact_in_flight ->
  propagates:(exn -> bool) ->
  step:('request -> 'halt step) ->
  ('request, 'halt) listing ->
  'halt option
(** [step] is asked for each request when the walk reaches it, so it sees
    what earlier requests of the same listing left behind.

    The walk reads what follows a [Page] when it has started that page's
    last request. The requests it started keep running meanwhile, so
    the number running does not fall at a page end. A page that cannot be
    read ends the cycle like a [Halt] at that place.

    After a [Halt] or an [Error] the walk starts no other request. The
    requests already running go on to their end, and the walk returns the
    first [Halt] or [Error] in listing order. [None] means every request was
    reached.

    An exception from [step] or from a request also stops the walk from
    starting another request. The walk waits for the running ones to end and
    then raises the first exception it caught. One exception leaves the walk,
    never a combination.

    An exception that [propagates] is not kept: it leaves at once and the
    running fibers are cancelled. If the walk already keeps an exception, that
    one still leaves after the running requests end and the propagating one
    is dropped. While a propagating exception is leaving, what the cancelled
    requests raise is dropped too. A dropped exception that does not
    propagate is logged as a warning. Cancellation always leaves at once. *)
