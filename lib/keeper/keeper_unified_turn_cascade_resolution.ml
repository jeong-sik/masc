(* Keeper_unified_turn_cascade_resolution — RFC-0136 PR-2.

   Extracted from keeper_unified_turn.ml (L143-210) during the
   run_keeper_cycle stage decomposition. Owns the [selected_item]
   override of [meta.cascade_ref], the [Keeper_cascade_routing.select_cascade]
   call, and the [fail_open_local_only_when_unavailable] hardening
   of the resolved cascade. *)

open Keeper_types
open Keeper_exec_context

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
  let meta =
    match selected_item with
    | Some (group, item) ->
      let cascade_ref = Some Cascade_ref.{ group; item = Some item.id } in
      { meta with cascade_ref }
    | None -> meta
  in
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
    Keeper_metrics.metric_keeper_fsm_edge_transitions
    ~labels:[ "edge", "ksm_to_kcl_routing" ]
    ();
  let routed_meta = set_cascade_name routing.effective_cascade meta in
  let routed_labels =
    Keeper_model_labels.configured_model_labels_of_meta routed_meta
  in
  let resolved_cascade =
    Keeper_turn_liveness.fail_open_local_only_when_unavailable
      ~base_cascade:(cascade_name_of_meta meta)
      ~effective_cascade:routing.effective_cascade
      routed_labels
  in
  Log.Keeper.debug
    "%s: cascade routing: %s -> %s (reason: %s)"
    meta.name
    (cascade_name_of_meta meta)
    routing.effective_cascade
    routing.reason;
  if not (String.equal resolved_cascade routing.effective_cascade)
  then
    Log.Keeper.warn
      "%s: local_only unavailable for labels [%s]; falling back to base cascade %s"
      meta.name
      (String.concat ", " routed_labels)
      resolved_cascade;
  let decision =
    `Assoc
      (Keeper_cascade_engine.manifest_fields
         Keeper_cascade_engine.keeper_managed
       @ [
         ("base_cascade", `String (cascade_name_of_meta meta));
         ("effective_cascade", `String routing.effective_cascade);
         ("resolved_cascade", `String resolved_cascade);
         ("routing_reason", `String routing.reason);
         ( "fail_opened",
           `Bool
             (not (String.equal resolved_cascade routing.effective_cascade))
         );
       ])
  in
  append_cascade_routed_manifest ~cascade_name:resolved_cascade ~decision;
  { resolved_meta = routed_meta; resolved_cascade }
