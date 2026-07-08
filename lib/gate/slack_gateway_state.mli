(** Slack_gateway_state — pure state machine for the Slack Socket Mode lifecycle.

    Zero I/O. All inputs are typed (parsed envelopes + supervision signals); all
    outputs are typed [gateway_effect]s that the I/O layer ([Slack_socket_client])
    interprets.

    This mirrors {!Discord_gateway_state} but is simpler: Slack Socket Mode has no
    client-sent heartbeat opcode (the ws-direct endpoint auto-replies to RFC 6455
    Ping frames), no resume (reconnect is always a fresh [apps.connections.open]
    → new WSS URL), and no identify frame (the WSS URL from
    [apps.connections.open] already carries the app-level token). What Slack adds
    is a per-envelope ack: each envelope received must be answered with a
    [Send_ack of {envelope_id}] or Slack will retransmit and eventually drop the
    connection.

    See: docs/rfc/RFC-0xxx-slack-builtin-gateway.md (and RFC-0203 for the
    Discord original this is modeled on). *)

(** {1 Envelope — what comes off the wire} *)

(** The Slack Socket Mode envelope [{type}] field. Closed sum of what we handle;
    unknown types surface as {!Envelope_parse_error}, never a catch-all. *)
type envelope_kind =
  | Hello_env              (** [type: "hello"] — sent once on connect. *)
  | Events_api_env         (** [type: "events_api"] — [payload.event] is the real event. *)
  | Disconnect_env of { reason : string }  (** [type: "disconnect"] — must reconnect. *)
  | Reconnect_env          (** [type: "reconnect"] — Slack asks for a fresh connection. *)
  | Ignored_env of string  (** Known envelope type we don't act on (slash_commands, interactive). *)

(** A Slack event inside an [events_api] envelope ([payload.event]). Closed sum of
    the events this gateway surfaces to the caller; others are {!Ignored_event}. *)
type slack_event =
  | Message_create of
      { channel_id : string
      ; thread_ts : string option
      ; user_id : string
      ; user_name : string option
      ; text : string
      ; ts : string
      ; mentions_bot : bool
      ; bot_id : string option  (** Set when the author is a bot/app — suppresses loop-prone turns. *)
      }
  | App_mention of
      { channel_id : string
      ; thread_ts : string option
      ; user_id : string
      ; text : string
      ; ts : string
      }
  | Reaction_added of
      { channel_id : string
      ; message_ts : string
      ; user_id : string
      ; reaction : string
      }
  | Ignored_event of string  (** Known event type we deliberately don't surface. *)

(** An envelope after JSON parse. [envelope_id] is present on every envelope that
    needs an ack (everything except [Hello_env]). [event] is [Some] only for
    [Events_api_env]. *)
type envelope =
  { kind : envelope_kind
  ; envelope_id : string option
  ; event : slack_event option
  }

(** {1 Connection lifecycle states} *)

(** Where we are in the connection's life. Closed sum.

    Transition diagram (only legal transitions exist):
    {v
        Disconnected --[connect_requested]--> Awaiting_hello
        Awaiting_hello --[hello envelope]--> Connected
        Connected --[disconnect/reconnect/wss_closed]--> Reconnect_pending
        Reconnect_pending --[backoff_elapsed]--> Awaiting_hello
        any --[fatal]--> Failed
    v}

    No [Resuming]/[Identifying]: Slack reconnect is always a fresh
    [apps.connections.open] → new WSS → new [hello], never a resume of a prior
    session. *)
type connection_state =
  | Disconnected
  | Awaiting_hello     (** WSS connected, waiting for [hello] envelope. *)
  | Connected
  | Reconnect_pending of { backoff_until_mono : float; reason : string }
  | Failed of string   (** Non-recoverable. Supervisor escalates. *)

(** {1 Input — what feeds the state machine} *)

type input =
  | Connect_requested             (** External: start a connection. *)
  | Apps_connections_open_succeeded of { url : string }
      (** [POST apps.connections.open] returned a fresh WSS URL — open it. *)
  | Apps_connections_open_failed of { reason : string }
      (** The URL-fetch HTTP call failed (transport / non-200 / malformed JSON). *)
  | Envelope_received of envelope
  | Envelope_parse_error of string
      (** Decoded JSON, failed schema — log and continue, do not crash the reader. *)
  | Wss_closed of { reason : string }
  | Backoff_elapsed                (** Reconnect timer fired. *)

(** {1 Output — what the state machine asks the I/O layer to do} *)

(** Side effects the I/O layer must perform. Closed sum.

    Named [gateway_effect] (not [effect]) because [effect] is reserved in OCaml 5. *)
type gateway_effect =
  | Apps_connections_open          (** Fetch a fresh WSS URL (app-level token, [get_sync]). *)
  | Open_wss of { url : string }
  | Close_wss
  | Send_ack of { envelope_id : string }
      (** Ack an envelope — Slack retransmits + eventually drops without it. *)
  | Emit_event of slack_event      (** Surface to the caller's [on_event]. *)
  | Schedule_backoff of { delay_ms : int }
  | Log of { level : [ `Info | `Warn | `Error ]; message : string }

(** {1 Configuration} *)

type trigger_policy =
  | Mention_only
  | Mention_or_thread   (** Mention in channels, auto-respond in Slack threads ([thread_ts] present). *)
  | User_only of string (** Slack user id. *)
  | All

val parse_trigger_policy : string -> (trigger_policy, string) result
(** Decodes the [MASC_SLACK_TRIGGER_POLICY] env value. Accepts exactly
    ["mention_only"], ["mention_or_thread"], ["user_only:<id>"], ["all"]. *)

val trigger_policy_to_string : trigger_policy -> string

type config =
  { trigger_policy : trigger_policy
  ; bot_user_id : string option   (** The bot's own Slack user id, for [mentions_bot]. *)
  }

(** {1 The state machine itself} *)

type t

val create : config:config -> t
val state : t -> connection_state
val config : t -> config

val step : t -> now_mono:float -> input -> t * gateway_effect list
(** Pure transition. Given the current state and an input, returns the new state
    and the effects the I/O layer must run, in order.

    - [now_mono] is the monotonic clock at input arrival, used for reconnect
      backoff deadlines.
    - The effect list may be empty; never raises.
    - Reentrant. No global state.

    Every [Envelope_received] of a kind carrying [envelope_id] produces a
    [Send_ack] effect alongside any [Emit_event], so the I/O layer cannot forget
    to ack. *)

(** {1 Envelope parsing — what the I/O layer calls before [step]} *)

val parse_envelope : bot_user_id:string option -> Yojson.Safe.t -> (envelope, string) result
(** Parse a Slack Socket Mode JSON envelope into a typed {!envelope}. Rejects
    unknown [{type}] values as [Error] (caller feeds [Envelope_parse_error] to
    [step]). For [events_api], decodes [payload.event] into a {!slack_event};
    [bot_user_id] drives [Message_create.mentions_bot]. *)

(** {1 Decoding events — exposed for unit tests} *)

val decode_event :
  bot_user_id:string option -> event_type:string -> payload:Yojson.Safe.t -> (slack_event, string) result
(** Decode an [events_api] event by [event.type]. Unknown types return
    [Ok (Ignored_event name)] — known unknowns, not a silent swallow. *)
