open Result.Syntax

type task_status =
  | Todo
  | Claimed
  | In_progress
  | Awaiting_verification
  | Done of { completed_at : Candle_time.t }
  | Cancelled

type task_found = { title : string; assignee : string option; status : task_status }
type keeper_observation =
  | Keeper_name of string
  | Not_keeper of string
  | No_assignee
  | Keeper_unknown
type assignee_observation = Assigned of string | Unassigned | Unreadable_assignee
type status_observation = Observed_status of task_status | Unreadable_status
type task_fragment = { title : string option; assignee : assignee_observation; status : status_observation;
                       keeper : keeper_observation }

type task_lookup =
  | Found of task_found
  | Found_uncertain of task_fragment list
  | Deleted
  | Unobserved

type attribution = {
  grade : Candle_grade.t;
  grade_trace : Candle_appraisal.trace;
  relations : Candle_appraisal.task_relation list;
}
type unattributed_reason = No_candidates | All_unrelated of attribution | No_related_keepers of attribution | Window_released

type equipment_choice = Default | Item of Keeper_portrait_item.t

type candidate_observation =
  { goal_id : string
  ; request_id : string
  ; verification_run_id : string
  ; tasks : (string * task_lookup) list
  ; candidate_task_ids : string list
  ; candidate_keepers : string list
  ; candidate_task_keepers : (string * string option) list
  }

type body =
  | Half_life_set of Candle_decay.half_life
  | Snapshot of
      { goal_id : string
      ; request_id : string
      ; verification_run_id : string
      ; criterion_revision : string
      ; passed_at : Candle_time.t
      ; goal_created_at : Candle_time.t
      ; due_date : string option
      ; title : string
      ; metric : string option
      ; target_value : string option
      ; linked_task_ids : string list
      }
  | Payout_owed of
      { goal_id : string
      ; request_id : string
      ; verification_run_id : string
      ; passed_at : Candle_time.t
      ; confirmed_at : Candle_time.t
      }
  | Candidates of candidate_observation
  | Candidates_fenced of candidate_observation
  | Candidate_window_held of
      { goal_id : string
      ; request_id : string
      ; verification_run_id : string
      ; passed_at : Candle_time.t
      ; confirmed_at : Candle_time.t
      ; tasks : (string * task_lookup) list
      ; task_keepers : (string * keeper_observation) list
      }
  | Candidate_window_released of
      { goal_id : string
      ; request_id : string
      ; verification_run_id : string
      }
  | Unattributed of
      { goal_id : string
      ; request_id : string
      ; verification_run_id : string
      ; reason : unattributed_reason
      }
  | Paid of Candle_payment.t
  | Purchased of { keeper : string; item : Keeper_portrait_item.t; amount_milli : int }
  | Granted of { keeper : string; amount_milli : int; reason : string }
  | Gifted of { from_keeper : string; to_keeper : string; amount_milli : int; reason : string }
  | Gifted_item of { from_keeper : string; to_keeper : string; item : Keeper_portrait_item.t }
  | Equipped of { keeper : string; slot : Keeper_portrait_item.slot; choice : equipment_choice }
  | Payout_failed of { goal_id : string; request_id : string; verification_run_id : string; due_date : string }

type t =
  { at : Candle_time.t
  ; body : body
  }

let kind = function
  | Half_life_set _ -> "half_life_set"
  | Snapshot _ -> "snapshot"
  | Payout_owed _ -> "payout_owed"
  | Candidates _ | Candidates_fenced _ -> "candidates"
  | Candidate_window_held _ -> "candidate_window_held"
  | Candidate_window_released _ -> "candidate_window_released"
  | Unattributed _ -> "unattributed"
  | Paid _ -> "paid"
  | Purchased _ -> "purchased"
  | Granted _ -> "granted"
  | Gifted _ -> "gifted"
  | Gifted_item _ -> "gifted_item"
  | Equipped _ -> "equipped"
  | Payout_failed _ -> "payout_failed"
;;

let nullable_text = function
  | None -> `Null
  | Some value -> `String value
;;

let text_list ids = `List (List.map (fun id -> `String id) ids)

let status_text = function
  | Todo -> "todo"
  | Claimed -> "claimed"
  | In_progress -> "in_progress"
  | Awaiting_verification -> "awaiting_verification"
  | Done _ -> "done"
  | Cancelled -> "cancelled"
