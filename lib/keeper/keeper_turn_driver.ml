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
    ?(max_tokens = Runtime_provider_defaults.agent_default_max_tokens)
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
  (* Single-runtime dispatch (RFC-0206 runtime purge).  The former named-runtime
     resolution + multi-candidate selection / health / capacity / strategy /
     cycle / admission-rotation machinery is deleted.  There is exactly one
     default Runtime: resolve its provider config, build one execution
     candidate, and run a single provider attempt.  A failed runtime surfaces
     its [sdk_error] directly — there is nothing left to "exhaust". *)
  let runtime_id = String.trim runtime_id in
  let runtime_mcp_policy = runtime_mcp_policy_for_tools ~base_path ~keeper_name tools in
  let runtime_seed = Runtime_inference.for_runtime ~name:runtime_id in
  let enable_thinking =
    match runtime_seed.thinking_enabled with
    | Some enabled -> Some enabled
    | None -> enable_thinking
  in
  let preserve_thinking = runtime_seed.preserve_thinking in
  (* Audit F8: the former [?provider_filter] / [?base_path] /
     [?wait_timeout_sec] parameters only fed the deleted multi-candidate
     machinery and were silently ignored here; they are removed from the
     signature so callers cannot pass dead routing knobs. *)
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
  (* RFC-0207: dispatch to the *requested* runtime (a keeper's persona [model]
     selection or the global default, both produced by [runtime_id_of_meta])
     instead of unconditionally the default.  A requested id that does not
     resolve is a config/validation bug — fail-fast rather than silently
     substituting the default (RFC-0206 §2.1: no Unknown→Permissive fallback). *)
  match Runtime.get_runtime_by_id runtime_id with
  | None ->
    Error
      (Agent_sdk.Error.Internal
         (Printf.sprintf
            "requested runtime %S not found among configured runtimes \
             (no silent fallback to default — RFC-0207/RFC-0206 §2.1)"
            runtime_id))
  | Some assigned_runtime ->
  (* RFC-0265: proactively reroute a turn whose active input modality
     (image/audio/document) the assigned runtime cannot accept to a capable
     configured runtime ([\[runtime\].media_failover] order, else declaration
     order). The active input includes both the current goal and prior
     [initial_messages]; otherwise an image in history can poison the next
     text-only follow-up and leak as a provider 400. Modality-satisfied turns are
     untouched; when no runtime qualifies the assigned runtime stands and the
     loud capability gate in [Runtime_agent.run_blocks] rejects (the floor). The
     reroute is visible via a WARN log (non-silent — RFC-0126/0145). *)
  let current_goal_blocks =
    match goal_blocks with
    | Some blocks -> blocks
    | None ->
      (* A missing current block payload means the current keeper goal is
         text-only; [initial_messages] still participate in reroute below. *)
      []
  in
  let checkpoint_messages =
    match oas_checkpoint with
    | None -> []
    | Some (checkpoint : Agent_sdk.Checkpoint.t) -> checkpoint.messages
  in
  let reroute_decision =
    Runtime_agent.decide_modality_reroute_for_runtime
      ~assigned:assigned_runtime
      ~checkpoint_messages
      ~initial_messages
      current_goal_blocks
  in
  let runtime_id, runtime =
    match reroute_decision with
    | Runtime_agent.No_reroute_needed | Runtime_agent.No_capable_runtime _ ->
      runtime_id, assigned_runtime
    | Runtime_agent.Reroute { to_runtime_id; reason } ->
      (match Runtime.get_runtime_by_id to_runtime_id with
       | None -> runtime_id, assigned_runtime
       | Some rerouted ->
         Log.Keeper.warn
           "%s: RFC-0265 modality reroute %s -> %s (%s)"
           keeper_name
           runtime_id
           to_runtime_id
           reason;
         to_runtime_id, rerouted)
  in
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
  let goal_blocks, initial_messages, oas_checkpoint =
    match reroute_decision with
    | Runtime_agent.No_capable_runtime _ ->
      let caps = Runtime_agent.input_capabilities_of_runtime runtime in
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
      (match Runtime_agent.media_degrade_note ~runtime_id dropped with
       | None ->
         (* Nothing strippable (e.g. only ToolResult-nested media): keep the
            inputs unchanged so the loud capability floor still applies. *)
         goal_blocks, initial_messages, oas_checkpoint
       | Some note ->
         Log.Keeper.warn
           "%s: RFC-0265 media degrade on %s — dropped %s, continuing text-only"
           keeper_name
           runtime_id
           (modality_counts_summary dropped);
         emit_runtime_manifest
           ~status:"degraded"
           ~decision:(media_degrade_manifest_decision ~runtime_id dropped)
           Keeper_runtime_manifest.Runtime_routed;
         let goal_with_note =
           stripped_goal @ [ Agent_sdk.Types.text_block note ]
         in
         Some goal_with_note, stripped_initial, stripped_checkpoint)
    | Runtime_agent.No_reroute_needed | Runtime_agent.Reroute _ ->
      goal_blocks, initial_messages, oas_checkpoint
  in
  let error_runtime_id = runtime_id in
  let* provider_config =
    match provider_config_transform with
    | None -> Ok runtime.Runtime.provider_config
    | Some transform -> transform runtime.Runtime.provider_config
  in
  let candidate =
    Runtime_candidate.of_provider_config
      ~max_concurrent:runtime.Runtime.binding.max_concurrent
      provider_config
  in
  let name = Printf.sprintf "oas-%s" runtime_id in
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
	  let try_provider_ctx : Keeper_turn_driver_try_provider.try_provider_ctx = {
	    runtime_id;
	    error_runtime_id;
	    base_path;
	    keeper_name;
    name;
    goal;
    goal_blocks;
    priority;
    session_id;
    system_prompt;
    tools;
    initial_messages;
    max_turns;
    max_idle_turns;
    stream_idle_timeout_s;
    execution_idle_timeout_s;
    body_timeout_s;
    temperature;
    max_tokens;
    accept;
    guardrails;
    hooks;
    context_reducer;
    raw_trace;
    transport_resolved;
    runtime_mcp_policy;
    allowed_paths;
    checkpoint_sidecar;
    cache_system_prompt;
    yield_on_tool;
    compact_ratio;
    oas_auto_context_overflow_retry;
    checkpoint_dir;
    context_injector;
    context;
    enable_thinking;
    preserve_thinking;
    approval;
    exit_condition;
    exit_condition_result;
    summarizer;
    oas_checkpoint;
    trace_link;
    sw;
    net;
    on_event;
    on_yield;
    on_resume;
    agent_ref;
    on_runtime_observation;
    event_bus;
    runtime_manifest_context;
    runtime_manifest_append;
    turn_start;
    seq_ref;
  } in
  let result, _checkpoint, _success_sample =
    Keeper_turn_driver_try_provider.run_try_provider
      try_provider_ctx ?per_provider_timeout_s candidate
  in
  result


