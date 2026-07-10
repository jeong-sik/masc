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

let slack_message_limit = 4000
let slack_max_blocks = 50
let slack_block_text_limit = 3000

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

(* Slack accepts mrkdwn, not CommonMark.  Keep this conversion deliberately
   structural: it only projects the markdown constructs supported by the
   connector and leaves code/fallback text unchanged. *)
let markdown_link_re =
  Re.compile
    (Re.seq
       [ Re.char '['; Re.group (Re.rep1 (Re.compl [ Re.char ']' ])); Re.str "](";
         Re.group (Re.rep1 (Re.compl [ Re.char ')' ]))); Re.char ')' ])

let markdown_bold_re =
  Re.compile (Re.seq [ Re.str "**"; Re.group (Re.rep1 (Re.compl [ Re.char '*' ])); Re.str "**" ])

let markdown_to_mrkdwn_inline text =
  let text =
    Re.replace markdown_link_re ~f:(fun group ->
      Printf.sprintf "<%s|%s>" (Re.Group.get group 2) (Re.Group.get group 1)) text
  in
  Re.replace markdown_bold_re ~f:(fun group ->
    Printf.sprintf "*%s*" (Re.Group.get group 1)) text

let markdown_to_mrkdwn text =
  text
  |> String.split_on_char '\n'
  |> List.map (fun line ->
       let line = String.trim line in
       let line =
         if String.length line >= 2 && String.sub line 0 2 = "- "
         then "• " ^ String.sub line 2 (String.length line - 2)
         else line
       in
       let line =
         if String.length line > 0 && line.[0] = '#'
         then
           let first_space = String.index_opt line ' ' in
           match first_space with
           | Some i when i + 1 < String.length line ->
               "*" ^ String.sub line (i + 1) (String.length line - i - 1) ^ "*"
           | _ -> line
         else line
       in
       markdown_to_mrkdwn_inline line)
  |> String.concat "\n"

let truncate_block_text s = truncate_to_limit s slack_block_text_limit

let redacted_http_url_opt url =
  Keeper_chat_blocks.redacted_http_url_opt
    ~on_drop:(fun reason ->
      Log.Keeper.warn
        "keeper_chat_slack: dropped non-http(s) chat block URL reason=%s"
        (Keeper_chat_blocks.dropped_http_url_reason_to_string reason))
    url

let strip_trailing_slash s =
  let len = String.length s in
  if len > 0 && s.[len - 1] = '/' then String.sub s 0 (len - 1) else s

let public_voice_audio_url ?base_url token =
  let base =
    match base_url with
    | Some b -> strip_trailing_slash b
    | None -> Env_config_core.masc_http_base_url ()
  in
  base ^ "/api/v1/voice/audio/" ^ token

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

let tool_context_block_json ~name ~args_summary ~result_summary =
  let name = redact name |> escape_mrkdwn_text in
  let args_summary = redact args_summary |> escape_mrkdwn_text in
  let result =
    match result_summary with
    | None -> ""
    | Some r -> Printf.sprintf "\nresult: %s" (redact r |> escape_mrkdwn_text)
  in
  let text =
    Printf.sprintf "*Tool:* %s\nargs: %s%s" name args_summary result
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
  | Keeper_chat_blocks.Trace _
  | Keeper_chat_blocks.Thinking _ -> None

let content_blocks_of_text text =
  text
  |> Keeper_chat_blocks.parse_text_to_blocks
  |> List.filter_map slack_block_of_chat_block

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

