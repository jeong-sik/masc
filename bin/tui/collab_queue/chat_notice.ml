module T = Masc_tui_types
module Keeper_chat = Masc_tui_keeper_chat_projection
module Terminal_text = Masc_tui_ansi.Terminal_text

type notice_kind =
  | Notice_reply
  | Notice_failure

let append_chat_local_message (state : T.state) ~keeper text =
  let role = T.Message_local in
  state.T.msg_history <-
    state.T.msg_history
    @ [ {
          T.me_role = role;
          me_identity =
            T.Session_row
              { request_id = ""
              ; turn_phase = T.chat_turn_phase_of_role role
              ; operation_seq = Masc_tui_chat_dispatch.Chat_watching.next_chat_operation_seq state ""
              };
          me_turn_phase = T.chat_turn_phase_of_role role;
          me_turn_sequence = None;
          me_operation_seq = Masc_tui_chat_dispatch.Chat_watching.next_chat_operation_seq state "";
          me_text = Keeper_chat.terminal_safe_text ~preserve_newlines:true text;
          me_images = [];
          me_media = [];
          me_memory_summary = None;
          me_memory_pass = Masc_tui_message_layout.No_pass;
          me_journal = [];
          me_gate = None;
          me_submitted_at = None;
          me_tool_block = None;
          me_skill_block = [];
          me_keeper_name = keeper;
          me_request_id = "";
          me_execution_source = None;
          me_at = Unix.gettimeofday ();
        } ]

let chat_notice state ~keeper_name ~kind text =
  match kind, keeper_name with
  | Notice_failure, (Some _ | None) ->
      Masc_tui_loader.report_action state "error" (Terminal_text.single_line text)
  | Notice_reply, None ->
      Masc_tui_loader.report_action state "system" (Terminal_text.single_line text)
  | Notice_reply, Some keeper ->
      append_chat_local_message state ~keeper text
