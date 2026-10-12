module Exact_flow = Keeper_board_attention_exact_flow
module Partition = Keeper_board_attention_partition

let running_progress partition =
  match partition.Partition.state with
  | Partition.Running { progress; _ } -> Some progress
  | Partition.Ready
  | Partition.Completed _
  | Partition.Settled _
  | Partition.Abandoned _
  | Partition.Blocked _ -> None
;;

let classified_progress partition =
  match running_progress partition with
  | Some ((Partition.Bound _ | Partition.Advancing _) as progress) -> Some progress
  | Some Partition.Unbound | None -> None
;;

let partition_provenance
      (provenance : Exact_flow.attempt_provenance)
      : Partition.exact_provenance
  =
  { slot_id = provenance.slot_id
  ; call_id = provenance.call_id
  ; plan_fingerprint = provenance.plan_fingerprint
  ; request_body_sha256 = provenance.request_body_sha256
  }
;;

let partition_candidate_visit (visit : Exact_flow.candidate_visit) :
    Partition.candidate_visit
  =
  { flow_id = visit.flow_id
  ; ordinal = visit.ordinal
  ; slot_id = visit.slot_id
  ; catalog_generation_fingerprint = visit.catalog_generation_fingerprint
  ; catalog_evidence_sha256 = visit.catalog_evidence_sha256
  ; target_identity_fingerprint = visit.target_identity_fingerprint
  }
;;

let partition_advance_source = function
  | Exact_flow.Executed_failure provenance ->
    Partition.Executed_failure (partition_provenance provenance)
  | Exact_flow.Predispatch_rejection visit ->
    Partition.Predispatch_rejection (partition_candidate_visit visit)
;;

let setup_error_detail = function
  | Exact_flow.Network_unavailable -> "network context unavailable"
  | Exact_flow.Candidate_not_pending -> "candidate is no longer pending"
  | Exact_flow.Prompt_contract_unavailable detail ->
    "prompt contract unavailable: " ^ detail
  | Exact_flow.Registry_unavailable -> "runtime registry unavailable"
  | Exact_flow.Lane_unavailable -> "board exact lane unavailable"
  | Exact_flow.Lane_preference_unavailable detail ->
    "board exact lane preference unavailable: " ^ detail
  | Exact_flow.Lane_resolved_without_slots ->
    "board exact lane has no admitted slots"
  | Exact_flow.Candidate_invalid { position; slot_id = _ } ->
    Printf.sprintf "board exact lane slot %d has invalid identity" position
  | Exact_flow.Flow_snapshot_failed -> "AGENT_CORE exact-flow snapshot failed"
  | Exact_flow.Flow_start_failed -> "AGENT_CORE exact-flow start failed"
;;

let exact_provenance_equal
      (left : Partition.exact_provenance)
      (right : Partition.exact_provenance)
  =
  String.equal left.Partition.slot_id right.Partition.slot_id
  && String.equal left.call_id right.call_id
  && String.equal left.plan_fingerprint right.plan_fingerprint
  && String.equal left.request_body_sha256 right.request_body_sha256
;;

let candidate_visit_equal
      (left : Partition.candidate_visit)
      (right : Partition.candidate_visit)
  =
  String.equal left.flow_id right.flow_id
  && Int.equal left.ordinal right.ordinal
  && String.equal left.slot_id right.slot_id
  && String.equal
       left.catalog_generation_fingerprint
       right.catalog_generation_fingerprint
  && String.equal left.catalog_evidence_sha256 right.catalog_evidence_sha256
  && String.equal
       left.target_identity_fingerprint
       right.target_identity_fingerprint
;;

let callback_invariant operation cause =
  Partition.Durable_partition_invariant
    (Printf.sprintf "%s callback disagrees with durable progress: %s" operation cause)
;;

let before_dispatch_failure_reason partition ~cause ~current =
  let projected = partition_provenance current in
  match running_progress partition with
  | Some (Partition.Bound durable as progress)
    when exact_provenance_equal durable projected ->
    Partition.Exact_execution_quarantined progress
  | Some (Partition.Advancing { next; _ } as progress)
    when String.equal next.slot_id projected.slot_id ->
    Partition.Exact_execution_quarantined progress
  | Some Partition.Unbound
  | Some (Partition.Bound _)
  | Some (Partition.Advancing _)
  | None -> callback_invariant "before-dispatch" cause
;;

let before_advance_failure_reason partition ~cause ~failed ~next =
  let source = partition_advance_source failed in
  let next = partition_candidate_visit next in
  match running_progress partition with
  | Some
      (Partition.Advancing
         { execution_anchor = Some anchor; last_from = None; next = durable_next }
       as progress)
    when (match source with
          | Partition.Executed_failure failed ->
            exact_provenance_equal anchor failed
            && candidate_visit_equal durable_next next
          | Partition.Predispatch_rejection _ -> false) ->
    Partition.Exact_execution_quarantined progress
  | Some
      (Partition.Advancing
         { execution_anchor = _
         ; last_from = Some durable_from
         ; next = durable_next
         } as progress)
    when (match source with
          | Partition.Predispatch_rejection rejected ->
            candidate_visit_equal durable_from rejected
            && candidate_visit_equal durable_next next
          | Partition.Executed_failure _ -> false) ->
    Partition.Exact_execution_quarantined progress
  | Some (Partition.Advancing _ as progress) ->
    Partition.Exact_execution_quarantined progress
  | Some (Partition.Bound durable as progress) ->
    (match source with
     | Partition.Executed_failure failed
       when exact_provenance_equal durable failed ->
       Partition.Exact_execution_quarantined progress
     | Partition.Executed_failure _
     | Partition.Predispatch_rejection _ ->
       callback_invariant "before-advance" cause)
  | Some Partition.Unbound ->
    (match source with
     | Partition.Predispatch_rejection last_from ->
       Partition.Exact_execution_quarantined
         (Partition.Advancing
            { execution_anchor = None
            ; last_from = Some last_from
            ; next
            })
     | Partition.Executed_failure _ -> callback_invariant "before-advance" cause)
  | None -> callback_invariant "before-advance" cause
