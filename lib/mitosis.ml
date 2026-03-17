(** MASC Mitosis - Cell Division Pattern for Infinite Agent Lifecycle

    Inspired by cellular biology:
    - Mitosis: Agent division before context overflow
    - Apoptosis: Graceful death after task completion
    - Stem Cells: Reserve agents ready for instant handoff

    Key insight: Don't wait for 80% - divide proactively and continuously *)

(** Lifecycle state of an agent cell.

    State transition diagram:
    {v
      Stem ──────────────────┐
        │                    │
        │ activate_stem()    │ (emergency creation)
        ▼                    │
      Active ◄───────────────┘
        │
        │ should_prepare() = true
        │ (context_ratio >= 50% OR time/task/tool triggers)
        ▼
      Prepared
        │
        │ should_handoff() = true
        │ (context_ratio >= 80%)
        ▼
      Dividing
        │
        │ begin_apoptosis()
        ▼
      Apoptotic ──► Dead (complete_apoptosis)
    v}
*)
type cell_state =
  | Stem
      (** Reserve cell, waiting in stem pool.
          Transition: → Active via [activate_stem] when parent divides. *)
  | Active
      (** Currently working on tasks.
          Transition: → Prepared when [should_prepare] returns true
          (context >= 50% OR time/task/tool triggers met). *)
  | Prepared
      (** DNA extracted at 50%, waiting for handoff threshold.
          Cell continues working but is ready for instant handoff.
          Transition: → Dividing when [should_handoff] returns true (context >= 80%). *)
  | Dividing
      (** In the process of mitosis handoff.
          DNA being transferred to child cell.
          Transition: → Apoptotic immediately after [perform_mitosis]. *)
  | Apoptotic
      (** Gracefully shutting down after successful division.
          Has [apoptosis_delay] seconds grace period.
          Transition: → Dead via [complete_apoptosis]. *)

(** Mitosis phase - 2-phase approach *)
type mitosis_phase =
  | Idle        (* Normal operation *)
  | ReadyForHandoff of string  (* DNA already extracted, waiting for handoff threshold *)

(** Agent cell with lifecycle metadata *)
type cell = {
  id: string;
  generation: int;          (* How many divisions from origin *)
  state: cell_state;
  phase: mitosis_phase;     (* Current mitosis phase - NEW! *)
  born_at: float;
  last_activity: float;
  context_dna: string option;  (* Compressed context from parent *)
  prepared_dna: string option; (* DNA extracted at prepare phase - NEW! *)
  prepare_context_len: int;    (* Context length when DNA was extracted - for delta calc *)
  task_count: int;
  tool_call_count: int;
}

(** Stem Cell Pool - reserve agents ready for instant activation *)
type stem_pool = {
  cells: cell list;
  max_size: int;
  warm_up_count: int;  (* How many to keep warm *)
}

(** Mitosis trigger conditions *)
type mitosis_trigger =
  | Time_based of float         (* Every N seconds *)
  | Task_count of int           (* Every N tasks *)
  | Tool_calls of int           (* Every N tool calls *)
  | Context_threshold of float  (* At N% context usage *)
  | Complexity_spike            (* When task complexity increases *)

(** Mitosis configuration.

    Controls when and how agent cells divide. Uses a 2-phase approach:
    - Phase 1 (Prepare): Extract DNA at [prepare_threshold] (50%)
    - Phase 2 (Handoff): Execute division at [handoff_threshold] (80%)

    This 2-phase design ensures:
    1. DNA is extracted early, before context pressure becomes critical
    2. Handoff is instant when needed (no extraction delay at 80%)
    3. Delta capture: changes between 50%-80% are merged into final DNA *)
type mitosis_config = {
  triggers: mitosis_trigger list;
      (** List of conditions that trigger mitosis.
          Any single trigger being met will initiate division.
          Evaluated in [check_non_context_triggers]. *)

  stem_pool_size: int;
      (** Number of reserve cells to maintain in the stem pool.
          Larger pools = faster handoff but more memory.
          Default: 2 (see {!Defaults.stem_pool_size}). *)

  max_generation: int;
      (** Maximum generation number to prevent infinite division loops.
          When reached, agent should gracefully exit.
          Default: 10 (see {!Defaults.max_generation}). *)

  dna_compression_ratio: float;
      (** Compression ratio for context DNA (0.0-1.0).
          0.1 = keep 10% of context, 1.0 = keep 100%.
          Lower = faster handoff, higher = better context retention.
          Default: 0.1 (see {!Defaults.dna_compression_ratio}). *)

  apoptosis_delay: float;
      (** Grace period in seconds before completing apoptosis.
          Allows dying cell to finish cleanup tasks.
          Default: 5.0s (see {!Defaults.apoptosis_delay_seconds}). *)

  prepare_threshold: float;
      (** Context usage ratio (0.0-1.0) to trigger Phase 1 (DNA extraction).
          At this threshold, DNA is extracted and cell enters [Prepared] state.
          Should be < [handoff_threshold] to allow delta capture.
          Default: 0.5 (50%) (see {!Defaults.prepare_threshold}). *)

  handoff_threshold: float;
      (** Context usage ratio (0.0-1.0) to trigger Phase 2 (actual handoff).
          At this threshold, mitosis is executed and new cell takes over.
          Default: 0.8 (80%) (see {!Defaults.handoff_threshold}). *)

  min_context_for_delta: int;
      (** Minimum context length to consider delta extraction.
          Sessions shorter than this skip delta (short session exception).
          Prevents noisy deltas from very short conversations.
          Default: 1000 chars (see {!Defaults.min_context_for_delta}). *)

  min_delta_len: int;
      (** Minimum delta length after compression to include in merged DNA.
          Deltas shorter than this are treated as noise and discarded.
          Quality threshold from BALTHASAR feedback.
          Default: 100 chars (see {!Defaults.min_delta_len}). *)
}

module Defaults = Mitosis_defaults

(** Default mitosis configuration - 2-phase approach *)
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

(** Cell state to string *)
let state_to_string = function
  | Stem -> "stem"
  | Active -> "active"
  | Prepared -> "prepared"
  | Dividing -> "dividing"
  | Apoptotic -> "apoptotic"

(** Mitosis phase to string *)
let phase_to_string = function
  | Idle -> "idle"
  | ReadyForHandoff _ -> "ready_for_handoff"

(** P1-6: Structured logging for state transitions.
    Emits key-value pairs for observability: old_state, new_state, agent, timestamp, reason. *)
let log_state_transition ~old_state ~new_state ~agent_name ~reason =
  Log.Mitosis_log.info
    "state_transition old_state=%s new_state=%s agent=%s timestamp=%.3f reason=%s"
    (state_to_string old_state)
    (state_to_string new_state)
    agent_name
    (Time_compat.now ())
    reason

(** Create a new stem cell with collision-resistant ID *)
let create_stem_cell ~generation =
  (* Use random bytes instead of timestamp mod to avoid ID collision *)
  let random_suffix =
    let bytes = Bytes.create 4 in
    for i = 0 to 3 do Bytes.set bytes i (Char.chr (Random.int 256)) done;
    Bytes.fold_left (fun acc b -> acc ^ Printf.sprintf "%02x" (Char.code b)) "" bytes
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

(** Initialize stem cell pool *)
let init_pool ~config =
  let cells = List.init config.stem_pool_size (fun i ->
    create_stem_cell ~generation:i
  ) in
  {
    cells;
    max_size = config.stem_pool_size;
    warm_up_count = min 2 config.stem_pool_size;
  }

(** Check if non-context triggers are met *)
let check_non_context_triggers ~config ~cell =
  let now = Time_compat.now () in
  let age = now -. cell.born_at in
  List.exists (function
    | Time_based interval -> age >= interval
    | Task_count n -> cell.task_count >= n
    | Tool_calls n -> cell.tool_call_count >= n
    | Context_threshold _ -> false  (* Handled by 2-phase thresholds *)
    | Complexity_spike -> false
  ) config.triggers

(** Phase 1: Should we PREPARE for division? (extract DNA, warm up) *)
let should_prepare ~config ~cell ~context_ratio =
  (* Only prepare if not already prepared *)
  match cell.phase with
  | ReadyForHandoff _ -> false  (* Already prepared *)
  | Idle ->
    context_ratio >= config.prepare_threshold ||
    check_non_context_triggers ~config ~cell

(** Phase 2: Should we actually HANDOFF? *)
let should_handoff ~config ~cell ~context_ratio =
  (* Only handoff if prepared OR if we hit handoff threshold directly *)
  match cell.phase with
  | ReadyForHandoff _ -> context_ratio >= config.handoff_threshold
  | Idle ->
    (* Emergency: hit handoff threshold without prepare phase *)
    context_ratio >= config.handoff_threshold

(** Legacy: Check if any trigger condition is met (for backward compat) *)
let should_divide ~config ~cell ~context_ratio =
  should_handoff ~config ~cell ~context_ratio

(** Safe substring extraction - never throws, returns empty on invalid range *)
let safe_sub s start len =
  let s_len = String.length s in
  if start < 0 || len < 0 || start >= s_len then ""
  else
    let actual_len = min len (s_len - start) in
    if actual_len <= 0 then ""
    else String.sub s start actual_len

(* Cap handoff context to a fixed approximate token budget. *)
let handoff_token_budget = 20000

let handoff_max_chars () =
  (* Approximate 4 chars/token for safety. *)
  handoff_token_budget * 4

let truncate_to_handoff_budget context =
  let max_chars = handoff_max_chars () in
  let context_len = String.length context in
  if context_len <= max_chars then context
  else
    let truncated = safe_sub context (context_len - max_chars) max_chars in
    Printf.sprintf
      "[... context truncated to %d-token budget: showing latest context ...]\n%s"
      handoff_token_budget
      truncated

let starts_with_ci ~prefix s =
  let p = String.lowercase_ascii prefix in
  let t = String.lowercase_ascii (String.trim s) in
  let lp = String.length p in
  String.length t >= lp && String.sub t 0 lp = p

let first_line_with_prefixes ~prefixes lines =
  let rec loop = function
    | [] -> None
    | line :: rest ->
        let trimmed = String.trim line in
        if trimmed = "" then
          loop rest
        else if List.exists (fun p -> starts_with_ci ~prefix:p trimmed) prefixes then
          Some trimmed
        else
          loop rest
  in
  loop lines

let take_last_non_empty_lines ~count text =
  let non_empty =
    String.split_on_char '\n' text
    |> List.fold_left (fun acc line ->
      let trimmed = String.trim line in
      if trimmed = "" then acc else trimmed :: acc
    ) []
    |> List.rev
  in
  let len = List.length non_empty in
  let drop_n = max 0 (len - count) in
  let rec drop n xs =
    if n <= 0 then xs
    else
      match xs with
      | [] -> []
      | _ :: rest -> drop (n - 1) rest
  in
  drop drop_n non_empty

let build_continuity_anchors full_context =
  let normalize_anchor_line s =
    let max_len = 240 in
    let trimmed = String.trim s in
    if String.length trimmed <= max_len then trimmed
    else safe_sub trimmed 0 max_len ^ "..."
  in
  let lines = String.split_on_char '\n' full_context in
  let goal_line =
    first_line_with_prefixes
      ~prefixes:["goal:"; "goal -"; "objective:"; "north star:"]
      lines
  in
  let task_line =
    first_line_with_prefixes
      ~prefixes:["current task:"; "current_task:"; "task:"; "now:"]
      lines
  in
  let recent_lines = take_last_non_empty_lines ~count:3 full_context in
  let anchor_lines =
    []
    |> fun acc ->
    (match goal_line with Some line -> acc @ [normalize_anchor_line line] | None -> acc)
    |> fun acc ->
    (match task_line with Some line -> acc @ [normalize_anchor_line line] | None -> acc)
    |> fun acc ->
    if recent_lines = [] then acc
    else
      acc
      @ ("Recent turns:"
         :: List.map (fun line -> "- " ^ normalize_anchor_line line) recent_lines)
  in
  match anchor_lines with
  | [] -> ""
  | _ ->
      String.concat "\n" (
        ["=== CONTINUITY ANCHORS ==="] @ anchor_lines @ ["=== END CONTINUITY ANCHORS ==="; ""]
      )

(** Compress context into DNA for transfer *)
let compress_to_dna ~ratio ~context =
  (* Clamp ratio to valid range [0.0, 1.0] *)
  let ratio = Float.max 0.0 (Float.min 1.0 ratio) in
  (* Continuity-aware compression: keep both head and tail *)
  let len = String.length context in
  let target_len = int_of_float (float_of_int len *. ratio) in
  if target_len <= 0 then
    ""
  else if target_len >= len then
    context
  else if target_len < 200 then
    safe_sub context 0 target_len
  else
    let head_len = max 1 (int_of_float (float_of_int target_len *. 0.6)) in
    let tail_len = max 1 (target_len - head_len) in
    if head_len + tail_len >= len then
      context
    else
      let head = safe_sub context 0 head_len in
      let tail = safe_sub context (len - tail_len) tail_len in
      String.concat "\n\n" [head; "[... middle context omitted ...]"; tail]

(** Generate mentor wisdom for successor - Agent Being Protocol
    Analyzes parent's experience and generates advice for the child.

    Wisdom categories:
    - Lifecycle awareness (time spent, phases traversed)
    - Work patterns (task count, tool usage)
    - Warnings about context pressure
*)
let generate_mentor_wisdom ~parent_cell =
  let now = Time_compat.now () in
  let age_seconds = now -. parent_cell.born_at in
  let age_str =
    if age_seconds < 60.0 then Printf.sprintf "%.0f seconds" age_seconds
    else if age_seconds < 3600.0 then Printf.sprintf "%.1f minutes" (age_seconds /. 60.0)
    else Printf.sprintf "%.1f hours" (age_seconds /. 3600.0)
  in

  let wisdom_lines = [
    (* Lifecycle wisdom *)
    Printf.sprintf "🧬 I am your predecessor, Generation %d, alive for %s."
      parent_cell.generation age_str;

    (* Work pattern wisdom *)
    (if parent_cell.task_count > 5 then
       Printf.sprintf "📋 I completed %d tasks. Focus on incremental progress."
         parent_cell.task_count
     else if parent_cell.task_count > 0 then
       Printf.sprintf "📋 I completed %d task(s). Continue my work."
         parent_cell.task_count
     else
       "📋 I had no tasks to complete. The work begins with you.");

    (* Tool usage wisdom *)
    (if parent_cell.tool_call_count > 100 then
       "🔧 Heavy tool usage depleted my context. Be efficient with tool calls."
     else if parent_cell.tool_call_count > 50 then
       "🔧 Moderate tool usage. Batch operations when possible."
     else
       "🔧 Light tool footprint. You have room to work.");

    (* Context pressure warning *)
    (match parent_cell.phase with
     | ReadyForHandoff _ ->
         "⚠️ I prepared DNA and am ready for handoff. Context was filling up."
     | Idle ->
         "💡 Stay aware of your context usage. Prepare DNA at 50%, handoff at 80%.");

    (* Final blessing *)
    "🌱 Carry our lineage forward. You are Generation " ^
      string_of_int (parent_cell.generation + 1) ^ ".";
  ] in

  String.concat "\n" wisdom_lines

(** Extract DNA from dying cell for child *)
let extract_dna ~config ~parent_cell ~full_context =
  let continuity_anchors = build_continuity_anchors full_context in
  let compressed = compress_to_dna ~ratio:config.dna_compression_ratio ~context:full_context in

  (* Agent Being Protocol: Include mentor wisdom in DNA *)
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

(** Extract delta context (changes since DNA was prepared)
    Quality controls:
    - Skip if full_context < min_context_for_delta (short session)
    - Skip if delta < min_delta_len (noise threshold) *)
let extract_delta ~config ~full_context ~since_len =
  let current_len = String.length full_context in
  (* Short session exception: skip delta for very short sessions *)
  if current_len < config.min_context_for_delta then begin
    Printf.printf "[MITOSIS/DELTA] Short session (%d < %d chars), skipping delta\n%!"
      current_len config.min_context_for_delta;
    ""
  end
  else if since_len >= current_len then
    ""  (* No new content *)
  else
    let raw_delta = safe_sub full_context since_len (current_len - since_len) in
    let compressed = compress_to_dna ~ratio:config.dna_compression_ratio ~context:raw_delta in
    (* Quality threshold: skip if delta is too short (noise) *)
    if String.length compressed < config.min_delta_len then begin
      Printf.printf "[MITOSIS/DELTA] Delta too short (%d < %d chars), treating as noise\n%!"
        (String.length compressed) config.min_delta_len;
      ""
    end
    else
      compressed

(** String Set for O(log n) lookup instead of O(n) List.mem *)
module StringSet = Set.Make(String)

(** Lazy line sequence from string - avoids full split allocation.
    Memory-efficient: generates lines on-demand without building intermediate list. *)
let lines_seq s =
  let len = String.length s in
  let rec find_line start () =
    if start >= len then Seq.Nil
    else
      match String.index_from_opt s start '\n' with
      | Some newline_pos ->
          let line = String.sub s start (newline_pos - start) in
          Seq.Cons (line, find_line (newline_pos + 1))
      | None ->
          (* Last line without trailing newline *)
          let line = String.sub s start (len - start) in
          Seq.Cons (line, fun () -> Seq.Nil)
  in
  find_line 0

(** Simple line-based deduplication for merge - O(n log n) with lazy Seq.
    Optimized: uses Seq to avoid intermediate list allocations for base. *)
let deduplicate_lines ~base ~delta =
  (* Build base_set from Seq - no intermediate list allocation *)
  let base_set =
    lines_seq base
    |> Seq.fold_left (fun acc line ->
        let trimmed = String.trim line in
        if String.length trimmed > 10 then (* Only track meaningful lines *)
          StringSet.add trimmed acc
        else acc
      ) StringSet.empty
  in
  (* Filter delta lines using Seq, collect to list for concat *)
  lines_seq delta
  |> Seq.filter (fun line ->
      let trimmed = String.trim line in
      (* Keep if: short line OR not in base *)
      String.length trimmed <= 10 || not (StringSet.mem trimmed base_set))
  |> List.of_seq
  |> String.concat "\n"

(** Merge prepared DNA with delta from 50%->80% window
    Enhanced strategy:
    - Skip if delta is empty
    - Deduplicate overlapping content
    - Add clear section marker *)
let merge_dna_with_delta ~prepared_dna ~delta =
  if String.length delta = 0 then
    prepared_dna
  else
    (* Deduplicate: remove lines from delta that already exist in prepared_dna *)
    let deduped_delta = deduplicate_lines ~base:prepared_dna ~delta in
    let deduped_len = String.length deduped_delta in
    let original_len = String.length delta in
    if deduped_len < original_len then
      Printf.printf "[MITOSIS/MERGE] Deduplication: %d → %d chars (-%d%% overlap)\n%!"
        original_len deduped_len ((original_len - deduped_len) * 100 / original_len);
    if String.length (String.trim deduped_delta) = 0 then
      prepared_dna  (* All delta was duplicate *)
    else
      Printf.sprintf "%s\n\n## Recent Updates (Delta)\n\n%s" prepared_dna deduped_delta

(** Phase 1: Prepare for division - extract DNA but don't handoff yet *)
let prepare_for_division ~config ~cell ~full_context =
  let dna = extract_dna ~config ~parent_cell:cell ~full_context in
  let context_len = String.length full_context in
  let prepared_cell = { cell with
    state = Prepared;
    phase = ReadyForHandoff dna;
    prepared_dna = Some dna;
    prepare_context_len = context_len;  (* Track for delta calculation *)
  } in
  log_state_transition
    ~old_state:cell.state ~new_state:Prepared
    ~agent_name:cell.id
    ~reason:(Printf.sprintf "DNA extracted (%d chars) at %.0f%% threshold"
      context_len (config.prepare_threshold *. 100.0));
  prepared_cell

(** Activate a stem cell with DNA from parent *)
let activate_stem ~pool ~dna =
  match List.find_opt (fun c -> c.state = Stem) pool.cells with
  | None ->
    (* No stem cells available - create emergency cell *)
    let emergency = create_stem_cell ~generation:Defaults.emergency_generation in
    let activated = { emergency with
      state = Active;
      phase = Idle;  (* Fresh start *)
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
      phase = Idle;  (* Fresh start *)
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

(** Trigger apoptosis on a cell *)
let begin_apoptosis cell =
  log_state_transition
    ~old_state:cell.state ~new_state:Apoptotic
    ~agent_name:cell.id
    ~reason:"mitosis division complete, entering graceful shutdown";
  { cell with state = Apoptotic }

(** Complete apoptosis - cell is now dead *)
let complete_apoptosis _cell =
  (* Return any final state/logs *)
  `Dead

(** Perform mitosis: parent divides into child *)
let perform_mitosis ~config ~pool ~parent ~full_context =
  (* 1. Build DNA: merge prepared DNA with delta if available, else extract fresh *)
  let dna = match parent.phase with
    | ReadyForHandoff prepared_dna ->
        (* Delta merge: prepared DNA (50%) + changes since then (50%->80%) *)
        let delta = extract_delta ~config ~full_context ~since_len:parent.prepare_context_len in
        let merged = merge_dna_with_delta ~prepared_dna ~delta in
        Printf.printf "[MITOSIS/DELTA] Merged DNA: prepared=%d chars + delta=%d chars\n%!"
          (String.length prepared_dna) (String.length delta);
        merged
    | Idle -> bounded_handoff_dna ~config ~parent_cell:parent ~full_context
  in
  let dna = truncate_to_handoff_budget dna in

  (* 2. Parent begins apoptosis *)
  let dying_parent = begin_apoptosis parent in

  (* 3. Activate a stem cell with the DNA *)
  let (child, new_pool) = activate_stem ~pool ~dna in
  let child = { child with generation = parent.generation + 1 } in

  (* 4. Replenish stem pool *)
  let new_stem = create_stem_cell ~generation:(child.generation + 1) in
  let replenished_pool = { new_pool with
    cells = new_stem :: new_pool.cells
  } in

  (child, dying_parent, replenished_pool, dna)

(** Build handoff prompt for the new cell *)
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

(** Execute the full mitosis cycle *)
let execute_mitosis ~config ~pool ~parent ~full_context ~spawn_fn =
  let (child, dying_parent, new_pool, dna) =
    perform_mitosis ~config ~pool ~parent ~full_context in

  (* Build the handoff prompt *)
  let prompt = build_mitosis_prompt ~child ~dna in

  (* Spawn the new agent *)
  let spawn_result = spawn_fn ~prompt in

  (* Complete apoptosis of parent *)
  let _ = complete_apoptosis dying_parent in

  Printf.printf "[MITOSIS] Cell %s (gen %d) → Cell %s (gen %d)\n%!"
    parent.id parent.generation child.id child.generation;

  (spawn_result, child, new_pool, dna)

(** Update cell activity counters *)
let record_activity ~cell ~task_done ~tool_called =
  let task_count = if task_done then cell.task_count + 1 else cell.task_count in
  let tool_call_count = if tool_called then cell.tool_call_count + 1 else cell.tool_call_count in
  { cell with
    task_count;
    tool_call_count;
    last_activity = Time_compat.now ();
  }

(** 2-Phase mitosis result *)
type mitosis_check_result =
  | NoAction                              (* Nothing to do *)
  | Prepared of cell                      (* Phase 1: Cell prepared, DNA extracted *)
  | Handoff of Spawn.spawn_result * cell * stem_pool * string

(** Auto-mitosis check - 2-phase approach *)
let auto_mitosis_check_2phase ~config ~pool ~cell ~context_ratio ~full_context ~spawn_fn =
  (* Phase 2: Check if we should handoff (higher priority) *)
  if should_handoff ~config ~cell ~context_ratio then begin
    Printf.printf "[MITOSIS/HANDOFF] Threshold %.0f%% reached for cell %s (gen %d), executing handoff...\n%!"
      (config.handoff_threshold *. 100.0) cell.id cell.generation;
    let (spawn_result, child, new_pool, dna) =
      execute_mitosis ~config ~pool ~parent:cell ~full_context ~spawn_fn in
    Handoff (spawn_result, child, new_pool, dna)
  end
  (* Phase 1: Check if we should prepare *)
  else if should_prepare ~config ~cell ~context_ratio then begin
    let prepared_cell = prepare_for_division ~config ~cell ~full_context in
    Prepared prepared_cell
  end
  else
    NoAction

(** Legacy auto-mitosis check - for backward compat *)
let auto_mitosis_check ~config ~pool ~cell ~context_ratio ~full_context ~spawn_fn =
  if should_divide ~config ~cell ~context_ratio then begin
    Printf.printf "[MITOSIS/AUTO] Trigger met for cell %s (gen %d), dividing...\n%!"
      cell.id cell.generation;
    Some (execute_mitosis ~config ~pool ~parent:cell ~full_context ~spawn_fn)
  end
  else
    None

(** Cell to JSON *)
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

(** Pool to JSON *)
let pool_to_json pool =
  `Assoc [
    ("cells", `List (List.map cell_to_json pool.cells));
    ("max_size", `Int pool.max_size);
    ("warm_up_count", `Int pool.warm_up_count);
    ("stem_count", `Int (List.length (List.filter (fun c -> c.state = Stem) pool.cells)));
  ]

(** Trigger to JSON *)
let trigger_to_json = function
  | Time_based f -> `Assoc [("type", `String "time_based"); ("interval_seconds", `Float f)]
  | Task_count n -> `Assoc [("type", `String "task_count"); ("count", `Int n)]
  | Tool_calls n -> `Assoc [("type", `String "tool_calls"); ("count", `Int n)]
  | Context_threshold f -> `Assoc [("type", `String "context_threshold"); ("threshold", `Float f)]
  | Complexity_spike -> `Assoc [("type", `String "complexity_spike")]

(** Config to JSON *)
let config_to_json config =
  `Assoc [
    ("triggers", `List (List.map trigger_to_json config.triggers));
    ("stem_pool_size", `Int config.stem_pool_size);
    ("max_generation", `Int config.max_generation);
    ("dna_compression_ratio", `Float config.dna_compression_ratio);
    ("apoptosis_delay", `Float config.apoptosis_delay);
    (* 2-Phase thresholds *)
    ("prepare_threshold", `Float config.prepare_threshold);
    ("handoff_threshold", `Float config.handoff_threshold);
  ]

