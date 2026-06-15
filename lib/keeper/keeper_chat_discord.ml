(** Keeper_chat_discord — Discord delivery adapter for keeper chat events.

    Streaming mode: the first stable text segment POST creates the Discord
    message. Subsequent deltas PATCH the message content at most once per
    [min_edit_interval_s] (rate limit: 5 edits / 5 s per channel).
    [Text_message_end] and [Run_finished] force a final PATCH so the user
    always sees the complete text.

    Tool embed visualization: [Tool_call_start] sends a blue "Running…"
    embed; [Tool_call_end] edits it to green "Done". *)

(* Minimum seconds between PATCH edits. Discord allows 5 edits per 5 s;
   1.0 s is 80 % of that budget, leaving headroom for the final edit. *)
let min_edit_interval_s = 1.0

(* ── Text chunking helpers ────────────────────────────────────────── *)

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
      if String.length rest = 0 then ()
      else
        (* Split on a codepoint boundary: Discord measures the limit in
           Unicode scalar values, and a mid-codepoint byte cut produces
           invalid UTF-8 that Discord rejects with a 400. *)
        let chunk, remaining =
          Discord_rest_client.split_at_codepoint rest ~limit
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

(* Truncate to Discord message limit for PATCH edits, with redaction.
   Cuts on a codepoint boundary so the PATCH body stays valid UTF-8. *)
let truncate content =
  Discord_rest_client.truncate_to_limit (Observability_redact.redact_text content)

let is_ascii_space = function
  | ' ' | '\n' | '\r' | '\t' -> true
  | _ -> false

let stable_stream_prefix content =
  let len = String.length content in
  let rec find i =
    if i < 0 then 0
    else if is_ascii_space content.[i] then i + 1
    else find (i - 1)
  in
  let stable_len = find (len - 1) in
  if stable_len = 0 then ""
  else String.sub content 0 stable_len

let streaming_patch_content content =
  content |> stable_stream_prefix |> truncate

let final_head_and_overflow content =
  let redacted = Observability_redact.redact_text content in
  (* Split head/overflow on a codepoint boundary so the head PATCH and
     the overflow follow-up are each valid UTF-8 (a byte cut would split
     a multi-byte char across the two). *)
  let head, overflow_str =
    Discord_rest_client.split_at_codepoint redacted
      ~limit:Discord_rest_client.message_content_limit
  in
  let overflow = if overflow_str = "" then None else Some overflow_str in
  (head, overflow)

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

module For_testing = struct
  let streaming_patch_content = streaming_patch_content
  let final_head_and_overflow = final_head_and_overflow
end

(* ── Tool embed helpers ──────────────────────────────────────────── *)

(* [tool_msgs] maps tool_call_id → (discord_message_id, tool_call_name).
   We store the tool name so the "done" edit can preserve it in the
   embed title without relying on the end event carrying the name. *)
type tool_msg_entry = (string * string)
(* (discord_message_id, tool_call_name) *)

let find_tool_msg tool_msgs tool_call_id =
  List.assoc_opt tool_call_id tool_msgs

let remove_tool_msg tool_msgs tool_call_id =
  List.filter (fun (k, _) -> k <> tool_call_id) tool_msgs

(* Truncate a string to [max_len], appending "…" when truncated.
   Separate from [truncate] above which truncates to Discord message
   limit with redaction. *)
let truncate_to ~max_len s =
  if String.length s <= max_len then s
  else String.sub s 0 (max_len - 1) ^ "…"

(* Discord embed title limit is 256 characters. *)
let tool_embed_title ~tool_name =
  let prefix = "🔧 " in
  let budget = 256 - String.length prefix in
  prefix ^ truncate_to ~max_len:budget tool_name

(* Send a "running" embed for a tool call. Returns the Discord message
   id so we can edit it to "done" later. *)
let send_tool_running ~token ~channel_id ~tool_call_name =
  let embed =
    { Discord_rest_client.title = tool_embed_title ~tool_name:tool_call_name
    ; description = Some "Running…"
    ; color = Discord_rest_client.color_blue
    ; fields = []
    }
  in
  match Discord_rest_client.send_embed_message
          ~token ~channel_id ~content:"" ~embeds:[embed] () with
  | Ok msg_id -> Some msg_id
  | Error err ->
      let err_str = Format.asprintf "%a" Discord_rest_client.pp_error err in
      Log.Keeper.warn
        "keeper_chat_discord: send_tool_running failed: %s" err_str;
      None

(* Edit a "running" embed to "done", preserving the original tool name. *)
let send_tool_done ~token ~channel_id ~message_id ~tool_call_name =
  let embed =
    { Discord_rest_client.title = tool_embed_title ~tool_name:tool_call_name
    ; description = Some "✅ Done"
    ; color = Discord_rest_client.color_green
    ; fields = []
    }
  in
  match Discord_rest_client.edit_embed_message
          ~token ~channel_id ~message_id ~content:"" ~embeds:[embed] () with
  | Ok () -> ()
  | Error err ->
      let err_str = Format.asprintf "%a" Discord_rest_client.pp_error err in
      Log.Keeper.warn
        "keeper_chat_discord: send_tool_done failed: %s" err_str

(* ── Adapter loop ────────────────────────────────────────────────── *)

(* NDT-OK: wall-clock used for Discord rate-limit backoff only,
   not for deterministic policy or state transitions. *)
let now () = Unix.gettimeofday ()

