(** MASC Telemetry - Event Tracking and Analytics (Eio Native)

    Tracks:
    - Agent lifecycle events
    - Task progress and completion
    - Handoff triggers
    - Error occurrences

    Storage: .masc/telemetry.jsonl (append-only log)
*)


(** Config type alias *)
type config = Room_utils.config

(** Telemetry event types *)
type event =
  | Agent_joined of { agent_id: string; capabilities: string list }
  | Agent_left of { agent_id: string; reason: string }
  | Task_started of { task_id: string; agent_id: string }
  | Task_completed of { task_id: string; duration_ms: int; success: bool }
  | Handoff_triggered of { from_agent: string; to_agent: string; reason: string }
  | Error_occurred of { code: string; message: string; context: string }
  | Tool_called of { tool_name: string; success: bool; duration_ms: int; agent_id: string option }
[@@deriving yojson, show]

(** Timestamped event record for storage *)
type event_record = {
  timestamp: float;
  event: event;
} [@@deriving yojson, show]

(** Aggregated metrics *)
type metrics = {
  active_agents: int;
  tasks_in_progress: int;
  tasks_completed_24h: int;
  avg_task_duration_ms: float;
  handoff_rate: float;
  error_rate: float;
} [@@deriving yojson, show]

type tool_usage_stats = {
  count: int;
  success_count: int;
  failure_count: int;
  last_used_at: float option;
}

type tool_usage_summary = {
  telemetry_path: string;
  telemetry_available: bool;
  total_calls: int;
  stats_by_tool: (string, tool_usage_stats) Hashtbl.t;
}

let empty_tool_usage_stats = {
  count = 0;
  success_count = 0;
  failure_count = 0;
  last_used_at = None;
}

let update_tool_usage stats_by_tool ~tool_name ~success ~timestamp =
  let current =
    match Hashtbl.find_opt stats_by_tool tool_name with
    | Some stats -> stats
    | None -> empty_tool_usage_stats
  in
  let updated = {
    count = current.count + 1;
    success_count = current.success_count + (if success then 1 else 0);
    failure_count = current.failure_count + (if success then 0 else 1);
    last_used_at =
      Some
        (match current.last_used_at with
        | Some previous -> max previous timestamp
        | None -> timestamp);
  } in
  Hashtbl.replace stats_by_tool tool_name updated

let telemetry_file config =
  Filename.concat (Room_utils.masc_dir config) "telemetry.jsonl"

let read_all_events_from_path (file : string) : event_record list =
  if not (Sys.file_exists file) then
    []
  else
    let ic = open_in file in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let rec loop acc =
          match input_line ic with
          | line ->
              let acc =
                if String.trim line = "" then acc
                else
                  match event_record_of_yojson (Yojson.Safe.from_string line) with
                  | Ok record -> record :: acc
                  | Error _ -> acc
              in
              loop acc
          | exception End_of_file -> List.rev acc
        in
        loop [])

let ensure_masc_dir fs config =
  let dir = Room_utils.masc_dir config in
  let path = Eio.Path.(fs / dir) in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 path

let event_to_json event =
  let record = {
    timestamp = Time_compat.now ();
    event;
  } in
  Yojson.Safe.to_string (event_record_to_yojson record)

