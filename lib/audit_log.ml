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
  | Custom of string

type audit_entry = {
  timestamp: float;
  agent_id: string;
  action: action;
  room_id: string option;
  details: Yojson.Safe.t;
  outcome: outcome;
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
  | Custom name -> "custom:" ^ name

let outcome_to_json = function
  | Success -> `Assoc [("status", `String "success")]
  | Failure reason -> `Assoc [
      ("status", `String "failure");
      ("reason", `String reason);
    ]

let entry_to_json (e : audit_entry) : Yojson.Safe.t =
  `Assoc [
    ("timestamp", `Float e.timestamp);
    ("agent_id", `String e.agent_id);
    ("action", `String (action_to_string e.action));
    ("room_id", match e.room_id with Some r -> `String r | None -> `Null);
    ("details", e.details);
    ("outcome", outcome_to_json e.outcome);
  ]

(** {1 File Operations} *)

let mutex = Mutex.create ()

let get_audit_path (config : Room.config) =
  let masc_dir = Room_utils.masc_dir config in
  Filename.concat masc_dir "audit.jsonl"

(** Recursively create directory (no shell, safe) *)
let rec ensure_dir_safe dir =
  if Sys.file_exists dir then ()
  else begin
    let parent = Filename.dirname dir in
    if parent <> dir then ensure_dir_safe parent;
    try Unix.mkdir dir 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()  (* Race-safe: another process created it *)
  end

let ensure_dir path =
  let dir = Filename.dirname path in
  ensure_dir_safe dir

(** Append a single entry to the audit log (thread-safe) *)
let append_entry (config : Room.config) (entry : audit_entry) =
  Mutex.lock mutex;
  Common.protect
    ~module_name:"audit_log"
    ~finally_label:"unlock"
    ~finally:(fun () -> Mutex.unlock mutex)
    (fun () ->
      let path = get_audit_path config in
      ensure_dir path;  (* Now safe: EEXIST handled, inside mutex *)
      let json_line = Yojson.Safe.to_string (entry_to_json entry) ^ "\n" in
      let oc = open_out_gen [Open_append; Open_creat; Open_text] 0o644 path in
      Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
        output_string oc json_line
      )
    )

(** {1 Logging API} *)

let log_action
    (config : Room.config)
    ~agent_id
    ~action
    ?(room_id : string option)
    ?(details : Yojson.Safe.t = `Null)
    ~outcome
    () =
  let entry = {
    timestamp = Time_compat.now ();
    agent_id;
    action;
    room_id;
    details;
    outcome;
  } in
  append_entry config entry

(** Convenience functions for common events *)

let log_join config ~agent_id ~room_id =
  log_action config ~agent_id ~action:Join ~room_id
    ~outcome:Success ()

let log_leave config ~agent_id ~room_id =
  log_action config ~agent_id ~action:Leave ~room_id
    ~outcome:Success ()

let log_claim_task config ~agent_id ~room_id ~task_id =
  log_action config ~agent_id ~action:ClaimTask ~room_id
    ~details:(`Assoc [("task_id", `String task_id)])
    ~outcome:Success ()

let log_done_task config ~agent_id ~room_id ~task_id =
  log_action config ~agent_id ~action:DoneTask ~room_id
    ~details:(`Assoc [("task_id", `String task_id)])
    ~outcome:Success ()

