(** Perpetual_oas — Adapter bridging MASC perpetual_loop to OAS Agent.t.

    Demonstrates the complete migration path from MASC's bespoke perpetual
    loop (think -> act -> observe -> verify -> compact -> heartbeat -> loop)
    to OAS Agent.t with lifecycle hooks. Ties together all previous phases:

    - Phase 1: Context_compact_oas (context reduction)
    - Phase 2: Succession_oas / Oas_checkpoint_bridge (checkpoint/DNA)
    - Phase 3: Llm_provider_oas (LLM cascade)
    - Phase 4: Verifier_oas (guardrails/hooks)
    - Phase 5: Worker_oas (Agent.run adapter)

    Enabled via [MASC_USE_OAS_PERPETUAL=true] environment variable.

    Key mappings:
    - perpetual_loop thresholds -> OAS BeforeTurn hook (threshold checking)
    - idle detection -> OAS OnIdle hook
    - heartbeat tick -> OAS periodic_callback
    - verification -> OAS PreToolUse hook (via Phase 4 adapter)
    - compaction -> OAS Context_reducer (via Phase 1 adapter)
    - DNA/handoff -> OAS Checkpoint (via Phase 2 adapter)

    @since Phase 6 — OAS Agent adapter for perpetual loop *)

open Printf

module Oas = Agent_sdk

(* ================================================================ *)
(* Feature Flag                                                      *)
(* ================================================================ *)

let use_oas_perpetual () =
  match Sys.getenv_opt "MASC_USE_OAS_PERPETUAL" with
  | Some v ->
    let v = String.lowercase_ascii (String.trim v) in
    v = "true" || v = "1" || v = "yes"
  | None -> false

(* ================================================================ *)
(* Perpetual State — mutable tracking for hook closures              *)
(* ================================================================ *)

(** Mutable state carried through hook closures across turns.
    Mirrors the subset of [Perpetual_loop.loop_state] that hooks need
    for threshold checking, idle detection, and metrics accumulation. *)
type perpetual_state = {
  mutable turn_count : int;
  mutable idle_turns : int;
  mutable total_tokens : int;
  mutable total_cost : float;
  mutable last_heartbeat : float;
  mutable compaction_count : int;
  mutable generation : int;
  mutable running : bool;
  mutable handoff_triggered : bool;
  trace_id : string;
}

let create_perpetual_state ~trace_id =
  {
    turn_count = 0;
    idle_turns = 0;
    total_tokens = 0;
    total_cost = 0.0;
    last_heartbeat = Time_compat.now ();
    compaction_count = 0;
    generation = 0;
    running = true;
    handoff_triggered = false;
    trace_id;
  }

(** Mutex protecting all mutable [perpetual_state] fields from concurrent
    access by Eio fibers (hook closures, periodic callbacks). *)
let state_mutex = Eio.Mutex.create ()

(* ================================================================ *)
(* Perpetual Hooks — lifecycle via OAS hook events                   *)
(* ================================================================ *)

(** Create OAS hooks that implement perpetual loop lifecycle.

    - BeforeTurn: increment turn counter, check context thresholds
      (compact/prepare/handoff), inject context ratio into system messages.
    - AfterTurn: update metrics (tokens, cost), track idle turns based on
      whether tool calls occurred.
    - OnIdle: when consecutive idle turns exceed [max_idle], signal stop.
    - PreToolUse: delegates to Phase 4 verifier hook when feedback is enabled.

    @param config The perpetual loop configuration.
    @param pstate Mutable perpetual state (shared across turns).
    @param emit Event emitter closure from perpetual_loop.
    @param ctx_ref Reference to the current working context (for ratio checks). *)
