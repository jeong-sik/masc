(** Keeper_continuation_channel — the connector/channel a wake or approval
    should continue the conversation on (RFC-0320).

    Captured at submission time (approval create, mention intake) and, in later
    waves, carried through the wake payload so a resumed keeper replies where
    the conversation started instead of proceeding on its own state.

    [Unrouted] is the fail-closed value: when the originating connector cannot
    be determined it is represented explicitly rather than defaulting to a
    convenience channel. The variant is closed and matches are exhaustive so a
    new connector forces a compile error at every routing site.

    This module is a pure data type. It lives below the main [masc] library, so
    connector constructors carry the lossless coordinate fields used by
    [Surface_ref] without depending on that higher-level module. *)

type t = private
  | Dashboard of { thread_id : string }
  | Discord of {
      guild_id : string option;
      channel_id : string;
      parent_channel_id : string option;
      thread_id : string option;
      reply_to_message_id : string option;
      user_id : string;
    }
  | Slack of {
      team_id : string option;
      channel_id : string;
      thread_ts : string option;
      user_id : string;
    }
  | Imessage of {
      chat_identifier : string;
      chat_guid : string option;
      user_id : string;
    }
  | Keeper of { keeper_name : string }
  | Unrouted of { reason : string }

val dashboard : thread_id:string -> (t, string) result

(** [keeper ~keeper_name] routes the continuation to another Keeper's own
    event queue. A Keeper that submits work on behalf of a person keeps the
    person's channel; a Keeper that submits work for itself is the reader of
    the reply, and this names it. Without this destination such a reply is
    addressed to a screen instead of to the Keeper waiting for it. *)
val keeper : keeper_name:string -> (t, string) result

val discord :
  guild_id:string option ->
  channel_id:string ->
  parent_channel_id:string option ->
  thread_id:string option ->
  ?reply_to_message_id:string ->
  user_id:string ->
  unit ->
  (t, string) result

(** [discord_thread_parent channel ~parent_channel_id] preserves a Discord
    continuation's concrete channel and marks it as a thread whose parent is
    [parent_channel_id]. Other connector continuations are unchanged. *)
val discord_thread_parent : t -> parent_channel_id:string -> t

val slack :
  team_id:string option ->
  channel_id:string ->
  thread_ts:string option ->
  user_id:string ->
  (t, string) result

(** [imessage] routes a continuation back to a Messages.app conversation.
    [chat_identifier] is the conversation and the binding key, so it is
    required. [chat_guid] is the handle a reply is addressed to and is optional
    because the connector's default reply mode answers in the note-to-self
    conversation, whose handle it resolves for itself. Closes the gap that made
    an iMessage-originated keeper resume as [Unrouted] (#24497). *)
val imessage :
  chat_identifier:string ->
  chat_guid:string option ->
  user_id:string ->
  (t, string) result

(** [unrouted reason] is the fail-closed channel carrying a diagnostic
    [reason] explaining why no connector could be determined. It raises
    [Invalid_argument] for a blank diagnostic. Every constructor therefore
    admits only values replayable by {!of_yojson}. *)
val unrouted : string -> t

(** [is_routable t] is [false] only for [Unrouted]; a routable channel has a
    concrete reply destination. *)
val is_routable : t -> bool

(** [kind_label t] is a stable lowercase tag for metrics / observability:
    ["dashboard"] | ["discord"] | ["slack"] | ["keeper"] | ["unrouted"]. *)
val kind_label : t -> string

(** [describe t] is a human-readable one-line summary for logs. *)
val describe : t -> string

(** [same_route a b] is [true] when two channels denote the same reply
    destination, used to coalesce continuations without losing routing. Two
    [Unrouted] values are never the same route (an unroutable value has no
    destination to share). *)
val same_route : t -> t -> bool

(** [same_conversation a b] is [true] when two channels identify the same
    connector conversation for stimulus-batching purposes (RFC-0377): same
    channel/thread location, regardless of which specific message a reply
    would target. This is deliberately looser than {!same_route}: Discord's
    [reply_to_message_id] and Slack's [thread_ts] are stamped per inbound
    message at the ambient producer, so two pending messages from the same
    conversation almost never share a {!same_route} value. Two [Unrouted]
    values are never the same conversation, matching {!same_route}. *)
val same_conversation : t -> t -> bool

(** [to_yojson t] serializes to a tagged object [{ "kind": <tag>; ... }]. *)
val to_yojson : t -> Yojson.Safe.t

(** [of_yojson json] parses a tagged object produced by {!to_yojson}. A
    missing or unknown ["kind"], a missing or blank required field, or a
    blank/non-string connector coordinate is an [Error]. Only absent or null
    optional coordinates become [None]; there are no field aliases or
    permissive defaults (RFC-0320 §2 fail-closed). *)
val of_yojson : Yojson.Safe.t -> (t, string) result
