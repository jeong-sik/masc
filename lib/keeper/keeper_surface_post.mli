(** Keeper_surface_post — act on one connected surface (RFC-0223 P4).

    Decision layer behind the [keeper_surface_post] tool: resolve which
    lane a post goes to, purely from the requested surface label, the
    optional channel id, the typed continuation channel, and the keeper's
    current Discord/Slack bindings.
    Posting to a surface the keeper is not bound to is an error, not a
    no-op (RFC-0223 §4 P4). All transport I/O stays in the runtime
    handler. *)

type rich_block = Yojson.Safe.t
(** Slack Block Kit block rendered as a JSON value. *)

type post_target =
  | To_dashboard
      (** Persist an assistant line + broadcast [keeper_chat_appended];
          the dashboard is always present. *)
  | To_discord of { channel_id : string }
  | To_slack of
      { channel_id : string
      ; thread_ts : string option
      ; blocks : rich_block list option
      }
      (** Post to a bound Slack channel. [thread_ts] carries the explicit
          thread requested by the tool call, else the continuation thread
          coordinate when the post lands on the continuation's own channel,
          so a threaded question is answered in its thread instead of the
          channel root. [blocks] may carry Slack Block Kit rich blocks to
          render alongside the plain-text fallback. *)

val dashboard_label : string
val discord_label : string
val slack_label : string

val max_user_mentions : int

val max_rich_blocks : int
(** Slack chat.postMessage rejects more than this many top-level Block Kit
    blocks per message. *)

val user_mentions_of_args :
  surface:string -> Yojson.Safe.t -> (string list, string) result
(** Decode and validate the optional [mention_user_ids] tool argument.
    Slack accepts only stable [U...]/[W...] participant ids; Discord accepts
    only decimal user snowflakes. Display names are never guessed. Duplicate
    ids are collapsed and more than {!max_user_mentions} ids are rejected.
    Non-empty mentions on dashboard or another surface are invalid. *)

val validate_user_mentions_against_roster :
  target:post_target ->
  messages:Keeper_chat_store.chat_message list ->
  string list ->
  (unit, string) result
(** Fail closed unless every requested mention id appears as a user speaker on
    the exact resolved Discord channel or Slack channel/thread in [messages].
    The persisted chat lane is the roster SSOT; syntactically valid but stale,
    hallucinated, or cross-channel ids are rejected before any effect. *)

val thread_ts_of_args :
  surface:string -> Yojson.Safe.t -> (string option, string) result
(** Decode the optional [thread_ts] tool argument: the Slack timestamp of an
    existing thread's root message. Slack-only; blank or non-string values are
    rejected. The value is passed to Slack verbatim — a foreign or expired
    timestamp fails at the connector, not silently as a root post. *)

val blocks_of_args :
  surface:string -> Yojson.Safe.t -> (rich_block list option, string) result
(** Decode the optional [blocks] tool argument: Slack Block Kit blocks for
    chat.postMessage. Slack-only. The array must be non-empty, carry at most
    {!max_rich_blocks} entries, and every entry must be a JSON object with a
    non-empty string ["type"] member. Content stays the notification fallback
    text. *)

type delivery_target =
  | Delivered_to_dashboard
  | Delivered_to_discord of { channel_id : string }
  | Delivered_to_slack of { channel_id : string; thread_ts : string option }
(** Where a completed surface post actually landed — the destination
    coordinates of a [post_target] without its payload ([blocks]). Carried on
    the turn's reply payload and the [External_effect_completed] chat event so
    the dashboard can name the real destination instead of assuming an
    external connector (issue #28374). *)

val delivery_target_of_post_target : post_target -> delivery_target

val delivery_target_to_yojson : delivery_target -> Yojson.Safe.t
(** [{"kind":"dashboard"}], [{"kind":"discord","channel_id":_}] or
    [{"kind":"slack","channel_id":_,"thread_ts"?:_}]. [thread_ts] is omitted,
    never [null], when absent. *)

val delivery_target_of_yojson : Yojson.Safe.t -> (delivery_target, string) result
(** Closed decode of {!delivery_target_to_yojson}. Unknown kinds, missing or
    blank coordinates are errors, never defaults. *)

val delivery_target_wire_key : string
(** ["external_effect_target"] — the reply-payload field carrying the
    delivery target. Shared by the producer ({!Keeper_turn}) and the stream
    decoder so the wire name cannot drift. *)

val resolve_bound_channel_reference :
  names:(string * string) list -> bound:string list -> string -> string option
(** Resolve a channel reference — a bound channel id, or the channel's name
    with an optional ["#"] prefix — to a bound channel id, against the
    (id, name) pairs the caller supplies (the connector_names projection a
    gateway fills on a channel's first inbound event). Resolution never
    leaves the bound set, and a name matching more than one bound channel
    resolves to none of them. Returns [None] for anything unresolved; the
    caller then passes the reference through unchanged so
    {!resolve_target} answers with its binding error as before. *)

val resolve_target :
  surface:string ->
  channel_id:string option ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?requested_thread_ts:string ->
  ?bound_discord_channels:string list ->
  ?bound_slack_channels:string list ->
  unit ->
  (post_target, string) result
(** Deterministic lane resolution:
    - blank surface or blank content are rejected by the caller; this
      function only routes.
    - ["dashboard"] → [To_dashboard].
    - ["discord"] → the bound channel when exactly one exists; the
      given [channel_id], or the exact matching typed continuation channel,
      when it is among the bindings. A typed Discord thread continuation
      keeps its thread channel as the target while authorizing it through
      the bound parent channel; an error names the bound channels when
      ambiguous, unbound, or foreign.
    - ["slack"] → same semantics against [bound_slack_channels]. An explicit
      [requested_thread_ts] wins and travels with any bound channel. Otherwise
      a typed Slack continuation supplies its [thread_ts], which travels with
      the target only when the post lands on the continuation's own channel.
      A continuation for another connector never supplies an id.
    - any other label → error: P4 ships discord + dashboard + slack
      (generic gate connectors have no send surface yet). *)

val set_blocks : post_target -> rich_block list option -> post_target
(** [set_blocks target blocks] attaches [blocks] to a [To_slack] target and
    returns any other target unchanged. *)

val matches_continuation_route :
  post_target -> Keeper_continuation_channel.t -> bool
(** True only when the completed post proves the same concrete delivery route.
    Keeper-global dashboard posts never match. A Slack post matches only when
    it carried the continuation's exact thread coordinate ([thread_ts]
    equality, including both-[None]); a root post does not prove delivery for
    a threaded continuation. *)

val ok_json : surface:string -> ?message_id:string -> unit -> string
val error_json : string -> string
