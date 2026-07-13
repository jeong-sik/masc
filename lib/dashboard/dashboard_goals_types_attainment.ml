(** Dashboard_goals_types_attainment — Stage 22 split (was inline in
    dashboard_goals_types.ml).

    Pure metric tokenizer + percent/count inference + the goal attainment
    JSON projection ([build_attainment_json] + [goal_attainment_to_json]).
    All inputs are already-loaded; no I/O.

    Depends on [Dashboard_goals_types_accessor] for the [attainment_unit]
    variant, the [tree_node] record, and [task_is_done]. Re-included by
    [Dashboard_goals_types] so the public surface is unchanged. *)

open Dashboard_goals_types_accessor

let clamp_float lower upper value =
  if value < lower then lower else if value > upper then upper else value

let contains_ci = String_util.contains_substring_ci

let pct_of_float value =
  int_of_float (floor (clamp_float 0.0 100.0 value +. 0.5))

let attainment_unit_to_string = function
  | Percent -> "percent"
  | Count -> "count"
  | Unknown -> "unknown"

let metric_evaluation_to_string = function
  | Metric_unevaluated -> "unevaluated"
  | Metric_absent -> "absent"

let metric_evaluation_of_string = function
  | "unevaluated" -> Some Metric_unevaluated
  | "absent" -> Some Metric_absent
  | _ -> None

(* A goal with a declared metric is [Metric_unevaluated] until a measurement
   source records an observation. This is display-only and never gates Goal
   lifecycle transitions. See the type comment in
   Dashboard_goals_types_accessor. *)
let metric_evaluation_of_goal (goal : Goal_store.goal) =
  match goal.metric with
  | Some _ -> Metric_unevaluated
  | None -> Metric_absent



(* Token-split that respects camelCase AND acronym boundaries.

   - lower -> upper splits (so [successRate] -> [success; rate])
   - upper -> upper-followed-by-lower splits (so [APIRatio] ->
     [api; ratio]; [PRCount] -> [pr; count])
   - consecutive uppercase letters not followed by a lowercase stay
     glued (so [API] -> [api], [HTTP] -> [http])

   Without the acronym rule, common acronym-prefixed metric names
   regressed against percent inference: post-#13170 review noted
   that names like [APIRatio] / [PRCount] still missed the percent
   token even after the camelCase fix. The split point is the
   *last* uppercase letter in a run -- that is the start of the
   following lowercase word -- not every uppercase letter, so
   abbreviations stay intact. *)
let metric_word_tokens raw =
  let len = String.length raw in
  let tokens = ref [] in
  let current = Buffer.create 16 in
  let flush () =
    if Buffer.length current > 0 then (
      tokens := Buffer.contents current :: !tokens;
      Buffer.clear current)
  in
  let is_lower c = c >= 'a' && c <= 'z' in
  let is_upper c = c >= 'A' && c <= 'Z' in
  let next_at i = if i + 1 < len then Some raw.[i + 1] else None in
  let prev_at i = if i > 0 then Some raw.[i - 1] else None in
  for i = 0 to len - 1 do
    let ch = raw.[i] in
    match ch with
    | 'A' .. 'Z' ->
        let prev_lower =
          match prev_at i with Some c -> is_lower c | None -> false
        in
        let prev_upper =
          match prev_at i with Some c -> is_upper c | None -> false
        in
        let next_lower =
          match next_at i with Some c -> is_lower c | None -> false
        in
        if prev_lower then flush ()
        else if prev_upper && next_lower then flush ();
        Buffer.add_char current (Char.lowercase_ascii ch)
    | 'a' .. 'z' | '0' .. '9' ->
        Buffer.add_char current ch
    | _ ->
        flush ()
  done;
  flush ();
  List.rev !tokens

(* Post-#13131 review (P1): substring match on "rate"/"ratio"/"pct"
   gave false positives for metric names like "iteration_rate"-vs-
   "iterate", "operation"-vs-"ratio". Match against tokenized words
   (alphanumerics split on punctuation) so only the actual metric
   nouns trigger the percent inference. *)
