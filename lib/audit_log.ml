(** Audit Log Writer for MASC

    Writes audit events to .masc/audit/YYYY-MM/DD.jsonl for security monitoring.
    JSONL format for grep-ability and stream processing.

    Security basis:
    - Open Challenges in MAS Security (arxiv:2505.02077v1)
    - Immutable audit trails for post-incident analysis

    @since 0.6.0 - MASC Social v4 Tier 1
*)

module StringMap = Set_util.StringMap

(** {1 Types} *)

type outcome =
  | Success [@tla.symbol "success"]
  | Failure of string [@tla.symbol "failure"]
[@@deriving tla]

type gate_audit_decision =
  | Gate_allow [@tla.symbol "gate_allow"]
  | Gate_require_confirmation [@tla.symbol "gate_require_confirmation"]
  | Gate_deny [@tla.symbol "gate_deny"]
  | Gate_confirm [@tla.symbol "gate_confirm"]
  | Gate_expired [@tla.symbol "gate_expired"]
  | Gate_unauthorized [@tla.symbol "gate_unauthorized"]
  | Gate_other of string [@tla.symbol "gate_other"]
[@@deriving tla]

type action =
  | ClaimTask [@tla.symbol "claim_task"]
  | StartTask [@tla.symbol "start_task"]
  | DoneTask [@tla.symbol "done_task"]
  | CancelTask [@tla.symbol "cancel_task"]
  | ReleaseTask [@tla.symbol "release_task"]
  | Broadcast [@tla.symbol "broadcast"]
  | Suspend [@tla.symbol "suspend"]
  | ToolCall of string [@tla.symbol "tool_call"]
  | AuthSuccess [@tla.symbol "auth_success"]
  | AuthFailure [@tla.symbol "auth_failure"]
  | CircuitOpen [@tla.symbol "circuit_open"]
  | CircuitClose [@tla.symbol "circuit_close"]
  | SearchRefinement [@tla.symbol "search_refinement"]
  | GateDecision of gate_audit_decision [@tla.symbol "gate_decision"]
  | RuntimeConfigWrite [@tla.symbol "runtime_config_write"]
  | Custom of string [@tla.symbol "custom"]
  | Unknown of string [@tla.symbol "unknown"]
[@@deriving tla]

type audit_entry = {
  timestamp: float;
  agent_id: string;
  action: action;
  workspace_id: string option;
  details: Yojson.Safe.t;
  outcome: outcome;
  cost_estimate: float option;
  token_count: int option;
  trace_id: string option;
}

