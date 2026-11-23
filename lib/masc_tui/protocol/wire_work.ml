open Masc_tui_core
open Json_decode_fields
open Wire_common

let ( let* ) = Result.bind

let planning_path = "/api/v1/dashboard/planning"
let execution_tasks_path = "/api/v1/dashboard/execution?light=true"
let goals_path = "/api/v1/dashboard/goals"
let goal_confirmation_path = "/api/v1/goals/confirmation"

let verification_requests_path ~view ~limit ~offset =
  Printf.sprintf "/api/v1/verification/requests?view=%s&limit=%d&offset=%d"
    (percent_encode view) (max 1 limit) (max 0 offset)

let verification_verdict_path = "/api/v1/verification/verdict"

let schedules_path ?cursor () =
  match cursor with
  | None -> "/api/v1/dashboard/scheduled-automation"
  | Some c ->
      "/api/v1/dashboard/scheduled-automation?cursor=" ^ percent_encode c

let keeper_asks_path ?keeper ?(include_resolved = false) () =
  let params =
    (match keeper with
    | None -> []
    | Some k -> [ "name=" ^ percent_encode k ])
    @ [ Printf.sprintf "include_resolved=%b" include_resolved ]
  in
  "/api/v1/keepers/asks?" ^ String.concat "&" params

let keeper_ask_answer_path = "/api/v1/keepers/ask-answer"
let keeper_tool_approvals_path = "/api/v1/keepers/tool-approvals"
let keeper_tool_approval_path = "/api/v1/keepers/tool-approval"
let gate_path = "/api/v1/dashboard/gate"

let candle_ledger_path ?limit () =
  match limit with
  | None -> "/api/v1/candle/ledger"
  | Some n -> Printf.sprintf "/api/v1/candle/ledger?limit=%d" (max 1 n)

type goal_resumable =
  | Resume_executing
  | Resume_verifying
  | Resume_awaiting_confirmation

type goal_phase =
  | Executing
  | Verifying
  | Awaiting_confirmation
  | Completed
  | Dropped
  | Paused of goal_resumable
  | Blocked of goal_resumable

type goal_action =
  | Request_complete
  | Drop
  | Reopen
  | Pause
  | Resume
  | Block
  | Unblock

type goal_criterion_verdict =
  | Criterion_pending
  | Criterion_valid
  | Criterion_invalid of string
  | Criterion_unavailable of string

type goal = {
  id : string;
  title : string;
  phase : goal_phase;
  priority : int;
  due_date : string option;
  measure : string;
  procedure : string;
  criterion_revision : string option;
  criterion_verdict : goal_criterion_verdict;
  last_review_note : string option;
  last_review_at : string option;
  created_at : string option;
  updated_at : string option;
  linked_task_count : int Observed.t;
}

type expected_workspace = {
  base_path : string;
  masc_root : string;
}

type goal_confirmation_request = {
  goal_id : string;
  criterion_revision : string;
  request_id : string;
  verification_run_id : string;
  expected_workspace : expected_workspace;
  expected_operator_id : string;
  expected_runtime_instance_id : string;
}

let goal_phase_to_string = function
  | Executing -> "executing"
  | Verifying -> "verifying"
  | Awaiting_confirmation -> "awaiting_confirmation"
  | Completed -> "completed"
  | Dropped -> "dropped"
  | Paused _ -> "paused"
  | Blocked _ -> "blocked"

let goal_action_to_string = function
  | Request_complete -> "request_complete"
  | Drop -> "drop"
  | Reopen -> "reopen"
  | Pause -> "pause"
  | Resume -> "resume"
  | Block -> "block"
  | Unblock -> "unblock"

let resumable_of_string = function
  | "executing" -> Some Resume_executing
  | "verifying" -> Some Resume_verifying
  | "awaiting_confirmation" -> Some Resume_awaiting_confirmation
  | _ -> None

let decode_goal_phase json =
  let* () = reject_forbidden_field json "status" ~context:"goal" in
  let* raw_phase = required_nonblank_string json "phase" in
  let resume_val = member "resume_phase" json in
  match (String.lowercase_ascii raw_phase, resume_val) with
  | ("paused" | "blocked") as kind, `String target -> (
      match resumable_of_string (String.lowercase_ascii (String.trim target)) with
      | None ->
          Error
            (Printf.sprintf "suspended goal requires live resume_phase, got %S"
               target)
      | Some r ->
          Ok (if String.equal kind "paused" then Paused r else Blocked r))
  | ("paused" | "blocked"), _ ->
      Error "suspended goal requires string resume_phase"
  | "executing", `Null -> Ok Executing
  | "verifying", `Null -> Ok Verifying
  | "awaiting_confirmation", `Null -> Ok Awaiting_confirmation
  | "completed", `Null -> Ok Completed
  | "dropped", `Null -> Ok Dropped
  | ("executing" | "verifying" | "awaiting_confirmation" | "completed" | "dropped"), _ ->
      Error "only paused or blocked goals may carry resume_phase"
  | other, _ -> Error (Printf.sprintf "unknown goal phase %S" other)

