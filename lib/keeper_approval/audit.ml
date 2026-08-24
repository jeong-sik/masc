open Keeper_approval_queue_rules_types

type read_stage =
  | Read_recent
  | List_recent_resolved

type read_error =
  { stage : read_stage
  ; detail : string
  }

let read_stage_to_string = function
  | Read_recent -> "read_recent"
  | List_recent_resolved -> "list_recent_resolved"
;;

let read_error_to_string error =
  Printf.sprintf "%s: %s" (read_stage_to_string error.stage) error.detail
;;

let record_failure ~keeper_name ~site ?(id = "-") ?(event_type = "-") exn =
  Keeper_fd_pressure.note_exception ~site:("approval_audit." ^ site) exn;
  Otel_metric_store_core.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:[ "keeper", keeper_name; "site", site ]
    ();
  Log.Keeper.warn
    "approval_audit: %s failed keeper=%s id=%s event=%s err=%s"
    site
    keeper_name
    id
    event_type
    (Printexc.to_string exn)
;;

(** Dated JSONL audit trail for approval events.
    Stored at [<base_path>/.masc/audit-approvals/YYYY-MM/DD.jsonl].
    Dashboard and workspace-scoped keeper runs pass [base_path] explicitly so approval
    history stays with the workspace that made the decision. *)
let audit_stores_mu = Stdlib.Mutex.create ()

let audit_io_mutex = Cross_context_mutex.create ()
let audit_stores : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 4

let recent_resolved_history_limit = 20
let audit_wide_scan_min_rows = 500
let audit_wide_scan_multiplier = 64

let wide_audit_scan_window n =
  max audit_wide_scan_min_rows (max n 1 * audit_wide_scan_multiplier)
;;

(* Resolved-history bounds. The wall-clock window is what an operator reasons
   about ("the last day"); the row cap is what keeps one dashboard poll from
   parsing the whole audit store. The two are independent because the store
   interleaves [resolved] rows with far more numerous [summary_updated] and
   [pending] rows, so a row cap alone silently returns fewer decisions as
   non-resolved traffic grows. Both bounds are reported to the caller. *)
let recent_resolved_max_limit = 200
let recent_resolved_default_window_minutes = 1440
let recent_resolved_min_window_minutes = 5
let recent_resolved_max_window_minutes = 10_080
let resolved_history_scan_min_rows = 2_000
let resolved_history_scan_max_rows = 20_000

let resolved_history_scan_rows limit =
  max
    resolved_history_scan_min_rows
    (min
       resolved_history_scan_max_rows
       (max limit 1 * audit_wide_scan_multiplier))
;;

(* A page of resolved decisions plus the evidence needed to tell "this is
   everything in the window" from "this is the newest slice of more". Callers
   that render only [resolved_rows] would repeat the silent truncation this
   record exists to remove. *)
type resolved_history =
  { resolved_rows : Yojson.Safe.t list (* newest first, at most [resolved_limit] *)
  ; resolved_matched : int (* resolved decisions inside the window that were scanned *)
  ; resolved_limit : int
  ; resolved_window_minutes : int
  ; resolved_scan_exhausted : bool
      (* the row cap stopped the scan before it reached the window start *)
  }

let parsed_rows ~stage entries =
  let rec collect acc = function
    | [] -> Ok (List.rev acc)
    | Dated_jsonl.Parsed row :: rest -> collect (row :: acc) rest
    | Dated_jsonl.Malformed_json { path; line_number; detail } :: _ ->
      let location =
        match line_number with
        | Some line -> Printf.sprintf "%s:%d" path line
        | None -> path
      in
      Error
        ({ stage; detail = Printf.sprintf "%s: %s" location detail }
          : read_error)
  in
  collect [] entries
;;

let read_recent_audit_raw store limit =
  match Dated_jsonl.read_recent_result store limit with
  | Error error ->
    Error
      { stage = Read_recent
      ; detail = Dated_jsonl.read_error_to_string error
      }
  | Ok entries -> parsed_rows ~stage:Read_recent entries
;;

