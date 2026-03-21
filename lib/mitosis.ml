(** MASC Mitosis - Cell Division Pattern for Infinite Agent Lifecycle.
    2-phase handoff: DNA extracted at 50%, handoff at 80%. *)

type cell_state =
  | Stem
  | Active
  | Prepared
  | Dividing
  | Apoptotic

type mitosis_phase =
  | Idle
  | ReadyForHandoff of string

type cell = {
  id: string;
  generation: int;
  state: cell_state;
  phase: mitosis_phase;
  born_at: float;
  last_activity: float;
  context_dna: string option;
  prepared_dna: string option;
  prepare_context_len: int;
  task_count: int;
  tool_call_count: int;
}

type stem_pool = {
  cells: cell list;
  max_size: int;
  warm_up_count: int;
}

type mitosis_trigger =
  | Time_based of float
  | Task_count of int
  | Tool_calls of int
  | Context_threshold of float
  | Complexity_spike

type mitosis_config = {
  triggers: mitosis_trigger list;
  stem_pool_size: int;
  max_generation: int;
  dna_compression_ratio: float;
  apoptosis_delay: float;
  prepare_threshold: float;
  handoff_threshold: float;
  min_context_for_delta: int;
  min_delta_len: int;
}

module Defaults = Mitosis_defaults

let default_config = {
  triggers = [
    Time_based Defaults.time_trigger_seconds;
    Task_count Defaults.task_trigger_count;
    Tool_calls Defaults.tool_call_trigger_count;
  ];
  stem_pool_size = Defaults.stem_pool_size;
  max_generation = Defaults.max_generation;
  dna_compression_ratio = Defaults.dna_compression_ratio;
  apoptosis_delay = Defaults.apoptosis_delay_seconds;
  prepare_threshold = Defaults.prepare_threshold;
  handoff_threshold = Defaults.handoff_threshold;
  min_context_for_delta = Defaults.min_context_for_delta;
  min_delta_len = Defaults.min_delta_len;
}

let state_to_string = function
  | Stem -> "stem"
  | Active -> "active"
  | Prepared -> "prepared"
  | Dividing -> "dividing"
  | Apoptotic -> "apoptotic"

let phase_to_string = function
  | Idle -> "idle"
  | ReadyForHandoff _ -> "ready_for_handoff"

let log_state_transition ~old_state ~new_state ~agent_name ~reason =
  Log.Mitosis_log.info
    "state_transition old_state=%s new_state=%s agent=%s timestamp=%.3f reason=%s"
    (state_to_string old_state)
    (state_to_string new_state)
    agent_name
    (Time_compat.now ())
    reason

let create_stem_cell ~generation =
  let random_suffix =
    let t = Unix.gettimeofday () in
    Printf.sprintf "%04x%04x"
      (Hashtbl.hash t land 0xFFFF)
      (Hashtbl.hash (t *. 1000.0) land 0xFFFF)
  in
  let id = Printf.sprintf "cell-%d-%s" generation random_suffix in
  {
    id;
    generation;
    state = Stem;
    phase = Idle;
    born_at = Time_compat.now ();
    last_activity = Time_compat.now ();
    context_dna = None;
    prepared_dna = None;
    prepare_context_len = 0;
    task_count = 0;
    tool_call_count = 0;
  }

let init_pool ~config =
  let cells = List.init config.stem_pool_size (fun i ->
    create_stem_cell ~generation:i
  ) in
  {
    cells;
    max_size = config.stem_pool_size;
    warm_up_count = min 2 config.stem_pool_size;
  }

let check_non_context_triggers ~config ~cell =
  let now = Time_compat.now () in
  let age = now -. cell.born_at in
  List.exists (function
    | Time_based interval -> age >= interval
    | Task_count n -> cell.task_count >= n
    | Tool_calls n -> cell.tool_call_count >= n
    | Context_threshold _ -> false
    | Complexity_spike -> false
  ) config.triggers

let should_prepare ~config ~cell ~context_ratio =
  match cell.phase with
  | ReadyForHandoff _ -> false
  | Idle ->
    context_ratio >= config.prepare_threshold ||
    check_non_context_triggers ~config ~cell

