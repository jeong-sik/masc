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
  trigger : Compaction_trigger.t;
  evidence : Keeper_compaction_evidence.t;
  turn_generation : int;
  projection_target : Keeper_compaction_projection_target.committed;
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
  | Checkpoint_cas_failed (Commit_durability_unknown _) ->
    "checkpoint_commit_durability_unknown"
  | Checkpoint_cas_failed (Transaction_outcome_unknown _) ->
    "checkpoint_transaction_outcome_unknown"
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
  | Commit_durability_unknown { installed_ref; error } ->
    Printf.sprintf
      "checkpoint commit durability unknown: %s error=%s"
      (checkpoint_ref_detail installed_ref)
      (Keeper_fs.durable_write_error_to_string error)
  | Transaction_outcome_unknown { possible_installed_ref; error } ->
    Printf.sprintf
      "checkpoint transaction outcome unknown: %s error=%s"
      (checkpoint_ref_detail possible_installed_ref)
      (File_lock_eio.durable_lock_error_to_string error)

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
      (Keeper_event_queue_state.no_compaction_reason_label reason)
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
   through. When on, [Recovery.classify_string] runs against any
   error signal surfaced by the turn's compaction or handoff steps,
   and a [`Assoc] meta tree is upserted into
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
        turn_generation = meta.runtime.generation;
        checkpoint_bytes = 0;
        message_count = 0;
      }
  | Some cp ->
      let ctx = context_of_oas_checkpoint cp in
      let current_generation =
        checkpoint_generation cp ~fallback:meta.runtime.generation
      in
      let base_meta =
        if current_generation = meta.runtime.generation then meta
        else
          map_runtime
            (fun rt -> { rt with generation = current_generation })
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

let commit_prepared_after_save ~trigger ~save =
  match save () with
  | Error _ as error -> error
  | Ok checkpoint -> Ok (checkpoint, trigger)
;;

let terminal_reason_of_rejection = function
  | Keeper_compact_policy.No_eligible_history ->
    Some Keeper_event_queue_state.No_eligible_history
  | Invalid_structure _ -> Some Invalid_structural_source
  | Structurally_unchanged -> Some Structurally_unchanged
  | Checkpoint_not_reduced -> Some Checkpoint_not_reduced
  | Invalid_compaction_plan -> Some Domain_invalid_output
  | Exact_execution_failed_after_dispatch ->
    Some Execution_may_have_dispatched
  | Exact_lane_unconfigured ->
    Some Keeper_event_queue_state.Exact_lane_unconfigured
  | Invalid_structural_evidence _
  | Exact_target_selection_failed
  | Exact_admission_failed
  | Exact_execution_context_unavailable
  | Exact_execution_failed_before_dispatch -> None
;;

type prepared_compaction =
  { session : Keeper_context_core.session_context
  ; source_ref : Keeper_checkpoint_ref.t
  ; retry_meta : keeper_meta
  ; turn_generation : int
  ; prepared_trigger : Compaction_trigger.t
  ; projection_target : Keeper_compaction_projection_target.t
  ; context : Keeper_context_core.working_context
  ; evidence : Keeper_compaction_evidence.t
  }

let no_compaction_of_uncommitted_prepared prepared =
  { source = prepared.source_ref; reason = Execution_may_have_dispatched }
;;

let prepare_compaction_admitted
      ~compact_for_request
      ~base_dir
      ~(meta : keeper_meta)
      ~(trigger : Compaction_trigger.t)
      ~projection_request
  : (prepared_compaction, compaction_recovery_error) result =
  (* Load the durable source and run the policy + LLM planner.  This phase
     is deliberately admission-free: the keeper's turn slot is not held
     while the provider call runs.  Correctness after an interleaved state
     change is enforced by the source CAS at commit, not by the slot. *)
  let projection_target =
    Keeper_compaction_projection_target.capture projection_request
  in
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
      checkpoint_generation checkpoint ~fallback:meta.runtime.generation
    in
    let ctx = context_of_oas_checkpoint checkpoint in
    let retry_meta =
      if turn_generation = meta.runtime.generation then meta
      else map_runtime (fun rt -> { rt with generation = turn_generation }) meta
    in
    let preparation : Keeper_compact_policy.compaction_preparation =
      compact_for_request
        ~meta:retry_meta
        ~trigger
        ctx
    in
    (match preparation.decision, preparation.evidence with
     | Keeper_compact_policy.Prepared _, None ->
       (* Prepared-without-evidence is a planner invariant violation (a bug),
          not a deterministic no-op: it must surface as a visible failure,
          never settle as a durable terminal no-compaction. *)
       Error
         (Checkpoint_candidate_failed
            "compaction preparation completed without structural evidence \
             (planner invariant violation)")
     | Keeper_compact_policy.Prepared prepared_trigger, Some evidence ->
       Ok
         { session
         ; source_ref
         ; retry_meta
         ; turn_generation
         ; prepared_trigger
         ; projection_target
         ; context = preparation.context
         ; evidence
         }
     | Keeper_compact_policy.Rejected (_, reason), _ ->
       (match terminal_reason_of_rejection reason with
        | Some reason -> Error (No_compaction { source = source_ref; reason })
        | None -> Error (Compaction_rejected reason))
     | (Keeper_compact_policy.Applied _
       | Keeper_compact_policy.Not_requested
       | Keeper_compact_policy.Skipped_no_checkpoint) as decision, _ ->
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
      ~(meta : keeper_meta)
      ~(trigger : Compaction_trigger.t)
      ~projection_request
  : (prepared_compaction, compaction_recovery_error) result =
  let suspended =
    Keeper_meta_contract.compaction_retry_suspended meta.runtime.compaction_rt
  in
  match trigger with
  | Compaction_trigger.Provider_overflow _ when suspended ->
    Error
      (Retry_suspended
         { consecutive_failures =
             meta.runtime.compaction_rt.consecutive_failures
         })
  | Compaction_trigger.Provider_overflow _ | Compaction_trigger.Manual ->
    prepare_compaction_admitted
      ~compact_for_request
      ~base_dir
      ~meta
      ~trigger
      ~projection_request
;;

let prepare_compaction =
  prepare_compaction_with
    ~compact_for_request:Keeper_compact_policy.compact_for_request_typed
;;

let commit_prepared_compaction (prepared : prepared_compaction)
  : (compaction_recovery, compaction_recovery_error) result =
  (* Source-CAS commit.  The caller decides which admission (if any) guards
     this phase; correctness against interleaved state change is enforced
     by [expected_source_ref], not by the slot. *)
  let { session
      ; source_ref
      ; retry_meta
      ; turn_generation
      ; prepared_trigger
      ; projection_target
      ; context
      ; evidence
      } =
    prepared
  in
  (try
     match
       commit_prepared_after_save
         ~trigger:prepared_trigger
         ~save:(fun () ->
           save_oas_checkpoint_if_source
             ~multimodal_policy:retry_meta.multimodal_policy
             ~keeper_name:retry_meta.name
             ~session
             ~agent_name:retry_meta.agent_name
             ~ctx:context
             ~generation:turn_generation
             ~expected_source_ref:source_ref
           |> Result.map_error (function
             | Tool_history_invalid _ ->
               No_compaction
                 { source = source_ref
                 ; reason = Keeper_event_queue_state.Invalid_structural_source
                 }
             | Persistence_error error -> Checkpoint_cas_failed error))
     with
     | Ok ((saved_checkpoint, installed_ref), trigger) ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string Compactions)
         ~labels:[ "keeper", retry_meta.name ]
         ();
       Ok
         { checkpoint = saved_checkpoint
         ; trigger
         ; evidence
         ; turn_generation
         ; projection_target =
             Keeper_compaction_projection_target.bind_committed_checkpoint
               installed_ref
               projection_target
         }
     | Error
         (Checkpoint_cas_failed (Keeper_checkpoint_store.Source_changed actual) as error) ->
       Log.Keeper.warn
         "compaction checkpoint source changed: %s"
         (checkpoint_ref_detail actual);
       Error error
     | Error (Checkpoint_cas_failed cas_error as error) ->
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
       Error error
     | Error error -> Error error
   with
   | Eio.Cancel.Cancelled _ as exn -> raise exn
   | exn ->
     let detail = Printexc.to_string exn in
     log_keeper_exn ~label:"compaction checkpoint save exception" exn;
     Error (Checkpoint_candidate_failed detail))
;;

let recover_latest_checkpoint_for_compaction
    ~(base_dir : string)
    ~(meta : keeper_meta)
    ~(trigger : Compaction_trigger.t)
    ~projection_request
  : (compaction_recovery, compaction_recovery_error) result =
  match prepare_compaction ~base_dir ~meta ~trigger ~projection_request with
  | Error _ as error -> error
  | Ok prepared -> commit_prepared_compaction prepared
;;
