(** Discord_presence_bridge — syncs keeper liveness to Discord bot presence.

    A long-lived fiber that polls keeper activation status every 30 s
    and calls {!Discord_gateway_client.set_presence} so Discord users
    see whether a bound keeper is available (Online) or paused (Idle). *)

val start :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  workspace_config:Workspace.config ->
  unit ->
  unit
(** [start ~sw ~clock ~workspace_config ()] forks a fiber that
    periodically updates the Discord bot presence.  Safe to call
    regardless of whether the Discord gateway is running — checks
    {!Channel_gate_discord_state.connected} before each update. *)
