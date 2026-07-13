type autonomous_blocker =
  | Lifecycle_denied of Keeper_lifecycle_admission.autonomous_denial
  | Autoboot_disabled
  | Proactive_disabled

type pause_kind =
  | Active
  | Operator_paused
  | Unclassified_paused
  | Dead_tombstone

let pause_kind (meta : Keeper_meta_contract.keeper_meta) =
  match
    Keeper_lifecycle_admission.state
      ~paused:meta.paused
      ~latched_reason:meta.latched_reason
  with
  | Keeper_lifecycle_admission.Dead_tombstone -> Dead_tombstone
  | Keeper_lifecycle_admission.Active -> Active
  | Keeper_lifecycle_admission.Paused latch ->
    (match latch with
     | Keeper_lifecycle_admission.Classified
         (Keeper_latched_reason.Operator_paused _) -> Operator_paused
     | Keeper_lifecycle_admission.Classified Keeper_latched_reason.Dead_tombstone ->
       Dead_tombstone
     | Keeper_lifecycle_admission.Unclassified -> Unclassified_paused)
;;

let pause_kind_to_wire = function
  | Active -> "active"
  | Operator_paused -> "operator_paused"
  | Unclassified_paused -> "unclassified_paused"
  | Dead_tombstone -> "dead_tombstone"
;;

type autonomous_activation =
  { ok : bool
  ; autoboot_enabled : bool
  ; proactive_enabled : bool
  ; paused : bool
  ; lifecycle_state : Keeper_lifecycle_admission.state
  ; blocker : autonomous_blocker option
  ; hint : string option
  }

type t =
  { ok : bool
  ; ready_for_unclaimed_backlog : bool
  ; autonomous_activation : autonomous_activation
  }

(* RFC-0297 P0-1: the autonomous and proactive gates are resolved through the
   single SSOT [Keeper_lifecycle_gate_env.enabled] (global kill-switch AND the
   per-keeper flag), rather than re-deriving the enabled state from
   [meta.autoboot_enabled] / [meta.proactive.enabled] here. This is the same
   resolver [keeper_cycle_decision] uses, so the two sites cannot drift. *)
let autonomous_blocker (meta : Keeper_meta_contract.keeper_meta) lifecycle_state =
  match Keeper_lifecycle_admission.admit_autonomous lifecycle_state with
  | Keeper_lifecycle_admission.Autonomous_denied denial ->
    Some (Lifecycle_denied denial)
  | Keeper_lifecycle_admission.Autonomous_admitted ->
    if not (Keeper_lifecycle_gate_env.enabled Autonomous meta) then
      Some Autoboot_disabled
    else if not (Keeper_lifecycle_gate_env.enabled Proactive meta) then
      Some Proactive_disabled
    else None
;;

let autonomous_blocker_to_wire = function
  | Lifecycle_denied denial ->
    Keeper_lifecycle_admission.autonomous_denial_to_wire denial
  | Autoboot_disabled -> "autoboot_disabled"
  | Proactive_disabled -> "proactive_disabled"
;;

(* The typed blocker is shared with the lifecycle and feature-gate verdicts.
   The hint checks the meta flag directly to distinguish a global kill-switch
   from a per-keeper flag without parsing the boundary string projection. *)
let autonomous_hint (meta : Keeper_meta_contract.keeper_meta) = function
  | None -> None
  | Some
      (Lifecycle_denied (Keeper_lifecycle_admission.Autonomous_paused _)) ->
    Some "resume keeper before expecting autonomous keepalive or PR fan-out"
  | Some
      (Lifecycle_denied Keeper_lifecycle_admission.Autonomous_dead_tombstone) ->
    Some "transition the dead keeper lifecycle before starting a new lane"
  | Some Autoboot_disabled ->
    if meta.autoboot_enabled
    then
      Some
        "set MASC_KEEPER_AUTONOMOUS_ENABLED=true (global kill-switch; \
         per-keeper autoboot_enabled is already true) before expecting \
         autonomous keepalive or PR fan-out"
    else
      Some "set autoboot_enabled=true before expecting autonomous keepalive or PR fan-out"
  | Some Proactive_disabled ->
    if meta.proactive.enabled
    then
      Some
        "set MASC_KEEPER_PROACTIVE_ENABLED=true (global kill-switch; \
         per-keeper proactive_enabled is already true) before expecting \
         scheduled autonomous work"
    else
      Some "set proactive_enabled=true before expecting scheduled autonomous work"
;;

let autonomous_activation (meta : Keeper_meta_contract.keeper_meta) =
  let lifecycle_state =
    Keeper_lifecycle_admission.state
      ~paused:meta.paused
      ~latched_reason:meta.latched_reason
  in
  let blocker = autonomous_blocker meta lifecycle_state in
  { ok = Option.is_none blocker
  ; autoboot_enabled = meta.autoboot_enabled
  ; proactive_enabled = meta.proactive.enabled
  ; paused = meta.paused
  ; lifecycle_state
  ; blocker
  ; hint = autonomous_hint meta blocker
  }
;;

let of_meta meta =
  let autonomous_activation = autonomous_activation meta in
  let ok = autonomous_activation.ok in
  { ok; ready_for_unclaimed_backlog = ok; autonomous_activation }
;;

let ready_for_unclaimed_backlog meta = (of_meta meta).ready_for_unclaimed_backlog

let autonomous_check_value (activation : autonomous_activation) =
  match activation.blocker with
  | None -> "ok"
  | Some blocker -> autonomous_blocker_to_wire blocker
;;

let autonomous_activation_to_yojson (activation : autonomous_activation) =
  `Assoc
    [ "ok", `Bool activation.ok
    ; "autoboot_enabled", `Bool activation.autoboot_enabled
    ; "proactive_enabled", `Bool activation.proactive_enabled
    ; "paused", `Bool activation.paused
    ; ( "lifecycle_state"
      , `String
          (Keeper_lifecycle_admission.state_to_wire activation.lifecycle_state) )
    ; ( "blocker"
      , Json_util.string_opt_to_json
          (Option.map autonomous_blocker_to_wire activation.blocker) )
    ; "hint", Json_util.string_opt_to_json activation.hint
    ]
;;

let to_yojson readiness =
  `Assoc
    [ "ok", `Bool readiness.ok
    ; "ready_for_unclaimed_backlog", `Bool readiness.ready_for_unclaimed_backlog
    ; ( "autonomous_activation"
      , autonomous_activation_to_yojson readiness.autonomous_activation )
    ]
;;
