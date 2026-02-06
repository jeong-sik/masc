(** Perpetual_loop — Autonomous agent loop with infinite context.

    Implements the core think → act → observe → verify → compact → heartbeat
    cycle.  Each turn:

    1. Build prompt from working context + system prompt
    2. Call LLM (cascade if primary fails)
    3. Parse response: tool calls or text
    4. If feedback enabled: verify action with cheap model
    5. Update context (add messages, recalculate tokens)
    6. Compact if context > threshold
    7. Prepare DNA if context > prepare_threshold
    8. Handoff to successor if context > handoff_threshold
    9. Heartbeat if interval elapsed
    10. Check idle detection

    @since 2.61.0 *)

open Printf

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type event =
  | TurnStart of int
  | TurnEnd of { turn : int; tokens_used : int; cost : float }
  | Compacted of { before_tokens : int; after_tokens : int }
  | Prepared of { dna_size : int }
  | Handoff of { to_model : string; generation : int }
  | Verified of { action : string; verdict : string }
  | Heartbeat of { turn : int; context_pct : float }
  | Error of string
  | IdleDetected of int
  | Terminated of string

type loop_config = {
  initial_goal : string;
  model_cascade : Llm_client.model_spec list;
  tools : Llm_client.tool_def list;
  heartbeat_interval_s : float;
  max_idle_turns : int;
  feedback_enabled : bool;
  verifier_model : Llm_client.model_spec;
  compact_threshold : float;
  prepare_threshold : float;
  handoff_threshold : float;
  compact_strategies : Context_manager.compaction_strategy list;
  session_base_dir : string;
  on_event : event -> unit;
}

type loop_state = {
  mutable context : Context_manager.working_context;
  mutable session : Context_manager.session_context;
  mutable generation : int;
  mutable turn_count : int;
  mutable idle_turns : int;
  mutable total_cost : float;
  mutable total_tokens : int;
  mutable last_heartbeat : float;
  mutable running : bool;
  trace_id : string;
}

(* ================================================================ *)
(* Defaults                                                         *)
(* ================================================================ *)

let default_config ~goal ~models ?verifier ?session_dir () =
  let me_root = Sys.getenv_opt "ME_ROOT"
                |> Option.value ~default:"/Users/dancer/me" in
  let verifier_model = match verifier with
    | Some v -> v
    | None -> Llm_client.ollama_lfm  (* Cheapest available *)
  in
  let session_base = match session_dir with
    | Some d -> d
    | None -> Filename.concat me_root ".masc/perpetual"
  in
  {
    initial_goal = goal;
    model_cascade = models;
    tools = [];
    heartbeat_interval_s = 30.0;
    max_idle_turns = 5;
    feedback_enabled = true;
    verifier_model;
    compact_threshold = 0.5;
    prepare_threshold = 0.7;
    handoff_threshold = 0.85;
    compact_strategies = Context_manager.[
      PruneToolOutputs; MergeContiguous; DropLowImportance; SummarizeOld
    ];
    session_base_dir = session_base;
    on_event = (fun _ -> ());  (* No-op default *)
  }

(* ================================================================ *)
(* State Management                                                 *)
(* ================================================================ *)

let generate_trace_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let rnd = Random.int 99999 in
  sprintf "trace-%d-%05d" ts rnd

let create_state config =
  let system_prompt = sprintf
    "You are a perpetual agent. Your goal: %s\n\
     You have tools available. Use them to accomplish your goal.\n\
     When you complete the goal, respond with [GOAL_COMPLETE].\n\
     If you get stuck, respond with [STUCK: reason]."
    config.initial_goal in
  let primary_model = match config.model_cascade with
    | m :: _ -> m
    | [] -> Llm_client.ollama_glm
  in
  let context = Context_manager.create
    ~system_prompt
    ~max_tokens:primary_model.max_context in
  let trace_id = generate_trace_id () in
  let session = Context_manager.create_session
    ~session_id:trace_id
    ~base_dir:config.session_base_dir in
  {
    context;
    session;
    generation = 0;
    turn_count = 0;
    idle_turns = 0;
    total_cost = 0.0;
    total_tokens = 0;
    last_heartbeat = Time_compat.now ();
    running = true;
    trace_id;
  }

(* ================================================================ *)
(* LLM Call with Cascade                                            *)
(* ================================================================ *)

