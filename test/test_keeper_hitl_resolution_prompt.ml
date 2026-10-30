open Alcotest
open Masc

(* The Gate replay/resolution wording lives in managed prompt templates
   under the config/prompts/keeper.gate_replay prefix; without a loaded
   registry the
   execution path falls back to bare data and the wording assertions below
   see nothing. Same repo-root idiom test_tool_task_coverage uses — that
   executable passes inside the CI sandbox, so the mechanism is CI-proven. *)
let () =
  Prompt_defaults.init ()
;;

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

let test_large_rejection_remains_exact () =
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
  let rendered = message (Hitl_rejected exact_tail) in
  check bool
    "rejection retains the full exact tail"
    true
    (contains ~needle:"RESOLUTION-END" rendered);
  check bool
    "rejection is not replaced with an opaque blob marker"
    false
    (contains ~needle:"[masc:blob " rendered)
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
    [ "filesystem_write"
    ; "tool_execute"
    ; "network_read"
    ; "connector_post"
    ; "identity_call"
    ; "keeper_voice_speak"
    ]
;;

let test_large_nonreplayable_approval_retains_model_issued_path () =
  let message = approved_message ~tool_name:"unreplayed_operation" in
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
let test_speak_replays_while_listen_never_reaches_the_gate () =
  check bool
    "approved speak is spent by host replay"
    true
    (Option.is_some
       (Keeper_gate_replay.replayable_of_operation "keeper_voice_speak"));
  check bool
    "listen is not a replayable operation"
    true
    (Option.is_none
       (Keeper_gate_replay.replayable_of_operation "keeper_voice_listen"))
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
            "large rejection remains exact"
            `Quick
            test_large_rejection_remains_exact
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
    ; ( "voice leaves"
      , [ test_case
            "speak replays while listen never reaches the Gate"
            `Quick
            test_speak_replays_while_listen_never_reaches_the_gate
        ] )
    ]
;;