let should_handoff ~config ~cell ~context_ratio =
  match cell.phase with
  | ReadyForHandoff _ -> context_ratio >= config.handoff_threshold
  | Idle ->
    context_ratio >= config.handoff_threshold

let should_divide ~config ~cell ~context_ratio =
  should_handoff ~config ~cell ~context_ratio

(* Re-export DNA operations from Mitosis_dna *)
include (Mitosis_dna : sig
  val safe_sub : string -> int -> int -> string
  val handoff_token_budget : int
  val handoff_max_chars : unit -> int
  val truncate_to_handoff_budget : string -> string
  val compress_to_dna : ratio:float -> context:string -> string
  val deduplicate_lines : base:string -> delta:string -> string
  val merge_dna_with_delta : prepared_dna:string -> delta:string -> string
  module StringSet : Set.S with type elt = string
end)

(** Generate mentor wisdom for successor *)
let generate_mentor_wisdom ~parent_cell =
  let now = Time_compat.now () in
  let age_seconds = now -. parent_cell.born_at in
  let age_str =
    if age_seconds < 60.0 then Printf.sprintf "%.0f seconds" age_seconds
    else if age_seconds < 3600.0 then Printf.sprintf "%.1f minutes" (age_seconds /. 60.0)
    else Printf.sprintf "%.1f hours" (age_seconds /. 3600.0)
  in

  let wisdom_lines = [
    Printf.sprintf "🧬 I am your predecessor, Generation %d, alive for %s."
      parent_cell.generation age_str;
    (if parent_cell.task_count > 5 then
       Printf.sprintf "📋 I completed %d tasks. Focus on incremental progress."
         parent_cell.task_count
     else if parent_cell.task_count > 0 then
       Printf.sprintf "📋 I completed %d task(s). Continue my work."
         parent_cell.task_count
     else
       "📋 I had no tasks to complete. The work begins with you.");
    (if parent_cell.tool_call_count > 100 then
       "🔧 Heavy tool usage depleted my context. Be efficient with tool calls."
     else if parent_cell.tool_call_count > 50 then
       "🔧 Moderate tool usage. Batch operations when possible."
     else
       "🔧 Light tool footprint. You have room to work.");
    (match parent_cell.phase with
     | ReadyForHandoff _ ->
         "⚠️ I prepared DNA and am ready for handoff. Context was filling up."
     | Idle ->
         "💡 Stay aware of your context usage. Prepare DNA at 50%, handoff at 80%.");
    "🌱 Carry our lineage forward. You are Generation " ^
      string_of_int (parent_cell.generation + 1) ^ ".";
  ] in
  String.concat "\n" wisdom_lines

let extract_dna ~config ~parent_cell ~full_context =
  let continuity_anchors = Mitosis_dna.build_continuity_anchors full_context in
  let compressed = compress_to_dna ~ratio:config.dna_compression_ratio ~context:full_context in
  let mentor_wisdom = generate_mentor_wisdom ~parent_cell in
  let header = Printf.sprintf
    "[Generation %d | Parent: %s | Tasks: %d | Born: %.0f]\n\n\
     === MENTOR'S WISDOM ===\n%s\n========================\n\n"
    parent_cell.generation
    parent_cell.id
    parent_cell.task_count
    parent_cell.born_at
    mentor_wisdom
  in
  header ^ continuity_anchors ^ compressed

let bounded_handoff_dna ~config ~parent_cell ~full_context =
  truncate_to_handoff_budget (extract_dna ~config ~parent_cell ~full_context)

let extract_delta ~config ~full_context ~since_len =
  let current_len = String.length full_context in
  if current_len < config.min_context_for_delta then begin
    Printf.printf "[MITOSIS/DELTA] Short session (%d < %d chars), skipping delta\n%!"
      current_len config.min_context_for_delta;
    ""
  end
  else if since_len >= current_len then
    ""
  else
    let raw_delta = safe_sub full_context since_len (current_len - since_len) in
    let compressed = compress_to_dna ~ratio:config.dna_compression_ratio ~context:raw_delta in
    if String.length compressed < config.min_delta_len then begin
      Printf.printf "[MITOSIS/DELTA] Delta too short (%d < %d chars), treating as noise\n%!"
        (String.length compressed) config.min_delta_len;
      ""
    end
    else
      compressed

