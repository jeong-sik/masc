(** Keeper_chat_discord — Discord delivery adapter for keeper chat events.

    Streaming mode: the first stable text segment POST creates the Discord
    message. Subsequent deltas PATCH the message content at most once per
    [min_edit_interval_s] (rate limit: 5 edits / 5 s per channel).
    [Text_message_end] and [Run_finished] force a final PATCH so the user
    always sees the complete text. Tool activity stays on Discord's native
    typing surface and never creates standalone messages. *)

(* Minimum seconds between PATCH edits. Discord allows 5 edits per 5 s;
   1.0 s is 80 % of that budget, leaving headroom for the final edit. *)
let min_edit_interval_s = 1.0

type error = Discord_rest_client.error

let pp_error = Discord_rest_client.pp_error

(* ── Text chunking helpers ────────────────────────────────────────── *)

let send_message ?clock ~token ~channel_id ~content () =
  let content = Observability_redact.redact_text content in
  let limit = Discord_rest_client.message_content_limit in
  let len = String.length content in
  if len = 0 then Ok ()
  else if len <= limit then
    match Discord_rest_client.send_message ?clock ~token ~channel_id ~content () with
    | Ok _msg_id -> Ok ()
    | Error err ->
        let err_str = Format.asprintf "%a" Discord_rest_client.pp_error err in
        Log.Keeper.warn
          "keeper_chat_discord: send_message failed: %s" err_str;
        Error err
  else
    let rec send_chunks first_error rest =
      if String.length rest = 0 then
        match first_error with
        | None -> Ok ()
        | Some err -> Error err
      else
        (* Split on a codepoint boundary: Discord measures the limit in
           Unicode scalar values, and a mid-codepoint byte cut produces
           invalid UTF-8 that Discord rejects with a 400. *)
        let chunk, remaining =
          Discord_rest_client.split_at_codepoint rest ~limit
        in
        (match Discord_rest_client.send_message ?clock ~token ~channel_id ~content:chunk () with
         | Ok _msg_id -> send_chunks first_error remaining
         | Error err ->
             let err_str = Format.asprintf "%a" Discord_rest_client.pp_error err in
             Log.Keeper.warn
               "keeper_chat_discord: send_message chunk failed: %s" err_str;
             (* Preserve the existing best-effort overflow behavior, but return
                the first failure after all remaining chunks are attempted so
                the terminal delivery receipt cannot claim success. *)
             let first_error =
               match first_error with
               | None -> Some err
               | Some _ -> first_error
             in
             send_chunks first_error remaining)
    in
    send_chunks None content

(* Truncate to Discord message limit for PATCH edits, with redaction.
   Cuts on a codepoint boundary so the PATCH body stays valid UTF-8. *)
let truncate content =
  Discord_rest_client.truncate_to_limit (Observability_redact.redact_text content)

let redacted_http_url_opt url =
  Keeper_chat_blocks.redacted_http_url_opt
    ~on_drop:(fun reason ->
      Log.Keeper.warn
        "keeper_chat_discord: dropped non-http(s) chat block URL reason=%s"
        (Keeper_chat_blocks.dropped_http_url_reason_to_string reason))
    url

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

let edit_message ?clock ~token ~channel_id ~message_id ~content () =
  match Discord_rest_client.edit_message
          ?clock ~token ~channel_id ~message_id ~content ()
  with
  | Ok () -> Ok ()
  | Error err ->
      let err_str = Format.asprintf "%a" Discord_rest_client.pp_error err in
      Log.Keeper.warn
        "keeper_chat_discord: edit_message failed (msg=%s): %s"
        message_id err_str;
      Error err

(* Truncate a string to [max_len], appending "…" when truncated.
   Separate from [truncate] above which truncates to Discord message
   limit with redaction. *)
let truncate_to ~max_len s =
  if String.length s <= max_len then s
  else String.sub s 0 (max_len - 1) ^ "…"

(* ── Rich block delivery helpers ─────────────────────────────────── *)

