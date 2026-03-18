(** Relay tools - Infinite context via handoff *)

open Tool_args

type context = {
  config: Room.config;
  agent_name: string;
  sw: Eio.Switch.t;
  proc_mgr: Eio_unix.Process.mgr_ty Eio.Resource.t option;
}

type result = bool * string

let handle_relay_status _ctx args =
  let messages = get_int args "messages" 0 in
  let tool_calls = get_int args "tool_calls" 0 in
  let model = get_string args "model" "claude" in
  let metrics = Relay.estimate_context ~messages ~tool_calls ~model in
  (* Record actual tokens for calibration if provided *)
  let actual_tokens_opt = match Yojson.Safe.Util.member "actual_tokens" args with
    | `Int n -> Some n
    | _ -> None
  in
  (match actual_tokens_opt with
   | Some actual ->
     Relay.record_actual_tokens ~estimated:metrics.Relay.estimated_tokens ~actual
   | None -> ());
  let should_relay = Relay.should_relay ~config:Relay.default_config ~metrics in
  let json = `Assoc [
    ("estimated_tokens", `Int metrics.Relay.estimated_tokens);
    ("max_tokens", `Int metrics.Relay.max_tokens);
    ("usage_ratio", `Float metrics.Relay.usage_ratio);
    ("message_count", `Int metrics.Relay.message_count);
    ("tool_call_count", `Int metrics.Relay.tool_call_count);
    ("should_relay", `Bool should_relay);
    ("calibration", Relay.get_calibration_info ());
  ] in
  (true, Yojson.Safe.pretty_to_string json)

