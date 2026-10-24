module Api=Telegram_rest_client
module Custody=Telegram_poll_custody
module State=Channel_gate_telegram_state
let ( let* )=Result.bind
let accept_update ~claim_root ~resolve ~dispatch_for_delivery ~bot_user_id ~operation_id (update:Api.update) =
  let ignore reason =
    let* () = Keeper_telegram_ingress_claim.ensure_unclaimed ~root:claim_root ~operation_id
      |> Result.map_error Keeper_telegram_ingress_claim.error_to_string in
    Ok(Custody.Intentionally_ignored reason) in
  match update.kind with
  | Api.Unsupported -> ignore Custody.Unsupported_update
  | Message message | Edited_message message ->
    match message.sender_chat_id,message.from_user with
    | Some _,_ | None,None -> ignore Custody.Unsupported_update
    | None,Some user when user.is_bot -> ignore Custody.Bot_message
    | None,Some user ->
      let content=match message.text,message.caption with Some text,_ -> text | None,Some caption -> caption | None,None -> "" in
      if String.trim content="" then ignore Custody.Empty_message
      else
        let* keeper=resolve ~channel_id:(Int64.to_string message.chat_id) in
        match keeper with
        | None -> ignore Custody.Unbound_chat
        | Some keeper_name ->
          let reply_to_message_id=Some message.message_id in
          let* continuation_channel=Keeper_continuation_channel.telegram ~bot_user_id ~chat_id:message.chat_id
            ~message_thread_id:message.message_thread_id ~direct_messages_topic_id:message.direct_messages_topic_id
            ~reply_to_message_id ~user_id:user.id in
          let conversation_id=Keeper_telegram_coordinates.conversation_id ~bot_user_id ~chat_id:message.chat_id
            ~message_thread_id:message.message_thread_id ~direct_messages_topic_id:message.direct_messages_topic_id in
          let external_message_id=string_of_int message.message_id in
          let delivery:Gate_keeper_backend.connector_delivery={continuation_channel;
            surface=Keeper_telegram_coordinates.surface ~bot_user_id ~chat_id:message.chat_id
              ~message_thread_id:message.message_thread_id ~direct_messages_topic_id:message.direct_messages_topic_id ~reply_to_message_id;
            conversation_id=Some conversation_id;external_message_id=Some external_message_id;workspace_id=None} in
          let kind=match update.kind with Message _ -> "message" | Edited_message _ -> "edited_message" | Unsupported -> "unsupported" in
          let inbound:Channel_gate.inbound_message={channel=State.channel;channel_user_id=Int64.to_string user.id;
            channel_user_name=(match user.username with None -> user.first_name | Some username -> username);
            channel_workspace_id="";keeper_name;content;idempotency_key=operation_id;
            metadata=["conversation_id",conversation_id;"external_message_id",external_message_id;
              "telegram.update_id",Int64.to_string update.update_id;"telegram.event_kind",kind;"mentions_bound_keeper","true"]} in
          let submit () =
            let optional value = function None -> `Null | Some v -> value v in
            let string value = `String value in
            let identity = `Assoc [
              "bot_user_id",`Intlit(Int64.to_string bot_user_id);
              "update_id",`Intlit(Int64.to_string update.update_id);
              "inbound",`Assoc ["channel",string inbound.channel;
                "channel_user_id",string inbound.channel_user_id;"channel_user_name",string inbound.channel_user_name;
                "channel_workspace_id",string inbound.channel_workspace_id;"keeper_name",string inbound.keeper_name;
                "content",string inbound.content;"idempotency_key",string inbound.idempotency_key;
                "metadata",`List(List.map(fun(k,v)->`List[string k;string v]) inbound.metadata)];
              "delivery",`Assoc ["continuation_channel",Keeper_continuation_channel.to_yojson delivery.continuation_channel;
                "surface",Surface_ref.to_json delivery.surface;
                "conversation_id",optional string delivery.conversation_id;
                "external_message_id",optional string delivery.external_message_id;
                "workspace_id",optional string delivery.workspace_id]] in
            let* () = Keeper_telegram_ingress_claim.ensure ~root:claim_root ~operation_id ~identity
              |> Result.map_error Keeper_telegram_ingress_claim.error_to_string in
            match Channel_gate.handle_inbound ~dispatch:(dispatch_for_delivery delivery) inbound with
            | Ok outbound -> Ok(Custody.Accepted outbound)
            | Error(Channel_gate.Validation Gate_protocol.Empty_content) -> ignore Custody.Empty_message
            | Error(Channel_gate.Validation (Gate_protocol.Content_too_long _)) ->
              Log.Server.warn "telegram: update %Ld rejected by Gate content limit" update.update_id;
              ignore Custody.Oversized_message
            | Error ((Channel_gate.Validation (Gate_protocol.Empty_keeper_name | Empty_channel_user_id | Empty_idempotency_key)
                     | Keeper_error _ | Dispatch_unavailable | Internal _) as error) ->
              Error(Channel_gate.gate_error_to_string error)
          in
          match Channel_gate.validate inbound with
          | Ok () -> submit ()
          | Error Gate_protocol.Empty_content -> ignore Custody.Empty_message
          | Error (Gate_protocol.Content_too_long _) -> ignore Custody.Oversized_message
          | Error ((Gate_protocol.Empty_keeper_name | Empty_channel_user_id | Empty_idempotency_key) as error) ->
            Error (Channel_gate.gate_error_to_string (Channel_gate.Validation error))

module For_testing = struct let accept_update=accept_update end
let start ~sw ~env ~state =
  let clock=Eio.Stdenv.clock env in
  let pause ()=Eio.Time.sleep clock Env_config_runtime_services.Timeouts.maintenance_pulse_interval_sec in
  let config=Mcp_server.workspace_config state in
  let resolve ~channel_id = State.resolve_keeper_for_channel_result ~channel_id
    |> Result.map_error Channel_gate_binding_store.binding_store_error_to_string in
  let dispatch_for_delivery delivery=Gate_keeper_backend.accept_connector ~delivery ~clock ~config in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Switch.check sw;
      match Env_config_telegram.bot_token_opt () with
      | None -> State.record_not_configured ();pause ();loop ()
      | Some token ->
        let result =
          let* client=Api.create ~token |> Result.map_error (fun e->Custody.Api e) in
          let bot_root ~bot_user_id = Filename.concat config.base_path
            (Printf.sprintf ".gate/runtime/telegram/%Ld" bot_user_id) in
          let path ~bot_user_id = Filename.concat (bot_root ~bot_user_id) "cursor.json" in
          let* custody=Custody.open_cursor ~clock ~client ~path () in
          let bot_user_id=Custody.bot_user_id custody in
          let* report=Custody.step ~clock custody ~now:(fun()->Eio.Time.now clock) ~poll_timeout_sec:30
            ~accept:(accept_update ~claim_root:(Filename.concat (bot_root ~bot_user_id) "claims")
              ~resolve ~dispatch_for_delivery ~bot_user_id) () in
          Ok(bot_user_id,report) in
        (match result with
         | Ok(bot_user_id,report) -> State.record_poll_ok ~bot_user_id ~next_offset:report.next_offset
         | Error error ->
           State.record_error(Format.asprintf "%a" Custody.pp_error error);
           (match error with
            | Custody.Api(Api.Api_error {retry_after=Some seconds;_}) -> Eio.Time.sleep clock (float_of_int seconds)
            | Api (Invalid_request _ | Invalid_response _ | Transport_failed | Http_status _ | Api_error {retry_after=None;_})
            | Cursor_refused _ | Acceptance_refused _ | Storage_failed _ -> pause ()));
        loop () in
    let stopped=ref "gateway stopped" in
    Fun.protect ~finally:(fun()->State.record_error !stopped) (fun () ->
      try loop () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        stopped:="gateway failed: " ^ Printexc.exn_slot_name exn;
        Log.Server.error "telegram: %s" !stopped))
