(** Discord_presence_bridge — syncs live keeper liveness to Discord bot presence.

    Polls keeper activation status every 30 s and calls
    {!Discord_gateway_client.set_presence} so Discord users see whether a
    bound keeper is available (Online) or paused (Idle). *)

type keeper_presence =
  { keeper_name : string
  ; running : bool
  ; bound_channels : string list
  }
(** Runtime liveness and Discord binding snapshot for one keeper. *)

val presence_status_for_keepers :
  gateway_connected:bool ->
  keeper_presence list ->
  Discord_gateway_state.presence_status option
(** [presence_status_for_keepers ~gateway_connected keepers] returns the
    Discord presence to publish.

    Returns [None] when the gateway is disconnected, [Some Online] when at
    least one running keeper has a Discord channel binding, and [Some Idle]
    otherwise. *)

val presence_transition :
  last:Discord_gateway_state.presence_status option ->
  Discord_gateway_state.presence_status option ->
  Discord_gateway_state.presence_status option
  * Discord_gateway_state.presence_status option
(** [presence_transition ~last computed] is [(to_send, next_last)]: the status
    to publish this poll, if it differs from the last one published, and what
    to remember. A [None] computed status (gateway disconnected) forgets the
    last send so the next connected poll publishes again. *)

val start :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  workspace_config:Workspace.config ->
  unit ->
  unit
(** [start ~sw ~clock ~workspace_config ()] runs the polling loop until
    cancelled. It is intended to be called from a managed subsystem fiber.

    Safe to call regardless of whether the Discord gateway is running; the
    loop checks {!Channel_gate_discord_state.connected} before each update. *)
