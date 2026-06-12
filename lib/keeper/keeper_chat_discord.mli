(** Keeper_chat_discord — Discord delivery adapter for keeper chat events.

    Streaming mode: on the first [Text_delta], POST creates the Discord
    message.  Subsequent deltas PATCH the message at most once per
    {!min_edit_interval_s} (Discord rate limit: 5 edits / 5 s).
    [Text_message_end] and [Run_finished] force a final PATCH so the
    user always sees the complete text.

    @since 2.145.0 *)

val min_edit_interval_s : float
(** Minimum seconds between PATCH edits (default 1.0). *)

val send_message :
  token:string -> channel_id:string -> content:string -> unit
(** [send_message ~token ~channel_id ~content] posts to Discord.
    Errors are logged as warnings but never raised.
    Content exceeding Discord's 2000-character limit is split into
    multiple messages. *)

val adapter_loop :
  token:string ->
  channel_id:string ->
  events:Keeper_chat_events.keeper_chat_event Eio.Stream.t ->
  unit
(** [adapter_loop ~token ~channel_id ~events] subscribes to the event
    stream and delivers text to Discord in real time:
    - [Text_delta] (first): POST creates the message, stores its id.
    - [Text_delta] (subsequent): PATCH edits the message content, at most
      once per {!min_edit_interval_s}.
    - [Text_message_end]: force PATCH if content changed since last edit.
    - [Run_finished]: force final PATCH with complete text.
    - [Event_error]: sends error text as a new message.

    Falls back to a single POST if no deltas arrive before [Run_finished].

    The loop exits after one turn; the caller must restart it for
    subsequent turns. *)
