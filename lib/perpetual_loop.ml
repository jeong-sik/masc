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

include Perpetual_loop_types

let default_config ~goal ~models ?verifier ?session_dir () =
  let me_root = Env_config.me_root () in
  let verifier_model = match verifier with
    | Some v -> v
    | None -> (
        match Llm_client.default_verifier_model_spec () with
        | Ok model -> model
        | Error _ -> (
            match models with
            | model :: _ -> model
            | [] -> Llm_client.glm_cloud))
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
    event_bus = None;
    coding_mode = false;
    coding_agent = Provider_adapter.default_cli_agent_name ();
    coding_timeout_s = Env_config.Spawn.coding_timeout_seconds;
    coding_sw = None;
    coding_proc_mgr = None;
    room_config = None;
    agent_name = "perpetual";
    auto_claim_cooldown_s = 60.0;
  }

(* ================================================================ *)
(* State Management                                                 *)
(* ================================================================ *)

let generate_trace_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let rnd = Random.int 99999 in
  sprintf "trace-%d-%05d" ts rnd

let create_state config =
  let system_prompt =
    "You are a perpetual agent with infinite context via compaction and succession.\n\
     \n\
     Continuity rules:\n\
     - This run may be compacted/summarized; you must preserve continuity.\n\
     - End every reply with a stable state block used for compaction/handoff.\n\
     - Do not include secrets in the state block.\n\
     \n\
     State block template (must use these exact markers):\n\
     [STATE]\n\
     Goal: <short>\n\
     Progress: <short>\n\
     Next: <0-3 items separated by ';'>\n\
     Decisions: <0-3 items separated by ';'>\n\
     OpenQuestions: <0-3 items separated by ';'>\n\
     Constraints: <0-3 items separated by ';'>\n\
     [/STATE]\n\
     \n\
     Tooling:\n\
     - You may have tools available; use them when helpful.\n\
     - When goal complete, include [GOAL_COMPLETE]. When stuck, include [STUCK: reason]."
  in
  let primary_model = match config.model_cascade with
    | m :: _ -> m
    | [] -> Llm_client.default_local_model_spec ()
  in
  let context = Context_manager.create
    ~system_prompt
    ~max_tokens:primary_model.max_context in
  (* Inject goal as first user message with sticky prefix for compaction safety *)
  let goal_msg = Llm_client.user_msg
    (sprintf "%s %s" Context_manager.goal_prefix config.initial_goal) in
  let context = Context_manager.append context goal_msg in
  let trace_id = generate_trace_id () in
  let session = Context_manager.create_session
    ~session_id:trace_id
    ~base_dir:config.session_base_dir in
  let zero_usage : Llm_client.token_usage = {
    Agent_sdk.Types.input_tokens = 0; output_tokens = 0;
    cache_creation_input_tokens = 0; cache_read_input_tokens = 0;
  } in
  let now_ts = Time_compat.now () in
  {
    context;
    session;
    generation = 0;
    turn_count = 0;
    idle_turns = 0;
    total_cost = 0.0;
    total_tokens = 0;
    last_heartbeat = now_ts;
    started_at = now_ts;
    last_turn_ts = 0.0;
    last_model_used = "";
    last_usage = zero_usage;
    last_latency_ms = 0;
    compaction_count = 0;
    compaction_tokens_saved = 0;
    last_compaction_ts = 0.0;
    last_compaction_before_tokens = 0;
    last_compaction_after_tokens = 0;
    events = [];
    running = true;
    trace_id;
    current_task_id = None;
    last_claim_attempt_ts = 0.0;
    claim_failure_count = 0;
  }

let record_event (state : loop_state) (ev : event) =
  let ts = Time_compat.now () in
  state.events <- (ts, ev) :: state.events;
  (* Keep only the most recent ~200 events to bound memory. *)
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  if List.length state.events > 200 then
    state.events <- take 200 state.events

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
(* Coding Turn (spawn Claude Code)                                  *)
(* ================================================================ *)

(** Execute one coding turn by spawning Claude Code with current context.
    Returns the spawn result for the caller to interpret. *)
