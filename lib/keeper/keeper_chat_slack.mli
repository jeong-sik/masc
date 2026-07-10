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
  token:string -> channel:string -> content:string -> (unit, error) result
(** [send_message ~token ~channel ~content] posts to
    [chat.postMessage]. Logs errors via [Log.Keeper.warn] and returns the
    outcome. *)

val send_message_with_blocks :
  token:string -> channel:string -> content:string -> blocks:Yojson.Safe.t list -> (unit, error) result
(** [send_message_with_blocks ~token ~channel ~content ~blocks] posts to
    [chat.postMessage] with the given Block Kit [blocks]. Logs errors via
    [Log.Keeper.warn] and returns the outcome. *)

val content_blocks_of_text : string -> Yojson.Safe.t list
(** [content_blocks_of_text text] projects server chat blocks into Slack
    Block Kit blocks:
    - Markdown images [![alt](url)] become image blocks.
    - Standalone image URLs (png/jpg/gif/webp/svg) become image blocks.
    - Other standalone URLs become link blocks with a hostname-derived title.
    Code and Mermaid fences become section code-block sections.
    Text and most other block kinds are omitted because primary text is
    already delivered via the [content] field; fusion cards also have no
    Slack-native projection yet. *)

val adapter_loop :
  token:string ->
  channel:string ->
  events:Keeper_chat_events.keeper_chat_event Eio.Stream.t ->
  ?base_url:string ->
  ?on_send_result:((unit, error) result -> unit) ->
  unit ->
  unit
(** [adapter_loop ~token ~channel ~events ?base_url ?on_send_result ()]
    blocks on the event stream until [Run_finished] or [Error], then sends
    the accumulated text (or error message) to the given Slack channel.

    Rich events ([Link_block], [Image_block], [Audio_block],
    [Tool_context_block]) are rendered as Slack Block Kit sections and
    included alongside the final message. [Tool_call_start],
    [Tool_call_args], [Tool_call_args_snapshot], and [Tool_call_end] are
    ignored for live streaming.

    [base_url] is used to build public voice-audio URLs; when omitted the
    configured {!Env_config_core.masc_http_base_url} is used.

    [on_send_result] is invoked once per outbound attempt with the send
    outcome, so callers (e.g. the connector gateway) can record delivery
    observability without this adapter depending on any metric sink. It
    defaults to a no-op to preserve existing behavior.

    The loop exits after one turn. *)

module For_testing : sig
  val escape_mrkdwn_text : string -> string
  val markdown_to_mrkdwn : string -> string

  val truncate_to_limit : string -> int -> string

  val limit_blocks_for_slack : Yojson.Safe.t list -> Yojson.Safe.t list

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

  val content_blocks_of_text : string -> Yojson.Safe.t list
  (** Same as {!content_blocks_of_text}; exposed for unit testing. *)

  val final_message_blocks :
    content:string -> event_blocks:Yojson.Safe.t list -> Yojson.Safe.t list
  (** Merge text-derived blocks with explicitly emitted rich event blocks in
      final delivery order. *)
end
