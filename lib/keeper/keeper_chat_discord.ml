(** Keeper_chat_discord — Discord delivery adapter for keeper chat events. *)

let discord_message_limit = 2000

let send_message ~token ~channel_id ~content =
  let truncated =
    if String.length content > discord_message_limit then
      String.sub content 0 discord_message_limit
    else content
  in
  match Discord_rest_client.send_message ~token ~channel_id ~content:truncated with
  | Ok _msg_id -> ()
  | Error err ->
      let err_str =
        Format.asprintf "%a" Discord_rest_client.pp_error err
      in
      Log.Keeper.warn
        "keeper_chat_discord: send_message failed: %s" err_str

let adapter_loop ~token ~channel_id ~events =
  let rec loop ~acc_text ~run_id_opt =
    match Keeper_chat_events.subscribe events with
    | Text_delta text ->
        loop ~acc_text:(acc_text ^ text) ~run_id_opt
    | Text_message_end ->
        loop ~acc_text ~run_id_opt
    | Run_finished { run_id = _ } ->
        if String.length acc_text > 0 then
          send_message ~token ~channel_id ~content:acc_text;
        (* Loop exits after one turn. *)
        ()
    | Event_error { message } ->
        send_message ~token ~channel_id
          ~content:("Keeper error: " ^ message);
        (* Loop exits after error. *)
        ()
    | Run_started { run_id; thread_id = _ } ->
        loop ~acc_text:"" ~run_id_opt:(Some run_id)
    | Text_message_start { message_id = _; role = _ } ->
        loop ~acc_text ~run_id_opt
    | Custom { name; value = _ } ->
        Log.Keeper.debug
          "keeper_chat_discord: custom event %s" name;
        loop ~acc_text ~run_id_opt
  in
  loop ~acc_text:"" ~run_id_opt:None
