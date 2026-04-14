(** Audit Log Writer for MASC

    Writes audit events to .masc/audit.jsonl for security monitoring.
    JSONL format for grep-ability and stream processing.

    Security basis:
    - Open Challenges in MAS Security (arxiv:2505.02077v1)
    - Immutable audit trails for post-incident analysis

    @since 0.6.0 - MASC Social v4 Tier 1
*)

module StringMap = Map.Make (String)

(** {1 Types} *)

type outcome =
  | Success
  | Failure of string

type action =
  | Join
  | Leave
  | ClaimTask
  | StartTask
  | DoneTask
  | CancelTask
  | ReleaseTask
  | Broadcast
  | Suspend
  | ToolCall of string
  | AuthSuccess
  | AuthFailure
  | CircuitOpen
  | CircuitClose
  | SearchRefinement
  | GovernanceDecision of string
  | Custom of string

type audit_entry = {
  timestamp: float;
  agent_id: string;
  action: action;
  room_id: string option;
  details: Yojson.Safe.t;
  outcome: outcome;
  cost_estimate: float option;
  token_count: int option;
  trace_id: string option;
}

let preview ?(max_len = 200) (value : string) =
  let len = String.length value in
  if len <= max_len then value else String.sub value 0 max_len ^ "..."

(** {1 Serialization} *)

let action_to_string = function
  | Join -> "join"
  | Leave -> "leave"
  | ClaimTask -> "claim_task"
  | StartTask -> "start_task"
  | DoneTask -> "done_task"
  | CancelTask -> "cancel_task"
  | ReleaseTask -> "release_task"
  | Broadcast -> "broadcast"
  | Suspend -> "suspend"
  | ToolCall name -> "tool_call:" ^ name
  | AuthSuccess -> "auth_success"
  | AuthFailure -> "auth_failure"
  | CircuitOpen -> "circuit_open"
  | CircuitClose -> "circuit_close"
  | SearchRefinement -> "search_refinement"
  | GovernanceDecision decision -> "governance_decision:" ^ decision
  | Custom name -> "custom:" ^ name

let string_to_action = function
  | "join" -> Join
  | "leave" -> Leave
  | "claim_task" -> ClaimTask
  | "start_task" -> StartTask
  | "done_task" -> DoneTask
  | "cancel_task" -> CancelTask
  | "release_task" -> ReleaseTask
  | "broadcast" -> Broadcast
  | "suspend" -> Suspend
  | "auth_success" -> AuthSuccess
  | "auth_failure" -> AuthFailure
  | "circuit_open" -> CircuitOpen
  | "circuit_close" -> CircuitClose
  | "search_refinement" -> SearchRefinement
  | s when String.length s > 10 && String.sub s 0 10 = "tool_call:" ->
      ToolCall (String.sub s 10 (String.length s - 10))
  | s when String.length s > 20 && String.sub s 0 20 = "governance_decision:" ->
      GovernanceDecision (String.sub s 20 (String.length s - 20))
  | s when String.length s > 7 && String.sub s 0 7 = "custom:" ->
      Custom (String.sub s 7 (String.length s - 7))
  | s -> Custom s