let coding_turn ~config ~state =
  match config.coding_sw, config.coding_proc_mgr with
  | Some sw, Some _proc_mgr ->
    let goal = config.initial_goal in
    let turn = state.turn_count in
    (* Extract latest state block from context messages for progress tracking *)
    let progress =
      let blocks =
        List.concat_map
          (fun (m : Llm_client.message) -> Context_manager.extract_state_blocks (Llm_client.text_of_message m))
          (List.rev state.context.messages)
      in
      match blocks with
      | latest :: _ -> latest
      | [] -> "No previous state"
    in
    let prompt = sprintf
      "Continue working on this goal:\n\n\
       Goal: %s\n\n\
       Turn: %d (Generation: %d)\n\n\
       Previous progress:\n%s\n\n\
       Instructions:\n\
       - Make concrete progress toward the goal\n\
       - Commit your work frequently\n\
       - Report your progress at the end\n\
       - If blocked, explain what's blocking you"
      goal turn state.generation progress
    in
    let prompt_with_lifecycle = prompt ^ Spawn_eio.masc_lifecycle_suffix in
    let result = Spawn_eio.spawn
      ~sw
      ~agent_name:config.coding_agent
      ~prompt:prompt_with_lifecycle
      ~timeout_seconds:config.coding_timeout_s
      ()
    in
    config.on_event (CodingSpawn {
      agent = config.coding_agent;
      exit_code = result.Spawn_eio.exit_code;
      elapsed_ms = result.Spawn_eio.elapsed_ms;
    });
    (* Log structured termination reason when available *)
    (match result.Spawn_eio.termination with
     | Some t ->
       Log.Perpetual.info "coding spawn termination: %s (agent=%s, elapsed=%dms, tools=%d)"
         (Spawn_eio.termination_reason_to_string t.reason)
         t.agent_name t.elapsed_ms t.tool_call_count
     | None -> ());
    Ok result
  | _ ->
    Error "coding_mode requires coding_sw and coding_proc_mgr to be set"

(* ================================================================ *)
(* Event Bus Bridge                                                 *)
(* ================================================================ *)

(** Publish perpetual_loop events to OAS Event_bus when configured.
    Extracted to module level to avoid duplication across emit closures. *)
