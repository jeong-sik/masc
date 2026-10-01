let ( let* ) = Result.bind

type task_status =
  | Todo
  | Claimed
  | In_progress
  | Awaiting_verification
  | Done of { completed_at : Candle_time.t }
  | Cancelled

type task_lookup =
  | Found of
      { title : string
      ; assignee : string option
      ; status : task_status
      }
  | Deleted

type attribution = {
  grade : Candle_grade.t;
  grade_trace : Candle_appraisal.trace;
  relations : Candle_appraisal.task_relation list;
}
type unattributed_reason = No_candidates | All_unrelated of attribution | No_related_keepers of attribution

type equipment_choice = Default | Item of Keeper_portrait_item.t

type body =
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
  | Candidates of
      { goal_id : string
      ; request_id : string
      ; verification_run_id : string
      ; tasks : (string * task_lookup) list
      ; candidate_task_ids : string list
      ; candidate_keepers : string list
      }
  | Unattributed of
      { goal_id : string
      ; request_id : string
      ; verification_run_id : string
      ; reason : unattributed_reason
      }
  | Paid of Candle_payment.t
  | Purchased of { keeper : string; item : Keeper_portrait_item.t; amount_milli : int }
  | Equipped of { keeper : string; slot : Keeper_portrait_item.slot; choice : equipment_choice }
  | Payout_failed of { goal_id : string; request_id : string; verification_run_id : string; due_date : string }

type t =
  { at : Candle_time.t
  ; body : body
  }

let kind = function
  | Snapshot _ -> "snapshot"
  | Payout_owed _ -> "payout_owed"
  | Candidates _ -> "candidates"
  | Unattributed _ -> "unattributed"
  | Paid _ -> "paid"
  | Purchased _ -> "purchased"
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

let lookup_fields task_id : task_lookup -> (string * Yojson.Safe.t) list = function
  | Found found ->
    [ "task_id", `String task_id
    ; "state", `String "found"
    ; "title", `String found.title
    ; "assignee", nullable_text found.assignee
    ; "status", `String (status_text found.status)
    ; "completed_at", completed_at_json found.status
    ]
  | Deleted -> [ "task_id", `String task_id; "state", `String "deleted" ]
;;

let unattributed_reason_text = function
  | No_candidates -> "no_candidates"
  | All_unrelated _ -> "all_unrelated"
  | No_related_keepers _ -> "no_related_keepers"
;;

let attribution_fields = function
  | No_candidates -> []
  | All_unrelated a | No_related_keepers a ->
    ["grade", `String (Candle_grade.to_string a.grade);
     "grade_trace", Candle_appraisal.trace_json a.grade_trace;
     "relations", `List (List.map Candle_appraisal.relation_json a.relations)]

let body_fields : body -> (string * Yojson.Safe.t) list = function
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
  | Candidates c ->
    [ "goal_id", `String c.goal_id
    ; "request_id", `String c.request_id
    ; "verification_run_id", `String c.verification_run_id
    ; ( "tasks"
      , `List (List.map (fun (task_id, lookup) -> `Assoc (lookup_fields task_id lookup)) c.tasks) )
    ; "candidate_task_ids", text_list c.candidate_task_ids
    ; "candidate_keepers", text_list c.candidate_keepers
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

let lookup_of_json json =
  let context = "task" in
  let* fields = Candle_json.object_fields ~context json in
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* task_id, fields = field "task_id" Candle_json.as_non_blank fields in
  let* state, fields = field "state" Candle_json.as_string fields in
  match state with
  | "found" ->
    let* title, fields = field "title" Candle_json.as_string fields in
    let* assignee, fields =
      field "assignee" (Candle_json.as_nullable Candle_json.as_non_blank) fields
    in
    let* status, fields = field "status" Candle_json.as_non_blank fields in
    let* completed_at, fields =
      field "completed_at" (Candle_json.as_nullable Candle_time.of_yojson) fields
    in
    let* () = Candle_json.finish ~context fields in
    let* status =
      Result.map_error
        (Printf.sprintf "%s %s: %s" context task_id)
        (status_of_fields ~status ~completed_at)
    in
    Ok (task_id, Found { title; assignee; status })
  | "deleted" ->
    let* () = Candle_json.finish ~context fields in
    Ok (task_id, Deleted)
  | unknown -> Error (Printf.sprintf "%s: unknown state %S" context unknown)
;;

let candidates_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
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
  let* () = Candle_json.finish ~context fields in
  Ok (Candidates { goal_id; request_id; verification_run_id; tasks; candidate_task_ids; candidate_keepers })
;;

let unattributed_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* goal_id, fields = field "goal_id" Candle_json.as_non_blank fields in
  let* request_id, fields = field "request_id" Candle_json.as_non_blank fields in
  let* verification_run_id, fields = field "verification_run_id" Candle_json.as_non_blank fields in
  let* reason_text, fields = field "reason" Candle_json.as_string fields in
  let* reason, fields = match reason_text with
    | "no_candidates" -> Ok (No_candidates, fields)
    | "all_unrelated" | "no_related_keepers" ->
      let* grade, fields = field "grade" Candle_appraisal.grade_of_json fields in
      let* grade_trace, fields = field "grade_trace" Candle_appraisal.trace_of_json fields in
      let* relations, fields = field "relations" (Candle_json.as_list Candle_appraisal.relation_of_json) fields in
      let attribution = {grade; grade_trace; relations} in
      Ok ((if reason_text = "all_unrelated" then All_unrelated attribution else No_related_keepers attribution), fields)
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
    | "snapshot" -> snapshot_of_fields ~context fields
    | "payout_owed" -> payout_owed_of_fields ~context fields
    | "candidates" -> candidates_of_fields ~context fields
    | "unattributed" -> unattributed_of_fields ~context fields
    | "paid" -> Result.map (fun p -> Paid p) (Candle_payment.of_yojson (`Assoc fields))
    | "purchased" -> purchased_of_fields ~context fields
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
