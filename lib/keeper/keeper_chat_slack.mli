(** Keeper_chat_slack — Slack delivery adapter for keeper chat events.

    Subscribes to a [Keeper_chat_events] stream, accumulates assistant
    text deltas and rich Block Kit blocks, and sends the final reply to
    a Slack channel via the Web API when the run finishes.

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
  ?base_url:string ->
  unit ->
  unit
(** [adapter_loop ~token ~channel ~events ?base_url ()] blocks on the event
    stream until [Run_finished] or [Error], then sends the accumulated
    text (or error message) to the given Slack channel.

    Rich events ([Link_block], [Image_block], [Audio_block],
    [Tool_context_block]) are rendered as Slack Block Kit sections and
    included alongside the final message. [Tool_call_start],
    [Tool_call_args], and [Tool_call_end] are ignored for live streaming.

    [base_url] is used to build public voice-audio URLs; when omitted the
    configured {!Env_config_core.masc_http_base_url} is used.

    The loop exits after one turn. *)

module For_testing : sig
  val public_voice_audio_url : ?base_url:string -> string -> string
  (** [public_voice_audio_url ?base_url token] returns the public URL for
      an audio clip. *)

  val link_block_json :
    url:string -> title:string -> description:string option -> Yojson.Safe.t

  val image_block_json : url:string -> caption:string option -> Yojson.Safe.t

  val audio_block_json :
    base_url:string option -> token:string -> message_text:string -> Yojson.Safe.t

  val tool_context_block_json :
    name:string -> args_summary:string -> result_summary:string option -> Yojson.Safe.t
end