;;

type execution_disposition =
  | Execution_blocked of Partition.blocked_reason
  | Execution_deferred of { detail : string }
      (** Every slot the lane walked refused for its account's standing, so
          the same candidate can be judged once one frees. On 2026-09-25
          every slot of this lane was spent and 1,459 candidates were
          quarantined as [Exact_lane_exhausted] instead of waiting. *)

type lane_standing =
  | Lane_resting
  | Lane_failed

let http_walk_standing = function
  | Agent_core.Exact_output.Every_binding_resting -> Lane_resting
  | Agent_core.Exact_output.Not_every_binding_resting -> Lane_failed
;;

let cli_tail_standing failures =
  match failures with
  | [] -> Lane_failed
  | _ :: _ ->
    if List.for_all Keeper_lane_cli_oneshot.refused_for_binding_rest failures
    then Lane_resting
    else Lane_failed
;;

let both_resting left right =
  match left, right with
  | Lane_resting, Lane_resting -> Lane_resting
  | Lane_failed, (Lane_resting | Lane_failed) | Lane_resting, Lane_failed ->
    Lane_failed
;;

(* A lane waits only when every slot it walked refused for its account's
   standing: an HTTP rate limit, quota, full capacity or payment refusal, or a
   network failure before the request was dispatched (AGENT_CORE's
   [Every_binding_resting]), then every CLI slot's typed quota or usage-limit
   refusal. Anything else can be about this input, and a
   waiting root is claimed first again (Ready roots are claimed oldest
   first), so one input no slot can take would hold every newer candidate of
   this Keeper behind it. Those stay Blocked and quarantined. *)
let lane_disposition partition exhausted = function
  | Lane_resting -> Execution_deferred { detail = Exact_flow.error_detail exhausted }
  | Lane_failed ->
    Execution_blocked
      (Partition.Exact_lane_exhausted
         { detail = Exact_flow.error_detail exhausted
         ; progress = classified_progress partition
         })
;;

let execution_disposition partition = function
  | Exact_flow.Flow_already_started _ ->
    Execution_blocked (Partition.Exact_flow_replayed (classified_progress partition))
  | Exact_flow.Before_dispatch_persistence_failed
      { cause; current; evidence = _ } ->
    Execution_blocked
      (before_dispatch_failure_reason partition ~cause ~current)
  | Exact_flow.Before_advance_persistence_failed
      { cause; failed; next; evidence = _ } ->
    Execution_blocked
      (before_advance_failure_reason partition ~cause ~failed ~next)
  | Exact_flow.Cli_slots_exhausted
      { prior_error = Some (Exact_flow.Domain_output_invalid detail)
      ; failures = _
      } ->
    Execution_blocked
      (Partition.Domain_output_invalid
         { detail; progress = classified_progress partition })
  | Exact_flow.Cli_slots_exhausted
      { prior_error = Some (Exact_flow.Provenance_mismatch detail)
      ; failures = _
      } ->
    Execution_blocked
      (Partition.Execution_provenance_mismatch
         { detail; progress = classified_progress partition })
  | Exact_flow.Providers_exhausted { binding_standing; attempts = _; detail = _ } as
    exhausted -> lane_disposition partition exhausted (http_walk_standing binding_standing)
  | Exact_flow.Cli_slots_exhausted { prior_error = None; failures } as exhausted ->
    lane_disposition partition exhausted (cli_tail_standing failures)
  | Exact_flow.Cli_slots_exhausted
      { prior_error =
          Some
            (Exact_flow.Providers_exhausted
              { binding_standing; attempts = _; detail = _ })
      ; failures
      } as exhausted ->
    lane_disposition
      partition
      exhausted
      (both_resting (http_walk_standing binding_standing) (cli_tail_standing failures))
  | Exact_flow.Cli_slots_exhausted
      { prior_error =
          Some
            ( Exact_flow.Flow_already_started _
            | Exact_flow.Before_dispatch_persistence_failed _
            | Exact_flow.Before_advance_persistence_failed _
            | Exact_flow.Cli_slots_exhausted _
            | Exact_flow.Flow_bookkeeping_failed _ )
      ; failures = _
      } as exhausted -> lane_disposition partition exhausted Lane_failed
  | Exact_flow.Flow_bookkeeping_failed _ as failed ->
    Execution_blocked
      (Partition.Exact_flow_bookkeeping_failed
         { detail = Exact_flow.error_detail failed
         ; progress = classified_progress partition
         })
  | Exact_flow.Provenance_mismatch detail ->
    Execution_blocked
      (Partition.Execution_provenance_mismatch
         { detail; progress = classified_progress partition })
  | Exact_flow.Domain_output_invalid detail ->
    Execution_blocked
      (Partition.Domain_output_invalid
         { detail; progress = classified_progress partition })
;;
