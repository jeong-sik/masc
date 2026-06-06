(** Keeper_chat_slack — Slack delivery adapter for keeper chat events.

    Subscribes to a [Keeper_chat_events] stream, accumulates assistant
    text deltas, and sends the final reply to a Slack channel via the
    Web API when the run finishes.

    @since 2.145.0 *)

type error =
  | Network of string
  | Http_status of { code : int; body : string }
  | Slack_api of { error : string }
  | Other of string

val pp_error : Format.formatter -> error -> unit

val send_message :
  token:string -> channel:string -> content:string -> unit
(** [send_message ~token ~channel ~content] posts to
    [chat.postMessage]. Logs errors via [Log.Keeper.warn]. *)

val adapter_loop :
  token:string ->
  channel:string ->
  events:Keeper_chat_events.keeper_chat_event Eio.Stream.t ->
  unit
(** [adapter_loop ~token ~channel ~events] blocks on the event
    stream until [Run_finished] or [Error], then sends the accumulated
    text (or error message) to the given Slack channel.

    The loop exits after one turn. *)