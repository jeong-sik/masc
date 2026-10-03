open Alcotest

module Composer = Masc_tui_composer
module Projection = Masc_tui_composer_projection
module Tui_types = Masc_tui_types

let keeper : Tui_types.keeper =
  { k_origin = Masc.Tui_decode.Persisted_keeper
  ; k_name = "analyst"
  ; k_paused = false
  ; k_identity = Ok { k_trace_id = "trace-current"; k_created_at = "2026-08-25T00:00:00Z"; k_updated_at = "2026-08-25T00:00:00Z" }
  ; k_activity = Some { k_current_task_id = None; k_total_turns = 0; k_total_tokens = 0; k_total_cost_usd = 0.0; k_last_turn_ts = ""; k_last_proactive_outcome = None }
  }

let state () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
  state.workspace_identity <- Tui_types.Workspace_identity_match;
  state

let target_testable =
  testable
    (fun formatter -> function
       | Composer.No_target -> Format.pp_print_string formatter "no_target"
       | Composer.Ready keeper_name ->
           Format.fprintf formatter "ready(%s)" keeper_name
       | Composer.Unreachable { keeper; reason } ->
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
       { keeper = "analyst"; reason = "keeper list unread" })
    composer.target

let test_focus_and_draft_are_projected_together () =
  let state = state () in
  state.keepers <- [ keeper ];
  let unfocused = Projection.of_state state in
  check focus_testable "initially unfocused" Composer.Unfocused
    unfocused.focus;
  check string "initially empty" "" unfocused.draft;
  state.composer_focused <- true;
  Buffer.add_string state.msg_input "draft for analyst";
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
    (Composer.Unreachable { keeper = "analyst";
      reason = "chat needs the server workspace for attachments and pasted files" })
    (Projection.of_state state).target;
  check bool "unobserved remote usage is not zero" true
    (Option.is_none (Tui_types.aggregate_keeper_stats state.keepers))

(* A slash command sent from the composer row runs as it does from the chat
   pane, but only the chat pane's footer said what the word being typed was:
   on every other surface "/tsk" read as a message until Enter. The row draws
   the same hint the footer draws, from the one function. *)
let test_the_composer_row_says_what_a_slash_word_is () =
  let plain text = Masc_tui_theme.strip_sgr text in
  let contains needle haystack =
    let n = String.length needle and h = String.length haystack in
    let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
    go 0
  in
  (match Masc_tui_render_prim.slash_hint_text ~restore:"" "/tsk" with
   | None -> fail "an unknown slash word draws a hint"
   | Some line ->
       check bool "and says it is no command" true (contains "is not a command" (plain line)));
  (match Masc_tui_render_prim.slash_hint_text ~restore:"" "/ta" with
   | None -> fail "a prefix draws its candidates"
   | Some line -> check bool "naming /task" true (contains "task" (plain line)));
  check (option string) "a message draws nothing" None
    (Masc_tui_render_prim.slash_hint_text ~restore:"" "hello")

let () =
  run "tui-composer-projection"
    [ ( "state projection"
      , [ test_case "no target" `Quick test_no_selected_keeper_has_no_target
        ; test_case "ready target" `Quick test_selected_keeper_is_ready
        ; test_case "unread roster" `Quick
            test_unread_roster_keeps_the_selected_name
        ; test_case "focus and draft" `Quick
            test_focus_and_draft_are_projected_together
        ; test_case "workspace loss withdraws queued message target" `Quick
            test_workspace_loss_withdraws_queued_message_target
        ; test_case "the composer row says what a slash word is" `Quick
            test_the_composer_row_says_what_a_slash_word_is

        ] )
    ]
