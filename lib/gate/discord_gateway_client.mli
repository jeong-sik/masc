(** Discord_gateway_client — I/O layer that drives
    {!Discord_gateway_state}.

    Thin wrapper: open WSS, parse frames, hand them to
    {!Discord_gateway_state.step}, run the returned effects, repeat.
    All correctness lives in the pure state machine; this module
    only translates between bytes and typed inputs/effects.

    Phase 1.1 (RFC-0203): typed surface only. {!run} raises until
    Phase 1.2 ships the WSS handshake.

    See: docs/rfc/RFC-0203-discord-builtin-gateway.md *)

(** Re-export the public-facing types so callers don't reach into
    the state machine module directly. *)

type intent = Discord_gateway_state.intent =
  | Guilds
  | Guild_messages
  | Message_content
  | Guild_message_reactions
  | Direct_messages
  | Direct_message_reactions

type mention_kind = Discord_gateway_state.mention_kind =
  | User_mention
  | Role_mention
  | Channel_mention

type resolved_mention = Discord_gateway_state.resolved_mention =
  { mention_id : string
  ; mention_name : string option
  ; mention_kind : mention_kind
  ; raw_mention : string
  }

type gateway_event = Discord_gateway_state.dispatched_event =
  | Ready of
      { session_id : string
      ; resume_gateway_url : string
      ; bot_user_id : string
      }
  | Message_create of
      { channel_id : string
      ; guild_id : string option
      ; message_id : string
      ; author_id : string
      ; author_name : string option
      ; content : string
      ; raw_content : string
      ; resolved_mentions : resolved_mention list
      ; mention_user_ids : string list
      ; mentions_bot : bool
      ; explicit_mentions_bot : bool
      ; author_is_bot : bool
      ; message_reference_channel_id : string option
      ; message_reference_message_id : string option
      ; referenced_message_author_id : string option
      }
  | Reaction_add of
      { channel_id : string
      ; message_id : string
      ; user_id : string
      ; emoji : string
      }
  | Thread_tracked of
      { thread_id : string
      ; parent_channel_id : string
      }
  | Threads_bulk_tracked of
      { threads : (string * string) list
      }
  | Thread_removed of
      { thread_id : string
      }
  | Ignored of string

type trigger_policy = Discord_gateway_state.trigger_policy =
  | Mention_only
  | Mention_or_thread
  | User_only of string
  | All

val intents_bitmask : intent list -> int

(** {1 Run loop} *)

val run :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  token:string ->
  intents:intent list ->
  trigger_policy:trigger_policy ->
  on_event:(gateway_event -> unit) ->
  on_ambient:(gateway_event -> unit) ->
  unit ->
  unit
(** Connect to Discord Gateway, identify with [intents], dispatch
    events that pass [trigger_policy] to [on_event]. Blocks until
    [sw] is closed.

    [on_ambient] receives [Message_create] events that fail
    [trigger_policy] but are not the bot's own echo (RFC-0226):
    record-only delivery — the handler persists the line to the bound
    keeper's lane history and must not start a turn.

    Internally:
    1. Create {!Discord_gateway_state.t} with [trigger_policy].
    2. Open WSS, fork heartbeat fiber, read loop.
    3. For each frame: parse → [Frame_received] → [step] → run
       returned effects (one of which is [Emit_event _] when the
       state machine decides the event passes [trigger_policy]).
    4. On [Close_wss] effect: tear down, reschedule per backoff.

    @raise Failure until Phase 1.2 ships the implementation. *)

(** {1 Connection state (RFC-0223 P2)} *)

val connection_state : unit -> Discord_gateway_state.connection_state
(** Last connection state published by the {!run} loop's state machine.
    [Disconnected] until [run] has started. One gateway per process
    (single bot token); written only by [run], safe to read from any
    fiber. Feeds connector presence ([Channel_gate_discord_state]). *)

val set_presence : Discord_gateway_state.presence_status -> unit
(** [set_presence status] pushes a [Status_change] input into the
    gateway's drive loop. When connected, the bot's Discord presence
    updates immediately (online/idle/dnd/invisible). When disconnected,
    the request is logged and dropped.

    Thread-safe: may be called from any fiber. *)

module For_testing : sig
  val reader_should_continue_after_input :
    Discord_gateway_state.input -> bool
end
