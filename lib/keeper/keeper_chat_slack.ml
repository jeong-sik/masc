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

let truncate_to_limit s limit =
  if String.length s <= limit then s else String.sub s 0 limit

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
  let title = redact title in
  let desc =
    match description with
    | None -> ""
    | Some d -> "\n" ^ redact d
  in
  let text =
    Printf.sprintf "*<%s|%s>*%s" url title desc
    |> fun s -> truncate_to_limit s slack_block_text_limit
  in
  `Assoc
    [ ("type", `String "section")
    ; ("text", `Assoc [ ("type", `String "mrkdwn"); ("text", `String text) ])
    ]

let image_block_json ~url ~caption =
  let alt_text = Option.value caption ~default:"" in
  `Assoc
    [ ("type", `String "image")
    ; ("image_url", `String url)
    ; ("alt_text", `String alt_text)
    ]

let audio_block_json ~base_url ~token ~message_text =
  let url = public_voice_audio_url ?base_url token in
  let message_text = redact message_text in
  let text =
    Printf.sprintf "🎙 <%s|Voice message> (%s)" url message_text
    |> fun s -> truncate_to_limit s slack_block_text_limit
  in
  `Assoc
    [ ("type", `String "section")
    ; ("text", `Assoc [ ("type", `String "mrkdwn"); ("text", `String text) ])
    ]

let tool_context_block_json ~name ~args_summary ~result_summary =
  let args_summary = redact args_summary in
  let result =
    match result_summary with
    | None -> ""
    | Some r -> Printf.sprintf "\nresult: %s" (redact r)
  in
  let text =
    Printf.sprintf "*Tool: %s*\nargs: %s%s" name args_summary result
    |> fun s -> truncate_to_limit s slack_block_text_limit
  in
  `Assoc
    [ ("type", `String "section")
    ; ("text", `Assoc [ ("type", `String "mrkdwn"); ("text", `String text) ])
    ]

(* ── HTTP delivery ───────────────────────────────────────────────── *)

let send_message_with_blocks ~token ~channel ~content ~blocks =
  let content = redact content |> fun s -> truncate_to_limit s slack_message_limit in
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
  | Error err -> Log.Keeper.warn "keeper_chat_slack: post failed: %s" err
  | Ok (code, response_body) -> (
      if code < 200 || code >= 300 then
        Log.Keeper.warn "keeper_chat_slack: HTTP %d: %s" code response_body
      else
        try
          let json = Yojson.Safe.from_string response_body in
          match Json_util.get_bool json "ok" with
          | Some true -> ()
          | Some false -> (
              match Json_util.get_string json "error" with
              | Some err ->
                  Log.Keeper.warn "keeper_chat_slack: Slack API error: %s" err
              | None ->
                  Log.Keeper.warn "keeper_chat_slack: Slack ok=false")
          | None ->
              Log.Keeper.warn "keeper_chat_slack: missing ok in response"
        with
        | Yojson.Json_error msg ->
            Log.Keeper.warn "keeper_chat_slack: JSON parse error: %s" msg)

let send_message ~token ~channel ~content =
  send_message_with_blocks ~token ~channel ~content ~blocks:[]

(* ── Adapter loop ────────────────────────────────────────────────── *)

let add_block acc block =
  if List.length acc >= slack_max_blocks then acc else block :: acc

let adapter_loop ~token ~channel ~events ?base_url () =
  let rec loop ~acc_text ~acc_blocks ~run_id_opt =
    match Keeper_chat_events.subscribe events with
    | Text_delta text ->
        loop ~acc_text:(acc_text ^ text) ~acc_blocks ~run_id_opt
    | Text_message_end ->
        loop ~acc_text ~acc_blocks ~run_id_opt
    | Run_finished { run_id = _ } ->
        let blocks = List.rev acc_blocks in
        if String.length acc_text > 0 || List.length blocks > 0 then
          send_message_with_blocks ~token ~channel ~content:acc_text ~blocks;
        ()
    | Event_error { message } ->
        send_message ~token ~channel ~content:("Keeper error: " ^ message);
        ()
    | Run_started { run_id; thread_id = _ } ->
        loop ~acc_text:"" ~acc_blocks:[] ~run_id_opt:(Some run_id)
    | Text_message_start { message_id = _; role = _ } ->
        loop ~acc_text ~acc_blocks ~run_id_opt
    | Custom { name; value = _ } ->
        Log.Keeper.debug "keeper_chat_slack: custom event %s" name;
        loop ~acc_text ~acc_blocks ~run_id_opt
    | Tool_call_start _ | Tool_call_args _ | Tool_call_end _ ->
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
  let public_voice_audio_url = public_voice_audio_url
  let link_block_json = link_block_json
  let image_block_json = image_block_json
  let audio_block_json = audio_block_json
  let tool_context_block_json = tool_context_block_json
end