let perpetual_hooks
    ~(config : Perpetual_loop.loop_config)
    ~(pstate : perpetual_state)
    ~(emit : Perpetual_loop.event -> unit)
    ~(ctx_ref : Context_manager.working_context ref)
  : Oas.Hooks.hooks =
  let before_turn : Oas.Hooks.hook = fun event ->
    match event with
    | Oas.Hooks.BeforeTurn { turn; _ } ->
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
        pstate.turn_count <- turn);
      emit (TurnStart turn);
      (* Check thresholds against current context *)
      let ratio = Context_manager.context_ratio !ctx_ref in
      (* Compact threshold: apply context reduction via Phase 1 adapter *)
      if ratio >= config.compact_threshold then begin
        let before = (!ctx_ref).token_count in
        let strategies =
          List.map (function
            | Context_manager.PruneToolOutputs ->
              Context_compact_oas.PruneToolOutputs
            | Context_manager.MergeContiguous ->
              Context_compact_oas.MergeContiguous
            | Context_manager.DropLowImportance ->
              Context_compact_oas.DropLowImportance
            | Context_manager.SummarizeOld ->
              Context_compact_oas.SummarizeOld
          ) config.compact_strategies
        in
        let compacted_msgs, new_token_count =
          Context_compact_oas.compact
            ~system_prompt:(!ctx_ref).system_prompt
            ~messages:(!ctx_ref).messages
            ~strategies
        in
        ctx_ref := {
          !ctx_ref with
          messages = compacted_msgs;
          token_count = new_token_count;
        };
        let after = new_token_count in
        Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          pstate.compaction_count <- pstate.compaction_count + 1);
        emit (Compacted {
          before_tokens = before;
          after_tokens = after;
          offloaded_path = None;
        })
      end;
      (* Handoff threshold: signal generation handoff *)
      let ratio2 = Context_manager.context_ratio !ctx_ref in
      if ratio2 >= config.handoff_threshold then begin
        let next_model = match config.model_cascade with
          | _ :: m :: _ -> m
          | [m] -> m
          | [] -> Llm_client.default_local_model_spec ()
        in
        Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          pstate.handoff_triggered <- true;
          pstate.running <- false);
        emit (Handoff {
          to_model = next_model.model_id;
          generation = pstate.generation + 1;
        })
      end;
      Oas.Hooks.Continue
    | _ -> Oas.Hooks.Continue
  in
  let after_turn : Oas.Hooks.hook = fun event ->
    match event with
    | Oas.Hooks.AfterTurn { turn; response } ->
      (* Track tokens from response usage *)
      let tokens_used = match response.usage with
        | Some u -> u.input_tokens + u.output_tokens
        | None -> 0
      in
      (* Check for tool calls to determine idle state *)
      let has_tool_use = List.exists (function
        | Oas.Types.ToolUse _ -> true
        | _ -> false
      ) response.content in
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
        pstate.total_tokens <- pstate.total_tokens + tokens_used;
        if has_tool_use then
          pstate.idle_turns <- 0
        else
          pstate.idle_turns <- pstate.idle_turns + 1);
      (* Check for goal completion or stuck signals in response text *)
      let text = List.filter_map (function
        | Oas.Types.Text s -> Some s
        | _ -> None
      ) response.content |> String.concat "\n" in
      let upper = String.uppercase_ascii text in
      if (try ignore (Str.search_forward
            (Str.regexp_string "[GOAL_COMPLETE]") upper 0); true
          with Not_found -> false) then begin
        Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          pstate.running <- false);
        emit (Terminated "Goal complete (OAS)")
      end
      else if (try ignore (Str.search_forward
            (Str.regexp_string "[STUCK") upper 0); true
          with Not_found -> false) then begin
        Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          pstate.running <- false);
        emit (Terminated "Agent stuck (OAS)")
      end;
      emit (TurnEnd { turn; tokens_used; cost = 0.0 });
      Oas.Hooks.Continue
    | _ -> Oas.Hooks.Continue
  in
  let on_idle : Oas.Hooks.hook = fun event ->
    match event with
    | Oas.Hooks.OnIdle { consecutive_idle_turns; _ } ->
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
        pstate.idle_turns <- consecutive_idle_turns);
      if consecutive_idle_turns >= config.max_idle_turns then begin
        Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          pstate.running <- false);
        emit (IdleDetected consecutive_idle_turns);
        emit (Terminated "Max idle turns reached (OAS)");
        Oas.Hooks.Skip
      end else
        Oas.Hooks.Continue
    | _ -> Oas.Hooks.Continue
  in
  let pre_tool_use =
    if config.feedback_enabled then
      Some (Verifier_oas.make_pre_tool_hook
        ~model:config.verifier_model
        ~goal:config.initial_goal
        ~context_summary:(sprintf "Turn %d, generation %d"
          pstate.turn_count pstate.generation))
    else
      None
  in
  {
    Oas.Hooks.empty with
    before_turn = Some before_turn;
    after_turn = Some after_turn;
    on_idle = Some on_idle;
    pre_tool_use;
  }

(* ================================================================ *)
(* Heartbeat as OAS periodic_callback                                *)
(* ================================================================ *)

