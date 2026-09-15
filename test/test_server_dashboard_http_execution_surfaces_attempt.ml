(* One forced-refresh attempt at publishing the execution surface.

   The attempt publishes what it computed, then refreshes the light body from
   it. That refresh waits on the preparation worker, so the window around the
   whole attempt can close while it runs -- and the window then published its
   own Compute_timeout over the answer the same attempt had just recorded for
   the same generation. An attempt now publishes a failure only while it has
   published no answer. *)
open Masc
module Execution = Server_dashboard_http_execution_surfaces
module Attempt = Server_dashboard_http_execution_surfaces.For_testing

let with_execution_surface f =
  let invalidate = Execution.invalidate_execution_cache in
  invalidate ();
  Fun.protect ~finally:invalidate f
;;

let ended_the_window () =
  Dashboard_cache.Compute_timeout ("execution:default:light", false)
;;

let surface () = Server_dashboard_http_cache.snapshot Execution.execution_cache

let test_a_published_answer_survives_its_attempts_own_failure () =
  with_execution_surface
  @@ fun () ->
  let attempt = Attempt.begin_execution_attempt () in
  Alcotest.(check bool)
    "the attempt published its answer"
    true
    (Attempt.publish_execution_attempt_success
       attempt
       (`Assoc [ "marker", `String "answered" ]));
  Alcotest.(check bool)
    "the attempt's own later failure is not published over it"
    false
    (Attempt.publish_execution_attempt_failure attempt (ended_the_window ()));
  let surface = surface () in
  Alcotest.(check bool)
    "the answer is still the surface's"
    true
    (Option.is_some surface.last_success_unix);
  Alcotest.(check (option string)) "no error was recorded" None surface.last_error
;;

let test_an_attempt_that_answered_nothing_publishes_its_failure () =
  with_execution_surface
  @@ fun () ->
  let attempt = Attempt.begin_execution_attempt () in
  Alcotest.(check bool)
    "the attempt publishes what ended it"
    true
    (Attempt.publish_execution_attempt_failure attempt (ended_the_window ()));
  Alcotest.(check bool)
    "the failure is the surface's"
    true
    (Option.is_some (surface ()).last_error)
;;

let () =
  Alcotest.run
    "execution publication attempt"
    [ ( "attempt"
      , [ Alcotest.test_case
            "a published answer survives the attempt's own failure"
            `Quick
            test_a_published_answer_survives_its_attempts_own_failure
        ; Alcotest.test_case
            "an attempt that answered nothing publishes its failure"
            `Quick
            test_an_attempt_that_answered_nothing_publishes_its_failure
        ] )
    ]
;;