let decode_criterion_review json =
  match member "criterion_review" json with
  | `Null -> Ok Criterion_pending
  | `Assoc _ as cr -> (
      let* state_str =
        if has_field cr "state" then required_nonblank_string cr "state"
        else required_nonblank_string cr "status"
      in
      let first_note keys fallback =
        let rec pick = function
          | [] -> Ok fallback
          | key :: rest -> (
              match optional_nonblank_string cr key with
              | Ok (Some s) -> Ok s
              | Ok None -> pick rest
              | Error _ as err -> err)
        in
        pick keys
      in
      match String.lowercase_ascii state_str with
      | "unchecked"
      | "pending"
      | "reviewing"
      | "execution_pending"
      | "judgment_pending"
      | "deferred"
      | "superseded" ->
          Ok Criterion_pending
      | "viable" | "valid" | "approved" | "pass" | "passed" ->
          Ok Criterion_valid
      | "needs_revision" | "invalid" | "rejected" | "fail" | "failed" ->
          let* reason = first_note [ "reason"; "detail" ] "criterion rejected" in
          Ok (Criterion_invalid reason)
      | "unavailable" | "execution_unknown" ->
          let* detail = first_note [ "detail"; "reason" ] "unavailable" in
          Ok (Criterion_unavailable detail)
      | other ->
          Error (Printf.sprintf "unknown criterion_review state %S" other))
  | bad -> field_type_error "criterion_review" "an object or null" bad

let format_measure_float f =
  if Float.is_integer f && Float.abs f < 1e15 then
    Printf.sprintf "%.0f" f
  else Printf.sprintf "%.6g" f

