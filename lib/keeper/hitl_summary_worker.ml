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

let preparation_error_retryable = function
  | Context_unavailable _ -> false
  | Prompt_unavailable _
  | Lane_unavailable _
  | Admission_rejected _ ->
    true
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

let observe_attempt (slot : admitted_slot) =
  observe_receipt ~slot_id:slot.slot_id slot.receipt

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

let bind_attempt (entry : pending_approval) observation =
  bind_summary_exact_attempt
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
    ~slot_id:observation.slot_id
    ~call_id:observation.call_id
    ~plan_fingerprint:observation.plan_fingerprint
    ~request_body_sha256:observation.request_body_sha256
;;

let release_attempt (entry : pending_approval) observation =
  release_summary_exact_attempt_before_dispatch
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
    ~slot_id:observation.slot_id
    ~call_id:observation.call_id
    ~plan_fingerprint:observation.plan_fingerprint
    ~request_body_sha256:observation.request_body_sha256
;;

let fail_last_attempt (entry : pending_approval) observation ~reason =
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

let quarantine_attempt (entry : pending_approval) observation cause =
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

let complete_attempt (entry : pending_approval) observation summary =
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

type lifecycle_write =
  | Lifecycle_fsync_completed
  | Lifecycle_visible_unconfirmed of string
  | Lifecycle_write_error of string

type lifecycle_execution =
  | Lifecycle_success of
      { observation : attempt_observation
      ; output : Yojson.Safe.t
      }
  | Lifecycle_provenance_mismatch of attempt_observation
  | Lifecycle_replay of attempt_observation
  | Lifecycle_before_dispatch_failure of
      { observation : attempt_observation
      ; reason : string
      }
  | Lifecycle_post_dispatch_failure of attempt_observation
  | Lifecycle_cancellation of
      { observation : attempt_observation
      ; cancellation : exn
      }

type 'candidate lifecycle_candidate =
  { initial_observation : attempt_observation
  ; candidate : 'candidate
  }

type lifecycle_result =
  { continue_owner : bool
  ; cancellation : exn option
  }

type 'candidate lifecycle_effects =
  { bind : attempt_observation -> lifecycle_write
  ; release : attempt_observation -> lifecycle_write
  ; fail : attempt_observation -> reason:string -> lifecycle_write
  ; quarantine :
      attempt_observation -> exact_attempt_quarantine_cause -> lifecycle_write
  ; complete :
      attempt_observation -> hitl_context_summary -> lifecycle_write
  ; execute : 'candidate -> lifecycle_execution
  ; parse :
      model_run_id:string ->
      Yojson.Safe.t ->
      (hitl_context_summary, string) result
  ; on_summary : hitl_context_summary -> unit
  ; record_outcome : string -> unit
  ; protect : (unit -> bool) -> bool
  ; report_write_issue :
      operation:string -> attempt_observation -> detail:string -> unit
  }

let lifecycle_result ?cancellation continue_owner =
  { continue_owner; cancellation }
;;