let log_cancel_task config ~agent_id ~room_id ~task_id ~reason =
  log_action config ~agent_id ~action:CancelTask ~room_id
    ~details:(`Assoc [
      ("task_id", `String task_id);
      ("reason", `String reason);
    ])
    ~outcome:Success ()

let log_broadcast config ~agent_id ~room_id ~message_preview =
  (* Truncate message for privacy/size *)
  let preview = if String.length message_preview > 100
    then String.sub message_preview 0 100 ^ "..."
    else message_preview in
  log_action config ~agent_id ~action:Broadcast ~room_id
    ~details:(`Assoc [("preview", `String preview)])
    ~outcome:Success ()

let log_suspend config ~agent_id ~target_agent ~reason ~rooms_affected =
  log_action config ~agent_id ~action:Suspend
    ~details:(`Assoc [
      ("target_agent", `String target_agent);
      ("reason", `String reason);
      ("rooms_affected", `Int rooms_affected);
    ])
    ~outcome:Success ()

let log_tool_call config ~agent_id ~tool_name ~success ~error_msg =
  let outcome = if success then Success else Failure (Option.value error_msg ~default:"unknown") in
  log_action config ~agent_id ~action:(ToolCall tool_name) ~outcome ()

let log_auth_attempt config ~agent_id ~success ~method_name =
  let action = if success then AuthSuccess else AuthFailure in
  log_action config ~agent_id ~action
    ~details:(`Assoc [("method", `String method_name)])
    ~outcome:(if success then Success else Failure "auth_failed") ()

let log_circuit_breaker config ~agent_id ~opened ~reason =
  let action = if opened then CircuitOpen else CircuitClose in
  log_action config ~agent_id ~action
    ~details:(`Assoc [("reason", `String reason)])
    ~outcome:Success ()

(** {1 Rotation & Cleanup} *)

let rotate_if_needed (config : Room.config) ~max_size_bytes =
  let path = get_audit_path config in
  if Sys.file_exists path then begin
    let stats = Unix.stat path in
    if stats.Unix.st_size > max_size_bytes then begin
      (* Rotate: move current to .1, keeping only one backup *)
      let backup_path = path ^ ".1" in
      if Sys.file_exists backup_path then
        Sys.remove backup_path;
      Sys.rename path backup_path;
      Printf.eprintf "[audit_log] Rotated %s (%.1f MB)\n" path
        (float_of_int stats.Unix.st_size /. 1_000_000.0)
    end
  end

(** Default max size: 10MB *)
let default_max_size = 10_000_000

let maybe_rotate config =
  rotate_if_needed config ~max_size_bytes:default_max_size

(** {1 Statistics} *)

type stats = {
  total_entries: int;
  file_size_bytes: int;
  oldest_timestamp: float option;
  newest_timestamp: float option;
}

let get_stats (config : Room.config) =
  let path = get_audit_path config in
  if not (Sys.file_exists path) then
    { total_entries = 0; file_size_bytes = 0; oldest_timestamp = None; newest_timestamp = None }
  else begin
    let size = (Unix.stat path).Unix.st_size in
    (* Count lines and get timestamps *)
    let ic = open_in path in
    let count = ref 0 in
    let oldest = ref None in
    let newest = ref None in
    (try
      while true do
        let line = input_line ic in
        incr count;
        (* Parse timestamp from first/last lines *)
        if !oldest = None || !count <= 1 then begin
          try
            let json = Yojson.Safe.from_string line in
            let ts = Yojson.Safe.Util.(json |> member "timestamp" |> to_float) in
            if !oldest = None then oldest := Some ts;
            newest := Some ts
          with _ -> ()
        end else begin
          (* Just update newest for each line *)
          try
            let json = Yojson.Safe.from_string line in
            let ts = Yojson.Safe.Util.(json |> member "timestamp" |> to_float) in
            newest := Some ts
          with _ -> ()
        end
      done
    with End_of_file -> ());
    close_in ic;
    {
      total_entries = !count;
      file_size_bytes = size;
      oldest_timestamp = !oldest;
      newest_timestamp = !newest;
    }
  end

let stats_to_json (s : stats) : Yojson.Safe.t =
  `Assoc [
    ("total_entries", `Int s.total_entries);
    ("file_size_bytes", `Int s.file_size_bytes);
    ("oldest_timestamp", match s.oldest_timestamp with Some t -> `Float t | None -> `Null);
    ("newest_timestamp", match s.newest_timestamp with Some t -> `Float t | None -> `Null);
  ]
