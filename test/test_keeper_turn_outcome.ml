(* RFC-0232 P2: producer-typed turn outcome.

   The reply payload's [turn_outcome] field is the only carrier of the
   checkpoint/visible/no-visible distinction; the legacy "Continuation
   checkpoint saved;" prefix sniff is deleted.  These tests pin:
   - the closed label codec (round-trip, unknown -> None),
   - the stop_reason -> outcome mapping (single mapping site),
   - response_text-aware result-surface classification,
   - payload decode policy: absent/unknown fails toward Visible_reply
     (the bitten failure mode, #20870, was silent non-persistence),
   - prefix deadness: checkpoint-shaped reply TEXT alone never
     classifies as a checkpoint. *)

open Alcotest

module TO = Masc.Keeper_turn_outcome
module Ops = Masc.Keeper_tool_surface_ops

let outcome : TO.t testable =
  testable
    (fun fmt t -> Format.pp_print_string fmt (TO.to_label t))
    TO.equal

let all = [ TO.Visible_reply; TO.Continuation_checkpoint; TO.No_visible_reply ]

let test_label_round_trip () =
  List.iter
    (fun t ->
      check (option outcome) "of_label (to_label t) = Some t"
        (Some t)
        (TO.of_label (TO.to_label t)))
    all

let test_unknown_label_is_none () =
  List.iter
    (fun label ->
      check (option outcome) label None (TO.of_label label))
    [ ""; "completed"; "checkpoint"; "Visible_reply"; "VISIBLE_REPLY" ]

let test_of_stop_reason () =
  check outcome "completed -> visible" TO.Visible_reply
    (TO.of_stop_reason Runtime_agent.Completed);
  check outcome "budget exhausted -> checkpoint" TO.Continuation_checkpoint
    (TO.of_stop_reason
       (Runtime_agent.TurnBudgetExhausted { turns_used = 3; limit = 3 }));
  check outcome "mutation boundary -> checkpoint" TO.Continuation_checkpoint
    (TO.of_stop_reason
       (Runtime_agent.MutationBoundaryReached
          { turns_used = 2; tool_name = Some "masc_add_task" }));
  check outcome "chat yield -> checkpoint" TO.Continuation_checkpoint
    (TO.of_stop_reason
       (Runtime_agent.Yielded_to_chat_waiting { turns_used = 2 }));
  check outcome "durable stimulus yield -> checkpoint" TO.Continuation_checkpoint
    (TO.of_stop_reason
       (Runtime_agent.Yielded_to_durable_stimulus { turns_used = 2 }))

let test_of_result_surface () =
  check outcome "completed with text -> visible" TO.Visible_reply
    (TO.of_result_surface ~response_text:"done" Runtime_agent.Completed);
  check outcome "completed with empty text -> no visible reply"
    TO.No_visible_reply
    (TO.of_result_surface ~response_text:"   " Runtime_agent.Completed);
  check outcome "budget exhausted -> checkpoint" TO.Continuation_checkpoint
    (TO.of_result_surface ~response_text:"done"
       (Runtime_agent.TurnBudgetExhausted { turns_used = 3; limit = 3 }))

let test_autonomous_yield_boundary_contract () =
  let module F = Masc.Keeper_agent_run.For_testing in
  let start_turn = 11570 in
  let immediate_chat : Masc.Keeper_agent_run.autonomous_yield_request =
    { reason = Masc.Keeper_agent_run.Chat_waiting
    ; boundary = Masc.Keeper_agent_run.Yield_immediately
    }
  in
  let reactive_chat : Masc.Keeper_agent_run.autonomous_yield_request =
    { reason = Masc.Keeper_agent_run.Chat_waiting
    ; boundary = Masc.Keeper_agent_run.Yield_after_current_turn
    }
  in
  let durable_stimulus : Masc.Keeper_agent_run.autonomous_yield_request =
    { reason = Masc.Keeper_agent_run.Durable_stimulus_waiting
    ; boundary = Masc.Keeper_agent_run.Yield_after_current_turn
    }
  in
  check bool "chat may yield before first provider dispatch" true
    (F.autonomous_yield_allowed_at_turn
       ~start_turn
       ~turn:start_turn
       immediate_chat);
  check bool "reactive chat cannot skip the leased stimulus" false
    (F.autonomous_yield_allowed_at_turn
       ~start_turn
       ~turn:start_turn
       reactive_chat);
  check bool "durable backlog cannot skip the leased stimulus" false
    (F.autonomous_yield_allowed_at_turn
       ~start_turn
       ~turn:start_turn
       durable_stimulus);
  check bool "durable backlog yields after one provider turn" true
    (F.autonomous_yield_allowed_at_turn
       ~start_turn
       ~turn:(start_turn + 1)
       durable_stimulus);
  match
    F.stop_reason_of_autonomous_yield
      ~turn:(start_turn + 1)
      durable_stimulus
  with
  | Runtime_agent.Yielded_to_durable_stimulus { turns_used } ->
    check int "typed durable yield carries the OAS turn" (start_turn + 1)
      turns_used
  | Runtime_agent.Completed
  | Runtime_agent.TurnBudgetExhausted _
  | Runtime_agent.MutationBoundaryReached _
  | Runtime_agent.Yielded_to_chat_waiting _ ->
    fail "durable request mapped to the wrong stop reason"

let payload fields = Some (`Assoc fields)

let test_payload_decode () =
  check outcome "no payload -> visible" TO.Visible_reply
    (TO.of_reply_payload None);
  check outcome "field absent -> visible" TO.Visible_reply
    (TO.of_reply_payload (payload [ ("reply", `String "hi") ]));
  check outcome "checkpoint label" TO.Continuation_checkpoint
    (TO.of_reply_payload
       (payload [ (TO.wire_key, `String "continuation_checkpoint") ]));
  check outcome "visible label" TO.Visible_reply
    (TO.of_reply_payload
       (payload [ (TO.wire_key, `String "visible_reply") ]));
  check outcome "no visible reply label" TO.No_visible_reply
    (TO.of_reply_payload
       (payload [ (TO.wire_key, `String "no_visible_reply") ]));
  check outcome "unknown label -> visible (report-and-persist)"
    TO.Visible_reply
    (TO.of_reply_payload (payload [ (TO.wire_key, `String "deferred") ]))