(** Write mitosis status to file for hook consumption.
    Hook reads this file to warn Claude about context pressure. *)
let write_status ~base_path ~cell ~config =
  let masc_dir = Filename.concat base_path ".masc" in
  let status_file = Filename.concat masc_dir "mitosis-status.json" in
  (* Estimate context ratio from tool calls *)
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
  (* Ensure .masc directory exists *)
  if Sys.file_exists masc_dir && Sys.is_directory masc_dir then begin
    try
      Fs_compat.save_file status_file (Yojson.Safe.pretty_to_string json ^ "\n")
    with exn ->
      Log.Mitosis_log.error "Failed to write status: %s" (Printexc.to_string exn)
  end

(** Write mitosis status to both local file AND backend (for cross-machine collaboration).
    - Local file: Hook reads this to warn Claude about context pressure
    - Backend (PostgreSQL): Other agents on different machines can see context pressure
    Key format: mitosis:{node_id} *)
let write_status_with_backend ~room_config ~cell ~config =
  let open Room_utils in
  let base_path = room_config.base_path in
  let node_id = room_config.backend_config.Backend.node_id in
  let cluster_name = room_config.backend_config.Backend.cluster_name in

  (* Calculate status using named constant *)
  let tool_calls = cell.tool_call_count in
  let estimated_ratio = Float.min 1.0 (Float.of_int tool_calls /. Defaults.tool_calls_per_full_context) in
  let status =
    if estimated_ratio >= config.handoff_threshold then "critical"
    else if estimated_ratio >= config.prepare_threshold then "warning"
    else "healthy" in

  (* JSON with node_id for multi-agent distinction *)
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

  (* 1. Write to local file (for hook consumption) *)
  let masc_dir = Filename.concat base_path ".masc" in
  let status_file = Filename.concat masc_dir "mitosis-status.json" in
  if Sys.file_exists masc_dir && Sys.is_directory masc_dir then begin
    try
      Fs_compat.save_file status_file (Yojson.Safe.pretty_to_string json ^ "\n")
    with exn ->
      Log.Mitosis_log.error "Failed to write status file: %s"
        (Printexc.to_string exn)
  end;

  (* 2. Write to backend (for cross-machine collaboration) *)
  let key = Printf.sprintf "mitosis:%s" node_id in
  (match backend_set room_config ~key ~value:json_str with
   | Ok () -> ()
   | Error e -> Log.Misc.error "mitosis: backend_set failed for %s: %s" node_id (Backend.show_error e))

(** Get all mitosis statuses from backend (for monitoring other agents) *)
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
        | _ -> None  (* Defensive: any other parse error *)
      ) pairs
  | Error _ -> []
