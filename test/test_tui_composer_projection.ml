open Alcotest

module Composer = Masc_tui_composer
module Projection = Masc_tui_composer_projection
module Tui_types = Masc_tui_types

let keeper : Tui_types.keeper =
  { k_origin = Masc.Tui_decode.Persisted_keeper
  ; k_name = "analyst"
  ; k_paused = false
  ; k_identity = Ok { k_trace_id = "trace-current"; k_created_at = "2026-08-25T00:00:00Z"; k_updated_at = "2026-08-25T00:00:00Z" }
  ; k_activity = Some { k_current_task_id = None; k_total_turns = 0; k_total_tokens = 0; k_total_cost_usd = Keeper_cost_coverage.empty; k_last_turn_at = None; k_last_proactive_outcome = None }
  }

let state () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 () in
  state.workspace_identity <- Tui_types.Workspace_identity_match;
  state.local_keepers <- Tui_types.Local_workspace_read;
  state

let target_testable =
  testable
    (fun formatter -> function
       | Composer.No_target -> Format.pp_print_string formatter "no_target"
       | Composer.Ready keeper_name ->
           Format.fprintf formatter "ready(%s)" keeper_name
       | Composer.Unreachable { keeper; reason } ->
           let reason = match reason with
             | Composer.Workspace_unread -> "workspace unread"
             | Composer.Workspace_differs -> "workspace differs"
             | Composer.Keeper_unavailable text -> text in
           Format.fprintf formatter "unreachable(%s, %s)" keeper reason)
    ( = )

let focus_testable =
  testable
    (fun formatter -> function
       | Composer.Unfocused -> Format.pp_print_string formatter "unfocused"
       | Composer.Focused -> Format.pp_print_string formatter "focused")
    ( = )

let test_no_selected_keeper_has_no_target () =
  let composer = Projection.of_state (state ()) in
  check target_testable "no target" Composer.No_target composer.target

let test_selected_keeper_is_ready () =
  let state = state () in
  state.keepers <- [ keeper ];
  let composer = Projection.of_state state in
  check target_testable "selected roster member" (Composer.Ready "analyst")
    composer.target

let test_unread_roster_keeps_the_selected_name () =
  let state = state () in
  state.keepers <- [ keeper ];
  state.keepers_error <- Some "metadata read failed";
  let composer = Projection.of_state state in
  check target_testable "unread roster"
    (Composer.Unreachable
       { keeper = "analyst";
         reason = Composer.Keeper_unavailable "keeper list unread" })
    composer.target

let test_focus_and_draft_are_projected_together () =
  let state = state () in
  state.keepers <- [ keeper ];
  let unfocused = Projection.of_state state in
  check focus_testable "initially unfocused" Composer.Unfocused
    unfocused.focus;
  check string "initially empty" "" unfocused.draft;
  state.msg_target_keeper_name <- Some keeper.k_name;
  state.composer_focused <- true;
  Masc_tui_message_input.insert state.msg_input "draft for analyst";
  let focused = Projection.of_state state in
  check focus_testable "focused" Composer.Focused focused.focus;
  check string "draft" "draft for analyst" focused.draft

let test_workspace_loss_withdraws_queued_message_target () =
  let state = state () in
  state.keepers <- [ keeper ];
  state.workspace_identity <- Tui_types.Workspace_identity_unread;
  check bool "retained local metadata cannot authorize a queued send" false
    (Tui_types.keeper_available_for_new_message state keeper.k_name);
  state.workspace_identity <- Tui_types.Workspace_identity_mismatch
    { local_base_path = "/client"; server_base_path = "/server" };
  state.keepers <- [{ keeper with k_origin = Masc.Tui_decode.Remote_keeper; k_activity = None }];
  check target_testable "remote observation does not advertise file access"
    (Composer.Unreachable { keeper = "analyst"; reason = Composer.Workspace_differs })
    (Projection.of_state state).target;
  check bool "unobserved remote usage is not zero" true
    (Option.is_none (Tui_types.aggregate_keeper_stats state.keepers))

let test_idle_recipient_owns_its_draft () =
  let state = state () in
  let other = {keeper with k_name="reviewer"} in
  state.keepers <- [keeper];
  state.msg_target_keeper_name <- Some keeper.k_name;
  Masc_tui_message_input.insert state.msg_input "analyst 한글 초안";
  state.msg_attachments <- [{attachment_id="analyst-image";name="image.png";
    mime_type="image/png";size=1;data="AA=="}];
  Tui_types.save_message_draft state;
  state.keepers <- [other];
  let unsaved = Projection.of_state state in
  check target_testable "new selected recipient" (Composer.Ready other.k_name) unsaved.target;
  check string "no borrowed draft" "" unsaved.draft;
  check int "no borrowed image" 0 unsaved.staged_images;
  state.msg_target_keeper_name <- Some other.k_name;
  Tui_types.restore_message_draft state other.k_name;
  Masc_tui_message_input.insert state.msg_input "reviewer draft";
  state.keepers <- [keeper];
  let saved = Projection.of_state state in
  check string "selected recipient's saved draft" "analyst 한글 초안" saved.draft;
  check int "selected recipient's saved image" 1 saved.staged_images;
  check string "live input is retained" "reviewer draft"
    (Masc_tui_message_input.contents state.msg_input);
  check (option string) "preview does not retarget" (Some other.k_name)
    state.msg_target_keeper_name;
  state.keepers <- [keeper;other];
  state.keeper_cursor <- 0;
  state.composer_focused <- true;
  let focused = Projection.of_state state in
  check target_testable "focused owner stays bound" (Composer.Ready other.k_name) focused.target;
  check string "focused owner's input" "reviewer draft" focused.draft;
  check bool "send stays with focused owner" true
    (Projection.classify_key state Composer.send_key = Composer.Send other.k_name)

let () =
  run "tui-composer-projection"
    [ ( "state projection"
      , [ test_case "no target" `Quick test_no_selected_keeper_has_no_target
        ; test_case "ready target" `Quick test_selected_keeper_is_ready
        ; test_case "unread roster" `Quick
            test_unread_roster_keeps_the_selected_name
        ; test_case "focus and draft" `Quick
            test_focus_and_draft_are_projected_together
        ; test_case "idle recipient owns its draft" `Quick
            test_idle_recipient_owns_its_draft
        ; test_case "workspace loss withdraws queued message target" `Quick
            test_workspace_loss_withdraws_queued_message_target
        ;] )
    ]
