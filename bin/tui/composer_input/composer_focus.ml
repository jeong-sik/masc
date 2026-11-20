module T = Masc_tui_types
module Composer = Masc_tui_composer
module Composer_projection = Masc_tui_composer_projection

let apply_take_focus (state : T.state) ~base_path ~mailbox keeper_name =
  (* Taking focus names the recipient for the draft, independently of
     later roster cursor movement. Focus before the retarget's drain. *)
  state.T.msg_return <- T.Keeper_chat_return_detail;
  state.T.composer_focused <- true;
  if state.T.msg_target_keeper_name <> Some keeper_name then begin
    Masc_tui_chat_input.Message_draft_recall.open_message_for_keeper state keeper_name ~drain_queue:(fun () ->
      Masc_tui_chat_dispatch.Queue_steer.drain_queued_message state ~base_path ~mailbox);
    (* Chat visits use the stored roster order; this surface may draw
       a sorted/grouped roster and keeps its selection by name. *)
    T.select_keeper_name state keeper_name
  end

let try_focus_from_key (state : T.state) ~base_path ~mailbox =
  if state.T.view = T.Overview || state.T.workspace_identity <> T.Workspace_identity_match
     || Option.is_some (T.browser_lane_on_screen state)
  then ()
  else
    match Composer_projection.classify_key state Composer.focus_key with
    | Composer.Take_focus keeper_name ->
        apply_take_focus state ~base_path ~mailbox keeper_name
    | Composer.Pass_to_surface
    | Composer.Release_focus
    | Composer.Send _
    | Composer.Start_listening _
    | Composer.Toggle_continuous _
    | Composer.Edit -> ()
