(** Dashboard_goals_types — pure types + task helpers extracted from
    Dashboard_goals (1998 LoC godfile).

    See dashboard_goals_types.mli for rationale and contract. *)

open Yojson.Safe.Util

type tree_node = {
  goal : Goal_store.goal;
  children : tree_node list;
  tasks : (Masc_domain.task * string) list;
  convergence : float;
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

(** {1 Metric parsing utilities — pure tokenizer + percent/count inference} *)

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
   nouns trigger the percent inference. *)
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

(** {1 Goal attainment JSON projection — pure tree → JSON converter} *)

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

(** {1 Goal phase health + reason + tree badges (pure)} *)

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

(** {1 Approval matching + keeper assignee resolution + goal FSM projection (pure)} *)

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

(** {1 Operator-disposition normalizer (pure)} *)

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

(** {1 Color helpers + task tree JSON projection (pure)} *)

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

(** {1 Tree flatten + goal-detail JSON + timeline projection (pure)} *)

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
      ("cascade_name", `String (Keeper_types.cascade_name_of_meta meta));
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