(* The vocabulary of the [event] field in the approval audit log. Every writer
   of that log goes through [event_to_string], so this list is the whole
   of it.

   It is a variant rather than a set of string constants because the log has a
   reader in another module — the runtime trust timeline renders each record for
   the operator — and the two drifted. The timeline carried arms for five
   spellings ("expired", "approval_timeout", "cancelled",
   "auto_approved_rule_match", "auto_approved_always") that no writer emits, and
   had no arm for ten that it does, so a successful gate pass and a degraded
   rule store both reached the dashboard as an unlabelled warning. *)
type event =
  | Pending
  | Resolved
  | Summary_updated
  | Rule_created
  | Rule_deleted
  | Grant_consumed
  | Gate_allowed
  | Gate_exact_rule_expired
  | Gate_exact_rule_store_degraded
  | Gate_grant_unavailable
  | Auto_judge_operator_retry_started
  | Auto_judge_block_observation_superseded
  | Auto_judge_restart_worker_recovered
  | Auto_judge_restart_judgment_recovered

let event_to_string = function
  | Pending -> "pending"
  | Resolved -> "resolved"
  | Summary_updated -> "summary_updated"
  | Rule_created -> "rule_created"
  | Rule_deleted -> "rule_deleted"
  | Grant_consumed -> "grant_consumed"
  | Gate_allowed -> "gate_allowed"
  | Gate_exact_rule_expired -> "gate_exact_rule_expired"
  | Gate_exact_rule_store_degraded -> "gate_exact_rule_store_degraded"
  | Gate_grant_unavailable -> "gate_grant_unavailable"
  | Auto_judge_operator_retry_started -> "auto_judge_operator_retry_started"
  | Auto_judge_block_observation_superseded ->
    "auto_judge_block_observation_superseded"
  | Auto_judge_restart_worker_recovered -> "auto_judge_restart_worker_recovered"
  | Auto_judge_restart_judgment_recovered ->
    "auto_judge_restart_judgment_recovered"
;;

(* Records already on disk were written by earlier builds, so the parse is
   partial by necessity. Readers get [None] and must say what they do with a
   spelling this build does not know. *)
let event_of_string = function
  | "pending" -> Some Pending
  | "resolved" -> Some Resolved
  | "summary_updated" -> Some Summary_updated
  | "rule_created" -> Some Rule_created
  | "rule_deleted" -> Some Rule_deleted
  | "grant_consumed" -> Some Grant_consumed
  | "gate_allowed" -> Some Gate_allowed
  | "gate_exact_rule_expired" -> Some Gate_exact_rule_expired
  | "gate_exact_rule_store_degraded" -> Some Gate_exact_rule_store_degraded
  | "gate_grant_unavailable" -> Some Gate_grant_unavailable
  | "auto_judge_operator_retry_started" -> Some Auto_judge_operator_retry_started
  | "auto_judge_block_observation_superseded" ->
    Some Auto_judge_block_observation_superseded
  | "auto_judge_restart_worker_recovered" ->
    Some Auto_judge_restart_worker_recovered
  | "auto_judge_restart_judgment_recovered" ->
    Some Auto_judge_restart_judgment_recovered
  | _ -> None
;;

type write_stage =
  | Store_create
  | Append
  | Append_cleanup

type write_failure =
  { stage : write_stage
  ; detail : string
  }

type receipt =
  { event_type : event
  ; write_result : (unit, write_failure) result
  ; cleanup_failure : write_failure option
  }

let write_stage_to_string = function
  | Store_create -> "store_create"
  | Append -> "append"
  | Append_cleanup -> "append_cleanup"
;;

let receipt_to_yojson receipt =
  let fields =
    [ "event", `String (event_to_string receipt.event_type) ]
  in
  let fields =
    match receipt.cleanup_failure with
    | None -> fields
    | Some failure ->
      ( "cleanup_failure"
      , `Assoc
          [ "stage", `String (write_stage_to_string failure.stage)
          ; "detail", `String failure.detail
          ] )
      :: fields
  in
  match receipt.write_result with
  | Ok () -> `Assoc (("recorded", `Bool true) :: fields)
  | Error failure ->
    `Assoc
      ([ "recorded", `Bool false
       ; "stage", `String (write_stage_to_string failure.stage)
       ; "detail", `String failure.detail
       ]
       @ fields)
