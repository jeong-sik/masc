(** Autoresearch — Autonomous experiment loop inspired by Karpathy's autoresearch.

    Facade module that re-exports sub-modules for backward compatibility.
    Implementation is split across:
    - {!Autoresearch_types}   -- type definitions
    - {!Autoresearch_serde}   -- JSON serialization/deserialization
    - {!Autoresearch_storage} -- file paths, persistence, load/save
    - {!Autoresearch_metric}  -- metric measurement and retry
    - {!Autoresearch_git}     -- git operations (commit, reset, tag, worktree)
    - {!Autoresearch_file}    -- target file validation and code change application
    - {!Autoresearch_codegen} -- LLM prompt building and response parsing

    Each cycle:
    1. MODEL generates hypothesis + code change
    2. git commit (tentative)
    3. Run metric_fn (shell command, bounded by cycle_timeout_s)
    4. Compare score vs baseline
    5. Improved -> keep commit, Not improved -> git reset
    6. Record result in JSONL
    7. Update baseline (if improved), loop

    Storage: .masc/autoresearch/{loop_id}/results.jsonl

    @since 2.80.0 *)

include Autoresearch_types

(* ================================================================ *)
(* Global State                                                      *)
(* ================================================================ *)

let active_loops : (string, loop_state) Hashtbl.t = Hashtbl.create 4
let latest_loop_id : string option ref = ref None

(** Eio.Mutex protecting [active_loops] and [latest_loop_id] against
    concurrent reads/writes from parallel tool handlers. *)
let loops_mu = Eio.Mutex.create ()

(** Execute [f] under exclusive write lock on the loops registry. *)
let with_loops_rw f = Eio.Mutex.use_rw ~protect:true loops_mu (fun () -> f ())

(** Execute [f] under shared read lock on the loops registry. *)
let with_loops_ro f = Eio.Mutex.use_ro loops_mu (fun () -> f ())

let generate_loop_id () =
  let rnd = Mirage_crypto_rng.generate 4 in
  let hex = List.fold_left (fun acc s -> acc ^ s) "" (List.init (String.length rnd) (fun i -> Printf.sprintf "%02x" (Char.code (String.get rnd i)))) in
  "ar-" ^ hex

let option_first_some left right =
  match left with Some _ -> left | None -> right

(* ================================================================ *)
(* Re-exports: Serde                                                 *)
(* ================================================================ *)

let decision_to_string = Autoresearch_serde.decision_to_string
let decision_of_string_result = Autoresearch_serde.decision_of_string_result
let status_to_string = Autoresearch_serde.status_to_string
let status_of_string_result = Autoresearch_serde.status_of_string_result
let cycle_to_yojson = Autoresearch_serde.cycle_to_yojson
let cycle_of_yojson_result = Autoresearch_serde.cycle_of_yojson_result
let state_to_yojson = Autoresearch_serde.state_to_yojson
let state_of_yojson_result = Autoresearch_serde.state_of_yojson_result
let execution_link_to_yojson = Autoresearch_serde.execution_link_to_yojson
let execution_link_of_yojson_result = Autoresearch_serde.execution_link_of_yojson_result

(* ================================================================ *)
(* Re-exports: Storage                                               *)
(* ================================================================ *)

let results_dir = Autoresearch_storage.results_dir
let results_file = Autoresearch_storage.results_file
let state_file = Autoresearch_storage.state_file
let loop_link_file = Autoresearch_storage.loop_link_file
let managed_worktree_dir = Autoresearch_storage.managed_worktree_dir
let session_link_file = Autoresearch_storage.session_link_file
let ensure_dir = Autoresearch_storage.ensure_dir
let append_cycle = Autoresearch_storage.append_cycle
let save_state = Autoresearch_storage.save_state
let save_execution_link = Autoresearch_storage.save_execution_link
let load_execution_link_by_loop = Autoresearch_storage.load_execution_link_by_loop
let load_execution_link_by_session = Autoresearch_storage.load_execution_link_by_session
let load_execution_link_by_loop_result = Autoresearch_storage.load_execution_link_by_loop_result
let load_execution_link_by_session_result = Autoresearch_storage.load_execution_link_by_session_result
let load_state = Autoresearch_storage.load_state
let load_state_result = Autoresearch_storage.load_state_result
let latest_cycle_record = Autoresearch_storage.latest_cycle_record
let load_cycle_history = Autoresearch_storage.load_cycle_history
let scan_persisted_loop_ids = Autoresearch_storage.scan_persisted_loop_ids

