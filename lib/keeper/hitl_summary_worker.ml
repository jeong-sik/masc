open Keeper_approval_queue

module Exact_output = Agent_sdk.Exact_output

(** Version of the [hitl_context_summary] schema/record. Bumping this is the
    signal for downstream consumers (dashboard, audit) that the shape or prompt
    contract changed. *)
let summary_version = 2

let lane_id = Runtime_exact_output_registry.hitl_auto_judge_lane_id

let system_prompt () =
  Prompt_registry.render_prompt_template Keeper_prompt_names.gate_judgment []
;;

(* -- Metrics --------------------------------------------------------------- *)

let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string HitlSummaryOutcomes)
    ~help:
      "Total HITL exact-output worker outcomes classified by [outcome]. Labels: \
       [outcome] (ok_summary | domain_invalid_output | admission_error | \
       lane_unavailable | execution_failed_before_dispatch | \
       execution_failed_after_dispatch | provenance_mismatch | cancellation | \
       terminal_persistence_failure | exact_context_unavailable | no_net | \
       prompt_error | restart_worker_recovered | restart_judgment_recovered | \
       operator_retry_started)."
    ()
;;

let record_outcome outcome =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string HitlSummaryOutcomes)
    ~labels:[ "outcome", outcome ]
    ()
;;

(* -- Exact request evidence ------------------------------------------------ *)

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
         ; "goal_ids", `List (List.map (fun g -> `String g) entry.goal_ids)
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

(* -- MASC domain validation ------------------------------------------------ *)

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

(* -- Immutable OAS plans and attempts -------------------------------------- *)

type admitted_slot =
  { slot_id : string
  ; ready_plan : Exact_output.ready_plan
  ; attempt : Exact_output.attempt
  ; receipt : Exact_output.receipt
  }

type attempt_observation =
  { slot_id : string
  ; call_id : string
  ; phase : Exact_output.effect_phase
  ; dispatch_count : int
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; catalog_generation_fingerprint : string
  ; catalog_evidence_sha256 : string
  ; target_identity_fingerprint : string
  }

type prepared_lane = admitted_slot list

type provenance_evidence =
  { source_schema_fingerprint : string
  ; effective_schema_fingerprint : string option
  ; actual_assurance : Exact_output.actual_assurance
  ; catalog_generation_fingerprint : string
  ; catalog_evidence_sha256 : string
  ; target_identity_fingerprint : string
  }

type preparation_error =
  | Context_unavailable of context_bundle_error
  | Prompt_unavailable of string
  | Lane_unavailable of string
  | Admission_rejected of string

let preparation_error_to_string = function
  | Context_unavailable error -> context_bundle_error_to_string error
  | Prompt_unavailable detail ->
    "HITL Gate judgment prompt unavailable: " ^ detail
  | Lane_unavailable detail -> detail
  | Admission_rejected detail -> detail
;;

let observe_receipt ~slot_id receipt =
  { slot_id
  ; call_id =
      Exact_output.receipt_call_id receipt |> Exact_output.call_id_to_string
  ; phase = Exact_output.receipt_phase receipt
  ; dispatch_count = Exact_output.receipt_dispatch_count receipt
  ; plan_fingerprint = Exact_output.receipt_plan_fingerprint receipt
  ; request_body_sha256 = Exact_output.receipt_request_body_sha256 receipt
  ; catalog_generation_fingerprint =
      Exact_output.receipt_catalog_generation receipt
      |> Exact_output.catalog_generation_fingerprint
  ; catalog_evidence_sha256 =
      Exact_output.receipt_catalog_evidence receipt
      |> Exact_output.catalog_evidence_sha256
  ; target_identity_fingerprint =
      Exact_output.receipt_target_identity receipt
      |> Exact_output.target_identity_fingerprint
  }
;;

let observe_attempt slot = observe_receipt ~slot_id:slot.slot_id slot.receipt

