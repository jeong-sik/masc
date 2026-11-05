open Keeper_approval_queue_result
open Keeper_approval_queue_rules_types

include Hitl_summary_flow_outcome
include Hitl_summary_flow_prepare
include Hitl_summary_exact_queue
include Hitl_summary_exact_settlement
include Hitl_summary_flow_terminalization

module Exact_output = Agent_core.Exact_output

open Result.Syntax

let log_cli_slot_failure (entry : pending_approval) failure =
  Log.Keeper.warn
    ~keeper_name:entry.keeper_name
    "HITL exact-output approval_id=%s: %s"
    entry.id
    (Keeper_lane_cli_oneshot.failure_to_string failure)
;;

type execution_boundary =
  | Executed
  | Identity_unbound_blocked
  | Exact_rejection_blocked of exact_attempt_rejection

(* ── CLI lane-slot fallback (RFC cli-runtimes-as-lane-slots) ─────────
   Walked only after the HTTP flow reports candidate exhaustion. Every queue
   transition stays inside the exact-attempt contract proven above:
   [release -> bind(new identity)] is the same rebind the HTTP walk uses, a
   summary completes the bound cli identity exactly like an HTTP success,
   and a failed walk leaves its last cli binding Exact_dispatch_uncertain so
   the ordinary quarantine transition can settle the entry. A cli one-shot
   has no request body; its input is the rendered prompt, so the prompt's
   sha256 fills both exactness fingerprints of the durable identity. *)

type cli_walk_outcome =
  | Cli_no_slots
      (* Nothing declared — the caller keeps its pre-cli behaviour. *)
  | Cli_summary
      (* A cli slot answered; the summary is completed and delivered. *)
  | Cli_settled
      (* Every cli slot failed and the entry was quarantined under the last
         cli identity. Nothing left for the caller to settle. *)
  | Cli_fell_back
      (* The walk could not take over (release/bind persistence refused);
         the pre-cli binding state is intact, so the caller settles exactly
         as it would have without cli slots. *)

let cli_prompt ~context_bundle =
  Hitl_judge_original.canonical_output_contract () ^ "\n\n" ^ Yojson.Safe.to_string context_bundle
;;

