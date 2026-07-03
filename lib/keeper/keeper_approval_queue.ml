(** Keeper_approval_queue — Eio.Promise-based HITL approval for keeper tools.

    When a keeper's OAS Agent invokes a tool that requires approval,
    the agent fiber is suspended via [Eio.Promise.await].  An operator
    can then approve/reject via the dashboard approval HTTP handler
    or the CLI.

    Types, rules, fingerprint — extracted to [Keeper_approval_queue_rules]. *)

include Keeper_approval_queue_rules


(* ── Persistent audit log ────────────────────────────────── *)

(* Stdlib.Mutex: the store registry critical section only mutates an in-memory
   hashtable and creates a Dated_jsonl handle. It is also used by synchronous
   tests outside an Eio context, so an Eio mutex would either raise Get_context
   or poison the registry after a recoverable store-creation failure. *)
(** Dated JSONL audit trail for approval events.
    Stored at [<base_path>/.masc/audit-approvals/YYYY-MM/DD.jsonl].
    Dashboard and workspace-scoped keeper runs pass [base_path] explicitly so approval
    history stays with the workspace that made the decision. *)
let audit_stores_mu = Stdlib.Mutex.create ()

let audit_io_mu = Stdlib.Mutex.create ()
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

let approval_audit_pending_event = "pending"
let approval_audit_resolved_event = "resolved"
let approval_audit_hard_forbidden_event = "hard_forbidden"
let approval_audit_summary_event = "summary_updated"
let approval_sse_pending_event = "approval:pending"
let approval_sse_resolved_event = "approval:resolved"
let approval_sse_summary_event = "approval:summary_updated"

let non_empty_reason reason =
  let reason = String.trim reason in
  if String.equal reason "" then None else Some reason
;;

let approval_audit_decision_kind_and_reason = function
  | Approval_resolved Agent_sdk.Hooks.Approve -> "approve", None
  | Approval_resolved (Agent_sdk.Hooks.Reject reason) -> "reject", non_empty_reason reason
  | Approval_resolved (Agent_sdk.Hooks.Edit _) -> "edit", None
  | Approval_expired reason -> "reject", non_empty_reason reason
;;

