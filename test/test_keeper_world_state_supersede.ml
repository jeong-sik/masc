(** World-state prompt provenance and supersession (#25193).

    The per-turn world-state block used to accumulate in the persisted
    conversation (a live checkpoint measured 180 near-identical copies =
    50.8% of its bytes). The fix stamps the injected message with typed
    metadata provenance and removes prior stamped copies by exact metadata
    equality before appending the new one. These tests pin the typed
    surface: stamping, detection (role-gated, metadata-only — content is
    never inspected), and metadata round-trip through the masc message
    serializer (which previously dropped metadata on read). *)

open Alcotest
module Support = Masc.Keeper_types_support

let world_state_source = Support.world_state_prompt_history_source

let tagged text =
  Support.tag_message_history_source ~source:world_state_source
    (Agent_sdk.Types.user_msg text)

let test_tagged_message_is_detected () =
  check bool "stamped user message is a world-state prompt" true
    (Support.message_is_world_state_prompt (tagged "## Current World State\n..."));
  check bool "plain user message is not" false
    (Support.message_is_world_state_prompt
       (Agent_sdk.Types.user_msg "operator says hi"))

let test_content_lookalike_is_not_detected () =
  (* Operator-authored text that merely looks like a world-state block must
     stay untouched: detection is metadata-only, never content inspection. *)
  check bool "content lookalike without the stamp is not detected" false
    (Support.message_is_world_state_prompt
       (Agent_sdk.Types.user_msg
          "## Current World State\n\n### Namespace State\n- Unclaimed tasks: 1"))

let test_non_user_roles_are_never_detected () =
  let assistant =
    Support.tag_message_history_source ~source:world_state_source
      (Agent_sdk.Types.make_message ~role:Agent_sdk.Types.Assistant
         [ Agent_sdk.Types.Text "reply" ])
  in
  check bool "stamped assistant message is role-gated out" false
    (Support.message_is_world_state_prompt assistant)

let test_noncanonical_source_is_not_detected () =
  let noncanonical =
    Support.tag_message_history_source ~source:" WORLD_STATE_PROMPT "
      (Agent_sdk.Types.user_msg "injected by an unknown producer")
  in
  check bool "only the canonical process-owned source is accepted" false
    (Support.message_is_world_state_prompt noncanonical)

let test_tag_replaces_previous_stamp () =
  let twice =
    Support.tag_message_history_source ~source:world_state_source
      (Support.tag_message_history_source ~source:"operator_chat"
         (Agent_sdk.Types.user_msg "x"))
  in
  let stamps =
    List.filter
      (fun (key, _) -> String.equal key Support.history_source_metadata_key)
      twice.Agent_sdk.Types.metadata
  in
  check int "exactly one provenance stamp survives re-tagging" 1
    (List.length stamps);
  check bool "the surviving stamp is the latest source" true
    (Support.message_is_world_state_prompt twice)

let test_masc_json_round_trip_preserves_stamp () =
  (* Counterfactual for the serializer fix: [message_of_json] used to
     hard-reset [metadata = []], so the stamp died on every masc-side
     re-serialization and supersession would silently stop. *)
  let round_tripped =
    tagged "## Current World State\n..."
    |> Masc.Keeper_context_runtime.message_to_json
    |> Masc.Keeper_context_runtime.message_of_json
  in
  check bool "stamp survives masc message json round-trip" true
    (Support.message_is_world_state_prompt round_tripped)

let test_supersede_filter_keeps_everything_else () =
  let conversation =
    [ tagged "## Current World State (turn 1)"
    ; Agent_sdk.Types.user_msg "operator question"
    ; Agent_sdk.Types.make_message ~role:Agent_sdk.Types.Assistant
        [ Agent_sdk.Types.Text "assistant answer" ]
    ; tagged "## Current World State (turn 2)"
    ]
  in
  let survivors =
    List.filter
      (fun message -> not (Support.message_is_world_state_prompt message))
      conversation
  in
  check int "both stamped copies removed, both real messages kept" 2
    (List.length survivors);
  check bool "operator message survives" true
    (List.exists
       (fun (m : Agent_sdk.Types.message) ->
         m.Agent_sdk.Types.content
         = [ Agent_sdk.Types.Text "operator question" ])
       survivors)

let () =
  run "Keeper world-state supersession"
    [
      ( "provenance",
        [
          test_case "stamped message is detected" `Quick
            test_tagged_message_is_detected;
          test_case "content lookalike is not detected" `Quick
            test_content_lookalike_is_not_detected;
          test_case "non-user roles are never detected" `Quick
            test_non_user_roles_are_never_detected;
          test_case "noncanonical source is not detected" `Quick
            test_noncanonical_source_is_not_detected;
          test_case "re-tagging keeps one stamp" `Quick
            test_tag_replaces_previous_stamp;
          test_case "masc json round-trip preserves the stamp" `Quick
            test_masc_json_round_trip_preserves_stamp;
          test_case "supersede filter keeps non-stamped messages" `Quick
            test_supersede_filter_keeps_everything_else;
        ] );
    ]
