(** Keeper_unified_turn — Single entry point for keeper cycles via Agent_core.Agent.run().

    Replaces the 3-path dispatcher (social/proactive/autonomy) with a unified
    observe -> prompt -> Agent.run(tools, guardrails, hooks) loop.
    The model decides what to do; code only enforces safety and observes results.

    @since Unified Keeper Loop *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_context_runtime
include Keeper_turn_helpers
include Keeper_turn_runtime_budget
include Keeper_unified_turn_types


include Keeper_unified_turn_phase_plan

type source_disposition =
  | Follow_failure_route

type turn_failure =
  { error : Agent_core.Error.t
  ; runtime_id : string
  ; route : Keeper_runtime_failure_route.route
  ; source_disposition : source_disposition
  ; deferred_runtime_lane : Keeper_turn_driver.deferred_runtime_lane option
  }

exception Owner_meta_commit_failed of string

let commit_turn_runtime_or_raise ~config ~before ~after =
  match
    Keeper_owner_registry.commit_turn_runtime
      ~base_path:config.Workspace.base_path
      ~keeper_name:before.Keeper_meta_contract.name
      ~before
      ~after
  with
  | Ok (Some committed) -> committed
  | Ok None ->
    raise
      (Owner_meta_commit_failed
         "Keeper Owner removed metadata during failed-turn commit")
  | Error error ->
    raise
      (Owner_meta_commit_failed
         (Keeper_owner_registry.command_error_to_string error))
;;

let turn_failure_of_error
      ~runtime_id
      ~fallback_boundary
      ~exact_failure_execution
      ~deferred_runtime_lane
      error
  =
  match exact_failure_execution with
  | Some (runtime_id, route, source_disposition) ->
    { error; runtime_id; route; source_disposition; deferred_runtime_lane }
  | None ->
    { error
    ; runtime_id
    ; route =
        Keeper_runtime_failure_route.route_of_error
          ~boundary:fallback_boundary
          error
    ; source_disposition = Follow_failure_route
    ; deferred_runtime_lane
    }
;;

let execution_boundary_of_turn_failure error =
  match Keeper_internal_error.classify_masc_internal_error error with
  | Some
      ( Keeper_internal_error.Incomplete_tool_transcript _
      | Keeper_internal_error.Gate_replay_repair_required _ ) ->
    (* Both failures are produced by MASC — the first over the transcript MASC
       persisted, the second after host replay and before provider dispatch.
       The shared [Agent_core.Error.Internal] carrier must not misattribute
       either local boundary to AGENT_CORE. *)
    Keeper_runtime_failure_route.Masc_execution
  | Some
      ( Keeper_internal_error.Runtime_exhausted _
      | Keeper_internal_error.Capacity_backpressure _
      | Keeper_internal_error.Resumable_cli_session _
      | Keeper_internal_error.Accept_rejected _
      | Keeper_internal_error.Internal_unhandled_exception _
      | Keeper_internal_error.Internal_bridge_exception _
      | Keeper_internal_error.Internal_contract_rejected _
      | Keeper_internal_error.Terminal_effect_failed _
      | Keeper_internal_error.Provider_attempt_effect_fenced _
      | Keeper_internal_error.Tool_correction_lost _
      | Keeper_internal_error.Receipt_persistence_failed _ )
  | None ->
    Keeper_runtime_failure_route.Agent_core_execution
;;

type continuation_route_disposition =
  | Continuation_route_addressed
  | Continuation_route_mismatch
  | Continuation_memory_write_completed
  | Continuation_memory_retract_completed
  | Continuation_no_terminal_effect_receipt
  | Continuation_route_not_applicable

type checkpoint_reason = Keeper_turn_checkpoint_reason.t =
  | Operation_queued
  | Durable_stimulus_arrived
  | Awaiting_external_effect
  | Repeated_tool_call of
      { tool_name : string
      ; repeated_count : int
      }
  | Repeated_assistant_text of { repeated_count : int }

type turn_success =
  | Turn_completed of
      { meta : keeper_meta
      ; continuation_route : continuation_route_disposition
      }
  | Turn_checkpointed of
      { meta : keeper_meta
      ; checkpoint_reason : checkpoint_reason
      ; continuation_route : continuation_route_disposition
      }
  | Turn_input_required of keeper_meta
  | Turn_cancelled of keeper_meta
  | Turn_skipped of keeper_meta

let turn_success_of_stop_reason ~meta ~continuation_route = function
  | Runtime_agent.Completed -> Turn_completed { meta; continuation_route }
  | Runtime_agent.Yielded_to_operation_queued _ ->
    Turn_checkpointed { meta; checkpoint_reason = Operation_queued; continuation_route }
  | Runtime_agent.Yielded_to_durable_stimulus _ ->
    Turn_checkpointed
      { meta; checkpoint_reason = Durable_stimulus_arrived; continuation_route }
  | Runtime_agent.Awaiting_external_effect _ ->
    Turn_checkpointed
      { meta; checkpoint_reason = Awaiting_external_effect; continuation_route }
  | Runtime_agent.Yielded_after_repeated_tool_call { tool_name; repeated_count; _ } ->
    Turn_checkpointed
      { meta
      ; checkpoint_reason = Repeated_tool_call { tool_name; repeated_count }
      ; continuation_route
      }
  | Runtime_agent.Yielded_after_repeated_assistant_text { repeated_count; _ } ->
    Turn_checkpointed
      { meta
      ; checkpoint_reason = Repeated_assistant_text { repeated_count }
      ; continuation_route
      }
  | Runtime_agent.InputRequired _ -> Turn_input_required meta
;;

let chat_yield_request ~base_path ~keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | None -> Error (Printf.sprintf "keeper not registered: %s" keeper_name)
  | Some _ ->
    (match Keeper_owner_registry.operation_projection ~base_path ~keeper_name with
     | Error error -> Error (Keeper_owner_registry.lookup_error_to_string error)
     | Ok operations ->
       if operations.Keeper_owner.queued_count > 0
       then Ok (Some Keeper_agent_run.{ reason = Operation_queued })
       else Ok None)
;;

let autonomous_yield_request ~base_path ~keeper_name =
  match chat_yield_request ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok (Some _) as request -> request
  | Ok None ->
    (match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
     | Error _ as error -> error
     | Ok pending ->
       if Keeper_event_queue.is_empty pending
       then Ok None
       else (
         let summary =
           Keeper_agent_run.durable_stimulus_summary ~now:(Time_compat.now ()) pending
         in
         Log.Keeper.info
           ~keeper_name
           "autonomous turn yields to durable stimulus: %s"
           (Keeper_agent_run.durable_stimulus_summary_to_string summary);
         Ok
           (Some
              Keeper_agent_run.
                { reason = Durable_stimulus_waiting summary })))
;;

(* #28809: an approved Gate resolution whose one-shot grant is still unspent
   is not an ordinary queued successor — it is the durable continuation of an
   already-deferred external effect, and the in-flight source may itself be
   the checkpoint that effect belongs to. Waiting for the source terminal can
   therefore starve the replay behind an arbitrarily long run. Deliverability
   is decided by the injected predicate; the wake payloads need no
   self-exclusion here because a resolution threaded into the current turn
   has its grant consumed at tool-bundle build, before this boundary probe
   can run, so it already fails the unspent check. *)
let hitl_replay_preemption_request ~resolution_deliverable ~now pending =
  let stimuli = Keeper_event_queue.to_list pending in
  match
    List.find_opt
      (fun (stimulus : Keeper_event_queue.stimulus) ->
         match stimulus.payload with
         | Keeper_event_queue.Hitl_resolved resolution ->
           resolution_deliverable resolution
         | Keeper_event_queue.Board_signal _
         | Keeper_event_queue.Board_attention _
         | Keeper_event_queue.Bootstrap
         | Keeper_event_queue.Fusion_completed _
         | Keeper_event_queue.Schedule_due _
         | Keeper_event_queue.Connector_attention _
         (* A held HITL approval is what this looks for; an answered question
            is not one, and resumes through its own wake. *)
         | Keeper_event_queue.Ask_answered _
         | Keeper_event_queue.Completion_authority_rejected _
         | Keeper_event_queue.Task_cancelled _
         | Keeper_event_queue.Workspace_message _
         | Keeper_event_queue.Delegate_completed _
         | Keeper_event_queue.Composition_completed _ -> false)
      stimuli
  with
  | None -> None
  | Some selected ->
    let summary = Keeper_agent_run.durable_stimulus_summary ~now pending in
    Some
      Keeper_agent_run.
        { reason =
            Durable_stimulus_waiting
              { summary with
                head = Some selected
              ; head_age_sec = Float.max 0. (now -. selected.arrived_at)
              }
        }
;;

(* Deliverable means the approval has left the pending map (the decision is
   durable) and its grant is still unspent. A rejected resolution carries no
   grant to starve: it reaches the model through ordinary selection or the
   turn-start projection, so it never preempts a run. *)
let approved_resolution_deliverable
      ~base_path
      (resolution : Keeper_event_queue.hitl_resolution)
  =
  match resolution.decision with
  | Keeper_event_queue.Hitl_rejected _ -> false
  | Keeper_event_queue.Hitl_approved ->
    (match
       Keeper_approval_queue.get_pending_entry_for_workspace
         ~base_path
         ~id:resolution.approval_id
     with
     | Ok (Some _) | Error _ -> false
     | Ok None ->
       (match
          Keeper_approval_queue.approved_resolution_state
            ~base_path
            ~id:resolution.approval_id
        with
        | Ok Keeper_approval_queue.Resolution_unconsumed -> true
        | Ok Keeper_approval_queue.Resolution_consumed | Error _ -> false))
;;

let hitl_replay_yield_request ~base_path ~keeper_name =
  match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
  | Error _ as error -> error
  | Ok pending ->
    let request =
      hitl_replay_preemption_request
        ~resolution_deliverable:(approved_resolution_deliverable ~base_path)
        ~now:(Time_compat.now ())
        pending
    in
    Option.iter
      (fun (request : Keeper_agent_run.autonomous_yield_request) ->
         match request.reason with
         | Keeper_agent_run.Operation_queued -> ()
         | Keeper_agent_run.Durable_stimulus_waiting summary ->
           Log.Keeper.info
             ~keeper_name
             "autonomous source turn yields to an approved Gate resolution: %s"
             (Keeper_agent_run.durable_stimulus_summary_to_string summary))
      request;
    Ok request
;;

let autonomous_yield_request_for_wake ~wake ~base_path ~keeper_name =
  match wake with
  (* A nonempty [Woken] is the event queue input already selected for this
     turn. It may yield for chat delivery. Two successors may preempt at a
     persisted post-tool boundary: an approved Gate resolution whose grant is
     still unspent (#28809 — the source may be the very checkpoint that
     resolution continues). The selected source remains pending and resumes
     after the preemptor. Other queued successors still wait for the source
     terminal. *)
  | Keeper_registry.Woken (_ :: _) ->
    fun () ->
      (match chat_yield_request ~base_path ~keeper_name with
       | Error _ as error -> error
       | Ok (Some _) as request -> request
       | Ok None -> hitl_replay_yield_request ~base_path ~keeper_name)
  | Keeper_registry.Proactive_tick | Keeper_registry.Woken [] ->
    fun () -> autonomous_yield_request ~base_path ~keeper_name
  (* Not reachable: [~wake] here originates in [run_keeper_cycle], which the
     chat lane does not call. The autonomous yield request is the conservative answer — it
     asks whether this lane should step aside, and a chat turn that somehow
     arrived here should step aside on the same terms. *)
  | Keeper_registry.Chat_request ->
    fun () -> autonomous_yield_request ~base_path ~keeper_name
;;

let continuation_channel_of_wake = function
  | Keeper_registry.Woken [ payload ] ->
    (match Keeper_event_queue.continuation_channel_of_payload payload with
     | Some channel when Keeper_continuation_channel.is_routable channel ->
       Some channel
     | Some _ | None -> None)
  | Keeper_registry.Woken []
  | Keeper_registry.Woken (_ :: _ :: _)
  | Keeper_registry.Proactive_tick
  | Keeper_registry.Chat_request -> None
;;


let run_keeper_cycle
      ~(before_dispatch_authority : unit -> (unit, string) result)
      ?deferred_runtime_lane
      ?on_deferred_runtime_consumed
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(publication_recovery_provider :
          Keeper_publication_recovery_availability.provider)
      ~(observation : Keeper_world_observation.world_observation)
      ~(wake : Keeper_registry.wake_reason)
      ~(turn_decision : Keeper_world_observation.keeper_cycle_decision)
      ?(previous_turn_stop : Keeper_turn_checkpoint_reason.t option)
      ?shared_context
      ?event_bus
      ?hitl_resolution
      ()
  : (turn_success, turn_failure) result
  =
  match
    Keeper_publication_recovery_scope.resolve_turn_resources
      ~provider:publication_recovery_provider
      ~base_path:config.base_path
      ~keeper_name:meta.name
  with
  | Error failure ->
    let error =
      Agent_core.Error.Config
        (Agent_core.Error.InvalidConfig
           { field = "keeper.publication_recovery_scope"
           ; detail =
               Keeper_publication_recovery_scope.failure_to_string failure
           })
    in
    Error
      { error
      ; runtime_id = Keeper_meta_contract.runtime_id_of_meta meta
      ; route =
          Keeper_runtime_failure_route.route_of_error
            ~boundary:Keeper_runtime_failure_route.Masc_execution
            error
      ; source_disposition = Follow_failure_route
      ; deferred_runtime_lane = None
      }
  | Ok { entry; publication_recovery } ->
  match
    Keeper_unified_turn_pre_dispatch.turn_profile_and_meta
      ~base_path:config.base_path
      ~entry_meta:entry.meta
  with
  | Error error ->
    Error
      { error
      ; runtime_id = Keeper_meta_contract.runtime_id_of_meta meta
      ; route =
          Keeper_runtime_failure_route.route_of_error
            ~boundary:Keeper_runtime_failure_route.Masc_execution
            error
      ; source_disposition = Follow_failure_route
      ; deferred_runtime_lane = None
      }
  | Ok (entry_profile_defaults, meta) ->
  let channel = turn_decision.channel in
  (* TurnComplete bracket — the cycle_completed flag is set to true on the
     [Ok updated_meta] return at the end of this function; an [Error _]
     branch leaves it false and skips the wrap, so completion is recorded
     on success only. *)
  (* 0. Phase gate + state-aware runtime routing.
     The gate owns turn executability; select_runtime remains a total helper
     so dashboards/tests can inspect the same routing contract for blocked
     phases. *)
  let registry_base_path = config.base_path in
  let exact_failure_execution = ref None in
  (* Quota expiry is wall-clock provider evidence. Freeze this observation so
     shaping and dispatch share one ordered runtime suffix. NDT-OK. *)
  let quota_snapshot_now = Unix.gettimeofday () in
  let deferred_runtime_lane =
    Option.map
      (Keeper_turn_driver.quota_ordered_deferred_runtime_lane
         ~now:quota_snapshot_now)
      deferred_runtime_lane
  in
  (* Decide turn_id at function entry so phase-gate and runtime-routing
     terminal paths can include it in the receipt and observability stream. *)
  let keeper_turn_id = meta.runtime.usage.total_turns + 1 in
  let runtime_manifest_context : Keeper_runtime_manifest.turn_context =
    { manifest_keeper_name = meta.name
    ; manifest_trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id
    ; manifest_keeper_turn_id = Some keeper_turn_id
    }
  in
  let turn_start = Mtime_clock.now () in
  let initial_turn_state : Keeper_unified_turn_types.turn_state =
    let degraded_retry_info =
      Option.map
        (fun (hint : Keeper_turn_driver.deferred_runtime_lane) ->
           let fallback_reason =
             match
               Keeper_error_classify.recoverable_runtime_failure_reason
                 hint.failure
             with
             | Some reason -> reason
             | None -> Keeper_error_classify.Deferred_runtime_lane
           in
           { Keeper_error_classify.next_runtime = hint.next_runtime_id
           ; fallback_reason
           })
        deferred_runtime_lane
    in
    { cycle_completed = false
    ; manifest_seq = 0
    ; current_turn_blocker_info = None
    ; last_execution = None
    ; degraded_retry_info
    ; deferred_runtime_lane = None
    ; runtime_rotation_attempts = []
    ; failure_reason = None
    ; retry_phase_started_at = None
    }
  in
  let turn_state =
    Keeper_unified_turn_manifest.append_manifest
      ~config
      ~runtime_manifest_context
      ~turn_start
      ~turn_state:initial_turn_state
      ~site:"turn_started"
      ~decision:
        (`Assoc
          [
            ( "channel",
              `String (Keeper_world_observation.channel_to_string channel) );
          ])
      Keeper_runtime_manifest.Turn_started
  in
  Keeper_turn_fsm.emit_transition
    ~keeper_name:meta.name
    ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Idle
    Keeper_turn_fsm.Phase_gating;
  (* SupervisorRequestsStop / HonorStopSignal — check stop signal at turn entry.
     If the supervisor set [fiber_stop] between the [should_run_turn] gate in the
     heartbeat loop and this point, honor it cooperatively before any I/O is issued.
     Satisfies the FSM contract: active state observed → SupervisorRequestsStop
     (Phase_gating → Phase_gating, stop signal acknowledged) then HonorStopSignal
     (Phase_gating → Cancelled supervisor_stop). *)
  (* RFC-0136 PR-1: phase gate stage extracted to
     [Keeper_unified_turn_phase_gate].  The main turn body is wrapped
     as a nested [main_path] function so the caller can match on a
     typed [phase_gate_outcome] and dispatch each terminal outcome at
     the top of the function body, rather than burying early-exits in
     deeply nested match arms.

     State-aware runtime routing resumes inside [main_path]. *)
  let main_path (turn_state : Keeper_unified_turn_execution.turn_state)
    : (turn_success, Agent_core.Error.t) result
      * Keeper_unified_turn_execution.turn_state
    =
      let effective_runtime_id =
        match deferred_runtime_lane with
        | Some hint -> hint.Keeper_turn_driver.next_runtime_id
        | None -> Keeper_meta_contract.runtime_id_of_meta meta
      in
      let source =
        match Runtime.runtime_id_for_keeper meta.name with
        | Some id when String.trim id <> "" -> "assigned"
        | _ -> "default"
      in
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string RuntimeSelected)
        ~labels:[("keeper", meta.name); ("runtime_id", effective_runtime_id); ("source", source)]
        ();
      let turn_state =
        Keeper_unified_turn_manifest.append_manifest
          ~config
          ~runtime_manifest_context
          ~turn_start
          ~turn_state
          ~site:"runtime_routed"
          ~runtime_id:effective_runtime_id
          (* RFC-0132-EXEMPT: internal observability — manifest decision reason label, not a redacted public surface *)
          ~decision:(`Assoc [ "reason", `String "runtime" ])
          Keeper_runtime_manifest.Runtime_routed
      in
      (* Concrete runtime health/capacity is owned by AGENT_CORE/provider adapters.
         Keeper routing no longer rewrites runtimes from provider cooldown or
         process-queue probes. *)
      (match None with
       | Some meta_after_skip -> Ok (Turn_skipped meta_after_skip), turn_state
       | None ->
         (* RFC-0136 PR-3: pre-dispatch validation extracted to
            [Keeper_unified_turn_pre_dispatch].  profile_defaults stays
            in scope so the retry-loop block below can also call the
            extracted builder with the same defaults. *)
         let effective_runtime_runtime_name = effective_runtime_id in
         (* The snapshot is the one already overlaid onto [meta] above. Loading
            it a second time here is what let the two halves disagree: the
            reload fed the runtime builder while [meta] stayed un-overlaid. *)
         let profile_and_execution =
           Keeper_unified_turn_pre_dispatch.build_runtime_execution
             ~meta
             ~runtime_id:effective_runtime_runtime_name
           |> Result.map (fun execution -> entry_profile_defaults, execution)
         in
         (match profile_and_execution
          with
          | Error err ->
            Option.iter
              (fun _ ->
                 Option.iter
                   (fun consume -> consume ())
                   on_deferred_runtime_consumed)
              deferred_runtime_lane;
            (* The wire code stays exactly what the typed encoder produced.
               [record_pre_dispatch_terminal_observation] already records that
               the turn never dispatched, in three typed fields:
               [completion_contract_result = Completion_not_dispatched],
               [runtime_outcome = Runtime_not_dispatched] and
               [runtime_attempt_count = 0]. A "pre_dispatch_" prefix on top of
               those said nothing new, and it broke the one consumer that
               reads this field: [Keeper_terminal_reason.of_wire] compares
               against ["config_error"] by equality, so the decorated form
               fell through to [Unknown] and every pre-dispatch config failure
               reached the operator as an unmapped runtime state (#29929). *)
            let terminal_reason_code =
              Keeper_agent_error.terminal_reason_code_of_core_error err
            in
            let error_message = Agent_core.Error.to_string err in
            Log.Keeper.error
              ~keeper_name:meta.name
              "%s: pre_dispatch failed: %s"
              meta.name
              error_message;
            record_pre_dispatch_terminal_observation
              ~config
              ~meta
              ~runtime_id:effective_runtime_runtime_name
              ~outcome:`Error
              ~terminal_reason_code
              ~activity_kind:"keeper.turn_blocked"
              ~trajectory_outcome:(Trajectory.Failed terminal_reason_code)
              ~error_kind:
                (Keeper_execution_receipt.error_kind_of_string
                   Agent_core.Error.(category err |> category_label))
              ~error_message
              ~keeper_turn_id
              ();
            let failure_reason =
              match Keeper_turn_driver.classify_masc_internal_error err with
              | _ when EC.is_runtime_exhausted_error err ->
                Keeper_turn_fsm.Failure_runtime_unavailable
                  { base = effective_runtime_runtime_name
                  ; resolved = None
                  }
              | _ ->
                Keeper_turn_fsm.Failure_provider_error
                  { kind = Agent_core.Error.(category err |> category_label)
                  ; detail = error_message
                  }
            in
            Keeper_turn_fsm.emit_transition
              ~keeper_name:meta.name
              ~turn_id:keeper_turn_id
              ~prev:Keeper_turn_fsm.Runtime_routing
              (Keeper_turn_fsm.Failed failure_reason);
            Error err, turn_state
          | Ok (profile_defaults, initial_execution) ->
            let turn_state =
              Keeper_unified_turn_manifest.append_manifest
                ~config
                ~runtime_manifest_context
                ~turn_start
                ~turn_state
                ~site:"runtime_execution_built"
                ~runtime_id:effective_runtime_runtime_name
                ~decision:
                  (`Assoc
                    [ "runtime_execution_built", `Bool true
                    ; "routing_action", `String "runtime_execution_built"
                    ; "routing_reason", `String "pre_dispatch_success"
                    ])
                Keeper_runtime_manifest.Runtime_execution_built
            in
            Keeper_event_publisher.publish_runtime_execution_built
              ~keeper_name:meta.name
              ~runtime_id:initial_execution.runtime_id
              ~max_context:initial_execution.max_context
              ~effective_budget:initial_execution.max_context_resolution.effective_budget
              ~temperature:initial_execution.temperature;
            let turn_id = keeper_turn_id in
            let (_ : Keeper_turn_attempt_observer.start_observation) =
              Keeper_turn_attempt_observer.record_turn_start
                ~base_path:registry_base_path
                ~keeper:meta.name
                ~turn_id
            in
               Keeper_turn_fsm.emit_transition
                 ~keeper_name:meta.name
                 ~turn_id:keeper_turn_id
                 ~prev:Keeper_turn_fsm.Runtime_routing
                 Keeper_turn_fsm.Awaiting_provider;
               (* Yield before CPU-bound prompt construction so the Eio scheduler
         can service HTTP handlers between keeper turn setups. *)
               Eio.Fiber.yield ();
               (* 2. Build unified prompt — diversity entropy recorded in decision_audit
         (keeper_keepalive.ml), not injected into prompt (#6814). *)
               (* RFC-0315: resolve the claimed task and goal titles here (the
                  turn runner owns config), so the prompt can render what the
                  keeper holds and why it woke. Task absence, a dangling id,
                  and an unavailable backlog remain distinct typed prompt
                  inputs; observation failure must not crash the turn or imply
                  that the keeper holds no task. *)
               let current_task =
                 Keeper_world_observation_inputs.read_current_task ~config ~meta
               in
               let skill_snapshot =
                 Keeper_agent_run.capture_skill_snapshot
                   ~base_path:config.base_path
               in
               let task_skill_selection =
                 Keeper_task_skill_turn.resolve_observations
                   ~snapshot:skill_snapshot
                   ~current_task
                   ~held_task_skills:observation.held_task_skills
               in
               let task_skill_surfaces =
                 match task_skill_selection with
                 | Error _ -> []
                 | Ok merged ->
                   Keeper_task_skill_turn.exact_task_surfaces
                     ~snapshot:skill_snapshot
                     ~skill_names:profile_defaults.skill_names
                     ~selection:merged
                     ~current_task
                     ~held_task_skills:observation.held_task_skills
               in
               let active_goal_summaries =
                 Keeper_unified_prompt.active_goal_summaries_of_store ~config
               in
               (* Repository freshness projection (context only, never a
                  gate): where each playground checkout stands against its
                  upstream default branch. A failed scan is logged and the
                  layer stays absent — the keeper_status tool still carries
                  the full typed answer. *)
               let repository_freshness =
                 match
                   Keeper_sandbox_control.checkout_freshness_rows ~config ~meta ()
                 with
                 | Ok rows -> rows
                 (* A keeper that has never materialized its playground has no
                    checkouts to report — absence, not a failure worth a warn
                    on every turn. *)
                 | Error (Keeper_playground_checkouts.Root_missing _) -> []
                 | Error
                     ((Keeper_playground_checkouts.Root_not_directory _
                      | Keeper_playground_checkouts.Root_unreadable _) as
                      scan_error) ->
                   Log.Keeper.warn
                     "repository freshness scan unavailable keeper=%s: %s"
                     meta.name
                     (Keeper_playground_checkouts.scan_error_to_string scan_error);
                   []
               in
               (* The briefing is pinned, so it is bounded here rather than
                  left to the model input projection, which can only cut the
                  conversation window. Sized from the runtime's own declared
                  input ceiling: a runtime that declares none gets no bound,
                  the same answer its projection gives it. Rotation to a larger
                  lane only makes this conservative. *)
               let context_budget_bytes =
                 Runtime.declared_input_byte_ceiling_of_runtime_id effective_runtime_id
                 |> Option.map (fun cap ->
                   cap * Keeper_config.keeper_context_briefing_share_percent () / 100)
               in
               let { Keeper_unified_prompt.system_prompt; world_state; user_message } =
                 Keeper_unified_prompt.build_prompt
                   ~meta
                   ~config
                   ~profile_defaults
                   ~turn_decision
                   ?previous_turn_stop
                   ~current_task
                   ~task_skill_surfaces
                   ~active_goal_summaries
                   ~repository_freshness
                   ?context_budget_bytes
                   ~observation
                   ()
               in
               Eio.Fiber.yield ();
               let base_dir = session_base_dir config in
               (* Ensure session dir tree for trace artifacts. *)
               let (_ : string) =
                 Keeper_fs.ensure_dir
                   (Filename.concat
                      base_dir
                      (Keeper_id.Trace_id.to_string meta.runtime.trace_id))
               in
               let masc_root = Workspace.masc_root_dir config in
               let trajectory_acc =
                 Trajectory.create_accumulator
                   ~masc_root
                   ~keeper_name:meta.name
                   ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                   ()
               in
               (* RFC-0225 §3.3: one carrier per cycle. The pre-request hook
                  writes the effective turn policy here; the decision records
                  below read the same cell, so a concurrent run of this keeper
                  can never substitute its own identity. *)
               let turn_ctx_cell =
                 Keeper_tool_call_log.create_turn_ctx_cell ()
               in
               (* 4. Build turn prompt callback: use our unified system prompt *)
               let build_turn_prompt ~base_system_prompt:_ ~messages:_
                 : Keeper_agent_run.turn_prompt
                 =
                 (* The observation frame rides [dynamic_context]: rebuilt fresh
                    every turn and composed into the per-turn system prompt, so
                    it never enters the persisted AGENT_CORE conversation. Persisting
                    it as a user message re-fed the model its own observations
                    (943/945 identical frames in one live checkpoint, #25193)
                    and exhausted the request window. Persisted user content is utterances
                    only (wake marker + HITL resolutions). *)
                 { system_prompt; dynamic_context = world_state }
               in
               (* 5. Run via Agent_core.Agent.run() with transient-error retry.
                  The turn-local AGENT_CORE Event_bus preserves factual
                  ToolCalled/ToolCompleted pairing and drives
                  Streaming⇄Awaiting_tool_result FSM transitions. It does
                  not infer tool effects or veto retry. *)
               let turn_state =
                 { turn_state with last_execution = Some initial_execution }
               in
               let turn_event_bus_state =
                 Keeper_unified_turn_event_bus.create
                   ?event_bus
                 (* Mirror the in-flight tool count into the
                    live turn_observation so the supervisor sweep excludes
                    active tool execution from the no-progress window. *)
                   ~on_pending_count_change:(fun count ->
                     Keeper_registry.record_turn_tool_inflight
                       ~base_path:config.base_path
                       meta.name
                       ~count)
                   ~keeper_name:meta.name
                   ~turn_id:keeper_turn_id
                   ()
               in
               (* PR-J: [?site] labels the call-site so metric queries can attribute
         drain pressure to background polling vs unsubscribe vs the
         retry path. [outcome=drained] when at least one event was
         pulled, [outcome=empty] otherwise (the latter is the no-op
         tick that establishes the lock-acquire baseline). *)
               let drain_turn_event_bus ?(site = "unspecified") () =
                 Keeper_unified_turn_event_bus.drain ~site turn_event_bus_state
               in
               let event_bus_integrity_error_snapshot () =
                 Keeper_unified_turn_event_bus.integrity_error turn_event_bus_state
               in
               let tool_completed_count_snapshot () =
                 Keeper_unified_turn_event_bus.tool_completed_count turn_event_bus_state
               in
               let start_background_turn_event_bus_drain ~clock =
                 Keeper_unified_turn_event_bus.start_background_drain
                   ~clock
                   turn_event_bus_state
               in
               let unsubscribe_event_bus () =
                 Keeper_unified_turn_event_bus.unsubscribe turn_event_bus_state
               in
               (* Mark turn boundary for the composite observer (issue #7122).
         [mark_turn_started] installs [current_turn_observation = Some _]
         so the composite observer can surface live in-turn states like
         [`Executing`]. The matching [mark_turn_finished] in the finally
         block clears the field, preventing stale state on idle keepers. *)
               Keeper_registry.mark_turn_started ~base_path:config.base_path ~wake meta.name;
               (* Refresh from the committed owner projection, then put the
                  TOML back on. The projection is durable keeper JSON, which
                  omits the TOML-owned fields on purpose
                  ([Keeper_meta_contract.effective_meta_result]), so adopting
                  it whole handed the rest of the turn a meta whose
                  sandbox_profile had reverted to the decoder's placeholder --
                  a keeper whose TOML said docker then ran Execute somewhere
                  else while the status API, which overlays separately, kept
                  answering docker (#31178). The host arm that made it "on the
                  host" is gone (#32078); the drift it describes is not.

                  [effective_meta_of_profile_defaults] exists for exactly this
                  second overlay: the turn loaded [entry_profile_defaults]
                  once in [turn_profile_and_meta] and reapplies it here rather
                  than re-reading the profile, so two reads inside one turn
                  cannot disagree.

                  A profile that no longer applies is not a reason to run the
                  turn under the looser sandbox, so that keeps the meta the
                  turn was admitted with -- the same thing the two arms below
                  already do. *)
               let meta =
                 match
                   Keeper_owner_registry.get
                     ~base_path:config.base_path
                     ~keeper_name:meta.name
                 with
                 | Ok owner ->
                   (match (Keeper_owner.projection owner).meta with
                    | Some latest ->
                      (match
                         Keeper_meta_contract.effective_meta_of_profile_defaults
                           entry_profile_defaults
                           latest
                       with
                       | Ok effective -> effective
                       | Error detail ->
                         Log.Keeper.warn
                           ~keeper_name:meta.name
                           "kept the admitted meta: the owner projection could \
                            not be made effective: %s"
                           detail;
                         meta)
                    | None -> meta)
                 | Error _ -> meta
               in
               Keeper_registry.mark_turn_measurement
                 ~base_path:config.base_path
                 meta.name;
               (match Keeper_registry.get ~base_path:config.base_path meta.name with
                | Some { current_turn_observation = Some { measurement = Some _; _ }; _ }
                  ->
                  Keeper_registry.set_turn_decision_stage
                    ~base_path:config.base_path
                    meta.name
                    Keeper_registry.Decision_active_guard_ok
                | _ -> ());
               let (run_result, turn_state), latency_ms =
                 (* Cancel-safe cleanup (#9747): stdlib [Fun.protect] wraps cleanup
           exceptions in [Fun.Finally_raised], losing the outer
           [Eio.Cancel.Cancelled]. Cleanup here logs its failures instead of
           propagating them, so a cleanup fault cannot replace the turn's own
           outcome.

           Each step runs under [Eio.Cancel.protect]. Since #15932 put the turn
           body inside [turn_sw], this cleanup runs in that switch's context,
           and an Eio call made after it is cancelled raises before doing
           anything. [mark_turn_finished] is a registry file write, so skipping
           it leaves [current_turn_observation] set and the keeper reads as
           mid-turn after its turn ended. The earlier reading — that the outer
           cancellation makes the cleanup unnecessary — is what lost sandbox
           containers in #30590.

           Both steps stay bounded: the registry write takes the keeper key
           lock, which raises [Flock_timeout] rather than waiting forever, so
           [protect] cannot park the caller.

           [Cancelled] is counted and logged like any other failure. A silent
           arm here is why a skipped cleanup left no evidence at all. *)
                 let cleanup () =
                   (try Eio.Cancel.protect unsubscribe_event_bus with
                    | e ->
                      Log.Keeper.warn
                        ~keeper_name:meta.name
                        "%s: unsubscribe_event_bus in turn cleanup raised: %s"
                        meta.name
                        (Printexc.to_string e);
                      Otel_metric_store.inc_counter
                        Keeper_metrics.(to_string TurnCleanupFailures)
                        ~labels:[ "keeper", meta.name; "site", Keeper_turn_cleanup_failure_site.(to_label Unsubscribe_event_bus) ]
                        ());
                   try
                     Eio.Cancel.protect (fun () ->
                       Keeper_registry.mark_turn_finished
                         ~base_path:config.base_path
                         meta.name)
                   with
                   | e ->
                     Log.Keeper.warn
                       ~keeper_name:meta.name
                       "%s: mark_turn_finished in turn cleanup raised: %s"
                       meta.name
                       (Printexc.to_string e);
                     Otel_metric_store.inc_counter
                       Keeper_metrics.(to_string TurnCleanupFailures)
                       ~labels:[ "keeper", meta.name; "site", Keeper_turn_cleanup_failure_site.(to_label Mark_turn_finished) ]
                       ()
                 in
                 match
                   Inference_utils.timed (fun () ->
                     match Eio_context.get_clock () with
                     | Error msg -> Error (Agent_core.Error.Internal msg), turn_state
                     | Ok clock ->
                       start_background_turn_event_bus_drain ~clock;
                       let { Keeper_unified_turn_retry_setup.current_turn_phase_elapsed_ms }
                         =
                         Keeper_unified_turn_retry_setup.build
                           ~now:(fun () -> Eio.Time.now clock)
                       in
                       let run_result, turn_state =
                         Keeper_unified_turn_execution.run
                           { attempt = 1
                           ; base_dir
                           ; build_turn_prompt
                           ; channel
                           ; continuation_channel = continuation_channel_of_wake wake
                           ; hitl_resolution
                           ; cleanup
                           ; config
                           ; drain_turn_event_bus
                           ; event_bus
                           ; event_bus_integrity_error_snapshot
                           ; tool_completed_count_snapshot
                           ; keeper_turn_id
                           ; meta
                           ; turn_ctx_cell
                           ; observation
                           ; profile_defaults
                           ; publication_recovery
                           ; skill_snapshot
                           ; task_skill_selection
                           ; shared_context
                           ; trajectory_acc
                           ; turn_id = keeper_turn_id
                           ; deferred_runtime_lane
                           ; on_deferred_runtime_consumed
                           }
                           ~autonomous_yield_requested:
                             (autonomous_yield_request_for_wake
                                ~wake
                                ~base_path:config.base_path
                                ~keeper_name:meta.name)
                           ~initial_execution
                           ~turn_state
                           ~before_dispatch_authority
                           ~current_turn_phase_elapsed_ms
                           ~user_message
                           ~registry_base_path
                           ~record_streaming_cancelled_observation
                           ~runtime_id_of_meta
                           ~start_background_turn_event_bus_drain
                       in
                       run_result, turn_state
                    )
                 with
                 | result ->
                   cleanup ();
                   result
                 | exception e ->
                   let backtrace = Printexc.get_raw_backtrace () in
                   cleanup ();
                   Printexc.raise_with_backtrace e backtrace
               in
               let turn_event_bus =
                 drain_turn_event_bus ~site:"turn_finalize_capture" ()
               in
               (match turn_event_bus.correlation_id with
                | Some correlation_id ->
                  Keeper_registry.set_last_correlation_id
                    ~base_path:config.base_path
                    meta.name
                    correlation_id
                | None -> ());
               let event_bus_manifest_status =
                 if turn_event_bus.event_count > 0 then "observed" else "empty"
               in
               let turn_state =
                 Keeper_unified_turn_manifest.append_manifest
                   ~config
                   ~runtime_manifest_context
                   ~turn_start
                   ~turn_state
                   ~site:"event_bus_correlated"
                   ~status:event_bus_manifest_status
                   ~clock_refs:
                     (Keeper_runtime_manifest.clock_refs_for_context
                        runtime_manifest_context
                        ~event:Keeper_runtime_manifest.Event_bus_correlated
                        ?event_bus_correlation_id:turn_event_bus.correlation_id
                        ?event_bus_run_id:turn_event_bus.run_id
                        ?caused_by:turn_event_bus.caused_by ())
                   ~decision:
                     (Keeper_runtime_manifest.with_payload_role ~payload_role:Operator_evidence
                        (turn_event_bus_manifest_decision turn_event_bus))
                   Keeper_runtime_manifest.Event_bus_correlated
               in
               let degraded_retry_info = turn_state.degraded_retry_info in
               (* [degraded_retry_info] is seeded at [initial_turn_state] from the
                  [deferred_runtime_lane] argument -- a hint a *previous* turn left
                  behind -- and no path in this turn writes it. Its presence says a
                  deferred lane is pending, not that a retry ran.

                  Applied means this turn actually ran on the runtime the hint
                  named. Presence alone reported "applied" on every turn carrying a
                  hint, which is why fsm-hub.ts could never render its "retry
                  queued" branch, and why an operator reading a receipt saw a retry
                  that had not happened -- carrying a [fallback_reason] computed
                  from the earlier turn's failure rather than this turn's. Observed
                  2026-08-27 on a live receipt whose own error was an invalid
                  request while the reason read rate_limit.

                  The comparison lives in [Keeper_unified_turn_types] so it can be
                  exercised without standing up a keeper cycle. *)
               let degraded_retry_applied =
                 degraded_retry_applied_for_turn
                   ~degraded_retry_info
                   ~last_execution:turn_state.last_execution
               in
               let degraded_retry_runtime =
                 Option.map
                   (fun (retry : EC.degraded_retry) -> retry.next_runtime)
                   degraded_retry_info
               in
               let fallback_reason =
                 Option.map
                   (fun (retry : EC.degraded_retry) -> retry.fallback_reason)
                   degraded_retry_info
               in
               (match run_result with
                | Error err when EC.is_input_required_error err ->
                  (* InputRequired: special stop condition (not a failure).
                     mark_terminal_error already emitted FSM Cancelled
                     transition and info-level log. Surface as Ok so the
                     keeper cycle does not enter failure processing. *)
                  finalize_trajectory_acc
                    ~config
                    ~keeper_name:meta.name
                    trajectory_acc
                    (Trajectory.Gated "input_required");
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string Turns)
                    ~labels:[ "keeper", meta.name; "outcome", "input_required" ]
                    ();
                  let turn_state =
                    { turn_state with cycle_completed = true }
                  in
                  post_turn_complete_task ~cycle_completed:turn_state.cycle_completed;
                  Ok (Turn_input_required meta), turn_state
                | Error err ->
                  (match
                     require_last_execution_for_finalize
                       ~keeper_name:meta.name
                       turn_state
                   with
                   | Error missing_err -> Error missing_err, turn_state
                   | Ok final_execution ->
                     finalize_trajectory_acc
                       ~config
                       ~keeper_name:meta.name
                       trajectory_acc
                       (Trajectory.Failed (Agent_core.Error.to_string err));
                  let e_str = Agent_core.Error.to_string err in
                  let is_transient = EC.is_transient_network_error err in
                  (match err with
                      | Agent_core.Error.Api (Timeout _) ->
                        Otel_metric_store.inc_counter
                          Keeper_metrics.(to_string Agent_coreTimeoutClassifications)
                          ~labels:[ "classification", "transient_network" ]
                          ()
                      | _ -> ());
                  let is_server_parse_rejection = EC.is_server_rejected_parse_error err in
                  let is_provider_wire_error = EC.is_provider_wire_error err in
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string Turns)
                    ~labels:[ "keeper", meta.name; "outcome", "failure" ]
                    ();
                  (if EC.is_provider_timeout_error err
                   then
                     Keeper_turn_fsm.emit_transition
                       ~keeper_name:meta.name
                       ~turn_id:keeper_turn_id
                       ~prev:Keeper_turn_fsm.Streaming
                       (Keeper_turn_fsm.Cancelled
                          Keeper_turn_fsm.Cancelled_provider_timeout)
                   else
                     let fsm_failure_reason =
                       if EC.is_receipt_lost_error err
                       then
                         Keeper_turn_fsm.Failure_receipt_lost
                           { primary_error = e_str; fallback_path = None }
                      else
                        match Keeper_turn_driver.classify_masc_internal_error err with
                         | _ ->
                           Keeper_turn_fsm.Failure_provider_error
                             { kind = Agent_core.Error.(category err |> category_label)
                             ; detail = short_preview e_str
                             }
                     in
                     Keeper_turn_fsm.emit_transition
                       ~keeper_name:meta.name
                       ~turn_id:keeper_turn_id
                       ~prev:Keeper_turn_fsm.Streaming
                       (Keeper_turn_fsm.Failed fsm_failure_reason));
                  let log_keeper_cycle_failed =
                    if EC.should_warn_keeper_cycle_failed err
                    then Log.Keeper.warn
                    else Log.Keeper.error
                  in
                  (* masc#28762: [final_execution.runtime_id] names the
                     deferred-lane assignment this cycle was budgeted under,
                     not necessarily the concrete candidate
                     [attempt_runtime_candidates] actually dispatched —
                     [Runtime_lane_preference] sticky ordering can route a
                     lane keyed by one runtime id to a different candidate
                     first (observed 2026-08-15T11:49Z: the lane-entry
                     runtime was consistently logged while a
                     sticky-reordered sibling candidate actually dispatched,
                     so this log named the untried lane key instead of the
                     runtime that actually errored).
                     [keeper_cycle_failed_runtime_attribution] reports the
                     dispatched candidate's own id when a same-turn
                     deferral hint is available. *)
                  let runtime_attribution =
                    keeper_cycle_failed_runtime_attribution
                      ~deferred_runtime_lane:turn_state.deferred_runtime_lane
                      ~execution_runtime_id:final_execution.runtime_id
                  in
                  log_keeper_cycle_failed
                    ~keeper_name:meta.name
                    ~category:Log.Turn
                    "%s: keeper cycle FAILED runtime=%s deferred_next_runtime=%s \
                     max_context=%d context_budget=%d \
                     primary_budget=%d requested_override=%s system_and_user_bytes=%d \
                     latency=%dms%s error=%s"
                    meta.name
                    runtime_attribution.reported_runtime_id
                    runtime_attribution.deferred_next_runtime_id
                    final_execution.max_context
                    final_execution.max_context_resolution.effective_budget
                    final_execution.max_context_resolution.primary_budget
                    (match
                       final_execution.max_context_resolution.requested_override
                     with
                     | Some requested -> string_of_int requested
                     | None -> "none")
                    (String.length system_prompt
                     + String.length world_state
                     + String.length user_message)
                    latency_ms
                    (if is_provider_wire_error
                    then " (provider wire error, counts toward crash threshold)"
                    else if is_server_parse_rejection
                      then " (server parse rejection, counts toward crash threshold)"
                     else if is_transient
                     then " (transient, cooldown preserved)"
                     else if EC.should_warn_keeper_cycle_failed err
                     then " (policy handled)"
                     else "")
                    (short_preview e_str);
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string Agent_coreExecutionErrors)
                    ~labels:[ "keeper", meta.name; "phase", Keeper_agent_core_execution_error_phase.(to_label Cycle_failed) ]
                    ();
                  let updated_meta =
                    Keeper_unified_metrics.update_metrics_from_failure
                      meta
                      ~latency_ms
                      ~observation
                      ~reason:e_str
                      ~core_error:err
                      ()
                  in
                  let e_str = Agent_core.Error.to_string err in
                  let terminal_reason =
                    Keeper_turn_terminal.of_failure
                      ~raw_error:e_str
                      err
                  in
                  Keeper_unified_metrics.append_decision_record
                    ~config
                    ~meta:updated_meta
                    ~turn_ctx_cell
                    ~observation
                    ~latency_ms
                    ~outcome:"error"
                    ~degraded_retry_applied
                    ?degraded_retry_runtime
                    ?fallback_reason:
                      (Option.map EC.degraded_retry_reason_to_string fallback_reason)
                    ~error:e_str
                    ~terminal_reason
                    ();
                  commit_turn_runtime_or_raise
                    ~config
                    ~before:meta
                    ~after:updated_meta
                  |> ignore;
                  (* Finish the Keeper Owner commit and its exact registry
                     projection before storing the live failure observation.
                     The two registry writes must not race on different entry
                     snapshots. *)
                  (match
                     registry_failure_reason_of_terminal_reason
                       ~core_error:err
                       terminal_reason
                       ~raw_error:e_str
                   with
                   | Some failure_reason ->
                     Keeper_registry.set_failure_reason
                       ~base_path:config.base_path
                       meta.name
                       (Some failure_reason)
                   | None -> ());
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string WriteMetaCycleFailures)
                    ~labels:[ "keeper", meta.name; "site", Keeper_write_meta_cycle_failure_site.(to_label Turn_failure) ]
                    ();
                  (* Route the failure (total over core_error), retain the exact
                     final execution identity, and record typed failure plus
                     telemetry here. Exhausted failures remain visible without
                     dispatching a second LLM call. *)
                  let failure_route =
                    Keeper_runtime_failure_route.route_of_error
                      ~boundary:(execution_boundary_of_turn_failure err)
                      err
                  in
                  (* Every failure follows the ordinary typed route, including
                     an incomplete tool transcript: a past structural defect is
                     evidence, not a scheduling gate. Boot-time
                     [Keeper_transcript_tail_recovery] closes the open cycles a
                     process death leaves behind. Capacity failures (context
                     overflow, request-body caps, serving-input rejection) also
                     route here. #26545 bounds conversation history;
                     whole-request provider fit is tracked separately in #26551. *)
                  let source_disposition = Follow_failure_route in
                  exact_failure_execution :=
                    Some
                      ( final_execution.runtime_id
                      , failure_route
                      , source_disposition );
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string FailureRoute)
                    ~labels:
                      [ "keeper", meta.name
                      ; (* RFC-0132-EXEMPT: internal observability — real runtime identity on a metric label, not a redacted public surface *)
                        "runtime", final_execution.runtime_id
                      ; "route", Keeper_runtime_failure_route.route_kind_label failure_route
                      ; "class", Keeper_runtime_failure_route.route_class_label failure_route
                      ]
                    ();
                  Keeper_unified_turn_failure.record_failure_observation
                    ~config
                    ~meta
                    ~err
                    ~error_text:e_str;
                  (* RFC-0221 §3.4: emit turn_completed telemetry on all exit paths
                     after Agent.run() — success path emits via
                     Keeper_unified_turn_success → keeper_unified_metrics_snapshot;
                     failure path emits here directly. *)
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string TurnCompleted)
                    ~labels:[("keeper", meta.name)]
                    ();
                  Error err, turn_state)
                | Ok result ->
                  (match
                     require_last_execution_for_finalize
                       ~keeper_name:meta.name
                       turn_state
                   with
                   | Error missing_err -> Error missing_err, turn_state
                   | Ok final_execution ->
                     finalize_trajectory_acc
                          ~config
                          ~keeper_name:meta.name
                          trajectory_acc
                          Trajectory.Completed;
                  (* SSOT: success-path terminal FSM transitions
                     (Streaming -> Completing -> Done) are emitted once inside
                     [Keeper_unified_turn_success.handle]. Do not duplicate them
                     here; this is the sole caller of that function. *)
                  let success =
                    let execution_outcome =
                      Keeper_execution_outcome.create
                        ~lane:(Keeper_execution_outcome.Autonomous channel)
                        result
                    in
                    Keeper_unified_turn_success.handle
                      ~config
                      ~meta
                      ~turn_ctx_cell
                      ~observation
                      ~latency_ms
                      ~degraded_retry_applied
                      ~degraded_retry_runtime
                      ~fallback_reason
                      ~keeper_turn_id
                      execution_outcome
                  in
                  (match success with
                   | Keeper_unified_turn_success.Completed updated_meta ->
                     (* TurnComplete post-action. *)
                     let turn_state =
                       { turn_state with cycle_completed = true }
                     in
                     post_turn_complete_task ~cycle_completed:turn_state.cycle_completed;
                     let continuation_route =
                       match
                         ( continuation_channel_of_wake wake
                         , result.Keeper_agent_run.terminal_effect_receipt )
                       with
                       | ( Some channel
                         , Some
                             (Keeper_tool_execution.Surface_post_completed
                                target) )
                         when Keeper_surface_post.matches_continuation_route
                                target
                                channel ->
                         Continuation_route_addressed
                       | ( Some _
                         , Some
                             (Keeper_tool_execution.Surface_post_completed _) ) ->
                         (* A terminal surface post landed on a different channel
                            than the one that woke this turn. Not a judgement to
                            ignore: leave it pending for investigation. *)
                         Continuation_route_mismatch
                       | ( Some _
                         , Some
                             (Keeper_tool_execution.Memory_write_completed _) ) ->
                         (* Exact receipt evidence only: a memory write
                            completed, while no direct surface post did.  Do
                            not invent a mental "observed and chose" state. *)
                         Continuation_memory_write_completed
                       | ( Some _
                         , Some
                             (Keeper_tool_execution.Memory_retract_completed _) ) ->
                         (* Exact receipt evidence only: a memory retraction
                            committed, while no direct surface post did. *)
                         Continuation_memory_retract_completed
                       | ( Some _, None ) ->
                         (* Absence of a receipt proves neither observation nor
                            intent. Keep only the absence we actually saw. *)
                         Continuation_no_terminal_effect_receipt
                       | ( None, _ ) ->
                         (* This turn has no continuation route against which a
                            terminal effect can be compared. *)
                         Continuation_route_not_applicable
                     in
                     Ok
                       (turn_success_of_stop_reason
                          ~meta:updated_meta
                          ~continuation_route
                          result.Keeper_agent_run.stop_reason),
                     turn_state))))
                     )
  in
  let append_phase_gate_decision_for_gate turn_plan turn_state =
    Keeper_unified_turn_manifest.append_phase_gate_decision
      ~config
      ~runtime_manifest_context
      ~turn_start
      ~turn_state
      turn_plan
  in
  let phase_gate_outcome, turn_state =
    Keeper_unified_turn_phase_gate.decide_and_record
      ~config
      ~meta
      ~keeper_turn_id
      ~append_phase_gate_decision:append_phase_gate_decision_for_gate
      ~turn_state
      ~registry_base_path
  in
  let failure_of_error ?deferred_runtime_lane error =
    turn_failure_of_error
      ~runtime_id:(Keeper_meta_contract.runtime_id_of_meta meta)
      ~fallback_boundary:Keeper_runtime_failure_route.Masc_execution
      ~exact_failure_execution:!exact_failure_execution
      ~deferred_runtime_lane
      error
  in
  match phase_gate_outcome with
  | Keeper_unified_turn_phase_gate.Phase_gate_cancelled meta ->
    Ok (Turn_cancelled meta)
  | Keeper_unified_turn_phase_gate.Phase_gate_skipped meta ->
    Ok (Turn_skipped meta)
  | Keeper_unified_turn_phase_gate.Phase_gate_terminal_error err ->
    Error (failure_of_error err)
  | Keeper_unified_turn_phase_gate.Phase_gate_proceed ->
    let result, turn_state = main_path turn_state in
    (match result with
     | Ok success -> Ok success
     | Error error ->
       Error
         (failure_of_error
            ?deferred_runtime_lane:turn_state.deferred_runtime_lane
            error))
;;