(** Track an event - appends to telemetry.jsonl *)
let track ~fs config event : unit =
  ensure_masc_dir fs config;
  let file = telemetry_file config in
  let json_line = event_to_json event ^ "\n" in

  (* Use Room_utils.with_file_lock for concurrent safety *)
  Room_utils.with_file_lock config file (fun () ->
    let path = Eio.Path.(fs / file) in
    Eio.Path.save ~append:true ~create:(`If_missing 0o600) path json_line
  )

(** Read all events from telemetry file *)
let read_all_events ~fs config : event_record list =
  let file = telemetry_file config in
  let path = Eio.Path.(fs / file) in
  try
    let content = Eio.Path.load path in
    let lines = String.split_on_char '\n' content
                |> List.filter (fun s -> String.trim s <> "") in
    List.filter_map (fun line ->
      try
        let json = Yojson.Safe.from_string line in
        match event_record_of_yojson json with
        | Ok record -> Some record
        | Error _ -> None
      with Yojson.Json_error _ -> None
    ) lines
  with Sys_error _ | Eio.Io _ -> []

let summarize_tool_usage ?fs config : tool_usage_summary =
  let telemetry_path = telemetry_file config in
  let telemetry_available = Sys.file_exists telemetry_path in
  let stats_by_tool = Hashtbl.create 32 in
  let total_calls = ref 0 in
  let records =
    match fs with
    | Some fs when telemetry_available -> read_all_events ~fs config
    | _ -> read_all_events_from_path telemetry_path
  in
  List.iter (fun (record : event_record) ->
    match record.event with
    | Tool_called { tool_name; success; _ } ->
        incr total_calls;
        update_tool_usage stats_by_tool ~tool_name ~success
          ~timestamp:record.timestamp
    | _ -> ()
  ) records;
  {
    telemetry_path;
    telemetry_available;
    total_calls = !total_calls;
    stats_by_tool;
  }

(** Agent activity summary from telemetry, filtered by time window. *)
type agent_activity = {
  agent_id: string;
  tool_calls: int;
  success_count: int;
  failure_count: int;
  first_seen: float;
  last_seen: float;
}

let summarize_agent_activity ?fs config ~since : agent_activity list =
  let records =
    match fs with
    | Some fs -> read_all_events ~fs config
    | None -> read_all_events_from_path (telemetry_file config)
  in
  let by_agent : (string, agent_activity) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun (record : event_record) ->
    if record.timestamp >= since then
      match record.event with
      | Tool_called { agent_id = Some aid; success; _ } ->
          let current =
            match Hashtbl.find_opt by_agent aid with
            | Some a -> a
            | None -> { agent_id = aid; tool_calls = 0; success_count = 0;
                        failure_count = 0; first_seen = record.timestamp;
                        last_seen = record.timestamp }
          in
          Hashtbl.replace by_agent aid
            { current with
              tool_calls = current.tool_calls + 1;
              success_count = current.success_count + (if success then 1 else 0);
              failure_count = current.failure_count + (if success then 0 else 1);
              first_seen = min current.first_seen record.timestamp;
              last_seen = max current.last_seen record.timestamp;
            }
      | Agent_joined { agent_id; _ } ->
          if not (Hashtbl.mem by_agent agent_id) then
            Hashtbl.replace by_agent agent_id
              { agent_id; tool_calls = 0; success_count = 0; failure_count = 0;
                first_seen = record.timestamp; last_seen = record.timestamp }
      | _ -> ()
  ) records;
  Hashtbl.fold (fun _ v acc -> v :: acc) by_agent []
  |> List.sort (fun a b -> compare b.tool_calls a.tool_calls)

let tool_usage_fields summary tool_name =
  let stats =
    match Hashtbl.find_opt summary.stats_by_tool tool_name with
    | Some stats -> stats
    | None -> empty_tool_usage_stats
  in
  [
    ("usageCount", `Int stats.count);
    ("usageSuccessCount", `Int stats.success_count);
    ("usageFailureCount", `Int stats.failure_count);
    ("usageLastUsedAt",
     match stats.last_used_at with
     | Some timestamp -> `Float timestamp
     | None -> `Null);
  ]

(** Read events since a timestamp *)
let read_events_since ~fs config ~since : event_record list =
  let all = read_all_events ~fs config in
  List.filter (fun r -> r.timestamp >= since) all

(** Metrics calculation functions (pure) *)
let count_active_agents events =
  let joined = List.filter_map (fun r ->
    match r.event with
    | Agent_joined { agent_id; _ } -> Some agent_id
    | _ -> None
  ) events in
  let left = List.filter_map (fun r ->
    match r.event with
    | Agent_left { agent_id; _ } -> Some agent_id
    | _ -> None
  ) events in
  let active = List.filter (fun id -> not (List.mem id left)) joined in
  List.length (List.sort_uniq String.compare active)