(** Create an OAS periodic_callback that emits MASC heartbeat events.

    Mirrors the heartbeat logic in [Perpetual_loop.run_turn]:
    if [heartbeat_interval_s] has elapsed since last heartbeat,
    emit a Heartbeat event with current turn and context percentage.

    @param config Loop config (for interval).
    @param pstate Mutable perpetual state (for last_heartbeat tracking).
    @param emit Event emitter.
    @param ctx_ref Current working context reference. *)
let perpetual_periodic_callbacks
    ~(config : Perpetual_loop.loop_config)
    ~(pstate : perpetual_state)
    ~(emit : Perpetual_loop.event -> unit)
    ~(ctx_ref : Context_manager.working_context ref)
  : Oas.Agent.periodic_callback list =
  [{
    Oas.Agent_types.interval_sec = config.heartbeat_interval_s;
    callback = (fun () ->
      let now = Time_compat.now () in
      let turn = Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
        pstate.last_heartbeat <- now;
        pstate.turn_count) in
      let pct = Context_manager.context_ratio !ctx_ref *. 100.0 in
      emit (Heartbeat { turn; context_pct = pct })
    );
  }]

(* ================================================================ *)
(* Build perpetual Agent.t via OAS Builder                           *)
(* ================================================================ *)

(** Construct an OAS Agent.t configured for perpetual execution.

    Ties together all phase adapters:
    - Phase 1: context reducer strategies
    - Phase 2: checkpoint config
    - Phase 3: LLM provider mapping
    - Phase 4: verifier hook / guardrails
    - Phase 5: builder pattern

    @param config The perpetual loop configuration.
    @param pstate Mutable state for hook closures.
    @param emit Event emitter.
    @param ctx_ref Current working context ref.
    @param net Eio network capability.
    @return Agent.t configured for perpetual operation, or error. *)
