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
let run_named
    ~runtime_id
    ?(keeper_name = "")
    ~goal
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
  let error_runtime_id = runtime_id in
  let runtime_mcp_policy = runtime_mcp_policy_for_tools ~keeper_name tools in
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
  | Some runtime ->
  let candidate =
    Runtime_candidate.of_provider_config
      ~max_concurrent:runtime.Runtime.binding.max_concurrent
      runtime.Runtime.provider_config
  in
  let name = Printf.sprintf "oas-%s" runtime_id in
  let transport_resolved =
    match transport with
    | Some t -> t
    | None -> Masc_grpc_transport.from_env ()
  in
  let turn_start = Mtime_clock.now () in
  let seq_ref = ref 0 in
  (* RFC-0206: execution_idle_timeout is intentionally not forwarded on the
     keeper path until OAS proves active tool execution is excluded from idle
     accounting. Passing [None] keeps the previous behavior without exposing a
     dead compatibility knob. *)
  let execution_idle_timeout_s = None in
  let try_provider_ctx : Keeper_turn_driver_try_provider.try_provider_ctx = {
    runtime_id;
    error_runtime_id;
    keeper_name;
    name;
    goal;
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
  let apply_accept = Keeper_turn_driver_try_provider.For_testing.apply_accept
  let last_tool_progress_context_string_of_messages messages =
    messages
    |> Keeper_turn_driver_try_provider.For_testing.last_tool_progress_context_of_messages
    |> Keeper_turn_driver_try_provider.For_testing.format_last_tool_progress_context

  let sdk_error_of_nonretryable_attempt_error =
    Keeper_turn_driver_try_runtime.sdk_error_of_nonretryable_attempt_error
end
