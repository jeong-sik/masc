open Alcotest
open Masc

let channel = Keeper_continuation_channel.unrouted "resolution prompt test"

let contains ~needle text =
  String_util.contains_substring text needle
;;

let test_rejection_rationale_is_actionable_without_grant () =
  let resolution : Keeper_event_queue.hitl_resolution =
    { approval_id = "approval-rejected"
    ; decision = Hitl_rejected "Use the project-scoped destination."
    ; channel
    }
  in
  let message =
    Keeper_unified_turn.user_message_with_hitl_resolution
      ~base_path:"/tmp"
      ~user_message:"continue"
      (Some resolution)
  in
  check bool
    "rationale reaches model input"
    true
    (contains ~needle:"Use the project-scoped destination." message);
  check bool
    "rejection explicitly grants nothing"
    true
    (contains ~needle:"grants no authorization" message);
  check bool
    "rejection cannot mint a cycle grant"
    true
    (Option.is_none (Keeper_gate.cycle_grant_of_resolution resolution))
;;

let test_edited_input_is_durable_and_not_a_grant () =
  let edited_input =
    `Assoc [ "destination", `String "project"; "payload", `Int 7 ]
  in
  let resolution : Keeper_event_queue.hitl_resolution =
    { approval_id = "approval-edited"
    ; decision = Hitl_edited edited_input
    ; channel
    }
  in
  let stimulus : Keeper_event_queue.stimulus =
    { post_id = Keeper_event_queue.hitl_resolution_post_id resolution
    ; urgency = Immediate
    ; arrived_at = 1.0
    ; payload = Hitl_resolved resolution
    }
  in
  let restored =
    Keeper_event_queue.stimulus_to_yojson stimulus
    |> Keeper_event_queue.stimulus_of_yojson
  in
  (match restored with
   | Ok { payload = Hitl_resolved { decision = Hitl_edited actual; _ }; _ } ->
     check bool "edited JSON survives durable codec" true (Yojson.Safe.equal edited_input actual)
   | Ok _ -> fail "restored stimulus lost edited resolution"
   | Error error -> fail ("edited resolution codec failed: " ^ error));
  let message =
    Keeper_unified_turn.user_message_with_hitl_resolution
      ~base_path:"/tmp"
      ~user_message:"continue"
      (Some resolution)
  in
  check bool
    "edited JSON reaches model input"
    true
    (contains ~needle:"\"destination\": \"project\"" message);
  check bool
    "edit explicitly grants nothing"
    true
    (contains ~needle:"grants no authorization" message);
  check bool
    "edit cannot mint a cycle grant"
    true
    (Option.is_none (Keeper_gate.cycle_grant_of_resolution resolution))
;;

let () =
  run
    "keeper HITL resolution prompt"
    [ ( "resolution"
      , [ test_case
            "rejection rationale is actionable"
            `Quick
            test_rejection_rationale_is_actionable_without_grant
        ; test_case
            "edited input is durable and not authorization"
            `Quick
            test_edited_input_is_durable_and_not_a_grant
        ] )
    ]
;;