module For_testing = struct
  let checkpoint_after_attempt = checkpoint_after_attempt
  let success_selected_model_raw = success_selected_model_raw
  let record_candidate_health_error = record_candidate_health_error
  let apply_accept = Keeper_turn_driver_try_provider.For_testing.apply_accept
  let max_execution_time_for_attempt =
    Keeper_turn_driver_try_provider.For_testing.max_execution_time_for_attempt

  let last_tool_progress_context_string_of_messages messages =
    messages
    |> Keeper_turn_driver_try_provider.For_testing.last_tool_progress_context_of_messages
    |> Keeper_turn_driver_try_provider.For_testing.format_last_tool_progress_context

  let sdk_error_of_nonretryable_attempt_error =
    Keeper_turn_driver_try_runtime.sdk_error_of_nonretryable_attempt_error

  let media_degrade_manifest_decision = media_degrade_manifest_decision

  let accept_no_progress_should_try_next =
    Keeper_turn_driver_try_runtime.For_testing.accept_no_progress_should_try_next

  let accept_no_progress_read_only_should_try_next =
    Keeper_turn_driver_try_runtime.For_testing
    .accept_no_progress_read_only_should_try_next

  let accept_rejected_result_should_try_next =
    Keeper_turn_driver_try_runtime.For_testing
    .accept_rejected_result_should_try_next
end
