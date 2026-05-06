(** Dashboard Goals — goal tree with explicit task linkage, health badges,
    and goal-first detail evidence. *)

open Yojson.Safe.Util

type tree_node = {
  goal : Goal_store.goal;
  children : tree_node list;
  tasks : (Masc_domain.task * string) list;
  convergence : float;  (** 0.0 .. 1.0 completion ratio *)
  health : string;
  badges : string list;
  last_activity_at : string;
  stagnation_seconds : int;
  linked_keeper_names : string list;
  pending_approval_count : int;
  infra_risk_count : int;
  linkage_source : string;
  linkage_warning_count : int;
  status_reason : string;
  blocking_source : string;
  blocking_reason : string;
  latest_keeper_ref : string option;
  latest_turn_ref : int option;
  stalled_since : string option;
  activity_observation : string;
  stagnation_status : string;
}

type goal_detail_keeper = {
  meta : Keeper_types.keeper_meta;
  latest_receipt : Yojson.Safe.t option;
  runtime_trust : Yojson.Safe.t;
}

type attainment_unit =
  | Percent
  | Count
  | Unknown

let task_is_linked_to_goal (task : Masc_domain.task) goal_id =
  Convergence.task_matches_goal ~goal_id task

let task_linkage_source_opt (task : Masc_domain.task) goal_id =
  match task.goal_id with
  | Some task_goal_id when String.equal task_goal_id goal_id -> Some "explicit"
  | Some _ -> None
  | None ->
      if task_is_linked_to_goal task goal_id then Some "title_tag" else None

let task_assignee (task : Masc_domain.task) : string option =
  Masc_domain.task_assignee_of_status task.task_status

let task_status_label (task : Masc_domain.task) : string =
  match task.task_status with
  | Masc_domain.Todo -> "pending"
  | Masc_domain.Claimed _ -> "claimed"
  | Masc_domain.InProgress _ -> "in_progress"
  | Masc_domain.AwaitingVerification _ -> "awaiting_verification"
  | Masc_domain.Done _ -> "completed"
  | Masc_domain.Cancelled _ -> "cancelled"

let task_is_terminal (task : Masc_domain.task) : bool =
  Masc_domain.task_status_is_terminal task.task_status

let task_is_done (task : Masc_domain.task) : bool =
  Masc_domain.task_status_is_done task.task_status

let task_updated_at (task : Masc_domain.task) : string =
  match task.task_status with
  | Masc_domain.Done { completed_at; _ } -> completed_at
  | Masc_domain.Cancelled { cancelled_at; _ } -> cancelled_at
  | Masc_domain.InProgress { started_at; _ } -> started_at
  | Masc_domain.AwaitingVerification { submitted_at; _ } -> submitted_at
  | Masc_domain.Claimed { claimed_at; _ } -> claimed_at
  | Masc_domain.Todo -> task.created_at

let dedupe_sort values =
  values |> List.sort_uniq String.compare

let link_source_of_values values =
  let normalized =
    values
    |> List.filter (fun value -> value <> "" && not (String.equal value "none"))
    |> dedupe_sort
  in
  match normalized with
  | [] -> "none"
  | [ source ] -> source
  | _ -> "mixed"

let receipt_error_kind json =
  match json |> member "error" with
  | `Assoc _ as error -> error |> member "kind" |> to_string_option
  | _ -> None

let receipt_error_message json =
  match json |> member "error" with
  | `Assoc _ as error -> error |> member "message" |> to_string_option
  | _ -> None

let receipt_sandbox_kind json =
  json |> member "sandbox" |> member "kind" |> to_string_option

let receipt_approval_profile json =
  json |> member "approval" |> member "profile" |> to_string_option

let receipt_cascade_name json =
  json |> member "cascade" |> member "name" |> to_string_option

let receipt_cascade_outcome json =
  json |> member "cascade" |> member "outcome" |> to_string_option

let receipt_cascade_fallback_applied json =
  json |> member "cascade" |> member "fallback_applied" |> to_bool_option
  |> Option.value ~default:false

let receipt_outcome json =
  json |> member "outcome" |> to_string_option

let receipt_started_at json =
  json |> member "started_at" |> to_string_option

let receipt_ended_at json =
  json |> member "ended_at" |> to_string_option

let receipt_turn_count json =
  json |> member "turn_count" |> to_int_option

let trust_disposition json =
  json |> member "disposition" |> to_string_option

let trust_disposition_reason json =
  json |> member "disposition_reason" |> to_string_option

let trust_attention_reason json =
  json |> member "attention_reason" |> to_string_option

let trust_needs_attention json =
  json |> member "needs_attention" |> to_bool_option
  |> Option.value ~default:false

let trust_snapshot_unavailable json =
  String.equal
    (json |> member "disposition_reason" |> to_string_option
     |> Option.value ~default:"")
    "runtime_trust_snapshot_unavailable"

let trust_turn_id json =
  json |> member "turn_id" |> to_int_option

