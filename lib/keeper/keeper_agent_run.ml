let adaptive_thinking_budget
      ~enabled
      ~is_retry
      ~last_tool_results
      ~user_message
      ~dynamic_context
      ~current_budget
  =
  if not enabled
  then current_budget
  else (
    (* 1) Structured tool errors in last tools -> High thinking *)
    let had_error =
      List.exists
        (fun (r : Agent_sdk.Types.tool_result) ->
           match r with
           | Error _ -> true
           | Ok _ -> false)
        last_tool_results
    in
    if is_retry || had_error
    then Some 1500
    else (
      (* 2) Task complexity keywords -> Max thinking *)
      let haystack = user_message ^ " " ^ dynamic_context in
      let complex_task =
        List.exists
          (fun needle -> String_util.contains_substring_ci haystack needle)
          [ "분석"; "설계"; "plan"; "architecture"; "complex"; "investigate" ]
      in
      if complex_task
      then Some 2000
      else
        (* Otherwise fallback to default or OFF (None) *)
        current_budget))
;;

(** Keeper_agent_run — Run a single keeper turn via OAS Agent.run().

    Owns the full context lifecycle: checkpoint loading, context creation,
    base system prompt application, and message persistence.
    Callers provide domain-specific system prompt logic via
    [build_turn_prompt] callback.

    Uses {!Keeper_tools_oas} for tool wrapping and
    {!Keeper_hooks_oas} for lifecycle hooks (checkpoint, metrics, social).

    @since Phase 5 — Keeper Agent.run encapsulation *)

(** Structured prompt result from [build_turn_prompt] callback.
    [system_prompt] contains hard constraints (identity, policy guards,
    tool guidance, direct-reply mode) that must stay in the system prompt.
    [dynamic_context] contains soft context (continuity, skill route,
    worktree changes, turn instructions) injected via OAS
    [extra_system_context] — prepended as a User message after reduction. *)
type turn_prompt =
  { system_prompt : string
  ; dynamic_context : string
  }

(** Prompt segment metrics for effective keeper input attribution.
    Bytes are stored rather than character counts because prompts are UTF-8. *)
type prompt_segment_metrics =
  { bytes : int
  ; estimated_tokens : int
  ; fingerprint : string option
  }

(** Effective prompt metrics for a keeper turn.
    [estimated_cacheable_tokens] tracks the system prompt portion only because
    OAS prompt caching is enabled via [cache_system_prompt:true]. *)
type prompt_metrics =
  { fingerprint : string
  ; estimated_total_tokens : int
  ; estimated_cacheable_tokens : int
  ; system_prompt_segment : prompt_segment_metrics
  ; dynamic_context_segment : prompt_segment_metrics
  ; user_message_segment : prompt_segment_metrics
  }

type ctx_composition_metrics =
  { actual_input_tokens : int option
  ; display_total_tokens : int
  ; estimated_known_tokens : int
  ; segments : (string * prompt_segment_metrics) list
  }

let empty_prompt_segment_metrics =
  { bytes = 0; estimated_tokens = 0; fingerprint = None }

let prompt_segment_metrics_of_text (text : string) : prompt_segment_metrics =
  let text = Inference_utils.sanitize_text_utf8 text in
  {
    bytes = String.length text;
    estimated_tokens =
      (if text = "" then 0 else Agent_sdk.Context_reducer.estimate_char_tokens text);
    fingerprint =
      (if text = ""
       then None
       else Some Digestif.SHA256.(digest_string text |> to_hex));
  }

let build_prompt_metrics ~(system_prompt : string) ~(dynamic_context : string)
    ~(user_message : string) : prompt_metrics =
  let system_prompt = Inference_utils.sanitize_text_utf8 system_prompt in
  let dynamic_context = Inference_utils.sanitize_text_utf8 dynamic_context in
  let user_message = Inference_utils.sanitize_text_utf8 user_message in
  let system_prompt_metrics = prompt_segment_metrics_of_text system_prompt in
  let dynamic_context_metrics = prompt_segment_metrics_of_text dynamic_context in
  let user_message_metrics = prompt_segment_metrics_of_text user_message in
  let fingerprint_input =
    `Assoc
      [
        ("system_prompt", `String system_prompt);
        ("dynamic_context", `String dynamic_context);
        ("user_message", `String user_message);
      ]
    |> Yojson.Safe.to_string
  in
  {
    fingerprint = Digestif.SHA256.(digest_string fingerprint_input |> to_hex);
    estimated_total_tokens =
      (system_prompt_metrics.estimated_tokens
       + dynamic_context_metrics.estimated_tokens
       + user_message_metrics.estimated_tokens);
    estimated_cacheable_tokens = system_prompt_metrics.estimated_tokens;
    system_prompt_segment = system_prompt_metrics;
    dynamic_context_segment = dynamic_context_metrics;
    user_message_segment = user_message_metrics;
  }

