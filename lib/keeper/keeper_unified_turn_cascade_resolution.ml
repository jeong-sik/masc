(* Keeper_unified_turn_cascade_resolution — RFC-0136 PR-2.

   Extracted from keeper_unified_turn.ml (L143-210) during the
   run_keeper_cycle stage decomposition. Owns the [selected_item]
   override of [meta.cascade_ref], the [Keeper_cascade_routing.select_cascade]
   call, and the [fail_open_phase_buffer_when_unavailable] hardening
   of the resolved cascade. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

type cascade_resolution =
  { resolved_meta : keeper_meta
  ; resolved_cascade : string
  }

let resolve_cascade
      ~(meta : keeper_meta)
      ~(phase_opt : Keeper_state_machine.phase option)
      ~(selected_item : (string * Cascade_ref.cascade_item) option)
      ~(append_cascade_routed_manifest :
         cascade_name:string -> decision:Yojson.Safe.t -> unit)
  =
  (* RFC-0041 Phase B4: when a specific item was selected by the
     proactive router, override (cascade_name_of_meta meta) so downstream
     cascade resolution uses the item's group. *)
  (* cascade_ref removed — Runtime model replaces cascade routing. *)
  let phase =
    match phase_opt with
    | Some p -> p
    | None ->
      (* The phase-gate stage fails closed on [None] before cascade
         routing.  Keep this fallback only to preserve exhaustiveness
         if the match shape changes. *)
      Keeper_state_machine.Failing
  in
  let routing =
    Keeper_cascade_routing.select_cascade
      ~base_cascade:(cascade_name_of_meta meta)
      ~phase
  in
  Prometheus.inc_counter
    Keeper_metrics.(to_string FsmEdgeTransitions)
    ~labels:[ "edge", "ksm_to_kcl_routing" ]
    ();
  (* cascade→Runtime 숙청: phase_buffer liveness fail-open 제거. 단일 runtime
     에서 effective == base 라 fail_open 은 항상 effective 를 그대로 반환했다 —
     resolved_cascade 는 곧 routing.effective_cascade. *)
  let resolved_cascade = routing.effective_cascade in
  Log.Keeper.debug
    "%s: cascade routing: %s -> %s (reason: %s)"
    meta.name
    (cascade_name_of_meta meta)
    routing.effective_cascade
    routing.reason;
  let decision =
    `Assoc
      (Keeper_cascade_engine.manifest_fields
         Keeper_cascade_engine.keeper_managed
       @ [
         ("base_cascade", `String (cascade_name_of_meta meta));
         ("effective_cascade", `String routing.effective_cascade);
         ("resolved_cascade", `String resolved_cascade);
         ("routing_reason", `String routing.reason);
         (* fail_opened: phase_buffer liveness fail-open 제거 후 항상 false.
            manifest schema 호환을 위해 필드는 유지. *)
         ("fail_opened", `Bool false);
       ])
  in
  append_cascade_routed_manifest ~cascade_name:resolved_cascade ~decision;
  { resolved_meta = meta; resolved_cascade }
