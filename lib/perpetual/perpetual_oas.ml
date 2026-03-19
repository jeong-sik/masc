(** Perpetual_oas — OAS Agent.t-based perpetual loop.

    Runs the MASC perpetual loop via OAS Agent.t with lifecycle hooks.
    Ties together all OAS integration phases:

    - Phase 1: Context_compact_oas (context reduction)
    - Phase 2: Succession_oas (checkpoint/DNA)
    - Phase 3: Llm_provider_oas (LLM cascade)
    - Phase 4: Verifier_oas (guardrails/hooks)
    - Phase 5: Worker_oas (Agent.run adapter)

    Split into sub-modules:
    - {!Perpetual_oas_state}: mutable state + mutex ops
    - {!Perpetual_oas_hooks}: 4 lifecycle hooks + periodic callback
    - {!Perpetual_oas_build}: OAS Agent.t builder

    @since Phase 6 — OAS Agent adapter for perpetual loop *)

open Printf

module Oas = Agent_sdk

(* ================================================================ *)
(* Run perpetual loop via OAS Agent.run                              *)
(* ================================================================ *)

(** Run the perpetual agent loop using OAS Agent.run.

    Replaces the while-loop in [Perpetual_loop.run] with:
    1. Build Agent.t via builder
    2. Run Agent.run with goal as initial prompt
    3. On handoff: extract DNA via Phase 2, create new Agent via resume
    4. On stop: persist final checkpoint

    Returns [Ok ()] on completion, [Error msg] on early abort.

    @param sw Eio switch for fiber management.
    @param config The perpetual loop configuration.
    @param state The MASC loop state (for initial context and session). *)
