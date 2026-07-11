(** Dashboard_goals_types_accessor — Stage 22 split (was inline in
    dashboard_goals_types.ml).

    Holds the public record types, pure task-status helpers, list utilities,
    and the receipt / trust JSON inspectors + iso/duration helpers. All
    pure projections over already-loaded inputs; no I/O or clock reads.

    Facade [Dashboard_goals_types] re-includes this module so existing
    callers keep using [Dashboard_goals.task_is_done], etc. unchanged. *)


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
  meta : Keeper_meta_contract.keeper_meta;
  latest_receipt : Yojson.Safe.t option;
  runtime_trust : Yojson.Safe.t;
}

type attainment_unit =
  | Percent
  | Count
  | Unknown

(* Whether a goal's declared metric has actually been evaluated (task-1743).
   The convergence evaluator that would turn [goal.metric] into an observed
   value (Convergence.check_convergence) has no caller, so a metric is only
   ever declared, never measured. Attainment percentages are derived from
   linked task completion, not from the metric, so this typed field keeps
   the two apart: it lets the IDE goal panel show "metric unevaluated"
   instead of presenting task progress as a metric result, and distinguishes
   an unmeasured metric from a genuine measured zero. Replaced with a real
   evaluation state once Wave-D wires a metric evaluator. *)
type metric_evaluation =
  | Metric_unevaluated  (* [goal.metric] is set but no evaluator produced a value *)
  | Metric_absent       (* [goal.metric] is [None]; there is no metric to evaluate *)

let task_is_linked_to_goal ?(goal_task_index = Hashtbl.create 0) (task : Masc_domain.task) goal_id =
  let task_goal_ids =
    try Hashtbl.find goal_task_index task.id with Not_found -> []
  in
  List.mem goal_id task_goal_ids

let task_linkage_source_opt ?(goal_task_index = Hashtbl.create 0) (task : Masc_domain.task) goal_id =
  if task_is_linked_to_goal ~goal_task_index task goal_id
  then Some "explicit"
  else None

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
  | Masc_domain.OperatorBlocked _ -> "operator_blocked"

let task_is_terminal (task : Masc_domain.task) : bool =
  Masc_domain.task_status_is_terminal task.task_status

let task_is_done (task : Masc_domain.task) : bool =
  Masc_domain.task_status_is_done task.task_status

let task_updated_at (task : Masc_domain.task) : string =
  match task.task_status with
  | Masc_domain.Done { completed_at; _ } -> completed_at
  | Masc_domain.Cancelled { cancelled_at; _ } -> cancelled_at
  | Masc_domain.OperatorBlocked { blocked_at; _ } -> blocked_at
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
  match Json_util.assoc_member_opt "error" json with
  | Some (`Assoc _ as error) -> Json_util.get_string error "kind"
  | _ -> None

let receipt_error_message json =
  match Json_util.assoc_member_opt "error" json with
  | Some (`Assoc _ as error) -> Json_util.get_string error "message"
  | _ -> None

let receipt_sandbox_kind json =
  match Json_util.assoc_member_opt "sandbox" json with
  | Some sandbox -> Json_util.get_string sandbox "kind"
  | None -> None

let receipt_runtime_id json =
  match Json_util.assoc_member_opt "runtime" json with
  | Some runtime -> Json_util.get_string runtime "name"
  | None -> None

let receipt_runtime_outcome json =
  match Json_util.assoc_member_opt "runtime" json with
  | Some runtime -> Json_util.get_string runtime "outcome"
  | None -> None

let receipt_runtime_fallback_applied json =
  (match Json_util.assoc_member_opt "runtime" json with
  | Some runtime -> Json_util.get_bool runtime "fallback_applied"
  | None -> None)
  |> Option.value ~default:false

let receipt_outcome json =
  Json_util.get_string json "outcome"

let receipt_started_at json =
  Json_util.get_string json "started_at"

let receipt_ended_at json =
  Json_util.get_string json "ended_at"

let receipt_turn_count json =
  Json_util.get_int json "turn_count"

let trust_disposition json =
  Json_util.get_string json "disposition"

let trust_disposition_reason json =
  Json_util.get_string json "disposition_reason"

let trust_attention_reason json =
  Json_util.get_string json "attention_reason"

let trust_needs_attention json =
  Json_util.get_bool json "needs_attention"
  |> Option.value ~default:false

let trust_snapshot_unavailable json =
  String.equal
    (Json_util.get_string_with_default json ~key:"disposition_reason" ~default:"")
    "runtime_trust_snapshot_unavailable"

let trust_turn_id json =
  Json_util.get_int json "turn_id"

let trust_latest_event json =
  match Json_util.assoc_member_opt "latest_causal_event" json with
  | Some (`Assoc _ as event) -> Some event
  | _ -> None

let trust_latest_event_ts json =
  Option.bind (trust_latest_event json) (fun event ->
      Json_util.get_string event "ts" )

let trust_latest_event_ts_unix json =
  Option.bind (trust_latest_event json) (fun event ->
      Json_util.get_float event "ts_unix" )

let trust_sandbox_risk json =
  String.equal
    (Json_util.get_string_with_default json ~key:"disposition_reason" ~default:"")
    "sandbox_violation"

let trust_runtime_risk json =
  String.equal
    (Json_util.get_string_with_default json ~key:"disposition_reason" ~default:"")
    "runtime_exhausted"

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

let receipt_has_runtime_risk json =
  receipt_runtime_fallback_applied json
  ||
  match receipt_runtime_outcome json with
  | Some "passed_to_next_model" -> true
  | _ -> false

let iso_max left right =
  if String.compare left right >= 0 then left else right

let latest_iso ?fallback values =
  match values with
  | [] -> fallback
  | first :: rest ->
      Some (List.fold_left iso_max first rest)

(* RFC-0294: stagnation threshold was per-horizon (Short 6h / Mid 1d / Long 3d).
   With the workspace-goal horizon removed it collapses to a single policy
   constant — the former Mid bucket (1 day) — chosen to preserve the median of
   the old table. *)
let stagnation_threshold_seconds = Masc_time_constants.day_int

let human_duration seconds =
  if seconds < Masc_time_constants.hour_int
  then Printf.sprintf "%dm" (seconds / 60)
  else if seconds < Masc_time_constants.day_int
  then Printf.sprintf "%dh" (seconds / Masc_time_constants.hour_int)
  else Printf.sprintf "%dd" (seconds / Masc_time_constants.day_int)
