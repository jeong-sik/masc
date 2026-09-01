open Alcotest
open Masc_tui_types

module Authority = Masc_tui_approval_authority

let operator token =
  Operator_row
    { ap_token = token;
      ap_trace_id = "trace-" ^ token;
      ap_actor = "masc-tui";
      ap_action_type = "keeper_probe";
      ap_target_type = "keeper";
      ap_target_id = Some token;
      ap_payload = `Assoc [];
      ap_delegated_tool = "masc_keeper_status";
      ap_created_at = "2026-08-27T00:00:00Z";
      ap_expires_at = None;
      ap_summary = "probe " ^ token;
    }

let keeper keeper_name tool_call_id =
  Keeper_tool_row
    { kta_keeper = keeper_name;
      kta_tool_call_id = tool_call_id;
      kta_tool = "Execute";
      kta_args = "{}";
      kta_question = "run?";
      kta_because = None;
      kta_asked_at = 0.;
      kta_timeout_sec = 30.;
    }

let gate approval_id =
  Gate_row
    { Tui_decode.gp_id = approval_id;
      gp_keeper = "gate-fixture";
      gp_operation = "identity_call";
      gp_display_tool = "atlassian \xc2\xb7 addCommentToJiraIssue";
      gp_input_preview = Some "{\"provider_id\":\"atlassian\"}";
      gp_execution_cwd = None;
      gp_execution_sandbox = None;
      gp_waiting_s = Some 12.;
      gp_phase = Tui_decode.Gate_human_required;
      gp_auto_judge_detail = None;
      gp_retry_request = None;
    }

let effect_row = function
  | Some resolved -> resolved.Authority.row
  | None -> fail "expected a resolved approval effect"

let test_removed_presented_row_has_no_effect () =
  let shown = operator "operator-a" in
  let unseen = keeper "keeper-b" "call-b" in
  check bool "A cannot turn into B" true
    (Option.is_none
       (Authority.resolve ~presented:(Some shown) ~current:[ unseen ] Confirm))

let test_reordered_presented_row_keeps_exact_identity () =
  let shown = keeper "keeper-a" "call-a" in
  let unseen = keeper "keeper-b" "call-b" in
  let row =
    Authority.resolve ~presented:(Some shown) ~current:[ unseen; shown ] Deny
    |> effect_row
  in
  match row with
  | Keeper_tool_row held ->
      check string "keeper" "keeper-a" held.kta_keeper;
      check string "call" "call-a" held.kta_tool_call_id
  | Operator_row _ | Gate_row _ ->
      fail "Keeper receipt resolved to another row kind"

let test_operator_token_is_the_identity () =
  let shown = operator "token-a" in
  let same_token_new_projection = operator "token-a" in
  let row =
    Authority.resolve ~presented:(Some shown)
      ~current:[ operator "token-b"; same_token_new_projection ] Confirm
    |> effect_row
  in
  match row with
  | Operator_row approval -> check string "token" "token-a" approval.ap_token
  | Keeper_tool_row _ | Gate_row _ ->
      fail "operator receipt resolved to another row kind"

let test_gate_approval_id_is_the_identity () =
  (* A durable Gate row is the same ask across refreshes exactly when its
     approval id matches; a fresh listing must not turn a decision onto a
     different pending approval. *)
  let shown = gate "appr-a" in
  let row =
    Authority.resolve ~presented:(Some shown)
      ~current:[ gate "appr-b"; gate "appr-a" ]
      Confirm
    |> effect_row
  in
  (match row with
  | Gate_row pending -> check string "approval" "appr-a" pending.Tui_decode.gp_id
  | Keeper_tool_row _ | Operator_row _ ->
      fail "gate receipt resolved to another row kind");
  check bool "a different approval is a different authority" true
    (Authority.authority_changed ~presented:(Some (gate "appr-a"))
       ~candidate:(Some (gate "appr-b")));
  check bool "a gate row is never an operator row" true
    (Authority.authority_changed ~presented:(Some (gate "appr-a"))
       ~candidate:(Some (operator "appr-a")))

let test_authority_change_is_typed () =
  let operator_a = operator "token-a" in
  check bool "same operator token" false
    (Authority.authority_changed ~presented:(Some operator_a)
       ~candidate:(Some (operator "token-a")));
  check bool "different operator token" true
    (Authority.authority_changed ~presented:(Some operator_a)
       ~candidate:(Some (operator "token-b")));
  check bool "different Keeper call" true
    (Authority.authority_changed
       ~presented:(Some (keeper "keeper-a" "call-a"))
       ~candidate:(Some (keeper "keeper-a" "call-b")));
  check bool "modal clears authority" true
    (Authority.authority_changed ~presented:(Some operator_a) ~candidate:None)

let () =
  run "tui-approval-authority"
    [ ( "authority",
        [ test_case "removed row has no effect" `Quick
            test_removed_presented_row_has_no_effect;
          test_case "reorder keeps exact row" `Quick
            test_reordered_presented_row_keeps_exact_identity;
          test_case "operator token is identity" `Quick
            test_operator_token_is_the_identity;
          test_case "gate approval id is identity" `Quick
            test_gate_approval_id_is_the_identity;
          test_case "authority change is typed" `Quick
            test_authority_change_is_typed;
        ] );
    ]