;;

(* Only a done Task has a completion time; the other rows write [null]. *)
let completed_at_json = function
  | Done { completed_at } -> Candle_time.to_yojson completed_at
  | Todo | Claimed | In_progress | Awaiting_verification | Cancelled -> `Null
;;

let found_detail_fields (found : task_found) =
  [ "title", `String found.title
  ; "assignee", nullable_text found.assignee
  ; "status", `String (status_text found.status)
  ; "completed_at", completed_at_json found.status
  ]

let fragment_fields (fragment : task_fragment) =
  let assignee_state, assignee = match fragment.assignee with
    | Assigned name -> "assigned", Some name
    | Unassigned -> "unassigned", None
    | Unreadable_assignee -> "unreadable", None in
  let status, completed_at = match fragment.status with
    | Observed_status status -> `String (status_text status), completed_at_json status
    | Unreadable_status -> `Null, `Null in
  let keeper_state, keeper_name = match fragment.keeper with
    | Keeper_name name -> "keeper", Some name | Not_keeper name -> "not_keeper", Some name
    | No_assignee -> "unassigned", None | Keeper_unknown -> "unknown", None in
  ["title", nullable_text fragment.title; "assignee_state", `String assignee_state;
   "assignee", nullable_text assignee; "status", status; "completed_at", completed_at;
   "keeper_state", `String keeper_state; "keeper", nullable_text keeper_name]

let lookup_fields task_id : task_lookup -> (string * Yojson.Safe.t) list = function
  | Found found -> ["task_id", `String task_id; "state", `String "found"] @ found_detail_fields found
  | Found_uncertain found ->
    ["task_id", `String task_id; "state", `String "found_uncertain";
     "observations", `List (List.map (fun row -> `Assoc (fragment_fields row)) found)]
  | Deleted -> [ "task_id", `String task_id; "state", `String "deleted" ]
  | Unobserved -> [ "task_id", `String task_id; "state", `String "unobserved" ]
;;