let prepare_lane ~registry ~(entry : pending_approval) =
  let ( let* ) = Result.bind in
  let* context_bundle =
    build_context_bundle ~entry
    |> Result.map_error (fun error -> Context_unavailable error)
  in
  let* system_prompt =
    system_prompt ()
    |> Result.map_error (fun detail -> Prompt_unavailable detail)
  in
  let* resolved =
    Runtime_exact_output_registry.resolve_lane registry ~lane_id
    |> Result.map_error (fun error ->
      Lane_unavailable
        (Runtime_exact_output_registry.lane_resolution_error_to_string error))
  in
  List.iter
    (fun (slot : Runtime_exact_output_registry.unavailable_slot) ->
       Log.Keeper.warn
         ~keeper_name:entry.keeper_name
         "HITL exact-output lane slot unavailable approval=%s slot=%s"
         entry.id
         slot.slot_id)
    resolved.unavailable_slots;
  let requirement =
    Exact_output.make_output_requirement
      ~schema:Keeper_structured_output_schema.hitl_context_summary_schema
      ~minimum_guarantee:Exact_output.Json_syntax
  in
  let messages = messages_for_summary ~system_prompt ~context_bundle in
  let rec admit_and_start admitted = function
    | [] -> Ok (List.rev admitted)
    | (slot : Runtime_exact_output_registry.selected_slot) :: rest ->
      (match Exact_output.admit ~target:slot.target ~messages requirement with
       | Error _ ->
         Error
           (Admission_rejected
              (Printf.sprintf
                 "HITL exact-output admission rejected slot=%s"
                 slot.slot_id))
       | Ok ready_plan ->
         (match Exact_output.start_attempt ready_plan with
          | Error (Exact_output.Call_id_generation_failed detail) ->
            Error
              (Admission_rejected
                 (Printf.sprintf
                    "HITL exact-output attempt identity failed slot=%s: %s"
                    slot.slot_id
                    detail))
          | Ok attempt ->
            let receipt = Exact_output.attempt_receipt attempt in
            admit_and_start
              ({ slot_id = slot.slot_id; ready_plan; attempt; receipt } :: admitted)
              rest))
  in
  admit_and_start [] resolved.selected_slots
;;

let readiness () =
  let ( let* ) = Result.bind in
  let* (_ : string) = system_prompt () in
  let* registry =
    Runtime_exact_output_registry.current ()
    |> Result.map_error Runtime_exact_output_registry.publication_error_to_string
  in
  let* (_ : Runtime_exact_output_registry.resolved_lane) =
    Runtime_exact_output_registry.resolve_lane registry ~lane_id
    |> Result.map_error Runtime_exact_output_registry.lane_resolution_error_to_string
  in
  Ok ()
;;

let same_call_id left right =
  String.equal
    (Exact_output.call_id_to_string left)
    (Exact_output.call_id_to_string right)
;;

let same_assurance left right =
  match left, right with
  | Exact_output.Json_syntax_only, Exact_output.Json_syntax_only
  | Exact_output.Provider_schema_requested, Exact_output.Provider_schema_requested ->
    true
  | Exact_output.Json_syntax_only, Exact_output.Provider_schema_requested
  | Exact_output.Provider_schema_requested, Exact_output.Json_syntax_only ->
    false
;;

let provenance_evidence_of_plan (provenance : Exact_output.plan_provenance) =
  { source_schema_fingerprint =
      Exact_output.schema_fingerprint_to_string
        provenance.source_schema_fingerprint
  ; effective_schema_fingerprint =
      Option.map
        Exact_output.schema_fingerprint_to_string
        provenance.effective_schema_fingerprint
  ; actual_assurance = provenance.actual_assurance
  ; catalog_generation_fingerprint =
      Exact_output.catalog_generation_fingerprint provenance.catalog_generation
  ; catalog_evidence_sha256 =
      Exact_output.catalog_evidence_sha256 provenance.catalog_evidence
  ; target_identity_fingerprint =
      Exact_output.target_identity_fingerprint provenance.target_identity
  }
;;