(* ================================================================ *)
(* Re-exports: Metric                                                *)
(* ================================================================ *)

let contains_substring = String_util.contains_substring
let validate_metric_fn = Autoresearch_metric.validate_metric_fn
let measure_metric = Autoresearch_metric.measure_metric
let measure_metric_with_retry = Autoresearch_metric.measure_metric_with_retry

(* ================================================================ *)
(* Re-exports: Git                                                   *)
(* ================================================================ *)

let is_in_git_repo = Autoresearch_git.is_in_git_repo
let run_capture_lines = Autoresearch_git.run_capture_lines
let git_head_short = Autoresearch_git.git_head_short
let git_commit = Autoresearch_git.git_commit
let git_restore_head = Autoresearch_git.git_restore_head
let git_reset_last = Autoresearch_git.git_reset_last
let git_commit_cycle = Autoresearch_git.git_commit_cycle
let git_tag_best = Autoresearch_git.git_tag_best
let git_top_level = Autoresearch_git.git_top_level
let git_current_branch = Autoresearch_git.git_current_branch
let git_is_dirty = Autoresearch_git.git_is_dirty
let managed_branch_name = Autoresearch_git.managed_branch_name
let prepare_managed_worktree = Autoresearch_git.prepare_managed_worktree

(* ================================================================ *)
(* Re-exports: File                                                  *)
(* ================================================================ *)

let has_path_traversal = Autoresearch_file.has_path_traversal
let resolve_target_file_path = Autoresearch_file.resolve_target_file_path
let validate_target_file = Autoresearch_file.validate_target_file
let read_file = Autoresearch_file.read_file
let apply_code_change = Autoresearch_file.apply_code_change

(* ================================================================ *)
(* Re-exports: Codegen                                               *)
(* ================================================================ *)

let build_code_change_prompt = Autoresearch_codegen.build_code_change_prompt
let parse_model_code_response = Autoresearch_codegen.parse_model_code_response
let generate_code_change = Autoresearch_codegen.generate_code_change

(* ================================================================ *)
(* Loop State Management                                             *)
(* ================================================================ *)

let create_state ~goal ~metric_fn ?model_model ?author ~target_file ?target_score
    ~cycle_timeout_s ~max_cycles ?patience ?build_verify_fn
    ?(lower_is_better = false) ~workdir () =
  let model_model = match model_model with
    | Some m -> m
    | None -> Provider_adapter.default_model_provider_prefix_result () |> Result.value ~default:"auto"
  in
  let now = Time_compat.now () in
  let patience = match patience with
    | Some p -> p
    | None -> max 3 (max_cycles / 3)
  in
  {
    loop_id = generate_loop_id ();
    author;
    goal;
    metric_fn;
    model_model;
    target_file;
    target_score;
    status = Running;
    error_message = None;
    current_cycle = 0;
    baseline = 0.0;
    best_score = 0.0;
    best_cycle = 0;
    queued_hypothesis = None;
    history = [];
    total_keeps = 0;
    total_discards = 0;
    insights = [];
    start_time = now;
    updated_at = now;
    cycle_timeout_s;
    max_cycles;
    workdir;
    source_workdir = workdir;
    program_note = None;
    warnings = [];
    patience;
    consecutive_discards = 0;
    build_verify_fn;
    lower_is_better;
  }

(** Append an insight, maintaining FIFO max 10 entries.
    Returns updated state. *)
