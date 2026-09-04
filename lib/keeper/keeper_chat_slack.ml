(** Keeper_chat_slack — Slack delivery adapter for keeper chat events. *)

type error =
  | Network of string
  | Http_status of { code : int; body : string }
  | Slack_api of { error : string }
  | Other of string

let pp_error fmt = function
  | Network msg -> Format.fprintf fmt "Network: %s" msg
  | Http_status { code; body } ->
      Format.fprintf fmt "HTTP %d: %s" code body
  | Slack_api { error } ->
      Format.fprintf fmt "Slack API error: %s" error
  | Other msg -> Format.fprintf fmt "Other: %s" msg

let effect_disposition = function
  | Slack_api _ -> Tool_result.Proven_pre_effect
  | Network _ | Http_status _ -> Tool_result.Effect_outcome_unknown
  | Other _ ->
    (* [Other] carries two facts the wire type does not separate: a
       non-JSON response (nothing proven) and [ok=true] with no [ts]
       (the message was posted). Reporting the weaker
       [Effect_outcome_unknown] is sound for both — it only ever
       withholds correction, never permits a retry of a committed send.
       Separating them belongs with a split of the [Other] constructor in
       {!Slack_rest_client}. *)
    Tool_result.Effect_outcome_unknown
;;

let slack_message_limit = 4000
let slack_max_blocks = 50
let slack_block_text_limit = 3000
let slack_markdown_limit = 12_000
let min_edit_interval_s = Slack_rest_client.streaming_update_min_interval_sec

let redact content = Observability_redact.redact_text content

let split_at_codepoint s ~limit =
  let len = String.length s in
  if limit <= 0 || len = 0 then ("", s)
  else
    let rec walk pos count =
      if pos >= len then (s, "")
      else if count >= limit then
        (String.sub s 0 pos, String.sub s pos (len - pos))
      else
        let dec = String.get_utf_8_uchar s pos in
        let step = max 1 (Uchar.utf_decode_length dec) in
        let step = min step (len - pos) in
        walk (pos + step) (count + 1)
    in
    walk 0 0

let truncate_to_limit s limit = fst (split_at_codepoint s ~limit)

let is_ascii_space = function
  | ' ' | '\n' | '\r' | '\t' -> true
  | _ -> false

let stable_stream_prefix content =
  let len = String.length content in
  let rec find index =
    if index < 0 then 0
    else if is_ascii_space content.[index] then index + 1
    else find (index - 1)
  in
  let stable_len = find (len - 1) in
  if stable_len = 0 then "" else String.sub content 0 stable_len

