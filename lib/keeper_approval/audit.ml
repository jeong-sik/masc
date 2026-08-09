open Keeper_approval_queue_rules_types

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

(* Runtime trust asks for per-keeper latest audit state across the same global
   audit tail. Cache the raw tail briefly so a keeper snapshot does one shared
   JSONL read instead of N identical scans. *)
type recent_audit_cache_entry =
  { rows : Yojson.Safe.t list
  ; observed_at : float
  }
;;

let recent_audit_cache_mu = Stdlib.Mutex.create ()
let recent_audit_cache : (string, recent_audit_cache_entry) Hashtbl.t =
  Hashtbl.create 4
;;

let recent_audit_cache_ttl_sec = 1.0
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

let recent_audit_cache_key store limit =
  Printf.sprintf "%s:%d" (Dated_jsonl.base_dir store) limit
;;

let invalidate_recent_audit_cache_for_store store =
  let prefix = Dated_jsonl.base_dir store ^ ":" in
  Stdlib.Mutex.protect recent_audit_cache_mu (fun () ->
    Hashtbl.filter_map_inplace
      (fun key entry -> if String.starts_with ~prefix key then None else Some entry)
      recent_audit_cache)
;;

let read_recent_audit_raw store limit =
  let key = recent_audit_cache_key store limit in
  let now = Unix.gettimeofday () in
  let cached =
    Stdlib.Mutex.protect recent_audit_cache_mu (fun () ->
      match Hashtbl.find_opt recent_audit_cache key with
      | Some entry when now -. entry.observed_at <= recent_audit_cache_ttl_sec ->
        Some entry.rows
      | _ -> None)
  in
  match cached with
  | Some rows -> rows
  | None ->
    let rows = Dated_jsonl.read_recent store limit in
    Stdlib.Mutex.protect recent_audit_cache_mu (fun () ->
      Hashtbl.replace recent_audit_cache key { rows; observed_at = now });
    rows
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

