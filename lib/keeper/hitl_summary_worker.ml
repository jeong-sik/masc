open Keeper_approval_queue

module Exact_output = Agent_sdk.Exact_output
module Registry = Runtime_exact_output_registry
module Schema = Keeper_structured_output_schema

let summary_version = 2
let lane_id = "hitl_auto_judge"

let system_prompt () =
  Prompt_registry.render_prompt_template Keeper_prompt_names.gate_judgment []
;;

let ( let* ) = Result.bind

(* ── Metrics ────────────────────────────────────── *)

let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string HitlSummaryOutcomes)
    ~help:
      "Total HITL exact-output flow outcomes classified by [outcome]. MASC \
       records domain and durability outcomes only; provider selection, \
       admission, dispatch, and failover remain OAS-owned."
    ()
;;

let record_outcome outcome =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string HitlSummaryOutcomes)
    ~labels:[ "outcome", outcome ]
    ()
;;

(* ── Immutable MASC request ─────────────────────── *)

type context_bundle_error = Exact_request_context_unavailable

let context_bundle_error_to_string = function
  | Exact_request_context_unavailable ->
    "HITL summary: exact outer-turn request context is unavailable"
;;

let build_context_bundle ~(entry : pending_approval) =
  match entry.request_context with
  | None -> Error Exact_request_context_unavailable
  | Some request_context ->
    Ok
      (`Assoc
         [ "keeper_name", `String entry.keeper_name
         ; "tool_name", `String entry.tool_name
         ; "turn_id", Json_util.int_opt_to_json entry.turn_id
         ; "task_id", Json_util.string_opt_to_json entry.task_id
         ; "goal_id", Json_util.string_opt_to_json entry.goal_id
         ; "goal_ids", `List (List.map (fun goal -> `String goal) entry.goal_ids)
         ; "input", entry.input
         ; "request_context", request_context
         ])
;;

let message role text = Agent_sdk.Types.text_message role text

let messages_for_summary ~system_prompt ~context_bundle =
  [ message Agent_sdk.Types.System system_prompt
  ; message Agent_sdk.Types.User (Yojson.Safe.to_string context_bundle)
  ]
;;

let output_requirement =
  Exact_output.make_output_requirement
    ~schema:Schema.hitl_context_summary_schema
    ~minimum_guarantee:Exact_output.Json_syntax
;;

type prepared_flow =
  { entry : pending_approval
  ; generated_at : float
  ; attempt : Exact_output.flow_attempt
  }

let registry_error error =
  "HITL exact-output registry unavailable: " ^ Registry.publication_error_to_string error
;;

let lane_error error =
  "HITL exact-output lane unavailable: " ^ Registry.lane_resolution_error_to_string error
;;

let flow_candidates selected_slots =
  let rec loop candidates = function
    | [] -> Ok (List.rev candidates)
    | (slot : Registry.selected_slot) :: rest ->
      (match Exact_output.make_flow_candidate ~id:slot.slot_id ~target:slot.target with
       | Ok candidate -> loop (candidate :: candidates) rest
       | Error Exact_output.Blank_flow_candidate_id ->
         Error "HITL exact-output lane contains a blank slot id")
  in
  loop [] selected_slots
;;

let prepare_flow ~(entry : pending_approval) =
  let* context_bundle =
    build_context_bundle ~entry
    |> Result.map_error context_bundle_error_to_string
  in
  let* system_prompt =
    system_prompt ()
    |> Result.map_error (fun detail ->
      "HITL Gate judgment prompt unavailable: " ^ detail)
  in
  let* registry =
    Registry.current ()
    |> Result.map_error registry_error
  in
  let* resolved =
    Registry.resolve_lane registry ~lane_id
    |> Result.map_error lane_error
  in
  let* candidates = flow_candidates resolved.selected_slots in
  let* ready_flow =
    match candidates with
    | [] -> Error "HITL exact-output lane has no usable candidates"
    | first :: rest ->
      Exact_output.admit_flow
        ~first
        ~rest
        ~messages:(messages_for_summary ~system_prompt ~context_bundle)
        output_requirement
      |> Result.map_error (fun _ ->
        "HITL exact-output flow admitted no candidates")
  in
  let* attempt =
    Exact_output.start_flow ready_flow
    |> Result.map_error (fun _ ->
      "HITL exact-output flow attempt allocation failed")
  in
  Ok { entry; generated_at = Time_compat.now (); attempt }
;;

let readiness () =
  let* (_ : string) = system_prompt () in
  let* registry = Registry.current () |> Result.map_error registry_error in
  let* (_ : Registry.resolved_lane) =
    Registry.resolve_lane registry ~lane_id
    |> Result.map_error lane_error
  in
  Ok ()
;;

(* ── MASC domain validation ─────────────────────── *)

let parse_summary ~generated_at ~model_run_id json =
  match json with
  | `Assoc fields ->
    hitl_context_summary_of_yojson_with_error
      (`Assoc
         ([ "summary_version", `Int summary_version
          ; "generated_at", `Float generated_at
          ; "model_run_id", `String model_run_id
          ]
          @ fields))
  | _ -> Error "HITL summary model output must be a JSON object"
;;

(* ── Exact queue identity and durability ────────── *)

type exact_identity =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

type strict_snapshot_writer =
  Keeper_approval_queue.For_testing.strict_snapshot_writer

type exact_queue_writers =
  { bind_writer : strict_snapshot_writer option
  ; release_writer : strict_snapshot_writer option
  ; complete_writer : strict_snapshot_writer option
  }

let production_exact_queue_writers =
  { bind_writer = None; release_writer = None; complete_writer = None }
;;

let exact_identity_of_candidate
      (candidate : Exact_output.flow_attempt_receipt)
  =
  let receipt = candidate.receipt in
  { slot_id = candidate.identity.candidate_id
  ; call_id =
      receipt
      |> Exact_output.receipt_call_id
      |> Exact_output.call_id_to_string
  ; plan_fingerprint = Exact_output.receipt_plan_fingerprint receipt
  ; request_body_sha256 =
      Exact_output.receipt_request_body_sha256 receipt
  }
;;

let exact_identity_of_binding (binding : exact_attempt_binding) =
  { slot_id = binding.slot_id
  ; call_id = binding.call_id
  ; plan_fingerprint = binding.plan_fingerprint
  ; request_body_sha256 = binding.request_body_sha256
  }
;;

let with_exact_identity
      (entry : pending_approval)
      (identity : exact_identity)
      transition
  =
  transition
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
    ~slot_id:identity.slot_id
    ~call_id:identity.call_id
    ~plan_fingerprint:identity.plan_fingerprint
    ~request_body_sha256:identity.request_body_sha256
;;

let bind_exact_attempt
      writers
      (entry : pending_approval)
      (identity : exact_identity)
  =
  match writers.bind_writer with
  | None ->
    with_exact_identity
      entry
      identity
      Keeper_approval_queue.bind_summary_exact_attempt
  | Some save_file_atomic_strict_staged ->
    with_exact_identity
      entry
      identity
      (Keeper_approval_queue.For_testing.bind_summary_exact_attempt_with_writer
         ~save_file_atomic_strict_staged)
;;

let release_exact_attempt
      writers
      (entry : pending_approval)
      (identity : exact_identity)
  =
  match writers.release_writer with
  | None ->
    with_exact_identity
      entry
      identity
      Keeper_approval_queue.release_summary_exact_attempt_before_dispatch
  | Some save_file_atomic_strict_staged ->
    with_exact_identity
      entry
      identity
      (Keeper_approval_queue.For_testing
       .release_summary_exact_attempt_before_dispatch_with_writer
         ~save_file_atomic_strict_staged)
;;

let complete_exact_attempt
      writers
      (entry : pending_approval)
      (identity : exact_identity)
      summary
  =
  match writers.complete_writer with
  | None ->
    with_exact_identity
      entry
      identity
      (fun
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
      ->
        Keeper_approval_queue.complete_summary_exact_attempt
          ~id
          ~input_hash
          ~sequence
          ~slot_id
          ~call_id
          ~plan_fingerprint
          ~request_body_sha256
          ~summary)
  | Some save_file_atomic_strict_staged ->
    with_exact_identity
      entry
      identity
      (fun
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
      ->
        Keeper_approval_queue.For_testing
        .complete_summary_exact_attempt_with_writer
          ~save_file_atomic_strict_staged
          ~id
          ~input_hash
          ~sequence
          ~slot_id
          ~call_id
          ~plan_fingerprint
          ~request_body_sha256
          ~summary)
;;

type flow_callback_error =
  | Exact_bind_failed of string
  | Exact_bind_sync_unconfirmed of string
  | Exact_release_failed of string
  | Exact_release_sync_unconfirmed of string

let flow_callback_error_to_string = function
  | Exact_bind_failed detail -> "exact bind failed: " ^ detail
  | Exact_bind_sync_unconfirmed detail ->
    "exact bind sync unconfirmed: " ^ detail
  | Exact_release_failed detail -> "exact release failed: " ^ detail
  | Exact_release_sync_unconfirmed detail ->
    "exact release sync unconfirmed: " ^ detail
;;

let before_dispatch ~queue_writers (entry : pending_approval) candidate =
  let identity = exact_identity_of_candidate candidate in
  match bind_exact_attempt queue_writers entry identity with
  | Ok { write_outcome = Fsync_completed; _ } -> Ok ()
  | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
    Error (Exact_bind_sync_unconfirmed detail)
  | Error error ->
    Error
      (Exact_bind_failed
         (Keeper_approval_queue.exact_attempt_error_to_string error))
;;

let before_advance
      ~queue_writers
      (entry : pending_approval)
      ~failed
      ~failure:_
      ~next:_
  =
  let identity = exact_identity_of_candidate failed in
  match release_exact_attempt queue_writers entry identity with
  | Ok { write_outcome = Fsync_completed; _ } -> Ok ()
  | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
    Error (Exact_release_sync_unconfirmed detail)
  | Error error ->
    Error
      (Exact_release_failed
         (Keeper_approval_queue.exact_attempt_error_to_string error))
;;

let log_exact_error (entry : pending_approval) operation detail =
  Log.Keeper.warn
    ~keeper_name:entry.keeper_name
    "HITL exact-output %s failed approval_id=%s: %s"
    operation
    entry.id
    detail
;;

exception Exact_terminalization_persistence_failed of string

let signal_terminalization_persistence_failure
      (entry : pending_approval)
      operation
      detail
  =
  record_outcome "exact_terminal_persistence_failure";
  log_exact_error entry operation detail;
  raise
    (Exact_terminalization_persistence_failed
       (Printf.sprintf
          "HITL exact-output %s failed approval_id=%s: %s"
          operation
          entry.id
          detail))
;;

let mark_unbound_failure (entry : pending_approval) reason =
  match
    Keeper_approval_queue.mark_summary_failed
      ~id:entry.id
      ~reason
      ~retryable:false
  with
  | Ok true -> Ok ()
  | Ok false -> Error "unbound failure transition did not change state"
  | Error error ->
    Error (Keeper_approval_queue.summary_transition_error_to_string error)
;;

let quarantine_identity_result
      (entry : pending_approval)
      (identity : exact_identity)
      cause
  =
  match
    with_exact_identity
      entry
      identity
      (fun
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
      ->
        Keeper_approval_queue.quarantine_summary_exact_attempt
          ~id
          ~input_hash
          ~sequence
          ~slot_id
          ~call_id
          ~plan_fingerprint
          ~request_body_sha256
          ~cause)
  with
  | Ok { write_outcome = Fsync_completed; _ } -> Ok ()
  | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
    Error ("quarantine durability confirmation failed: " ^ detail)
  | Error error ->
    Error (Keeper_approval_queue.exact_attempt_error_to_string error)
;;

let quarantine_identity
      (entry : pending_approval)
      (identity : exact_identity)
      cause
  =
  match quarantine_identity_result entry identity cause with
  | Ok () -> ()
  | Error detail ->
    signal_terminalization_persistence_failure
      entry
      "quarantine persistence"
      detail
;;

let quarantine_candidate (entry : pending_approval) candidate cause =
  quarantine_identity entry (exact_identity_of_candidate candidate) cause
;;

let settle_current (entry : pending_approval) ~reason ~cause =
  match Keeper_approval_queue.get_pending_entry ~id:entry.id with
  | None -> Ok ()
  | Some { exact_attempt = Exact_unbound; _ } ->
    mark_unbound_failure entry reason
  | Some { exact_attempt = Exact_bound binding; _ } ->
    quarantine_identity_result entry (exact_identity_of_binding binding) cause
;;

let settle_current_or_signal (entry : pending_approval) ~reason ~cause =
  match settle_current entry ~reason ~cause with
  | Ok () -> ()
  | Error detail ->
    signal_terminalization_persistence_failure
      entry
      "terminalization persistence"
      detail
;;

let fail_final_before_dispatch (entry : pending_approval) candidate reason =
  let identity = exact_identity_of_candidate candidate in
  match
    with_exact_identity
      entry
      identity
      (fun
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
      ->
        Keeper_approval_queue.fail_summary_exact_attempt_before_dispatch
          ~id
          ~input_hash
          ~sequence
          ~slot_id
          ~call_id
          ~plan_fingerprint
          ~request_body_sha256
          ~reason
          ~retryable:false)
  with
  | Ok { write_outcome = Fsync_completed; _ } -> ()
  | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
    signal_terminalization_persistence_failure
      entry
      "final pre-dispatch failure persistence"
      detail
  | Error error ->
    signal_terminalization_persistence_failure
      entry
      "final pre-dispatch failure persistence"
      (Keeper_approval_queue.exact_attempt_error_to_string error)
;;

(* ── OAS evidence verification ──────────────────── *)

let same_catalog_generation left right =
  String.equal
    (Exact_output.catalog_generation_fingerprint left)
    (Exact_output.catalog_generation_fingerprint right)
;;

let same_catalog_evidence left right =
  String.equal
    (Exact_output.catalog_evidence_sha256 left)
    (Exact_output.catalog_evidence_sha256 right)
;;

let same_target_identity left right =
  String.equal
    (Exact_output.target_identity_fingerprint left)
    (Exact_output.target_identity_fingerprint right)
;;

let receipt_matches
      (left : Exact_output.receipt)
      (right : Exact_output.receipt)
  =
  String.equal
    (left |> Exact_output.receipt_call_id |> Exact_output.call_id_to_string)
    (right |> Exact_output.receipt_call_id |> Exact_output.call_id_to_string)
  && String.equal
       (Exact_output.receipt_plan_fingerprint left)
       (Exact_output.receipt_plan_fingerprint right)
  && String.equal
       (Exact_output.receipt_request_body_sha256 left)
       (Exact_output.receipt_request_body_sha256 right)
  && same_catalog_generation
       (Exact_output.receipt_catalog_generation left)
       (Exact_output.receipt_catalog_generation right)
  && same_catalog_evidence
       (Exact_output.receipt_catalog_evidence left)
       (Exact_output.receipt_catalog_evidence right)
  && same_target_identity
       (Exact_output.receipt_target_identity left)
       (Exact_output.receipt_target_identity right)
;;

let success_provenance_matches (flow_success : Exact_output.flow_success) =
  let candidate = flow_success.candidate in
  let identity = candidate.identity in
  let success = flow_success.success in
  let provenance = success.provenance in
  String.equal
    (Exact_output.call_id_to_string success.call_id)
    (candidate.receipt
     |> Exact_output.receipt_call_id
     |> Exact_output.call_id_to_string)
  && receipt_matches candidate.receipt success.receipt
  && same_catalog_generation
       identity.catalog_generation
       (Exact_output.receipt_catalog_generation candidate.receipt)
  && same_catalog_evidence
       identity.catalog_evidence
       (Exact_output.receipt_catalog_evidence candidate.receipt)
  && same_target_identity
       identity.target_identity
       (Exact_output.receipt_target_identity candidate.receipt)
  && same_catalog_generation
       identity.catalog_generation
       provenance.catalog_generation
  && same_catalog_evidence identity.catalog_evidence provenance.catalog_evidence
  && same_target_identity identity.target_identity provenance.target_identity
;;

(* ── Flow terminalization ───────────────────────── *)

let handle_success
      ~queue_writers
      (prepared : prepared_flow)
      ~on_summary
      (flow_success : Exact_output.flow_success)
  =
  let entry = prepared.entry in
  let candidate = flow_success.candidate in
  if not (success_provenance_matches flow_success)
  then (
    record_outcome "exact_provenance_mismatch";
    quarantine_candidate entry candidate Exact_flow_execution_failed)
  else
    let call_id =
      candidate.receipt
      |> Exact_output.receipt_call_id
      |> Exact_output.call_id_to_string
    in
    match
      parse_summary
        ~generated_at:prepared.generated_at
        ~model_run_id:call_id
        flow_success.success.output
    with
    | Error detail ->
      record_outcome "exact_domain_invalid_output";
      log_exact_error entry "domain validation" detail;
      quarantine_candidate entry candidate Exact_domain_invalid_output
    | Ok summary ->
      let identity = exact_identity_of_candidate candidate in
      (match complete_exact_attempt queue_writers entry identity summary with
       | Ok { write_outcome = Fsync_completed; _ } ->
         record_outcome "ok_summary";
         on_summary summary
       | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
         record_outcome "exact_terminal_sync_unconfirmed";
         signal_terminalization_persistence_failure
           entry
           "completion sync"
           detail
       | Error error ->
         record_outcome "exact_terminal_persistence_failure";
         log_exact_error
           entry
           "completion"
           (Keeper_approval_queue.exact_attempt_error_to_string error);
         quarantine_identity entry identity Exact_terminal_persistence_failure)
;;

let handle_flow_error (prepared : prepared_flow) = function
  | Exact_output.Flow_attempt_already_started _ ->
    record_outcome "exact_attempt_replay";
    settle_current_or_signal
      prepared.entry
      ~reason:"HITL exact-output flow attempt was replayed"
      ~cause:Exact_attempt_replay
  | Exact_output.Flow_before_dispatch_callback_failed
      { candidate; cause; _ } ->
    record_outcome "exact_bind_failed";
    settle_current_or_signal
      prepared.entry
      ~reason:(flow_callback_error_to_string cause)
      ~cause:Exact_terminal_persistence_failure;
    ignore candidate
  | Exact_output.Flow_before_advance_callback_failed
      { failed; cause; _ } ->
    record_outcome "exact_release_failed";
    settle_current_or_signal
      prepared.entry
      ~reason:(flow_callback_error_to_string cause)
      ~cause:Exact_terminal_persistence_failure;
    ignore failed
  | Exact_output.Flow_exact_execution_failed { candidate; _ } ->
    let receipt = candidate.receipt in
    if
      Exact_output.receipt_phase receipt = Exact_output.Before_dispatch
      && Exact_output.receipt_dispatch_count receipt = 0
    then (
      record_outcome "exact_execution_failed_before_dispatch";
      fail_final_before_dispatch
        prepared.entry
        candidate
        "HITL exact-output flow exhausted before dispatch")
    else (
      record_outcome "exact_execution_failed_after_dispatch";
      quarantine_candidate
        prepared.entry
        candidate
        Exact_flow_execution_failed)
;;

let execute_prepared_flow_with_queue_writers
      ~queue_writers
      ~net
      ?clock
      ~on_summary
      (prepared : prepared_flow)
  =
  try
    match
      Exact_output.execute_flow_once
        ~net
        ?clock
        ~before_dispatch:(before_dispatch ~queue_writers prepared.entry)
        ~before_advance:(before_advance ~queue_writers prepared.entry)
        prepared.attempt
    with
    | Ok success -> handle_success ~queue_writers prepared ~on_summary success
    | Error error -> handle_flow_error prepared error
  with
  | Eio.Cancel.Cancelled _ as cancellation ->
    let settlement =
      Eio.Cancel.protect
      @@ fun () ->
      record_outcome "exact_cancellation";
      settle_current
        prepared.entry
        ~reason:"HITL exact-output flow was cancelled"
        ~cause:Exact_cancellation
    in
    (match settlement with
     | Ok () -> raise cancellation
     | Error detail ->
       signal_terminalization_persistence_failure
         prepared.entry
         "cancellation terminalization persistence"
         detail)
  | Exact_terminalization_persistence_failed _ as persistence_failure ->
    raise persistence_failure
  | exn ->
    let detail = Printexc.to_string exn in
    record_outcome "crashed";
    log_exact_error prepared.entry "worker crash" detail;
    let settlement =
      Eio.Cancel.protect
      @@ fun () ->
      settle_current
        prepared.entry
        ~reason:("HITL exact-output worker crashed: " ^ detail)
        ~cause:Exact_terminal_persistence_failure
    in
    (match settlement with
     | Ok () -> ()
     | Error persistence_detail ->
       signal_terminalization_persistence_failure
         prepared.entry
         "crash terminalization persistence"
         persistence_detail)
;;

let execute_prepared_flow ~net ?clock ~on_summary prepared =
  execute_prepared_flow_with_queue_writers
    ~queue_writers:production_exact_queue_writers
    ~net
    ?clock
    ~on_summary
    prepared
;;

type finish_outcome =
  | Conclusive_terminalization
  | Terminalization_persistence_uncertain

let spawn_with
      ~queue_writers
      ~sw
      ~(entry : pending_approval)
      ~on_summary
      ~on_finish
      ()
  =
  let* net =
    Eio_context.get_net_opt ()
    |> Option.to_result
         ~none:"HITL exact-output flow: Eio net is unavailable"
  in
  let* prepared = prepare_flow ~entry in
  let clock = Eio_context.get_clock_opt () in
  Eio.Fiber.fork ~sw (fun () ->
    let execution_outcome =
      try
        execute_prepared_flow_with_queue_writers
          ~queue_writers
          ~net
          ?clock
          ~on_summary
          prepared;
        `Completed
      with
      | Eio.Cancel.Cancelled _ as cancellation -> `Cancelled cancellation
      | Exact_terminalization_persistence_failed _ as uncertainty ->
        `Uncertain uncertainty
      | exn -> `Uncertain exn
    in
    match execution_outcome with
    | `Completed -> on_finish Conclusive_terminalization
    | `Cancelled cancellation ->
      on_finish Conclusive_terminalization;
      raise cancellation
    | `Uncertain uncertainty ->
      on_finish Terminalization_persistence_uncertain;
      raise uncertainty);
  Ok ()
;;

let spawn =
  spawn_with ~queue_writers:production_exact_queue_writers
;;

module For_testing = struct
  type nonrec context_bundle_error = context_bundle_error =
    | Exact_request_context_unavailable

  type nonrec prepared_flow = prepared_flow
  type nonrec strict_snapshot_writer = strict_snapshot_writer

  let build_context_bundle = build_context_bundle
  let context_bundle_error_to_string = context_bundle_error_to_string
  let messages_for_summary = messages_for_summary
  let parse_summary = parse_summary
  let prepare_flow = prepare_flow
  let execute_prepared_flow = execute_prepared_flow

  let execute_prepared_flow_with_writers
        ?bind_writer
        ?release_writer
        ?complete_writer
        ~net
        ?clock
        ~on_summary
        prepared
    =
    let queue_writers = { bind_writer; release_writer; complete_writer } in
    execute_prepared_flow_with_queue_writers
      ~queue_writers
      ~net
      ?clock
      ~on_summary
      prepared
  ;;

  let spawn_with_writers
        ?bind_writer
        ?release_writer
        ?complete_writer
        ~sw
        ~entry
        ~on_summary
        ~on_finish
        ()
    =
    let queue_writers = { bind_writer; release_writer; complete_writer } in
    spawn_with
      ~queue_writers
      ~sw
      ~entry
      ~on_summary
      ~on_finish
      ()
  ;;

  let flow_evidence prepared = Exact_output.flow_attempt_evidence prepared.attempt
  let success_provenance_matches = success_provenance_matches
  let system_prompt = system_prompt
  let summary_version = summary_version
  let lane_id = lane_id
end
;;
