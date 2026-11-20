(* The decisions an owed read makes about when a surface reads again.

   The case worth a test is a change announced while a read is in flight.
   That read may have been answered from a state before the change, so one
   more read is owed after it. *)

open Alcotest
module O = Masc_tui_owed_read

(* Instants on the main loop's clock, [seconds] after this test began. *)
let start = Masc_tui_wake.Mono.now ()
let at seconds = Masc_tui_wake.Mono.after start seconds

let retry_s = 2.0
let max_retry_s = 30.0
let failed ~now t = O.failed ~retry_s ~max_retry_s ~now t

let test_a_change_is_owed_until_a_later_read_succeeds () =
  let t = O.changed O.settled in
  check bool "owed after a change" true (O.due ~now:(at 0.0) t);
  let t = O.started t in
  check bool "not due while reading" false (O.due ~now:(at 0.0) t);
  check bool "settled after success" false (O.due ~now:(at 0.0) (O.succeeded t))

let test_a_change_during_a_read_is_read_again () =
  let t = O.started O.settled in
  let t = O.changed t in
  check bool "still not due while the read is in flight" false (O.due ~now:(at 0.0) t);
  let t = O.succeeded t in
  check bool "owed once the earlier read lands" true (O.due ~now:(at 0.0) t);
  let t = O.succeeded (O.started t) in
  check bool "settled after the read that followed the change" false (O.due ~now:(at 0.0) t)

let test_a_failed_read_retries_with_backoff () =
  let t = failed ~now:(at 10.0) (O.started (O.changed O.settled)) in
  check bool "not before the first wait" false (O.due ~now:(at 11.9) t);
  check bool "after the first wait" true (O.due ~now:(at 12.0) t);
  let t = failed ~now:(at 12.0) (O.started t) in
  check bool "second wait doubles" false (O.due ~now:(at 15.9) t);
  check bool "after the second wait" true (O.due ~now:(at 16.0) t);
  let t = O.succeeded (O.started t) in
  check bool "a success ends the retries" false (O.due ~now:(at 1000.0) t)

let test_the_wait_stops_growing () =
  let rec fail_times n now t =
    if n = 0 then t else fail_times (n - 1) now (failed ~now (O.started t))
  in
  let t = fail_times 10 (at 0.0) (O.changed O.settled) in
  check bool "capped wait has passed" true (O.due ~now:(at max_retry_s) t);
  check bool "capped wait has not passed" false (O.due ~now:(at (max_retry_s -. 0.1)) t)

let test_a_change_during_a_failure_wait_is_read_now_and_keeps_the_backoff () =
  let t = failed ~now:(at 0.0) (O.started (O.changed O.settled)) in
  let t = O.changed t in
  check bool "the change is read now" true (O.due ~now:(at 1.0) t);
  let t = failed ~now:(at 1.0) (O.started t) in
  check bool "the next failure waits the doubled time" false (O.due ~now:(at 4.9) t);
  check bool "after the doubled time" true (O.due ~now:(at 5.0) t)

(* A placeholder answer waits like a failure, unless a change was announced
   while it was read: that change is read now, and the placeholders in a row
   still count toward the next wait. *)
let placeholder ~now t = O.placeholder ~retry_s ~max_retry_s ~now t

let test_a_placeholder_waits_unless_a_change_came_during_it () =
  let t = placeholder ~now:(at 10.0) (O.started (O.changed O.settled)) in
  check bool "not before the first wait" false (O.due ~now:(at 11.9) t);
  check bool "after the first wait" true (O.due ~now:(at 12.0) t);
  let t = placeholder ~now:(at 12.0) (O.changed (O.started t)) in
  check bool "a change during the read is read now" true (O.due ~now:(at 12.0) t);
  let t = placeholder ~now:(at 12.0) (O.started t) in
  check bool "the third placeholder waits the third wait" false (O.due ~now:(at 19.9) t);
  check bool "after the third wait" true (O.due ~now:(at 20.0) t)

(* The record as the read that just answered left it. A read in flight keeps
   the change announced during it; an answer with no read in flight is a
   read begun just now with no change since, so a placeholder from it waits
   instead of reading again at once. *)
let test_answering_keeps_the_change_of_the_read_in_flight () =
  let changed_since = function
    | O.Reading { changed_since; _ } -> Some changed_since
    | O.(Settled | Owed _ | Waiting _) -> None
  in
  check (option bool) "a change during the read stays" (Some true)
    (changed_since (O.answering (O.changed (O.started O.settled))));
  check (option bool) "an unheard read counts as begun" (Some false)
    (changed_since (O.answering O.settled));
  check bool "an unheard read that failed is retried" true
    (O.due ~now:(at 2.0) (failed ~now:(at 0.0) (O.answering O.settled)));
  check bool "an unheard placeholder waits" false
    (O.due ~now:(at 0.0)
       (O.placeholder ~retry_s:2.0 ~max_retry_s:30.0 ~now:(at 0.0) (O.answering (O.changed O.settled))))

(* An answer arriving when no read is in flight belongs to a read that did
   not carry the owed change (an audit still owed, for one), so it settles
   nothing. *)
let test_an_answer_without_a_read_in_flight_keeps_what_is_owed () =
  let owed = O.changed O.settled in
  check bool "success keeps it owed" true (O.due ~now:(at 0.0) (O.succeeded owed));
  check bool "failure keeps it owed" true (O.due ~now:(at 0.0) (failed ~now:(at 0.0) owed))

let test_a_replacing_read_covers_the_changes_before_it () =
  let t = O.changed (O.started O.settled) in
  let t = O.succeeded (O.started t) in
  check bool "the read that replaced it began after the change" false (O.due ~now:(at 0.0) t)

let test_a_read_that_never_ran_is_owed_again () =
  let reading = O.started (O.changed O.settled) in
  check bool "a read in flight is not due" false (O.due ~now:(at 0.0) reading);
  check bool "the read that never ran leaves it owed" true (O.due ~now:(at 0.0) (O.abandoned reading));
  let after_failure = O.started (failed ~now:(at 0.0) reading) in
  check bool "the failures in a row survive" true
    (match O.abandoned after_failure with O.Owed { failures = 1 } -> true | _ -> false)

(* The server sets stale_at = last verdict + 12h, so a snapshot whose
   evaluator is already Stale carries a stale_at in the past. The read that
   returned it covered that turn; keeping the past moment would store a
   schedule that is due at once, and the loop would owe a new read on every
   answer, since each answer carries the same past moment. *)
let test_a_stale_at_already_past_stores_no_schedule () =
  check bool "a past stale_at is not stored" false
    (Option.is_some (O.stale_at_to_schedule ~wall_now:100.0 (Some 99.0)));
  check bool "a stale_at at the reading moment is not stored either" false
    (Option.is_some (O.stale_at_to_schedule ~wall_now:100.0 (Some 100.0)));
  check bool "a future stale_at is stored" true
    (Option.is_some (O.stale_at_to_schedule ~wall_now:100.0 (Some 100.5)));
  check bool "no stale_at stays none" false
    (Option.is_some (O.stale_at_to_schedule ~wall_now:100.0 None));
  (match O.stale_at_to_schedule ~wall_now:100.0 (Some 100.5) with
   | Some at ->
       check bool "the stored moment is the server's own" true (Float.equal at 100.5)
   | None -> check bool "a future stale_at is stored" true false)

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
        ; test_case "a change during a failure wait is read now and keeps the backoff" `Quick
            test_a_change_during_a_failure_wait_is_read_now_and_keeps_the_backoff
        ; test_case "an answer without a read in flight keeps what is owed" `Quick
            test_an_answer_without_a_read_in_flight_keeps_what_is_owed
        ; test_case "a placeholder waits unless a change came during it" `Quick
            test_a_placeholder_waits_unless_a_change_came_during_it
        ; test_case "answering keeps the change of the read in flight" `Quick
            test_answering_keeps_the_change_of_the_read_in_flight
        ; test_case "a read that never ran is owed again" `Quick
            test_a_read_that_never_ran_is_owed_again
        ; test_case "a replacing read covers the changes before it" `Quick
            test_a_replacing_read_covers_the_changes_before_it
        ; test_case "a stale_at already past stores no schedule" `Quick
            test_a_stale_at_already_past_stores_no_schedule
        ] )
    ]