let run_lifecycle ~effects candidates =
  let report_write_issue operation observation detail =
    effects.report_write_issue ~operation observation ~detail
  in
  let quarantine observation cause =
    match effects.quarantine observation cause with
    | Lifecycle_fsync_completed -> true
    | Lifecycle_visible_unconfirmed detail
    | Lifecycle_write_error detail ->
      report_write_issue "quarantine" observation detail;
      false
  in
  let terminalize_persistence_failure observation =
    effects.record_outcome "terminal_persistence_failure";
    quarantine observation Exact_terminal_persistence_failure
  in
  let rec execute_candidates = function
    | [] -> lifecycle_result false
    | { initial_observation; candidate } :: rest ->
      (match effects.bind initial_observation with
       | Lifecycle_write_error detail ->
         effects.record_outcome "terminal_persistence_failure";
         report_write_issue "bind" initial_observation detail;
         lifecycle_result false
       | Lifecycle_visible_unconfirmed detail ->
         report_write_issue "bind" initial_observation detail;
         lifecycle_result
           (effects.protect (fun () ->
              terminalize_persistence_failure initial_observation))
       | Lifecycle_fsync_completed ->
         (match effects.execute candidate with
          | Lifecycle_cancellation { observation; cancellation } ->
            (* Cancellation is caller-directed structured abort, not an
               availability failure. Even an OAS receipt that still says
               Before_dispatch/count=0 is terminally quarantined: it must not
               release this identity or dispatch a successor slot. *)
            effects.record_outcome "cancellation";
            ignore
              (effects.protect (fun () ->
                 quarantine observation Exact_cancellation));
            lifecycle_result ~cancellation false
          | Lifecycle_provenance_mismatch observation ->
            effects.record_outcome "provenance_mismatch";
            lifecycle_result
              (quarantine observation Exact_provenance_mismatch)
          | Lifecycle_replay observation ->
            effects.record_outcome "execution_failed_after_dispatch";
            lifecycle_result (quarantine observation Exact_attempt_replay)
          | Lifecycle_before_dispatch_failure { observation; reason } ->
            effects.record_outcome "execution_failed_before_dispatch";
            (match rest with
             | [] ->
               (match effects.fail observation ~reason with
                | Lifecycle_fsync_completed -> lifecycle_result true
                | Lifecycle_visible_unconfirmed detail ->
                  report_write_issue "fail" observation detail;
                  lifecycle_result
                    (terminalize_persistence_failure observation)
                | Lifecycle_write_error detail ->
                  report_write_issue "fail" observation detail;
                  lifecycle_result
                    (terminalize_persistence_failure observation))
             | _ ->
               (match effects.release observation with
                | Lifecycle_fsync_completed -> execute_candidates rest
                | Lifecycle_visible_unconfirmed detail ->
                  report_write_issue "release" observation detail;
                  lifecycle_result
                    (terminalize_persistence_failure observation)
                | Lifecycle_write_error detail ->
                  report_write_issue "release" observation detail;
                  lifecycle_result
                    (terminalize_persistence_failure observation)))
          | Lifecycle_post_dispatch_failure observation ->
            effects.record_outcome "execution_failed_after_dispatch";
            lifecycle_result
              (quarantine observation Exact_post_dispatch_failure)
          | Lifecycle_success { observation; output } ->
            (match
               effects.parse
                 ~model_run_id:initial_observation.call_id
                 output
             with
             | Error _ ->
               effects.record_outcome "domain_invalid_output";
               lifecycle_result
                 (quarantine observation Exact_domain_invalid_output)
             | Ok summary ->
               (match effects.complete observation summary with
                | Lifecycle_fsync_completed ->
                  effects.record_outcome "ok_summary";
                  effects.on_summary summary;
                  lifecycle_result true
                | Lifecycle_visible_unconfirmed detail ->
                  report_write_issue "complete" observation detail;
                  lifecycle_result false
                | Lifecycle_write_error detail ->
                  report_write_issue "complete" observation detail;
                  lifecycle_result
                    (terminalize_persistence_failure observation)))))
  in
  execute_candidates candidates
;;

let lifecycle_write_of_transition = function
  | Ok { write_outcome = Fsync_completed; _ } ->
    Lifecycle_fsync_completed
  | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
    Lifecycle_visible_unconfirmed detail
  | Error error ->
    Lifecycle_write_error (exact_attempt_error_to_string error)
;;

