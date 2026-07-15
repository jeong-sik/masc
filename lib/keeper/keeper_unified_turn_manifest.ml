(** Manifest append helpers for [Keeper_unified_turn].

    Extracted from [run_keeper_cycle] so the orchestrator does not own
    manifest-construction details.

    @since God file decomposition *)

open Keeper_meta_contract
open Keeper_unified_turn_types
open Keeper_unified_turn_phase_plan

let prepare_manifest
      ~runtime_manifest_context
      ~turn_start
      ~(turn_state : turn_state)
      ?status
      ?decision
      ?runtime_id
      ?clock_refs
      ?compaction_source
      ?checkpoint_path
      event
  =
  let decision, manifest_seq =
    let decision =
      match decision with
      | Some value -> value
      | None -> `Assoc []
    in
    match clock_refs with
    | Some value ->
      ( Some (Keeper_runtime_manifest.with_clock_refs ~clock_refs:value decision)
      , turn_state.manifest_seq )
    | None ->
      let manifest_seq = turn_state.manifest_seq + 1 in
      let elapsed_ms =
        let ns =
          Mtime.Span.to_uint64_ns
            (Mtime.span turn_start (Mtime_clock.now ()))
        in
        Some (Int64.to_int (Int64.div ns 1_000_000L))
      in
      let clock_refs =
        Keeper_runtime_manifest.clock_refs_for_context
          runtime_manifest_context
          ~event
          ?elapsed_ms
          ~logical_seq:manifest_seq
          ?compaction_source
          ()
      in
      Some (Keeper_runtime_manifest.with_clock_refs ~clock_refs decision), manifest_seq
  in
  ( Keeper_runtime_manifest.make_for_context
      runtime_manifest_context
      ~event
      ?runtime_id
      ?status
      ?decision
      ?checkpoint_path
      ()
  , { turn_state with manifest_seq } )
;;

let append_manifest
      ~config
      ~runtime_manifest_context
      ~turn_start
      ~turn_state
      ?status
      ?decision
      ?runtime_id
      ?clock_refs
      ?compaction_source
      ?checkpoint_path
      ~site
      event
  =
  let manifest, turn_state =
    prepare_manifest
      ~runtime_manifest_context
      ~turn_start
      ~turn_state
      ?status
      ?decision
      ?runtime_id
      ?clock_refs
      ?compaction_source
      ?checkpoint_path
      event
  in
  Keeper_runtime_manifest.append_best_effort ~site config manifest;
  turn_state
;;

let append_manifest_once
      ~operation_id
      ~config
      ~runtime_manifest_context
      ~turn_start
      ~turn_state
      ?status
      ?decision
      ?runtime_id
      ?clock_refs
      ?compaction_source
      ?checkpoint_path
      event
  =
  let manifest, turn_state =
    prepare_manifest
      ~runtime_manifest_context
      ~turn_start
      ~turn_state
      ?status
      ?decision
      ?runtime_id
      ?clock_refs
      ?compaction_source
      ?checkpoint_path
      event
  in
  match Keeper_runtime_manifest.append_once ~operation_id config manifest with
  | Ok
      ( Keeper_runtime_manifest.Appended
      | Keeper_runtime_manifest.Already_present ) ->
    Ok turn_state
  | Error _ as error -> error
;;

let append_phase_gate_decision
      ~config
      ~runtime_manifest_context
      ~turn_start
      ~turn_state
      turn_plan
  =
  append_manifest
    ~config
    ~runtime_manifest_context
    ~turn_start
    ~turn_state
    ~site:"phase_gate_decided"
    ~status:(turn_plan_manifest_status turn_plan)
    ~decision:(turn_plan_manifest_decision turn_plan)
    Keeper_runtime_manifest.Phase_gate_decided
;;
