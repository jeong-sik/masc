(** Keeper_post_turn — post-turn checkpoint preservation and explicit
    compaction recovery.

    Orchestrates the end-of-turn checkpoint pipeline. Compaction is entered
    only through an explicit typed request from its owner lane.

    This module owns only the checkpoint/lineage tail of a keeper turn.
    Current-memory selection runs in
    [Keeper_agent_run_post_turn_memory]; task learning remains in
    [Workspace_task].

    Extracted from Keeper_context_runtime as part of #4955 god-file split.

    Generation-lineage properties this tail maintains: identity is stable
    across generations, trace_id is replaced per generation, ancestry is
    append-only, and checkpoint commit preserves checkpoint-valid /
    checkpoint-generation parity once the keeper is back to idle. While an
    in-flight turn is still resolving, the compaction phase feeds into
    [keeper_phase] = "running".

    Out of scope here: explicit compaction requests, the [Agent.run] turn
    loop, and long-term memory recall. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_core

type post_turn_lifecycle = {
  updated_meta : keeper_meta;
  checkpoint : Agent_core.Checkpoint.t option;
  handoff_json : Yojson.Safe.t option;
  handoff_attempted : bool;
  handoff_failure_reason : string option;
  checkpoint_bytes : int;
  message_count : int;
}

type compaction_recovery = {
  checkpoint : Agent_core.Checkpoint.t;
  checkpoint_installation : Keeper_checkpoint_store.installed_checkpoint;
  trigger : Compaction_trigger.t;
  evidence : Keeper_compaction_evidence.t;
  commit_count : int;
}

type no_compaction = Keeper_compaction_outcome.no_compaction =
  { source : Keeper_checkpoint_ref.t
  ; reason : Keeper_compaction_outcome.no_compaction_reason
  }

type compaction_recovery_error =
  | Checkpoint_ref_load_failed of Keeper_checkpoint_store.checkpoint_ref_load_error
  | Checkpoint_candidate_failed of string
  | Compaction_rejected of Keeper_compact_policy.compaction_rejection
  | No_compaction of no_compaction

type prepared_commit_failure =
  { error : compaction_recovery_error
  ; committed : compaction_recovery option
  }

type prepared_commit_outcome =
  | Committed of compaction_recovery
  | Not_committed of no_compaction
  | Commit_failed of prepared_commit_failure

let compaction_recovery_error_to_tag = function
  | Checkpoint_ref_load_failed Keeper_checkpoint_store.Ref_not_found ->
    "checkpoint_not_found"
  | Checkpoint_ref_load_failed _ -> "checkpoint_load_failed"
  | Checkpoint_candidate_failed _ -> "checkpoint_candidate_failed"
  | Compaction_rejected reason ->
    Keeper_compact_policy.compaction_rejection_to_tag reason
  | No_compaction { reason; _ } ->
    "no_compaction:" ^ Keeper_compaction_outcome.no_compaction_reason_label reason

let checkpoint_load_error_detail = function
  | Keeper_checkpoint_store.Not_found -> "checkpoint not found"
  | Store_error detail
  | Parse_error detail
  | Io_error detail
  | Agent_core_error detail -> detail

let checkpoint_identity_error_detail = function
  | Keeper_checkpoint_store.Session_id_invalid detail ->
    "invalid session id: " ^ detail
  | Ref_create_failed (Keeper_checkpoint_ref.Negative_turn_count turn_count) ->
    Printf.sprintf "negative checkpoint turn count: %d" turn_count
  | Ref_create_failed (Invalid_sha256 digest) ->
    Printf.sprintf "invalid checkpoint SHA-256: %s" digest

let checkpoint_ref_detail (reference : Keeper_checkpoint_ref.t) =
  Printf.sprintf
    "trace_id=%s turn_count=%d sha256=%s"
    (Keeper_id.Trace_id.to_string reference.trace_id)
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
  | Checkpoint_candidate_failed detail -> detail
  | Compaction_rejected reason ->
    "compaction rejected: "
    ^ Keeper_compact_policy.compaction_rejection_to_string reason
  | No_compaction { source; reason } ->
    Printf.sprintf
      "no compaction for trace_id=%s turn_count=%d sha256=%s: %s"
      (Keeper_id.Trace_id.to_string source.trace_id)
      source.turn_count
      source.sha256
      (Keeper_compaction_outcome.no_compaction_reason_to_string reason)

let apply_tool_emission_wirein
    (lifecycle : post_turn_lifecycle) : post_turn_lifecycle =
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
              ~working_context:cp.Agent_core.Checkpoint.working_context
          in
          let new_cp =
            { cp with Agent_core.Checkpoint.working_context = new_wc }
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
         cp.Agent_core.Checkpoint.working_context
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
            { cp with Agent_core.Checkpoint.working_context = new_wc }
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

let apply_post_turn_lifecycle
    ~(meta : keeper_meta)
    ~(checkpoint : Agent_core.Checkpoint.t option) : post_turn_lifecycle =
  let now_ts = Time_compat.now () in
  let body = match checkpoint with
  | None ->
      let updated_meta = meta in
      {
        updated_meta;
        checkpoint = None;
        handoff_json = None;
        handoff_attempted = false;
        handoff_failure_reason = None;
        checkpoint_bytes = 0;
        message_count = 0;
      }
  | Some cp ->
      let ctx = context_of_agent_core_checkpoint cp in
      let base_meta = meta in
      let meta_after_context_check = base_meta in
      {
        updated_meta = meta_after_context_check;
        checkpoint = Some cp;
        handoff_json = None;
        handoff_attempted = false;
        handoff_failure_reason = None;
        checkpoint_bytes = serialized_bytes ctx;
        message_count = message_count ctx;
      }
  in
  (* Strict ordering: tool emission drain (K4b) → multimodal hydration (K1).
     K4b precedes multimodal because it is the producer that K1 consumes. The
     multimodal pass runs last because it persists a [workspace_meta] summary
     that depends on whether the prior pass has already mutated
     [working_context]. *)
  let body = apply_tool_emission_wirein body in
  apply_multimodal_wirein ~now:now_ts body

type rejection_disposition =
  | Terminal_no_compaction of Keeper_compaction_outcome.no_compaction_reason
  | Nonterminal_rejection

let rejection_disposition = function
  | Keeper_compact_policy.No_eligible_history ->
    Terminal_no_compaction Keeper_compaction_outcome.No_eligible_history
  | No_reducible_boundary ->
    Terminal_no_compaction Keeper_compaction_outcome.No_reducible_boundary
  | Invalid_structure _ ->
    Terminal_no_compaction Keeper_compaction_outcome.Invalid_structural_source
  | Exact_execution_terminal terminal ->
    Terminal_no_compaction
      (Keeper_compaction_outcome.Exact_execution_terminal terminal)
  | Invalid_structural_evidence (_, terminal) ->
    Terminal_no_compaction
      (Keeper_compaction_outcome.Exact_execution_terminal terminal)
  | Exact_lane_unconfigured ->
    Terminal_no_compaction Keeper_compaction_outcome.Exact_lane_unconfigured
  | Invalid_compaction_plan
  | Exact_target_selection_failed
  | Exact_admission_failed
  | Exact_attempt_start_failed
  | Exact_execution_context_unavailable
  | Exact_execution_authority_absent
  | Exact_execution_authority_rejected
  | Exact_flow_already_started ->
    Nonterminal_rejection
;;

type prepared_compaction =
  { session : Keeper_context_core.session_context
  ; source_ref : Keeper_checkpoint_ref.t
  ; retry_meta : keeper_meta
  ; prepared_trigger : Compaction_trigger.t
  ; context : Keeper_context_core.working_context
  ; evidence : Keeper_compaction_evidence.t
  }

let exact_execution_terminal_of_evidence
      cause
      (evidence : Keeper_compaction_evidence.t)
  =
  Keeper_compaction_outcome.
    { cause
    ; slot_id = evidence.slot_id
    ; call_id = evidence.call_id
    ; plan_fingerprint = evidence.plan_fingerprint
    ; request_body_sha256 = evidence.receipt_request_body_sha256
    ; detail = None
    }
;;

let no_compaction_of_prepared
      ?(cause = Keeper_compaction_outcome.Commit_admission_unavailable)
      prepared
  =
  let terminal = exact_execution_terminal_of_evidence cause prepared.evidence in
  { source = prepared.source_ref
  ; reason = Keeper_compaction_outcome.Exact_execution_terminal terminal
  }
;;

let prepare_compaction_admitted
      ~compact_for_request
      ~base_dir
      ~(meta : keeper_meta)
      ~(trigger : Compaction_trigger.t)
  : (prepared_compaction, compaction_recovery_error) result =
  (* Load the durable source and run the policy + LLM planner.  This phase
     is deliberately outside turn execution: no Keeper Owner child is active
     while the provider call runs.  Correctness after an interleaved state
     change is enforced by the source CAS at commit, not by the slot. *)
  let session =
    create_session
      ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ~base_dir
  in
  match
    Keeper_checkpoint_store.load_agent_core_with_ref
      ~session_dir:session.session_dir
      ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
  with
  | Error Keeper_checkpoint_store.Ref_not_found ->
    Log.Keeper.debug
      "keeper:%s compaction AGENT_CORE checkpoint not found"
      (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
    Error (Checkpoint_ref_load_failed Keeper_checkpoint_store.Ref_not_found)
  | Error error ->
    let detail = checkpoint_ref_load_error_detail error in
    Log.Keeper.error
      "keeper:%s compaction AGENT_CORE load error: %s"
      (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      detail;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string Agent_coreExecutionErrors)
      ~labels:
        [ "keeper", meta.name
        ; ( "phase"
          , Keeper_agent_core_execution_error_phase.(to_label Compaction_checkpoint_load) )
        ]
      ();
    Error (Checkpoint_ref_load_failed error)
  | Ok (checkpoint, source_ref) ->
    let ctx = context_of_agent_core_checkpoint checkpoint in
    let retry_meta = meta in
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
          never produce a durable terminal no-compaction outcome. *)
       Error
         (Checkpoint_candidate_failed
            "compaction preparation completed without structural evidence \
             (planner invariant violation)")
     | Keeper_compact_policy.Prepared prepared_trigger, Some evidence ->
       Ok
         { session
         ; source_ref
         ; retry_meta
         ; prepared_trigger
         ; context = preparation.context
         ; evidence
         }
     | Keeper_compact_policy.Rejected (_, reason), _ ->
       (match rejection_disposition reason with
        | Terminal_no_compaction terminal_reason ->
          Error (No_compaction { source = source_ref; reason = terminal_reason })
        | Nonterminal_rejection ->
          Error (Compaction_rejected reason))
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

let prepare_compaction_with
      ~compact_for_request
      ~base_dir
      ~(meta : keeper_meta)
      ~(trigger : Compaction_trigger.t)
  : (prepared_compaction, compaction_recovery_error) result =
  prepare_compaction_admitted
    ~compact_for_request
    ~base_dir
    ~meta
    ~trigger
;;

let prepare_compaction
      ?before_dispatch_authority
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
         ~base_path)
    ~base_dir
    ~meta
    ~trigger
