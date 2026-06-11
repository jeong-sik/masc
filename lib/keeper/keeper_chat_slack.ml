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

let send_message ~token ~channel ~content =
  let content = Observability_redact.redact_text content in
  let truncated =
    if String.length content > slack_message_limit then
      String.sub content 0 slack_message_limit
    else content
  in
  let body_json =
    `Assoc
      [ ("channel", `String channel);
        ("text", `String truncated) ]
    |> Yojson.Safe.to_string
  in
  match
    Masc_http_client.post_sync ~url:"https://slack.com/api/chat.postMessage"
      ~headers:
        [
          ("Authorization", "Bearer " ^ token);
          ("Content-Type", "application/json");
        ]
      ~body:body_json ()
  with
  | Error err ->
      Log.Keeper.warn "keeper_chat_slack: post failed: %s" err
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

let adapter_loop ~token ~channel ~events =
  let rec loop ~acc_text ~run_id_opt =
    match Keeper_chat_events.subscribe events with
    | Text_delta text ->
        loop ~acc_text:(acc_text ^ text) ~run_id_opt
    | Text_message_end ->
        loop ~acc_text ~run_id_opt
    | Run_finished { run_id = _ } ->
        if String.length acc_text > 0 then
          send_message ~token ~channel ~content:acc_text;
        ()
    | Event_error { message } ->
        send_message ~token ~channel
          ~content:("Keeper error: " ^ message);
        ()
    | Run_started { run_id; thread_id = _ } ->
        loop ~acc_text:"" ~run_id_opt:(Some run_id)
    | Text_message_start { message_id = _; role = _ } ->
        loop ~acc_text ~run_id_opt
    | Custom { name; value = _ } ->
        Log.Keeper.debug
          "keeper_chat_slack: custom event %s" name;
        loop ~acc_text ~run_id_opt
    | Tool_call_start _ | Tool_call_args _ | Tool_call_end _ ->
        loop ~acc_text ~run_id_opt
  in
  loop ~acc_text:"" ~run_id_opt:None
