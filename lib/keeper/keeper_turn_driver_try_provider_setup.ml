(** Keeper_turn_driver_try_provider_setup — context record and helper
    functions extracted from [Keeper_turn_driver_try_provider] (570 LoC).
    @since Keeper 500-line decomposition *)

(** Explicit context record for the extracted [try_provider] function.

    Each field corresponds to a variable captured by the original closure.
    Fields are grouped by role: cascade identity, agent config, transport,
    session/checkpoint, Eio primitives, callbacks, and event bus. *)
type try_provider_ctx =
  { (* Cascade identity *)
    cascade_name : string
  ; error_cascade_name : Cascade_name.t
  ; keeper_name : string
  ; name : string
  ; (* Agent config — fields passed through the runtime candidate boundary. *)
    goal : string
  ; require_tool_choice_support : bool
  ; require_tool_support : bool
  ; priority : Llm_provider.Request_priority.t option
  ; session_id : string option
  ; system_prompt : string
  ; tools : Agent_sdk.Tool.t list
  ; initial_messages : Agent_sdk.Types.message list
  ; max_turns : int
  ; max_idle_turns : int
  ; stream_idle_timeout_s : float option
  ; temperature : float
  ; max_tokens : int
  ; max_input_tokens : int option
  ; max_cost_usd : float option
  ; guardrails : Agent_sdk.Guardrails.t option
  ; hooks : Agent_sdk.Hooks.hooks option
  ; context_reducer : Agent_sdk.Context_reducer.t option
  ; memory : Agent_sdk.Memory.t option
  ; tool_retry_policy : Agent_sdk.Tool_retry_policy.t option
  ; required_tool_satisfaction : Agent_sdk.Completion_contract.required_tool_satisfaction
  ; raw_trace : Agent_sdk.Raw_trace.t option
  ; (* Transport *)
    transport_resolved : Masc_grpc_transport.t
  ; cli_transport_overrides : Cascade_runner.cli_transport_overrides option
  ; runtime_mcp_policy : Llm_provider.Llm_transport.runtime_mcp_policy option
  ; (* Session / checkpoint *)
    allowed_paths : string list
  ; checkpoint_sidecar : Yojson.Safe.t option
  ; cache_system_prompt : bool
  ; yield_on_tool : bool
  ; compact_ratio : float option
  ; oas_auto_context_overflow_retry : bool
  ; checkpoint_dir : string option
  ; context_injector : Agent_sdk.Hooks.context_injector option
  ; context : Agent_sdk.Context.t option
  ; slot_id : int option
  ; enable_thinking : bool option
  ; approval : Agent_sdk.Hooks.approval_callback option
  ; exit_condition : (int -> bool) option
  ; exit_condition_result : (int -> Cascade_runner.stop_reason * string option) option
  ; summarizer : (Agent_sdk.Types.message list -> string) option
  ; oas_checkpoint : Agent_sdk.Checkpoint.t option
  ; contract : Masc_mcp_cdal_runtime.Risk_contract.t option
  ; (* Eio concurrency *)
    sw : Eio.Switch.t
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  ; (* Callbacks *)
    on_event : (Agent_sdk.Types.sse_event -> unit) option
  ; on_yield : (unit -> unit) option
  ; on_resume : (unit -> unit) option
  ; agent_ref : Agent_sdk.Agent.t option ref option
  ; proof_ref : Masc_mcp_cdal_runtime.Cdal_proof.t option ref option
  ; (* Event bus *)
    event_bus : Agent_sdk.Event_bus.t option
  ; cascade_engine : Keeper_cascade_engine.t
  ; runtime_manifest_context : Keeper_runtime_manifest.turn_context option
  ; runtime_manifest_append : (Keeper_runtime_manifest.t -> unit) option
  ; runtime_manifest_required_tool_names : string list
  ; turn_start : Mtime.t
  ; seq_ref : int ref
  }

let emit_runtime_manifest
      (ctx : try_provider_ctx)
      ?status
      ?decision
      event
  =
  match ctx.runtime_manifest_context, ctx.runtime_manifest_append with
  | Some manifest_ctx, Some append ->
    let decision =
      match decision with
      | None -> Some (`Assoc (Keeper_cascade_engine.manifest_fields ctx.cascade_engine))
      | Some (`Assoc fields) ->
          Some
            (`Assoc
              (Keeper_cascade_engine.manifest_fields ctx.cascade_engine @ fields))
      | Some other ->
          Some
            (`Assoc
              (Keeper_cascade_engine.manifest_fields ctx.cascade_engine
               @ [ ("decision", other) ]))
    in
    ctx.seq_ref := !(ctx.seq_ref) + 1;
    let elapsed_ms =
      let ns =
        Mtime.Span.to_uint64_ns
          (Mtime.span ctx.turn_start (Mtime_clock.now ()))
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
             (Keeper_runtime_manifest.clock_refs_for_context manifest_ctx ~event
                ?elapsed_ms ~logical_seq:!(ctx.seq_ref) ())
           decision)
    in
    Keeper_runtime_manifest.make_for_context manifest_ctx ~event
      ~cascade_name:ctx.cascade_name ?logical_seq:(Some !(ctx.seq_ref))
      ?status ?decision ()
    |> append
  | _ -> ()

let sanitize_runtime_mcp_external_tool_choice
      ~runtime_mcp_external_tools
      (params : Agent_sdk.Hooks.turn_params)
  =
  if not runtime_mcp_external_tools then params
  else
    match params.tool_choice with
    | Some (Agent_sdk.Types.Any | Agent_sdk.Types.Tool _) ->
      { params with tool_choice = Some Agent_sdk.Types.Auto }
    | Some (Agent_sdk.Types.Auto | Agent_sdk.Types.None_) | None -> params

let sanitize_runtime_mcp_external_tool_decision
      ~runtime_mcp_external_tools
      (decision : Agent_sdk.Hooks.hook_decision)
  =
  match decision with
  | Agent_sdk.Hooks.AdjustParams params ->
    Agent_sdk.Hooks.AdjustParams
      (sanitize_runtime_mcp_external_tool_choice
         ~runtime_mcp_external_tools
         params)
  | _ -> decision

let wrap_runtime_mcp_external_tool_hooks
      ~runtime_mcp_external_tools
      (hooks : Agent_sdk.Hooks.hooks option)
  =
  match hooks, runtime_mcp_external_tools with
  | None, _ | Some _, false -> hooks
  | Some hooks, true ->
    let before_turn_params =
      Option.map
        (fun hook event ->
           hook event
           |> sanitize_runtime_mcp_external_tool_decision
                ~runtime_mcp_external_tools:true)
        hooks.before_turn_params
    in
    Some { hooks with before_turn_params }

let max_execution_time_for_attempt ?per_provider_timeout_s () =
  match per_provider_timeout_s with
  | Some timeout_s -> Some timeout_s
  | None -> Some (Keeper_runtime_resolved.oas_call_timeout_sec ())
