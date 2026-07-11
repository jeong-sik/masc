(** Keeper_turn_driver — MASC named-runtime and model-label execution entry points.

    Public API for running OAS agents through MASC-managed named runtime
    profiles ([run_named])
    or explicit model label ([run_model_by_label]), with optional MASC
    tool bridging variants.

    @since God file decomposition — extracted from oas_worker.ml *)

open Result.Syntax

(* Sub-module includes (God file decomposition).
   Each sub-module is self-contained; the facade re-exports everything
   so existing callers do not need qualification. *)
include Runtime_oas_runner
include Keeper_internal_error
include Keeper_turn_driver_helpers

include Keeper_turn_driver_provider_attempt
include Keeper_turn_driver_backpressure

(* Composition root for the inverted runtime -> keeper-name-translation edge.
   This facade already bridges keeper and runtime ([include Runtime_oas_runner]
   above), and is in the startup link closure, so its top-level effect runs once
   before any runtime tool dispatch. Register the two pure Keeper_identity
   translators here; the runtime accessor stays fail-fast if this never ran. *)
let () =
  Runtime_oas_runner.set_keeper_name_xlat
    { Runtime_oas_runner.keeper_agent_name = Keeper_identity.keeper_agent_name
    ; keeper_name_from_agent_name = Keeper_identity.keeper_name_from_agent_name
    }

let release_client_capacity_quietly =
  Keeper_turn_driver_admission.release_client_capacity_quietly

let provider_config_identity_key =
  Keeper_turn_driver_admission.provider_config_identity_key

let runtime_candidates_of_providers =
  Keeper_turn_driver_admission.runtime_candidates_of_providers

let positive_modality_counts counts =
  counts
  |> List.filter (fun (_, n) -> n > 0)
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let modality_counts_summary counts =
  counts
  |> positive_modality_counts
  |> List.map (fun (modality, n) -> Printf.sprintf "%s=%d" modality n)
  |> String.concat ","

let modality_counts_total counts =
  counts
  |> positive_modality_counts
  |> List.fold_left (fun acc (_, n) -> acc + n) 0

let media_degrade_manifest_decision ~(runtime_id : string)
    (dropped : (string * int) list) =
  let summary = modality_counts_summary dropped in
  Keeper_runtime_manifest.with_payload_role
    ~payload_role:Keeper_runtime_manifest.Operator_evidence
    (`Assoc
      [
        ("routing_action", `String "media_degraded_to_text");
        ( "routing_reason",
          `String "no_configured_runtime_accepts_required_media" );
        ("degraded_runtime_id", `String runtime_id);
        ("media_dropped_total", `Int (modality_counts_total dropped));
        ("media_dropped_counts", `String summary);
      ])

type context_window_rebudget =
  { requested_context_window : int option
  ; final_runtime_context_window : int
  ; resolved_context_window : int
  ; context_window_rebudgeted : bool
  }

let resolve_context_window_tokens_after_runtime_selection
    ~(requested_context_window : int option)
    ~(final_runtime_context_window : int)
    : (context_window_rebudget, Agent_sdk.Error.sdk_error) result =
  let invalid_requested_context_window value =
    Agent_sdk.Error.Config
      (Agent_sdk.Error.InvalidConfig
         { field = "context_window_tokens"
         ; detail =
             Printf.sprintf
               "requested_context_window must be positive when provided (got %d)"
               value
         })
  in
  match requested_context_window with
  | Some value when value <= 0 -> Error (invalid_requested_context_window value)
  | Some requested ->
    let resolved_context_window = min requested final_runtime_context_window in
    Ok
      { requested_context_window
      ; final_runtime_context_window
      ; resolved_context_window
      ; context_window_rebudgeted =
          (match requested_context_window with
           | Some value when value > 0 -> value <> resolved_context_window
           | Some _ | None -> false)
      }
  | None ->
    Ok
      { requested_context_window
      ; final_runtime_context_window
      ; resolved_context_window = final_runtime_context_window
      ; context_window_rebudgeted = false
      }

