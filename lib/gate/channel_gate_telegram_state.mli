(** Telegram connector state owned by the native poll loop; no sidecar status
    file or heartbeat age is used as liveness. Bindings use the shared store. *)
include Channel_gate_connector.S
val resolve_keeper_for_channel_result : channel_id:string -> (string option, Channel_gate_binding_store.binding_store_error) result
val record_poll_ok : bot_user_id:int64 -> next_offset:int64 option -> unit
val record_error : string -> unit
val record_not_configured : unit -> unit
val chunks : string -> (string list, Telegram_rest_client.error) result
(** Lossless UTF-8 chunks within Telegram's documented text limit. *)
type send_error =
  | Api_failure of Telegram_rest_client.error
  | Partial_delivery of {sent_messages:(int64 * int) list;cause:Telegram_rest_client.error}
val pp_send_error : Format.formatter -> send_error -> unit
val send_message :
  ?post:Telegram_rest_client.post -> clock:[> float Eio.Time.clock_ty] Eio.Resource.t ->
  bot_user_id:int64 -> chat_id:int64 -> message_thread_id:int option -> direct_messages_topic_id:int64 option ->
  reply_to_message_id:int option -> html:bool -> messages:string list -> unit -> (unit, send_error) result
(** Resolve the current credential and verify getMe against the persisted bot
    route before any send. [messages] are prepared chunks with complete formatting;
    an empty list is refused. Partial successes retain their message IDs. Retry only typed API refusal with retry_after; a
    transport uncertainty is returned, never blindly sent again. *)
