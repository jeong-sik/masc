(** Dashboard_goals_types_accessor — Stage 22 split (was inline in
    dashboard_goals_types.ml).

    Holds the public record types, pure task-status helpers, list utilities,
    and the receipt / trust JSON inspectors + iso/duration helpers. All
    pure projections over already-loaded inputs; no I/O or clock reads.

    Facade [Dashboard_goals_types] re-includes this module so existing
    callers keep using [Dashboard_goals.task_is_done], etc. unchanged. *)

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
