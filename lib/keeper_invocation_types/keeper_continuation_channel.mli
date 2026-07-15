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

type t =
  | Dashboard of { thread_id : string }
  | Discord of {
      guild_id : string option;
      channel_id : string;
      parent_channel_id : string option;
      thread_id : string option;
      user_id : string;
    }
  | Slack of {
      team_id : string option;
      channel_id : string;
      thread_ts : string option;
      user_id : string;
    }
  | Unrouted of { reason : string }

(** [unrouted reason] is the fail-closed channel carrying a diagnostic
    [reason] explaining why no connector could be determined. *)
val unrouted : string -> t

(** [is_routable t] is [false] only for [Unrouted]; a routable channel has a
    concrete reply destination. *)
val is_routable : t -> bool

(** [kind_label t] is a stable lowercase tag for metrics / observability:
    ["dashboard"] | ["discord"] | ["slack"] | ["unrouted"]. *)
val kind_label : t -> string

(** [describe t] is a human-readable one-line summary for logs. *)
val describe : t -> string

(** [same_route a b] is [true] when two channels denote the same reply
    destination, used to coalesce continuations without losing routing. Two
    [Unrouted] values are never the same route (an unroutable value has no
    destination to share). *)
val same_route : t -> t -> bool

(** [to_yojson t] serializes to a tagged object [{ "kind": <tag>; ... }]. *)
val to_yojson : t -> Yojson.Safe.t

(** [of_yojson json] parses a tagged object produced by {!to_yojson}. A
    missing or unknown ["kind"], or a missing field, is an [Error]; there is
    no permissive default (RFC-0320 §2 fail-closed). *)
val of_yojson : Yojson.Safe.t -> (t, string) result
