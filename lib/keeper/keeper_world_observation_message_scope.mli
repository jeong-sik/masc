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

val is_keeper_authored_message : string -> bool

type recent_direct_line = {
  role_label : string;
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

(** [pending_mentions_of_messages ~targets messages] returns the [(speaker,
    content)] of every user line whose persisted [mentions] (RFC-0232
    §3.3: parsed once at append) hit a target and that arrives after the
    keeper's own last line. Pure (no I/O) so the watermark logic is testable
    directly; this is the core of {!collect_message_scope}. *)
val pending_mentions_of_messages
  :  targets:string list
  -> Keeper_chat_store.chat_message list
  -> (string * string) list

(** [pending_scope_of_messages ~targets messages] returns the [(speaker,
    content)] of every unanswered Owner-authored user line that is {e not} a
    mention — the operator addressing the keeper without an "@name". External
    (connector) lines and lines already counted as mentions are excluded, so
    this signal stays disjoint from mentions and does not flood on busy
    channels. Same watermark as {!pending_mentions_of_messages}; pure. *)
val pending_scope_of_messages
  :  targets:string list
  -> Keeper_chat_store.chat_message list
  -> (string * string) list

val collect_message_scope
  :  config:Workspace.config
  -> meta:keeper_meta
  -> (string * string) list * (string * string) list