let handle_relay_checkpoint _ctx args =
  let summary = get_string args "summary" "" in
  let current_task = get_string_opt args "current_task" in
  let todos = get_string_list args "todos" in
  let pdca_state = get_string_opt args "pdca_state" in
  let relevant_files = get_string_list args "relevant_files" in
  (* Goal fields are parsed for validation but not yet persisted in checkpoint.
     They will be wired into checkpoint storage when Goal Store integration
     is added to the relay module (tracked in Phase 2 roadmap). *)
  let _active_goal_ids = get_string_list args "active_goal_ids" in
  let _goal_blockers = get_string_list args "goal_blockers" in
  let _goal_progress = match Yojson.Safe.Util.member "goal_progress" args with
    | `List items -> List.filter_map (fun item ->
        match item with
        | `List [`String gid; `Float pct] -> Some (gid, pct)
        | `List [`String gid; `Int n] -> Some (gid, float_of_int n)
        | _ -> None
      ) items
    | _ -> []
  in
  let cell = !(Mcp_server.current_cell) in
  let messages = get_int args "messages" cell.Mitosis.task_count in
  let tool_calls = get_int args "tool_calls" cell.Mitosis.tool_call_count in
  let metrics = Relay.estimate_context ~messages ~tool_calls ~model:"claude" in
  let _ = Relay.save_checkpoint ~summary ~task:current_task ~todos ~pdca:pdca_state ~files:relevant_files ~metrics in
  let json = `Assoc [
    ("status", `String "checkpoint_saved");
    ("usage_ratio", `Float metrics.Relay.usage_ratio);
    ("estimated_tokens", `Int metrics.Relay.estimated_tokens);
    ("calibration", Relay.get_calibration_info ());
  ] in
  (true, Yojson.Safe.pretty_to_string json)

let handle_relay_now ctx args =
  let summary = get_string args "summary" "" in
  let current_task = get_string_opt args "current_task" in
  let target_agent = get_string args "target_agent" "claude" in
  let generation = get_int args "generation" 0 in
  let active_goal_ids = get_string_list args "active_goal_ids" in
  let goal_blockers = get_string_list args "goal_blockers" in
  let goal_progress = match Yojson.Safe.Util.member "goal_progress" args with
    | `List items -> List.filter_map (fun item ->
        match item with
        | `List [`String gid; `Float pct] -> Some (gid, pct)
        | `List [`String gid; `Int n] -> Some (gid, float_of_int n)
        | _ -> None
      ) items
    | _ -> []
  in
  let todos = get_string_list args "todos" in
  let pdca_state = get_string_opt args "pdca_state" in
  let relevant_files = get_string_list args "relevant_files" in
  let session_id = get_string_opt args "session_id" in
  let payload : Relay.handoff_payload = {
    summary;
    current_task;
    todos;
    pdca_state;
    relevant_files;
    session_id;
    relay_generation = generation;
    active_goal_ids;
    goal_progress;
    goal_blockers;
  } in
  let prompt = Relay.build_handoff_prompt ~payload ~generation:(generation + 1) in
  (* Use Eio-native spawn to avoid blocking HTTP server *)
  match ctx.proc_mgr with
  | None -> (false, "❌ Process manager not available for relay spawn")
  | Some _pm ->
      let result = Spawn_eio.spawn ~sw:ctx.sw ~agent_name:target_agent
        ~prompt ~timeout_seconds:Env_config.Spawn.timeout_seconds
        ~room_config:ctx.config ()
      in
      (* Log structured termination reason when available *)
      (match result.Spawn_eio.termination with
       | Some t ->
         Log.Spawn.info "relay termination: %s (agent=%s, elapsed=%dms, tools=%d)"
           (Spawn_eio.termination_reason_to_string t.reason)
           t.agent_name t.elapsed_ms t.tool_call_count
       | None -> ());
      let output_preview =
        if String.length result.Spawn_eio.output > 500 then
          String.sub result.Spawn_eio.output 0 500
        else result.Spawn_eio.output
      in
      let json = `Assoc [
        ("success", `Bool result.Spawn_eio.success);
        ("exit_code", `Int result.Spawn_eio.exit_code);
        ("elapsed_ms", `Int result.Spawn_eio.elapsed_ms);
        ("target_agent", `String target_agent);
        ("generation", `Int (generation + 1));
        ("output_preview", `String output_preview);
      ] in
      (true, Yojson.Safe.pretty_to_string json)

let handle_relay_smart_check _ctx args =
  let messages = get_int args "messages" 0 in
  let tool_calls = get_int args "tool_calls" 0 in
  let hint_str = get_string args "task_hint" "simple" in
  let file_count = get_int args "file_count" 1 in
  let task_hint =
    match hint_str with
    | "large_file" -> Relay.Large_file_read "unknown"
    | "multi_file" -> Relay.Multi_file_edit (max 1 file_count)
    | "long_running" -> Relay.Long_running_task
    | "exploration" -> Relay.Exploration_task
    | _ -> Relay.Simple_task
  in
  let metrics = Relay.estimate_context ~messages ~tool_calls ~model:"claude" in
  let decision = Relay.should_relay_smart ~config:Relay.default_config ~metrics ~task_hint in
  let decision_str = match decision with
    | `Proactive -> "proactive"
    | `Reactive -> "reactive"
    | `No_relay -> "no_relay"
  in
  let json = `Assoc [
    ("decision", `String decision_str);
    ("usage_ratio", `Float metrics.Relay.usage_ratio);
    ("estimated_tokens", `Int metrics.Relay.estimated_tokens);
    ("max_tokens", `Int metrics.Relay.max_tokens);
  ] in
  (true, Yojson.Safe.pretty_to_string json)

let schemas : Types.tool_schema list = [
  {
    name = "masc_relay_status";
    description = "Check current context usage and relay readiness. Shows estimated token count, usage ratio, and whether relay is recommended. Call periodically to monitor context health.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("messages", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of messages in conversation");
        ]);
        ("tool_calls", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of tool calls made");
        ]);
        ("model", `Assoc [
          ("type", `String "string");
          ("description", `String "Model name (claude, gemini, codex) for max context lookup");
          ("default", `String "claude");
        ]);
      ]);
    ];
  };

  (* masc_relay_checkpoint *)
  {
    name = "masc_relay_checkpoint";
    description = "Save a checkpoint of current work state (summary, TODOs, relevant files) for smooth handoff. \
Use when completing a subtask or before starting a complex operation. \
Pair with masc_relay_now to trigger handoff, or masc_relay_status to check if relay is needed.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Brief summary of work done so far");
        ]);
        ("current_task", `Assoc [
          ("type", `String "string");
          ("description", `String "Current task being worked on (optional)");
        ]);
        ("todos", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of remaining TODO items");
        ]);
        ("pdca_state", `Assoc [
          ("type", `String "string");
          ("description", `String "Current PDCA cycle state (optional)");
        ]);
        ("relevant_files", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of files being worked on");
        ]);
      ]);
      ("required", `List [`String "summary"]);
    ];
  };

  (* masc_relay_now *)
  {
    name = "masc_relay_now";
    description = "Trigger immediate relay to a new agent with compressed context. \
Use when context is getting full (>70%) or before a task that will overflow. \
Call masc_relay_checkpoint first to save state. The successor continues where you left off.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Summary of work for handoff");
        ]);
        ("current_task", `Assoc [
          ("type", `String "string");
          ("description", `String "Task to continue (optional)");
        ]);
        ("target_agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to relay to (default: claude)");
          ("default", `String "claude");
        ]);
        ("generation", `Assoc [
          ("type", `String "integer");
          ("description", `String "Current relay generation (default: 0)");
          ("default", `Int 0);
        ]);
      ]);
      ("required", `List [`String "summary"]);
    ];
  };

  (* masc_relay_smart_check *)
  {
    name = "masc_relay_smart_check";
    description = "Proactive relay check with task complexity hint. Predicts if the next task will overflow context. \
Use when about to start a large_file, multi_file, or long_running task. \
Returns relay recommendation before you commit. Pair with masc_relay_now if relay is advised.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("messages", `Assoc [
          ("type", `String "integer");
          ("description", `String "Current message count");
        ]);
        ("tool_calls", `Assoc [
          ("type", `String "integer");
          ("description", `String "Current tool call count");
        ]);
        ("task_hint", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "large_file"; `String "multi_file"; `String "long_running"; `String "exploration"; `String "simple"]);
          ("description", `String "Hint about upcoming task complexity");
        ]);
        ("file_count", `Assoc [
          ("type", `String "integer");
          ("description", `String "For multi_file hint: number of files");
        ]);
      ]);
      ("required", `List [`String "task_hint"]);
    ];
  };

]

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_relay_status" -> Some (handle_relay_status ctx args)
  | "masc_relay_checkpoint" -> Some (handle_relay_checkpoint ctx args)
  | "masc_relay_now" -> Some (handle_relay_now ctx args)
  | "masc_relay_smart_check" -> Some (handle_relay_smart_check ctx args)
  | _ -> None
