(** MASC Relay - Infinite Context via Agent Handoff *)

(** Relay configuration *)
type relay_config = {
  threshold: float;          (* Context usage threshold (0.0-1.0), default 0.8 *)
  target_agent: string;      (* Agent to relay to; "auto" defers to cascade *)
  compress_ratio: float;     (* Target compression ratio, default 0.1 *)
  include_todos: bool;       (* Include TODO list in handoff *)
  include_pdca: bool;        (* Include PDCA state in handoff *)
  neo4j_episode: bool;       (* Create Neo4j Episode for continuity *)
}

(** Default relay configuration — reads from environment *)
let default_config = {
  threshold = 0.8;
  target_agent = Env_config_runtime.Relay.target_agent;
  compress_ratio = 0.1;
  include_todos = true;
  include_pdca = true;
  neo4j_episode = true;
}

(** Context metrics *)
type context_metrics = {
  estimated_tokens: int;
  max_tokens: int;
  usage_ratio: float;
  message_count: int;
  tool_call_count: int;
}

(** Handoff payload *)
type handoff_payload = {
  summary: string;
  current_task: string option;
  todos: string list;
  pdca_state: string option;
  relevant_files: string list;
  session_id: string option;
  relay_generation: int;  (* How many times relayed *)
  (* Goal-aware fields *)
  active_goal_ids: string list;
  goal_progress: (string * float) list;  (* goal_id * completion_pct *)
  goal_blockers: string list;
}

(** Context estimation calibration state *)
type calibration_state = {
  mutable samples: (int * int) list;  (* (estimated, actual) pairs *)
  mutable correction_factor: float;    (* multiplied to estimate *)
}

let calibration = {
  samples = [];
  correction_factor = 1.0;
}

(** Record actual token count vs estimated for calibration.
    Keeps the last 10 samples and updates a moving-average correction factor. *)
let record_actual_tokens ~estimated ~actual =
  let enabled = Env_config_core.relay_calibration_enabled () in
  if enabled then begin
    calibration.samples <- (estimated, actual) :: calibration.samples;
    if List.length calibration.samples > 10 then
      calibration.samples <- List.filteri (fun i _ -> i < 10) calibration.samples;
    let ratios = List.filter_map (fun (e, a) ->
      if e > 0 then Some (float_of_int a /. float_of_int e) else None
    ) calibration.samples in
    match ratios with
    | [] -> ()
    | rs ->
      let sum = List.fold_left (+.) 0.0 rs in
      let new_factor = sum /. float_of_int (List.length rs) in
      let prev_factor = calibration.correction_factor in
      calibration.correction_factor <- new_factor;
      if new_factor > 1.5 || new_factor < 0.5 then
        Log.warn ~ctx:"relay"
          "calibration drift: correction_factor=%.2f (was %.2f, %d samples)"
          new_factor prev_factor (List.length rs)
      else if abs_float (new_factor -. prev_factor) > 0.1 then
        Log.debug ~ctx:"relay"
          "calibration updated: correction_factor=%.2f (was %.2f)"
          new_factor prev_factor
  end

(** Get calibration info as JSON for debugging *)
let get_calibration_info () =
  `Assoc [
    ("correction_factor", `Float calibration.correction_factor);
    ("sample_count", `Int (List.length calibration.samples));
    ("enabled", `Bool (Env_config_core.relay_calibration_enabled ()));
  ]

(** Cached default registry — avoids re-allocation on every resolve call. *)
let default_registry = Llm_provider.Provider_registry.default ()

(** Resolve max context tokens from OAS Provider_registry / Capabilities (SSOT).
    Resolution order:
    1. Capabilities.for_model_id — per-model override (e.g. "claude-opus-4-6" -> 1M)
    2. Provider_registry.find — provider-level default (e.g. "claude" -> 200K)
    3. {!Cascade_runtime.fallback_context_window} *)