let prepare_for_division ~config ~cell ~full_context =
  let dna = extract_dna ~config ~parent_cell:cell ~full_context in
  let context_len = String.length full_context in
  let prepared_cell = { cell with
    state = Prepared;
    phase = ReadyForHandoff dna;
    prepared_dna = Some dna;
    prepare_context_len = context_len;
  } in
  log_state_transition
    ~old_state:cell.state ~new_state:Prepared
    ~agent_name:cell.id
    ~reason:(Printf.sprintf "DNA extracted (%d chars) at %.0f%% threshold"
      context_len (config.prepare_threshold *. 100.0));
  prepared_cell
let activate_stem ~pool ~dna =
  match List.find_opt (fun c -> c.state = Stem) pool.cells with
  | None ->
    let emergency = create_stem_cell ~generation:Defaults.emergency_generation in
    let activated = { emergency with
      state = Active;
      phase = Idle;
      context_dna = Some dna;
      prepared_dna = None;
      last_activity = Time_compat.now ();
    } in
    log_state_transition
      ~old_state:Stem ~new_state:Active
      ~agent_name:activated.id
      ~reason:"emergency activation (no stem cells available)";
    (activated, pool)
  | Some stem ->
    let activated = { stem with
      state = Active;
      phase = Idle;
      context_dna = Some dna;
      prepared_dna = None;
      last_activity = Time_compat.now ();
    } in
    log_state_transition
      ~old_state:Stem ~new_state:Active
      ~agent_name:stem.id
      ~reason:"stem cell activation with parent DNA";
    let remaining = List.filter (fun c -> c.id <> stem.id) pool.cells in
    (activated, { pool with cells = remaining })

let begin_apoptosis cell =
  log_state_transition
    ~old_state:cell.state ~new_state:Apoptotic
    ~agent_name:cell.id
    ~reason:"mitosis division complete, entering graceful shutdown";
  { cell with state = Apoptotic }

