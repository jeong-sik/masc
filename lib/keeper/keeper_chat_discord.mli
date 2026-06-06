(** Keeper_chat_discord — Discord delivery adapter for keeper chat events.

    Subscribes to a [Keeper_chat_events] stream, accumulates assistant
    text deltas, and sends the final reply to a Discord channel via the
    REST API when the run finishes.

    @since 2.145.0 *)

val send_message :
  token:string -> channel_id:string -> content:string -> unit
(** [send_message ~token ~channel_id ~content] posts to Discord.
    Errors are logged as warnings but never raised.
    The content is truncated to Discord's 2000-character limit. *)

val adapter_loop :
  token:string ->
  channel_id:string ->
  events:Keeper_chat_events.keeper_chat_event Eio.Stream.t ->
  unit
(** [adapter_loop ~token ~channel_id ~events] blocks on the event
    stream until [Run_finished] or [Error], then sends the accumulated
    text (or error message) to the given Discord channel.

    The loop exits after one turn; the caller must restart it for
    subsequent turns. *)