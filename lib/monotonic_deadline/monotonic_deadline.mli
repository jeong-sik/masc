(** A deadline on a clock no NTP step moves.

    Subtracting two [Unix.gettimeofday] readings measures the wall clock, so
    it also measures any correction the clock took in between: an NTP step, a
    VM resume, the first sync after boot. A forward step retires a deadline
    that has not passed; a backward step withholds one that has. Where the
    answer only reaches a log that is noise, but these deadlines decide
    whether to kill a running command, how long to drain its output, and how
    long to wait before SIGKILL.

    [Mtime_clock.elapsed_ns] counts from the program's start and no
    correction moves it, so a span taken from it is the span that elapsed.

    The type is abstract on purpose. A deadline used to be a [float] holding
    a wall-clock instant, which is the same type as every other timestamp in
    the tree and compares against them without complaint. Nothing here is
    comparable to a wall-clock instant, so a site that mixes the two stops
    building instead of drifting. *)

type t

val after : seconds:float -> t
(** A deadline [seconds] from now. A non-positive [seconds] is already
    passed. *)

val remaining_seconds : t -> float
(** Seconds left, clamped at [0.] once passed — the shape a [select] or
    [poll] timeout wants, and one that cannot ask to wait backwards. *)

val passed : t -> bool
(** Whether the deadline is behind us. [remaining_seconds t = 0.] says the
    same thing; this reads better in a guard. *)