(* Fold after resolving, not inside one branch. The env value is a base URL
   the same way the argument is, and it arrives unfolded: MASC_HTTP_BASE_URL
   is taken verbatim, and [Server_bootstrap_http.make_http_config] leaves an
   existing one alone. Folding only the argument made the two branches answer
   differently for one server, and made this file disagree with its Slack
   sibling (#30476). *)
let public_voice_audio_url ?base_url token =
  let base =
    match base_url with
    | Some b -> b
    | None -> Env_config_core.masc_http_base_url ()
  in
  Masc_network_defaults.normalize_loopback_base_url base
  ^ Masc_network_defaults.voice_audio_path token

let send_link_block ?clock ~token ~channel_id ~url ~title ~description ~image () =
  let embed =
    Discord_rest_client.link_embed ~url ~title ~description ~image
  in
  match Discord_rest_client.send_embed_message
          ?clock ~token ~channel_id ~content:"" ~embeds:[embed] ()
  with
  | Ok _msg_id -> ()
  | Error err ->
      let err_str = Format.asprintf "%a" Discord_rest_client.pp_error err in
      Log.Keeper.warn
        "keeper_chat_discord: send_link_block failed: %s" err_str

let send_image_block ?clock ~token ~channel_id ~url ~caption () =
  let embed = Discord_rest_client.image_embed ~url ~caption in
  match Discord_rest_client.send_embed_message
          ?clock ~token ~channel_id ~content:"" ~embeds:[embed] ()
  with
  | Ok _msg_id -> ()
  | Error err ->
      let err_str = Format.asprintf "%a" Discord_rest_client.pp_error err in
      Log.Keeper.warn
        "keeper_chat_discord: send_image_block failed: %s" err_str

let send_audio_block ?clock ~token ~channel_id ~base_url ~audio_token ~message_text
    ~duration_sec () =
  let url = public_voice_audio_url ?base_url audio_token in
  let duration_prefix =
    match duration_sec with
    | None -> ""
    | Some d -> Printf.sprintf "%.1fs " d
  in
  let content =
    Printf.sprintf "🔊 %s%s\n%s" duration_prefix message_text url
  in
  (* Rich audio is a side message, not the primary terminal delivery receipt.
     [send_message] already logs the concrete transport error. *)
  match send_message ?clock ~token ~channel_id ~content () with
  | Ok () -> ()
  | Error err ->
      Log.Keeper.debug
        "keeper_chat_discord: audio block delivery returned observed error: %s"
        (Format.asprintf "%a" Discord_rest_client.pp_error err)

let truncate_embed_desc s =
  let max_len = 3900 in
  truncate_to ~max_len s

let code_to_embed ~source ~caption =
  let source =
    Observability_redact.redact_text source |> truncate_to ~max_len:3800
  in
  let language = Option.value caption ~default:"code" in
  let title =
    Printf.sprintf "Code (%s)" (Observability_redact.redact_text language)
    |> truncate_to ~max_len:200
  in
  let body = Printf.sprintf "```%s\n%s\n```" language source in
  { Discord_rest_client.title = title
    ; description = Some (truncate_embed_desc body)
    ; url = None
    ; color = Discord_rest_client.color_green
    ; image = None
    ; fields = []
    }

let mermaid_to_embed ~source =
  let source = Observability_redact.redact_text source |> truncate_to ~max_len:3800 in
  let body = Printf.sprintf "```mermaid\n%s\n```" source in
  { Discord_rest_client.title = "Mermaid Diagram"
    ; description = Some (truncate_embed_desc body)
    ; url = None
    ; color = Discord_rest_client.color_blue
    ; image = None
    ; fields = []
    }

let rich_embed_of_chat_block = function
  | Keeper_chat_blocks.Image { src; cap } ->
      let caption = Option.map Observability_redact.redact_text cap in
      Option.map
        (fun url -> Discord_rest_client.image_embed ~url ~caption)
        (redacted_http_url_opt src)
  | Keeper_chat_blocks.Link { url; title; meta = _ } ->
      let title = Observability_redact.redact_text title in
      Option.map
        (fun url ->
          Discord_rest_client.link_embed ~url ~title ~description:None
            ~image:None)
        (redacted_http_url_opt url)
  | Keeper_chat_blocks.Code { cap; html = _; source = Some source } ->
      Some (code_to_embed ~source ~caption:cap)
  | Keeper_chat_blocks.Code { cap; html; source = None } ->
      Some (code_to_embed ~source:html ~caption:cap)
  | Keeper_chat_blocks.Mermaid { source; caption = _ } ->
      Some (mermaid_to_embed ~source)
  | Keeper_chat_blocks.Text _
  | Keeper_chat_blocks.Heading _
  | Keeper_chat_blocks.Unordered_list _
  | Keeper_chat_blocks.Callout _
  | Keeper_chat_blocks.Table _
  | Keeper_chat_blocks.Svg _
  | Keeper_chat_blocks.Voice _
  | Keeper_chat_blocks.Attach _
  | Keeper_chat_blocks.Fusion _
  | Keeper_chat_blocks.Status _
  | Keeper_chat_blocks.Trace _
  | Keeper_chat_blocks.Thinking _ -> None

let rich_embeds_of_text text =
  text
  |> Keeper_chat_blocks.parse_text_to_blocks
  |> List.filter_map rich_embed_of_chat_block

let send_text_rich_embeds ?clock ~token ~channel_id text =
  rich_embeds_of_text text
  |> List.iter (fun embed ->
         match
           Discord_rest_client.send_embed_message ~token ~channel_id
             ?clock ~content:"" ~embeds:[ embed ] ()
         with
         | Ok _msg_id -> ()
         | Error err ->
             let err_str =
               Format.asprintf "%a" Discord_rest_client.pp_error err
             in
             Log.Keeper.warn
               "keeper_chat_discord: send_text_rich_embed failed: %s" err_str)

(* ── Adapter loop ────────────────────────────────────────────────── *)

let combine_delivery_results primary overflow =
  match primary with
  | Error _ -> primary
  | Ok () -> overflow

let adapter_loop_with_transport ~token ~channel_id ~events ~post_message
    ~edit_message ~send_message ?show_activity ?clock ?base_url
    (* NDT-OK: wall time only paces external Discord edits; tests inject
       [now]. *)
    ?(now = Unix.gettimeofday)
    ?(on_send_result = fun _ -> ()) () =
  let external_effect_completed = ref false in
  let tool_trail = ref (Keeper_chat_tool_trail.create ()) in
  let activity_error_logged = ref false in
  let refresh_activity () =
    match show_activity with
    | None -> ()
    | Some show ->
        (match show () with
         | Ok () -> ()
         | Error err when not !activity_error_logged ->
             activity_error_logged := true;
             Log.Keeper.warn
               "keeper_chat_discord: native activity refresh failed: %s"
               (Format.asprintf "%a" Discord_rest_client.pp_error err)
         | Error _ -> ())
  in
  let rec loop ~acc_text ~msg_id ~last_edit_time ~last_edited_text
      ~post_attempts_left =
    let continue ?(acc_text = acc_text) ?(msg_id = msg_id)
        ?(last_edit_time = last_edit_time)
        ?(last_edited_text = last_edited_text)
        ?(post_attempts_left = post_attempts_left) () =
      loop ~acc_text ~msg_id ~last_edit_time ~last_edited_text
        ~post_attempts_left
    in
    let event = Keeper_chat_events.subscribe events in
    (* This adapter keeps tool activity off the channel as messages; the trail
       collects the same events so the delivered reply can still name the work.
       See keeper_chat_tool_trail.mli. *)
    Keeper_chat_tool_trail.on_event !tool_trail event;
    match event with
    | Text_delta text ->
        let acc_text = acc_text ^ text in
        let patch_content = streaming_patch_content acc_text in
        (match msg_id with
         | None when String.length patch_content = 0 -> continue ~acc_text ()
         | None when post_attempts_left > 0 ->
             (match post_message ~content:patch_content with
              | Ok created_id ->
                  continue ~acc_text ~msg_id:(Some created_id)
                    ~last_edit_time:(now ()) ~last_edited_text:patch_content ()
              | Error err ->
                  (* A failed POST may still have landed server-side (network
                     error after send, or a 2xx whose body we could not read an
                     id from), and Discord offers no idempotency key for message
                     creation. One bounded retry, then this turn degrades to
                     log-only streaming rather than risk a duplicate channel
                     message; Run_finished still delivers the reply as a fresh
                     message. *)
                  Log.Keeper.warn
                    "keeper_chat_discord: streaming POST failed: %s"
                    (Format.asprintf "%a" Discord_rest_client.pp_error err);
                  continue ~acc_text
                    ~post_attempts_left:(post_attempts_left - 1) ())
         | None ->
             (* The POST retry budget is spent; skip live edits until the
                final send. *)
             continue ~acc_text ()
         | Some mid ->
             let elapsed = now () -. last_edit_time in
             if patch_content = last_edited_text then continue ~acc_text ()
             else if elapsed < min_edit_interval_s then continue ~acc_text ()
             else
               (match edit_message ~message_id:mid ~content:patch_content with
                | Ok () ->
                    continue ~acc_text ~last_edit_time:(now ())
                      ~last_edited_text:patch_content ()
                | Error err ->
                    Log.Keeper.warn
                      "keeper_chat_discord: streaming PATCH failed (msg=%s): %s"
                      mid
                      (Format.asprintf "%a" Discord_rest_client.pp_error err);
                    (* A failed edit consumed the rate budget just like a
                       successful one; leaving last_edit_time stale let every
                       incoming token retry immediately, deepening a 429
                       window. Retry-After is unavailable here (the HTTP
                       client discards response headers), so re-arming the
                       plain interval is the honest bound. *)
                    continue ~acc_text ~last_edit_time:(now ()) ()))
    | Text_message_end ->
        let final_content = truncate acc_text in
        (match msg_id with
         | Some mid when final_content <> last_edited_text ->
             (match edit_message ~message_id:mid ~content:final_content with
              | Ok () ->
                  continue ~last_edit_time:(now ())
                    ~last_edited_text:final_content ()
              | Error err ->
                  Log.Keeper.warn
                    "keeper_chat_discord: text-end PATCH failed (msg=%s): %s"
                    mid
                    (Format.asprintf "%a" Discord_rest_client.pp_error err);
                  continue ())
         | _ -> continue ())
    | Run_finished { run_id = _ } ->
        let delivered_text = Keeper_chat_tool_trail.append_to !tool_trail ~text:acc_text in
        let final_result =
          match msg_id with
          | None when !external_effect_completed -> Ok ()
          | None ->
              (* Ask whether there is anything to send, which is
                 [delivered_text] — the accumulated text plus the tool trail.
                 Checking [acc_text] asked about a different value: a turn that
                 only called tools has no assistant text but does have a trail,
                 so it settled Error while the turn layer had already settled
                 Delivered (#26406). *)
              if String.length delivered_text = 0 then
                Error
                  (Discord_rest_client.Other
                     { request_id = "keeper_chat_discord.final_reply"
                     ; reason = "primary final Discord reply contained no text"
                     ; body_bytes = 0
                     })
              else send_message ~content:delivered_text
          | Some mid ->
              let head, overflow = final_head_and_overflow delivered_text in
              let patch_result = edit_message ~message_id:mid ~content:head in
              let overflow_result =
                match overflow with
                | None -> Ok ()
                | Some overflow -> send_message ~content:overflow
              in
              combine_delivery_results patch_result overflow_result
        in
        on_send_result final_result;
        send_text_rich_embeds ?clock ~token ~channel_id acc_text
    | External_effect_completed _ ->
        external_effect_completed := true;
        continue ()
    | Event_error { message } ->
        on_send_result (send_message ~content:("Keeper error: " ^ message))
    | Run_started { run_id = _; thread_id = _ } ->
        refresh_activity ();
        (* A new run's work is its own; the previous run's trail was delivered
           with the previous run's reply. *)
        tool_trail := Keeper_chat_tool_trail.create ();
        loop ~acc_text:"" ~msg_id:None ~last_edit_time:0.0
          ~last_edited_text:"" ~post_attempts_left:2
    | Agent_core_runtime_attempt_started ->
        continue ~acc_text:"" ()
    | Text_message_start _ -> continue ()
    | Reply_details _
    | Continuation_checkpoint _
    | Agent_core_stream_connected
    | Agent_core_stream_message_start _
    | Agent_core_stream_message_delta _
    | Agent_core_stream_message_stop
    | Agent_core_stream_ping
    | Agent_core_content_block_start _
    | Agent_core_content_block_stop _
    | Agent_core_thinking_delta _
    | Agent_core_thinking_signature_delta _
    | Agent_core_media_delta _ -> continue ()
    | Agent_core_stream_protocol_error error ->
        ignore
          (send_message
             ~content:
               ("Keeper stream protocol: "
                ^ Keeper_chat_events.stream_protocol_error_summary error)
            : (unit, error) result);
        continue ()
    | Tool_call_start _ ->
        refresh_activity ();
        continue ()
    | Tool_call_args _
    | Tool_call_args_snapshot _
    | Tool_call_end _
    (* An approval prompt has no operator on a connector channel: nobody is
       sitting there to answer y/n, and posting the question would ask a room
       to decide something it cannot. Approval is offered on the operator's
       own surface, so this never arrives here -- it is spelled out rather
       than left to a catch-all so a future surface has to make the same
       decision deliberately. *)
    | Tool_approval_requested _
    | Tool_approval_settled _
    | Tool_result_ready _
    | Tool_context_block _ -> continue ()
    | Link_block { url; title; description; image } ->
        send_link_block ?clock ~token ~channel_id ~url ~title ~description ~image ();
        continue ()
    | Image_block { url; caption } ->
        send_image_block ?clock ~token ~channel_id ~url ~caption ();
        continue ()
    | Status_block { kind } ->
        (match kind with
         | Keeper_chat_blocks.Awaiting_gate_approval ->
             (* The turn's partial text is deliberately replaced by the
                pending-approval status; the external-effect flow then owns
                the message. *)
             continue
               ~acc_text:(Keeper_chat_blocks.status_kind_connector_text kind)
               ()
         | Keeper_chat_blocks.Continuation_checkpoint ->
             (* A mid-turn checkpoint must not shrink the posted message:
                the accumulated text is what Text_message_end and
                Run_finished deliver. *)
             continue ())
    | Audio_block { token; mime = _; message_text; duration_sec } ->
        send_audio_block ?clock ~token ~channel_id ~base_url ~audio_token:token
          ~message_text ~duration_sec ();
        continue ()
  in
  let run () =
    loop ~acc_text:"" ~msg_id:None ~last_edit_time:0.0
      ~last_edited_text:"" ~post_attempts_left:2
  in
  match clock, show_activity with
  | Some clock, Some _ ->
      Eio.Fiber.first
        run
        (fun () ->
           let rec refresh_loop () =
             Eio.Time.sleep clock 8.0;
             refresh_activity ();
             refresh_loop ()
           in
           refresh_loop ())
  | _ -> run ()

let adapter_loop ~clock ~token ~channel_id ~events ?base_url
    ?(on_send_result = fun _ -> ()) () =
  adapter_loop_with_transport ~token ~channel_id ~events
    ~post_message:(fun ~content ->
      Discord_rest_client.send_message ~clock ~token ~channel_id ~content ())
    ~edit_message:(fun ~message_id ~content ->
      edit_message ~clock ~token ~channel_id ~message_id ~content ())
    ~send_message:(fun ~content -> send_message ~clock ~token ~channel_id ~content ())
    ~show_activity:(fun () ->
      Discord_rest_client.trigger_typing ~clock ~token ~channel_id ())
    ~clock ?base_url ~on_send_result ()

module For_testing = struct
  let streaming_patch_content = streaming_patch_content
  let final_head_and_overflow = final_head_and_overflow
  let public_voice_audio_url = public_voice_audio_url
  let rich_embeds_of_text = rich_embeds_of_text
  let adapter_loop = adapter_loop_with_transport
end
