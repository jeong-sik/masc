open Masc_tui_core
open Json_decode_fields
open Wire_common

let ( let* ) = Result.bind

let planning_path = "/api/v1/dashboard/planning"
let execution_tasks_path = "/api/v1/dashboard/execution?light=true"
let goals_path = "/api/v1/dashboard/goals"
let goal_confirmation_path = "/api/v1/goals/confirmation"

let goal_confirmation_get_path ~goal_id =
  goal_confirmation_path ^ "?goal_id=" ^ percent_encode (String.trim goal_id)
let mcp_path = "/mcp"
let mcp_protocol_version = "2026-07-28"

let task_link_goal_path ~task_id =
  "/api/v1/tasks/" ^ percent_encode (String.trim task_id) ^ "/link-goal"

let verification_requests_path ~view ~limit ~offset =
  Printf.sprintf "/api/v1/verification/requests?view=%s&limit=%d&offset=%d"
    (percent_encode view) (max 1 limit) (max 0 offset)

let verification_verdict_path = "/api/v1/verification/verdict"

(* Active schedules only: the Keepers list reads each keeper's next due time
   from this list, and ended one-shot rows outnumber live ones by about
   twenty to one, so a mixed first page leaves most keepers out. *)
let schedules_path ?cursor () =
  match cursor with
  | None -> "/api/v1/dashboard/scheduled-automation?active_only=true"
  | Some c ->
      "/api/v1/dashboard/scheduled-automation?active_only=true&cursor="
      ^ percent_encode c

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
let gate_resolve_path = "/api/v1/dashboard/gate/resolve"
let gate_mode_path = "/api/v1/dashboard/gate/mode"
let gate_external_mode_path = "/api/v1/dashboard/gate/external-mode"
let gate_rules_delete_path = "/api/v1/dashboard/gate/rules/delete"
let gate_retry_path = "/api/v1/dashboard/gate/retry"

let gate_tool_events_path ?(window_minutes = 60) () =
  Printf.sprintf "/api/v1/dashboard/gate/tool-events?window=%d"
    (max 1 window_minutes)

let keeper_tool_approval_mode_path = "/api/v1/keepers/tool-approval-mode"
let hitl_late_approval_attempts_path =
  "/api/v1/keepers/hitl/late-approval-attempts"
let hitl_late_approval_restore_path =
  "/api/v1/keepers/hitl/late-approval-restore"

let hitl_approval_recover_path ~approval_id =
  Printf.sprintf "/api/v1/keepers/hitl/approvals/%s/recover"
    (percent_encode (String.trim approval_id))

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