let approval_audit_disposition_fields = function
  | Approval_escalated reason -> "escalated", non_empty_reason reason
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
    Otel_metric_store.inc_counter
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
      mutex_protect_allow_reentrant audit_stores_mu (fun () ->
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

let audit_approval_event
      ~base_path
      ~event_type
      ~id
      ~keeper_name
      ~tool_name
      ~risk_level
      ?turn_id
      ?task_id
      ?goal_id
      ?(goal_ids = [])
      ?sandbox_target
      ?runtime_contract
      ?selected_model
      ?audit_disposition
      ?disposition
      ?disposition_reason
      ?rule_match
      ?source_approval_id
      ?auto_approved
      ?decision
      ()
  =
  let decision, decision_kind, decision_reason =
    match decision with
    | None -> "", None, None
    | Some decision ->
      let kind, reason = approval_audit_decision_kind_and_reason decision in
      approval_audit_decision_to_string decision, Some kind, reason
  in
  let disposition, disposition_reason =
    match audit_disposition with
    | None -> disposition, disposition_reason
    | Some audit_disposition ->
      if Option.is_some disposition || Option.is_some disposition_reason then
        invalid_arg
          "audit_approval_event: audit_disposition cannot be combined with raw disposition fields";
      let disposition, reason = approval_audit_disposition_fields audit_disposition in
      Some disposition, reason
  in
  match get_audit_store ~base_path () with
  | None -> ()
  | Some store ->
    let json =
      `Assoc
        ([ "ts", `Float (Unix.gettimeofday ())
         ; "event", `String event_type
         ; "id", `String id
         ; "keeper", `String keeper_name
         ; "tool", `String tool_name
         ; "risk", `String (risk_level_to_string risk_level)
         ; "decision", `String decision
         ; "turn_id", Json_util.int_opt_to_json turn_id
         ; "task_id", Json_util.string_opt_to_json task_id
         ; "goal_id", Json_util.string_opt_to_json goal_id
         ; "goal_ids", `List (List.map (fun goal -> `String goal) goal_ids)
         ; "selected_model", `Null
         ; "sandbox_target", Json_util.string_opt_to_json sandbox_target
         ; "disposition", Json_util.string_opt_to_json disposition
         ; "disposition_reason", Json_util.string_opt_to_json disposition_reason
         ]
         @ (match runtime_contract with
            | Some json -> [ "runtime_contract", json ]
            | None -> [])
         @ (match rule_match with
            | Some matched -> [ "rule_match", rule_match_to_yojson matched ]
            | None -> [])
         @ (match source_approval_id with
            | Some approval_id -> [ "source_approval_id", `String approval_id ]
            | None -> [])
         @ (match decision_kind with
            | Some kind -> [ "decision_kind", `String kind ]
            | None -> [])
         @ (match decision_reason with
            | Some reason -> [ "decision_reason", `String reason ]
            | None -> [])
         @
         match auto_approved with
         | Some value -> [ "auto_approved", `Bool value ]
         | None -> [])
    in
    mutex_protect_allow_reentrant audit_io_mu (fun () ->
      try
        Fs_compat.append_jsonl (audit_today_path (Dated_jsonl.base_dir store)) json;
        invalidate_recent_audit_cache_for_store store
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> record_queue_failure ~keeper_name ~site:"audit_append" ~id ~event_type exn)
;;

let audit_rule_event ~base_path ~event_type (rule : approval_rule) =
  audit_approval_event
    ~base_path
    ~event_type
    ~id:rule.id
    ~keeper_name:rule.keeper_name
    ~tool_name:rule.tool_name
    ~risk_level:rule.max_risk
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

let resolved_audit_scan_window = wide_audit_scan_window

let record_audit_read_failure ?keeper_name ?(metric_site = Keeper_approval_queue_failure_site.Audit_read_recent) ~site exn =
  Keeper_fd_pressure.note_exception ~site exn;
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:
      [ "keeper",
        keeper_audit_metric_label keeper_name;
        "site",
        Keeper_approval_queue_failure_site.to_label metric_site
      ]
    ()
;;

let read_recent_audit ~base_path ?keeper_name ?(n = 20) () : Yojson.Safe.t list =
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

let closed_decision_kind_of_string value =
  match String.trim value with
  | "approve" -> Some "approve"
  | "reject" -> Some "reject"
  | "edit" -> Some "edit"
  | _ -> None
;;

let legacy_decision_kind_of_string value =
  let value = String.trim value in
  match closed_decision_kind_of_string value with
  | Some _ as kind -> kind
  | None when String.starts_with ~prefix:"reject:" value -> Some "reject"
  | None -> None
;;

let resolved_approval_decision_kind json =
  match Option.bind (Safe_ops.json_string_opt "decision_kind" json) closed_decision_kind_of_string with
  | Some _ as kind -> kind
  | None ->
    Option.bind (Safe_ops.json_string_opt "decision" json) legacy_decision_kind_of_string
;;

let resolved_history_event json =
  match Safe_ops.json_string_opt "event" json with
  | Some event ->
    String.equal event approval_audit_resolved_event
    || String.equal event approval_audit_hard_forbidden_event
  | None -> false
;;

let resolved_approval_json_of_audit_event json =
  let resolved_at = Safe_ops.json_float_opt "ts" json in
  `Assoc
    [ "id", `String (Safe_ops.json_string ~default:"" "id" json)
    ; "event", `String (Safe_ops.json_string ~default:"" "event" json)
    ; "keeper_name", `String (Safe_ops.json_string ~default:"" "keeper" json)
    ; "tool_name", `String (Safe_ops.json_string ~default:"" "tool" json)
    ; "risk_level", `String (Safe_ops.json_string ~default:"" "risk" json)
    ; "decision", Json_util.string_opt_to_json_trimmed (Safe_ops.json_string_opt "decision" json)
    ; "decision_kind", Json_util.string_opt_to_json_trimmed (resolved_approval_decision_kind json)
    ; "decision_reason", json_member_or_null "decision_reason" json
    ; "resolved_at", Json_util.float_opt_to_json resolved_at
    ; ( "resolved_at_iso",
        match resolved_at with
        | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
        | None -> `Null )
    ; "turn_id", json_member_or_null "turn_id" json
    ; "task_id", json_member_or_null "task_id" json
    ; "goal_id", json_member_or_null "goal_id" json
    ; "goal_ids", json_member_or_null "goal_ids" json
    ; "sandbox_target", json_member_or_null "sandbox_target" json
    ; "disposition", json_member_or_null "disposition" json
    ; "disposition_reason", json_member_or_null "disposition_reason" json
    ; "rule_match", json_member_or_null "rule_match" json
    ]
;;

let list_recent_resolved_json ~base_path ?(n = recent_resolved_history_limit) ()
  : Yojson.Safe.t list
  =
  if n <= 0
  then []
  else (
    match get_audit_store ~base_path () with
    | None -> []
    | Some store ->
      try
        read_recent_audit_raw store (resolved_audit_scan_window n)
        |> List.filter resolved_history_event
        |> List.rev
        |> List.filteri (fun idx _ -> idx < n)
        |> List.map resolved_approval_json_of_audit_event
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        record_audit_read_failure
          ~metric_site:Keeper_approval_queue_failure_site.Audit_list_recent_resolved
          ~site:"approval_audit.list_recent_resolved"
          exn;
        [])
;;

let generate_id () = make_generated_id "appr"

let normalized_input_hash (input : Yojson.Safe.t) =
  Digestif.SHA256.(digest_string (Yojson.Safe.to_string input) |> to_hex)
;;

let first_cmd_token (cmd : string) =
  Keeper_tool_command_words.first_token_of_cmd cmd
;;

module For_testing = struct
  let reset_audit_store () =
    Stdlib.Mutex.protect audit_stores_mu (fun () -> Hashtbl.clear audit_stores);
    Stdlib.Mutex.protect recent_audit_cache_mu (fun () ->
      Hashtbl.clear recent_audit_cache)
  ;;

  let first_cmd_token = first_cmd_token

  let get_pending_entry ~id = SMap.find_opt id (Atomic.get pending)
end

