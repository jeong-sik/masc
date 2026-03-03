(** MDAL — Metric-Driven Agent Loop

    Orchestrates iterative improvement loops where each iteration:
    1. Measures a metric via shell command
    2. Spawns a worker agent to improve it
    3. Re-measures and records delta
    4. Decides whether to continue, switch strategy, or stop

    Uses Board for state persistence and SSE for real-time updates.

    @since 2.70.0 *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

(** A profile defines the metric, goal, and constraints for a loop. *)
type profile = {
  name : string;
  metric_fn : string;              (** Shell command that outputs a float *)
  goal : Bounded.goal;             (** When to stop (e.g., metric >= 0.95) *)
  target : string;                 (** Human-readable target description *)
  reference : string option;       (** Optional reference file/dir *)
  agent : string;                  (** Agent type to spawn (e.g., "claude") *)
  max_iterations : int;            (** Hard iteration limit *)
  max_time_seconds : float option; (** Optional wall-clock limit *)
  stagnation_threshold : float;    (** Min delta to count as progress *)
  stagnation_count : int;          (** Consecutive stagnation iterations before stop *)
  heuristics : string;             (** Domain-specific hints for the worker *)
  tools_allow : string list;       (** Tools the worker may use *)
  tools_deny : string list;        (** Tools the worker must NOT use *)
}

(** One iteration's record. *)
type iteration_record = {
  iteration : int;
  metric_before : float;
  metric_after : float;
  delta : float;
  changes : string;
  failed_attempts : string;
  next_suggestion : string;
  elapsed_ms : int;
  cost_usd : float option;
}

(** Mutable state for a running loop. *)
type loop_state = {
  loop_id : string;
  profile : profile;
  mutable status : [ `Running | `Completed | `Stopped | `Error of string ];
  mutable current_iteration : int;
  mutable history : iteration_record list;  (** Most recent first *)
  mutable stagnation_streak : int;
  baseline_metric : float;
  start_time : float;
  state_post_id : string;
}

(* ================================================================ *)
(* ID Generation                                                    *)
(* ================================================================ *)

let generate_loop_id () =
  let rnd = Mirage_crypto_rng.generate 8 in
  let hex = String.concat "" (
    List.init (String.length rnd) (fun i ->
      Printf.sprintf "%02x" (Char.code (String.get rnd i))
    )
  ) in
  "mdal-" ^ hex

(* ================================================================ *)
(* Hearth Names (Board topic categories)                            *)
(* ================================================================ *)

let iter_hearth loop_id = "mdal-iter-" ^ loop_id
let state_hearth loop_id = "mdal-" ^ loop_id

(* ================================================================ *)
(* Built-in Profiles                                                *)
(* ================================================================ *)

let builtin_profile name =
  match name with
  | "ssim" ->
    { name = "ssim";
      metric_fn = "python3 -c \"import sys; from skimage.metrics import structural_similarity; print(structural_similarity(...))\"";
      goal = { path = "metric"; condition = Bounded.Gte 0.95 };
      target = "SSIM >= 0.95 (perceptual similarity)";
      reference = None;
      agent = "claude";
      max_iterations = 20;
      max_time_seconds = Some 3600.0;
      stagnation_threshold = 0.005;
      stagnation_count = 3;
      heuristics = "Focus on structural accuracy. Prioritize layout over colors. Use pixel-level comparison.";
      tools_allow = [];
      tools_deny = [];
    }
  | "coverage" ->
    { name = "coverage";
      metric_fn = "make test-coverage 2>/dev/null | tail -1 | rg -o '[0-9]+\\.[0-9]+' | head -1";
      goal = { path = "metric"; condition = Bounded.Gte 80.0 };
      target = "Test coverage >= 80%";
      reference = None;
      agent = "claude";
      max_iterations = 15;
      max_time_seconds = Some 1800.0;
      stagnation_threshold = 1.0;
      stagnation_count = 3;
      heuristics = "Add tests for uncovered branches. Focus on error paths and edge cases. Avoid trivial getter tests.";
      tools_allow = [];
      tools_deny = [];
    }
  | "lint" ->
    { name = "lint";
      metric_fn = "make lint 2>&1 | rg -c 'error|warning' || echo 0";
      goal = { path = "metric"; condition = Bounded.Lte 0.0 };
      target = "Zero lint errors/warnings";
      reference = None;
      agent = "claude";
      max_iterations = 10;
      max_time_seconds = Some 900.0;
      stagnation_threshold = 1.0;
      stagnation_count = 2;
      heuristics = "Fix errors before warnings. Group related fixes. Don't suppress warnings without justification.";
      tools_allow = [];
      tools_deny = [];
    }
  | "review" ->
    { name = "review";
      metric_fn = "echo 0.5";
      goal = { path = "metric"; condition = Bounded.Gte 0.9 };
      target = "Code review score >= 0.9";
      reference = None;
      agent = "claude";
      max_iterations = 5;
      max_time_seconds = Some 1200.0;
      stagnation_threshold = 0.05;
      stagnation_count = 2;
      heuristics = "Address high-severity issues first. Verify each fix doesn't introduce regressions.";
      tools_allow = [];
      tools_deny = [];
    }
  | "docs" ->
    { name = "docs";
      metric_fn = "echo 0.3";
      goal = { path = "metric"; condition = Bounded.Gte 0.8 };
      target = "Documentation coverage >= 0.8";
      reference = None;
      agent = "claude";
      max_iterations = 10;
      max_time_seconds = Some 1200.0;
      stagnation_threshold = 0.05;
      stagnation_count = 3;
      heuristics = "Document public APIs first. Include examples. Keep docstrings concise.";
      tools_allow = [];
      tools_deny = [];
    }
  | other ->
    invalid_arg (Printf.sprintf "Unknown built-in profile: %s. Use custom profile instead." other)

(* ================================================================ *)
(* Goal Parsing                                                     *)
(* ================================================================ *)

(** Parse a string like "ssim >= 0.95" into a Bounded.goal.
    Format: "<path> <op> <value>"
    Supported ops: >=, <=, >, <, ==, != *)
let parse_goal s =
  let s = String.trim s in
  (* Try to match: metric_name op value *)
  let parts = Str.split (Str.regexp "[ \t]+") s in
  match parts with
  | [path; op; value_str] ->
    let value = float_of_string value_str in
    let condition = match op with
      | ">=" -> Bounded.Gte value
      | "<=" -> Bounded.Lte value
      | ">" -> Bounded.Gt value
      | "<" -> Bounded.Lt value
      | "==" -> Bounded.Eq (`Float value)
      | "!=" -> Bounded.Neq (`Float value)
      | _ -> invalid_arg (Printf.sprintf "Unknown operator: %s (use >=, <=, >, <, ==, !=)" op)
    in
    { Bounded.path; condition }
  | _ ->
    invalid_arg (Printf.sprintf "Invalid goal format: '%s'. Expected: '<metric> <op> <value>'" s)

(* ================================================================ *)
(* Stagnation Detection                                             *)
(* ================================================================ *)

let stagnation_exceeded (state : loop_state) : bool =
  state.stagnation_streak >= state.profile.stagnation_count

let time_exceeded (state : loop_state) (profile : profile) : bool =
  match profile.max_time_seconds with
  | None -> false
  | Some max_t ->
    let elapsed = Time_compat.now () -. state.start_time in
    elapsed > max_t

let update_stagnation (state : loop_state) (record : iteration_record) : unit =
  if Float.abs record.delta < state.profile.stagnation_threshold then
    state.stagnation_streak <- state.stagnation_streak + 1
  else
    state.stagnation_streak <- 0

(* ================================================================ *)
(* Metric Measurement                                               *)
(* ================================================================ *)

(** Run a shell command and parse the first float from stdout.
    Uses Process_eio if initialized, falls back to Unix. *)
let measure_metric (cmd : string) : (float, string) result =
  try
    let output = Process_eio.run_argv ~timeout_sec:30.0 ["sh"; "-c"; cmd] in
    let trimmed = String.trim output in
    if trimmed = "" then
      Error (Printf.sprintf "Metric command returned empty output: %s" cmd)
    else
      match float_of_string_opt trimmed with
      | Some v -> Ok v
      | None ->
        (* Try to extract first float-like substring *)
        let re = Str.regexp "[0-9]+\\(\\.[0-9]+\\)?" in
        if Str.string_match re trimmed 0 then
          match float_of_string_opt (Str.matched_string trimmed) with
          | Some v -> Ok v
          | None -> Error (Printf.sprintf "Cannot parse float from: %s" trimmed)
        else
          Error (Printf.sprintf "No numeric value found in: %s" trimmed)
  with
  | exn ->
    Error (Printf.sprintf "Metric command failed: %s — %s" cmd (Printexc.to_string exn))

(* ================================================================ *)
(* Worker Prompt Generation                                         *)
(* ================================================================ *)

let render_worker_prompt (profile : profile) (history : iteration_record list)
    (current_metric : float) : string =
  let history_text =
    if history = [] then "No previous iterations."
    else
      let lines = List.map (fun (r : iteration_record) ->
        Printf.sprintf "  Iter %d: %.4f -> %.4f (delta=%.4f) [%dms] %s"
          r.iteration r.metric_before r.metric_after r.delta r.elapsed_ms
          (if r.changes = "" then "" else "Changes: " ^ r.changes)
      ) history in
      String.concat "\n" lines
  in
  let tool_rules =
    let allow = match profile.tools_allow with
      | [] -> ""
      | ts -> Printf.sprintf "\nAllowed tools: %s" (String.concat ", " ts)
    in
    let deny = match profile.tools_deny with
      | [] -> ""
      | ts -> Printf.sprintf "\nForbidden tools: %s" (String.concat ", " ts)
    in
    allow ^ deny
  in
  Printf.sprintf {|You are an improvement agent in a metric-driven loop (MDAL).

GOAL: %s
CURRENT METRIC: %.4f
TARGET: %s

HISTORY:
%s

DOMAIN HINTS:
%s
%s
OUTPUT FORMAT (strict JSON):
{
  "changes": "description of what you changed",
  "failed_attempts": "what you tried that didn't work (empty string if none)",
  "next_suggestion": "what to try next iteration if needed"
}

Focus on making measurable progress toward the goal. Each iteration should improve the metric.
Do NOT output anything outside the JSON block.|}
    profile.name current_metric profile.target
    history_text profile.heuristics tool_rules

(* ================================================================ *)
(* Board Post Formatting                                            *)
(* ================================================================ *)

let format_state_post (state : loop_state) : string =
  let status_str = match state.status with
    | `Running -> "RUNNING"
    | `Completed -> "COMPLETED"
    | `Stopped -> "STOPPED"
    | `Error e -> Printf.sprintf "ERROR: %s" e
  in
  let elapsed = Time_compat.now () -. state.start_time in
  let latest_metric = match state.history with
    | r :: _ -> Printf.sprintf "%.4f" r.metric_after
    | [] -> Printf.sprintf "%.4f" state.baseline_metric
  in
  Printf.sprintf {|[MDAL_STATE] %s
Loop: %s | Profile: %s | Status: %s
Iteration: %d/%d | Stagnation: %d/%d
Baseline: %.4f | Current: %s
Elapsed: %.0fs | Goal: %s|}
    state.loop_id state.loop_id state.profile.name status_str
    state.current_iteration state.profile.max_iterations
    state.stagnation_streak state.profile.stagnation_count
    state.baseline_metric latest_metric
    elapsed state.profile.target

let format_iter_post (record : iteration_record) : string =
  Printf.sprintf {|[MDAL_ITER] #%d
Before: %.4f | After: %.4f | Delta: %+.4f
Changes: %s
Failed: %s
Next: %s
Elapsed: %dms | Cost: %s|}
    record.iteration record.metric_before record.metric_after record.delta
    (if record.changes = "" then "(none)" else record.changes)
    (if record.failed_attempts = "" then "(none)" else record.failed_attempts)
    (if record.next_suggestion = "" then "(none)" else record.next_suggestion)
    record.elapsed_ms
    (match record.cost_usd with Some c -> Printf.sprintf "$%.4f" c | None -> "n/a")

let format_final_post (state : loop_state) : string =
  let status_str = match state.status with
    | `Running -> "RUNNING"
    | `Completed -> "COMPLETED"
    | `Stopped -> "STOPPED"
    | `Error e -> Printf.sprintf "ERROR: %s" e
  in
  let elapsed = Time_compat.now () -. state.start_time in
  let final_metric = match state.history with
    | r :: _ -> r.metric_after
    | [] -> state.baseline_metric
  in
  let total_delta = final_metric -. state.baseline_metric in
  let avg_delta =
    if state.current_iteration > 0 then
      total_delta /. float_of_int state.current_iteration
    else 0.0
  in
  Printf.sprintf {|[MDAL_FINAL] %s
Loop: %s | Profile: %s | Result: %s
Iterations: %d | Baseline: %.4f | Final: %.4f
Total Delta: %+.4f | Avg Delta/Iter: %+.4f
Total Time: %.0fs
Goal: %s|}
    state.loop_id state.loop_id state.profile.name status_str
    state.current_iteration state.baseline_metric final_metric
    total_delta avg_delta elapsed state.profile.target

(* ================================================================ *)
(* Worker Result Parsing                                            *)
(* ================================================================ *)

(** Parse JSON output from the worker agent into an iteration_record.
    Expects: { "changes": "...", "failed_attempts": "...", "next_suggestion": "..." }
    The metric values and timing are filled in by the caller. *)
let parse_worker_result (raw : string) : (iteration_record, string) result =
  try
    (* Try to extract JSON from possibly noisy output *)
    let json_str =
      let open Str in
      (* Find first { ... } block — use search_forward to handle multiline *)
      let re = regexp "{[^}]*}" in
      (try
        let _ = search_forward re raw 0 in
        matched_string raw
      with Not_found -> raw)
    in
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let changes = json |> member "changes" |> to_string_option
                  |> Option.value ~default:"" in
    let failed_attempts = json |> member "failed_attempts" |> to_string_option
                          |> Option.value ~default:"" in
    let next_suggestion = json |> member "next_suggestion" |> to_string_option
                          |> Option.value ~default:"" in
    Ok {
      iteration = 0;  (* Filled by caller *)
      metric_before = 0.0;
      metric_after = 0.0;
      delta = 0.0;
      changes;
      failed_attempts;
      next_suggestion;
      elapsed_ms = 0;
      cost_usd = None;
    }
  with
  | Yojson.Json_error msg ->
    let truncated = if String.length raw > 200 then String.sub raw 0 200 else raw in
    Error (Printf.sprintf "JSON parse error: %s (raw: %s)" msg truncated)
  | exn ->
    let truncated = if String.length raw > 200 then String.sub raw 0 200 else raw in
    Error (Printf.sprintf "Parse error: %s (raw: %s)" (Printexc.to_string exn) truncated)

(* ================================================================ *)
(* Iteration Evaluation                                             *)
(* ================================================================ *)

(** Evaluate the result of an iteration to decide next action. *)
let evaluate_iteration (record : iteration_record) :
    [ `Continue_same_strategy | `Switch_area | `Revert_and_switch | `Stagnation ] =
  let abs_delta = Float.abs record.delta in
  if record.delta < -0.01 then
    (* Regression: metric got worse *)
    `Revert_and_switch
  else if abs_delta < 0.001 then
    (* Essentially no change *)
    `Stagnation
  else if record.delta > 0.0 && abs_delta < 0.005 then
    (* Tiny improvement, might be worth switching area *)
    `Switch_area
  else
    (* Meaningful improvement *)
    `Continue_same_strategy