let prompt_segment_metrics_to_json (segment : prompt_segment_metrics) :
    Yojson.Safe.t =
  `Assoc
    [
      ("bytes", `Int segment.bytes);
      ("estimated_tokens", `Int segment.estimated_tokens);
      ("fingerprint", Json_util.string_opt_to_json segment.fingerprint);
    ]

let prompt_metrics_to_json (metrics : prompt_metrics) : Yojson.Safe.t =
  `Assoc
    [
      ("fingerprint", `String metrics.fingerprint);
      ("estimated_total_tokens", `Int metrics.estimated_total_tokens);
      ("estimated_cacheable_tokens", `Int metrics.estimated_cacheable_tokens);
      ("system_prompt", prompt_segment_metrics_to_json metrics.system_prompt_segment);
      ("dynamic_context", prompt_segment_metrics_to_json metrics.dynamic_context_segment);
      ("user_message", prompt_segment_metrics_to_json metrics.user_message_segment);
    ]

let synthetic_prompt_segment_metrics ~estimated_tokens : prompt_segment_metrics =
  { bytes = 0; estimated_tokens; fingerprint = None }

let add_segment_metric
    (totals : (string, prompt_segment_metrics) Hashtbl.t)
    ~(bucket : string)
    (metric : prompt_segment_metrics) : unit =
  let prev =
    match Hashtbl.find_opt totals bucket with
    | Some existing -> existing
    | None -> empty_prompt_segment_metrics
  in
  Hashtbl.replace totals bucket
    {
      bytes = prev.bytes + metric.bytes;
      estimated_tokens = prev.estimated_tokens + metric.estimated_tokens;
      fingerprint = None;
    }

let metric_of_block
    ~(role : Agent_sdk.Types.role)
    (block : Agent_sdk.Types.content_block) : prompt_segment_metrics =
  let bytes =
    match block with
    | Agent_sdk.Types.Text text ->
        String.length (Inference_utils.sanitize_text_utf8 text)
    | Agent_sdk.Types.ToolUse { id; name; input } ->
        String.length (Inference_utils.sanitize_text_utf8 id)
        + String.length (Inference_utils.sanitize_text_utf8 name)
        + String.length (Yojson.Safe.to_string input)
    | Agent_sdk.Types.ToolResult { tool_use_id; content; json; _ } ->
        String.length (Inference_utils.sanitize_text_utf8 tool_use_id)
        + String.length (Inference_utils.sanitize_text_utf8 content)
        + (match json with
           | Some value -> String.length (Yojson.Safe.to_string value)
           | None -> 0)
    | _ -> 0
  in
  let msg =
    {
      Agent_sdk.Types.role;
      content = [block];
      name = None;
      tool_call_id = None;
    }
  in
  {
    bytes;
    estimated_tokens = Keeper_exec_context.msg_tokens msg;
    fingerprint = None;
  }

let history_bucket_of_block
    ~(role : Agent_sdk.Types.role)
    (block : Agent_sdk.Types.content_block) : string =
  match block with
  | Agent_sdk.Types.ToolUse _ -> "history_tool_use"
  | Agent_sdk.Types.ToolResult _ -> "history_tool_result"
  | Agent_sdk.Types.Text _ -> (
      match role with
      | Agent_sdk.Types.User -> "history_user"
      | Agent_sdk.Types.Assistant | Agent_sdk.Types.System ->
          "history_assistant_text"
      | Agent_sdk.Types.Tool -> "history_tool_result")
  | _ -> "history_other"

let build_ctx_composition_metrics
    ~(system_prompt : string)
    ~(dynamic_context : string)
    ~(memory_context : string)
    ~(temporal_context : string)
    ~(user_message : string)
    ~(history_messages : Agent_sdk.Types.message list)
    ~(actual_input_tokens : int) : ctx_composition_metrics =
  let totals : (string, prompt_segment_metrics) Hashtbl.t = Hashtbl.create 16 in
  let add_text_segment bucket text =
    let metric = prompt_segment_metrics_of_text text in
    if metric.estimated_tokens > 0 then add_segment_metric totals ~bucket metric
  in
  add_text_segment "system_prompt" system_prompt;
  add_text_segment "dynamic_context" dynamic_context;
  add_text_segment "memory_context" memory_context;
  add_text_segment "temporal_context" temporal_context;
  add_text_segment "user_message" user_message;
  List.iter
    (fun (message : Agent_sdk.Types.message) ->
      List.iter
        (fun block ->
          let bucket = history_bucket_of_block ~role:message.role block in
          let metric = metric_of_block ~role:message.role block in
          if metric.estimated_tokens > 0 then add_segment_metric totals ~bucket metric)
        message.content)
    history_messages;
  let segments =
    Hashtbl.to_seq totals
    |> List.of_seq
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  in
  let estimated_known_tokens =
    List.fold_left
      (fun acc (_, metric) -> acc + metric.estimated_tokens)
      0 segments
  in
  let actual_input_tokens =
    if actual_input_tokens > 0 then Some actual_input_tokens else None
  in
  let display_total_tokens =
    match actual_input_tokens with
    | Some actual -> max actual estimated_known_tokens
    | None -> estimated_known_tokens
  in
  let segments =
    if display_total_tokens > estimated_known_tokens then
      segments
      @ [ ( "unattributed",
            synthetic_prompt_segment_metrics
              ~estimated_tokens:(display_total_tokens - estimated_known_tokens) ) ]
    else segments
  in
  {
    actual_input_tokens;
    display_total_tokens;
    estimated_known_tokens;
    segments;
  }

let ctx_composition_to_json (metrics : ctx_composition_metrics) : Yojson.Safe.t =
  `Assoc
    [
      ("actual_input_tokens", Json_util.int_opt_to_json metrics.actual_input_tokens);
      ("display_total_tokens", `Int metrics.display_total_tokens);
      ("estimated_known_tokens", `Int metrics.estimated_known_tokens);
      ( "segments",
        `Assoc
          (List.map
             (fun (key, value) -> (key, prompt_segment_metrics_to_json value))
             metrics.segments) );
    ]

(** Result of a single Agent.run() keeper turn. *)
type run_result =
  { response_text : string
  ; model_used : string
  ; prompt_metrics : prompt_metrics
  ; ctx_composition : ctx_composition_metrics
  ; cascade_observation : Oas_worker.cascade_observation option
  ; turn_count : int
  ; tool_calls_made : int
  ; usage : Agent_sdk.Types.api_usage
  ; tools_used : string list
  ; checkpoint : Agent_sdk.Checkpoint.t option
  ; proof : Agent_sdk.Cdal_proof.t option
  ; trace_ref : Agent_sdk.Raw_trace.run_ref option
  ; run_validation : Agent_sdk.Raw_trace.run_validation option
  ; stop_reason : Oas_worker.stop_reason
  ; inference_telemetry : Agent_sdk.Types.inference_telemetry option
  }

let nonempty_trimmed raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None else Some trimmed

let surface_model_used (result : run_result) : string =
  let attempt_surface_model (attempt : Oas_worker.cascade_attempt) =
    match Option.bind attempt.model_label nonempty_trimmed with
    | Some label -> Some label
    | None -> nonempty_trimmed attempt.model_id
  in
  let observation_surface_model (obs : Oas_worker.cascade_observation) =
    match
      obs.attempts
      |> List.rev
      |> List.find_map attempt_surface_model
    with
    | Some model -> Some model
    | None -> (
        match Option.bind obs.selected_model nonempty_trimmed with
        | Some model -> Some model
        | None -> Option.bind obs.primary_model nonempty_trimmed)
  in
  match Option.bind result.cascade_observation observation_surface_model with
  | Some model -> model
  | None -> Option.value ~default:"" (nonempty_trimmed result.model_used)

(* Tool selection & disclosure — extracted to Keeper_tool_disclosure (#5732) *)

(* Deterministic selection floor size: keep the executable surface small
   enough for prompt budgets while still surfacing a handful of relevant
   tools even before any LLM hinting lands. *)
let keeper_selection_top_k = 10

(* BM25 candidate pool for TopK_llm: wide enough to give reranking room to
   improve results, but still bounded and deterministic. *)
let keeper_selection_bm25_prefilter_n = 30

let tool_index_entry_of_tool
    ~(korean_kw_tbl : (string, string) Hashtbl.t)
    (t : Agent_sdk.Tool.t) : Agent_sdk.Tool_index.entry =
  let name = t.schema.name in
  let group =
    if String.starts_with ~prefix:"keeper_board_" name then Some "board"
    else if String.starts_with ~prefix:"keeper_memory_" name
         || String.starts_with ~prefix:"keeper_library_" name then Some "knowledge"
    else if String.starts_with ~prefix:"keeper_task" name then Some "tasks"
    else if String.starts_with ~prefix:"keeper_voice_" name then Some "voice"
    else if String.starts_with ~prefix:"keeper_fs_" name
         || name = "keeper_shell"
         || name = "keeper_bash"
         || name = "keeper_write" then Some "filesystem"
    else if String.starts_with ~prefix:"masc_board_" name then Some "masc_board"
    else if String.starts_with ~prefix:"masc_keeper_" name then Some "masc_keeper"
    else if String.starts_with ~prefix:"masc_plan_" name then Some "masc_plan"
    else if String.starts_with ~prefix:"masc_worktree_" name then Some "masc_worktree"
    else if String.starts_with ~prefix:"masc_code_" name then Some "masc_code"
    else if String.starts_with ~prefix:"masc_governance_" name then Some "masc_governance"
    else if String.starts_with ~prefix:"masc_autoresearch_" name then Some "masc_autoresearch"
    else if String.starts_with ~prefix:"masc_agent_" name
         || name = "masc_agents" then Some "masc_agent"
    else if String.starts_with ~prefix:"masc_" name then Some "masc_core"
    else None
  in
  let aliases =
    match Hashtbl.find_opt korean_kw_tbl name with
    | Some kw ->
        String.split_on_char ' ' kw
        |> List.filter (fun s -> s <> "")
    | None -> []
  in
  Agent_sdk.Tool_index.{ name; description = t.schema.description; group; aliases }

(* Post-turn telemetry logging — extracted to Keeper_turn_telemetry (#5732) *)

(** Run a single keeper turn via OAS Agent.run().

    Loads checkpoint, creates working context with the base keeper system
    prompt, then calls [build_turn_prompt] with the base prompt and message
    history so the caller can layer skill routing, continuity context,
    policy guards, and turn-specific instructions on top.

    After the callback returns the final system prompt, appends the user
    message, builds OAS tools + hooks, and delegates to
    [Oas_worker.run_named] which internally calls Agent.run().

    @param config Room configuration
    @param meta Keeper metadata
    @param base_dir Session base directory for checkpoints
    @param max_context Maximum context window tokens
    @param build_turn_prompt Callback: receives the base keeper system prompt
           and checkpoint message history, returns the final turn system prompt
    @param user_message The user's message to the keeper
    @param cascade_name Cascade profile name for model selection
    @param generation Current generation counter
    @param max_turns Maximum agent turns (default: 50, generous budget for multi-step)
    @param guardrails Optional OAS guardrails for tool safety gates
    @param temperature MODEL temperature override; when omitted, resolved
           from [Cascade_inference] with a 0.3 fallback
    @param max_tokens Maximum output tokens override; when omitted, resolved
           from [Cascade_inference] with a 8192 fallback
    @param is_retry When [true], replays the current user message into the
           working context without persisting it again, so transient retry
           attempts do not duplicate the user entry in session history *)
let run_turn
      ~(config : Room.config)
      ~(meta : Keeper_types.keeper_meta)
      ~(base_dir : string)
      ~(max_context : int)
      ~(build_turn_prompt :
         base_system_prompt:string -> messages:Agent_sdk.Types.message list -> turn_prompt)
      ~(user_message : string)
      ~(cascade_name : string)
      ?provider_filter
      ~(generation : int)
      ?(max_turns : int = Env_config_keeper.KeeperKeepalive.oas_max_turns_per_call)
      (* Per-call turn budget. Keeper resumes via checkpoint if exhausted. *)
      ?(max_idle_turns : int = 3)
      ?(history_user_source = "direct_user")
      ?(history_assistant_source = "direct_assistant")
      ?guardrails
      ?temperature
      ?max_tokens
      ?oas_timeout_s
      ?max_cost_usd
      ?on_event
      ?(trajectory_acc : Trajectory.accumulator option)
      ?(tool_overlay : Agent_sdk.Tool_op.t ref option)
      ?priority
      ?(is_retry = false)
      ?shared_context
      ?event_bus
      ()
  : (run_result, Oas.Error.sdk_error) result
  =
  (* 0. Resolve inference parameters via Cascade_inference *)
  let temperature =
    match temperature with
    | Some t -> t
    | None ->
      Cascade_inference.resolve_temperature ~cascade_name ~fallback:(fun () -> 0.3)
  in
  let max_tokens =
    match max_tokens with
    | Some t -> t
    | None ->
      Cascade_inference.resolve_max_tokens
        ~cascade_name
          (* 8192 allows complex multi-tool reasoning per turn.
           Cloudflare tunnel 100s is no longer a constraint with
           streaming responses. *)
        ~fallback:(fun () -> 8192)
  in
  (* 0b. Create context injector for temporal awareness *)
  let injector_config = Masc_context_injector.default_config () in
  let context_injector = Masc_context_injector.make ~config:injector_config () in
  (* Use caller-provided Context.t for cross-turn OAS context persistence.
     OAS Context.t is a mutable container, so reusing it preserves any
     state stored in that context across keeper turns. Note, however, that
     this function creates a fresh [context_injector] on each call, so any
     injector-local elapsed-time or tool-call counters do not accumulate
     across turns merely by sharing [~shared_context]. Callers that manage
     a persistent lifecycle (keeper heartbeat loop) should pass a long-lived
     [~shared_context] when they need cross-turn OAS context continuity. *)
  let shared_context =
    match shared_context with
    | Some ctx -> ctx
    | None -> Oas.Context.create ()
  in
  (* 1. Ensure session directory tree exists.
     Both the base traces dir AND the trace-specific session dir must
     exist before any file I/O (checkpoint load, history persist).
     In filesystem fallback mode (PG unavailable), these directories may
     not have been created by keeper_up if it only registered in-memory. *)
  let session_dir = Filename.concat base_dir (Keeper_id.Trace_id.to_string meta.runtime.trace_id) in
  Keeper_types.mkdir_p session_dir;
  (* 2. Load checkpoint *)
  let session, ctx_opt =
    Keeper_exec_context.load_context_from_checkpoint
      ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
      ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ~primary_model_max_tokens:max_context
      ~base_dir
  in
  (* 2b. Load raw OAS checkpoint for Agent.resume path.
     Preserves turn_count, usage_stats, and lifecycle state across turns.
     Falls back to fresh build when unavailable (first turn, rollover). *)
  let raw_oas_checkpoint =
    match
      Keeper_checkpoint_store.load_oas
        ~session_dir:session.session_dir
        ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
    with
    | Ok cp -> Some cp
    | Error _ -> None
  in
  (* Starting turn count for per-call budget calculation in hooks.
     With Agent.resume, turn count is cumulative from checkpoint. *)
  let start_turn_count =
    match raw_oas_checkpoint with
    | Some cp -> cp.turn_count
    | None -> 0
  in
  (* 3. Build base system prompt from meta *)
  let profile_defaults = Keeper_types_profile.load_keeper_profile_defaults meta.name in
  let persona_extended =
    Keeper_types_profile.resolved_persona_name ~keeper_name:meta.name
      profile_defaults
    |> Keeper_types_profile.load_persona_extended
    |> Option.value ~default:""
  in
  let base_system_prompt =
    Keeper_prompt.build_keeper_system_prompt
      ~goal:meta.goal
      ~short_goal:meta.short_goal
      ~mid_goal:meta.mid_goal
      ~long_goal:meta.long_goal
      ~will:meta.will
      ~needs:meta.needs
      ~desires:meta.desires
      ~instructions:meta.instructions
      ~persona_extended
      ~keeper_name:meta.name
      ()
  in
  (* 4. Create or restore working context, re-apply current prompt *)
  let base_ctx =
    match ctx_opt with
    | Some c -> c
    | None ->
      Keeper_exec_context.create ~system_prompt:base_system_prompt ~max_tokens:max_context
  in
  let ctx_work =
    Keeper_exec_context.set_system_prompt base_ctx ~system_prompt:base_system_prompt
  in
  (* 5. Build final turn system prompt via caller callback.
     Hard constraints stay in system_prompt; soft context is injected
     via OAS extra_system_context (prepended as User message after reduction). *)
  let { system_prompt = turn_system_prompt; dynamic_context } =
    build_turn_prompt ~base_system_prompt ~messages:ctx_work.messages
  in
  let memory_episode_limit = 30 in
  let memory_procedure_limit = 10 in
  let memory_context =
    Memory_hooks.render_memory_context
      ~agent_name:meta.agent_name
      ~config
      ~episode_limit:memory_episode_limit
      ~procedure_limit:memory_procedure_limit
      ()
    |> Option.value ~default:""
  in
  let temporal_context =
    Masc_context_injector.render_temporal_summary shared_context
    |> Option.value ~default:""
  in
  let prompt_metrics =
    build_prompt_metrics ~system_prompt:turn_system_prompt ~dynamic_context
      ~user_message
  in
  (* 6. Append user message and persist.
     On retry (is_retry=true), the user message was already persisted by the
     first attempt.  Checkpoint reload does not include it (checkpoint is
     written only on success), so we still append to ctx — but skip persist
     to avoid duplicate entries in the session history file. *)
  let user_msg = Agent_sdk.Types.user_msg user_message in
  (* Capture history BEFORE appending the current user_msg.
     OAS Agent.run appends user_msg from ~goal internally, so passing it
     in initial_messages would cause duplication. *)
  (* OAS Utf8_sanitize.sanitize handles UTF-8 repair and control char
     stripping at serialization time (backend_openai_serialize.ml,
     backend_anthropic.ml). No pre-sanitize needed here. See OAS #916. *)
  (* Repair orphaned ToolResult blocks before passing to OAS Agent.run.
     Stale checkpoints saved before #7237 may contain tool_result blocks
     whose matching tool_use was trimmed. Anthropic API rejects these.
     repair_orphan_tool_result_messages downgrades orphans to plain Text. *)
  let history_messages =
    Keeper_context_core.repair_orphan_tool_result_messages ctx_work.messages
  in
  let ctx_work = Keeper_exec_context.append ctx_work user_msg in
  if not is_retry
  then Keeper_exec_context.persist_message ~source:history_user_source session user_msg;
  (* 7. Set up agent *)
  let ctx_snapshot = ctx_work in
  let agent_name = meta.agent_name in
  let meta_ref = ref meta in
  let agent_ref : Agent_sdk.Agent.t option ref = ref None in
  (* Session-local search function ref.  Uses the forward-ref pattern:
     1. Create a placeholder ref before make_tools (search index not yet built).
     2. Pass it to make_tools so each tool call captures this ref by value.
     3. After building the search index, update the ref with the real impl.
     This makes keeper_tool_search session-scoped and race-free: each keeper
     session owns its own ref; concurrent sessions never touch each other's state. *)
  let local_search_fn_ref : (query:string -> max_results:int -> Yojson.Safe.t) ref =
    ref (fun ~query:_ ~max_results:_ -> `Assoc [ "results", `List [] ])
  in
  (* Track current agent turn so Keeper_discovered_tools.add/mark_used
     use the real turn rather than a constant 0.  Updated at the start of
     each turn inside before_turn_params. *)
  let current_turn_ref : int ref = ref 0 in
  (* Per-session discovered tools: populated by keeper_tool_search,
     consumed by before_turn_hook in discovery mode.
     Defined here (before make_tools) so on_tool_called can capture it. *)
  let decay_turns =
    match Sys.getenv_opt "MASC_KEEPER_TOOL_DECAY_TURNS" with
    | Some s ->
      (try max 1 (int_of_string s) with
       | Failure _ ->
         Log.Keeper.warn
           "keeper: MASC_KEEPER_TOOL_DECAY_TURNS=%S is not a valid integer, using default 5"
           s;
         5)
    | None -> 5
  in
  let discovered_ref = ref (Keeper_discovered_tools.create ~decay_turns) in
  let completion_contract_ref =
    ref Keeper_tool_disclosure.Allow_text_or_tool
  in
  (* L1 Tool Affinity: pre-populate discovered tools from trajectory history.
     Solves the 9B text_response trap by making proven tools visible at
     turn 0 without requiring keeper_tool_search first.  #5566 *)
  let affinity_k = Keeper_tool_affinity.configured_max_k () in
  if affinity_k > 0
  then (
    let masc_root = Filename.concat config.base_path ".masc" in
    let allowed = Keeper_tool_policy.keeper_allowed_tool_names meta in
    let core = Keeper_tool_registry.core_discovery_tools in
    let entries =
      Keeper_tool_affinity.pre_populate_from_history
        ~masc_root
        ~keeper_name:meta.name
        ~allowed_tool_names:allowed
        ~core_tool_names:core
        ~discovered:!discovered_ref
        ~max_k:affinity_k
    in
    if entries <> []
    then
      Log.Keeper.info
        "keeper:%s affinity pre-populated %d tools: [%s]"
        meta.name
        (List.length entries)
        (String.concat
           ", "
           (List.map
              (fun (e : Keeper_tool_affinity.affinity_entry) ->
                 Printf.sprintf "%s(%.1f)" e.tool_name e.score)
              entries)));
  let keeper_tools =
    Keeper_tools_oas.make_tools
      ~config
      ~meta
      ~ctx_snapshot
      ~search_fn:(fun ~query ~max_results -> !local_search_fn_ref ~query ~max_results)
      ~on_tool_called:(fun name ->
        Keeper_discovered_tools.mark_used !discovered_ref ~turn:!current_turn_ref ~name)
      ()
  in
  let extend_turns_tool = Keeper_extend_turns.make ~agent_ref ~max_turns () in
  let tools = extend_turns_tool :: keeper_tools in
  let tool_usage_before =
    Keeper_tool_disclosure.keeper_tool_usage_snapshot ~base_path:config.base_path ~keeper_name:meta.name
  in
  (* Progressive tool disclosure via OAS Tool_selector.
     Delegates BM25 retrieval, confidence gating, fallback, and optional
     LLM reranking to Tool_selector.select instead of manual Tool_index
     calls.  See OAS boundary violation #6.

     Korean keyword aliases: Tool_selector.select uses Tool_index.of_tools
     internally (aliases=[], group=None).  To preserve bilingual BM25
     matching, we append Korean keywords directly into tool descriptions.
     This gives equivalent BM25 term overlap.

     Trade-off vs previous manual approach:
     - Lost: group co-retrieval (e.g. matching keeper_board_post would
       pull keeper_board_comment).  Mitigated by k=20 which already
       retrieves enough related tools.
     - Lost: pre-built index reuse across turns.  Tool_selector rebuilds
       per call, but Tool_index construction is O(n) with n~30-60 for
       preset-scoped tools — sub-millisecond on M3.
     - Gained: single-point-of-truth for BM25+confidence+fallback+rerank
       logic.  ~120 fewer lines of manual retrieval code.

     TODO(OAS): Add Tool_selector.select_with_index that accepts a
     pre-built Tool_index.t to support aliases, groups, and index reuse.
     When that lands, this code can drop the description augmentation. *)
  (* Korean keyword map for bilingual BM25 matching.
     Tool descriptions are English; Korean users issue Korean queries.
     Appending Korean keywords to descriptions gives BM25 term overlap
     across languages.
     Keys must match actual tool names from keeper_tools. *)
  let korean_keywords =
    [ "keeper_board_post", "게시판 글 작성 올리기 포스트"
    ; "keeper_board_get", "게시판 글 읽기 조회 확인"
    ; "keeper_board_list", "게시판 목록 최근글"
    ; "keeper_board_comment", "게시판 댓글 답글 코멘트"
    ; "keeper_board_vote", "게시판 투표 추천 반대"
    ; "keeper_board_search", "게시판 검색 키워드 글찾기"
    ; "keeper_board_delete", "게시판 삭제 제거 글삭제"
    ; "keeper_board_stats", "게시판 통계 활동 참여 게시글수"
    ; "keeper_stay_silent", "침묵 대기 아무것도 안함 넘어가기"
    ; "keeper_write", "파일 작성 저장 새파일 생성 쓰기"
    ; "keeper_tool_search", "도구 검색 발견 찾기 어떤도구"
    ; "keeper_voice_listen", "음성 듣기 마이크 녹음 입력"
    ; "keeper_fs_read", "파일 읽기 소스코드 설정"
    ; "keeper_fs_edit", "파일 쓰기 편집 저장 수정 생성"
    ; "keeper_shell", "명령어 조회 검색 탐색 gh github pull request issue pr ci 풀리퀘스트 이슈"
    ; "keeper_bash", "명령어 실행 쉘 빌드 테스트"
    ; "keeper_pr_workflow", "PR 생성 워크트리 커밋 푸시 풀리퀘스트 원���"
    ; "keeper_memory_search", "기억 검색 대화 이전 메시지"
    ; "keeper_library_search", "라이브러리 지식 문서 검색"
    ; "keeper_library_read", "라이브러리 문서 읽기 지식"
    ; "keeper_time_now", "시간 현재 타임스탬프"
    ; "keeper_context_status", "컨텍스트 상태 토큰 사용량"
    ; "keeper_tools_list", "도구 목록 기능 할수있는것 능력"
    ; "keeper_broadcast", "브로드캐스트 알림 공지 전달"
    ; "keeper_tasks_list", "태스크 목록 할일 백로그"
    ; "keeper_tasks_audit", "태스크 감사 고아 방치"
    ; "keeper_task_claim", "태스크 가져오기 할당"
    ; "keeper_task_create", "태스크 생성 만들기 일감"
    ; "keeper_task_done", "태스크 완료 마감"
    ; "keeper_task_force_release", "태스크 강제해제 반환"
    ; "keeper_task_force_done", "태스크 강제완료"
    ; "keeper_voice_speak", "음성 말하기 보이스"
    ; "keeper_voice_agent", "음성 설정 보이스"
    ; "keeper_voice_sessions", "음성 세션 목록"
    ; "keeper_voice_session_start", "음성 세션 시작"
    ; "keeper_voice_session_end", "음성 세션 종료"
    ; (* masc_* tools: Korean keywords for cross-language BM25 retrieval.
       Without these, Korean queries like "코드 검색" only match keeper_*
       tools that have Korean aliases, systematically deprioritizing
       masc_* tools.  See #4520. *)
      "masc_code_search", "코드 검색 소스코드 찾기 심볼"
    ; "masc_code_read", "코드 읽기 파일 소스코드"
    ; "masc_code_edit", "코드 편집 수정 파일 변경"
    ; "masc_code_write", "코드 작성 파일 생성 쓰기"
    ; "masc_code_symbols", "코드 심볼 함수 클래스 정의"
    ; "masc_code_shell", "코드 명령어 쉘 실행"
    ; "masc_code_git", "깃 커밋 브랜치 로그 이력"
    ; "masc_governance_status", "거버넌스 상태 규칙 정책"
    ; "masc_governance_feed", "거버넌스 피드 이벤트 로그"
    ; "masc_autoresearch_start", "자동연구 리서치 시작"
    ; "masc_autoresearch_status", "자동연구 리서치 상태"
    ; "masc_autoresearch_stop", "자동연구 리서치 중지"
    ; "masc_autoresearch_cycle", "자동연구 리서치 사이클 실행"
    ; "masc_plan_get", "계획 플랜 마일스톤 로드맵 프로젝트 전략"
    ; "masc_plan_update", "계획 플랜 수정 업데이트"
    ; "masc_plan_init", "계획 플랜 초기화 생성"
    ; "masc_plan_set_task", "계획 태스크 설정 할당"
    ; "masc_plan_get_task", "계획 태스크 조회"
    ; "masc_agent_card", "에이전트 카드 프로필 정보"
    ; "masc_agents", "에이전트 목록 현황 누구"
    ; "masc_agent_update", "에이전트 업데이트 상태변경"
    ; "masc_keeper_up", "키퍼 시작 기동 생성"
    ; "masc_keeper_down", "키퍼 중지 종료"
    ; "masc_keeper_list", "키퍼 목록 현황"
    ; "masc_keeper_msg", "키퍼 메시지 전달 대화"
    ; "masc_keeper_status", "키퍼 상태 확인"
    ; "masc_keeper_compact", "키퍼 컨텍스트 압축 컴팩트 요약"
    ; "masc_keeper_clear", "키퍼 컨텍스트 초기화 클리어 비우기"
    ; "masc_worktree_create", "워크트리 생성 브랜치"
    ; "masc_worktree_list", "워크트리 목록 현황"
    ; "masc_worktree_remove", "워크트리 삭제 정리"
    ; "masc_tasks", "태스크 목록 할일 작업"
    ; "masc_add_task", "태스크 추가 등록 생성"
    ; "masc_status", "상태 현황 방 룸 요약"
    ; "masc_dashboard", "대시보드 현황 대시 보드 개요"
    ; "masc_plan_clear_task", "계획 태스크 제거 해제 클리어"
    ; "masc_agent_fitness", "에이전트 평가 점수 피트니스"
    ; "masc_web_search", "웹 검색 인터넷 온라인 구글"
    ; "masc_broadcast", "브로드캐스트 방송 알림 공지"
    ; "masc_claim_next", "다음태스크 가져오기 할당"
    ; "masc_messages", "메시지 대화 채팅 로그"
    ; "masc_leave", "퇴장 나가기 오프라인 종료"
      (* masc_broadcast, masc_who, masc_messages require MCP session context
       and fail in keeper. Use keeper_broadcast instead. (#4694) *)
    ]
  in
  (* Convert to Hashtbl for O(1) lookup — used in augment_tool_description
     and tool_entries aliases.  75 static entries, built once per session. *)
  let korean_kw_tbl =
    let tbl = Hashtbl.create 80 in
    List.iter (fun (k, v) -> Hashtbl.replace tbl k v) korean_keywords;
    tbl
  in
  (* Full-universe search index for keeper_tool_search.
     Separate from the preset-scoped Tool_selector used for progressive disclosure:
     search needs access to ALL tools so the keeper can discover beyond its preset.
     BM25 progressive disclosure is now delegated to OAS Tool_selector.select_names;
     this index serves only the explicit keeper_tool_search tool.
     top_k from Keeper_config for dashboard tuning; groups enable
     co-retrieval of related tools. *)
  let tool_index_config =
    { Agent_sdk.Tool_index.default_config with
      top_k = Keeper_config.keeper_tool_search_top_k ()
    }
  in
  let tool_entries =
    List.map (tool_index_entry_of_tool ~korean_kw_tbl) keeper_tools
  in
  (* Full-universe search index for keeper_tool_search.
     Separate from the preset-scoped Tool_selector used for progressive disclosure:
     search needs access to ALL tools so the keeper can discover beyond its preset.
     BM25 progressive disclosure is now delegated to OAS Tool_selector.select_names;
     this index serves only the explicit keeper_tool_search tool.
     Search results are post-filtered to keeper_allowed_tool_names
     so the keeper only sees tools it is actually permitted to call. *)
  let search_index = Agent_sdk.Tool_index.build ~config:tool_index_config tool_entries in
  let load_preset_selection_context () =
    let preset_names =
      Keeper_tool_policy.keeper_preset_universe_tool_names meta
    in
    let preset_set = Hashtbl.create (List.length preset_names) in
    List.iter (fun n -> Hashtbl.replace preset_set n true) preset_names;
    let preset_tools =
      List.filter
        (fun (t : Agent_sdk.Tool.t) -> Hashtbl.mem preset_set t.schema.name)
        keeper_tools
    in
    let progressive_tool_index_config =
      { Agent_sdk.Tool_index.default_config with
        top_k = keeper_selection_bm25_prefilter_n }
    in
    let preset_tool_entries =
      List.map (tool_index_entry_of_tool ~korean_kw_tbl) preset_tools
    in
    (preset_tools,
     Agent_sdk.Tool_index.build ~config:progressive_tool_index_config
       preset_tool_entries)
  in
  (* Map tool name → OAS schema for search result enrichment.
     Two maps: description (string) and full schema (tool_schema).
     Covers both keeper_* and masc_* tools from the OAS Tool.t list. *)
  let oas_description_map =
    let tbl = Hashtbl.create (List.length keeper_tools) in
    List.iter
      (fun (t : Agent_sdk.Tool.t) ->
         Hashtbl.replace tbl t.schema.name t.schema.description)
      keeper_tools;
    tbl
  in
  (* Map tool name → OAS input_schema JSON for keeper_tool_search enrichment.
     Covers keeper_* tools that don't appear in masc_schemas_ref. *)
  let oas_input_schema_map =
    let tbl = Hashtbl.create (List.length keeper_tools) in
    List.iter
      (fun (t : Agent_sdk.Tool.t) ->
         let param_type_str (pt : Agent_sdk.Types.param_type) =
           match pt with
           | String -> "string"
           | Integer -> "integer"
           | Number -> "number"
           | Boolean -> "boolean"
           | Array -> "array"
           | Object -> "object"
         in
         let props =
           List.map
             (fun (p : Agent_sdk.Types.tool_param) ->
                ( p.name
                , `Assoc
                    [ "type", `String (param_type_str p.param_type)
                    ; "description", `String p.description
                    ] ))
             t.schema.parameters
         in
         let required =
           t.schema.parameters
           |> List.filter (fun (p : Agent_sdk.Types.tool_param) -> p.required)
           |> List.map (fun (p : Agent_sdk.Types.tool_param) -> `String p.name)
         in
         let schema =
           `Assoc
             [ "type", `String "object"
             ; "properties", `Assoc props
             ; "required", `List required
             ]
         in
         Hashtbl.replace tbl t.schema.name schema)
      keeper_tools;
    tbl
  in
  (* Wire keeper_tool_search: update session-local ref with the real BM25 impl.
     Filtering excludes already-visible tools (core_discovery_tools in discovery
     mode, core_always_tools otherwise) so results are genuinely additional. *)
  (local_search_fn_ref
   := fun ~query ~max_results ->
        let core = Keeper_exec_tools.effective_core_tools () in
        let retrieved = Agent_sdk.Tool_index.retrieve search_index query in
        (* Pre-filter: exclude core tools, the search tool itself, and
       policy-denied tools.  Samchon principle: "if you can verify, you
       converge" — only return tools the keeper can actually call,
       preventing hallucinated attempts. *)
        let allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
        let allowed_set =
          let tbl = Hashtbl.create (List.length allowed) in
          List.iter (fun n -> Hashtbl.replace tbl n ()) allowed;
          tbl
        in
        let raw_hit_count = List.length retrieved in
        (* Samchon principle: "if the tool is already visible, tell the LLM
       which one" — prevents redundant search→call cycles. *)
        let matched_core_names =
          retrieved
          |> List.filter_map (fun (name, _) ->
            if List.mem name core || name = "keeper_tool_search" then Some name else None)
        in
        let after_core_filter =
          retrieved
          |> List.filter (fun (name, _) ->
            (not (List.mem name core)) && name <> "keeper_tool_search")
        in
        let after_policy_filter =
          after_core_filter |> List.filter (fun (name, _) -> Hashtbl.mem allowed_set name)
        in
        let new_discoveries =
          after_policy_filter |> List.filteri (fun i _ -> i < max_results)
        in
        let filtered_by_policy =
          List.length after_core_filter - List.length after_policy_filter
        in
        (* Register discovered tools for discovery-mode before_turn_hook
       using the actual current turn so decay/visibility stay aligned. *)
        let discovered_names = List.map fst new_discoveries in
        Keeper_discovered_tools.add
          !discovered_ref
          ~turn:!current_turn_ref
          ~names:discovered_names;
        (* Try MASC help_entry (from injected schemas), fall back to OAS description *)
        let masc_schemas = !Keeper_exec_tools.masc_schemas_ref in
        let results =
          List.map
            (fun (name, score) ->
               let help_opt = Tool_help_registry.find_entry masc_schemas name in
               let desc =
                 match help_opt with
                 | Some e -> `String e.short_description
                 | None ->
                   (match Hashtbl.find_opt oas_description_map name with
                    | Some d -> `String d
                    | None -> `Null)
               in
               let when_to_use =
                 match help_opt with
                 | Some e -> `String e.when_to_use
                 | None -> `Null
               in
               (* Samchon verification principle: include full input_schema so
           the LLM can construct a correct call on the first attempt.
           "Schema drives both LLM guidance and validation."
           Fallback chain: MASC injected schema → OAS tool schema. *)
               let input_schema =
                 match
                   List.find_opt
                     (fun (s : Types.tool_schema) -> s.name = name)
                     masc_schemas
                 with
                 | Some s -> s.input_schema
                 | None ->
                   (match Hashtbl.find_opt oas_input_schema_map name with
                    | Some j -> j
                    | None -> `Null)
               in
               `Assoc
                 [ "name", `String name
                 ; "score", `Float score
                 ; "description", desc
                 ; "when_to_use", when_to_use
                 ; "input_schema", input_schema
                 ])
            new_discoveries
        in
        let hint =
          match results, matched_core_names with
          | [], [] when raw_hit_count = 0 ->
            "No tools match this query. Try different keywords (e.g., 'worktree', \
             'board', 'github')."
          | [], _ :: _ when filtered_by_policy = 0 ->
            Printf.sprintf
              "Already loaded: %s. Call directly — no search needed."
              (String.concat ", " matched_core_names)
          | [], _ when filtered_by_policy > 0 ->
            let core_part =
              match matched_core_names with
              | [] -> ""
              | names -> Printf.sprintf " Already loaded: %s." (String.concat ", " names)
            in
            Printf.sprintf
              "Found %d matches but all filtered (already visible or policy-denied).%s"
              (filtered_by_policy + List.length matched_core_names)
              core_part
          | [], _ ->
            Printf.sprintf
              "Found %d raw BM25 hits but all are already in your core tool set."
              raw_hit_count
          | _, _ -> "Call any of these tools by name in this or a future turn."
        in
        `Assoc
          ([ "ok", `Bool true
           ; "query", `String query
           ; "results", `List results
           ; "result_count", `Int (List.length results)
           ]
           @ (match matched_core_names with
              | [] -> []
              | names ->
                [ "already_visible", `List (List.map (fun n -> `String n) names) ])
           @ [ ( "diagnostics"
               , `Assoc
                   [ "raw_bm25_hits", `Int raw_hit_count
                   ; ( "filtered_by_core"
                     , `Int (raw_hit_count - List.length after_core_filter) )
                   ; "filtered_by_policy", `Int filtered_by_policy
                   ] )
             ; "hint", `String hint
             ]));
  (* Visibility measurement (#4961): log universe size vs search scope *)
  if Keeper_types_profile.keeper_debug
  then
    Log.Keeper.debug
      "keeper:%s tool visibility: total=%d search_indexed=%d"
      meta.name
      (List.length keeper_tools)
      (List.length tool_entries);
  (* Layer 0: Core tools — always visible to the LLM regardless of preset.
     Kept to 5 survival-critical tools (#4961).  Status and other coordination tools
     (keeper_broadcast, keeper_task_claim, keeper_task_done, keeper_tasks_list,
     keeper_time_now, masc_tool_help) are now BM25-retrievable, freeing
     ranking budget for context-relevant tools. *)
  let always_include_tools = Keeper_exec_tools.core_always_tools in
  (* Layer 2: Universe — all tool names that the dispatch can handle.
     keeper_tools is now built from the universe (not just policy), so
     this includes all candidate tools minus denied.  BM25 retrieval
     and Tool_op.Add operate within this scope. *)
  let all_tool_names =
    "extend_turns" :: List.map (fun (t : Agent_sdk.Tool.t) -> t.schema.name) keeper_tools
  in
  (* Precompute membership table for AllowList validation below.
     all_tool_names is constant for the session; building universe_set
     once here avoids O(n) Hashtbl allocation on every turn. *)
  let universe_set = Keeper_tool_policy.tool_name_set all_tool_names in
  (* Precompute preset-executable set for AllowList pruning.
     Prevents tools visible via core_discovery_tools but blocked by
     preset (e.g. social keeper seeing keeper_fs_edit) from reaching
     the LLM and triggering tool_not_allowed errors. *)
  let allowed_exec_names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let allowed_exec_set =
    let set = Keeper_tool_policy.tool_name_set allowed_exec_names in
    (* Core always-tools bypass candidate_set in can_execute, so they
       may be absent from keeper_allowed_tool_names.  Add them back to
       prevent the preset filter from dropping survival-critical tools. *)
    List.iter
      (fun name -> Hashtbl.replace set name ())
      Keeper_tool_registry.core_always_tools;
    set
  in
  let max_tools_per_turn =
    if is_retry
    then Keeper_config.keeper_retry_max_tools_per_turn ()
    else Keeper_config.keeper_max_tools_per_turn ()
  in
  (* Runtime tool overlay: external callers (masc_tool_grant/revoke)
     push Tool_op.t values here. The hook applies them each turn.
     If caller provides one, use it; otherwise create a local one. *)
  let tool_overlay_ref =
    match tool_overlay with
    | Some r -> r
    | None -> ref Agent_sdk.Tool_op.Keep_all
  in
  (* Mutation boundary mechanism removed. Previously, the first successful
     mutating tool would open a "boundary" that blocked further tools and
     exited the OAS loop early. This caused keeper death spirals (#6801) and
     limited keepers to 1 mutating action per turn.
     Now: OAS Agent.run completes naturally (max_turns or model end_turn).
     Failure recovery: evidence records + operator notification via board,
     not sticky blocker state. See plan: enchanted-strolling-bonbon. *)
  let base_hooks =
    Keeper_hooks_oas.make_hooks
      ~config
      ~meta_ref
      ~session
      ~ctx_snapshot
      ~generation
      ?max_cost_usd
      ?trajectory_acc
      ()
  in
  (* BM25 Tool_selector removed: discovery mode uses core + keeper_tool_search.
     The search_index (full universe BM25) is still used by keeper_tool_search
     for explicit on-demand discovery. *)
  (* Compose dynamic_context injection + progressive tool disclosure
     in a single before_turn_params hook.

     Both modifications return AdjustParams, so they must be in the
     same hook to avoid compose's outer-bypasses-inner semantics.

     Progressive disclosure delegates to OAS Tool_selector.select:
     each turn selects the top-k tools most relevant to the current
     context, with confidence-gated fallback and optional LLM rerank.
     This replaces ~120 lines of manual Tool_index calls. *)
  let before_turn_hook : Agent_sdk.Hooks.hooks =
    { Agent_sdk.Hooks.empty with
      before_turn_params =
        Some
          (fun event ->
            match event with
            | Agent_sdk.Hooks.BeforeTurnParams
                { turn; current_params; messages; last_tool_results; _ } ->
              let hook_t0 = Time_compat.now () in
              (* Update current_turn_ref so session-scoped callbacks
           (keeper_tool_search, on_tool_called) use the correct turn. *)
              current_turn_ref := turn;
              (* Adaptive thinking override based on turn signals *)
              let adaptive_thinking_budget =
                adaptive_thinking_budget
                  ~enabled:(Keeper_config.keeper_adaptive_thinking_enabled ())
                  ~is_retry
                  ~last_tool_results
                  ~user_message
                  ~dynamic_context
                  ~current_budget:current_params.thinking_budget
              in
              let current_params =
                { current_params with thinking_budget = adaptive_thinking_budget }
              in
              (* 1. Dynamic context injection *)
              let ctx =
                if String.trim dynamic_context = ""
                then current_params.extra_system_context
                else (
                  match current_params.extra_system_context with
                  | None -> Some dynamic_context
                  | Some existing -> Some (existing ^ "\n\n" ^ dynamic_context))
              in
              (* 1b. Temporal context from context_injector (turn 1+) *)
              let ctx =
                match Masc_context_injector.render_temporal_summary shared_context with
                | None -> ctx
                | Some temporal ->
                  (match ctx with
                   | None -> Some temporal
                   | Some existing -> Some (existing ^ "\n\n" ^ temporal))
              in
              (* 2. Progressive tool disclosure via OAS Tool_selector.
           Extract context from last user message for relevance scoring. *)
              let last_user_text =
                List.fold_left
                  (fun acc (m : Agent_sdk.Types.message) ->
                     match m.role with
                     | Agent_sdk.Types.User -> Agent_sdk.Types.text_of_content m.content
                     | _ -> acc)
                  ""
                  messages
              in
              let query_text =
                (if String.trim last_user_text <> "" then last_user_text else user_message)
                |> Keeper_tool_disclosure.tool_query_text_of_user_message
              in
              let max_tools = max_tools_per_turn in
              let portal_ctx : Tool_portal.context = { config; agent_name = meta.name } in
              let visible_always_include_tools =
                Tool_portal.filter_visible_tool_names portal_ctx always_include_tools
              in
              (* Progressive tool disclosure: core tools are always visible;
           additional tools are selected by BM25 + optional LLM reranking
           (TopK_llm, gated by MASC_KEEPER_LLM_RERANK env var).
           When LLM rerank is disabled, only tools explicitly discovered
           via keeper_tool_search appear alongside core. *)
              let llm_rerank_enabled = Keeper_config.keeper_llm_rerank_enabled () in
              let effective_selected, deterministic_prefilter_count, llm_selected_count,
                  selection_mode =
                let core =
                  Keeper_exec_tools.effective_core_tools ()
                  |> List.filter (fun name -> Hashtbl.mem allowed_exec_set name)
                in
                let discovered =
                  Keeper_discovered_tools.active_names !discovered_ref ~turn
                in
                let _ = Keeper_discovered_tools.decay !discovered_ref ~turn in
                let selection_limit = min max_tools keeper_selection_top_k in
                let preset_tools, preset_search_index =
                  load_preset_selection_context ()
                in
                let deterministic_prefilter =
                  (* Keep a deterministic BM25 floor even when TopK_llm is disabled:
                     productive preset-local tools such as masc_code_search should
                     stay visible without requiring keeper_tool_search first. *)
                  Keeper_tool_disclosure.deterministic_prefilter_names
                    ~search_index:preset_search_index
                    ~query_text
                    ~selection_limit
                    ~core
                in
                let llm_selected =
                  if llm_rerank_enabled then
                    (match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
                     | Some sw, Some net ->
                       let rerank_cascade =
                         Keeper_config.keeper_llm_rerank_cascade ()
                       in
                       let defaults =
                         Oas_worker.default_model_strings ~cascade_name:rerank_cascade
                       in
                       let config_path = Oas_worker.default_config_path () in
                       let rerank_fn =
                         Agent_sdk.Tool_selector.default_rerank_fn
                           ~sw
                           ~net
                           ?config_path
                           ~cascade_name:rerank_cascade
                           ~defaults
                           ~k:selection_limit
                           ()
                       in
                       let strategy =
                         Agent_sdk.Tool_selector.TopK_llm
                           { k = selection_limit
                           ; bm25_prefilter_n =
                               min
                                 keeper_selection_bm25_prefilter_n
                                 (List.length preset_tools)
                           ; always_include = core
                           ; confidence_threshold = 0.3
                           ; rerank_fn
                           }
                       in
                       (try
                          let selected =
                            Agent_sdk.Tool_selector.select_names
                              ~strategy
                              ~context:query_text
                              ~tools:preset_tools
                          in
                          if Keeper_types_profile.keeper_debug
                          then
                            Log.Keeper.info
                              "keeper:%s TopK_llm selected %d tools (query_len=%d, \
                               candidates=%d)"
                              meta.name
                              (List.length selected)
                              (String.length query_text)
                              (List.length preset_tools);
                          selected
                        with
                        | Eio.Cancel.Cancelled _ as e -> raise e
                        | exn ->
                          Log.Keeper.warn
                            "keeper:%s TopK_llm failed (%s), falling back to \
                             core+prefilter+discovered"
                            meta.name
                            (Printexc.to_string exn);
                          [])
                     | _ ->
                       Log.Keeper.warn
                         "keeper:%s TopK_llm: Eio context unavailable, falling back \
                          to core+prefilter+discovered"
                         meta.name;
                       [])
                  else []
                in
                let merged =
                  Keeper_tool_disclosure.merge_tool_selection_boundary
                    ~core
                    ~deterministic_prefilter
                    ~llm_selected
                    ~discovered
                  |> Tool_portal.filter_visible_tool_names portal_ctx
                in
                let selection_mode =
                  if llm_rerank_enabled
                  then "deterministic_plus_llm_hint"
                  else "core_plus_prefilter_plus_discovered"
                in
                let deterministic_floor_set =
                  Keeper_types.dedupe_keep_order
                    (core @ deterministic_prefilter @ List.sort String.compare discovered)
                in
                let llm_only_count =
                  List.length
                    (List.filter
                       (fun n -> not (List.mem n deterministic_floor_set))
                       llm_selected)
                in
                merged, List.length deterministic_prefilter, llm_only_count,
                selection_mode
              in
              (* Apply runtime tool overlay (masc_tool_grant/revoke) and
           intersect with the full dispatch universe. *)
              let all_allowed =
                let raw =
                  Agent_sdk.Tool_op.apply
                    (Agent_sdk.Tool_op.compose
                       [ Agent_sdk.Tool_op.Replace_with effective_selected
                       ; !tool_overlay_ref
                       ])
                    all_tool_names
                  |> Tool_portal.filter_visible_tool_names portal_ctx
                in
                (* Validate AllowList against dispatch universe: tools visible
             to the LLM but absent from keeper_tools would cause execution
             errors and waste a turn.  Filter them out defensively.
             This can happen when core_discovery_tools includes tools
             not covered by the keeper's preset (e.g. minimal). *)
                let validated, dropped_names =
                  List.partition
                    (fun n ->
                       Hashtbl.mem universe_set n && Hashtbl.mem allowed_exec_set n)
                    raw
                in
                let dropped = List.length dropped_names in
                if dropped > 0
                then (
                  let max_logged = 10 in
                  let shown = List.filteri (fun i _ -> i < max_logged) dropped_names in
                  let omitted = dropped - List.length shown in
                  let shown_text = String.concat ", " shown in
                  let omitted_suffix =
                    if omitted > 0 then Printf.sprintf " (+%d more)" omitted else ""
                  in
                  Log.Keeper.warn
                    "keeper:%s turn:%d AllowList pruned %d tool(s) outside dispatch \
                     universe: %s%s"
                    meta.name
                    turn
                    dropped
                    shown_text
                    omitted_suffix);
                validated
              in
              let core_count = List.length (Keeper_exec_tools.effective_core_tools ()) in
              let discovered_count =
                List.length (Keeper_discovered_tools.active_names !discovered_ref ~turn)
              in
              if Keeper_types_profile.keeper_debug
              then
                Log.Keeper.info
                  "tool_disclosure keeper=%s core=%d deterministic_prefilter=%d \
                   discovered=%d llm_selected=%d llm_rerank=%b allowed=%d query_len=%d \
                   mode=%s"
                  meta.name
                  core_count
                  deterministic_prefilter_count
                  discovered_count
                  llm_selected_count
                  llm_rerank_enabled
                  (List.length all_allowed)
                  (String.length query_text)
                  selection_mode;
              (* 3. Graceful last-turn: inject budget warnings and restrict
           tools when approaching the turn limit.
           - Warning zone (2 turns before limit): inject budget warning
           - Last turn (1 turn before limit): restrict to safe tools + force [STATE]
           The keeper can still call extend_turns to escape the limit. *)
              (* With Agent.resume, turn is cumulative from checkpoint.
           Use per-call turn count for budget calculations. *)
              let per_call_turn = turn - start_turn_count in
              let is_last_turn = per_call_turn >= max_turns - 1 in
              let is_warning_zone = per_call_turn >= max_turns - 2 in
              let append_ctx ctx text =
                Some
                  (match ctx with
                   | None -> text
                   | Some e -> e ^ "\n\n" ^ text)
              in
              let ctx =
                if is_last_turn
                then
                  append_ctx
                    ctx
                    (Printf.sprintf
                       "[LAST TURN] Turn %d/%d. This is your final turn. You MUST emit a \
                        [STATE]...[/STATE] block now summarizing what you accomplished \
                        and what the next generation should do. Do NOT start new tool \
                        work. If you need more turns, call extend_turns. If you claimed \
                        a task, call keeper_task_done NOW before session ends."
                       turn
                       max_turns)
                else if is_retry
                then
                  append_ctx
                    ctx
                    (Printf.sprintf
                       "[RETRY] The previous attempt overflowed the model context. Stay \
                        concise, prefer already-loaded context, and only use the \
                        smallest essential tool set if a tool call is strictly \
                        necessary. Current tool budget: %d."
                       max_tools)
                else if is_warning_zone
                then
                  append_ctx
                    ctx
                    (Printf.sprintf
                       "[BUDGET] %d/%d turns used. Wrap up current work and emit a \
                        [STATE] block. Call extend_turns if you need more time."
                       turn
                       max_turns)
                else ctx
              in
              let safe_last_turn_tools =
                Keeper_tool_policy.last_turn_safe_tool_names ()
              in
              let all_allowed =
                if is_last_turn
                then
                  Agent_sdk.Tool_op.apply
                    (Agent_sdk.Tool_op.Intersect_with safe_last_turn_tools)
                    all_allowed
                else all_allowed
              in
              if is_warning_zone
              then
                Log.Keeper.info
                  "keeper:%s turn_budget turn=%d/%d last_turn=%b"
                  meta.name
                  turn
                  max_turns
                  is_last_turn;
              (* Context overflow guard: Tool_selector.select already respects
           the k limit, but overlays can grow the visible set beyond
           max_tools.  Cap the post-overlay set to stay inside small-model
           context windows. Configurable via MASC_KEEPER_MAX_TOOLS_PER_TURN. *)
              let all_allowed =
                if List.length all_allowed > max_tools
                then (
                  Log.Keeper.info
                    "context overflow guard: %d tools > max %d, truncating"
                    (List.length all_allowed)
                    max_tools;
                  let essential =
                    List.filter
                      (fun name -> List.mem name visible_always_include_tools)
                      all_allowed
                  in
                  let non_essential =
                    List.filter
                      (fun name -> not (List.mem name visible_always_include_tools))
                      all_allowed
                  in
                  let budget = max_tools - List.length essential in
                  essential @ List.filteri (fun i _ -> i < budget) non_essential)
                else all_allowed
              in
              let tool_filter = Agent_sdk.Guardrails.AllowList all_allowed in
              (* Tool choice: Any on all non-last turns.
           "Must call a tool" is deterministic (API enforces).
           "Which tool" is non-deterministic (model chooses).
           OAS handles provider differences:
             - GLM: Any → Auto (api_openai.ml, GLM only supports auto)
             - Ollama (supports_tool_choice=false): contract relaxed
             - Claude/OpenAI: Any = required, enforced by API
           Reconcile/mutation-boundary removed — #6801 root cause
           was sticky_reconcile, not tool_choice=Any itself. *)
              let tool_choice =
                if is_last_turn || List.length all_allowed = 0
                then current_params.tool_choice (* last turn: preserve caller's choice *)
                else Some Agent_sdk.Types.Any (* all other turns: force tool use *)
              in
              completion_contract_ref :=
                Keeper_tool_disclosure.completion_contract_of_tool_choice tool_choice;
              let lane =
                if is_retry then "retry"
                else (
                  match tool_choice with
                  | Some (Agent_sdk.Types.Any | Agent_sdk.Types.Tool _) ->
                    "tool_required"
                  | Some Agent_sdk.Types.None_ -> "tool_disabled"
                  | _ -> "tool_optional")
              in
              Keeper_tool_call_log.set_turn_context
                ~keeper_name:meta.name
                ~lane
                ?tool_choice:(Option.map
                  (fun choice ->
                    Yojson.Safe.to_string
                      (Agent_sdk.Types.tool_choice_to_json choice))
                  tool_choice)
                ~thinking_enabled:(Keeper_config.keeper_enable_thinking ())
                ?thinking_budget:current_params.thinking_budget
                ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                ~turn
                ();
              (* Tool disclosure telemetry: emitted after all allow-list rewrites
           (last-turn intersect, max_tools cap) so that
           final_visible and hook_ms reflect the actual state sent to AdjustParams.
           Capture now once so ts_unix and hook_ms are consistent. *)
              (let now = Time_compat.now () in
               let hook_elapsed_ms = Keeper_timing.round1 ((now -. hook_t0) *. 1000.0) in
               let disclosure_json =
                 `Assoc
                   [ "ts_unix", `Float now
                   ; "event", `String "tool_disclosure"
                   ; "keeper_name", `String meta.name
                   ; "turn", `Int turn
                   ; "selection_mode", `String selection_mode
                   ; "core_count", `Int core_count
                   ; "deterministic_prefilter_count", `Int deterministic_prefilter_count
                   ; "discovered_count", `Int discovered_count
                   ; "llm_selected_count", `Int llm_selected_count
                   ; "final_visible", `Int (List.length all_allowed)
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
                 Log.Keeper.warn
                   "keeper:%s tool_disclosure jsonl append failed: %s"
                   meta.name
                   (Printexc.to_string exn));
              (* Yield after CPU-bound tool filtering to let HTTP handlers run.
           Without this, N concurrent keeper fibers starve the Eio scheduler
           during turn setup (tool list construction + prompt building). *)
              Eio.Fiber.yield ();
              Agent_sdk.Hooks.AdjustParams
                { current_params with
                  extra_system_context = ctx
                ; tool_choice
                ; tool_filter_override = Some tool_filter
                }
            | _ -> Agent_sdk.Hooks.Continue)
    }
  in
  let hooks = Agent_sdk.Hooks.compose ~outer:before_turn_hook ~inner:base_hooks in
  let base_dir = Filename.concat config.base_path ".masc" in
  (* RFC-MASC-004 Phase 2: Hook-first is now the only path.
     Create bare memory (no imperative seeding). Memory content is
     injected via BeforeTurnParams hook; flush is incremental via
     AfterTurn hook. The memory instance is still needed for flush. *)
  let memory =
    Memory_oas_bridge.create_memory
      ~agent_name
      ~base_dir
      ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ()
  in
  (* RFC-MASC-004: Memory hooks provide before_turn_params (text injection)
     and after_turn (incremental flush). Composed as outermost layer so
     memory context is available to all downstream hooks. *)
  let hooks =
    let mem_hooks =
      Memory_hooks.make
        ~agent_name ~config ~memory
        ~episode_limit:memory_episode_limit
        ~procedure_limit:memory_procedure_limit ()
    in
    Agent_sdk.Hooks.compose ~outer:mem_hooks ~inner:hooks
  in
  let reducer =
    Agent_sdk.Context_reducer.compose [
      Agent_sdk.Context_reducer.drop_thinking;
      Agent_sdk.Context_reducer.stub_tool_results ~keep_recent:3;
      Agent_sdk.Context_reducer.prune_tool_outputs ~max_output_len:4000;
      Agent_sdk.Context_reducer.cap_message_tokens ~max_tokens:32000 ~keep_recent:3;
      Agent_sdk.Context_reducer.repair_dangling_tool_calls;
      Agent_sdk.Context_reducer.merge_contiguous;
    ]
  in
  (* 8. Run Agent *)
  let contract =
    if Env_config.Cdal.enabled () then Keeper_cdal_contract.of_keeper_meta meta else None
  in
  let yield_on_tool = Env_config.Slot.yield_enabled () in
  let on_yield =
    if yield_on_tool
    then
      Some (fun () -> Log.Misc.debug "keeper %s: slot yielded (tool execution)" meta.name)
    else None
  in
  let on_resume =
    if yield_on_tool
    then
      Some (fun () -> Log.Misc.debug "keeper %s: slot resumed (next LLM turn)" meta.name)
    else None
  in
  let priority = Option.value priority ~default:Llm_provider.Request_priority.Proactive in
  let admission_wait_timeout_sec =
    if Llm_provider.Request_priority.resolve priority
       = Llm_provider.Request_priority.Proactive
    then Some Env_config_keeper.KeeperKeepalive.admission_wait_timeout_sec
    else None
  in
  ignore (Keeper_alerting_path.ensure_playground_bundle ~config ~name:meta.name);
  let effective_allowed_paths = Keeper_alerting_path.effective_allowed_paths ~meta in
  match
    Keeper_alerting_path.absolute_allowed_paths_result
      ~config
      ~allowed_paths:effective_allowed_paths
  with
  | Error e -> Error (Oas.Error.Internal e)
  | Ok oas_allowed_paths ->
    let timeout_s =
      match oas_timeout_s with
      | Some value -> value
      | None ->
          Env_config_keeper.KeeperKeepalive.oas_timeout_for_context ~max_context
    in
    (match
       Keeper_llm_bridge.run_with_timeout_and_fallback ~timeout_s (fun () ->
         Oas_worker.run_named
           ~cascade_name
           ~model_strings:meta.models
           ?provider_filter
           ~goal:user_message
           ~priority
           ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
           ~system_prompt:turn_system_prompt
           ~tools
           ~compact_ratio:meta.compaction.ratio_gate
           ~initial_messages:history_messages
           ~hooks
           ~context_reducer:reducer
           ~memory
             (* Keepers use turn-level retry for transient errors but benefit
               from OAS per-call retry for validation errors (malformed tool
               args). retry_on_validation_error=true lets OAS re-prompt the
               LLM with structured feedback instead of wasting a full turn.
               retry_on_recoverable_tool_error remains false — tool-level
               errors are handled by MASC's consecutive failure guardrail. *)
           ~tool_retry_policy:{
             Oas.Tool_retry_policy.max_retries = 2;
             retry_on_validation_error = true;
             retry_on_recoverable_tool_error = false;
             feedback_style = Oas.Tool_retry_policy.Structured_tool_result;
           }
           ~max_turns
           ~max_idle_turns
           ~temperature
           ~max_tokens
           ?max_cost_usd
           ?wait_timeout_sec:admission_wait_timeout_sec
           ?guardrails
           ?on_event
           ?on_yield
           ?on_resume
           ~agent_ref
           ?contract
           ~allowed_paths:oas_allowed_paths
           ~cache_system_prompt:true
           ~yield_on_tool
           ~checkpoint_dir:session_dir
           ~context_injector
           ~context:shared_context
           ?slot_id:(Keeper_config.keeper_slot_id meta.name)
           ~approval:(Governance_pipeline.to_oas_approval_callback
                        ~governance_level:(Env_config_core.governance_level ())
                        ~keeper_name:meta.name)
           ~enable_thinking:(Keeper_config.keeper_enable_thinking ())
           (* exit_condition removed with mutation_boundary — OAS runs to
              natural completion (max_turns or model end_turn). *)
           ?oas_checkpoint:raw_oas_checkpoint
           ?event_bus
           ())
     with
     | Error e -> Error e
     | Ok result ->
       let post_turn_t0 = Time_compat.now () in
       (* Checkpoint save is deferred until after [STATE] synthesis so the
           persisted checkpoint includes the synthesized continuity block.
           Without this, read_continuity_summary finds no [STATE] in the
           checkpoint messages and returns empty — causing keepers to lose
           context across turns.  See #5431. *)
       (* RFC-MASC-004: AfterTurn hooks flush incrementally during
          Agent.run. Post-run episode creation requires an explicit
          flush_incremental call since AfterTurn already fired. *)
       let text = Agent_sdk.Types.text_of_content result.response.content in
       let model = result.response.model in
       (* Extract and persist thinking blocks to trajectory JSONL.
           NOTE: turn = acc.turn stays at 0 in the keeper path because
           Trajectory.increment_turn is never called here — the keeper
           uses OAS Agent.run which manages its own internal call count.
           Consumers should treat turn=0 as "turn not tracked in keeper path". *)
       (match trajectory_acc with
        | Some acc ->
          let now = Time_compat.now () in
          let now_iso = Types.now_iso () in
          List.iter
            (function
              | Agent_sdk.Types.Thinking { content; _ } ->
                let entry : Trajectory.thinking_entry =
                  { ts = now
                  ; ts_iso = now_iso
                  ; turn = acc.Trajectory.turn
                  ; content
                  ; content_length = String.length content
                  ; redacted = false
                  }
                in
                (try
                   Trajectory.append_thinking
                     ~masc_root:acc.Trajectory.masc_root
                     ~keeper_name:acc.Trajectory.keeper_name
                     ~trace_id:acc.Trajectory.trace_id
                     entry
                 with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                   Log.Keeper.error
                     "keeper:%s thinking persist failed: %s"
                     meta.name
                     (Printexc.to_string exn))
              | Agent_sdk.Types.RedactedThinking _ ->
                let entry : Trajectory.thinking_entry =
                  { ts = now
                  ; ts_iso = now_iso
                  ; turn = acc.Trajectory.turn
                  ; content = "[redacted]"
                  ; content_length = 0
                  ; redacted = true
                  }
                in
                (try
                   Trajectory.append_thinking
                     ~masc_root:acc.Trajectory.masc_root
                     ~keeper_name:acc.Trajectory.keeper_name
                     ~trace_id:acc.Trajectory.trace_id
                     entry
                 with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                   Log.Keeper.error
                     "keeper:%s redacted thinking persist failed: %s"
                     meta.name
                     (Printexc.to_string exn))
              | _ -> ())
            result.response.content
        | None -> ());
       let reported_tool_names =
         List.filter_map
           (function
             | Agent_sdk.Types.ToolUse { name; _ } -> Some name
             | _ -> None)
           result.response.content
       in
       let tool_usage_after =
         Keeper_tool_disclosure.keeper_tool_usage_snapshot ~base_path:config.base_path ~keeper_name:meta.name
       in
       let observed_tool_names =
         Keeper_tool_disclosure.tool_usage_delta ~before:tool_usage_before ~after:tool_usage_after
       in
       let tool_names =
         Keeper_tool_disclosure.merge_reported_and_observed_tool_names ~reported_tool_names ~observed_tool_names
       in
       let usage = Keeper_exec_context.usage_of_response result.response in
       let ctx_composition =
         build_ctx_composition_metrics
           ~system_prompt:turn_system_prompt
           ~dynamic_context
           ~memory_context
           ~temporal_context
           ~user_message
           ~history_messages
           ~actual_input_tokens:usage.input_tokens
       in
       (* Text-response trap tolerance: when tool_choice=Any is set but
          the provider ignores it (e.g. Ollama #14493), the model returns
          text-only on non-last turns. Instead of hard-failing the turn
          (which wastes the entire OAS run), log a warning and treat the
          text response as valid. The turn is counted as text_response
          in telemetry via keeper_unified_turn. See #5566. *)
       let text =
         match
           Keeper_tool_disclosure.validate_completion_contract
             ~contract:!completion_contract_ref
             ~tool_names
             ()
         with
         | Ok () -> text
         | Error reason ->
           let contract_str =
             match !completion_contract_ref with
             | Keeper_tool_disclosure.Allow_text_or_tool -> "Allow_text_or_tool"
             | Keeper_tool_disclosure.Require_tool_use -> "Require_tool_use"
           in
           Log.Keeper.warn
             "keeper:%s text_response trap: tool contract violated \
              (turn=%d, tools=0, contract=%s). \
              Provider likely ignored tool_choice=Any. Tolerating text-only \
              response to avoid wasting OAS run. Reason: %s"
             meta.name result.turns contract_str reason;
           (* When both text and tool_names are empty, normalize_response_text
              would hard-fail. Synthesize minimal text so the turn survives. *)
           if String.trim text = "" && tool_names = []
           then "[no output]"
           else text
       in
       (match Keeper_tool_disclosure.normalize_response_text ~text ~tool_names () with
        | Error e -> Error (Oas.Error.Internal e)
        | Ok response_text ->
          (* Ensure every generation has a [STATE] block for continuity.
             If the model omitted it, synthesize one deterministically
             from tool usage and stop reason. *)
          let response_text =
            match Keeper_memory_policy.find_state_block response_text with
               | Some _ -> response_text
               | None ->
                 let stop_reason_str =
                   match result.stop_reason with
                   | Oas_worker.Completed -> "completed"
                   | Oas_worker.TurnBudgetExhausted _ -> "budget_exhausted"
                   | Oas_worker.MutationBoundaryReached { tool_name; _ } ->
                       (match tool_name with
                        | Some tool -> Printf.sprintf "mutation_boundary(%s)" tool
                        | None -> "mutation_boundary")
                 in
                 let synth =
                   Keeper_memory_policy.synthesize_state_from_run_result
                     ~goal:meta.goal
                     ~tools_used:tool_names
                     ~stop_reason:stop_reason_str
                     ~response_text
                 in
                 let block = Keeper_memory_policy.render_state_block synth in
                 Log.Keeper.info
                   "keeper:%s [STATE] missing, synthesized from %d tools (stop=%s)"
                   meta.name
                   (List.length tool_names)
                   stop_reason_str;
                 response_text ^ "\n" ^ block
             in
             let assistant_msg = Agent_sdk.Types.assistant_msg response_text in
             Keeper_exec_context.persist_message
               ~source:history_assistant_source
               session
               assistant_msg;
          (* ctx_snapshot is immutable — assistant message is persisted
                via checkpoint (OAS) and persist_message (history file).
                No in-memory mutation needed; next turn reconstructs
                context from checkpoint. *)
          (* Save checkpoint AFTER [STATE] synthesis.  Patch the last
                assistant message in the OAS checkpoint so that the persisted
                checkpoint contains the [STATE] block.  Without this patch,
                read_continuity_summary would find no [STATE] in checkpoint
                messages and return empty, causing context loss.  #5431 *)
          let saved_checkpoint =
            match result.checkpoint with
            | Some checkpoint ->
              let patched =
                Keeper_context_core.patch_checkpoint_last_assistant
                  checkpoint
                  ~session_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                  ~response_text
              in
              (match
                 Keeper_checkpoint_store.save_oas ~session_dir:session.session_dir patched
               with
               | Ok () -> ()
               | Error e ->
                 Log.Keeper.error "keeper:%s OAS checkpoint save failed: %s" meta.name e);
              Some patched
            | None ->
              Log.Keeper.warn "keeper:%s missing OAS checkpoint after run" meta.name;
              None
          in
          (match result.proof with
           | Some p ->
             Keeper_turn_telemetry.log_keeper_proof ~keeper_name:meta.name p;
             let store = Agent_sdk.Proof_store.default_config in
             let outcome = Cdal_eval_v1.evaluate ~store p in
             let verdict = Cdal_eval_v1.verdict_of_outcome outcome in
             Cdal_eval_v1.persist verdict;
             Keeper_turn_telemetry.log_keeper_contract_verdict ~keeper_name:meta.name verdict;
             (match outcome with
              | Cdal_eval_v1.Load_failure (err, _) ->
                Log.Keeper.warn
                  "keeper:%s contract_verdict load failure: %s"
                  meta.name
                  (Cdal_loader.load_error_to_string err)
              | Cdal_eval_v1.Verdict (_, _) -> ());
             (match Cdal_eval_v1.friction_of_outcome outcome with
              | Some fp -> Keeper_turn_telemetry.log_keeper_friction ~keeper_name:meta.name fp
              | None -> ())
           | None -> ());
          (* Post-turn deterministic memory write.
            Uses meta-based fallback when [STATE] parsing fails.
            See RFC #3646 Section 3: Det/NonDet boundary. *)
          (try
             let notes_written, kinds_written =
               Keeper_memory_bank.append_memory_notes_from_reply
                 config
                 meta
                 ~turn:result.turns
                 ~reply:response_text
             in
             if notes_written > 0
             then
               Keeper_turn_telemetry.log_keeper_memory_write
                 ~keeper_name:meta.name
                 ~notes_written
                 ~kinds_written
           with
           | exn ->
             Log.Keeper.warn
               "keeper:%s memory_write failed: %s"
               meta.name
               (Printexc.to_string exn));
          (* Episodic memory: create OAS episode from [STATE] snapshot.
             store_episode adds to Memory.t, then flush_incremental
             persists to institution_episodes.jsonl. The explicit flush
             is required because this runs AFTER Agent.run returns, so
             the AfterTurn hook has already fired for the last turn. *)
          (try
             (match
                Keeper_memory_policy.parse_state_snapshot_from_reply
                  response_text
              with
             | Some snap ->
               Memory_oas_bridge.store_episode_from_snapshot ~memory
                 ~keeper_name:meta.name ~turn:result.turns
                 ~trace_id:
                   (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                 snap;
               let ep, pr =
                 Memory_oas_bridge.flush_incremental ~memory
                   ~agent_name:meta.name
               in
               if ep > 0 || pr > 0 then begin
                 Log.Keeper.debug
                   "keeper:%s post-run flush episodes=%d procedures=%d"
                   meta.name ep pr;
                 (* Emit activity event so episode flushes appear in
                    the activity graph / telemetry surface. *)
                 (try
                    !Room_hooks.activity_emit_fn config
                      ~actor:Room_hooks.{ kind = "keeper"; id = meta.name }
                      ~kind:"episode.flush"
                      ~payload:(`Assoc [
                        ("keeper", `String meta.name);
                        ("episodes", `Int ep);
                        ("procedures", `Int pr);
                        ("turn", `Int result.turns);
                      ])
                      ~tags:[ "memory"; "episode"; "flush" ]
                      ()
                  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ())
               end
             | None -> ())
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
               Log.Keeper.warn "keeper:%s episode_create failed: %s"
                 meta.name (Printexc.to_string exn));
          (* Memory bank compaction: dedup + consolidate if over threshold. *)
          (try
             let compaction =
               Keeper_memory_bank.compact_memory_bank_if_needed config meta
             in
             if compaction.performed then
               Log.Keeper.info
                 "keeper:%s memory_compacted before=%d after=%d dropped=%d"
                 meta.name compaction.before_notes compaction.after_notes
                 compaction.dropped_notes
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
               Log.Keeper.warn "keeper:%s compaction failed: %s" meta.name
                 (Printexc.to_string exn));
          (* Post-turn quality metrics — goal alignment + memory recall.
            Logged to decisions.jsonl for feedback loop analysis. *)
          (try
             let goal_score =
               Keeper_memory_recall.goal_alignment_score
                 ~meta
                 ~user_message:None
                 ~assistant_reply:(Some response_text)
             in
             let used_search =
               List.exists (fun t -> t = "keeper_memory_search") tool_names
             in
             let recall_eval =
               if used_search
               then (
                 let bank_path =
                   Keeper_types_support.keeper_memory_bank_path config meta.name
                 in
                 let candidates =
                   try
                     Keeper_memory_recall.load_history_user_messages
                       ~path:bank_path
                       ~max_n:50
                   with
                   | Eio.Cancel.Cancelled _ as e -> raise e
                   | exn ->
                     Log.Keeper.warn
                       "keeper:%s memory recall history load failed: %s"
                       meta.name
                       (Printexc.to_string exn);
                     []
                 in
                 Some
                   (Keeper_memory_recall.evaluate_memory_recall
                      ~user_message:""
                      ~assistant_reply:response_text
                      ~candidates))
               else None
             in
             let post_turn_ms =
               Keeper_timing.round1 ((Time_compat.now () -. post_turn_t0) *. 1000.0)
             in
             let eval_json =
               `Assoc
                 ([ "ts_unix", `Float (Time_compat.now ())
                  ; "event", `String "post_turn_eval"
                  ; "keeper_name", `String meta.name
                  ; "turn", `Int result.turns
                  ; "goal_alignment", `Float goal_score
                  ; "tools_used_count", `Int (List.length tool_names)
                  ; "used_memory_search", `Bool used_search
                  ; "post_turn_ms", `Float post_turn_ms
                  ]
                  @ (match result.response.telemetry with
                     | Some t ->
                       [ ( "inference_telemetry"
                         , Agent_sdk.Types.inference_telemetry_to_yojson t )
                       ]
                     | None -> [])
                  @
                  match recall_eval with
                  | Some e ->
                    [ "memory_recall_performed", `Bool e.performed
                    ; "memory_recall_passed", `Bool e.passed
                    ; "memory_recall_score", `Float e.final_score
                    ; "memory_recall_candidates", `Int e.candidate_count
                    ]
                  | None -> [])
             in
             Keeper_types_support.append_jsonl_line
               (Keeper_types_support.keeper_decision_log_path config meta.name)
               eval_json
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             Log.Keeper.warn
               "keeper:%s post_turn_eval jsonl append failed: %s"
               meta.name
               (Printexc.to_string exn));
             Ok
               { response_text
               ; model_used = model
               ; prompt_metrics
               ; ctx_composition
               ; cascade_observation = result.cascade_observation
               ; turn_count = result.turns
               ; tool_calls_made = List.length tool_names
               ; usage
               ; tools_used = tool_names
               ; checkpoint = saved_checkpoint
               ; proof = result.proof
               ; trace_ref = result.trace_ref
               ; run_validation = result.run_validation
               ; stop_reason = result.stop_reason
               ; inference_telemetry = result.response.telemetry
               }))
;;
