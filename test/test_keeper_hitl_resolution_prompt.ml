open Alcotest
open Masc

let channel = Keeper_continuation_channel.unrouted "resolution prompt test"

let contains ~needle text =
  String_util.contains_substring text needle
;;

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_hitl_resolution_prompt_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
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

let test_large_rejection_and_edit_are_artifact_backed () =
  let base_path = temp_dir () in
  let exact_tail =
    "RESOLUTION-BEGIN\n"
    ^ String.make (512 * 1024) 'x'
    ^ "\nRESOLUTION-END"
  in
  let message decision =
    let resolution : Keeper_event_queue.hitl_resolution =
      { approval_id = "approval-large-resolution"; decision; channel }
    in
    Keeper_unified_turn.user_message_with_hitl_resolution
      ~base_path
      ~user_message:"continue"
      (Some resolution)
  in
  List.iter
    (fun (label, rendered) ->
       check bool
         (label ^ " excludes the full exact tail")
         false
         (contains ~needle:"RESOLUTION-END" rendered);
       check bool
         (label ^ " carries a recoverable artifact reference")
         true
         (contains ~needle:"[masc:blob " rendered);
       check bool
         (label ^ " remains request-bounded")
         true
         (String.length rendered
          < Keeper_approval_queue.max_replay_evidence_bytes))
    [ "rejection", message (Hitl_rejected exact_tail)
    ; "edit", message (Hitl_edited (`Assoc [ "payload", `String exact_tail ]))
    ]
;;

let approved_message ~tool_name =
  Keeper_unified_turn.approved_resolution_message
    ~approval_id:"approval-approved"
    ~tool_name
    ~input:
      (`Assoc
         [ "path", `String "/repo/a.ml"
         ; "content", `String ("APPROVED-BEGIN\n" ^ String.make (512 * 1024) 'x' ^ "\nAPPROVED-END")
         ])
    ~user_message:"continue"
;;

let test_approved_fallback_is_bounded_and_never_resubmits_exact_input () =
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
         (contains ~needle:"Operator repair is required" message);
       check bool
         (tool_name ^ ": fallback remains bounded")
         true
         (String.length message < Keeper_approval_queue.max_replay_evidence_bytes))
    [ "filesystem_write"
    ; "tool_execute"
    ; "network_read"
    ; "connector_post"
    ; "keeper_voice_speak"
    ; ""
    ]
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
            "large rejection and edit are artifact-backed"
            `Quick
            test_large_rejection_and_edit_are_artifact_backed
        ] )
    ; ( "approved resolution"
      , [ test_case
            "approved fallback is bounded and never resubmits exact input"
            `Quick
            test_approved_fallback_is_bounded_and_never_resubmits_exact_input
        ] )
    ]
;;
