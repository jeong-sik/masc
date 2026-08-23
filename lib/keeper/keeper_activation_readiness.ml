type autonomous_blocker =
  | Lifecycle_denied of Keeper_lifecycle_admission.autonomous_denial
  | Autoboot_disabled
  | Proactive_disabled

type owner_runtime =
  | Owner_unregistered
  | Owner_registered of
      { phase : Keeper_state_machine.phase
      ; live_fiber : bool
      ; lane_exited : bool
      }

type retained_disabled_reason =
  | Retained_autoboot_disabled
  | Retained_proactive_disabled

type paused_dead_reason =
  | Persisted_lifecycle_denied of Keeper_lifecycle_admission.autonomous_denial
  | Runtime_terminal of Keeper_state_machine.phase

type owner_execution_truth =
  | Executable
  | Recoverable
  | Retained_disabled of retained_disabled_reason
  | Paused_dead of paused_dead_reason
  | Shutdown_fenced of Keeper_shutdown_types.Operation_id.t
  | Unknown of string

type pause_kind =
  | Active
  | Operator_paused
  | Unclassified_paused

let pause_kind (meta : Keeper_meta_contract.keeper_meta) =
  match
    Keeper_lifecycle_admission.state
      ~paused:meta.paused
      ~latched_reason:meta.latched_reason
  with
  | Keeper_lifecycle_admission.Active -> Active
  | Keeper_lifecycle_admission.Paused latch ->
    (match latch with
     | Keeper_lifecycle_admission.Classified
         (Keeper_latched_reason.Operator_paused _) -> Operator_paused
     | Keeper_lifecycle_admission.Unclassified -> Unclassified_paused)
;;

let pause_kind_to_wire = function
  | Active -> "active"
  | Operator_paused -> "operator_paused"
  | Unclassified_paused -> "unclassified_paused"
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

let owner_runtime_of_registry_entry = function
  | None -> Owner_unregistered
  | Some (entry : Keeper_registry.registry_entry) ->
    let lane_exited = Keeper_registry.lane_has_exited entry in
    let live_fiber =
      entry.conditions.fiber_alive
      && not lane_exited
      && Option.is_none (Eio.Promise.peek entry.done_p)
    in
    Owner_registered { phase = entry.phase; live_fiber; lane_exited }
;;

let retained_disabled_reason_to_wire = function
  | Retained_autoboot_disabled -> "autoboot_disabled"
  | Retained_proactive_disabled -> "proactive_disabled"
;;

let paused_dead_reason_to_wire = function
  | Persisted_lifecycle_denied denial ->
    Keeper_lifecycle_admission.autonomous_denial_to_wire denial
  | Runtime_terminal phase ->
    "runtime_" ^ Keeper_state_machine.phase_to_string phase
;;

let owner_execution_truth_to_wire = function
  | Executable -> "executable"
  | Recoverable -> "recoverable"
  | Retained_disabled reason -> retained_disabled_reason_to_wire reason
  | Paused_dead reason -> paused_dead_reason_to_wire reason
  | Shutdown_fenced _ -> "shutdown_fenced"
  | Unknown _ -> "unknown"
;;

let classify_owner_execution_with
      ~require_proactive
      ~shutdown_operation_id
      ~runtime
      meta_result
  =
  match meta_result with
  | Error detail -> Unknown detail
  | Ok meta ->
    (match shutdown_operation_id with
     | Some operation_id -> Shutdown_fenced operation_id
     | None ->
       let activation = autonomous_activation meta in
       (match activation.blocker with
        | Some (Lifecycle_denied denial) ->
          Paused_dead (Persisted_lifecycle_denied denial)
        | Some Autoboot_disabled ->
          Retained_disabled Retained_autoboot_disabled
        | Some Proactive_disabled when require_proactive ->
          Retained_disabled Retained_proactive_disabled
        | Some Proactive_disabled
        | None ->
          (match runtime with
           | Owner_unregistered -> Recoverable
           (* [Stopped] is terminal. [Paused] is not terminal, but it is also
              not executable. Both must be excluded before the live-fiber
              fast path below. *)
           | Owner_registered
               { phase =
                   ( Keeper_state_machine.Paused
                   | Keeper_state_machine.Stopped ) as phase
               ; _
               } ->
             Paused_dead (Runtime_terminal phase)
           | Owner_registered { live_fiber = true; _ } -> Executable
           | Owner_registered { live_fiber = false; _ } -> Recoverable)))
;;

let classify_owner_execution =
  classify_owner_execution_with ~require_proactive:true
;;

let classify_durable_demand_execution
      ~shutdown_operation_id
      ~runtime
      meta_result
  =
  match
    classify_owner_execution_with
      ~require_proactive:false
      ~shutdown_operation_id
      ~runtime
      meta_result,
    runtime,
    meta_result
  with
  | Retained_disabled Retained_autoboot_disabled,
    Owner_registered
      { phase = Keeper_state_machine.Running; live_fiber = true; _ },
    Ok meta
      when (not meta.autoboot_enabled)
           && (Keeper_lifecycle_gate_env.global ()).autonomous ->
    (* [autoboot_enabled] controls whether an absent owner may be started. It
       must not suppress an explicit durable wake for an owner that is already
       running. Lifecycle and shutdown fences were resolved before this arm. *)
    Executable
  | truth, _, _ -> truth
;;

let of_meta meta =
  let autonomous_activation = autonomous_activation meta in
  let ok = autonomous_activation.ok in
  { ok; ready_for_unclaimed_backlog = ok; autonomous_activation }
;;

let ready_for_unclaimed_backlog meta = (of_meta meta).ready_for_unclaimed_backlog

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
