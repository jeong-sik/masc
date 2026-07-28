(* Two reasons a turn releases its lane, and they need opposite responses.

   A durable-stimulus yield resolves itself: the next cycle drains the queue.
   An external-effect yield does not: a human or a gate has to answer first.
   While both produced [Yielded_to_durable_stimulus], a keeper stuck on an
   unanswered approval was indistinguishable from one cooperating with a busy
   queue, and every record — log line, finish_reason, dashboard status — said
   the same thing about both. *)

open Alcotest

module Run = Masc.Keeper_agent_run
module Receipt = Masc.Keeper_execution_receipt_types

let test_deferred_external_effect_is_not_a_stimulus_yield () =
  let decision =
    Run.terminal_effect_boundary_decision
      Masc.Keeper_tools_oas.External_effect_deferred
  in
  match decision with
  | Ok (Runtime_agent.Yield Runtime_agent.External_effect_waiting) -> ()
  | Ok (Runtime_agent.Yield Runtime_agent.Durable_stimulus_waiting) ->
    fail "a tool parked on an approval was reported as a queued stimulus"
  | Ok _ | Error _ -> fail "a deferred external effect did not yield"
;;

let test_open_effect_still_continues () =
  match
    Run.terminal_effect_boundary_decision
      Masc.Keeper_tools_oas.Terminal_effect_open
  with
  | Ok Runtime_agent.Continue -> ()
  | Ok _ | Error _ -> fail "an open effect must not release the lane"
;;

let test_each_yield_reason_maps_to_its_own_stop_reason () =
  let stop_of reason =
    Runtime_agent.For_testing.stop_reason_of_cooperative_yield ~turns_used:7 reason
  in
  (match stop_of Runtime_agent.Durable_stimulus_waiting with
   | Runtime_agent.Yielded_to_durable_stimulus { turns_used } ->
     check int "turns carried through" 7 turns_used
   | _ -> fail "stimulus yield lost its reason");
  match stop_of Runtime_agent.External_effect_waiting with
  | Runtime_agent.Yielded_to_external_effect { turns_used } ->
    check int "turns carried through" 7 turns_used
  | Runtime_agent.Yielded_to_durable_stimulus _ ->
    fail "external-effect yield collapsed into the stimulus reason"
  | _ -> fail "external-effect yield lost its reason"
;;

let test_the_two_are_distinguishable_in_the_durable_record () =
  (* finish_reason is what a later reader has. If the two share a string the
     distinction exists only at runtime and never reaches anyone. *)
  let wire stop = Receipt.stop_reason_to_string stop in
  let a = wire (Runtime_agent.Yielded_to_durable_stimulus { turns_used = 3 }) in
  let b = wire (Runtime_agent.Yielded_to_external_effect { turns_used = 3 }) in
  check bool "the two yields do not share a finish_reason" true (a <> b);
  check
    bool
    "the stimulus yield keeps its existing wire form"
    true
    (Astring.String.is_prefix ~affix:"yielded_to_durable_stimulus" a);
  check
    bool
    "the external-effect yield names what it waits on"
    true
    (Astring.String.is_prefix ~affix:"yielded_to_external_effect" b)
;;

let () =
  run
    "Keeper yield reason split"
    [ ( "production"
      , [ test_case
            "a deferred external effect is not a stimulus yield"
            `Quick
            test_deferred_external_effect_is_not_a_stimulus_yield
        ; test_case "an open effect still continues" `Quick test_open_effect_still_continues
        ] )
    ; ( "propagation"
      , [ test_case
            "each reason maps to its own stop reason"
            `Quick
            test_each_yield_reason_maps_to_its_own_stop_reason
        ; test_case
            "the two are distinguishable in the durable record"
            `Quick
            test_the_two_are_distinguishable_in_the_durable_record
        ] )
    ]
;;
