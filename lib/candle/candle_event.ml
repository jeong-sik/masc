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

type body =
  | Snapshot of
      { goal_id : string
      ; request_id : string
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
      ; passed_at : Candle_time.t
      ; confirmed_at : Candle_time.t
      }

type t =
  { at : Candle_time.t
  ; body : body
  }

let kind = function
  | Snapshot _ -> "snapshot"
  | Payout_owed _ -> "payout_owed"
;;

let nullable_text = function
  | None -> `Null
  | Some value -> `String value
;;

let body_fields : body -> (string * Yojson.Safe.t) list = function
  | Snapshot s ->
    [ "goal_id", `String s.goal_id
    ; "request_id", `String s.request_id
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
    ; "passed_at", Candle_time.to_yojson p.passed_at
    ; "confirmed_at", Candle_time.to_yojson p.confirmed_at
    ]
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
  let* passed_at, fields = field "passed_at" Candle_time.of_yojson fields in
  let* confirmed_at, fields = field "confirmed_at" Candle_time.of_yojson fields in
  let* () = Candle_json.finish ~context fields in
  Ok (Payout_owed { goal_id; request_id; passed_at; confirmed_at })
;;

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