type goal_confirmation_proof = {
  goal_id : string;
  criterion_revision : string;
  request_id : string option;
  verification_run_id : string option;
  inspection_operator_id : string;
  state : string;
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

(* The route refuses a transition that does not name the workspace the
   operator read the Goal from ([validate_goal_workspace] in
   server_routes_http_routes_activity.ml), so the field is not optional. *)
let encode_goal_transition ~goal_id ~action ~note ~expected_workspace =
  let note_field =
    match note with
    | None -> []
    | Some n -> [ ("note", `String n) ]
  in
  `Assoc
    ([
       ("goal_id", `String goal_id);
       ("action", `String (goal_action_to_string action));
     ]
    @ note_field
    @ [ ("expected_workspace", encode_expected_workspace expected_workspace) ])

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

(* Decode [GET /api/v1/goals/confirmation?goal_id=...], which returns
   [inspection_operator_id], the full [goal], and the authoritative
   [verification] record. Only the proof fields the confirmation modal
   needs are extracted; anything else is ignored. *)
let decode_goal_confirmation json =
  let* inspection_operator_id =
    required_nonblank_string json "inspection_operator_id"
  in
  let* (goal_json, verification_json) =
    match (member "goal" json, member "verification" json) with
    | (`Assoc _ as g, v) -> Ok (g, v)
    | _ -> Error "goal confirmation requires goal and verification fields"
  in
  let* goal_id = required_nonblank_string goal_json "id" in
  let* criterion_revision =
    match optional_nonblank_string goal_json "criterion_revision" with
    | Ok (Some r) -> Ok r
    | Ok None ->
        (* A Goal without a criterion revision has no proof to name; surface
           it as a decode error rather than prefilling a bogus revision. *)
        Error "goal confirmation requires goal.criterion_revision"
    | Error _ as err -> err
  in
  let state, request_id, verification_run_id =
    match verification_json with
    | `Null -> ("no_record", None, None)
    | `Assoc _ as v -> (
        let completion =
          match member "completion" v with `Assoc _ as c -> c | _ -> v
        in
        match optional_nonblank_string completion "state" with
        | Ok (Some (("proof_proven" | "human_confirmed") as raw_state)) -> (
            match member "verdict" completion with
            | `Assoc _ as verdict ->
                let rid = optional_nonblank_string verdict "request_id" in
                let run =
                  optional_nonblank_string verdict "verification_run_id"
                in
                ( raw_state
                , (match rid with Ok r -> r | Error _ -> None)
                , (match run with Ok r -> r | Error _ -> None) )
            | _ -> (raw_state, None, None))
        | Ok (Some "proof_pending") ->
            let rid = optional_nonblank_string completion "request_id" in
            ("proof_pending", (match rid with Ok r -> r | Error _ -> None), None)
        | Ok (Some state) -> (state, None, None)
        | Ok None -> ("unknown", None, None)
        | Error _ -> ("unknown", None, None))
    | _ -> ("unknown", None, None)
  in
  Ok
    {
      goal_id;
      criterion_revision;
      request_id;
      verification_run_id;
      inspection_operator_id;
      state;
    }

type goal_measure_direction =
  | At_least
  | At_most

type goal_measure =
  | Measure_done_when of { condition : string }
  | Measure_count of {
      noun : string;
      total : int;
    }
  | Measure_quantity of {
      unit : string;
      direction : goal_measure_direction;
      target : float;
    }

let split_first_word raw =
  let s = String.trim raw in
  let len = String.length s in
  let rec find_ws i =
    if i >= len then len
    else
      match s.[i] with
      | ' ' | '\t' | '\n' | '\r' -> i
      | _ -> find_ws (i + 1)
  in
  let ws = find_ws 0 in
  let first = String.sub s 0 ws in
  let rest =
    if ws >= len then "" else String.trim (String.sub s ws (len - ws))
  in
  (first, rest)

let parse_goal_measure_input ~kind ~spec =
  let spec = String.trim spec in
  if String.equal spec "" then Error "Goal measure value is required"
  else
    match String.lowercase_ascii (String.trim kind) with
    | "done_when" -> Ok (Measure_done_when { condition = spec })
    | "count" -> (
        let total_s, noun = split_first_word spec in
        match int_of_string_opt total_s with
        | Some total when total > 0 && not (String.equal noun "") ->
            Ok (Measure_count { noun; total })
        | Some _ | None ->
            Error
              "Count measure must be '<positive-int> <noun>' (e.g. '14 files')")
    | "quantity" -> (
        let dir_tok, rest1 = split_first_word spec in
        let dir_opt =
          match String.lowercase_ascii dir_tok with
          | ">=" | "at_least" -> Some At_least
          | "<=" | "at_most" -> Some At_most
          | _ -> None
        in
        match dir_opt with
        | None ->
            Error
              "Quantity measure must start with '>=' (at_least) or '<=' (at_most), e.g. '<= 100 ms'"
        | Some direction -> (
            let target_s, unit = split_first_word rest1 in
            match float_of_string_opt target_s with
            | Some target
              when Float.is_finite target && not (String.equal unit "") ->
                Ok (Measure_quantity { unit; direction; target })
            | Some _ | None ->
                Error
                  "Quantity measure must be '<=|>= <number> <unit>' (e.g. '<= 100 ms')"))
    | _ ->
        Error "Measure kind must be 'done_when', 'count', or 'quantity'"

let encode_goal_measure = function
  | Measure_done_when { condition } ->
      `Assoc [ ("kind", `String "done_when"); ("condition", `String condition) ]
  | Measure_count { noun; total } ->
      `Assoc
        [
          ("kind", `String "count");
          ("noun", `String noun);
          ("total", `Int total);
        ]
  | Measure_quantity { unit; direction; target } ->
      let dir_str =
        match direction with At_least -> "at_least" | At_most -> "at_most"
      in
      `Assoc
        [
          ("kind", `String "quantity");
          ("unit", `String unit);
          ("direction", `String dir_str);
          ("target", `Float target);
        ]

let encode_goal_upsert ?id ~title ?measure ~procedure ?priority ?due_date
    ?expected_workspace () =
  let opt_str key = function
    | Some v when not (String.equal (String.trim v) "") ->
        [ (key, `String (String.trim v)) ]
    | Some _ | None -> []
  in
  let measure_field =
    match measure with
    | Some m -> [ ("measure", encode_goal_measure m) ]
    | None -> []
  in
  let priority_field =
    match priority with
    | Some p when p >= 1 && p <= 5 -> [ ("priority", `Int p) ]
    | Some _ | None -> []
  in
  let ws_field =
    match expected_workspace with
    | Some ws -> [ ("expected_workspace", encode_expected_workspace ws) ]
    | None -> []
  in
  `Assoc
    (opt_str "id" id
    @ [ ("title", `String (String.trim title)) ]
    @ measure_field
    @ [ ("procedure", `String (String.trim procedure)) ]
    @ priority_field
    @ opt_str "due_date" due_date
    @ ws_field)

let encode_mcp_tool_call ~id ~tool_name ~arguments =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", `String id);
      ("method", `String "tools/call");
      ( "params"
      , `Assoc
          [
            ("name", `String tool_name);
            ("arguments", arguments);
            ( "_meta"
            , `Assoc
                [
                  ( "io.modelcontextprotocol/protocolVersion"
                  , `String mcp_protocol_version );
                  ("io.modelcontextprotocol/clientCapabilities", `Assoc []);
                ] );
          ] );
    ]

let extract_mcp_json_payload raw =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then None
  else if trimmed.[0] = '{' then Some trimmed
  else
    let lines = String.split_on_char '\n' trimmed in
    let data_payloads =
      List.filter_map
        (fun line ->
          let l = String.trim line in
          if String.starts_with ~prefix:"data:" l then
            let rest = String.trim (String.sub l 5 (String.length l - 5)) in
            if String.length rest > 0 && rest.[0] = '{' then Some rest
            else None
          else None)
        lines
    in
    match List.rev data_payloads with
    | last :: _ -> Some last
    | [] -> Some trimmed

let extract_mcp_result_error_text result_json =
  match member "content" result_json with
  | `List items -> (
      let texts =
        List.filter_map
          (fun item ->
            match member "text" item with
            | `String s when not (String.equal (String.trim s) "") ->
                Some (String.trim s)
            | `String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _
            | `Assoc _ | `List _ ->
                None)
          items
      in
      match texts with
      | [] -> "MCP tool call failed (isError=true)"
      | xs -> String.concat " " xs)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
      "MCP tool call failed (isError=true)"

let decode_mcp_tool_call_ack raw =
  match extract_mcp_json_payload raw with
  | None -> Ok ()
  | Some payload -> (
      match Yojson.Safe.from_string payload with
      | exception Yojson.Json_error msg ->
          Error ("invalid MCP JSON response: " ^ msg)
      | json -> (
          match member "error" json with
          | `Assoc _ as err_obj -> (
              match member "message" err_obj with
              | `String msg when not (String.equal (String.trim msg) "") ->
                  Error (String.trim msg)
              | `String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _
              | `Assoc _ | `List _ ->
                  Error (Yojson.Safe.to_string err_obj))
          | `Null -> (
              match member "result" json with
              | `Assoc _ as res_obj -> (
                  match member "isError" res_obj with
                  | `Bool true -> Error (extract_mcp_result_error_text res_obj)
                  | `Bool false | `Null | `Int _ | `Intlit _ | `Float _
                  | `String _ | `Assoc _ | `List _ -> (
                      match member "structuredContent" res_obj with
                      | `Assoc _ as sc -> (
                          match member "ok" sc with
                          | `Bool false -> (
                              match member "error" sc with
                              | `String s
                                when not (String.equal (String.trim s) "") ->
                                  Error (String.trim s)
                              | `String _ | `Null | `Bool _ | `Int _ | `Intlit _
                              | `Float _ | `Assoc _ | `List _ ->
                                  Error (extract_mcp_result_error_text res_obj))
                          | `Bool true | `Null | `Int _ | `Intlit _ | `Float _
                          | `String _ | `Assoc _ | `List _ ->
                              Ok ())
                      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _
                      | `String _ | `List _ ->
                          Ok ()))
              | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _
              | `List _ ->
                  Ok ())
          | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
              Error ("unexpected MCP error field: " ^ Yojson.Safe.to_string json)))

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

(* The route's allowlist is exactly these three fields, and it refuses a body
   without [expected_workspace] ([commit_operator_cancel_json] in
   server_routes_http_routes_verification.ml). A blank reason is left out. *)
let encode_task_cancel ~task_id ~reason ~expected_workspace =
  let reason_field =
    match reason with
    | Some r when not (String.equal (String.trim r) "") ->
        [ ("reason", `String (String.trim r)) ]
    | Some _ | None -> []
  in
  `Assoc
    ([ ("task_id", `String task_id) ]
    @ reason_field
    @ [ ("expected_workspace", encode_expected_workspace expected_workspace) ])