let resolve_max_context model =
  let fallback = Cascade_runtime.fallback_context_window in
  (* Layer 1: per-model capabilities (e.g. "claude-opus-4-6" -> 1M) *)
  let from_caps =
    match Llm_provider.Capabilities.for_model_id model with
    | Some caps -> caps.Llm_provider.Capabilities.max_context_tokens
    | None -> None
  in
  match from_caps with
  | Some n -> n
  | None ->
    (* Layer 2: exact provider name lookup (e.g. "claude" -> 200K) *)
    (match Llm_provider.Provider_registry.find default_registry model with
     | Some entry -> entry.Llm_provider.Provider_registry.max_context
     | None ->
       (* Layer 3: extract base provider from separator
          "provider:model" -> "provider" (colon), "claude-opus" -> "claude" (hyphen) *)
       let base =
         match String.index_opt model ':' with
         | Some idx when idx > 0 -> String.sub model 0 idx
         | _ ->
           match String.index_opt model '-' with
           | Some idx when idx > 0 -> String.sub model 0 idx
           | _ -> ""
       in
       if base <> "" then
         match Llm_provider.Provider_registry.find default_registry base with
         | Some entry -> entry.Llm_provider.Provider_registry.max_context
         | None -> fallback
       else fallback)

(** {1 Token estimation constants}

    Heuristic estimates for context usage prediction.
    These are NOT empirically calibrated — they are order-of-magnitude guesses
    adjusted by [calibration.correction_factor] at runtime.

    Provenance: initial values set during v2.100 development (2026-01) based
    on informal observation of Claude/local model conversations.
    No formal benchmark has validated these specific numbers.

    TODO(RFC-0001 Phase 0): Replace with empirical calibration once
    heuristic_metrics.jsonl collects actual token counts per message type.
    Governable via [Governance_registry.relay_tokens_per_*]. *)
let tokens_per_user_msg () = Runtime_params.get Governance_registry.relay_tokens_per_user_msg
let tokens_per_assistant_msg () = Runtime_params.get Governance_registry.relay_tokens_per_assistant_msg
let tokens_per_tool_call () = Runtime_params.get Governance_registry.relay_tokens_per_tool_call
let tokens_per_tool_result () = Runtime_params.get Governance_registry.relay_tokens_per_tool_result

(** Estimate context usage.
    Token-per-message estimates are rough heuristics, corrected by calibration. *)
let estimate_context ~messages ~tool_calls ~model =

  let message_tokens = messages * (tokens_per_user_msg () + tokens_per_assistant_msg ()) in
  let tool_tokens = tool_calls * (tokens_per_tool_call () + tokens_per_tool_result ()) in
  let estimated_raw = message_tokens + tool_tokens in
  let factor = calibration.correction_factor in
  let estimated = int_of_float (float_of_int estimated_raw *. factor) in

  let max_tokens = resolve_max_context model in

  {
    estimated_tokens = estimated;
    max_tokens;
    usage_ratio = float_of_int estimated /. float_of_int max_tokens;
    message_count = messages;
    tool_call_count = tool_calls;
  }

(** Task complexity hints for proactive relay *)
type task_hint =
  | Large_file_read of string    (* About to read large file *)
  | Multi_file_edit of int       (* Editing N files *)
  | Long_running_task            (* Task marked as long *)
  | Exploration_task             (* Codebase exploration *)
  | Simple_task                  (* Quick task, no relay needed *)

(** Task cost estimates (tokens). Same heuristic caveat as above —
    these are order-of-magnitude guesses, not measured values.
    Governable via [Governance_registry.relay_cost_*]. *)
let estimate_task_cost = function
  | Large_file_read _ -> Runtime_params.get Governance_registry.relay_cost_large_file_read
  | Multi_file_edit n -> n * Runtime_params.get Governance_registry.relay_cost_per_file_edit
  | Long_running_task -> Runtime_params.get Governance_registry.relay_cost_long_running
  | Exploration_task -> Runtime_params.get Governance_registry.relay_cost_exploration
  | Simple_task -> Runtime_params.get Governance_registry.relay_cost_simple

