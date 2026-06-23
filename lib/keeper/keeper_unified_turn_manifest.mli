(** Manifest append helpers for [Keeper_unified_turn].

    Extracted from [run_keeper_cycle] so the orchestrator does not own
    manifest-construction details. These functions are effectful: they read
    the monotonic clock ([Mtime_clock.now]) for elapsed-time clock refs and
    perform best-effort manifest append I/O
    ([Keeper_runtime_manifest.append_best_effort]). The
    [Keeper_unified_turn_types.turn_state] is threaded immutably — each call
    returns a new value with an incremented [manifest_seq] rather than mutating
    in place.

    @since God file decomposition *)

open Keeper_meta_contract

val append_manifest
  :  config:Workspace.config
  -> runtime_manifest_context:Keeper_runtime_manifest.turn_context
  -> turn_start:Mtime.t
  -> turn_state:Keeper_unified_turn_types.turn_state
  -> ?status:string
  -> ?decision:Yojson.Safe.t
  -> ?runtime_id:string
  -> ?clock_refs:Yojson.Safe.t
  -> site:string
  -> Keeper_runtime_manifest.event_kind
  -> Keeper_unified_turn_types.turn_state
(** Append a manifest row for [event] and return [turn_state] with an
    incremented [manifest_seq]. [clock_refs] is computed automatically
    when omitted. *)

val append_phase_gate_decision
  :  config:Workspace.config
  -> runtime_manifest_context:Keeper_runtime_manifest.turn_context
  -> turn_start:Mtime.t
  -> turn_state:Keeper_unified_turn_types.turn_state
  -> Keeper_unified_turn_phase_plan.turn_plan
  -> Keeper_unified_turn_types.turn_state
(** Convenience wrapper around [append_manifest] for phase-gate rows. *)
