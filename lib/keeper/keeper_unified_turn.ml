(** MASC orchestration of a Keeper turn.

    Observes current state, prepares the turn prompt and calls
    [Keeper_agent_run.run_turn] through [Keeper_unified_turn_execution].
    [Keeper_turn_driver] dispatches each runtime attempt to AGENT_CORE or an
    official client according to [Runtime_execution.t].

    Error classification predicates are in [Keeper_error_classify]. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_context_runtime
include Keeper_turn_helpers
include Keeper_turn_runtime_budget
include Keeper_unified_turn_types

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

(* A commit that fails leaves the Keeper's durable state behind the turn it
   just ran; the cycle stops here rather than run on from it. *)
let commit_turn_with_attempt_spend
      ~config
      ~keeper_turn_id
      ~before
      ~attempt_spend
      ~settled_start
      after
  =
  match
    Keeper_turn_spend_commit.commit
      ~config ~keeper_turn_id ~before ~attempt_spend ~settled_start after
  with
  | Ok committed -> committed
  | Error error ->
    raise (Owner_meta_commit_failed (Keeper_turn_spend_commit.error_to_string error))
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
      | Keeper_internal_error.Official_client_recovery_required _
      | Keeper_internal_error.Gate_replay_repair_required _
      | Keeper_internal_error.Receipt_persistence_failed _ ) ->
    (* These failures are produced by MASC, not by the provider turn:
       transcript validation, a durable session claim, host replay, or the
       execution-receipt write after the turn body succeeded. The shared
       carrier must not attribute these local boundaries to AGENT_CORE. *)
    Keeper_runtime_failure_route.Masc_execution
  | Some
      ( Keeper_internal_error.Runtime_exhausted _
      | Keeper_internal_error.Resumable_cli_session _
      | Keeper_internal_error.Accept_rejected _
      | Keeper_internal_error.Internal_unhandled_exception _
      | Keeper_internal_error.Internal_bridge_exception _
      | Keeper_internal_error.Internal_contract_rejected _
      | Keeper_internal_error.Terminal_effect_failed _
      | Keeper_internal_error.Provider_attempt_effect_fenced _
      | Keeper_internal_error.Tool_correction_lost _
      (* Both are reported by the runtime client, which is the agent-core
         side of this boundary. *)
      | Keeper_internal_error.Host_stopped_turn _
      | Keeper_internal_error.Runtime_connection_closed _ )
  | None ->
    Keeper_runtime_failure_route.Agent_core_execution
;;

type turn_success =
  | Turn_completed of { meta : keeper_meta }
  | Turn_checkpointed of
      { meta : keeper_meta
      ; followup : Keeper_agent_result.checkpoint_followup
      }
  | Turn_input_required of keeper_meta
  | Turn_cancelled of keeper_meta
  | Turn_skipped of keeper_meta
  | Turn_rested of
      { meta : keeper_meta
      ; rest : Keeper_turn_driver.provider_rest
      ; deferred_runtime_lane : Keeper_turn_driver.deferred_runtime_lane option
      }

let turn_success_of_stop_reason ~meta ~followup = function
  | Runtime_agent.Completed _ -> Turn_completed { meta }
  | Runtime_agent.Yielded_to_durable_stimulus _ ->
    Turn_checkpointed { meta; followup }
  | Runtime_agent.InputRequired _ -> Turn_input_required meta
;;

(* RFC-0377 admits a whole conversation backlog as one wake: intake batches
   one connector conversation's pending rows together with every other ready
   payload (at most one HITL resolution), so a batch is not connector rows
   only. The batch continues on one channel only when every member has a routable
   channel and all of them are the same conversation; one channel-less member
   ([Board_signal], [Bootstrap], ...) routes the batch nowhere. The chosen
   member is the last in the wake's order, which is intake's selection order
   over the queue's urgency-stable order rather than arrival order. The
   members agree on the conversation, so the choice decides only the
   per-message stamps a reply inherits: Discord's [reply_to_message_id],
   which no sender reads, and Slack's [thread_ts], which
   [Keeper_surface_post] threads under. *)
