(* The guard on attempts at publishing the execution surface. An attempt
   publishes a failure only while it has published no answer, and attempts
   that run at once under one generation are ordered by when they began: the
   outcome of an attempt that began earlier never replaces the outcome of one
   that began later.

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
  Dashboard_cache.Compute_timeout
    { key = "the attempt's key"; role = Dashboard_cache.Compute_owner }
;;

let surface () = Server_dashboard_http_cache.snapshot Execution.execution_cache

let published_marker () =
  match Server_dashboard_http_cache.cached_surface_json Execution.execution_cache with
  | `Assoc fields -> (match List.assoc_opt "marker" fields with Some (`String m) -> Some m | _ -> None)
  | _ -> None
;;

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

(* Two forced refreshes admitted without an invalidation between them share
   one generation. The one that began later answered; the one that began
   earlier then fails. Its failure describes an older read and must not mark
   the later success as an error. *)
let test_an_older_attempts_failure_does_not_replace_a_newer_attempts_answer () =
  with_execution_surface
  @@ fun () ->
  let older = Attempt.begin_execution_attempt () in
  let newer = Attempt.begin_execution_attempt () in
  Alcotest.(check bool)
    "the newer attempt publishes its answer"
    true
    (Attempt.publish_execution_attempt_success newer (`Assoc [ "marker", `String "newer" ]));
  Alcotest.(check bool)
    "the older attempt's failure is not published over it"
    false
    (Attempt.publish_execution_attempt_failure older (a_failure_that_ends_an_attempt ()));
  let surface = surface () in
  Alcotest.(check (option string)) "no error was recorded" None surface.last_error;
  Alcotest.(check (option string)) "the newer answer stands" (Some "newer") (published_marker ())
;;

let test_an_older_attempts_answer_does_not_replace_a_newer_attempts_answer () =
  with_execution_surface
  @@ fun () ->
  let older = Attempt.begin_execution_attempt () in
  let newer = Attempt.begin_execution_attempt () in
  Alcotest.(check bool)
    "the newer attempt publishes its answer"
    true
    (Attempt.publish_execution_attempt_success newer (`Assoc [ "marker", `String "newer" ]));
  Alcotest.(check bool)
    "the older attempt's answer is not published over it"
    false
    (Attempt.publish_execution_attempt_success older (`Assoc [ "marker", `String "older" ]));
  Alcotest.(check (option string)) "the newer answer stands" (Some "newer") (published_marker ())
;;

(* The order is by when an attempt began, not by who finishes first: an older
   attempt that finishes first publishes, and the newer attempt's outcome,
   success or failure, is published over it. *)
let test_a_newer_attempts_outcome_follows_an_older_attempts_answer () =
  with_execution_surface
  @@ fun () ->
  let older = Attempt.begin_execution_attempt () in
  let newer = Attempt.begin_execution_attempt () in
  Alcotest.(check bool)
    "the older attempt publishes while nothing newer has"
    true
    (Attempt.publish_execution_attempt_success older (`Assoc [ "marker", `String "older" ]));
  Alcotest.(check bool)
    "the newer attempt's failure is published over it"
    true
    (Attempt.publish_execution_attempt_failure newer (a_failure_that_ends_an_attempt ()));
  Alcotest.(check bool)
    "the failure is the surface's"
    true
    (Option.is_some (surface ()).last_error)
;;

(* An invalidation ends every attempt that began before it, whatever the
   attempt would publish. *)
let test_an_attempt_begun_before_an_invalidation_publishes_nothing () =
  with_execution_surface
  @@ fun () ->
  let before = Attempt.begin_execution_attempt () in
  Execution.invalidate_execution_cache ();
  Alcotest.(check bool)
    "its failure is not published"
    false
    (Attempt.publish_execution_attempt_failure before (Failure "before"));
  Alcotest.(check bool)
    "its answer is not published"
    false
    (Attempt.publish_execution_attempt_success before (`Assoc [ "marker", `String "before" ]));
  let surface = surface () in
  Alcotest.(check (option string)) "no error was recorded" None surface.last_error;
  Alcotest.(check bool) "no answer was recorded" true (Option.is_none surface.last_success_unix);
  let after = Attempt.begin_execution_attempt () in
  Alcotest.(check bool)
    "an attempt begun after the invalidation publishes"
    true
    (Attempt.publish_execution_attempt_success after (`Assoc [ "marker", `String "after" ]))
;;

(* A newer attempt that failed has said the surface has no answer; the outcome
   of an older read, answer or failure, does not take that back. *)
let test_an_older_attempts_outcome_does_not_replace_a_newer_attempts_failure () =
  with_execution_surface
  @@ fun () ->
  let older = Attempt.begin_execution_attempt () in
  let newer = Attempt.begin_execution_attempt () in
  Alcotest.(check bool)
    "the newer attempt publishes its failure"
    true
    (Attempt.publish_execution_attempt_failure newer (Failure "newer"));
  Alcotest.(check bool)
    "the older attempt's answer is not published over it"
    false
    (Attempt.publish_execution_attempt_success older (`Assoc [ "marker", `String "older" ]));
  Alcotest.(check bool)
    "the older attempt's failure is not published over it"
    false
    (Attempt.publish_execution_attempt_failure older (Failure "older"));
  let surface = surface () in
  Alcotest.(check (option string))
    "the newer failure stands"
    (Some (Printexc.to_string (Failure "newer")))
    surface.last_error;
  Alcotest.(check bool) "no answer was recorded" true (Option.is_none surface.last_success_unix)
;;

(* The refresh loop publishes an attempt's exception from the attempt and the
   message of the window that ran out from [on_failure], both under one
   attempt. *)
let test_an_attempts_failure_message_follows_its_failure () =
  with_execution_surface
  @@ fun () ->
  let attempt = Attempt.begin_execution_attempt () in
  Alcotest.(check bool)
    "the attempt publishes its failure"
    true
    (Attempt.publish_execution_attempt_failure attempt (Failure "the attempt"));
  Alcotest.(check bool)
    "the attempt publishes the message of its window"
    true
    (Attempt.publish_execution_attempt_failure_message attempt "the window ran out");
  Alcotest.(check (option string))
    "the message is the surface's"
    (Some "the window ran out")
    (surface ()).last_error
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
        ; Alcotest.test_case
            "an older attempt's failure does not replace a newer attempt's answer"
            `Quick
            test_an_older_attempts_failure_does_not_replace_a_newer_attempts_answer
        ; Alcotest.test_case
            "an older attempt's answer does not replace a newer attempt's answer"
            `Quick
            test_an_older_attempts_answer_does_not_replace_a_newer_attempts_answer
        ; Alcotest.test_case
            "a newer attempt's outcome follows an older attempt's answer"
            `Quick
            test_a_newer_attempts_outcome_follows_an_older_attempts_answer
        ; Alcotest.test_case
            "an attempt begun before an invalidation publishes nothing"
            `Quick
            test_an_attempt_begun_before_an_invalidation_publishes_nothing
        ; Alcotest.test_case
            "an older attempt's outcome does not replace a newer attempt's failure"
            `Quick
            test_an_older_attempts_outcome_does_not_replace_a_newer_attempts_failure
        ; Alcotest.test_case
            "an attempt's failure message follows its failure"
            `Quick
            test_an_attempts_failure_message_follows_its_failure
        ] )
    ]
;;