let decode_measure json =
  match required_member json "measure" with
  | Error _ as err -> err
  | Ok (`String s) ->
      if String.equal (String.trim s) "" then
        Error "goal measure must not be empty"
      else Ok s
  | Ok (`Assoc _ as obj) -> (
      match optional_nonblank_string obj "description" with
      | Ok (Some d) -> Ok d
      | Error _ as err -> err
      | Ok None -> (
          match optional_nonblank_string obj "kind" with
          | Error _ as err -> err
          | Ok (Some kind) -> (
              match String.lowercase_ascii kind with
              | "count" -> (
                  let* noun = optional_nonblank_string obj "noun" in
                  let total =
                    match member "total" obj with
                    | `Int n -> Some n
                    | `Float f when Float.is_finite f -> Some (int_of_float f)
                    | `Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ ->
                        None
                  in
                  match total, noun with
                  | Some n, Some u -> Ok (Printf.sprintf "%d %s" n u)
                  | Some n, None -> Ok (Printf.sprintf "%d count" n)
                  | None, Some u -> Ok u
                  | None, None -> Ok kind)
              | "quantity" -> (
                  let* unit_opt = optional_nonblank_string obj "unit" in
                  let* dir_opt = optional_nonblank_string obj "direction" in
                  let* target_opt = optional_finite_float obj "target" in
                  let dir_sym =
                    match Option.map String.lowercase_ascii dir_opt with
                    | Some "at_least" -> ">="
                    | Some "at_most" -> "<="
                    | Some d -> d
                    | None -> ""
                  in
                  match target_opt, unit_opt with
                  | Some t, Some u ->
                      let num = format_measure_float t in
                      if String.equal dir_sym "" then
                        Ok (Printf.sprintf "%s %s" num u)
                      else Ok (Printf.sprintf "%s %s %s" dir_sym num u)
                  | Some t, None ->
                      let num = format_measure_float t in
                      if String.equal dir_sym "" then Ok num
                      else Ok (Printf.sprintf "%s %s" dir_sym num)
                  | None, Some u -> Ok u
                  | None, None -> Ok kind)
              | "done_when" -> (
                  match optional_nonblank_string obj "condition" with
                  | Ok (Some cond) -> Ok cond
                  | Ok None -> Ok kind
                  | Error _ as err -> err)
              | _ -> Ok kind)
          | Ok None -> Ok (Yojson.Safe.to_string obj)))
  | Ok bad -> field_type_error "measure" "a string or measure object" bad

let decode_goal ~observed_at json =
  let* () = reject_forbidden_field json "status" ~context:"goal" in
  let* id = required_nonblank_string json "id" in
  let* title = required_nonblank_string json "title" in
  let* phase = decode_goal_phase json in
  let* priority = required_int_field json "priority" in
  let* due_date = optional_nonblank_string json "due_date" in
  let* measure = decode_measure json in
  let* procedure = required_nonblank_string json "procedure" in
  let* criterion_revision = optional_nonblank_string json "criterion_revision" in
  let* criterion_verdict = decode_criterion_review json in
  let* last_review_note = optional_nonblank_string json "last_review_note" in
  let* last_review_at = optional_nonblank_string json "last_review_at" in
  let* created_at = optional_nonblank_string json "created_at" in
  let* updated_at = optional_nonblank_string json "updated_at" in
  let* linked_task_count =
    observed_int ~observed_at json "linked_task_count"
  in
  Ok
    {
      id;
      title;
      phase;
      priority;
      due_date;
      measure;
      procedure;
      criterion_revision;
      criterion_verdict;
      last_review_note;
      last_review_at;
      created_at;
      updated_at;
      linked_task_count;
    }

let encode_expected_workspace (ws : expected_workspace) =
  `Assoc
    [ ("base_path", `String ws.base_path); ("masc_root", `String ws.masc_root) ]

let encode_goal_transition ~goal_id ~action ~note =
  let base =
    [
      ("goal_id", `String goal_id);
      ("action", `String (goal_action_to_string action));
    ]
  in
  let fields =
    match note with
    | None -> base
    | Some n -> base @ [ ("note", `String n) ]
  in
  `Assoc fields

let encode_goal_confirmation (req : goal_confirmation_request) =
  (* Exact 7-field allowlist enforced by [server_routes_http_routes_verification.ml:204]. *)
  `Assoc
    [
      ("goal_id", `String req.goal_id);
      ("criterion_revision", `String req.criterion_revision);
      ("request_id", `String req.request_id);
      ("verification_run_id", `String req.verification_run_id);
      ("expected_workspace", encode_expected_workspace req.expected_workspace);
      ("expected_operator_id", `String req.expected_operator_id);
      ("expected_runtime_instance_id", `String req.expected_runtime_instance_id);
    ]

type task_status =
  | Todo
  | Claimed of { assignee : string; claimed_at : string }
  | InProgress of { assignee : string; started_at : string }
  | AwaitingVerification of {
      assignee : string;
      started_at : string;
      submitted_at : string;
      verification_id : string;
    }
  | Done of {
      assignee : string;
      completed_at : string;
      notes : string option;
    }
  | Cancelled of {
      cancelled_by : string;
      cancelled_at : string;
      reason : string option;
    }

type task_goal_link =
  | Unlinked
  | Linked of string

type task = {
  id : string;
  title : string;
  description : string option;
  priority : int;
  status : task_status;
  goal_link : task_goal_link;
  created_at : string option;
  updated_at : string option;
}

type planning_snapshot = {
  goals : goal list;
  tasks : task list;
}

type task_backlog_counts = {
  todo : int;
  claimed : int;
  in_progress : int;
  awaiting_verification : int;
  done_total : int;
  cancelled : int;
}

let decode_task_status_fields kind obj =
  match String.lowercase_ascii kind with
  | "todo" -> Ok Todo
  | "claimed" ->
      let* assignee = required_string_field obj "assignee" in
      let* claimed_at = required_nonblank_string obj "claimed_at" in
      Ok (Claimed { assignee; claimed_at })
  | "in_progress" | "inprogress" ->
      let* assignee = required_string_field obj "assignee" in
      let* started_at = required_nonblank_string obj "started_at" in
      Ok (InProgress { assignee; started_at })
  | "awaiting_verification" | "awaitingverification" ->
      let* assignee = required_string_field obj "assignee" in
      let* started_at = required_nonblank_string obj "started_at" in
      let* submitted_at = required_nonblank_string obj "submitted_at" in
      let* verification_id = required_nonblank_string obj "verification_id" in
      Ok
        (AwaitingVerification
           { assignee; started_at; submitted_at; verification_id })
  | "done" ->
      let* assignee = required_string_field obj "assignee" in
      let* completed_at = required_nonblank_string obj "completed_at" in
      let* notes = optional_nonblank_string obj "notes" in
      Ok (Done { assignee; completed_at; notes })
  | "cancelled" ->
      let* cancelled_by = required_string_field obj "cancelled_by" in
      let* cancelled_at = required_nonblank_string obj "cancelled_at" in
      let* reason = optional_nonblank_string obj "reason" in
      Ok (Cancelled { cancelled_by; cancelled_at; reason })
  | other -> Error (Printf.sprintf "unknown task_status %S" other)

let decode_task_status json =
  match required_member json "task_status" with
  | Ok (`String kind) -> decode_task_status_fields kind json
  | Ok (`Assoc _ as obj) ->
      let* kind =
        if has_field obj "kind" then required_nonblank_string obj "kind"
        else required_nonblank_string obj "status"
      in
      decode_task_status_fields kind obj
  | Ok (`List [ `String kind ]) -> decode_task_status_fields kind json
  | Ok (`List [ `String kind; (`Assoc _ as obj) ]) ->
      decode_task_status_fields kind obj
  | Ok bad -> field_type_error "task_status" "a status string or object" bad
  | Error _ -> (
      match required_member json "status" with
      | Ok (`String kind) -> decode_task_status_fields kind json
      | Ok (`Assoc _ as obj) ->
          let* kind = required_nonblank_string obj "kind" in
          decode_task_status_fields kind obj
      | Ok bad -> field_type_error "status" "a task status" bad
      | Error _ as err -> err)

let decode_task json =
  let* id = required_nonblank_string json "id" in
  let* title = required_nonblank_string json "title" in
  let* description = optional_nonblank_string json "description" in
  let* priority = required_int_field json "priority" in
  let* status = decode_task_status json in
  let* goal_id = optional_nonblank_string json "goal_id" in
  let goal_link = match goal_id with None -> Unlinked | Some g -> Linked g in
  let* created_at = optional_nonblank_string json "created_at" in
  let* updated_at = optional_nonblank_string json "updated_at" in
  Ok
    {
      id;
      title;
      description;
      priority;
      status;
      goal_link;
      created_at;
      updated_at;
    }

let check_goal_link_assignable (t : task) =
  match t.goal_link with
  | Unlinked -> Ok ()
  | Linked goal_id ->
      Error
        (Printf.sprintf "task %S is already assigned to goal %S" t.id goal_id)

let enrich_planning_with_tasks ~observed_at (snap : planning_snapshot) tasks =
  let count_for_goal goal_id =
    List.fold_left
      (fun acc (t : task) ->
        match t.goal_link with
        | Linked gid when String.equal gid goal_id -> acc + 1
        | Linked _ | Unlinked -> acc)
      0 tasks
  in
  let goals =
    List.map
      (fun (g : goal) ->
        match g.linked_task_count with
        | Observed.Absent | Observed.Unreported ->
            {
              g with
              linked_task_count =
                Observed.value ~observed_at (count_for_goal g.id);
            }
        | Observed.Value _ | Observed.Loading _ | Observed.Failed _ -> g)
      snap.goals
  in
  { goals; tasks }

let decode_planning_snapshot ~observed_at json =
  let* _, body = unwrap_v2_or_raw json in
  let* goal_items = required_list_field body "goals" in
  let* goals = decode_list "goals" (decode_goal ~observed_at) goal_items in
  let* task_items =
    if has_field body "tasks" then required_list_field body "tasks"
    else if has_field body "task_backlog" then (
      match member "task_backlog" body with
      | `List items -> Ok items
      | `Assoc _ as tb when has_field tb "tasks" -> required_list_field tb "tasks"
      | `Assoc _ | `Null ->
          (* Live /api/v1/dashboard/planning returns task_backlog as a counts
             summary object ({todo, claimed, in_progress, ...}). Individual
             task rows come from /api/v1/dashboard/execution?light=true. *)
          Ok []
      | bad ->
          field_type_error "task_backlog"
            "a task list or backlog summary object" bad)
    else
      match optional_object_field body "backlog" with
      | Ok (Some b) -> required_list_field b "tasks"
      | Ok None -> Ok []
      | Error _ as err -> err
  in
  let* tasks = decode_list "tasks" decode_task task_items in
  let snap = { goals; tasks } in
  if tasks = [] then Ok snap
  else Ok (enrich_planning_with_tasks ~observed_at snap tasks)

let decode_planning_backlog_counts json =
  let* _, body = unwrap_v2_or_raw json in
  if not (has_field body "task_backlog") then Ok None
  else
    match member "task_backlog" body with
    | `Assoc _ as tb ->
        let opt_nonneg key =
          match optional_int_field tb key with
          | Error _ as err -> err
          | Ok None -> Ok 0
          | Ok (Some n) when n >= 0 -> Ok n
          | Ok (Some n) ->
              Error
                (Printf.sprintf "task_backlog.%s must be >= 0, got %d" key n)
        in
        let* todo = opt_nonneg "todo" in
        let* claimed = opt_nonneg "claimed" in
        let* in_progress = opt_nonneg "in_progress" in
        let* awaiting_verification = opt_nonneg "awaiting_verification" in
        let* done_total = opt_nonneg "done" in
        let* cancelled = opt_nonneg "cancelled" in
        Ok
          (Some
             {
               todo;
               claimed;
               in_progress;
               awaiting_verification;
               done_total;
               cancelled;
             })
    | `List _ | `Null -> Ok None
    | bad ->
        field_type_error "task_backlog" "a task list or backlog summary object"
          bad

let decode_execution_tasks json =
  let* _, body = unwrap_v2_or_raw json in
  let* task_items = required_list_field body "tasks" in
  decode_list "tasks" decode_task task_items

type review_observation_state =
  | Review_unobserved
  | Review_running
  | Review_approved
  | Review_rejected
  | Review_unavailable
  | Review_not_reviewed
  | Review_commit_failed
  | Review_execution_pending
  | Review_execution_repair_required
  | Review_failed
  | Review_cancelled
  | Review_superseded

type review_observation = {
  state : review_observation_state;
  detail : string;
  actor : string;
}

type verification_request = {
  request_id : string;
  task_id : string;
  task_title : string;
  submitted_by : string;
  created_at_unix : float option;
  completion_contract : string list;
  required_artifacts : string list;
  submitted_evidence : string list;
  evidence_projection_error : string option;
  review_observation : review_observation option;
}

type operator_verdict =
  | Verdict_approve
  | Verdict_reject of { reason : string }

let review_observation_state_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "unobserved" -> Some Review_unobserved
  | "running" -> Some Review_running
  | "approved" -> Some Review_approved
  | "rejected" -> Some Review_rejected
  | "unavailable" -> Some Review_unavailable
  | "not_reviewed" -> Some Review_not_reviewed
  | "commit_failed" -> Some Review_commit_failed
  | "execution_pending" -> Some Review_execution_pending
  | "execution_repair_required" -> Some Review_execution_repair_required
  | "failed" -> Some Review_failed
  | "cancelled" -> Some Review_cancelled
  | "superseded" -> Some Review_superseded
  | _ -> None

let decode_review_observation json =
  let* state =
    decode_enum ~field:"state" review_observation_state_of_string json
  in
  let* detail = required_string_field json "detail" in
  let* actor = required_string_field json "actor" in
  Ok { state; detail; actor }

let decode_verification_request json =
  let* request_id = required_nonblank_string json "request_id" in
  let* task_id = required_nonblank_string json "task_id" in
  let* task_title = required_nonblank_string json "task_title" in
  let* submitted_by = required_nonblank_string json "submitted_by" in
  let* created_at_unix = decode_optional_timestamp_unix json "created_at" in
  let* completion_contract = optional_string_list json "completion_contract" in
  let* required_artifacts = optional_string_list json "required_artifacts" in
  let* submitted_evidence = optional_string_list json "submitted_evidence" in
  let* evidence_projection_error =
    optional_nonblank_string json "evidence_projection_error"
  in
  let* review_observation =
    match optional_object_field json "review_observation" with
    | Ok None -> Ok None
    | Ok (Some obs) ->
        let* decoded = decode_review_observation obs in
        Ok (Some decoded)
    | Error _ as err -> err
  in
  Ok
    {
      request_id;
      task_id;
      task_title;
      submitted_by;
      created_at_unix;
      completion_contract;
      required_artifacts;
      submitted_evidence;
      evidence_projection_error;
      review_observation;
    }

let decode_verification_snapshot json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "requests" in
  decode_list "requests" decode_verification_request items

let encode_verification_verdict ~task_id ~verification_id ~verdict ~notes =
  (* Strict allowlist: [task_id; verification_id; verdict; reason; notes]. *)
  let verdict_fields =
    match verdict with
    | Verdict_approve -> [ ("verdict", `String "approve") ]
    | Verdict_reject { reason } ->
        [ ("verdict", `String "reject"); ("reason", `String reason) ]
  in
  let notes_field =
    match notes with None -> [] | Some n -> [ ("notes", `String n) ]
  in
  `Assoc
    ([
       ("task_id", `String task_id);
       ("verification_id", `String verification_id);
     ]
    @ verdict_fields @ notes_field)

type schedule_status =
  | Sched_scheduled
  | Sched_due
  | Sched_running
  | Sched_succeeded
  | Sched_failed
  | Sched_cancelled
  | Sched_expired

(* The server's wake statuses are running / succeeded / failed
   (Schedule_contract_values.wake_status_to_string). A failed wake carries its
   reason in the wake's [error] field, which may be absent. *)
type wake_disposition =
  | Wake_succeeded
  | Wake_failed of string option
  | Wake_running
  | Wake_never

type schedule_row = {
  schedule_instance_id : string;
  schedule_id : string;
  status : schedule_status;
  source : string;
  due_at_unix : float;
  next_due_at_unix : float option;
  recurrence_kind : string;
  recurrence_summary : string;
  payload_kind : string option;
  payload_support : string;
  payload_target : string option;
  payload_keeper_name : string option;
  payload_summary : string option;
  last_wake_unix : float option;
  last_disposition : wake_disposition;
}

let schedule_status_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "scheduled" -> Some Sched_scheduled
  | "due" -> Some Sched_due
  | "running" -> Some Sched_running
  | "succeeded" -> Some Sched_succeeded
  | "failed" -> Some Sched_failed
  | "cancelled" -> Some Sched_cancelled
  | "expired" -> Some Sched_expired
  | _ -> None

let decode_last_wake json =
  match optional_object_field json "last_wake" with
  | Error _ as err -> err
  | Ok None -> Ok (None, Wake_never)
  | Ok (Some wake) ->
      let* ts =
        match decode_optional_timestamp_unix wake "finished_at" with
        | Ok (Some _ as v) -> Ok v
        | Ok None -> decode_optional_timestamp_unix wake "started_at"
        | Error _ as err -> err
      in
      (* [detail] is the consumer's receipt object (e.g. the keeper wake
         enqueue record), not a reason string, so it is not read here. *)
      let* error = optional_nonblank_string wake "error" in
      let* status = required_nonblank_string wake "status" in
      let* disp =
        match status with
        | "succeeded" -> Ok Wake_succeeded
        | "running" -> Ok Wake_running
        | "failed" -> Ok (Wake_failed error)
        | other -> Error (Printf.sprintf "unknown schedule wake status %S" other)
      in
      Ok (ts, disp)

let decode_schedule_row json =
  let* schedule_instance_id =
    required_nonblank_string json "schedule_instance_id"
  in
  let* schedule_id = required_nonblank_string json "schedule_id" in
  let* status = decode_enum ~field:"status" schedule_status_of_string json in
  let* source = required_nonblank_string json "source" in
  let* due_at_unix = decode_timestamp_unix json "due_at" in
  let* next_due_at_unix = decode_optional_timestamp_unix json "next_due_at" in
  let* recurrence_kind = required_nonblank_string json "recurrence_kind" in
  let* recurrence_summary = required_string_field json "recurrence_summary" in
  let* payload_kind = optional_nonblank_string json "payload_kind" in
  let* payload_support = required_nonblank_string json "payload_support" in
  let* payload_target = optional_nonblank_string json "payload_target" in
  let* payload_keeper_name =
    optional_nonblank_string json "payload_keeper_name"
  in
  let* payload_summary = optional_nonblank_string json "payload_summary" in
  let* last_wake_unix, last_disposition = decode_last_wake json in
  Ok
    {
      schedule_instance_id;
      schedule_id;
      status;
      source;
      due_at_unix;
      next_due_at_unix;
      recurrence_kind;
      recurrence_summary;
      payload_kind;
      payload_support;
      payload_target;
      payload_keeper_name;
      payload_summary;
      last_wake_unix;
      last_disposition;
    }

let decode_schedules_snapshot json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "requests" in
  let* rows = decode_list "requests" decode_schedule_row items in
  let* next_cursor = optional_nonblank_string body "next_cursor" in
  Ok (rows, next_cursor)

type ask_mode =
  | Ask_single
  | Ask_multi

type ask_choice = {
  choice_id : string;
  label : string;
  description : string option;
}

type ask_question = {
  question_id : string;
  header : string;
  prompt : string;
  mode : ask_mode;
  allow_free_text : bool;
  free_text_hint : string option;
  choices : ask_choice list;
}

type ask_resolution =
  | Ask_open
  | Ask_answered of { answered_at : float; question_ids : string list }
  | Ask_withdrawn of { reason : string; withdrawn_at : float }

type ask_row = {
  ask_id : string;
  keeper : string;
  asked_at : float;
  context : string option;
  questions : ask_question list;
  resolution : ask_resolution;
}

type ask_response =
  | Ask_chose of string list
  | Ask_wrote of string
  | Ask_skipped

type held_tool_approval = {
  approval_id : string;
  tool_call_id : string;
  keeper : string;
  tool : string;
  args_preview : string;
  question : string;
  because : string option;
  asked_at : float;
  timeout_sec : float;
}

type tool_approval_decision =
  | Tool_approve
  | Tool_deny

type gate_pending = {
  id : string;
  keeper : string;
  tool_name : string;
  input_preview : string option;
  waiting_s : float option;
  phase : string;
}

let decode_ask_choice json =
  let* choice_id = required_nonblank_string json "choice_id" in
  let* label = required_nonblank_string json "label" in
  let* description = optional_nonblank_string json "description" in
  Ok { choice_id; label; description }

let ask_mode_of_string = function
  | "single" -> Some Ask_single
  | "multi" -> Some Ask_multi
  | _ -> None

let decode_ask_question json =
  let* question_id = required_nonblank_string json "question_id" in
  let* header = required_string_field json "header" in
  let* prompt = required_nonblank_string json "prompt" in
  let* mode = decode_enum ~field:"mode" ask_mode_of_string json in
  let* allow_free_text, free_text_hint =
    match member "free_text" json with
    | `Null -> Ok (false, None)
    | `Assoc _ as ft ->
        let* allowed = required_bool_field ft "allowed" in
        let* hint = optional_nonblank_string ft "hint" in
        Ok (allowed, hint)
    | bad -> field_type_error "free_text" "an object or null" bad
  in
  let* choice_items = optional_list_field json "choices" in
  let* choices = decode_list "choices" decode_ask_choice choice_items in
  Ok
    {
      question_id;
      header;
      prompt;
      mode;
      allow_free_text;
      free_text_hint;
      choices;
    }

let decode_ask_resolution json =
  let* state = required_nonblank_string json "state" in
  match state with
  | "open" -> Ok Ask_open
  | "answered" ->
      let* answered_at = required_finite_float json "answered_at" in
      let* question_ids = required_string_list json "answered_question_ids" in
      Ok (Ask_answered { answered_at; question_ids })
  | "withdrawn" ->
      let* reason = required_string_field json "reason" in
      let* withdrawn_at = required_finite_float json "withdrawn_at" in
      Ok (Ask_withdrawn { reason; withdrawn_at })
  | other -> Error (Printf.sprintf "unknown ask resolution state %S" other)

let decode_ask_row json =
  let* ask_id = required_nonblank_string json "ask_id" in
  let* keeper = required_nonblank_string json "keeper" in
  let* asked_at = required_finite_float json "asked_at" in
  let* context = optional_nonblank_string json "context" in
  let* q_items = required_list_field json "questions" in
  let* questions = decode_list "questions" decode_ask_question q_items in
  let* res_obj = required_object_field json "resolution" in
  let* resolution = decode_ask_resolution res_obj in
  Ok { ask_id; keeper; asked_at; context; questions; resolution }

let decode_asks_snapshot json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "asks" in
  decode_list "asks" decode_ask_row items

let decode_tool_approval json =
  let* approval_id = required_nonblank_string json "approval_id" in
  let* tool_call_id = required_nonblank_string json "tool_call_id" in
  let* keeper = required_nonblank_string json "keeper" in
  let* tool = required_nonblank_string json "tool" in
  let* args_preview = required_string_field json "args" in
  let* question = required_string_field json "question" in
  let* because = optional_nonblank_string json "because" in
  let* asked_at = required_finite_float json "asked_at" in
  let* timeout_sec = required_nonnegative_float json "timeout_sec" in
  Ok
    {
      approval_id;
      tool_call_id;
      keeper;
      tool;
      args_preview;
      question;
      because;
      asked_at;
      timeout_sec;
    }

let decode_tool_approvals json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "pending" in
  decode_list "pending" decode_tool_approval items

let decode_gate_pending json =
  let* id = required_nonblank_string json "id" in
  let* keeper = required_nonblank_string json "keeper_name" in
  let* tool_name = required_nonblank_string json "tool_name" in
  let* input_preview = optional_nonblank_string json "input_preview" in
  let* waiting_s = optional_finite_float json "waiting_s" in
  let* phase = required_nonblank_string json "phase" in
  Ok { id; keeper; tool_name; input_preview; waiting_s; phase }

let decode_gate_pending_list json =
  let* _, body = unwrap_v2_or_raw json in
  if has_field body "approval_queue" then
    match member "approval_queue" body with
    | `Null -> Ok []
    | `List items -> decode_list "approval_queue" decode_gate_pending items
    | bad -> field_type_error "approval_queue" "a list or null" bad
  else
    let* items = required_list_field body "pending" in
    decode_list "pending" decode_gate_pending items

let encode_ask_response = function
  | Ask_chose choice_ids ->
      `Assoc
        [
          ("kind", `String "chose");
          ("choice_ids", `List (List.map (fun c -> `String c) choice_ids));
        ]
  | Ask_wrote text ->
      `Assoc [ ("kind", `String "wrote"); ("text", `String text) ]
  | Ask_skipped -> `Assoc [ ("kind", `String "skipped") ]

let encode_ask_answer ~keeper ~ask_id ?session_id ~answers () =
  let session_field =
    match session_id with
    | None -> []
    | Some sid -> [ ("session_id", `String sid) ]
  in
  `Assoc
    ([
       ("name", `String keeper);
       ("ask_id", `String ask_id);
       ( "answers"
       , `List
           (List.map
              (fun (question_id, response) ->
                `Assoc
                  [
                    ("question_id", `String question_id);
                    ("response", encode_ask_response response);
                  ])
              answers) );
     ]
    @ session_field)

