(** Server_imessage_in_process_gateway — in-process iMessage connector.

    The iMessage sibling of {!Server_discord_in_process_gateway} and
    {!Server_slack_in_process_gateway}. Spawned once during server bootstrap,
    it forks a long-running fiber on the server-wide [Eio.Switch.t] that polls
    Messages.app's SQLite store ({!Imessage_chat_db}) and, for each new inbound
    message in a bound conversation, durably accepts a keeper turn through
    {!Channel_gate.handle_inbound}. Replies go out through
    {!Imessage_applescript}.

    There is no third process. Liveness is the poll itself, published into
    {!Channel_gate_imessage_state} — the sidecar this replaces kept liveness in
    a file, and every one of its four defects on 2026-08-16 came from that.

    Off unless Messages.app's store is readable: on a machine with no chat.db,
    or without Full Disk Access, [start] records the reason, logs it, and skips.
    The server boots normally. That is also what keeps this harmless on Linux,
    where the file never exists.

    Unlike the other two connectors this one cannot edit a sent message, so a
    keeper reply is delivered once, whole, at the end of the run rather than
    streamed. *)

val default_poll_interval_sec : float
(** Cadence used when [MASC_IMESSAGE_POLL_INTERVAL_SEC] is unset. *)


val resolved_poll_interval_sec : unit -> (float, string) result
(** The configured cadence, or an error. An unparseable or out-of-range value
    is refused rather than silently replaced by the default. *)

(** What to do with the cursor after one row has been handled. *)
type disposition =
  | Consume
      (** The row reached a terminal state — accepted, permanently invalid, or
          addressed to no keeper. The cursor advances past it. *)
  | Retry of string
      (** The accept could not be attempted. The cursor stays put and the rest
          of the batch is left for the next poll, because rows are delivered in
          [ROWID] order and skipping one would reorder the conversation. *)

module For_testing : sig
  val cursor_to_json : int -> string
  val cursor_of_json : string -> (int, string) result
  (** Codec for the durable [ROWID] cursor. A malformed file is an error, not a
      silent restart from zero — that would redeliver the whole history. *)

  val conversation_id : chat_identifier:string -> string

  val inbound_message_of_row :
    keeper_name:string -> Imessage_chat_db.inbound_row -> Channel_gate.inbound_message
  (** Pure projection from a chat.db row to the gate's wire type. *)

  val disposition_of_outcome :
    (Channel_gate.outbound_message, Channel_gate.gate_error) result -> disposition
  (** Pure cursor decision. This is the at-least-once boundary: the mapping
      from a gate outcome to "advance" or "leave it" is the whole delivery
      guarantee, so it is a function that can be tested rather than a shape
      buried in the loop. *)
end

val start :
  sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> state:Mcp_server.server_state -> unit
(** Fork the gateway fiber. Returns immediately. Cancellation propagates
    through [~sw]. *)