let metric_word_implies_percent token =
  match token with
  | "percent" | "pct" | "ratio" | "rate" | "completion" -> true
  | _ -> false

let metric_implies_percent metric =
  match metric with
  | None -> false
  | Some raw ->
      String_util.contains_substring_ci raw "%"
      || List.exists metric_word_implies_percent (metric_word_tokens raw)

let metric_count_token = function
  | "task" | "tasks" | "todo" | "todos" | "issue" | "issues" | "ticket"
  | "tickets" | "pr" | "prs" | "done" ->
      true
  | _ ->
      false

let metric_has_pull_request_phrase tokens =
  let rec loop = function
    | "pull" :: next :: _ when next = "request" || next = "requests" -> true
    | _ :: rest -> loop rest
    | [] -> false
  in
  loop tokens

let metric_supports_count_target metric =
  match metric with
  | None -> true
  | Some raw ->
      let tokens = metric_word_tokens raw in
      List.exists metric_count_token tokens
      || metric_has_pull_request_phrase tokens

let target_value_implies_percent raw =
  String_util.contains_substring_ci raw "%"
  || String_util.contains_substring_ci raw "percent"
  || String_util.contains_substring_ci raw "pct"

let strip_number_group_separators token =
  let buffer = Buffer.create (String.length token) in
  String.iter
    (fun ch ->
      if ch <> ',' then
        Buffer.add_char buffer ch)
    token;
  Buffer.contents buffer

let parse_first_float raw =
  let len = String.length raw in
  let is_digit = function
    | '0' .. '9' -> true
    | _ -> false
  in
  let is_start = function
    | '0' .. '9' | '+' | '-' | '.' -> true
    | _ -> false
  in
  let is_part ~start index =
    match raw.[index] with
    | '0' .. '9' | '.' -> true
    | '+' | '-' -> index = start
    | ',' ->
        index > 0 && index + 1 < len && is_digit raw.[index - 1]
        && is_digit raw.[index + 1]
    | _ -> false
  in
  let rec token_end start index =
    if index >= len || not (is_part ~start index) then index
    else token_end start (index + 1)
  in
  let rec search index =
    if index >= len then None
    else if is_start raw.[index] then
      let stop = token_end index index in
      let token = String.sub raw index (stop - index) in
      match float_of_string_opt (strip_number_group_separators token) with
      | Some value when Float.is_finite value -> Some value
      | Some _ | None -> search stop
    else
      search (index + 1)
  in
  search 0

let parsed_target_unit metric raw =
  if target_value_implies_percent raw || metric_implies_percent metric then
    Percent
  else
    Count

