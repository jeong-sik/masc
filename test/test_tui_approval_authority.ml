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
  | Operator_row _ -> fail "Keeper receipt resolved to an operator row"

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
  | Keeper_tool_row _ -> fail "operator receipt resolved to a Keeper row"

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
          test_case "authority change is typed" `Quick
            test_authority_change_is_typed;
        ] );
    ]
