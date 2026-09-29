(* The Keeper side of the DOS controller hand-over.

   The tool surface cannot read Keeper state (RFC-0194), so it asks this
   module whether a holder can still act.

   - Paused or Stopped: it cannot, and will not pass. Paused is let go on
     purpose: an operator's pause can outlast the game.
   - A Keeper whose stop has finished leaves the registry but keeps its
     meta. A known Keeper with no registry entry has stopped, and is let go.
   - Running, Failing, Draining, Restarting, Crashed (whose only way out is
     an automatic restart) and Offline (launch pending) are on their way
     back and keep the controller.
   - An expired Player credential cannot act again, so its controller is
     freed on the next move. A missing or unreadable credential is not proof
     that a holder was a Player.
   - Other names without Keeper meta (MCP clients and operators), and meta
     that cannot be read, keep the controller. *)

let expired_player ~base_path ~now holder =
  match Auth.load_credential base_path holder with
  | Some { Masc_domain.agent_name; role = Masc_domain.Player; expires_at = Some stamp; _ }
    when String.equal agent_name holder ->
    (* Static bearer validation compares whole-second UTC timestamps with a
       strict [now > expiry]. During the expiry second its bearer still works,
       so do not free its controller until the following second. *)
    (match Time_codec.parse_rfc3339_opt stamp with
     | Some expiry when expiry < Float.floor now -> Some Tool_misc_dos_lane.Player_expired
     | Some _ | None -> None)
  | Some _ | None -> None
;;

let holder_left ~(config : Workspace.config) ~now holder =
  match Keeper_registry.get_phase ~base_path:config.base_path holder with
  | Some (Paused | Stopped) -> Some Tool_misc_dos_lane.Keeper_stopped
  | Some (Running | Failing | Draining | Restarting | Crashed | Offline) -> None
  | None ->
    (match Keeper_meta_store.read_meta config holder with
     | Ok (Some _) -> Some Tool_misc_dos_lane.Keeper_stopped
     | Ok None -> expired_player ~base_path:config.base_path ~now holder
     | Error _ -> None)
;;

let before_move ~config ~who =
  (* DET-OK: sample time once at the move boundary to classify invite expiry. *)
  let now = Unix.gettimeofday () in
  Tool_misc_dos_lane.free_left_controller ~holder_left:(holder_left ~config ~now) ~who
;;