let action_key_of_input ~tool_name ~(input : Yojson.Safe.t) =
  match Safe_ops.json_string_opt "op" input with
  | Some op when String.trim op <> "" -> "op:" ^ String.trim op
  | _ ->
    (match Safe_ops.json_string_opt "action" input with
     | Some action when String.trim action <> "" -> "action:" ^ String.trim action
     | _ ->
       (match Safe_ops.json_string_opt "kind" input with
        | Some kind when String.trim kind <> "" -> "kind:" ^ String.trim kind
        | _ ->
          (match
             Safe_ops.json_string_opt "cmd" input
             |> fun value -> Option.bind value first_cmd_token
           with
           | Some token -> "cmd:" ^ token
           | None -> "tool:" ^ tool_name)))
;;

let sandbox_target_of_runtime_contract = function
  | Some runtime_contract ->
    (match Safe_ops.json_string_opt "sandbox_target" runtime_contract with
     | Some target when String.trim target <> "" -> String.trim target
     | _ ->
       (match Safe_ops.json_string_opt "backend" runtime_contract with
        | Some backend when String.trim backend <> "" -> String.trim backend
        | _ -> "unknown"))
  | None -> "unknown"
;;

let input_preview_of_json (json : Yojson.Safe.t) =
  (* Per-leaf marker-aware truncation: a naive [String.sub] on the
     serialized form would chop a [masc:blob ...] marker mid-field and
     leave sha256/bytes/mime malformed so the approval-queue viewer
     cannot round-trip the preview. *)
  let json = Observability_redact.preview_json_strings ~max_len:200 json in
  let raw = Yojson.Safe.to_string json in
  Observability_redact.redact_preview ~max_len:200 raw
;;

let create_entry
      ~id
      ~keeper_name
      ~tool_name
      ~input
      ~risk_level
      ?turn_id
      ?task_id
      ?goal_id
      ?(goal_ids = [])
      ?sandbox_target
      ?sandbox_profile
      ?backend
      ?runtime_contract
      ?selected_model
      ?disposition
      ?disposition_reason
      ~audit_base_path
      ~resolver
      ~on_resolution
      ()
  =
  let action_key = action_key_of_input ~tool_name ~input in
  let input_hash = normalized_input_hash input in
  let sandbox_target =
    match nonempty_string_opt sandbox_target with
    | Some target -> target
    | None -> sandbox_target_of_runtime_contract runtime_contract
  in
  let sandbox_profile =
    sandbox_profile_of_runtime_context ?sandbox_profile runtime_contract
  in
  let backend = backend_of_runtime_context ?backend runtime_contract in
  { id
  ; keeper_name
  ; tool_name
  ; action_key
  ; input_hash
  ; sandbox_target
  ; sandbox_profile
  ; backend
  ; input
  ; risk_level
  ; requested_at = Unix.gettimeofday ()
  ; turn_id
  ; task_id
  ; goal_id
  ; goal_ids
  ; runtime_contract
  ; selected_model
  ; disposition
  ; disposition_reason
  ; phase = Awaiting_operator
  ; audit_base_path
  ; resolver
  ; on_resolution
  ; context_summary = None
  ; summary_status = Summary_not_requested
  }
;;

