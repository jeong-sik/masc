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
  tasks : Masc_domain.task list;
  last_activity_at : string;
  stagnation_seconds : int option;
  linked_keeper_names : string list;
  pending_approval_count : int;
  latest_keeper_ref : string option;
  latest_turn_ref : int option;
  activity_observation : string;
}

type goal_detail_keeper = {
  meta : Keeper_meta_contract.keeper_meta;
  latest_receipt : Yojson.Safe.t option;
  runtime_trust : Yojson.Safe.t;
}

let task_is_linked_to_goal ?(goal_task_index = Hashtbl.create 0) (task : Masc_domain.task) goal_id =
  let task_goal_ids =
    (* DET-OK: an absent bucket means no recorded links; this is the same []
       returned by the replaced [Not_found] handler. *)
    Option.value (Hashtbl.find_opt goal_task_index task.id) ~default:[]
  in
  List.mem goal_id task_goal_ids

(* A Task appears under a Goal only when the link table says so, so every row
   carried the same constant "explicit". The other three documented values —
   "title_tag", "mixed", "none" — had no producer at all: [link_source_of_values]
   could only ever see one distinct value, and no code ever emitted a title-tag
   linkage. The field conveyed nothing and the frontend still branched on it,
   printing "title tag" for a case that could not occur. Linkage is now the
   membership itself. *)
let task_is_linked_opt ?(goal_task_index = Hashtbl.create 0) (task : Masc_domain.task) goal_id =
  if task_is_linked_to_goal ~goal_task_index task goal_id then Some () else None

(* The tree feeds the same Work surface as the execution payload, so it must
   answer the same question: who did or is doing the work. Using the ownership
   helper here made a completed Task show its performer via execution and
   nobody via the tree. *)
let task_assignee (task : Masc_domain.task) : string option =
  Masc_domain.task_performer_of_status task.task_status


let task_is_terminal (task : Masc_domain.task) : bool =
  Masc_domain.task_status_is_terminal task.task_status

let task_is_done (task : Masc_domain.task) : bool =
  Masc_domain.task_status_is_done task.task_status

let task_updated_at = Masc_domain.task_last_transition_at

let dedupe_sort values =
  values |> List.sort_uniq String.compare

let receipt_error_kind json =
  match Json_util.assoc_member_opt "error" json with
  | Some (`Assoc _ as error) -> Json_util.get_string error "kind"
  | _ -> None

let receipt_error_message json =
  match Json_util.assoc_member_opt "error" json with
  | Some (`Assoc _ as error) -> Json_util.get_string error "message"
  | _ -> None

let receipt_runtime_id json =
  match Json_util.assoc_member_opt "runtime" json with
  | Some runtime -> Json_util.get_string runtime "name"
  | None -> None

let receipt_runtime_outcome json =
  match Json_util.assoc_member_opt "runtime" json with
  | Some runtime -> Json_util.get_string runtime "outcome"
  | None -> None

let receipt_outcome json =
  Json_util.get_string json "outcome"

let receipt_started_at json =
  Json_util.get_string json "started_at"

let receipt_ended_at json =
  Json_util.get_string json "ended_at"

let receipt_turn_count json =
  Json_util.get_int json "turn_count"

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

let receipt_has_error json =
  match receipt_error_kind json with
  | Some _ -> true
  | None -> false

let iso_max left right =
  if String.compare left right >= 0 then left else right

let latest_iso ?fallback values =
  match values with
  | [] -> fallback
  | first :: rest ->
      Some (List.fold_left iso_max first rest)
