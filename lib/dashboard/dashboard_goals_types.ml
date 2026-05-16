(** Dashboard_goals_types — pure types + task helpers extracted from
    Dashboard_goals (1998 LoC godfile).

    See dashboard_goals_types.mli for rationale and contract. *)

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
