(** Discord_presence_bridge — syncs live keeper liveness to Discord bot presence.

    Periodically checks whether keepers with Discord channel bindings are
    running and updates the Discord gateway bot presence:

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

type keeper_presence =
  { keeper_name : string
  ; running : bool
  ; bound_channels : string list
  }

let keeper_has_active_binding keeper =
  keeper.running && keeper.bound_channels <> []
;;

let presence_status_for_keepers ~gateway_connected keepers =
  if not gateway_connected
  then None
  else if List.exists keeper_has_active_binding keepers
  then Some Discord_gateway_state.Online
  else Some Discord_gateway_state.Idle
;;

let keeper_presence_of_registry_entry ~base_path (entry : Keeper_registry.registry_entry)
  =
  { keeper_name = entry.name
  ; running = Keeper_registry.is_running ~base_path entry.name
  ; bound_channels =
      Channel_gate_discord_state.bound_channels ~keeper_name:entry.name
  }
;;

let live_keeper_presence ~base_path =
  Keeper_registry.all ~base_path ()
  |> List.map (keeper_presence_of_registry_entry ~base_path)
;;

let update_presence ~workspace_config =
  let base_path = workspace_config.Workspace.base_path in
  match
    presence_status_for_keepers
      ~gateway_connected:(Channel_gate_discord_state.connected ())
      (live_keeper_presence ~base_path)
  with
  | None -> ()
  | Some status -> Discord_gateway_client.set_presence status
;;

(* ── Fiber entry ────────────────────────────────────────────────── *)

let start ~sw:_ ~clock ~workspace_config () =
  let rec loop () =
    (try update_presence ~workspace_config with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Discord.warn
         "discord_presence_bridge: update failed: %s"
         (Printexc.to_string exn));
    Eio.Time.sleep clock poll_interval_s;
    loop ()
  in
  Log.Discord.info
    "discord_presence_bridge: starting (poll interval %.0fs)"
    poll_interval_s;
  loop ()
;;