let run_perpetual_via_oas
    ~(sw : Eio.Switch.t)
    ~(config : Perpetual_loop.loop_config)
    ~(state : Perpetual_loop.loop_state)
  : (unit, string) result =
  (* Event emitter: record locally, invoke callback, and bridge to OAS Event_bus.
     Cannot use Perpetual_loop.record_event (private). Inline the logic:
     prepend event to state.events, cap at 200 entries. *)
  let record_event (ev : Perpetual_loop.event) =
    let ts = Time_compat.now () in
    state.events <- (ts, ev) :: state.events;
    if List.length state.events > 200 then
      state.events <- List.filteri (fun i _ -> i < 200) state.events
  in
  let emit ev =
    record_event ev;
    config.on_event ev;
    Option.iter (fun bus ->
      (* Bridge selected events to OAS Event_bus *)
      match ev with
      | Perpetual_loop.Heartbeat { turn; context_pct } ->
        Oas_events.publish_heartbeat bus ~agent_name:config.agent_name
          ~turn ~context_pct
      | Perpetual_loop.Error msg ->
        Oas.Event_bus.publish bus
          (Oas.Event_bus.Custom ("masc:perpetual_oas:error",
            `Assoc [("message", `String msg);
                    ("timestamp", `Float (Time_compat.now ()))]))
      | Perpetual_loop.Terminated reason ->
        Oas.Event_bus.publish bus
          (Oas.Event_bus.Custom ("masc:perpetual_oas:terminated",
            `Assoc [("reason", `String reason);
                    ("timestamp", `Float (Time_compat.now ()))]))
      | _ -> ()
    ) config.event_bus
  in
  (* Acquire Eio net — abort early if unavailable *)
  match Eio_context.get_net_opt () with
  | None ->
    eprintf "[perpetual_oas] Eio net not available, cannot run OAS path\n%!";
    emit (Error "Eio net not available for OAS perpetual path");
    state.running <- false;
    Error "Eio net not available for OAS perpetual path"
  | Some net ->
  let trace_id = state.trace_id in
  let pstate = Perpetual_oas_state.create_perpetual_state ~trace_id in
  Perpetual_oas_state.update_state (fun ps ->
    ps.generation <- state.generation) pstate;
  let ctx_ref = ref state.context in
  eprintf "[perpetual_oas] Starting OAS loop: goal=%s, trace=%s, gen=%d\n%!"
    config.initial_goal trace_id pstate.generation;
  (* Build the initial agent — abort early on failure *)
  match
    Perpetual_oas_build.build_perpetual_agent ~config ~pstate ~emit ~ctx_ref ~net
  with
  | Error e ->
    eprintf "[perpetual_oas] Failed to build agent: %s\n%!" e;
    emit (Error (sprintf "OAS agent build failed: %s" e));
    state.running <- false;
    Error (sprintf "OAS agent build failed: %s" e)
  | Ok agent ->
  (* Run agent with goal as initial prompt *)
  let result = Oas.Agent.run ~sw agent config.initial_goal in
  (* Persist checkpoint via Phase 2 adapter *)
  let oas_ckpt = Oas.Agent.checkpoint ~session_id:trace_id agent in
  (try
    let checkpoint_path =
      Filename.concat config.session_base_dir (trace_id ^ ".json")
    in
    Fs_compat.mkdir_p config.session_base_dir;
    Fs_compat.save_file checkpoint_path
      (Oas.Checkpoint.to_string oas_ckpt)
  with exn ->
    eprintf "[perpetual_oas] Checkpoint save failed: %s\n%!"
      (Printexc.to_string exn));
  (* Also save MASC-format checkpoint for cross-compatibility
     (inlined from deleted oas_checkpoint_bridge) *)
  (try
    let ctx = !ctx_ref in
    let oas_ctx = Oas.Context.copy ctx.Context_manager.oas_context in
    Oas.Context.set_scoped oas_ctx Oas.Context.Session
      "goal" (`String config.initial_goal);
    Oas.Context.set_scoped oas_ctx Oas.Context.Session
      "generation" (`Int pstate.generation);
    Oas.Context.set_scoped oas_ctx Oas.Context.Session
      "turn_count" (`Int pstate.turn_count);
    Oas.Context.set_scoped oas_ctx Oas.Context.Session
      "trace_id" (`String trace_id);
    Oas.Context.set_scoped oas_ctx Oas.Context.App
      "masc_version" (`String Version.version);
    let messages = List.filter_map Oas_type_adapters.to_oas_message ctx.messages in
    let masc_oas_ckpt : Oas.Checkpoint.t = {
      version = 3;
      session_id = trace_id;
      agent_name = "perpetual";
      model = "masc-perpetual";
      system_prompt = Some ctx.system_prompt;
      messages;
      usage = {
        Oas.Types.total_input_tokens = pstate.total_tokens;
        total_output_tokens = 0;
        total_cache_creation_input_tokens = 0;
        total_cache_read_input_tokens = 0;
        api_calls = pstate.turn_count;
        estimated_cost_usd = pstate.total_cost;
      };
      turn_count = pstate.turn_count;
      created_at = Time_compat.now ();
      tools = [];
      tool_choice = None;
      temperature = None;
      top_p = None;
      top_k = None;
      min_p = None;
      enable_thinking = None;
      response_format_json = false;
      thinking_budget = None;
      cache_system_prompt = false;
      max_input_tokens = Some ctx.max_tokens;
      max_total_tokens = None;
      disable_parallel_tool_use = false;
      context = oas_ctx;
      mcp_sessions = [];
      working_context = None;
    } in
    let ckpt_path2 =
      Filename.concat config.session_base_dir
        (trace_id ^ "-masc.json")
    in
    Fs_compat.save_file ckpt_path2
      (Oas.Checkpoint.to_string masc_oas_ckpt)
  with exn ->
    eprintf "[perpetual_oas] MASC checkpoint save failed: %s\n%!"
      (Printexc.to_string exn));
  (* Handle handoff: extract DNA, increment generation *)
  if pstate.handoff_triggered then begin
    eprintf "[perpetual_oas] Handoff triggered at gen %d, preparing DNA\n%!"
      pstate.generation;
    let metrics : Succession_oas.succession_metrics = {
      total_turns = pstate.turn_count;
      total_tokens_used = pstate.total_tokens;
      total_cost_usd = pstate.total_cost;
      tasks_completed = 0;
      errors_encountered = 0;
      elapsed_seconds = Time_compat.now () -. state.started_at;
    } in
    (* Extract DNA via Phase 2 adapter *)
    let _dna, dna_ckpt = Succession_oas.extract_dna_via_checkpoint
      ~working_ctx:!ctx_ref
      ~session_ctx:state.session
      ~goal:config.initial_goal
      ~generation:pstate.generation
      ~trace_id
      ~metrics
    in
    (* Persist DNA checkpoint *)
    (try
      let dna_path = Filename.concat config.session_base_dir
        (sprintf "%s-dna-gen%d.json" trace_id pstate.generation)
      in
      Fs_compat.save_file dna_path
        (Oas.Checkpoint.to_string dna_ckpt)
    with exn ->
      eprintf "[perpetual_oas] DNA checkpoint save failed: %s\n%!"
        (Printexc.to_string exn));
    (* Update MASC state for potential successor *)
    state.generation <- pstate.generation + 1;
    emit (Terminated (sprintf "Handoff complete, gen %d -> %d"
      pstate.generation (pstate.generation + 1)))
  end;
  (* Sync mutable state back to MASC loop_state *)
  Perpetual_oas_state.update_state (fun _ps ->
    state.turn_count <- pstate.turn_count;
    state.idle_turns <- pstate.idle_turns;
    state.total_tokens <- pstate.total_tokens;
    state.total_cost <- pstate.total_cost;
    state.compaction_count <- pstate.compaction_count;
    state.running <- false) pstate;
  Oas.Agent.close agent;
  (* Log result *)
  (match result with
  | Ok response ->
    let text = List.filter_map (function
      | Oas.Types.Text s -> Some s
      | _ -> None
    ) response.content |> String.concat "\n" in
    let summary = if String.length text > 200
      then String.sub text 0 200 ^ "..."
      else text
    in
    eprintf "[perpetual_oas] Loop ended: turns=%d, tokens=%d, cost=$%.4f\n%!"
      pstate.turn_count pstate.total_tokens pstate.total_cost;
    eprintf "[perpetual_oas] Final response: %s\n%!" summary
  | Error err ->
    let detail = Oas.Error.to_string err in
    eprintf "[perpetual_oas] Loop ended with error: %s\n%!" detail;
    emit (Error (sprintf "OAS perpetual loop error: %s" detail)));
  Ok ()

(* ================================================================ *)
(* Unified entry point                                               *)
(* ================================================================ *)

(** Run the perpetual loop via OAS Agent.run.
    Wraps {!run_perpetual_via_oas} and logs errors to stderr. *)
let run
    ~(sw : Eio.Switch.t)
    ~(config : Perpetual_loop.loop_config)
    ~(state : Perpetual_loop.loop_state)
  : unit =
  run_perpetual_via_oas ~sw ~config ~state
  |> Result.iter_error (fun e ->
    eprintf "[perpetual_oas] OAS path aborted: %s\n%!" e)