let provenance_evidence_matches expected actual =
  String.equal
    expected.source_schema_fingerprint
    actual.source_schema_fingerprint
  && Option.equal
       String.equal
       expected.effective_schema_fingerprint
       actual.effective_schema_fingerprint
  && same_assurance expected.actual_assurance actual.actual_assurance
  && String.equal
       expected.catalog_generation_fingerprint
       actual.catalog_generation_fingerprint
  && String.equal
       expected.catalog_evidence_sha256
       actual.catalog_evidence_sha256
  && String.equal
       expected.target_identity_fingerprint
       actual.target_identity_fingerprint
;;

let receipt_identity_matches observation receipt =
  String.equal
    observation.call_id
    (Exact_output.receipt_call_id receipt |> Exact_output.call_id_to_string)
  && String.equal
       observation.plan_fingerprint
       (Exact_output.receipt_plan_fingerprint receipt)
  && String.equal
       observation.request_body_sha256
       (Exact_output.receipt_request_body_sha256 receipt)
  && String.equal
       observation.catalog_generation_fingerprint
       (Exact_output.receipt_catalog_generation receipt
        |> Exact_output.catalog_generation_fingerprint)
  && String.equal
       observation.catalog_evidence_sha256
       (Exact_output.receipt_catalog_evidence receipt
        |> Exact_output.catalog_evidence_sha256)
  && String.equal
       observation.target_identity_fingerprint
       (Exact_output.receipt_target_identity receipt
        |> Exact_output.target_identity_fingerprint)
;;

let success_provenance_matches slot observation (success : Exact_output.success) =
  let expected = Exact_output.plan_provenance slot.ready_plan in
  let actual = success.provenance in
  let expected_evidence = provenance_evidence_of_plan expected in
  let actual_evidence = provenance_evidence_of_plan actual in
  same_call_id success.call_id (Exact_output.receipt_call_id success.receipt)
  && String.equal
       observation.call_id
       (Exact_output.call_id_to_string success.call_id)
  && receipt_identity_matches observation success.receipt
  && String.equal
       observation.plan_fingerprint
       (Exact_output.plan_fingerprint slot.ready_plan)
  && String.equal
       observation.catalog_generation_fingerprint
       (Exact_output.catalog_generation_fingerprint expected.catalog_generation)
  && String.equal
       observation.catalog_evidence_sha256
       (Exact_output.catalog_evidence_sha256 expected.catalog_evidence)
  && String.equal
       observation.target_identity_fingerprint
       (Exact_output.target_identity_fingerprint expected.target_identity)
  && provenance_evidence_matches expected_evidence actual_evidence
  && (match Exact_output.receipt_phase success.receipt with
      | Exact_output.Terminal -> true
      | Exact_output.Not_started
      | Exact_output.Before_dispatch
      | Exact_output.Dispatch_started
      | Exact_output.Response_received -> false)
  && Exact_output.receipt_dispatch_count success.receipt = 1
;;

let execution_error_identity_matches observation (error : Exact_output.execution_error) =
  String.equal observation.call_id (Exact_output.call_id_to_string error.call_id)
  && same_call_id error.call_id (Exact_output.receipt_call_id error.receipt)
  && receipt_identity_matches observation error.receipt
;;

let is_before_dispatch_zero receipt =
  match Exact_output.receipt_phase receipt with
  | Exact_output.Before_dispatch -> Exact_output.receipt_dispatch_count receipt = 0
  | Exact_output.Not_started
  | Exact_output.Dispatch_started
  | Exact_output.Response_received
  | Exact_output.Terminal -> false
;;

