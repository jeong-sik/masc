(** Keeper_surface_post — act on one connected surface (RFC-0223 P4).

    Decision layer behind the [keeper_surface_post] tool: resolve which
    lane a post goes to, purely from the requested surface label, the
    optional channel id, and the keeper's current Discord/Slack bindings.
    Posting to a surface the keeper is not bound to is an error, not a
    no-op (RFC-0223 §4 P4). All transport I/O stays in the runtime
    handler. *)

type post_target =
  | To_dashboard
      (** Persist an assistant line + broadcast [keeper_chat_appended];
          the dashboard is always present. *)
  | To_discord of { channel_id : string }
  | To_slack of { channel_id : string }

val resolve_target :
  surface:string ->
  channel_id:string option ->
  ?bound_discord_channels:string list ->
  ?bound_slack_channels:string list ->
  unit ->
  (post_target, string) result
(** Deterministic lane resolution:
    - blank surface or blank content are rejected by the caller; this
      function only routes.
    - ["dashboard"] → [To_dashboard].
    - ["discord"] → the bound channel when exactly one exists; the
      given [channel_id] when it is among the bindings; an error
      naming the bound channels when ambiguous, unbound, or the id is
      not bound.
    - ["slack"] → same semantics against [bound_slack_channels].
    - any other label → error: P4 ships discord + dashboard + slack
      (generic gate connectors have no send surface yet). *)

val ok_json : surface:string -> ?message_id:string -> unit -> string
val error_json : string -> string
