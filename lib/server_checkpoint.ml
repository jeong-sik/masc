(** Server Checkpoint — Periodic server-wide state persistence

    Captures server runtime state to .masc/server_checkpoint.json:
    - Room agents and their last-seen timestamps
    - Task backlog summary (version, counts by status)
    - Sentinel/guardian uptime
    - Governance pending decisions
    - Keeper timeout states
    - Circuit breaker states

    Restored on server startup to avoid cold-start data loss.

    @since 2.102.0 *)

(** {1 Types} *)

type agent_snapshot = {
  name : string;
  last_seen : float;
}

type task_summary = {
  total : int;
  pending : int;
  active : int;
  done_count : int;
}

type keeper_timeout_entry = {
  keeper_name : string;
  timeout_until : float;
  reason : string;
}

type checkpoint = {
  version : int;
  timestamp : float;
  agents : agent_snapshot list;
  task_summary : task_summary;
  sentinel_started_at : float option;
  guardian_started_at : float option;
  governance_pending : string list;
  keeper_timeouts : keeper_timeout_entry list;
  circuit_breaker_open : string list;
}

let current_version = 1

(** {1 JSON Serialization} *)

let agent_to_json (a : agent_snapshot) : Yojson.Safe.t =
  `Assoc [
    ("name", `String a.name);
    ("last_seen", `Float a.last_seen);
  ]

let task_summary_to_json (t : task_summary) : Yojson.Safe.t =
  `Assoc [
    ("total", `Int t.total);
    ("pending", `Int t.pending);
    ("active", `Int t.active);
    ("done", `Int t.done_count);
  ]

let keeper_timeout_to_json (k : keeper_timeout_entry) : Yojson.Safe.t =
  `Assoc [
    ("keeper_name", `String k.keeper_name);
    ("timeout_until", `Float k.timeout_until);
    ("reason", `String k.reason);
  ]