let add_insight (state : loop_state) msg =
  let max_insights = 10 in
  let insights = msg :: state.insights in
  let insights =
    if List.length insights > max_insights then
      List.filteri (fun i _ -> i < max_insights) insights
    else insights
  in
  { state with insights }

(** Record one completed experiment cycle.
    Returns [(state, record)] with the updated state. *)
let record_cycle (state : loop_state) ~hypothesis ~score_before ~score_after
    ~commit_hash ~elapsed_ms ~model_used =
  let delta = score_after -. score_before in
  (* Compare against the maintained baseline, not score_before which can dip
     below baseline due to metric noise -- preventing ratchet-down regressions.
     Polarity: lower_is_better inverts the comparison direction. *)
  let is_improvement =
    if state.lower_is_better then score_after < state.baseline
    else score_after > state.baseline
  in
  let decision = if is_improvement then Keep else Discard in
  let now = Time_compat.now () in
  let record = {
    cycle = state.current_cycle;
    hypothesis;
    score_before;
    score_after;
    delta;
    decision;
    commit_hash;
    elapsed_ms;
    model_used;
    timestamp = now;
  } in
  let state = { state with history = record :: state.history; updated_at = now } in
  let state =
    match decision with
    | Keep ->
      let state = { state with
        total_keeps = state.total_keeps + 1;
        baseline = score_after } in
      let is_new_best =
        if state.lower_is_better then score_after < state.best_score
        else score_after > state.best_score
      in
      let state =
        if is_new_best then
          { state with best_score = score_after; best_cycle = state.current_cycle }
        else state
      in
      add_insight state
        (Printf.sprintf "Cycle %d: %s improved +%.4f" state.current_cycle hypothesis delta)
    | Discard ->
      let state = { state with total_discards = state.total_discards + 1 } in
      add_insight state
        (Printf.sprintf "Cycle %d: %s no improvement (%.4f)" state.current_cycle hypothesis delta)
  in
  (state, record)

let target_reached (state : loop_state) =
  match state.target_score with
  | None -> false
  | Some target ->
      if state.lower_is_better then state.best_score <= target
      else state.best_score >= target

let completion_reason (state : loop_state) =
  if target_reached state then
    Some "target_score reached"
  else if state.current_cycle >= state.max_cycles then
    Some "max_cycles reached"
  else
    None

let complete_if_finished (state : loop_state) =
  match state.status, completion_reason state with
  | Running, Some "target_score reached" ->
      let target =
        match state.target_score with
        | Some value -> Printf.sprintf "%.4f" value
        | None -> "n/a"
      in
      add_insight
        { state with status = Completed; updated_at = Time_compat.now () }
        (Printf.sprintf "Target reached at cycle %d (target=%s, best=%.4f)"
           state.current_cycle target state.best_score)
  | Running, Some reason ->
      add_insight
        { state with status = Completed; updated_at = Time_compat.now () }
        (Printf.sprintf "Autoresearch completed: %s" reason)
  | _ -> state

(** Check if the loop should continue. *)
let should_continue (state : loop_state) =
  state.status = Running && Option.is_none (completion_reason state)

(** Stop a running or persisted loop.
    Acquires [loops_mu] write lock internally. *)