let publish_to_event_bus bus (ev : event) =
  match ev with
  | Heartbeat { turn; context_pct } ->
    Oas_events.publish_heartbeat bus ~agent_name:"perpetual"
      ~turn ~context_pct
  | TurnStart turn ->
    Agent_sdk.Event_bus.publish bus
      (Agent_sdk.Event_bus.TurnStarted
         { agent_name = "perpetual"; turn })
  | TurnEnd { turn; _ } ->
    Agent_sdk.Event_bus.publish bus
      (Agent_sdk.Event_bus.TurnCompleted
         { agent_name = "perpetual"; turn })
  | Error msg ->
    Agent_sdk.Event_bus.publish bus
      (Agent_sdk.Event_bus.Custom ("masc:perpetual:error",
        `Assoc [("message", `String msg);
                ("timestamp", `Float (Time_compat.now ()))]))
  | Terminated reason ->
    Agent_sdk.Event_bus.publish bus
      (Agent_sdk.Event_bus.Custom ("masc:perpetual:terminated",
        `Assoc [("reason", `String reason);
                ("timestamp", `Float (Time_compat.now ()))]))
  | Compacted { before_tokens; after_tokens; offloaded_path } ->
    Agent_sdk.Event_bus.publish bus
      (Agent_sdk.Event_bus.Custom ("masc:perpetual:compacted",
        `Assoc (List.concat [
          [("before", `Int before_tokens);
           ("after", `Int after_tokens);
           ("timestamp", `Float (Time_compat.now ()))];
          (match offloaded_path with
           | Some p -> [("offloaded_path", `String p)]
           | None -> [])
        ])))
  | Handoff { to_model; generation } ->
    Agent_sdk.Event_bus.publish bus
      (Agent_sdk.Event_bus.Custom ("masc:perpetual:handoff",
        `Assoc [("to_model", `String to_model);
                ("generation", `Int generation);
                ("timestamp", `Float (Time_compat.now ()))]))
  | _ -> ()

(* ================================================================ *)
(* Auto-Claim                                                       *)
(* ================================================================ *)

(** Attempt to claim the next task from the Room backlog.
    Only runs when room_config is Some and no task is currently held.
    Uses exponential backoff on repeated failures (cap at ~16 min).
    Returns [true] when a new task was claimed this turn. *)
let try_auto_claim ~config ~state ~emit =
  match config.room_config with
  | None -> false
  | Some room_config ->
    if Option.is_some state.current_task_id then false
    else begin
      let now = Time_compat.now () in
      let effective_cd =
        config.auto_claim_cooldown_s
        *. (2.0 ** Float.of_int (min 4 state.claim_failure_count))
      in
      if now -. state.last_claim_attempt_ts < effective_cd then false
      else begin
        state.last_claim_attempt_ts <- now;
        (* P2: claim_next_r calls ensure_initialized which can raise
           Invalid_argument when room paths are not set up. Catch and
           skip gracefully to avoid crashing the perpetual loop. *)
        match
          (try Room_task.claim_next_r room_config
                 ~agent_name:config.agent_name ()
           with exn ->
             eprintf "[perpetual] auto-claim exception: %s\n%!"
               (Printexc.to_string exn);
             Room_task.Claim_next_error (Printexc.to_string exn))
        with
        | Room_task.Claim_next_claimed { task_id; title; priority; _ } ->
          state.current_task_id <- Some task_id;
          state.claim_failure_count <- 0;
          state.idle_turns <- 0;
          let msg = Llm_client.user_msg
            (sprintf "[AUTO-CLAIMED] Task %s (P%d): %s" task_id priority title) in
          state.context <- Context_manager.append state.context msg;
          emit (TaskClaimed { task_id; title; priority });
          true
        | Room_task.Claim_next_no_unclaimed ->
          (* Empty queue is not a failure — do not increment backoff counter *)
          emit (ClaimSkipped "no_unclaimed_tasks");
          false
        | Room_task.Claim_next_no_eligible _ ->
          state.claim_failure_count <- state.claim_failure_count + 1;
          emit (ClaimSkipped "no_eligible");
          false
        | Room_task.Claim_next_error e ->
          state.claim_failure_count <- state.claim_failure_count + 1;
          emit (ClaimSkipped (sprintf "error: %s" e));
          false
      end
    end

(** Detect [TASK_DONE] in LLM response and complete the current task. *)
let check_task_completion ~config ~state ~emit content =
  match state.current_task_id with
  | Some task_id when (
      try ignore (Str.search_forward (Str.regexp_string "[TASK_DONE]") content 0); true
      with Not_found -> false) ->
    (match config.room_config with
     | Some rc ->
       (* P1-2: Honor complete_task_r failures. On error, keep current_task_id
          so the agent can retry completion on the next turn. *)
       (match Room_task.complete_task_r rc ~agent_name:config.agent_name
                ~task_id ~notes:"completed by perpetual agent" with
        | Ok _ ->
          let completed_id = task_id in
          state.current_task_id <- None;
          emit (TaskCompleted { task_id = completed_id })
        | Error err ->
          eprintf "[perpetual] complete_task_r failed for %s: %s — will retry next turn\n%!"
            task_id (Types.masc_error_to_string err))
     | None ->
       (* No room_config but task is held — clear to prevent deadlock *)
       eprintf "[perpetual] check_task_completion: room_config is None, clearing orphaned task %s\n%!" task_id;
       state.current_task_id <- None)
  | _ -> ()

(* ================================================================ *)
(* Single Turn Execution                                            *)
(* ================================================================ *)

(** Execute a single coding-mode turn.
    Spawns Claude Code, parses output, updates state accordingly.
    Returns true to continue, false to stop. *)
let run_coding_turn ~config ~state =
  let turn = state.turn_count in
  let emit ev =
    record_event state ev;
    config.on_event ev;
    Option.iter (fun bus -> publish_to_event_bus bus ev) config.event_bus
  in
  match coding_turn ~config ~state with
  | Error e ->
    emit (Error (sprintf "Turn %d: coding spawn failed: %s" turn e));
    emit (Terminated "Coding mode misconfigured (missing sw/proc_mgr)");
    state.running <- false;
    false
  | Ok result ->
    let now_ts = Time_compat.now () in
    state.last_turn_ts <- now_ts;
    state.last_model_used <- config.coding_agent;
    state.last_latency_ms <- result.Spawn_eio.elapsed_ms;

    (* Track cost from spawn result *)
    let cost = Option.value ~default:0.0 result.Spawn_eio.cost_usd in
    state.total_cost <- state.total_cost +. cost;
    let tokens_used =
      (Option.value ~default:0 result.Spawn_eio.input_tokens) +
      (Option.value ~default:0 result.Spawn_eio.output_tokens)
    in
    state.total_tokens <- state.total_tokens + tokens_used;

    (* Add spawn output to context for continuity *)
    let output_summary =
      let raw = result.Spawn_eio.output in
      if String.length raw > 2000 then
        (String.sub raw 0 1000) ^ "\n...[truncated]...\n" ^
        (String.sub raw (String.length raw - 1000) 1000)
      else raw
    in
    let assistant_msg = Llm_client.assistant_msg
      (sprintf "[Coding Agent: %s, exit=%d, elapsed=%dms]\n%s"
         config.coding_agent result.Spawn_eio.exit_code
         result.Spawn_eio.elapsed_ms output_summary) in
    state.context <- Context_manager.append state.context assistant_msg;
    Context_manager.persist_message state.session assistant_msg;

    (* Reset idle if spawn succeeded; increment if failed *)
    if result.Spawn_eio.success then
      state.idle_turns <- 0
    else
      state.idle_turns <- state.idle_turns + 1;

    (* Context management: compact with offload if needed *)
    let ratio = Context_manager.context_ratio state.context in
    if ratio >= config.compact_threshold then begin
      let before = state.context.token_count in
      let result = Context_manager.compact_with_offload
        ~session_ctx:state.session
        ~compaction_count:state.compaction_count
        state.context config.compact_strategies in
      state.context <- result.context;
      let after = state.context.token_count in
      state.compaction_count <- state.compaction_count + 1;
      state.compaction_tokens_saved <- state.compaction_tokens_saved + max 0 (before - after);
      state.last_compaction_ts <- Time_compat.now ();
      state.last_compaction_before_tokens <- before;
      state.last_compaction_after_tokens <- after;
      (match result.offloaded_path with
       | Some path ->
         Log.Perpetual.info "compaction offloaded history to %s" path
       | None -> ());
      emit (Compacted { before_tokens = before; after_tokens = after;
                         offloaded_path = result.offloaded_path })
    end;

    (* Handoff if context exhausted *)
    let ratio2 = Context_manager.context_ratio state.context in
    if ratio2 >= config.handoff_threshold then begin
      let next_model = match config.model_cascade with
        | _ :: m :: _ -> m
        | [m] -> m
        | [] -> Llm_client.default_local_model_spec ()
      in
      emit (Handoff {
        to_model = next_model.model_id;
        generation = state.generation + 1;
      });
      emit (Terminated "Context handoff triggered (coding mode)");
      state.running <- false;
      false
    end
    else begin
      (* Heartbeat *)
      let now = Time_compat.now () in
      if now -. state.last_heartbeat >= config.heartbeat_interval_s then begin
        state.last_heartbeat <- now;
        let pct = Context_manager.context_ratio state.context *. 100.0 in
        emit (Heartbeat { turn; context_pct = pct })
      end;

      (* Auto-claim + task completion in coding mode *)
      let just_claimed = try_auto_claim ~config ~state ~emit in
      if not just_claimed then
        check_task_completion ~config ~state ~emit result.Spawn_eio.output;

      (* Check termination: goal complete, stuck, or spawn indicates context exhaustion *)
      let content = result.Spawn_eio.output in
      if is_goal_complete content then begin
        emit (Terminated "Goal complete (coding mode)");
        state.running <- false;
        false
      end else if is_stuck content then begin
        emit (Terminated "Agent stuck (coding mode)");
        state.running <- false;
        false
      end else if state.idle_turns >= config.max_idle_turns then begin
        emit (IdleDetected state.idle_turns);
        emit (Terminated "Max idle turns reached (coding mode)");
        state.running <- false;
        false
      end else begin
        emit (TurnEnd { turn; tokens_used; cost });
        true
      end
    end

let run_turn ~config ~state =
  if not state.running then false
  else begin
    state.turn_count <- state.turn_count + 1;
    let turn = state.turn_count in
    let emit ev =
      record_event state ev;
      config.on_event ev;
      (* Bridge to OAS Event_bus when configured *)
      Option.iter (fun bus -> publish_to_event_bus bus ev) config.event_bus
    in
    emit (TurnStart turn);

    (* Branch: coding mode spawns Claude Code, normal mode calls LLM directly *)
    if config.coding_mode then
      run_coding_turn ~config ~state
    else begin

    (* 1. THINK + ACT: Call LLM *)
    let requests = build_requests config state in
    let result = Llm_provider_oas.cascade requests in

    match result with
    | Error e ->
      emit (Error (sprintf "Turn %d: LLM call failed: %s" turn e));
      state.idle_turns <- state.idle_turns + 1;
      (* Check idle threshold *)
      if state.idle_turns >= config.max_idle_turns then begin
        emit (IdleDetected state.idle_turns);
        emit (Terminated "Max idle turns reached");
        state.running <- false;
        false
      end else
        true  (* Continue despite error *)

    | Ok resp ->
      let now_ts = Time_compat.now () in
      state.last_turn_ts <- now_ts;
      state.last_model_used <- resp.model_used;
      state.last_usage <- resp.usage;
      state.last_latency_ms <- resp.latency_ms;

      (* 2. OBSERVE: Update state from response *)
      let primary_model =
        match config.model_cascade with
        | m :: _ -> m
        | [] -> Llm_client.default_local_model_spec ()
      in
      let used_model =
        let used =
          if String.ends_with ~suffix:":latest" resp.model_used then
            String.sub resp.model_used 0
              (String.length resp.model_used - String.length ":latest")
          else
            resp.model_used
        in
        List.find_opt (fun (m : Llm_client.model_spec) ->
          m.model_id = resp.model_used || m.model_id = used
        ) config.model_cascade
        |> Option.value ~default:primary_model
      in
      let cost = calculate_cost resp.usage used_model in
      state.total_cost <- state.total_cost +. cost;
      state.total_tokens <- state.total_tokens + Llm_client.total_tokens resp.usage;

      (* Track activity: tool calls = active, text only = potentially idle *)
      if resp.tool_calls <> [] then
        state.idle_turns <- 0
      else
        state.idle_turns <- state.idle_turns + 1;

      (* Add assistant response to context *)
      let assistant_msg = Llm_client.assistant_msg (Llm_client.text_of_response resp) in
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
          action_result = Llm_client.text_of_response resp;
          goal = config.initial_goal;
          context_summary = sprintf "Turn %d, generation %d" turn state.generation;
        } in
        let verdict = Verifier.verify ~model:config.verifier_model vreq in
        emit (Verified {
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

      (* 4. COMPACT: If context > threshold (with history offload) *)
      let ratio = Context_manager.context_ratio state.context in
      if ratio >= config.compact_threshold then begin
        let before = state.context.token_count in
        let result = Context_manager.compact_with_offload
          ~session_ctx:state.session
          ~compaction_count:state.compaction_count
          state.context config.compact_strategies in
        state.context <- result.context;
        let after = state.context.token_count in
        state.compaction_count <- state.compaction_count + 1;
        state.compaction_tokens_saved <- state.compaction_tokens_saved + max 0 (before - after);
        state.last_compaction_ts <- Time_compat.now ();
        state.last_compaction_before_tokens <- before;
        state.last_compaction_after_tokens <- after;
        (match result.offloaded_path with
         | Some path ->
           Log.Perpetual.info "compaction offloaded history to %s" path
         | None -> ());
        emit (Compacted { before_tokens = before; after_tokens = after;
                           offloaded_path = result.offloaded_path })
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
        emit (Prepared { dna_size });

        (* Save checkpoint — both Context_manager and OAS bridge *)
        let ckpt = Context_manager.create_checkpoint
          state.context ~generation:state.generation in
        Context_manager.save_checkpoint state.session ckpt;
        (* OAS Checkpoint bridge: portable state snapshot *)
        (try
          let oas_ckpt = Oas_checkpoint_bridge.to_oas_checkpoint
            ~state:
              {
                Oas_checkpoint_bridge.session_id = state.session.session_id;
                generation = state.generation;
                turn_count = state.turn_count;
                total_tokens = state.total_tokens;
                total_cost = state.total_cost;
                trace_id = state.trace_id;
              }
            ~ctx:state.context ~goal:config.initial_goal () in
          let checkpoint_path =
            Filename.concat config.session_base_dir (state.trace_id ^ ".json")
          in
          Fs_compat.mkdir_p config.session_base_dir;
          Fs_compat.save_file checkpoint_path
            (Agent_sdk.Checkpoint.to_string oas_ckpt)
        with exn ->
          eprintf "[perpetual] OAS checkpoint save failed: %s\n%!"
            (Printexc.to_string exn))
      end;

      (* 6. HANDOFF: If context > handoff_threshold *)
      let ratio3 = Context_manager.context_ratio state.context in
      if ratio3 >= config.handoff_threshold then begin
        (* Succession: extract final DNA and stop *)
        let next_model = match config.model_cascade with
          | _ :: m :: _ -> m  (* Next model in cascade *)
          | [m] -> m          (* Same model *)
          | [] -> Llm_client.default_local_model_spec ()
        in
        emit (Handoff {
          to_model = next_model.model_id;
          generation = state.generation + 1;
        });
        emit (Terminated "Context handoff triggered");
        state.running <- false;
        false
      end
      else begin
        (* 7. HEARTBEAT: If interval elapsed *)
        let now = Time_compat.now () in
        if now -. state.last_heartbeat >= config.heartbeat_interval_s then begin
          state.last_heartbeat <- now;
          let pct = Context_manager.context_ratio state.context *. 100.0 in
          emit (Heartbeat { turn; context_pct = pct })
        end;

        (* 7b. AUTO-CLAIM: try to pick up a task if idle *)
        let just_claimed = try_auto_claim ~config ~state ~emit in

        (* 7c. TASK COMPLETION: detect [TASK_DONE] in response.
           P1-1: Skip when a task was just claimed this turn — resp.content
           predates the claim and may contain stale [TASK_DONE] signals. *)
        if not just_claimed then
          check_task_completion ~config ~state ~emit (Llm_client.text_of_response resp);

        (* 8. Check termination conditions *)
        if is_goal_complete (Llm_client.text_of_response resp) then begin
          emit (Terminated "Goal complete");
          state.running <- false;
          false
        end else if is_stuck (Llm_client.text_of_response resp) then begin
          emit (Terminated "Agent stuck");
          state.running <- false;
          false
        end else if state.idle_turns >= config.max_idle_turns then begin
          emit (IdleDetected state.idle_turns);
          emit (Terminated "Max idle turns reached");
          state.running <- false;
          false
        end else begin
          emit (TurnEnd {
            turn;
            tokens_used = Llm_client.total_tokens resp.usage;
            cost;
          });
          true  (* Continue *)
        end
      end
    end  (* else: normal LLM mode *)
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
      Time_compat.sleep 0.5
  done;
  eprintf "[perpetual] Loop ended: turns=%d, tokens=%d, cost=$%.4f\n%!"
    state.turn_count state.total_tokens state.total_cost

let stop state =
  state.running <- false;
  (* Save final OAS checkpoint on graceful stop *)
  eprintf "[perpetual] Saving final checkpoint: trace=%s turns=%d\n%!"
    state.trace_id state.turn_count

(* ================================================================ *)
(* Status                                                           *)
(* ================================================================ *)

let status ~config state : Yojson.Safe.t =
  let now_ts = Time_compat.now () in
  let age_s = if state.started_at <= 0.0 then 0.0 else now_ts -. state.started_at in
  let last_turn_ago_s = if state.last_turn_ts <= 0.0 then 0.0 else now_ts -. state.last_turn_ts in
  let last_heartbeat_ago_s =
    if state.last_heartbeat <= 0.0 then 0.0 else now_ts -. state.last_heartbeat
  in
  let last_compaction_ago_s =
    if state.last_compaction_ts <= 0.0 then 0.0 else now_ts -. state.last_compaction_ts
  in
  let event_kind = function
    | TurnStart _ -> "turn_start"
    | TurnEnd _ -> "turn_end"
    | Compacted _ -> "compacted"
    | Prepared _ -> "prepared"
    | Handoff _ -> "handoff"
    | Verified _ -> "verified"
    | Heartbeat _ -> "heartbeat"
    | Error _ -> "error"
    | IdleDetected _ -> "idle_detected"
    | Terminated _ -> "terminated"
    | CodingSpawn _ -> "coding_spawn"
    | TaskClaimed _ -> "task_claimed"
    | TaskCompleted _ -> "task_completed"
    | ClaimSkipped _ -> "claim_skipped"
  in
  let event_to_json (ev : event) : Yojson.Safe.t =
    match ev with
    | TurnStart n -> `Assoc [("kind", `String (event_kind ev)); ("turn", `Int n)]
    | TurnEnd { turn; tokens_used; cost } ->
      `Assoc [
        ("kind", `String (event_kind ev));
        ("turn", `Int turn);
        ("tokens_used", `Int tokens_used);
        ("cost_usd", `Float cost);
      ]
    | Compacted { before_tokens; after_tokens; offloaded_path } ->
      `Assoc (List.concat [
        [("kind", `String (event_kind ev));
         ("before_tokens", `Int before_tokens);
         ("after_tokens", `Int after_tokens)];
        (match offloaded_path with
         | Some p -> [("offloaded_path", `String p)]
         | None -> [])
      ])
    | Prepared { dna_size } ->
      `Assoc [("kind", `String (event_kind ev)); ("dna_size", `Int dna_size)]
    | Handoff { to_model; generation } ->
      `Assoc [
        ("kind", `String (event_kind ev));
        ("to_model", `String to_model);
        ("generation", `Int generation);
      ]
    | Verified { action; verdict } ->
      `Assoc [
        ("kind", `String (event_kind ev));
        ("action", `String action);
        ("verdict", `String verdict);
      ]
    | Heartbeat { turn; context_pct } ->
      `Assoc [
        ("kind", `String (event_kind ev));
        ("turn", `Int turn);
        ("context_pct", `Float context_pct);
      ]
    | Error msg ->
      `Assoc [("kind", `String (event_kind ev)); ("message", `String msg)]
    | IdleDetected n ->
      `Assoc [("kind", `String (event_kind ev)); ("idle_turns", `Int n)]
    | Terminated reason ->
      `Assoc [("kind", `String (event_kind ev)); ("reason", `String reason)]
    | CodingSpawn { agent; exit_code; elapsed_ms } ->
      `Assoc [
        ("kind", `String (event_kind ev));
        ("agent", `String agent);
        ("exit_code", `Int exit_code);
        ("elapsed_ms", `Int elapsed_ms);
      ]
    | TaskClaimed { task_id; title; priority } ->
      `Assoc [
        ("kind", `String (event_kind ev));
        ("task_id", `String task_id);
        ("title", `String title);
        ("priority", `Int priority);
      ]
    | TaskCompleted { task_id } ->
      `Assoc [("kind", `String (event_kind ev)); ("task_id", `String task_id)]
    | ClaimSkipped reason ->
      `Assoc [("kind", `String (event_kind ev)); ("reason", `String reason)]
  in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  let events_tail =
    state.events
    |> take 20
    |> List.rev
    |> List.map (fun (ts, ev) ->
      `Assoc [("ts_unix", `Float ts); ("event", event_to_json ev)]
    )
  in
  `Assoc [
    ("trace_id", `String state.trace_id);
    ("running", `Bool state.running);
    ("generation", `Int state.generation);
    ("turn_count", `Int state.turn_count);
    ("idle_turns", `Int state.idle_turns);
    ("total_tokens", `Int state.total_tokens);
    ("total_cost_usd", `Float state.total_cost);
    ("started_at_ts", `Float state.started_at);
    ("age_s", `Float age_s);
    ("last_turn_ts", `Float state.last_turn_ts);
    ("last_turn_ago_s", `Float last_turn_ago_s);
    ("last_model_used", `String state.last_model_used);
    ("last_usage", `Assoc [
      ("input_tokens", `Int state.last_usage.input_tokens);
      ("output_tokens", `Int state.last_usage.output_tokens);
      ("total_tokens", `Int (Llm_client.total_tokens state.last_usage));
    ]);
    ("last_latency_ms", `Int state.last_latency_ms);
    ("last_heartbeat_ts", `Float state.last_heartbeat);
    ("last_heartbeat_ago_s", `Float last_heartbeat_ago_s);
    ("compaction_count", `Int state.compaction_count);
    ("compaction_tokens_saved", `Int state.compaction_tokens_saved);
    ("last_compaction", `Assoc [
      ("ts_unix", `Float state.last_compaction_ts);
      ("ago_s", `Float last_compaction_ago_s);
      ("before_tokens", `Int state.last_compaction_before_tokens);
      ("after_tokens", `Int state.last_compaction_after_tokens);
    ]);
    ("events_tail", `List events_tail);
    ("context_ratio", `Float (Context_manager.context_ratio state.context));
    ("context_tokens", `Int state.context.token_count);
    ("context_max", `Int state.context.max_tokens);
    ("message_count", `Int (List.length state.context.messages));
    ("current_task_id", match state.current_task_id with
      | Some id -> `String id | None -> `Null);
    ("claim_failure_count", `Int state.claim_failure_count);
    ("auto_claim_enabled", `Bool (Option.is_some config.room_config));
  ]