let checkpoint_text =
  "Continuation checkpoint saved; keeper remains scheduled for the next \
   cycle."

(* The reply text no longer participates in classification: a reply that
   *looks* like the synthetic notice but is declared visible stays
   visible, and the declared checkpoint suppresses regardless of text. *)
let test_prefix_is_dead () =
  check outcome "checkpoint-shaped text, declared visible"
    TO.Visible_reply
    (TO.of_reply_payload
       (payload
          [ ("reply", `String checkpoint_text);
            (TO.wire_key, `String "visible_reply")
          ]));
  check outcome "ordinary text, declared checkpoint"
    TO.Continuation_checkpoint
    (TO.of_reply_payload
       (payload
         [ ("reply", `String "all done");
           (TO.wire_key, `String "continuation_checkpoint")
          ]));
  check outcome "ordinary text, declared no visible reply"
    TO.No_visible_reply
    (TO.of_reply_payload
       (payload
          [ ("reply", `String "all done");
            (TO.wire_key, `String "no_visible_reply")
          ]))

let turn_ref_t : Ids.Turn_ref.t testable =
  testable
    (fun fmt t -> Format.pp_print_string fmt (Ids.Turn_ref.to_string t))
    Ids.Turn_ref.equal

(* RFC-0233 §7: the consumer-side decode of the turn join key the keeper
   minted into the reply payload.  Parse, don't repair — absent and
   malformed both decode to None; of_string splits on the LAST '#'. *)
let test_turn_ref_payload_decode () =
  check (option turn_ref_t) "no payload -> None" None
    (TO.turn_ref_of_reply_payload None);
  check (option turn_ref_t) "field absent -> None" None
    (TO.turn_ref_of_reply_payload (payload [ ("reply", `String "hi") ]));
  check (option turn_ref_t) "valid join key decodes"
    (Some
       (Ids.Turn_ref.make ~trace_id:"trace-1780648779957-00000"
          ~absolute_turn:4071))
    (TO.turn_ref_of_reply_payload
       (payload
          [ (TO.turn_ref_wire_key, `String "trace-1780648779957-00000#4071") ]));
  check (option turn_ref_t) "inner '#' splits on the last separator"
    (Some (Ids.Turn_ref.make ~trace_id:"weird#trace" ~absolute_turn:12))
    (TO.turn_ref_of_reply_payload
       (payload [ (TO.turn_ref_wire_key, `String "weird#trace#12") ]));
  check (option turn_ref_t) "no separator -> None (never repaired)" None
    (TO.turn_ref_of_reply_payload
       (payload [ (TO.turn_ref_wire_key, `String "no-separator") ]));
  check (option turn_ref_t) "non-int suffix -> None" None
    (TO.turn_ref_of_reply_payload
       (payload [ (TO.turn_ref_wire_key, `String "trace#abc") ]));
  check (option turn_ref_t) "non-string field -> None" None
    (TO.turn_ref_of_reply_payload (payload [ (TO.turn_ref_wire_key, `Int 5) ]))

let body fields = Yojson.Safe.to_string (`Assoc fields)

let test_direct_reply_visible_text () =
  check (option string) "declared checkpoint -> None" None
    (Ops.direct_reply_visible_text
       (body
          [ ("reply", `String checkpoint_text);
            ("turn_outcome", `String "continuation_checkpoint")
          ]));
  check (option string) "declared no visible reply -> None" None
    (Ops.direct_reply_visible_text
       (body
          [ ("reply", `String "all done");
            ("turn_outcome", `String "no_visible_reply")
          ]));
  check (option string) "checkpoint-shaped text without field -> visible"
    (Some checkpoint_text)
    (Ops.direct_reply_visible_text
       (body [ ("reply", `String checkpoint_text) ]));
  check (option string) "declared visible -> reply text" (Some "all done")
    (Ops.direct_reply_visible_text
       (body
          [ ("reply", `String "all done");
            ("turn_outcome", `String "visible_reply")
          ]));
  check (option string) "empty reply -> None" None
    (Ops.direct_reply_visible_text
       (body
          [ ("reply", `String "   ");
            ("turn_outcome", `String "visible_reply")
          ]))

let () =
  run "keeper_turn_outcome"
    [
      ( "codec",
        [
          test_case "label round trip" `Quick test_label_round_trip;
          test_case "unknown label is None" `Quick test_unknown_label_is_none;
        ] );
      ( "mapping",
        [
          test_case "of_stop_reason" `Quick test_of_stop_reason;
          test_case "of_result_surface" `Quick test_of_result_surface;
          test_case "autonomous yield boundary contract" `Quick
            test_autonomous_yield_boundary_contract;
        ] );
      ( "payload_decode",
        [
          test_case "decode policy" `Quick test_payload_decode;
          test_case "prefix is dead" `Quick test_prefix_is_dead;
          test_case "turn_ref decode (parse, don't repair)" `Quick
            test_turn_ref_payload_decode;
        ] );
      ( "direct_reply",
        [
          test_case "direct_reply_visible_text" `Quick
            test_direct_reply_visible_text;
        ] );
    ]
