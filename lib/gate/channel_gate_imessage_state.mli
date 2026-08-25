(** Channel_gate_imessage_state — iMessage in-process connector state.

    Implements {!Channel_gate_connector.S} so it can be registered at server
    startup via
    [Channel_gate_connector.register (module Channel_gate_imessage_state)].

    The in-process gateway ({!Server_imessage_in_process_gateway}) is the only
    iMessage transport. It reads Messages.app's SQLite store through
    {!Imessage_chat_db} and replies through {!Imessage_applescript}; there is no
    sidecar and no status file. Liveness is a value this module owns, which is
    the whole reason the connector moved in-process — a value cannot be stale,
    cannot sit at a path nobody reads, and cannot outlive the process that set
    it. *)

include Channel_gate_connector.S

(** {1 Reply routing} *)

type reply_mode =
  | Self_chat
      (** Replies go to the note-to-self conversation, so a keeper answering a
          group chat does not post into it. The default. *)
  | Source_chat  (** Replies go back to the conversation the message came from. *)

val parse_reply_mode : string -> (reply_mode, string) result
(** Parse [MASC_IMESSAGE_REPLY_MODE]. An unrecognised value is an error, not a
    fallback: a typo that silently routed replies to the wrong conversation
    would be visible only to whoever received them. *)

val reply_mode_to_string : reply_mode -> string

val configured_reply_mode : unit -> (reply_mode, string) result
(** {!parse_reply_mode} of the configured value, or {!Self_chat} when unset.
    Unset and unrecognised are different answers. *)

(** {1 In-process gateway support} *)

type keeper_binding_resolution =
  { keeper_name : string
  ; incoming_channel_id : string
  ; bound_channel_id : string
  }

val resolve_keeper_for_channel_result :
  channel_id:string ->
  ( keeper_binding_resolution option
    , Channel_gate_binding_store.binding_store_error )
    result
(** Resolve the keeper bound to [channel_id]. A store read failure stays
    distinct from an unbound conversation. *)

(** Liveness, published by the gateway's poll fiber. Closed sum. *)
type poll_state =
  | Not_started  (** The fiber has not completed a poll yet. *)
  | Polling  (** The most recent poll read chat.db. *)
  | Degraded of string  (** The most recent poll failed; carries the reason. *)

val record_poll_ok : cursor_rowid:int -> unit
(** Called after each successful poll. Publishes liveness and the cursor that
    {!status_json} reports. *)

val record_poll_error : string -> unit
(** Called when a poll fails. The connector reports itself disconnected with
    this reason rather than staying quietly "connected". *)

val record_self_chat_guid : string -> unit
(** Publishes the resolved note-to-self chat handle for {!status_json}, which
    reports it with the addressable tail redacted. *)

val record_startup_error : string -> unit
val clear_startup_error : unit -> unit
(** Record/clear a fail-closed gateway bootstrap error, so an unusable
    configuration does not present as an ordinary disconnected connector. *)

(** {1 Outbound} *)

val reply_target : chat_guid:string option -> (string, string) result
(** The Messages.app chat a reply is addressed to, given the conversation the
    message arrived on. In {!Self_chat} mode that is the resolved note-to-self
    conversation; in {!Source_chat} mode it is [chat_guid]. Returns an error
    when the configured mode has no target, so a reply is refused rather than
    sent to whichever conversation happens to be at hand. *)

val send_message :
  ?timeout_sec:float -> chat_guid:string -> content:string -> unit
  -> (unit, Imessage_applescript.error) result
(** Send one reply through Messages.app. *)
