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
  Channel_gate_discord_state.bound_channels_result ~keeper_name:entry.name
  |> Result.map (fun bound_channels ->
       { keeper_name = entry.name
       ; running = Keeper_registry.is_running ~base_path entry.name
       ; bound_channels
       })
;;

let live_keeper_presence ~base_path =
  Keeper_registry.all ~base_path ()
  |> List.fold_left
       (fun result entry ->
          match result with
          | Error _ as error -> error
          | Ok keepers ->
            keeper_presence_of_registry_entry ~base_path entry
            |> Result.map (fun keeper -> keeper :: keepers))
       (Ok [])
  |> Result.map List.rev
;;

(* Written out over every pair so a new [presence_status] constructor is a
   compile error here rather than a status the bridge re-sends forever. *)
let same_status (a : Discord_gateway_state.presence_status) b =
  let module S = Discord_gateway_state in
  match a, b with
  | S.Online, S.Online | S.Idle, S.Idle | S.Dnd, S.Dnd | S.Invisible, S.Invisible ->
    true
  | S.Online, (S.Idle | S.Dnd | S.Invisible)
  | S.Idle, (S.Online | S.Dnd | S.Invisible)
  | S.Dnd, (S.Online | S.Idle | S.Invisible)
  | S.Invisible, (S.Online | S.Idle | S.Dnd) -> false
;;

(* The gateway frame and its "presence update" log line go out only when the
   status changes. Every poll used to re-send the same status: 61 identical
   "presence update: online" lines and as many Discord frames in 41 minutes
   (2026-09-09). A disconnected gateway forgets the last send, because the
   reconnect identifies as Online by default and the next connected poll has
   to publish the real status again. *)
let presence_transition ~last computed =
  match last, computed with
  | Some previous, Some next when same_status previous next -> None, last
  | (None | Some _), (Some _ as next) -> next, next
  | (None | Some _), None -> None, None
;;

let update_presence ~workspace_config ~last =
  let base_path = workspace_config.Workspace.base_path in
  match live_keeper_presence ~base_path with
  | Error detail ->
    Log.Discord.error
      "discord_presence_bridge: binding read failed: %s"
      (Channel_gate_discord_state.binding_lookup_error_to_string detail)
  | Ok keepers ->
    let computed =
      presence_status_for_keepers
        ~gateway_connected:(Channel_gate_discord_state.connected ())
        keepers
    in
    let to_send, next_last = presence_transition ~last:!last computed in
    last := next_last;
    (match to_send with
     | None -> ()
     | Some status -> Discord_gateway_client.set_presence status)
;;

(* ── Fiber entry ────────────────────────────────────────────────── *)

let start ~sw:_ ~clock ~workspace_config () =
  let last = ref None in
  let rec loop () =
    (try update_presence ~workspace_config ~last with
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
