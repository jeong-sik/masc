(* Chat requests queued behind a Keeper's running turn.

   The owner's queue of chat requests is not in the prompt of the turn that
   runs, so a request waits for the turn to end however long that takes.
   [Keeper_waiting_operations] says how many are queued. What matters is that
   it never reports a count the owner did not hold, that it says nothing when
   no request waits for this turn, that a count is told once, and that a
   request that never reached the model tells it again. *)

module Waiting = Masc.Keeper_waiting_operations

let waiting queued = Waiting.Waiting { queued }

let equal_waiting left right =
  match left, right with
  | Waiting.Not_waiting, Waiting.Not_waiting -> true
  | Waiting.Waiting { queued = left }, Waiting.Waiting { queued = right } -> Int.equal left right
  | Waiting.Not_waiting, Waiting.Waiting _ | Waiting.Waiting _, Waiting.Not_waiting -> false
;;

let pp_waiting formatter = function
  | Waiting.Not_waiting -> Format.pp_print_string formatter "Not_waiting"
  | Waiting.Waiting { queued } -> Format.fprintf formatter "Waiting %d" queued
;;

let waiting_testable = Alcotest.testable pp_waiting equal_waiting
let projected = Alcotest.result waiting_testable Alcotest.string

let projection ?(store_unavailable = false) ?(has_claimable_queued = true) queued_count =
  Waiting.waiting_of_projection ~store_unavailable ~queued_count ~has_claimable_queued
;;

let check_error label = function
  | Ok _ -> Alcotest.fail (label ^ ": expected an error")
  | Error _ -> ()
;;

let test_a_ready_request_is_waiting_for_the_turn () =
  Alcotest.check projected "three queued, one ready" (Ok (waiting 3)) (projection 3)
;;

let test_requests_that_wait_for_something_else_do_not_wait_for_the_turn () =
  Alcotest.check
    projected
    "all queued ones wait for a gate or a retry time"
    (Ok Waiting.Not_waiting)
    (projection ~has_claimable_queued:false 2)
;;

let test_an_empty_queue_is_not_waiting () =
  Alcotest.check
    projected
    "nothing queued"
    (Ok Waiting.Not_waiting)
    (projection ~has_claimable_queued:false 0)
;;

let test_an_unavailable_store_is_an_error_whatever_its_counts_say () =
  check_error "counts of the last good read" (projection ~store_unavailable:true 3);
  check_error "an empty last read" (projection ~store_unavailable:true ~has_claimable_queued:false 0)
;;

let test_a_projection_that_disagrees_with_itself_is_an_error () =
  check_error "negative count" (projection (-1));
  check_error "ready request in an empty queue" (projection ~has_claimable_queued:true 0)
;;

let test_nothing_waiting_renders_nothing () =
  Alcotest.(check (option string)) "no block" None (Waiting.render Waiting.Not_waiting)
;;

let test_the_block_gives_the_count () =
  List.iter
    (fun queued ->
       match Waiting.render (waiting queued) with
       | None -> Alcotest.fail "a waiting request renders a block"
       | Some text ->
         Alcotest.(check bool)
           (Printf.sprintf "%d queued is in the text" queued)
           true
           (Astring.String.is_infix ~affix:(Printf.sprintf "%d chat request" queued) text))
    [ 1; 17 ]
;;

let told = Alcotest.option waiting_testable

let test_a_count_is_told_once_after_the_model_answered () =
  let tracker = Waiting.create_tracker () in
  Alcotest.check told "round 1" (Some (waiting 2)) (Waiting.next tracker (waiting 2));
  Waiting.confirm tracker;
  Alcotest.check told "round 2 has nothing new" None (Waiting.next tracker (waiting 2))
;;

let test_a_higher_count_is_told_again () =
  let tracker = Waiting.create_tracker () in
  ignore (Waiting.next tracker (waiting 1));
  Waiting.confirm tracker;
  Alcotest.check told "a second request queued" (Some (waiting 3)) (Waiting.next tracker (waiting 3));
  Waiting.confirm tracker;
  Alcotest.check told "and stops once an answer confirmed it" None (Waiting.next tracker (waiting 3))
;;

let test_a_request_that_failed_tells_its_count_again () =
  let tracker = Waiting.create_tracker () in
  Alcotest.check told "round 1" (Some (waiting 2)) (Waiting.next tracker (waiting 2));
  (* No [confirm]: the request failed before the model answered it. *)
  Alcotest.check told "the next request tells it again" (Some (waiting 2)) (Waiting.next tracker (waiting 2))
;;