let keeper_audit_metric_label = function
  | Some keeper when String.trim keeper <> "" -> keeper
  | Some _ | None -> "aggregate"
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
    None
  in
  try
    match
      Stdlib.Mutex.protect audit_stores_mu (fun () ->
        try
          Ok
            (match Hashtbl.find_opt audit_stores base_path with
             | Some store -> Some store
             | None ->
               let dir =
                 Filename.concat
                   (Common.masc_dir_from_base_path ~base_path)
                   "audit-approvals"
               in
               let store = Dated_jsonl.create ~base_dir:dir () in
               Hashtbl.replace audit_stores base_path store;
               Some store)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn -> Error exn)
    with
    | Ok store -> store
    | Error exn -> report_failure exn
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
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
      ?(goal_ids = [])
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
  | None -> ()
  | Some store ->
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
         ; "goal_ids", `List (List.map (fun goal -> `String goal) goal_ids)
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
         ]
         @ (match rule_match with
            | Some matched -> [ "rule_match", rule_match_to_yojson matched ]
            | None -> [])
         @ (match source_approval_id with
            | Some approval_id -> [ "source_approval_id", `String approval_id ]
            | None -> [])
         @ (match decision_kind with
            | Some kind ->
              [ "decision_kind", `String (decision_kind_to_string kind) ]
            | None -> [])
         @ (match decision_reason with
            | Some reason -> [ "decision_reason", `String reason ]
            | None -> [])
         @ (match summary_status with
            | Some status -> [ "summary_status", summary_status_to_yojson status ]
            | None -> [])
         @ (match exact_attempt with
            | Some attempt ->
              [ "exact_attempt", exact_attempt_state_to_yojson attempt ]
            | None -> [])
         @ (match summary_attempt_disposition with
            | Some disposition ->
              [ ( "summary_attempt_disposition"
                , summary_attempt_disposition_to_yojson disposition ) ]
            | None -> [])
         @ extra_fields
         )
    in
    Cross_context_mutex.with_durable_lock audit_io_mutex (fun () ->
      try
        Fs_compat.append_jsonl (audit_today_path (Dated_jsonl.base_dir store)) json;
        invalidate_recent_audit_cache_for_store store
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> record_failure ~keeper_name ~site:"audit_append" ~id
          ~event_type:(event_to_string event_type) exn)
;;

let record_rule ~base_path ~event_type ~actor (rule : approval_rule) =
  record
    ~base_path
    ~event_type
    ~id:rule.id
    ~keeper_name:rule.keeper_name
    ~tool_name:rule.tool_name
    ~source_approval_id:rule.source_approval_id
    ~actor
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


let record_audit_read_failure ?keeper_name ?(metric_site = Keeper_approval_queue_failure_site.Audit_read_recent) ~site exn =
  Keeper_fd_pressure.note_exception ~site exn;
  Otel_metric_store_core.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:
      [ "keeper",
        keeper_audit_metric_label keeper_name;
        "site",
        Keeper_approval_queue_failure_site.to_label metric_site
      ]
    ()
;;

let read_recent ~base_path ?keeper_name ?(n = 20) () : Yojson.Safe.t list =
  if n <= 0
  then []
  else (
    match get_audit_store ~base_path () with
    | None -> []
    | Some store ->
      try
        let raw = read_recent_audit_raw store (audit_scan_window ?keeper_name n) in
        let filtered =
          match keeper_name with
          | None -> raw
          | Some name ->
            raw
            |> List.filter (fun json ->
              String.equal name (Safe_ops.json_string ~default:"" "keeper" json))
        in
        filtered |> List.rev |> List.filteri (fun idx _ -> idx < n)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        record_audit_read_failure ?keeper_name ~site:"approval_audit.read_recent" exn;
        [])
;;

let json_member_or_null key json =
  match Json_util.assoc_member_opt key json with
  | Some value -> value
  | None -> `Null
;;

let resolved_approval_decision_kind json =
  Option.bind
    (Safe_ops.json_string_opt "decision_kind" json)
    decision_kind_of_string
;;

let resolved_history_event json =
  match Safe_ops.json_string_opt "event" json with
  | Some event -> String.equal event (event_to_string Resolved)
  | None -> false
;;

let resolved_approval_json_of_audit_event json =
  let resolved_at = Safe_ops.json_float_opt "ts" json in
  `Assoc
    [ "id", `String (Safe_ops.json_string ~default:"" "id" json)
    ; "event", `String (Safe_ops.json_string ~default:"" "event" json)
    ; "keeper_name", `String (Safe_ops.json_string ~default:"" "keeper" json)
    ; "tool_name", `String (Safe_ops.json_string ~default:"" "tool" json)
    ; "decision", Json_util.string_opt_to_json_trimmed (Safe_ops.json_string_opt "decision" json)
    ; "decision_kind", Json_util.string_opt_to_json_trimmed
        (Option.map decision_kind_to_string (resolved_approval_decision_kind json))
    ; "decision_reason", json_member_or_null "decision_reason" json
    ; "resolved_at", Json_util.float_opt_to_json resolved_at
    ; "turn_id", json_member_or_null "turn_id" json
    ; "task_id", json_member_or_null "task_id" json
    ; "goal_id", json_member_or_null "goal_id" json
    ; "goal_ids", json_member_or_null "goal_ids" json
    ; "actor", json_member_or_null "actor" json
    ; "decision_source", json_member_or_null "decision_source" json
    ; "rule_match", json_member_or_null "rule_match" json
      (* Judge evidence recorded at resolution time (#26126). Events written
         before that enrichment have no such members and project as [`Null]. *)
    ; "summary_status", json_member_or_null "summary_status" json
    ; "exact_attempt", json_member_or_null "exact_attempt" json
    ]
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

let list_recent_resolved
      ~base_path
      ~now_ts
      ?(limit = recent_resolved_history_limit)
      ?(window_minutes = recent_resolved_default_window_minutes)
      ()
  : resolved_history
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
  then empty
  else (
    match get_audit_store ~base_path () with
    | None -> empty
    | Some store ->
      (try
         let window_start =
           now_ts -. (float_of_int window_minutes *. Masc_time_constants.minute)
         in
         let scan_rows = resolved_history_scan_rows limit in
         (* Chronological, oldest first, tail-bounded to [scan_rows]. *)
         let scanned =
           Dated_jsonl.read_range_recent
             store
             ~since:(day_string_of_ts window_start)
             ~until:(day_string_of_ts now_ts)
             scan_rows
         in
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
         let rows =
           matched_rows
           |> List.filteri (fun idx _ -> idx < limit)
           |> List.map resolved_approval_json_of_audit_event
         in
         { resolved_rows = rows
         ; resolved_matched = List.length matched_rows
         ; resolved_limit = limit
         ; resolved_window_minutes = window_minutes
         ; resolved_scan_exhausted = scan_exhausted
         }
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         record_audit_read_failure
           ~metric_site:Keeper_approval_queue_failure_site.Audit_list_recent_resolved
           ~site:"approval_audit.list_recent_resolved"
           exn;
         empty))
;;

module For_testing = struct
  let reset_store () =
    Stdlib.Mutex.protect audit_stores_mu (fun () -> Hashtbl.clear audit_stores);
    Stdlib.Mutex.protect recent_audit_cache_mu (fun () ->
      Hashtbl.clear recent_audit_cache)
  ;;
end
