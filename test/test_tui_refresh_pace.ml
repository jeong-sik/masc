(* When a refresh pass may read [/health] again after the probe failed
   (RFC tui-one-screen-grammar §2, §10).

   With no wait, a failed pass withdrew the workspace confirmation, the
   observer recovery restored it and the reopened stream asked for the next
   pass at once, many times a second (#53205). These are the decisions that
   break that ring, and the ones that end the wait once the server is back. *)

open Alcotest
module P = Masc_tui_refresh_pace

let retry_s = 2.0
let max_retry_s = 30.0
let failed ~now t = P.probe_failed ~retry_s ~max_retry_s ~now t

let wait_after ~now t =
  match t with
  | P.Failing { retry_at; _ } -> retry_at -. now
  | P.Answering | P.Recovered _ -> Alcotest.fail "no wait is scheduled"

let failures t =
  match t with
  | P.Failing { failures; _ } | P.Recovered { failures } -> failures
  | P.Answering -> 0

let test_consecutive_failures_wait_longer_up_to_the_max () =
  let rec run t now acc = function
    | 0 -> List.rev acc
    | n ->
        let t = failed ~now t in
        let wait = wait_after ~now t in
        run t (now +. wait) (wait :: acc) (n - 1)
  in
  check (list (float 1e-9)) "waits double and stop at the max"
    [ 2.0; 4.0; 8.0; 16.0; 30.0; 30.0; 30.0 ]
    (run P.answering 100.0 [] 7);
  check int "each failure counts" 3
    (failures (failed ~now:0.0 (failed ~now:0.0 (failed ~now:0.0 P.answering))))

(* An outage of hours: the count of failures keeps growing, the wait does not
   shrink back to nothing, so the ring cannot come back after a long outage. *)
let test_a_long_outage_keeps_the_longest_wait () =
  let rec run t now n =
    if n = 0 then t, now
    else
      let t = failed ~now t in
      run t (now +. wait_after ~now t) (n - 1)
  in
  let t, now = run P.answering 0.0 5000 in
  check int "every failure counts" 5000 (failures t);
  check (float 1e-9) "the wait stays at the max" max_retry_s (wait_after ~now:now (failed ~now t))

let test_a_pass_that_answers_resets_the_wait () =
  let t = failed ~now:0.0 (failed ~now:0.0 (failed ~now:0.0 P.answering)) in
  let t = P.pass_answered t in
  check bool "nothing is owed after the pass answered" false (P.due ~now:1000.0 t);
  check bool "a pass the TUI asks for starts at once" true (P.starts ~now:0.0 P.Revalidate t);
  check (float 1e-9) "the next failure waits the first wait again" retry_s
    (wait_after ~now:50.0 (failed ~now:50.0 t))

let test_no_pass_starts_before_its_wait () =
  let t = failed ~now:10.0 P.answering in
  check bool "the owed pass is not due before the wait" false (P.due ~now:11.9 t);
  check bool "the owed pass does not start before the wait" false
    (P.starts ~now:11.9 P.Owed_pass t);
  check bool "the owed pass is due once the wait is over" true (P.due ~now:12.0 t);
  check bool "the owed pass starts once the wait is over" true
    (P.starts ~now:12.0 P.Owed_pass t);
  check bool "a pass the TUI asks for waits" false (P.starts ~now:11.9 P.Revalidate t);
  check bool "it still leaves the start to the owed pass after the wait" false
    (P.starts ~now:12.0 P.Revalidate t);
  check bool "an answering probe owes no pass" false (P.due ~now:0.0 P.answering);
  check bool "an answering probe starts what the TUI asks for" true
    (P.starts ~now:0.0 P.Revalidate P.answering)

let test_an_operator_key_skips_the_wait_and_keeps_the_count () =
  let t = failed ~now:10.0 P.answering in
  check bool "the operator's key starts during the wait" true
    (P.starts ~now:10.1 P.Operator_key t);
  check (float 1e-9) "a failure after it waits one step longer" 4.0
    (wait_after ~now:10.2 (failed ~now:10.2 t))

let test_an_answer_ends_the_wait_and_the_owed_pass_starts_now () =
  let t = failed ~now:10.0 (failed ~now:0.0 P.answering) in
  let t = P.answered_again t in
  check bool "the owed pass is due before its wait was over" true (P.due ~now:10.1 t);
  check bool "a pass the TUI asks for starts" true (P.starts ~now:10.1 P.Revalidate t);
  check (float 1e-9) "the run of failures is broken" retry_s
    (wait_after ~now:10.2 (failed ~now:10.2 t));
  check bool "a screen answer with nothing owed owes nothing" false
    (P.due ~now:0.0 (P.answered_again P.answering))

(* A server whose [/health] alone fails still opens the stream that restores
   the workspace confirmation. That open is the ring, so it keeps the wait. *)
let test_a_stream_open_at_every_attempt_keeps_the_wait () =
  let t = failed ~now:10.0 (failed ~now:0.0 P.answering) in
  let t = P.stream_opened P.Opened_each_time t in
  check bool "the owed pass is not due before its wait" false (P.due ~now:10.1 t);
  check bool "a pass the TUI asks for still waits" false (P.starts ~now:10.1 P.Revalidate t);
  check int "the run of failures goes on" 2 (failures t)

(* After an outage the same stream opens once the server is back. An attempt
   that did not open before it means the server answers again. *)
let test_a_stream_open_after_a_failed_attempt_ends_the_wait () =
  let t = failed ~now:10.0 (failed ~now:0.0 P.answering) in
  let t = P.stream_opened P.Opened_after_failure t in
  check bool "the owed pass is due before its wait was over" true (P.due ~now:10.1 t);
  check bool "a pass the TUI asks for starts" true (P.starts ~now:10.1 P.Revalidate t);
  check bool "with nothing owed it owes nothing" false
    (P.due ~now:0.0 (P.stream_opened P.Opened_after_failure P.answering))

(* The reopened stream is not a [/health] answer. A server whose [/health]
   still fails after it goes on doubling the wait; only [/health] answering
   ends the run. *)
let test_a_failure_after_a_reopened_stream_waits_longer () =
  let t = failed ~now:10.0 (failed ~now:0.0 P.answering) in
  let last_wait = wait_after ~now:10.0 t in
  let reopened = P.stream_opened P.Opened_after_failure t in
  check int "the run of failures goes on" 2 (failures reopened);
  let next_wait = wait_after ~now:10.2 (failed ~now:10.2 reopened) in
  check bool "the next failure waits longer than the last wait" true (next_wait > last_wait);
  check int "the next failure continues the run" 3 (failures (failed ~now:10.2 reopened));
  check (float 1e-9) "a [/health] answer after it ends the run" retry_s
    (wait_after ~now:10.3 (failed ~now:10.3 (P.answered_again reopened)))

let () =
  run "tui_refresh_pace"
    [ ( "pace",
        [ test_case "consecutive failures wait longer up to the max" `Quick
            test_consecutive_failures_wait_longer_up_to_the_max
        ; test_case "a long outage keeps the longest wait" `Quick
            test_a_long_outage_keeps_the_longest_wait
        ; test_case "a pass that answers resets the wait" `Quick
            test_a_pass_that_answers_resets_the_wait
        ; test_case "no pass starts before its wait" `Quick
            test_no_pass_starts_before_its_wait
        ; test_case "an operator key skips the wait and keeps the count" `Quick
            test_an_operator_key_skips_the_wait_and_keeps_the_count
        ; test_case "an answer ends the wait and the owed pass starts now" `Quick
            test_an_answer_ends_the_wait_and_the_owed_pass_starts_now
        ; test_case "a stream open at every attempt keeps the wait" `Quick
            test_a_stream_open_at_every_attempt_keeps_the_wait
        ; test_case "a stream open after a failed attempt ends the wait" `Quick
            test_a_stream_open_after_a_failed_attempt_ends_the_wait
        ; test_case "a failure after a reopened stream waits longer" `Quick
            test_a_failure_after_a_reopened_stream_waits_longer
        ] )
    ]