let try_cli_slots
      ~queue_ops
      ~cli_runner
      ~(bound : exact_identity option)
      (prepared : prepared_flow)
      ~on_summary
  =
  match prepared.cli_slots with
  | [] -> Cli_no_slots
  | slots ->
    let entry = prepared.entry in
    let base_dir = entry.Keeper_approval_queue_rules_types.audit_base_path in
    let prompt = cli_prompt ~context_bundle:prepared.context_bundle in
    let prompt_sha = Agent_core_sha256.(digest_string prompt |> to_hex) in
    let quarantine_cause_of_failure = function
      | Keeper_lane_cli_oneshot.Invalid_json_output _
      | Keeper_lane_cli_oneshot.Invalid_domain_output _ -> Exact_domain_invalid_output
      | Keeper_lane_cli_oneshot.Unknown_runtime _
      | Keeper_lane_cli_oneshot.Not_an_official_client _
      | Keeper_lane_cli_oneshot.Execution_failed _ -> Exact_flow_execution_failed
    in
    let release identity =
      match release_exact_attempt queue_ops entry identity with
      | Ok { write_outcome = Fsync_completed; _ } -> Ok ()
      | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } -> Error detail
      | Error error ->
        Error (Keeper_approval_queue_result.exact_attempt_error_to_string error)
    in
    let rec walk ~bound ~released_entry_binding ~last_cli_failure slots =
      match Keeper_lane_cli_oneshot.order_slots slots with
      | [] ->
        (match bound, last_cli_failure with
         | Some identity, Some failure ->
           (* The last failed cli slot is still Exact_dispatch_uncertain, so
              the entry settles through the ordinary quarantine transition
              under the identity that actually failed. *)
           record_outcome Cli_slots_exhausted;
           Log.Keeper.warn
             ~keeper_name:entry.keeper_name
             "HITL exact-output CLI candidates exhausted approval_id=%s last_slot=%s"
             entry.id
             identity.slot_id;
           quarantine_identity
             ~queue_ops
             entry
             identity
             (quarantine_cause_of_failure failure);
           Cli_settled
         | Some identity, None ->
           (* Unreachable by construction: [bound] becomes [Some] only for a
              cli identity whose run already recorded a failure, and a
              success returns before the walk recurses. Treat it as the
              exhausted case with an execution cause rather than hiding it
              under a wildcard. *)
           record_outcome Cli_slots_exhausted;
           quarantine_identity ~queue_ops entry identity Exact_flow_execution_failed;
           Cli_settled
         | None, (Some _ | None) ->
           if released_entry_binding
           then (
             (* The walk released the caller's exhausted binding and then no
                cli slot managed to bind: the pre-cli state is gone, so the
                caller's quarantine (which requires that binding) would be
                rejected. Settle the entry here instead. *)
             record_outcome Cli_released_without_binding;
             settle_current_or_signal
               ~queue_ops
               entry
               ~reason:
                 "HITL cli lane-slot walk released the exhausted binding but \
                  no cli slot bound"
               ~cause:Exact_flow_execution_failed;
             Cli_settled)
           else (
             (* Nothing was released and nothing bound: the pre-cli state is
                intact and the caller's ordinary settlement still applies. *)
             record_outcome Cli_walk_fell_back;
             Cli_fell_back))
      | runtime_id :: rest ->
        (* Rebind discipline: whatever is bound (the exhausted HTTP candidate
           or the previous cli slot) is released before the next identity
           binds — the same release-then-bind step the HTTP walk performs. *)
        let released_entry_binding = released_entry_binding || Option.is_some bound in
        (match
           match bound with
           | None -> Ok ()
           | Some identity -> release identity
         with
         | Error detail ->
           record_outcome Cli_release_unconfirmed;
           log_exact_error entry "cli slot release" detail;
           (* The release did not confirm, so the caller's binding may or may
              not remain; the caller's own settlement copes with either (its
              quarantine raises a typed rejection at worst on a state it can
              no longer see). Nothing cli-owned exists yet. *)
           Cli_fell_back
         | Ok () ->
           let identity =
             { slot_id = runtime_id
             ; call_id = Random_id.prefixed ~prefix:"cli-hitl-" ~bytes:16
             ; plan_fingerprint = "cli-oneshot:" ^ prompt_sha
             ; request_body_sha256 = prompt_sha
             }
           in
           (match bind_exact_attempt queue_ops entry identity with
            | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
              record_outcome Cli_bind_unconfirmed;
              log_exact_error entry "cli slot bind" detail;
              (* The binding may not be durable; walking on without a durable
                 identity would detach the dispatch from the queue record. *)
              Cli_fell_back
            | Error error ->
              record_outcome Cli_bind_failed;
              log_exact_error
                entry
                "cli slot bind"
                (Keeper_approval_queue_result.exact_attempt_error_to_string error);
              (* This slot never bound; the previous binding was already
                 released, so continue the walk with nothing bound. *)
              walk ~bound:None ~released_entry_binding ~last_cli_failure rest
            | Ok { write_outcome = Fsync_completed; _ } ->
              queue_ops.after_bind ();
              (match
                 Keeper_lane_cli_oneshot.run
                   ?runner:cli_runner
                   ~base_dir
                   ~runtime_id
                   ~system_prompt:prepared.system_prompt
                   ~requirement:output_requirement
                   ~prompt
                   ()
               with
               | Error failure ->
                 log_cli_slot_failure entry failure;
                 walk
                   ~bound:(Some identity)
                   ~released_entry_binding
                   ~last_cli_failure:(Some failure)
                   rest
               | Ok output ->
                 (match
                    Hitl_summary_request.parse_summary
                      ~generated_at:prepared.generated_at
                      ~model_run_id:identity.call_id
                      output
                  with
                  | Error detail ->
                    let failure =
                      Keeper_lane_cli_oneshot.Invalid_domain_output
                        { runtime_id; detail }
                    in
                    log_cli_slot_failure entry failure;
                    walk
                      ~bound:(Some identity)
                      ~released_entry_binding
                      ~last_cli_failure:(Some failure)
                      rest
                  | Ok summary ->
                    (match complete_exact_attempt queue_ops entry identity summary with
                     | Ok { write_outcome = Fsync_completed; _ } ->
                       record_outcome Ok_summary_cli;
                       on_summary summary;
                       Cli_summary
                     | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
                       record_outcome Terminal_sync_unconfirmed;
                       (* Raises: the surrounding execution boundary treats an
                          unconfirmed terminal write as persistence
                          uncertainty, same as the HTTP completion path. *)
                       signal_terminalization_persistence_failure
                         entry
                         "cli completion sync"
                         detail
                     | Error error when exact_attempt_source_resolved entry error ->
                       record_outcome Source_resolved;
                       Cli_settled
                     | Error (Exact_attempt_rejected rejection) ->
                       raise (Exact_terminalization_rejected rejection)
                     | Error (Exact_attempt_storage_error error) ->
                       record_outcome Terminal_persistence_failure;
                       log_exact_error
                         entry
                         "cli completion"
                         (Keeper_approval_queue_result.storage_error_to_string error);
                       quarantine_identity
                         ~queue_ops
                         entry
                         identity
                         Exact_terminal_persistence_failure;
                       Cli_settled)))))
    in
    walk ~bound ~released_entry_binding:false ~last_cli_failure:None slots