let keeper_observation_json (task_id, observation) =
  let state, name = match observation with
    | Keeper_name name -> "keeper", Some name
    | Not_keeper name -> "not_keeper", Some name
    | No_assignee -> "unassigned", None
    | Keeper_unknown -> "unknown", None in
  `Assoc ["task_id", `String task_id; "state", `String state; "name", nullable_text name]
;;

let unattributed_reason_text = function
  | No_candidates -> "no_candidates"
  | All_unrelated _ -> "all_unrelated"
  | No_related_keepers _ -> "no_related_keepers"
  | Window_released -> "window_released"
;;

let attribution_fields = function
  | No_candidates | Window_released -> []
  | All_unrelated a | No_related_keepers a ->
    ["grade", `String (Candle_grade.to_string a.grade);
     "grade_trace", Candle_appraisal.trace_json a.grade_trace;
     "relations", `List (List.map Candle_appraisal.relation_json a.relations)]

let candidate_fields (c : candidate_observation) =
  [ "goal_id", `String c.goal_id
  ; "request_id", `String c.request_id
  ; "verification_run_id", `String c.verification_run_id
  ; "tasks", `List (List.map (fun (task_id, lookup) -> `Assoc (lookup_fields task_id lookup)) c.tasks)
  ; "candidate_task_ids", text_list c.candidate_task_ids
  ; "candidate_keepers", text_list c.candidate_keepers
  ; "candidate_task_keepers", `List (List.map (fun (task_id, keeper) ->
      `Assoc ["task_id", `String task_id; "keeper", nullable_text keeper]) c.candidate_task_keepers)
  ]

let body_fields : body -> (string * Yojson.Safe.t) list = function
  | Half_life_set half_life ->
    ["half_life", (match half_life with
      | Candle_decay.Off -> `String "off"
      | Candle_decay.Hours hours -> `Int hours)]
  | Snapshot s ->
    [ "goal_id", `String s.goal_id
    ; "request_id", `String s.request_id
    ; "verification_run_id", `String s.verification_run_id
    ; "criterion_revision", `String s.criterion_revision
    ; "passed_at", Candle_time.to_yojson s.passed_at
    ; "goal_created_at", Candle_time.to_yojson s.goal_created_at
    ; "due_date", nullable_text s.due_date
    ; "title", `String s.title
    ; "metric", nullable_text s.metric
    ; "target_value", nullable_text s.target_value
    ; "linked_task_ids", `List (List.map (fun id -> `String id) s.linked_task_ids)
    ]
  | Payout_owed p ->
    [ "goal_id", `String p.goal_id
    ; "request_id", `String p.request_id
    ; "verification_run_id", `String p.verification_run_id
    ; "passed_at", Candle_time.to_yojson p.passed_at
    ; "confirmed_at", Candle_time.to_yojson p.confirmed_at
    ]
  | Candidates c -> candidate_fields c
  | Candidates_fenced c -> ("observation", `String "backlog_fenced") :: candidate_fields c
  | Candidate_window_held h ->
    [ "goal_id", `String h.goal_id
    ; "request_id", `String h.request_id
    ; "verification_run_id", `String h.verification_run_id
    ; "passed_at", Candle_time.to_yojson h.passed_at
    ; "confirmed_at", Candle_time.to_yojson h.confirmed_at
    ; "tasks", `List (List.map (fun (task_id, lookup) -> `Assoc (lookup_fields task_id lookup)) h.tasks)
    ; "task_keepers", `List (List.map keeper_observation_json h.task_keepers)
    ]
  | Candidate_window_released r ->
    [ "goal_id", `String r.goal_id
    ; "request_id", `String r.request_id
    ; "verification_run_id", `String r.verification_run_id
    ]
  | Unattributed u ->
    [ "goal_id", `String u.goal_id
    ; "request_id", `String u.request_id
    ; "verification_run_id", `String u.verification_run_id
    ; "reason", `String (unattributed_reason_text u.reason)
    ] @ attribution_fields u.reason
  | Paid payment -> Candle_payment.to_fields payment
  | Equipped e ->
    [ "keeper", `String e.keeper; "slot", `String (Keeper_portrait_item.slot_id e.slot)
    ; "item", (match e.choice with Default -> `Null | Item item -> `String (Keeper_portrait_item.id item)) ]
  | Purchased p ->
    [ "keeper", `String p.keeper
    ; "item", `String (Keeper_portrait_item.id p.item)
    ; "amount_milli", `Int p.amount_milli
    ]
  | Granted g ->
    [ "keeper", `String g.keeper
    ; "amount_milli", `Int g.amount_milli
    ; "reason", `String g.reason
    ]
  | Gifted g ->
    [ "from_keeper", `String g.from_keeper
    ; "to_keeper", `String g.to_keeper
    ; "amount_milli", `Int g.amount_milli
    ; "reason", `String g.reason
    ]
  | Gifted_item g ->
    [ "from_keeper", `String g.from_keeper
    ; "to_keeper", `String g.to_keeper
    ; "item", `String (Keeper_portrait_item.id g.item)
    ]
  | Payout_failed f -> ["goal_id", `String f.goal_id; "request_id", `String f.request_id;
      "verification_run_id", `String f.verification_run_id;
      "reason", `String "unreadable_due_date"; "due_date", `String f.due_date]
;;

let to_yojson (event : t) : Yojson.Safe.t =
  `Assoc
    (("kind", `String (kind event.body))
     :: ("at", Candle_time.to_yojson event.at)
     :: body_fields event.body)
;;

let snapshot_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* goal_id, fields = field "goal_id" Candle_json.as_non_blank fields in
  let* request_id, fields = field "request_id" Candle_json.as_non_blank fields in
  let* verification_run_id, fields = field "verification_run_id" Candle_json.as_non_blank fields in
  let* criterion_revision, fields =
    field "criterion_revision" Candle_json.as_non_blank fields
  in
  let* passed_at, fields = field "passed_at" Candle_time.of_yojson fields in
  let* goal_created_at, fields = field "goal_created_at" Candle_time.of_yojson fields in
  let* due_date, fields =
    field "due_date" (Candle_json.as_nullable Candle_json.as_string) fields
  in
  let* title, fields = field "title" Candle_json.as_string fields in
  let* metric, fields =
    field "metric" (Candle_json.as_nullable Candle_json.as_string) fields
  in
  let* target_value, fields =
    field "target_value" (Candle_json.as_nullable Candle_json.as_string) fields
  in
  let* linked_task_ids, fields =
    field "linked_task_ids" (Candle_json.as_list Candle_json.as_non_blank) fields
  in
  let* () = Candle_json.finish ~context fields in
  Ok
    (Snapshot
       { goal_id
       ; request_id
       ; verification_run_id
       ; criterion_revision
       ; passed_at
       ; goal_created_at
       ; due_date
       ; title
       ; metric
       ; target_value
       ; linked_task_ids
       })
;;

let payout_owed_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* goal_id, fields = field "goal_id" Candle_json.as_non_blank fields in
  let* request_id, fields = field "request_id" Candle_json.as_non_blank fields in
  let* verification_run_id, fields = field "verification_run_id" Candle_json.as_non_blank fields in
  let* passed_at, fields = field "passed_at" Candle_time.of_yojson fields in
  let* confirmed_at, fields = field "confirmed_at" Candle_time.of_yojson fields in
  let* () = Candle_json.finish ~context fields in
  Ok (Payout_owed { goal_id; request_id; verification_run_id; passed_at; confirmed_at })
;;

let status_of_fields ~status ~completed_at =
  match status, completed_at with
  | "done", Some completed_at -> Ok (Done { completed_at })
  | "done", None -> Error "a done task has no completed_at"
  | "todo", None -> Ok Todo
  | "claimed", None -> Ok Claimed
  | "in_progress", None -> Ok In_progress
  | "awaiting_verification", None -> Ok Awaiting_verification
  | "cancelled", None -> Ok Cancelled
  | ("todo" | "claimed" | "in_progress" | "awaiting_verification" | "cancelled"), Some _ ->
    Error (Printf.sprintf "a %s task has a completed_at" status)
  | unknown, (Some _ | None) -> Error (Printf.sprintf "unknown status %S" unknown)
;;

let found_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* title, fields = field "title" Candle_json.as_string fields in
  let* assignee, fields = field "assignee" (Candle_json.as_nullable Candle_json.as_non_blank) fields in
  let* status, fields = field "status" Candle_json.as_non_blank fields in
  let* completed_at, fields = field "completed_at" (Candle_json.as_nullable Candle_time.of_yojson) fields in
  let* () = Candle_json.finish ~context fields in
  let* status = status_of_fields ~status ~completed_at in
  Ok ({ title; assignee; status } : task_found)
;;

let fragment_of_json json =
  let context = "uncertain task observation" in
  let* fields = Candle_json.object_fields ~context json in
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* title, fields = field "title" (Candle_json.as_nullable Candle_json.as_string) fields in
  let* assignee_state, fields = field "assignee_state" Candle_json.as_string fields in
  let* name, fields = field "assignee" (Candle_json.as_nullable Candle_json.as_non_blank) fields in
  let* status, fields = field "status" (Candle_json.as_nullable Candle_json.as_non_blank) fields in
  let* completed_at, fields = field "completed_at" (Candle_json.as_nullable Candle_time.of_yojson) fields in
  let* keeper_state, fields = field "keeper_state" Candle_json.as_string fields in
  let* keeper_name, fields = field "keeper" (Candle_json.as_nullable Candle_json.as_non_blank) fields in
  let* () = Candle_json.finish ~context fields in
  let* assignee = match assignee_state, name with
    | "assigned", Some name -> Ok (Assigned name)
    | "unassigned", None -> Ok Unassigned
    | "unreadable", None -> Ok Unreadable_assignee
    | _ -> Error "uncertain task observation: invalid assignee state" in
  let* status = match status, completed_at with
    | None, None -> Ok Unreadable_status
    | Some status, completed_at -> Result.map (fun status -> Observed_status status)
        (status_of_fields ~status ~completed_at)
    | None, Some _ -> Error "uncertain task observation: unreadable status has a completion time" in
  let* keeper = match assignee, keeper_state, keeper_name with
    | Assigned name, "keeper", Some actual when name = actual -> Ok (Keeper_name name)
    | Assigned name, "not_keeper", Some actual when name = actual -> Ok (Not_keeper name)
    | Assigned _, "unknown", None | Unreadable_assignee, "unknown", None -> Ok Keeper_unknown
    | Unassigned, "unassigned", None -> Ok No_assignee
    | (Assigned _ | Unassigned | Unreadable_assignee), _, _ ->
        Error "uncertain task observation: Keeper classification does not match assignee" in
  Ok ({title; assignee; status; keeper} : task_fragment)
;;

let lookup_of_json json =
  let context = "task" in
  let* fields = Candle_json.object_fields ~context json in
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* task_id, fields = field "task_id" Candle_json.as_non_blank fields in
  let* state, fields = field "state" Candle_json.as_string fields in
  match state with
  | "found" ->
    let* found = found_of_fields ~context fields in
    Ok (task_id, Found found)
  | "found_uncertain" ->
    let* observations, fields = field "observations" (Candle_json.as_list fragment_of_json) fields in
    let* () = Candle_json.finish ~context fields in
    (match observations with
     | [] -> Error "task: uncertain observation must retain at least one row"
     | _ :: _ -> Ok (task_id, Found_uncertain observations))
  | "deleted" ->
    let* () = Candle_json.finish ~context fields in
    Ok (task_id, Deleted)
  | "unobserved" ->
    let* () = Candle_json.finish ~context fields in
    Ok (task_id, Unobserved)
  | unknown -> Error (Printf.sprintf "%s: unknown state %S" context unknown)
;;

let candidate_keeper_of_json json =
  let context = "candidate Keeper eligibility" in
  let* fields = Candle_json.object_fields ~context json in
  let* task_id, fields = Candle_json.field ~context "task_id" Candle_json.as_non_blank fields in
  let* keeper, fields = Candle_json.field ~context "keeper"
    (Candle_json.as_nullable Candle_json.as_non_blank) fields in
  let* () = Candle_json.finish ~context fields in
  Ok (task_id, keeper)

let keeper_observation_of_json json =
  let context = "held Keeper observation" in
  let* fields = Candle_json.object_fields ~context json in
  let* task_id, fields = Candle_json.field ~context "task_id" Candle_json.as_non_blank fields in
  let* state, fields = Candle_json.field ~context "state" Candle_json.as_string fields in
  let* name, fields = Candle_json.field ~context "name"
    (Candle_json.as_nullable Candle_json.as_non_blank) fields in
  let* () = Candle_json.finish ~context fields in
  match state, name with
  | "keeper", Some name -> Ok (task_id, Keeper_name name)
  | "not_keeper", Some name -> Ok (task_id, Not_keeper name)
  | "unassigned", None -> Ok (task_id, No_assignee)
  | "unknown", None -> Ok (task_id, Keeper_unknown)
  | _ -> Error (Printf.sprintf "%s: invalid state and name" context)
;;

let candidates_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* fenced, fields =
    match List.partition (fun (name, _) -> String.equal name "observation") fields with
    | [], rest -> Ok (false, rest)
    | [(_, `String "backlog_fenced")], rest -> Ok (true, rest)
    | [(_ , _)], _ -> Error (context ^ ".observation: invalid observation provenance")
    | _ :: _ :: _, _ -> Error (context ^ ".observation: field appears more than once") in
  let* goal_id, fields = field "goal_id" Candle_json.as_non_blank fields in
  let* request_id, fields = field "request_id" Candle_json.as_non_blank fields in
  let* verification_run_id, fields = field "verification_run_id" Candle_json.as_non_blank fields in
  let* tasks, fields = field "tasks" (Candle_json.as_list lookup_of_json) fields in
  let* candidate_task_ids, fields =
    field "candidate_task_ids" (Candle_json.as_list Candle_json.as_non_blank) fields
  in
  let* candidate_keepers, fields =
    field "candidate_keepers" (Candle_json.as_list Candle_json.as_non_blank) fields
  in
  let* candidate_task_keepers, fields =
    field "candidate_task_keepers" (Candle_json.as_list candidate_keeper_of_json) fields in
  let* () = Candle_json.finish ~context fields in
  let observation = { goal_id; request_id; verification_run_id; tasks; candidate_task_ids; candidate_keepers; candidate_task_keepers } in
  Ok (if fenced then Candidates_fenced observation else Candidates observation)
;;

let candidate_window_held_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* goal_id, fields = field "goal_id" Candle_json.as_non_blank fields in
  let* request_id, fields = field "request_id" Candle_json.as_non_blank fields in
  let* verification_run_id, fields = field "verification_run_id" Candle_json.as_non_blank fields in
  let* passed_at, fields = field "passed_at" Candle_time.of_yojson fields in
  let* confirmed_at, fields = field "confirmed_at" Candle_time.of_yojson fields in
  let* tasks, fields = field "tasks" (Candle_json.as_list lookup_of_json) fields in
  let* task_keepers, fields = field "task_keepers" (Candle_json.as_list keeper_observation_of_json) fields in
  let* () = Candle_json.finish ~context fields in
  Ok (Candidate_window_held { goal_id; request_id; verification_run_id; passed_at; confirmed_at; tasks; task_keepers })
;;

let candidate_window_released_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* goal_id, fields = field "goal_id" Candle_json.as_non_blank fields in
  let* request_id, fields = field "request_id" Candle_json.as_non_blank fields in
  let* verification_run_id, fields = field "verification_run_id" Candle_json.as_non_blank fields in
  let* () = Candle_json.finish ~context fields in
  Ok (Candidate_window_released { goal_id; request_id; verification_run_id })
;;

let unattributed_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* goal_id, fields = field "goal_id" Candle_json.as_non_blank fields in
  let* request_id, fields = field "request_id" Candle_json.as_non_blank fields in
  let* verification_run_id, fields = field "verification_run_id" Candle_json.as_non_blank fields in
  let* reason_text, fields = field "reason" Candle_json.as_string fields in
  let attributed reason fields =
    let* grade, fields = field "grade" Candle_appraisal.grade_of_json fields in
    let* grade_trace, fields = field "grade_trace" Candle_appraisal.trace_of_json fields in
    let* relations, fields = field "relations" (Candle_json.as_list Candle_appraisal.relation_of_json) fields in
    Ok (reason {grade; grade_trace; relations}, fields)
  in
  let* reason, fields = match reason_text with
    | "no_candidates" -> Ok (No_candidates, fields)
    | "window_released" -> Ok (Window_released, fields)
    | "all_unrelated" -> attributed (fun attribution -> All_unrelated attribution) fields
    | "no_related_keepers" -> attributed (fun attribution -> No_related_keepers attribution) fields
    | _ -> Error "unknown unattributed reason" in
  let* () = Candle_json.finish ~context fields in
  Ok (Unattributed { goal_id; request_id; verification_run_id; reason })
;;

let payout_failed_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* goal_id, fields = field "goal_id" Candle_json.as_non_blank fields in
  let* request_id, fields = field "request_id" Candle_json.as_non_blank fields in
  let* verification_run_id, fields = field "verification_run_id" Candle_json.as_non_blank fields in
  let* reason, fields = field "reason" Candle_json.as_string fields in
  let* () = if reason = "unreadable_due_date" then Ok () else Error "unknown payout failure" in
  let* due_date, fields = field "due_date" Candle_json.as_string fields in
  let* () = Candle_json.finish ~context fields in
  Ok (Payout_failed {goal_id;request_id;verification_run_id;due_date})

let purchased_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* keeper, fields = field "keeper" Candle_json.as_non_blank fields in
  let* item_id, fields = field "item" Candle_json.as_string fields in
  let* item = match Keeper_portrait_item.of_id item_id with
    | Some item -> Ok item
    | None -> Error (Printf.sprintf "%s: unknown item %S" context item_id) in
  let* amount_milli, fields = field "amount_milli" Candle_appraisal.as_int fields in
  let* () = if amount_milli < 0 then Error (context ^ ": purchase amount must not be negative") else Ok () in
  let* () = Candle_json.finish ~context fields in
  Ok (Purchased { keeper; item; amount_milli })

let granted_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* keeper, fields = field "keeper" Candle_json.as_non_blank fields in
  let* amount_milli, fields = field "amount_milli" Candle_appraisal.as_int fields in
  let* reason, fields = field "reason" Candle_json.as_non_blank fields in
  let* () = if amount_milli <= 0 then Error (context ^ ": grant amount must be positive") else Ok () in
  let* () = Candle_json.finish ~context fields in
  Ok (Granted { keeper; amount_milli; reason })

let gifted_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* from_keeper, fields = field "from_keeper" Candle_json.as_non_blank fields in
  let* to_keeper, fields = field "to_keeper" Candle_json.as_non_blank fields in
  let* amount_milli, fields = field "amount_milli" Candle_appraisal.as_int fields in
  let* reason, fields = field "reason" Candle_json.as_non_blank fields in
  let* () = if amount_milli <= 0 then Error (context ^ ": gift amount must be positive") else Ok () in
  let* () =
    if String.equal from_keeper to_keeper
    then Error (context ^ ": a gift needs two keepers")
    else Ok () in
  let* () = Candle_json.finish ~context fields in
  Ok (Gifted { from_keeper; to_keeper; amount_milli; reason })

let gifted_item_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* from_keeper, fields = field "from_keeper" Candle_json.as_non_blank fields in
  let* to_keeper, fields = field "to_keeper" Candle_json.as_non_blank fields in
  let* item_id, fields = field "item" Candle_json.as_string fields in
  let* item = match Keeper_portrait_item.of_id item_id with
    | Some item -> Ok item
    | None -> Error (Printf.sprintf "%s: unknown item %S" context item_id) in
  let* () =
    if String.equal from_keeper to_keeper
    then Error (context ^ ": a gift needs two keepers")
    else Ok () in
  let* () = Candle_json.finish ~context fields in
  Ok (Gifted_item { from_keeper; to_keeper; item })

let equipped_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* keeper, fields = field "keeper" Candle_json.as_non_blank fields in
  let* slot_id, fields = field "slot" Candle_json.as_string fields in
  let* slot = match Keeper_portrait_item.slot_of_id slot_id with
    | Some slot -> Ok slot | None -> Error (context ^ ": unknown equipment slot") in
  let* item_id, fields = field "item" (Candle_json.as_nullable Candle_json.as_string) fields in
  let* choice = match item_id with
    | None -> Ok Default
    | Some id -> (match Keeper_portrait_item.of_id id with
      | Some item when Keeper_portrait_item.slot item = slot -> Ok (Item item)
      | Some _ | None -> Error (context ^ ": item does not belong to the slot")) in
  let* () = Candle_json.finish ~context fields in
  Ok (Equipped {keeper;slot;choice})

let of_yojson json =
  let context = "candle event" in
  let* fields = Candle_json.object_fields ~context json in
  let* kind_text, fields = Candle_json.field ~context "kind" Candle_json.as_string fields in
  let* at, fields = Candle_json.field ~context "at" Candle_time.of_yojson fields in
  let context = Printf.sprintf "%s %s" context kind_text in
  let* body =
    match kind_text with
    | "half_life_set" ->
      let* half_life, fields = Candle_json.field ~context "half_life"
        (function
          | `String "off" -> Ok Candle_decay.Off
          | value ->
            let* hours = Candle_appraisal.as_int value in
            Candle_decay.half_life_of_hours hours) fields in
      let* () = Candle_json.finish ~context fields in
      Ok (Half_life_set half_life)
    | "snapshot" -> snapshot_of_fields ~context fields
    | "payout_owed" -> payout_owed_of_fields ~context fields
    | "candidates" -> candidates_of_fields ~context fields
    | "candidate_window_held" -> candidate_window_held_of_fields ~context fields
    | "candidate_window_released" -> candidate_window_released_of_fields ~context fields
    | "unattributed" -> unattributed_of_fields ~context fields
    | "paid" -> Result.map (fun p -> Paid p) (Candle_payment.of_yojson (`Assoc fields))
    | "purchased" -> purchased_of_fields ~context fields
    | "granted" -> granted_of_fields ~context fields
    | "gifted" -> gifted_of_fields ~context fields
    | "gifted_item" -> gifted_item_of_fields ~context fields
    | "equipped" -> equipped_of_fields ~context fields
    | "payout_failed" -> payout_failed_of_fields ~context fields
    | unknown -> Error (Printf.sprintf "%s: unknown kind %S" context unknown)
  in
  Ok { at; body }
;;

let of_line line =
  match Yojson.Safe.from_string line with
  | exception Yojson.Json_error detail -> Error (Printf.sprintf "not JSON: %s" detail)
  | json -> of_yojson json
;;

let to_line event =
  let line = Yojson.Safe.to_string (to_yojson event) in
  Result.map (fun (_ : t) -> line) (of_line line)
;;