let outcome_to_json = function
  | Success -> `Assoc [("status", `String "success")]
  | Failure reason -> `Assoc [
      ("status", `String "failure");
      ("reason", `String reason);
    ]

let entry_to_json (e : audit_entry) : Yojson.Safe.t =
  let base = [
    ("timestamp", `Float e.timestamp);
    ("agent_id", `String e.agent_id);
    ("action", `String (action_to_string e.action));
    ("room_id", Json_util.string_opt_to_json e.room_id);
    ("details", e.details);
    ("outcome", outcome_to_json e.outcome);
  ] in
  let with_cost = match e.cost_estimate with
    | Some c -> base @ [("cost_estimate", `Float c)]
    | None -> base
  in
  let with_tokens = match e.token_count with
    | Some t -> with_cost @ [("token_count", `Int t)]
    | None -> with_cost
  in
  let with_trace = match e.trace_id with
    | Some tid -> with_tokens @ [("trace_id", `String tid)]
    | None -> with_tokens
  in
  `Assoc with_trace

(** Parse a JSON object back into an audit_entry.
    Returns Error with reason on parse failure (never silently drops). *)
let entry_of_json_r (json : Yojson.Safe.t) : (audit_entry, string) result =
  try
    let module U = Yojson.Safe.Util in
    let timestamp = json |> U.member "timestamp" |> U.to_float in
    let agent_id = json |> U.member "agent_id" |> U.to_string in
    let action = json |> U.member "action" |> U.to_string |> string_to_action in
    let room_id = json |> U.member "room_id" |> U.to_string_option in
    let details =
      match Safe_ops.json_member_opt "details" json with
      | Some v -> v
      | None -> `Null
    in
    let outcome =
      let o = json |> U.member "outcome" in
      let status = o |> U.member "status" |> U.to_string in
      if status = "success" then Success
      else
        let reason = Safe_ops.json_string ~default:"unknown" "reason" o in
        Failure reason
    in
    let cost_estimate = Safe_ops.json_float_opt "cost_estimate" json in
    let token_count = Safe_ops.json_int_opt "token_count" json in
    let trace_id = Safe_ops.json_string_opt "trace_id" json in
    Ok { timestamp; agent_id; action; room_id; details; outcome; cost_estimate; token_count; trace_id }
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    (* Redact details field to prevent sensitive content leaking into logs *)
    let redacted = match json with
      | `Assoc fields ->
        let safe_fields = List.filter_map (fun (k, v) ->
          if k = "details" then Some (k, `String "<redacted>")
          else Some (k, v)
        ) fields in
        `Assoc safe_fields
      | _ -> `String "<non-object>"
    in
    let snippet = preview (Yojson.Safe.to_string redacted) in
    Error (Printf.sprintf "%s | json: %s" (Printexc.to_string exn) snippet)

(** Lenient wrapper: logs warning and returns option for backward compat *)
let entry_of_json (json : Yojson.Safe.t) : audit_entry option =
  match entry_of_json_r json with
  | Ok entry -> Some entry
  | Error reason ->
      Log.Misc.warn "audit_log: entry parse failed: %s" reason;
      None

(** {1 File Operations} *)

type config = Room_utils.config

(** Legacy single-file path (for fallback reads). *)
let legacy_audit_path (config : config) =
  let masc_dir = Room_utils.masc_dir config in
  Filename.concat masc_dir "audit.jsonl"

(** Date-split store: [.masc/audit/YYYY-MM/DD.jsonl].
    Cached per base_dir so all callers share the same Eio.Mutex.

    The cache itself is protected by [audit_store_cache_mu] so that
    two concurrent [get_audit_store] calls for the same base dir
    cannot install two [Dated_jsonl.t] records with different inner
    [Eio.Mutex] instances — otherwise file I/O to the same
    [YYYY-MM/DD.jsonl] path would serialise through two different
    mutexes and racing appends could interleave on disk.  Under the
    current single-domain Eio with a non-yielding [Dated_jsonl.create]
    this race does not fire today, but the fix is cheap and removes a
    fragile implicit invariant. *)
let audit_store_cache : Dated_jsonl.t StringMap.t ref = ref StringMap.empty
let audit_store_cache_mu = Eio.Mutex.create ()

let get_audit_store (config : config) : Dated_jsonl.t =
  let base = Filename.concat (Room_utils.masc_dir config) "audit" in
  Eio_guard.with_mutex audit_store_cache_mu (fun () ->
    match StringMap.find_opt base !audit_store_cache with
    | Some store -> store
    | None ->
      let store = Dated_jsonl.create ~base_dir:base () in
      audit_store_cache := StringMap.add base store !audit_store_cache;
      store)

(** Parse JSON list into audit entries. Logs first 5 failures individually,
    then a summary. Returns only successfully parsed entries. *)
let max_logged_errors = 5

let parse_entries (jsons : Yojson.Safe.t list) : audit_entry list =
  let ok = ref [] in
  let err_count = ref 0 in
  List.iter (fun json ->
    match entry_of_json_r json with
    | Ok entry -> ok := entry :: !ok
    | Error reason ->
        incr err_count;
        if !err_count <= max_logged_errors then
          Log.Misc.error "audit_log: corrupt entry (#%d): %s" !err_count reason
  ) jsons;
  if !err_count > 0 then
    Log.Misc.error "audit_log: %d/%d entries failed to parse (possible corruption)%s"
      !err_count (List.length jsons)
      (if !err_count > max_logged_errors
       then Printf.sprintf " (%d more suppressed)" (!err_count - max_logged_errors)
       else "");
  List.rev !ok

(** Read recent audit entries.
    Tries date-split store first; falls back to legacy single file.
    Legacy JSON parse failures are logged at WARN (rate-limited, first N only).
    Structural parse failures go through [parse_entries] ERROR path. *)
let read_entries ?(n = 10_000) (config : config) : audit_entry list =
  let store = get_audit_store config in
  let entries = Dated_jsonl.read_recent store n in
  if entries <> [] then
    parse_entries entries
  else
    let path = legacy_audit_path config in
    if not (Sys.file_exists path) then []
    else
      let content = Fs_compat.load_file path in
      let invalid_count = ref 0 in
      let jsons = String.split_on_char '\n' content
        |> List.filter (fun line -> String.trim line <> "")
        |> List.filter_map (fun line ->
            match Yojson.Safe.from_string line with
            | json -> Some json
            | exception Yojson.Json_error msg ->
                incr invalid_count;
                if !invalid_count <= max_logged_errors then
                  Log.Misc.warn "audit_log: invalid JSON line (#%d): %s | line: %s"
                    !invalid_count msg (preview ~max_len:100 line);
                None) in
      if !invalid_count > 0 then
        Log.Misc.warn "audit_log: %d invalid JSON line(s) in legacy audit log%s"
          !invalid_count
          (if !invalid_count > max_logged_errors
           then Printf.sprintf " (%d more suppressed)" (!invalid_count - max_logged_errors)
           else "");
      parse_entries jsons

(** Append a single entry to the audit log (thread-safe via Dated_jsonl). *)
let append_entry (config : config) (entry : audit_entry) =
  let store = get_audit_store config in
  Dated_jsonl.append store (entry_to_json entry)

(** {1 Logging API} *)

let log_action
    (config : config)
    ~agent_id
    ~action
    ?(room_id : string option)
    ?(details : Yojson.Safe.t = `Null)
    ?(cost_estimate : float option)
    ?(token_count : int option)
    ?(trace_id : string option)
    ~outcome
    () =
  let entry = {
    timestamp = Time_compat.now ();
    agent_id;
    action;
    room_id;
    details;
    outcome;
    cost_estimate;
    token_count;
    trace_id;
  } in
  append_entry config entry

(** Convenience functions for common events *)

let log_join config ~agent_id ?cost_estimate ?token_count () =
  log_action config ~agent_id ~action:Join
    ?cost_estimate ?token_count ~outcome:Success ()

let log_leave config ~agent_id ?cost_estimate ?token_count () =
  log_action config ~agent_id ~action:Leave
    ?cost_estimate ?token_count ~outcome:Success ()

let log_claim_task config ~agent_id ~task_id ?cost_estimate ?token_count () =
  log_action config ~agent_id ~action:ClaimTask
    ~details:(`Assoc [("task_id", `String task_id)])
    ?cost_estimate ?token_count ~outcome:Success ()

let log_done_task config ~agent_id ~task_id ?cost_estimate ?token_count () =
  log_action config ~agent_id ~action:DoneTask
    ~details:(`Assoc [("task_id", `String task_id)])
    ?cost_estimate ?token_count ~outcome:Success ()

