(** Discord_presence_bridge — syncs keeper liveness to Discord bot presence.

    Periodically checks whether keepers with Discord channel bindings
    are running and updates the Discord gateway bot presence:

    - At least one active bound keeper → Online (green circle)
    - No active bound keepers → Idle (yellow moon)
    - Gateway disconnected → no-op

    Polled every 30 s via a long-lived fiber forked at server startup
    alongside the other subsystems in {!Server_bootstrap_loops}. *)

(* Minimum seconds between presence checks. Keeper liveness is
   in-memory state (Keeper_registry), so disk churn is not a concern.
   30 s balances responsiveness with overhead. *)
let poll_interval_s = 30.0

(* ── Presence logic ──────────────────────────────────────────────── *)

let keeper_has_active_binding ~base_path keeper_name =
  Channel_gate_discord_state.bound_channels ~keeper_name <> []
  && Keeper_registry.is_running ~base_path keeper_name

let update_presence ~workspace_config =
  if not (Channel_gate_discord_state.connected ()) then ()
  else
    let base_path = workspace_config.Workspace.base_path in
    let all_keepers = Keeper_meta_store.keeper_names workspace_config in
    let any_active_bound =
      List.exists (keeper_has_active_binding ~base_path) all_keepers
    in
    let status =
      if any_active_bound then Discord_gateway_state.Online
      else Discord_gateway_state.Idle
    in
    Discord_gateway_client.set_presence status

(* ── Fiber entry ────────────────────────────────────────────────── *)

let start ~sw ~clock ~workspace_config () =
  let rec loop () =
    (try update_presence ~workspace_config with exn ->
       Log.Discord.warn
         "discord_presence_bridge: update failed: %s"
         (Printexc.to_string exn));
    Eio.Time.sleep clock poll_interval_s;
    loop ()
  in
  Eio.Fiber.fork ~sw (fun () ->
    Log.Discord.info
      "discord_presence_bridge: starting (poll interval %.0fs)"
      poll_interval_s;
    loop ())