let runtime_attempt_decision ~idx ~runtime_id =
  `Assoc [ ("idx", `Int idx); ("runtime_id", `String runtime_id) ]

let runtime_failed_decision ~idx ~runtime_id error =
  `Assoc
    [
      ("idx", `Int idx);
      ("runtime_id", `String runtime_id);
      ("error_kind", `String (Oas_compat.error_kind error));
    ]

let lane_retry_checkpoint
    ~is_last
    ~allow_accept_no_progress_retry
    ~resume_checkpoint
    ~checkpoint_after
    error =
  if is_last then
    None
  else if Keeper_turn_driver_try_runtime.accept_no_progress_should_try_next error
  then
    if allow_accept_no_progress_retry
    then
      Some
        (Keeper_turn_driver_try_runtime.checkpoint_for_accept_rejected_retry
           ~resume_checkpoint
           ~checkpoint_after
           error)
    else None
  else
    match Keeper_turn_driver_try_runtime.sdk_error_to_http_error error with
    | Some http_err when Runtime_attempt_fsm.should_try_next http_err ->
      Some checkpoint_after
    | _ -> None

let attempt_runtime_candidates
    ?(allow_accept_no_progress_retry = fun ~runtime_id:_ ~attempt:_ _error ->
      true)
    ~runtime_id ~runtime_id_of
    ~(emit_runtime_manifest :
       ?status:string ->
       ?decision:Yojson.Safe.t ->
       Keeper_runtime_manifest.event_kind ->
       unit) ~run_attempt candidates =
  let rec loop idx resume_checkpoint = function
    | [] ->
      Error
        (Agent_sdk.Error.Internal
           (Printf.sprintf "runtime lane %S exhausted all candidates" runtime_id))
    | candidate :: rest ->
      let is_last = rest = [] in
      let attempt_runtime_id = runtime_id_of candidate in
      emit_runtime_manifest
        ~status:"attempt"
        ~decision:(runtime_attempt_decision ~idx ~runtime_id:attempt_runtime_id)
        Keeper_runtime_manifest.Runtime_routed;
      (match
         run_attempt ?resume_checkpoint ~idx ~runtime_id:attempt_runtime_id candidate
       with
       | Ok value, _checkpoint_after ->
         emit_runtime_manifest
           ~status:"completed"
           ~decision:(runtime_attempt_decision ~idx ~runtime_id:attempt_runtime_id)
           Keeper_runtime_manifest.Runtime_completed;
         Ok value
       | Error error, checkpoint_after ->
         emit_runtime_manifest
           ~status:"failed"
           ~decision:(runtime_failed_decision ~idx ~runtime_id:attempt_runtime_id error)
           Keeper_runtime_manifest.Runtime_failed;
         (match
            let allow_accept_no_progress_retry =
              if
                Keeper_turn_driver_try_runtime.accept_no_progress_should_try_next
                  error
              then
                allow_accept_no_progress_retry
                  ~runtime_id:attempt_runtime_id
                  ~attempt:idx
                  error
              else true
            in
            lane_retry_checkpoint
              ~is_last
              ~allow_accept_no_progress_retry
              ~resume_checkpoint
              ~checkpoint_after
              error
          with
          | Some retry_checkpoint -> loop (idx + 1) retry_checkpoint rest
          | None -> Error error))
  in
  loop 0 None candidates

let elapsed_seconds_since started_at =
  let ns =
    Mtime.Span.to_uint64_ns (Mtime.span started_at (Mtime_clock.now ()))
  in
  Int64.to_float ns /. 1_000_000_000.

let lane_accept_no_progress_retry_slot_available ~turn_start =
  let elapsed_s = Float.max 0.0 (elapsed_seconds_since turn_start) in
  let budget_s =
    Env_config_keeper.KeeperRetryBackoff.degraded_retry_slot_phase_budget_sec
  in
  elapsed_s < budget_s

let log_lane_accept_no_progress_retry_suppressed
    ~keeper_name
    ~runtime_id
    ~attempt
    ~turn_start
    error =
  let elapsed_s = Float.max 0.0 (elapsed_seconds_since turn_start) in
  let budget_s =
    Env_config_keeper.KeeperRetryBackoff.degraded_retry_slot_phase_budget_sec
  in
  Log.Keeper.warn
    "%s: suppressing lane no-progress retry for runtime=%s attempt=%d \
     elapsed=%.3fs budget=%.3fs error=%s"
    keeper_name
    runtime_id
    attempt
    elapsed_s
    budget_s
    (Agent_sdk.Error.to_string error)

let runtime_candidate_missing_error id =
  Agent_sdk.Error.Internal
    (Printf.sprintf
       "keeper_turn_driver: lane candidate %S disappeared from runtimes"
       id)

let resolve_runtime_candidate id =
  match Runtime.get_runtime_by_id id with
  | Some runtime -> Ok runtime
  | None -> Error (runtime_candidate_missing_error id)

let resolve_runtime_candidates ids =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | id :: rest ->
      let* runtime = resolve_runtime_candidate id in
      loop (runtime :: acc) rest
  in
  loop [] ids

let dedupe_runtimes_preserve_order runtimes =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | runtime :: rest ->
      let runtime_id = runtime.Runtime.id in
      if List.exists (String.equal runtime_id) seen then
        loop seen acc rest
      else
        loop (runtime_id :: seen) (runtime :: acc) rest
  in
  loop [] [] runtimes

let lane_modality_reroute_decision ~checkpoint_messages ~initial_messages
    ~goal_blocks ~first_candidate ~remaining_runtimes =
  Runtime_agent.decide_modality_reroute_for_runtime_candidates
    ~assigned:first_candidate
    ~candidates:remaining_runtimes
    ~checkpoint_messages
    ~initial_messages
    goal_blocks

let first_runtime_after_modality_reroute ~keeper_name ~assignment_id
    ~first_candidate_id ~first_candidate = function
  | Runtime_agent.No_reroute_needed | Runtime_agent.No_capable_runtime _ ->
    first_candidate_id, first_candidate
  | Runtime_agent.Reroute { to_runtime_id; reason } ->
    (match Runtime.get_runtime_by_id to_runtime_id with
     | None -> first_candidate_id, first_candidate
     | Some rerouted ->
       Log.Keeper.warn
         "%s: RFC-0265 modality reroute %s -> %s (%s)"
         keeper_name
         assignment_id
         to_runtime_id
         reason;
       to_runtime_id, rerouted)

type attempt_inference_policy =
  { attempt_temperature : float
  ; attempt_enable_thinking : bool option
  ; attempt_preserve_thinking : bool option
  ; attempt_max_tokens : int option
  }

let attempt_inference_policy
    ?max_tokens_for_runtime
    ~runtime_id
    ~fallback_temperature
    ~fallback_enable_thinking
    ~fallback_max_tokens
    ()
  =
  let runtime_seed = Runtime_inference.for_runtime ~name:runtime_id in
  let attempt_temperature =
    Runtime_inference.resolve_temperature
      ~runtime_id
      ~fallback:(fun () -> fallback_temperature)
  in
  let attempt_enable_thinking =
    match runtime_seed.thinking_enabled with
    | Some _ as enabled -> enabled
    | None -> fallback_enable_thinking
  in
  let attempt_max_tokens =
    match max_tokens_for_runtime with
    | Some resolver -> resolver ~runtime_id
    | None -> fallback_max_tokens
  in
  { attempt_temperature
  ; attempt_enable_thinking
  ; attempt_preserve_thinking = runtime_seed.preserve_thinking
  ; attempt_max_tokens
  }

let run_named
    ~runtime_id
    ?(keeper_name = "")
    ~base_path
    ~goal
    ?goal_blocks
    ?priority
    ?session_id
    ?(system_prompt = "")
    ?(tools = [])
    ?(initial_messages = [])
    ?(max_turns = Agent_sdk.Types.default_config.max_turns)
    ~max_idle_turns
    ?stream_idle_timeout_s
    ?body_timeout_s
    ?(temperature = Runtime_provider_defaults.agent_default_temperature)
    (* masc#24067 / oas#2517: no flat-int default. Omitting [?max_tokens]
       means [None] — no request [max_tokens] field, not a synthesized
       fallback. *)
    ?max_tokens
    ?max_tokens_for_runtime
    ?(accept = fun (_ : Agent_sdk_response.api_response) -> true)
    ?guardrails
    ?hooks
    ?context_reducer
    ?raw_trace
    ?on_event
    ?on_yield
    ?on_resume
    ?agent_ref
    ?transport
    ?(allowed_paths = [])
    ?checkpoint_sidecar
    ?(cache_system_prompt = false)
    ?(yield_on_tool = false)
    ?compact_ratio
    ?context_window_tokens
    ?(oas_auto_context_overflow_retry = true)
    ?checkpoint_dir
    ?context_injector
    ?context
    ?enable_thinking
    ?approval
    ?exit_condition
    ?exit_condition_result
    ?summarizer
    ?oas_checkpoint
    ?trace_link
    ?event_bus
    ?on_runtime_observation
    ?runtime_manifest_context
    ?runtime_manifest_append
    ?provider_config_transform
    ?sw
    ?net
    ?per_provider_timeout_s
    ()
  : (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result =
  match require_eio ?sw ?net () with
  | Error e -> Error (eio_context_error_to_sdk_error e)
  | Ok (sw, net) ->
	  (* Lane-aware dispatch: resolve a runtime id or ordered failover lane, then
	     attempt candidates sequentially with manifest evidence per attempt. *)
	  let runtime_id = String.trim runtime_id in
	  let runtime_mcp_policy = runtime_mcp_policy_for_tools ~base_path ~keeper_name tools in
	  (* Audit F8: removed dead routing knobs from the signature so callers cannot
	     pass values that would be silently ignored. *)
  let turn_start = Mtime_clock.now () in
  let seq_ref = ref 0 in
  let emit_runtime_manifest ?status ?decision event =
    match runtime_manifest_context, runtime_manifest_append with
    | Some manifest_ctx, Some append ->
      let decision =
        match decision with
        | None -> Some (`Assoc [])
        | Some (`Assoc _) as d -> d
        | Some other -> Some (`Assoc [ ("decision", other) ])
      in
      seq_ref := !seq_ref + 1;
      let elapsed_ms =
        let ns =
          Mtime.Span.to_uint64_ns
            (Mtime.span turn_start (Mtime_clock.now ()))
        in
        Some (Int64.to_int (Int64.div ns 1_000_000L))
      in
      let decision =
        let decision =
          match decision with
          | Some value -> value
          | None -> `Assoc []
        in
        Some
          (Keeper_runtime_manifest.with_clock_refs
             ~clock_refs:
               (Keeper_runtime_manifest.clock_refs_for_context manifest_ctx
                  ~event ?elapsed_ms ~logical_seq:!seq_ref ())
             decision)
      in
      Keeper_runtime_manifest.make_for_context manifest_ctx ~event
        ~runtime_id ?logical_seq:(Some !seq_ref) ?status ?decision ()
      |> append
    | _ -> ()
  in
  (* Lanes shadow runtimes: a lane id takes precedence over a runtime id so
     operators can route through explicit failover groups. *)
  let lane_resolution = Runtime.resolve_assignment runtime_id in
  let lane_candidate_ids =
    match lane_resolution with
    | `Missing -> []
    | `Single_runtime runtime -> [ runtime.Runtime.id ]
    | `Lane lane -> Runtime_lane.ordered_candidates lane
  in
  if lane_candidate_ids = []
  then
    Error
      (Agent_sdk.Error.Internal
         (Printf.sprintf
            "requested runtime or lane %S not found among configured runtimes"
            runtime_id))
  else
  (* RFC-0265: reroute when active input modality exceeds the first candidate's
     capabilities; later lane candidates remain in declared order. *)
  let current_goal_blocks =
    match goal_blocks with
    | Some blocks -> blocks
    | None ->
      []
  in
  let checkpoint_messages =
    match oas_checkpoint with
    | None -> []
    | Some (checkpoint : Agent_sdk.Checkpoint.t) -> checkpoint.messages
  in
  (* [initial_messages] is the caller's canonical pre-turn history and is the
     exact prefix checked later by replay persistence.  A resumed checkpoint is
     only the OAS dispatch carrier; media degradation may project its messages
     without changing this canonical history. *)
  let canonical_replay_prefix = initial_messages in
  let first_candidate_id, remaining_candidate_ids =
    match lane_candidate_ids with
    | first :: rest -> first, rest
    | [] -> runtime_id, []
  in
  let* first_candidate = resolve_runtime_candidate first_candidate_id in
  let* remaining_runtimes = resolve_runtime_candidates remaining_candidate_ids in
  let reroute_decision =
    lane_modality_reroute_decision
      ~checkpoint_messages
      ~initial_messages
      ~goal_blocks:current_goal_blocks
      ~first_candidate
      ~remaining_runtimes
  in
  let first_runtime_id, first_runtime =
    first_runtime_after_modality_reroute ~keeper_name ~assignment_id:runtime_id
      ~first_candidate_id ~first_candidate reroute_decision
  in
  let attempt_runtimes =
    dedupe_runtimes_preserve_order (first_runtime :: remaining_runtimes)
  in
  let assigned_runtime_context_window =
    Some (Runtime.max_context_of_runtime first_candidate)
  in
  let first_runtime_context_window =
    Runtime.max_context_of_runtime first_runtime
  in
  let* first_context_window_rebudget =
    resolve_context_window_tokens_after_runtime_selection
      ~requested_context_window:context_window_tokens
      ~final_runtime_context_window:first_runtime_context_window
  in
  (match reroute_decision with
   | Runtime_agent.Reroute { reason; _ } ->
     emit_runtime_manifest
       ~status:"rerouted"
       ~decision:
         (Keeper_runtime_manifest.with_payload_role
            ~payload_role:Keeper_runtime_manifest.Operator_evidence
            (`Assoc
              [
                ("routing_action", `String "modality_rerouted");
                ("routing_reason", `String reason);
                ("assigned_runtime_id", `String first_candidate_id);
                ("rerouted_runtime_id", `String first_runtime_id);
                ( "assigned_context_window",
                  match assigned_runtime_context_window with
                  | Some value -> `Int value
                  | None -> `Null );
                ( "requested_context_window",
                  match
                    first_context_window_rebudget.requested_context_window
                  with
                  | Some value -> `Int value
                  | None -> `Null );
                ( "final_runtime_context_window",
                  `Int first_context_window_rebudget.final_runtime_context_window );
                ( "resolved_context_window",
                  `Int first_context_window_rebudget.resolved_context_window );
                ( "context_window_rebudgeted",
                  `Bool first_context_window_rebudget.context_window_rebudgeted );
              ]))
       Keeper_runtime_manifest.Runtime_routed
   | Runtime_agent.No_reroute_needed | Runtime_agent.No_capable_runtime _ -> ());
  (* RFC-0265 follow-up — graceful media degrade floor. When no configured
     runtime can accept the turn's input modality ([No_capable_runtime]), strip
     the unsupported media blocks from the goal, prior [initial_messages], and
     resumed checkpoint, then append a degraded [Runtime_routed] manifest row
     and inject a text notice so the turn runs on text instead of the loud
     terminal reject in [Runtime_agent.run_blocks]. Modality-satisfied turns and
     reroutes are untouched. The drop is non-silent (WARN log + runtime manifest
     row + injected model-input notice — RFC-0126/0145). The stripped checkpoint
     is the dispatch view only; the persisted checkpoint is unchanged, so a
     later vision-capable runtime still sees the original media. *)
  let goal_blocks, initial_messages, oas_checkpoint, replay_prefix_projection =
    match reroute_decision with
    | Runtime_agent.No_capable_runtime _ ->
      let caps = Runtime_agent.input_capabilities_of_runtime first_runtime in
      let stripped_goal, goal_dropped =
        Runtime_agent.strip_unsupported_modality_blocks caps current_goal_blocks
      in
      let stripped_initial, initial_dropped =
        Runtime_agent.strip_unsupported_modality_messages caps initial_messages
      in
      let stripped_checkpoint, checkpoint_dropped =
        match oas_checkpoint with
        | None -> None, []
        | Some (checkpoint : Agent_sdk.Checkpoint.t) ->
          let messages, dropped =
            Runtime_agent.strip_unsupported_modality_messages
              caps
              checkpoint.messages
          in
          Some { checkpoint with messages }, dropped
      in
      let dropped =
        Runtime_agent.merge_modality_counts
          (Runtime_agent.merge_modality_counts goal_dropped initial_dropped)
          checkpoint_dropped
      in
      (match Runtime_agent.media_degrade_note ~runtime_id:first_runtime_id dropped with
       | None ->
         (* Nothing strippable (e.g. only ToolResult-nested media): keep the
            inputs unchanged so the loud capability floor still applies. *)
         goal_blocks, initial_messages, oas_checkpoint, Keeper_replay_prefix.unchanged
       | Some note ->
         Log.Keeper.warn
           "%s: RFC-0265 media degrade on %s — dropped %s, continuing text-only"
           keeper_name
           first_runtime_id
           (modality_counts_summary dropped);
         emit_runtime_manifest
           ~status:"degraded"
           ~decision:(media_degrade_manifest_decision ~runtime_id:first_runtime_id dropped)
           Keeper_runtime_manifest.Runtime_routed;
         let goal_with_note =
           stripped_goal @ [ Agent_sdk.Types.text_block note ]
         in
         let dispatch_prefix =
           match stripped_checkpoint with
           | Some (checkpoint : Agent_sdk.Checkpoint.t) -> checkpoint.messages
           | None -> stripped_initial
         in
         ( Some goal_with_note
         , stripped_initial
         , stripped_checkpoint
         , Keeper_replay_prefix.media_degraded
             ~canonical_prefix:canonical_replay_prefix
             ~dispatch_prefix ))
    | Runtime_agent.No_reroute_needed | Runtime_agent.Reroute _ ->
      goal_blocks, initial_messages, oas_checkpoint, Keeper_replay_prefix.unchanged
  in
  let transport_resolved =
    match transport with
    | Some t -> t
    | None -> Masc_grpc_transport.from_env ()
  in
  (* RFC-0206: execution_idle_timeout is intentionally not forwarded on the
     keeper path until OAS proves active tool execution is excluded from idle
     accounting. Passing [None] keeps the previous behavior without exposing a
     dead compatibility knob. *)
  let execution_idle_timeout_s = None in
  (* Sequential candidate attempt loop. On failure we record a manifest row and
     move to the next candidate; on success we record completion and return. *)
  attempt_runtime_candidates
    ~runtime_id
    ~runtime_id_of:(fun (runtime : Runtime.t) -> runtime.Runtime.id)
    ~emit_runtime_manifest
    ~allow_accept_no_progress_retry:
      (fun ~runtime_id:attempt_runtime_id ~attempt error ->
         if
           not
             (Keeper_turn_driver_try_runtime.accept_no_progress_should_try_next
                error)
         then true
         else if lane_accept_no_progress_retry_slot_available ~turn_start then
           true
         else (
           log_lane_accept_no_progress_retry_suppressed
             ~keeper_name
             ~runtime_id:attempt_runtime_id
             ~attempt
             ~turn_start
             error;
           false))
    ~run_attempt:(fun ?resume_checkpoint ~idx:_ ~runtime_id:attempt_runtime_id runtime ->
      let error_runtime_id = attempt_runtime_id in
      let inference_policy =
        attempt_inference_policy
          ?max_tokens_for_runtime
          ~runtime_id:attempt_runtime_id
          ~fallback_temperature:temperature
          ~fallback_enable_thinking:enable_thinking
          ~fallback_max_tokens:max_tokens
          ()
      in
      let final_runtime_context_window =
        Runtime.max_context_of_runtime runtime
      in
      let context_window_rebudget_res =
        resolve_context_window_tokens_after_runtime_selection
          ~requested_context_window:context_window_tokens
          ~final_runtime_context_window
      in
      match context_window_rebudget_res with
      | Error err -> Error err, None
      | Ok context_window_rebudget ->
      let context_window_tokens = Some context_window_rebudget.resolved_context_window in
      (match
         match provider_config_transform with
         | None -> Ok runtime.Runtime.provider_config
         | Some transform -> transform runtime.Runtime.provider_config
       with
      | Error err -> Error err, None
      | Ok provider_config ->
        let candidate =
          Runtime_candidate.of_provider_config
            ~max_concurrent:runtime.Runtime.binding.max_concurrent
            provider_config
        in
        match provider_cooldown_block ~keeper_name candidate with
        | Some block ->
          emit_runtime_manifest
            ~status:"provider_cooldown"
            ~decision:(provider_cooldown_block_decision block)
            Keeper_runtime_manifest.Provider_attempt_finished;
          ( Error
              (provider_cooldown_block_error
                 ~runtime_id:attempt_runtime_id
                 block)
          , None )
        | None ->
          let name = Printf.sprintf "oas-%s" attempt_runtime_id in
          let try_provider_ctx : Keeper_turn_driver_try_provider.try_provider_ctx =
            { runtime_id = attempt_runtime_id
            ; error_runtime_id
            ; base_path
            ; keeper_name
            ; name
            ; goal
            ; goal_blocks
            ; priority
            ; session_id
            ; system_prompt
            ; tools
            ; initial_messages
            ; max_turns
            ; max_idle_turns
            ; stream_idle_timeout_s
            ; execution_idle_timeout_s
            ; body_timeout_s
            ; temperature = inference_policy.attempt_temperature
            ; max_tokens = inference_policy.attempt_max_tokens
            ; accept
            ; guardrails
            ; hooks
            ; context_reducer
            ; raw_trace
            ; transport_resolved
            ; runtime_mcp_policy
            ; allowed_paths
            ; checkpoint_sidecar
            ; cache_system_prompt
            ; yield_on_tool
            ; compact_ratio
            ; context_window_tokens
            ; oas_auto_context_overflow_retry
            ; checkpoint_dir
            ; context_injector
            ; context
            ; enable_thinking = inference_policy.attempt_enable_thinking
            ; preserve_thinking = inference_policy.attempt_preserve_thinking
            ; approval
            ; exit_condition
            ; exit_condition_result
            ; summarizer
            ; oas_checkpoint
            ; trace_link
            ; sw
            ; net
            ; on_event
            ; on_yield
            ; on_resume
            ; agent_ref
            ; on_runtime_observation
            ; event_bus
            ; runtime_manifest_context
            ; runtime_manifest_append
            ; turn_start
            ; seq_ref
            }
          in
          let provider_attempt_started_at = Mtime_clock.now () in
          let result, checkpoint_after, _success_sample =
            Keeper_turn_driver_try_provider.run_try_provider
              try_provider_ctx ?resume_checkpoint ?per_provider_timeout_s candidate
          in
          let result =
            match result with
            | Error _ as error -> error
            | Ok run_result ->
              (match run_result.Runtime_agent.checkpoint with
               | None -> Ok run_result
               | Some checkpoint ->
                 (match
                    Keeper_replay_prefix.restore_checkpoint
                      replay_prefix_projection
                      checkpoint
                  with
                  | Ok checkpoint ->
                    Ok
                      { run_result with
                        Runtime_agent.checkpoint = Some checkpoint
                      }
                  | Error error ->
                    Error
                       (Agent_sdk.Error.Internal
                          (Keeper_replay_prefix.restore_error_to_string error))))
          in
          let latency_ms =
            let ns =
              Mtime.Span.to_uint64_ns
                (Mtime.span provider_attempt_started_at (Mtime_clock.now ()))
            in
            Int64.to_float ns /. 1_000_000.
          in
          (match result with
           | Ok _ ->
             record_candidate_health_success
               ~keeper_name
               candidate
               ~latency_ms
           | Error err ->
             (match classify_masc_internal_error err with
              | Some (Accept_rejected { reason; _ }) ->
                record_candidate_health_rejected ~keeper_name candidate ~reason
              | Some _ | None ->
                record_candidate_health_error ~keeper_name candidate err));
          result, checkpoint_after))
    attempt_runtimes


