(** Keeper_chat_slack — Slack delivery adapter for keeper chat events.

    Subscribes to a [Keeper_chat_events] stream, accumulates assistant
    text deltas and rich Block Kit blocks, and incrementally edits one Slack
    reply before committing the final content when the run finishes. When the reply
    belongs to a thread, the production adapter projects active work through
    Slack's native assistant thread status.

    @since 2.145.0 *)

type error =
  | Network of string
  | Http_status of { code : int; body : string }
  | Slack_api of { error : string }
  | Other of string

val pp_error : Format.formatter -> error -> unit

val effect_disposition : error -> Tool_result.failure_effect_disposition
(** [effect_disposition error] states what the Slack transport proves about
    the requested send. Slack answers every Web API call with HTTP 200 and
    [{ ok, error? }] (RFC-0317, {!Slack_rest_client}), so [Slack_api] is a
    logical refusal of a request Slack fully received and declined to act on
    — the message was not posted. Callers turn this into
    {!Tool_result.Proven_pre_effect} so the refusal stays correctable inside
    the provider turn instead of reaching the terminal effect boundary. *)

val send_message_with_blocks :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  ?thread_ts:string ->
  ?mention_user_ids:string list ->
  token:string -> channel:string -> content:string -> blocks:Yojson.Safe.t list -> unit -> (unit, error) result
(** [send_message_with_blocks ~token ~channel ~content ~blocks] posts to
    [chat.postMessage] with the given Block Kit [blocks]. Stable Slack ids in
    [mention_user_ids] are emitted both in the accessible fallback and the
    visible blocks assembled by the caller. Logs errors via [Log.Keeper.warn]
    and returns the outcome. *)

val message_blocks_of_text :
  mention_user_ids:string list -> string -> Yojson.Safe.t list
(** Prepend one visible mrkdwn mention section to
    {!content_blocks_of_text}. Ids must already have passed the surface-post
    validator. *)

val adapter_loop :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  token:string ->
  channel:string ->
  ?thread_ts:string ->
  events:Keeper_chat_events.t ->
  ?base_url:string ->
  ?on_send_result:((unit, error) result -> unit) ->
  unit ->
  unit
(** [adapter_loop ~token ~channel ~events ?base_url ?on_send_result ()]
    blocks on the event stream until [Run_finished] or [Error]. Stable text
    creates one Slack message and updates that same message no more frequently
    than Slack's documented streaming interval; terminal delivery commits the
    complete text and rich blocks to the same message.

    Rich events ([Link_block], [Image_block], [Status_block], [Audio_block])
    are rendered as Slack Block Kit sections and included alongside the final
    message. [Tool_call_start], [Tool_call_args], [Tool_call_args_snapshot],
    and [Tool_call_end] create no message of their own: they show as native
    activity while the run is open, and {!Keeper_chat_tool_trail} collects them
    into one fenced block appended to the terminal reply, so the delivered
    message names the work the turn did. That block carries each call's name and
    the one argument it acted on -- a path, a command, a search pattern -- which
    a channel with readers beyond the keeper's operator should be bound with in
    mind. [Tool_context_block] stays out of the conversation entirely: its
    summaries are the tool's own account of itself, not the call's identity.

    [base_url] is used to build public voice-audio URLs; when omitted the
    configured {!Env_config_core.masc_http_base_url} is used.

    [on_send_result] is invoked exactly once for the terminal
    [Run_finished]/[Event_error] delivery. Interim protocol diagnostics do not
    settle the callback, so an earlier diagnostic cannot hide a later final
    send failure. Empty terminal output reports a typed [Other] error. The
    callback defaults to a no-op.

    The loop exits after one turn. *)

module For_testing : sig
  val escape_mrkdwn_text : string -> string

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

  val content_blocks_of_text : string -> Yojson.Safe.t list
  (** Same as {!content_blocks_of_text}; exposed for unit testing. *)

  val message_blocks_of_text :
    mention_user_ids:string list -> string -> Yojson.Safe.t list

  val final_message_blocks :
    content:string -> event_blocks:Yojson.Safe.t list -> Yojson.Safe.t list
  (** Merge text-derived blocks with explicitly emitted rich event blocks in
      final delivery order. *)

  val build_message_body :
    channel:string ->
    content:string ->
    blocks:Yojson.Safe.t list ->
    ?thread_ts:string ->
    unit ->
    string
  (** Pure chat.postMessage JSON builder used to prove deferred replies retain
      the originating Slack thread. *)

  val build_thread_status_body :
    channel:string -> thread_ts:string -> status:string -> string
  (** Pure [assistant.threads.setStatus] JSON builder. *)

  val adapter_loop :
    events:Keeper_chat_events.t ->
    ?post_stream:(content:string -> (string, error) result) ->
    ?edit_stream:(message_id:string -> content:string -> (unit, error) result) ->
    ?edit_blocks:
      (message_id:string ->
       content:string ->
       blocks:Yojson.Safe.t list ->
       (unit, error) result) ->
    ?delete_stream:(message_id:string -> (unit, error) result) ->
    ?now:(unit -> float) ->
    ?sleep:(float -> unit) ->
    send_plain:(content:string -> (unit, error) result) ->
    send_blocks:(content:string -> blocks:Yojson.Safe.t list -> (unit, error) result) ->
    ?set_activity_status:(status:string -> (unit, error) result) ->
    ?base_url:string ->
    ?on_send_result:((unit, error) result -> unit) ->
    unit ->
    unit
  (** Test seam for the outbound transport. [post_stream], [edit_stream],
      [edit_blocks], and [delete_stream] are supplied together to exercise
      incremental delivery. [now] and [sleep] make update pacing deterministic.
      Activity failures never settle terminal delivery. *)
end
