(** Server_slack_poll_lane — the in-process Slack collection fiber
    (docs/design/slack-poll-checkpoints.md).

    Spawned once during server bootstrap next to the Socket Mode gateway.
    Every poll interval it reads the channel→keeper bindings — the same
    SSOT the gateway routes by — and pulls each bound channel's new
    messages through [conversations.history] into the {!Slack_lane} ring
    buffer. Only plain human-authored top-level messages are collected:
    mentions stay on the socket path (app_mention is the subscribed event),
    and bot/subtype rows are not conversation.

    The checkpoint holds either a committed high-water mark, an unfinished
    time window with staged messages, or a completed window awaiting publication.
    Pagination moves latest backwards while oldest stays fixed. A cycle cap
    yields to other channels without discarding its checkpoint. Only a completed,
    published window advances high-water. Failed writes or fetches leave the
    previous checkpoint replayable; unreadable checkpoints refuse collection.
    Slack_lane remains a bounded in-memory recent-message view, not an archive.

    This optional REST reader is independent of the Browser-based Slack TUI.
    It publishes observations to Slack_lane and sends no Slack or Board messages.

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
     socket path owns them), legacy [<@id|label>] mention rendering
     included. *)

  type checkpoint
  type collect_error = Fetch_failed of string | Checkpoint_failed of string | Page_invalid of string
  val idle : string -> checkpoint
  val high_water : checkpoint -> string
  val encode : checkpoint -> Yojson.Safe.t
  val decode : Yojson.Safe.t -> (checkpoint, string) result
  val read_checkpoints : path:string -> ((string * checkpoint) list, string) result
  val collect :
    now:float ->
    cursor:checkpoint option ->
    fetch:(oldest:string -> latest:string -> (Slack_rest_client.conversations_history_ok, string) result) ->
    save:(checkpoint -> (unit, string) result) ->
    publish:(Slack_rest_client.history_message list -> unit) ->
    (unit, collect_error) result
  (** The real per-channel cycle with injected I/O. Every successful page is
      checkpointed; a completed window is checkpointed before publication. *)

end

val start :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  state:Mcp_server.server_state ->
  unit
(** Fork the poll fiber. Returns immediately. Warnings, per-channel fetch
    failures (the cursor is held for retry), and a fiber crash are emitted
    via [Log.Server]. Cancellation propagates through [~sw]. *)
