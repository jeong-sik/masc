module Store=Channel_gate_binding_store
module Api=Telegram_rest_client
let connector_id="telegram"
let display_name="Telegram"
let channel="telegram"
let binding_store_path = Env_config_telegram.binding_store_path
let binding_audit_path = Env_config_telegram.binding_audit_path
let store=Store.create ~connector_id ~binding_store_path ~binding_store_read_path:binding_store_path
  ~binding_audit_path ~binding_audit_read_path:binding_audit_path ~guild_id_field:Store.Include_empty
let ( let* )=Result.bind

type poll_state = Not_configured | Starting | Polling of {bot_user_id:int64;next_offset:int64 option} | Degraded of string
let state=Atomic.make Starting

(* What the connector list draws from the poll state: whether it polls, as
   which bot, and why not. The offset moves with every poll and is not drawn,
   so only a change of the rest tells readers (RFC-0480 §3.4). *)
let same_drawn_state previous next =
  match previous, next with
  | Not_configured, Not_configured | Starting, Starting -> true
  | Polling previous, Polling next -> Int64.equal previous.bot_user_id next.bot_user_id
  | Degraded previous, Degraded next -> String.equal previous next
  | (Not_configured | Starting | Polling _ | Degraded _),
    (Not_configured | Starting | Polling _ | Degraded _) -> false

let publish next =
  let previous = Atomic.exchange state next in
  if not (same_drawn_state previous next) then Gate_connector_announce.changed ~connector_id

let record_not_configured () = publish Not_configured
let record_error detail = publish (Degraded detail)
let record_poll_ok ~bot_user_id ~next_offset = publish (Polling {bot_user_id;next_offset})
let connected () = match Atomic.get state with Polling _ -> true | Not_configured | Starting | Degraded _ -> false
let snapshot ?(audit_limit = 10) () : Channel_gate_connector.snapshot =
  let binding_read =
    Store.read_bindings_result store
    |> Result.map_error Store.binding_store_error_to_string
  in
  let configured = Option.is_some (Env_config_telegram.bot_token_opt ()) in
  let available = configured && Result.is_ok binding_read in
  let current = Atomic.get state in
  let connected =
    match current with
    | Polling _ -> available
    | Not_configured | Starting | Degraded _ -> false
  in
  let poll_error =
    match current with
    | Degraded detail -> detail
    | Not_configured -> "TELEGRAM_BOT_TOKEN is not configured"
    | Starting | Polling _ -> ""
  in
  let error = match binding_read with Ok _ -> poll_error | Error error -> error in
  (* bot_user_id goes out as a string, as every connector sends it: the
     dashboard and TUI read one string field for all connectors. *)
  let bot_user_id, next_offset =
    match current with
    | Polling { bot_user_id; next_offset } ->
        `String (Int64.to_string bot_user_id),
        Option.fold ~none:`Null
          ~some:(fun n -> `Intlit (Int64.to_string n)) next_offset
    | Not_configured | Starting | Degraded _ -> `Null, `Null
  in
  { available
  ; connected
  ; stale = false
  ; error
  ; binding_read
  ; binding_store_path = binding_store_path ()
  ; audit_path = binding_audit_path ()
  ; recent_audit = Store.read_recent_audit store ~limit:audit_limit
  ; updated_at = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ())
  ; details =
      [ "capabilities", Channel_gate_connector_capability.all_json
      ; "status_source", `String "in_process_gateway"
      ; "bot_user_id", bot_user_id
      ; "next_offset", next_offset
      ]
  ; descriptor_details = []
  }

let status_json ?audit_limit () =
  Channel_gate_connector.snapshot_status_json ~channel (snapshot ?audit_limit ())

let connector_json ?audit_limit () =
  Channel_gate_connector.snapshot_connector_json ~connector_id ~display_name ~channel
    (snapshot ?audit_limit ())

let resolve_keeper_for_channel_result ~channel_id =
  Result.map (fun bindings -> Option.map (fun (binding:Store.binding) -> binding.keeper_name)
    (Store.find_binding_by_channel_id bindings ~channel_id)) (Store.read_bindings_result store)
let bound_channels ~keeper_name = Store.bound_channels_result store ~keeper_name

