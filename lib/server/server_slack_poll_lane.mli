(** Server_slack_poll_lane — the in-process Slack collection fiber
    (docs/design/slack-lane.md, task-1418).

    Spawned once during server bootstrap next to the Socket Mode gateway.
    Every poll interval it reads the channel→keeper bindings — the same
    SSOT the gateway routes by — and pulls each bound channel's new
    messages through [conversations.history] into the {!Slack_lane} ring
    buffer. Only plain human-authored top-level messages are collected:
    mentions stay on the socket path (app_mention is the subscribed event),
    and bot/subtype rows are not conversation.

    The cursor (.gate/runtime/slack/poll-cursor.json, channel_id → last
    ts seen) is durable across restarts and advances only over messages
    the fiber actually saw, so a failed cycle retries rather than skips.

    Board posting is deliberately absent here: the external bridge poller
    (jeong-sik/me#1291) owns the digest circuit until the cutover
    described in the design doc, so the two never double-post.

    Off by default: the lane starts only when SLACK_BOT_TOKEN is set and
    [slack] poll_enabled is true in the resolved runtime.toml. A
    present-but-invalid [poll_interval_sec] is a typed configuration
    error and the lane does not start — never a silent default. *)

type poll_config = { interval_sec : float }

type poll_config_load =
  | Poll_disabled
  | Poll_enabled of poll_config

type poll_config_error =
  | Runtime_toml_unreadable of { path : string; detail : string }
  | Runtime_toml_invalid of { path : string; detail : string }
  | Poll_enabled_not_bool of { path : string; expected : string; message : string }
  | Poll_interval_invalid of { path : string; detail : string }

val poll_config_error_to_string : poll_config_error -> string

val load_poll_config :
  path:string -> (poll_config_load, poll_config_error) result
(** Read and validate the poll knobs. Missing file or key is
    {!Poll_disabled}; [poll_enabled = true] without an interval yields the
    900-second default; an interval below 60 seconds is rejected. *)

module For_testing : sig
  val pollable :
    bot_user_id:string option -> Slack_rest_client.history_message -> bool
  (** The collection filter, exposed so tests can pin the contract without
     a live token: plain human top-level messages, mentions excluded (the
     socket path owns them). *)
end

val start :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  state:Mcp_server.server_state ->
  unit
(** Fork the poll fiber. Returns immediately. Warnings, per-channel fetch
    failures (the cursor is held for retry), and a fiber crash are emitted
    via [Log.Server]. Cancellation propagates through [~sw]. *)