let trust_latest_event json =
  match json |> member "latest_causal_event" with
  | `Assoc _ as event -> Some event
  | _ -> None

let trust_latest_event_ts json =
  Option.bind (trust_latest_event json) (fun event ->
      event |> member "ts" |> to_string_option )

let trust_latest_event_ts_unix json =
  Option.bind (trust_latest_event json) (fun event ->
      event |> member "ts_unix" |> to_float_option )

let trust_sandbox_risk json =
  String.equal
    (json |> member "disposition_reason" |> to_string_option
     |> Option.value ~default:"")
    "sandbox_violation"

let trust_cascade_risk json =
  String.equal
    (json |> member "disposition_reason" |> to_string_option
     |> Option.value ~default:"")
    "cascade_exhausted"

let receipt_has_error json =
  match receipt_error_kind json with
  | Some _ -> true
  | None ->
      (match receipt_outcome json with
       | Some "completed" | Some "success" | Some "not_observed" | None -> false
       | Some _ -> false)

let receipt_has_sandbox_risk json =
  match receipt_sandbox_kind json with
  | Some "local" -> false
  | Some "docker" -> false
  | Some _ | None -> false

let receipt_has_cascade_risk json =
  receipt_cascade_fallback_applied json
  ||
  match receipt_cascade_outcome json with
  | Some "passed_to_next_model" -> true
  | _ -> false

let iso_max left right =
  if String.compare left right >= 0 then left else right

let latest_iso ?fallback values =
  match values with
  | [] -> fallback
  | first :: rest ->
      Some (List.fold_left iso_max first rest)

let stagnation_threshold_seconds = function
  | Goal_store.Short -> 6 * 3600
  | Goal_store.Mid -> 24 * 3600
  | Goal_store.Long -> 72 * 3600

let human_duration seconds =
  if seconds < 3600 then Printf.sprintf "%dm" (seconds / 60)
  else if seconds < 86400 then Printf.sprintf "%dh" (seconds / 3600)
  else Printf.sprintf "%dd" (seconds / 86400)

let compute_convergence (goal : Goal_store.goal) linked_tasks children =
  let goal_done_weight =
    match goal.phase with
    | Goal_phase.Completed -> 1.0
    | Goal_phase.Executing
    | Goal_phase.Awaiting_verification
    | Goal_phase.Awaiting_approval
    | Goal_phase.Blocked
    | Goal_phase.Paused
    | Goal_phase.Dropped ->
        0.0
  in
  let task_count = List.length linked_tasks in
  let done_count =
    List.length
      (List.filter
         (fun ((task, _) : Masc_domain.task * string) -> task_is_done task)
         linked_tasks)
  in
  let task_ratio =
    if task_count = 0 then goal_done_weight
    else float_of_int done_count /. float_of_int task_count
  in
  let child_ratios =
    List.map (fun (child : tree_node) -> child.convergence) children
  in
  let child_avg =
    match child_ratios with
    | [] -> task_ratio
    | rs ->
        let sum = List.fold_left ( +. ) 0.0 rs in
        sum /. float_of_int (List.length rs)
  in
  if task_count > 0 && children <> [] then
    (task_ratio +. child_avg) /. 2.0
  else if children <> [] then
    child_avg
  else
    task_ratio

let clamp_float lower upper value =
  if value < lower then lower else if value > upper then upper else value

let pct_of_float value =
  int_of_float (floor (clamp_float 0.0 100.0 value +. 0.5))

let json_float_opt = function
  | Some value -> `Float value
  | None -> `Null

let json_int_opt = function
  | Some value -> `Int value
  | None -> `Null

let attainment_unit_to_string = function
  | Percent -> "percent"
  | Count -> "count"
  | Unknown -> "unknown"

let contains_ci haystack needle =
  String_util.contains_substring_ci haystack needle

(* Token-split that respects camelCase AND acronym boundaries.

   - lower → upper splits (so [successRate] → [success; rate])
   - upper → upper-followed-by-lower splits (so [APIRatio] →
     [api; ratio]; [PRCount] → [pr; count])
   - consecutive uppercase letters not followed by a lowercase stay
     glued (so [API] → [api], [HTTP] → [http])

   Without the acronym rule, common acronym-prefixed metric names
   regressed against percent inference: post-#13170 review noted
   that names like [APIRatio] / [PRCount] still missed the percent
   token even after the camelCase fix.  The split point is the
   *last* uppercase letter in a run — that is the start of the
   following lowercase word — not every uppercase letter, so
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
        (* Split before this uppercase letter when:
           1. Previous char was lowercase (camelCase: aA boundary)
           2. Previous char was uppercase AND next char is lowercase
              (acronym→word: end-of-acronym boundary, e.g. APIRatio
              splits between [I] and [R]) *)
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
   "iterate", "operation"-vs-"ratio".  Match against tokenized words
   (alphanumerics split on punctuation) so only the actual metric
   nouns trigger the percent inference.  The literal [%] symbol stays
   on the substring path because it cannot occur as part of an
   unrelated word. *)
let metric_word_implies_percent token =
  match token with
  | "percent" | "pct" | "ratio" | "rate" | "completion" -> true
  | _ -> false

let metric_implies_percent metric =
  match metric with
  | None -> false
  | Some raw ->
      contains_ci raw "%"
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
  contains_ci raw "%"
  || contains_ci raw "percent"
  || contains_ci raw "pct"

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
      (* Post-#13131 review: [float_of_string_opt] accepts "nan"/"inf"
         and yields non-finite floats, which propagate into
         [pct_of_float] where [int_of_float (floor nan)] is undefined
         and crashes JSON projection.  Reject non-finite parses and
         keep scanning for a finite token. *)
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
      ("target_value", Json_util.string_opt_to_json goal.target_value);
      ("target_parse_status", `String target_parse_status);
      ("unit", `String (attainment_unit_to_string unit));
      ("observed_value", json_float_opt observed_value);
      ("target_numeric", json_float_opt target_numeric);
      ("attainment_pct", json_int_opt attainment_pct);
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

let observe_goal_attainment_metrics (goal : Goal_store.goal) attainment =
  let labels = [ ("goal_id", goal.id) ] in
  let measured, pct =
    match attainment |> member "attainment_pct" |> to_int_option with
    | Some pct -> (1.0, float_of_int pct)
    | None -> (0.0, 0.0)
  in
  Prometheus.register_gauge ~name:Prometheus.metric_goal_attainment_pct
    ~help:goal_attainment_pct_help ~labels ();
  Prometheus.set_gauge Prometheus.metric_goal_attainment_pct ~labels pct;
  Prometheus.register_gauge ~name:Prometheus.metric_goal_attainment_measured
    ~help:goal_attainment_measured_help ~labels ();
  Prometheus.set_gauge Prometheus.metric_goal_attainment_measured ~labels
    measured

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
       [attainment_pct].  For small-but-nonzero progress (e.g.
       1/1000 → 0.1%), rounding yields 0% and the state collapsed
       to "not_started" even though [observed_value] > 0.  Use the
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

let approval_matches_goal goal_id approval_json =
  let goal_ids =
    approval_json |> member "goal_ids" |> to_list
    |> List.filter_map to_string_option
  in
  List.mem goal_id goal_ids
  ||
  match approval_json |> member "goal_id" |> to_string_option with
  | Some pending_goal_id -> String.equal pending_goal_id goal_id
  | None -> false

let keeper_name_matches_meta metas name =
  List.exists (fun (meta : Keeper_types.keeper_meta) -> String.equal meta.name name) metas

let keeper_name_of_assignee metas assignee =
  match Keeper_types.canonical_keeper_name_from_agent_name assignee with
  | Some keeper_name -> Some keeper_name
  | None ->
      if keeper_name_matches_meta metas assignee then Some assignee
      else None

let goal_phase_to_health = function
  | Goal_phase.Completed -> Some "done"
  | Goal_phase.Paused -> Some "paused"
  | Goal_phase.Blocked | Goal_phase.Dropped -> Some "blocked"
  | Goal_phase.Executing
  | Goal_phase.Awaiting_verification
  | Goal_phase.Awaiting_approval ->
      None

let goal_health_reason ~goal_phase ~blocked_by_receipt ~child_blocked
    ~pending_approvals ~sandbox_risk ~cascade_risk ~fsm_risk ~stalled
    ~stagnation_seconds ~child_at_risk ~linkage_warning_reason
    ~activity_observation ~stagnation_status =
  match goal_phase_to_health goal_phase with
  | Some "done" -> "Goal phase is completed."
  | Some "paused" -> "Goal phase is paused."
  | Some "blocked" -> (
      match goal_phase with
      | Goal_phase.Blocked -> "Goal phase is blocked."
      | Goal_phase.Dropped -> "Goal phase is dropped."
      | Goal_phase.Completed | Goal_phase.Paused | Goal_phase.Executing
      | Goal_phase.Awaiting_verification | Goal_phase.Awaiting_approval ->
          "Goal is blocked.")
  | Some _ | None ->
      if blocked_by_receipt then "Recent keeper execution ended with an error."
      else if child_blocked then "A linked sub-goal is blocked."
      else if pending_approvals > 0 then
        Printf.sprintf "%d approval request(s) are still pending."
          pending_approvals
      else if sandbox_risk then
        "Linked keeper is constrained by the current sandbox or scope."
      else if cascade_risk then
        "Latest keeper run fell back within the configured cascade."
      else if fsm_risk then
        "Linked task is waiting on FSM verification or remediation."
      else if Option.is_some linkage_warning_reason then
        (match linkage_warning_reason with
         | Some "no_linked_tasks" ->
             "Goal has no linked tasks, child goals, or assigned keepers."
         | Some "no_open_work" ->
             "Linked tasks are terminal but none completed successfully."
         | Some "unstaffed" ->
             "Linked tasks exist, but no keeper is assigned or linked."
         | Some reason -> reason
         | None -> "Goal linkage needs attention.")
      else if stalled then
        Printf.sprintf "No linked activity for %s."
          (human_duration stagnation_seconds)
      else if String.equal stagnation_status "unobserved" then
        Printf.sprintf
          "Goal FSM is %s; activity freshness is based only on %s, so stalled is not asserted."
          (Goal_phase.to_string goal_phase) activity_observation
      else if child_at_risk then
        "A linked sub-goal is at risk."
      else
        "Linked tasks and keepers are progressing."

let tree_health ~goal_phase ~blocked_by_receipt ~child_blocked ~at_risk =
  match goal_phase_to_health goal_phase with
  | Some health -> health
  | None ->
      if blocked_by_receipt || child_blocked then "blocked"
      else if at_risk then "at_risk"
      else "on_track"

let tree_badges ~pending_approvals ~sandbox_risk ~cascade_risk ~fsm_risk ~stalled
    ~activity_unobserved =
  let badges = ref [] in
  if pending_approvals > 0 then badges := "awaiting_approval" :: !badges;
  if sandbox_risk then badges := "sandbox" :: !badges;
  if cascade_risk then badges := "cascade" :: !badges;
  if fsm_risk then badges := "task_verification_pending" :: !badges;
  if stalled then badges := "stalled" :: !badges;
  if activity_unobserved then badges := "activity_unobserved" :: !badges;
  List.rev !badges

let goal_fsm_state_kind = function
  | Goal_phase.Executing -> "executing"
  | Goal_phase.Awaiting_verification -> "verification_gate"
  | Goal_phase.Awaiting_approval -> "approval_gate"
  | Goal_phase.Blocked -> "blocked"
  | Goal_phase.Paused -> "paused"
  | Goal_phase.Completed -> "completed"
  | Goal_phase.Dropped -> "dropped"

let goal_fsm_next_actions ~goal_phase ~has_effective_verifier_policy
    ~require_completion_approval =
  [
    Goal_phase.Request_complete;
    Goal_phase.Approve_completion;
    Goal_phase.Reject_completion;
    Goal_phase.Pause;
    Goal_phase.Resume;
    Goal_phase.Operator_block;
    Goal_phase.Operator_unblock;
    Goal_phase.Drop;
    Goal_phase.Reopen;
  ]
  |> List.filter (fun action ->
         match
           Goal_phase.decide_transition ~phase:goal_phase ~action
             ~has_effective_verifier_policy ~require_completion_approval
         with
         | Ok _ -> true
         | Error _ -> false)
  |> List.map Goal_phase.action_to_string

let goal_fsm_to_json ~effective_policy (goal : Goal_store.goal)
    (node : tree_node) =
  `Assoc
    [
      ("state", Goal_phase.to_yojson goal.phase);
      ("source", `String "goal.phase");
      ("state_kind", `String (goal_fsm_state_kind goal.phase));
      ( "next_actions",
        `List
          (goal_fsm_next_actions ~goal_phase:goal.phase
             ~has_effective_verifier_policy:(Option.is_some effective_policy)
             ~require_completion_approval:goal.require_completion_approval
          |> List.map (fun action -> `String action)) );
      ("activity_observation", `String node.activity_observation);
      ("stagnation_status", `String node.stagnation_status);
    ]

