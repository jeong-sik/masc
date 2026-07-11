type paused_latch =
  | Classified of Keeper_latched_reason.t
  | Unclassified

type state =
  | Active
  | Paused of paused_latch
  | Dead_tombstone

let state ~paused ~latched_reason =
  match latched_reason with
  | Some Keeper_latched_reason.Dead_tombstone -> Dead_tombstone
  | Some reason when paused -> Paused (Classified reason)
  | None when paused -> Paused Unclassified
  | Some _ | None -> Active
;;

type manual_one_shot_admission =
  | Manual_admitted_active
  | Manual_admitted_paused_recovery of paused_latch
  | Manual_denied_dead_tombstone

let admit_manual_one_shot = function
  | Active -> Manual_admitted_active
  | Paused latch -> Manual_admitted_paused_recovery latch
  | Dead_tombstone -> Manual_denied_dead_tombstone
;;

type autonomous_denial =
  | Autonomous_paused of paused_latch
  | Autonomous_dead_tombstone

type autonomous_admission =
  | Autonomous_admitted
  | Autonomous_denied of autonomous_denial

let admit_autonomous = function
  | Active -> Autonomous_admitted
  | Paused latch -> Autonomous_denied (Autonomous_paused latch)
  | Dead_tombstone -> Autonomous_denied Autonomous_dead_tombstone
;;

let paused_latch_to_wire = function
  | Classified reason -> Keeper_latched_reason.to_wire reason
  | Unclassified -> "unclassified"
;;

let state_to_wire = function
  | Active -> "active"
  | Paused _ -> "paused"
  | Dead_tombstone -> "dead_tombstone"
;;

let autonomous_denial_to_wire = function
  | Autonomous_paused _ -> "paused"
  | Autonomous_dead_tombstone -> "dead_tombstone"
;;