let log_cancel_task config ~agent_id ~task_id ~reason ?cost_estimate ?token_count () =
  log_action config ~agent_id ~action:CancelTask
    ~details:(`Assoc [
      ("task_id", `String task_id);
      ("reason", `String reason);
    ])
    ?cost_estimate ?token_count ~outcome:Success ()

let log_broadcast config ~agent_id ~message_preview ?cost_estimate ?token_count () =
  (* Truncate message for privacy/size *)
  let preview = preview ~max_len:100 message_preview in
  log_action config ~agent_id ~action:Broadcast
    ~details:(`Assoc [("preview", `String preview)])
    ?cost_estimate ?token_count ~outcome:Success ()

let log_suspend config ~agent_id ~target_agent ~reason ~rooms_affected ?cost_estimate ?token_count () =
  log_action config ~agent_id ~action:Suspend
    ~details:(`Assoc [
      ("target_agent", `String target_agent);
      ("reason", `String reason);
      ("rooms_affected", `Int rooms_affected);
    ])
    ?cost_estimate ?token_count ~outcome:Success ()

let log_tool_call config ~agent_id ~tool_name ~success ~error_msg ?cost_estimate ?token_count ?trace_id () =
  let outcome = if success then Success else Failure (Option.value error_msg ~default:"unknown") in
  log_action config ~agent_id ~action:(ToolCall tool_name) ?cost_estimate ?token_count ?trace_id ~outcome ()

let remove_assoc_keys keys fields =
  List.filter (fun (key, _) -> not (List.mem key keys)) fields

let log_system_internal_tool_call config ~agent_id ~tool_name ~success ~error_msg
    ?(details : Yojson.Safe.t = `Null) ?cost_estimate ?token_count ?trace_id () =
  let outcome =
    if success then Success else Failure (Option.value error_msg ~default:"unknown")
  in
  let details =
    match details with
    | `Assoc fields ->
        let caller_fields = remove_assoc_keys [ "surface"; "tool_name" ] fields in
        `Assoc
          (("surface", `String "system_internal")
          :: ("tool_name", `String tool_name)
          :: caller_fields)
    | other ->
        `Assoc
          [
            ("surface", `String "system_internal");
            ("tool_name", `String tool_name);
            ("context", other);
          ]
  in
  log_action config ~agent_id ~action:(Custom "system_internal_tool_call")
    ~details ?cost_estimate ?token_count ?trace_id ~outcome ()

let log_client_tool_host_failure config ~agent_id ~client_name ~tool_name
    ~transport ~message ?phase ?request_id ?session_id ?trace_id ?timeout_ms () =
  let details =
    `Assoc
      (List.filter_map
         Fun.id
         [
           Some ("client_name", `String client_name);
           Some ("tool_name", `String tool_name);
           Some ("transport", `String transport);
           Option.map (fun value -> ("phase", `String value)) phase;
           Option.map (fun value -> ("request_id", `String value)) request_id;
           Option.map (fun value -> ("session_id", `String value)) session_id;
           Option.map (fun value -> ("timeout_ms", `Int value)) timeout_ms;
         ])
  in
  log_action config ~agent_id ~action:(Custom "client_tool_host_failure")
    ~details ?trace_id ~outcome:(Failure message) ()

let log_auth_attempt config ~agent_id ~success ~method_name ?cost_estimate ?token_count () =
  let action = if success then AuthSuccess else AuthFailure in
  log_action config ~agent_id ~action
    ~details:(`Assoc [("method", `String method_name)])
    ?cost_estimate ?token_count
    ~outcome:(if success then Success else Failure "auth_failed") ()

let log_circuit_breaker config ~agent_id ~opened ~reason ?cost_estimate ?token_count () =
  let action = if opened then CircuitOpen else CircuitClose in
  log_action config ~agent_id ~action
    ~details:(`Assoc [("reason", `String reason)])
    ?cost_estimate ?token_count ~outcome:Success ()

let log_governance_decision config ~agent_id ~trace_id ~decision ~action_type ~confirmation_state () =
  log_action config ~agent_id
    ~action:(GovernanceDecision decision)
    ~trace_id
    ~details:(`Assoc [
      ("action_type", `String action_type);
      ("confirmation_state", `String confirmation_state);
    ])
    ~outcome:Success ()

(** {1 Pruning (replaces rotation)} *)

(** Prune audit entries older than [days] days.
    Date-split storage makes rotation unnecessary. *)
let prune_old (config : config) ~days =
  let store = get_audit_store config in
  let deleted = Dated_jsonl.prune store ~days in
  if deleted > 0 then
    Log.Misc.info "Pruned %d old audit day-files" deleted

(** {1 Statistics} *)

type stats = {
  total_entries: int;
  file_size_bytes: int;
  oldest_timestamp: float option;
  newest_timestamp: float option;
}

let get_stats (config : config) =
  let store = get_audit_store config in
  (* Read a large window to compute stats *)
  let entries = Dated_jsonl.read_recent store 100_000 in
  let count = List.length entries in
  let oldest = ref None in
  let newest = ref None in
  List.iter (fun json ->
    (match Safe_ops.json_float_opt "timestamp" json with
     | Some ts ->
       if !oldest = None then oldest := Some ts;
       newest := Some ts
     | None -> ())
  ) entries;
  {
    total_entries = count;
    file_size_bytes = 0; (* no longer a single file *)
    oldest_timestamp = !oldest;
    newest_timestamp = !newest;
  }

let stats_to_json (s : stats) : Yojson.Safe.t =
  `Assoc [
    ("total_entries", `Int s.total_entries);
    ("file_size_bytes", `Int s.file_size_bytes);
    ("oldest_timestamp", Json_util.float_opt_to_json s.oldest_timestamp);
    ("newest_timestamp", Json_util.float_opt_to_json s.newest_timestamp);
  ]
