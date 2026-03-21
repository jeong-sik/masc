(** Audit Log Writer for MASC

    Writes audit events to .masc/audit.jsonl for security monitoring.
    JSONL format for grep-ability and stream processing.

    Complements tool_audit.ml which handles reading/querying.

    Security basis:
    - Open Challenges in MAS Security (arxiv:2505.02077v1)
    - Immutable audit trails for post-incident analysis

    @since 0.6.0 - MASC Social v4 Tier 1
*)

(** {1 Types} *)

type outcome =
  | Success
  | Failure of string

type action =
  | Join
  | Leave
  | ClaimTask
  | DoneTask
  | CancelTask
  | Broadcast
  | Suspend
  | ToolCall of string
  | AuthSuccess
  | AuthFailure
  | CircuitOpen
  | CircuitClose
  | SearchRefinement
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
}

(** {1 Serialization} *)

let action_to_string = function
  | Join -> "join"
  | Leave -> "leave"
  | ClaimTask -> "claim_task"
  | DoneTask -> "done_task"
  | CancelTask -> "cancel_task"
  | Broadcast -> "broadcast"
  | Suspend -> "suspend"
  | ToolCall name -> "tool_call:" ^ name
  | AuthSuccess -> "auth_success"
  | AuthFailure -> "auth_failure"
  | CircuitOpen -> "circuit_open"
  | CircuitClose -> "circuit_close"
  | SearchRefinement -> "search_refinement"
  | Custom name -> "custom:" ^ name

let string_to_action = function
  | "join" -> Join
  | "leave" -> Leave
  | "claim_task" -> ClaimTask
  | "done_task" -> DoneTask
  | "cancel_task" -> CancelTask
  | "broadcast" -> Broadcast
  | "suspend" -> Suspend
  | "auth_success" -> AuthSuccess
  | "auth_failure" -> AuthFailure
  | "circuit_open" -> CircuitOpen
  | "circuit_close" -> CircuitClose
  | "search_refinement" -> SearchRefinement
  | s when String.length s > 10 && String.sub s 0 10 = "tool_call:" ->
      ToolCall (String.sub s 10 (String.length s - 10))
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
    ("room_id", match e.room_id with Some r -> `String r | None -> `Null);
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
  `Assoc with_tokens

(** Parse a JSON object back into an audit_entry *)
let entry_of_json (json : Yojson.Safe.t) : audit_entry option =
  try
    let module U = Yojson.Safe.Util in
    let timestamp = json |> U.member "timestamp" |> U.to_float in
    let agent_id = json |> U.member "agent_id" |> U.to_string in
    let action = json |> U.member "action" |> U.to_string |> string_to_action in
    let room_id = json |> U.member "room_id" |> U.to_string_option in
    let details =
      try json |> U.member "details"
      with Yojson.Safe.Util.Type_error _ -> `Null
    in
    let outcome =
      let o = json |> U.member "outcome" in
      let status = o |> U.member "status" |> U.to_string in
      if status = "success" then Success
      else
        let reason = try o |> U.member "reason" |> U.to_string with Yojson.Safe.Util.Type_error _ -> "unknown" in
        Failure reason
    in
    let cost_estimate =
      try
        match json |> U.member "cost_estimate" with
        | `Float f -> Some f
        | `Int i -> Some (float_of_int i)
        | _ -> None
      with Yojson.Safe.Util.Type_error _ -> None
    in
    let token_count =
      try
        match json |> U.member "token_count" with
        | `Int i -> Some i
        | _ -> None
      with Yojson.Safe.Util.Type_error _ -> None
    in
    Some { timestamp; agent_id; action; room_id; details; outcome; cost_estimate; token_count }
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Misc.warn "audit_log: entry parse failed: %s" (Printexc.to_string exn);
    None

(** {1 File Operations} *)

(** Legacy single-file path (for fallback reads). *)
let legacy_audit_path (config : Room.config) =
  let masc_dir = Room_utils.masc_dir config in
  Filename.concat masc_dir "audit.jsonl"

(** Date-split store: [.masc/audit/YYYY-MM/DD.jsonl].
    Cached per base_dir so all callers share the same Eio.Mutex. *)
let audit_store_cache : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 4

let get_audit_store (config : Room.config) : Dated_jsonl.t =
  let base = Filename.concat (Room_utils.masc_dir config) "audit" in
  match Hashtbl.find_opt audit_store_cache base with
  | Some store -> store
  | None ->
    let store = Dated_jsonl.create ~base_dir:base () in
    Hashtbl.replace audit_store_cache base store;
    store

(** Read recent audit entries.
    Tries date-split store first; falls back to legacy single file. *)
let read_entries ?(n = 10_000) (config : Room.config) : audit_entry list =
  let store = get_audit_store config in
  let entries = Dated_jsonl.read_recent store n in
  if entries <> [] then
    List.filter_map entry_of_json entries
  else
    (* Legacy fallback: single .masc/audit.jsonl *)
    let path = legacy_audit_path config in
    if not (Sys.file_exists path) then []
    else
      let content = Fs_compat.load_file path in
      String.split_on_char '\n' content
      |> List.filter (fun line -> String.trim line <> "")
      |> List.filter_map (fun line ->
          try entry_of_json (Yojson.Safe.from_string line)
          with Yojson.Json_error _ -> None)

(** Append a single entry to the audit log (thread-safe via Dated_jsonl). *)
let append_entry (config : Room.config) (entry : audit_entry) =
  let store = get_audit_store config in
  Dated_jsonl.append store (entry_to_json entry)

(** {1 Logging API} *)

let log_action
    (config : Room.config)
    ~agent_id
    ~action
    ?(room_id : string option)
    ?(details : Yojson.Safe.t = `Null)
    ?(cost_estimate : float option)
    ?(token_count : int option)
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
  } in
  append_entry config entry

