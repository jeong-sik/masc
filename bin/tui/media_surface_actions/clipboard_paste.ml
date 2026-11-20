module T = Masc_tui_types
module Chat_notice = Masc_tui_collab_queue.Chat_notice
module Clipboard = Masc_tui_clipboard
module Attachment = Masc_tui_attachment
module Draft_recall = Masc_tui_chat_input.Message_draft_recall
module Message_input = Masc_tui_message_input
module Chat_proj = Masc_tui_keeper_chat_projection

(* Ctrl-V. A terminal never delivers a pasted image: bracketed paste carries
   text, and a clipboard holding a screenshot has no text form to send. So the
   bytes are fetched from the clipboard itself and staged the way a dropped
   file is -- same size limit, same media-type sniff, same staging list.

   The answer goes to the chat pane rather than the event log because that is
   the surface the operator is looking at when they press this key; with no
   keeper selected [chat_notice] falls back to the log on its own.

   The draft gets a marker where the image went. Without one, a staged image
   and a keystroke the terminal ate look identical from the composer, and the
   operator would learn which it was only after the turn came back. *)
let paste_clipboard_image (state : T.state) =
  let notice = Chat_notice.chat_notice state ~keeper_name:state.T.msg_target_keeper_name in
  match Clipboard.read_image () with
  | Error error ->
    notice ~kind:Chat_notice.Notice_failure
      ("Ctrl-V: " ^ Clipboard.error_to_string error)
  | Ok bytes ->
    (* Numbered by staging order and restarting at 1 with each message, so the
       marker in the draft and the attachment beside it carry the same number:
       the keeper reads "[Image #2]" and has an image-2.png to look at. *)
    let index = List.length state.T.msg_attachments + 1 in
    let name = Printf.sprintf "image-%d.png" index in
    (match Attachment.of_bytes ~name bytes with
     | Error error ->
       notice ~kind:Chat_notice.Notice_failure
         ("Ctrl-V: " ^ Attachment.error_to_string error)
     | Ok attachment ->
       Draft_recall.forget_recall state;
       (Message_input.invalidate_revision state.T.msg_input;
        state.T.msg_attachments <- state.T.msg_attachments @ [ attachment ]);
       Draft_recall.note_attachment_staged state;
       (* A marker run into the word before it changes that word. Only a draft
          that does not already end in whitespace needs the separator. *)
       let before = Message_input.before_cursor state.T.msg_input in
       let needs_separator =
         String.length before > 0
         && (match before.[String.length before - 1] with
             | ' ' | '\n' | '\t' -> false
             | _ -> true)
       in
       if needs_separator then Message_input.insert_char state.T.msg_input ' ';
       Message_input.insert state.T.msg_input (Printf.sprintf "[Image #%d] " index);
       notice ~kind:Chat_notice.Notice_reply
         (Printf.sprintf
            "pasted [Image #%d] (%s, %d bytes) \xc2\xb7 %d staged for the next message"
            index
            attachment.Chat_proj.mime_type
            attachment.Chat_proj.size
            (List.length state.T.msg_attachments)))
