let deliver ~events ~load_blocks ~send =
  let open Result.Syntax in
  let rec loop terminal =
    match Keeper_chat_run_signal.read events with
    | Keeper_chat_run_signal.Closed -> Error "Telegram event stream closed before terminal completion"
    | Keeper_chat_run_signal.Failed message -> Error message
    | Keeper_chat_run_signal.Reply details -> loop (Some details)
    | Keeper_chat_run_signal.Finished ->
      (match terminal with
       | None -> Error "Telegram run completed without terminal reply details"
       | Some details -> match details.Keeper_chat_events.turn_outcome with
         | Keeper_turn_outcome.Visible_reply ->
           let* blocks = load_blocks details.turn_ref in
           let* messages = Keeper_telegram_render.render ~reply:details.reply ~blocks in
           send messages
         | Continuation_checkpoint ->
           let* messages = Keeper_telegram_render.render ~reply:"" ~blocks:(Some [Keeper_chat_blocks.Status {kind=Continuation_checkpoint}]) in
           send messages
         | Awaiting_gate_approval ->
           let* messages = Keeper_telegram_render.render ~reply:"" ~blocks:(Some [Keeper_chat_blocks.Status {kind=Awaiting_gate_approval}]) in
           send messages
         | Terminal_effect_settled | No_visible_reply -> Ok ())
    | Keeper_chat_run_signal.Progress -> loop terminal
  in loop None
