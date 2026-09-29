let ( let* ) = Result.bind
let permille_scale = 1000

(* What an [Equipped] row writes in the item field to go back to the accessory
   the keeper's name gives it. It is not an item name, so it cannot collide. *)
let default_wear_wire = "default"

(* Each closed set is spelled once, in its [to_wire]; reading walks the list. *)
let find_wire ~to_wire all text =
  List.find_opt (fun value -> String.equal (to_wire value) text) all
;;

let enum_of_yojson ~what ~all ~to_wire json =
  let* text = Candle_json.as_string json in
  match find_wire ~to_wire all text with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "unknown %s %S" what text)
;;

let nullable to_json = function
  | None -> `Null
  | Some value -> to_json value
;;

let text value = `String value

type grade =
  | Trivial
  | Small
  | Medium
  | Large
  | Epic

let grades = [ Trivial; Small; Medium; Large; Epic ]

let grade_to_wire = function
  | Trivial -> "trivial"
  | Small -> "small"
  | Medium -> "medium"
  | Large -> "large"
  | Epic -> "epic"
;;

let grade_of_wire wire = find_wire ~to_wire:grade_to_wire grades wire

type due =
  | No_due
  | Due_date of Candle_time.Date.t
  | Unreadable_due of string

let due_to_yojson : due -> Yojson.Safe.t = function
  | No_due -> `Assoc [ "state", `String "none" ]
  | Due_date date ->
    `Assoc [ "state", `String "date"; "date", Candle_time.Date.to_yojson date ]
  | Unreadable_due raw -> `Assoc [ "state", `String "unreadable"; "raw", `String raw ]
;;

let due_of_yojson json =
  let context = "due" in
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* fields = Candle_json.object_fields ~context json in
  let* state, fields = field "state" Candle_json.as_string fields in
  match state with
  | "none" ->
    let* () = Candle_json.finish ~context fields in
    Ok No_due
  | "date" ->
    let* date, fields = field "date" Candle_time.Date.of_yojson fields in
    let* () = Candle_json.finish ~context fields in
    Ok (Due_date date)
  | "unreadable" ->
    let* raw, fields = field "raw" Candle_json.as_string fields in
    let* () = Candle_json.finish ~context fields in
    Ok (Unreadable_due raw)
  | other -> Error (Printf.sprintf "%s: unknown state %S" context other)
;;

type task_state =
  | Todo
  | Claimed
  | In_progress
  | Awaiting_verification
  | Done
  | Cancelled

let task_states = [ Todo; Claimed; In_progress; Awaiting_verification; Done; Cancelled ]

let task_state_to_wire = function
  | Todo -> "todo"
  | Claimed -> "claimed"
  | In_progress -> "in_progress"
  | Awaiting_verification -> "awaiting_verification"
  | Done -> "done"
  | Cancelled -> "cancelled"
;;

type task_row =
  { task_id : string
  ; title : string
  ; assignee : Candle_keeper.t option
  ; state : task_state
  ; completed_at : Candle_time.t option
  }

let task_row_to_yojson (row : task_row) : Yojson.Safe.t =
  `Assoc
    [ "task_id", `String row.task_id
    ; "title", `String row.title
    ; "assignee", nullable Candle_keeper.to_yojson row.assignee
    ; "state", `String (task_state_to_wire row.state)
    ; "completed_at", nullable Candle_time.to_yojson row.completed_at
    ]
;;

let task_row_of_yojson json =
  let context = "task" in
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* fields = Candle_json.object_fields ~context json in
  let* task_id, fields = field "task_id" Candle_json.as_non_blank fields in
  let* title, fields = field "title" Candle_json.as_string fields in
  let* assignee, fields =
    field "assignee" (Candle_json.as_nullable Candle_keeper.of_yojson) fields
  in
  let* state, fields =
    field
      "state"
      (enum_of_yojson ~what:"task state" ~all:task_states ~to_wire:task_state_to_wire)
      fields
  in
  let* completed_at, fields =
    field "completed_at" (Candle_json.as_nullable Candle_time.of_yojson) fields
  in
  let* () = Candle_json.finish ~context fields in
  Ok { task_id; title; assignee; state; completed_at }
;;

type payout_line =
  { keeper : Candle_keeper.t
  ; weight : int
  ; share : Candle_milli.t
  ; coefficient_permille : int
  ; amount : Candle_milli.t
  }

let payout_line_to_yojson (line : payout_line) : Yojson.Safe.t =
  `Assoc
    [ "keeper", Candle_keeper.to_yojson line.keeper
    ; "weight", `Int line.weight
    ; "share_milli", Candle_milli.to_yojson line.share
    ; "coefficient_permille", `Int line.coefficient_permille
    ; "amount_milli", Candle_milli.to_yojson line.amount
    ]
;;

let payout_line_of_yojson json =
  let context = "payout line" in
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* fields = Candle_json.object_fields ~context json in
  let* keeper, fields = field "keeper" Candle_keeper.of_yojson fields in
  let* weight, fields = field "weight" Candle_json.as_int fields in
  let* share, fields = field "share_milli" Candle_milli.of_yojson fields in
  let* coefficient_permille, fields =
    field "coefficient_permille" Candle_json.as_int fields
  in
  let* amount, fields = field "amount_milli" Candle_milli.of_yojson fields in
  let* () = Candle_json.finish ~context fields in
  Ok { keeper; weight; share; coefficient_permille; amount }
;;

type deduction =
  { clock : Candle_time.t
  ; due : due
  ; rate_permille : int
  ; floor_permille : int
  }

let deduction_to_yojson (deduction : deduction) : Yojson.Safe.t =
  `Assoc
    [ "clock", Candle_time.to_yojson deduction.clock
    ; "due", due_to_yojson deduction.due
    ; "rate_permille", `Int deduction.rate_permille
    ; "floor_permille", `Int deduction.floor_permille
    ]
;;

let deduction_of_yojson json =
  let context = "deduction" in
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* fields = Candle_json.object_fields ~context json in
  let* clock, fields = field "clock" Candle_time.of_yojson fields in
  let* due, fields = field "due" due_of_yojson fields in
  let* rate_permille, fields = field "rate_permille" Candle_json.as_int fields in
  let* floor_permille, fields = field "floor_permille" Candle_json.as_int fields in
  let* () = Candle_json.finish ~context fields in
  Ok { clock; due; rate_permille; floor_permille }
;;

type paid =
  { goal_id : string
  ; request_id : string
  ; grade : grade
  ; total : Candle_milli.t
  ; lane_slot : string
  ; lines : payout_line list
  ; deduction : deduction
  }

let require_non_blank name value =
  if String.equal (String.trim value) "" then Error (name ^ " is blank") else Ok ()
;;

let rec has_adjacent_duplicate = function
  | first :: (second :: _ as rest) ->
    Candle_keeper.equal first second || has_adjacent_duplicate rest
  | [] | [ _ ] -> false
;;

let check_line (line : payout_line) =
  let keeper = Candle_keeper.to_string line.keeper in
  if line.weight < 0
  then Error (Printf.sprintf "%s: weight %d is negative" keeper line.weight)
  else if line.coefficient_permille < 0 || line.coefficient_permille > permille_scale
  then
    Error
      (Printf.sprintf
         "%s: coefficient_permille %d is outside 0..%d"
         keeper
         line.coefficient_permille
         permille_scale)
  else if Candle_milli.compare line.amount line.share > 0
  then Error (Printf.sprintf "%s: amount is more than the share" keeper)
  else Ok ()
;;

let rec check_lines = function
  | [] -> Ok ()
  | line :: rest ->
    let* () = check_line line in
    check_lines rest
;;

let make_paid ~goal_id ~request_id ~grade ~total ~lane_slot ~lines ~deduction =
  let* () = require_non_blank "goal_id" goal_id in
  let* () = require_non_blank "request_id" request_id in
  let* () = require_non_blank "lane_slot" lane_slot in
  let* () =
    match lines with
    | [] -> Error "a payout has no lines"
    | _ :: _ -> Ok ()
  in
  let* () = check_lines lines in
  let* () =
    let keepers = List.map (fun (line : payout_line) -> line.keeper) lines in
    if has_adjacent_duplicate (List.sort Candle_keeper.compare keepers)
    then Error "a keeper is on more than one line"
    else Ok ()
  in
  let* issued =
    Candle_milli.sum (List.map (fun (line : payout_line) -> line.share) lines)
    |> Result.map_error Candle_milli.error_to_string
  in
  let* () =
    if Candle_milli.compare issued total > 0
    then Error "the shares add up to more than the total"
    else Ok ()
  in
  let* () =
    if deduction.rate_permille < 0
    then Error (Printf.sprintf "rate_permille %d is negative" deduction.rate_permille)
    else if deduction.floor_permille < 0 || deduction.floor_permille > permille_scale
    then
      Error
        (Printf.sprintf
           "floor_permille %d is outside 0..%d"
           deduction.floor_permille
           permille_scale)
    else Ok ()
  in
  Ok { goal_id; request_id; grade; total; lane_slot; lines; deduction }
;;

type failure_reason = Due_unreadable

let failure_reasons = [ Due_unreadable ]
let failure_reason_to_wire = function Due_unreadable -> "due_unreadable"

type unattributed_reason =
  | No_candidate
  | Lane_judged_no_contributor

let unattributed_reasons = [ No_candidate; Lane_judged_no_contributor ]

let unattributed_reason_to_wire = function
  | No_candidate -> "no_candidate"
  | Lane_judged_no_contributor -> "lane_judged_no_contributor"
;;

type body =
  | Snapshot of
      { goal_id : string
      ; request_id : string
      ; criterion_revision : string
      ; passed_at : Candle_time.t
      ; goal_created_at : Candle_time.t
      ; due : due
      ; title : string
      ; metric : string option
      ; target_value : string option
      ; linked_task_ids : string list
      }
  | Payout_owed of
      { goal_id : string
      ; request_id : string
      ; passed_at : Candle_time.t
      ; tasks : task_row list
      ; candidates : Candle_keeper.t list
      }
  | Payout_failed of
      { goal_id : string
      ; request_id : string
      ; reason : failure_reason
      }
  | Paid of paid
  | Unattributed of
      { goal_id : string
      ; reason : unattributed_reason
      }
  | Purchased of
      { keeper : Candle_keeper.t
      ; item : Candle_item.t
      ; cost : Candle_milli.t
      }
  | Equipped of
      { keeper : Candle_keeper.t
      ; wear : Candle_item.wear
      }

type t =
  { at : Candle_time.t
  ; body : body
  }

let kind = function
  | Snapshot _ -> "snapshot"
  | Payout_owed _ -> "payout_owed"
  | Payout_failed _ -> "payout_failed"
  | Paid _ -> "paid"
  | Unattributed _ -> "unattributed"
  | Purchased _ -> "purchased"
  | Equipped _ -> "equipped"
;;

let wear_item_wire = function
  | Candle_item.Wear item -> Candle_item.to_wire item
  | Candle_item.Default _ -> default_wear_wire
;;

let body_fields : body -> (string * Yojson.Safe.t) list = function
  | Snapshot s ->
    [ "goal_id", `String s.goal_id
    ; "request_id", `String s.request_id
    ; "criterion_revision", `String s.criterion_revision
    ; "passed_at", Candle_time.to_yojson s.passed_at
    ; "goal_created_at", Candle_time.to_yojson s.goal_created_at
    ; "due", due_to_yojson s.due
    ; "title", `String s.title
    ; "metric", nullable text s.metric
    ; "target_value", nullable text s.target_value
    ; "linked_task_ids", `List (List.map text s.linked_task_ids)
    ]
  | Payout_owed o ->
    [ "goal_id", `String o.goal_id
    ; "request_id", `String o.request_id
    ; "passed_at", Candle_time.to_yojson o.passed_at
    ; "tasks", `List (List.map task_row_to_yojson o.tasks)
    ; "candidates", `List (List.map Candle_keeper.to_yojson o.candidates)
    ]
  | Payout_failed f ->
    [ "goal_id", `String f.goal_id
    ; "request_id", `String f.request_id
    ; "reason", `String (failure_reason_to_wire f.reason)
    ]
  | Paid p ->
    [ "goal_id", `String p.goal_id
    ; "request_id", `String p.request_id
    ; "grade", `String (grade_to_wire p.grade)
    ; "total_milli", Candle_milli.to_yojson p.total
    ; "lane_slot", `String p.lane_slot
    ; "lines", `List (List.map payout_line_to_yojson p.lines)
    ; "deduction", deduction_to_yojson p.deduction
    ]
  | Unattributed u ->
    [ "goal_id", `String u.goal_id
    ; "reason", `String (unattributed_reason_to_wire u.reason)
    ]
  | Purchased p ->
    [ "keeper", Candle_keeper.to_yojson p.keeper
    ; "item", `String (Candle_item.to_wire p.item)
    ; "cost_milli", Candle_milli.to_yojson p.cost
    ]
  | Equipped e ->
    [ "keeper", Candle_keeper.to_yojson e.keeper
    ; "slot", `String (Candle_item.slot_to_wire (Candle_item.wear_slot e.wear))
    ; "item", `String (wear_item_wire e.wear)
    ]
;;

let to_yojson (event : t) : Yojson.Safe.t =
  `Assoc
    (("kind", `String (kind event.body))
     :: ("at", Candle_time.to_yojson event.at)
     :: body_fields event.body)
;;

let item_of_yojson json =
  let* wire = Candle_json.as_string json in
  match Candle_item.of_wire wire with
  | Some item -> Ok item
  | None -> Error (Printf.sprintf "unknown item %S" wire)
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
  let* due, fields = field "due" due_of_yojson fields in
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
       ; due
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
  let* tasks, fields = field "tasks" (Candle_json.as_list task_row_of_yojson) fields in
  let* candidates, fields =
    field "candidates" (Candle_json.as_list Candle_keeper.of_yojson) fields
  in
  let* () = Candle_json.finish ~context fields in
  Ok (Payout_owed { goal_id; request_id; passed_at; tasks; candidates })
;;

let payout_failed_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* goal_id, fields = field "goal_id" Candle_json.as_non_blank fields in
  let* request_id, fields = field "request_id" Candle_json.as_non_blank fields in
  let* reason, fields =
    field
      "reason"
      (enum_of_yojson
         ~what:"failure reason"
         ~all:failure_reasons
         ~to_wire:failure_reason_to_wire)
      fields
  in
  let* () = Candle_json.finish ~context fields in
  Ok (Payout_failed { goal_id; request_id; reason })
;;

let paid_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* goal_id, fields = field "goal_id" Candle_json.as_non_blank fields in
  let* request_id, fields = field "request_id" Candle_json.as_non_blank fields in
  let* grade, fields =
    field
      "grade"
      (enum_of_yojson ~what:"grade" ~all:grades ~to_wire:grade_to_wire)
      fields
  in
  let* total, fields = field "total_milli" Candle_milli.of_yojson fields in
  let* lane_slot, fields = field "lane_slot" Candle_json.as_non_blank fields in
  let* lines, fields = field "lines" (Candle_json.as_list payout_line_of_yojson) fields in
  let* deduction, fields = field "deduction" deduction_of_yojson fields in
  let* () = Candle_json.finish ~context fields in
  let* paid =
    make_paid ~goal_id ~request_id ~grade ~total ~lane_slot ~lines ~deduction
    |> Result.map_error (Printf.sprintf "%s: %s" context)
  in
  Ok (Paid paid)
;;

let unattributed_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* goal_id, fields = field "goal_id" Candle_json.as_non_blank fields in
  let* reason, fields =
    field
      "reason"
      (enum_of_yojson
         ~what:"unattributed reason"
         ~all:unattributed_reasons
         ~to_wire:unattributed_reason_to_wire)
      fields
  in
  let* () = Candle_json.finish ~context fields in
  Ok (Unattributed { goal_id; reason })
;;

let purchased_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* keeper, fields = field "keeper" Candle_keeper.of_yojson fields in
  let* item, fields = field "item" item_of_yojson fields in
  let* cost, fields = field "cost_milli" Candle_milli.of_yojson fields in
  let* () = Candle_json.finish ~context fields in
  Ok (Purchased { keeper; item; cost })
;;

let equipped_of_fields ~context fields =
  let field key decode fields = Candle_json.field ~context key decode fields in
  let* keeper, fields = field "keeper" Candle_keeper.of_yojson fields in
  let* slot, fields =
    field
      "slot"
      (fun json ->
        let* wire = Candle_json.as_string json in
        match Candle_item.slot_of_wire wire with
        | Some slot -> Ok slot
        | None -> Error (Printf.sprintf "unknown slot %S" wire))
      fields
  in
  let* item, fields = field "item" Candle_json.as_string fields in
  let* () = Candle_json.finish ~context fields in
  let* wear =
    if String.equal item default_wear_wire
    then Ok (Candle_item.Default slot)
    else (
      match Candle_item.of_wire item with
      | None -> Error (Printf.sprintf "%s: unknown item %S" context item)
      | Some worn when Candle_item.slot_equal (Candle_item.slot worn) slot ->
        Ok (Candle_item.Wear worn)
      | Some worn ->
        Error
          (Printf.sprintf
             "%s: item %S is a %s item, not a %s item"
             context
             item
             (Candle_item.slot_to_wire (Candle_item.slot worn))
             (Candle_item.slot_to_wire slot)))
  in
  Ok (Equipped { keeper; wear })
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
    | "payout_failed" -> payout_failed_of_fields ~context fields
    | "paid" -> paid_of_fields ~context fields
    | "unattributed" -> unattributed_of_fields ~context fields
    | "purchased" -> purchased_of_fields ~context fields
    | "equipped" -> equipped_of_fields ~context fields
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
