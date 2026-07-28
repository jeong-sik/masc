(** Keeper_post_turn — post-turn checkpoint preservation and explicit
    compaction recovery.

    Orchestrates the end-of-turn checkpoint pipeline. Compaction is entered
    only through an explicit typed request from its owner lane.

    This module owns only the checkpoint/lineage tail of a keeper turn.
    Memory bank append, episode flush, and Hebbian learning are recorded
    elsewhere:
    - memory bank / episodes: [Keeper_agent_run] tail after [Agent.run]
    - hebbian: task lifecycle in [Workspace_task]

    Extracted from Keeper_context_runtime as part of #4955 god-file split.

    Spec navigation (OCaml -> TLA+) — plan §19 anchor pattern.  Sibling
    Authoritative spec
    mirror is [specs/keeper-state-machine/KeeperGenerationLineage.tla].

    Spec lines 10-13 already cite this module as one of three modeled
    OCaml sources:
      - lib/keeper/keeper_post_turn.ml   (this file — post-turn pipeline)
      - lib/keeper_types/keeper_types.mli (type lineage — anchor deferred)

    This block is the reverse-direction citation so code search for
    "KeeperGenerationLineage" lands here.

    Post-turn -> spec mapping:
      Compaction phase    feeds into [keeper_phase] = "running" while
                          the in-flight turn is still resolving.
      Checkpoint commit    preserves the spec's checkpoint-valid /
                          checkpoint-generation parity invariant.

    Spec scope (line 4-8): same identity across generations,
    trace_id replacement, append-only ancestry, checkpoint lineage
    parity once back to idle.

    Spec out-of-scope (line 15-18 in spec): explicit compaction requests,
    Agent.run turn loop, and long-term memory recall. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_core

type post_turn_lifecycle = {
  updated_meta : keeper_meta;
  checkpoint : Agent_sdk.Checkpoint.t option;
  handoff_json : Yojson.Safe.t option;
  handoff_attempted : bool;
  handoff_failure_reason : string option;
  turn_generation : int;
  checkpoint_bytes : int;
  message_count : int;
}

type compaction_recovery = {
  checkpoint : Agent_sdk.Checkpoint.t;
  checkpoint_installation : Keeper_checkpoint_store.checkpoint_installation;
  trigger : Compaction_trigger.t;
  evidence : Keeper_compaction_evidence.t;
  turn_generation : int;
}

type no_compaction = Keeper_event_queue_state.no_compaction =
  { source : Keeper_checkpoint_ref.t
  ; reason : Keeper_event_queue_state.no_compaction_reason
  }

type compaction_recovery_error =
  | Checkpoint_ref_load_failed of Keeper_checkpoint_store.checkpoint_ref_load_error
  | Checkpoint_cas_failed of Keeper_checkpoint_store.checkpoint_cas_error
  | Checkpoint_candidate_failed of string
  | Compaction_rejected of Keeper_compact_policy.compaction_rejection
  | No_compaction of no_compaction
  | Retry_suspended of { consecutive_failures : int }

type prepared_commit_failure =
  { error : compaction_recovery_error
  ; committed : compaction_recovery option
  }

type prepared_commit_completion =
  | Commit_completion_committed of compaction_recovery
  | Commit_completion_rejected of no_compaction
  | Commit_completion_failed of prepared_commit_failure

type prepared_commit_outcome =
  | Committed of compaction_recovery
  | Commit_in_progress of prepared_commit_completion Eio.Promise.t
  | Already_committed of compaction_recovery
  | Already_rejected of no_compaction
  | Commit_failed of prepared_commit_failure

let compaction_recovery_error_to_tag = function
  | Checkpoint_ref_load_failed Keeper_checkpoint_store.Ref_not_found ->
    "checkpoint_not_found"
  | Checkpoint_ref_load_failed _ -> "checkpoint_load_failed"
  | Checkpoint_cas_failed (Keeper_checkpoint_store.Source_changed _) ->
    "checkpoint_source_changed"
  | Checkpoint_cas_failed (Source_unavailable _) ->
    "checkpoint_source_unavailable"
  | Checkpoint_cas_failed
      (Candidate_identity_invalid _
      | Candidate_session_mismatch _
      | Candidate_generation_mismatch _
      | Candidate_turn_regressed _) ->
    "checkpoint_candidate_invalid"
  | Checkpoint_cas_failed (Commit_not_installed _) ->
    "checkpoint_commit_not_installed"
  | Checkpoint_candidate_failed _ -> "checkpoint_candidate_failed"
  | Compaction_rejected reason ->
    Keeper_compact_policy.compaction_rejection_to_tag reason
  | No_compaction { reason; _ } ->
    "no_compaction:" ^ Keeper_event_queue_state.no_compaction_reason_label reason
  | Retry_suspended _ -> "retry_suspended"

let checkpoint_load_error_detail = function
  | Keeper_checkpoint_store.Not_found -> "checkpoint not found"
  | Store_error detail
  | Parse_error detail
  | Io_error detail
  | Sdk_other_error detail -> detail

let checkpoint_identity_error_detail = function
  | Keeper_checkpoint_store.Session_id_invalid detail ->
    "invalid session id: " ^ detail
  | Generation_missing -> "checkpoint generation is missing"
  | Generation_not_integer -> "checkpoint generation is not an integer"
  | Ref_create_failed (Keeper_checkpoint_ref.Negative_generation generation) ->
    Printf.sprintf "negative checkpoint generation: %d" generation
  | Ref_create_failed (Negative_turn_count turn_count) ->
    Printf.sprintf "negative checkpoint turn count: %d" turn_count
  | Ref_create_failed (Invalid_sha256 digest) ->
    Printf.sprintf "invalid checkpoint SHA-256: %s" digest

let checkpoint_ref_detail (reference : Keeper_checkpoint_ref.t) =
  Printf.sprintf
    "trace_id=%s generation=%d turn_count=%d sha256=%s"
    (Keeper_id.Trace_id.to_string reference.trace_id)
    reference.generation
    reference.turn_count
    reference.sha256

let checkpoint_ref_load_error_detail = function
  | Keeper_checkpoint_store.Ref_not_found -> "checkpoint not found"
  | Ref_read_failed error -> checkpoint_load_error_detail error
  | Ref_identity_invalid error -> checkpoint_identity_error_detail error
  | Ref_session_mismatch { expected; actual } ->
    Printf.sprintf
      "checkpoint session mismatch: expected=%s actual=%s"
      (Keeper_id.Trace_id.to_string expected)
      (Keeper_id.Trace_id.to_string actual)
  | Ref_lock_failed detail -> "checkpoint source lock failed: " ^ detail

let checkpoint_cas_error_detail = function
  | Keeper_checkpoint_store.Source_unavailable error ->
    "checkpoint source unavailable: " ^ checkpoint_ref_load_error_detail error
  | Source_changed actual ->
    "checkpoint source changed: " ^ checkpoint_ref_detail actual
  | Candidate_identity_invalid error ->
    "checkpoint candidate identity invalid: "
    ^ checkpoint_identity_error_detail error
  | Candidate_session_mismatch { expected; candidate } ->
    Printf.sprintf
      "checkpoint candidate session mismatch: expected=%s candidate=%s"
      (Keeper_id.Trace_id.to_string expected)
      (Keeper_id.Trace_id.to_string candidate)
  | Candidate_generation_mismatch { expected; candidate } ->
    Printf.sprintf
      "checkpoint candidate generation mismatch: expected=%d candidate=%d"
      expected
      candidate
  | Candidate_turn_regressed { source_turn; candidate_turn } ->
    Printf.sprintf
      "checkpoint candidate turn regressed: source=%d candidate=%d"
      source_turn
      candidate_turn
  | Commit_not_installed error ->
    "checkpoint commit not installed: "
    ^ Keeper_fs.durable_write_error_to_string error

let compaction_recovery_error_to_string = function
  | Checkpoint_ref_load_failed error -> checkpoint_ref_load_error_detail error
  | Checkpoint_cas_failed error -> checkpoint_cas_error_detail error
  | Checkpoint_candidate_failed detail -> detail
  | Compaction_rejected reason ->
    "compaction rejected: "
    ^ Keeper_compact_policy.compaction_rejection_to_string reason
  | No_compaction { source; reason } ->
    Printf.sprintf
      "no compaction for trace_id=%s generation=%d turn_count=%d sha256=%s: %s"
      (Keeper_id.Trace_id.to_string source.trace_id)
      source.generation
      source.turn_count
      source.sha256
      (Keeper_event_queue_state.no_compaction_reason_to_string reason)
  | Retry_suspended { consecutive_failures } ->
    Printf.sprintf
      "compaction retry suspended after %d consecutive failures; reactive \
       prepare refused before the summarizer call — an operator-committed \
       manual compaction resets the streak and lifts the suspension"
      consecutive_failures

(* ── Tier A6: resilience post-turn wire-in (Cycle 23) ──────────────
   Feature-flag-gated layer that runs before tool emission and
   multimodal hydration. The strict ordering is explicit at the call
   site below — do not reorder.

   When [MASC_RESILIENCE] is off (default), this is a pure pass-
   through. When on, untyped compaction or handoff error text is
   fail-closed to operator handoff, and a [`Assoc] meta tree is upserted into
   [working_context["resilience_meta"]].

   Failures inside the wire-in do not propagate — they are logged
   and the unmodified lifecycle result is returned, preserving the
   keeper's primary turn outcome. *)

let apply_resilience_wirein
    ?audit_store
    ?strategy_executor
    ~(now : float)
    (lifecycle : post_turn_lifecycle) : post_turn_lifecycle =
  if not (Resilience.Keeper_bridge.masc_resilience_enabled ()) then lifecycle
  else
    match lifecycle.checkpoint with
    | None ->
        (* No checkpoint to enrich; resilience_meta has no host. *)
        lifecycle
    | Some cp -> (
        try
          let maybe_error = lifecycle.handoff_failure_reason in
          let witness = Resilience.Keeper_bridge.running_witness in
          let outcome =
            Resilience.Keeper_bridge.apply_post_turn_resilience
              witness ?audit_store ?strategy_executor ~now
              ~working_context:cp.Agent_sdk.Checkpoint.working_context
              ~maybe_error ()
          in
          let new_cp =
            { cp with
              Agent_sdk.Checkpoint.working_context = outcome.working_context
            }
          in
          { lifecycle with checkpoint = Some new_cp }
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.warn
            "keeper:%s resilience wire-in failed: %s"
            lifecycle.updated_meta.name (Printexc.to_string exn);
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string PostTurnWireinFailures)
            ~labels:[("keeper", lifecycle.updated_meta.name); ("phase", "resilience")]
            ();
          lifecycle)

(* ── Tier K1: multimodal post-turn wire-in (Cycle 27) ─────────────
   Wire-in that runs after the A5/A6 pair. Reads
   raw multimodal artifacts the keeper agent dropped into
   [working_context["multimodal_artifacts"]], hydrates them via
   [Multimodal_keeper_bridge.hydrate_one], and accumulates them into
   the process-wide [Multimodal.Workspace_holder].

   It consumes the artifact bag and replaces it with a [workspace_meta]
   summary so the next turn does not re-process the same entries.

   Failures inside the wire-in do not propagate — they are logged
   and the unmodified lifecycle result is returned, preserving the
   keeper's primary turn outcome. *)

(* ── Tier K4b: tool-emission drain (Cycle 27) ──────────────────────
   Drains producer-owned typed JSON captured at the Keeper tool execution
   boundary into [working_context["multimodal_artifacts"]] so the
   K1 wirein below picks them up.

   Strict ordering: this MUST run BEFORE [apply_multimodal_wirein].
   K4b emit + K1 hydrate is a producer/consumer pair on the same
   working_context bag.

   Typed tool emission is a normal Keeper capability, not a rollout gate. *)
let apply_tool_emission_wirein
    ~(now : float)
    (lifecycle : post_turn_lifecycle) : post_turn_lifecycle =
  let _ = now in
  match lifecycle.checkpoint with
  | None -> lifecycle
  | Some cp -> (
        try
          let acc =
            (* Tier K4c — pull THIS keeper's accumulator. The typed execution
               boundary records items under the same stable keeper name. *)
            Keeper_tool_emission_hook.accumulator_for_keeper
              lifecycle.updated_meta.name
          in
          let new_wc =
            Keeper_tool_emission_hook.drain_into_working_context
              acc
              ~working_context:cp.Agent_sdk.Checkpoint.working_context
          in
          let new_cp =
            { cp with Agent_sdk.Checkpoint.working_context = new_wc }
          in
          { lifecycle with checkpoint = Some new_cp }
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.warn
            "keeper:%s tool emission drain failed: %s"
            lifecycle.updated_meta.name
            (Printexc.to_string exn);
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string PostTurnWireinFailures)
            ~labels:[("keeper", lifecycle.updated_meta.name); ("phase", "tool_emission_drain")]
            ();
          lifecycle)

let apply_multimodal_wirein
    ~(now : float)
    (lifecycle : post_turn_lifecycle) : post_turn_lifecycle =
  match lifecycle.checkpoint with
  | None -> lifecycle
  | Some cp ->
    (match
       Multimodal.Wirein_helpers.extract_raw_artifacts
         cp.Agent_sdk.Checkpoint.working_context
     with
     | Error detail ->
       Log.Keeper.warn
         "keeper:%s multimodal wire-in contract unavailable: %s"
         lifecycle.updated_meta.name
         detail;
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string PostTurnWireinFailures)
         ~labels:[ ("keeper", lifecycle.updated_meta.name); ("phase", "multimodal_contract") ]
         ();
       lifecycle
     | Ok (raws, wc_rest) ->
       (try
          let added_count = ref 0 in
          let last_id = ref None in
          Multimodal.Workspace_holder.update (fun ws ->
              let ws', added =
                Multimodal.Multimodal_keeper_bridge
                .hydrate_with_workspace ws raws
                  ~now
                  ~created_by:lifecycle.updated_meta.name
              in
              added_count := List.length added;
              (match List.rev added with
               | [] -> ()
               | last :: _ ->
                   last_id :=
                     Some
                       (Shared_types.Artifact_id.to_string
                          (Multimodal.Artifact.any_id last)));
              ws')
          ;
          let workspace_size =
            Multimodal.Workspace.size
              (Multimodal.Workspace_holder.get ())
          in
          let meta =
            `Assoc
              [
                ("added_this_turn", `Int !added_count);
                ("workspace_size", `Int workspace_size);
                ( "last_artifact_id", Json_util.string_opt_to_json !last_id );
                ("at", `Float now);
              ]
          in
          let new_wc =
            Multimodal.Wirein_helpers.upsert_workspace_meta wc_rest
              meta
          in
          let new_cp =
            { cp with Agent_sdk.Checkpoint.working_context = new_wc }
          in
          { lifecycle with checkpoint = Some new_cp }
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.warn
            "keeper:%s multimodal wire-in failed: %s"
            lifecycle.updated_meta.name (Printexc.to_string exn);
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string PostTurnWireinFailures)
            ~labels:[("keeper", lifecycle.updated_meta.name); ("phase", "multimodal")]
            ();
          lifecycle))

let apply_post_turn_lifecycle_with_resilience_handles
    ~(resilience_audit_store : Shared_audit.Store.t option)
    ~(resilience_strategy_executor : Resilience.Recovery.strategy_executor option)
    ~(meta : keeper_meta)
    ~(checkpoint : Agent_sdk.Checkpoint.t option) : post_turn_lifecycle =
  (* Reviewer #13214: an executor without an audit store would let
     retry/fallback/handoff/abort callbacks mutate live state
     without the pre-flight RecoveryAttempted envelope that
     keeper_bridge relies on for durable auditability.  Reject the
     combination at the seam so the invariant fails fast at the
     call site, not later when an envelope is missing. *)
  (match resilience_audit_store, resilience_strategy_executor with
   | None, Some _ ->
     invalid_arg
       "Keeper_post_turn.apply_post_turn_lifecycle_with_resilience_handles: \
        resilience_strategy_executor requires resilience_audit_store; \
        executor without audit store would skip the RecoveryAttempted \
        envelope and break durable auditability"
   | _ -> ());
  let now_ts = Time_compat.now () in
  let no_checkpoint_decision = Keeper_compact_policy.Skipped_no_checkpoint in
  let body = match checkpoint with
  | None ->
      let updated_meta =
        map_runtime
          (fun rt ->
            {
              rt with
              compaction_rt =
                {
                  rt.compaction_rt with
                  last_check_ts = now_ts;
                  last_decision =
                    Keeper_compact_policy.compaction_decision_to_string
                      no_checkpoint_decision
                    |> compaction_runtime_decision_of_string;
                };
            })
          meta
      in
      {
        updated_meta;
        checkpoint = None;
        handoff_json = None;
        handoff_attempted = false;
        handoff_failure_reason = None;
        turn_generation = meta.runtime.nonce;
        checkpoint_bytes = 0;
        message_count = 0;
      }
  | Some cp ->
      let ctx = context_of_oas_checkpoint cp in
      let current_generation =
        checkpoint_generation cp ~fallback:meta.runtime.nonce
      in
      let base_meta =
        if current_generation = meta.runtime.nonce then meta
        else
          map_runtime
            (fun rt -> { rt with nonce = current_generation })
            meta
      in
      let decision = Keeper_compact_policy.Not_requested in
      let meta_after_context_check =
        map_runtime
          (fun rt ->
            {
              rt with
              compaction_rt =
                {
                  rt.compaction_rt with
                  last_check_ts = now_ts;
                  last_decision =
                    Keeper_compact_policy.compaction_decision_to_string
                      decision
                    |> compaction_runtime_decision_of_string;
                };
            })
          base_meta
      in
      {
        updated_meta = meta_after_context_check;
        checkpoint = Some cp;
        handoff_json = None;
        handoff_attempted = false;
        handoff_failure_reason = None;
        turn_generation = current_generation;
        checkpoint_bytes = serialized_bytes ctx;
        message_count = message_count ctx;
      }
  in
  (* Strict ordering: resilience classification → tool emission drain (K4b)
     → multimodal hydration (K1). K4b precedes multimodal because it is the
     producer that K1 consumes. The multimodal pass runs last because it
     persists a [workspace_meta] summary that depends on whether prior passes
     have already mutated [working_context]. *)
  let body =
    apply_resilience_wirein
      ?audit_store:resilience_audit_store
      ?strategy_executor:resilience_strategy_executor
      ~now:now_ts body
  in
  let body = apply_tool_emission_wirein ~now:now_ts body in
  apply_multimodal_wirein ~now:now_ts body

type rejection_disposition =
  | Terminal_no_compaction of Keeper_event_queue_state.no_compaction_reason
  | Owner_generation_deferred
  | Nonterminal_rejection

let rejection_disposition = function
  | Keeper_compact_policy.No_eligible_history ->
    Terminal_no_compaction Keeper_event_queue_state.No_eligible_history
  | Invalid_structure _ -> Terminal_no_compaction Invalid_structural_source
  | Structurally_unchanged -> Terminal_no_compaction Structurally_unchanged
  | Checkpoint_not_reduced -> Terminal_no_compaction Checkpoint_not_reduced
  | Exact_execution_terminal terminal ->
    Terminal_no_compaction
      (Keeper_event_queue_state.Exact_execution_terminal terminal)
  | Invalid_structural_evidence (_, terminal) ->
    Terminal_no_compaction
      (Keeper_event_queue_state.Exact_execution_terminal terminal)
  | Exact_lane_unconfigured ->
    Terminal_no_compaction Keeper_event_queue_state.Exact_lane_unconfigured
  | Invalid_compaction_plan
  | Exact_target_selection_failed
  | Exact_admission_failed
  | Exact_attempt_start_failed
  | Exact_execution_context_unavailable
  | Exact_execution_authority_absent
  | Exact_execution_authority_rejected
  | Exact_execution_bind_failed
  | Exact_flow_already_started ->
    Nonterminal_rejection
;;

type prepared_compaction =
  { session : Keeper_context_core.session_context
  ; source_ref : Keeper_checkpoint_ref.t
  ; retry_meta : keeper_meta
  ; turn_generation : int
  ; prepared_trigger : Compaction_trigger.t
  ; context : Keeper_context_core.working_context
  ; evidence : Keeper_compaction_evidence.t
  ; post_success_terminalizer :
      Keeper_compaction_llm_summarizer.post_success_terminalizer
  ; commit_waiter : prepared_commit_completion Eio.Promise.t
  ; publish_commit_completion : prepared_commit_completion -> unit
  ; canonical_commit_completion :
      prepared_commit_completion option Atomic.t
  }

type uncommitted_prepared_outcome =
  | Uncommitted_terminalized of no_compaction
  | Uncommitted_commit_in_progress of
      prepared_commit_completion Eio.Promise.t
  | Uncommitted_already_committed of compaction_recovery
  | Uncommitted_failed of compaction_recovery_error

let publish_prepared_commit_completion prepared completion =
  if
    Atomic.compare_and_set
      prepared.canonical_commit_completion
      None
      (Some completion)
  then prepared.publish_commit_completion completion
;;

let observed_commit_completion prepared =
  match Atomic.get prepared.canonical_commit_completion with
  | Some (Commit_completion_committed recovery) ->
    Already_committed recovery
  | Some (Commit_completion_rejected no_compaction) ->
    Already_rejected no_compaction
  | Some (Commit_completion_failed failure) ->
    Commit_failed failure
  | None -> Commit_in_progress prepared.commit_waiter
;;

let no_compaction_of_uncommitted_prepared
      ?(cause = Keeper_event_queue_state.Commit_admission_unavailable)
      prepared
  =
  match
    Keeper_compaction_llm_summarizer.terminalize_post_success
      prepared.post_success_terminalizer
      cause
  with
  | Keeper_compaction_llm_summarizer.Terminalized terminal ->
    let no_compaction =
      { source = prepared.source_ref
      ; reason = Exact_execution_terminal terminal
      }
    in
    publish_prepared_commit_completion
      prepared
      (Commit_completion_rejected no_compaction);
    Uncommitted_terminalized no_compaction
  | Keeper_compaction_llm_summarizer.Terminalization_commit_in_progress _ ->
    Uncommitted_commit_in_progress prepared.commit_waiter
  | Keeper_compaction_llm_summarizer.Terminalization_already_committed ->
    (match observed_commit_completion prepared with
     | Already_committed recovery ->
       Uncommitted_already_committed recovery
     | Commit_in_progress waiter ->
       Uncommitted_commit_in_progress waiter
     | Commit_failed failure -> Uncommitted_failed failure.error
     | Already_rejected no_compaction ->
       Uncommitted_terminalized no_compaction
     | Committed recovery ->
       Uncommitted_already_committed recovery)
  | Keeper_compaction_llm_summarizer.Terminalization_persistence_failed
      (_, detail)
  | Keeper_compaction_llm_summarizer.Terminalization_invariant_failed detail ->
    let error = Checkpoint_candidate_failed detail in
    publish_prepared_commit_completion
      prepared
      (Commit_completion_failed { error; committed = None });
    Uncommitted_failed error
;;

let readmission_terminal_cause_of_failure = function
  | Runtime_agent.Still_over_capacity _ ->
    Keeper_event_queue_state.Failed_request_still_over_capacity
  | Runtime_agent.Readmission_failed _ ->
    Keeper_event_queue_state.Failed_request_readmission_failed
;;

let readmission_evidence_failure detail =
  Runtime_agent.Readmission_failed (Agent_sdk.Error.Internal detail)
;;

let readmission_evidence_for_trigger
      trigger
      (evidence : Runtime_agent.capacity_readmission_evidence)
  =
  match trigger with
  | Compaction_trigger.Manual -> Ok ()
  | Compaction_trigger.Request_body_over_capacity { limit_bytes; _ } ->
    if evidence.serialized_body_bytes <= limit_bytes
    then Ok ()
    else
      Error
        (Runtime_agent.Still_over_capacity
           (Agent_sdk.Error.Api
              (Agent_sdk.Retry.InvalidRequest
                 { message =
                     Printf.sprintf
                       "compacted request still requires %d serialized bytes, \
                        limit %d"
                       evidence.serialized_body_bytes
                       limit_bytes
                 ; reason =
                     Agent_sdk.Retry.Request_body_too_large
                       { actual_bytes = evidence.serialized_body_bytes
                       ; limit_bytes
                       }
                 })))
  | Compaction_trigger.Request_body_refused_by_provider { status } ->
    Error
      (readmission_evidence_failure
         (Printf.sprintf
            "provider size refusal status %d exposed no byte boundary; local \
             serialization cannot prove provider re-admission"
            status))
  | Compaction_trigger.Provider_overflow { limit_tokens = None } ->
    Error
      (readmission_evidence_failure
         "provider context overflow exposed no token boundary; local \
          serialization cannot prove provider re-admission")
  | Compaction_trigger.Provider_overflow { limit_tokens = Some provider_limit } ->
    (match evidence.token_fit_limit_tokens with
     | Some admitted_limit when admitted_limit <= provider_limit -> Ok ()
     | Some admitted_limit ->
       Error
         (readmission_evidence_failure
            (Printf.sprintf
               "runtime token admission limit %d is looser than provider \
                overflow limit %d"
               admitted_limit
               provider_limit))
     | None ->
       Error
         (readmission_evidence_failure
            "runtime route has no supported exact token-fit admission for the \
             provider overflow boundary"))
  | Compaction_trigger.Serving_input_capacity _ ->
    if evidence.serving_constraint_admitted
    then Ok ()
    else
      Error
        (readmission_evidence_failure
           "runtime route did not re-admit the candidate against a current \
            serving constraint")
;;

let terminalize_failed_readmission
      ~source
      terminalizer
      cause
  =
  match
    Keeper_compaction_llm_summarizer.terminalize_post_success
      terminalizer
      cause
  with
  | Keeper_compaction_llm_summarizer.Terminalized terminal ->
    Error
      (No_compaction
         { source
         ; reason = Keeper_event_queue_state.Exact_execution_terminal terminal
         })
  | Keeper_compaction_llm_summarizer.Terminalization_persistence_failed
      (_, detail)
  | Keeper_compaction_llm_summarizer.Terminalization_invariant_failed detail ->
    Error (Checkpoint_candidate_failed detail)
  | Keeper_compaction_llm_summarizer.Terminalization_commit_in_progress _ ->
    Error
      (Checkpoint_candidate_failed
         "failed-request re-admission raced with compaction commit")
  | Keeper_compaction_llm_summarizer.Terminalization_already_committed ->
    Error
      (Checkpoint_candidate_failed
         "failed-request re-admission observed an already committed compaction")
;;

let validate_failed_request_readmission
      ~source
      ~trigger
      ~candidate_readmission_probe
      (preparation : Keeper_compact_policy.compaction_preparation)
      post_success_terminalizer
  =
  match trigger with
  | Compaction_trigger.Manual -> Ok ()
  | Compaction_trigger.Provider_overflow _
  | Compaction_trigger.Request_body_over_capacity _
  | Compaction_trigger.Request_body_refused_by_provider _
  | Compaction_trigger.Serving_input_capacity _ ->
    (match candidate_readmission_probe with
     | None ->
       terminalize_failed_readmission
         ~source
         post_success_terminalizer
         Keeper_event_queue_state.Failed_request_readmission_unavailable
     | Some probe ->
       let candidate_checkpoint =
         resume_checkpoint_of_context preparation.context
       in
       (match probe candidate_checkpoint with
        | exception Eio.Cancel.Cancelled _ as cancellation ->
          let _terminalization =
            terminalize_failed_readmission
              ~source
              post_success_terminalizer
              Keeper_event_queue_state.Exact_execution_cancelled
          in
          raise cancellation
        | Ok evidence ->
          (match readmission_evidence_for_trigger trigger evidence with
           | Ok () -> Ok ()
           | Error failure ->
             terminalize_failed_readmission
               ~source
               post_success_terminalizer
               (readmission_terminal_cause_of_failure failure))
        | Error failure ->
          terminalize_failed_readmission
            ~source
            post_success_terminalizer
            (readmission_terminal_cause_of_failure failure)))
;;

let prepare_compaction_admitted
      ~compact_for_request
      ~base_dir
      ~candidate_readmission_probe
      ~(meta : keeper_meta)
      ~(trigger : Compaction_trigger.t)
  : (prepared_compaction, compaction_recovery_error) result =
  (* Load the durable source and run the policy + LLM planner.  This phase
     is deliberately admission-free: the keeper's turn slot is not held
     while the provider call runs.  Correctness after an interleaved state
     change is enforced by the source CAS at commit, not by the slot. *)
  let session =
    create_session
      ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ~base_dir
  in
  match
    Keeper_checkpoint_store.load_oas_with_ref
      ~session_dir:session.session_dir
      ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
  with
  | Error Keeper_checkpoint_store.Ref_not_found ->
    Log.Keeper.debug
      "keeper:%s compaction OAS checkpoint not found"
      (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
    Error (Checkpoint_ref_load_failed Keeper_checkpoint_store.Ref_not_found)
  | Error error ->
    let detail = checkpoint_ref_load_error_detail error in
    Log.Keeper.error
      "keeper:%s compaction OAS load error: %s"
      (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      detail;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string OasExecutionErrors)
      ~labels:
        [ "keeper", meta.name
        ; ( "phase"
          , Keeper_oas_execution_error_phase.(to_label Compaction_checkpoint_load) )
        ]
      ();
    Error (Checkpoint_ref_load_failed error)
  | Ok (checkpoint, source_ref) ->
    let turn_generation =
      checkpoint_generation checkpoint ~fallback:meta.runtime.nonce
    in
    let ctx = context_of_oas_checkpoint checkpoint in
    let retry_meta =
      if turn_generation = meta.runtime.nonce then meta
      else map_runtime (fun rt -> { rt with nonce = turn_generation }) meta
    in
    let preparation : Keeper_compact_policy.compaction_preparation =
      compact_for_request
        ~meta:retry_meta
        ~trigger
        ctx
    in
    (match
       preparation.decision,
       preparation.evidence,
       preparation.post_success_terminalizer
     with
     | Keeper_compact_policy.Prepared _, None, _
     | Keeper_compact_policy.Prepared _, _, None ->
       (* Prepared-without-evidence is a planner invariant violation (a bug),
          not a deterministic no-op: it must surface as a visible failure,
          never settle as a durable terminal no-compaction. *)
       Error
         (Checkpoint_candidate_failed
            "compaction preparation completed without structural evidence \
             (planner invariant violation)")
     | Keeper_compact_policy.Prepared prepared_trigger,
       Some evidence,
       Some post_success_terminalizer ->
       (match
          validate_failed_request_readmission
            ~source:source_ref
            ~trigger
            ~candidate_readmission_probe
            preparation
            post_success_terminalizer
        with
        | Error _ as error -> error
        | Ok () ->
          let commit_waiter, commit_resolver = Eio.Promise.create () in
          Ok
            { session
            ; source_ref
            ; retry_meta
            ; turn_generation
            ; prepared_trigger
            ; context = preparation.context
            ; evidence
            ; post_success_terminalizer
            ; commit_waiter
            ; publish_commit_completion =
                (fun completion ->
                   ignore
                     (Eio.Promise.try_resolve
                        commit_resolver
                        completion
                      : bool))
            ; canonical_commit_completion = Atomic.make None
            })
     | Keeper_compact_policy.Rejected (_, reason), _, _ ->
       (match rejection_disposition reason with
        | Terminal_no_compaction terminal_reason ->
          Error (No_compaction { source = source_ref; reason = terminal_reason })
        | Owner_generation_deferred
        | Nonterminal_rejection ->
          Error (Compaction_rejected reason))
     | (Keeper_compact_policy.Applied _
       | Keeper_compact_policy.Not_requested
       | Keeper_compact_policy.Skipped_no_checkpoint) as decision, _, _ ->
       (* Reaching recovery with a non-preparation decision is an invariant
          violation: surface it as a visible failure with the decision
          detail, never as a hidden terminal no-compaction. *)
       Error
         (Checkpoint_candidate_failed
            (Printf.sprintf
               "compaction recovery reached a non-preparation decision: %s"
               (Keeper_compact_policy.compaction_decision_to_string decision))))
;;

(* RFC-0351 S0 / #25461: reactive admission gate in front of the prepare
   phase. Once the persisted failure streak reaches the escalation threshold
   the settlement already refuses to retry, but each *new* stimulus still paid
   one full prepare — checkpoint load plus a summarizer LLM call — before its
   escalation settled. Refusing the reactive trigger here, before any I/O,
   drops that residual burn to zero. The manual trigger passes through on
   purpose: an operator-committed compaction is the recovery lever — its
   commit resets the streak and lifts the suspension. *)
let prepare_compaction_with
      ~compact_for_request
      ~base_dir
      ~candidate_readmission_probe
      ~(meta : keeper_meta)
      ~(trigger : Compaction_trigger.t)
  : (prepared_compaction, compaction_recovery_error) result =
  let suspended =
    Keeper_meta_contract.compaction_retry_suspended meta.runtime.compaction_rt
  in
  match trigger with
  (* The suspension guard follows the trigger's origin, not its axis. The
     provider token window, serialized byte limit, and serving-admission token
     evidence are all raised by the turn path itself, so a suspended retry must
     refuse them or a keeper whose compactions keep failing would keep
     re-entering compaction on every turn. [Manual] stays exempt: an operator
     asked for this one, and refusing it would leave no way to intervene. *)
  | Compaction_trigger.Provider_overflow _
  | Compaction_trigger.Request_body_over_capacity _
  | Compaction_trigger.Request_body_refused_by_provider _
  | Compaction_trigger.Serving_input_capacity
      (Compaction_trigger.Boundary_unknown _)
  | Compaction_trigger.Serving_input_capacity
      (Compaction_trigger.Input_rejected _)
    when suspended ->
    Error
      (Retry_suspended
         { consecutive_failures =
             meta.runtime.compaction_rt.consecutive_failures
         })
  | Compaction_trigger.Provider_overflow _
  | Compaction_trigger.Request_body_over_capacity _
  | Compaction_trigger.Request_body_refused_by_provider _
  | Compaction_trigger.Serving_input_capacity
      (Compaction_trigger.Boundary_unknown _)
  | Compaction_trigger.Serving_input_capacity
      (Compaction_trigger.Input_rejected _)
  | Compaction_trigger.Manual ->
    prepare_compaction_admitted
      ~compact_for_request
      ~base_dir
      ~candidate_readmission_probe
      ~meta
      ~trigger
;;

let prepare_compaction
      ?before_dispatch_authority
      ?exact_execution_guard
      ?candidate_readmission_probe
      ~base_path
      ~base_dir
      ~meta
      ~trigger
      ()
  =
  prepare_compaction_with
    ~compact_for_request:
      (Keeper_compact_policy.compact_for_request_typed
         ?before_dispatch_authority
         ?exact_execution_guard
         ~base_path)
    ~base_dir
    ~candidate_readmission_probe
    ~meta
    ~trigger
;;

let commit_prepared_compaction_with
    ?(after_checkpoint_installed = fun () -> ())
    ?(complete_post_success_commit =
      Keeper_compaction_llm_summarizer.complete_post_success_commit)
    ~save_oas_checkpoint_if_source
    (prepared : prepared_compaction)
  : prepared_commit_outcome =
  (* Source-CAS commit.  The caller decides which admission (if any) guards
     this phase; correctness against interleaved state change is enforced
     by [expected_source_ref], not by the slot. *)
  let { session
      ; source_ref
      ; retry_meta
      ; turn_generation
      ; prepared_trigger
      ; context
      ; evidence
      ; post_success_terminalizer
      ; _
      } =
    prepared
  in
  let commit_failure ?committed error =
    Commit_failed { error; committed }
  in
  let publish_owner outcome =
    let completion =
      match outcome with
      | Committed recovery -> Commit_completion_committed recovery
      | Already_rejected no_compaction ->
        Commit_completion_rejected no_compaction
      | Commit_failed failure -> Commit_completion_failed failure
      | Commit_in_progress _
      | Already_committed _ ->
        invalid_arg "non-owner prepared commit outcome cannot be published"
    in
    publish_prepared_commit_completion prepared completion;
    outcome
  in
  let terminalized_outcome = function
    | Keeper_compaction_llm_summarizer.Terminalized terminal ->
      Already_rejected
        { source = source_ref
        ; reason = Exact_execution_terminal terminal
        }
    | Keeper_compaction_llm_summarizer.Terminalization_commit_in_progress _ ->
      commit_failure
        (Checkpoint_candidate_failed
           "post-success commit terminalization is already in progress")
    | Keeper_compaction_llm_summarizer.Terminalization_already_committed ->
      commit_failure
        (Checkpoint_candidate_failed
           "commit owner observed an already-committed terminalization")
    | Keeper_compaction_llm_summarizer.Terminalization_persistence_failed
        (_, detail)
    | Keeper_compaction_llm_summarizer.Terminalization_invariant_failed detail ->
      commit_failure (Checkpoint_candidate_failed detail)
  in
  let terminalize_claimed cause =
    Keeper_compaction_llm_summarizer.terminalize_claimed_commit
      post_success_terminalizer
      cause
    |> terminalized_outcome
    |> publish_owner
  in
  let installed_recovery = ref None in
  let commit_claimed () =
    try
     match
       save_oas_checkpoint_if_source
         ~multimodal_policy:retry_meta.multimodal_policy
         ~keeper_name:retry_meta.name
         ~session
         ~agent_name:retry_meta.agent_name
         ~ctx:context
         ~generation:turn_generation
         ~expected_source_ref:source_ref
     with
     | Ok
         ( saved_checkpoint
         , (Keeper_checkpoint_store.Installed _ as installation) ) ->
       let recovery =
         { checkpoint = saved_checkpoint
         ; checkpoint_installation = installation
         ; trigger = prepared_trigger
         ; evidence
         ; turn_generation
         }
       in
       installed_recovery := Some recovery;
       Eio.Cancel.protect
       @@ fun () ->
       (match
          Keeper_compaction_llm_summarizer
          .mark_post_success_checkpoint_installed
            post_success_terminalizer
        with
        | Error detail ->
          publish_owner
            (commit_failure
               ~committed:recovery
               (Checkpoint_candidate_failed detail))
        | Ok () ->
          after_checkpoint_installed ();
          (match
             complete_post_success_commit post_success_terminalizer
           with
           | Error detail ->
             publish_owner
               (commit_failure
                  ~committed:recovery
                  (Checkpoint_candidate_failed detail))
           | Ok () ->
             (try
                Otel_metric_store.inc_counter
                  Keeper_metrics.(to_string Compactions)
                  ~labels:[ "keeper", retry_meta.name ]
                  ()
              with
              | exn ->
                log_keeper_exn
                  ~label:"compaction committed metric emission"
                  exn);
             publish_owner (Committed recovery)))
     | Ok
         ( _
         , Keeper_checkpoint_store.Not_installed
             { cause = Keeper_checkpoint_store.Source_changed actual; _ } ) ->
       Log.Keeper.warn
         "compaction checkpoint source changed: %s"
         (checkpoint_ref_detail actual);
       terminalize_claimed Keeper_event_queue_state.Checkpoint_source_changed
     | Ok
         (_, Keeper_checkpoint_store.Not_installed { cause = cas_error; _ })
     | Error (Persistence_error cas_error) ->
       let detail = checkpoint_cas_error_detail cas_error in
       Log.Keeper.error "compaction checkpoint save failed: %s" detail;
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string CheckpointFailures)
         ~labels:
           [ "keeper", retry_meta.agent_name
           ; ( "operation"
             , Keeper_checkpoint_failure_operation.(to_label Compaction_save) )
         ]
         ();
       terminalize_claimed Keeper_event_queue_state.Checkpoint_persistence_failed
     | Error (Tool_history_invalid _) ->
       terminalize_claimed
         Keeper_event_queue_state.Invalid_structural_source_after_dispatch
    with
    | Eio.Cancel.Cancelled _ as exn ->
      let raw_bt = Printexc.get_raw_backtrace () in
      (match !installed_recovery with
       | None ->
         Eio.Cancel.protect (fun () ->
          ignore
            (terminalize_claimed
               Keeper_event_queue_state.Exact_execution_cancelled));
         Printexc.raise_with_backtrace exn raw_bt
       | Some recovery ->
         Eio.Cancel.protect (fun () ->
          let detail =
            "post-install compaction finalization was cancelled: "
            ^ Printexc.to_string exn
          in
          let terminal_detail =
            match
              Keeper_compaction_llm_summarizer
              .finish_post_success_commit_failure
                post_success_terminalizer
                detail
            with
            | Ok () -> detail
            | Error terminal_detail -> terminal_detail
          in
          publish_owner
            (commit_failure
               ~committed:recovery
               (Checkpoint_candidate_failed terminal_detail))))
    | exn ->
      let detail = Printexc.to_string exn in
      log_keeper_exn ~label:"compaction checkpoint save exception" exn;
      (match !installed_recovery with
       | Some recovery ->
         let terminal_detail =
           match
             Keeper_compaction_llm_summarizer
             .finish_post_success_commit_failure
               post_success_terminalizer
               ("post-install compaction finalization raised: " ^ detail)
           with
           | Ok () -> detail
           | Error terminal_detail -> terminal_detail
         in
         publish_owner
           (commit_failure
              ~committed:recovery
              (Checkpoint_candidate_failed
                 terminal_detail))
       | None ->
         Log.Keeper.error
           "compaction checkpoint save exception became terminal: %s"
           detail;
         terminalize_claimed
           Keeper_event_queue_state.Checkpoint_persistence_failed)
  in
  match
    Keeper_compaction_llm_summarizer.with_post_success_commit
      prepared.post_success_terminalizer
      commit_claimed
  with
  | Keeper_compaction_llm_summarizer.Post_success_commit_result result ->
    result
  | Keeper_compaction_llm_summarizer.Post_success_commit_in_progress _ ->
    Commit_in_progress prepared.commit_waiter
  | Keeper_compaction_llm_summarizer.Post_success_commit_already_committed ->
    observed_commit_completion prepared
  | Keeper_compaction_llm_summarizer.Post_success_commit_rejected _ ->
    observed_commit_completion prepared
;;

let commit_prepared_compaction prepared =
  commit_prepared_compaction_with
    ~save_oas_checkpoint_if_source
    prepared
;;

module For_testing = struct
  let commit_prepared_compaction_with_history
        ?after_checkpoint_installed
        ?complete_post_success_commit
        ~save_oas_history
        prepared
    =
    commit_prepared_compaction_with
      ?after_checkpoint_installed
      ?complete_post_success_commit
      ~save_oas_checkpoint_if_source:
        (Keeper_context_core.For_testing.save_oas_checkpoint_if_source_with_history
           ~save_oas_history)
      prepared
  ;;

  let post_success_snapshot prepared =
    Keeper_compaction_llm_summarizer.For_testing.post_success_snapshot
      prepared.post_success_terminalizer
  ;;

  let claim_post_success_commit prepared =
    Keeper_compaction_llm_summarizer.claim_post_success_commit
      prepared.post_success_terminalizer
  ;;
end

let recover_latest_checkpoint_for_compaction
    ?before_dispatch_authority
    ?exact_execution_guard
    ?candidate_readmission_probe
    ~(base_path : string)
    ~(base_dir : string)
    ~(meta : keeper_meta)
    ~(trigger : Compaction_trigger.t)
    ()
  : prepared_commit_outcome =
  match
    prepare_compaction
      ?before_dispatch_authority
      ?exact_execution_guard
      ?candidate_readmission_probe
      ~base_path
      ~base_dir
      ~meta
      ~trigger
      ()
  with
  | Error (No_compaction no_compaction) ->
    Already_rejected no_compaction
  | Error error -> Commit_failed { error; committed = None }
  | Ok prepared -> commit_prepared_compaction prepared
;;