let adapter_loop ~token ~channel_id ~events =
  (* Streaming state:
     - msg_id: Some once the initial POST succeeds
     - last_edit_time: wall-clock of last PATCH (rate limiting)
     - last_edited_text: content sent by last POST/PATCH (skip no-op edits)
     - tool_msgs: tool_call_id → (discord_message_id, tool_call_name) *)
  let rec loop ~acc_text ~msg_id ~last_edit_time ~last_edited_text
      ~(tool_msgs : (string * tool_msg_entry) list) =
    match Keeper_chat_events.subscribe events with
    | Text_delta text ->
        let acc_text = acc_text ^ text in
        let patch_content = streaming_patch_content acc_text in
        (match msg_id with
         | None ->
             (* First stable segment — POST to create the message. *)
             if String.length patch_content = 0 then
               loop ~acc_text ~msg_id:None ~last_edit_time
                 ~last_edited_text ~tool_msgs
             else
               (match Discord_rest_client.send_message
                       ~token ~channel_id ~content:patch_content ()
               with
                | Ok created_id ->
                    loop ~acc_text
                      ~msg_id:(Some created_id)
                      ~last_edit_time:(now ())
                      ~last_edited_text:patch_content
                      ~tool_msgs
                | Error err ->
                    let err_str =
                      Format.asprintf "%a" Discord_rest_client.pp_error err
                    in
                    Log.Keeper.warn
                      "keeper_chat_discord: streaming POST failed: %s" err_str;
                    (* Keep accumulating; will try again on next delta. *)
                    loop ~acc_text ~msg_id:None
                      ~last_edit_time ~last_edited_text ~tool_msgs)
         | Some mid ->
             let elapsed = now () -. last_edit_time in
             if patch_content = last_edited_text then
               loop ~acc_text ~msg_id ~last_edit_time
                 ~last_edited_text ~tool_msgs
             else if elapsed >= min_edit_interval_s then begin
               edit_message_silent ~token ~channel_id
                 ~message_id:mid ~content:patch_content;
               loop ~acc_text ~msg_id
                 ~last_edit_time:(now ())
                 ~last_edited_text:patch_content
                 ~tool_msgs
             end else
               (* Rate limited — skip this PATCH. *)
               loop ~acc_text ~msg_id ~last_edit_time
                 ~last_edited_text ~tool_msgs)
    | Text_message_end ->
        (* Force a final PATCH for this text message if content changed. *)
        let final_content = truncate acc_text in
        (match msg_id with
         | Some mid when final_content <> last_edited_text ->
             edit_message_silent ~token ~channel_id
               ~message_id:mid ~content:final_content;
             loop ~acc_text ~msg_id
               ~last_edit_time:(now ())
               ~last_edited_text:final_content
               ~tool_msgs
         | _ ->
             loop ~acc_text ~msg_id ~last_edit_time
               ~last_edited_text ~tool_msgs)
    | Run_finished { run_id = _ } ->
        (match msg_id with
         | None ->
             (* No deltas received — fall back to single send (chunks). *)
             if String.length acc_text > 0 then
               send_message ~token ~channel_id ~content:acc_text
         | Some mid ->
             let head, overflow = final_head_and_overflow acc_text in
             (* Final PATCH with the head (first 2000 chars). *)
             edit_message_silent ~token ~channel_id
               ~message_id:mid ~content:head;
             (* Send overflow as follow-up messages, matching the original
                chunking behavior. send_message handles further splitting. *)
             (match overflow with
              | None -> ()
              | Some overflow ->
               send_message ~token ~channel_id ~content:overflow
             ));
        (* Loop exits after one turn. *)
        ()
    | Event_error { message } ->
        send_message ~token ~channel_id
          ~content:("Keeper error: " ^ message);
        (* Loop exits after error. *)
        ()
    | Run_started { run_id = _; thread_id = _ } ->
        loop ~acc_text:"" ~msg_id:None ~last_edit_time:0.0
          ~last_edited_text:"" ~tool_msgs:[]
    | Text_message_start { message_id = _; role = _ } ->
        loop ~acc_text ~msg_id ~last_edit_time ~last_edited_text ~tool_msgs
    | Custom { name; value = _ } ->
        Log.Keeper.debug
          "keeper_chat_discord: custom event %s" name;
        loop ~acc_text ~msg_id ~last_edit_time ~last_edited_text ~tool_msgs
    | Tool_call_start { tool_call_id; tool_call_name } ->
        let tool_msgs =
          match send_tool_running ~token ~channel_id ~tool_call_name with
          | Some discord_msg_id ->
              (tool_call_id, (discord_msg_id, tool_call_name)) :: tool_msgs
          | None -> tool_msgs
        in
        loop ~acc_text ~msg_id ~last_edit_time ~last_edited_text ~tool_msgs
    | Tool_call_args { tool_call_id = _; delta = _ } ->
        (* Args stream is not visualized — only start/end matters. *)
        loop ~acc_text ~msg_id ~last_edit_time ~last_edited_text ~tool_msgs
    | Tool_call_end { tool_call_id } ->
        (match find_tool_msg tool_msgs tool_call_id with
         | Some (discord_msg_id, tool_call_name) ->
             send_tool_done ~token ~channel_id
               ~message_id:discord_msg_id ~tool_call_name;
             let tool_msgs = remove_tool_msg tool_msgs tool_call_id in
             loop ~acc_text ~msg_id ~last_edit_time ~last_edited_text ~tool_msgs
         | None ->
             (* No running embed was created (send failed earlier). *)
             loop ~acc_text ~msg_id ~last_edit_time ~last_edited_text ~tool_msgs)
  in
  loop ~acc_text:"" ~msg_id:None ~last_edit_time:0.0
    ~last_edited_text:"" ~tool_msgs:[]
