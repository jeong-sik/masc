(* keeper_run_tools_hooks — hooks assembly for prepare_agent_setup.
   Extracted from keeper_run_tools.ml. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_agent_tool_surface
open Keeper_agent_result
open Keeper_agent_prompt_metrics

type hook_accumulator = Keeper_run_tools_hook_accumulator.hook_accumulator

type agent_setup =
  { tools : Agent_sdk.Tool.t list
  ; cleanup : unit -> unit
  ; hooks : Agent_sdk.Hooks.hooks
  ; reducer : Agent_sdk.Context_reducer.t
  ; acc : hook_accumulator
  ; all_tool_names : string list
  ; tool_context_estimate : Keeper_run_prompt.tool_schema_context_estimate
  ; receipt_turn_count_ref : int option ref
  ; receipt_model_used_ref : string option ref
  ; receipt_stop_reason_ref : Runtime_agent.stop_reason option ref
  ; receipt_runtime_observation_ref : Runtime_observation.runtime_observation option ref
  ; receipt_response_text_present_ref : bool ref
  }

type ctx =
  { acc : hook_accumulator
  ; agent_name : string
  ; all_tool_names : string list
  ; compute_tool_surface :
      turn:int -> messages:Agent_sdk.Types.message list ->
      current_tool_choice:Agent_sdk.Types.tool_choice option ->
      decay_discovered:bool -> unit ->
      string list * turn_lane
  ; record_tool_assignment :
      turn:int -> tool_list:string list -> lane:turn_lane -> unit
  ; config : Workspace.config
  ; keeper_tools_cleanup : unit -> unit
  ; manifest_keeper_turn_id : int option
  ; max_context : int
  ; meta : Keeper_meta_contract.keeper_meta
  ; tool_context_estimate : Keeper_run_prompt.tool_schema_context_estimate
  ; turn_ctx_cell : Keeper_tool_call_log.turn_ctx_cell
    (* RFC-0225 §3.3: per-run carrier; written by the pre-request hook
       below, read by the post-tool hooks in Keeper_hooks_oas. *)
  ; receipt_turn_count_ref : int option ref
  ; receipt_model_used_ref : string option ref
  ; receipt_stop_reason_ref : Runtime_agent.stop_reason option ref
  ; receipt_runtime_observation_ref : Runtime_observation.runtime_observation option ref
  ; receipt_response_text_present_ref : bool ref
  ; tools : Agent_sdk.Tool.t list
  }

let relax_strict_tool_choice_for_keeper = function
  | Some (Agent_sdk.Types.Any | Agent_sdk.Types.Tool _) ->
    Some Agent_sdk.Types.Auto
  | other -> other

let relative_path_has_segment_prefix prefix raw =
  String.equal raw prefix || String.starts_with ~prefix:(prefix ^ "/") raw
;;

let sandbox_rooted_relative_path raw =
  Filename.is_relative raw
  && List.exists
       (fun prefix -> relative_path_has_segment_prefix prefix raw)
       [ "repos"; "mind"; Common.masc_dirname; "playground" ]
;;

let non_empty_string_member name input =
  match Yojson.Safe.Util.member name input with
  | `String raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then None else Some raw
  | _ -> None
;;

(* #23469 (task-1733 completion): keeper file tools resolve relative paths
   against the keeper's playground sandbox root ([keeper_default_read_root]),
   never against the server base path. The observation join mirrors that
   contract, otherwise the emitted partition describes a file the tool never
   touched: a sandbox-rooted [repos/<id>/…] edit used to be re-anchored at
   the server base path and attributed through whichever repository happened
   to be registered there, and a bare relative path with no [cwd] leaked
   through unanchored for the resolver to join at the base path. Every
   relative shape therefore anchors at [sandbox_root]; absolute paths pass
   through untouched, and a pathless tool call stays a keeper-timeline fact
   at [base_path]. *)
let observation_file_path_from_tool_input ~base_path ~sandbox_root input =
  let under_sandbox p = Filename.concat sandbox_root p in
  match Tool_input_path.tool_input_file_path input with
  | None -> base_path
  | Some p when Filename.is_relative p ->
    if sandbox_rooted_relative_path p
    then under_sandbox p
    else (
      match non_empty_string_member "cwd" input with
      | Some cwd when Filename.is_relative cwd ->
        under_sandbox (Filename.concat cwd p)
      | Some cwd -> Filename.concat cwd p
      | None -> under_sandbox p)
  | Some p -> p
;;

let observation_partition_for_tool_input ~config ~meta ~kind input =
  let base_dir = Keeper_alerting_path.project_root_of_config config in
  let sandbox_root =
    Keeper_tool_shared_runtime.keeper_observation_sandbox_root ~config ~meta
  in
  let file_path =
    observation_file_path_from_tool_input ~base_path:base_dir ~sandbox_root input
    |> Keeper_tool_shared_runtime.keeper_observation_host_path_of_visible_path
         ~config
         ~meta
  in
  Keeper_tool_filesystem_runtime.resolve_partition_for_write
    ~base_dir
    ~kind
    ~file_path
;;

let assemble_hooks
      ~(ctx : ctx)
      ~(session : Keeper_types.session_context)
      ~(turn_system_prompt : string)
      ~(user_message : string)
      ~(dynamic_context : string)
      ~(history_messages : Agent_sdk.Types.message list)
      ~(prompt_metrics : Keeper_agent_prompt_metrics.prompt_metrics)
      ~(shared_context : Agent_sdk.Context.t)
      ~(start_turn_count : int)
      ~(generation : int)
      ~(runtime_id_string : string)
      ~(is_retry : bool)
      ~(turn_affordances : string list)
      ~(config_root : string)
      ~(runtime_config_path : string option)
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
  let record_tool_assignment = ctx.record_tool_assignment in
  let config = ctx.config in
  let keeper_tools_cleanup = ctx.keeper_tools_cleanup in
  let manifest_keeper_turn_id = ctx.manifest_keeper_turn_id in
  let max_context = ctx.max_context in
  let meta = ctx.meta in
  let tool_context_estimate = ctx.tool_context_estimate in
  let turn_ctx_cell = ctx.turn_ctx_cell in
  let receipt_turn_count_ref = ctx.receipt_turn_count_ref in
  let receipt_model_used_ref = ctx.receipt_model_used_ref in
  let receipt_stop_reason_ref = ctx.receipt_stop_reason_ref in
  let receipt_runtime_observation_ref = ctx.receipt_runtime_observation_ref in
  let receipt_response_text_present_ref = ctx.receipt_response_text_present_ref in
  let tools = ctx.tools in
  let all_tool_names = ctx.all_tool_names in
  let initial_schema_filter, initial_turn_lane =
    compute_tool_surface
      ~turn:(start_turn_count + 1)
      ~messages:history_messages
      ~current_tool_choice:None
      ~decay_discovered:false
      ()
  in
  acc.tool_surface
  <- { turn_lane = initial_turn_lane
     ; config_root
     ; runtime_config_path
     };
  Keeper_run_tools_hook_accumulator.record_requested_tool_names
      acc
      initial_schema_filter;
    let meta_ref = ref acc.meta in
    let public_alias_pre_tool_use_guard ~tool_name ~input:_ =
      Keeper_tool_resolution.public_alias_guidance_for_internal_call
        ~allowed_tool_names:acc.requested_tool_names
        tool_name
    in
    let base_hooks =
      Keeper_hooks_oas.make_hooks
        ~config
        ~meta_ref
        ~turn_ctx_cell
        ~generation
        ?max_cost_usd
        ?trajectory_acc
        ~on_tool_executed:
          (fun
            ~tool_name ~input ~output_text ~success ~duration_ms ~provider ~typed_outcome ->
          let route_evidence =
            Keeper_tool_call_log.route_evidence_json_of_tool_io
              ~tool_name
              ~input
              ~output_text
          in
          let progress_io_fingerprints =
            Keeper_tool_progress_identity.digest_tool_io
              ~tool_name
              ~input
              ~output_text
          in
          let outcome =
            if not success
            then "error"
            else if
              Keeper_tool_progress.tool_result_has_material_progress
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
             ; execution_outcome =
                 (if success then Tool_result.Ok else Tool_result.Error)
             ; typed_outcome
             ; latency_ms = duration_ms
             ; task_id
             ; route_evidence
             ; input_fingerprint =
                 Option.map
                   (fun (d : Keeper_tool_progress_identity.io_fingerprints) ->
                      d.input_fingerprint)
                   progress_io_fingerprints
             ; output_fingerprint =
                 Option.map
                   (fun (d : Keeper_tool_progress_identity.io_fingerprints) ->
                      d.output_fingerprint)
                   progress_io_fingerprints
             }
             :: acc.tool_calls;
          (* Emit neutral agent observation events; UI adapters subscribe separately. *)
          (let typed_outcome_str =
             match typed_outcome with
             | Some Keeper_tool_outcome.Progress -> "progress"
             | Some (Keeper_tool_outcome.No_progress _) -> "no_progress"
             | Some (Keeper_tool_outcome.Error _) -> "error"
             | None -> outcome
           in
           let turn_id =
             match acc.meta.Keeper_meta_contract.current_task_id with
             | Some t -> Keeper_id.Task_id.to_string t
             | None -> "turn-" ^ string_of_int (List.length acc.tool_calls)
           in
           (* task-1733: resolve the partition from the tool's actual edited
              file (input.path / input.file_path, with explicit cwd honoured
              for relative paths), not from the [.masc] runtime root.
              #23469: relative shapes anchor at this keeper's playground
              sandbox root, matching the file tools' own resolution. *)
           let partition, _ =
             observation_partition_for_tool_input
               ~config
               ~meta:acc.meta
               ~kind:"tool_event"
               input
           in
           Agent_observation.emit_tool_event
             { base_path = config.base_path
             ; partition
             ; tool_name
             ; keeper_id = acc.meta.name
             ; turn_id
             ; outcome
             ; typed_outcome = typed_outcome_str
             ; duration_ms
             ; output_text
             ; input
             };
           Agent_observation.emit_pr_event
             { base_path = config.base_path
             ; partition
             ; keeper_id = acc.meta.name
             ; turn_id
             ; output_text
             ; tool_name
             ; success
             };
           (* #23540: keeper in-turn tool executions never reached the
              activity log ([tool.called] is emitted only by the external MCP
              path), so the agent timeline reported tool_calls = 0 for any
              keeper working through its own turn. *)
           Keeper_tool_activity.emit_tool_exec
             ~config
             ~agent_name:acc.meta.Keeper_meta_contract.agent_name
             ~keeper_name:acc.meta.name
             ~tool_name
             ~success
             ~duration_ms:(int_of_float (Float.round duration_ms))
             ~outcome:typed_outcome_str
             ~provider
             ~turn_id
             ()))
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
                  fields ([turn_phase], [runtime_state], [decision_stage])
                  are reset before the hook writes [Runtime_selecting] /
                  [Decision_tool_policy_selected] / [Turn_prompting] below.
                  The MASC keeper-turn boundary ([mark_turn_started]) only
                  fires once per [Agent_sdk.run_loop] call; every additional
                  SDK turn inside that loop must use this entry point or
                  [validate_turn_phase_transition] rejects the transition
                  from the previous SDK turn's [Turn_finalizing] terminal. *)
                Keeper_registry.mark_sdk_turn_started
                  ~base_path:config.base_path
                  meta.name;
                let runtime_seed =
                  Runtime_inference.for_runtime ~name:runtime_id_string
                in
                let current_budget =
                  match runtime_seed.thinking_budget with
                  | Some _ as v -> v
                  | None -> current_params.thinking_budget
                in
                let adaptive_thinking_budget =
                  adaptive_thinking_budget
                    ~enabled:(Keeper_config.keeper_adaptive_thinking_enabled ())
                    ~is_retry
                    ~last_tool_results
                    ~current_budget
                in
                let current_params =
                  { current_params with
                    thinking_budget = adaptive_thinking_budget
                  ; enable_thinking =
                      (match runtime_seed.thinking_enabled with
                       | Some enabled -> Some enabled
                       | None -> current_params.enable_thinking)
                  ; preserve_thinking =
                      (match runtime_seed.preserve_thinking with
                       | Some preserve -> Some preserve
                       | None -> current_params.preserve_thinking)
                  }
                in
                (* RFC-0233 PR-3: every append below also records its
                   (block id, raw text) pair; the snapshot lands in the
                   hook accumulator just before AdjustParams so the
                   receipt/TurnRecord writer can persist typed
                   provenance. The closed Prompt_block_id sum makes a
                   new injection site without a recording a compile
                   error at the snapshot below. *)
                let recorded_blocks = ref [] in
                let record_block block text =
                  recorded_blocks := (block, text) :: !recorded_blocks
                in
                let preflight_accounted_blocks = ref [] in
                let record_preflight_accounted_block block text =
                  record_block block text;
                  preflight_accounted_blocks := block :: !preflight_accounted_blocks
                in
                (if String.trim dynamic_context <> ""
                 then
                   record_preflight_accounted_block
                     Prompt_block_id.Dynamic_context
                     dynamic_context);
                (match Masc_context_injector.render_temporal_summary shared_context with
                 | None -> ()
                 | Some temporal ->
                   record_preflight_accounted_block
                     Prompt_block_id.Temporal_summary
                     temporal);
                (match acc.meta.current_task_id with
                  | Some task_id ->
                    let last_tool_names =
                      let rev = List.rev messages in
                      let rec scan = function
                        | [] -> []
                        | (msg : Agent_sdk.Types.message) :: rest ->
                          let names =
                            List.filter_map
                              (fun block ->
                                Agent_sdk.Canonical_tool.tool_call_of_block block
                                |> Option.map (fun call ->
                                  call.Agent_sdk.Canonical_tool.name))
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
                           an execution tool from your active runtime schema to start \
                           working on it now. If no execution tool is available, explain \
                           the blocker explicitly instead of inventing a tool name."
                          (Keeper_id.Task_id.to_string task_id)
                      in
                      record_block Prompt_block_id.Claimed_task_nudge nudge;
                      ())
                  | None -> ());
                let schema_filter, computed_turn_lane =
                  compute_tool_surface
                    ~turn
                    ~messages
                    ~current_tool_choice:current_params.tool_choice
                    ~decay_discovered:true
                    ()
                in
                (if is_retry
                 then (
                    let retry_nudge =
                      "[RETRY] The previous attempt overflowed the model context. \
                       Stay concise, prefer already-loaded context, and only use the \
                       smallest essential tool set if a tool call is strictly \
                       necessary."
                    in
                    record_block Prompt_block_id.Retry_nudge retry_nudge));
                (match
                   (* Off-main: [render_if_enabled] performs synchronous file I/O
                      (stat/readdir/open over the persisted memory store). Running
                      it directly on the main Eio domain blocks the cooperative
                      scheduler, head-of-line-blocking every sibling keeper fiber
                      until the syscalls return. Push the I/O onto the shared
                      domain pool ([submit_io_or_inline] runs inline when no pool
                      is configured, e.g. tests). The render is read-side only and
                      keeps no module-level mutable state, so it is domain-safe. *)
                   Domain_pool_ref.submit_io_or_inline (fun () ->
                     Keeper_user_model.render_if_enabled
                       ~keeper_id:meta.name
                       ~now:(Time_compat.now ())
                       ())
                 with
                 | None -> ()
                 | Some block -> record_block Prompt_block_id.User_model block);
                (match
                   (* Memory OS recall — bounded advisory block rendered from
                      persisted facts/episodes (read side; the write side is
                      the librarian wired in #20897). Opt-in via
                      MASC_KEEPER_MEMORY_OS_RECALL. RFC-0247 removed the lexical
                      seed: recall now orders by structural recency, so the
                      current-turn text no longer reranks the recalled facts. *)
                   (* Off-main: same rationale as the user-model render above —
                      the recall reads persisted facts/episodes via synchronous
                      file I/O, which would starve the main Eio domain and HOL
                      sibling keepers. Read-side only, no module-level mutable
                      state, so it is domain-safe on the shared pool. *)
                   Domain_pool_ref.submit_io_or_inline (fun () ->
                     Keeper_memory_os_recall.render_if_enabled
                       ~keeper_id:meta.name
                       ~now:(Time_compat.now ())
                       ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                       ~turn
                       ~masc_root:(Workspace.masc_root_dir config)
                       ())
                 with
                 | None -> ()
                 | Some block -> record_block Prompt_block_id.Memory_os_recall block);
                let extra_system_context_budget =
                  Keeper_run_prompt.budget_extra_system_context
                    ~estimated_input_tokens_with_tools:
                      tool_context_estimate.estimated_input_tokens_with_tools
                    ~max_context
                    ~existing_extra_system_context:
                      current_params.extra_system_context
                    ~preflight_accounted_blocks:
                      (List.rev !preflight_accounted_blocks)
                    ~blocks:(List.rev !recorded_blocks)
                in
                let ctx = extra_system_context_budget.extra_system_context in
                let recorded_blocks_for_receipt =
                  extra_system_context_budget.included_blocks
                in
                let tool_filter =
                  Agent_sdk.Guardrails.AllowList schema_filter
                in
                (* OAS treats [None] in AdjustParams as "keep the base
                   config", so strict choices must be explicitly relaxed.
                   Tools remain available, but the model may finish without
                   another forced tool call. *)
                let tool_choice =
                  relax_strict_tool_choice_for_keeper current_params.tool_choice
                in
                let lane = computed_turn_lane in
                record_tool_assignment ~turn ~tool_list:schema_filter ~lane;
                Keeper_run_tools_hook_accumulator.record_requested_tool_names
                  acc
                  schema_filter;
                acc.tool_surface
                <- { turn_lane = lane
                   ; config_root
                   ; runtime_config_path
                   };
                let thinking_enabled_effective =
                  match current_params.enable_thinking with
                  | Some b -> b
                  | None -> Keeper_config.keeper_enable_thinking ()
                in
                Keeper_tool_call_log.set_turn_context
                  ~cell:turn_ctx_cell
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
                    (Keeper_types_profile_sandbox.sandbox_profile_to_string meta.sandbox_profile)
                  ~sandbox_root:
                    (Keeper_sandbox.keeper_visible_root_abs_of_meta ~config meta)
                  ~allowed_paths:(Keeper_alerting_path.effective_allowed_paths ~meta)
                  ~network_mode:(Keeper_types_profile_sandbox.network_mode_to_string meta.network_mode)
                  ~runtime_profile:runtime_id_string
                  ();
                (ignore hook_t0;
                 Keeper_registry.set_turn_decision_stage
                   ~base_path:config.base_path
                   meta.name
                   Keeper_registry.Decision_active_tool_policy_selected;
                 Keeper_registry.set_turn_phase
                   ~base_path:config.base_path
                   meta.name
                   (Keeper_registry.Packed Keeper_registry.Turn_routing);
                 (* Spec atomic group: SelectToolPolicy(idle->selecting)
                   is immediately followed by RuntimeTrying(selecting->
                   trying).  Both transitions are materialised inside
                   the disclosure hook because the spec invariant
                   [SelectingRequiresToolPolicy] requires
                   [decision_stage = Decision_tool_policy_selected],
                   which is only set at this site.  Pre-PR #14153 the
                   Runtime_trying marking lived inside
                   [Keeper_unified_turn.retry_loop] (line 1138 era),
                   producing an [idle -> trying] jump that bypassed
                   selecting; the move here closes that gap by keeping
                   the two transitions adjacent.  On retry attempts
                   the prior runtime state is [Runtime_trying]; the
                   re-entry sequence becomes [trying -> selecting ->
                   trying] which is admitted by
                   [validate_runtime_transition]. *)
                 Keeper_registry.mark_turn_provider_attempt_started
                   ~base_path:config.base_path
                   meta.name);
                (* RFC-0233 PR-3 + #20936: snapshot this SDK turn's
                   assembly into the accumulator the receipt/TurnRecord
                   writer reads. Appended blocks hash their raw appended
                   text; Persona reuses the prompt-metrics fingerprint
                   (sha256 of the sanitized rendered system prompt) —
                   the digest the prompt store already records. *)
                let sha256_hex text =
                  Digestif.SHA256.(digest_string text |> to_hex)
                in
                let persona_blocks =
                  match prompt_metrics.system_prompt_segment.fingerprint with
                  | Some digest ->
                    [ { Turn_record.block = Prompt_block_id.Persona
                      ; bytes = prompt_metrics.system_prompt_segment.bytes
                      ; digest
                      }
                    ]
                  | None -> []
                in
                acc.prompt_blocks
                <- persona_blocks
                   @ List.map
                       (fun (block, text) ->
                          { Turn_record.block
                          ; bytes = String.length text
                          ; digest = sha256_hex text
                          })
                       recorded_blocks_for_receipt;
                acc.extra_system_context_digest <- Option.map sha256_hex ctx;
                acc.extra_system_context_size <- Option.map String.length ctx;
                let extra_system_context_estimated_tokens =
                  Option.map Keeper_context_core_accessors.estimate_char_tokens ctx
                in
                let hook_extra_system_context_estimated_tokens =
                  extra_system_context_budget
                    .hook_extra_system_context_estimated_tokens
                in
                let post_hook_estimated_input_tokens =
                  extra_system_context_budget.post_hook_estimated_input_tokens
                in
                let post_hook_context_window_budget =
                  extra_system_context_budget.post_hook_context_window_budget
                in
                (* [budget_extra_system_context] computes the post-hook ledger
                   from the assembled [extra_system_context] string, subtracting
                   only blocks already represented in the pre-dispatch estimate.
                   When the base tool-inclusive estimate fits the window, hook
                   additions that would push the request over are skipped before
                   this check. Any remaining overflow is therefore the base
                   request overflow that must reach OAS' typed ContextOverflow
                   retry path, not a silent hook-induced overrun. *)
                let post_hook_context_window_error =
                  Keeper_run_prompt.preflight_context_window
                    ~estimated_input_tokens:post_hook_estimated_input_tokens
                    ~max_context
                in
                let post_hook_over_context_window =
                  match post_hook_context_window_error with
                  | Ok () -> false
                  | Error _ -> true
                in
                (match runtime_manifest_context, runtime_manifest_append with
                 | Some manifest_context, Some append_manifest ->
                   let post_tool_context =
                     last_tool_results <> []
                   in
                   append_manifest
                     (Keeper_runtime_manifest.make_for_context
                        manifest_context
                        ~event:Keeper_runtime_manifest.Context_injected
                        ~oas_turn_count:turn
                        ~runtime_id:runtime_id_string
                        ~status:
                          (if post_hook_over_context_window
                           then "post_hook_context_overflow"
                           else if post_tool_context
                           then "post_tool_context_injection"
                           else "pre_tool_context_injection")
                        ~decision:
                          (Keeper_runtime_manifest.with_payload_role
                             ~payload_role:Keeper_runtime_manifest.Model_input
                             (`Assoc
                               [ ( "sdk_turn", `Int turn )
                               ; ( "post_tool_context_injection",
                                   `Bool post_tool_context )
                               ; ( "last_tool_result_count",
                                   `Int (List.length last_tool_results) )
                               ; ( "prompt_block_count",
                                   `Int (List.length acc.prompt_blocks) )
                               ; ( "extra_system_context_digest",
                                   Json_util.string_opt_to_json
                                     acc.extra_system_context_digest )
                               ; ( "extra_system_context_computed_size",
                                   Json_util.int_opt_to_json
                                     acc.extra_system_context_size )
                               ; ( "extra_system_context_estimated_tokens",
                                   Json_util.int_opt_to_json
                                     extra_system_context_estimated_tokens )
                               ; ( "hook_extra_system_context_estimated_tokens",
                                   `Int hook_extra_system_context_estimated_tokens )
                               ; ( "estimated_input_tokens_with_tools",
                                   `Int
                                     tool_context_estimate.estimated_input_tokens_with_tools )
                               ; ( "post_hook_estimated_input_tokens",
                                   `Int post_hook_estimated_input_tokens )
                               ; ( "context_window",
                                   `Int max_context )
                               ; ( "post_hook_remaining_context_tokens",
                                   `Int
                                     post_hook_context_window_budget
                                       .remaining_context_tokens )
                               ; ( "post_hook_over_context_tokens",
                                   `Int
                                     post_hook_context_window_budget
                                       .over_context_tokens )
                               ; ( "post_hook_context_usage_ratio",
                                   `Float
                                     post_hook_context_window_budget
                                       .context_usage_ratio )
                               ; ( "post_hook_over_context_window",
                                   `Bool post_hook_over_context_window )
                               ; ( "skipped_extra_system_context_blocks",
                                   `List
                                     (List.map
                                        (fun block ->
                                           `String
                                             (Prompt_block_id.to_string block))
                                        extra_system_context_budget
                                          .skipped_blocks) )
                               ; ( "skipped_extra_system_context_estimated_tokens",
                                   `Int
                                     extra_system_context_budget
                                       .skipped_estimated_tokens )
                               ]))
                        ())
                 | _ -> ());
                (* Phase O observability: capture the effective OAS request
                   boundary after keeper-owned context injection has finalized
                   [extra_system_context]. *)
                Option.iter
                  (fun turn_id ->
                     Keeper_wire_capture.capture_request
                       ~masc_root:(Workspace.masc_root_dir config)
                       ~keeper_name:meta.name
                       ~turn_id
                       ~trace_id:meta.runtime.trace_id
                       ~sdk_turn:turn
                       ~system_prompt:turn_system_prompt
                       ~extra_system_context:ctx
                       ~user_message
                       ~history_messages:messages
                       ())
                  manifest_keeper_turn_id;
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
      let repair_broken_tool_call_pairs_observed messages =
        let repaired, stats =
          Keeper_context_core.repair_broken_tool_call_pairs_with_stats messages
        in
        let record kind delta =
          if delta > 0 then
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string ToolPairRepair)
              ~labels:[ "keeper", agent_name; "kind", kind; "site", "keeper_reducer" ]
              ~delta:(float_of_int delta)
              ()
        in
        record "dropped_tool_use" stats.dropped_tool_uses;
        record "dropped_tool_result" stats.dropped_tool_results;
        if Keeper_context_core.tool_pair_repair_stats_changed stats then (
          let tool_use_sample_json =
            List.map
              (fun (tool_use_id, tool_name) ->
                 `Assoc
                   [ "tool_use_id", `String tool_use_id
                   ; "tool_name", `String tool_name
                   ])
              stats.dropped_tool_use_samples
          in
          let tool_result_id_json =
            List.map
              (fun tool_use_id -> `String tool_use_id)
              stats.dropped_tool_result_ids
          in
          Log.Harness.emit
            Log.Warn
            ~details:
              (`Assoc
                  [ "keeper_name", `String agent_name
                  ; "site", `String "keeper_reducer"
                  ; "dropped_tool_uses", `Int stats.dropped_tool_uses
                  ; "dropped_tool_results", `Int stats.dropped_tool_results
                  ; "dropped_tool_use_samples", `List tool_use_sample_json
                  ; "dropped_tool_result_ids", `List tool_result_id_json
                  ])
            (Printf.sprintf
               "keeper_reducer_pair_repair keeper=%s dropped_tool_uses=%d \
                dropped_tool_results=%d"
               agent_name
               stats.dropped_tool_uses
               stats.dropped_tool_results));
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
      ; cleanup = keeper_tools_cleanup
      ; hooks
      ; reducer
      ; acc
      ; all_tool_names
      ; tool_context_estimate
      ; receipt_turn_count_ref
      ; receipt_model_used_ref
      ; receipt_stop_reason_ref
      ; receipt_runtime_observation_ref
      ; receipt_response_text_present_ref
      }
;;
