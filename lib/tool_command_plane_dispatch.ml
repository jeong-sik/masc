open Tool_command_plane_support
open Tool_command_plane_mutations

let dispatch (ctx : (_, _) context) ~name ~args : result option =
  match name with
  | "masc_dispatch_plan" -> Some (handle_dispatch_plan ctx args)
  | "masc_dispatch_assign" -> Some (handle_dispatch_assign ctx args)
  | "masc_dispatch_rebalance" -> Some (handle_dispatch_rebalance ctx args)
  | "masc_dispatch_escalate" -> Some (handle_dispatch_escalate ctx args)
  | "masc_dispatch_recall" -> Some (handle_dispatch_recall ctx args)
  | "masc_dispatch_tick" -> Some (handle_dispatch_tick ctx args)
  | "masc_policy_status" -> Some (handle_policy_status ctx)
  | "masc_policy_approve" -> Some (handle_policy_approve ctx args)
  | "masc_policy_deny" -> Some (handle_policy_deny ctx args)
  | "masc_policy_update" -> Some (handle_policy_update ctx args)
  | "masc_policy_freeze_unit" -> Some (handle_policy_freeze_unit ctx args)
  | "masc_policy_kill_switch" -> Some (handle_policy_kill_switch ctx args)
  | _ -> None