let update_pending_phase ~id phase =
  atomic_update pending (fun map ->
    match SMap.find_opt id map with
    | None -> map
    | Some entry ->
      let entry' = { entry with phase } in
      SMap.add id entry' map);
  match SMap.find_opt id (Atomic.get pending) with
  | Some entry when entry.phase = phase -> Some entry
  | Some entry ->
    Log.Keeper.warn
      "approval_queue: update_pending_phase id=%s phase race current=%s expected=%s"
      id
      (pending_phase_to_string entry.phase)
      (pending_phase_to_string phase);
    None
  | None ->
    Log.Keeper.warn
      "approval_queue: update_pending_phase id=%s not found"
      id;
    None
;;

let pending_entry_json_fields
      ?(include_requested_at_iso = false)
      ?(include_runtime_contract = false)
      ?(include_input = false)
      (entry : pending_approval)
  =
  [ "id", `String entry.id
  ; "keeper_name", `String entry.keeper_name
  ; "tool_name", `String entry.tool_name
  ; "action_key", `String entry.action_key
  ; "sandbox_target", `String entry.sandbox_target
  ; "risk_level", `String (risk_level_to_string entry.risk_level)
  ; "phase", `String (pending_phase_to_string entry.phase)
  ; "requested_at", `Float entry.requested_at
  ; "waiting_s", `Float (Unix.gettimeofday () -. entry.requested_at)
  ; "turn_id", Json_util.int_opt_to_json entry.turn_id
  ; "task_id", Json_util.string_opt_to_json entry.task_id
  ; "goal_id", Json_util.string_opt_to_json entry.goal_id
  ; "goal_ids", `List (List.map (fun goal -> `String goal) entry.goal_ids)
  ; "selected_model", `Null
  ; "disposition", Json_util.string_opt_to_json entry.disposition
  ; "disposition_reason", Json_util.string_opt_to_json entry.disposition_reason
  ]
  @ (if include_requested_at_iso
     then
       [ ( "requested_at_iso"
         , `String (Masc_domain.iso8601_of_unix_seconds entry.requested_at) )
       ]
     else [])
  @ (if include_runtime_contract
     then
       [ ( "runtime_contract"
         , match entry.runtime_contract with
           | Some json -> json
           | None when String.equal entry.sandbox_target "unknown" -> `Null
           | None ->
             `Assoc
               [ "backend", `String entry.sandbox_target
               ; "sandbox_target", `String entry.sandbox_target
               ] )
       ]
     else [])
  @
  if include_input
  then
    [ "input", entry.input; "input_preview", `String (input_preview_of_json entry.input) ]
  else []
  @
  [ "summary_status", summary_status_to_yojson entry.summary_status
  ; ( "context_summary"
    , match entry.context_summary with
      | Some summary -> hitl_context_summary_to_yojson summary
      | None -> `Null )
  ]
;;

let broadcast_pending entry =
  try
    Sse.broadcast
      (`Assoc
          [ "type", `String approval_sse_pending_event
          ; ( "payload"
            , `Assoc
                (pending_entry_json_fields
                   ~include_runtime_contract:true
                   ~include_input:true
                   entry) )
          ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    record_queue_failure
      ~keeper_name:entry.keeper_name
      ~site:"broadcast_pending"
      ~id:entry.id
      ~event_type:approval_audit_pending_event
      exn
;;

let record_pending (entry : pending_approval) =
  Log.Keeper.info
    "HITL_APPROVAL_PENDING: id=%s keeper=%s tool=%s risk=%s"
    entry.id
    entry.keeper_name
    entry.tool_name
    (risk_level_to_string entry.risk_level);
  audit_approval_event
    ~base_path:entry.audit_base_path
    ~event_type:approval_audit_pending_event
    ~id:entry.id
    ~keeper_name:entry.keeper_name
    ~tool_name:entry.tool_name
    ~risk_level:entry.risk_level
    ?turn_id:entry.turn_id
    ?task_id:entry.task_id
    ?goal_id:entry.goal_id
    ~goal_ids:entry.goal_ids
    ~sandbox_target:entry.sandbox_target
    ?runtime_contract:entry.runtime_contract
    ?selected_model:entry.selected_model
    ?disposition:entry.disposition
    ?disposition_reason:entry.disposition_reason
    ();
  broadcast_pending entry
;;

let record_summary_updated ~now (entry : pending_approval) =
  (try
     match get_audit_store ~base_path:entry.audit_base_path () with
     | None -> ()
     | Some store ->
       let json =
         `Assoc
           [ "ts", `Float now
           ; "event", `String approval_audit_summary_event
           ; "id", `String entry.id
           ; "summary_status", summary_status_to_yojson entry.summary_status
           ]
       in
       mutex_protect_allow_reentrant audit_io_mu (fun () ->
         Fs_compat.append_jsonl (audit_today_path (Dated_jsonl.base_dir store)) json;
         invalidate_recent_audit_cache_for_store store)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     record_queue_failure
       ~keeper_name:entry.keeper_name
       ~site:"audit_summary"
       ~id:entry.id
       ~event_type:approval_audit_summary_event
       exn);
  try
    Sse.broadcast
      (`Assoc
         [ "type", `String approval_sse_summary_event
         ; ( "payload"
           , `Assoc
               (pending_entry_json_fields
                  ~include_runtime_contract:true
                  ~include_input:false
                  entry) )
         ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    record_queue_failure
      ~keeper_name:entry.keeper_name
      ~site:"broadcast_summary"
      ~id:entry.id
      ~event_type:approval_sse_summary_event
      exn
;;

(* ── In-place entry updates (copy-on-write) ──────────────── *)

(** Read a pending entry by id. Returns [None] if already resolved. *)
let get_pending_entry ~id : pending_approval option = SMap.find_opt id (Atomic.get pending)

(** Apply [f] to the pending entry with [id] if it still exists.
    Used by the HITL context-summary worker for non-blocking updates. *)
let update_pending_entry ~id f =
  atomic_update pending (fun map ->
    match SMap.find_opt id map with
    | None -> map
    | Some entry -> SMap.add id (f entry) map)
;;

let provider_config_for_summary () =
  let runtime_id = Keeper_config.default_runtime_id () in
  match Runtime.get_runtime_by_id runtime_id with
  | Some rt -> Some rt.Runtime.provider_config
  | None -> None
;;

let spawn_hitl_summary_worker ~sw ~(entry : pending_approval) =
  let now = Time_compat.now () in
  match entry.risk_level with
  | Low -> ()
  | Medium | High | Critical ->
    update_pending_entry ~id:entry.id (fun e ->
      { e with summary_status = Summary_pending });
    let on_summary summary =
      update_pending_entry ~id:entry.id (fun e ->
        { e with
          context_summary = Some summary
        ; summary_status = Summary_available summary
        });
      match get_pending_entry ~id:entry.id with
      | Some updated -> record_summary_updated ~now updated
      | None -> ()
    in
    let on_failure ~reason ~retryable =
      update_pending_entry ~id:entry.id (fun e ->
        { e with summary_status = Summary_failed { reason; retryable } });
      match get_pending_entry ~id:entry.id with
      | Some updated -> record_summary_updated ~now updated
      | None -> ()
    in
    match provider_config_for_summary () with
    | None ->
      on_failure ~reason:"HITL summary: no runtime provider config available" ~retryable:false
    | Some config ->
      Hitl_summary_worker.spawn ~sw ~entry ~provider_config:config ~on_summary ~on_failure ()
;;

let resolve_entry ~base_path (entry : pending_approval) (decision : decision) =
  let decision_str = approval_decision_to_string decision in
  Log.Keeper.info
    "HITL_APPROVAL_RESOLVED: id=%s keeper=%s tool=%s decision=%s"
    entry.id
    entry.keeper_name
    entry.tool_name
    decision_str;
  audit_approval_event
    ~base_path:base_path
    ~event_type:approval_audit_resolved_event
    ~id:entry.id
    ~keeper_name:entry.keeper_name
    ~tool_name:entry.tool_name
    ~risk_level:entry.risk_level
    ?turn_id:entry.turn_id
    ?task_id:entry.task_id
    ?goal_id:entry.goal_id
    ~goal_ids:entry.goal_ids
    ~sandbox_target:entry.sandbox_target
    ?runtime_contract:entry.runtime_contract
    ?selected_model:entry.selected_model
    ?disposition:entry.disposition
    ?disposition_reason:entry.disposition_reason
    ~decision:(Approval_resolved decision)
    ();
  (match entry.resolver with
   | Some resolver -> Eio.Promise.resolve resolver decision
   | None -> ());
  (match entry.on_resolution with
   | Some f ->
     Cancel_safe.observe
       ~on_exn:(fun exn ->
         Otel_metric_store.inc_counter Keeper_metrics.(to_string LifecycleCallbackFailures)
           ~labels:[ ("keeper", entry.keeper_name); ("callback", "on_resolution") ]
           ();
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string ApprovalQueueFailures)
           ~labels:[ "keeper", entry.keeper_name; "site", Keeper_approval_queue_failure_site.(to_label Resolution_callback) ]
           ();
         Log.Keeper.warn
           "approval_queue: resolution callback failed id=%s err=%s"
           entry.id
           (Printexc.to_string exn))
       (fun () -> f decision)
   | None -> ());
  try
    Sse.broadcast
      (`Assoc
          [ "type", `String approval_sse_resolved_event
          ; ( "payload"
            , `Assoc
                [ "id", `String entry.id
                ; "keeper_name", `String entry.keeper_name
                ; "tool_name", `String entry.tool_name
                ; "decision", `String decision_str
                ; "selected_model", `Null
                ; "disposition", Json_util.string_opt_to_json entry.disposition
                ; ( "disposition_reason"
                  , Json_util.string_opt_to_json entry.disposition_reason )
                ] )
          ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    record_queue_failure
      ~keeper_name:entry.keeper_name
      ~site:"broadcast_resolved"
      ~id:entry.id
      ~event_type:approval_audit_resolved_event
      exn
;;

let pending_entry_matches
      (entry : pending_approval)
      ~keeper_name
      ~tool_name
      ~action_key
      ~input_hash
      ~task_id
      ~goal_id
      ~sandbox_target
  =
  String.equal entry.keeper_name keeper_name
  && String.equal entry.tool_name tool_name
  && String.equal entry.action_key action_key
  && String.equal entry.input_hash input_hash
  && String.equal entry.sandbox_target sandbox_target
  && entry.task_id = task_id
  && entry.goal_id = goal_id
;;

let find_pending_id_in_map
      (map : pending_approval SMap.t)
      ~keeper_name
      ~tool_name
      ~action_key
      ~input_hash
      ~task_id
      ~goal_id
      ~sandbox_target
  =
  SMap.fold
    (fun id (entry : pending_approval) acc ->
       match acc with
       | Some _ -> acc
       | None ->
         if
           pending_entry_matches
             entry
             ~keeper_name
             ~tool_name
             ~action_key
             ~input_hash
             ~task_id
             ~goal_id
             ~sandbox_target
         then Some id
         else None)
    map
    None
;;

let sort_entries_by_requested_at entries =
  List.sort
    (fun left right ->
       let ts_of_json json = (match Json_util.assoc_member_opt "requested_at" json with Some (`Float f) -> f | Some (`Int n) -> Float.of_int n | _ -> 0.0) in
       Float.compare (ts_of_json left) (ts_of_json right))
    entries
;;

(* ── Submit & await ───────────────────────────────────────── *)

(** Submit a tool call for approval and suspend the calling fiber.
    Returns the operator's decision when the promise is resolved.
    Called from the OAS approval_callback (inside agent fiber).

    [timeout_s] defaults to {!default_noncritical_approval_timeout_s}
    for non-[Critical] approvals. This is intentionally longer than the
    30s wrapper used by A2 for generic [Eio.Promise.await] sites: a HITL
    approval is bounded by an operator's response time, not by an SLA on
    autonomous progress.
    [Critical] approvals are exempt, matching [expire_stale]'s
    operator-must-decide policy. Drop the default only after measuring
    the operator-response distribution — premature shortening turns
    every distracted operator into an [Approval_expired] event. *)
let submit_and_await
      ~keeper_name
      ~tool_name
      ~input
      ~risk_level
      ~base_path
      ?turn_id
      ?task_id
      ?goal_id
      ?(goal_ids = [])
      ?sandbox_target
      ?sandbox_profile
      ?backend
      ?runtime_contract
      ?selected_model
      ?disposition
      ?disposition_reason
      ?clock
      ?(timeout_s = default_noncritical_approval_timeout_s)
      ?(critical_escalation_after_s = default_critical_approval_escalation_after_s)
      ()
  : Agent_sdk.Hooks.approval_decision
  =
  let id = generate_id () in
  let promise, resolver = Eio.Promise.create () in
  let entry =
    create_entry
      ~id
      ~keeper_name
      ~tool_name
      ~input
      ~risk_level
      ?turn_id
      ?task_id
      ?goal_id
      ~goal_ids
      ?sandbox_target
      ?sandbox_profile
      ?backend
      ?runtime_contract
      ?selected_model
      ?disposition
      ?disposition_reason
      ~audit_base_path:base_path
      ~resolver:(Some resolver)
      ~on_resolution:None
      ()
  in
  atomic_update pending (fun map -> SMap.add id entry map);
  record_pending entry;
  let () =
    match Eio_context.get_switch_opt () with
    | Some sw -> spawn_hitl_summary_worker ~sw ~entry
    | None -> ()
  in
  let timeout_decision reason =
    let decision = Agent_sdk.Hooks.Reject reason in
    match Eio.Promise.peek promise with
    | Some observed -> observed
    | None ->
      (try Eio.Promise.resolve resolver decision with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | _ -> ());
      (match Eio.Promise.peek promise with
       | Some observed -> observed
       | None -> decision)
  in
  let await_with_timeout () =
    match clock, risk_level with
    | Some clock, (Low | Medium | High) ->
      (match
         Eio.Fiber.first
           (fun () -> `Decision (Eio.Promise.await promise))
           (fun () ->
              Eio.Time.sleep clock timeout_s;
              `Timeout)
       with
       | `Decision d -> d
       | `Timeout ->
         let reason = Printf.sprintf "approval timeout after %.0fs" timeout_s in
         audit_approval_event
           ~base_path:entry.audit_base_path
           ~event_type:"approval_timeout"
           ~id
           ~keeper_name
           ~tool_name
           ~risk_level
           ?turn_id
           ?task_id
           ?goal_id
           ~goal_ids
           ~sandbox_target:entry.sandbox_target
           ?runtime_contract
           ?selected_model
           ~decision:(Approval_expired reason)
           ();
         (* Mirror expire_stale's teardown, but preserve any concurrent
            operator decision that wins the promise resolution race. *)
         timeout_decision reason)
    | Some clock, Critical ->
      (match
         Eio.Fiber.first
           (fun () -> `Decision (Eio.Promise.await promise))
           (fun () ->
              Eio.Time.sleep clock critical_escalation_after_s;
              `Escalated)
       with
       | `Decision d -> d
       | `Escalated ->
         let reason = "critical approval escalated — operator must decide" in
         audit_approval_event
           ~base_path:entry.audit_base_path
           ~event_type:"approval_escalated"
           ~id
           ~keeper_name
           ~tool_name
           ~risk_level
           ?turn_id
           ?task_id
           ?goal_id
           ~goal_ids
           ~sandbox_target:entry.sandbox_target
           ?runtime_contract
           ?selected_model
           ~audit_disposition:(Approval_escalated reason)
           ();
         (match update_pending_phase ~id Escalated with
          | Some escalated_entry -> broadcast_pending escalated_entry
          | None -> ());
         (* Escalated — keep waiting for operator, do not reject *)
         Eio.Promise.await promise)
    | None, _ -> Eio.Promise.await promise
  in
  Eio_guard.protect await_with_timeout ~finally:(fun () ->
    Safe_ops.protect ~default:() (fun () ->
      (match Eio.Promise.peek promise with
       | Some _ -> ()
       | None ->
         let reason = "approval await cancelled before operator decision" in
         audit_approval_event
           ~base_path:entry.audit_base_path
           ~event_type:"cancelled"
           ~id
           ~keeper_name
           ~tool_name
           ~risk_level
           ?turn_id
           ?task_id
           ?goal_id
           ~goal_ids
           ~sandbox_target:entry.sandbox_target
           ?runtime_contract
           ?selected_model
           ?disposition
           ?disposition_reason
           ~decision:(Approval_expired reason)
           ());
      atomic_update pending (fun map -> SMap.remove id map)))
;;

let submit_pending
      ~keeper_name
      ~tool_name
      ~input
      ~risk_level
      ~base_path
      ?turn_id
      ?task_id
      ?goal_id
      ?(goal_ids = [])
      ?sandbox_target
      ?sandbox_profile
      ?backend
      ?runtime_contract
      ?selected_model
      ?disposition
      ?disposition_reason
      ~on_resolution
      ()
  : string
  =
  let action_key = action_key_of_input ~tool_name ~input in
  let input_hash = normalized_input_hash input in
  let sandbox_target =
    match nonempty_string_opt sandbox_target with
    | Some target -> target
    | None -> sandbox_target_of_runtime_contract runtime_contract
  in
  let rec submit () =
    let map = Atomic.get pending in
    match
      find_pending_id_in_map
        map
        ~keeper_name
        ~tool_name
        ~action_key
        ~input_hash
        ~task_id
        ~goal_id
        ~sandbox_target
    with
    | Some id -> id
    | None ->
      let id = generate_id () in
      let entry =
        create_entry
          ~id
          ~keeper_name
          ~tool_name
          ~input
          ~risk_level
          ?turn_id
          ?task_id
          ?goal_id
          ~goal_ids
          ~sandbox_target
          ?sandbox_profile
          ?backend
          ?runtime_contract
          ?selected_model
          ?disposition
          ?disposition_reason
          ~audit_base_path:base_path
          ~resolver:None
          ~on_resolution:(Some on_resolution)
          ()
      in
      let updated = SMap.add id entry map in
      if Atomic.compare_and_set pending map updated
      then (
        record_pending entry;
        let () =
          match Eio_context.get_switch_opt () with
          | Some sw -> spawn_hitl_summary_worker ~sw ~entry
          | None -> ()
        in
        id)
      else submit ()
  in
  submit ()
;;

(* ── Resolve (operator action) ────────────────────────────── *)

type resolve_error =
  | Not_found of string
  | Already_resolved of string

let resolve_error_to_string = function
  | Not_found id -> Printf.sprintf "approval %s not found" id
  | Already_resolved id -> Printf.sprintf "approval %s already resolved" id
;;

let remember_rule_for_entry ~base_path ?created_by (entry : pending_approval) =
  let rememberable =
    match entry.risk_level with
    | Low | Medium -> true
    | High | Critical -> false
  in
  if not rememberable
  then None
  else (
    try
      let rule, created =
        upsert_rule
          ~base_path:base_path
          ~keeper_name:entry.keeper_name
          ~tool_name:entry.tool_name
          ~input:entry.input
          ~risk_level:entry.risk_level
          ?sandbox_profile:entry.sandbox_profile
          ?backend:entry.backend
          ?runtime_contract:entry.runtime_contract
          ?created_by
          ~source_approval_id:entry.id
          ()
      in
      if created then audit_rule_event ~base_path:base_path ~event_type:"rule_created" rule;
      Some rule
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ApprovalQueueFailures)
        ~labels:[ "keeper", entry.keeper_name; "site", Keeper_approval_queue_failure_site.(to_label Remember_rule) ]
        ();
      Log.Keeper.warn
        "approval_queue: remember rule failed id=%s err=%s"
        entry.id
        (Printexc.to_string exn);
      None)
;;

let resolve_with_policy
      ~base_path
      ~id
      ~(decision : Agent_sdk.Hooks.approval_decision)
      ?(remember_rule = false)
      ?created_by
      ()
  : (resolution_result, resolve_error) result
  =
  let result = ref (Error (Not_found id)) in
  atomic_update pending (fun map ->
    match SMap.find_opt id map with
    | None -> map
    | Some entry ->
      result := Ok entry;
      SMap.remove id map);
  match !result with
  | Error _ as err -> err
  | Ok entry ->
    let remembered_rule =
      match decision with
      | Agent_sdk.Hooks.Approve when remember_rule ->
        remember_rule_for_entry ~base_path ?created_by entry
      | _ -> None
    in
    resolve_entry ~base_path entry decision;
    Ok { remembered_rule }
;;

(** Resolve a pending approval. Returns [Ok ()] if found and resolved,
    [Error (Not_found _)] if the id is not in the queue, or
    [Error (Already_resolved _)] if the atomic update found no matching
    entry (concurrent resolve race).
    Called from the dashboard approval HTTP handler
    ([server_dashboard_http.ml]) and MCP runtime.

    [base_path] is sourced from the entry's captured [audit_base_path]
    rather than threaded from the caller: the convenience wrapper takes
    only an [id], so the entry is the authoritative workspace source
    (RFC-0274 Wave A). *)
let resolve ~id ~(decision : Agent_sdk.Hooks.approval_decision)
  : (unit, resolve_error) result
  =
  (* The entry is the authoritative base_path source for the convenience
     wrapper: it has no caller-threaded [base_path], and the pending map
     is per-workspace so the entry's captured [audit_base_path] is the
     workspace that owns the approval. RFC-0274 Wave A. *)
  match SMap.find_opt id (Atomic.get pending) with
  | None -> Error (Not_found id)
  | Some entry ->
    (match resolve_with_policy ~base_path:entry.audit_base_path ~id ~decision () with
     | Ok _ -> Ok ()
     | Error _ as err -> err)
;;

(* ── Query ────────────────────────────────────────────────── *)

(** List all pending approvals as JSON. *)
let list_pending_json () : Yojson.Safe.t =
  let entries =
    SMap.fold
      (fun _id entry acc -> `Assoc (pending_entry_json_fields entry) :: acc)
      (Atomic.get pending)
      []
  in
  `List (sort_entries_by_requested_at entries)
;;

let list_pending_dashboard_json () : Yojson.Safe.t =
  let entries =
    SMap.fold
      (fun _id entry acc ->
         `Assoc
           (pending_entry_json_fields
              ~include_requested_at_iso:true
              ~include_runtime_contract:true
              ~include_input:true
              entry)
         :: acc)
      (Atomic.get pending)
      []
  in
  `List (sort_entries_by_requested_at entries)
;;

let pending_entry_detail_json (entry : pending_approval) : Yojson.Safe.t =
  `Assoc
    (pending_entry_json_fields
       ~include_requested_at_iso:true
       ~include_runtime_contract:true
       ~include_input:true
       entry)
;;

let get_pending_json ~id : Yojson.Safe.t option =
  match SMap.find_opt id (Atomic.get pending) with
  | None -> None
  | Some entry -> Some (pending_entry_detail_json entry)
;;

let pending_count () : int = SMap.cardinal (Atomic.get pending)

let pending_count_for_keeper ~keeper_name : int =
  SMap.fold
    (fun _ (entry : pending_approval) count ->
       if String.equal entry.keeper_name keeper_name then count + 1 else count)
    (Atomic.get pending)
    0
;;

let has_pending_for_keeper ~keeper_name : bool =
  SMap.fold
    (fun _ (entry : pending_approval) acc ->
       acc || String.equal entry.keeper_name keeper_name)
    (Atomic.get pending)
    false
;;

(* ── Timeout cleanup ──────────────────────────────────────── *)

(** Reject all approvals that have been waiting longer than [max_wait_s].
    Call periodically from a health loop.

    [Critical] risk-level entries are NEVER auto-expired.  They originate
    from indefinite-wait operator gates ([keeper_continue_after_reconcile],
    [keeper_continue_after_partial_commit] — see callers in
    [Keeper_supervisor] and [Keeper_unified_turn]) where:

    - Auto-rejecting would cause the supervisor's Phase-2 sweep to
      re-enqueue the same approval on the next tick (since the
      paused-meta blocker class is unchanged), creating a 30-min
      expire / re-enqueue / expire cycle that flooded the audit log
      and starved the operator of agency.
    - Critical decisions (auto-compact retry exhaustion, partial-commit
      ambiguity) are exactly the cases where a human MUST decide; a
      stale 30-min default would silently push the keeper into a
      permanent [paused = true] state that no autonomous logic can
      recover from.

    Operators escalate a stuck Critical entry by manual resolve via
    dashboard / mcp / CLI — the timeout policy applies to
    [Low / Medium / High] tool approvals only. *)
let expire_stale ~max_wait_s =
  let now = Unix.gettimeofday () in
  let stale_ref = ref [] in
  atomic_update pending (fun map ->
    let stale =
      SMap.fold
        (fun id entry acc ->
           match entry.risk_level with
           | Critical -> acc
           | Low | Medium | High ->
             if now -. entry.requested_at > max_wait_s then (id, entry) :: acc else acc)
        map
        []
    in
    stale_ref := stale;
    List.fold_left (fun acc (id, _) -> SMap.remove id acc) map stale);
  let stale = !stale_ref in
  List.iter
    (fun (id, entry) ->
       let reason =
         Printf.sprintf "approval timed out after %.0fs" (now -. entry.requested_at)
       in
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string ApprovalQueueFailures)
         ~labels:[ "keeper", entry.keeper_name; "site", Keeper_approval_queue_failure_site.(to_label Approval_expired) ]
         ();
       Log.Keeper.warn
         "HITL_APPROVAL_EXPIRED: id=%s keeper=%s tool=%s"
         id
         entry.keeper_name
         entry.tool_name;
       audit_approval_event
         ~base_path:entry.audit_base_path
         ~event_type:"expired"
         ~id
         ~keeper_name:entry.keeper_name
         ~tool_name:entry.tool_name
         ~risk_level:entry.risk_level
         ?turn_id:entry.turn_id
         ?task_id:entry.task_id
         ?goal_id:entry.goal_id
         ~goal_ids:entry.goal_ids
         ~sandbox_target:entry.sandbox_target
         ?runtime_contract:entry.runtime_contract
         ?selected_model:entry.selected_model
         ?disposition:entry.disposition
         ?disposition_reason:entry.disposition_reason
         ~decision:(Approval_expired reason)
         ();
       (match entry.resolver with
        | Some resolver -> Eio.Promise.resolve resolver (Agent_sdk.Hooks.Reject reason)
        | None -> ());
       match entry.on_resolution with
       | Some f ->
         Cancel_safe.observe
           ~on_exn:(fun exn ->
             Otel_metric_store.inc_counter Keeper_metrics.(to_string LifecycleCallbackFailures)
               ~labels:[ ("keeper", entry.keeper_name); ("callback", "on_approval_expire") ]
               ();
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string ApprovalQueueFailures)
               ~labels:[ "keeper", entry.keeper_name; "site", Keeper_approval_queue_failure_site.(to_label Expire_callback) ]
               ();
             Log.Keeper.warn
               "approval_queue: expire callback failed id=%s err=%s"
               id
               (Printexc.to_string exn))
           (fun () -> f (Agent_sdk.Hooks.Reject reason))
       | None -> ())
    stale
;;