(** Build completion requests for all models in cascade. *)
let build_requests (config : loop_config) (state : loop_state) =
  let tools = config.tools in
  List.map (fun model ->
    let msgs = (Llm_client.system_msg state.context.system_prompt)
               :: state.context.messages in
    ({
      Llm_client.model;
      messages = msgs;
      temperature = 0.7;
      max_tokens = 4096;
      tools;
      response_format = `Text;
    } : Llm_client.completion_request)
  ) config.model_cascade

(* ================================================================ *)
(* Response Analysis                                                *)
(* ================================================================ *)

(** Check if response indicates goal completion. *)
let is_goal_complete content =
  let upper = String.uppercase_ascii content in
  try
    let _ = Str.search_forward (Str.regexp_string "[GOAL_COMPLETE]") upper 0 in
    true
  with Not_found -> false

(** Check if response indicates the agent is stuck. *)
let is_stuck content =
  let upper = String.uppercase_ascii content in
  try
    let _ = Str.search_forward (Str.regexp_string "[STUCK") upper 0 in
    true
  with Not_found -> false

(** Calculate cost from token usage and model spec. *)
let calculate_cost (usage : Llm_client.token_usage) (model : Llm_client.model_spec) =
  let input_cost = float_of_int usage.input_tokens *. model.cost_per_1k_input /. 1000.0 in
  let output_cost = float_of_int usage.output_tokens *. model.cost_per_1k_output /. 1000.0 in
  input_cost +. output_cost

(* ================================================================ *)
(* Single Turn Execution                                            *)
(* ================================================================ *)

let run_turn ~config ~state =
  if not state.running then false
  else begin
    state.turn_count <- state.turn_count + 1;
    let turn = state.turn_count in
    config.on_event (TurnStart turn);

    (* 1. THINK + ACT: Call LLM *)
    let requests = build_requests config state in
    let result = Llm_client.cascade requests in

    match result with
    | Error e ->
      config.on_event (Error (sprintf "Turn %d: LLM call failed: %s" turn e));
      state.idle_turns <- state.idle_turns + 1;
      (* Check idle threshold *)
      if state.idle_turns >= config.max_idle_turns then begin
        config.on_event (IdleDetected state.idle_turns);
        config.on_event (Terminated "Max idle turns reached");
        state.running <- false;
        false
      end else
        true  (* Continue despite error *)

    | Ok resp ->
      (* 2. OBSERVE: Update state from response *)
      let cost = calculate_cost resp.usage
        (List.hd config.model_cascade) in
      state.total_cost <- state.total_cost +. cost;
      state.total_tokens <- state.total_tokens + resp.usage.total_tokens;

      (* Track activity: tool calls = active, text only = potentially idle *)
      if resp.tool_calls <> [] then
        state.idle_turns <- 0
      else
        state.idle_turns <- state.idle_turns + 1;

      (* Add assistant response to context *)
      let assistant_msg = Llm_client.assistant_msg resp.content in
      state.context <- Context_manager.append state.context assistant_msg;
      Context_manager.persist_message state.session assistant_msg;

      (* 3. VERIFY: If feedback enabled and action taken *)
      if config.feedback_enabled && resp.tool_calls <> [] then begin
        let action_desc = List.map (fun (tc : Llm_client.tool_call) ->
          sprintf "%s(%s)" tc.call_name
            (if String.length tc.call_arguments > 100
             then String.sub tc.call_arguments 0 100 ^ "..."
             else tc.call_arguments)
        ) resp.tool_calls |> String.concat ", " in
        let vreq = Verifier.{
          action_description = action_desc;
          action_result = resp.content;
          goal = config.initial_goal;
          context_summary = sprintf "Turn %d, generation %d" turn state.generation;
        } in
        let verdict = Verifier.verify ~model:config.verifier_model vreq in
        config.on_event (Verified {
          action = action_desc;
          verdict = Verifier.verdict_to_string verdict;
        });
        (* On FAIL, inject feedback as user message *)
        match verdict with
        | Verifier.Fail reason ->
          let feedback_msg = Llm_client.user_msg
            (sprintf "[Verifier FAIL] %s — please retry with a different approach." reason) in
          state.context <- Context_manager.append state.context feedback_msg;
          Context_manager.persist_message state.session feedback_msg
        | _ -> ()
      end;

      (* 4. COMPACT: If context > threshold *)
      let ratio = Context_manager.context_ratio state.context in
      if ratio >= config.compact_threshold then begin
        let before = state.context.token_count in
        state.context <- Context_manager.compact
          state.context config.compact_strategies;
        let after = state.context.token_count in
        config.on_event (Compacted { before_tokens = before; after_tokens = after })
      end;

      (* 5. PREPARE DNA: If context > prepare_threshold *)
      let ratio2 = Context_manager.context_ratio state.context in
      if ratio2 >= config.prepare_threshold then begin
        let metrics = Succession.{
          total_turns = state.turn_count;
          total_tokens_used = state.total_tokens;
          total_cost_usd = state.total_cost;
          tasks_completed = 0;
          errors_encountered = 0;
          elapsed_seconds = Time_compat.now () -. state.last_heartbeat;
        } in
        let dna = Succession.extract_dna
          ~working_ctx:state.context
          ~session_ctx:state.session
          ~goal:config.initial_goal
          ~generation:state.generation
          ~trace_id:state.trace_id
          ~metrics in
        let dna_json = Succession.dna_to_json dna in
        let dna_size = String.length (Yojson.Safe.to_string dna_json) in
        config.on_event (Prepared { dna_size });

        (* Save checkpoint *)
        let ckpt = Context_manager.create_checkpoint
          state.context ~generation:state.generation in
        Context_manager.save_checkpoint state.session ckpt
      end;

      (* 6. HANDOFF: If context > handoff_threshold *)
      let ratio3 = Context_manager.context_ratio state.context in
      if ratio3 >= config.handoff_threshold then begin
        (* Succession: extract final DNA and stop *)
        let next_model = match config.model_cascade with
          | _ :: m :: _ -> m  (* Next model in cascade *)
          | [m] -> m          (* Same model *)
          | [] -> Llm_client.ollama_glm
        in
        config.on_event (Handoff {
          to_model = next_model.model_id;
          generation = state.generation + 1;
        });
        config.on_event (Terminated "Context handoff triggered");
        state.running <- false;
        false
      end
      else begin
        (* 7. HEARTBEAT: If interval elapsed *)
        let now = Time_compat.now () in
        if now -. state.last_heartbeat >= config.heartbeat_interval_s then begin
          state.last_heartbeat <- now;
          let pct = Context_manager.context_ratio state.context *. 100.0 in
          config.on_event (Heartbeat { turn; context_pct = pct })
        end;

        (* 8. Check termination conditions *)
        if is_goal_complete resp.content then begin
          config.on_event (Terminated "Goal complete");
          state.running <- false;
          false
        end else if is_stuck resp.content then begin
          config.on_event (Terminated "Agent stuck");
          state.running <- false;
          false
        end else if state.idle_turns >= config.max_idle_turns then begin
          config.on_event (IdleDetected state.idle_turns);
          config.on_event (Terminated "Max idle turns reached");
          state.running <- false;
          false
        end else begin
          config.on_event (TurnEnd {
            turn;
            tokens_used = resp.usage.total_tokens;
            cost;
          });
          true  (* Continue *)
        end
      end
  end

(* ================================================================ *)
(* Main Loop                                                        *)
(* ================================================================ *)

let run ~config ~state =
  eprintf "[perpetual] Starting loop: goal=%s, trace=%s, models=%d\n%!"
    config.initial_goal state.trace_id (List.length config.model_cascade);
  while state.running do
    let should_continue = run_turn ~config ~state in
    if not should_continue then
      state.running <- false
    else
      (* Brief pause between turns to avoid hammering the LLM *)
      Unix.sleepf 0.5
  done;
  eprintf "[perpetual] Loop ended: turns=%d, tokens=%d, cost=$%.4f\n%!"
    state.turn_count state.total_tokens state.total_cost

let stop state =
  state.running <- false

(* ================================================================ *)
(* Status                                                           *)
(* ================================================================ *)

let status state : Yojson.Safe.t =
  `Assoc [
    ("trace_id", `String state.trace_id);
    ("running", `Bool state.running);
    ("generation", `Int state.generation);
    ("turn_count", `Int state.turn_count);
    ("idle_turns", `Int state.idle_turns);
    ("total_tokens", `Int state.total_tokens);
    ("total_cost_usd", `Float state.total_cost);
    ("context_ratio", `Float (Context_manager.context_ratio state.context));
    ("context_tokens", `Int state.context.token_count);
    ("context_max", `Int state.context.max_tokens);
    ("message_count", `Int (List.length state.context.messages));
  ]
