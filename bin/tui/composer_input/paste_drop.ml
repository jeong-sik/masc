module T = Masc_tui_types
module Keeper_chat = Masc_tui_keeper_chat_projection

(* Where a paste lands.

   The composer row and the chat pane hold one draft between them
   ([msg_input]), so a paste has one destination whatever surface is on
   screen. When the row is idle the paste takes focus for it, through the same
   path the focus key takes: focus is what names the recipient, and text
   dropped into a draft whose keeper was never resolved is a message with
   nowhere to go.

   The text is sanitized the way every other text this process draws is.
   Typed keys reach the draft only through [is_printable_utf8_scalar], so a
   control byte cannot get in one keystroke at a time; a paste is the one way
   a terminal escape could arrive, and it arrives as spaces instead. *)
(* A paste filename pairs the wall-clock minute with a random suffix. The
   publication step refuses to replace an existing name if that suffix collides. *)
let spill_stamp () = Masc_tui_value.Instant.file_stamp (Unix.gettimeofday ())

let spill_nonce () =
  (* Keep the existing short filename; [write_file] refuses any collision. *)
  Random_id.hex ~bytes:4

(* A file dropped on the composer arrives as a paste. An image is meant to be
   looked at, so it is staged rather than spelled out; every other file keeps
   its path in the draft, which is how an operator names a file they want read.

   Shares handle_paste's guard: a staged image with no keeper to send it to is
   the same silence as a paste with nowhere to go. *)
let attach_dropped_image ?(protect_recovered = false) (state : T.state) ~base_path ~mailbox
    (attachment : Keeper_chat.attachment) =
  let in_chat = state.T.view = T.Keepers T.Keeper_message in
  if not (in_chat || state.T.composer_focused) then
    Composer_focus.try_focus_from_key state ~base_path ~mailbox;
  if not (in_chat || state.T.composer_focused) then
    Masc_tui_loader.report_action state "error"
      (Printf.sprintf "Dropped %s with no Keeper to send it to"
         attachment.Keeper_chat.name)
  else begin
    if protect_recovered then Masc_tui_chat_input.Paste_spill.protect_recovered_paste_for_current_keeper state;
    (Masc_tui_message_input.invalidate_revision state.T.msg_input; state.T.msg_attachments <- state.T.msg_attachments @ [ attachment ]);
    Masc_tui_chat_input.Message_draft_recall.note_attachment_staged state;
    Masc_tui_loader.report_action state "system"
      (Printf.sprintf "Attached %s (%s, %d bytes) · %d staged for the next message"
         attachment.Keeper_chat.name
         attachment.Keeper_chat.mime_type
         attachment.Keeper_chat.size
         (List.length state.T.msg_attachments))
  end

let handle_paste ?(protect_recovered = false) (state : T.state) ~base_path ~mailbox
    ~(paste : Masc_tui_paste.t) =
  if state.T.workspace_identity <> T.Workspace_identity_match
  then ()
  else
  let in_chat = state.T.view = T.Keepers T.Keeper_message in
  if not (in_chat || state.T.composer_focused) then
    Composer_focus.try_focus_from_key state ~base_path ~mailbox;
  if not (in_chat || state.T.composer_focused) then
    (* No keeper is selected, or the one that is cannot be written to. A paste
       that says nothing and goes nowhere is the silence this surface keeps
       being caught by. *)
    Masc_tui_loader.report_action state "error"
      (let count = String.length paste.Masc_tui_paste.text in
       if state.T.ui_language = T.Lang_ko then
         Printf.sprintf "보낼 키퍼가 선택되지 않은 상태에서 %d바이트가 붙여넣기되었습니다" count
       else
         Printf.sprintf "Pasted %s with no Keeper to send %s to"
           (Masc_tui_message_layout.count_noun count "character")
           (if count = 1 then "it" else "them"))
  else begin
    Masc_tui_chat_input.Message_draft_recall.forget_recall state;
    let text =
      Keeper_chat.terminal_safe_text ~preserve_newlines:true
        paste.Masc_tui_paste.text
    in
    if protect_recovered
       && (String.trim (Masc_tui_message_input.contents state.T.msg_input ^ text) <> ""
           || state.T.msg_attachments <> [] || state.T.msg_references <> [])
    then
      Masc_tui_chat_input.Paste_spill.protect_recovered_paste_for_current_keeper state;
    (match state.T.msg_spill with
     | Some _ ->
         (* The draft still owns its first spill. Keep later paste bytes in
            the editable input rather than replacing that original source. *)
         Masc_tui_message_input.insert state.T.msg_input text
     | None ->
       match
         Masc_tui_paste_spill.of_paste ~now_iso:(spill_stamp ())
           ~nonce:(spill_nonce ()) text
       with
       | None -> Masc_tui_message_input.insert state.T.msg_input text
       | Some spill ->
         (* One line in the draft, the text kept beside it. The composer is
            five rows: a four-hundred-line paste in it is a draft the operator
            cannot read, and a draft they cannot read is a message they cannot
            check before sending. The text goes back in on the way out, so
            what the keeper receives is what was pasted. *)
         let owner = Masc_tui_message_input.insert_owned state.T.msg_input
             (Masc_tui_paste_spill.draft_line spill) in
         state.T.msg_spill <- Some { T.msp_paste = spill; msp_owner = owner });
    if paste.Masc_tui_paste.dropped > 0 then
      Masc_tui_loader.report_action state "error"
        (Printf.sprintf "Paste kept the first %s bytes; %s were dropped"
           (Masc_tui_value.Count.grouped Masc_tui_paste.max_bytes)
           (Masc_tui_value.Count.more ~ko:false paste.Masc_tui_paste.dropped))
  end
