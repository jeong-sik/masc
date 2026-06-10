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

type gateway_event = Discord_gateway_state.dispatched_event =
  | Ready of
      { session_id : string
      ; resume_gateway_url : string
      ; bot_user_id : string
      }
  | Message_create of
      { channel_id : string
      ; message_id : string
      ; author_id : string
      ; author_name : string option
      ; content : string
      ; mentions_bot : bool
      }
  | Reaction_add of
      { channel_id : string
      ; message_id : string
      ; user_id : string
      ; emoji : string
      }
  | Ignored of string

type trigger_policy = Discord_gateway_state.trigger_policy =
  | Mention_only
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
  unit ->
  unit
(** Connect to Discord Gateway, identify with [intents], dispatch
    events that pass [trigger_policy] to [on_event]. Blocks until
    [sw] is closed.

    Internally:
    1. Create {!Discord_gateway_state.t} with [trigger_policy].
    2. Open WSS, fork heartbeat fiber, read loop.
    3. For each frame: parse → [Frame_received] → [step] → run
       returned effects (one of which is [Emit_event _] when the
       state machine decides the event passes [trigger_policy]).
    4. On [Close_wss] effect: tear down, reschedule per backoff.

    @raise Failure until Phase 1.2 ships the implementation. *)
