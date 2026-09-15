(* The guard on one forced-refresh attempt at publishing the execution
   surface: it publishes a failure only while it has published no answer.

   The attempt publishes what it computed, then refreshes the light body from
   it, and the whole attempt runs under a window. Both the refresh and the
   window can produce a failure for an attempt that already published, and
   that failure used to land on the answer.

   These cases cover the guard, not its wiring. Driving
   [dashboard_execution_http_response] into either failure is not reachable
   from a test: its window is [Env_config_runtime.Dashboard.execution_timeout_sec],
   which has a 5s floor and is read once at module load, and the light-body
   refresh it calls takes no injectable failure. That both failure paths go
   through the guard is read at the call site, not run here. *)
open Masc
module Execution = Server_dashboard_http_execution_surfaces
module Attempt = Server_dashboard_http_execution_surfaces.For_testing

let with_execution_surface f =
  let invalidate = Execution.invalidate_execution_cache in
  invalidate ();
  Fun.protect ~finally:invalidate f
;;

(* A failure of the kind that ends an attempt. Only its string form reaches
   the surface, so the key inside it is not the production key under test. *)
let a_failure_that_ends_an_attempt () =
  Dashboard_cache.Compute_timeout ("the attempt's key", false)
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
    (Attempt.publish_execution_attempt_failure attempt (a_failure_that_ends_an_attempt ()));
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
    (Attempt.publish_execution_attempt_failure attempt (a_failure_that_ends_an_attempt ()));
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