let execution_error_reason (error : Exact_output.execution_error) =
  match error.cause with
  | Exact_output.Attempt_already_started -> "exact attempt was already started"
  | Exact_output.Clock_required_for_timeout -> "exact execution requires a root clock"
  | Exact_output.Frozen_request_mismatch -> "frozen exact request mismatch"
  | Exact_output.Completion_failed -> "exact completion transport failed"
  | Exact_output.Incomplete_output -> "exact completion output was incomplete"
  | Exact_output.Missing_output -> "exact completion output was missing"
  | Exact_output.Ambiguous_output count ->
    Printf.sprintf "exact completion returned %d outputs" count
  | Exact_output.Unexpected_output_content ->
    "exact completion returned unexpected output content"
  | Exact_output.Invalid_json_output -> "exact completion returned invalid JSON"
  | Exact_output.Internal_non_json_output ->
    "exact completion violated the OAS JSON contract"
;;

(* -- Durable queue transitions -------------------------------------------- *)

let bind_attempt entry observation =
  bind_summary_exact_attempt
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
    ~slot_id:observation.slot_id
    ~call_id:observation.call_id
    ~plan_fingerprint:observation.plan_fingerprint
    ~request_body_sha256:observation.request_body_sha256
;;

let release_attempt entry observation =
  release_summary_exact_attempt_before_dispatch
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
    ~slot_id:observation.slot_id
    ~call_id:observation.call_id
    ~plan_fingerprint:observation.plan_fingerprint
    ~request_body_sha256:observation.request_body_sha256
;;

let fail_last_attempt entry observation ~reason =
  fail_summary_exact_attempt_before_dispatch
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
    ~slot_id:observation.slot_id
    ~call_id:observation.call_id
    ~plan_fingerprint:observation.plan_fingerprint
    ~request_body_sha256:observation.request_body_sha256
    ~reason
    ~retryable:false
;;

let quarantine_attempt entry observation cause =
  quarantine_summary_exact_attempt
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
    ~slot_id:observation.slot_id
    ~call_id:observation.call_id
    ~plan_fingerprint:observation.plan_fingerprint
    ~request_body_sha256:observation.request_body_sha256
    ~cause
;;

let complete_attempt entry observation summary =
  complete_summary_exact_attempt
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
    ~slot_id:observation.slot_id
    ~call_id:observation.call_id
    ~plan_fingerprint:observation.plan_fingerprint
    ~request_body_sha256:observation.request_body_sha256
    ~summary
;;

let quarantine_durably entry observation cause =
  match quarantine_attempt entry observation cause with
  | Ok { write_outcome = Fsync_completed; _ } -> true
  | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
    Log.Keeper.error
      ~keeper_name:entry.keeper_name
      "HITL exact quarantine visible without fsync approval=%s slot=%s detail=%s"
      entry.id
      observation.slot_id
      detail;
    false
  | Error error ->
    Log.Keeper.error
      ~keeper_name:entry.keeper_name
      "HITL exact quarantine failed approval=%s slot=%s error=%s"
      entry.id
      observation.slot_id
      (exact_attempt_error_to_string error);
    false
;;

let terminalize_persistence_failure entry observation =
  record_outcome "terminal_persistence_failure";
  quarantine_durably entry observation Exact_terminal_persistence_failure
;;

(* -- Single worker lifecycle ---------------------------------------------- *)

