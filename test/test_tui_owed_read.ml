(* The decisions an owed read makes about when a surface reads again.

   The case worth a test is a change announced while a read is in flight.
   That read may have been answered from a state before the change, so one
   more read is owed after it. *)

open Alcotest
module O = Masc_tui_owed_read

let retry_s = 2.0
let max_retry_s = 30.0
let failed ~now t = O.failed ~retry_s ~max_retry_s ~now t

let test_a_change_is_owed_until_a_later_read_succeeds () =
  let t = O.changed O.settled in
  check bool "owed after a change" true (O.due ~now:0.0 t);
  let t = O.started t in
  check bool "not due while reading" false (O.due ~now:0.0 t);
  check bool "settled after success" false (O.due ~now:0.0 (O.succeeded t))

let test_a_change_during_a_read_is_read_again () =
  let t = O.started O.settled in
  let t = O.changed t in
  check bool "still not due while the read is in flight" false (O.due ~now:0.0 t);
  let t = O.succeeded t in
  check bool "owed once the earlier read lands" true (O.due ~now:0.0 t);
  let t = O.succeeded (O.started t) in
  check bool "settled after the read that followed the change" false (O.due ~now:0.0 t)

let test_a_failed_read_retries_with_backoff () =
  let t = failed ~now:10.0 (O.started (O.changed O.settled)) in
  check bool "not before the first wait" false (O.due ~now:11.9 t);
  check bool "after the first wait" true (O.due ~now:12.0 t);
  let t = failed ~now:12.0 (O.started t) in
  check bool "second wait doubles" false (O.due ~now:15.9 t);
  check bool "after the second wait" true (O.due ~now:16.0 t);
  let t = O.succeeded (O.started t) in
  check bool "a success ends the retries" false (O.due ~now:1000.0 t)

let test_the_wait_stops_growing () =
  let rec fail_times n now t =
    if n = 0 then t else fail_times (n - 1) now (failed ~now (O.started t))
  in
  let t = fail_times 10 0.0 (O.changed O.settled) in
  check bool "capped wait has passed" true (O.due ~now:max_retry_s t);
  check bool "capped wait has not passed" false (O.due ~now:(max_retry_s -. 0.1) t)

let test_a_change_during_a_failure_wait_keeps_the_scheduled_retry () =
  let t = failed ~now:0.0 (O.started (O.changed O.settled)) in
  let t = O.changed t in
  check bool "the change waits for the scheduled retry" false (O.due ~now:1.9 t);
  check bool "due at the scheduled retry" true (O.due ~now:2.0 t);
  let t = failed ~now:2.0 (O.started t) in
  check bool "the next failure waits the doubled time" false (O.due ~now:5.9 t);
  check bool "after the doubled time" true (O.due ~now:6.0 t)

(* An answer arriving when no read is in flight belongs to a read that did
   not carry the owed change (an audit still owed, for one), so it settles
   nothing. *)
let test_an_answer_without_a_read_in_flight_keeps_what_is_owed () =
  let owed = O.changed O.settled in
  check bool "success keeps it owed" true (O.due ~now:0.0 (O.succeeded owed));
  check bool "failure keeps it owed" true (O.due ~now:0.0 (failed ~now:0.0 owed))

let test_a_replacing_read_covers_the_changes_before_it () =
  let t = O.changed (O.started O.settled) in
  let t = O.succeeded (O.started t) in
  check bool "the read that replaced it began after the change" false (O.due ~now:0.0 t)

let test_a_read_that_never_ran_is_owed_again () =
  let reading = O.started (O.changed O.settled) in
  check bool "a read in flight is not due" false (O.due ~now:0.0 reading);
  check bool "the read that never ran leaves it owed" true (O.due ~now:0.0 (O.abandoned reading));
  let after_failure = O.started (failed ~now:0.0 reading) in
  check bool "the failures in a row survive" true
    (match O.abandoned after_failure with O.Owed { failures = 1 } -> true | _ -> false)

let () =
  run "tui_owed_read"
    [ ( "owed_read"
      , [ test_case "a change is owed until a later read succeeds" `Quick
            test_a_change_is_owed_until_a_later_read_succeeds
        ; test_case "a change during a read is read again" `Quick
            test_a_change_during_a_read_is_read_again
        ; test_case "a failed read retries with backoff" `Quick
            test_a_failed_read_retries_with_backoff
        ; test_case "the wait stops growing" `Quick test_the_wait_stops_growing
        ; test_case "a change during a failure wait keeps the scheduled retry" `Quick
            test_a_change_during_a_failure_wait_keeps_the_scheduled_retry
        ; test_case "an answer without a read in flight keeps what is owed" `Quick
            test_an_answer_without_a_read_in_flight_keeps_what_is_owed
        ; test_case "a read that never ran is owed again" `Quick
            test_a_read_that_never_ran_is_owed_again
        ; test_case "a replacing read covers the changes before it" `Quick
            test_a_replacing_read_covers_the_changes_before_it
        ] )
    ]
