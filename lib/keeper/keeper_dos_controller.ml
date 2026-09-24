(* The Keeper side of the DOS controller hand-over.

   The tool surface cannot read Keeper state (RFC-0194), so it asks this
   module whether a holder can still act. A Keeper that is paused, stopped,
   crashed or offline cannot, and will never pass. A Keeper that is failing,
   draining or restarting is on its way back and keeps the controller. A
   holder with no registry entry is not a Keeper at all (an MCP client, an
   operator); nothing here can tell whether it is still playing, so it keeps
   the controller too. *)

let holder_left ~base_path holder =
  match Keeper_registry.get_phase ~base_path holder with
  | Some (Paused | Stopped | Crashed | Offline) -> true
  | Some (Running | Failing | Draining | Restarting) | None -> false
;;

let before_move ~base_path ~who =
  Tool_misc_dos_lane.free_left_controller ~holder_left:(holder_left ~base_path) ~who
;;