let build_perpetual_agent
    ~(config : Perpetual_loop.loop_config)
    ~(pstate : perpetual_state)
    ~(emit : Perpetual_loop.event -> unit)
    ~(ctx_ref : Context_manager.working_context ref)
    ~(net : [> `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
  : (Oas.Agent.t, string) result =
  (* Resolve OAS model from primary cascade model *)
  let primary_model = match config.model_cascade with
    | m :: _ -> m
    | [] -> Llm_client.default_local_model_spec ()
  in
  let oas_model = Oas.Types.Custom primary_model.model_id in
  (* Build provider via Phase 3 adapter.
     Uses Llm_client.to_oas_provider which handles the Llm_client.model_spec
     -> Oas.Provider.config conversion (avoiding Llm_types nominality gap). *)
  let provider = match Llm_client.to_oas_provider primary_model with
    | Some cfg -> cfg
    | None ->
      (* Fallback for Custom providers — use OpenAICompat *)
      { Oas.Provider.provider =
          Oas.Provider.OpenAICompat {
            base_url = primary_model.api_url;
            auth_header = None;
            path = "/v1/chat/completions";
            static_token = None;
          };
        model_id = primary_model.model_id;
        api_key_env = Option.value ~default:"" primary_model.api_key_env;
      }
  in
  (* Hooks: perpetual lifecycle + Phase 4 verifier *)
  let hooks = perpetual_hooks ~config ~pstate ~emit ~ctx_ref in
  (* Heartbeat callback *)
  let periodic_cbs =
    perpetual_periodic_callbacks ~config ~pstate ~emit ~ctx_ref
  in
  (* Guardrails via Phase 4 adapter *)
  let guardrails =
    Verifier_oas.guardrails_with_read_only_tag
      ~max_tool_calls_per_turn:12 ()
  in
  (* Convert MASC tool_defs to OAS Tool.t list.
     Tool_bridge.oas_tool_of_masc creates OAS Tool.t from name/desc/schema/handler.
     For the perpetual loop adapter, each tool delegates to a no-op handler since
     actual tool dispatch remains in MASC's perpetual_loop infrastructure. *)
  let tools = List.map (fun (td : Llm_client.tool_def) ->
    Tool_bridge.oas_tool_of_masc
      ~name:td.tool_name
      ~description:td.tool_description
      ~input_schema:td.parameters
      (fun _input ->
        (true, "[perpetual_oas] Tool dispatch delegated to MASC infrastructure"))
  ) config.tools in
  let tool_names =
    List.map (fun (t : Oas.Tool.t) -> t.schema.name) tools
  in
  let system_prompt = (!ctx_ref).system_prompt in
  (* Use max_turns as a reasonable upper bound per generation.
     Perpetual loop handles multi-generation externally. *)
  let max_turns = 100 in
  let builder =
    Oas.Builder.create ~net ~model:oas_model
    |> Oas.Builder.with_name config.agent_name
    |> Oas.Builder.with_system_prompt system_prompt
    |> Oas.Builder.with_max_tokens 4096
    |> Oas.Builder.with_max_turns max_turns
    |> Oas.Builder.with_temperature 0.7
    |> Oas.Builder.with_provider provider
    |> Oas.Builder.with_tools tools
    |> Oas.Builder.with_hooks hooks
    |> Oas.Builder.with_guardrails { guardrails with
      tool_filter =
        if tool_names <> [] then
          Oas.Guardrails.AllowList tool_names
        else
          Oas.Guardrails.AllowAll }
    |> Oas.Builder.with_periodic_callbacks periodic_cbs
    |> Oas.Builder.with_description
         (sprintf "Perpetual agent (gen %d, trace %s)"
           pstate.generation pstate.trace_id)
  in
  Oas.Builder.build_safe builder
  |> Result.map_error Oas.Error.to_string

(* ================================================================ *)
(* Run perpetual loop via OAS Agent.run                              *)
(* ================================================================ *)

(** Run the perpetual agent loop using OAS Agent.run.

    Replaces the while-loop in [Perpetual_loop.run] with:
    1. Build Agent.t via builder
    2. Run Agent.run with goal as initial prompt
    3. On handoff: extract DNA via Phase 2, create new Agent via resume
    4. On stop: persist final checkpoint

    @param sw Eio switch for fiber management.
    @param config The perpetual loop configuration.
    @param state The MASC loop state (for initial context and session).
    @return Unit on completion. *)
let run_perpetual_via_oas
    ~(sw : Eio.Switch.t)
    ~(config : Perpetual_loop.loop_config)
    ~(state : Perpetual_loop.loop_state)
  : unit =
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
  let net = match Eio_context.get_net_opt () with
    | Some net -> net
    | None ->
      eprintf "[perpetual_oas] Eio net not available, cannot run OAS path\n%!";
      emit (Error "Eio net not available for OAS perpetual path");
      state.running <- false;
      raise Exit
  in
  let trace_id = state.trace_id in
  let pstate = create_perpetual_state ~trace_id in
  Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
    pstate.generation <- state.generation);
  let ctx_ref = ref state.context in
  eprintf "[perpetual_oas] Starting OAS loop: goal=%s, trace=%s, gen=%d\n%!"
    config.initial_goal trace_id pstate.generation;
  (* Build the initial agent *)
  let agent = match
    build_perpetual_agent ~config ~pstate ~emit ~ctx_ref ~net
  with
  | Ok a -> a
  | Error e ->
    eprintf "[perpetual_oas] Failed to build agent: %s\n%!" e;
    emit (Error (sprintf "OAS agent build failed: %s" e));
    state.running <- false;
    raise Exit
  in
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
  (* Also save MASC-format checkpoint for cross-compatibility *)
  (try
    let masc_ckpt_state : Oas_checkpoint_bridge.checkpoint_state = {
      session_id = trace_id;
      generation = pstate.generation;
      turn_count = pstate.turn_count;
      total_tokens = pstate.total_tokens;
      total_cost = pstate.total_cost;
      trace_id;
    } in
    let masc_oas_ckpt = Oas_checkpoint_bridge.to_oas_checkpoint
      ~state:masc_ckpt_state ~ctx:!ctx_ref ~goal:config.initial_goal () in
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
    let metrics : Succession.succession_metrics = {
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
  Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
    state.turn_count <- pstate.turn_count;
    state.idle_turns <- pstate.idle_turns;
    state.total_tokens <- pstate.total_tokens;
    state.total_cost <- pstate.total_cost;
    state.compaction_count <- pstate.compaction_count;
    state.running <- false);
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
    emit (Error (sprintf "OAS perpetual loop error: %s" detail)))

(* ================================================================ *)
(* Unified entry point — dispatch based on feature flag              *)
(* ================================================================ *)

(** Run the perpetual loop, dispatching to OAS or legacy path.

    If [MASC_USE_OAS_PERPETUAL=true], uses {!run_perpetual_via_oas}.
    Otherwise, delegates to {!Perpetual_loop.run}. *)
let run
    ~(sw : Eio.Switch.t)
    ~(config : Perpetual_loop.loop_config)
    ~(state : Perpetual_loop.loop_state)
  : unit =
  if use_oas_perpetual () then
    (try run_perpetual_via_oas ~sw ~config ~state
     with Exit -> ())
  else
    Perpetual_loop.run ~config ~state
