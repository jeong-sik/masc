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
   - A name with no meta is not a Keeper (an MCP client, an operator), and
     a meta that cannot be read tells nothing. Both keep it: nothing here
     can say whether they are still playing. *)

let holder_left ~(config : Workspace.config) holder =
  match Keeper_registry.get_phase ~base_path:config.base_path holder with
  | Some (Paused | Stopped) -> true
  | Some (Running | Failing | Draining | Restarting | Crashed | Offline) -> false
  | None ->
    (match Keeper_meta_store.read_meta config holder with
     | Ok (Some _) -> true
     | Ok None | Error _ -> false)
;;

let before_move ~config ~who =
  Tool_misc_dos_lane.free_left_controller ~holder_left:(holder_left ~config) ~who
;;
