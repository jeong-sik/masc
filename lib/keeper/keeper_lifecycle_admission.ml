type paused_latch =
  | Classified of Keeper_latched_reason.t
  | Unclassified

type state =
  | Active
  | Paused of paused_latch

let state ~paused ~latched_reason =
  match latched_reason with
  | Some reason when paused -> Paused (Classified reason)
  | None when paused -> Paused Unclassified
  | Some _ | None -> Active
;;

type manual_one_shot_admission =
  | Manual_admitted_active
  | Manual_admitted_paused_recovery of paused_latch

let admit_manual_one_shot = function
  | Active -> Manual_admitted_active
  | Paused latch -> Manual_admitted_paused_recovery latch
;;

type autonomous_denial =
  | Autonomous_paused of paused_latch

type autonomous_admission =
  | Autonomous_admitted
  | Autonomous_denied of autonomous_denial

let admit_autonomous = function
  | Active -> Autonomous_admitted
  | Paused latch -> Autonomous_denied (Autonomous_paused latch)
;;

let state_to_wire = function
  | Active -> "active"
  | Paused _ -> "paused"
;;

let autonomous_denial_to_wire (Autonomous_paused _ : autonomous_denial) = "paused"
;;
