(* Nanoseconds since the program started, as Mtime_clock counts them. Kept
   in Int64 rather than float so a long-running process does not lose
   resolution the way a float of nanoseconds would past a few months. *)
type t = { at_ns : int64 }

let ns_per_second = 1_000_000_000.

(* A span past Int64 nanoseconds wraps rather than saturating, and this adds
   nothing to stop it. Measured 2026-09-07: it cannot be seen through this
   interface. [Int64.of_float] pins the span at max_int, the add wraps at_ns
   negative, and the subtraction in [passed] and [remaining_seconds] wraps a
   second time back onto the same answer -- 9.2e9 seconds left, not passed,
   with or without a saturating add. A guard here would change no result and
   carry a test that cannot fail, so there is none. *)
let after ~seconds =
  let span_ns =
    if seconds <= 0. then 0L else Int64.of_float (seconds *. ns_per_second)
  in
  { at_ns = Int64.add (Mtime_clock.elapsed_ns ()) span_ns }
;;

let remaining_seconds t =
  let left_ns = Int64.sub t.at_ns (Mtime_clock.elapsed_ns ()) in
  if Int64.compare left_ns 0L <= 0
  then 0.
  else Int64.to_float left_ns /. ns_per_second
;;

let passed t = Int64.compare (Int64.sub t.at_ns (Mtime_clock.elapsed_ns ())) 0L <= 0

(* The other half of the same question. A deadline answers "is it time yet";
   a stopwatch answers "how long has this taken", which is what a budget
   check and the line that reports it both want. Reading a deadline's
   remaining time cannot answer the second: it clamps at zero, so a run that
   overran its budget reports the budget rather than what it took. *)
type stopwatch = { started_ns : int64 }

let start () = { started_ns = Mtime_clock.elapsed_ns () }

let elapsed_seconds t =
  Int64.to_float (Int64.sub (Mtime_clock.elapsed_ns ()) t.started_ns)
  /. ns_per_second
;;
