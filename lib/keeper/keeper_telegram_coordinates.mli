(** One projection from typed Telegram route coordinates to the generic Gate
    surface. Used by ingress and source validation so no address field is lost. *)
val conversation_id : bot_user_id:int64 -> chat_id:int64 -> message_thread_id:int option -> direct_messages_topic_id:int64 option -> string
val surface : bot_user_id:int64 -> chat_id:int64 -> message_thread_id:int option -> direct_messages_topic_id:int64 option -> reply_to_message_id:int option -> Surface_ref.t

val matches_surface : bot_user_id:int64 -> chat_id:int64 -> message_thread_id:int option -> direct_messages_topic_id:int64 option -> reply_to_message_id:int option -> Surface_ref.t -> bool
(** Exact coordinate-map equality, independent of JSON object key order.
    Duplicate, missing and unknown coordinates cannot equal the complete route. *)
