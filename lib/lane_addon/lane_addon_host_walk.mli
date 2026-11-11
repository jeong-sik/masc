(** One listing of a host cycle, walked in order (RFC
    host-cycle-runs-exact-requests-side-by-side 3.3 and 3.5).

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

val walk :
  max_in_flight:Lane_addon_config.exact_in_flight ->
  propagates:(exn -> bool) ->
  step:('request -> 'halt step) ->
  'request list ->
  'halt option
(** [step] is asked for each request when the walk reaches it, so it sees
    what earlier requests of the same listing left behind.

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
    requests raise is dropped too. Cancellation always leaves at once. *)