let count_tasks_in_progress events =
  let started = List.filter_map (fun r ->
    match r.event with
    | Task_started { task_id; _ } -> Some task_id
    | _ -> None
  ) events in
  let completed = List.filter_map (fun r ->
    match r.event with
    | Task_completed { task_id; _ } -> Some task_id
    | _ -> None
  ) events in
  let in_progress = List.filter (fun id -> not (List.mem id completed)) started in
  List.length (List.sort_uniq String.compare in_progress)

let count_completed_tasks events =
  List.length (List.filter (fun r ->
    match r.event with
    | Task_completed _ -> true
    | _ -> false
  ) events)

let avg_duration events =
  let durations = List.filter_map (fun r ->
    match r.event with
    | Task_completed { duration_ms; _ } -> Some (float_of_int duration_ms)
    | _ -> None
  ) events in
  match durations with
  | [] -> 0.0
  | times ->
      let sum = List.fold_left (+.) 0.0 times in
      sum /. float_of_int (List.length times)

let calculate_handoff_rate events =
  let handoffs = List.length (List.filter (fun r ->
    match r.event with
    | Handoff_triggered _ -> true
    | _ -> false
  ) events) in
  let task_events = List.length (List.filter (fun r ->
    match r.event with
    | Task_started _ | Task_completed _ -> true
    | _ -> false
  ) events) in
  if task_events = 0 then 0.0
  else float_of_int handoffs /. float_of_int task_events

let calculate_error_rate events =
  let errors = List.length (List.filter (fun r ->
    match r.event with
    | Error_occurred _ -> true
    | _ -> false
  ) events) in
  let total = List.length events in
  if total = 0 then 0.0
  else float_of_int errors /. float_of_int total

(** Get aggregated metrics for last 24 hours *)
let get_metrics ~fs config : metrics =
  let now = Time_compat.now () in
  let since_24h = now -. 86400.0 in
  let events = read_events_since ~fs config ~since:since_24h in
  {
    active_agents = count_active_agents events;
    tasks_in_progress = count_tasks_in_progress events;
    tasks_completed_24h = count_completed_tasks events;
    avg_task_duration_ms = avg_duration events;
    handoff_rate = calculate_handoff_rate events;
    error_rate = calculate_error_rate events;
  }

(** Convenience tracking functions *)
let track_agent_joined ~fs config ~agent_id ?(capabilities=[]) () =
  track ~fs config (Agent_joined { agent_id; capabilities })

let track_agent_left ~fs config ~agent_id ~reason =
  track ~fs config (Agent_left { agent_id; reason })

let track_task_started ~fs config ~task_id ~agent_id =
  track ~fs config (Task_started { task_id; agent_id })

let track_task_completed ~fs config ~task_id ~duration_ms ~success =
  track ~fs config (Task_completed { task_id; duration_ms; success })

let track_handoff ~fs config ~from_agent ~to_agent ~reason =
  track ~fs config (Handoff_triggered { from_agent; to_agent; reason })

let track_error ~fs config ~code ~message ~context =
  track ~fs config (Error_occurred { code; message; context })

let track_tool_called ~fs config ~tool_name ~success ~duration_ms ?agent_id () =
  track ~fs config (Tool_called { tool_name; success; duration_ms; agent_id })

(** Rotate telemetry file *)
let rotate ~fs config ~max_age_days : unit =
  let now = Time_compat.now () in
  let cutoff = now -. (float_of_int max_age_days *. 86400.0) in
  let all = read_all_events ~fs config in
  let recent = List.filter (fun r -> r.timestamp >= cutoff) all in

  let file = telemetry_file config in
  let tmp_file = file ^ ".tmp" in
  let content = 
    List.map (fun record -> Yojson.Safe.to_string (event_record_to_yojson record)) recent
    |> String.concat "\n"
    |> (fun s -> if s = "" then "" else s ^ "\n")
  in
  let tmp_path = Eio.Path.(fs / tmp_file) in
  Eio.Path.save ~create:(`Or_truncate 0o600) tmp_path content;
  Unix.rename tmp_file file