let build_attainment_json ~state ~basis ~task_done_count ~task_count
    ~target_parse_status ~unit ~observed_value ~target_numeric ~attainment_pct
    ~note (goal : Goal_store.goal) =
  `Assoc
    [
      ("state", `String state);
      ("basis", `String basis);
      ("metric", Json_util.string_opt_to_json goal.metric);
      (* Typed metric-evaluation state (task-1743): even when [state] /
         [attainment_pct] look like progress, they are task-derived, so this
         field reports whether the metric itself was evaluated. *)
      ( "metric_evaluation",
        `String (metric_evaluation_to_string (metric_evaluation_of_goal goal)) );
      ("target_value", Json_util.string_opt_to_json goal.target_value);
      ("target_parse_status", `String target_parse_status);
      ("unit", `String (attainment_unit_to_string unit));
      ("observed_value", Json_util.float_opt_to_json observed_value);
      ("target_numeric", Json_util.float_opt_to_json target_numeric);
      ("attainment_pct", Json_util.int_opt_to_json attainment_pct);
      ("task_done_count", `Int task_done_count);
      ("task_count", `Int task_count);
      ("note", `String note);
    ]

let goal_attainment_pct_help =
  "Goal attainment percentage by goal_id. Use \
   masc_goal_attainment_measured to distinguish real 0% from unmeasured."

let goal_attainment_measured_help =
  "Whether goal attainment percentage is currently measured by goal_id \
   (1 = measured, 0 = unmeasured)."

let goal_attainment_to_json (goal : Goal_store.goal) (node : tree_node) =
  let task_count = List.length node.tasks in
  let task_done_count =
    List.length
      (List.filter
         (fun ((task, _) : Masc_domain.task * string) -> task_is_done task)
         node.tasks)
  in
  let task_completion_pct =
    if task_count = 0 then None
    else Some (float_of_int task_done_count /. float_of_int task_count *. 100.0)
  in
  let measured ~basis ~unit ~observed_value ~target_numeric ~target_parse_status =
    let attainment_pct =
      if target_numeric <= 0.0 then
        None
      else
        Some (pct_of_float (observed_value /. target_numeric *. 100.0))
    in
    (* Post-#13131 review: state was derived from the rounded
       [attainment_pct]. For small-but-nonzero progress (e.g.
       1/1000 -> 0.1%), rounding yields 0% and the state collapsed
       to "not_started" even though [observed_value] > 0. Use the
       unrounded observed_value to disambiguate. *)
    let state =
      match attainment_pct with
      | Some pct when pct >= 100 -> "attained"
      | Some 0 when observed_value > 0.0 -> "in_progress"
      | Some 0 -> "not_started"
      | Some _ -> "in_progress"
      | None -> "unmeasured"
    in
    build_attainment_json ~state ~basis ~task_done_count ~task_count
      ~target_parse_status ~unit ~observed_value:(Some observed_value)
      ~target_numeric:(Some target_numeric) ~attainment_pct
      ~note:
        (match unit with
        | Percent -> "Derived from linked task completion against a percent target."
        | Count -> "Derived from completed linked tasks against a count target."
        | Unknown -> "Derived from linked goal evidence.")
      goal
  in
  let unmeasured ?(unit = Unknown) ?target_numeric target_parse_status note =
    build_attainment_json ~state:"unmeasured" ~basis:"unmeasured"
      ~task_done_count ~task_count ~target_parse_status ~unit
      ~observed_value:None ~target_numeric ~attainment_pct:None ~note goal
  in
  match goal.phase with
  | Goal_phase.Completed ->
      build_attainment_json ~state:"attained" ~basis:"goal_phase"
        ~task_done_count ~task_count
        ~target_parse_status:
          (match goal.target_value with
          | Some raw when parse_first_float raw <> None -> "parseable"
          | Some _ -> "unparseable"
          | None -> "absent")
        ~unit:Percent ~observed_value:(Some 100.0) ~target_numeric:(Some 100.0)
        ~attainment_pct:(Some 100)
        ~note:"Goal lifecycle phase is completed." goal
  | _ -> (
      match goal.target_value with
      | Some raw -> (
          match parse_first_float raw with
          | None ->
              unmeasured "unparseable"
                "Target value is not numeric enough for dashboard attainment."
          | Some target_numeric when target_numeric <= 0.0 ->
              unmeasured "invalid_target"
                "Target value must be greater than zero."
          | Some target_numeric -> (
              let unit = parsed_target_unit goal.metric raw in
              match unit with
              | Percent -> (
                  match task_completion_pct with
                  | Some observed_value ->
                      measured ~basis:"metric_target_percent" ~unit
                        ~observed_value ~target_numeric
                        ~target_parse_status:"parseable"
                  | None ->
                      unmeasured ~unit ~target_numeric "no_linked_tasks"
                        "Percent target needs linked task evidence." )
              | Count ->
                  if metric_supports_count_target goal.metric then
                    measured ~basis:"metric_target_count" ~unit
                      ~observed_value:(float_of_int task_done_count)
                      ~target_numeric ~target_parse_status:"parseable"
                  else
                    unmeasured ~unit ~target_numeric "unsupported_metric"
                      "Numeric target is not mapped to a known count metric."
              | Unknown ->
                  unmeasured "unsupported_metric"
                    "Target unit is unknown." ))
      | None -> (
          match task_completion_pct with
          | Some observed_value ->
              measured ~basis:"linked_tasks" ~unit:Percent ~observed_value
                ~target_numeric:100.0 ~target_parse_status:"absent"
          | None ->
              unmeasured "absent"
                "No target value or linked task evidence is available." ))

let assoc_member_opt = Json_util.assoc_member_opt

let assoc_string_opt = Json_util.assoc_string_opt

let assoc_int_opt = Json_util.assoc_int_opt

let goal_completion_to_json (goal : Goal_store.goal) (node : tree_node) ~attainment =
  let task_count = List.length node.tasks in
  let task_done_count =
    List.length
      (List.filter
         (fun ((task, _) : Masc_domain.task * string) -> task_is_done task)
         node.tasks)
  in
  let task_terminal_count =
    List.length
      (List.filter
         (fun ((task, _) : Masc_domain.task * string) -> task_is_terminal task)
         node.tasks)
  in
  let task_open_count = task_count - task_terminal_count in
  let task_completion_pct =
    if task_count = 0 then
      None
    else
      Some (pct_of_float (float_of_int task_done_count /. float_of_int task_count *. 100.0))
  in
  let attainment_pct = assoc_int_opt "attainment_pct" attainment in
  let attainment_state =
    assoc_string_opt "state" attainment |> Option.value ~default:"unmeasured"
  in
  let attainment_basis =
    assoc_string_opt "basis" attainment |> Option.value ~default:"unmeasured"
  in
  let metric_evaluation =
    match assoc_string_opt "metric_evaluation" attainment with
    | Some s -> (
        match metric_evaluation_of_string s with
        | Some m -> m
        | None -> metric_evaluation_of_goal goal )
    | None -> metric_evaluation_of_goal goal
  in
  let pct, pct_source =
    match attainment_pct, task_completion_pct with
    | Some pct, _ -> (Some pct, "attainment")
    | None, Some pct -> (Some pct, "task_summary")
    | None, None -> (None, "none")
  in
  let ready_to_request_completion =
    match goal.phase with
    | Goal_phase.Executing -> true
    | Goal_phase.Blocked | Goal_phase.Paused | Goal_phase.Completed | Goal_phase.Dropped ->
        false
  in
  let state =
    match goal.phase with
    | Goal_phase.Completed -> "completed"
    | Goal_phase.Dropped -> "dropped"
    | Goal_phase.Blocked -> "blocked"
    | Goal_phase.Paused -> "paused"
    | Goal_phase.Executing -> "ready_for_completion"
  in
  let is_terminal =
    match goal.phase with
    | Goal_phase.Completed | Goal_phase.Dropped -> true
    | Goal_phase.Executing | Goal_phase.Blocked | Goal_phase.Paused ->
        false
  in
  `Assoc
    [
      ("state", `String state);
      ("pct", Json_util.int_opt_to_json pct);
      ("pct_source", `String pct_source);
      ("attainment_state", `String attainment_state);
      ("attainment_basis", `String attainment_basis);
      (* task-1743: mirror the attainment metric-evaluation state so a
         consumer reading only the completion summary still learns the
         metric was never evaluated (task-derived pct is not a metric). *)
      ("metric_evaluation", `String (metric_evaluation_to_string metric_evaluation));
      ("task_total", `Int task_count);
      ("task_done", `Int task_done_count);
      ("task_open", `Int task_open_count);
      ("is_complete", `Bool (goal.phase = Goal_phase.Completed));
      ("is_terminal", `Bool is_terminal);
      ("ready_to_request_completion", `Bool ready_to_request_completion);
    ]
