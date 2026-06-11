(** Keeper_chat_discord — Discord delivery adapter for keeper chat events. *)

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
    | Tool_call_start _ | Tool_call_args _ | Tool_call_end _ ->
        loop ~acc_text ~run_id_opt
  in
  loop ~acc_text:"" ~run_id_opt:None