;;

let sanitized_write_failure_detail = function
  | Unix.Unix_error (error, operation, _) ->
    let operation =
      operation
      |> Safe_ops.sanitize_text_utf8
      |> String_util.utf8_safe ~max_bytes:80 ~suffix:"..."
      |> String_util.to_string
    in
    Printf.sprintf "%s failed: %s" operation (Unix.error_message error)
  | Sys_error _ -> "approval audit filesystem operation failed"
  | Eio.Io _ -> "approval audit I/O failed"
  | _ -> "approval audit write failed"
;;

(* The [decision_kind] axis of a resolved approval record. The queue derives it
   from the decision itself, so a reader that wants to know whether an approval
   was rejected parses this back instead of scanning the rendered decision text
   for the word. *)
type decision_kind =
  | Decision_approve
  | Decision_reject

let decision_kind_to_string = function
  | Decision_approve -> "approve"
  | Decision_reject -> "reject"
;;

let decision_kind_of_string value =
  match String.trim value with
  | "approve" -> Some Decision_approve
  | "reject" -> Some Decision_reject
  | _ -> None
;;

let non_empty_reason reason =
  let reason = String.trim reason in
  if String.equal reason "" then None else Some reason
;;

let approval_decision_kind_and_reason = function
  | Decision.Approve -> Decision_approve, None
  | Decision.Reject reason -> Decision_reject, non_empty_reason reason
;;

let audit_today_path base_dir =
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  let month = Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) in
  let day = Printf.sprintf "%02d.jsonl" tm.tm_mday in
  let dir = Filename.concat base_dir month in
  Fs_compat.mkdir_p dir;
  Filename.concat dir day
;;

let store_create_probe = Atomic.make (fun ~base_path:_ -> ())

type append_outcome =
  | Append_recorded
  | Append_recorded_with_settlement_failure of write_failure

let append_jsonl_durable path json =
  let suffix = Yojson.Safe.to_string json ^ "\n" in
  match Fs_compat.append_private_jsonl_durable_locked_result path suffix with
  | Private_file_succeeded () -> Append_recorded
  | Private_file_succeeded_with_cleanup_failure
      { value = (); cleanup_failure } ->
    Append_recorded_with_settlement_failure
      { stage = Append_cleanup
      ; detail = sanitized_write_failure_detail cleanup_failure.exception_
      }
  | Private_file_failed error ->
    raise (Sys_error (Fs_compat.private_jsonl_append_error_to_string error))
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    raise
      (Sys_error
         (Printf.sprintf
            "%s; descriptor settlement failed: %s"
            (Fs_compat.private_jsonl_append_error_to_string error)
            (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)))
;;

let append_jsonl = Atomic.make append_jsonl_durable

let get_audit_store ~base_path () =
  let report_failure exn =
    Keeper_fd_pressure.note_exception ~site:"approval_audit.store_create" exn;
    Otel_metric_store_core.inc_counter
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels:
        [ "keeper", "aggregate"
        ; "site", Keeper_approval_queue_failure_site.(to_label Audit_store_create)
        ]
      ();
    Log.Keeper.warn
      "approval_queue: audit store creation failed: %s"
      (Printexc.to_string exn);
    Error (sanitized_write_failure_detail exn)
  in
  try
    match
      Stdlib.Mutex.protect audit_stores_mu (fun () ->
        try
          (Atomic.get store_create_probe) ~base_path;
          Ok
            (match Hashtbl.find_opt audit_stores base_path with
               | Some store -> store
               | None ->
               let dir =
                 Filename.concat
                   (Common.masc_dir_from_base_path ~base_path)
                   "audit-approvals"
               in
               let store = Dated_jsonl.create ~base_dir:dir () in
               Hashtbl.replace audit_stores base_path store;
               store)
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error exn)
    with
    | Ok store -> Ok store
    | Error exn -> report_failure exn
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> report_failure exn
;;

