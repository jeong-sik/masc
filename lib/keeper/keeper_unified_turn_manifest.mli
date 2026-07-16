(** Manifest append helpers for [Keeper_unified_turn].

    Extracted from [run_keeper_cycle] so the orchestrator does not own
    manifest-construction details. These functions perform best-effort manifest
    append I/O ([Keeper_runtime_manifest.append_best_effort]). When
    [clock_refs] is omitted they also read the monotonic clock
    ([Mtime_clock.now]) for elapsed-time clock refs and return a new
    [turn_state] whose [manifest_seq] is incremented; when [clock_refs] is
    supplied explicitly the provided refs are used and [manifest_seq] is left
    unchanged. The [Keeper_unified_turn_types.turn_state] is threaded
    immutably in both cases.

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
  -> ?compaction_source:string
  -> ?checkpoint_path:string
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
