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

(* RFC-0356: the runtime replays an approved filesystem_write / tool_execute
   during tool-bundle setup, which runs after this message is composed. Telling
   the Keeper to spend a grant the runtime is about to spend sends it after an
   authorization that will be gone, and the repeat call opens a new Gate
   request. The instruction has to follow the same dispatch the replay uses. *)
let approved_message ~tool_name =
  Keeper_unified_turn.approved_resolution_message
    ~approval_id:"approval-approved"
    ~tool_name
    ~input:(`Assoc [ "path", `String "/repo/a.ml"; "content", `String "let a = 1\n" ])
    ~user_message:"continue"
;;

let test_replayed_operation_is_not_asked_for_again () =
  List.iter
    (fun tool_name ->
       let message = approved_message ~tool_name in
       check bool
         (tool_name ^ ": the exact input still reaches the model")
         true
         (contains ~needle:"\"path\": \"/repo/a.ml\"" message);
       check bool
         (tool_name ^ ": the runtime is named as the spender")
         true
         (contains ~needle:"runtime spends this one-shot authorization itself" message);
       check bool
         (tool_name ^ ": the pre-replay instruction to emit it is gone")
         false
         (contains ~needle:"authorization belongs to this exact operation" message))
    [ "filesystem_write"; "tool_execute" ]
;;

(* An operation the replay does not dispatch to still depends on the Keeper
   emitting the call, so the original instruction must survive there. *)
let test_unreplayed_operation_still_owns_its_grant () =
  let message = approved_message ~tool_name:"network_read" in
  check bool
    "the Keeper is still told the grant is its to spend"
    true
    (contains ~needle:"authorization belongs to this exact operation" message);
  check bool
    "and is not told the runtime already spent it"
    false
    (contains ~needle:"runtime spends this one-shot authorization itself" message)
;;

(* The branch is the replay dispatch itself, not a copy of its operation list:
   a future replayable operation must not need this renderer edited too. *)
let test_message_follows_replay_dispatch () =
  List.iter
    (fun tool_name ->
       let replayed =
         Option.is_some (Keeper_gate_replay.replayable_of_operation tool_name)
       in
       check bool
         (tool_name ^ ": message agrees with replay dispatch")
         replayed
         (contains
            ~needle:"runtime spends this one-shot authorization itself"
            (approved_message ~tool_name)))
    [ "filesystem_write"; "tool_execute"; "network_read"; "keeper_board_post"; "" ]
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
    ; ( "approved resolution"
      , [ test_case
            "replayed operation is not asked for again"
            `Quick
            test_replayed_operation_is_not_asked_for_again
        ; test_case
            "unreplayed operation still owns its grant"
            `Quick
            test_unreplayed_operation_still_owns_its_grant
        ; test_case
            "message follows replay dispatch"
            `Quick
            test_message_follows_replay_dispatch
        ] )
    ]
;;
