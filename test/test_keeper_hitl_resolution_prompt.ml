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
    Keeper_gate_replay.user_message_with_hitl_resolution
      ~base_path:"/tmp"
      ~user_message:"continue"
      (Some resolution)
    |> fun message -> message.Keeper_gate_replay.text
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
    Keeper_gate_replay.user_message_with_hitl_resolution
      ~base_path:"/tmp"
      ~user_message:"continue"
      (Some resolution)
    |> fun message -> message.Keeper_gate_replay.text
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

let test_large_rejection_and_edit_remain_exact () =
  let exact_tail =
    "RESOLUTION-BEGIN\n"
    ^ String.make (512 * 1024) 'x'
    ^ "\nRESOLUTION-END"
  in
  let message decision =
    let resolution : Keeper_event_queue.hitl_resolution =
      { approval_id = "approval-large-resolution"; decision; channel }
    in
    Keeper_gate_replay.user_message_with_hitl_resolution
      ~base_path:"/tmp"
      ~user_message:"continue"
      (Some resolution)
    |> fun message -> message.Keeper_gate_replay.text
  in
  List.iter
    (fun (label, rendered) ->
       check bool
         (label ^ " retains the full exact tail")
         true
         (contains ~needle:"RESOLUTION-END" rendered);
       check bool
         (label ^ " is not replaced with an opaque blob marker")
         false
         (contains ~needle:"[masc:blob " rendered))
    [ "rejection", message (Hitl_rejected exact_tail)
    ; "edit", message (Hitl_edited (`Assoc [ "payload", `String exact_tail ]))
    ]
;;

let approved_message ~tool_name =
  Keeper_gate_replay.approved_resolution_message
    ~approval_id:"approval-approved"
    ~tool_name
    ~input:
      (`Assoc
         [ "path", `String "/repo/a.ml"
         ; "content", `String ("APPROVED-BEGIN\n" ^ String.make (512 * 1024) 'x' ^ "\nAPPROVED-END")
         ])
    ~user_message:"continue"
;;

let test_replayable_approval_fallback_never_resubmits_exact_input () =
  List.iter
    (fun tool_name ->
       let message = approved_message ~tool_name in
       check bool
         (tool_name ^ ": exact input is absent")
         false
         (contains ~needle:"APPROVED-END" message);
       check bool
         (tool_name ^ ": fallback requires repair")
         true
         (contains ~needle:"Operator repair is required" message))
    [ "filesystem_write"; "tool_execute"; "network_read"; "connector_post" ]
;;

let test_large_nonreplayable_approval_retains_model_issued_path () =
  let message = approved_message ~tool_name:"keeper_voice_speak" in
  check bool
    "large exact input remains available"
    true
    (contains ~needle:"APPROVED-END" message);
  check bool
    "one-shot authorization remains explicit"
    true
    (contains ~needle:"one-shot authorization belongs" message);
  check bool
    "ordinary non-replayable approval does not invent repair"
    false
    (contains ~needle:"Operator repair is required" message)
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
        ; test_case
            "large rejection and edit remain exact"
            `Quick
            test_large_rejection_and_edit_remain_exact
        ] )
    ; ( "approved resolution"
      , [ test_case
            "replayable approval fallback never resubmits exact input"
            `Quick
            test_replayable_approval_fallback_never_resubmits_exact_input
        ; test_case
            "large non-replayable approval retains model-issued path"
            `Quick
            test_large_nonreplayable_approval_retains_model_issued_path
        ] )
    ]
;;