(** Convenience functions for common events *)

let log_join config ~agent_id ~room_id ?cost_estimate ?token_count () =
  log_action config ~agent_id ~action:Join ~room_id
    ?cost_estimate ?token_count ~outcome:Success ()

let log_leave config ~agent_id ~room_id ?cost_estimate ?token_count () =
  log_action config ~agent_id ~action:Leave ~room_id
    ?cost_estimate ?token_count ~outcome:Success ()

let log_claim_task config ~agent_id ~room_id ~task_id ?cost_estimate ?token_count () =
  log_action config ~agent_id ~action:ClaimTask ~room_id
    ~details:(`Assoc [("task_id", `String task_id)])
    ?cost_estimate ?token_count ~outcome:Success ()

let log_done_task config ~agent_id ~room_id ~task_id ?cost_estimate ?token_count () =
  log_action config ~agent_id ~action:DoneTask ~room_id
    ~details:(`Assoc [("task_id", `String task_id)])
    ?cost_estimate ?token_count ~outcome:Success ()

let log_cancel_task config ~agent_id ~room_id ~task_id ~reason ?cost_estimate ?token_count () =
  log_action config ~agent_id ~action:CancelTask ~room_id
    ~details:(`Assoc [
      ("task_id", `String task_id);
      ("reason", `String reason);
    ])
    ?cost_estimate ?token_count ~outcome:Success ()

let log_broadcast config ~agent_id ~room_id ~message_preview ?cost_estimate ?token_count () =
  (* Truncate message for privacy/size *)
  let preview = if String.length message_preview > 100
    then String.sub message_preview 0 100 ^ "..."
    else message_preview in
  log_action config ~agent_id ~action:Broadcast ~room_id
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

let log_tool_call config ~agent_id ~tool_name ~success ~error_msg ?cost_estimate ?token_count () =
  let outcome = if success then Success else Failure (Option.value error_msg ~default:"unknown") in
  log_action config ~agent_id ~action:(ToolCall tool_name) ?cost_estimate ?token_count ~outcome ()

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

(** {1 Pruning (replaces rotation)} *)

(** Prune audit entries older than [days] days.
    Date-split storage makes rotation unnecessary. *)
let prune_old (config : Room.config) ~days =
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

let get_stats (config : Room.config) =
  let store = get_audit_store config in
  (* Read a large window to compute stats *)
  let entries = Dated_jsonl.read_recent store 100_000 in
  let count = List.length entries in
  let oldest = ref None in
  let newest = ref None in
  List.iter (fun json ->
    (try
       let ts = Yojson.Safe.Util.(json |> member "timestamp" |> to_float) in
       if !oldest = None then oldest := Some ts;
       newest := Some ts
     with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ())
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
    ("oldest_timestamp", match s.oldest_timestamp with Some t -> `Float t | None -> `Null);
    ("newest_timestamp", match s.newest_timestamp with Some t -> `Float t | None -> `Null);
  ]
