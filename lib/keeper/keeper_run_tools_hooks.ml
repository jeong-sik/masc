(* keeper_run_tools_hooks — hooks assembly for prepare_agent_setup.
   Extracted from keeper_run_tools.ml. *)

open Keeper_types
open Keeper_agent_tool_surface
open Keeper_agent_result
open Keeper_agent_error
open Keeper_agent_prompt_metrics

type hook_accumulator = Keeper_run_tools_hook_accumulator.hook_accumulator

type agent_setup =
  { tools : Agent_sdk.Tool.t list
  ; cleanup : unit -> unit
  ; hooks : Agent_sdk.Hooks.hooks
  ; reducer : Agent_sdk.Context_reducer.t
  ; memory : Agent_sdk.Memory.t
  ; acc : hook_accumulator
  ; initial_tool_surface : computed_tool_surface
  ; initial_tool_surface_blocker : Agent_sdk.Error.sdk_error option ref
  ; all_tool_names : string list
  ; tool_usage_before : (string * int) list
  ; receipt_turn_count_ref : int option ref
  ; receipt_model_used_ref : string option ref
  ; receipt_stop_reason_ref : Cascade_runner.stop_reason option ref
  ; receipt_cascade_observation_ref : Cascade_observation.cascade_observation option ref
  ; receipt_response_text_present_ref : bool ref
  ; reported_tool_names_ref : string list ref
  ; observed_tool_names_ref : string list ref
  ; canonical_tool_names_ref : string list ref
  ; unexpected_tool_names_ref : string list ref
  ; actual_keeper_tool_names_ref : string list ref
  }

type ctx =
  { acc : hook_accumulator
  ; agent_name : string
  ; all_tool_names : string list
  ; compute_tool_surface :
      turn:int -> messages:Agent_sdk.Types.message list ->
      current_tool_choice:Agent_sdk.Types.tool_choice option ->
      decay_discovered:bool -> ?actionable_signal:bool -> unit ->
      computed_tool_surface
  ; config : Coord.config
  ; keeper_tool_bundle : Keeper_tools_oas.tool_bundle
  ; keeper_has_owned_active_task : unit -> bool
  ; manifest_keeper_turn_id : int option
  ; max_tools_per_turn : int
  ; meta : Keeper_types.keeper_meta
  ; reported_tool_names_ref : string list ref
  ; observed_tool_names_ref : string list ref
  ; canonical_tool_names_ref : string list ref
  ; unexpected_tool_names_ref : string list ref
  ; actual_keeper_tool_names_ref : string list ref
  ; receipt_turn_count_ref : int option ref
  ; receipt_model_used_ref : string option ref
  ; receipt_stop_reason_ref : Cascade_runner.stop_reason option ref
  ; receipt_cascade_observation_ref : Cascade_observation.cascade_observation option ref
  ; receipt_response_text_present_ref : bool ref
  ; tool_usage_before : (string * int) list
  ; tools : Agent_sdk.Tool.t list
  }