module For_testing = struct
  let checkpoint_after_attempt = checkpoint_after_attempt
  let success_selected_model_raw = success_selected_model_raw
  let record_candidate_health_error = record_candidate_health_error
  let provider_cooldown_block = provider_cooldown_block

  let aggregate_cooldown_cause =
    Keeper_turn_driver_provider_attempt.aggregate_cooldown_cause

  let provider_cooldown_block_error = provider_cooldown_block_error
  let apply_accept = Keeper_turn_driver_try_provider.For_testing.apply_accept
  let max_execution_time_for_attempt =
    Keeper_turn_driver_try_provider.For_testing.max_execution_time_for_attempt

  let last_tool_progress_context_string_of_messages messages =
    messages
    |> Keeper_turn_driver_try_provider.For_testing.last_tool_progress_context_of_messages
    |> Keeper_turn_driver_try_provider.For_testing.format_last_tool_progress_context

  let sdk_error_of_nonretryable_attempt_error =
    Keeper_turn_driver_try_runtime.sdk_error_of_nonretryable_attempt_error

  let first_runtime_after_modality_reroute =
    first_runtime_after_modality_reroute

  let lane_modality_reroute_decision = lane_modality_reroute_decision
  let dedupe_runtimes_preserve_order = dedupe_runtimes_preserve_order
	  let media_degrade_manifest_decision = media_degrade_manifest_decision
	  let attempt_inference_policy = attempt_inference_policy
	  let attempt_runtime_candidates = attempt_runtime_candidates

  let resolve_context_window_tokens_after_runtime_selection =
    resolve_context_window_tokens_after_runtime_selection

  let accept_no_progress_should_try_next =
    Keeper_turn_driver_try_runtime.For_testing.accept_no_progress_should_try_next

  let accept_no_progress_read_only_should_try_next =
    Keeper_turn_driver_try_runtime.For_testing
    .accept_no_progress_read_only_should_try_next

  let accept_rejected_result_should_try_next =
    Keeper_turn_driver_try_runtime.For_testing
    .accept_rejected_result_should_try_next

  let runtime_exhaustion_reason_of_http_error =
    Keeper_turn_driver_try_runtime.For_testing
    .runtime_exhaustion_reason_of_http_error

  let sdk_error_of_exhausted =
    Keeper_turn_driver_try_runtime.For_testing.sdk_error_of_exhausted
end