let encode_tool_approval_decision ~keeper ~tool_call_id ~approval_id ~decision
    ?expected_workspace () =
  let decision_str =
    match decision with Tool_approve -> "approve" | Tool_deny -> "deny"
  in
  let ws_field =
    match expected_workspace with
    | None -> []
    | Some ws -> [ ("expected_workspace", encode_expected_workspace ws) ]
  in
  `Assoc
    ([
       ("name", `String keeper);
       ("tool_call_id", `String tool_call_id);
       ("approval_id", `String approval_id);
       ("decision", `String decision_str);
     ]
    @ ws_field)

let encode_gate_resolution ~id ~approved ~reason =
  `Assoc
    ([
       ("id", `String id);
       ("decision", `String (if approved then "approve" else "reject"));
     ]
    @ match reason with None -> [] | Some r -> [ ("reason", `String r) ])

type candle_ledger_state =
  | Ledger_present
  | Ledger_missing
  | Ledger_unavailable of string

type candle_allocation = {
  keeper : string;
  amount_milli : int;
  weight : int;
}

type candle_event_kind =
  | Candle_paid of {
      goal_id : string;
      total_milli : int;
      allocations : candle_allocation list;
    }
  | Candle_purchased of { keeper : string; item : string; amount_milli : int }
  | Candle_granted of { keeper : string; amount_milli : int; reason : string }
  | Candle_gifted of {
      from_keeper : string;
      to_keeper : string;
      amount_milli : int;
      reason : string;
    }
  | Candle_gifted_item of {
      from_keeper : string;
      to_keeper : string;
      item : string;
    }
  | Candle_equipped of { keeper : string; slot : string; choice : string }
  | Candle_half_life_set of {
      mode : string;
      half_life_hours : int option;
      half_life_sec : float option;
    }
  | Candle_snapshot of {
      goal_id : string;
      title : string;
      linked_task_count : int;
    }
  | Candle_payout_owed of { goal_id : string }
  | Candle_candidates of {
      goal_id : string;
      observation : string;
      candidate_task_count : int;
      candidate_keeper_count : int;
    }
  | Candle_candidates_fenced of {
      goal_id : string;
      observation : string;
      candidate_task_count : int;
      candidate_keeper_count : int;
    }
  | Candle_window_held of { goal_id : string; task_count : int }
  | Candle_window_released of { goal_id : string }
  | Candle_unattributed of {
      goal_id : string;
      reason : string;
      observation : string;
      diagnostic_hint : string option;
    }
  | Candle_payout_failed of { goal_id : string; due_date : string }

type candle_event = {
  seq : int;
  at_unix : float;
  kind : candle_event_kind;
}

type candle_balance_row = {
  keeper : string;
  balance_milli : int;
  decayed_milli : string;
  last_event_unix : float option;
  owned_items : string list;
}

type candle_diagnostics = {
  unattributed_count : int;
  backlog_fenced_count : int;
  zero_linked_tasks_goals : int;
  held_windows_count : int;
}

type candle_ledger = {
  ledger_state : candle_ledger_state;
  total_events : int;
  balance_error : string option;
  policy_configuration : string;
  pricing_mode : string;
  disabled_reason : string option;
  half_life_sec : float option;
  issued_milli : string;
  burned_milli : string;
  circulating_milli : string;
  total_supply_milli : string;
  active_keepers : int;
  diagnostics : candle_diagnostics;
  balances : candle_balance_row list;
  recent_events : candle_event list;
}

let decode_candle_balance json =
  let* keeper = required_nonblank_string json "keeper" in
  let* balance_milli = required_nonnegative_int_field json "balance_milli" in
  let* decayed_milli = required_string_field json "decayed_milli" in
  let* last_event_unix = decode_optional_timestamp_unix json "last_event_unix" in
  let* owned_items = optional_string_list json "owned_items" in
  Ok { keeper; balance_milli; decayed_milli; last_event_unix; owned_items }

let decode_candle_allocation json =
  let* keeper = required_nonblank_string json "keeper" in
  let* amount_milli = required_nonnegative_int_field json "amount_milli" in
  let* weight = required_nonnegative_int_field json "weight" in
  Ok { keeper; amount_milli; weight }

let decode_candle_event json =
  let* seq = required_int_field json "seq" in
  let* at_unix = required_finite_float json "at_unix" in
  let* kind_word = required_nonblank_string json "kind" in
  let* kind =
    match kind_word with
    | "paid" ->
        let* goal_id = required_nonblank_string json "goal_id" in
        let* total_milli = required_nonnegative_int_field json "total_milli" in
        let* alloc_items = required_list_field json "allocations" in
        let* allocations =
          decode_list "allocations" decode_candle_allocation alloc_items
        in
        Ok (Candle_paid { goal_id; total_milli; allocations })
    | "purchased" ->
        let* keeper = required_nonblank_string json "keeper" in
        let* item = required_nonblank_string json "item" in
        let* amount_milli = required_nonnegative_int_field json "amount_milli" in
        Ok (Candle_purchased { keeper; item; amount_milli })
    | "granted" ->
        let* keeper = required_nonblank_string json "keeper" in
        let* amount_milli = required_nonnegative_int_field json "amount_milli" in
        let* reason = required_string_field json "reason" in
        Ok (Candle_granted { keeper; amount_milli; reason })
    | "gifted" ->
        let* from_keeper = required_nonblank_string json "from_keeper" in
        let* to_keeper = required_nonblank_string json "to_keeper" in
        let* amount_milli = required_nonnegative_int_field json "amount_milli" in
        let* reason = required_string_field json "reason" in
        Ok (Candle_gifted { from_keeper; to_keeper; amount_milli; reason })
    | "gifted_item" ->
        let* from_keeper = required_nonblank_string json "from_keeper" in
        let* to_keeper = required_nonblank_string json "to_keeper" in
        let* item = required_nonblank_string json "item" in
        Ok (Candle_gifted_item { from_keeper; to_keeper; item })
    | "equipped" ->
        let* keeper = required_nonblank_string json "keeper" in
        let* slot = required_nonblank_string json "slot" in
        let* choice = required_nonblank_string json "choice" in
        Ok (Candle_equipped { keeper; slot; choice })
    | "half_life_set" ->
        let* hl = required_object_field json "half_life" in
        let* mode = required_nonblank_string hl "mode" in
        let* half_life_hours = optional_int_field hl "half_life_hours" in
        let* half_life_sec = optional_finite_float hl "half_life_sec" in
        Ok (Candle_half_life_set { mode; half_life_hours; half_life_sec })
    | "snapshot" ->
        let* goal_id = required_nonblank_string json "goal_id" in
        let* title = required_string_field json "title" in
        let* linked_task_count =
          required_nonnegative_int_field json "linked_task_count"
        in
        Ok (Candle_snapshot { goal_id; title; linked_task_count })
    | "payout_owed" ->
        let* goal_id = required_nonblank_string json "goal_id" in
        Ok (Candle_payout_owed { goal_id })
    | "candidates" ->
        let* goal_id = required_nonblank_string json "goal_id" in
        let* observation = required_nonblank_string json "observation" in
        let* candidate_task_count =
          required_nonnegative_int_field json "candidate_task_count"
        in
        let* candidate_keeper_count =
          required_nonnegative_int_field json "candidate_keeper_count"
        in
        Ok
          (Candle_candidates
             {
               goal_id;
               observation;
               candidate_task_count;
               candidate_keeper_count;
             })
    | "candidates_fenced" ->
        let* goal_id = required_nonblank_string json "goal_id" in
        let* observation = required_nonblank_string json "observation" in
        let* candidate_task_count =
          required_nonnegative_int_field json "candidate_task_count"
        in
        let* candidate_keeper_count =
          required_nonnegative_int_field json "candidate_keeper_count"
        in
        Ok
          (Candle_candidates_fenced
             {
               goal_id;
               observation;
               candidate_task_count;
               candidate_keeper_count;
             })
    | "candidate_window_held" ->
        let* goal_id = required_nonblank_string json "goal_id" in
        let* task_count = required_nonnegative_int_field json "task_count" in
        Ok (Candle_window_held { goal_id; task_count })
    | "candidate_window_released" ->
        let* goal_id = required_nonblank_string json "goal_id" in
        Ok (Candle_window_released { goal_id })
    | "unattributed" ->
        let* goal_id = required_nonblank_string json "goal_id" in
        let* reason = required_nonblank_string json "reason" in
        let* observation = required_nonblank_string json "observation" in
        let* diagnostic_hint = optional_nonblank_string json "diagnostic_hint" in
        Ok (Candle_unattributed { goal_id; reason; observation; diagnostic_hint })
    | "payout_failed" ->
        let* goal_id = required_nonblank_string json "goal_id" in
        let* due_date = required_nonblank_string json "due_date" in
        Ok (Candle_payout_failed { goal_id; due_date })
    | other -> Error (Printf.sprintf "unknown candle event kind %S" other)
  in
  Ok { seq; at_unix; kind }

let decode_candle_diagnostics json =
  let* unattributed_count =
    required_nonnegative_int_field json "unattributed_count"
  in
  let* backlog_fenced_count =
    required_nonnegative_int_field json "backlog_fenced_count"
  in
  let* zero_linked_tasks_goals =
    required_nonnegative_int_field json "zero_linked_tasks_goals"
  in
  let* held_windows_count =
    required_nonnegative_int_field json "held_windows_count"
  in
  Ok
    {
      unattributed_count;
      backlog_fenced_count;
      zero_linked_tasks_goals;
      held_windows_count;
    }

let decode_candle_ledger json =
  let* _, body = unwrap_v2_or_raw json in
  let* state_str = required_nonblank_string body "ledger_state" in
  let* ledger_state =
    match state_str with
    | "present" -> Ok Ledger_present
    | "missing" | "empty" | "absent" -> Ok Ledger_missing
    | "unavailable" ->
        let* reason =
          match optional_nonblank_string body "reason" with
          | Ok (Some r) -> Ok r
          | Ok None -> Ok "candle ledger unavailable"
          | Error _ as err -> err
        in
        Ok (Ledger_unavailable reason)
    | other -> Error (Printf.sprintf "unknown candle ledger_state %S" other)
  in
  let* total_events = required_nonnegative_int_field body "total_events" in
  let* balance_error = optional_nonblank_string body "balance_error" in
  let* policy = required_object_field body "policy" in
  let* policy_configuration =
    required_nonblank_string policy "configuration"
  in
  let* pricing_mode = required_nonblank_string policy "pricing_mode" in
  let* disabled_reason = optional_nonblank_string policy "disabled_reason" in
  let* half_life_sec = optional_finite_float policy "half_life_sec" in
  let* supply = required_object_field body "supply" in
  let* issued_milli = required_string_field supply "issued_milli" in
  let* burned_milli = required_string_field supply "burned_milli" in
  let* circulating_milli = required_string_field supply "circulating_milli" in
  let* total_supply_milli = required_string_field supply "total_supply_milli" in
  let* active_keepers = required_nonnegative_int_field supply "active_keepers" in
  let* diag_obj = required_object_field body "diagnostics" in
  let* diagnostics = decode_candle_diagnostics diag_obj in
  let* balance_items = required_list_field body "balances" in
  let* balances = decode_list "balances" decode_candle_balance balance_items in
  let* event_items = required_list_field body "recent_events" in
  let* recent_events = decode_list "recent_events" decode_candle_event event_items in
  Ok
    {
      ledger_state;
      total_events;
      balance_error;
      policy_configuration;
      pricing_mode;
      disabled_reason;
      half_life_sec;
      issued_milli;
      burned_milli;
      circulating_milli;
      total_supply_milli;
      active_keepers;
      diagnostics;
      balances;
      recent_events;
    }