let assemble_hooks
      ~(ctx : ctx)
      ~(session : Keeper_types.session_context)
      ~(user_message : string)
      ~(dynamic_context : string)
      ~(history_messages : Agent_sdk.Types.message list)
      ~(prompt_metrics : Keeper_agent_prompt_metrics.prompt_metrics)
      ~(shared_context : Agent_sdk.Context.t)
      ~(start_turn_count : int)
      ~(generation : int)
      ~(max_turns : int)
      ~(cascade_name_string : string)
      ~(is_retry : bool)
      ~(turn_affordances : string list)
      ~(required_tool_names : string list)
      ~(config_root : string)
      ~(cascade_config_path : string option)
      ~(gemini_mcp_disabled : bool)
      ~(approval_mode_effective : string option)
      ~(approval_mode_derived : bool)
      ?(actionable_signal = false)
      ?max_cost_usd
      ~(trajectory_acc : Trajectory.accumulator option)
      ?runtime_manifest_context
      ?runtime_manifest_append
      ()
  : (agent_setup, Agent_sdk.Error.sdk_error) result
  =
  let acc = ctx.acc in
  let agent_name = ctx.agent_name in
  let compute_tool_surface = ctx.compute_tool_surface in
  let config = ctx.config in
  let keeper_tool_bundle = ctx.keeper_tool_bundle in
  let keeper_has_owned_active_task = ctx.keeper_has_owned_active_task in
  let manifest_keeper_turn_id = ctx.manifest_keeper_turn_id in
  let max_tools_per_turn = ctx.max_tools_per_turn in
  let meta = ctx.meta in
  let reported_tool_names_ref = ctx.reported_tool_names_ref in
  let observed_tool_names_ref = ctx.observed_tool_names_ref in
  let canonical_tool_names_ref = ctx.canonical_tool_names_ref in
  let unexpected_tool_names_ref = ctx.unexpected_tool_names_ref in
  let actual_keeper_tool_names_ref = ctx.actual_keeper_tool_names_ref in
  let receipt_turn_count_ref = ctx.receipt_turn_count_ref in
  let receipt_model_used_ref = ctx.receipt_model_used_ref in
  let receipt_stop_reason_ref = ctx.receipt_stop_reason_ref in
  let receipt_cascade_observation_ref = ctx.receipt_cascade_observation_ref in
  let receipt_response_text_present_ref = ctx.receipt_response_text_present_ref in
  let tool_usage_before = ctx.tool_usage_before in
  let tools = ctx.tools in
  let all_tool_names = ctx.all_tool_names in
  let initial_tool_surface =
    compute_tool_surface
      ~turn:(start_turn_count + 1)
      ~messages:history_messages
      ~current_tool_choice:None
      ~decay_discovered:false
      ~actionable_signal
      ()
  in
  acc.tool_surface
  <- { turn_lane = initial_tool_surface.lane
     ; tool_surface_class = initial_tool_surface.tool_surface_class
     ; tool_requirement = initial_tool_surface.tool_requirement
     ; visible_tool_count = List.length initial_tool_surface.all_allowed
     ; tool_gate_enabled = initial_tool_surface.tool_gate_requested
     ; tool_surface_fallback_used = initial_tool_surface.tool_surface_fallback_used
     ; required_tool_names = initial_tool_surface.required_tool_names
     ; required_tool_candidate_names =
         initial_tool_surface.required_tool_candidate_names
     ; missing_required_tool_names = initial_tool_surface.missing_required_tool_names
     ; config_root
     ; cascade_config_path
     ; gemini_mcp_disabled
     ; approval_mode_effective
     ; approval_mode_derived
     };
  let initial_tool_surface_blocker = ref None in
  let initial_tool_surface_result =
    if initial_tool_surface.missing_required_tool_names <> []
    then (
      acc.receipt_tool_contract_result <-
        Keeper_execution_receipt.Contract_tool_surface_mismatch;
      initial_tool_surface_blocker
      := Some
           (sdk_error_of_keeper_internal_error
              (Keeper_tool_surface_mismatch
                 { keeper_name = meta.name
                 ; required_tools = initial_tool_surface.required_tool_names
                 ; missing_required_tools =
                     initial_tool_surface.missing_required_tool_names
                 ; visible_tools = initial_tool_surface.all_allowed
                 }));
      Ok initial_tool_surface)
    else if
      initial_tool_surface.tool_gate_requested && initial_tool_surface.all_allowed = []
    then (
      acc.receipt_tool_contract_result <-
        Keeper_execution_receipt.Contract_no_tool_capable_provider;
      Prometheus.inc_counter
        Prometheus.metric_empty_tool_universe_observed
        ~labels:
          [ "keeper_name", meta.name
          ; ( "turn_lane"
            , Keeper_agent_tool_surface.turn_lane_to_string
                initial_tool_surface.lane )
          ; ( "fallback_used"
            , string_of_bool initial_tool_surface.tool_surface_fallback_used )
          ]
        ();
      initial_tool_surface_blocker
      := Some
           (sdk_error_of_keeper_internal_error
              (Keeper_tool_surface_empty
                 { keeper_name = meta.name
                 ; turn_lane =
                     Keeper_agent_tool_surface.turn_lane_to_string
                       initial_tool_surface.lane
                 ; affordances = turn_affordances
                 ; fallback_used = initial_tool_surface.tool_surface_fallback_used
                 }));
      Ok initial_tool_surface)
    else Ok initial_tool_surface
  in
  match initial_tool_surface_result with
  | Error err -> Error err
  | Ok initial_tool_surface ->
    Keeper_run_tools_hook_accumulator.record_requested_tool_names acc initial_tool_surface.all_allowed;
    let meta_ref = ref acc.meta in
    let public_alias_pre_tool_use_guard ~tool_name ~input:_ =
      Keeper_tool_resolution.public_alias_guidance_for_internal_call
        ~visible_tool_names:acc.requested_tool_names
        tool_name
    in
    let base_hooks =
      Keeper_hooks_oas.make_hooks
        ~config
        ~meta_ref
        ~generation
        ?max_cost_usd
        ?trajectory_acc
        ~on_tool_executed:
          (fun
            ~tool_name ~input ~output_text ~success ~duration_ms ~provider ~typed_outcome ->
          let route_evidence =
            Keeper_tool_call_log.route_evidence_json_of_tool_io
              ~success:(Some success)
              ~tool_name
              ~input
              ~output_text
          in
          let outcome =
            if not success
            then "error"
            else if
              Keeper_tool_observation.tool_result_has_material_progress
                ~tool_name
                ~output_text
            then "ok"
            else "ok_no_progress"
          in
          (match Keeper_registry.get ~base_path:config.base_path meta.name with
           | Some entry ->
             acc.meta <- entry.meta;
             meta_ref := entry.meta
           | None -> ());
          let task_id = Keeper_run_tools_task_scope.task_id_scope_of_tool_call ~tool_name ~input ~output_text ~meta:acc.meta in
          acc.tool_calls
          <- { tool_name
             ; provider
             ; outcome
             ; typed_outcome
             ; latency_ms = duration_ms
             ; task_id
             ; route_evidence
             }
             :: acc.tool_calls)
        ~passive_loop_nudge:(fun () ->
          Keeper_passive_loop_detector.nudge_message ~keeper_name:acc.meta.name)
        ~pre_tool_use_guard:public_alias_pre_tool_use_guard
        ()
    in
    let before_turn_hook : Agent_sdk.Hooks.hooks =
      { Agent_sdk.Hooks.empty with
        before_turn_params =
          Some
            (fun event ->
              match event with
              | Agent_sdk.Hooks.BeforeTurnParams
                  { turn; current_params; messages; last_tool_results; _ } ->
                let hook_t0 = Time_compat.now () in
                acc.current_turn <- turn;
                (* RFC-0045: signal an SDK-turn boundary so the in-turn FSM
                  fields ([turn_phase], [cascade_state], [decision_stage])
                  are reset before the hook writes [Cascade_selecting] /
                  [Decision_tool_policy_selected] / [Turn_prompting] below.
                  The MASC keeper-turn boundary ([mark_turn_started]) only
                  fires once per [Agent_sdk.run_loop] call; every additional
                  SDK turn inside that loop must use this entry point or
                  [validate_turn_phase_transition] rejects the transition
                  from the previous SDK turn's [Turn_finalizing] terminal. *)
                Keeper_registry.mark_sdk_turn_started
                  ~base_path:config.base_path
                  meta.name;
                let intent =
                  if Keeper_config.keeper_adaptive_thinking_mode ()
                  then (
                    let last_tool_calls =
                      let rev = List.rev messages in
                      let rec scan = function
                        | [] -> []
                        | (msg : Agent_sdk.Types.message) :: rest ->
                          let names =
                            List.filter_map
                              (function
                                | Agent_sdk.Types.ToolUse { name; _ } -> Some name
                                | _ -> None)
                              msg.content
                          in
                          if names <> [] then names else scan rest
                      in
                      scan rev
                    in
                    let retry_count = if is_retry then 1 else 0 in
                    Some
                      (Keeper_turn_intent.classify
                         ~last_tool_calls
                         ~last_user_message:(Some user_message)
                         ~retry_count))
                  else None
                in
                let cascade_seed =
                  Cascade_inference.for_cascade ~name:cascade_name_string
                in
                let current_budget =
                  match cascade_seed.thinking_budget with
                  | Some _ as v -> v
                  | None -> current_params.thinking_budget
                in
                let adaptive_thinking_budget =
                  adaptive_thinking_budget
                    ~enabled:(Keeper_config.keeper_adaptive_thinking_enabled ())
                    ~is_retry
                    ~last_tool_results
                    ~user_message
                    ~dynamic_context
                    ~current_budget
                    ~intent
                in
                let adaptive_thinking_override =
                  match intent with
                  | Some i ->
                    Some (Keeper_turn_intent.equal i Keeper_turn_intent.Cognitive)
                  | None -> None
                in
                let current_params =
                  { current_params with
                    thinking_budget = adaptive_thinking_budget
                  ; enable_thinking =
                      (match cascade_seed.thinking_enabled with
                       | Some false -> Some false
                       | _ ->
                         (match adaptive_thinking_override with
                          | Some _ as v -> v
                          | None -> current_params.enable_thinking))
                  }
                in
                let ctx =
                  if String.trim dynamic_context = ""
                  then current_params.extra_system_context
                  else (
                    match current_params.extra_system_context with
                    | None -> Some dynamic_context
                    | Some existing -> Some (existing ^ "\n\n" ^ dynamic_context))
                in
                let ctx =
                  match Masc_context_injector.render_temporal_summary shared_context with
                  | None -> ctx
                  | Some temporal ->
                    (match ctx with
                     | None -> Some temporal
                     | Some existing -> Some (existing ^ "\n\n" ^ temporal))
                in
                let ctx =
                  match acc.meta.current_task_id with
                  | Some task_id ->
                    let last_tool_names =
                      let rev = List.rev messages in
                      let rec scan = function
                        | [] -> []
                        | (msg : Agent_sdk.Types.message) :: rest ->
                          let names =
                            List.filter_map
                              (function
                                | Agent_sdk.Types.ToolUse { name; _ } -> Some name
                                | _ -> None)
                              msg.content
                          in
                          if names <> [] then names else scan rest
                      in
                      scan rev
                    in
                    let is_claim_only_turn =
                      List.exists is_claim_tool_name last_tool_names
                      && List.for_all is_claim_context_tool_name last_tool_names
                    in
                    if is_claim_only_turn
                    then (
                      let nudge =
                        Printf.sprintf
                          "[CLAIMED TASK] You hold %s. Do NOT call claim_next again. Use \
                           an execution tool visible in your active runtime schema to \
                           start working on it now. If no execution tool is visible, \
                           emit [STATE] with the blocker instead of inventing a tool \
                           name."
                          (Keeper_id.Task_id.to_string task_id)
                      in
                      match ctx with
                      | None -> Some nudge
                      | Some existing -> Some (existing ^ "\n\n" ^ nudge))
                    else ctx
                  | None -> ctx
                in
                let computed_surface =
                  compute_tool_surface
                    ~turn
                    ~messages
                    ~current_tool_choice:current_params.tool_choice
                    ~decay_discovered:true
                    ~actionable_signal
                    ()
                in
                if Keeper_types_profile.keeper_debug
                then
                  Log.Keeper.info
                    "tool_disclosure keeper=%s core=%d deterministic_prefilter=%d \
                     discovered=%d llm_selected=%d llm_rerank=%b allowed=%d query_len=%d \
                     mode=%s"
                    meta.name
                    computed_surface.core_count
                    computed_surface.deterministic_prefilter_count
                    computed_surface.discovered_count
                    computed_surface.llm_selected_count
                    (Keeper_config.keeper_llm_rerank_enabled ())
                    (List.length computed_surface.all_allowed)
                    (String.length computed_surface.query_text)
                    (Keeper_agent_tool_surface.tool_selection_mode_to_string
                       computed_surface.selection_mode);
                let append_ctx ctx text =
                  Some
                    (match ctx with
                     | None -> text
                     | Some e -> e ^ "\n\n" ^ text)
                in
                let ctx =
                  if
                    computed_surface.is_last_turn
                    && computed_surface.required_tool_names <> []
                  then
                    append_ctx
                      ctx
                      (Printf.sprintf
                         "[REQUIRED TOOLS - FINAL TURN] This Agent.run call is on its \
                          final turn, but this message has explicit required_tools: %s. \
                          You MUST either use every required tool now or return a \
                          concise blocker naming the missing policy/tool/runtime \
                          condition."
                         (String.concat ", " computed_surface.required_tool_names))
                  else if computed_surface.is_last_turn
                  then
                    append_ctx
                      ctx
                      (Printf.sprintf
                         "[LAST TURN] Per-call turn %d/%d. This is your final turn in \
                          this Agent.run call. You MUST emit a [STATE]...[/STATE] block \
                          now summarizing what you accomplished and what the next \
                          generation should do. Do NOT start new tool work. Three escape \
                          hatches, in priority order: (1) call extend_turns if the task \
                          is almost finished and more turns will close it out; (2) call \
                          keeper_board_post to hand off the current task and ask another \
                          keeper or operator for judgment when the work needs a decision \
                          you cannot make alone; (3) if you claimed a task, close it NOW \
                          before session ends with keeper_task_done or \
                          keeper_task_submit_for_verification."
                         computed_surface.per_call_turn
                         computed_surface.per_call_max_turns)
                  else if computed_surface.required_tool_names <> []
                  then
                    append_ctx
                      ctx
                      (Printf.sprintf
                         "[REQUIRED TOOLS] This Agent.run call has explicit \
                          required_tools: %s. You MUST use these exact runtime tools \
                          before answering in natural language. Do not substitute a \
                          shell command or status read for a listed required tool."
                         (String.concat ", " computed_surface.required_tool_names))
                  else if computed_surface.tool_gate_requested
                  then
                    append_ctx
                      ctx
                      (generic_required_tool_gate_guidance
                         ~has_current_task:(keeper_has_owned_active_task ())
                         ~turn_affordances
                         ~allowed_tool_names:computed_surface.all_allowed)
                  else if is_retry
                  then
                    append_ctx
                      ctx
                      (Printf.sprintf
                         "[RETRY] The previous attempt overflowed the model context. \
                          Stay concise, prefer already-loaded context, and only use the \
                          smallest essential tool set if a tool call is strictly \
                          necessary. Current tool budget: %d."
                         max_tools_per_turn)
                  else if computed_surface.is_warning_zone
                  then
                    append_ctx
                      ctx
                      (Printf.sprintf
                         "[BUDGET] %d/%d turns used in this Agent.run call. Wrap up \
                          current work and emit a [STATE] block. If more turns will \
                          genuinely finish the task, call extend_turns. If you are \
                          blocked on a decision or external input, post a question to \
                          the board via keeper_board_post rather than burning turns \
                          retrying — that is the intended judgment-escalation path."
                         computed_surface.per_call_turn
                         computed_surface.per_call_max_turns)
                  else ctx
                in
                (* Contract violation retry feedback: when a previous
                   Agent.run attempt was rejected for not calling
                   required tools, inject explicit guidance naming the
                   satisfying tools so the model knows what to do. *)
                let ctx =
                  if acc.contract_violation_retries > 0
                  then
                    let satisfying_tools =
                      Keeper_agent_tool_surface
                      .generic_required_tool_candidate_names
                        ~has_current_task:(keeper_has_owned_active_task ())
                        ~turn_affordances
                        ~allowed_tool_names:computed_surface.all_allowed
                    in
                    let preview =
                      satisfying_tools
                      |> List.filteri (fun i _ -> i < 8)
                      |> String.concat ", "
                    in
                    let retry_action =
                      if preview = ""
                      then
                        "No currently visible tool can satisfy this contract; \
                         emit a concise blocker instead."
                      else
                        Printf.sprintf
                          "You MUST call one of these tools NOW: %s."
                          preview
                    in
                    append_ctx
                      ctx
                      (Printf.sprintf
                         "[CONTRACT VIOLATION RETRY] Your previous Agent.run \
                          attempt was rejected because you did not call a \
                          required tool. %s Do NOT respond with text only, do NOT substitute \
                          status or read-only tools."
                         retry_action)
                  else ctx
                in
                if computed_surface.is_warning_zone
                then
                  Log.Keeper.info
                    "keeper:%s per_call_turn_budget absolute_turn=%d \
                     checkpoint_start_turn=%d per_call_turn=%d/%d last_turn=%b"
                    meta.name
                    computed_surface.absolute_turn
                    computed_surface.checkpoint_start_turn
                    computed_surface.per_call_turn
                    computed_surface.per_call_max_turns
                    computed_surface.is_last_turn;
                let all_allowed = computed_surface.all_allowed in
                let tool_filter = Agent_sdk.Guardrails.AllowList all_allowed in
                let clear_inherited_strict_tool_choice = function
                  | Some (Agent_sdk.Types.Any | Agent_sdk.Types.Tool _) -> None
                  | other -> other
                in
                let tool_choice =
                  if computed_surface.required_tool_names <> [] && all_allowed <> []
                  then
                    Some
                      (preferred_tool_choice_for_required_tool_names
                         ~required_tool_names:computed_surface.required_tool_names
                         ~allowed_tool_names:all_allowed)
                  else if
                    (not computed_surface.is_last_turn)
                    && computed_surface.tool_gate_requested
                    && all_allowed <> []
                  then
                    Some
                      (preferred_tool_choice_for_required_turn
                         ~has_current_task:(keeper_has_owned_active_task ())
                         ~turn_affordances
                         ~allowed_tool_names:all_allowed)
                  else clear_inherited_strict_tool_choice current_params.tool_choice
                in
                let turn_completion_contract =
                  match computed_surface.tool_gate_requested, tool_choice with
                  | true, Some Agent_sdk.Types.Auto ->
                    Keeper_tool_completion_contract.completion_contract_of_tool_choice tool_choice
                  | true, _ -> Keeper_tool_completion_contract.Require_tool_use
                  | false, _ ->
                    Keeper_tool_completion_contract.completion_contract_of_tool_choice tool_choice
                in
                acc.completion_contract <- turn_completion_contract;
                if turn_completion_contract = Keeper_tool_completion_contract.Require_tool_use
                then acc.required_tool_use_seen <- true;
                let lane = computed_surface.lane in
                Keeper_run_tools_hook_accumulator.record_requested_tool_names acc all_allowed;
                acc.tool_surface
                <- { turn_lane = lane
                   ; tool_surface_class = computed_surface.tool_surface_class
                   ; tool_requirement = computed_surface.tool_requirement
                   ; visible_tool_count = List.length all_allowed
                   ; tool_gate_enabled = computed_surface.tool_gate_requested
                   ; tool_surface_fallback_used =
                       computed_surface.tool_surface_fallback_used
                   ; required_tool_names = computed_surface.required_tool_names
                   ; required_tool_candidate_names =
                       computed_surface.required_tool_candidate_names
                   ; missing_required_tool_names =
                       computed_surface.missing_required_tool_names
                   ; config_root
                   ; cascade_config_path
                   ; gemini_mcp_disabled
                   ; approval_mode_effective
                   ; approval_mode_derived
                   };
                let thinking_enabled_effective =
                  match current_params.enable_thinking with
                  | Some b -> b
                  | None -> Keeper_config.keeper_enable_thinking ()
                in
                Keeper_tool_call_log.set_turn_context
                  ~keeper_name:meta.name
                  ~agent_name:meta.agent_name
                  ~lane:
                    (Keeper_agent_tool_surface.turn_lane_to_string lane)
                  ?tool_choice:
                    (Option.map
                       (fun choice ->
                          Yojson.Safe.to_string
                            (Agent_sdk.Types.tool_choice_to_json choice))
                       tool_choice)
                  ~thinking_enabled:thinking_enabled_effective
                  ?thinking_budget:current_params.thinking_budget
                  ~prompt_fingerprint:prompt_metrics.fingerprint
                  ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                  ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                  ~generation
                  ~turn
                  ?keeper_turn_id:manifest_keeper_turn_id
                  ?task_id:
                    (Option.map Keeper_id.Task_id.to_string acc.meta.current_task_id)
                  ~goal_ids:meta.active_goal_ids
                  ~sandbox_profile:
                    (Keeper_types.sandbox_profile_to_string meta.sandbox_profile)
                  ~sandbox_root:
                    (Keeper_sandbox.keeper_visible_root_abs_of_meta ~config meta)
                  ~allowed_paths:(Keeper_alerting_path.effective_allowed_paths ~meta)
                  ~network_mode:(Keeper_types.network_mode_to_string meta.network_mode)
                  ?approval_mode:approval_mode_effective
                  ~tool_surface_class:
                    (Keeper_agent_tool_surface.tool_surface_class_to_string
                       computed_surface.tool_surface_class)
                  ~visible_tool_count:(List.length all_allowed)
                  ~required_tools:computed_surface.required_tool_names
                  ~required_tool_candidates:
                    computed_surface.required_tool_candidate_names
                  ~missing_required_tools:computed_surface.missing_required_tool_names
                  ~cascade_profile:cascade_name_string
                  ();
                (let now = Time_compat.now () in
                 let hook_elapsed_ms =
                   Keeper_timing.round1 ((now -. hook_t0) *. 1000.0)
                 in
                 Keeper_registry.set_turn_decision_stage
                   ~base_path:config.base_path
                   meta.name
                   Keeper_registry.Decision_active_tool_policy_selected;
                 Keeper_registry.set_turn_cascade_state
                   ~base_path:config.base_path
                   meta.name
                   (Keeper_registry.Packed Keeper_registry.Cascade_selecting
                    : Keeper_registry.packed_cascade_state);
                 (* Spec atomic group: SelectToolPolicy(idle->selecting)
                   is immediately followed by CascadeTrying(selecting->
                   trying).  Both transitions are materialised inside
                   the disclosure hook because the spec invariant
                   [SelectingRequiresToolPolicy] requires
                   [decision_stage = Decision_tool_policy_selected],
                   which is only set at this site.  Pre-PR #14153 the
                   Cascade_trying marking lived inside
                   [Keeper_unified_turn.retry_loop] (line 1138 era),
                   producing an [idle -> trying] jump that bypassed
                   selecting; the move here closes that gap by keeping
                   the two transitions adjacent.  On retry attempts
                   the prior cascade state is [Cascade_trying]; the
                   re-entry sequence becomes [trying -> selecting ->
                   trying] which is admitted by
                   [validate_cascade_transition]. *)
                 Keeper_registry.set_turn_cascade_state
                   ~base_path:config.base_path
                   meta.name
                   (Keeper_registry.Packed Keeper_registry.Cascade_trying
                    : Keeper_registry.packed_cascade_state);
                 let disclosure_json =
                   `Assoc
                     [ "ts_unix", `Float now
                     ; "event", `String "tool_disclosure"
                     ; "keeper_name", `String meta.name
                     ; "turn", `Int turn
                     ; ( "checkpoint_start_turn"
                       , `Int computed_surface.checkpoint_start_turn )
                     ; "per_call_turn", `Int computed_surface.per_call_turn
                     ; "per_call_max_turns", `Int computed_surface.per_call_max_turns
                     ; ( "selection_mode"
                       , Keeper_agent_tool_surface.tool_selection_mode_to_yojson
                           computed_surface.selection_mode )
                     ; "core_count", `Int computed_surface.core_count
                     ; ( "deterministic_prefilter_count"
                       , `Int computed_surface.deterministic_prefilter_count )
                     ; "discovered_count", `Int computed_surface.discovered_count
                     ; "llm_selected_count", `Int computed_surface.llm_selected_count
                     ; "final_visible", `Int (List.length all_allowed)
                     ; ( "turn_lane"
                       , Keeper_agent_tool_surface.turn_lane_to_yojson lane )
                     ; ( "tool_surface_class"
                       , Keeper_agent_tool_surface.tool_surface_class_to_yojson
                           computed_surface.tool_surface_class )
                     ; ( "tool_requirement"
                       , tool_requirement_to_yojson computed_surface.tool_requirement )
                     ; "tool_gate_enabled", `Bool computed_surface.tool_gate_requested
                     ; ( "tool_surface_fallback_used"
                       , `Bool computed_surface.tool_surface_fallback_used )
                     ; "hook_ms", `Float hook_elapsed_ms
                     ]
                 in
                 try
                   Keeper_types_support.append_jsonl_line
                     (Keeper_types_support.keeper_decision_log_path config meta.name)
                     disclosure_json
                 with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                   Prometheus.inc_counter
                     Keeper_metrics.(to_string DecisionAuditFlushFailures)
                     ~labels:[ "keeper", meta.name ]
                     ();
                   Log.Keeper.warn
                     "keeper:%s tool_disclosure jsonl append failed: %s"
                     meta.name
                     (Printexc.to_string exn));
                Eio.Fiber.yield ();
                Agent_sdk.Hooks.AdjustParams
                  { current_params with
                    extra_system_context = ctx
                  ; tool_choice
                  ; tool_filter_override = Some tool_filter
                  }
              | _event -> Agent_sdk.Hooks.Continue)
      }
    in
    let hooks = Agent_sdk.Hooks.compose ~outer:before_turn_hook ~inner:base_hooks in
    let base_dir = Coord.masc_root_dir config in
    let memory_session_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let memory_bundle =
      Memory_oas_bridge.create_memory_with_backend
        ~agent_name
        ~base_dir
        ~session_id:memory_session_id
        ()
    in
    let memory = memory_bundle.created_memory in
    let memory_backend = memory_bundle.created_memory_long_term_backend in
    let hooks =
      let mem_hooks =
        Memory_hooks.make
          ~agent_name
          ~config
          ~memory
          ~world_backend:memory_backend
          ~episode_limit:30
          ~procedure_limit:10
          ?runtime_manifest_context
          ?runtime_manifest_append
          ()
      in
      Memory_hooks.compose_with_inner ~memory_hooks:mem_hooks ~inner:hooks
    in
    (* Tier K4b/K4c: install the tool-emission PostToolUse hook so
     tagged tool results flow into this keeper's own accumulator
     during Agent.run. The drain happens in keeper_post_turn.ml
     [apply_tool_emission_wirein] BEFORE [apply_multimodal_wirein],
     keyed by the SAME keeper name (stable across turns).
     When [MASC_TOOL_EMISSION] is off the hook is a no-op (see
     [Keeper_tool_emission_hook] for the gating). *)
    let hooks =
      let acc = Keeper_tool_emission_hook.accumulator_for_keeper agent_name in
      Keeper_tool_emission_hook.install_into_hooks acc hooks
    in
    let reducer =
      let hydrator_steps =
        match Keeper_artifact_hydrator.reducer_from_env () with
        | Some r -> [ r ]
        | None -> []
      in
      let tool_pair_counts messages =
        List.fold_left
          (fun (uses, results) (msg : Agent_sdk.Types.message) ->
             List.fold_left
               (fun (uses, results) -> function
                 | Agent_sdk.Types.ToolUse _ -> uses + 1, results
                 | Agent_sdk.Types.ToolResult _ -> uses, results + 1
                 | Agent_sdk.Types.Text _
                 | Agent_sdk.Types.Thinking _
                 | Agent_sdk.Types.RedactedThinking _
                 | Agent_sdk.Types.Image _
                 | Agent_sdk.Types.Document _
                 | Agent_sdk.Types.Audio _ -> uses, results)
               (uses, results)
               msg.content)
          (0, 0)
          messages
      in
      let repair_broken_tool_call_pairs_observed messages =
        let before_uses, before_results = tool_pair_counts messages in
        let repaired = Keeper_context_core.repair_broken_tool_call_pairs messages in
        let after_uses, after_results = tool_pair_counts repaired in
        let record kind delta =
          if delta > 0 then
            Prometheus.inc_counter
              Keeper_metrics.(to_string ToolPairRepair)
              ~labels:[ "keeper", agent_name; "kind", kind; "site", "keeper_reducer" ]
              ~delta:(float_of_int delta)
              ()
        in
        record "dangling_tool_use" (max 0 (before_uses - after_uses));
        record "orphan_tool_result" (max 0 (before_results - after_results));
        repaired
      in
      Agent_sdk.Context_reducer.compose
        (hydrator_steps
         @ [ Agent_sdk.Context_reducer.drop_thinking
           ; Agent_sdk.Context_reducer.stub_tool_results ~keep_recent:3
           ; Agent_sdk.Context_reducer.prune_tool_outputs ~max_output_len:4000
           ; Agent_sdk.Context_reducer.cap_message_tokens
               ~max_tokens:Env_config_keeper.KeeperReducer.cap_message_tokens
               ~keep_recent:Env_config_keeper.KeeperReducer.cap_message_keep_recent
           ; { Agent_sdk.Context_reducer.strategy =
                 Agent_sdk.Context_reducer.Custom
                   repair_broken_tool_call_pairs_observed
             }
           ; Agent_sdk.Context_reducer.merge_contiguous
           ])
    in
    Ok
      { tools
      ; cleanup = keeper_tool_bundle.cleanup
      ; hooks
      ; reducer
      ; memory
      ; acc
      ; initial_tool_surface
      ; initial_tool_surface_blocker
      ; all_tool_names
      ; tool_usage_before
      ; receipt_turn_count_ref
      ; receipt_model_used_ref
      ; receipt_stop_reason_ref
      ; receipt_cascade_observation_ref
      ; receipt_response_text_present_ref
      ; reported_tool_names_ref
      ; observed_tool_names_ref
      ; canonical_tool_names_ref
      ; unexpected_tool_names_ref
      ; actual_keeper_tool_names_ref
      }
;;