type task_transition_action =
  | Task_claim
  | Task_start
  | Task_release
  | Task_submit_for_verification

let equal_task_transition_action a b =
  match (a, b) with
  | Task_claim, Task_claim
  | Task_start, Task_start
  | Task_release, Task_release
  | Task_submit_for_verification, Task_submit_for_verification ->
      true
  | ( (Task_claim | Task_start | Task_release | Task_submit_for_verification)
    , (Task_claim | Task_start | Task_release | Task_submit_for_verification) )
    ->
      false

let task_transition_action_to_string = function
  | Task_claim -> "claim"
  | Task_start -> "start"
  | Task_release -> "release"
  | Task_submit_for_verification -> "submit_for_verification"

let task_transition_action_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "claim" -> Some Task_claim
  | "start" -> Some Task_start
  | "release" -> Some Task_release
  | "submit_for_verification" -> Some Task_submit_for_verification
  | _ -> None

let encode_task_create ~title ~priority ?description ?goal_id
    ?expected_workspace () =
  let opt_str key = function
    | Some s when not (String.equal (String.trim s) "") ->
        [ (key, `String (String.trim s)) ]
    | Some _ | None -> []
  in
  let ws_field =
    match expected_workspace with
    | Some ws -> [ ("expected_workspace", encode_expected_workspace ws) ]
    | None -> []
  in
  `Assoc
    ([ ("title", `String (String.trim title)); ("priority", `Int priority) ]
    @ opt_str "description" description
    @ opt_str "goal_id" goal_id
    @ ws_field)

let encode_task_transition ~task_id ~action ?notes ?expected_workspace () =
  let notes_field =
    match notes with
    | Some n when not (String.equal (String.trim n) "") ->
        [ ("notes", `String (String.trim n)) ]
    | Some _ | None -> []
  in
  let ws_field =
    match expected_workspace with
    | Some ws -> [ ("expected_workspace", encode_expected_workspace ws) ]
    | None -> []
  in
  `Assoc
    ([
       ("task_id", `String (String.trim task_id));
       ("action", `String (task_transition_action_to_string action));
     ]
    @ notes_field
    @ ws_field)

let encode_task_link_goal ~goal_id ~expected_workspace =
  `Assoc
    [
      ("goal_id", `String (String.trim goal_id));
      ("expected_workspace", encode_expected_workspace expected_workspace);
    ]

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

(* An unreadable verification backlog answers the awaiting view with an
   empty queue and [backlog_error] (Dashboard_verification.filter_by_view).
   An empty list there is not "nothing awaits review", so it is a failed
   read. The All view carries no backlog fields. *)
let decode_verification_snapshot json =
  let* _, body = unwrap_v2_or_raw json in
  let* backlog_error = optional_nonblank_string body "backlog_error" in
  match backlog_error with
  | Some reason -> Error ("verification backlog unreadable: " ^ reason)
  | None ->
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

(* The server answers 200 for an unreadable store and for a rejected cursor,
   each with an empty [requests] list (Server_dashboard_schedule_projection).
   An empty list there is not "no schedules", so it is a failed read. *)
let decode_schedules_snapshot json =
  let* _, body = unwrap_v2_or_raw json in
  let* status = required_nonblank_string body "status" in
  match status with
  | "ok" ->
      let* items = required_list_field body "requests" in
      let* rows = decode_list "requests" decode_schedule_row items in
      let* next_cursor = optional_nonblank_string body "next_cursor" in
      Ok (rows, next_cursor)
  | "unknown" ->
      let* reason = required_nonblank_string body "schedule_store_read_error" in
      Error reason
  | "invalid_cursor" ->
      let* reason = required_nonblank_string body "cursor_error" in
      Error ("schedule cursor rejected: " ^ reason)
  | other -> Error (Printf.sprintf "unknown scheduled-automation status %S" other)

type schedule_repeat =
  | Repeat_once
  | Repeat_every of { interval_sec : int }

type schedule_create_request = {
  keeper_name : string;
  message : string;
  first_due_in_sec : int;
  repeat : schedule_repeat;
}

(* The route validates the body against the [masc_schedule_create] tool
   schema, which takes no other field (config/tools/masc_schedule_create.toml).
   The first due time is a delay, so it counts from the server's clock and
   not the terminal's. *)
let encode_schedule_create (req : schedule_create_request) =
  let recurrence =
    match req.repeat with
    | Repeat_once -> [ ("recurrence_kind", `String "one_shot") ]
    | Repeat_every { interval_sec } ->
        [
          ("recurrence_kind", `String "interval");
          ("recurrence_interval_sec", `Int interval_sec);
        ]
  in
  `Assoc
    ([
       ("keeper_name", `String req.keeper_name);
       ("message", `String req.message);
       ("due_in_sec", `Int req.first_due_in_sec);
     ]
    @ recurrence)

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

(* Dashboard_gate.dashboard_json sends approval_queue = null with
   approval_queue_state.state = "unavailable" when the queue store cannot be
   read. That is a failed read, not an empty queue: Keepers may be waiting on
   approvals the store holds. *)
let decode_gate_pending_list json =
  let* _, body = unwrap_v2_or_raw json in
  let* queue_state = required_object_field body "approval_queue_state" in
  let* state = required_nonblank_string queue_state "state" in
  match state with
  | "ready" ->
      let* items = required_list_field body "approval_queue" in
      decode_list "approval_queue" decode_gate_pending items
  | "unavailable" ->
      let* title = required_nonblank_string queue_state "title" in
      let* detail = required_nonblank_string queue_state "operator_detail" in
      Error (title ^ ": " ^ detail)
  | other -> Error (Printf.sprintf "unknown approval_queue_state %S" other)

let decode_ask_answers json =
  let* items = match json with
    | `List items -> Ok items
    | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ ->
        Error "answers: expected array"
  in
  let decode_answer item =
    let* question_id = required_string_field item "question_id" in
    let* response = required_object_field item "response" in
    let* kind = required_string_field response "kind" in
    let* value =
      match kind with
      | "chose" ->
          let* ids = required_list_field response "choice_ids" in
          let* choices = decode_list "choice_ids" (function
            | `String id -> Ok id
            | `List _ | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ ->
                Error "choice ID must be a string") ids in
          Ok (Ask_chose choices)
      | "wrote" ->
          let* text = required_string_field response "text" in
          Ok (Ask_wrote text)
      | "skipped" -> Ok Ask_skipped
      | other -> Error ("Unknown answer kind: " ^ other)
    in
    Ok (question_id, value)
  in
  decode_list "answers" decode_answer items

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

(* The tool-approval route answers 200 with [settled] and [remembered]
   (server_routes_http_keeper_control.ml). [remembered] is only read when
   [settled] is false, so the server never sends both as true. *)
type tool_approval_outcome =
  | Tool_approval_settled
  | Tool_approval_remembered
  | Tool_approval_no_waiting_call

let decode_tool_approval_outcome json =
  let* settled = required_bool_field json "settled" in
  let* remembered = required_bool_field json "remembered" in
  match (settled, remembered) with
  | true, false -> Ok Tool_approval_settled
  | false, true -> Ok Tool_approval_remembered
  | false, false -> Ok Tool_approval_no_waiting_call
  | true, true -> Error "tool approval answer is both settled and remembered"

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

(* --- Wave 3: Harness Health & Verification Evidence / Summary / Specs / TLC --- *)

let harness_health_path = "/api/v1/dashboard/harness-health"

let verification_evidence_path ~task_id ~verification_id =
  Printf.sprintf "/api/v1/verification/evidence?task_id=%s&verification_id=%s"
    (percent_encode task_id) (percent_encode verification_id)

let verification_summary_path = "/api/v1/verification/summary"
let verification_specs_path = "/api/v1/verification/specs"
let verification_tlc_results_path = "/api/v1/verification/tlc-results"

type harness_verdict_row = {
  timestamp : float;
  task_id : string;
  task_title : string;
  agent_name : string;
  gate : string;
  verdict : string;
  evaluator_runtime : string;
  fallback_reason : string option;
  notes_hash : string;
}

type harness_calibration = {
  total_verdicts : int;
  approve_count : int;
  reject_count : int;
  labeled_count : int;
  false_positive_count : int;
  false_negative_count : int;
  agreement_rate : float;
  fallback_count : int;
  distinct_runtime_count : int;
  verdicts_with_generator_runtime : int;
  distinct_runtime_rate : float option;
  recent_fallback_reasons : string list;
  unreadable_record_count : int;
}

type harness_health = {
  generated_at : float;
  scope_note : string;
  evaluator_status : string;
  fallback_ratio : float;
  last_signal_at : float option;
  calibration : harness_calibration;
  recent_verdicts : harness_verdict_row list;
  unreadable_verdicts_count : int;
}

let is_valid_notes_hash s =
  let len = String.length s in
  if len <> 64 then false
  else
    let rec loop i =
      if i = 64 then true
      else
        let c = s.[i] in
        if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') then loop (i + 1)
        else false
    in
    loop 0

let int_or_0 json key =
  match optional_int_field json key with Ok (Some n) -> n | Ok None | Error _ -> 0

let float_or_0 json key =
  match optional_finite_float json key with
  | Ok (Some f) -> f
  | Ok None | Error _ -> 0.0

let decode_harness_verdict_row json =
  let timestamp = float_or_0 json "timestamp" in
  let* task_id = required_nonblank_string json "task_id" in
  let task_title =
    match optional_string_field json "task_title" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> task_id
  in
  let agent_name =
    match optional_string_field json "agent_name" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let gate =
    match optional_string_field json "gate" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let* verdict = required_nonblank_string json "verdict" in
  let evaluator_runtime =
    match optional_string_field json "evaluator_runtime" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let* fallback_reason = optional_nonblank_string json "fallback_reason" in
  let notes_hash =
    match optional_string_field json "notes_hash" with
    | Ok (Some s) -> String.trim s
    | Ok None | Error _ -> ""
  in
  Ok
    {
      timestamp;
      task_id;
      task_title;
      agent_name;
      gate;
      verdict;
      evaluator_runtime;
      fallback_reason;
      notes_hash;
    }

let decode_harness_health json =
  let* _, body = unwrap_v2_or_raw json in
  let generated_at = float_or_0 body "generated_at" in
  let scope_note =
    match optional_string_field body "scope_note" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let* overview = required_object_field body "overview" in
  let* evaluator_status = required_nonblank_string overview "evaluator_status" in
  let fallback_ratio = float_or_0 overview "fallback_ratio" in
  let* last_signal_at = optional_finite_float overview "last_signal_at" in
  let* cal = required_object_field body "calibration" in
  let* distinct_runtime_rate =
    optional_finite_float cal "distinct_runtime_rate"
  in
  let* recent_fallback_reasons =
    optional_string_list cal "recent_fallback_reasons"
  in
  let calibration =
    {
      total_verdicts = int_or_0 cal "total_verdicts";
      approve_count = int_or_0 cal "approve_count";
      reject_count = int_or_0 cal "reject_count";
      labeled_count = int_or_0 cal "labeled_count";
      false_positive_count = int_or_0 cal "false_positive_count";
      false_negative_count = int_or_0 cal "false_negative_count";
      agreement_rate = float_or_0 cal "agreement_rate";
      fallback_count = int_or_0 cal "fallback_count";
      distinct_runtime_count = int_or_0 cal "distinct_runtime_count";
      verdicts_with_generator_runtime =
        int_or_0 cal "verdicts_with_generator_runtime";
      distinct_runtime_rate;
      recent_fallback_reasons;
      unreadable_record_count = int_or_0 cal "unreadable_record_count";
    }
  in
  let* verdict_items = optional_list_field body "recent_verdicts" in
  let* recent_verdicts =
    decode_list "recent_verdicts" decode_harness_verdict_row verdict_items
  in
  let unreadable_verdicts_count =
    int_or_0 body "recent_verdicts_unreadable_count"
  in
  Ok
    {
      generated_at;
      scope_note;
      evaluator_status;
      fallback_ratio;
      last_signal_at;
      calibration;
      recent_verdicts;
      unreadable_verdicts_count;
    }

type verification_evidence_item =
  | Verif_ev_note of string
  | Verif_ev_artifact of {
      reference : string;
      content : string;
      bytes : int;
      truncated : bool;
    }
  | Verif_ev_binary of {
      reference : string;
      bytes : int;
      sha256 : string;
      format : string;
      body : string option;
    }
  | Verif_ev_collab of {
      reference : string;
      content : string;
      sha256 : string;
    }
  | Verif_ev_unreadable of {
      reference : string option;
      code : string;
      detail : string option;
    }

type verification_evidence_bundle = {
  task_id : string;
  verification_id : string;
  producer : string option;
  authority_kind : string;
  authority_actor : string;
  available : bool;
  unavailable_reason : string option;
  items : verification_evidence_item list;
}

type verification_summary = {
  updated_at : string;
  total : int;
  pending : int option;
  approved : int option;
  rejected : int option;
  raw : Yojson.Safe.t;
}

type tla_spec_entry = {
  name : string;
  path : string;
  category : string;
  has_clean_cfg : bool;
  has_buggy_cfg : bool;
  mtime_iso : string;
}

type verification_specs = {
  updated_at : string;
  specs_dir : string option;
  entries : tla_spec_entry list;
}

type tlc_result_entry = {
  spec_name : string;
  cfg_name : string;
  category : string;
  status : string;
  states_explored : int option;
  distinct_states : int option;
  diameter : int option;
  last_run_at : string option;
  violation : string option;
  log_path : string option;
}

type verification_tlc_results = {
  updated_at : string;
  results_dir : string option;
  entries : tlc_result_entry list;
}

let decode_verification_evidence_item json =
  let* kind = required_nonblank_string json "kind" in
  match kind with
  | "note" ->
      let* content = required_string_field json "content" in
      Ok (Verif_ev_note content)
  | "artifact" ->
      let* reference = required_nonblank_string json "reference" in
      let content =
        match optional_string_field json "content" with
        | Ok (Some s) -> s
        | Ok None | Error _ -> ""
      in
      let bytes = int_or_0 json "bytes" in
      let truncated =
        match optional_bool_field json "truncated" with
        | Ok (Some b) -> b
        | Ok None | Error _ -> false
      in
      Ok (Verif_ev_artifact { reference; content; bytes; truncated })
  | "artifact_binary" ->
      let* reference = required_nonblank_string json "reference" in
      let bytes = int_or_0 json "bytes" in
      let sha256 =
        match optional_string_field json "sha256" with
        | Ok (Some s) -> s
        | Ok None | Error _ -> ""
      in
      let format =
        match optional_string_field json "format" with
        | Ok (Some s) -> s
        | Ok None | Error _ -> "unknown"
      in
      let* body = optional_nonblank_string json "body" in
      Ok (Verif_ev_binary { reference; bytes; sha256; format; body })
  | "collaboration" ->
      let* reference = required_nonblank_string json "reference" in
      let content =
        match optional_string_field json "content" with
        | Ok (Some s) -> s
        | Ok None | Error _ -> ""
      in
      let sha256 =
        match optional_string_field json "sha256" with
        | Ok (Some s) -> s
        | Ok None | Error _ -> ""
      in
      Ok (Verif_ev_collab { reference; content; sha256 })
  | "artifact_unreadable" ->
      let* reference = optional_nonblank_string json "reference" in
      let code, detail =
        match optional_object_field json "reason" with
        | Ok (Some r) ->
            let c =
              match optional_nonblank_string r "code" with
              | Ok (Some s) -> s
              | Ok None | Error _ -> "unreadable"
            in
            let d =
              match optional_nonblank_string r "detail" with
              | Ok v -> v
              | Error _ -> None
            in
            (c, d)
        | Ok None | Error _ -> ("unreadable", None)
      in
      Ok (Verif_ev_unreadable { reference; code; detail })
  | other ->
      Error (Printf.sprintf "unknown verification evidence item kind %S" other)

let decode_verification_evidence json =
  let* _, body = unwrap_v2_or_raw json in
  let res =
    match optional_object_field body "result" with
    | Ok (Some r) -> r
    | Ok None | Error _ -> body
  in
  let* task_id = required_nonblank_string res "task_id" in
  let* verification_id = required_nonblank_string res "verification_id" in
  let* producer = optional_nonblank_string res "producer" in
  let authority_kind =
    match optional_string_field res "authority_kind" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let authority_actor =
    match optional_string_field res "authority_actor" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let* ev_obj = required_object_field res "evidence" in
  let* access = required_nonblank_string ev_obj "access" in
  match access with
  | "available" ->
      let* raw_items = optional_list_field ev_obj "items" in
      let* items =
        decode_list "items" decode_verification_evidence_item raw_items
      in
      Ok
        {
          task_id;
          verification_id;
          producer;
          authority_kind;
          authority_actor;
          available = true;
          unavailable_reason = None;
          items;
        }
  | "unavailable" ->
      let* unavailable_reason = optional_nonblank_string ev_obj "reason" in
      Ok
        {
          task_id;
          verification_id;
          producer;
          authority_kind;
          authority_actor;
          available = false;
          unavailable_reason;
          items = [];
        }
  | other -> Error (Printf.sprintf "unknown verification evidence access %S" other)

let decode_verification_summary json =
  let* _, body = unwrap_v2_or_raw json in
  let updated_at =
    match optional_string_field body "updated_at" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let total = int_or_0 body "total" in
  let counts_obj =
    match optional_object_field body "counts" with
    | Ok (Some o) -> o
    | Ok None | Error _ -> (
        match optional_object_field body "by_status" with
        | Ok (Some o) -> o
        | Ok None | Error _ -> body)
  in
  let opt_int obj k =
    match optional_int_field obj k with Ok v -> v | Error _ -> None
  in
  let pending = opt_int counts_obj "pending" in
  let approved =
    match opt_int counts_obj "approved" with
    | Some _ as v -> v
    | None -> opt_int counts_obj "passed"
  in
  let rejected =
    match opt_int counts_obj "rejected" with
    | Some _ as v -> v
    | None -> opt_int counts_obj "failed"
  in
  Ok { updated_at; total; pending; approved; rejected; raw = body }

let decode_tla_spec_entry json =
  let* name = required_nonblank_string json "name" in
  let path =
    match optional_string_field json "path" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> name
  in
  let category =
    match optional_string_field json "category" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> "general"
  in
  let has_clean_cfg =
    match optional_bool_field json "has_clean_cfg" with
    | Ok (Some b) -> b
    | Ok None | Error _ -> false
  in
  let has_buggy_cfg =
    match optional_bool_field json "has_buggy_cfg" with
    | Ok (Some b) -> b
    | Ok None | Error _ -> false
  in
  let mtime_iso =
    match optional_string_field json "mtime_iso" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  Ok { name; path; category; has_clean_cfg; has_buggy_cfg; mtime_iso }

let decode_verification_specs json =
  let* _, body = unwrap_v2_or_raw json in
  let updated_at =
    match optional_string_field body "updated_at" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let* specs_dir = optional_nonblank_string body "specs_dir" in
  let* items = optional_list_field body "entries" in
  let* entries = decode_list "entries" decode_tla_spec_entry items in
  Ok { updated_at; specs_dir; entries }

let decode_tlc_result_entry json =
  let* spec_name = required_nonblank_string json "spec_name" in
  let cfg_name =
    match optional_string_field json "cfg_name" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let category =
    match optional_string_field json "category" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> "general"
  in
  let* status = required_nonblank_string json "status" in
  let* states_explored = optional_int_field json "states_explored" in
  let* distinct_states = optional_int_field json "distinct_states" in
  let* diameter = optional_int_field json "diameter" in
  let* last_run_at = optional_nonblank_string json "last_run_at" in
  let* violation = optional_nonblank_string json "violation" in
  let* log_path = optional_nonblank_string json "log_path" in
  Ok
    {
      spec_name;
      cfg_name;
      category;
      status;
      states_explored;
      distinct_states;
      diameter;
      last_run_at;
      violation;
      log_path;
    }

let decode_verification_tlc_results json =
  let* _, body = unwrap_v2_or_raw json in
  let updated_at =
    match optional_string_field body "updated_at" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let* results_dir = optional_nonblank_string body "results_dir" in
  let* items = optional_list_field body "entries" in
  let* entries = decode_list "entries" decode_tlc_result_entry items in
  Ok { updated_at; results_dir; entries }

(* ========================================================================= *)
(* Wave 4 Layer 2: HITL Gate Policy, Rules CRUD, Modes, Retry & Recovery     *)
(* ========================================================================= *)

type gate_mode =
  | Gate_manual
  | Gate_auto_judge
  | Gate_always_allow

let gate_mode_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "manual" -> Some Gate_manual
  | "auto_judge" -> Some Gate_auto_judge
  | "always_allow" -> Some Gate_always_allow
  | _ -> None

let gate_mode_to_string = function
  | Gate_manual -> "manual"
  | Gate_auto_judge -> "auto_judge"
  | Gate_always_allow -> "always_allow"

let equal_gate_mode a b =
  match (a, b) with
  | Gate_manual, Gate_manual
  | Gate_auto_judge, Gate_auto_judge
  | Gate_always_allow, Gate_always_allow ->
      true
  | Gate_manual, (Gate_auto_judge | Gate_always_allow)
  | Gate_auto_judge, (Gate_manual | Gate_always_allow)
  | Gate_always_allow, (Gate_manual | Gate_auto_judge) ->
      false

type gate_mode_status = {
  mode : gate_mode;
  configured : bool;
  state : string;
  read_error : string option;
}

type judge_lane_status =
  | Judge_lane_available of { lane_id : string; slots : string list }
  | Judge_lane_unavailable of { lane_id : string; reason : string }

type hitl_status = {
  gate_mode : gate_mode_status;
  external_gate_mode : gate_mode_status;
  judge_lane : judge_lane_status;
}

type gate_retry_meta = {
  id : string;
  input_hash : string;
  sequence : int;
  exact_attempt : Yojson.Safe.t;
  summary_attempt_disposition : Yojson.Safe.t;
  summary_text : string option;
  summary_judgment : string option;
}

type gate_rule = {
  id : string;
  keeper_name : string;
  tool_name : string;
  request_fingerprint : string;
  created_at : float;
  created_by : string option;
  source_approval_id : string option;
  expires_at : float option;
}

type gate_resolved_row = {
  id : string;
  event : string;
  keeper : string;
  tool : string;
  decision : string;
  decision_kind : string option;
  decision_reason : string option;
  decision_source : string option;
  authorization_source : string option;
  actor : string option;
  ts : float;
}

type gate_snapshot = {
  generated_at : string option;
  pending : gate_pending list;
  pending_error : string option;
  retry_meta : gate_retry_meta list;
  rules : gate_rule list;
  rules_error : string option;
  recent_resolved : gate_resolved_row list;
  recent_resolved_error : string option;
  recent_resolved_partial : bool;
  hitl : hitl_status option;
}

let decode_gate_mode_status json =
  let* mode = decode_enum ~field:"mode" gate_mode_of_string json in
  let* configured = required_bool_field json "configured" in
  let* state = required_nonblank_string json "state" in
  let* read_error = optional_nonblank_string json "read_error" in
  Ok { mode; configured; state; read_error }

let decode_judge_lane_status json =
  let* status = required_nonblank_string json "status" in
  let* lane_id = required_nonblank_string json "lane_id" in
  match status with
  | "available" ->
      let* slots = optional_string_list json "slots" in
      Ok (Judge_lane_available { lane_id; slots })
  | "unavailable" ->
      let* reason =
        match optional_nonblank_string json "reason" with
        | Ok (Some r) -> Ok r
        | Ok None -> Ok "unavailable"
        | Error _ as err -> err
      in
      Ok (Judge_lane_unavailable { lane_id; reason })
  | other -> Error (Printf.sprintf "unknown judge_lane status %S" other)

let decode_hitl_status json =
  let* gm_obj = required_object_field json "gate_mode" in
  let* gate_mode = decode_gate_mode_status gm_obj in
  let* egm_obj = required_object_field json "external_gate_mode" in
  let* external_gate_mode = decode_gate_mode_status egm_obj in
  let* jl_obj = required_object_field json "judge_lane" in
  let* judge_lane = decode_judge_lane_status jl_obj in
  Ok { gate_mode; external_gate_mode; judge_lane }

let decode_gate_retry_meta_opt json =
  match optional_nonblank_string json "id" with
  | Error _ | Ok None -> None
  | Ok (Some id) -> (
      match optional_nonblank_string json "input_hash" with
      | Error _ | Ok None -> None
      | Ok (Some input_hash) -> (
          match optional_int_field json "sequence" with
          | Error _ | Ok None -> None
          | Ok (Some sequence)
            when sequence > 0
                 && has_field json "exact_attempt"
                 && has_field json "summary_attempt_disposition" ->
              let exact_attempt = member "exact_attempt" json in
              let summary_attempt_disposition =
                member "summary_attempt_disposition" json
              in
              let summary_text, summary_judgment =
                match member "summary_status" json with
                | `Assoc _ as st -> (
                    match optional_object_field st "summary" with
                    | Ok (Some s) ->
                        let txt =
                          match optional_nonblank_string s "context_summary" with
                          | Ok v -> v
                          | Error _ -> None
                        in
                        let jdg =
                          match optional_nonblank_string s "judgment" with
                          | Ok v -> v
                          | Error _ -> None
                        in
                        (txt, jdg)
                    | Ok None | Error _ -> (
                        let r =
                          match optional_nonblank_string st "reason" with
                          | Ok v -> v
                          | Error _ -> None
                        in
                        (r, None)))
                | `String _
                | `Null
                | `Bool _
                | `Int _
                | `Intlit _
                | `Float _
                | `List _ ->
                    (None, None)
              in
              Some
                {
                  id;
                  input_hash;
                  sequence;
                  exact_attempt;
                  summary_attempt_disposition;
                  summary_text;
                  summary_judgment;
                }
          | Ok (Some _) -> None))

let decode_gate_rule json =
  let* id = required_nonblank_string json "id" in
  let* keeper_name = required_nonblank_string json "keeper_name" in
  let* tool_name = required_nonblank_string json "tool_name" in
  let* request_fingerprint =
    required_nonblank_string json "request_fingerprint"
  in
  let* created_at = required_finite_float json "created_at" in
  let* created_by = optional_nonblank_string json "created_by" in
  let* source_approval_id =
    optional_nonblank_string json "source_approval_id"
  in
  let* expires_at = optional_finite_float json "expires_at" in
  Ok
    {
      id;
      keeper_name;
      tool_name;
      request_fingerprint;
      created_at;
      created_by;
      source_approval_id;
      expires_at;
    }

let decode_gate_resolved_row json =
  let* id = required_nonblank_string json "id" in
  let* event = required_nonblank_string json "event" in
  let* keeper =
    if has_field json "keeper" then required_nonblank_string json "keeper"
    else required_nonblank_string json "keeper_name"
  in
  let* tool =
    if has_field json "tool" then required_nonblank_string json "tool"
    else required_nonblank_string json "tool_name"
  in
  let* decision = required_string_field json "decision" in
  let* decision_kind = optional_nonblank_string json "decision_kind" in
  let* decision_reason = optional_nonblank_string json "decision_reason" in
  let* decision_source = optional_nonblank_string json "decision_source" in
  let* authorization_source =
    optional_nonblank_string json "authorization_source"
  in
  let* actor = optional_nonblank_string json "actor" in
  let* ts =
    if has_field json "ts" then required_finite_float json "ts"
    else required_finite_float json "resolved_at"
  in
  Ok
    {
      id;
      event;
      keeper;
      tool;
      decision;
      decision_kind;
      decision_reason;
      decision_source;
      authorization_source;
      actor;
      ts;
    }

let decode_gate_snapshot json =
  let* _, body = unwrap_v2_or_raw json in
  let* generated_at = optional_nonblank_string body "generated_at" in
  let* queue_state = required_object_field body "approval_queue_state" in
  let* qstate = required_nonblank_string queue_state "state" in
  let* pending, retry_meta, pending_error =
    match qstate with
    | "ready" ->
        let* items = required_list_field body "approval_queue" in
        let* pend = decode_list "approval_queue" decode_gate_pending items in
        let meta = List.filter_map decode_gate_retry_meta_opt items in
        Ok (pend, meta, None)
    | "unavailable" ->
        let* title = required_nonblank_string queue_state "title" in
        let* detail = required_nonblank_string queue_state "operator_detail" in
        Ok ([], [], Some (title ^ ": " ^ detail))
    | other -> Error (Printf.sprintf "unknown approval_queue_state %S" other)
  in
  let* rules, rules_error =
    if not (has_field body "approval_rules_state") then Ok ([], None)
    else
      let* rstate_obj = required_object_field body "approval_rules_state" in
      let* rstate = required_nonblank_string rstate_obj "state" in
      match rstate with
      | "ready" ->
          let* items = optional_list_field body "approval_rules" in
          let* rs = decode_list "approval_rules" decode_gate_rule items in
          Ok (rs, None)
      | "unavailable" ->
          let* err = optional_nonblank_string rstate_obj "error" in
          Ok ([], Some (Option.value err ~default:"rules store unavailable"))
      | other ->
          Error (Printf.sprintf "unknown approval_rules_state %S" other)
  in
  let* recent_resolved, recent_resolved_error =
    if not (has_field body "recent_resolved_state") then Ok ([], None)
    else
      let* hstate_obj = required_object_field body "recent_resolved_state" in
      let* hstate = required_nonblank_string hstate_obj "state" in
      match hstate with
      | "ready" ->
          let* items = optional_list_field body "recent_resolved" in
          let* rows =
            decode_list "recent_resolved" decode_gate_resolved_row items
          in
          Ok (rows, None)
      | "unavailable" ->
          let* err = optional_nonblank_string hstate_obj "error" in
          Ok ([], Some (Option.value err ~default:"audit store unavailable"))
      | other ->
          Error (Printf.sprintf "unknown recent_resolved_state %S" other)
  in
  let* hitl =
    match optional_object_field body "hitl" with
    | Error _ as err -> err
    | Ok None -> Ok None
    | Ok (Some h) ->
        let* decoded = decode_hitl_status h in
        Ok (Some decoded)
  in
  let* recent_resolved_partial =
    match optional_object_field body "recent_resolved_page" with
    | Error _ as err -> err
    | Ok None -> Ok false
    | Ok (Some page) ->
        let* truncated = optional_bool_field page "truncated" in
        let* scan_exhausted = optional_bool_field page "scan_exhausted" in
        Ok (truncated = Some true || scan_exhausted = Some true)
  in
  Ok
    {
      generated_at;
      pending;
      pending_error;
      retry_meta;
      rules;
      rules_error;
      recent_resolved;
      recent_resolved_error;
      recent_resolved_partial;
      hitl;
    }

let encode_gate_resolution_with_policy ~id ~approved ~reason ~remember_rule
    ?rule_expires_at ?expected_workspace () =
  let base =
    [
      ("id", `String id);
      ("decision", `String (if approved then "approve" else "reject"));
    ]
  in
  let reason_f =
    match reason with
    | Some r when not (String.equal (String.trim r) "") ->
        [ ("reason", `String (String.trim r)) ]
    | Some _ | None -> []
  in
  let rule_f =
    if not remember_rule then []
    else
      [ ("remember_rule", `Bool true) ]
      @
      match rule_expires_at with
      | Some ts when Float.is_finite ts -> [ ("rule_expires_at", `Float ts) ]
      | Some _ | None -> []
  in
  let ws_f =
    match expected_workspace with
    | Some ws -> [ ("expected_workspace", encode_expected_workspace ws) ]
    | None -> []
  in
  `Assoc (base @ reason_f @ rule_f @ ws_f)

let encode_gate_mode ~mode = `Assoc [ ("mode", `String (gate_mode_to_string mode)) ]

let encode_gate_rule_delete ~id = `Assoc [ ("id", `String (String.trim id)) ]

let encode_gate_retry ?expected_workspace (meta : gate_retry_meta) =
  (* Exact 5-field closed allowlist (+ optional expected_workspace) enforced by
     [Server_dashboard_http.dashboard_gate_retry_http_json]. *)
  let base =
    [
      ("id", `String meta.id);
      ("input_hash", `String meta.input_hash);
      ("sequence", `Int meta.sequence);
      ("exact_attempt", meta.exact_attempt);
      ("summary_attempt_disposition", meta.summary_attempt_disposition);
    ]
  in
  let ws_f =
    match expected_workspace with
    | Some ws -> [ ("expected_workspace", encode_expected_workspace ws) ]
    | None -> []
  in
  `Assoc (base @ ws_f)

type keeper_tool_approval_mode =
  | Approval_auto
  | Approval_yolo

let keeper_tool_approval_mode_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "auto" -> Some Approval_auto
  | "yolo" -> Some Approval_yolo
  | _ -> None

let keeper_tool_approval_mode_to_string = function
  | Approval_auto -> "auto"
  | Approval_yolo -> "yolo"

let equal_keeper_tool_approval_mode a b =
  match (a, b) with
  | Approval_auto, Approval_auto | Approval_yolo, Approval_yolo -> true
  | Approval_auto, Approval_yolo | Approval_yolo, Approval_auto -> false

type tool_approval_modes_snapshot = {
  overrides : (string * keeper_tool_approval_mode) list;
  default_mode : keeper_tool_approval_mode;
  restore_error : string option;
}

let decode_tool_approval_modes json =
  let* _, body = unwrap_v2_or_raw json in
  let* default_mode =
    decode_enum ~field:"default" keeper_tool_approval_mode_of_string body
  in
  let* restore_error = optional_nonblank_string body "restore_error" in
  let* items = required_list_field body "overrides" in
  let* overrides =
    decode_list "overrides"
      (fun item ->
        let* keeper = required_nonblank_string item "keeper" in
        let* mode =
          decode_enum ~field:"mode" keeper_tool_approval_mode_of_string item
        in
        Ok (keeper, mode))
      items
  in
  Ok { overrides; default_mode; restore_error }

let encode_tool_approval_mode_set ~keeper ~mode =
  `Assoc
    [
      ("name", `String (String.trim keeper));
      ("mode", `String (keeper_tool_approval_mode_to_string mode));
    ]

type late_approval_attempt = {
  consume_id : string;
  keeper_name : string;
  tool_name : string;
  args_fingerprint : string;
  consumed_at : float;
  outcome : string;
}

let decode_late_approval_attempt json =
  let* consume_id = required_nonblank_string json "consume_id" in
  let* keeper_name = required_nonblank_string json "keeper_name" in
  let* tool_name = required_nonblank_string json "tool_name" in
  let* args_fingerprint = required_nonblank_string json "args_fingerprint" in
  let* consumed_at = required_finite_float json "consumed_at" in
  let* outcome = required_nonblank_string json "outcome" in
  Ok
    {
      consume_id;
      keeper_name;
      tool_name;
      args_fingerprint;
      consumed_at;
      outcome;
    }

let decode_late_approval_attempts json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "attempts" in
  decode_list "attempts" decode_late_approval_attempt items

let encode_hitl_ack_uncertain ~keeper_name ~consume_id =
  (* Strict 3-field closed object enforced by
     [Server_dashboard_http_hitl_recover.parse_ack_fields]. *)
  `Assoc
    [
      ("action", `String "ack_uncertain");
      ("keeper_name", `String (String.trim keeper_name));
      ("consume_id", `String (String.trim consume_id));
    ]

type gate_tool_rejection_row = {
  tool : string;
  reason : string;
  count : int;
}

type gate_queue_latency_summary = {
  depth : int;
  p50_wait_sec : float option;
  p95_wait_sec : float option;
  oldest_pending_sec : float option;
}

type gate_tool_events_snapshot = {
  generated_at : string;
  window_minutes : int;
  tool_rejections : gate_tool_rejection_row list;
  queue_summary : gate_queue_latency_summary option;
  queue_error : string option;
}

let decode_gate_tool_events json =
  let* _, body = unwrap_v2_or_raw json in
  let* generated_at = required_nonblank_string body "generated_at" in
  let* window_minutes = required_nonnegative_int_field body "window_minutes" in
  let* rej_items = optional_list_field body "tool_rejections" in
  let* tool_rejections =
    decode_list "tool_rejections"
      (fun r ->
        let* tool = required_nonblank_string r "tool" in
        let* reason = required_string_field r "reason" in
        let* count = required_nonnegative_int_field r "count" in
        Ok { tool; reason; count })
      rej_items
  in
  let* qstate_obj = required_object_field body "approval_queue_state" in
  let* qstate = required_nonblank_string qstate_obj "state" in
  let* queue_summary, queue_error =
    match qstate with
    | "ready" ->
        let* aq = required_object_field body "approval_queue" in
        let* depth = required_nonnegative_int_field aq "depth" in
        let* p50_wait_sec = optional_finite_float aq "p50_wait_sec" in
        let* p95_wait_sec = optional_finite_float aq "p95_wait_sec" in
        let* oldest_pending_sec =
          optional_finite_float aq "oldest_pending_sec"
        in
        Ok
          ( Some { depth; p50_wait_sec; p95_wait_sec; oldest_pending_sec }
          , None )
    | "unavailable" ->
        let* title = optional_nonblank_string qstate_obj "title" in
        let* detail = optional_nonblank_string qstate_obj "operator_detail" in
        let msg =
          match (title, detail) with
          | Some t, Some d -> t ^ ": " ^ d
          | Some t, None -> t
          | None, Some d -> d
          | None, None -> "approval queue unavailable"
        in
        Ok (None, Some msg)
    | other -> Error (Printf.sprintf "unknown approval_queue_state %S" other)
  in
  Ok
    {
      generated_at;
      window_minutes;
      tool_rejections;
      queue_summary;
      queue_error;
    }