type mutation = Bind of string | Unbind of string option
let mutate mutation ~channel_id ~actor_name =
  let channel_id=String.trim channel_id in
  match Int64.of_string_opt channel_id with
  | None -> Error "Telegram binding requires a numeric chat ID"
  | Some id when id=0L || Int64.to_string id<>channel_id -> Error "Telegram binding requires the canonical numeric chat ID"
  | Some _ ->
    Store.mutate_bindings store ~decide:(fun bindings ->
      let previous=Store.find_binding_by_channel_id bindings ~channel_id in
      let previous_keeper=Option.fold ~none:"" ~some:(fun (b:Store.binding) -> b.keeper_name) previous in
      let rest=List.filter(fun (b:Store.binding)->b.channel_id<>channel_id) bindings in
      let* action,keeper_name,updated=match mutation with
        | Bind keeper_name when String.trim keeper_name="" -> Error "keeper_name is required"
        | Bind keeper_name -> Ok("bind",keeper_name,({Store.channel_id;keeper_name}::rest))
        | Unbind (Some expected) when previous_keeper<>expected -> Error "Telegram binding ownership changed"
        | Unbind (None | Some _) -> Ok("unbind",previous_keeper,rest) in
      let event=Store.{timestamp=Gate_time_util.iso8601_of_unix(Unix.gettimeofday());action;
        channel_id;keeper_name;actor_id=actor_name;actor_name;previous_keeper} in
      Ok(List.sort(fun (a:Store.binding) b->String.compare a.channel_id b.channel_id) updated,event,()))
    |> Result.map_error Store.mutation_error_to_string |> Result.map(fun ()->status_json ())
let bind ~channel_id ~keeper_name ~actor_name = mutate (Bind(String.trim keeper_name)) ~channel_id ~actor_name
let unbind ~channel_id ~actor_name = mutate (Unbind None) ~channel_id ~actor_name
let unbind_if_keeper ~channel_id ~expected_keeper_name ~actor_name = mutate (Unbind(Some expected_keeper_name)) ~channel_id ~actor_name

(* The documented 4096-character sendMessage boundary. Count UTF-16 units
   conservatively so astral scalars never overrun either character convention;
   all original UTF-8 bytes and ordering are preserved. *)
let chunks text =
  let rec scan start index units acc =
    if index=String.length text then Ok(List.rev(if index=start then acc else String.sub text start (index-start)::acc))
    else
      let decoded=String.get_utf_8_uchar text index in
      if not(Uchar.utf_decode_is_valid decoded) then Error(Api.Invalid_request "reply UTF-8")
      else
        let bytes=Uchar.utf_decode_length decoded in
        let width=if Uchar.to_int(Uchar.utf_decode_uchar decoded)>0xffff then 2 else 1 in
        if units+width>4096 then scan index index 0 (String.sub text start (index-start)::acc)
        else scan start (index+bytes) (units+width) acc in
  scan 0 0 0 []
type send_error = Api_failure of Api.error | Partial_delivery of {sent_messages:(int64 * int) list;cause:Api.error}
let pp_send_error fmt = function
  | Api_failure error -> Api.pp_error fmt error
  | Partial_delivery {sent_messages;cause} ->
    Format.fprintf fmt "telegram partial delivery [%s]: %a"
      (String.concat "," (List.map(fun (chat,id)->Printf.sprintf "%Ld/%d" chat id) sent_messages)) Api.pp_error cause
let send_message ?post ~clock ~bot_user_id ~chat_id ~message_thread_id ~direct_messages_topic_id ~reply_to_message_id ~html ~messages () =
  let result =
    let* token=match Env_config_telegram.bot_token_opt () with Some token -> Ok token | None -> Error(Api.Invalid_request "TELEGRAM_BOT_TOKEN missing") in
    let* client=Api.create ~token in
    let* actual=Api.get_me ?post ~clock client () in
    if not actual.is_bot || actual.id<>bot_user_id then Error(Api.Invalid_request "configured bot differs from continuation")
    else if messages=[] || List.exists (fun text -> text="") messages then Error(Api.Invalid_request "empty reply")
    else Ok(client,messages) in
  let* client,parts=Result.map_error(fun error->Api_failure error) result in
  let failed sent cause = Error(match sent with [] -> Api_failure cause | _::_ -> Partial_delivery {sent_messages=List.rev sent;cause}) in
  let rec send sent = function
    | [] -> Ok ()
    | text::rest ->
      let rec attempt () = match Api.send_message ?post ~clock client ~chat_id
          ?message_thread_id ?direct_messages_topic_id ?reply_to_message_id ~html ~text () with
        | Error(Api.Api_error {retry_after=Some seconds;_}) -> Eio.Time.sleep clock (float_of_int seconds);attempt ()
        | Error ((Api.Invalid_request _ | Invalid_response _ | Transport_failed | Http_status _
                 | Api_error {retry_after=None;_}) as error) -> Error error
        | Ok message -> Ok message in
      match attempt () with
      | Error cause -> failed sent cause
      | Ok delivered ->
        let sent=(delivered.chat_id,delivered.message_id)::sent in
        if delivered.chat_id<>chat_id || delivered.message_thread_id<>message_thread_id || delivered.direct_messages_topic_id<>direct_messages_topic_id || delivered.message_id<=0
        then failed sent (Api.Invalid_response "reply destination/message identity differs from continuation")
        else send sent rest in
  send [] parts
