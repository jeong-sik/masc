(** Perpetual_loop — Types, configuration, and state for the perpetual agent.

    The loop runtime has moved to {!Perpetual_oas}.  This module retains:
    - Event / config / state type definitions
    - [default_config], [create_state] (construction)
    - [stop], [status] (lifecycle queries)
    - [record_event], [publish_to_event_bus] (event plumbing)

    @since 2.61.0 *)

open Printf

type event =
  | TurnStart of int
  | TurnEnd of { turn : int; tokens_used : int; cost : float }
  | Compacted of { before_tokens : int; after_tokens : int; offloaded_path : string option }
  | Prepared of { dna_size : int }
  | Handoff of { to_model : string; generation : int }
  | Verified of { action : string; verdict : string }
  | Heartbeat of { turn : int; context_pct : float }
  | Error of string
  | IdleDetected of int
  | Terminated of string
  | CodingSpawn of { agent : string; exit_code : int; elapsed_ms : int }
  | TaskClaimed of { task_id : string; title : string; priority : int }
  | TaskCompleted of { task_id : string }
  | ClaimSkipped of string

type loop_config = {
  initial_goal : string;
  model_cascade : Cascade.model_spec list;
  tools : Types.tool_schema list;
  heartbeat_interval_s : float;
  max_idle_turns : int;
  feedback_enabled : bool;
  verifier_model : Cascade.model_spec;
  compact_threshold : float;
  prepare_threshold : float;
  handoff_threshold : float;
  compact_strategies : Compaction_types.compaction_strategy list;
  session_base_dir : string;
  on_event : event -> unit;
  event_bus : Agent_sdk.Event_bus.t option;
  (* Coding mode: spawn Claude Code instead of LLM direct calls *)
  coding_mode : bool;
  coding_agent : string;
  coding_timeout_s : int;
  coding_sw : Eio.Switch.t option;
  coding_proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  (* Auto-claim: connect perpetual agent to Room task backlog *)
  room_config : Room_utils_backend_setup.config option;
  agent_name : string;
  auto_claim_cooldown_s : float;
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
  mutable started_at : float;
  mutable last_turn_ts : float;
  mutable last_model_used : string;
  mutable last_usage : Agent_sdk.Types.api_usage;
  mutable last_latency_ms : int;
  mutable compaction_count : int;
  mutable compaction_tokens_saved : int;
  mutable last_compaction_ts : float;
  mutable last_compaction_before_tokens : int;
  mutable last_compaction_after_tokens : int;
  mutable events : (float * event) list;
  mutable running : bool;
  trace_id : string;
  (* Auto-claim state *)
  mutable current_task_id : string option;
  mutable last_claim_attempt_ts : float;
  mutable claim_failure_count : int;
}

let default_config ~goal ~models ?verifier ?session_dir () =
  let me_root = Env_config.me_root () in
  let verifier_model = match verifier with
    | Some v -> v
    | None -> (
        match Cascade.default_verifier_model_spec () with
        | Ok model -> model
        | Error _ -> (
            match models with
            | model :: _ -> model
            | [] -> Cascade.glm_cloud))
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
  let hash = Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFF in
  sprintf "trace-%d-%05x" ts hash

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
    | [] -> Cascade.default_local_model_spec ()
  in
  let context = Context_manager.create
    ~system_prompt
    ~max_tokens:primary_model.max_context in
  (* Inject goal as first user message with sticky prefix for compaction safety *)
  let goal_msg = Agent_sdk.Types.user_msg
    (sprintf "%s %s" Context_manager.goal_prefix config.initial_goal) in
  let context = Context_manager.append context goal_msg in
  let trace_id = generate_trace_id () in
  let session = Context_manager.create_session
    ~session_id:trace_id
    ~base_dir:config.session_base_dir in
  let zero_usage : Agent_sdk.Types.api_usage = {
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
(* Event Bus Bridge                                                 *)
(* ================================================================ *)

(** Publish perpetual_loop events to OAS Event_bus when configured. *)
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
(* Lifecycle (runtime removed — see Perpetual_oas)                  *)
(* ================================================================ *)

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
      ("total_tokens", `Int (Cascade.total_tokens state.last_usage));
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