let test_a_count_that_fell_makes_a_later_rise_news () =
  let tracker = Waiting.create_tracker () in
  ignore (Waiting.next tracker (waiting 3));
  Waiting.confirm tracker;
  Alcotest.check told "fell to one" None (Waiting.next tracker (waiting 1));
  Alcotest.check told "rose to two" (Some (waiting 2)) (Waiting.next tracker (waiting 2));
  Waiting.confirm tracker;
  Alcotest.check told "emptied" None (Waiting.next tracker Waiting.Not_waiting);
  Alcotest.check told "rose to one again" (Some (waiting 1)) (Waiting.next tracker (waiting 1))
;;

let test_an_answer_does_not_confirm_a_count_the_queue_no_longer_holds () =
  let tracker = Waiting.create_tracker () in
  Alcotest.check told "round 1" (Some (waiting 2)) (Waiting.next tracker (waiting 2));
  (* The request that carried the count failed, and the queue emptied before
     the retry. The answer that follows carried no count. *)
  Alcotest.check told "emptied" None (Waiting.next tracker Waiting.Not_waiting);
  Waiting.confirm tracker;
  Alcotest.check told "a new request is news" (Some (waiting 2)) (Waiting.next tracker (waiting 2))
;;

let test_an_answer_with_nothing_asked_confirms_nothing () =
  let tracker = Waiting.create_tracker () in
  Waiting.confirm tracker;
  Alcotest.check told "the first count is news" (Some (waiting 1)) (Waiting.next tracker (waiting 1))
;;

let unexpected reason = Alcotest.fail ("unexpected: " ^ reason)

let test_an_unreadable_queue_gives_no_block_and_forgets_no_count () =
  let tracker = Waiting.create_tracker () in
  let reasons = ref [] in
  let block read =
    Waiting.block tracker ~read ~on_unavailable:(fun reason -> reasons := reason :: !reasons)
  in
  (match block (fun () -> Ok (waiting 2)) with
   | None -> Alcotest.fail "round 1 tells the count"
   | Some _ -> ());
  Waiting.confirm tracker;
  Alcotest.(check (option string)) "unreadable" None (block (fun () -> Error "owner unavailable"));
  Alcotest.(check (list string)) "the reason is reported" [ "owner unavailable" ] !reasons;
  Alcotest.(check (option string)) "the count is still known" None (block (fun () -> Ok (waiting 2)));
  Alcotest.(check (list string)) "no further reason" [ "owner unavailable" ] !reasons
;;

let test_an_unreadable_first_round_tells_the_count_on_the_next () =
  let tracker = Waiting.create_tracker () in
  Alcotest.(check (option string))
    "unreadable"
    None
    (Waiting.block tracker ~read:(fun () -> Error "owner unavailable") ~on_unavailable:ignore);
  match Waiting.block tracker ~read:(fun () -> Ok (waiting 2)) ~on_unavailable:unexpected with
  | None -> Alcotest.fail "the next readable round tells the count"
  | Some _ -> ()
;;

let () =
  Alcotest.run
    "keeper_waiting_operations"
    [ ( "projection"
      , [ Alcotest.test_case "ready request" `Quick test_a_ready_request_is_waiting_for_the_turn
        ; Alcotest.test_case "blocked requests" `Quick test_requests_that_wait_for_something_else_do_not_wait_for_the_turn
        ; Alcotest.test_case "empty queue" `Quick test_an_empty_queue_is_not_waiting
        ; Alcotest.test_case "unavailable store" `Quick test_an_unavailable_store_is_an_error_whatever_its_counts_say
        ; Alcotest.test_case "contradiction" `Quick test_a_projection_that_disagrees_with_itself_is_an_error
        ] )
    ; ( "render"
      , [ Alcotest.test_case "nothing waiting" `Quick test_nothing_waiting_renders_nothing
        ; Alcotest.test_case "the count" `Quick test_the_block_gives_the_count
        ] )
    ; ( "tracker"
      , [ Alcotest.test_case "told once" `Quick test_a_count_is_told_once_after_the_model_answered
        ; Alcotest.test_case "higher count" `Quick test_a_higher_count_is_told_again
        ; Alcotest.test_case "failed request" `Quick test_a_request_that_failed_tells_its_count_again
        ; Alcotest.test_case "fell then rose" `Quick test_a_count_that_fell_makes_a_later_rise_news
        ; Alcotest.test_case "stale answer" `Quick test_an_answer_does_not_confirm_a_count_the_queue_no_longer_holds
        ; Alcotest.test_case "answer without a count" `Quick test_an_answer_with_nothing_asked_confirms_nothing
        ] )
    ; ( "block"
      , [ Alcotest.test_case "unreadable queue" `Quick test_an_unreadable_queue_gives_no_block_and_forgets_no_count
        ; Alcotest.test_case "unreadable first round" `Quick test_an_unreadable_first_round_tells_the_count_on_the_next
        ] )
    ]
;;