let send_message_with_blocks ~token ~channel ~content ~blocks =
  let content =
    redact content |> markdown_to_mrkdwn |> escape_mrkdwn_text |> fun s ->
    truncate_to_limit s slack_message_limit
  in
  let blocks = limit_blocks_for_slack blocks in
  let fields =
    [ ("channel", `String channel); ("text", `String content) ]
  in
  let fields =
    match blocks with
    | [] -> fields
    | _ -> fields @ [ ("blocks", `List blocks) ]
  in
  let body_json = `Assoc fields |> Yojson.Safe.to_string in
  match
    Masc_http_client.post_sync ~url:"https://slack.com/api/chat.postMessage"
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

let send_message ~token ~channel ~content =
  send_message_with_blocks ~token ~channel ~content ~blocks:[]

(* ── Adapter loop ────────────────────────────────────────────────── *)

let add_block acc block = block :: acc

let adapter_loop ~token ~channel ~events ?base_url
    ?(on_send_result = fun _ -> ()) () =
  let rec loop ~acc_text ~acc_blocks ~run_id_opt =
    match Keeper_chat_events.subscribe events with
    | Text_delta text ->
        loop ~acc_text:(acc_text ^ text) ~acc_blocks ~run_id_opt
    | Text_message_end ->
        loop ~acc_text ~acc_blocks ~run_id_opt
    | Run_finished { run_id = _ } ->
        let blocks =
          final_message_blocks ~content:acc_text
            ~event_blocks:(List.rev acc_blocks)
        in
        if String.length acc_text > 0 || List.length blocks > 0 then
          on_send_result
            (send_message_with_blocks ~token ~channel ~content:acc_text ~blocks);
        ()
    | Event_error { message } ->
        on_send_result
          (send_message ~token ~channel ~content:("Keeper error: " ^ message));
        ()
    | Run_started { run_id; thread_id = _ } ->
        loop ~acc_text:"" ~acc_blocks:[] ~run_id_opt:(Some run_id)
    | Text_message_start { message_id = _; role = _ } ->
        loop ~acc_text ~acc_blocks ~run_id_opt
    | Custom { name; value = _ } ->
        Log.Keeper.debug "keeper_chat_slack: custom event %s" name;
        loop ~acc_text ~acc_blocks ~run_id_opt
    | Oas_stream_connected
    | Oas_stream_message_start _
    | Oas_stream_message_delta _
    | Oas_stream_message_stop
    | Oas_stream_ping
    | Oas_content_block_start _
    | Oas_content_block_stop _
    | Oas_thinking_delta _
    | Oas_thinking_signature_delta _
    | Oas_media_delta _ ->
        loop ~acc_text ~acc_blocks ~run_id_opt
    | Oas_stream_protocol_error error ->
        on_send_result
          (send_message ~token ~channel
             ~content:
               ("Keeper stream protocol: "
                ^ Keeper_chat_events.stream_protocol_error_summary error));
        loop ~acc_text ~acc_blocks ~run_id_opt
    | Tool_call_start _ | Tool_call_args _ | Tool_call_args_snapshot _ | Tool_call_end _ ->
        loop ~acc_text ~acc_blocks ~run_id_opt
    | Link_block { url; title; description; image = _ } ->
        let block = link_block_json ~url ~title ~description in
        loop ~acc_text ~acc_blocks:(add_block acc_blocks block) ~run_id_opt
    | Image_block { url; caption } ->
        let block = image_block_json ~url ~caption in
        loop ~acc_text ~acc_blocks:(add_block acc_blocks block) ~run_id_opt
    | Audio_block { token; mime = _; message_text; duration_sec = _ } ->
        let block = audio_block_json ~base_url ~token ~message_text in
        loop ~acc_text ~acc_blocks:(add_block acc_blocks block) ~run_id_opt
    | Tool_context_block { tool_call_id = _; name; args_summary; result_summary }
      ->
        let block =
          tool_context_block_json ~name ~args_summary ~result_summary
        in
        loop ~acc_text ~acc_blocks:(add_block acc_blocks block) ~run_id_opt
  in
  loop ~acc_text:"" ~acc_blocks:[] ~run_id_opt:None

module For_testing = struct
  let escape_mrkdwn_text = escape_mrkdwn_text
  let markdown_to_mrkdwn = markdown_to_mrkdwn
  let truncate_to_limit = truncate_to_limit
  let limit_blocks_for_slack = limit_blocks_for_slack
  let public_voice_audio_url = public_voice_audio_url
  let link_block_json = link_block_json
  let image_block_json = image_block_json
  let audio_block_json = audio_block_json
  let tool_context_block_json = tool_context_block_json
  let content_blocks_of_text = content_blocks_of_text
  let final_message_blocks = final_message_blocks
end