let complete_apoptosis _cell = `Dead

let perform_mitosis ~config ~pool ~parent ~full_context =
  let dna = match parent.phase with
    | ReadyForHandoff prepared_dna ->
        let delta = extract_delta ~config ~full_context ~since_len:parent.prepare_context_len in
        let merged = merge_dna_with_delta ~prepared_dna ~delta in
        Printf.printf "[MITOSIS/DELTA] Merged DNA: prepared=%d chars + delta=%d chars\n%!"
          (String.length prepared_dna) (String.length delta);
        merged
    | Idle -> bounded_handoff_dna ~config ~parent_cell:parent ~full_context
  in
  let dna = truncate_to_handoff_budget dna in
  let dying_parent = begin_apoptosis parent in
  let (child, new_pool) = activate_stem ~pool ~dna in
  let child = { child with generation = parent.generation + 1 } in
  let new_stem = create_stem_cell ~generation:(child.generation + 1) in
  let replenished_pool = { new_pool with
    cells = new_stem :: new_pool.cells
  } in
  (child, dying_parent, replenished_pool, dna)
let build_mitosis_prompt ~child ~dna =
  Printf.sprintf
    "🧬 **MITOSIS HANDOFF** (Generation %d)\n\n\
     You are a new agent cell, born from division.\n\
     Your parent completed their lifecycle and passed on their DNA (compressed context).\n\n\
     **IMPORTANT**: Continue seamlessly. The user should not notice the transition.\n\n\
     ## Inherited DNA\n\n\
     %s\n\n\
     ---\n\
     **Instructions**:\n\
     1. Parse the inherited DNA above\n\
     2. Continue the current task\n\
     3. You will divide again when triggers are met\n\
     4. This is normal - embrace the lifecycle\n"
    child.generation
    dna

let execute_mitosis ~config ~pool ~parent ~full_context ~spawn_fn =
  let (child, dying_parent, new_pool, dna) =
    perform_mitosis ~config ~pool ~parent ~full_context in
  let prompt = build_mitosis_prompt ~child ~dna in
  let spawn_result = spawn_fn ~prompt in
  let _ = complete_apoptosis dying_parent in
  Printf.printf "[MITOSIS] Cell %s (gen %d) -> Cell %s (gen %d)\n%!"
    parent.id parent.generation child.id child.generation;
  (spawn_result, child, new_pool, dna)
let record_activity ~cell ~task_done ~tool_called =
  let task_count = if task_done then cell.task_count + 1 else cell.task_count in
  let tool_call_count = if tool_called then cell.tool_call_count + 1 else cell.tool_call_count in
  { cell with
    task_count;
    tool_call_count;
    last_activity = Time_compat.now ();
  }

type mitosis_check_result =
  | NoAction
  | Prepared of cell
  | Handoff of Spawn.spawn_result * cell * stem_pool * string

let auto_mitosis_check_2phase ~config ~pool ~cell ~context_ratio ~full_context ~spawn_fn =
  if should_handoff ~config ~cell ~context_ratio then begin
    Printf.printf "[MITOSIS/HANDOFF] Threshold %.0f%% reached for cell %s (gen %d), executing handoff...\n%!"
      (config.handoff_threshold *. 100.0) cell.id cell.generation;
    let (spawn_result, child, new_pool, dna) =
      execute_mitosis ~config ~pool ~parent:cell ~full_context ~spawn_fn in
    Handoff (spawn_result, child, new_pool, dna)
  end
  else if should_prepare ~config ~cell ~context_ratio then begin
    let prepared_cell = prepare_for_division ~config ~cell ~full_context in
    Prepared prepared_cell
  end
  else
    NoAction

let auto_mitosis_check ~config ~pool ~cell ~context_ratio ~full_context ~spawn_fn =
  if should_divide ~config ~cell ~context_ratio then begin
    Printf.printf "[MITOSIS/AUTO] Trigger met for cell %s (gen %d), dividing...\n%!"
      cell.id cell.generation;
    Some (execute_mitosis ~config ~pool ~parent:cell ~full_context ~spawn_fn)
  end
  else
    None

let cell_to_json cell =
  `Assoc [
    ("id", `String cell.id);
    ("generation", `Int cell.generation);
    ("state", `String (state_to_string cell.state));
    ("phase", `String (phase_to_string cell.phase));
    ("born_at", `Float cell.born_at);
    ("last_activity", `Float cell.last_activity);
    ("context_dna", match cell.context_dna with Some d -> `String d | None -> `Null);
    ("prepared_dna", match cell.prepared_dna with Some d -> `String d | None -> `Null);
    ("prepare_context_len", `Int cell.prepare_context_len);
    ("task_count", `Int cell.task_count);
    ("tool_call_count", `Int cell.tool_call_count);
  ]
let pool_to_json pool =
  `Assoc [
    ("cells", `List (List.map cell_to_json pool.cells));
    ("max_size", `Int pool.max_size);
    ("warm_up_count", `Int pool.warm_up_count);
    ("stem_count", `Int (List.length (List.filter (fun c -> c.state = Stem) pool.cells)));
  ]

let trigger_to_json = function
  | Time_based f -> `Assoc [("type", `String "time_based"); ("interval_seconds", `Float f)]
  | Task_count n -> `Assoc [("type", `String "task_count"); ("count", `Int n)]
  | Tool_calls n -> `Assoc [("type", `String "tool_calls"); ("count", `Int n)]
  | Context_threshold f -> `Assoc [("type", `String "context_threshold"); ("threshold", `Float f)]
  | Complexity_spike -> `Assoc [("type", `String "complexity_spike")]
let config_to_json config =
  `Assoc [
    ("triggers", `List (List.map trigger_to_json config.triggers));
    ("stem_pool_size", `Int config.stem_pool_size);
    ("max_generation", `Int config.max_generation);
    ("dna_compression_ratio", `Float config.dna_compression_ratio);
    ("apoptosis_delay", `Float config.apoptosis_delay);
    ("prepare_threshold", `Float config.prepare_threshold);
    ("handoff_threshold", `Float config.handoff_threshold);
  ]