type build_context = {
  now_ts : float;
  all_tasks : Masc_domain.task list;
  pending_approvals : Yojson.Safe.t list;
  keeper_metas : Keeper_types.keeper_meta list;
  latest_receipts : (string * Yojson.Safe.t) list;
  latest_runtime_trusts : (string * Yojson.Safe.t) list;
}

let keeper_runtime_trust_snapshot_json ~config ~(meta : Keeper_types.keeper_meta) =
  try Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta with
  | exn ->
      let error = Printexc.to_string exn in
      `Assoc
        [
          ("disposition", `String "Pause");
          ("disposition_reason", `String "runtime_trust_snapshot_unavailable");
          ("needs_attention", `Bool true);
          ("attention_reason", `String "runtime_trust_snapshot_unavailable");
          ("next_human_action", `String "inspect_keeper_runtime_trust");
          ("snapshot_error", `String error);
          ("latest_causal_event", `Null);
          ("causal_timeline", `List []);
        ]

let display_disposition_of_receipt_json receipt =
  let operator_disposition =
    receipt |> member "operator_disposition" |> to_string_option
    |> Option.value ~default:"unknown"
  in
  let operator_disposition_reason =
    receipt |> member "operator_disposition_reason" |> to_string_option
    |> Option.value ~default:""
  in
  let reason fallback =
    match String.trim operator_disposition_reason with
    | "" -> fallback
    | value -> value
  in
  match String.lowercase_ascii operator_disposition with
  | "pass" -> ("Pass", "healthy", operator_disposition, operator_disposition_reason)
  | "skipped" ->
      ("Pass", "phase_skipped", operator_disposition, operator_disposition_reason)
  | "pass_next_model" ->
      ("Pass", "cascade_fallback", operator_disposition, operator_disposition_reason)
  | "pause_human" ->
      ( "Pause",
        reason "needs_human_attention",
        operator_disposition,
        operator_disposition_reason )
  | "fail_open_next_cascade" ->
      ("Pause", reason "degraded_retry", operator_disposition, operator_disposition_reason)
  | "user_cancelled" ->
      ("Pause", reason "cancelled", operator_disposition, operator_disposition_reason)
  | "alert_exhausted" ->
      ("Alert", reason "cascade_exhausted", operator_disposition, operator_disposition_reason)
  | "unknown" ->
      ( "Alert",
        reason "unmapped_cascade_state",
        operator_disposition,
        operator_disposition_reason )
  | _ ->
      ( "Alert",
        reason "unmapped_operator_disposition",
        operator_disposition,
        operator_disposition_reason )

let runtime_blocker_event_from_meta ~config ~(meta : Keeper_types.keeper_meta) =
  let runtime_blocker_fields =
    Keeper_status_bridge.runtime_blocker_fields_json config meta
  in
  let assoc_string_opt name =
    match List.assoc_opt name runtime_blocker_fields with
    | Some json -> to_string_option json
    | None -> None
  in
  let blocker_class = assoc_string_opt "runtime_blocker_class" in
  let blocker_summary = assoc_string_opt "runtime_blocker_summary" in
  let summary =
    match blocker_summary, blocker_class with
    | Some value, _ when String.trim value <> "" -> Some value
    | _, Some value when String.trim value <> "" -> Some value
    | _ -> None
  in
  match summary with
  | None -> None
  | Some summary ->
      let now_ts = Time_compat.now () in
      let now_iso = Masc_domain.now_iso () in
      Some
        (`Assoc
          [
            ("kind", `String "runtime_blocker");
            ("ts", `String now_iso);
            ("ts_unix", `Float now_ts);
            ("observed_at", `String now_iso);
            ("observed_at_unix", `Float now_ts);
            ("observation_only", `Bool true);
            ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
            ("keeper_turn_id", `Null);
            ("task_id", `Null);
            ( "goal_ids",
              `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids)
            );
            ("title", `String "Runtime Blocker");
            ("summary", `String summary);
            ( "severity",
              `String
                (match blocker_class with
                 | Some "cascade_exhausted"
                 | Some "completion_contract_violation" ->
                     "bad"
                 | _ -> "warn") );
            ("next_human_action", `String "inspect_runtime_blocker");
          ])

let runtime_trust_from_receipt_fallback ~config ~(meta : Keeper_types.keeper_meta)
    receipt =
  let disposition, disposition_reason, operator_disposition,
      operator_disposition_reason =
    display_disposition_of_receipt_json receipt
  in
  let ts =
    receipt_ended_at receipt
    |> Option.value ~default:meta.updated_at
  in
  let turn_id = receipt_turn_count receipt in
  let severity =
    match disposition with
    | "Pass" -> "ok"
    | "Pause" -> "warn"
    | _ -> "bad"
  in
  let latest_event =
    `Assoc
      [
        ("kind", `String "execution_receipt");
        ("ts", `String ts);
        ("keeper_turn_id", Json_util.int_opt_to_json turn_id);
        ("goal_ids", `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids));
        ("title", `String "Keeper Execution Receipt");
        ("summary", `String disposition_reason);
        ("severity", `String severity);
      ]
  in
  let runtime_blocker_fields =
    Keeper_status_bridge.runtime_blocker_fields_json config meta
  in
  let causal_timeline =
    let blocker_events =
      runtime_blocker_event_from_meta ~config ~meta
      |> Option.map (fun event -> [ event ])
      |> Option.value ~default:[]
    in
    `List (latest_event :: blocker_events)
  in
  `Assoc
    [
      ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
      ("generation", `Int meta.runtime.generation);
      ("turn_id", Json_util.int_opt_to_json turn_id);
      ("phase", `Null);
      ("raw_phase", `Null);
      ("goal_ids", `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids));
      ("disposition", `String disposition);
      ("disposition_reason", `String disposition_reason);
      ("operator_disposition", `String operator_disposition);
      ("operator_disposition_reason", `String operator_disposition_reason);
      ("needs_attention", `Bool (not (String.equal disposition "Pass")));
      ("attention_reason", `Null);
      ("next_human_action", `Null);
      ( "approval",
        `Assoc
          [
            ("state", `String "idle");
            ("summary", `String "idle");
            ("pending_count", `Int 0);
          ] );
      ( "execution_summary",
        `Assoc
          [
            ( "tool_contract_result",
              receipt |> member "tool_contract_result" );
            ("latest_receipt_at", `String ts);
          ] );
      ("runtime_blockers", `Assoc runtime_blocker_fields);
      ("latest_causal_event", latest_event);
      ("causal_timeline", causal_timeline);
      ("latest_receipt", receipt);
    ]

let rec build_tree context goals goal =
  let child_goals =
    List.filter
      (fun (candidate : Goal_store.goal) ->
        candidate.parent_goal_id = Some goal.Goal_store.id)
      goals
  in
  let children = List.map (build_tree context goals) child_goals in
  let linked_tasks =
    context.all_tasks
    |> List.filter_map (fun task ->
           task_linkage_source_opt task goal.Goal_store.id
           |> Option.map (fun source -> (task, source)))
  in
  let direct_linkage_source =
    linked_tasks |> List.map snd |> link_source_of_values
  in
  let direct_pending_approvals =
    context.pending_approvals
    |> List.filter (approval_matches_goal goal.Goal_store.id)
  in
  let direct_task_keeper_names =
    linked_tasks
    |> List.filter_map (fun ((task, _) : Masc_domain.task * string) ->
           match task_assignee task with
           | Some assignee ->
               keeper_name_of_assignee context.keeper_metas assignee
           | None -> None)
  in
  let direct_goal_keeper_names =
    context.keeper_metas
    |> List.filter (fun (meta : Keeper_types.keeper_meta) ->
           List.mem goal.Goal_store.id meta.active_goal_ids)
    |> List.map (fun (meta : Keeper_types.keeper_meta) -> meta.name)
  in
  let direct_linked_keeper_names =
    dedupe_sort (direct_task_keeper_names @ direct_goal_keeper_names)
  in
  let direct_receipt_refs =
    direct_linked_keeper_names
    |> List.filter_map (fun keeper_name ->
           List.assoc_opt keeper_name context.latest_receipts
           |> Option.map (fun receipt -> (keeper_name, receipt)))
  in
  let direct_receipts =
    direct_receipt_refs |> List.map snd
  in
  let direct_runtime_trusts =
    direct_linked_keeper_names
    |> List.filter_map (fun keeper_name ->
           List.assoc_opt keeper_name context.latest_runtime_trusts
           |> Option.map (fun trust -> (keeper_name, trust)))
  in
  let child_blocked =
    List.exists (fun (child : tree_node) -> String.equal child.health "blocked")
      children
  in
  let child_at_risk =
    List.exists
      (fun (child : tree_node) ->
        String.equal child.health "at_risk"
        || String.equal child.health "blocked")
      children
  in
  let task_activity_values =
    linked_tasks
    |> List.map (fun ((task, _) : Masc_domain.task * string) -> task_updated_at task)
  in
  let approval_activity_values =
    direct_pending_approvals
    |> List.filter_map (fun json ->
           json |> member "requested_at_iso" |> to_string_option)
  in
  let receipt_activity_values =
    direct_receipts |> List.filter_map receipt_ended_at
  in
  let runtime_activity_values =
    direct_runtime_trusts
    |> List.filter_map (fun (_, trust) -> trust_latest_event_ts trust)
  in
  let direct_observed_activity_values =
    task_activity_values @ approval_activity_values @ receipt_activity_values
    @ runtime_activity_values
  in
  let direct_last_activity_values =
    goal.Goal_store.updated_at :: direct_observed_activity_values
  in
  let child_observed_activity_values =
    children
    |> List.filter_map (fun child ->
           if String.equal child.activity_observation "goal_metadata" then None
           else Some child.last_activity_at)
  in
  let child_last_activity_values =
    children |> List.map (fun child -> child.last_activity_at)
  in
  let last_activity_at =
    latest_iso
      ~fallback:goal.Goal_store.updated_at
      (direct_last_activity_values @ child_last_activity_values)
    |> Option.value ~default:goal.Goal_store.updated_at
  in
  let stagnation_seconds =
    int_of_float
      (max 0.0
         (context.now_ts
          -. Masc_domain.parse_iso8601 ~default_time:context.now_ts last_activity_at))
  in
  let direct_sandbox_risk =
    List.exists receipt_has_sandbox_risk direct_receipts
    || List.exists (fun (_, trust) -> trust_sandbox_risk trust) direct_runtime_trusts
  in
  let direct_cascade_risk =
    List.exists receipt_has_cascade_risk direct_receipts
    || List.exists (fun (_, trust) -> trust_cascade_risk trust) direct_runtime_trusts
  in
  let blocked_by_receipt =
    List.exists receipt_has_error direct_receipts
  in
  let direct_runtime_blocking_reason =
    direct_runtime_trusts
    |> List.find_map (fun (_keeper_name, trust) ->
           if trust_snapshot_unavailable trust && direct_receipts <> [] then
             None
           else
             match trust_disposition trust with
             | Some "Alert" ->
                 (match trust_attention_reason trust with
                  | Some _ as reason -> reason
                  | None -> trust_disposition_reason trust)
             | Some "Pause" when trust_needs_attention trust ->
                 (match trust_attention_reason trust with
                  | Some _ as reason -> reason
                  | None -> trust_disposition_reason trust)
             | _ -> None)
  in
  let direct_fsm_risk =
    List.exists
      (fun ((task, _) : Masc_domain.task * string) ->
        match task.task_status with
        | Masc_domain.AwaitingVerification _ -> true
        | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _ | Masc_domain.Done _
        | Masc_domain.Cancelled _ ->
            false)
      linked_tasks
  in
  let open_linked_task_count =
    linked_tasks
    |> List.filter (fun ((task, _) : Masc_domain.task * string) ->
           not (task_is_terminal task))
    |> List.length
  in
  let done_linked_task_count =
    linked_tasks
    |> List.filter (fun ((task, _) : Masc_domain.task * string) -> task_is_done task)
    |> List.length
  in
  let linkage_warning_reason =
    match goal.Goal_store.phase with
    | Goal_phase.Executing
    | Goal_phase.Awaiting_verification
    | Goal_phase.Awaiting_approval ->
        if linked_tasks = [] && children = [] && direct_linked_keeper_names = [] then
          Some "no_linked_tasks"
        else if linked_tasks <> [] && open_linked_task_count = 0
                && done_linked_task_count = 0 then
          Some "no_open_work"
        else if open_linked_task_count > 0 && direct_linked_keeper_names = [] then
          Some "unstaffed"
        else
          None
    | Goal_phase.Completed | Goal_phase.Blocked | Goal_phase.Paused
    | Goal_phase.Dropped ->
        None
  in
  let activity_observation =
    if runtime_activity_values <> [] || receipt_activity_values <> [] then
      "runtime"
    else if approval_activity_values <> [] then
      "approval"
    else if task_activity_values <> [] then
      "task"
    else if child_observed_activity_values <> [] then
      "child"
    else
      "goal_metadata"
  in
  let stale_by_threshold =
    stagnation_seconds >= stagnation_threshold_seconds goal.Goal_store.horizon
  in
  let observed_for_stagnation =
    not (String.equal activity_observation "goal_metadata")
  in
  let stalled = stale_by_threshold && observed_for_stagnation in
  let stagnation_status =
    if stalled then "stalled"
    else if stale_by_threshold then "unobserved"
    else "recent"
  in
  let direct_badges =
    tree_badges ~pending_approvals:(List.length direct_pending_approvals)
      ~sandbox_risk:direct_sandbox_risk ~cascade_risk:direct_cascade_risk
      ~fsm_risk:direct_fsm_risk ~stalled
      ~activity_unobserved:(String.equal stagnation_status "unobserved")
  in
  let direct_badges =
    match linkage_warning_reason with
    | Some reason -> reason :: direct_badges
    | None -> direct_badges
  in
  let badges =
    dedupe_sort
      (direct_badges
       @ List.concat_map (fun (child : tree_node) -> child.badges) children)
  in
  let pending_approval_count =
    List.length direct_pending_approvals
    + List.fold_left
        (fun acc (child : tree_node) -> acc + child.pending_approval_count)
        0 children
  in
  let direct_infra_risk_count =
    List.length
      (List.filter
         (fun json ->
           receipt_has_error json || receipt_has_sandbox_risk json
           || receipt_has_cascade_risk json)
         direct_receipts)
    + List.length
        (List.filter
           (fun (_, trust) ->
             if trust_snapshot_unavailable trust && direct_receipts <> [] then
               false
             else
               match trust_disposition trust with
               | Some "Alert" -> true
               | Some "Pause" -> trust_needs_attention trust
               | _ -> false)
           direct_runtime_trusts)
  in
  let infra_risk_count =
    direct_infra_risk_count
    + List.fold_left
        (fun acc (child : tree_node) -> acc + child.infra_risk_count)
        0 children
  in
  let linked_keeper_names =
    dedupe_sort
      (direct_linked_keeper_names
       @ List.concat_map
           (fun (child : tree_node) -> child.linked_keeper_names)
           children)
  in
  let linkage_source =
    link_source_of_values
      (direct_linkage_source
       :: List.map (fun (child : tree_node) -> child.linkage_source) children)
  in
  let linkage_warning_count =
    (if Option.is_some linkage_warning_reason then 1 else 0)
    + List.fold_left
        (fun acc (child : tree_node) -> acc + child.linkage_warning_count)
        0 children
  in
  let at_risk =
    pending_approval_count > 0
    || infra_risk_count > 0
    || Option.is_some direct_runtime_blocking_reason
    || direct_fsm_risk
    || Option.is_some linkage_warning_reason
    || stalled
    || child_at_risk
  in
  let health =
    tree_health ~goal_phase:goal.Goal_store.phase ~blocked_by_receipt
      ~child_blocked ~at_risk
  in
  let status_reason =
    goal_health_reason ~goal_phase:goal.Goal_store.phase ~blocked_by_receipt
      ~child_blocked ~pending_approvals:pending_approval_count
      ~sandbox_risk:direct_sandbox_risk ~cascade_risk:direct_cascade_risk
      ~fsm_risk:direct_fsm_risk ~stalled
      ~stagnation_seconds ~child_at_risk ~linkage_warning_reason
      ~activity_observation ~stagnation_status
  in
  let blocking_source, blocking_reason =
    match goal.Goal_store.phase with
    | Goal_phase.Blocked | Goal_phase.Dropped ->
        ("goal_phase", status_reason)
    | Goal_phase.Completed | Goal_phase.Paused | Goal_phase.Executing
    | Goal_phase.Awaiting_verification | Goal_phase.Awaiting_approval ->
        if child_blocked then
          ("child_goal", "A linked sub-goal is blocked.")
        else if pending_approval_count > 0 then
          ("approval", status_reason)
        else if Option.is_some direct_runtime_blocking_reason then
          ( "keeper_runtime",
            Option.value direct_runtime_blocking_reason ~default:status_reason )
        else if direct_fsm_risk then
          ("task_fsm", status_reason)
        else if Option.is_some linkage_warning_reason then
          ("goal_linkage", status_reason)
        else if stalled then
          ("stalled", status_reason)
        else
          ("none", status_reason)
  in
  let latest_receipt_ref =
    direct_receipt_refs
    |> List.sort (fun (_, left) (_, right) ->
           String.compare
             (Option.value ~default:"" (receipt_ended_at right))
             (Option.value ~default:"" (receipt_ended_at left)))
    |> function
    | (keeper_name, receipt) :: _ -> (Some keeper_name, receipt_turn_count receipt)
    | [] -> (None, None)
  in
  let latest_runtime_ref =
    direct_runtime_trusts
    |> List.filter (fun (_, trust) ->
           Option.is_some (trust_latest_event_ts_unix trust))
    |> List.sort (fun (_, left) (_, right) ->
           Float.compare
             (Option.value ~default:0.0 (trust_latest_event_ts_unix right))
             (Option.value ~default:0.0 (trust_latest_event_ts_unix left)))
    |> function
    | (keeper_name, trust) :: _ -> Some (Some keeper_name, trust_turn_id trust)
    | [] -> None
  in
  let latest_linked_keeper_ref =
    match direct_linked_keeper_names with
    | keeper_name :: _ -> (Some keeper_name, None)
    | [] -> (None, None)
  in
  let latest_keeper_ref, latest_turn_ref =
    match latest_runtime_ref with
    | Some latest -> latest
    | None -> (
        match latest_receipt_ref with
        | Some _, _ -> latest_receipt_ref
        | None, _ -> latest_linked_keeper_ref)
  in
  let stalled_since =
    if stalled then Some last_activity_at else None
  in
  let convergence = compute_convergence goal linked_tasks children in
  {
    goal;
    children;
    tasks = linked_tasks;
    convergence;
    health;
    badges;
    last_activity_at;
    stagnation_seconds;
    linked_keeper_names;
    pending_approval_count;
    infra_risk_count;
    linkage_source;
    linkage_warning_count;
    status_reason;
    blocking_source;
    blocking_reason;
    latest_keeper_ref;
    latest_turn_ref;
    stalled_since;
    activity_observation;
    stagnation_status;
  }

let build_forest ~(config : Coord.config) ~goals ~tasks =
  let goal_ids = List.map (fun (goal : Goal_store.goal) -> goal.id) goals in
  let is_root (goal : Goal_store.goal) =
    match goal.parent_goal_id with
    | None -> true
    | Some parent_id -> not (List.mem parent_id goal_ids)
  in
  let keeper_metas =
    Keeper_types.keeper_names config
    |> List.filter_map (fun keeper_name ->
           match Keeper_types.read_meta config keeper_name with
           | Ok (Some meta) -> Some meta
           | Ok None | Error _ -> None)
  in
  let pending_approvals =
    match Keeper_approval_queue.list_pending_dashboard_json () with
    | `List items -> items
    | _ -> []
  in
  let latest_receipts =
    keeper_metas
    |> List.map (fun (meta : Keeper_types.keeper_meta) -> meta.name)
    |> Keeper_execution_receipt.latest_json_by_keeper config
  in
  let context =
    {
      now_ts = Time_compat.now ();
      all_tasks = tasks;
      pending_approvals;
      keeper_metas;
      latest_receipts;
      latest_runtime_trusts =
        keeper_metas
        |> List.map (fun (meta : Keeper_types.keeper_meta) ->
               ( meta.name,
                 keeper_runtime_trust_snapshot_json ~config ~meta ));
    }
  in
  goals
  |> List.filter is_root
  |> List.map (build_tree context goals)

let goal_status_color = function
  | Goal_store.Active -> "#4ade80"
  | Goal_store.Paused -> "#f59e0b"
  | Goal_store.Done -> "#60a5fa"
  | Goal_store.Dropped -> "#6b7280"

let goal_phase_color = function
  | Goal_phase.Executing -> "#4ade80"
  | Goal_phase.Awaiting_verification -> "#f59e0b"
  | Goal_phase.Awaiting_approval -> "#fb7185"
  | Goal_phase.Blocked -> "#ef4444"
  | Goal_phase.Paused -> "#94a3b8"
  | Goal_phase.Completed -> "#60a5fa"
  | Goal_phase.Dropped -> "#6b7280"

let goal_health_color = function
  | "done" -> "#60a5fa"
  | "paused" -> "#f59e0b"
  | "blocked" -> "#ef4444"
  | "at_risk" -> "#f59e0b"
  | "on_track" -> "#4ade80"
  | _ -> "#94a3b8"

let task_status_color status_label =
  match status_label with
  | "pending" -> "#6b7280"
  | "claimed" -> "#f59e0b"
  | "in_progress" -> "#3b82f6"
  | "awaiting_verification" -> "#a78bfa"
  | "completed" -> "#4ade80"
  | "cancelled" -> "#ef4444"
  | _ -> "#888888"

let task_to_tree_json ((task, linkage_source) : Masc_domain.task * string) =
  let status = task_status_label task in
  `Assoc
    [
      ("id", `String task.id);
      ("title", `String task.title);
      ("goal_id", Json_util.string_opt_to_json task.goal_id);
      ("status", `String status);
      ("status_color", `String (task_status_color status));
      ("priority", `Int task.priority);
      ("goal_id", Json_util.string_opt_to_json task.goal_id);
      ("assignee",
       match task_assignee task with
       | Some assignee -> `String assignee
       | None -> `Null);
      ("goal_id",
       match task.goal_id with
       | Some goal_id -> `String goal_id
       | None -> `Null);
      ("linkage_source", `String linkage_source);
      ("is_terminal", `Bool (task_is_terminal task));
      ("created_at", `String task.created_at);
      ("updated_at", `String (task_updated_at task));
    ]

let goal_policy_nodes goals =
  List.map
    (fun (goal : Goal_store.goal) ->
      {
        Goal_verification.goal_id = goal.id;
        parent_goal_id = goal.parent_goal_id;
        verifier_policy = goal.verifier_policy;
      })
    goals

let build_goal_verification_projection ~(config : Coord.config) goals =
  let requests =
    Goal_verification.read_state config |> fun (state : Goal_verification.state) ->
    state.requests
  in
  let effective_policy_table = Hashtbl.create (max 16 (List.length goals)) in
  let request_table = Hashtbl.create (max 16 (List.length requests)) in
  let latest_request_table :
      (string, Goal_verification.goal_verification_request) Hashtbl.t =
    Hashtbl.create (max 16 (List.length requests))
  in
  let goal_events =
    let path = Goal_verification.events_path config in
    if Coord.path_exists config path then
      Fs_compat.load_jsonl path
    else
      []
  in
  let events_table = Hashtbl.create (max 16 (List.length goals)) in
  let policy_nodes = goal_policy_nodes goals in
  List.iter
    (fun (goal : Goal_store.goal) ->
      match
        Goal_verification.effective_policy_for_nodes ~goals:policy_nodes
          ~goal_id:goal.id
      with
      | Ok policy -> Hashtbl.replace effective_policy_table goal.id policy
      | Error _ -> Hashtbl.replace effective_policy_table goal.id None)
    goals;
  List.iter
    (fun (request : Goal_verification.goal_verification_request) ->
      let should_replace_latest =
        match Hashtbl.find_opt latest_request_table request.goal_id with
        | None -> true
        | Some existing -> String.compare request.created_at existing.created_at >= 0
      in
      if should_replace_latest then
        Hashtbl.replace latest_request_table request.goal_id request;
      if request.status = Goal_verification.Open then
        Hashtbl.replace request_table request.goal_id request)
    requests;
  List.iter
    (fun json ->
      match json |> member "goal_id" |> to_string_option with
      | Some goal_id ->
          let existing =
            Option.value (Hashtbl.find_opt events_table goal_id) ~default:[]
          in
          Hashtbl.replace events_table goal_id (existing @ [ json ])
      | None -> ())
    goal_events;
  ( (fun goal_id ->
      Option.value (Hashtbl.find_opt effective_policy_table goal_id)
        ~default:None),
    (fun goal_id -> Hashtbl.find_opt request_table goal_id),
    (fun goal_id -> Hashtbl.find_opt latest_request_table goal_id),
    (fun goal_id ->
      Option.value (Hashtbl.find_opt events_table goal_id) ~default:[]) )

let rec tree_node_to_json ?(effective_policy_for_goal = fun _ -> None)
    ?(open_request_for_goal = fun _ -> None)
    ?(latest_request_for_goal = fun _ -> None) ?(events_for_goal = fun _ -> [])
    node =
  let goal = node.goal in
  let effective_policy = effective_policy_for_goal goal.id in
  let open_request = open_request_for_goal goal.id in
  let latest_request = latest_request_for_goal goal.id in
  let summary_request =
    match open_request with
    | Some request -> Some request
    | None -> latest_request
  in
  let approve_count, reject_count, remaining_possible =
    match summary_request with
    | None -> (0, 0, 0)
    | Some request ->
        ( Goal_verification.count_votes ~decision:Goal_verification.Approve request,
          Goal_verification.count_votes ~decision:Goal_verification.Reject request,
          Goal_verification.remaining_possible_votes request )
  in
  `Assoc
    [
      ("id", `String goal.id);
      ("title", `String goal.title);
      ("horizon", Goal_store.horizon_to_yojson goal.horizon);
      ("status", Goal_store.goal_status_to_yojson goal.status);
      ("status_color", `String (goal_status_color goal.status));
      ("phase", Goal_phase.to_yojson goal.phase);
      ("phase_color", `String (goal_phase_color goal.phase));
      ("goal_fsm", goal_fsm_to_json ~effective_policy goal node);
      ("health", `String node.health);
      ("health_color", `String (goal_health_color node.health));
      ("badges", `List (List.map (fun badge -> `String badge) node.badges));
      ("status_reason", `String node.status_reason);
      ("priority", `Int goal.priority);
      ("metric",
       match goal.metric with Some metric -> `String metric | None -> `Null);
      ("target_value",
       match goal.target_value with Some value -> `String value | None -> `Null);
      ("due_date",
       match goal.due_date with Some due_date -> `String due_date | None -> `Null);
      ("parent_goal_id",
       match goal.parent_goal_id with
       | Some parent_goal_id -> `String parent_goal_id
       | None -> `Null);
      ("convergence", `Float node.convergence);
      ("convergence_pct", `Int (int_of_float (node.convergence *. 100.0)));
      ( "attainment",
        let attainment = goal_attainment_to_json goal node in
        observe_goal_attainment_metrics goal attainment;
        attainment );
      ("tasks", `List (List.map task_to_tree_json node.tasks));
      ("task_count", `Int (List.length node.tasks));
      ("task_done_count",
       `Int
         (List.length
            (List.filter
               (fun ((task, _) : Masc_domain.task * string) -> task_is_done task)
               node.tasks)));
      ( "verification_summary",
        `Assoc
          [
            ( "effective_policy",
              match effective_policy with
              | Some policy -> Goal_verification.policy_snapshot_to_yojson policy
              | None -> `Null );
            ( "open_request",
              match open_request with
              | Some request ->
                  Goal_verification.goal_verification_request_to_yojson request
              | None -> `Null );
            ( "latest_request",
              match latest_request with
              | Some request ->
                  Goal_verification.goal_verification_request_to_yojson request
              | None -> `Null );
            ("approve_count", `Int approve_count);
            ("reject_count", `Int reject_count);
            ("remaining_possible", `Int remaining_possible);
          ] );
      ( "effective_verifier_policy",
        match effective_policy with
        | Some policy -> Goal_verification.policy_snapshot_to_yojson policy
        | None -> `Null );
      ( "active_verification_request",
        match open_request with
        | Some request -> Goal_verification.goal_verification_request_to_yojson request
        | None -> `Null );
      ("pending_verification_count", `Int (if open_request = None then 0 else 1));
      ("timeline_events", `List (events_for_goal goal.id));
      ( "children",
        `List
          (List.map
             (tree_node_to_json ~effective_policy_for_goal ~open_request_for_goal
                ~latest_request_for_goal ~events_for_goal)
             node.children) );
      ("child_count", `Int (List.length node.children));
      ("last_activity_at", `String node.last_activity_at);
      ("stagnation_seconds", `Int node.stagnation_seconds);
      ("activity_observation", `String node.activity_observation);
      ("stagnation_status", `String node.stagnation_status);
      ( "linked_keeper_names",
        `List
          (List.map (fun keeper_name -> `String keeper_name) node.linked_keeper_names)
      );
      ("pending_approval_count", `Int node.pending_approval_count);
      ("infra_risk_count", `Int node.infra_risk_count);
      ("linkage_source", `String node.linkage_source);
      ("linkage_warning_count", `Int node.linkage_warning_count);
      ("blocking_source", `String node.blocking_source);
      ("blocking_reason", `String node.blocking_reason);
      ("latest_keeper_ref", Json_util.string_opt_to_json node.latest_keeper_ref);
      ("latest_turn_ref", Json_util.int_opt_to_json node.latest_turn_ref);
      ("stalled_since", Json_util.string_opt_to_json node.stalled_since);
      ("created_at", `String goal.created_at);
      ("updated_at", `String goal.updated_at);
    ]

let rec flatten_tree acc = function
  | [] -> List.rev acc
  | node :: rest ->
      flatten_tree (node :: acc) (node.children @ rest)

let goal_detail_keeper_json (detail : goal_detail_keeper) =
  let meta = detail.meta in
  let latest_receipt = detail.latest_receipt in
  let latest_causal_event =
    match detail.runtime_trust |> member "latest_causal_event" with
    | `Assoc _ as event -> event
    | _ -> `Null
  in
  let latest_execution_outcome =
    match latest_receipt with
    | Some receipt -> receipt_outcome receipt
    | None -> None
  in
  `Assoc
    [
      ("name", `String meta.name);
      ("agent_name", `String meta.agent_name);
      ( "current_task_id",
        match meta.current_task_id with
        | Some task_id -> `String (Keeper_id.Task_id.to_string task_id)
        | None -> `Null );
      ( "active_goal_ids",
        `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids) );
      ( "sandbox_profile",
        `String (Keeper_types.sandbox_profile_to_string meta.sandbox_profile) );
      ("network_mode", `String (Keeper_types.network_mode_to_string meta.network_mode));
      ("cascade_name", `String meta.cascade_name);
      ( "approval_profile",
        match latest_receipt with
        | Some receipt ->
            (match receipt_approval_profile receipt with
             | Some profile -> `String profile
             | None -> `Null)
        | None -> `Null );
      ( "cascade_outcome",
        match latest_receipt with
        | Some receipt ->
            (match receipt_cascade_outcome receipt with
             | Some outcome -> `String outcome
             | None -> `Null)
        | None -> `Null );
      ( "latest_execution_outcome",
        match latest_execution_outcome with
        | Some outcome -> `String outcome
        | None -> `Null );
      ( "latest_execution_at",
        match latest_receipt with
        | Some receipt ->
            (match receipt_ended_at receipt with
             | Some ended_at -> `String ended_at
             | None -> `Null)
        | None -> `Null );
      ( "latest_receipt",
        match latest_receipt with
        | Some receipt -> receipt
        | None -> `Null );
      ("runtime_trust", detail.runtime_trust);
      ("latest_causal_event", latest_causal_event);
    ]

let timeline_event_json ~ts ~kind ~lane ~title ~summary ~severity =
  `Assoc
    [
      ("ts", `String ts);
      ("kind", `String kind);
      ("lane", `String lane);
      ("title", `String title);
      ("summary", `String summary);
      ("severity", `String severity);
    ]

let json_member_or_null field = function
  | `Assoc _ as json -> member field json
  | _ -> `Null

let goal_event_timeline_json event =
  let event_type =
    event |> member "event_type" |> to_string_option
    |> Option.value ~default:"goal_event"
  in
  let payload = event |> member "payload" in
  let payload_field field = json_member_or_null field payload in
  let ts = event |> member "ts" |> to_string_option |> Option.value ~default:"" in
  let title, summary, severity =
    match event_type with
    | "goal_phase" ->
        let phase =
          payload_field "phase" |> to_string_option
          |> Option.value ~default:"unknown"
        in
        let actor =
          payload_field "actor" |> json_member_or_null "id" |> to_string_option
        in
        ( "Goal Phase",
          (match actor with
          | Some actor_id -> Printf.sprintf "phase=%s by %s" phase actor_id
          | None -> Printf.sprintf "phase=%s" phase),
          (match phase with
          | "blocked" -> "bad"
          | "awaiting_verification" | "awaiting_approval" | "paused" -> "warn"
          | _ -> "ok") )
    | "goal_verification_opened" ->
        let request = payload_field "request" in
        let request_id =
          request |> json_member_or_null "id" |> to_string_option
          |> Option.value ~default:"request"
        in
        let required =
          request |> json_member_or_null "policy_snapshot"
          |> json_member_or_null "required_verdicts" |> to_int_option
        in
        ( "Goal Verification Opened",
          (match required with
          | Some n -> Printf.sprintf "request %s quorum=%d" request_id n
          | None -> Printf.sprintf "request %s opened" request_id),
          "warn" )
    | "goal_vote" ->
        let vote = payload_field "vote" in
        let decision =
          vote |> json_member_or_null "decision" |> to_string_option
          |> Option.value ~default:"unknown"
        in
        let principal =
          vote |> json_member_or_null "principal" |> json_member_or_null "id"
          |> to_string_option
          |> Option.value ~default:"principal"
        in
        ( "Goal Vote",
          Printf.sprintf "%s voted %s" principal decision,
          if String.equal decision "reject" then "bad" else "ok" )
    | "goal_verification_resolved" ->
        let status =
          payload_field "status" |> to_string_option
          |> Option.value ~default:"unknown"
        in
        ( "Goal Verification Resolved",
          Printf.sprintf "status=%s" status,
          (match status with
          | "approved" -> "ok"
          | "rejected" -> "bad"
          | _ -> "warn") )
    | "goal_approval_opened" ->
        let request_id = payload_field "request_id" |> to_string_option in
        ( "Goal Approval Opened",
          (match request_id with
          | Some id -> Printf.sprintf "request %s is awaiting operator approval" id
          | None -> "goal is awaiting operator approval"),
          "warn" )
    | "goal_approval_resolved" ->
        let decision =
          payload_field "decision" |> to_string_option
          |> Option.value ~default:"unknown"
        in
        ( "Goal Approval Resolved",
          Printf.sprintf "decision=%s" decision,
          if String.equal decision "reject" then "bad" else "ok" )
    | _ ->
        ("Goal Event", event_type, "ok")
  in
  timeline_event_json ~ts ~kind:event_type ~lane:"goal" ~title ~summary ~severity

let build_goal_timeline node linked_keepers approvals goal_events =
  let task_events =
    node.tasks
    |> List.map (fun ((task, linkage_source) : Masc_domain.task * string) ->
           let status = task_status_label task in
           timeline_event_json ~ts:(task_updated_at task) ~kind:"task"
             ~lane:("task:" ^ task.id)
             ~title:task.title
             ~summary:
               (Printf.sprintf "%s · linkage=%s" status linkage_source)
             ~severity:
               (match status with
                | "cancelled" -> "bad"
                | "awaiting_verification" | "claimed" | "in_progress" ->
                    "warn"
                | _ -> "ok"))
  in
  let approval_events =
    approvals
    |> List.filter_map (fun approval ->
           match approval |> member "requested_at_iso" |> to_string_option with
           | None -> None
           | Some requested_at ->
               let approval_id =
                 approval |> member "id" |> to_string_option
                 |> Option.value ~default:"approval"
               in
               let tool_name =
                 approval |> member "tool_name" |> to_string_option
                 |> Option.value ~default:"tool"
               in
               Some
                 (timeline_event_json ~ts:requested_at ~kind:"approval"
                    ~lane:("approval:" ^ approval_id)
                    ~title:(Printf.sprintf "Approval · %s" tool_name)
                    ~summary:
                      (approval |> member "input_preview" |> to_string_option
                       |> Option.value ~default:"pending operator decision")
                    ~severity:"warn"))
  in
  let keeper_events =
    linked_keepers
    |> List.filter_map (fun (detail : goal_detail_keeper) ->
           match trust_latest_event detail.runtime_trust with
           | Some event ->
               let title =
                 event |> member "title" |> to_string_option
                 |> Option.value ~default:(Printf.sprintf "Keeper · %s" detail.meta.name)
               in
               let summary =
                 event |> member "summary" |> to_string_option
                 |> Option.value ~default:"latest keeper event"
               in
               let severity =
                 event |> member "severity" |> to_string_option
                 |> Option.value ~default:"warn"
               in
               let ts =
                 event |> member "ts" |> to_string_option
                 |> Option.value ~default:(Masc_domain.now_iso ())
               in
               Some
                 (timeline_event_json ~ts ~kind:"keeper_runtime"
                    ~lane:("keeper:" ^ detail.meta.name)
                    ~title:(Printf.sprintf "%s · %s" detail.meta.name title)
                    ~summary ~severity)
           | None ->
               match detail.latest_receipt with
               | None -> None
               | Some receipt -> (
                   match receipt_ended_at receipt with
                   | None -> None
                   | Some ended_at ->
                       let outcome =
                         receipt_outcome receipt |> Option.value ~default:"unknown"
                       in
                       let severity =
                         if receipt_has_error receipt then "bad"
                         else if receipt_has_sandbox_risk receipt
                                 || receipt_has_cascade_risk receipt
                         then "warn"
                         else "ok"
                       in
                       Some
                         (timeline_event_json ~ts:ended_at ~kind:"keeper_receipt"
                            ~lane:("keeper:" ^ detail.meta.name)
                            ~title:(Printf.sprintf "Keeper · %s" detail.meta.name)
                            ~summary:
                              (Printf.sprintf "%s · %s"
                                 outcome
                                 (receipt_cascade_name receipt
                                  |> Option.value ~default:detail.meta.cascade_name))
                            ~severity)))
  in
  let goal_events = List.map goal_event_timeline_json goal_events in
  task_events @ approval_events @ keeper_events @ goal_events
  |> List.sort (fun left right ->
         let lts = left |> member "ts" |> to_string_option |> Option.value ~default:"" in
         let rts = right |> member "ts" |> to_string_option |> Option.value ~default:"" in
         String.compare rts lts)

let goal_detail_json ~(config : Coord.config) ~goal_id :
    (Yojson.Safe.t, string) result =
  let goals = Goal_store.list_goals config () in
  let tasks = Coord.get_tasks_safe config in
  let ( effective_policy_for_goal,
        open_request_for_goal,
        latest_request_for_goal,
        events_for_goal ) =
    build_goal_verification_projection ~config goals
  in
  let forest = build_forest ~config ~goals ~tasks in
  let all_nodes = flatten_tree [] forest in
  match List.find_opt (fun (node : tree_node) -> String.equal node.goal.id goal_id) all_nodes with
  | None -> Error (Printf.sprintf "Goal %s not found" goal_id)
  | Some node ->
      let keeper_details =
        Keeper_types.keeper_names config
        |> List.filter_map (fun keeper_name ->
               match Keeper_types.read_meta config keeper_name with
               | Ok (Some meta) when List.mem meta.name node.linked_keeper_names ->
                   let latest_receipt =
                     List.assoc_opt meta.name
                       (Keeper_execution_receipt.latest_json_by_keeper
                          config node.linked_keeper_names)
                   in
                   let runtime_trust =
                     let snapshot =
                       keeper_runtime_trust_snapshot_json ~config ~meta
                     in
                     if trust_snapshot_unavailable snapshot then
                       match latest_receipt with
                       | Some receipt ->
                           runtime_trust_from_receipt_fallback ~config ~meta receipt
                       | None -> snapshot
                     else
                       snapshot
                   in
                   Some
                     {
                       meta;
                       latest_receipt;
                       runtime_trust;
                     }
               | Ok None | Error _ | Ok (Some _) -> None)
      in
      let approvals =
        match Keeper_approval_queue.list_pending_dashboard_json () with
        | `List items ->
            items |> List.filter (approval_matches_goal goal_id)
        | _ -> []
      in
      let latest_receipts =
        keeper_details
        |> List.filter_map (fun detail ->
               detail.latest_receipt |> Option.map (fun receipt -> receipt))
      in
      let goal_events = events_for_goal goal_id in
      Ok
        (`Assoc
          [
            ("generated_at", `String (Masc_domain.now_iso ()));
            ( "goal",
              tree_node_to_json ~effective_policy_for_goal ~open_request_for_goal
                ~latest_request_for_goal ~events_for_goal node );
            ("linked_tasks", `List (List.map task_to_tree_json node.tasks));
            ("linked_keepers", `List (List.map goal_detail_keeper_json keeper_details));
            ("approvals", `List approvals);
            ("execution_receipts", `List latest_receipts);
            ( "timeline",
              `List
                (build_goal_timeline node keeper_details approvals goal_events) );
          ])

let dashboard_goals_tree_json ~(config : Coord.config) : Yojson.Safe.t =
  let goals = Goal_store.list_goals config () in
  let tasks = Coord.get_tasks_safe config in
  let ( effective_policy_for_goal,
        open_request_for_goal,
        latest_request_for_goal,
        events_for_goal ) =
    build_goal_verification_projection ~config goals
  in
  let forest = build_forest ~config ~goals ~tasks in
  let all_nodes = flatten_tree [] forest in
  let total_goals = List.length goals in
  let total_tasks =
    List.fold_left
      (fun acc (node : tree_node) -> acc + List.length node.tasks)
      0 all_nodes
  in
  let done_tasks =
    List.fold_left
      (fun acc (node : tree_node) ->
        acc
        + List.length
            (List.filter
               (fun ((task, _) : Masc_domain.task * string) -> task_is_done task)
               node.tasks))
      0 all_nodes
  in
  let overall_convergence =
    match forest with
    | [] -> 0.0
    | roots ->
        let sum =
          List.fold_left (fun acc (node : tree_node) -> acc +. node.convergence)
            0.0 roots
        in
        sum /. float_of_int (List.length roots)
  in
  let count_health health =
    List.length
      (List.filter (fun (node : tree_node) -> String.equal node.health health) all_nodes)
  in
  let active_goal_count =
    goals
    |> List.filter (fun (goal : Goal_store.goal) -> goal.status = Goal_store.Active)
    |> List.length
  in
  let pending_approval_total =
    match Keeper_approval_queue.list_pending_dashboard_json () with
    | `List items -> List.length items
    | _ -> 0
  in
  `Assoc
    [
      ("generated_at", `String (Masc_domain.now_iso ()));
      ( "tree",
        `List
          (List.map
             (tree_node_to_json ~effective_policy_for_goal ~open_request_for_goal
                ~latest_request_for_goal ~events_for_goal)
             forest) );
      ( "summary",
        `Assoc
          [
            ("total_goals", `Int total_goals);
            ("active_goals", `Int active_goal_count);
            ("on_track_goals", `Int (count_health "on_track"));
            ("done_goals", `Int (count_health "done"));
            ("paused_goals", `Int (count_health "paused"));
            ("at_risk_goals", `Int (count_health "at_risk"));
            ("blocked_goals", `Int (count_health "blocked"));
            ("total_tasks", `Int total_tasks);
            ("done_tasks", `Int done_tasks);
            ("pending_approvals", `Int pending_approval_total);
            ( "infra_risk_count",
              `Int
                (List.fold_left
                   (fun acc (node : tree_node) -> acc + node.infra_risk_count)
                   0 forest) );
            ("overall_convergence", `Float overall_convergence);
            ( "overall_convergence_pct",
              `Int (int_of_float (overall_convergence *. 100.0)) );
          ] );
    ]
