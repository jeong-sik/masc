open Alcotest

module Registry = Masc.Keeper_tool_approval_registry

(* Real clock with sub-second waits, the way test_pool.ml does it: this Eio
   version has no mock clock, and the logic is generic over [clock], so real
   time is a faithful driver as long as the waits stay small. *)

let outcome_to_string : Registry.outcome -> string = function
  | Registry.Answered Registry.Approve -> "approved"
  | Registry.Answered Registry.Deny -> "denied"
  | Registry.Timed_out -> "timed_out"
  | Registry.Displaced -> "displaced"

let outcome = testable (Fmt.of_to_string outcome_to_string) ( = )

let with_env f = Eio_main.run (fun env -> f ~clock:(Eio.Stdenv.clock env))

let keeper = "keeper.one"

(* Answer a wait once it has actually opened. Sleeping first would be a race:
   settle before await registers returns false and the waiter then blocks for
   the whole timeout. *)
let settle_when_pending registry ~clock ~tool_call_id decision =
  let rec wait_for_registration attempts =
    if Registry.pending registry = [] && attempts > 0 then begin
      Eio.Time.sleep clock 0.005;
      wait_for_registration (attempts - 1)
    end
  in
  wait_for_registration 100;
  Registry.settle registry ~keeper_name:keeper ~tool_call_id decision

let test_an_answer_releases_the_wait () =
  with_env (fun ~clock ->
      let registry = Registry.create () in
      let settled = ref false in
      let result =
        Eio.Fiber.pair
          (fun () ->
            Registry.await registry ~clock ~keeper_name:keeper
              ~tool_call_id:"call-1" ~timeout_sec:5.0)
          (fun () ->
            settled :=
              settle_when_pending registry ~clock ~tool_call_id:"call-1"
                Registry.Approve)
        |> fst
      in
      check outcome "the waiter gets the operator's answer"
        (Registry.Answered Registry.Approve) result;
      check bool "and settle reports that someone was waiting" true !settled;
      check int "the wait is gone" 0 (List.length (Registry.pending registry)))

let test_a_denial_is_carried_as_itself () =
  with_env (fun ~clock ->
      let registry = Registry.create () in
      let result =
        Eio.Fiber.pair
          (fun () ->
            Registry.await registry ~clock ~keeper_name:keeper
              ~tool_call_id:"call-2" ~timeout_sec:5.0)
          (fun () ->
            ignore
              (settle_when_pending registry ~clock ~tool_call_id:"call-2"
                 Registry.Deny))
        |> fst
      in
      check outcome "denial is not an absence of approval, it is a decision"
        (Registry.Answered Registry.Deny) result)

let test_a_wait_nobody_answers_times_out () =
  with_env (fun ~clock ->
      let registry = Registry.create () in
      let result =
        Registry.await registry ~clock ~keeper_name:keeper
          ~tool_call_id:"call-3" ~timeout_sec:0.05
      in
      check outcome "the turn is released rather than parked forever"
        Registry.Timed_out result;
      (* The entry has to be gone on this path too, or a later answer would
         find a waiter that no longer exists. *)
      check int "and the wait is cleaned up" 0
        (List.length (Registry.pending registry)))

let test_answering_a_wait_that_already_timed_out_reports_it () =
  with_env (fun ~clock ->
      let registry = Registry.create () in
      let timed_out =
        Registry.await registry ~clock ~keeper_name:keeper
          ~tool_call_id:"call-4" ~timeout_sec:0.02
      in
      check outcome "the wait ended on its own" Registry.Timed_out timed_out;
      check bool "a late answer says nothing was listening" false
        (Registry.settle registry ~keeper_name:keeper ~tool_call_id:"call-4"
           Registry.Approve))

let test_answering_an_unknown_call_reports_it () =
  with_env (fun ~clock:_ ->
      let registry = Registry.create () in
      check bool "no wait, no success" false
        (Registry.settle registry ~keeper_name:keeper
           ~tool_call_id:"never-asked" Registry.Approve))

let test_a_second_wait_on_the_same_id_displaces_the_first () =
  with_env (fun ~clock ->
      let registry = Registry.create () in
      (* Both waits are on one id, so an answer cannot be meant for both. The
         first is told it was displaced instead of sharing the second's
         answer, which would approve a call its operator never saw. *)
      let first, second =
        Eio.Fiber.pair
          (fun () ->
            Registry.await registry ~clock ~keeper_name:keeper
              ~tool_call_id:"call-5" ~timeout_sec:5.0)
          (fun () ->
            let rec wait_for_first attempts =
              if Registry.pending registry = [] && attempts > 0 then begin
                Eio.Time.sleep clock 0.005;
                wait_for_first (attempts - 1)
              end
            in
            wait_for_first 100;
            Eio.Fiber.pair
              (fun () ->
                Registry.await registry ~clock ~keeper_name:keeper
                  ~tool_call_id:"call-5" ~timeout_sec:5.0)
              (fun () ->
                Eio.Time.sleep clock 0.02;
                ignore
                  (Registry.settle registry ~keeper_name:keeper
                     ~tool_call_id:"call-5" Registry.Approve))
            |> fst)
      in
      check outcome "the first wait is told it was displaced" Registry.Displaced
        first;
      check outcome "and only the second gets the answer"
        (Registry.Answered Registry.Approve) second)

