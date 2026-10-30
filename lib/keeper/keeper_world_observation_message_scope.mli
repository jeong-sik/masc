(** Message-scope helpers for keeper world observation. *)

open Keeper_meta_contract
open Keeper_types_profile

val message_feed_targets : keeper_meta -> string list

val self_ids : keeper_meta -> Keeper_identity.Keeper_id.t list
(** The keeper's own identities, minted from [meta.name] and
    [meta.agent_name] at the parse boundary (RFC-0232 §3.4).  Usually a
    single canonical id; at most two. *)

val is_self_author
  :  self_ids:Keeper_identity.Keeper_id.t list
  -> string
  -> bool
(** [is_self_author ~self_ids author] mints [author]'s id and compares
    with {!Keeper_identity.Keeper_id.equal} — the single source of truth
    for "is this author one of us?". *)

type pending_kind =
  | Mention
  | Scope

type pending_message = {
  message_id : string;
  speaker : string;
  content : string;
  kind : pending_kind;
}
(** One unacknowledged lane row. Stable [message_id] is the exact durable
    acknowledgement cursor; list order is persisted source order. *)

type fleet_message = {
  fleet_speaker : string;
  fleet_content : string;
}
(** One keeper broadcast projected into this keeper's transcript. No message
    id: the layer carries no acknowledgement cursor, so nothing keys off row
    identity. List order is persisted source order. *)

val pairs_of_kind : pending_kind -> pending_message list -> (string * string) list
val has_kind : pending_kind -> pending_message list -> bool

type direct_line_role =
  | User
  | Assistant
  | Tool_call
(** RFC-0232 P1: closed-sum role for a direct-conversation line, replacing the
    former [role_label : string]. The renderer derives the display label from
    this via {!direct_line_role_to_label}; no consumer re-derives semantics
    from a free string. *)

val direct_line_role_to_label : direct_line_role -> string
(** Display vocabulary SSOT: [User -> "user"], [Assistant -> "assistant"],
    [Tool_call -> "tool_call"]. *)

type recent_direct_line = {
  role : direct_line_role;
  speaker_label : string option;
  content : string;
}
(** Bounded transcript line for direct-chat continuity. Tool rows retain
    only the call name; assistant transport failures are omitted because
    they are server failures, not keeper utterances. Assistant rows carrying
    synthesized voice audio are also omitted from this prompt context so the
    keeper does not quote its own spoken output back into the next turn. *)

val recent_direct_conversation_of_messages
  :  ?limit:int
  -> Keeper_chat_store.chat_message list
  -> recent_direct_line list

val collect_recent_direct_conversation
  :  ?limit:int
  -> config:Workspace.config
  -> meta:keeper_meta
  -> unit
  -> recent_direct_line list

val render_recent_direct_conversation_context
  :  recent_direct_line list
  -> string

(** Pure source-ordered classification after the optional durable ack row.
    Paired turns are acknowledged by an assistant utterance with the same
    typed [turn_ref], or by a terminal assistant transcript row with the same
    typed delivery key. An unrelated assistant row and a transport-failure row
    never clear input. *)
val pending_messages_of_messages
  :  ?ack_id:string
  -> targets:string list
  -> Keeper_chat_store.chat_message list
  -> pending_message list

val pending_mentions_of_messages
  :  ?ack_id:string
  -> targets:string list
  -> Keeper_chat_store.chat_message list
  -> (string * string) list

(** [pending_scope_of_messages ~targets messages] returns the [(speaker,
    content)] of every unanswered Owner-authored user line that is {e not} a
    mention — the operator addressing the keeper without an "@name". External
    (connector) lines and lines already counted as mentions are excluded, so
    this signal stays disjoint from mentions and does not flood on busy
    channels. Same watermark as {!pending_mentions_of_messages}; pure. *)
val pending_scope_of_messages
  :  ?ack_id:string
  -> targets:string list
  -> Keeper_chat_store.chat_message list
  -> (string * string) list

(** [fleet_messages_of_messages ~limit ~targets messages] returns the newest
    [limit] keeper broadcasts projected into this transcript, in arrival order.
    A row qualifies when it is a user line on the [Surface_ref.Broadcast]
    (fleet fanout) or [Surface_ref.Agent] (direct keeper delivery) surface
    that the lane classifier places in no reactive lane — the lanes take its
    [Some], this layer takes its [None], so the same row cannot reach both.
    [limit <= 0] returns
    the empty list. No watermark: unlike the lanes this is standing context,
    and lane acknowledgement only advances on autonomous turns. Pure. *)
val fleet_messages_of_messages
  :  limit:int
  -> targets:string list
  -> Keeper_chat_store.chat_message list
  -> fleet_message list

(** Loads the transcript once and derives both the reactive lanes and the fleet
    layer from the same rows. *)
val collect_message_scope_and_fleet
  :  config:Workspace.config
  -> meta:keeper_meta
  -> fleet_limit:int
  -> pending_message list * fleet_message list