let to_json (c : checkpoint) : Yojson.Safe.t =
  `Assoc [
    ("version", `Int c.version);
    ("timestamp", `Float c.timestamp);
    ("agents", `List (List.map agent_to_json c.agents));
    ("task_summary", task_summary_to_json c.task_summary);
    ("sentinel_started_at",
     (match c.sentinel_started_at with Some f -> `Float f | None -> `Null));
    ("guardian_started_at",
     (match c.guardian_started_at with Some f -> `Float f | None -> `Null));
    ("governance_pending", `List (List.map (fun s -> `String s) c.governance_pending));
    ("keeper_timeouts", `List (List.map keeper_timeout_to_json c.keeper_timeouts));
    ("circuit_breaker_open", `List (List.map (fun s -> `String s) c.circuit_breaker_open));
  ]

(** {1 JSON Deserialization} *)

let json_string key fields =
  match List.assoc_opt key fields with
  | Some (`String s) -> Some s | _ -> None

let json_float key fields =
  match List.assoc_opt key fields with
  | Some (`Float f) -> Some f
  | Some (`Int n) -> Some (float_of_int n)
  | _ -> None

let json_int key fields =
  match List.assoc_opt key fields with
  | Some (`Int n) -> Some n | _ -> None

let json_string_list key fields =
  match List.assoc_opt key fields with
  | Some (`List items) ->
      List.filter_map (function `String s -> Some s | _ -> None) items
  | _ -> []

let parse_agent (json : Yojson.Safe.t) : agent_snapshot option =
  match json with
  | `Assoc fields ->
      (match json_string "name" fields, json_float "last_seen" fields with
       | Some name, Some last_seen -> Some { name; last_seen }
       | _ -> None)
  | _ -> None

let parse_task_summary (json : Yojson.Safe.t) : task_summary =
  match json with
  | `Assoc fields ->
      { total = Option.value ~default:0 (json_int "total" fields);
        pending = Option.value ~default:0 (json_int "pending" fields);
        active = Option.value ~default:0 (json_int "active" fields);
        done_count = Option.value ~default:0 (json_int "done" fields);
      }
  | _ -> { total = 0; pending = 0; active = 0; done_count = 0 }

let parse_keeper_timeout (json : Yojson.Safe.t) : keeper_timeout_entry option =
  match json with
  | `Assoc fields ->
      (match json_string "keeper_name" fields,
             json_float "timeout_until" fields,
             json_string "reason" fields with
       | Some keeper_name, Some timeout_until, Some reason ->
           Some { keeper_name; timeout_until; reason }
       | _ -> None)
  | _ -> None

let of_json (json : Yojson.Safe.t) : checkpoint option =
  match json with
  | `Assoc fields ->
      (match json_int "version" fields with
       | Some v when v = current_version ->
           let agents = match List.assoc_opt "agents" fields with
             | Some (`List items) -> List.filter_map parse_agent items
             | _ -> []
           in
           let task_summary = match List.assoc_opt "task_summary" fields with
             | Some json -> parse_task_summary json
             | None -> { total = 0; pending = 0; active = 0; done_count = 0 }
           in
           let keeper_timeouts = match List.assoc_opt "keeper_timeouts" fields with
             | Some (`List items) -> List.filter_map parse_keeper_timeout items
             | _ -> []
           in
           Some {
             version = v;
             timestamp = Option.value ~default:0.0 (json_float "timestamp" fields);
             agents;
             task_summary;
             sentinel_started_at = json_float "sentinel_started_at" fields;
             guardian_started_at = json_float "guardian_started_at" fields;
             governance_pending = json_string_list "governance_pending" fields;
             keeper_timeouts;
             circuit_breaker_open = json_string_list "circuit_breaker_open" fields;
           }
       | _ ->
           Log.Server.warn "[Checkpoint] unsupported version, ignoring";
           None)
  | _ -> None

(** {1 File I/O} *)

let checkpoint_path () =
  let masc_dir = match Sys.getenv_opt "MASC_BASE_PATH" with
    | Some p when String.trim p <> "" -> Filename.concat p ".masc"
    | _ -> ".masc"
  in
  Filename.concat masc_dir "server_checkpoint.json"

let save (c : checkpoint) : (unit, string) result =
  let path = checkpoint_path () in
  let dir = Filename.dirname path in
  (try Fs_compat.mkdir_p dir
   with Unix.Unix_error _ | Sys_error _ -> ());
  try
    let json_str = Yojson.Safe.pretty_to_string (to_json c) in
    (* Atomic write: unique temp file per call to avoid concurrent save races *)
    let tmp_path = Printf.sprintf "%s.%d-%Ld.tmp" path
      (Unix.getpid ()) (Int64.of_float (Unix.gettimeofday () *. 1e6)) in
    Out_channel.with_open_text tmp_path (fun oc ->
      Out_channel.output_string oc json_str;
      Out_channel.output_string oc "\n");
    Sys.rename tmp_path path;
    Log.Server.debug "[Checkpoint] saved to %s (%.0f bytes)"
      path (float_of_int (String.length json_str));
    Ok ()
  with exn ->
    let msg = Printf.sprintf "checkpoint save failed: %s" (Printexc.to_string exn) in
    Log.Server.warn "[Checkpoint] %s" msg;
    Error msg

let load () : checkpoint option =
  let path = checkpoint_path () in
  if not (Sys.file_exists path) then begin
    Log.Server.info "[Checkpoint] no checkpoint at %s" path;
    None
  end else
    try
      let content = In_channel.with_open_text path In_channel.input_all in
      let json = Yojson.Safe.from_string content in
      match of_json json with
      | Some c ->
          let age = Time_compat.now () -. c.timestamp in
          Log.Server.info "[Checkpoint] loaded from %s (age: %.0fs, %d agents, %d tasks)"
            path age (List.length c.agents) c.task_summary.total;
          Some c
      | None ->
          Log.Server.warn "[Checkpoint] invalid checkpoint at %s, ignoring" path;
          None
    with exn ->
      Log.Server.warn "[Checkpoint] load failed: %s" (Printexc.to_string exn);
      None

(** {1 Capture — Build checkpoint from current server state} *)

(** Build an empty checkpoint (for use when state collectors are not yet available). *)
let empty () : checkpoint = {
  version = current_version;
  timestamp = Time_compat.now ();
  agents = [];
  task_summary = { total = 0; pending = 0; active = 0; done_count = 0 };
  sentinel_started_at = None;
  guardian_started_at = None;
  governance_pending = [];
  keeper_timeouts = [];
  circuit_breaker_open = [];
}

(** {1 Restore — Apply checkpoint to server state} *)

(** Filter keeper timeouts that have not yet expired. *)
let active_keeper_timeouts (c : checkpoint) : keeper_timeout_entry list =
  let now = Time_compat.now () in
  List.filter (fun kt -> kt.timeout_until > now) c.keeper_timeouts

(** Check if checkpoint is stale (older than max_age_s). *)
let is_stale ?(max_age_s = 3600.0) (c : checkpoint) : bool =
  let age = Time_compat.now () -. c.timestamp in
  age > max_age_s