let spawn ~sw ~(entry : pending_approval) ~on_summary ~on_failure ~on_finish () =
  let generated_at = Time_compat.now () in
  let finish_before_attempt ~outcome ~reason ~retryable =
    Fun.protect
      ~finally:(fun () -> on_finish ~continue_owner:true)
      (fun () ->
         record_outcome outcome;
         on_failure ~reason ~retryable)
  in
  let registry_result = Runtime_exact_output_registry.current () in
  match registry_result with
  | Error error ->
    finish_before_attempt
      ~outcome:"lane_unavailable"
      ~reason:(Runtime_exact_output_registry.publication_error_to_string error)
      ~retryable:true
  | Ok registry ->
    (match prepare_lane ~registry ~entry with
     | Error error ->
       let outcome =
         match error with
         | Context_unavailable _ -> "exact_context_unavailable"
         | Prompt_unavailable _ -> "prompt_error"
         | Lane_unavailable _ -> "lane_unavailable"
         | Admission_rejected _ -> "admission_error"
       in
       finish_before_attempt
         ~outcome
         ~reason:(preparation_error_to_string error)
         ~retryable:true
     | Ok prepared_lane ->
       (match Eio_context.get_net_opt () with
        | None ->
          finish_before_attempt
            ~outcome:"no_net"
            ~reason:"HITL exact-output worker: Eio net unavailable"
            ~retryable:true
        | Some net ->
          let continue_owner = ref false in
          Eio.Fiber.fork ~sw (fun () ->
            Fun.protect
              ~finally:(fun () -> on_finish ~continue_owner:!continue_owner)
              (fun () ->
                 let rec execute_candidates = function
                   | [] -> false
                   | slot :: rest ->
                     let bound_observation = observe_attempt slot in
                     (match bind_attempt entry bound_observation with
                      | Error error ->
                        record_outcome "terminal_persistence_failure";
                        Log.Keeper.error
                          ~keeper_name:entry.keeper_name
                          "HITL exact bind failed approval=%s slot=%s error=%s"
                          entry.id
                          slot.slot_id
                          (exact_attempt_error_to_string error);
                        false
                      | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
                        Log.Keeper.error
                          ~keeper_name:entry.keeper_name
                          "HITL exact bind visible without fsync; dispatch withheld approval=%s slot=%s detail=%s"
                          entry.id
                          slot.slot_id
                          detail;
                        Eio.Cancel.protect (fun () ->
                          terminalize_persistence_failure entry bound_observation)
                      | Ok { write_outcome = Fsync_completed; _ } ->
                        let execute_result =
                          try
                            `Result
                              (Exact_output.execute_once
                                 ~net
                                 ?clock:(Eio_context.get_clock_opt ())
                                 slot.attempt)
                          with
                          | Eio.Cancel.Cancelled _ as cancellation ->
                            let observation = observe_attempt slot in
                            record_outcome "cancellation";
                            ignore
                              (Eio.Cancel.protect (fun () ->
                                 quarantine_durably entry observation Exact_cancellation));
                            raise cancellation
                          | exn -> `Raised exn
                        in
                        (match execute_result with
                         | `Raised exn ->
                           let observation = observe_attempt slot in
                           record_outcome "execution_failed_after_dispatch";
                           Log.Keeper.error
                             ~keeper_name:entry.keeper_name
                             "HITL exact execution raised approval=%s slot=%s error=%s"
                             entry.id
                             slot.slot_id
                             (Printexc.to_string exn);
                           quarantine_durably
                             entry
                             observation
                             Exact_post_dispatch_failure
                         | `Result (Error error) ->
                           let observation = observe_attempt slot in
                           if not (execution_error_identity_matches bound_observation error)
                           then (
                             record_outcome "provenance_mismatch";
                             quarantine_durably
                               entry
                               observation
                               Exact_provenance_mismatch)
                           else
                             (match error.cause with
                              | Exact_output.Attempt_already_started ->
                                record_outcome "execution_failed_after_dispatch";
                                quarantine_durably
                                  entry
                                  observation
                                  Exact_attempt_replay
                              | _ when is_before_dispatch_zero error.receipt ->
                                let reason = execution_error_reason error in
                                (match rest with
                                 | [] ->
                                   record_outcome "execution_failed_before_dispatch";
                                   (match fail_last_attempt entry observation ~reason with
                                    | Ok { write_outcome = Fsync_completed; _ } -> true
                                    | Ok
                                        { write_outcome =
                                            Visible_sync_unconfirmed detail
                                        ; _
                                        } ->
                                      Log.Keeper.error
                                        ~keeper_name:entry.keeper_name
                                        "HITL exact failure visible without fsync approval=%s slot=%s detail=%s"
                                        entry.id
                                        slot.slot_id
                                        detail;
                                      terminalize_persistence_failure entry observation
                                    | Error _ ->
                                      terminalize_persistence_failure entry observation)
                                 | _ ->
                                   (match release_attempt entry observation with
                                    | Ok { write_outcome = Fsync_completed; _ } ->
                                      execute_candidates rest
                                    | Ok
                                        { write_outcome =
                                            Visible_sync_unconfirmed detail
                                        ; _
                                        } ->
                                      Log.Keeper.error
                                        ~keeper_name:entry.keeper_name
                                        "HITL exact release visible without fsync; failover withheld approval=%s slot=%s detail=%s"
                                        entry.id
                                        slot.slot_id
                                        detail;
                                      terminalize_persistence_failure entry observation
                                    | Error _ ->
                                      terminalize_persistence_failure entry observation))
                              | _ ->
                                record_outcome "execution_failed_after_dispatch";
                                quarantine_durably
                                  entry
                                  observation
                                  Exact_post_dispatch_failure)
                         | `Result (Ok success) ->
                           let observation = observe_attempt slot in
                           if not (success_provenance_matches slot bound_observation success)
                           then (
                             record_outcome "provenance_mismatch";
                             quarantine_durably
                               entry
                               observation
                               Exact_provenance_mismatch)
                           else
                             (match
                                parse_summary
                                  ~generated_at
                                  ~model_run_id:bound_observation.call_id
                                  success.output
                              with
                              | Error reason ->
                                record_outcome "domain_invalid_output";
                                Log.Keeper.warn
                                  ~keeper_name:entry.keeper_name
                                  "HITL exact domain validation failed approval=%s slot=%s reason=%s"
                                  entry.id
                                  slot.slot_id
                                  reason;
                                quarantine_durably
                                  entry
                                  observation
                                  Exact_domain_invalid_output
                              | Ok summary ->
                                (match complete_attempt entry observation summary with
                                 | Ok { write_outcome = Fsync_completed; _ } ->
                                   record_outcome "ok_summary";
                                   on_summary summary;
                                   true
                                 | Ok
                                     { write_outcome =
                                         Visible_sync_unconfirmed detail
                                     ; _
                                     } ->
                                   Log.Keeper.error
                                     ~keeper_name:entry.keeper_name
                                     "HITL exact completion visible without fsync; Gate withheld approval=%s slot=%s detail=%s"
                                     entry.id
                                     slot.slot_id
                                     detail;
                                   false
                                 | Error _ ->
                                   terminalize_persistence_failure entry observation))))
                 in
                 continue_owner := execute_candidates prepared_lane)))
;;

module For_testing = struct
  type nonrec context_bundle_error = context_bundle_error =
    | Exact_request_context_unavailable

  type nonrec attempt_observation = attempt_observation =
    { slot_id : string
    ; call_id : string
    ; phase : Exact_output.effect_phase
    ; dispatch_count : int
    ; plan_fingerprint : string
    ; request_body_sha256 : string
    ; catalog_generation_fingerprint : string
    ; catalog_evidence_sha256 : string
    ; target_identity_fingerprint : string
    }

  type nonrec prepared_lane = prepared_lane
  type nonrec provenance_evidence = provenance_evidence =
    { source_schema_fingerprint : string
    ; effective_schema_fingerprint : string option
    ; actual_assurance : Exact_output.actual_assurance
    ; catalog_generation_fingerprint : string
    ; catalog_evidence_sha256 : string
    ; target_identity_fingerprint : string
    }

  type nonrec preparation_error = preparation_error =
    | Context_unavailable of context_bundle_error
    | Prompt_unavailable of string
    | Lane_unavailable of string
    | Admission_rejected of string

  let lane_id = lane_id
  let system_prompt = system_prompt
  let summary_version = summary_version
  let build_context_bundle = build_context_bundle
  let context_bundle_error_to_string = context_bundle_error_to_string
  let messages_for_summary = messages_for_summary
  let parse_summary = parse_summary
  let prepare_lane = prepare_lane
  let preparation_error_to_string = preparation_error_to_string
  let observations prepared_lane = List.map observe_attempt prepared_lane
  let is_before_dispatch_zero = is_before_dispatch_zero
  let provenance_evidence_matches = provenance_evidence_matches
end
;;