;;

let commit_prepared_compaction_with
    ?(after_checkpoint_installed = fun () -> ())
    ~save_agent_core_checkpoint_if_source
    (prepared : prepared_compaction)
  : prepared_commit_outcome =
  (* Source-CAS commit.  The caller decides which admission (if any) guards
     this phase; correctness against interleaved state change is enforced
     by [expected_source_ref], not by the slot. *)
  let { session
      ; source_ref
      ; retry_meta
      ; prepared_trigger
      ; context
      ; evidence
      } =
    prepared
  in
  let commit_failure ?committed error =
    Commit_failed { error; committed }
  in
  let not_committed cause =
    Not_committed (no_compaction_of_prepared ~cause prepared)
  in
  try
    let candidate_context = agent_core_context_of_context context in
    match
      Keeper_checkpoint_store.compaction_commit_count_of_context
        candidate_context
    with
    | Error detail ->
      Log.Keeper.error
        ~keeper_name:retry_meta.name
        "compaction checkpoint has invalid commit count: %s"
        detail;
      not_committed Keeper_compaction_outcome.Domain_invalid_output
    | Ok source_commit_count when source_commit_count = max_int ->
      Log.Keeper.error
        ~keeper_name:retry_meta.name
        "compaction checkpoint commit count is exhausted";
      not_committed Keeper_compaction_outcome.Domain_invalid_output
    | Ok source_commit_count ->
      let commit_count = source_commit_count + 1 in
      let stamped_context =
        Agent_core.Context.copy ~eio:true candidate_context
      in
      Agent_core.Context.set_scoped
        stamped_context
        Agent_core.Context.Session
        Keeper_checkpoint_store.compaction_commit_count_context_key
        (`Int commit_count);
      let commit_context =
        { checkpoint =
            { context.checkpoint with context = stamped_context }
        }
      in
      (match
         save_agent_core_checkpoint_if_source
           ~runtime_id:(Keeper_meta_contract.runtime_id_of_meta retry_meta)
           ~keeper_name:retry_meta.name
           ~session
           ~agent_name:retry_meta.agent_name
           ~ctx:commit_context
           ~expected_source_ref:source_ref
       with
       | Ok
           ( saved_checkpoint
           , Keeper_checkpoint_store.Installed installed ) ->
         let recovery =
           { checkpoint = saved_checkpoint
           ; checkpoint_installation = installed
           ; trigger = prepared_trigger
           ; evidence
           ; commit_count
           }
         in
         (try
            Eio.Cancel.protect
            @@ fun () ->
            after_checkpoint_installed ();
            (* [inc_counter] is best-effort by construction (its wrapper
               swallows and logs); the catch that sat here was a second
               swallow around a total call. *)
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string Compactions)
              ~labels:[ "keeper", retry_meta.name ]
              ();
            Committed recovery
          with
          | Eio.Cancel.Cancelled _ as exn ->
            commit_failure
              ~committed:recovery
              (Checkpoint_candidate_failed
                 ("post-install compaction callback was cancelled: "
                  ^ Printexc.to_string exn))
          | exn ->
            let detail = Printexc.to_string exn in
            log_keeper_exn
              ~label:"post-install compaction callback"
              exn;
            commit_failure
              ~committed:recovery
              (Checkpoint_candidate_failed
                 ("post-install compaction callback raised: "
                  ^ detail)))
       | Ok
           ( _
           , Keeper_checkpoint_store.Not_installed
               { cause = Keeper_checkpoint_store.Source_changed actual; _ } ) ->
         Log.Keeper.warn
           "compaction checkpoint source changed: %s"
           (checkpoint_ref_detail actual);
         not_committed Keeper_compaction_outcome.Checkpoint_source_changed
       | Ok
           (_, Keeper_checkpoint_store.Not_installed { cause = cas_error; _ })
       | Error (Persistence_error cas_error) ->
         let detail = checkpoint_cas_error_detail cas_error in
         Log.Keeper.error
           "compaction checkpoint save failed: %s"
           detail;
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string CheckpointFailures)
           ~labels:
             [ "keeper", retry_meta.agent_name
             ; ( "operation"
               , Keeper_checkpoint_failure_operation.(to_label Compaction_save) )
             ]
           ();
         not_committed
           Keeper_compaction_outcome.Checkpoint_persistence_failed
       | Error (Tool_history_invalid _) ->
         not_committed
           Keeper_compaction_outcome.Invalid_structural_source_after_dispatch)
  with
  | Eio.Cancel.Cancelled _ as exn ->
    let raw_bt = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace exn raw_bt
  | exn ->
    let detail = Printexc.to_string exn in
    log_keeper_exn ~label:"compaction checkpoint save exception" exn;
    Log.Keeper.error
      "compaction checkpoint save exception became terminal: %s"
      detail;
    not_committed Keeper_compaction_outcome.Checkpoint_persistence_failed
;;

let commit_prepared_compaction prepared =
  commit_prepared_compaction_with
    ~save_agent_core_checkpoint_if_source
    prepared
;;

module For_testing = struct
  let commit_prepared_compaction_with_history
        ?after_checkpoint_installed
        ~save_agent_core_history
        prepared
    =
    commit_prepared_compaction_with
      ?after_checkpoint_installed
      ~save_agent_core_checkpoint_if_source:
        (Keeper_context_core.For_testing.save_agent_core_checkpoint_if_source_with_history
           ~save_agent_core_history)
      prepared
  ;;
end

let recover_latest_checkpoint_for_compaction
    ?before_dispatch_authority
    ~(base_path : string)
    ~(base_dir : string)
    ~(meta : keeper_meta)
    ~(trigger : Compaction_trigger.t)
    ()
  : prepared_commit_outcome =
  match
    prepare_compaction
      ?before_dispatch_authority
      ~base_path
      ~base_dir
      ~meta
      ~trigger
      ()
  with
  | Error error -> Commit_failed { error; committed = None }
  | Ok prepared -> commit_prepared_compaction prepared
;;