(** Write mitosis status to file for hook consumption. *)
let write_status ~base_path ~cell ~config =
  let masc_dir = Filename.concat base_path ".masc" in
  let status_file = Filename.concat masc_dir "mitosis-status.json" in
  let tool_calls = cell.tool_call_count in
  let estimated_ratio = Float.min 1.0 (Float.of_int tool_calls /. Defaults.tool_calls_per_full_context) in
  let status =
    if estimated_ratio >= config.handoff_threshold then "critical"
    else if estimated_ratio >= config.prepare_threshold then "warning"
    else "healthy" in
  let json = `Assoc [
    ("tool_calls", `Int tool_calls);
    ("task_count", `Int cell.task_count);
    ("estimated_ratio", `Float estimated_ratio);
    ("status", `String status);
    ("generation", `Int cell.generation);
    ("phase", `String (phase_to_string cell.phase));
    ("prepare_threshold", `Float config.prepare_threshold);
    ("handoff_threshold", `Float config.handoff_threshold);
    ("updated_at", `Float (Time_compat.now ()));
  ] in
  if Sys.file_exists masc_dir && Sys.is_directory masc_dir then begin
    try
      Fs_compat.save_file status_file (Yojson.Safe.pretty_to_string json ^ "\n")
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.Mitosis_log.error "Failed to write status: %s" (Printexc.to_string exn)
  end

(** Write mitosis status to both local file AND backend. *)
let write_status_with_backend ~room_config ~cell ~config =
  let open Room_utils in
  let base_path = room_config.base_path in
  let node_id = room_config.backend_config.Backend.node_id in
  let cluster_name = room_config.backend_config.Backend.cluster_name in
  let tool_calls = cell.tool_call_count in
  let estimated_ratio = Float.min 1.0 (Float.of_int tool_calls /. Defaults.tool_calls_per_full_context) in
  let status =
    if estimated_ratio >= config.handoff_threshold then "critical"
    else if estimated_ratio >= config.prepare_threshold then "warning"
    else "healthy" in
  let json = `Assoc [
    ("node_id", `String node_id);
    ("cluster_name", `String cluster_name);
    ("tool_calls", `Int tool_calls);
    ("task_count", `Int cell.task_count);
    ("estimated_ratio", `Float estimated_ratio);
    ("status", `String status);
    ("generation", `Int cell.generation);
    ("phase", `String (phase_to_string cell.phase));
    ("prepare_threshold", `Float config.prepare_threshold);
    ("handoff_threshold", `Float config.handoff_threshold);
    ("updated_at", `Float (Time_compat.now ()));
  ] in
  let json_str = Yojson.Safe.to_string json in
  let masc_dir = Filename.concat base_path ".masc" in
  let status_file = Filename.concat masc_dir "mitosis-status.json" in
  if Sys.file_exists masc_dir && Sys.is_directory masc_dir then begin
    try
      Fs_compat.save_file status_file (Yojson.Safe.pretty_to_string json ^ "\n")
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.Mitosis_log.error "Failed to write status file: %s"
        (Printexc.to_string exn)
  end;
  let key = Printf.sprintf "mitosis:%s" node_id in
  (match backend_set room_config ~key ~value:json_str with
   | Ok () -> ()
   | Error e -> Log.Misc.error "mitosis: backend_set failed for %s: %s" node_id (Backend.show_error e))

(** Get all mitosis statuses from backend. *)
let get_all_statuses ~room_config =
  let open Room_utils in
  match backend_get_all room_config ~prefix:"mitosis:" with
  | Ok pairs ->
      List.filter_map (fun (_key, value) ->
        try
          let json = Yojson.Safe.from_string value in
          let node_id = Yojson.Safe.Util.(json |> member "node_id" |> to_string) in
          let status = Yojson.Safe.Util.(json |> member "status" |> to_string) in
          let ratio = Yojson.Safe.Util.(json |> member "estimated_ratio" |> to_float) in
          Some (node_id, status, ratio)
        with
        | Yojson.Safe.Util.Type_error _ -> None
        | Yojson.Json_error _ -> None
        | _ -> None
      ) pairs
  | Error _ -> []
