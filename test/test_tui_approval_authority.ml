open Alcotest
open Masc_tui_types

module Authority = Masc_tui_approval_authority
module Chat_frame = Masc_tui_chat_row_actions
module Presented = Masc_tui_presented

let operator token =
  Masc_tui_approvals_model.Operator_row
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

let keeper ?(approval_id = "approval-call") keeper_name tool_call_id =
  Masc_tui_approvals_model.Keeper_tool_row
    { kta_keeper = keeper_name;
      kta_tool_call_id = tool_call_id;
      kta_approval_id = approval_id;
      kta_tool = "Execute";
      kta_args = "{}";
      kta_question = "run?";
      kta_because = None;
      kta_asked_at = 0.;
      kta_timeout_sec = 30.;
    }

let gate approval_id =
  Masc_tui_approvals_model.Gate_row
    { Tui_decode.gp_id = approval_id;
      gp_keeper = "gate-fixture";
      gp_operation = "identity_call";
      gp_display_tool = "atlassian \xc2\xb7 addCommentToJiraIssue";
      gp_input_preview = Some "{\"provider_id\":\"atlassian\"}";
      gp_input_rows = Tui_decode.Flattened None;
      gp_execution_cwd = None;
      gp_execution_sandbox = None;
      gp_waiting_s = Some 12.;
      gp_phase = Tui_decode.Gate_human_required;
      gp_judge_advice = None;
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
  | Masc_tui_approvals_model.Keeper_tool_row held ->
      check string "keeper" "keeper-a" held.kta_keeper;
      check string "call" "call-a" held.kta_tool_call_id
  | Masc_tui_approvals_model.Operator_row _ | Masc_tui_approvals_model.Gate_row _ ->
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
  | Masc_tui_approvals_model.Operator_row approval -> check string "token" "token-a" approval.ap_token
  | Masc_tui_approvals_model.Keeper_tool_row _ | Masc_tui_approvals_model.Gate_row _ ->
      fail "operator receipt resolved to another row kind"

let test_replacement_waiter_has_no_presented_authority () =
  let shown = keeper ~approval_id:"waiter-a" "keeper-a" "call-a" in
  let replacement = keeper ~approval_id:"waiter-b" "keeper-a" "call-a" in
  check bool "same keeper and call cannot transfer a decision" true
    (Option.is_none
       (Authority.resolve ~presented:(Some shown) ~current:[ replacement ] Confirm));
  check bool "a new waiter requires a new accepted frame" true
    (Authority.authority_changed ~presented:(Some shown)
       ~candidate:(Some replacement));
  match
    Authority.resolve ~presented:(Some replacement) ~current:[ replacement ] Deny
    |> effect_row
  with
  | Masc_tui_approvals_model.Keeper_tool_row held ->
      check string "the replacement can answer itself" "waiter-b" held.kta_approval_id
  | Masc_tui_approvals_model.Operator_row _ | Masc_tui_approvals_model.Gate_row _ ->
      fail "replacement resolved to another row kind"

let held keeper_name tool_call_id approval_id =
  match keeper ~approval_id keeper_name tool_call_id with
  | Masc_tui_approvals_model.Keeper_tool_row row -> row
  | Masc_tui_approvals_model.Operator_row _ | Masc_tui_approvals_model.Gate_row _ ->
      fail "expected a Keeper row"

let pending_identities rows =
  List.map
    (fun (row : Tui_decode.keeper_tool_approval) ->
      row.kta_keeper ^ "/" ^ row.kta_tool_call_id ^ "/" ^ row.kta_approval_id)
    rows

let test_confirmed_answer_removes_only_its_waiter () =
  let pending =
    [ held "keeper-a" "call-a" "waiter-a"
    ; held "keeper-a" "call-a" "waiter-b"
    ; held "keeper-b" "call-a" "waiter-a"
    ; held "keeper-a" "call-b" "waiter-a"
    ]
  in
  List.iter
    (fun result ->
      let remaining =
        Authority.after_answer ~keeper_name:"keeper-a" ~tool_call_id:"call-a"
          ~approval_id:"waiter-a" ~result pending
      in
      check (list string) "the three identity fields scope cleanup"
        [ "keeper-a/call-a/waiter-b"; "keeper-b/call-a/waiter-a"
        ; "keeper-a/call-b/waiter-a" ]
        (pending_identities remaining))
    [ Ok { Masc_tui_http.settled = true; remembered = false }
    ; Ok { Masc_tui_http.settled = false; remembered = true }
    ]

let test_failed_or_stale_answer_preserves_pending_waiters () =
  let pending =
    [ held "keeper-a" "call-a" "waiter-a"
    ; held "keeper-a" "call-a" "waiter-b"
    ]
  in
  List.iter
    (fun result ->
      check (list string) "an unconfirmed answer removes nothing"
        (pending_identities pending)
        (Authority.after_answer ~keeper_name:"keeper-a" ~tool_call_id:"call-a"
           ~approval_id:"waiter-a" ~result pending
         |> pending_identities))
    [ Error "request failed"
    ; Ok { Masc_tui_http.settled = false; remembered = false }
    ]

let chat_approval ~scope approval_id : _ Chat_frame.approval =
  { scope; keeper = "keeper-a"; request_id = "request-a"
  ; tool_call_id = "call-a"; approval_id }

let test_chat_decision_requires_the_accepted_prompt () =
  let scope = Workspace_authority 1, ref () in
  let shown = chat_approval ~scope "waiter-a" in
  let replacement = chat_approval ~scope "waiter-b" in
  check bool "a candidate B is not the accepted A" true
    (Option.is_none
       (Authority.resolve_chat ~presented:(Some shown) ~current:(Some replacement)));
  check bool "an unpresented or failed frame grants no authority" true
    (Option.is_none
       (Authority.resolve_chat ~presented:None ~current:(Some replacement)));
  check bool "a removed prompt grants no authority" true
    (Option.is_none (Authority.resolve_chat ~presented:(Some shown) ~current:None));
  match Authority.resolve_chat ~presented:(Some replacement) ~current:(Some replacement) with
  | Some approved -> check string "accepted B authorizes B" "waiter-b" approved.approval_id
  | None -> fail "the accepted current prompt was refused"

let test_chat_decision_keeps_all_source_identities () =
  let reading = ref () in
  let shown = chat_approval ~scope:(Workspace_authority 1, reading) "waiter-a" in
  List.iter
    (fun current ->
      check bool "a different source cannot reuse a shown approval" true
        (Option.is_none
           (Authority.resolve_chat ~presented:(Some shown) ~current:(Some current))))
    [ { shown with scope = Workspace_authority 2, reading }
    ; { shown with scope = Workspace_authority 1, ref () }
    ; { shown with keeper = "keeper-b" }
    ; { shown with request_id = "request-b" }
    ; { shown with tool_call_id = "call-b" }
    ]

let test_approval_transition_quarantines_queued_input () =
  let scope = Workspace_authority 1, ref () in
  let chat_a = Some (chat_approval ~scope "waiter-a") in
  let chat_b = Some (chat_approval ~scope "waiter-b") in
  let chat_changed =
    not (Option.equal (Chat_frame.same_approval ~same_scope:same_acting_pane_scope)
           chat_a chat_b)
  in
  let surface_changed =
    Authority.authority_changed
      ~presented:(Some (keeper ~approval_id:"waiter-a" "keeper-a" "call-a"))
      ~candidate:(Some (keeper ~approval_id:"waiter-b" "keeper-a" "call-a"))
  in
  List.iter
    (fun changed ->
      let initial =
        Presented.initial ~approval:chat_a ~presses:() ~panes:() ~reader:None
          ~panel_owner:None
      in
      let frame =
        Presented.presented initial ~approval:chat_b ~presses:() ~panes:()
          ~reader:None ~panel_owner:None ~owner_changed:changed ~input_pending:true
      in
      (match frame.barrier with
       | Presented.Held _ -> ()
       | Presented.Open -> fail "queued input crossed an approval ownership change");
      let rejected = Presented.reject frame ~paste:false in
      let drained = Presented.after_input rejected ~input_pending:false in
      (match drained.barrier with
       | Presented.Open -> ()
       | Presented.Held _ -> fail "drained stale input left the frame quarantined");
      check bool "only the subsequently accepted current prompt is actionable" true
        (Option.is_some
           (Authority.resolve_chat ~presented:drained.approval ~current:chat_b)))
    [ chat_changed; surface_changed ];
  check bool "no accepted frame rejects an action" true
    (Presented.decide_unpresented_input ~frame_presented:false
       ~external_surface:false Presented.Action = Presented.Reject_action)

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
  | Masc_tui_approvals_model.Gate_row pending -> check string "approval" "appr-a" pending.Tui_decode.gp_id
  | Masc_tui_approvals_model.Keeper_tool_row _ | Masc_tui_approvals_model.Operator_row _ ->
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
          test_case "replacement waiter needs its own authority" `Quick
            test_replacement_waiter_has_no_presented_authority;
          test_case "confirmed answer removes only its waiter" `Quick
            test_confirmed_answer_removes_only_its_waiter;
          test_case "failed and stale answers retain waiters" `Quick
            test_failed_or_stale_answer_preserves_pending_waiters;
          test_case "chat decisions need the accepted prompt" `Quick
            test_chat_decision_requires_the_accepted_prompt;
          test_case "chat decisions retain all source identities" `Quick
            test_chat_decision_keeps_all_source_identities;
          test_case "approval changes quarantine queued input" `Quick
            test_approval_transition_quarantines_queued_input;
          test_case "operator token is identity" `Quick
            test_operator_token_is_the_identity;
          test_case "gate approval id is identity" `Quick
            test_gate_approval_id_is_the_identity;
          test_case "authority change is typed" `Quick
            test_authority_change_is_typed;
        ] );
    ]
