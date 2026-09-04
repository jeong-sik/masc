(** Keeper_chat_discord — Discord delivery adapter for keeper chat events.

    Streaming mode: the first stable text segment POST creates the Discord
    message. Subsequent deltas PATCH the message at most once per
    {!min_edit_interval_s} (Discord rate limit: 5 edits / 5 s).
    [Text_message_end] and [Run_finished] force a final PATCH so the
    user always sees the complete text. Streaming PATCH/POST content
    holds back the current trailing non-whitespace segment until a
    delimiter arrives, so partial secret-like tokens are not published
    before the redactor can see the complete token.

    While the run is active, the production adapter refreshes Discord's
    native typing indicator. Tool lifecycle events refresh that indicator
    but never create standalone tool messages: {!Keeper_chat_tool_trail}
    collects them into one fenced block appended to the final reply instead.
    That block carries each call's name and the one argument it acted on -- a
    path, a command, a search pattern -- which a channel with readers beyond
    the keeper's operator should be bound with in mind.

    @since 2.145.0 *)

val min_edit_interval_s : float
(** Minimum seconds between PATCH edits (default 1.0). *)

type error = Discord_rest_client.error

val pp_error : Format.formatter -> error -> unit

val send_message :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  token:string -> channel_id:string -> content:string -> unit -> (unit, error) result
(** [send_message ~token ~channel_id ~content] posts to Discord.
    Errors are logged as warnings and returned to the caller.
    Content exceeding Discord's 2000-character limit is split into
    multiple messages. All chunks are attempted; the first failure is
    returned after the remaining chunks have been attempted. *)

val adapter_loop :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  token:string ->
  channel_id:string ->
  events:Keeper_chat_events.t ->
  ?base_url:string ->
  ?on_send_result:((unit, error) result -> unit) ->
  unit ->
  unit
(** [adapter_loop ~token ~channel_id ~events ?base_url ?on_send_result ()]
    subscribes to the
    event stream and delivers text to Discord in real time:
    - [Text_delta] (first stable segment): POST creates the message,
      stores its id.
    - [Text_delta] (subsequent): PATCH edits the message content, at most
      once per {!min_edit_interval_s}.
    - [Text_message_end]: force PATCH if content changed since last edit.
    - [Run_finished]: force final PATCH with complete text.
      Standalone links, images, code, and Mermaid blocks in the final text
      are also projected into Discord embeds using the shared server
      chat-block parser.
    - [Event_error]: sends error text as a new message.
    - [Link_block], [Image_block], [Audio_block]: send rich block embeds
    - [Status_block]: replace the terminal assistant text with typed status UI
      or messages.
    - [Tool_call_start], [Tool_call_args], [Tool_call_args_snapshot],
      [Tool_call_end]: no message of their own; activity stays on Discord's
      native typing surface and the calls are appended to the final reply as
      one {!Keeper_chat_tool_trail} block. [Tool_context_block] is not
      projected at all.

    [base_url] is used to build public voice-audio URLs; when omitted the
    configured {!Env_config_core.masc_http_base_url} is used.

    Falls back to a single POST if no deltas arrive before [Run_finished].

    [on_send_result] is invoked exactly once when the turn terminates through
    [Run_finished] or [Event_error]. The result reports whether the primary
    final text/error reply was actually delivered: the final PATCH plus every
    overflow POST must succeed. Streaming previews, tool embeds, and other rich
    side messages do not produce terminal callback invocations. The callback
    defaults to a no-op.

    The loop exits after one turn; the caller must restart it for
    subsequent turns. *)

module For_testing : sig
  val streaming_patch_content : string -> string
  (** Redacted, Discord-sized content suitable for streaming POST/PATCH.
      The current trailing non-whitespace segment is withheld. *)

  val final_head_and_overflow : string -> string * string option
  (** Redacted final content split into the first Discord message body and
      optional overflow for follow-up chunked delivery. *)

  val public_voice_audio_url : ?base_url:string -> string -> string
  (** [public_voice_audio_url ?base_url token] returns the public URL for
      an audio clip. Exposed for testing. *)

  val rich_embeds_of_text : string -> Discord_rest_client.embed list
  (** Project text-derived server chat blocks into Discord embeds. Text,
      list/callout/table, trace, and thinking blocks are omitted because
      the text message already carries the reply. Image/link/audio/fusion
      cards use existing channel-native projection paths; code and Mermaid
      are rendered into embeds for richer Discord delivery. *)

  val adapter_loop :
    token:string ->
    channel_id:string ->
    events:Keeper_chat_events.t ->
    post_message:(content:string -> (string, error) result) ->
    edit_message:(message_id:string -> content:string -> (unit, error) result) ->
    send_message:(content:string -> (unit, error) result) ->
    ?show_activity:(unit -> (unit, error) result) ->
    ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
    ?base_url:string ->
    ?now:(unit -> float) ->
    ?on_send_result:((unit, error) result -> unit) ->
    unit ->
    unit
  (** Test seam for the text-delivery and activity transports. Production uses
      {!Discord_rest_client}; tests can inject exact POST/PATCH outcomes while
      exercising the real event-loop state machine. [show_activity] represents
      one native typing refresh; its failure is observational and never settles
      [on_send_result]. [now] makes edit pacing deterministic. Rich
      side-message helpers remain production-backed and should not be emitted
      by transport tests. *)
end