let execute_exact_candidate ~net ~bound_observation (slot : admitted_slot) =
  try
    match
      Exact_output.execute_once
        ~net
        ?clock:(Eio_context.get_clock_opt ())
        slot.attempt
    with
    | Ok success ->
      let observation = observe_attempt slot in
      if success_provenance_matches slot bound_observation success
      then Lifecycle_success { observation; output = success.output }
      else Lifecycle_provenance_mismatch observation
    | Error error ->
      let observation = observe_attempt slot in
      if not (execution_error_identity_matches bound_observation error)
      then Lifecycle_provenance_mismatch observation
      else
        (match error.cause with
         | Exact_output.Attempt_already_started ->
           Lifecycle_replay observation
         | _ when is_before_dispatch_zero error.receipt ->
           Lifecycle_before_dispatch_failure
             { observation; reason = execution_error_reason error }
         | _ -> Lifecycle_post_dispatch_failure observation)
  with
  | Eio.Cancel.Cancelled _ as cancellation ->
    Lifecycle_cancellation
      { observation = observe_attempt slot; cancellation }
  | exn ->
    Log.Keeper.error
      "HITL exact execution raised slot=%s error=%s"
      slot.slot_id
      (Printexc.to_string exn);
    Lifecycle_post_dispatch_failure (observe_attempt slot)
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
         ~retryable:(preparation_error_retryable error)
     | Ok prepared_lane ->
       (match Eio_context.get_net_opt () with
        | None ->
          finish_before_attempt
            ~outcome:"no_net"
            ~reason:"HITL exact-output worker: Eio net unavailable"
            ~retryable:true
        | Some net ->
          let continue_owner = ref false in
          let report_write_issue ~operation observation ~detail =
            Log.Keeper.error
              ~keeper_name:entry.keeper_name
              "HITL exact lifecycle write not durable operation=%s approval=%s slot=%s detail=%s"
              operation
              entry.id
              observation.slot_id
              detail
          in
          let effects : (attempt_observation * admitted_slot) lifecycle_effects =
            { bind = (fun observation ->
                bind_attempt entry observation
                |> lifecycle_write_of_transition)
            ; release = (fun observation ->
                release_attempt entry observation
                |> lifecycle_write_of_transition)
            ; fail = (fun observation ~reason ->
                fail_last_attempt entry observation ~reason
                |> lifecycle_write_of_transition)
            ; quarantine = (fun observation cause ->
                quarantine_attempt entry observation cause
                |> lifecycle_write_of_transition)
            ; complete = (fun observation summary ->
                complete_attempt entry observation summary
                |> lifecycle_write_of_transition)
            ; execute = (fun (bound_observation, candidate) ->
                execute_exact_candidate ~net ~bound_observation candidate)
            ; parse = (fun ~model_run_id output ->
                parse_summary ~generated_at ~model_run_id output)
            ; on_summary
            ; record_outcome
            ; protect = Eio.Cancel.protect
            ; report_write_issue
            }
          in
          let candidates =
            List.map
              (fun candidate ->
                 let initial_observation = observe_attempt candidate in
                 { initial_observation
                 ; candidate = initial_observation, candidate
                 })
              prepared_lane
          in
          Eio.Fiber.fork ~sw (fun () ->
            Fun.protect
              ~finally:(fun () -> on_finish ~continue_owner:!continue_owner)
              (fun () ->
                 let result = run_lifecycle ~effects candidates in
                 continue_owner := result.continue_owner;
                 match result.cancellation with
                 | None -> ()
                 | Some cancellation -> raise cancellation))))
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

  type nonrec lifecycle_write = lifecycle_write =
    | Lifecycle_fsync_completed
    | Lifecycle_visible_unconfirmed of string
    | Lifecycle_write_error of string

  type nonrec lifecycle_execution = lifecycle_execution =
    | Lifecycle_success of
        { observation : attempt_observation
        ; output : Yojson.Safe.t
        }
    | Lifecycle_provenance_mismatch of attempt_observation
    | Lifecycle_replay of attempt_observation
    | Lifecycle_before_dispatch_failure of
        { observation : attempt_observation
        ; reason : string
        }
    | Lifecycle_post_dispatch_failure of attempt_observation
    | Lifecycle_cancellation of
        { observation : attempt_observation
        ; cancellation : exn
        }

  type nonrec 'candidate lifecycle_candidate = 'candidate lifecycle_candidate =
    { initial_observation : attempt_observation
    ; candidate : 'candidate
    }

  type nonrec lifecycle_result = lifecycle_result =
    { continue_owner : bool
    ; cancellation : exn option
    }

  type nonrec 'candidate lifecycle_effects = 'candidate lifecycle_effects =
    { bind : attempt_observation -> lifecycle_write
    ; release : attempt_observation -> lifecycle_write
    ; fail : attempt_observation -> reason:string -> lifecycle_write
    ; quarantine :
        attempt_observation ->
        exact_attempt_quarantine_cause ->
        lifecycle_write
    ; complete :
        attempt_observation -> hitl_context_summary -> lifecycle_write
    ; execute : 'candidate -> lifecycle_execution
    ; parse :
        model_run_id:string ->
        Yojson.Safe.t ->
        (hitl_context_summary, string) result
    ; on_summary : hitl_context_summary -> unit
    ; record_outcome : string -> unit
    ; protect : (unit -> bool) -> bool
    ; report_write_issue :
        operation:string ->
        attempt_observation ->
        detail:string ->
        unit
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
  let preparation_error_retryable = preparation_error_retryable
  let observations prepared_lane = List.map observe_attempt prepared_lane
  let is_before_dispatch_zero = is_before_dispatch_zero
  let provenance_evidence_matches = provenance_evidence_matches
  let run_lifecycle = run_lifecycle
end
;;