let escape_mrkdwn_text s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (function
      | '&' -> Buffer.add_string buf "&amp;"
      | '<' -> Buffer.add_string buf "&lt;"
      | '>' -> Buffer.add_string buf "&gt;"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let stream_content content =
  content
  |> stable_stream_prefix
  |> redact
  |> escape_mrkdwn_text
  |> fun value -> truncate_to_limit value slack_message_limit

let final_stream_content content =
  content
  |> redact
  |> escape_mrkdwn_text
  |> fun value -> truncate_to_limit value slack_message_limit

let truncate_block_text s = truncate_to_limit s slack_block_text_limit

let redacted_http_url_opt url =
  Keeper_chat_blocks.redacted_http_url_opt
    ~on_drop:(fun reason ->
      Log.Keeper.warn
        "keeper_chat_slack: dropped non-http(s) chat block URL reason=%s"
        (Keeper_chat_blocks.dropped_http_url_reason_to_string reason))
    url

(* Same rule as the Discord adapter, reached the same way: resolve first, then
   fold. This file used to strip one trailing slash off the argument and leave
   the env value alone, so the same server produced a different link depending
   on which branch ran (#30476). *)
let public_voice_audio_url ?base_url token =
  let base =
    match base_url with
    | Some b -> b
    | None -> Env_config_core.masc_http_base_url ()
  in
  Masc_network_defaults.normalize_loopback_base_url base
  ^ Masc_network_defaults.voice_audio_path token

(* ── Rich block builders ─────────────────────────────────────────── *)

let link_block_json ~url ~title ~description =
  let url = escape_mrkdwn_text url in
  let title = redact title |> escape_mrkdwn_text in
  let desc =
    match description with
    | None -> ""
    | Some d -> "\n" ^ (redact d |> escape_mrkdwn_text)
  in
  let text =
    Printf.sprintf "*<%s|%s>*%s" url title desc |> truncate_block_text
  in
  `Assoc
    [ ("type", `String "section")
    ; ("text", `Assoc [ ("type", `String "mrkdwn"); ("text", `String text) ])
    ]

let image_block_json ~url ~caption =
  let alt_text =
    match caption with
    | Some caption -> redact caption
    | None -> ""
  in
  `Assoc
    [ ("type", `String "image")
    ; ("image_url", `String url)
    ; ("alt_text", `String alt_text)
    ]

let audio_block_json ~base_url ~token ~message_text =
  let url = public_voice_audio_url ?base_url token |> escape_mrkdwn_text in
  let message_text = redact message_text |> escape_mrkdwn_text in
  let text =
    Printf.sprintf "🎙 <%s|Voice message> (%s)" url message_text
    |> truncate_block_text
  in
  `Assoc
    [ ("type", `String "section")
    ; ("text", `Assoc [ ("type", `String "mrkdwn"); ("text", `String text) ])
    ]

let code_block_json ~source ~caption =
  let language = Option.value caption ~default:"code" in
  let body =
    Printf.sprintf "```%s\n%s\n```" (redact language) (redact source)
    |> truncate_block_text
  in
  `Assoc
    [ ("type", `String "section")
    ; ("text", `Assoc [ ("type", `String "mrkdwn"); ("text", `String body) ])
    ]

let mermaid_block_json ~source =
  let body = Printf.sprintf "```mermaid\n%s\n```" (redact source) |> truncate_block_text in
  `Assoc
    [ ("type", `String "section")
    ; ("text", `Assoc [ ("type", `String "mrkdwn"); ("text", `String body) ])
    ]

let status_block_json ({ Keeper_chat_blocks.kind } : Keeper_chat_blocks.status_block) =
  let body =
    Keeper_chat_blocks.status_kind_connector_text kind
    |> redact
    |> escape_mrkdwn_text
    |> truncate_block_text
  in
  `Assoc
    [ ("type", `String "section")
    ; ("text", `Assoc [ ("type", `String "mrkdwn"); ("text", `String body) ])
    ]

let escape_markdown_mentions text =
  let length = String.length text in
  let buffer = Buffer.create length in
  let rec copy index =
    if index < length then
      if
        text.[index] = '<'
        && index + 1 < length
        && (text.[index + 1] = '@' || text.[index + 1] = '!')
      then (
        Buffer.add_string buffer "&lt;";
        copy (index + 1)
      ) else (
        Buffer.add_char buffer text.[index];
        copy (index + 1)
      )
  in
  copy 0;
  Buffer.contents buffer

let markdown_block_json text =
  let text =
    redact text
    |> escape_markdown_mentions
    |> fun value -> truncate_to_limit value slack_markdown_limit
  in
  `Assoc [ "type", `String "markdown"; "text", `String text ]

let mention_block_json user_ids =
  let text =
    user_ids
    |> List.map (Printf.sprintf "<@%s>")
    |> String.concat " "
  in
  `Assoc
    [ "type", `String "section"
    ; "text", `Assoc [ "type", `String "mrkdwn"; "text", `String text ]
    ]

(* ── Content → Slack blocks ──────────────────────────────────────── *)

let slack_block_of_chat_block = function
  | Keeper_chat_blocks.Image { src; cap } ->
      Option.map
        (fun url -> image_block_json ~url ~caption:cap)
        (redacted_http_url_opt src)
  | Keeper_chat_blocks.Link { url; title; meta = _ } ->
      Option.map
        (fun url -> link_block_json ~url ~title ~description:None)
        (redacted_http_url_opt url)
  | Keeper_chat_blocks.Code { cap; html; source } ->
    let source =
      match source with
      | Some source -> source
      | None -> html
    in
    if String.trim source = "" then None else Some (code_block_json ~source ~caption:cap)
  | Keeper_chat_blocks.Mermaid { source; caption = _ } -> Some (mermaid_block_json ~source)
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

let content_blocks_of_text text =
  if String.trim text = "" then []
  else
    let media_blocks =
      text
      |> Keeper_chat_blocks.parse_text_to_blocks
      |> List.filter_map (function
        | Keeper_chat_blocks.Image _ as block -> slack_block_of_chat_block block
        | Keeper_chat_blocks.Text _
        | Keeper_chat_blocks.Heading _
        | Keeper_chat_blocks.Unordered_list _
        | Keeper_chat_blocks.Callout _
        | Keeper_chat_blocks.Table _
        | Keeper_chat_blocks.Code _
        | Keeper_chat_blocks.Mermaid _
        | Keeper_chat_blocks.Svg _
        | Keeper_chat_blocks.Voice _
        | Keeper_chat_blocks.Attach _
        | Keeper_chat_blocks.Link _
        | Keeper_chat_blocks.Fusion _
        | Keeper_chat_blocks.Status _
        | Keeper_chat_blocks.Trace _
        | Keeper_chat_blocks.Thinking _ -> None)
    in
    markdown_block_json text :: media_blocks

let message_blocks_of_text ~mention_user_ids text =
  let mention_blocks =
    match mention_user_ids with
    | [] -> []
    | user_ids -> [ mention_block_json user_ids ]
  in
  mention_blocks @ content_blocks_of_text text

let final_message_blocks ~content ~event_blocks =
  content_blocks_of_text content @ event_blocks

(* ── HTTP delivery ───────────────────────────────────────────────── *)

let omitted_blocks_notice omitted =
  let text =
    Printf.sprintf
      ":warning: %d Slack block(s) omitted because Slack allows at most %d \
       blocks per message."
      omitted slack_max_blocks
  in
  `Assoc
    [ ("type", `String "section")
    ; ("text", `Assoc [ ("type", `String "mrkdwn"); ("text", `String text) ])
    ]

let rec take n xs =
  if n <= 0 then []
  else
    match xs with
    | [] -> []
    | x :: rest -> x :: take (n - 1) rest

let limit_blocks_for_slack blocks =
  let count = List.length blocks in
  if count <= slack_max_blocks then blocks
  else
    let keep = max 0 (slack_max_blocks - 1) in
    take keep blocks @ [ omitted_blocks_notice (count - keep) ]

let build_message_body ~channel ~content ~blocks ?thread_ts () =
  let fields = [ ("channel", `String channel); ("text", `String content) ] in
  let fields =
    match blocks with
    | [] -> fields
    | _ -> fields @ [ ("blocks", `List blocks) ]
  in
  let fields =
    match thread_ts with
    | None -> fields
    | Some thread_ts -> fields @ [ "thread_ts", `String thread_ts ]
  in
  `Assoc fields |> Yojson.Safe.to_string

let build_update_message_body ~channel ~message_id ~content ~blocks =
  let fields =
    [ "channel", `String channel
    ; "ts", `String message_id
    ; "text", `String content
    ]
  in
  let fields =
    match blocks with
    | [] -> fields
    | _ -> fields @ [ "blocks", `List blocks ]
  in
  `Assoc fields |> Yojson.Safe.to_string

let build_thread_status_body ~channel ~thread_ts ~status =
  `Assoc
    [ "channel_id", `String channel
    ; "thread_ts", `String thread_ts
    ; "status", `String status
    ]
  |> Yojson.Safe.to_string

let set_thread_status ?clock
    ?(timeout_sec = Masc_http_client.default_request_timeout_sec)
    ~token ~channel ~thread_ts ~status () =
  let body = build_thread_status_body ~channel ~thread_ts ~status in
  match
    Masc_http_client.post_sync ?clock ~timeout_sec
      ~url:"https://slack.com/api/assistant.threads.setStatus"
      ~headers:
        [ "Authorization", "Bearer " ^ token
        ; "Content-Type", "application/json"
        ]
      ~body ()
  with
  | Error err -> Error (Network err)
  | Ok (code, response_body) when code < 200 || code >= 300 ->
      Error (Http_status { code; body = response_body })
  | Ok (_, response_body) ->
      (try
         let json = Yojson.Safe.from_string response_body in
         match Json_util.get_bool json "ok" with
         | Some true -> Ok ()
         | Some false ->
             (match Json_util.get_string json "error" with
              | Some error -> Error (Slack_api { error })
              | None -> Error (Other "Slack setStatus returned ok=false"))
         | None -> Error (Other "Slack setStatus response is missing ok")
       with
       | Yojson.Json_error msg ->
           Error (Other ("Slack setStatus JSON parse error: " ^ msg)))

let send_message_with_blocks ?clock
    ?(timeout_sec = Masc_http_client.default_request_timeout_sec)
    ?thread_ts ?(mention_user_ids = []) ~token ~channel ~content ~blocks () =
  let fallback_content =
    redact content |> escape_mrkdwn_text |> fun s ->
    truncate_to_limit s slack_message_limit
  in
  let content =
    match mention_user_ids with
    | [] -> fallback_content
    | user_ids ->
      let mentions =
        user_ids |> List.map (Printf.sprintf "<@%s>") |> String.concat " "
      in
      truncate_to_limit (mentions ^ "\n" ^ fallback_content) slack_message_limit
  in
  let blocks = limit_blocks_for_slack blocks in
  let body_json = build_message_body ~channel ~content ~blocks ?thread_ts () in
  match
    Masc_http_client.post_sync ?clock ~timeout_sec
      ~url:"https://slack.com/api/chat.postMessage"
      ~headers:
        [ ("Authorization", "Bearer " ^ token)
        ; ("Content-Type", "application/json")
        ]
      ~body:body_json ()
  with
  | Error err ->
      Log.Keeper.warn "keeper_chat_slack: post failed: %s" err;
      Error (Network err)
  | Ok (code, response_body) ->
      if code < 200 || code >= 300 then (
        Log.Keeper.warn "keeper_chat_slack: HTTP %d: %s" code response_body;
        Error (Http_status { code; body = response_body }))
      else
        try
          let json = Yojson.Safe.from_string response_body in
          match Json_util.get_bool json "ok" with
          | Some true -> Ok ()
          | Some false -> (
              match Json_util.get_string json "error" with
              | Some err ->
                  Log.Keeper.warn "keeper_chat_slack: Slack API error: %s" err;
                  Error (Slack_api { error = err })
              | None ->
                  Log.Keeper.warn "keeper_chat_slack: Slack ok=false";
                  Error (Other "Slack ok=false"))
          | None ->
              Log.Keeper.warn "keeper_chat_slack: missing ok in response";
              Error (Other "missing ok in response")
        with
        | Yojson.Json_error msg ->
            Log.Keeper.warn "keeper_chat_slack: JSON parse error: %s" msg;
            Error (Other ("JSON parse error: " ^ msg))

let send_message ?clock ?timeout_sec ?thread_ts ~token ~channel ~content () =
  send_message_with_blocks ?clock ?timeout_sec ?thread_ts
    ~token ~channel ~content ~blocks:[] ()

let error_of_slack_rest = function
  | Slack_rest_client.Network message -> Network message
  | Slack_rest_client.Http_status { code; body } -> Http_status { code; body }
  | Slack_rest_client.Slack_api { error } -> Slack_api { error }
  | Slack_rest_client.Other message -> Other message

let edit_message_with_blocks ?clock
    ?(timeout_sec = Masc_http_client.default_request_timeout_sec)
    ~token ~channel ~message_id ~content ~blocks () =
  let content = final_stream_content content in
  let blocks = limit_blocks_for_slack blocks in
  let body = build_update_message_body ~channel ~message_id ~content ~blocks in
  match
    Masc_http_client.post_sync ?clock ~timeout_sec
      ~url:"https://slack.com/api/chat.update"
      ~headers:
        [ "Authorization", "Bearer " ^ token
        ; "Content-Type", "application/json"
        ]
      ~body ()
  with
  | Error error -> Error (Network error)
  | Ok (code, response_body) when code < 200 || code >= 300 ->
    Error (Http_status { code; body = response_body })
  | Ok (_, response_body) ->
    (try
       let json = Yojson.Safe.from_string response_body in
       match Json_util.get_bool json "ok" with
       | Some true -> Ok ()
       | Some false ->
         (match Json_util.get_string json "error" with
          | Some error -> Error (Slack_api { error })
          | None -> Error (Other "Slack chat.update returned ok=false"))
       | None -> Error (Other "Slack chat.update response is missing ok")
     with
     | Yojson.Json_error message ->
       Error (Other ("Slack chat.update JSON parse error: " ^ message)))

let delete_message ?clock
    ?(timeout_sec = Masc_http_client.default_request_timeout_sec)
    ~token ~channel ~message_id () =
  let body =
    `Assoc [ "channel", `String channel; "ts", `String message_id ]
    |> Yojson.Safe.to_string
  in
  match
    Masc_http_client.post_sync ?clock ~timeout_sec
      ~url:"https://slack.com/api/chat.delete"
      ~headers:
        [ "Authorization", "Bearer " ^ token
        ; "Content-Type", "application/json"
        ]
      ~body ()
  with
  | Error error -> Error (Network error)
  | Ok (code, response_body) when code < 200 || code >= 300 ->
    Error (Http_status { code; body = response_body })
  | Ok (_, response_body) ->
    (try
       let json = Yojson.Safe.from_string response_body in
       match Json_util.get_bool json "ok" with
       | Some true -> Ok ()
       | Some false ->
         (match Json_util.get_string json "error" with
          | Some error -> Error (Slack_api { error })
          | None -> Error (Other "Slack chat.delete returned ok=false"))
       | None -> Error (Other "Slack chat.delete response is missing ok")
     with
     | Yojson.Json_error message ->
       Error (Other ("Slack chat.delete JSON parse error: " ^ message)))

(* ── Adapter loop ────────────────────────────────────────────────── *)

let add_block acc block = block :: acc

let adapter_loop_with_transport
    ~(events : Keeper_chat_events.keeper_chat_event Eio.Stream.t)
    ?post_stream
    ?edit_stream
    ?edit_blocks
    ?delete_stream
    (* NDT-OK: wall time only paces external Slack edits; tests inject [now]. *)
    ?(now = Unix.gettimeofday)
    ?(sleep = fun _ -> ())
    ~(send_plain : content:string -> (unit, error) result)
    ~(send_blocks :
       content:string -> blocks:Yojson.Safe.t list -> (unit, error) result)
    ?set_activity_status
    ?base_url
    ?(on_send_result = fun _ -> ()) () =
  let external_effect_completed = ref false in
  let tool_trail = ref (Keeper_chat_tool_trail.create ()) in
  let external_effect_cleanup_result = ref (Ok ()) in
  let activity_error_logged = ref false in
  let last_activity_status = ref None in
  let update_activity status =
    if !last_activity_status <> Some status then begin
      last_activity_status := Some status;
      match set_activity_status with
      | None -> ()
      | Some set_status ->
          (match set_status ~status with
           | Ok () -> ()
           | Error error when not !activity_error_logged ->
               activity_error_logged := true;
               Log.Keeper.warn
                 "keeper_chat_slack: native activity update failed: %s"
                 (Format.asprintf "%a" pp_error error)
           | Error _ -> ())
    end
  in
  let clear_activity () = update_activity "" in
  let streaming_transport =
    match post_stream, edit_stream, edit_blocks, delete_stream with
    | Some post, Some edit, Some edit_final, Some delete ->
      Some (post, edit, edit_final, delete)
    | None, None, None, None -> None
    | _ -> invalid_arg "Slack streaming transport must be supplied as one closed set"
  in
  let pace_edit last_edit_time =
    let remaining = min_edit_interval_s -. (now () -. last_edit_time) in
    if remaining > 0.0 then sleep remaining
  in
  let rec loop ~acc_text ~acc_blocks ~run_id_opt ~message_id
      ~last_edit_time ~last_edited_text ~post_attempts_left =
    let continue ?(acc_text = acc_text) ?(acc_blocks = acc_blocks)
        ?(run_id_opt = run_id_opt) ?(message_id = message_id)
        ?(last_edit_time = last_edit_time)
        ?(last_edited_text = last_edited_text)
        ?(post_attempts_left = post_attempts_left) () =
      loop ~acc_text ~acc_blocks ~run_id_opt ~message_id ~last_edit_time
        ~last_edited_text ~post_attempts_left
    in
    let event = Keeper_chat_events.subscribe events in
    (* Tool activity shows here as a transient "사용 중" line that the next one
       overwrites; the trail keeps the same events so the delivered reply can
       still name the work. See keeper_chat_tool_trail.mli. *)
    Keeper_chat_tool_trail.on_event !tool_trail event;
    match event with
    | Text_delta text ->
        let acc_text = acc_text ^ text in
        let patch_content = stream_content acc_text in
        (match streaming_transport, message_id with
         | None, _ -> continue ~acc_text ()
         | Some _, None when patch_content = "" ->
           continue ~acc_text ()
         | Some (post, _, _, _), None when post_attempts_left > 0 ->
           (match post ~content:patch_content with
            | Ok created_id ->
              continue ~acc_text ~message_id:(Some created_id)
                ~last_edit_time:(now ()) ~last_edited_text:patch_content ()
            | Error error ->
              (* A failed POST may still have landed server-side (network
                 error after send, or ok=true with a missing ts), and Slack
                 offers no idempotency key for chat.postMessage. One bounded
                 retry, then this turn degrades to log-only streaming rather
                 than risk a duplicate channel message; Run_finished still
                 delivers the reply as a fresh message. *)
              Log.Keeper.warn
                "keeper_chat_slack: streaming POST failed: %s"
                (Format.asprintf "%a" pp_error error);
              continue ~acc_text
                ~post_attempts_left:(post_attempts_left - 1) ())
         | Some _, None ->
           (* The POST retry budget is spent; skip live edits until the final
              send. *)
           continue ~acc_text ()
         | Some (_, edit, _, _), Some message_id ->
           let elapsed = now () -. last_edit_time in
           if patch_content = last_edited_text || elapsed < min_edit_interval_s
           then continue ~acc_text ()
           else
             (match edit ~message_id ~content:patch_content with
              | Ok () ->
                continue ~acc_text ~last_edit_time:(now ())
                  ~last_edited_text:patch_content ()
              | Error error ->
                Log.Keeper.warn
                  "keeper_chat_slack: streaming PATCH failed (message_id=%s): %s"
                  message_id
                  (Format.asprintf "%a" pp_error error);
                (* A failed edit consumed the rate budget just like a
                   successful one; leaving last_edit_time stale let every
                   incoming token retry immediately, deepening a 429 window.
                   Retry-After is unavailable here (the HTTP client discards
                   response headers), so re-arming the plain interval is the
                   honest bound. *)
                continue ~acc_text ~last_edit_time:(now ()) ()))
    | Text_message_end ->
        let final_content = final_stream_content acc_text in
        (match streaming_transport, message_id with
         | Some (_, edit, _, _), Some message_id
           when final_content <> last_edited_text ->
           pace_edit last_edit_time;
           (match edit ~message_id ~content:final_content with
            | Ok () ->
              continue ~last_edit_time:(now ())
                ~last_edited_text:final_content ()
            | Error error ->
              Log.Keeper.warn
                "keeper_chat_slack: text-end PATCH failed (message_id=%s): %s"
                message_id
                (Format.asprintf "%a" pp_error error);
              continue ())
         | _ -> continue ())
    | Run_finished { run_id = _ } ->
        if !external_effect_completed
        then on_send_result !external_effect_cleanup_result
        else begin
          let delivered_text = Keeper_chat_tool_trail.append_to !tool_trail ~text:acc_text in
          let blocks =
            final_message_blocks ~content:delivered_text
              ~event_blocks:(List.rev acc_blocks)
          in
          (* [delivered_text] is what goes out — the accumulated text plus the
             tool trail. Asking about [acc_text] asked about a different value:
             a tool-only turn has no assistant text but does have a trail, and
             settled Error while the turn layer settled Delivered (#26406). *)
          if String.length delivered_text > 0 || List.length blocks > 0
          then
            let result =
              match streaming_transport, message_id with
              | Some (_, _, edit_final, _), Some message_id ->
                let final_content = final_stream_content delivered_text in
                if final_content = last_edited_text && blocks = []
                then Ok ()
                else begin
                  pace_edit last_edit_time;
                  edit_final ~message_id ~content:delivered_text ~blocks
                end
              | _ -> send_blocks ~content:delivered_text ~blocks
            in
            on_send_result result
          else
            on_send_result
              (Error (Other "Slack terminal reply contained no text or blocks"))
        end;
        clear_activity ();
        ()
    | External_effect_completed _ ->
        external_effect_completed := true;
        (match streaming_transport, message_id with
         | Some (_, _, _, delete), Some message_id ->
           external_effect_cleanup_result := delete ~message_id
         | _ -> ());
        continue ()
    | Event_error { message } ->
        let content = "Keeper error: " ^ message in
        let result =
          match streaming_transport, message_id with
          | Some (_, edit, _, _), Some message_id ->
            pace_edit last_edit_time;
            edit ~message_id ~content:(final_stream_content content)
          | _ -> send_plain ~content
        in
        on_send_result result;
        clear_activity ();
        ()
    | Run_started { run_id; thread_id = _ } ->
        update_activity "답변을 준비하고 있어요…";
        (* A new run's work is its own; the previous run's trail went out with
           the previous run's reply. *)
        tool_trail := Keeper_chat_tool_trail.create ();
        loop ~acc_text:"" ~acc_blocks:[] ~run_id_opt:(Some run_id)
          ~message_id:None ~last_edit_time:0.0 ~last_edited_text:""
          ~post_attempts_left:2
    | Agent_core_runtime_attempt_started ->
        continue ~acc_text:"" ()
    | Text_message_start { message_id = _; role = _ } ->
        continue ()
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
    | Agent_core_media_delta _ ->
        continue ()
    | Agent_core_stream_protocol_error error ->
        (* This is an interim diagnostic, not the terminal queued-message
           delivery receipt. Reporting it through [on_send_result] could let a
           successful diagnostic mask a later final-send failure. *)
        (match
           send_plain
             ~content:
               ("Keeper stream protocol: "
                ^ Keeper_chat_events.stream_protocol_error_summary error)
         with
         | Ok () -> ()
         | Error error ->
           Log.Keeper.warn
             "keeper_chat_slack: protocol diagnostic delivery failed: %s"
             (Format.asprintf "%a" pp_error error));
        continue ()
    | Tool_call_start { tool_call_name; _ } ->
        update_activity (Printf.sprintf "🔧 %s 사용 중…" tool_call_name);
        continue ()
    (* An approval prompt has no operator on a connector channel: nobody is
       sitting there to answer y/n, and posting the question would ask a room
       to decide something it cannot. Approval is offered on the operator's
       own surface, so this never arrives here -- it is spelled out rather
       than left to a catch-all so a future surface has to make the same
       decision deliberately. *)
    | Tool_call_args _ | Tool_call_args_snapshot _ | Tool_call_end _
    | Tool_approval_requested _ | Tool_approval_settled _
    | Tool_result_ready _ ->
        continue ()
    | Link_block { url; title; description; image = _ } ->
        let block = link_block_json ~url ~title ~description in
        continue ~acc_blocks:(add_block acc_blocks block) ()
    | Image_block { url; caption } ->
        let block = image_block_json ~url ~caption in
        continue ~acc_blocks:(add_block acc_blocks block) ()
    | Status_block status ->
        let block = status_block_json status in
        (match status.Keeper_chat_blocks.kind with
         | Keeper_chat_blocks.Awaiting_gate_approval ->
           (* The turn's partial text is deliberately replaced by the
              pending-approval status; External_effect_completed later deletes
              the streaming message. *)
           continue ~acc_text:"" ~acc_blocks:(add_block acc_blocks block) ()
         | Keeper_chat_blocks.Continuation_checkpoint ->
           (* A mid-turn checkpoint must not shrink the posted message: the
              accumulated text is what Text_message_end and Run_finished
              deliver. *)
           continue ~acc_blocks:(add_block acc_blocks block) ())
    | Audio_block { token; mime = _; message_text; duration_sec = _ } ->
        let block = audio_block_json ~base_url ~token ~message_text in
        continue ~acc_blocks:(add_block acc_blocks block) ()
    | Tool_context_block _ ->
        continue ()
  in
  loop ~acc_text:"" ~acc_blocks:[] ~run_id_opt:None ~message_id:None
    ~last_edit_time:0.0 ~last_edited_text:"" ~post_attempts_left:2

let adapter_loop ~clock ~token ~channel ?thread_ts ~events ?base_url
    ?on_send_result () =
  let set_activity_status =
    match thread_ts with
    | Some thread_ts ->
        Some
          (fun ~status ->
             set_thread_status ~clock ~token ~channel ~thread_ts ~status ())
    | None ->
        Log.Keeper.debug
          "keeper_chat_slack: native activity unavailable without thread_ts";
        None
  in
  adapter_loop_with_transport
    ~post_stream:(fun ~content ->
      Slack_rest_client.send_message ~clock ~token ~channel_id:channel
        ~text:content ?thread_ts ()
      |> Result.map_error error_of_slack_rest)
    ~edit_stream:(fun ~message_id ~content ->
      Slack_rest_client.edit_message ~clock ~token ~channel_id:channel
        ~ts:message_id ~text:content ()
      |> Result.map_error error_of_slack_rest)
    ~edit_blocks:(fun ~message_id ~content ~blocks ->
      edit_message_with_blocks ~clock ~token ~channel ~message_id ~content
        ~blocks ())
    ~delete_stream:(fun ~message_id ->
      delete_message ~clock ~token ~channel ~message_id ())
    ~sleep:(Eio.Time.sleep clock)
    ~send_plain:(fun ~content ->
      send_message ~clock ?thread_ts ~token ~channel ~content ())
    ~send_blocks:(fun ~content ~blocks ->
      send_message_with_blocks ~clock ?thread_ts ~token ~channel ~content ~blocks ())
    ~events ?set_activity_status ?base_url ?on_send_result ()

module For_testing = struct
  let escape_mrkdwn_text = escape_mrkdwn_text
  let truncate_to_limit = truncate_to_limit
  let limit_blocks_for_slack = limit_blocks_for_slack
  let public_voice_audio_url = public_voice_audio_url
  let link_block_json = link_block_json
  let image_block_json = image_block_json
  let audio_block_json = audio_block_json
  let content_blocks_of_text = content_blocks_of_text
  let message_blocks_of_text = message_blocks_of_text
  let markdown_block_json = markdown_block_json
  let mention_block_json = mention_block_json
  let final_message_blocks = final_message_blocks
  let build_message_body = build_message_body
  let build_thread_status_body = build_thread_status_body

  let adapter_loop = adapter_loop_with_transport
end