let record
      ~base_path
      ~event_type
      ~id
      ~keeper_name
      ~tool_name
      ?turn_id
      ?task_id
      ?goal_id
      ?rule_match
      ?source_approval_id
      ?actor
      ?decision_source
      ?authorization_source
      ?decision
      ?summary_status
      ?exact_attempt
      ?summary_attempt_disposition
      ?timestamp
      ?(extra_fields = [])
      ()
  =
  let decision, decision_kind, decision_reason =
    match decision with
    | None -> "", None, None
    | Some decision ->
      let kind, reason = approval_decision_kind_and_reason decision in
      approval_decision_to_string decision, Some kind, reason
  in
  let timestamp =
    match timestamp with
    | Some timestamp -> timestamp
    (* NDT-OK: the audit append boundary owns an omitted event timestamp. *)
    | None -> Unix.gettimeofday ()
  in
  match get_audit_store ~base_path () with
  | Error detail ->
    { event_type
    ; write_result = Error { stage = Store_create; detail }
    ; cleanup_failure = None
    }
  | Ok store ->
    let json =
      `Assoc
        ([ "ts", `Float timestamp
         ; "event", `String (event_to_string event_type)
         ; "id", `String id
         ; "keeper", `String keeper_name
         ; "tool", `String tool_name
         ; "decision", `String decision
         ; "turn_id", Json_util.int_opt_to_json turn_id
         ; "task_id", Json_util.string_opt_to_json task_id
         ; "goal_id", Json_util.string_opt_to_json goal_id
         ; "actor", Json_util.string_opt_to_json actor
         ; ( "decision_source"
           , match decision_source with
             | Some source -> `String (decision_source_to_string source)
             | None -> `Null )
           (* Which standing authority allowed this. Without it every blanket
              allow is indistinguishable from an operator approving one exact
              request: both land as decision_source=always_allowed. *)
         ; ( "authorization_source"
           , match authorization_source with
             | Some source -> `String (authorization_source_to_string source)
             | None -> `Null )
         ; ( "rule_match"
           , match rule_match with
             | Some matched -> rule_match_to_yojson matched
             | None -> `Null )
         ; "source_approval_id", Json_util.string_opt_to_json source_approval_id
         ; ( "decision_kind"
           , match decision_kind with
             | Some kind -> `String (decision_kind_to_string kind)
             | None -> `Null )
         ; "decision_reason", Json_util.string_opt_to_json decision_reason
         ; ( "summary_status"
           , match summary_status with
             | Some status -> summary_status_to_yojson status
             | None -> `Null )
         ; ( "exact_attempt"
           , match exact_attempt with
             | Some attempt -> exact_attempt_state_to_yojson attempt
             | None -> `Null )
         ; ( "summary_attempt_disposition"
           , match summary_attempt_disposition with
             | Some disposition ->
               summary_attempt_disposition_to_yojson disposition
             | None -> `Null )
         ]
         @ extra_fields
         )
    in
    let append_result =
      try
        Ok
          (Cross_context_mutex.with_durable_lock audit_io_mutex (fun () ->
             (Atomic.get append_jsonl)
               (audit_today_path (Dated_jsonl.base_dir store))
               json))
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error exn
    in
    (match append_result with
     | Ok Append_recorded ->
       { event_type; write_result = Ok (); cleanup_failure = None }
     | Ok (Append_recorded_with_settlement_failure failure) ->
       record_failure
         ~keeper_name
         ~site:Keeper_approval_queue_failure_site.(to_label Audit_append)
         ~id
         ~event_type:(event_to_string event_type)
         (Sys_error failure.detail);
       { event_type
       ; write_result = Ok ()
       ; cleanup_failure = Some failure
       }
     | Error exn ->
       record_failure
         ~keeper_name
         ~site:Keeper_approval_queue_failure_site.(to_label Audit_append)
         ~id
         ~event_type:(event_to_string event_type)
         exn;
       { event_type
       ; write_result =
           Error
             { stage = Append
             ; detail = sanitized_write_failure_detail exn
             }
       ; cleanup_failure = None
       })
;;

let record_rule ~base_path ~event_type (rule : approval_rule) =
  record
    ~base_path
    ~event_type
    ~id:rule.id
    ~keeper_name:rule.keeper_name
    ~tool_name:rule.tool_name
    ?source_approval_id:rule.source_approval_id
    ()
;;

let audit_scan_window ?keeper_name n =
  match keeper_name with
  | None -> max n 1
  | Some _ ->
    (* Approval audit is global, but runtime trust asks for per-keeper
         "latest" records. Scan a bounded wider window before filtering so a
         busy fleet cannot hide the target keeper behind unrelated events. *)
    wide_audit_scan_window n
;;


let read_recent ~base_path ?keeper_name ?(n = 20) ()
  : (Yojson.Safe.t list, read_error) result
  =
  if n <= 0
  then Ok []
  else (
    match get_audit_store ~base_path () with
    | Error detail -> Error ({ stage = Read_recent; detail } : read_error)
    | Ok store ->
      (match read_recent_audit_raw store (audit_scan_window ?keeper_name n) with
       | Error _ as error -> error
       | Ok raw ->
         let filtered =
           match keeper_name with
           | None -> raw
           | Some name ->
             raw
             |> List.filter (fun json ->
               String.equal name (Safe_ops.json_string ~default:"" "keeper" json))
         in
         Ok (filtered |> List.rev |> List.filteri (fun idx _ -> idx < n))))
;;

let resolved_history_event json =
  match Safe_ops.json_string_opt "event" json with
  | Some event -> String.equal event (event_to_string Resolved)
  | None -> false
;;

let resolved_audit_fields =
  [ "ts"
  ; "event"
  ; "id"
  ; "keeper"
  ; "tool"
  ; "decision"
  ; "turn_id"
  ; "task_id"
  ; "goal_id"
  ; "goal_ids"
  ; "actor"
  ; "decision_source"
  ; "authorization_source"
  ; "rule_match"
  ; "source_approval_id"
  ; "decision_kind"
  ; "decision_reason"
  ; "summary_status"
  ; "exact_attempt"
  ; "summary_attempt_disposition"
  ]
;;

let required_member ~surface key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s.%s is required" surface key)
;;

let required_nonblank_string ~surface key fields =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | Some (`String _) -> Error (Printf.sprintf "%s.%s must be non-blank" surface key)
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string" surface key)
  | None -> Error (Printf.sprintf "%s.%s is required" surface key)