let stop_loop ~base_path ?reason loop_id =
  let stop_state (state : loop_state) =
    let state = { state with
      status = Stopped;
      error_message = reason;
      updated_at = Time_compat.now () } in
    save_state ~base_path state;
    Hashtbl.replace active_loops loop_id state;
    state
  in
  with_loops_rw (fun () ->
    match Hashtbl.find_opt active_loops loop_id with
    | Some state -> Some (stop_state state)
    | None -> (
        match load_state ~base_path loop_id with
        | None -> None
        | Some persisted ->
            let now = Time_compat.now () in
            let state =
              {
                loop_id = persisted.loop_id;
                author = persisted.author;
                goal = persisted.goal;
                metric_fn = persisted.metric_fn;
                model_model = persisted.model_model;
                target_file = persisted.target_file;
                target_score = persisted.target_score;
                status = persisted.status;
                error_message = persisted.error_message;
                current_cycle = persisted.current_cycle;
                baseline = persisted.baseline;
                best_score = persisted.best_score;
                best_cycle = persisted.best_cycle;
                queued_hypothesis = persisted.queued_hypothesis;
                history = [];
                total_keeps = persisted.total_keeps;
                total_discards = persisted.total_discards;
                insights = [];
                start_time = now -. max 0.0 persisted.elapsed_s;
                updated_at = now;
                cycle_timeout_s = persisted.cycle_timeout_s;
                max_cycles = persisted.max_cycles;
                workdir = persisted.workdir;
                source_workdir = persisted.source_workdir;
                program_note = persisted.program_note;
                warnings = persisted.warnings;
                patience = persisted.patience;
                consecutive_discards = persisted.consecutive_discards;
                build_verify_fn = persisted.build_verify_fn;
                lower_is_better = persisted.lower_is_better;
              }
            in
            Some (stop_state state)))

(** Linked loop status JSON for execution-session integration.
    Acquires [loops_mu] read lock internally. *)
let linked_status_json ~base_path (link : execution_link) =
  let current_cycle, status, best_score, target_score, error_message, workdir,
      lower_is_better, source_workdir, program_note, warnings,
      queued_hypothesis =
    with_loops_ro (fun () ->
      match Hashtbl.find_opt active_loops link.loop_id with
      | Some state ->
          ( state.current_cycle,
            status_to_string state.status,
            state.best_score,
            state.target_score,
            state.error_message,
            state.workdir,
            state.lower_is_better,
            state.source_workdir,
            state.program_note,
            state.warnings,
            state.queued_hypothesis )
      | None -> (
          match load_state ~base_path link.loop_id with
          | Some persisted ->
              ( persisted.current_cycle,
                status_to_string persisted.status,
                persisted.best_score,
                persisted.target_score,
                persisted.error_message,
                persisted.workdir,
                persisted.lower_is_better,
                persisted.source_workdir,
                persisted.program_note,
                persisted.warnings,
                persisted.queued_hypothesis )
          | None ->
              ( 0,
                "missing",
                0.0,
                None,
                Some "state file missing",
                managed_worktree_dir ~base_path link.loop_id,
                false,
                "",
                link.program_note,
                [],
                None )))
  in
  let last_decision =
    match latest_cycle_record ~base_path link.loop_id with
    | Some record -> Some (decision_to_string record.decision)
    | None -> None
  in
  `Assoc
    [
      ("loop_id", `String link.loop_id);
      ("session_id", `String link.session_id);
      ("task_id", Json_util.string_opt_to_json link.task_id);
      ("status", `String status);
      ("current_cycle", `Int current_cycle);
      ("best_score", `Float best_score);
      ("target_score", Json_util.float_opt_to_json target_score);
      ( "target_reached",
        `Bool
          (match target_score with
           | None -> false
           | Some target ->
               if lower_is_better then best_score <= target
               else best_score >= target) );
      ( "last_decision",
        Json_util.string_opt_to_json last_decision );
      ("target_file", `String link.target_file);
      ( "program_note",
        Json_util.string_opt_to_json (option_first_some program_note link.program_note) );
      ( "operation_id",
        Json_util.string_opt_to_json link.operation_id );
      ("workdir", `String workdir);
      ("source_workdir", `String source_workdir);
      ("warnings", `List (List.map (fun value -> `String value) warnings));
      ( "queued_hypothesis",
        Json_util.string_opt_to_json queued_hypothesis );
      ("error", Json_util.string_opt_to_json error_message);
    ]

(** Summary for status reporting. *)
let summary (state : loop_state) =
  let recent = List.filteri (fun i _ -> i < 5) state.history in
  let recent_json = `List (List.map cycle_to_yojson recent) in
  let base = state_to_yojson state in
  match base with
  | `Assoc fields ->
    `Assoc (fields @ [("recent_cycles", recent_json)])
  | other -> other