(** Proactive relay decision - key insight: predict before hitting limit *)
let should_relay_proactive ~config ~metrics ~task_hint =
  let predicted_cost = estimate_task_cost task_hint in
  let predicted_tokens = metrics.estimated_tokens + predicted_cost in
  let predicted_ratio = float_of_int predicted_tokens /. float_of_int metrics.max_tokens in

  (* Proactive: if predicted usage > threshold, relay NOW before the task *)
  predicted_ratio >= config.threshold

(** Check if relay is needed - reactive (legacy) *)
let should_relay ~config ~metrics =
  metrics.usage_ratio >= config.threshold

(** Smart relay decision - combines reactive + proactive *)
let should_relay_smart ~config ~metrics ~task_hint =
  (* Proactive: predict before task *)
  let proactive = should_relay_proactive ~config ~metrics ~task_hint in
  (* Reactive: already at limit *)
  let reactive = should_relay ~config ~metrics in

  if proactive && not reactive then
    `Proactive  (* Relay NOW before task consumes more *)
  else if reactive then
    `Reactive   (* Already at limit *)
  else
    `No_relay   (* Safe to continue *)

(** Compress context for handoff - extract essentials *)
let compress_context ~summary ~task ~todos ~pdca ~files
    ?(goal_progress=[]) ?(goal_blockers=[]) () =
  let sections = [] in

  (* Summary section *)
  let sections = ("## Context Summary\n" ^ summary) :: sections in

  (* Current task *)
  let sections = match task with
    | Some t -> ("## Current Task\n" ^ t) :: sections
    | None -> sections
  in

  (* TODOs *)
  let sections = match todos with
    | [] -> sections
    | _ ->
      let todo_str = String.concat "\n" (List.map (fun t -> "- " ^ t) todos) in
      ("## TODO List\n" ^ todo_str) :: sections
  in

  (* PDCA state *)
  let sections = match pdca with
    | Some p -> ("## PDCA State\n" ^ p) :: sections
    | None -> sections
  in

  (* Relevant files *)
  let sections = match files with
    | [] -> sections
    | _ ->
      let files_str = String.concat "\n" (List.map (fun f -> "- `" ^ f ^ "`") files) in
      ("## Relevant Files\n" ^ files_str) :: sections
  in

  (* Goal progress *)
  let sections = match goal_progress with
    | [] -> sections
    | progress ->
      let prog_str = String.concat "\n" (List.map (fun (gid, pct) ->
        Printf.sprintf "- %s: %.0f%%" gid (pct *. 100.0)) progress) in
      ("## Goal Progress\n" ^ prog_str) :: sections
  in

  (* Goal blockers *)
  let sections = match goal_blockers with
    | [] -> sections
    | blockers ->
      let block_str = String.concat "\n" (List.map (fun b -> "- " ^ b) blockers) in
      ("## Blockers\n" ^ block_str) :: sections
  in

  String.concat "\n\n" (List.rev sections)

(** Build handoff prompt for the new agent *)
let build_handoff_prompt ~payload ~generation =
  let header = Printf.sprintf
    "🔄 **RELAY HANDOFF** (Generation %d)\n\n\
     You are continuing work from a previous agent session.\n\
     The previous agent's context was getting full, so it handed off to you.\n\n\
     **IMPORTANT**: Continue the work seamlessly. The user should not notice the transition.\n\n"
    generation
  in

  let context = compress_context
    ~summary:payload.summary
    ~task:payload.current_task
    ~todos:payload.todos
    ~pdca:payload.pdca_state
    ~files:payload.relevant_files
    ~goal_progress:payload.goal_progress
    ~goal_blockers:payload.goal_blockers
    ()
  in

  let footer = "\n\n---\n\
    **Instructions**:\n\
    1. Read the context above carefully\n\
    2. Continue working on the current task\n\
    3. Maintain the same tone and approach\n\
    4. If context is unclear, ask the user for clarification\n\
    5. Use MASC tools to coordinate if needed\n"
  in

  header ^ context ^ footer

(** Checkpoint - saved state for smooth handoff *)
type checkpoint = {
  cp_timestamp: float;
  cp_summary: string;
  cp_task: string option;
  cp_todos: string list;
  cp_pdca: string option;
  cp_files: string list;
  cp_metrics: context_metrics;
}

(** Checkpoint storage (in-memory, could be persisted) *)
let checkpoints : checkpoint list ref = ref []
let max_checkpoints = 500
let checkpoint_mu = Eio.Mutex.create ()

let with_checkpoint_rw f = Eio_guard.with_mutex checkpoint_mu f
let with_checkpoint_ro f = Eio_guard.with_mutex_ro checkpoint_mu f

(** Save a checkpoint, capping at [max_checkpoints] to prevent unbounded growth. *)
let save_checkpoint ~summary ~task ~todos ~pdca ~files ~metrics =
  with_checkpoint_rw (fun () ->
    let cp = {
      cp_timestamp = Time_compat.now ();
      cp_summary = summary;
      cp_task = task;
      cp_todos = todos;
      cp_pdca = pdca;
      cp_files = files;
      cp_metrics = metrics;
    } in
    let cps = cp :: !checkpoints in
    checkpoints := List.filteri (fun i _ -> i < max_checkpoints) cps;
    Log.info ~ctx:"checkpoint" "Saved at %.1f%% context usage"
      (metrics.usage_ratio *. 100.0);
    cp)

(** Get latest checkpoint *)
let get_latest_checkpoint () =
  with_checkpoint_ro (fun () ->
    match !checkpoints with
    | [] -> None
    | cp :: _ -> Some cp)

(** Checkpoint to payload *)
let checkpoint_to_payload cp generation =
  {
    summary = cp.cp_summary;
    current_task = cp.cp_task;
    todos = cp.cp_todos;
    pdca_state = cp.cp_pdca;
    relevant_files = cp.cp_files;
    session_id = None;
    relay_generation = generation;
    active_goal_ids = [];
    goal_progress = [];
    goal_blockers = [];
  }

(** Metrics to JSON *)
let metrics_to_json metrics =
  `Assoc [
    ("estimated_tokens", `Int metrics.estimated_tokens);
    ("max_tokens", `Int metrics.max_tokens);
    ("usage_ratio", `Float metrics.usage_ratio);
    ("message_count", `Int metrics.message_count);
    ("tool_call_count", `Int metrics.tool_call_count);
  ]

(** Payload to JSON *)
let payload_to_json payload =
  `Assoc [
    ("summary", `String payload.summary);
    ("current_task", Json_util.string_opt_to_json payload.current_task);
    ("todos", `List (List.map (fun t -> `String t) payload.todos));
    ("pdca_state", Json_util.string_opt_to_json payload.pdca_state);
    ("relevant_files", `List (List.map (fun f -> `String f) payload.relevant_files));
    ("session_id", Json_util.string_opt_to_json payload.session_id);
    ("relay_generation", `Int payload.relay_generation);
    ("active_goal_ids", `List (List.map (fun g -> `String g) payload.active_goal_ids));
    ("goal_progress", `List (List.map (fun (gid, pct) ->
      `List [`String gid; `Float pct]) payload.goal_progress));
    ("goal_blockers", `List (List.map (fun b -> `String b) payload.goal_blockers));
  ]

(** Create empty payload *)
let empty_payload = {
  summary = "";
  current_task = None;
  todos = [];
  pdca_state = None;
  relevant_files = [];
  session_id = None;
  relay_generation = 0;
  active_goal_ids = [];
  goal_progress = [];
  goal_blockers = [];
}