let continuation_channel_of_wake = function
  | Keeper_registry.Woken (_ :: _ as payloads) ->
    let routable payload =
      match Keeper_event_queue.continuation_channel_of_payload payload with
      | Some channel when Keeper_continuation_channel.is_routable channel ->
        Some channel
      | Some _ | None -> None
    in
    (match List.rev_map routable payloads with
     | Some newest :: older
       when List.for_all
              (function
                | Some channel ->
                  Keeper_continuation_channel.same_conversation channel newest
                | None -> false)
              older -> Some newest
     | Some _ :: _ | None :: _ | [] -> None)
  | Keeper_registry.Woken []
  | Keeper_registry.Proactive_tick
  | Keeper_registry.Chat_request -> None
;;


let run_keeper_cycle
      ~(before_dispatch_authority : unit -> (unit, string) result)
      ~(execution_path : Keeper_unified_metrics_decision.execution_path)
      ?deferred_runtime_lane
      ?on_deferred_runtime_consumed
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(publication_recovery_provider :
          Keeper_publication_recovery_availability.provider)
      ~(observation : Keeper_world_observation.world_observation)
      ~(turn_input : Keeper_heartbeat_source_batch.turn_input)
      ~(turn_decision : Keeper_world_observation.keeper_cycle_decision)
      ?shared_context
      ?event_bus
      ?hitl_resolution
      ()
  : (turn_success, turn_failure) result
  =
  let wake = Keeper_heartbeat_source_batch.wake turn_input in
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
  (* 0. Phase gate + state-aware runtime routing.
     The gate owns turn executability. *)
  let registry_base_path = config.base_path in
  let exact_failure_execution = ref None in
  (* Quota expiry is wall-clock provider evidence. Freeze this observation so
     shaping and dispatch share one resumed walk. NDT-OK. *)
  let quota_snapshot_now = Unix.gettimeofday () in
  let deferred_runtime_lane =
    Option.map
      (Keeper_turn_driver.resumed_runtime_lane
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
    { manifest_seq = 0
    ; last_execution = None
    ; degraded_retry_settled = None
    ; deferred_runtime_lane = None
    ; failure_reason = None
    ; runtime_attempt_errors = []
    ; lane_terminal_error = None
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
            ( "intake_sources",
              Keeper_heartbeat_source_batch.observed_sources_to_yojson
                (Keeper_heartbeat_source_batch.sources turn_input) );
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
        | Some hint -> Keeper_turn_driver.resumed_head hint
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
      (* Concrete runtime health/capacity is owned by AGENT_CORE/provider
         adapters; routing here does not consult it. *)
      (
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
             ~deferred_runtime_lane
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
            (* The same discarded classification as the Streaming path below:
               both arms were wildcards and the branch was decided by the
               [when] guard, which never looks at the scrutinee. Written as
               the two-way choice it is. Whether a masc-internal failure
               deserves a reason of its own is #33671. *)
            let failure_reason =
              if EC.is_runtime_exhausted_error err
              then
                Keeper_turn_fsm.Failure_runtime_unavailable
                  { base = effective_runtime_runtime_name; resolved = None }
              else
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
               let preparation_turn_ref = Ids.Turn_ref.make
                 ~trace_id:runtime_manifest_context.manifest_trace_id ~absolute_turn:keeper_turn_id in
               let preview = Keeper_turn_preview.reset ~base_path:config.base_path ~keeper_name:meta.name ~execution_scope:None
                 ~turn_ref:(Some preparation_turn_ref)
                 ~now:(Time_compat.now ())
                 ~redaction:(Keeper_secret_redaction.snapshot ~base_path:config.base_path
                   ~keeper_name:meta.name) in
               Keeper_preparation_runtime_observation.with_turn ~config
                 ~keeper_name:meta.name ~preview @@ fun () ->
               let current_task,skill_snapshot =
                 Keeper_turn_preview.with_preparation ~writer:(Some preview)
                   ~turn_ref:(Some preparation_turn_ref) ~phase:Keeper_turn_preview.Task_preparation (fun () ->
               let current_task =
                 Keeper_world_observation_inputs.read_current_task ~config ~meta
               in
               let skill_snapshot =
                 Keeper_agent_run.capture_skill_snapshot
                   ~base_path:config.base_path
               in
               current_task,skill_snapshot)
               in
               let task_skill_selection =
                 Keeper_skill_preparation_runtime_observation.with_turn_result
                   ~preview
                   ~config ~keeper_name:meta.name
                   ~turn_ref:preparation_turn_ref
                   ~phase:Keeper_skill_preparation_runtime_observation.Autonomous_task_resolution @@ fun () ->
                 Keeper_task_skill_turn.resolve_live_observations
                  ~config:config ~keeper_name:meta.name
                   ~snapshot:skill_snapshot
                   ~current_task
                   ~held_task_skills:observation.held_task_skills
               in
               let task_skill_surfaces =
                 match task_skill_selection with
                 | Error _ -> []
                 | Ok merged ->
                   Keeper_turn_preview.with_preparation ~writer:(Some preview)
                     ~turn_ref:(Some preparation_turn_ref) ~phase:Keeper_turn_preview.Skill_preparation (fun () ->
                   Keeper_task_skill_turn.exact_task_surfaces
                     ~snapshot:skill_snapshot
                     ~tool_deny:profile_defaults.tool_deny
                     ~sandbox_profile:meta.sandbox_profile
                     ~skill_names:profile_defaults.skill_names
                     ~selection:merged
                     ~current_task
                     ~held_task_skills:observation.held_task_skills)
               in
               let active_goal_summaries =
                 Keeper_unified_prompt.active_goal_summaries ~config ~keeper_name:meta.name
               in
               let {Keeper_turn_shared_inputs.lane_updates;workspace_memory;wiki_contents} =
                 Keeper_turn_shared_inputs.observe ~preview ~config ~keeper_name:meta.name () in
               let recent_work = Keeper_recent_work.collect ~config ~meta in
               let render_prompt,prompt_parts =
                 Keeper_turn_preview.with_preparation ~writer:(Some preview)
                   ~turn_ref:(Some preparation_turn_ref) ~phase:Keeper_turn_preview.Prompt_preparation (fun () ->
                 Eio_guard.with_named_switch "turn:prompt" (fun () ->
                 let prepared = Keeper_unified_prompt.prepare_prompt
                     ~turn_decision
                     ~current_task
                     ~task_skill_surfaces
                     ~active_goal_summaries
                     ~workspace_memory
                     ~wiki_contents
                     ~lane_updates
                     ~observation
                     () in
                 let render_prompt ?workspace_memory_access own_recent_actions tools =
                   let recent_work = Keeper_recent_work.transmit ~base_path:config.base_path ~tools recent_work in
                   Keeper_unified_prompt.project_prompt prepared ?workspace_memory_access
                     ~own_recent_actions ~recent_work () in
                 render_prompt,render_prompt observation.own_recent_actions []))
               in
               let { Keeper_unified_prompt.world_state; user_message; _ } = prompt_parts in
               let dynamic_context_for_tools = Some (fun access ->
                 let tools = Keeper_request_tool_access.offered access in
                 Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                   let own_recent_actions =
                     Result.map
                       (Keeper_own_recent_actions.externalize_failures
                          ~base_path:config.base_path ~keeper_name:meta.name ~tools)
                       observation.own_recent_actions in
                   (render_prompt ~workspace_memory_access:access own_recent_actions tools).world_partition)) in
               Eio.Fiber.yield ();
               let base_dir = session_base_dir config in
               (* Ensure session dir tree for trace artifacts. *)
               let (_ : string) =
                 Keeper_fs.ensure_dir
                   (Filename.concat
                      base_dir
                      (Keeper_id.Trace_id.to_string meta.runtime.trace_id))
               in
               let masc_root = Workspace.masc_dir config in
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
               (* 4. Build turn prompt callback. The system prompt is the base
                  prompt [Keeper_run_context] built -- the same one a direct
                  turn sends. Rendering a second one here read the
                  constitution ledger twice per turn, and the two reads could
                  disagree (#38354). *)
               (* Per cycle, not per candidate, and that is exact: the
                  callback runs once per [Keeper_agent_run.run_turn], after
                  [prepare_run_context] and before the candidate walk
                  ([Keeper_turn_driver.run_named]), and every candidate sends
                  this one prompt. [do_run] calls [run_turn] once per cycle.
                  A cycle whose prepare failed never calls it, so the failure
                  log says [not_sent]. *)
               let sent_system_prompt_bytes = ref None in
               let build_turn_prompt ~base_system_prompt ~messages:_
                 : Keeper_agent_run.turn_prompt
                 =
                 sent_system_prompt_bytes := Some (String.length base_system_prompt);
                 (* Request metrics are emitted by the pre-request hook after
                    the offered tool surface selects the transmitted context. *)
                 (* The observation frame rides [dynamic_context]: rebuilt fresh
                    every turn and composed into the per-turn system prompt, so
                    it never enters the persisted AGENT_CORE conversation. Persisting
                    it as a user message re-fed the model its own observations
                    (943/945 identical frames in one live checkpoint, #25193)
                    and exhausted the request window. Persisted user content is utterances
                    only (wake marker, answered Asks, and HITL resolutions). *)
                 { dynamic_context = world_state; dynamic_context_for_tools }
               in
               (* 5. Run via Agent_core.Agent.run() with transient-error retry.
                  The turn-local AGENT_CORE Event_bus preserves factual
                  ToolCalled/ToolCompleted pairing and drives
                  Streaming⇄Awaiting_tool_result FSM transitions. It does
                  not infer tool effects or veto retry. *)
               let turn_state =
                 { turn_state with last_execution = Some initial_execution }
               in
               let observation_token = Keeper_turn_observation_token.fresh () in
               let event_scope = Keeper_turn_scope.create ~keeper_turn_id in
               let turn_event_bus_state =
                 Keeper_unified_turn_event_bus.create
                   ?event_bus
                 (* Mirror the in-flight tool count into the
                    live turn_observation so the supervisor sweep excludes
                    active tool execution from the no-progress window. *)
                   ~on_pending_count_change:(fun count ->
                     Keeper_registry.record_turn_tool_inflight
                       ~observation_token
                       ~base_path:config.base_path
                       meta.name
                       ~count)
                   ~keeper_name:meta.name
                   ~scope:event_scope
                   ()
               in
               let event_bus = Keeper_unified_turn_event_bus.publishing_bus turn_event_bus_state in
               (* PR-J: [?site] labels the call-site so metric queries can attribute
         drain pressure to background polling vs unsubscribe vs the
         retry path. [outcome=drained] when at least one event was
         pulled, [outcome=empty] otherwise (the latter is the no-op
         tick that establishes the lock-acquire baseline). *)
               let drain_turn_event_bus ?(site = "unspecified") () =
                 Keeper_unified_turn_event_bus.drain ~site turn_event_bus_state
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
               Keeper_registry.mark_turn_started ~observation_token ~base_path:config.base_path ~wake meta.name;
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
                 ~observation_token:(Some observation_token)
                 ~base_path:config.base_path
                 meta.name;
               (match Keeper_registry.get ~base_path:config.base_path meta.name with
                | Some { current_turn_observation = Some { measurement = Some _; _ }; _ }
                  ->
                  Keeper_registry.set_turn_decision_stage
                    ~observation_token:(Some observation_token)
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
           arm here is why a skipped cleanup left no evidence at all.

           The two [Otel_metric_store.inc_counter] bumps below are the tail of
           each handler arm, outside [Eio.Cancel.protect]. Neither can raise
           today: the store swallows every failure of its own and re-raises
           only [Cancelled], which cannot originate under it (#37349). That
           matters because a raise out of [cleanup ()] skips the
           [Printexc.raise_with_backtrace] that carries the turn's own
           exception, and the turn would then report the cleanup's failure
           instead of its own. If the store ever gains a suspending call, wrap
           these two bumps the way [Keeper_vision_tool] wraps its cancelled
           observation. *)
                 let cleanup () =
                   (try Eio.Cancel.protect unsubscribe_event_bus with
                    | e -> (* cancel-guard-ok: the body is Eio.Cancel.protect, so the ambient cancellation cannot fire inside it; see the cleanup comment above for why a raise here must not escape. *)
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
                         ~observation_token
                         ~base_path:config.base_path
                         meta.name)
                   with
                   | e -> (* cancel-guard-ok: the body is Eio.Cancel.protect, so the ambient cancellation cannot fire inside it; see the cleanup comment above for why a raise here must not escape. *)
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
                       let run_result, turn_state =
                         Keeper_unified_turn_execution.run
                           ~event_scope
                           ~observation_token
                           { base_dir
                           ; build_turn_prompt
                           ; channel
                           ; continuation_channel = continuation_channel_of_wake wake
                           ; approval_admission = Keeper_approval_origin.Admitted
                               (Keeper_heartbeat_source_batch.selections
                                  (Keeper_heartbeat_source_batch.sources turn_input))
                           ; hitl_resolution
                           ; config
                           ; drain_turn_event_bus
                           ; event_bus
                           ; keeper_turn_id
                           ; meta
                           ; preview
                           ; turn_ctx_cell
                           ; observation
                           ; profile_defaults
                           ; publication_recovery
                           ; skill_snapshot
                           ; task_skill_selection
                           ; shared_context
                           ; trajectory_acc
                           ; deferred_runtime_lane
                           ; on_deferred_runtime_consumed
                           }
                           ~initial_execution
                           ~turn_state
                           ~before_dispatch_authority
                           ~user_message
                           ~record_streaming_cancelled_observation
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
               (* What the turn's receipt recorded, not a second answer to the
                  same question. Absent when the turn never reached
                  [Keeper_agent_run_receipt.finalize] -- a phase-gate or
                  pre-dispatch end -- and then no lane was run or left behind
                  either. *)
               let degraded_retry_applied, degraded_retry_deferred, attempt_spend, settled_start =
                 match turn_state.degraded_retry_settled with
                 | Some (settled : Keeper_agent_run.turn_settlement) ->
                   ( settled.degraded_retry_applied
                   , settled.degraded_retry_deferred
                   , settled.spend
                   , settled.settled_start )
                 | None -> None, None, [], None
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
                  (* The attempt wrote under [keeper_turn_id] and may have
                     run the provider before it asked, so the turn id is
                     spent and so is what its attempts read. *)
                  let committed =
                    commit_turn_with_attempt_spend
                      ~config
                      ~keeper_turn_id
                      ~before:meta
                      ~attempt_spend
                      ~settled_start
                      { meta with
                        updated_at = now_iso ()
                      ; runtime =
                          { meta.runtime with
                            usage =
                              { meta.runtime.usage with
                                total_turns = meta.runtime.usage.total_turns + 1
                              ; last_turn_ts = Time_compat.now ()
                              }
                          }
                      }
                  in
                  Ok (Turn_input_required committed), turn_state
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
                  (* Route the failure (total over core_error). A provider's
                     dated quota refusal whose next dispatch waits is a rest,
                     not a turn failure: the turn-level records below keep
                     the refusal, and the Keeper's failure accounting is left
                     as it was. *)
                  let failure_route =
                    Keeper_runtime_failure_route.route_of_error
                      ~boundary:(execution_boundary_of_turn_failure err)
                      err
                  in
                  let provider_rest =
                    Keeper_turn_driver.provider_rest_of_failure
                      ~now:(Time_compat.now ())
                      ~route:failure_route
                      ~assignment_id:(Keeper_meta_contract.runtime_id_of_meta meta)
                      turn_state.deferred_runtime_lane
                  in
                  let is_transient = EC.is_transient_network_error err in
                  (match err with
                      | Agent_core.Error.Api (Timeout _) ->
                        Otel_metric_store.inc_counter
                          Keeper_metrics.(to_string Agent_coreTimeoutClassifications)
                          ~labels:[ "classification", "transient_network" ]
                          ()
                      | Agent_core.Error.Api (Llm_provider.Retry.RateLimited _ | (Llm_provider.Retry.Overloaded _ | (Llm_provider.Retry.ServerError _ | (Llm_provider.Retry.AuthError _ | (Llm_provider.Retry.AuthorizationError _ | (Llm_provider.Retry.PaymentRequired _ | (Llm_provider.Retry.InvalidRequest _ | (Llm_provider.Retry.NotFound _ | (Llm_provider.Retry.ContextOverflow _ | (Llm_provider.Retry.InputCapacity _ | Llm_provider.Retry.NetworkError _))))))))))
                      | Agent_core.Error.Provider _ | Agent_core.Error.Agent _
                      | Agent_core.Error.Mcp _ | Agent_core.Error.Config _
                      | Agent_core.Error.Serialization _ | Agent_core.Error.Io _
                      | Agent_core.Error.Orchestration _ | Agent_core.Error.Media _ | Agent_core.Error.Internal _
                      | Agent_core.Error.Internal_carried _ -> ());
                  let is_server_parse_rejection = EC.is_server_rejected_parse_error err in
                  let is_provider_wire_error = EC.is_provider_wire_error err in
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string Turns)
                    ~labels:
                      [ "keeper", meta.name
                      ; ( "outcome"
                        , match provider_rest with
                          | Some _ -> "rested"
                          | None -> "failure" )
                      ]
                    ();
                  (if EC.is_provider_timeout_error err
                   then
                     (* The FSM's from-state is the event bus's pending-tool
                        count (the authoritative value, per drain): [>0] means
                        the turn was in [Awaiting_tool_result] when the
                        provider operation timed out. Hardcoding [Streaming]
                        here recorded a false from-state for exactly the hang
                        this escape exists for (#29230) — the classifier then
                        had no arm for it and the audit trail lost the
                        action. The branches are separate because the state
                        is a GADT; both emit the same terminal Cancelled. *)
                     if
                       Keeper_unified_turn_event_bus.pending_tool_count
                         turn_event_bus_state
                       > 0
                     then
                       Keeper_turn_fsm.emit_transition
                         ~keeper_name:meta.name
                         ~turn_id:keeper_turn_id
                         ~prev:Keeper_turn_fsm.Awaiting_tool_result
                         (Keeper_turn_fsm.Cancelled
                            Keeper_turn_fsm.Cancelled_provider_timeout)
                     else
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
                         (* Every remaining failure out of Streaming is reported as
                            a provider error, including the ones that are ours.
                            The two are not told apart here, and nothing upstream
                            stops them from being: {!Turn_fsm} admits every failure reason out of
                            an active state through
                            [_, Any (Failed _) when is_active from_state], which
                            names the event [GenericFail]. A masc-internal failure
                            given [Failure_runtime_error] here would be allowed and
                            would report GenericFail where it now reports
                            ProviderError. That is the open question, and it is
                            about which event operators should count, not about
                            what the machine permits — #33671.

                            Until it is answered an internal failure rides the
                            provider edge and says what it really is in [kind] —
                            "internal" rather than "provider". 54 turns took that
                            path on 2026-09-06 (grep [masc_agent_core_error] in the
                            system log). *)
                         Keeper_turn_fsm.Failure_provider_error
                           { kind = Agent_core.Error.(category err |> category_label)
                           ; detail = short_preview e_str
                           }
                     in
                     (* Same reasoning as the timeout branch above: the
                        from-state must reflect the pending-tool count, not
                        an assumed [Streaming]. *)
                     if
                       Keeper_unified_turn_event_bus.pending_tool_count
                         turn_event_bus_state
                       > 0
                     then
                       Keeper_turn_fsm.emit_transition
                         ~keeper_name:meta.name
                         ~turn_id:keeper_turn_id
                         ~prev:Keeper_turn_fsm.Awaiting_tool_result
                         (Keeper_turn_fsm.Failed fsm_failure_reason)
                     else
                       Keeper_turn_fsm.emit_transition
                         ~keeper_name:meta.name
                         ~turn_id:keeper_turn_id
                         ~prev:Keeper_turn_fsm.Streaming
                         (Keeper_turn_fsm.Failed fsm_failure_reason));
                  let log_keeper_cycle_end, cycle_end =
                    match provider_rest with
                    | Some rest ->
                      ( Log.Keeper.info
                      , Printf.sprintf
                          "rested until=%.0f waiting_on=%s"
                          rest.Keeper_turn_driver.release_at
                          rest.Keeper_turn_driver.waiting_on )
                    | None ->
                      ( (if EC.should_warn_keeper_cycle_failed err
                         then Log.Keeper.warn
                         else Log.Keeper.error)
                      , "FAILED" )
                  in
                  (* [final_execution.runtime_id] names the assignment this
                     cycle was budgeted under, except on a cycle that took a
                     deferred suffix: that execution is keyed by the
                     suffix's first runtime, so [lane=] takes the deferring
                     assignment from [deferred_runtime_lane] instead. Neither
                     is necessarily the concrete candidate
                     [attempt_runtime_candidates] dispatched: a lane keyed by
                     one runtime id walks a different candidate first when
                     the head rests or a deferred suffix starts elsewhere.
                     [keeper_cycle_failed_runtime_attribution] takes
                     [runtime=] from the last dispatched entry of
                     [turn_state.runtime_attempt_errors] (never from a
                     pre-dispatch refusal and never from the execution
                     record), reports the lane key as its own [lane=] field,
                     and names the candidate whose error [error=] carries as
                     [error_origin=], which can be an earlier candidate than
                     [runtime=]. [cycle_latency=] measures the whole
                     execution, every candidate included, not the reported
                     candidate alone. *)
                  let runtime_attribution =
                    keeper_cycle_failed_runtime_attribution
                      ~entry_deferred_runtime_lane:deferred_runtime_lane
                      ~deferred_runtime_lane:turn_state.deferred_runtime_lane
                      ~lane_runtime_id:final_execution.runtime_id
                      ~runtime_attempt_errors:turn_state.runtime_attempt_errors
                      ~lane_terminal_error:turn_state.lane_terminal_error
                  in
                  log_keeper_cycle_end
                    ~keeper_name:meta.name
                    ~category:Log.Turn
                    "%s: keeper cycle %s runtime=%s lane=%s error_origin=%s \
                     attempts=%s deferred_next_runtime=%s \
                     max_context=%d context_budget=%d \
                     primary_budget=%d requested_override=%s system_and_user_bytes=%s \
                     cycle_latency=%dms%s error=%s"
                    meta.name
                    cycle_end
                    (keeper_cycle_failed_runtime_to_string
                       runtime_attribution.reported_runtime)
                    runtime_attribution.lane_runtime_id
                    (keeper_cycle_failed_terminal_origin_to_string
                       runtime_attribution.terminal_error_origin)
                    (runtime_attempt_errors_to_string runtime_attribution.attempts)
                    runtime_attribution.deferred_next_runtime_id
                    final_execution.max_context
                    final_execution.max_context_resolution.effective_budget
                    final_execution.max_context_resolution.primary_budget
                    (match
                       final_execution.max_context_resolution.requested_override
                     with
                     | Some requested -> string_of_int requested
                     | None -> "none")
                    (* A turn refused before its prompt was built sent no
                       system prompt; a count would claim one. [world_state]
                       and [user_message] are the parts rendered here, before
                       a request re-renders the world for its offered tools
                       and [run_turn] appends the completion line, so the sum
                       is an estimate. *)
                    (match !sent_system_prompt_bytes with
                     | Some system_bytes ->
                       string_of_int
                         (system_bytes
                          + String.length world_state
                          + String.length user_message)
                     | None -> "not_sent")
                    latency_ms
                    (if Option.is_some provider_rest
                     then " (provider-stated quota, the refused attempt had no \
                           tool effect; not counted as a turn failure)"
                     else if is_provider_wire_error
                    then " (provider wire error, counts toward crash threshold)"
                    else if is_server_parse_rejection
                      then " (server parse rejection, counts toward crash threshold)"
                     else if is_transient
                     then " (transient, cooldown preserved)"
                     else if EC.should_warn_keeper_cycle_failed err
                     then " (policy handled)"
                     else "")
                    (short_preview e_str);
                  (match provider_rest with
                   | Some _ -> ()
                   | None ->
                     Otel_metric_store.inc_counter
                       Keeper_metrics.(to_string Agent_coreExecutionErrors)
                       ~labels:[ "keeper", meta.name; "phase", Keeper_agent_core_execution_error_phase.(to_label Cycle_failed) ]
                       ());
                  let updated_meta =
                    Keeper_unified_metrics.update_metrics_from_failure
                      meta
                      ~latency_ms
                      ~observation
                      ~reason:e_str
                      ~ended:
                        (match provider_rest with
                         | Some _ -> Keeper_unified_metrics.Rested_cycle
                         | None -> Keeper_unified_metrics.Failed_cycle)
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
                    ~outcome:Keeper_decision_outcome.Failed
                    ~execution_path
                    ~degraded_retry_applied
                    ~degraded_retry_deferred
                    ~error:e_str
                    ~terminal_reason
                    (* The runtime walk's own name for the last candidate it
                       dispatched: the same attempt list
                       [runtime_attribution] above reports on the log line.
                       The record takes the walk's report or nothing. *)
                    ?executed_runtime_id:
                      (match runtime_attribution.reported_runtime with
                       | Dispatched_candidate runtime_id -> Some runtime_id
                       | No_candidate_dispatched -> None)
                    ();
                  let committed =
                    commit_turn_with_attempt_spend
                      ~config
                      ~keeper_turn_id
                      ~before:meta
                      ~attempt_spend
                      ~settled_start
                      updated_meta
                  in
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
                  let turn_result =
                    match provider_rest with
                    | Some rest ->
                      (* The streak, the registry failure cause and Health
                         stay as they were: a rest is not a failure, and not a
                         success either. *)
                      Ok
                        (Turn_rested
                           { meta = committed
                           ; rest
                           ; deferred_runtime_lane = turn_state.deferred_runtime_lane
                           })
                    | None ->
                      Otel_metric_store.inc_counter
                        Keeper_metrics.(to_string WriteMetaCycleFailures)
                        ~labels:[ "keeper", meta.name; "site", Keeper_write_meta_cycle_failure_site.(to_label Turn_failure) ]
                        ();
                      (* Every failure follows the ordinary typed route, including
                         an incomplete tool transcript: a past structural defect is
                         evidence, not a scheduling gate. Boot-time
                         [Keeper_transcript_tail_recovery] closes the open cycles a
                         process death leaves behind. Capacity failures (context
                         overflow, request-body caps, serving-input rejection) also
                         route here. #26545 bounds conversation history;
                         whole-request provider fit is tracked separately in #26551.
                         Exhausted failures remain visible without dispatching a
                         second LLM call. *)
                      let source_disposition = Follow_failure_route in
                      exact_failure_execution :=
                        Some
                          ( final_execution.runtime_id
                          , failure_route
                          , source_disposition );
                      (* The Owner commit above must finish before this live
                         observation replaces the registry's failure cause. *)
                      Keeper_unified_turn_failure.record_failure_observation
                        ~config
                        ~meta
                        ~terminal_reason
                        ~err
                        ~error_text:e_str
                        ~terminal_error_origin:runtime_attribution.terminal_error_origin;
                      Error err
                  in
                  (* RFC-0221 §3.4: emit turn_completed telemetry on all exit paths
                     after Agent.run() — success path emits via
                     Keeper_unified_turn_success → keeper_unified_metrics_snapshot;
                     failure path emits here directly. *)
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string TurnCompleted)
                    ~labels:[("keeper", meta.name)]
                    ();
                  turn_result, turn_state)
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
                      ~degraded_retry_deferred
                      ~keeper_turn_id
                      ~spend:attempt_spend
                      ~settled_start
                      execution_outcome
                  in
                  (match success with
                   | Keeper_unified_turn_success.Completed updated_meta ->
                     Ok
                       (turn_success_of_stop_reason
                          ~meta:updated_meta
                          ~followup:result.Keeper_agent_run.checkpoint_followup
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
