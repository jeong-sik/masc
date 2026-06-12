(** Keeper_chat_discord — Discord delivery adapter for keeper chat events.

    Streaming mode: on the first [Text_delta], POST creates the Discord
    message.  Subsequent deltas PATCH the message content at most once
    per [min_edit_interval_s] (rate limit: 5 edits / 5 s per channel).
    [Text_message_end] and [Run_finished] force a final PATCH so the
    user always sees the complete text. *)

(* Minimum seconds between PATCH edits. Discord allows 5 edits per 5 s;
   1.0 s is 80 % of that budget, leaving headroom for the final edit. *)
let min_edit_interval_s = 1.0

let send_message ~token ~channel_id ~content =
  let content = Observability_redact.redact_text content in
  let limit = Discord_rest_client.message_content_limit in
  let len = String.length content in
  if len = 0 then ()
  else if len <= limit then
    match Discord_rest_client.send_message ~token ~channel_id ~content () with
    | Ok _msg_id -> ()
    | Error err ->
        let err_str = Format.asprintf "%a" Discord_rest_client.pp_error err in
        Log.Keeper.warn
          "keeper_chat_discord: send_message failed: %s" err_str
  else
    let rec send_chunks rest =
      let rlen = String.length rest in
      if rlen = 0 then ()
      else
        let chunk =
          if rlen <= limit then rest
          else String.sub rest 0 limit
        in
        let remaining =
          if rlen <= limit then ""
          else String.sub rest limit (rlen - limit)
        in
        (match Discord_rest_client.send_message ~token ~channel_id ~content:chunk () with
         | Ok _msg_id -> send_chunks remaining
         | Error err ->
             let err_str = Format.asprintf "%a" Discord_rest_client.pp_error err in
             Log.Keeper.warn
               "keeper_chat_discord: send_message chunk failed: %s" err_str;
             (* Continue sending remaining chunks despite error — partial
                delivery is better than silent truncation. *)
             send_chunks remaining)
    in
    send_chunks content

(* Truncate to Discord message limit for PATCH edits, with redaction. *)
let truncate content =
  let content = Observability_redact.redact_text content in
  let limit = Discord_rest_client.message_content_limit in
  if String.length content <= limit then content
  else String.sub content 0 limit

let edit_message_silent ~token ~channel_id ~message_id ~content =
  match Discord_rest_client.edit_message
          ~token ~channel_id ~message_id ~content ()
  with
  | Ok () -> ()
  | Error err ->
      let err_str = Format.asprintf "%a" Discord_rest_client.pp_error err in
      Log.Keeper.warn
        "keeper_chat_discord: edit_message failed (msg=%s): %s"
        message_id err_str

(* NDT-OK: wall-clock used for Discord rate-limit backoff only,
   not for deterministic policy or state transitions. *)
let now () = Unix.gettimeofday ()

let adapter_loop ~token ~channel_id ~events =
  (* Streaming state:
     - msg_id: Some once the initial POST succeeds
     - last_edit_time: wall-clock of last PATCH (rate limiting)
     - last_edited_text: snapshot of acc_text at last PATCH (skip no-op edits) *)
  let rec loop ~acc_text ~msg_id ~last_edit_time ~last_edited_text =
    match Keeper_chat_events.subscribe events with
    | Text_delta text ->
        let acc_text = acc_text ^ text in
        (match msg_id with
         | None ->
             (* First delta — POST to create the message. *)
             (match Discord_rest_client.send_message
                     ~token ~channel_id ~content:(truncate acc_text) ()
             with
              | Ok created_id ->
                  loop ~acc_text
                    ~msg_id:(Some created_id)
                    ~last_edit_time:(now ())
                    ~last_edited_text:acc_text
              | Error err ->
                  let err_str =
                    Format.asprintf "%a" Discord_rest_client.pp_error err
                  in
                  Log.Keeper.warn
                    "keeper_chat_discord: streaming POST failed: %s" err_str;
                  (* Keep accumulating; will try again on next delta. *)
                  loop ~acc_text ~msg_id:None
                    ~last_edit_time ~last_edited_text)
         | Some mid ->
             let elapsed = now () -. last_edit_time in
             if elapsed >= min_edit_interval_s then begin
               edit_message_silent ~token ~channel_id
                 ~message_id:mid ~content:(truncate acc_text);
               loop ~acc_text ~msg_id
                 ~last_edit_time:(now ())
                 ~last_edited_text:acc_text
             end else
               (* Rate limited — skip this PATCH. *)
               loop ~acc_text ~msg_id ~last_edit_time ~last_edited_text)
    | Text_message_end ->
        (* Force a final PATCH for this text message if content changed. *)
        (match msg_id with
         | Some mid when acc_text <> last_edited_text ->
             edit_message_silent ~token ~channel_id
               ~message_id:mid ~content:(truncate acc_text);
             loop ~acc_text ~msg_id
               ~last_edit_time:(now ())
               ~last_edited_text:acc_text
         | _ ->
             loop ~acc_text ~msg_id ~last_edit_time ~last_edited_text)
    | Run_finished { run_id = _ } ->
        (match msg_id with
         | None ->
             (* No deltas received — fall back to single send (chunks). *)
             if String.length acc_text > 0 then
               send_message ~token ~channel_id ~content:acc_text
         | Some mid ->
             (* Redact once, then split head/tail at the 2000-char limit. *)
             let redacted = Observability_redact.redact_text acc_text in
             let limit = Discord_rest_client.message_content_limit in
             let rlen = String.length redacted in
             let head =
               if rlen <= limit then redacted
               else String.sub redacted 0 limit
             in
             (* Final PATCH with the head (first 2000 chars). *)
             edit_message_silent ~token ~channel_id
               ~message_id:mid ~content:head;
             (* Send overflow as follow-up messages, matching the original
                chunking behavior. send_message handles further splitting. *)
             if rlen > limit then begin
               let overflow =
                 String.sub redacted limit (rlen - limit)
               in
               send_message ~token ~channel_id ~content:overflow
             end);
        (* Loop exits after one turn. *)
        ()
    | Event_error { message } ->
        send_message ~token ~channel_id
          ~content:("Keeper error: " ^ message);
        (* Loop exits after error. *)
        ()
    | Run_started { run_id = _; thread_id = _ } ->
        loop ~acc_text:"" ~msg_id:None ~last_edit_time:0.0 ~last_edited_text:""
    | Text_message_start { message_id = _; role = _ } ->
        loop ~acc_text ~msg_id ~last_edit_time ~last_edited_text
    | Custom { name; value = _ } ->
        Log.Keeper.debug
          "keeper_chat_discord: custom event %s" name;
        loop ~acc_text ~msg_id ~last_edit_time ~last_edited_text
    | Tool_call_start _ | Tool_call_args _ | Tool_call_end _ ->
        loop ~acc_text ~msg_id ~last_edit_time ~last_edited_text
  in
  loop ~acc_text:"" ~msg_id:None ~last_edit_time:0.0 ~last_edited_text:""
