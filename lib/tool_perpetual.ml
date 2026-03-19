(** Tool_perpetual — MCP tool schemas for the Perpetual Agent Runtime.

    Provides 4 MCP tools:
    - masc_perpetual_start  — Start a perpetual agent with goal + model cascade
    - masc_perpetual_status — Get current state (turn, context%, generation)
    - masc_perpetual_stop   — Graceful shutdown with handover
    - masc_perpetual_inject — Inject new goal/context into running agent

    @since 2.61.0 *)

(* ================================================================ *)
(* Tool Schemas                                                     *)
(* ================================================================ *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_perpetual_start";
    description = "Start a perpetual agent that runs autonomously with infinite context. \
The agent will think → act → observe → verify in a loop, compacting context as needed \
and handing off to successor agents when context fills up. \
Requires: goal (what to accomplish), models (LLM cascade in priority order). \
Example models: 'default', 'default:auto', 'gemini:flash', 'claude:opus'.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("goal", `Assoc [
          ("type", `String "string");
          ("description", `String "The goal for the agent to accomplish autonomously");
        ]);
        ("models", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "LLM model cascade in priority order. \
Format: 'provider:model_id' or 'default[:model_id]'. Examples: 'default', 'default:auto', 'gemini:flash', 'claude:opus'");
        ]);
        ("verify", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable action verification via cheap model (default: true)");
        ]);
        ("heartbeat_sec", `Assoc [
          ("type", `String "number");
          ("description", `String "Heartbeat interval in seconds (default: 30)");
        ]);
        ("max_idle", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max idle turns before stopping (default: 5)");
        ]);
        ("coding_mode", `Assoc [
          ("type", `String "boolean");
          ("description", `String "When true, spawn Claude Code for coding tasks instead of direct LLM calls (default: false)");
        ]);
        ("coding_agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to spawn in coding mode (default: 'claude')");
        ]);
        ("coding_timeout_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Timeout per coding turn in seconds (default: 7200)");
        ]);
      ]);
      ("required", `List [`String "goal"; `String "models"]);
    ];
  };

  {
    name = "masc_perpetual_status";
    description = "Get the current status of the running perpetual agent. \
Returns: trace_id, running state, generation, turn count, context usage, cost.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("trace_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Trace ID of the perpetual agent (optional, uses latest if omitted)");
        ]);
      ]);
    ];
  };

  {
    name = "masc_perpetual_stop";
    description = "Stop a running perpetual agent gracefully. \
The agent will finish its current turn, save a checkpoint, and extract DNA for potential resumption.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("trace_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Trace ID of the agent to stop (optional, stops latest)");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for stopping (for logging)");
        ]);
      ]);
    ];
  };

  {
    name = "masc_perpetual_inject";
    description = "Inject a new message or updated goal into a running perpetual agent. \
The agent will receive this as a user message on its next turn.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("trace_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Trace ID of the target agent (optional, uses latest)");
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Message to inject into the agent's context");
        ]);
        ("new_goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: replace the agent's goal entirely");
        ]);
      ]);
      ("required", `List [`String "message"]);
    ];
  };
]

type result = bool * string
type context = {
  agent_name : string;
  start_loop : (Perpetual_loop.loop_state -> Perpetual_loop.loop_config -> unit) option;
  sw : Eio.Switch.t option;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  room_config : Room_utils_backend_setup.config option;
}

(* ================================================================ *)
(* Tool Dispatch                                                    *)
(* ================================================================ *)

(** Global registry of running perpetual agents. *)
let active_agents : (string, Perpetual_loop.loop_state * Perpetual_loop.loop_config) Hashtbl.t =
  Hashtbl.create 4

let latest_trace_id : string option ref = ref None

let handle_start ctx args =
  let goal = Safe_ops.json_string "goal" args in
  let model_strs = Safe_ops.json_string_list "models" args in
  let verify = Safe_ops.json_bool ~default:true "verify" args in
  let heartbeat = Safe_ops.json_float ~default:30.0 "heartbeat_sec" args in
  let max_idle = Safe_ops.json_int ~default:5 "max_idle" args in
  let coding_mode = Safe_ops.json_bool ~default:false "coding_mode" args in
  let coding_agent = match Safe_ops.json_string_opt "coding_agent" args with
                     | Some s -> s
                     | None -> Provider_adapter.default_cli_agent_name () in
  let coding_timeout = Safe_ops.json_int ~default:Env_config.Spawn.coding_timeout_seconds "coding_timeout_sec" args in
  let auto_claim_cooldown = Safe_ops.json_float ~default:60.0 "auto_claim_cooldown_sec" args in
  (* Parse model specs *)
  let models = List.filter_map (fun s ->
    match Llm_cascade.model_spec_of_string s with
    | Ok m -> Some m
    | Error e -> Log.Perpetual.info "Bad model spec %s: %s" s e; None
  ) model_strs in
  if models = [] then
    `Assoc [("error", `String "No valid models provided")]
  else begin
    let config = Perpetual_loop.default_config ~goal ~models () in
    let config = { config with
      feedback_enabled = verify;
      heartbeat_interval_s = heartbeat;
      max_idle_turns = max_idle;
      coding_mode;
      coding_agent;
      coding_timeout_s = coding_timeout;
      coding_sw = ctx.sw;
      coding_proc_mgr = ctx.proc_mgr;
      room_config = ctx.room_config;
      agent_name = ctx.agent_name;
      auto_claim_cooldown_s = auto_claim_cooldown;
      on_event = (fun ev ->
        match ev with
        | Perpetual_loop.TurnStart n ->
          Log.Perpetual.info "%s: Turn %d" config.initial_goal n
        | Perpetual_loop.CodingSpawn { agent; exit_code; elapsed_ms } ->
          Log.Perpetual.info "agent=%s exit=%d elapsed=%dms"
            agent exit_code elapsed_ms
        | Perpetual_loop.TaskClaimed { task_id; title; priority } ->
          Log.Perpetual.info "Auto-claimed [P%d] %s: %s" priority task_id title
        | Perpetual_loop.TaskCompleted { task_id } ->
          Log.Perpetual.info "Task completed: %s" task_id
        | Perpetual_loop.Error e ->
          Log.Perpetual.error "%s" e
        | Perpetual_loop.Terminated reason ->
          Log.Perpetual.info "%s" reason
        | _ -> ()
      );
    } in
    let state = Perpetual_loop.create_state config in
    Hashtbl.replace active_agents state.trace_id (state, config);
    latest_trace_id := Some state.trace_id;
    (match ctx.start_loop with
     | Some start -> start state config
     | None -> ());
    `Assoc [
      ("trace_id", `String state.trace_id);
      ("status", `String (match ctx.start_loop with Some _ -> "started" | None -> "created"));
      ("generation", `Int 0);
      ("models", `List (List.map (fun (m : Llm_types.model_spec) ->
        `String m.model_id) models));
    ]
  end

let handle_status args =
  let trace = match Safe_ops.json_string_opt "trace_id" args with
    | Some id -> Some id
    | None -> !latest_trace_id
  in
  match trace with
  | None -> `Assoc [("error", `String "No perpetual agent running")]
  | Some id ->
    match Hashtbl.find_opt active_agents id with
    | None -> `Assoc [("error", `String (Printf.sprintf "Agent %s not found" id))]
    | Some (state, config) ->
      let base = Perpetual_loop.status ~config state in
      (match base with
       | `Assoc fields ->
         let models =
           `List (List.map (fun (m : Llm_types.model_spec) ->
             `Assoc [
               ("provider", `String (Llm_types.string_of_provider m.provider));
               ("model_id", `String m.model_id);
               ("max_context", `Int m.max_context);
               ("api_key_env", match m.api_key_env with None -> `Null | Some k -> `String k);
             ]
           ) config.model_cascade)
         in
         `Assoc ([
           ("goal", `String config.initial_goal);
           ("model_cascade", models);
           ("heartbeat_interval_s", `Float config.heartbeat_interval_s);
           ("compact_threshold", `Float config.compact_threshold);
           ("prepare_threshold", `Float config.prepare_threshold);
           ("handoff_threshold", `Float config.handoff_threshold);
           ("coding_mode", `Bool config.coding_mode);
           ("coding_agent", `String config.coding_agent);
           ("coding_timeout_s", `Int config.coding_timeout_s);
         ] @ fields)
       | other -> other)

let handle_stop args =
  let trace = match Safe_ops.json_string_opt "trace_id" args with
    | Some id -> Some id
    | None -> !latest_trace_id
  in
  let reason = Safe_ops.json_string ~default:"manual stop" "reason" args in
  match trace with
  | None -> `Assoc [("error", `String "No perpetual agent running")]
  | Some id ->
    match Hashtbl.find_opt active_agents id with
    | None -> `Assoc [("error", `String (Printf.sprintf "Agent %s not found" id))]
    | Some (state, _config) ->
      Perpetual_loop.stop state;
      `Assoc [
        ("trace_id", `String id);
        ("status", `String "stopped");
        ("reason", `String reason);
        ("final_turn", `Int state.turn_count);
        ("total_cost", `Float state.total_cost);
      ]

let handle_inject args =
  let trace = match Safe_ops.json_string_opt "trace_id" args with
    | Some id -> Some id
    | None -> !latest_trace_id
  in
  let message = Safe_ops.json_string "message" args in
  match trace with
  | None -> `Assoc [("error", `String "No perpetual agent running")]
  | Some id ->
    match Hashtbl.find_opt active_agents id with
    | None -> `Assoc [("error", `String (Printf.sprintf "Agent %s not found" id))]
    | Some (state, _config) ->
      let msg = Agent_sdk.Types.user_msg message in
      state.context <- Context_manager.append state.context msg;
      Context_manager.persist_message state.session msg;
      state.idle_turns <- 0;  (* Reset idle counter *)
      `Assoc [
        ("trace_id", `String id);
        ("status", `String "injected");
        ("message_length", `Int (String.length message));
        ("new_context_ratio", `Float (Context_manager.context_ratio state.context));
      ]

(** Wrap a Yojson.Safe.t result into (success, json_string).
    Returns (false, ...) if the JSON contains an "error" key. *)
let wrap_result json =
  let s = Yojson.Safe.to_string json in
  let is_error = match json with
    | `Assoc fields -> List.mem_assoc "error" fields
    | _ -> false
  in
  (not is_error, s)

(** Dispatch a perpetual tool call (standard MCP pattern). *)
let dispatch _ctx ~name ~args : result option =
  match name with
  | "masc_perpetual_start" -> Some (wrap_result (handle_start _ctx args))
  | "masc_perpetual_status" -> Some (wrap_result (handle_status args))
  | "masc_perpetual_stop" -> Some (wrap_result (handle_stop args))
  | "masc_perpetual_inject" -> Some (wrap_result (handle_inject args))
  | _ -> None