let preview ?(max_len = 200) (value : string) =
  (* UTF-8-safe truncation: byte-based String.sub split multi-byte chars in
     audit/*.jsonl. See Issue #7690. Use [max_bytes:(max_len + 3)] so that
     output length cap matches the original (prefix + suffix). *)
  String_util.utf8_safe ~max_bytes:(max_len + 3) ~suffix:"..." value
  |> String_util.to_string

(** {1 Serialization} *)

let gate_audit_decision_to_string = function
  | Gate_allow -> "allow"
  | Gate_require_confirmation -> "require_confirmation"
  | Gate_deny -> "deny"
  | Gate_confirm -> "confirm"
  | Gate_expired -> "expired"
  | Gate_unauthorized -> "unauthorized"
  | Gate_other value -> value

let gate_audit_decision_of_string = function
  | "allow" -> Gate_allow
  | "require_confirmation" -> Gate_require_confirmation
  | "deny" -> Gate_deny
  | "confirm" -> Gate_confirm
  | "expired" -> Gate_expired
  | "unauthorized" -> Gate_unauthorized
  | value -> Gate_other value

let action_to_string = function
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
  | GateDecision decision -> "gate_decision:" ^ gate_audit_decision_to_string decision
  | RuntimeConfigWrite -> "runtime_config_write"
  | Custom name -> "custom:" ^ name
  | Unknown raw -> raw

let unknown_action raw =
  (* [Unknown] is the forward-compatible unknown-action variant for audit-log
     wire strings. Keep this path named so the parser does not look like a
     silent coercion to a normal concrete action. *)
  Unknown raw

let string_to_action s =
  (* Split on first ':' to separate tag from payload for parameterized
     variants.  Simple action names without ':' match directly.  This
     replaces the old prefix+magic-length approach which was fragile:
     magic numbers drifted from tag lengths, and a fixed-length prefix
     could not account for variable-length payloads. *)
  match String.index_opt s ':' with
  | Some colon_pos ->
    let tag = String.sub s 0 colon_pos in
    let payload = String.sub s (colon_pos + 1) (String.length s - colon_pos - 1) in
    (match tag with
     | "tool_call" -> ToolCall payload
     | "gate_decision" -> GateDecision (gate_audit_decision_of_string payload)
     | "custom" -> Custom payload
     | _ -> unknown_action s)
  | None ->
    (match s with
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
     | "runtime_config_write" -> RuntimeConfigWrite
     | _ -> unknown_action s)

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
    ("workspace_id", Json_util.string_opt_to_json e.workspace_id);
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
    let timestamp = Json_util.get_float json "timestamp" in
    let agent_id = Json_util.get_string json "agent_id" in
    let action_raw = Json_util.get_string json "action" in
    let workspace_id = Json_util.get_string json "workspace_id" in
    let details =
      match Safe_ops.json_member_opt "details" json with
      | Some v -> v
      | None -> `Null
    in
    let outcome =
      match Json_util.get_object json "outcome" with
      | Some o ->
        let status = Json_util.get_string o "status" |> Option.value ~default:"" in
        if status = "success" then Success
        else
          let reason = Safe_ops.json_string ~default:"unknown" "reason" o in
          Failure reason
      | None -> Failure "missing outcome"
    in
    let cost_estimate = Safe_ops.json_float_opt "cost_estimate" json in
    let token_count = Safe_ops.json_int_opt "token_count" json in
    let trace_id = Safe_ops.json_string_opt "trace_id" json in
    match timestamp, agent_id, action_raw with
    | Some timestamp, Some agent_id, Some action_raw ->
      let action = string_to_action action_raw in
      Ok { timestamp; agent_id; action; workspace_id; details; outcome; cost_estimate; token_count; trace_id }
    | _ -> Error "missing required fields (timestamp, agent_id, action)"
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

(** {1 File Operations} *)

type config = Workspace_utils.config

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

(* The directory this store occupies under [.masc]. Exposed so readers of the
   same store name it from here instead of spelling the literal. *)
let store_dirname = "audit"

let get_audit_store (config : config) : Dated_jsonl.t =
  let base = Filename.concat (Workspace_utils.masc_dir config) store_dirname in
  Eio_guard.with_mutex audit_store_cache_mu (fun () ->
    match StringMap.find_opt base !audit_store_cache with
    | Some store -> store
    | None ->
      let store = Dated_jsonl.create ~base_dir:base () in
      audit_store_cache := StringMap.add base store !audit_store_cache;
      store)

(** How many individual corrupt-entry failures {!collect_entries} reports
    before it switches to a suppressed count in the summary. *)
let max_logged_errors = 5

(* Takes decode results rather than rows. [read_entries] decodes during the
   read so the parsed trees are not all held at once, and the reader calls its
   projection newest-first — so the rate-limited logging below must stay out of
   the projection, or which five failures get reported would flip. Folding over
   the returned (chronological) list keeps the reported set and the [#N]
   numbering identical to reading the whole window first. *)
let collect_entries (decoded : (audit_entry, string) result list) :
    audit_entry list =
  let ok_rev, err_count =
    List.fold_left
      (fun (ok, errc) -> function
        | Ok entry -> (entry :: ok, errc)
        | Error reason ->
            let errc = errc + 1 in
            if errc <= max_logged_errors then
              Log.Misc.error "audit_log: corrupt entry (#%d): %s" errc reason;
            (ok, errc))
      ([], 0)
      decoded
  in
  if err_count > 0 then
    Log.Misc.error "audit_log: %d/%d entries failed to parse (possible corruption)%s"
      err_count (List.length decoded)
      (if err_count > max_logged_errors
       then Printf.sprintf " (%d more suppressed)" (err_count - max_logged_errors)
       else "");
  List.rev ok_rev

(** Read recent audit entries from the date-split store.
    Structural parse failures go through [parse_entries] ERROR path. *)
let read_entries ?(n = 10_000) (config : config) : audit_entry list =
  let store = get_audit_store config in
  Dated_jsonl.filter_map_recent store n ~f:(fun json ->
    Some (entry_of_json_r json))
  |> collect_entries

let utc_date_of_timestamp timestamp =
  match Unix.gmtime timestamp with
  | tm ->
    let year = tm.Unix.tm_year + 1900 in
    if year < 0 || year > 9999
    then None
    else
      Some
        (Printf.sprintf
           "%04d-%02d-%02d"
           year
           (tm.Unix.tm_mon + 1)
           tm.Unix.tm_mday)
  | exception Invalid_argument _
  | exception Unix.Unix_error _ -> None
;;

let optional_date_bound = function
  | None -> Some None
  | Some timestamp ->
    Option.map (fun date -> Some date) (utc_date_of_timestamp timestamp)
;;

(* [n] counts entries that satisfy [keep]. {!read_entries} counts rows read, so
   a caller that filters afterwards has to guess how wide a window its matches
   need — the audit store carries every agent's actions, and one busy agent
   fills any fixed guess. *)
(* Day-file names sort lexicographically, so these two bound the range from
   outside: no stored day can precede the first or follow the second. They mean
   "this side is unbounded", which is why an absent [since]/[until] maps onto
   them rather than onto a narrower guess. *)
let earliest_day_bound = "0000-01-01"
let latest_day_bound = "9999-12-31"

let read_entries_matching ?(n = 10_000) ?since ?until ~keep (config : config)
  : audit_entry list
  =
  let store = get_audit_store config in
  (* Corrupt rows are collected but not counted: they are not entries the
     caller asked for, and letting them consume the budget would make [n] mean
     "matches, unless the store is damaged". They still reach
     [collect_entries] so corruption keeps being reported. *)
  let malformed = ref [] in
  let select json =
      match entry_of_json_r json with
      | Ok entry when keep entry -> Some (Ok entry)
      | Ok _ -> None
      | Error _ as corrupt ->
        malformed := corrupt :: !malformed;
        None
  in
  let matched =
    match optional_date_bound since, optional_date_bound until with
    | Some since_day, Some until_day
      when Option.is_some since_day || Option.is_some until_day ->
      (* DET-OK: range identities, not a guess at a missing value. *)
      let since_bound = Option.value ~default:earliest_day_bound since_day in
      let until_bound = Option.value ~default:latest_day_bound until_day in
      Dated_jsonl.collect_matching_range
        store
        ~since:since_bound
        ~until:until_bound
        n
        ~f:select
    | Some _, Some _ | None, _ | _, None ->
      Dated_jsonl.collect_matching store n ~f:select
  in
  collect_entries (List.rev !malformed @ matched)

(** Append a single entry to the audit log (thread-safe via Dated_jsonl). *)
let append_entry (config : config) (entry : audit_entry) =
  let store = get_audit_store config in
  Dated_jsonl.append store (entry_to_json entry)

(** {1 Logging API} *)

(* ── Audit-event helpers ─────────────────────────────────────────── *)

(** Derive a stable lexicographic ID from timestamp and entry content.
    Format: [aud-<16-hex-ms>-<8-hex-content-hash>] *)
let audit_entry_id ~timestamp ~agent_id ~action =
  let ms = Int64.of_float (timestamp *. 1000.0) in
  (* SHA-256, not Stdlib.Digest (MD5): this suffix is the collision boundary
     for an audit key, and it is truncated to 32 bits on top (#26720). *)
  let hash =
    Digestif.SHA256.(
      digest_string
        (agent_id ^ action_to_string action ^ Printf.sprintf "%.6f" timestamp)
      |> to_hex)
  in
  Printf.sprintf "aud-%016Lx-%s" ms (String.sub hash 0 8)

(** Map outcome + action to O2 severity string. *)
let audit_severity ~action ~outcome =
  match outcome with
  | Failure _ ->
    (match action with
     | AuthFailure | CircuitOpen -> "error"
     | ClaimTask | StartTask | DoneTask | CancelTask | ReleaseTask | Broadcast
     | Suspend | ToolCall _ | AuthSuccess | CircuitClose | SearchRefinement
     | GateDecision _ | RuntimeConfigWrite | Custom _ | Unknown _ ->
       "warn")
  | Success ->
    (match action with
     | AuthSuccess -> "info"
     | GateDecision d ->
       (match d with
        | Gate_deny | Gate_unauthorized -> "warn"
        | Gate_allow | Gate_require_confirmation | Gate_confirm | Gate_expired
        | Gate_other _ ->
          "info")
     | CircuitClose -> "warn"
     (* A successful runtime.toml write rewrites global keeper routing
        (RFC-0273 §3.2: the highest-risk surface). Surface it above
        routine info events so a severity-filtered audit scan catches it,
        consistent with [CircuitClose] elevating a significant successful
        transition to "warn". *)
     | RuntimeConfigWrite -> "warn"
     (* Enumerated rather than swept into a default: severity is the key a
        filtered audit scan reads, and RuntimeConfigWrite above is the record
        of what a default costs -- it sat at "info" until someone noticed the
        highest-risk surface was hidden among routine events. A new action now
        has to be placed here. *)
     | ClaimTask | StartTask | DoneTask | CancelTask | ReleaseTask | Broadcast
     | Suspend | ToolCall _ | AuthFailure | CircuitOpen | SearchRefinement
     | Custom _ | Unknown _ ->
       "info")

(** Build a human-readable one-line summary from action + details. *)
let audit_summary ~action ~details =
  let kind = action_to_string action in
  let extract_str key =
    match details with
    | `Assoc fields -> (match List.assoc_opt key fields with
      | Some (`String v) -> Some (String.sub v 0 (min (String.length v) 80))
      | _ -> None)
    | _ -> None
  in
  let extract_bool key =
    match details with
    | `Assoc fields -> (match List.assoc_opt key fields with
      | Some (`Bool v) -> Some v
      | _ -> None)
    | _ -> None
  in
  let extract_string_list key =
    match details with
    | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`List values) ->
         let rec loop acc = function
           | [] -> Some (List.rev acc)
           | `String v :: rest ->
             loop (String.sub v 0 (min (String.length v) 80) :: acc) rest
           | _ :: _ -> None
         in
         loop [] values
       | _ -> None)
    | _ -> None
  in
  match action with
  | ToolCall name ->
    (match extract_str "error_msg" with
     | Some msg -> Printf.sprintf "tool_call:%s failed: %s" name msg
     | None -> Printf.sprintf "tool_call:%s" name)
  | GateDecision d ->
    let decision = gate_audit_decision_to_string d in
    (match extract_str "action_type" with
     | Some at -> Printf.sprintf "gate %s: %s" decision at
     | None -> Printf.sprintf "gate %s" decision)
  | Broadcast ->
    (match extract_str "preview" with
     | Some p -> Printf.sprintf "broadcast: %s" p
     | None -> "broadcast")
  | Suspend ->
    (match extract_str "target_agent" with
     | Some t -> Printf.sprintf "suspend %s" t
     | None -> "suspend")
  | CancelTask ->
    (match extract_str "task_id" with
     | Some id -> Printf.sprintf "cancel_task %s" id
     | None -> "cancel_task")
  | RuntimeConfigWrite ->
    (match extract_str "operation" with
     | Some "assignment" ->
       (match extract_str "keeper_name", extract_str "runtime_id", extract_bool "cleared" with
        | Some keeper, _, Some true ->
          Printf.sprintf "runtime.toml assignment cleared: %s" keeper
        | Some keeper, Some runtime_id, _ ->
          Printf.sprintf "runtime.toml assignment updated: %s -> %s" keeper runtime_id
        | Some keeper, None, _ ->
          Printf.sprintf "runtime.toml assignment updated: %s" keeper
        | None, _, _ -> "runtime.toml assignment updated")
     | Some "routing" ->
       (match
          ( extract_str "lane"
          , extract_str "runtime_id"
          , extract_string_list "runtime_ids"
          , extract_bool "cleared" )
        with
        | Some lane, _, _, Some true ->
          Printf.sprintf "runtime.toml routing cleared: %s" lane
        | Some lane, Some runtime_id, _, _ ->
          Printf.sprintf "runtime.toml routing updated: %s -> %s" lane runtime_id
        | Some lane, None, Some runtime_ids, _ ->
          Printf.sprintf
            "runtime.toml routing updated: %s -> [%s]"
            lane
            (String.concat ", " runtime_ids)
        | Some lane, None, None, _ ->
          Printf.sprintf "runtime.toml routing updated: %s" lane
        | None, _, _, _ -> "runtime.toml routing updated")
     | Some "raw_save" ->
       (match extract_str "path" with
        | Some p -> Printf.sprintf "runtime.toml raw save: %s" p
        | None -> "runtime.toml raw save")
     | Some "reload" ->
       (match extract_str "path" with
        | Some p -> Printf.sprintf "runtime.toml reloaded: %s" p
        | None -> "runtime.toml reloaded")
     | _ ->
       (match extract_str "path" with
        | Some p -> Printf.sprintf "runtime.toml updated: %s" p
        | None -> "runtime.toml updated"))
  | _ -> kind

(** Extract primary target from action + details, if any. *)
let audit_target ~action ~details =
  let extract_str key =
    match details with
    | `Assoc fields -> (match List.assoc_opt key fields with
      | Some (`String v) -> Some v
      | _ -> None)
    | _ -> None
  in
  match action with
  | ToolCall name -> Some name
  | GateDecision _ -> extract_str "action_type"
  | ClaimTask | StartTask | DoneTask | CancelTask | ReleaseTask ->
    extract_str "task_id"
  | Suspend -> extract_str "target_agent"
  | RuntimeConfigWrite -> extract_str "path"
  | Custom _ -> extract_str "tool_name"
  (* These carry no single subject worth putting in the one-line summary. *)
  | Broadcast | AuthSuccess | AuthFailure | CircuitOpen | CircuitClose
  | SearchRefinement | Unknown _ ->
    None

let audit_event_severity (entry : audit_entry) =
  audit_severity ~action:entry.action ~outcome:entry.outcome

let audit_event_json (entry : audit_entry) =
  let kind = action_to_string entry.action in
  let id =
    audit_entry_id ~timestamp:entry.timestamp ~agent_id:entry.agent_id
      ~action:entry.action
  in
  let target = audit_target ~action:entry.action ~details:entry.details in
  let fields =
    [
      ("id", `String id);
      ("ts", `String (Masc_domain.iso8601_of_unix_seconds entry.timestamp));
      ("actor", `String entry.agent_id);
      ("kind", `String kind);
      ("summary", `String (audit_summary ~action:entry.action ~details:entry.details));
      ("severity", `String (audit_event_severity entry));
    ]
  in
  let fields =
    match target with
    | Some value -> ("target", `String value) :: fields
    | None -> fields
  in
  let fields =
    if entry.details = `Null then fields else ("payload", entry.details) :: fields
  in
  `Assoc fields

(* One predicate for the query filters, so the read and the projection cannot
   disagree about what the caller asked for. A reader that counts matches needs
   this decision before it pages; leaving it inside the projection is what made
   the endpoint read a multiple of [limit] and hope. *)
let audit_entry_matches ?actor ?kind ?severity ?since ?until (entry : audit_entry)
  =
  (match actor with
   | None -> true
   | Some value -> String.equal entry.agent_id (String.trim value))
  && (match kind with
      | None -> true
      | Some value ->
        String.starts_with ~prefix:(String.trim value)
          (action_to_string entry.action))
  && (match since with None -> true | Some value -> entry.timestamp >= value)
  && (match until with None -> true | Some value -> entry.timestamp <= value)
  && (match severity with
      | None -> true
      | Some value ->
        String.equal (audit_event_severity entry) (String.trim value))

let audit_events_response_json ?actor ?kind ?severity ?since ?until ~limit
    (entries : audit_entry list) =
  let filtered =
    List.filter (audit_entry_matches ?actor ?kind ?severity ?since ?until) entries
  in
  let total = List.length filtered in
  let drop_n = max 0 (total - limit) in
  let rec drop_front n = function
    | list when n <= 0 -> list
    | [] -> []
    | _ :: rest -> drop_front (n - 1) rest
  in
  let page = drop_front drop_n filtered in
  `Assoc
    [
      ("entries", `List (List.map audit_event_json page));
      ("count", `Int (List.length page));
    ]

let log_action
    (config : config)
    ~agent_id
    ~action
    ?(workspace_id : string option)
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
    workspace_id;
    details;
    outcome;
    cost_estimate;
    token_count;
    trace_id;
  } in
  append_entry config entry;
  (* Publish to the MASC event bus for real-time SSE streaming. *)
  let id = audit_entry_id ~timestamp:entry.timestamp ~agent_id ~action in
  let ts = Masc_domain.iso8601_of_unix_seconds entry.timestamp in
  let kind = action_to_string action in
  let severity = audit_severity ~action ~outcome in
  let summary = audit_summary ~action ~details in
  let target = audit_target ~action ~details in
  let payload_opt = if details = `Null then None else Some details in
  Keeper_event_publisher.publish_audit_event ~id ~ts ~actor:agent_id ~kind ?target
    ~summary ~severity ?payload:payload_opt ()

(** Convenience functions for common events *)

let log_broadcast config ~agent_id ~message_preview ?cost_estimate ?token_count () =
  (* Truncate message for privacy/size *)
  let preview = preview ~max_len:100 message_preview in
  log_action config ~agent_id ~action:Broadcast
    ~details:(`Assoc [("preview", `String preview)])
    ?cost_estimate ?token_count ~outcome:Success ()

let log_tool_call config ~agent_id ~tool_name ~success ~error_msg ?cost_estimate ?token_count ?trace_id () =
  let outcome = if success then Success else Failure (Option.value error_msg ~default:"unknown") in
  log_action config ~agent_id ~action:(ToolCall tool_name) ?cost_estimate ?token_count ?trace_id ~outcome ()

let remove_assoc_keys keys fields =
  List.filter (fun (key, _) -> not (List.mem key keys)) fields

let log_non_public_tool_call config ~agent_id ~tool_name ~success ~error_msg
    ?(details : Yojson.Safe.t = `Null) ?cost_estimate ?token_count ?trace_id () =
  let outcome =
    if success then Success else Failure (Option.value error_msg ~default:"unknown")
  in
  let details =
    match details with
    | `Assoc fields ->
        let caller_fields = remove_assoc_keys [ "surface"; "tool_name" ] fields in
        `Assoc
          (("surface", `String "non_public")
          :: ("tool_name", `String tool_name)
          :: caller_fields)
    | other ->
        `Assoc
          [
            ("surface", `String "non_public");
            ("tool_name", `String tool_name);
            ("context", other);
          ]
  in
  log_action config ~agent_id ~action:(Custom "non_public_tool_call")
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

let log_gate_decision config ~agent_id ~trace_id ~decision ~action_type ~confirmation_state () =
  log_action config ~agent_id
    ~action:(GateDecision decision)
    ~trace_id
    ~details:(`Assoc [
      ("action_type", `String action_type);
      ("confirmation_state", `String confirmation_state);
    ])
    ~outcome:Success ()

(** Render the result of an audit write as a two-field JSON receipt.
    [Ok ()] becomes [{"recorded": true}]; [Error detail] becomes
    [{"recorded": false, "error": <detail>}] with the detail passed through
    {!Observability_redact.redact_text}. *)
let write_result_to_json = function
  | Ok () -> `Assoc [("recorded", `Bool true)]
  | Error detail ->
    `Assoc [
      ("recorded", `Bool false);
      ("error", `String (Observability_redact.redact_text detail));
    ]

(** {1 Pruning (replaces rotation)} *)

(** Prune audit entries older than [days] days.
    Date-split storage makes rotation unnecessary. *)
(** {1 Statistics} *)

type stats = {
  total_entries: int;
  file_size_bytes: int;
  oldest_timestamp: float option;
  newest_timestamp: float option;
}

let get_stats (config : config) =
  let store = get_audit_store config in
  (* Read a large window to compute stats. Project each row to its timestamp
     during the read: this window is 100k rows and the three values below are
     all that survives, so materialising the parsed trees costs gigabytes that
     are discarded immediately. [Some] wraps every row so [total_entries] still
     counts rows that carry no timestamp. *)
  let timestamps =
    Dated_jsonl.filter_map_recent store 100_000 ~f:(fun json ->
      Some (Safe_ops.json_float_opt "timestamp" json))
  in
  {
    total_entries = List.length timestamps;
    file_size_bytes = 0; (* no longer a single file *)
    (* Chronological order, so the first timestamp present is the oldest and
       the last one present is the newest. *)
    oldest_timestamp = List.find_map Fun.id timestamps;
    newest_timestamp =
      List.fold_left
        (fun newest ts -> match ts with Some _ -> ts | None -> newest)
        None
        timestamps;
  }