;;

let execute_prepared_flow_with_queue_ops_current
      ~queue_ops
      ?cli_runner
      ~net
      ~clock
      ~on_summary
      ?on_usage
      (prepared : prepared_flow)
  =
  let bound_candidate = ref None in
  let guarded_before_dispatch candidate =
    let* () =
      match !bound_candidate with
      | None -> Ok ()
      | Some previous ->
        let identity = exact_identity_of_candidate previous in
        (match release_exact_attempt queue_ops prepared.entry identity with
         | Ok { write_outcome = Fsync_completed; _ } ->
           bound_candidate := None;
           Ok ()
         | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
           Error (Exact_release_sync_unconfirmed detail)
         | Error error ->
           Error (Exact_release_failed error))
    in
    let* () = before_dispatch ~queue_ops prepared.entry candidate in
    bound_candidate := Some candidate;
    queue_ops.after_bind ();
    Ok ()
  in
  let guarded_before_advance ~failed ~next =
    let* () = before_advance ~queue_ops prepared.entry ~failed ~next in
    (match failed with
     | Exact_output.Flow_candidate_rejected _ -> ()
     | Exact_output.Flow_candidate_execution_failed _ ->
       bound_candidate := None);
    Ok ()
  in
  try
    match prepared.transport with
    | Cli_only ->
      (match try_cli_slots ~queue_ops ~cli_runner ~bound:None prepared ~on_summary with
       | Cli_summary | Cli_settled -> ()
       | Cli_no_slots | Cli_fell_back ->
         settle_current_or_signal ~queue_ops prepared.entry
           ~reason:"HITL CLI-only lane could not bind a runtime"
           ~cause:Exact_flow_execution_failed);
      Executed
    | Http_attempt (attempt, resolved) ->
    let flow =
      Exact_output.execute_flow_once
        ~net
        ~clock
        ~before_measurement_dispatch:(fun _ -> Ok ())
        ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_dispatch:guarded_before_dispatch
        ~before_advance:guarded_before_advance
        ~validate:(validate_success prepared)
        attempt
    in
    Runtime_exact_lane_backpressure.observe ~resolved flow;
    match flow with
    | Ok success ->
      (match on_usage with
       | Some observe -> observe (Exact_output.flow_success_output success.transport_success).usage
       | None -> ());
      handle_validated_success
        ~queue_ops
        prepared
        ~on_summary
        success.transport_success
        success.accepted;
      Executed
    | Error (Exact_output.Flow_execution_terminal { cause; _ }) ->
      (match Exact_output.flow_execution_terminal_kind cause with
       | Exact_output.Non_advanceable_terminal ->
         handle_flow_error ~queue_ops prepared cause
       | Exact_output.Advanceable_candidates_exhausted ->
         (* [flow_execution_terminal_kind] admits only [Flow_candidates_exhausted]
            and [Flow_exact_execution_failed]; both matches below rely on that pair. *)
         let bound =
           match cause with
           | Exact_output.Flow_exact_execution_failed { candidate; _ } ->
             Some (exact_identity_of_candidate candidate)
           | Exact_output.Flow_attempt_already_started _ | Exact_output.Flow_attempt_start_failed _
           | Exact_output.Flow_measurement_start_failed _
           | Exact_output.Flow_before_measurement_dispatch_callback_failed _
           | Exact_output.Flow_measurement_terminal_callback_failed _
           | Exact_output.Flow_before_dispatch_callback_failed _
           | Exact_output.Flow_before_advance_callback_failed _
           | Exact_output.Flow_candidates_exhausted _ -> Option.map exact_identity_of_candidate !bound_candidate
         in
         (match try_cli_slots ~queue_ops ~cli_runner ~bound prepared ~on_summary with
          | Cli_summary | Cli_settled -> ()
          | Cli_no_slots | Cli_fell_back ->
            (match cause, !bound_candidate with
             | Exact_output.Flow_candidates_exhausted _, Some candidate ->
               record_outcome Domain_invalid_output;
               quarantine_candidate ~queue_ops prepared.entry candidate
                 Exact_domain_invalid_output
             | (Exact_output.Flow_candidates_exhausted _, None)
             | ((Exact_output.Flow_attempt_already_started _ | (Exact_output.Flow_attempt_start_failed _ | (Exact_output.Flow_measurement_start_failed _ | (Exact_output.Flow_before_measurement_dispatch_callback_failed _ | (Exact_output.Flow_measurement_terminal_callback_failed _ | (Exact_output.Flow_before_dispatch_callback_failed _ | (Exact_output.Flow_before_advance_callback_failed _ | Exact_output.Flow_exact_execution_failed _))))))), _) -> handle_flow_error ~queue_ops prepared cause)));
      Executed
    | Error
        (Exact_output.Flow_semantic_candidates_exhausted
           { rejections; _ }) ->
      (* The rejected candidate is still bound Exact_dispatch_uncertain (the
         semantic reject happens after dispatch, before any advance), which
         is exactly the state the cli walk's release-then-bind step expects. *)
      let bound =
        rejections
        |> last_semantic_rejection
        |> fun rejection ->
        rejection.transport_success
        |> Exact_output.flow_success_candidate
        |> exact_identity_of_candidate
      in
      (match
         try_cli_slots ~queue_ops ~cli_runner ~bound:(Some bound) prepared ~on_summary
       with
       | Cli_summary | Cli_settled -> ()
       | Cli_no_slots | Cli_fell_back ->
         handle_semantic_exhaustion ~queue_ops prepared rejections);
      Executed
  with
  | Eio.Cancel.Cancelled _ as cancellation ->
    let cancellation_backtrace = Printexc.get_raw_backtrace () in
    let cancelled_uncertain detail =
      (match mark_persistence_uncertain prepared.entry with
       | Ok _ -> ()
       | Error marker_error ->
         log_exact_error
           prepared.entry
           "cancellation uncertainty observation"
           (Keeper_approval_queue_result.exact_attempt_error_to_string marker_error));
      raise
        (Cancelled_uncertain
           (cancellation, cancellation_backtrace, detail))
    in
    let settlement =
      try
        Eio.Cancel.protect
        @@ fun () ->
        record_outcome Cancellation;
        (match
           settle_current
             ~queue_ops
             prepared.entry
             ~reason:"HITL exact-output flow was cancelled"
             ~cause:Exact_cancellation
         with
        | Ok () ->
          Cancellation_settled
        | Error error ->
          Cancellation_exact_settlement_failed error)
      with
      | exn -> (* cancel-guard-ok: the body is Eio.Cancel.protect *)
        Cancellation_settlement_raised
          ("cancellation settlement raised: " ^ Printexc.to_string exn)
    in
    (match settlement with
     | Cancellation_settled ->
       Printexc.raise_with_backtrace cancellation cancellation_backtrace
     | Cancellation_exact_settlement_failed
         (Exact_settlement_identity_unbound _) ->
       (match persist_identity_unbound prepared.entry with
        | Ok () ->
          raise
            (Cancelled_identity_unbound
               (cancellation, cancellation_backtrace))
        | Error `Transition_not_applied ->
          raise
            (Cancelled_identity_unbound
               (cancellation, cancellation_backtrace))
        | Error (`Rejected rejection) ->
          raise
            (Cancelled_exact_rejected
               (cancellation, cancellation_backtrace, rejection))
        | Error (`Storage_failed marker_detail) ->
          cancelled_uncertain marker_detail)
     | Cancellation_exact_settlement_failed
         (Exact_settlement_persistence_failed detail)
     | Cancellation_settlement_raised detail ->
       record_outcome Cancellation_settlement_failed;
       log_exact_error
         prepared.entry
         "cancellation terminalization persistence"
         detail;
       cancelled_uncertain detail
     | Cancellation_exact_settlement_failed
         (Exact_settlement_rejected rejection) ->
       raise
         (Cancelled_exact_rejected
            (cancellation, cancellation_backtrace, rejection)))
  | Exact_terminalization_persistence_failed _ as persistence_failure ->
    raise persistence_failure
  | Exact_terminalization_rejected rejection ->
    record_outcome Terminal_rejected;
    log_exact_error
      prepared.entry
      "terminalization rejected"
      (Keeper_approval_queue_result.exact_attempt_error_to_string
         (Exact_attempt_rejected rejection));
    Exact_rejection_blocked rejection
  | Exact_terminalization_identity_unbound _ ->
    Identity_unbound_blocked
  | exn ->
    let detail = Printexc.to_string exn in
    record_outcome Crashed;
    log_exact_error prepared.entry "worker crash" detail;
    let settlement =
      Eio.Cancel.protect
      @@ fun () ->
      settle_current
        ~queue_ops
        prepared.entry
        ~reason:("HITL exact-output worker crashed: " ^ detail)
        ~cause:Exact_terminal_persistence_failure
    in
    (match settlement with
     | Ok () -> Executed
     | Error (Exact_settlement_identity_unbound detail) ->
       (match persist_identity_unbound prepared.entry with
        | Ok () ->
          record_outcome Identity_unbound;
          log_exact_error prepared.entry "terminalization blocked" detail;
          Identity_unbound_blocked
        | Error `Transition_not_applied ->
          Identity_unbound_blocked
        | Error (`Rejected rejection) ->
          raise (Exact_terminalization_rejected rejection)
        | Error (`Storage_failed marker_detail) ->
          signal_terminalization_persistence_failure
            prepared.entry
            "identity-unbound observation"
            marker_detail)
     | Error (Exact_settlement_persistence_failed detail) ->
       signal_terminalization_persistence_failure
         prepared.entry
         "crash terminalization persistence"
         detail
     | Error (Exact_settlement_rejected rejection) ->
       raise (Exact_terminalization_rejected rejection))
;;

let execute_prepared_flow_with_queue_ops
      ~queue_ops
      ?cli_runner
      ~net
      ~clock
      ~on_summary
      ?on_usage
      (prepared : prepared_flow)
  =
  execute_prepared_flow_with_queue_ops_current
    ~queue_ops
    ?cli_runner
    ~net
    ~clock
    ~on_summary
    ?on_usage
    prepared
;;

let execute_prepared_flow ~net ~clock ~on_summary prepared =
  execute_prepared_flow_with_queue_ops
    ~queue_ops:production_exact_queue_ops
    ~net
    ~clock
    ~on_summary
    prepared
;;

type finish_outcome =
  | Conclusive_terminalization
  | Terminalization_persistence_uncertain
  | Terminalization_identity_unbound
  | Terminalization_rejected

type spawn_outcome =
  | Worker_forked

let spawn_with
      ~queue_ops
      ?cli_runner
      ~prepare_flow
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
  let* clock =
    Eio_context.get_clock_opt ()
    |> Option.to_result
         ~none:"HITL exact-output flow: Eio clock is unavailable"
  in
  match prepare_flow ~entry with
  | Error detail -> Error detail
  | Ok prepared ->
    let registry = Exact_lane_run_registry.global () in
    let run_id = Random_id.prefixed ~prefix:"exact-hitl-judge-" ~bytes:16 in
    let started_at = Time_compat.now () in
    let observed_summary = ref None in
    let observed_outcome = ref None in
    let selected_slot = ref None in
    let bind
          ~id
          ~input_hash
          ~sequence
          ~slot_id
          ~call_id
          ~plan_fingerprint
          ~request_body_sha256
      =
      let result =
        queue_ops.bind
          ~id
          ~input_hash
          ~sequence
          ~slot_id
          ~call_id
          ~plan_fingerprint
          ~request_body_sha256
      in
      (match result with
       | Ok { write_outcome = Fsync_completed; _ } ->
         selected_slot := Some slot_id
       | Ok { write_outcome = Visible_sync_unconfirmed _; _ } | Error _ -> ());
      result
    in
    let release_before_dispatch
          ~id
          ~input_hash
          ~sequence
          ~slot_id
          ~call_id
          ~plan_fingerprint
          ~request_body_sha256
      =
      let result =
        queue_ops.release_before_dispatch
          ~id
          ~input_hash
          ~sequence
          ~slot_id
          ~call_id
          ~plan_fingerprint
          ~request_body_sha256
      in
      (match result with
       | Ok { write_outcome = Fsync_completed; _ } -> selected_slot := None
       | Ok { write_outcome = Visible_sync_unconfirmed _; _ } | Error _ -> ());
      result
    in
    (* These wrappers only retain the durable binding selected by the existing
       queue authority. They do not choose a candidate or alter settlement. *)
    let observed_queue_ops = { queue_ops with bind; release_before_dispatch } in
    let on_summary summary =
      observed_summary := Some summary;
      on_summary summary
    in
    Exact_lane_run_registry.register_running
      registry
      ~run_id
      ~lane:Exact_lane_run_registry.Hitl_auto_judge
      ~actor:entry.keeper_name
      ~started_at
      ~input:
        (Exact_lane_run_registry.Exact_input
           (`Assoc
           [ "tool_name", `String entry.tool_name
           ; "tool_input", entry.input
           ; ( "request_context"
             , match entry.request_context with
               | Some context -> context
               | None -> `Null )
           ; "turn_id", Json_util.int_opt_to_json entry.turn_id
           ; "task_id", Json_util.string_opt_to_json entry.task_id
           ; "goal_id", Json_util.string_opt_to_json entry.goal_id
                  ; "partial_context", `Bool (Option.is_none entry.request_context)
           ; ( "observation"
             , match entry.observation with
               | Some refusal ->
                 Keeper_approval_queue_rules_types.observed_refusal_to_yojson refusal
               | None -> `Null )
           ]));
    let observed_usage = ref None in
    let complete ?usage outcome output =
      match
        Exact_lane_run_registry.mark_completed
          registry
          ~run_id
          ~outcome
          ~elapsed_s:(Time_compat.now () -. started_at)
          ~selected_slot:!selected_slot
          ?usage
          ~output
          ()
      with
      | Ok () -> ()
      | Error error ->
        Log.Keeper.error
          ~keeper_name:entry.keeper_name
          "HITL exact-run observation completion failed run_id=%s: %s"
          run_id
          (Exact_lane_run_registry.completion_error_to_string error)
    in
    Eio.Fiber.fork ~sw (fun () ->
    let execution_outcome =
      with_outcome_sink observed_outcome
      @@ fun () ->
      try
        match
          execute_prepared_flow_with_queue_ops
            ~queue_ops:observed_queue_ops
            ?cli_runner
            ~net
            ~clock
            ~on_summary
            ~on_usage:(fun usage ->
               observed_usage :=
                 Option.map Exact_lane_run_registry.usage_of_api_usage usage)
            prepared
        with
        | Executed -> `Completed
        | Identity_unbound_blocked -> `Identity_unbound
        | Exact_rejection_blocked rejection -> `Rejected rejection
      with
      | Cancelled_identity_unbound
          (cancellation, cancellation_backtrace) ->
        `Cancelled_identity_unbound
          (cancellation, cancellation_backtrace)
      | Cancelled_exact_rejected
          (cancellation, cancellation_backtrace, rejection) ->
        `Cancelled_rejected
          (cancellation, cancellation_backtrace, rejection)
      | Cancelled_uncertain (cancellation, cancellation_backtrace, detail) ->
        `Cancelled_uncertain
          (cancellation, cancellation_backtrace, detail)
      | Eio.Cancel.Cancelled _ as cancellation ->
        `Cancelled (cancellation, Printexc.get_raw_backtrace ())
      | Exact_terminalization_persistence_failed _ as uncertainty ->
        `Uncertain uncertainty
      | Exact_terminalization_rejected rejection ->
        `Rejected rejection
      | exn -> `Uncertain exn
    in
    match execution_outcome with
    | `Completed ->
      (* The flow can reach here without ever producing a summary: when every
         candidate is rejected, [Flow_semantic_candidates_exhausted] routes to
         [handle_semantic_exhaustion], which quarantines the candidate and
         returns [Executed] like a judged run. Recording [Succeeded] with a
         synthesised output made a run that judged nothing indistinguishable
         from one that did, and the .mli already says a summary reaches
         [on_summary] only after validation, provenance and fsync. So the
         absence of one is a failure except when only the source resolved,
         and the outcome type has a variant for that ending.

         [on_finish] is unchanged: whether an exhausted flow should still
         permit draining later owner work is a separate contract question. *)
      let outcome, output = run_outcome_of_observed_summary
          ~last_outcome:!observed_outcome
          !observed_summary in
      complete ?usage:!observed_usage outcome output;
      on_finish Conclusive_terminalization
    | `Cancelled (cancellation, cancellation_backtrace) ->
      complete Exact_lane_run_registry.Cancelled `Null;
      on_finish Terminalization_persistence_uncertain;
      Printexc.raise_with_backtrace cancellation cancellation_backtrace
    | `Cancelled_uncertain
        (cancellation, cancellation_backtrace, _detail) ->
      complete Exact_lane_run_registry.Cancelled `Null;
      on_finish Terminalization_persistence_uncertain;
      Printexc.raise_with_backtrace cancellation cancellation_backtrace
    | `Cancelled_identity_unbound
        (cancellation, cancellation_backtrace) ->
      complete Exact_lane_run_registry.Cancelled `Null;
      on_finish Terminalization_identity_unbound;
      Printexc.raise_with_backtrace cancellation cancellation_backtrace
    | `Cancelled_rejected
        (cancellation, cancellation_backtrace, _rejection) ->
      complete Exact_lane_run_registry.Cancelled `Null;
      on_finish Terminalization_rejected;
      Printexc.raise_with_backtrace cancellation cancellation_backtrace
    | `Identity_unbound ->
      complete
        (Exact_lane_run_registry.Failed
           { code = "terminalization_identity_unbound"
           ; detail = "exact attempt identity was not durably bound"
           })
        `Null;
      on_finish Terminalization_identity_unbound
    | `Rejected rejection ->
      let detail =
        Keeper_approval_queue_result.exact_attempt_error_to_string
          (Exact_attempt_rejected rejection)
      in
      complete
        (Exact_lane_run_registry.Failed
           { code = "terminalization_rejected"; detail })
        `Null;
      on_finish Terminalization_rejected
    | `Uncertain uncertainty ->
      complete
        (Exact_lane_run_registry.Failed
           { code = "terminalization_persistence_uncertain"
           ; detail = Printexc.to_string uncertainty
           })
        `Null;
      on_finish Terminalization_persistence_uncertain;
      raise uncertainty);
    Ok Worker_forked
;;

let spawn ~sw ~entry ~on_summary ~on_finish () =
  (* Eta-expanded so the cli-runner injection stays a test-surface knob:
     production always spawns the real official client. *)
  spawn_with
    ~queue_ops:production_exact_queue_ops
    ~prepare_flow
    ~sw
    ~entry
    ~on_summary
    ~on_finish
    ()
;;

module For_testing = struct
  let with_outcome_sink = with_outcome_sink
  let next_observed_outcome = next_observed_outcome
  let run_outcome_of_observed_summary = run_outcome_of_observed_summary

  type nonrec prepared_flow = prepared_flow
  type nonrec exact_transition = exact_transition
  type nonrec exact_completion_transition = exact_completion_transition
  type nonrec exact_quarantine_transition = exact_quarantine_transition
  type nonrec exact_queue_ops = exact_queue_ops

  let prepare_flow = prepare_flow
  let execute_prepared_flow = execute_prepared_flow

  let make_exact_queue_ops
        ?(bind = production_exact_queue_ops.bind)
        ?(release_before_dispatch =
          production_exact_queue_ops.release_before_dispatch)
        ?(complete = production_exact_queue_ops.complete)
        ?(quarantine = production_exact_queue_ops.quarantine)
        ?(after_bind = production_exact_queue_ops.after_bind)
        ()
    =
    create_exact_queue_ops
      ~bind
      ~release_before_dispatch
      ~complete
      ~quarantine
      ~after_bind
  ;;

  let execute_prepared_flow_with_queue_ops
        ~queue_ops
        ?cli_runner
        ~net
        ~clock
        ~on_summary
        prepared
    =
    execute_prepared_flow_with_queue_ops
      ~queue_ops
      ?cli_runner
      ~net
      ~clock
      ~on_summary
      prepared
  ;;

  let spawn_with_queue_ops
        ~queue_ops
        ?cli_runner
        ~sw
        ~entry
        ~on_summary
        ~on_finish
        ()
    =
    spawn_with
      ~queue_ops
      ?cli_runner
      ~prepare_flow
      ~sw
      ~entry
      ~on_summary
      ~on_finish
      ()
  ;;

  let flow_evidence prepared =
    match prepared.transport with
    | Cli_only -> None
    | Http_attempt (attempt, _) -> Some (Exact_output.flow_attempt_evidence attempt)
  let system_prompt = system_prompt
  let lane_id = lane_id
end
;;