;;

let required_nullable_string ~surface key fields =
  match List.assoc_opt key fields with
  | Some `Null -> Ok None
  | Some (`String value) when String.trim value <> "" -> Ok (Some value)
  | Some (`String _) -> Error (Printf.sprintf "%s.%s must be non-blank" surface key)
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string or null" surface key)
  | None -> Error (Printf.sprintf "%s.%s is required" surface key)
;;

let nullable_string_json = function
  | Some value -> `String value
  | None -> `Null
;;

let required_nullable_nonnegative_int ~surface key fields =
  match List.assoc_opt key fields with
  | Some `Null -> Ok `Null
  | Some (`Int value) when value >= 0 -> Ok (`Int value)
  | Some _ ->
    Error (Printf.sprintf "%s.%s must be a non-negative integer or null" surface key)
  | None -> Error (Printf.sprintf "%s.%s is required" surface key)
;;

let required_finite_timestamp ~surface key fields =
  match List.assoc_opt key fields with
  | Some (`Float value) when Float.is_finite value && value >= 0.0 -> Ok value
  | Some (`Int value) when value >= 0 -> Ok (float_of_int value)
  | Some _ ->
    Error (Printf.sprintf "%s.%s must be a finite non-negative number" surface key)
  | None -> Error (Printf.sprintf "%s.%s is required" surface key)
;;

let resolved_approval_json_of_audit_event json =
  let ( let* ) = Result.bind in
  let surface = "resolved_approval_audit" in
  match json with
  | `Assoc fields ->
    let* () = Json_util.reject_unknown_fields ~surface ~allowed:resolved_audit_fields fields in
    let* event = required_nonblank_string ~surface "event" fields in
    let* () =
      if String.equal event (event_to_string Resolved)
      then Ok ()
      else Error (Printf.sprintf "%s.event must be resolved" surface)
    in
    let* id = required_nonblank_string ~surface "id" fields in
    let* keeper_name = required_nonblank_string ~surface "keeper" fields in
    let* tool_name = required_nonblank_string ~surface "tool" fields in
    let* decision = required_nonblank_string ~surface "decision" fields in
    let* decision_kind_raw = required_nonblank_string ~surface "decision_kind" fields in
    let* decision_kind =
      match decision_kind_of_string decision_kind_raw with
      | Some kind -> Ok kind
      | None -> Error (Printf.sprintf "%s.decision_kind is invalid" surface)
    in
    let* decision_reason = required_nullable_string ~surface "decision_reason" fields in
    let* () =
      match decision_kind with
      | Decision_approve ->
        (match decision_reason with
         | None -> Ok ()
         | Some _ ->
           Error (Printf.sprintf "%s.approve decision cannot carry a reason" surface))
      | Decision_reject ->
        (match decision_reason with
         | Some _ -> Ok ()
         | None -> Error (Printf.sprintf "%s.reject decision requires a reason" surface))
    in
    let* resolved_at = required_finite_timestamp ~surface "ts" fields in
    let* turn_id = required_nullable_nonnegative_int ~surface "turn_id" fields in
    let* task_id = required_nullable_string ~surface "task_id" fields in
    let* goal_id = required_nullable_string ~surface "goal_id" fields in
    let* actor = required_nullable_string ~surface "actor" fields in
    let* decision_source_raw = required_nonblank_string ~surface "decision_source" fields in
    let* () =
      match decision_source_of_string decision_source_raw with
      | Some _ -> Ok ()
      | None -> Error (Printf.sprintf "%s.decision_source is invalid" surface)
    in
    let* authorization_source = required_member ~surface "authorization_source" fields in
    let* rule_match = required_member ~surface "rule_match" fields in
    let* source_approval_id = required_member ~surface "source_approval_id" fields in
    let* summary_status = required_member ~surface "summary_status" fields in
    let* exact_attempt = required_member ~surface "exact_attempt" fields in
    let* summary_attempt_disposition =
      required_member ~surface "summary_attempt_disposition" fields
    in
    let* () =
      match authorization_source, rule_match, source_approval_id, summary_attempt_disposition with
      | `Null, `Null, `Null, `Null -> Ok ()
      | _ -> Error (Printf.sprintf "%s contains fields outside the resolved contract" surface)
    in
    let* () = summary_status_of_yojson_with_error summary_status |> Result.map ignore in
    let* () = exact_attempt_state_of_yojson_with_error exact_attempt |> Result.map ignore in
    Ok
      (`Assoc
          [ "id", `String id
          ; "event", `String event
          ; "keeper_name", `String keeper_name
          ; "tool_name", `String tool_name
          ; "decision", `String decision
          ; "decision_kind", `String (decision_kind_to_string decision_kind)
          ; "decision_reason", nullable_string_json decision_reason
          ; "resolved_at", `Float resolved_at
          ; "turn_id", turn_id
          ; "task_id", nullable_string_json task_id
          ; "goal_id", nullable_string_json goal_id
          ; "actor", nullable_string_json actor
          ; "decision_source", `String decision_source_raw
          ; "summary_status", summary_status
          ; "exact_attempt", exact_attempt
          ])
  | _ -> Error (Printf.sprintf "%s must be an object" surface)
;;

(* Day key for the [YYYY-MM/DD.jsonl] layout. The reasoning this comment used
   to carry -- must stay UTC, because the write path picks the day file with
   [Unix.gmtime] and a local-time key would look in the wrong file -- now lives
   where it can be enforced: both come from one [Unix.gmtime] call inside
   [Jsonl_writer]. Still pinned by [test_keeper_approval_resolved_history.ml]. *)
let day_string_of_ts ts = Jsonl_writer.day_key ~ts

let clamp_int value ~low ~high = max low (min high value)

let resolved_history_empty ~limit ~window_minutes =
  { resolved_rows = []
  ; resolved_matched = 0
  ; resolved_limit = limit
  ; resolved_window_minutes = window_minutes
  ; resolved_scan_exhausted = false
  }
;;

let project_resolved_rows rows =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | row :: rest ->
      (match resolved_approval_json_of_audit_event row with
       | Ok projected -> loop (projected :: acc) rest
       | Error detail ->
         Error ({ stage = List_recent_resolved; detail } : read_error))
  in
  loop [] rows
;;

let list_recent_resolved
      ~base_path
      ~now_ts
      ?(limit = recent_resolved_history_limit)
      ?(window_minutes = recent_resolved_default_window_minutes)
      ()
  : (resolved_history, read_error) result
  =
  let limit = clamp_int limit ~low:0 ~high:recent_resolved_max_limit in
  let window_minutes =
    clamp_int
      window_minutes
      ~low:recent_resolved_min_window_minutes
      ~high:recent_resolved_max_window_minutes
  in
  let empty = resolved_history_empty ~limit ~window_minutes in
  if limit <= 0
  then Ok empty
  else (
    match get_audit_store ~base_path () with
    | Error detail ->
      Error ({ stage = List_recent_resolved; detail } : read_error)
    | Ok store ->
      let window_start =
        now_ts -. (float_of_int window_minutes *. Masc_time_constants.minute)
      in
      let scan_rows = resolved_history_scan_rows limit in
      (match Dated_jsonl.read_recent_result store scan_rows with
       | Error error ->
         Error
           { stage = List_recent_resolved
           ; detail = Dated_jsonl.read_error_to_string error
           }
       | Ok entries ->
         (match parsed_rows ~stage:List_recent_resolved entries with
          | Error _ as error -> error
          | Ok scanned ->
         let scanned_count = List.length scanned in
         (* The row cap only hides decisions when it stopped us before we
            reached back to the window start. If the oldest row we read is
            already older than the window, the window is fully covered and the
            cap is irrelevant. *)
         let scan_exhausted =
           scanned_count >= scan_rows
           &&
           match scanned with
           | [] -> true
           | oldest :: _ ->
             (match Safe_ops.json_float_opt "ts" oldest with
              | None -> true
              | Some ts -> ts > window_start)
         in
         (* An undated row cannot be placed in a wall-clock window, so it is
            excluded rather than dated by guesswork. The audit writer always
            stamps [ts]; this is the boundary that keeps a future regression
            from silently mis-dating history. *)
         let matched_rows =
           scanned
           |> List.filter_map (fun json ->
             if resolved_history_event json
             then (
               match Safe_ops.json_float_opt "ts" json with
               | Some ts when ts >= window_start -> Some (ts, json)
               | Some _ | None -> None)
             else None)
           (* Newest first by timestamp, not by file position. The audit writer
              stamps [ts] before it takes the append lock, so two concurrent
              resolutions can land in the file in the opposite order from the
              one they were decided in. [stable_sort] keeps file order as the
              tie-break for identical stamps. *)
           |> List.stable_sort (fun (left, _) (right, _) -> Float.compare right left)
           |> List.map snd
         in
         let selected_rows =
           matched_rows |> List.filteri (fun idx _ -> idx < limit)
         in
         (match project_resolved_rows selected_rows with
          | Error _ as error -> error
          | Ok rows ->
            Ok
              { resolved_rows = rows
              ; resolved_matched = List.length matched_rows
              ; resolved_limit = limit
              ; resolved_window_minutes = window_minutes
              ; resolved_scan_exhausted = scan_exhausted
              }))))
;;

module For_testing = struct
  let reset_store () =
    Stdlib.Mutex.protect audit_stores_mu (fun () -> Hashtbl.clear audit_stores);
    Atomic.set store_create_probe (fun ~base_path:_ -> ());
    Atomic.set append_jsonl append_jsonl_durable
  ;;

  let set_store_create_probe probe = Atomic.set store_create_probe probe
  let set_append_jsonl append =
    Atomic.set append_jsonl (fun path json ->
      append path json;
      Append_recorded)
  ;;

  let set_append_jsonl_cleanup_failure detail =
    Atomic.set append_jsonl (fun _path _json ->
      Append_recorded_with_settlement_failure
        { stage = Append_cleanup; detail })
  ;;

  let with_audit_io_lock f =
    Cross_context_mutex.with_durable_lock audit_io_mutex f
  ;;
end
