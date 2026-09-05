module Projection = Server_keeper_chat_agui_projection

let replay ~redact_text ~redact_json ~since_seq entries =
  let _, rev_events =
    List.fold_left
      (fun (projection, acc) (entry : Keeper_chat_event_log.journaled_event) ->
         let projection, projected =
           Projection.project
             ~timestamp:entry.ts
             ~redact_text
             ~redact_json
             projection
             entry.event
         in
         let acc =
           match projected with
           | Some event when Keeper_chat_event_log.seq_is_after since_seq entry.seq ->
             (entry.seq, event) :: acc
           | Some _ | None -> acc
         in
         projection, acc)
      (Projection.initial, [])
      entries
  in
  List.rev rev_events
;;
