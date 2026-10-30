let conversation_id ~bot_user_id ~chat_id ~message_thread_id ~direct_messages_topic_id =
  let root=Printf.sprintf "telegram:bot:%Ld:chat:%Ld" bot_user_id chat_id in
  let root=match message_thread_id with None -> root | Some topic -> Printf.sprintf "%s:topic:%d" root topic in
  match direct_messages_topic_id with None -> root | Some topic -> Printf.sprintf "%s:direct-topic:%Ld" root topic
let address ~bot_user_id ~chat_id ~message_thread_id ~direct_messages_topic_id ~reply_to_message_id =
  let optional name value = match value with None -> [] | Some n -> [name,string_of_int n] in
  (["connector","telegram";"bot_user_id",Int64.to_string bot_user_id;"chat_id",Int64.to_string chat_id]
    @ optional "message_thread_id" message_thread_id @ optional "reply_to_message_id" reply_to_message_id
    @ (match direct_messages_topic_id with None -> [] | Some topic -> ["direct_messages_topic_id",Int64.to_string topic]))
  |> List.sort Stdlib.compare
let surface ~bot_user_id ~chat_id ~message_thread_id ~direct_messages_topic_id ~reply_to_message_id =
  Surface_ref.Gate {label="telegram";address=address ~bot_user_id ~chat_id ~message_thread_id ~direct_messages_topic_id ~reply_to_message_id}
let matches_surface ~bot_user_id ~chat_id ~message_thread_id ~direct_messages_topic_id ~reply_to_message_id = function
  | Surface_ref.Gate {label;address=actual} ->
    String.equal label "telegram" && List.sort Stdlib.compare actual =
      address ~bot_user_id ~chat_id ~message_thread_id ~direct_messages_topic_id ~reply_to_message_id
  | Dashboard _ | Discord _ | Slack _ | Webhook _ | Agent | Broadcast -> false
