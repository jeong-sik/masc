type t =
  | Telegram of {
      bot_user_id:int64; chat_id:int64; message_thread_id:int option;
      direct_messages_topic_id:int64 option; reply_to_message_id:int option; user_id:int64;
    }
  | Imessage of {chat_identifier:string; chat_guid:string; user_id:string}

let of_continuation ?imessage_destination = function
  | Keeper_continuation_channel.Telegram
      {bot_user_id;chat_id;message_thread_id;direct_messages_topic_id;reply_to_message_id;user_id} ->
    Ok (Telegram {bot_user_id;chat_id;message_thread_id;direct_messages_topic_id;reply_to_message_id;user_id})
  | Keeper_continuation_channel.Imessage {chat_identifier;chat_guid;user_id} ->
    (match imessage_destination, chat_guid with
     | Some destination, _ when String.trim destination <> "" ->
       Ok (Imessage {chat_identifier;chat_guid=destination;user_id})
     | None, Some chat_guid -> Ok (Imessage {chat_identifier;chat_guid;user_id})
     | Some _, _ | None, None -> Error "iMessage continuation has no concrete reply destination")
  | Keeper_continuation_channel.Dashboard _ | Keeper_continuation_channel.Discord _
  | Keeper_continuation_channel.Slack _ | Keeper_continuation_channel.Keeper _
  | Keeper_continuation_channel.Unrouted _ -> Error "native reply requires a Telegram or iMessage continuation"

let connector = function Telegram _ -> "telegram" | Imessage _ -> "imessage"
let channel_id = function Telegram r -> Int64.to_string r.chat_id | Imessage r -> r.chat_identifier

let destination_id = function Telegram r -> Int64.to_string r.chat_id | Imessage r -> r.chat_guid

let to_yojson = function
  | Telegram r ->
    let int64 n = `Intlit (Int64.to_string n) in
    let optional name f = function None -> [] | Some n -> [name,f n] in
    `Assoc (["kind",`String "telegram";"bot_user_id",int64 r.bot_user_id;
      "chat_id",int64 r.chat_id;"user_id",int64 r.user_id]
      @ optional "message_thread_id" (fun n -> `Int n) r.message_thread_id
      @ optional "direct_messages_topic_id" int64 r.direct_messages_topic_id
      @ optional "reply_to_message_id" (fun n -> `Int n) r.reply_to_message_id)
  | Imessage r -> `Assoc ["kind",`String "imessage";"chat_identifier",`String r.chat_identifier;
      "chat_guid",`String r.chat_guid;"user_id",`String r.user_id]

let of_yojson json = Result.bind (Keeper_continuation_channel.of_yojson json) (of_continuation ?imessage_destination:None)

let matches_continuation route channel =
  match route, channel with
  | Telegram a, Keeper_continuation_channel.Telegram b ->
    a.bot_user_id=b.bot_user_id && a.chat_id=b.chat_id && a.message_thread_id=b.message_thread_id
    && a.direct_messages_topic_id=b.direct_messages_topic_id && a.reply_to_message_id=b.reply_to_message_id
    && a.user_id=b.user_id
  | Imessage a, Keeper_continuation_channel.Imessage b ->
    a.chat_identifier=b.chat_identifier && b.chat_guid=Some a.chat_guid && a.user_id=b.user_id
  | (Telegram _ | Imessage _), (Keeper_continuation_channel.Dashboard _
      | Keeper_continuation_channel.Discord _ | Keeper_continuation_channel.Slack _
      | Keeper_continuation_channel.Telegram _ | Keeper_continuation_channel.Imessage _
      | Keeper_continuation_channel.Keeper _ | Keeper_continuation_channel.Unrouted _) -> false

let surface = function
  | Telegram r -> Keeper_telegram_coordinates.surface ~bot_user_id:r.bot_user_id ~chat_id:r.chat_id
      ~message_thread_id:r.message_thread_id ~direct_messages_topic_id:r.direct_messages_topic_id
      ~reply_to_message_id:r.reply_to_message_id
  | Imessage r -> Surface_ref.Gate {label="imessage";
      address=["connector","imessage";"chat_identifier",r.chat_identifier;"chat_guid",r.chat_guid]}

let check_binding ~keeper_name route =
  let resolved = match route with
    | Telegram _ -> Channel_gate_telegram_state.resolve_keeper_for_channel_result
        ~channel_id:(channel_id route)
    | Imessage _ -> Channel_gate_imessage_state.resolve_keeper_for_channel_result
        ~channel_id:(channel_id route)
        |> Result.map (Option.map (fun (binding : Channel_gate_imessage_state.keeper_binding_resolution) -> binding.keeper_name)) in
  match resolved with
  | Error error -> Error (Channel_gate_binding_store.binding_store_error_to_string error)
  | Ok (Some owner) when String.equal owner keeper_name -> Ok ()
  | Ok (Some _) | Ok None -> Error "native continuation conversation is no longer bound to this Keeper"

let send ?telegram_post ?imessage_send ~clock route ~content =
  match route with
  | Telegram r ->
    Result.bind (Channel_gate_telegram_state.chunks content
      |> Result.map_error (Format.asprintf "%a" Telegram_rest_client.pp_error)) (fun messages ->
      Channel_gate_telegram_state.send_message ?post:telegram_post ~clock
        ~bot_user_id:r.bot_user_id ~chat_id:r.chat_id ~message_thread_id:r.message_thread_id
        ~direct_messages_topic_id:r.direct_messages_topic_id ~reply_to_message_id:r.reply_to_message_id
        ~html:false ~messages ()
      |> Result.map_error (Format.asprintf "%a" Channel_gate_telegram_state.pp_send_error))
  | Imessage r ->
    match imessage_send with
    | Some send -> send ~chat_guid:r.chat_guid ~content
    | None -> Channel_gate_imessage_state.send_message ~chat_guid:r.chat_guid ~content ()
        |> Result.map_error Imessage_applescript.error_to_string