let test_waits_are_scoped_to_their_keeper () =
  with_env (fun ~clock ->
      let registry = Registry.create () in
      let result =
        Eio.Fiber.pair
          (fun () ->
            Registry.await registry ~clock ~keeper_name:"keeper.one"
              ~tool_call_id:"shared-id" ~timeout_sec:0.15)
          (fun () ->
            let rec wait_for_registration attempts =
              if Registry.pending registry = [] && attempts > 0 then begin
                Eio.Time.sleep clock 0.005;
                wait_for_registration (attempts - 1)
              end
            in
            wait_for_registration 100;
            (* Same call id, different keeper. Tool call ids are unique per
               provider stream, not across keepers. *)
            Registry.settle registry ~keeper_name:"keeper.two"
              ~tool_call_id:"shared-id" Registry.Approve)
      in
      check outcome "the other keeper's answer does not release this wait"
        Registry.Timed_out (fst result);
      check bool "and it reports that nothing was waiting" false (snd result))

let test_pending_lists_open_waits_oldest_first () =
  with_env (fun ~clock ->
      let registry = Registry.create () in
      Eio.Fiber.all
        [ (fun () ->
            ignore
              (Registry.await registry ~clock ~keeper_name:keeper
                 ~tool_call_id:"call-a" ~timeout_sec:0.2))
        ; (fun () ->
            Eio.Time.sleep clock 0.01;
            ignore
              (Registry.await registry ~clock ~keeper_name:keeper
                 ~tool_call_id:"call-b" ~timeout_sec:0.2))
        ; (fun () ->
            Eio.Time.sleep clock 0.05;
            check (list string) "both waits are listed, in the order they opened"
              [ "call-a"; "call-b" ]
              (Registry.pending registry
               |> List.map (fun (p : Registry.pending) -> p.tool_call_id)))
        ])

let test_a_cancelled_wait_leaves_nothing_behind () =
  with_env (fun ~clock ->
      let registry = Registry.create () in
      (* Cancellation is the ordinary way a turn ends early -- an operator
         interrupts it. The waiter has to come off the list then too, or the
         next call with the same id is displaced by a ghost. *)
      Eio.Fiber.first
        (fun () ->
          ignore
            (Registry.await registry ~clock ~keeper_name:keeper
               ~tool_call_id:"call-cancel" ~timeout_sec:5.0))
        (fun () -> Eio.Time.sleep clock 0.02);
      check int "the cancelled wait is not still registered" 0
        (List.length (Registry.pending registry)))

let test_decision_labels_round_trip () =
  List.iter
    (fun decision ->
      check (option string) "a label decodes back to what it named"
        (Some (Registry.decision_to_string decision))
        (Registry.decision_of_string (Registry.decision_to_string decision)
         |> Option.map Registry.decision_to_string))
    [ Registry.Approve; Registry.Deny ];
  check bool "an unknown label is not guessed at" true
    (Option.is_none (Registry.decision_of_string "maybe"))

let () =
  run "keeper_tool_approval_registry"
    [ ( "answering"
      , [ test_case "an answer releases the wait" `Quick
            test_an_answer_releases_the_wait
        ; test_case "a denial is carried as itself" `Quick
            test_a_denial_is_carried_as_itself
        ; test_case "decision labels round-trip" `Quick
            test_decision_labels_round_trip
        ] )
    ; ( "nobody answers"
      , [ test_case "a wait nobody answers times out" `Quick
            test_a_wait_nobody_answers_times_out
        ; test_case "a late answer reports that nothing was listening" `Quick
            test_answering_a_wait_that_already_timed_out_reports_it
        ; test_case "answering an unknown call reports it" `Quick
            test_answering_an_unknown_call_reports_it
        ] )
    ; ( "identity and cleanup"
      , [ test_case "a second wait on the same id displaces the first" `Quick
            test_a_second_wait_on_the_same_id_displaces_the_first
        ; test_case "waits are scoped to their keeper" `Quick
            test_waits_are_scoped_to_their_keeper
        ; test_case "pending lists open waits oldest first" `Quick
            test_pending_lists_open_waits_oldest_first
        ; test_case "a cancelled wait leaves nothing behind" `Quick
            test_a_cancelled_wait_leaves_nothing_behind
        ] )
    ]
