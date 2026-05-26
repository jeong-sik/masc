(** Keeper_exec_status_helpers — type conversion helpers and pipeline
    stage mapping extracted from [Keeper_exec_status] (558 LoC).
    Health classification, diagnostics, and surface status remain
    in the parent.
    @since Keeper 500-line decomposition *)

open Keeper_types

let active_model_of_meta (m : keeper_meta) : string =
  let _ = m in
  ""

let active_model_label_of_meta (m : keeper_meta) : string =
  (* RFC-0132 PR-2: meta surface is external (status detail); redact via SSOT. *)
  let _ = m in
  Boundary_redaction.to_string Boundary_redaction.runtime_model_label

let next_model_hint_of_meta (m : keeper_meta) : string option =
  let _ = m in
  None

let string_of_fiber_health = function
  | Fiber_alive -> "alive"
  | Fiber_zombie -> "zombie"
  | Fiber_dead -> "dead"
  | Fiber_unknown -> "unknown"

let keeper_health_to_string = function
  | KH_healthy -> "healthy"
  | KH_idle -> "idle"
  | KH_offline -> "offline"
  | KH_stale -> "stale"
  | KH_degraded -> "degraded"
  | KH_zombie -> "zombie"
  | KH_dead -> "dead"

(** Issue #8670: strict parser returning [None] on unknown strings so
    drift (producer typo, future variant) is visible to callers instead
    of silently masquerading as [KH_offline]. Mirrors the #8636 lenient
    parser pattern (option-typed reverse route on the parse boundary). *)
let keeper_health_of_string_opt = function
  | "healthy" -> Some KH_healthy
  | "idle" -> Some KH_idle
  | "offline" -> Some KH_offline
  | "stale" -> Some KH_stale
  | "degraded" -> Some KH_degraded
  | "zombie" -> Some KH_zombie
  | "dead" -> Some KH_dead
  | _ -> None

let keeper_health_or_offline ~source s =
  match keeper_health_of_string_opt s with
  | Some h -> h
  | None ->
      Log.Keeper.warn
        "%s: unknown keeper health wire string %S -> KH_offline fallback (#8670)"
        source
        s;
      KH_offline

let keeper_continuity_to_string = function
  | Continuity_healthy -> "healthy"
  | Continuity_recovering -> "recovering"
  | Continuity_not_running -> "not_running"

let pipeline_stage_of_phase (phase : Keeper_state_machine.phase) : string =
  match phase with
  | Keeper_state_machine.Offline -> "offline"
  | Keeper_state_machine.Running -> "idle"
  | Keeper_state_machine.Failing -> "failing"
  | Keeper_state_machine.Overflowed -> "overflowed"
  | Keeper_state_machine.Compacting -> "compacting"
  | Keeper_state_machine.HandingOff -> "handoff"
  | Keeper_state_machine.Draining -> "draining"
  | Keeper_state_machine.Paused -> "paused"
  | Keeper_state_machine.Stopped -> "offline"
  | Keeper_state_machine.Crashed -> "crashed"
  | Keeper_state_machine.Restarting -> "restarting"
  | Keeper_state_machine.Dead | Keeper_state_machine.Zombie -> "offline"
